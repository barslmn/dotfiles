-- nav.lua: getting around the tabs on every machine you're attached to.
--
-- It notes which tabs you use (visits and time spent, ranked like zoxide's
-- frecency) and keeps up to nine pins, both saved in
-- ~/.local/state/wezterm/nav.json so they outlive restarts. Key actions:
--   overview    every tab on every attached domain, most used first, then
--               the domains you could attach
--   workspaces  every workspace, most used first
--   previous    back to the tab you were in before, wherever it is
--   set_pin(n)  pin the current tab as n (again on the same tab: unpin;
--               when n holds another tab, press twice to replace it)
--   jump_pin(n) go to pin n, attaching its domain if needed
--   pins        list the pins
-- A tab is remembered by host, workspace and its title (if you set one) or
-- directory, since tab ids don't survive a restart or reconnect.
local wezterm = require("wezterm")
local act = wezterm.action
local util = require("util")
local names = require("names")
local picker = require("picker")
local domains = require("domains")
local ui = require("ui")

local M = {}

-- A visit counts once you stay this long, so tabs passed on the way
-- somewhere don't gain score.
local VISIT_SECONDS = 3
-- Time in a tab adds a point per SECONDS_PER_POINT, up to MAX_STAY_SECONDS
-- per visit, so a tab left open overnight doesn't win forever.
local SECONDS_PER_POINT = 300
local MAX_STAY_SECONDS = 600
-- Tabs unused for this long are forgotten.
local FORGET_SECONDS = 60 * 86400
-- How often pins are matched to tabs and remote workspaces renamed, and how
-- often state is copied for config reloads and to disk.
local SWEEP_SECONDS = 5
local SYNC_SECONDS = 10
local SAVE_SECONDS = 60
local MRU_SIZE = 50
-- Replacing a pin takes a second press within this long.
local CONFIRM_SECONDS = 3

local STATE_DIR = (os.getenv("XDG_STATE_HOME") or (wezterm.home_dir .. "/.local/state")) .. "/wezterm"
local STATE_FILE = STATE_DIR .. "/nav.json"

-- state.scores: key -> { visits, seconds, last }. state.pins: "n" -> { id,
-- session, key, host, workspace, label }. state.mru: tab ids, newest first;
-- like pin ids, only meaningful within one GUI session, so it isn't saved
-- to disk. All of it survives config reloads in wezterm.GLOBAL, as JSON.
local state
local session
local stay = {} -- the tab being looked at: key, since, tick, credited, counted
local pin_by_tab = {} -- tab id -> pin number, for the bar
local pending -- { n, id, expires }: a pin replacement waiting for its second press
local last_sweep, last_sync, last_save = 0, 0, 0
local dirty_sync, dirty_save = false, false

local function decode(text)
	local ok, value = pcall(wezterm.serde.json_decode, text or "")
	return ok and type(value) == "table" and value or nil
end

local function load()
	if state then
		return state
	end
	-- GLOBAL lasts as long as the GUI process, so it marks the session.
	session = wezterm.GLOBAL.nav_session
	if not session then
		session = tostring(os.time()) .. "-" .. tostring(math.random(1000000000))
		wezterm.GLOBAL.nav_session = session
	end
	state = decode(wezterm.GLOBAL.nav_state)
	if not state then
		local file = io.open(STATE_FILE, "r")
		if file then
			state = decode(file:read("*a"))
			file:close()
		end
	end
	state = state or {}
	state.scores = state.scores or {}
	state.pins = state.pins or {}
	state.mru = state.mru or {}
	return state
end

local function changed()
	dirty_sync, dirty_save = true, true
end

local function write_file()
	local saved = {}
	for k, v in pairs(state) do
		saved[k] = v
	end
	saved.mru = nil
	local text = wezterm.serde.json_encode(saved)
	local tmp = STATE_FILE .. ".tmp"
	local file = io.open(tmp, "w")
	if not file then
		wezterm.run_child_process({ "mkdir", "-p", STATE_DIR })
		file = io.open(tmp, "w")
	end
	if not file then
		wezterm.log_warn("nav: can't write " .. STATE_FILE)
		return
	end
	file:write(text)
	file:close()
	os.rename(tmp, STATE_FILE)
end

local function persist(now, force)
	if dirty_sync and (force or now - last_sync >= SYNC_SECONDS) then
		wezterm.GLOBAL.nav_state = wezterm.serde.json_encode(state)
		last_sync, dirty_sync = now, false
	end
	if dirty_save and (force or now - last_save >= SAVE_SECONDS) then
		for key, e in pairs(state.scores) do
			if now - (e.last or 0) > FORGET_SECONDS then
				state.scores[key] = nil
			end
		end
		write_file()
		last_save, dirty_save = now, false
	end
end

local function key_of(tab, pane, workspace)
	local title = tab:get_title()
	local where = title ~= "" and title or util.cwd_path(pane) or names.tab(tab, false)
	return util.host(pane:get_domain_name()) .. "|" .. workspace .. "|" .. where
end

-- zoxide's ranking: score times 4 within the hour, 2 within the day, 1/2
-- within the week, 1/4 after that.
local function frecency(e, now)
	if not e then
		return 0
	end
	local age = now - (e.last or 0)
	local weight = age < 3600 and 4 or age < 86400 and 2 or age < 604800 and 0.5 or 0.25
	return ((e.visits or 0) + (e.seconds or 0) / SECONDS_PER_POINT) * weight
end

-- Every tab on every attached domain.
local function all_tabs()
	local list = {}
	for _, mw in ipairs(wezterm.mux.all_windows()) do
		local ws = mw:get_workspace()
		for _, info in ipairs(mw:tabs_with_info()) do
			local pane = info.tab:active_pane()
			if pane then
				list[#list + 1] = {
					tab = info.tab,
					id = info.tab:tab_id(),
					window = mw,
					workspace = ws,
					domain = pane:get_domain_name(),
					index = info.index,
					key = key_of(info.tab, pane, ws),
				}
			end
		end
	end
	return list
end

local function tab_by_id(id)
	local ok, tab = pcall(wezterm.mux.get_tab, id)
	return ok and tab or nil
end

-- "gpu › work": the workspace without the host prefix domains.lua
-- gives it.
local function place(host, workspace)
	if workspace:sub(1, #host + 1) == host .. "/" then
		workspace = workspace:sub(#host + 2)
	end
	return host .. " › " .. workspace
end

-- Show a tab: activate it, then switch workspace (or GUI window) to it.
local function go_to(window, pane, tab)
	local mw = tab:window()
	local ws = mw:get_workspace()
	tab:activate()
	if ws ~= window:active_workspace() then
		window:perform_action(act.SwitchToWorkspace({ name = ws }), pane)
	elseif mw:window_id() ~= window:window_id() then
		local gui = mw:gui_window()
		if gui then
			gui:focus()
		end
	end
end

-- ---------------------------------------------------------------- pins

local function find_pin(pin, tabs)
	-- By id within the session that pinned it (the key changes when you cd),
	-- else by key (after a restart or reconnect).
	if pin.session == session then
		for _, t in ipairs(tabs) do
			if t.id == pin.id then
				return t
			end
		end
	end
	for _, t in ipairs(tabs) do
		if t.key == pin.key then
			return t
		end
	end
end

-- Match pins to the tabs open now and keep their details current.
local function refresh_pins(tabs)
	pin_by_tab = {}
	for n, pin in pairs(state.pins) do
		local t = find_pin(pin, tabs)
		if t then
			local label = names.tab(t.tab, false)
			if pin.id ~= t.id or pin.key ~= t.key or pin.workspace ~= t.workspace or pin.label ~= label then
				pin.id, pin.session, pin.key, pin.workspace, pin.label = t.id, session, t.key, t.workspace, label
				changed()
			end
			pin_by_tab[t.id] = tonumber(n)
		end
	end
end

M.pin_of = function(tab_id)
	return pin_by_tab[tab_id]
end

local function jump(window, pane, n)
	local pin = state.pins[tostring(n)]
	if not pin then
		ui.flash(window, wezterm.nerdfonts.md_pin_off, "Pin " .. n .. " is empty · ALT+Shift+" .. n .. " pins this tab", { seconds = 2.5 })
		return
	end
	local t = find_pin(pin, all_tabs())
	if not t then
		-- Its machine may just be detached: attach and look again.
		local domain = wezterm.mux.get_domain("SSHMUX:" .. pin.host)
		if domain and domain:state() ~= "Attached" then
			domain:attach()
			domains.prefix_workspaces()
			t = find_pin(pin, all_tabs())
		end
	end
	if not t then
		ui.flash(window, wezterm.nerdfonts.md_pin_off, n .. " · " .. pin.label .. " isn't open (" .. place(pin.host, pin.workspace) .. ")", { seconds = 2.5 })
		return
	end
	local here = window:mux_window():active_tab()
	if not (here and here:tab_id() == t.id) then
		go_to(window, pane, t.tab)
	end
	ui.flash(window, wezterm.nerdfonts.md_pin, n .. " · " .. pin.label .. " · " .. place(pin.host, t.workspace), {
		seconds = 1.5,
		mux_window_id = t.window:window_id(),
	})
end

M.set_pin = function(n)
	return wezterm.action_callback(function(window, _)
		load()
		local mw = window:mux_window()
		local tab = mw:active_tab()
		local pane = tab and tab:active_pane()
		if not pane then
			return
		end
		local now = os.time()
		refresh_pins(all_tabs())
		local id = tab:tab_id()
		local before = pin_by_tab[id]
		local old = state.pins[tostring(n)]
		if old and before ~= n then
			local confirmed = pending and pending.n == n and pending.id == id and now <= pending.expires
			if not confirmed then
				pending = { n = n, id = id, expires = now + CONFIRM_SECONDS }
				local text = "Pin " .. n .. " is " .. old.label .. " · " .. place(old.host, old.workspace) .. " · again to replace"
				ui.flash(window, wezterm.nerdfonts.md_pin, text, { seconds = CONFIRM_SECONDS })
				return
			end
		end
		pending = nil
		if before then
			state.pins[tostring(before)] = nil
		end
		if before == n then
			ui.flash(window, wezterm.nerdfonts.md_pin_off, "Unpinned " .. n, { seconds = 1.5 })
		else
			local ws = mw:get_workspace()
			local pin = {
				id = id,
				session = session,
				key = key_of(tab, pane, ws),
				host = util.host(pane:get_domain_name()),
				workspace = ws,
				label = names.tab(tab, false),
			}
			state.pins[tostring(n)] = pin
			local text = "Pinned " .. n .. " · " .. pin.label .. (old and (" (was " .. old.label .. ")") or "")
			ui.flash(window, wezterm.nerdfonts.md_pin, text, { seconds = 2 })
		end
		refresh_pins(all_tabs())
		changed()
		persist(now, true)
	end)
end

M.jump_pin = function(n)
	return wezterm.action_callback(function(window, pane)
		load()
		jump(window, pane, n)
	end)
end

M.pins = wezterm.action_callback(function(window, pane)
	load()
	local tabs = all_tabs()
	local choices = {}
	for n = 1, 9 do
		local pin = state.pins[tostring(n)]
		if pin then
			local t = find_pin(pin, tabs)
			choices[#choices + 1] = {
				id = tostring(n),
				label = wezterm.nerdfonts.md_pin .. n .. "  " .. pin.label .. "\t" .. place(pin.host, t and t.workspace or pin.workspace) .. (t and "" or " · not open"),
			}
		end
	end
	if #choices == 0 then
		ui.flash(window, wezterm.nerdfonts.md_pin_off, "No pins yet · ALT+Shift+1-9 pins this tab", { seconds = 2.5 })
		return
	end
	picker.select(window, pane, {
		title = "Pins",
		choices = choices,
		fuzzy = true,
		action = function(win, p, id)
			if id then
				jump(win, p, tonumber(id))
			end
		end,
	})
end)

-- ---------------------------------------------------------------- pickers

M.overview = wezterm.action_callback(function(window, pane)
	load()
	local now = os.time()
	local here = window:mux_window():active_tab()
	local here_id = here and here:tab_id()
	local tabs = all_tabs()
	refresh_pins(tabs)
	for _, t in ipairs(tabs) do
		t.score = t.id == here_id and -1 or frecency(state.scores[t.key], now)
	end
	table.sort(tabs, function(a, b)
		if a.score ~= b.score then
			return a.score > b.score
		end
		if a.workspace ~= b.workspace then
			return a.workspace < b.workspace
		end
		return a.index < b.index
	end)

	local choices, attached = {}, {}
	for _, t in ipairs(tabs) do
		local host = util.host(t.domain)
		attached[host] = true
		local pin = pin_by_tab[t.id]
		local label = (pin and (wezterm.nerdfonts.md_pin .. pin .. " ") or "") .. names.tab(t.tab, false)
		local where = place(host, t.workspace) .. " · tab " .. (t.index + 1) .. (t.id == here_id and " · here" or "")
		choices[#choices + 1] = { id = "tab:" .. t.id, label = label .. "\t" .. where }
	end
	-- Machines to attach: mux domains not attached and with no tabs open.
	for _, domain in ipairs(wezterm.mux.all_domains()) do
		local name = domain:name()
		if name:match("^SSHMUX:") and domain:state() ~= "Attached" and not attached[util.host(name)] then
			choices[#choices + 1] = { id = "attach:" .. name, label = "○ attach " .. util.host(name) .. "\t" .. name }
		end
	end

	picker.select(window, pane, {
		title = "Go to tab",
		choices = choices,
		fuzzy = true,
		action = function(win, p, id)
			local tab_id = id and id:match("^tab:(%d+)$")
			local tab = tab_id and tab_by_id(tonumber(tab_id))
			if tab then
				go_to(win, p, tab)
				return
			end
			local dom = id and id:match("^attach:(.*)$")
			if dom then
				domains.attach(win, dom)
			end
		end,
	})
end)

M.workspaces = wezterm.action_callback(function(window, pane)
	load()
	local now = os.time()
	local current = window:active_workspace()
	local by_name, list = {}, {}
	local function entry(name)
		local w = by_name[name]
		if not w then
			w = { name = name, score = 0, tabs = 0, hosts = {}, host_list = {} }
			by_name[name] = w
			list[#list + 1] = w
		end
		return w
	end
	for _, t in ipairs(all_tabs()) do
		local w = entry(t.workspace)
		w.score = w.score + frecency(state.scores[t.key], now)
		w.tabs = w.tabs + 1
		local host = util.host(t.domain)
		if not w.hosts[host] then
			w.hosts[host] = true
			w.host_list[#w.host_list + 1] = host
		end
	end
	for _, name in ipairs(wezterm.mux.get_workspace_names()) do
		entry(name)
	end
	table.sort(list, function(a, b)
		if (a.name == current) ~= (b.name == current) then
			return b.name == current
		end
		if a.score ~= b.score then
			return a.score > b.score
		end
		return a.name < b.name
	end)

	local choices = {}
	for _, w in ipairs(list) do
		local hosts = #w.host_list > 0 and table.concat(w.host_list, "+") or "empty"
		local tabs = w.tabs == 1 and "1 tab" or (w.tabs .. " tabs")
		local label = w.name .. "\t" .. hosts .. " · " .. tabs .. (w.name == current and " · here" or "")
		choices[#choices + 1] = { id = w.name, label = label }
	end
	picker.select(window, pane, {
		title = "Switch workspace",
		choices = choices,
		fuzzy = true,
		action = function(win, p, id)
			if id then
				win:perform_action(act.SwitchToWorkspace({ name = id }), p)
			end
		end,
	})
end)

M.previous = wezterm.action_callback(function(window, pane)
	load()
	local here = window:mux_window():active_tab()
	local here_id = here and here:tab_id()
	for _, id in ipairs(state.mru) do
		if id ~= here_id then
			local tab = tab_by_id(id)
			if tab then
				go_to(window, pane, tab)
				return
			end
		end
	end
	window:perform_action(act.ActivateLastTab, pane)
end)

-- ---------------------------------------------------------------- tracking

local function track(window, now)
	if not window:is_focused() then
		return
	end
	local mw = window:mux_window()
	local tab = mw:active_tab()
	local pane = tab and tab:active_pane()
	if not pane then
		return
	end

	local id = tab:tab_id()
	local mru = state.mru
	if mru[1] ~= id then
		for i = #mru, 1, -1 do
			if mru[i] == id then
				table.remove(mru, i)
			end
		end
		table.insert(mru, 1, id)
		mru[MRU_SIZE + 1] = nil
	end

	local key = key_of(tab, pane, mw:get_workspace())
	if stay.key ~= key then
		stay = { key = key, since = now, tick = now, credited = 0 }
	end
	local e = state.scores[key] or { visits = 0, seconds = 0 }
	state.scores[key] = e
	-- Ticks come every second while focused; a longer gap (sleep, another
	-- app focused) counts as a few seconds at most.
	local add = math.min(now - stay.tick, SWEEP_SECONDS, MAX_STAY_SECONDS - stay.credited)
	stay.tick = now
	if add > 0 then
		e.seconds = e.seconds + add
		stay.credited = stay.credited + add
	end
	if not stay.counted and now - stay.since >= VISIT_SECONDS then
		e.visits = e.visits + 1
		stay.counted = true
	end
	e.last = now
	changed()
end

-- Runs before bar.lua's handler (keybindings.lua requires this module first),
-- so the strip sees current pins.
wezterm.on("update-status", function(window, _)
	load()
	local now = os.time()
	if now - last_sweep >= SWEEP_SECONDS then
		last_sweep = now
		domains.prefix_workspaces()
		refresh_pins(all_tabs())
	end
	domains.follow(window)
	track(window, now)
	persist(now)
end)

return M
