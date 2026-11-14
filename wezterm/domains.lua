-- domains.lua: keys to jump between the domains you have open.
--
-- A domain counts as open when it has at least one pane. They're numbered with
-- this machine first, then alphabetically. Switching to one goes to its
-- workspace (a workspace with only that domain's panes wins over a mixed one),
-- then to a tab in that domain if the workspace has other tabs too.
local wezterm = require("wezterm")
local act = wezterm.action

local M = {}

local LOCAL_DOMAIN = wezterm.hostname()

local function has_domain(tab, dom)
	for _, p in ipairs(tab:panes()) do
		if p:get_domain_name() == dom then
			return true
		end
	end
	return false
end

-- Open domains: this machine first, then by name, so the numbers are stable.
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

-- Go to a domain; with no workspace yet, create one named after the host.
M.switch = function(win, dom)
	local pane = win:active_pane()
	local ws, tab = find(dom)
	if not ws then
		win:perform_action(
			act.SwitchToWorkspace({
				name = dom:match(":(.*)$") or dom,
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

-- Key actions: go to the next/previous open domain, or to number n.
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

M.jump = function(n)
	return wezterm.action_callback(function(window, _)
		local dom = M.list()[n]
		if dom then
			M.switch(window, dom)
		end
	end)
end

return M
