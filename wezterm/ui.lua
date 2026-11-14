-- ui.lua: short messages ("Copied!", "Pinned 2 · nvim") that bar.lua shows
-- in the right status of the window they're for.
local wezterm = require("wezterm")
local M = {}

local FLASH_SECONDS = 0.7

-- The message showing, and a counter so an older message's timer can't end
-- a newer one early.
local current
local flash_count = 0

-- Redraw the status now instead of at the next status_update_interval tick.
local function refresh(window)
	-- pcall: the window may have closed by the time the message ends.
	pcall(function()
		wezterm.emit("update-status", window, window:active_pane())
	end)
end

-- opts.seconds: how long it shows. opts.mux_window_id: show it with this mux
-- window instead of the one on screen now (for a message about where a jump
-- to another workspace lands).
M.flash = function(window, icon, text, opts)
	opts = opts or {}
	flash_count = flash_count + 1
	local count = flash_count
	current = { window = opts.mux_window_id or window:window_id(), icon = icon, text = text }
	refresh(window)

	wezterm.time.call_after(opts.seconds or FLASH_SECONDS, function()
		if flash_count == count then
			current = nil
			refresh(window)
		end
	end)
end

M.start_flash = function(window)
	M.flash(window, wezterm.nerdfonts.md_clipboard_check, "Copied!")
end

-- Icon and text for this window's status, or nil.
M.flash_message = function(window)
	if current and current.window == window:window_id() then
		return current.icon, current.text
	end
end

return M
