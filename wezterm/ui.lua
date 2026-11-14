-- ui.lua: the "Copied!" flash, which bar.lua draws in the right status.
local wezterm = require("wezterm")
local M = {}

local FLASH_SECONDS = 0.7

-- The window flashing and a counter, so an older flash's timer can't end a
-- newer one early.
local flash_window
local flash_count = 0

-- Redraw the status now instead of at the next status_update_interval tick.
local function refresh(window)
	-- pcall: the window may have closed by the time the flash ends.
	pcall(function()
		wezterm.emit("update-status", window, window:active_pane())
	end)
end

M.start_flash = function(window)
	flash_count = flash_count + 1
	local count = flash_count
	flash_window = window:window_id()
	refresh(window)

	wezterm.time.call_after(FLASH_SECONDS, function()
		if flash_count == count then
			flash_window = nil
			refresh(window)
		end
	end)
end

M.is_flashing = function(window)
	return flash_window ~= nil and flash_window == window:window_id()
end

return M
