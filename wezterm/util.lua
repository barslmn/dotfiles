-- util.lua: small helpers shared by the bar and the key bindings.
local wezterm = require("wezterm")

local M = {}

M.LOCAL_DOMAIN = wezterm.hostname()

-- djb2-style string hash: stable across reloads and machines.
M.hash = function(text)
	local h = 5381
	for i = 1, #text do
		h = (h * 31 + text:byte(i)) % 4294967296
	end
	return h
end

-- An accent for a name: one of brights 2-7 (skipping grey and white), so the
-- same name always gets the same colour in the bar and the pickers.
M.accent = function(brights, name)
	return brights[M.hash(name) % 6 + 2]
end

-- The directory the pane's shell reports, as a path, or nil.
M.cwd_path = function(pane)
	local cwd = pane:get_current_working_dir()
	if type(cwd) == "string" then
		return (cwd:gsub("^file://[^/]*", ""))
	end
	return cwd and cwd.file_path
end

-- Whether a domain is another machine (the GUI connects to this machine's
-- mux as a unix domain named after the host).
M.is_remote = function(domain)
	return domain ~= nil and domain ~= M.LOCAL_DOMAIN and domain ~= "local"
end

-- The host a domain is on: "SSHMUX:gpu" -> "gpu". Keep the configured domain
-- alias; OSC 7 may still name an earlier host.
M.host = function(domain)
	if not M.is_remote(domain) then
		return M.LOCAL_DOMAIN
	end
	return (domain:gsub("^SSHMUX:", ""):gsub("^SSH:", ""))
end

return M
