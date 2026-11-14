-- bar.lua: the bottom bar. The left status shows the workspace and a tab
-- strip, the right status system stats, the clock and the domain; windows
-- whose active pane is on another machine get a faint background tint.
--
-- Call require("bar").apply_to_config(config) last in wezterm.lua, so it
-- sees the final colours and tab_max_width.
--
-- For directory-free command titles over mux, use this Fish function on
-- the host running the shell: function fish_title; status current-command; end
-- Save it with: funcsave fish_title

local wezterm = require("wezterm")
local ui = require("ui")
local util = require("util")
local M = {}

-- Statistics are for the Linux machine running the GUI, also in SSH mux tabs.
local SYSTEM_STATS_INTERVAL = 2
local BATTERY_INTERVAL = 10

-- Tabs are drawn in the left status as a strip that scrolls: only the tabs
-- that fit beside the right status are shown, hidden ones are counted at the
-- ends (‹3 … 12›), and the strip moves only when the active tab would leave
-- it. Inactive tabs show their last folder and running command (cut at
-- tab_max_width); the active tab its full title, as long as the free space
-- allows. Long names lose their start, not their end.
--
-- The fancy tab bar draws in window_frame.font while the terminal uses
-- config.font, so widths are converted with this ratio: bar font character
-- width ÷ terminal font character width. GohuFont 11 Nerd Font (0.545 em) ÷
-- IosevkaTerm (0.5 em) ≈ 1.09. Raise it if tabs still reach the right side,
-- and recheck it after changing either font (use 1 with the retro tab bar,
-- which draws in config.font).
local BAR_FONT_RATIO = 1.1
-- Extra columns kept free between the tabs and the right status.
local STRIP_MARGIN = 2
-- Right status spacing: between items, between an icon and its text, and
-- after the last item.
local STATUS_GAP = "   "
local ICON_GAP = " "
local STATUS_END = "  "
-- How much of a remote domain's accent tints the window background.
local DOMAIN_TINT = 0.10

local function read_file(path, pattern)
	local file = io.open(path, "r")
	if not file then
		return nil
	end
	local text = file:read(pattern or "*a")
	file:close()
	return text
end

local function percent(value)
	return math.max(0, math.min(100, value))
end

local function system_stats_reader()
	-- Share samples across all GUI windows; switching domains does not reset CPU.
	local stats = { batteries = {} }
	local sampled_at, battery_at, previous_cpu
	return function()
		local now = os.time()
		if not sampled_at or now < sampled_at or now - sampled_at >= SYSTEM_STATS_INTERVAL then
			sampled_at = now
			local line = read_file("/proc/stat", "*l")
			local fields = {}
			for value in (line and line:match("^cpu%s+(.+)") or ""):gmatch("%d+") do
				fields[#fields + 1] = tonumber(value)
			end
			stats.cpu = nil
			if #fields >= 4 then
				-- user/nice already include guest time: count only the first 8 fields.
				local total = 0
				for i = 1, math.min(8, #fields) do
					total = total + fields[i]
				end
				local idle = fields[4] + (fields[5] or 0)
				if previous_cpu then
					local elapsed = total - previous_cpu.total
					local idle_delta = idle - previous_cpu.idle
					if elapsed > 0 and idle_delta >= 0 then
						stats.cpu = percent(100 * (1 - idle_delta / elapsed))
					end
				end
				previous_cpu = { total = total, idle = idle }
			else
				previous_cpu = nil
			end

			local meminfo = read_file("/proc/meminfo") or ""
			local total = tonumber(meminfo:match("MemTotal:%s+(%d+)"))
			local available = tonumber(meminfo:match("MemAvailable:%s+(%d+)"))
			stats.memory = total and total > 0 and available and percent(100 * (total - available) / total) or nil
		end
		if not battery_at or now < battery_at or now - battery_at >= BATTERY_INTERVAL then
			battery_at = now
			local ok, batteries = pcall(wezterm.battery_info)
			stats.batteries = ok and type(batteries) == "table" and batteries or {}
		end
		return stats
	end
end

local function copy(value)
	if type(value) ~= "table" then
		return value
	end
	local result = {}
	for key, item in pairs(value) do
		result[key] = copy(item)
	end
	return result
end

local function merge(base, extra)
	local result = copy(base)
	for key, value in pairs(extra or {}) do
		if type(value) == "table" and type(result[key]) == "table" then
			result[key] = merge(result[key], value)
		else
			result[key] = copy(value)
		end
	end
	return result
end

local function equal(a, b)
	if type(a) ~= type(b) then
		return false
	end
	if type(a) ~= "table" then
		return a == b
	end
	for key, value in pairs(a) do
		if not equal(value, b[key]) then
			return false
		end
	end
	for key in pairs(b) do
		if a[key] == nil then
			return false
		end
	end
	return true
end

local function mix(background, accent, amount)
	local br, bg, bb = wezterm.color.parse(background):srgba_u8()
	local ar, ag, ab = wezterm.color.parse(accent):srgba_u8()
	local function channel(base, target)
		return math.floor(base + (target - base) * amount + 0.5)
	end
	return string.format("#%02x%02x%02x", channel(br, ar), channel(bg, ag), channel(bb, ab))
end

-- The scheme config.color_scheme names, looked up in WezTerm's order:
-- config.color_schemes, then colors/<name>.toml, then the built-in schemes
-- (last, since building that table of ~1000 schemes is slow).
local function load_palette(config)
	local name = config.color_scheme
	if not name then
		return nil
	end
	local schemes = config.color_schemes or {}
	if schemes[name] then
		return schemes[name]
	end
	local path = wezterm.config_dir .. "/colors/" .. name .. ".toml"
	-- load_scheme/io.open do not register this dependency like require does.
	-- Noctalia replaces this file when it generates a wallpaper palette.
	wezterm.add_to_config_reload_watch_list(path)
	local file = io.open(path, "r")
	if not file then
		return wezterm.color.get_builtin_schemes()[name]
	end
	file:close()
	-- The native loader converts indexed color keys to numbers for Config.
	local palette = wezterm.color.load_scheme(path)
	-- Register it so WezTerm finds it wherever the config directory is.
	schemes[name] = palette
	config.color_schemes = schemes
	return palette
end

-- The bottom bar sits over the pane's already-composited background, so its
-- cells are transparent rather than adding a second fill. The strip colours
-- the active tab with ansi 4 and the others with ansi 6.
local function tab_bar_colors(palette)
	local ansi = palette.ansi or {}
	local tab_bar = copy(palette.tab_bar or {})
	tab_bar.background = "transparent"
	tab_bar.inactive_tab_edge = "transparent"
	tab_bar.inactive_tab_edge_hover = "transparent"
	for _, name in ipairs({ "active_tab", "inactive_tab", "inactive_tab_hover", "new_tab", "new_tab_hover" }) do
		tab_bar[name] = tab_bar[name] or {}
		tab_bar[name].bg_color = "transparent"
	end
	tab_bar.active_tab.fg_color = ansi[4] or tab_bar.active_tab.fg_color
	tab_bar.inactive_tab.fg_color = ansi[6] or tab_bar.inactive_tab.fg_color
	return tab_bar
end

local function domain_label(domain, local_domain)
	if domain == "local" then
		return local_domain
	end
	-- Keep the configured domain alias; OSC 7 may still name an earlier host.
	return (domain:gsub("^SSHMUX:", ""):gsub("^SSH:", ""))
end

-- ---------------------------------------------------------------- tab strip

-- Columns a piece of bar text takes. Nerd Font icons draw wider than a
-- column but still take one in the layout.
local text_width = wezterm.column_width

-- Fit text in `max` columns by dropping its start: "…config/wezterm/x.lua".
local function fit_left(text, max)
	if text_width(text) <= max then
		return text
	end
	if max <= 1 then
		return ""
	end
	return "…" .. wezterm.truncate_left(text, max - 1)
end

local function cells_width(cells)
	local width = 0
	for _, cell in ipairs(cells) do
		if cell.Text then
			width = width + text_width(cell.Text)
		end
	end
	return width
end

local function basename(path)
	path = path:gsub("/+$", "")
	if path == "" or path == "~" or path == wezterm.home_dir or path == "/root" or path:match("^/home/[^/]+$") then
		return "~"
	end
	return path:match("([^/]+)$") or path
end

local function is_path(text)
	local first = text and text:sub(1, 1)
	return first == "/" or first == "~"
end

local SHELLS = { fish = true, bash = true, zsh = true, sh = true }
-- Skipped to find the real command: "sudo htop" shows htop.
local WRAPPERS = { sudo = true, doas = true, time = true, exec = true, command = true, env = true }

-- The command a title says is running: "~/dir: nvim file" (fish title with
-- the command line) or a bare "nvim" (fish_title = status current-command).
-- nil at an idle prompt.
local function command_of(title, before, after)
	local line
	if is_path(before) then
		line = after
	elseif title ~= "" and not is_path(title) and not title:find("[:/ ]") then
		line = title
	end
	local cmd
	for word in (line or ""):gmatch("%S+") do
		cmd = word:match("([^/]+)$")
		if not WRAPPERS[cmd] then
			break
		end
	end
	if not cmd or SHELLS[cmd] or WRAPPERS[cmd] then
		return nil
	end
	return cmd
end

-- An inactive tab's name: its last folder, from the directory the shell
-- reports (fish always does) or else a path in its title, plus the running
-- command: "myproject: nvim". nil when neither is known.
local function short_name(pane)
	local title = pane:get_title() or ""
	local before, after = title:match("^(.-): (.*)$")

	local folder
	local path = util.cwd_path(pane)
	if path and path ~= "" then
		folder = basename(path)
	elseif is_path(before) then
		folder = basename(before)
	elseif is_path(after) then
		folder = basename(after)
	elseif is_path(title) then
		folder = basename(title)
	end

	local cmd = command_of(title, before, after)
	if cmd == folder then
		cmd = nil
	end
	if folder and cmd then
		return folder .. ": " .. cmd
	end
	return folder or cmd
end

local function tab_name(tab, active)
	local name = tab:get_title()
	if name ~= "" then
		return name
	end
	local pane = tab:active_pane()
	if not pane then
		return "shell"
	end
	if not active then
		local short = short_name(pane)
		if short then
			return short
		end
	end
	local process = (pane:get_foreground_process_name() or ""):match("([^/\\]+)$") or ""
	if process ~= "" then
		return process
	end
	local title = pane:get_title() or ""
	return title ~= "" and title or "shell"
end

local function is_zoomed(tab)
	for _, info in ipairs(tab:panes_with_info()) do
		if info.is_zoomed then
			return true
		end
	end
	return false
end

local function marker_width(count)
	return #tostring(count) + 2
end

local strip_first = {} -- mux window id -> first visible tab

-- Which tabs to show. Keeps the previous start unless the active tab would
-- fall outside, so the strip scrolls rather than re-centres.
local function visible_range(key, widths, active, budget)
	local n = #widths
	local function fits(first, last)
		local width = 0
		for i = first, last do
			width = width + widths[i]
		end
		if first > 1 then
			width = width + marker_width(first - 1)
		end
		if last < n then
			width = width + marker_width(n - last)
		end
		return width <= budget
	end
	local function last_from(first)
		local last = first
		while last < n and fits(first, last + 1) do
			last = last + 1
		end
		return last
	end

	local first = math.max(1, math.min(strip_first[key] or 1, active, n))
	local last = last_from(first)
	while active > last and first < active do
		first = first + 1
		last = last_from(first)
	end
	-- Room on the left again (tabs closed, window widened): scroll back.
	while first > 1 and fits(first - 1, last) do
		first = first - 1
	end
	last = last_from(first)
	strip_first[key] = first
	return first, last
end

-- Bar width in bar-font columns.
local function bar_columns(window, mux_window)
	local tab = mux_window:active_tab()
	local size = tab and tab:get_size()
	if not size or size.cols == 0 or size.pixel_width == 0 then
		return nil
	end
	local cell = size.pixel_width / size.cols * BAR_FONT_RATIO
	return math.floor(window:get_dimensions().pixel_width / cell)
end

local function tab_strip(mux_window, budget, max_width, tab_bar, foreground, dim)
	local tabs = mux_window:tabs_with_info()
	if #tabs == 0 then
		return {}
	end
	local labels, widths, active = {}, {}, 1
	for i, info in ipairs(tabs) do
		local name = tab_name(info.tab, info.is_active)
		if is_zoomed(info.tab) then
			name = name .. " " .. wezterm.nerdfonts.md_fullscreen
		end
		local prefix, suffix = " " .. (info.index + 1) .. " ", "  "
		local room = max_width
		if info.is_active then
			-- Whatever the strip has, minus room for the ‹n and n› counts.
			room = budget and (budget - 2 * marker_width(#tabs)) or math.huge
			active = i
		end
		local label = prefix .. fit_left(name, room - #prefix - #suffix) .. suffix
		labels[i], widths[i] = label, text_width(label)
	end

	local first, last = visible_range(mux_window:window_id(), widths, active, budget or math.huge)
	local active_style = tab_bar.active_tab or {}
	local inactive_style = tab_bar.inactive_tab or {}
	local cells = {}
	if first > 1 then
		cells[#cells + 1] = { Foreground = { Color = dim } }
		cells[#cells + 1] = { Attribute = { Intensity = "Normal" } }
		cells[#cells + 1] = { Text = "‹" .. (first - 1) .. " " }
	end
	for i = first, last do
		local is_active = i == active
		local style = is_active and active_style or inactive_style
		cells[#cells + 1] = { Foreground = { Color = style.fg_color or foreground } }
		cells[#cells + 1] = { Attribute = { Intensity = is_active and "Bold" or "Normal" } }
		cells[#cells + 1] = { Text = labels[i] }
	end
	if last < #tabs then
		cells[#cells + 1] = { Foreground = { Color = dim } }
		cells[#cells + 1] = { Attribute = { Intensity = "Normal" } }
		cells[#cells + 1] = { Text = " " .. (#tabs - last) .. "›" }
	end
	return cells
end

M.apply_to_config = function(config)
	local read_stats = system_stats_reader()
	local local_domain = wezterm.hostname()
	local max_width = config.tab_max_width or 16

	-- Everything the bar draws with comes from this palette, which is also
	-- exactly what each window's overrides hold (plus its background), so
	-- the status handler never needs window:effective_config().
	local colors = merge(merge(wezterm.color.get_default_colors(), load_palette(config)), config.colors)
	colors.tab_bar = tab_bar_colors(colors)
	local tab_bar = colors.tab_bar
	local foreground = colors.foreground
	local ansi = colors.ansi or {}
	local brights = colors.brights
	local dim = brights and brights[1] or foreground

	local config_colors = config.colors or {}
	config_colors.tab_bar = copy(tab_bar)
	config.colors = config_colors
	config.enable_tab_bar = true
	config.show_new_tab_button_in_tab_bar = false
	-- The strip in the left status replaces WezTerm's own tab elements.
	config.show_tabs_in_tab_bar = false

	local function background_for(domain)
		if domain == local_domain or domain == "local" or not brights then
			return colors.background
		end
		return mix(colors.background, util.accent(brights, domain), DOMAIN_TINT)
	end

	-- A GUI's overrides survive config reloads, so after a reload (full) the
	-- whole palette is compared, replacing tab_bar/ansi/brights/indexed left
	-- over from the previous Noctalia.toml. Between reloads only the
	-- background can change, so the status tick compares just that.
	local function apply_window_colors(window, domain, full)
		local overrides = window:get_config_overrides() or {}
		local background = background_for(domain)
		local current = overrides.colors
		if not full and current and current.background == background then
			return
		end
		local wanted = copy(colors)
		wanted.background = background
		-- set_config_overrides emits window-config-reloaded too; this check
		-- makes that second invocation a no-op and prevents a reload loop.
		if full and equal(current, wanted) then
			return
		end
		overrides.colors = wanted
		window:set_config_overrides(overrides)
	end

	wezterm.on("window-config-reloaded", function(window, _)
		local pane = window:mux_window():active_pane()
		apply_window_colors(window, pane and pane:get_domain_name() or local_domain, true)
	end)

	wezterm.on("update-status", function(window, _)
		-- Resolve both labels from this window, rather than a globally active
		-- workspace or the pane captured when an asynchronous event was queued.
		local mux_window = window:mux_window()
		local pane = mux_window:active_pane()
		if not pane then
			window:set_left_status("")
			window:set_right_status("")
			return
		end
		local workspace = mux_window:get_workspace()
		local domain = pane:get_domain_name() or local_domain
		apply_window_colors(window, domain)

		local left_cells = {
			{ Background = { Color = tab_bar.background } },
			{ Foreground = { Color = ansi[8] or foreground } },
			{ Text = " " .. wezterm.nerdfonts.cod_window .. " " .. workspace .. "  " },
		}
		if window:leader_is_active() then
			left_cells[#left_cells + 1] = { Foreground = { Color = ansi[2] or foreground } }
			left_cells[#left_cells + 1] = { Text = wezterm.nerdfonts.oct_rocket .. "  " }
		end
		local cells = {
			{ Background = { Color = tab_bar.background } },
			{ Attribute = { Intensity = "Normal" } },
		}
		local function metric(icon, text, color)
			cells[#cells + 1] = { Foreground = { Color = color or foreground } }
			cells[#cells + 1] = { Text = STATUS_GAP .. icon .. ICON_GAP .. text }
		end
		if ui.is_flashing(window) then
			metric(wezterm.nerdfonts.md_clipboard_check, "Copied!", foreground)
		end
		local stats = read_stats()
		for i, battery in ipairs(stats.batteries) do
			if type(battery.state_of_charge) == "number" then
				local charge = percent(battery.state_of_charge * 100)
				local charging = battery.state == "Charging"
				local icon = charging and wezterm.nerdfonts.md_battery_charging or wezterm.nerdfonts.md_battery
				if #stats.batteries > 1 then
					icon = icon .. i
				end
				local color = charging and ansi[3] or (charge <= 20 and ansi[2] or ansi[8])
				metric(icon, string.format("%.0f%%", charge), color)
			end
		end
		metric(wezterm.nerdfonts.md_cpu_64_bit, stats.cpu and string.format("%.0f%%", stats.cpu) or "--", ansi[7])
		if stats.memory then
			metric(wezterm.nerdfonts.md_memory, string.format("%.0f%%", stats.memory), ansi[4])
		end
		metric(wezterm.nerdfonts.md_clock_outline, wezterm.strftime("%H:%M"), ansi[5])
		metric(wezterm.nerdfonts.cod_server, domain_label(domain, local_domain), ansi[8])
		cells[#cells + 1] = { Text = STATUS_END }

		-- Tabs get what's left of the bar after both statuses (plus the half
		-- cell of padding WezTerm puts before each status).
		local columns = bar_columns(window, mux_window)
		local budget = columns and (columns - cells_width(left_cells) - cells_width(cells) - 1 - STRIP_MARGIN)
		for _, item in ipairs(tab_strip(mux_window, budget, max_width, tab_bar, foreground, dim)) do
			left_cells[#left_cells + 1] = item
		end

		-- Always submit both labels. The native setters compare against the
		-- visible GUI's current text and only repaint when it actually changes.
		-- A cache keyed by window_id() (a mux ID) leaves stale labels on A->B->A.
		window:set_left_status(wezterm.format(left_cells))
		window:set_right_status(wezterm.format(cells))
	end)
end

return M
