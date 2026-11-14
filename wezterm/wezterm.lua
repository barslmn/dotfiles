local wezterm = require("wezterm")
local keys = require("keybindings")

local config = wezterm.config_builder()

-- 1. APPEARANCE
-- config.font = wezterm.font("Fira Mono Nerd Font")
config.font = wezterm.font("IosevkaTerm Nerd Font")
-- config.font = wezterm.font("SauceCodePro Nerd Font")
-- config.font = wezterm.font("GohuFont 14 Nerd Font")
config.font_size = 16
config.window_background_opacity = 0.8
config.window_decorations = "NONE"
config.color_scheme = "Noctalia"
config.window_content_alignment = {
	horizontal = "Left",
	vertical = "Bottom",
}
config.window_padding = {
	left = 30,
	right = 30,
	top = 0,
	bottom = 0,
}

-- 2. TAB BAR (drawn by bar.lua, applied at the end)
-- bar.lua measures the bar in window_frame.font, which only the fancy tab
-- bar uses; see BAR_FONT_RATIO there before switching to the retro one.
config.use_fancy_tab_bar = true
config.tab_bar_at_bottom = true
-- config.hide_tab_bar_if_only_one_tab = true
config.tab_max_width = 72
config.window_frame = {
	font = wezterm.font("GohuFont 11 Nerd Font"),
	-- font = wezterm.font("BigBlueTerm437 Nerd Font"),
	-- font = wezterm.font("BigBlueTermPlus Nerd Font"),
	font_size = 16,
	active_titlebar_bg = "none",
	inactive_titlebar_bg = "none",
}

-- 3. INPUTS (Keys & Mouse)
config.keys = keys.keys
config.mouse_bindings = keys.mouse_bindings

-- 4. DOMAINS & MUX
local hostname = wezterm.hostname()
config.default_domain = hostname
config.unix_domains = { { name = hostname } }
-- Auto-connect to local mux so tabs persist if you close the window
config.default_gui_startup_args = { "connect", hostname }
config.default_workspace = hostname

-- Predictive local echo only starts above this latency, so 10 s turns it off.
local ssh_domains = wezterm.default_ssh_domains()
for _, domain in ipairs(ssh_domains) do
	domain.local_echo_threshold_ms = 10000
end
config.ssh_domains = ssh_domains

-- 5. SYSTEM
config.enable_wayland = true
config.scrollback_lines = 10000
config.front_end = "WebGpu"
config.webgpu_power_preference = "HighPerformance"
config.animation_fps = 1
config.cursor_blink_rate = 0
config.text_blink_rate = 0
config.max_fps = 60
config.use_ime = false

-- Last, so the bar sees the final colours and tab settings.
require("bar").apply_to_config(config)

return config
