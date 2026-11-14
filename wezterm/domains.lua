-- domains.lua: moving between the domains you have open, and naming the
-- workspaces other machines bring along.
--
-- A domain counts as open when it has at least one pane. They're ordered with
-- this machine first, then alphabetically. Switching to one goes to its
-- workspace (a workspace with only that domain's panes wins over a mixed one),
-- then to a tab in that domain if the workspace has other tabs too.
local wezterm = require("wezterm")
local act = wezterm.action
local util = require("util")

local M = {}

local LOCAL_DOMAIN = util.LOCAL_DOMAIN

local function has_domain(tab, dom)
	for _, p in ipairs(tab:panes()) do
		if p:get_domain_name() == dom then
			return true
		end
	end
	return false
end

-- Open domains: this machine first, then by name, so the order is stable.
M.list = function()
	local seen, list = {}, {}
	for _, mw in ipairs(wezterm.mux.all_windows()) do
		for _, tab in ipairs(mw:tabs()) do
			for _, p in ipairs(tab:panes()) do
				local d = p:get_domain_name()
				if d and not seen[d] then
					seen[d] = true
					list[#list + 1] = d
				end
			end
		end
	end
	table.sort(list, function(a, b)
		if (a == LOCAL_DOMAIN) ~= (b == LOCAL_DOMAIN) then
			return a == LOCAL_DOMAIN
		end
		return a < b
	end)
	return list
end

-- Where a domain lives. Returns its workspace, and a tab to activate when the
-- workspace's current tab isn't in that domain (nil when it already is).
local function find(dom)
	local fallback_ws, fallback_tab
	for _, mw in ipairs(wezterm.mux.all_windows()) do
		local first, pure = nil, true
		for _, tab in ipairs(mw:tabs()) do
			if has_domain(tab, dom) then
				first = first or tab
			else
				pure = false
			end
		end
		if first then
			local active = mw:active_tab()
			local tab = not (active and has_domain(active, dom)) and first or nil
			if pure then
				return mw:get_workspace(), tab
			end
			if not fallback_ws then
				fallback_ws, fallback_tab = mw:get_workspace(), tab
			end
		end
	end
	return fallback_ws, fallback_tab
end

-- The host whose panes fill this window, or nil when it has this machine's
-- panes or several machines'.
local function window_host(mw)
	local host
	for _, tab in ipairs(mw:tabs()) do
		for _, p in ipairs(tab:panes()) do
			local dom = p:get_domain_name()
			if not util.is_remote(dom) then
				return nil
			end
			local h = util.host(dom)
			if host and h ~= host then
				return nil
			end
			host = h
		end
	end
	return host
end

local moved = {} -- mux window id -> its new workspace, for M.follow

-- Name other machines' workspaces "host/workspace", so two hosts' "default"
-- workspaces don't merge into one here. Windows mixing machines keep their
-- workspace. Cheap when there's nothing to rename; nav.lua runs it every
-- few seconds, and switching to a domain runs it first.
M.prefix_workspaces = function()
	moved = {}
	local plan = {} -- workspace -> { windows = n, moves = { { mw, name } } }
	for _, mw in ipairs(wezterm.mux.all_windows()) do
		local ws = mw:get_workspace()
		local p = plan[ws] or { windows = 0, moves = {} }
		plan[ws] = p
		p.windows = p.windows + 1
		local host = window_host(mw)
		if host and ws:sub(1, #host + 1) ~= host .. "/" then
			table.insert(p.moves, { mw = mw, name = host .. "/" .. ws })
		end
	end
	for ws, p in pairs(plan) do
		-- The whole workspace goes to one name: rename it, which also keeps the
		-- GUI on it. Otherwise move the windows one by one.
		local whole = #p.moves == p.windows
		for _, m in ipairs(p.moves) do
			whole = whole and m.name == p.moves[1].name
		end
		if whole then
			wezterm.mux.rename_workspace(ws, p.moves[1].name)
		end
		for _, m in ipairs(p.moves) do
			if not whole then
				m.mw:set_workspace(m.name)
			end
			moved[m.mw:window_id()] = m.name
		end
	end
end

-- A GUI window whose window M.prefix_workspaces just moved goes with it.
M.follow = function(window)
	local name = moved[window:window_id()]
	if name then
		moved[window:window_id()] = nil
		if window:active_workspace() ~= name then
			window:perform_action(act.SwitchToWorkspace({ name = name }), window:active_pane())
		end
	end
end

-- Go to a domain; with no workspace yet, create "host/default" for it.
M.switch = function(win, dom)
	local pane = win:active_pane()
	M.prefix_workspaces()
	local ws, tab = find(dom)
	if not ws then
		win:perform_action(
			act.SwitchToWorkspace({
				name = util.is_remote(dom) and util.host(dom) .. "/default" or dom,
				spawn = { domain = { DomainName = dom } },
			}),
			pane
		)
		return
	end
	if tab then
		tab:activate()
	end
	if ws ~= win:active_workspace() then
		win:perform_action(act.SwitchToWorkspace({ name = ws }), pane)
	end
end

-- Attach a mux domain if needed (which brings its windows over), then go there.
M.attach = function(win, dom)
	local domain = wezterm.mux.get_domain(dom)
	if not domain then
		return
	end
	if domain:state() ~= "Attached" then
		domain:attach()
	end
	M.switch(win, dom)
end

-- Key action: go to the next/previous open domain.
M.cycle = function(step)
	return wezterm.action_callback(function(window, _)
		local list = M.list()
		if #list == 0 then
			return
		end
		local here = window:active_pane():get_domain_name()
		local i
		for k, d in ipairs(list) do
			if d == here then
				i = k
				break
			end
		end
		local target = i and list[(i - 1 + step) % #list + 1] or list[1]
		M.switch(window, target)
	end)
end

return M
