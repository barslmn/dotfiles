-- picker.lua: show pickers and prompts in Noctalia's launcher (a floating,
-- themed, rofi-style window) instead of WezTerm's own selector and prompt,
-- which cover the whole tab. Falls back to those if the launcher can't run.
--
-- picker.select(window, pane, opts): like InputSelector (title, choices =
--   { { id, label } }, fuzzy, ...), but `action` is a plain
--   function(window, pane, id, label); id and label are nil when cancelled.
--   A tab in a label shows the rest as a description in Noctalia.
-- picker.prompt(window, pane, opts): like PromptInputLine; opts.title and
--   opts.action = function(window, pane, line); line is nil when cancelled.
local wezterm = require("wezterm")
local act = wezterm.action

local M = {}

-- Any dmenu-style launcher: reads entries on stdin, prints the chosen one on
-- stdout, takes the prompt text as its last argument. Prompts rely on it
-- returning typed text that matches no entry, which Noctalia does.
--   { "fuzzel", "--dmenu", "--font", "GohuFont 11 Nerd Font:size=11", "--prompt" }
--   { "rofi", "-dmenu", "-font", "GohuFont 11 Nerd Font 11", "-p" }
M.command = { "noctalia", "dmenu", "-p" }

local DIR = os.getenv("XDG_RUNTIME_DIR") or "/tmp"

-- Labels made with wezterm.format carry colour escapes; the launcher wants
-- plain text. Tabs are kept (title/description split in Noctalia).
local function plain(s)
	s = s:gsub("\27%[[%d;:?]*[ -/]*[@-~]", "") -- CSI, including 38:2::r:g:b colours
	s = s:gsub("\27%][^\7\27]*\7", ""):gsub("\27%][^\27]*\27\\", "") -- OSC
	s = s:gsub("\27[()][%w]", "") -- charset selection
	s = s:gsub("[%z\1-\8\10-\31\127]", " ")
	return s
end

-- Runs the launcher on these lines. Returns "ok", text | "cancel" | "failed".
local function run(window, lines, title)
	local file = string.format("%s/wezterm-picker-%d", DIR, window:window_id())
	local f = io.open(file, "w")
	if not f then
		return "failed"
	end
	if #lines > 0 then
		f:write(table.concat(lines, "\n"), "\n")
	end
	f:close()

	-- run_child_process gives the command no stdin, so let sh feed the file.
	local args = { "sh", "-c", 'exec "$@" < "$0"', file }
	for _, a in ipairs(M.command) do
		args[#args + 1] = a
	end
	args[#args + 1] = title
	local ok, out, err = wezterm.run_child_process(args)
	os.remove(file)

	if ok then
		return "ok", (out:gsub("\r?\n$", ""))
	end
	-- Cancelling exits non-zero quietly; anything on stderr means the
	-- launcher itself failed (not installed, Noctalia not running).
	if err and err:match("%S") then
		wezterm.log_warn("picker: " .. err:gsub("%s+$", "") .. "; using WezTerm's own")
		return "failed"
	end
	return "cancel"
end

M.select = function(window, pane, opts)
	if #opts.choices == 0 then
		return
	end

	-- One line per choice; lines must be unique so the answer maps back.
	local lines, by_line = {}, {}
	for _, c in ipairs(opts.choices) do
		local line = plain(c.label)
		while by_line[line] do
			line = line .. " "
		end
		by_line[line] = c
		lines[#lines + 1] = line
	end

	local status, text = run(window, lines, opts.title or "Select")
	if status == "failed" then
		local o = {}
		for k, v in pairs(opts) do
			o[k] = v
		end
		o.choices = {}
		for _, c in ipairs(opts.choices) do
			o.choices[#o.choices + 1] = { id = c.id, label = (c.label:gsub("\t", "  ")) }
		end
		o.action = wezterm.action_callback(opts.action)
		return window:perform_action(act.InputSelector(o), pane)
	end

	local choice = status == "ok" and by_line[text]
	if choice then
		opts.action(window, pane, choice.id or choice.label, choice.label)
	else
		opts.action(window, pane, nil, nil)
	end
end

M.prompt = function(window, pane, opts)
	local status, text = run(window, {}, opts.title or "")
	if status == "failed" then
		return window:perform_action(
			act.PromptInputLine({
				description = opts.title or "",
				action = wezterm.action_callback(opts.action),
			}),
			pane
		)
	end
	opts.action(window, pane, status == "ok" and text or nil)
end

return M
