-- ~/projects/my-plugins/codebase-gen/lua/codebase-gen.lua

local codebase_gen = {}

local curl = require("plenary.curl")
local json = vim.json

-- Configuration
codebase_gen.config = {
	api_url = "https://api.groq.com/openai/v1/chat/completions",
	api_key = nil,
	model = "mixtral-8x7b-32768",
}

-- Set up the plugin
-- function codebase_gen.setup(opts)
-- 	codebase_gen.config = vim.tbl_extend("force", codebase_gen.config, opts or {})
-- 	if not codebase_gen.config.api_key then
-- 		error("Groq API key not set. Please set it in the setup function.")
-- 	end
-- 	vim.api.nvim_create_user_command("GenerateCodebase", function(opts)
-- 		codebase_gen.generate_codebase(opts.args)
-- 	end, { nargs = 1 })
-- end

-- Helper function to make API calls with streaming
-- local function call_groq_api_stream(messages, callback)
-- 	local job_id = vim.fn.jobstart({
-- 		"curl",
-- 		"-sS",
-- 		"-N",
-- 		codebase_gen.config.api_url,
-- 		"-H",
-- 		"Authorization: Bearer " .. codebase_gen.config.api_key,
-- 		"-H",
-- 		"Content-Type: application/json",
-- 		"-d",
-- 		json.encode({
-- 			model = codebase_gen.config.model,
-- 			messages = messages,
-- 			stream = true,
-- 		}),
-- 	}, {
-- 		on_stdout = function(_, data)
-- 			for _, line in ipairs(data) do
-- 				if line:sub(1, 6) == "data: " then
-- 					local raw_data = line:sub(7)
-- 					if raw_data ~= "[DONE]" then
-- 						local success, parsed_data = pcall(json.decode, raw_data)
-- 						if success and parsed_data.choices and parsed_data.choices[1].delta.content then
-- 							callback(parsed_data.choices[1].delta.content)
-- 						end
-- 					end
-- 				end
-- 			end
-- 		end,
-- 		on_exit = function()
-- 			callback(nil) -- Signal end of stream
-- 		end,
-- 	})
-- end

local function clean_json_string(str)
	str = str:gsub("\\_", "/")
	return str
end

-- Generate project plan
function codebase_gen.generate_project_plan(prompt)
	local messages = {
		{
			role = "system",
			content = "You are a software architect. Given a project description, create a detailed project plan including a list of files needed, a brief description of each file's purpose, and any dependencies or relationships between files. Respond in a JSON format.",
		},
		{ role = "user", content = prompt },
	}
	local plan = ""
	local completed = false
	codebase_gen.call_groq_api_stream(messages, function(content)
		if content then
			plan = plan .. content
		else
			completed = true
		end
	end)
	vim.wait(1000, function()
		return completed
	end)
	-- print("Raw API response:", plan)

	if plan == "" then
		error("Failed to generate project plan: Emplty response from API")
	end

	-- plan = clean_json_string(plan)

	local success, decoded_plan = pcall(json.decode, plan)
	if not success then
		error("Failed to parse project plan: " .. decoded_plan)
	end

	if not decoded_plan.files or type(decoded_plan.files) ~= "table" then
		error("Invalid project plan: 'files' property is missing or not a table")
	end

	return decoded_plan
end

-- Helper function to check if a path is a directory
local function is_directory(path)
	return path:sub(-1) == "/"
end

-- Helper function to create directories
local function create_directory(path)
	vim.fn.mkdir(path, "p")
end

local function get_file_name(file_info)
	return file_info.file or file_info.fileName
end

-- Helper function to open a file and handle swap file prompts
local function safe_edit(file_name)
	-- create buffer
	vim.cmd("edit " .. vim.fn.fnameescape(file_name))

	-- check for swap
	local swap_file = vim.fn.swapname(file_name)
	if swap_file ~= "" then
		print("Swap file exists for " .. file_name .. ". Attempting to delete.")
		local delete_success = vim.fn.delete(swap_file) == 0
		if not delete_success then
			print("Failed to delete swap file. Please delete it manually: " .. swap_file)
			return false
		end
	end

	vim.cmd("edit!")

	-- local ok, err = pcall(function()
	-- 	vim.cmd("edit" .. vim.fn.fnameescape(file_name))
	-- end)

	-- if not ok then
	-- 	print("Error opening file " .. file_name .. ": " .. tostring(err))
	-- 	return false
	-- end

	return true
end

-- Create windows for each file
function codebase_gen.create_windows(files)
	-- print("Creating windows for files:")
	for _, file_info in ipairs(files) do
		local file_name = get_file_name(file_info)
		if file_name then
			if is_directory(file_name) then
				print("Creating directory: " .. file_name)
				create_directory(file_name)
			else
				print("Creating window for file:" .. file_name)
				-- Create parent dir if it doesnt exist
				local parent_dir = vim.fn.fnamemodify(file_name, ":h")
				create_directory(parent_dir)
				if safe_edit(file_name) then
					vim.bo[0].buftype = ""
				else
					print("Failed to create window for file: " .. file_name)
				end
			end
		else
			print("Warning: File object missing 'file' field:", vim.inspect(file_info))
		end
	end
end

-- Generate code for a specific file
function codebase_gen.generate_file_code(file_info, project_plan, system_prompt)
	local messages = {
		{
			role = "system",
			content = "You are a skilled programmer. Generate code for the specified file based on the project plan and system description. Only output the code, no additional explanations.",
		},
		{
			role = "user",
			content = string.format(
				"System: %s\nProject Plan: %s\nGenerate code for file: %s",
				system_prompt,
				json.encode(project_plan),
				json.encode(file_info)
			),
		},
	}
	local code = ""
	local completed = false
	codebase_gen.call_groq_api_stream(messages, function(content)
		if content then
			code = code .. content
		else
			completed = true
		end
	end)

	vim.wait(1000, function()
		return completed
	end)
	return code
end

local function write_to_file(file_path, content)
	local file = io.open(file_path, "w")
	if not file then
		error("Failed to open file for writing: " .. file_path)
	end
	file:write(content)
	file:close()
end

-- Write code to buffer
function codebase_gen.write_to_buffer(code)
	print("Writing to buffer. Code Length: " .. #code)
	local lines = vim.split(code, "\n")
	vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
	if vim.bo.buftype == "" then
		local success, result = pcall(function()
			vim.api.nvim_command("write")
		end)
		if success then
			print("File written successfilly")
		else
			print("Error writing files: " .. tostring(result))
		end
	else
		print("Buffer is not a file buffer, skipping write")
	end
end

-- Main function to generate codebase
function codebase_gen.generate_codebase(prompt)
	local project_plan = codebase_gen.generate_project_plan(prompt)
	print("Project plan generated:", vim.inspect(project_plan))

	if not project_plan.files or #project_plan.files == 0 then
		print("Error No files to generate in the project plan")
		return
	end

	-- codebase_gen.create_windows(project_plan.files)

	for _, file_info in ipairs(project_plan.files) do
		local file_name = get_file_name(file_info)
		if not file_name then
			print("Warning file object missing 'file' field:", vim.inspect(file_info))
		elseif is_directory(file_name) then
			print("Creating directory:" .. file_name)
			create_directory(file_name)
		else
			print("Generating code for file: " .. file_name)
			local code = codebase_gen.generate_file_code(file_info, project_plan, prompt)
			if #code > 0 then
				local parent_dir = vim.fn.fnamemodify(file_name, ":h")
				create_directory(parent_dir)
				write_to_file(file_name, code)
				print("File creating and written: " .. file_name)
			else
				print("Warning generated code is empty for file: " .. file_name)
			end
		end
	end

	print("Codebase generation comlete !!")
end

function codebase_gen.call_groq_api_stream(messages, callback)
	curl.post(codebase_gen.config.api_url, {
		headers = {
			["Content-Type"] = "application/json",
			["Authorization"] = "Bearer " .. codebase_gen.config.api_key,
		},
		body = json.encode({
			model = codebase_gen.config.model,
			messages = messages,
			stream = true,
		}),
		stream = function(_, data, _)
			if data then
				local raw_data = data:match("^data: (.+)")
				if raw_data and raw_data ~= "[DONE]" then
					local success, parsed_data = pcall(json.decode, raw_data)
					if success and parsed_data.choices and parsed_data.choices[1].delta.content then
						callback(parsed_data.choices[1].delta.content)
					end
				end
			end
		end,
		on_complete = function()
			callback(nil)
		end,
	})
end

function codebase_gen.setup(opts)
	codebase_gen.config = vim.tbl_extend("force", {
		api_url = "https://api.groq.com/openai/v1/chat/completions",
		api_key = nil,
		model = "mixtral-8x7b-32768",
	}, opts or {})

	if not codebase_gen.config.api_key then
		error("Groq API key not set. please set it in the setup function.")
	end

	vim.api.nvim_create_user_command("GenerateCodebase", function(opts)
		codebase_gen.generate_codebase(opts.args)
	end, { nargs = 1 })
end

return codebase_gen
