local wezterm = require("wezterm")
local act = wezterm.action
local ui = require("ui")
local util = require("util")
local picker = require("picker")
local domains = require("domains")

local M = {}

-- ALT+y finds commands on screen by the symbol your prompt's command line
-- starts with, and treats this many lines above it as part of the prompt
-- (the directory/git/clock line). WezTerm can't see fish's own prompt/output
-- marks through the mux connection. nil = use whatever the prompt you're at
-- when you press ALT+y starts with.
local PROMPT_SYMBOL = nil
local PROMPT_LINES_ABOVE = 1

-- Resolve once per selector invocation, not once per row.
-- AnsiColor names do NOT resolve against the active scheme in InputSelector
-- labels, so everything below uses hex pulled from resolved_palette, which
-- only has the colours the config sets (WezTerm's defaults fill the gaps).
-- (The colours only show when the picker falls back to InputSelector.)
local function theme(window)
	local pal = window:effective_config().resolved_palette
	local defaults = wezterm.color.get_default_colors()
	local brights = pal.brights or defaults.brights

	return { brights = brights, dim = brights[1], fg = pal.foreground or defaults.foreground }
end

-- Color by domain type (SSH, SSHMUX, unix...), not by host, so the list
-- stays scannable.
local function color_for_domain(t, dom)
	return util.accent(t.brights, dom:match("^([^:]+)") or dom)
end

-- Quick select matches paths relative to the pane's directory, but
-- open_with would resolve them against WezTerm's own.
local function resolve_target(item, pane)
	if item:match("^%a[%w+.-]*://") or item:match("^mailto:") or item:sub(1, 1) == "/" then
		return item
	end
	if item == "~" or item:sub(1, 2) == "~/" then
		return wezterm.home_dir .. item:sub(2)
	end
	local cwd = util.cwd_path(pane)
	if cwd and cwd ~= "" then
		return cwd:gsub("/*$", "/") .. item
	end
	return item
end

-- Commands on screen and their output, oldest first.
local function command_outputs(pane)
	local text = pane:get_logical_lines_as_text(10000)
	local lines = {}

	for line in (text .. "\n"):gmatch("(.-)\n") do
		lines[#lines + 1] = (line:gsub("%s+$", ""))
	end

	-- The symbol: as configured, or the first word of the last non-empty line,
	-- which is the prompt you're typing at.
	local symbol = PROMPT_SYMBOL
	if not symbol then
		for i = #lines, 1, -1 do
			symbol = lines[i]:match("^%s*(%S+)")
			if symbol then
				break
			end
		end
	end
	if not symbol then
		return {}, "?"
	end

	-- Every prompt, with or without a command; empty ones still mark where
	-- the previous command's output ends.
	local pattern = "^%s*" .. symbol:gsub("[%p%c]", "%%%0") .. "%s*(.-)$"
	local prompts = {}

	for i, line in ipairs(lines) do
		local cmd = line:match(pattern)
		if cmd then
			table.insert(prompts, { at = i, cmd = cmd })
		end
	end

	local found = {}

	for n, p in ipairs(prompts) do
		if p.cmd ~= "" then
			local first = p.at + 1
			local last = prompts[n + 1] and (prompts[n + 1].at - 1 - PROMPT_LINES_ABOVE) or #lines

			while first <= last and lines[first] == "" do
				first = first + 1
			end
			while last >= first and lines[last] == "" do
				last = last - 1
			end

			if last >= first then
				table.insert(found, { cmd = p.cmd, output = table.concat(lines, "\n", first, last) })
			end
		end
	end

	return found, symbol
end

M.keys = {
	{
		key = "b",
		mods = "ALT",
		action = wezterm.action_callback(function(window, _)
			local o = window:get_config_overrides() or {}
			o.enable_tab_bar = o.enable_tab_bar == false
			window:set_config_overrides(o)
		end),
	},
	{
		key = "r",
		mods = "ALT",
		action = wezterm.action_callback(function(window, pane)
			picker.prompt(window, pane, {
				title = "Rename tab (empty to reset)",
				action = function(win, _, line)
					if line then
						win:active_tab():set_title(line)
					end
				end,
			})
		end),
	},
	{
		key = "y",
		mods = "ALT",
		action = wezterm.action_callback(function(window, pane)
			local found, symbol = command_outputs(pane)

			if #found == 0 then
				wezterm.log_info(
					"No command output found; looked for prompt lines starting with "
						.. string.format("%q", symbol)
						.. ". Last lines on screen:\n"
						.. pane:get_logical_lines_as_text(8)
				)
				return
			end

			-- Newest first. Label: the command, then its first output line
			-- (shown as a description in Noctalia).
			local choices = {}
			local output_by_id = {}

			for i = #found, 1, -1 do
				local f = found[i]
				local id = tostring(i)
				local first_line = f.output:match("^[^\n]*")

				output_by_id[id] = f.output
				table.insert(choices, {
					id = id,
					label = wezterm.truncate_right(f.cmd, 80) .. "\t" .. wezterm.truncate_right(first_line, 80),
				})
			end

			picker.select(window, pane, {
				title = "Copy command output",
				choices = choices,
				fuzzy = true,
				action = function(win, _, id, _)
					local output = id and output_by_id[id]

					if output then
						win:copy_to_clipboard(output)
						ui.start_flash(win)
					end
				end,
			})
		end),
	},
	{
		key = "Space",
		mods = "ALT",
		action = act.QuickSelectArgs({
			label = "open link or path",
			action = wezterm.action_callback(function(window, pane)
				local item = window:get_selection_text_for_pane(pane)
				wezterm.open_with(resolve_target(item, pane))
			end),
		}),
	},
	{
		key = "o",
		mods = "ALT|SHIFT|CTRL",
		action = wezterm.action_callback(function(window, pane)
			local t = theme(window)
			local choices = {}

			for _, domain in ipairs(wezterm.mux.all_domains()) do
				local name = domain:name()
				local attached = domain:state() == "Attached"

				-- Split "SSHMUX:myhost" so the prefix carries the color
				-- and the host stays in plain foreground.
				local prefix, host = name:match("^([^:]+):(.*)$")

				local parts = {
					{ Foreground = { Color = attached and t.brights[3] or t.dim } },
					{ Text = attached and "● " or "○ " },
					{ Foreground = { Color = color_for_domain(t, name) } },
					{ Attribute = { Intensity = "Bold" } },
					{ Text = prefix or name },
				}

				if host then
					table.insert(parts, { Foreground = { Color = t.dim } })
					table.insert(parts, { Text = ":" })
					table.insert(parts, { Attribute = { Intensity = attached and "Bold" or "Normal" } })
					table.insert(parts, { Foreground = { Color = t.fg } })
					table.insert(parts, { Text = host })
				end

				table.insert(choices, { id = name, label = wezterm.format(parts) })
			end

			if #choices == 0 then
				wezterm.log_info("No domains found")
				return
			end

			picker.select(window, pane, {
				title = "Attach or spawn in domain",
				choices = choices,
				fuzzy = true,
				action = function(win, _, id, _)
					if not id then
						return
					end

					local domain = wezterm.mux.get_domain(id)
					if not domain then
						return
					end

					-- Import the remote windows independently of this
					-- local window, then select their workspace.
					if domain:state() ~= "Attached" then
						domain:attach()
					end
					domains.switch(win, id)
				end,
			})
		end),
	},
	{
		key = "o",
		mods = "ALT",
		action = wezterm.action_callback(function(window, pane)
			local mux = wezterm.mux
			local t = theme(window)
			local current = window:active_workspace()

			-- Collect the domains in use by each workspace, in first-seen order.
			local domains_by_ws = {}

			for _, mux_win in ipairs(mux.all_windows()) do
				local ws = mux_win:get_workspace()
				local seen = domains_by_ws[ws]

				if not seen then
					seen = { order = {}, set = {} }
					domains_by_ws[ws] = seen
				end

				for _, tab in ipairs(mux_win:tabs()) do
					for _, p in ipairs(tab:panes()) do
						local dom = p:get_domain_name()

						if dom and not seen.set[dom] then
							seen.set[dom] = true
							table.insert(seen.order, dom)
						end
					end
				end
			end

			local choices = {}

			for _, ws in ipairs(mux.get_workspace_names()) do
				local info = domains_by_ws[ws]
				local dom = "unknown"

				if info and #info.order > 0 then
					dom = table.concat(info.order, "+")
				end

				local label = wezterm.format({
					{ Foreground = { Color = color_for_domain(t, dom) } },
					{ Text = dom },
					{ Foreground = { Color = t.dim } },
					{ Text = ":" },
					{ Attribute = { Intensity = ws == current and "Bold" or "Normal" } },
					{ Foreground = { Color = t.fg } },
					{ Text = ws },
				})

				if ws == current then
					label = label
						.. wezterm.format({
							{ Foreground = { Color = t.brights[4] } },
							{ Text = " *" },
						})
				end

				table.insert(choices, { id = ws, label = label })
			end

			picker.select(window, pane, {
				title = "Switch workspace",
				choices = choices,
				fuzzy = true,
				action = function(win, p, id, _)
					if id then
						win:perform_action(act.SwitchToWorkspace({ name = id }), p)
					end
				end,
			})
		end),
	},
	{
		key = "o",
		mods = "ALT|SHIFT",
		action = wezterm.action_callback(function(window, pane)
			picker.prompt(window, pane, {
				title = "Name for new workspace",
				action = function(win, p, line)
					if line and line ~= "" then
						win:perform_action(act.SwitchToWorkspace({ name = line }), p)
					end
				end,
			})
		end),
	},
	{
		key = "v",
		mods = "ALT",
		action = act.SplitPane({
			direction = "Right",
			size = { Percent = 50 },
		}),
	},
	{
		key = "v",
		mods = "ALT|SHIFT",
		action = act.SplitPane({
			direction = "Down",
			size = { Percent = 50 },
		}),
	},
	{ key = "h", mods = "ALT", action = act.ActivatePaneDirection("Left") },
	{ key = "l", mods = "ALT", action = act.ActivatePaneDirection("Right") },
	{ key = "k", mods = "ALT", action = act.ActivatePaneDirection("Up") },
	{ key = "j", mods = "ALT", action = act.ActivatePaneDirection("Down") },
	{ key = "t", mods = "ALT", action = act.SpawnTab("CurrentPaneDomain") },
	-- ALT + Tab to switch to the most recently used tab
	{ key = "Tab", mods = "ALT", action = act.ActivateLastTab },
	{ key = "q", mods = "ALT", action = act.ActivateTabRelative(-1) },
	{ key = "e", mods = "ALT", action = act.ActivateTabRelative(1) },
	{ key = "e", mods = "ALT|SHIFT", action = domains.cycle(1) },
	{ key = "q", mods = "ALT|SHIFT", action = domains.cycle(-1) },
	{ key = "e", mods = "ALT|CTRL", action = act.SwitchWorkspaceRelative(1) },
	{ key = "q", mods = "ALT|CTRL", action = act.SwitchWorkspaceRelative(-1) },
	{ key = "t", mods = "ALT|SHIFT", action = picker.tabs },
	{ key = "d", mods = "ALT", action = act.DetachDomain("CurrentPaneDomain") },
	{ key = "w", mods = "ALT", action = act.CloseCurrentTab({ confirm = true }) },
	-- Close the current PANE (if you have splits)
	{ key = "x", mods = "ALT", action = act.CloseCurrentPane({ confirm = true }) },
}

-- ALT+number: tab n. ALT+SHIFT+number: domain n. ALT+CTRL+number: workspace n
-- (alphabetical, same order as ALT+o). phys: keys match the key position,
-- whatever SHIFT+number types on the layout.
for i = 1, 9 do
	table.insert(M.keys, { key = tostring(i), mods = "ALT", action = act.ActivateTab(i - 1) })
	table.insert(M.keys, { key = "phys:" .. i, mods = "ALT|SHIFT", action = domains.jump(i) })
	table.insert(M.keys, {
		key = "phys:" .. i,
		mods = "ALT|CTRL",
		action = wezterm.action_callback(function(window, pane)
			local name = wezterm.mux.get_workspace_names()[i]
			if name then
				window:perform_action(act.SwitchToWorkspace({ name = name }), pane)
			end
		end),
	})
end

-- Releasing the button after a drag or a double/triple click: the selection
-- is already made, so it can be read before copying it.
local copy_and_flash = wezterm.action_callback(function(window, pane)
	local text = window:get_selection_text_for_pane(pane)
	window:perform_action(act.CompleteSelection("ClipboardAndPrimarySelection"), pane)
	if text and #text > 0 then
		ui.start_flash(window)
	end
end)

M.mouse_bindings = {}
for streak = 1, 3 do
	M.mouse_bindings[streak] = {
		event = { Up = { streak = streak, button = "Left" } },
		mods = "NONE",
		action = copy_and_flash,
	}
end

return M
