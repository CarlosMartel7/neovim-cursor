-- JSONL transcript parser for Cursor agent sessions.
--
-- Reads agent-transcript JSONL files and extracts file edits:
--   StrReplace  → { type="str_replace", path, old_string, new_string }
--   Write       → { type="write",       path, content }
--   ApplyPatch  → { type="apply_patch",  path, patch }

local log = require("neovim-cursor.log")

local M = {}

function M.project_hash(cwd)
	local h = cwd:gsub("^/", ""):gsub("/", "-")
	return h
end

function M.transcripts_dir(cwd)
	local home = vim.fn.expand("~")
	local hash = M.project_hash(cwd)
	return home .. "/.cursor/projects/" .. hash .. "/agent-transcripts"
end

function M.list_sessions(cwd)
	local dir = M.transcripts_dir(cwd)
	if vim.fn.isdirectory(dir) == 0 then
		return {}
	end

	local sessions = {}
	local subdirs = vim.fn.readdir(dir)
	for _, name in ipairs(subdirs) do
		local jsonl = dir .. "/" .. name .. "/" .. name .. ".jsonl"
		if vim.fn.filereadable(jsonl) == 1 then
			local stat = vim.loop.fs_stat(jsonl)
			local mtime = stat and stat.mtime and stat.mtime.sec or 0
			local first_prompt = M._extract_first_prompt(jsonl)
			table.insert(sessions, {
				id = name,
				path = jsonl,
				mtime = mtime,
				prompt = first_prompt or "(no prompt)",
			})
		end
	end

	table.sort(sessions, function(a, b)
		return a.mtime > b.mtime
	end)
	return sessions
end

function M._extract_first_prompt(jsonl_path)
	local f = io.open(jsonl_path, "r")
	if not f then
		return nil
	end

	for line in f:lines() do
		local ok, obj = pcall(vim.json.decode, line)
		if ok and obj and obj.role == "user" then
			local content = obj.message and obj.message.content
			if type(content) == "table" then
				for _, block in ipairs(content) do
					if block.type == "text" and type(block.text) == "string" then
						local text = block.text:match("<user_query>%s*(.-)%s*</user_query>")
							or block.text
						f:close()
						return vim.trim(text):sub(1, 120)
					end
				end
			end
		end
	end
	f:close()
	return nil
end

-- Parse a single ApplyPatch string into per-file patches.
local function parse_apply_patch(patch_str)
	local edits = {}
	local current_path = nil
	local chunks = {}

	for line in (patch_str .. "\n"):gmatch("(.-)\n") do
		local update_path = line:match("^%*%*%* Update File:%s*(.+)$")
		if update_path then
			if current_path and #chunks > 0 then
				table.insert(edits, {
					type = "apply_patch",
					path = current_path,
					patch = table.concat(chunks, "\n"),
				})
			end
			current_path = vim.trim(update_path)
			chunks = {}
		elseif current_path then
			table.insert(chunks, line)
		end
	end

	if current_path and #chunks > 0 then
		table.insert(edits, {
			type = "apply_patch",
			path = current_path,
			patch = table.concat(chunks, "\n"),
		})
	end

	return edits
end

function M.parse_edits(jsonl_path)
	local f = io.open(jsonl_path, "r")
	if not f then
		log.debug("diff.parser", "cannot open " .. jsonl_path)
		return {}
	end

	local edits = {}
	for line in f:lines() do
		local ok, obj = pcall(vim.json.decode, line)
		if ok and obj and obj.role == "assistant" then
			local content = obj.message and obj.message.content
			if type(content) == "table" then
				for _, block in ipairs(content) do
					if block.type == "tool_use" then
						M._process_tool_use(block, edits)
					end
				end
			end
		end
	end
	f:close()

	log.debug("diff.parser", "parsed " .. #edits .. " edits from " .. jsonl_path)
	return edits
end

function M._process_tool_use(block, edits)
	local name = block.name
	local input = block.input

	if name == "StrReplace" and type(input) == "table" then
		if input.path and input.old_string and input.new_string then
			table.insert(edits, {
				type = "str_replace",
				path = input.path,
				old_string = input.old_string,
				new_string = input.new_string,
			})
		end
	elseif name == "Write" and type(input) == "table" then
		if input.path then
			table.insert(edits, {
				type = "write",
				path = input.path,
				content = input.contents or input.content or "",
			})
		end
	elseif name == "ApplyPatch" and type(input) == "string" then
		vim.list_extend(edits, parse_apply_patch(input))
	end
end

--- Parse a transcript into per-turn edit groups.
--- Works with both agent-transcripts (role-keyed) and session.jsonl
--- (type-keyed) formats.  A new turn starts at every user message.
function M.parse_turns(jsonl_path)
	local f = io.open(jsonl_path, "r")
	if not f then
		log.debug("diff.parser", "cannot open " .. jsonl_path)
		return {}
	end

	local turns = {}
	local current_prompt = nil
	local current_edits = {}

	local function flush_turn()
		if #current_edits > 0 then
			table.insert(turns, {
				prompt = current_prompt or "(no prompt)",
				edits = current_edits,
			})
		end
		current_prompt = nil
		current_edits = {}
	end

	for line in f:lines() do
		local ok, obj = pcall(vim.json.decode, line)
		if not ok or not obj then
			goto continue
		end

		local role = obj.role or obj.type
		local content = obj.message and obj.message.content

		if role == "user" then
			flush_turn()
			if type(content) == "table" then
				for _, block in ipairs(content) do
					if block.type == "text" and type(block.text) == "string" then
						local text = block.text:match("<user_query>%s*(.-)%s*</user_query>") or block.text
						current_prompt = vim.trim(text):sub(1, 120)
						break
					end
				end
			end
		elseif role == "assistant" then
			if type(content) == "table" then
				for _, block in ipairs(content) do
					if block.type == "tool_use" then
						M._process_tool_use(block, current_edits)
					end
				end
			end
		end

		::continue::
	end
	flush_turn()
	f:close()

	log.debug("diff.parser", "parsed " .. #turns .. " turns from " .. jsonl_path)
	return turns
end

-- Group edits by file path, preserving order within each file.
function M.group_by_file(edits)
	local by_file = {}
	local order = {}
	for _, edit in ipairs(edits) do
		if not by_file[edit.path] then
			by_file[edit.path] = {}
			table.insert(order, edit.path)
		end
		table.insert(by_file[edit.path], edit)
	end
	return by_file, order
end

log.debug("diff.parser", "loaded")

return M
