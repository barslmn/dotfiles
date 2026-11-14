-- util.lua: small helpers shared by the bar and the key bindings.
local M = {}

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

return M
