-- names.lua: what to call a tab, shared by the bar's tab strip and the
-- pickers so a tab reads the same everywhere.
local wezterm = require("wezterm")
local util = require("util")

local M = {}

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

-- A tab's name: its own title if set, else for an inactive tab the short
-- name above, else the running process or the pane title.
M.tab = function(tab, active)
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

return M
