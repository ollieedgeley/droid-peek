if o == nil then
  require("default.hypr.helpers")
end

local SUBMAP_NAME = "droid-peek"
local submap_defined = false
local defining_submap = false
local request_sequence = 0
local staged_scrcpy_arguments = nil
local configuration_committed = false
local helper_executable
local build_info
local reserved_scrcpy_arguments = {
  ["--serial"] = true,
  ["--select-usb"] = true,
  ["--select-tcpip"] = true,
  ["--tcpip"] = true,
  ["--video-source"] = true,
  ["--new-display"] = true,
  ["--display"] = true,
  ["--v4l2-sink"] = true,
  ["--no-video"] = true,
  ["--no-window"] = true,
  ["--window"] = true,
  ["--control"] = true,
  ["--no-control"] = true,
  ["--no-cleanup"] = true,
  ["--no-power-on"] = true,
  ["--max-size"] = true,
  ["--video-bit-rate"] = true,
  ["--max-fps"] = true,
}

local function fail(message)
  error("droid-peek: " .. message, 3)
end

local home = os.getenv("HOME")
if type(home) ~= "string" or home == "" then
  fail("HOME is required")
end
helper_executable = home .. "/.local/bin/droid-peek-helper"

local source = debug.getinfo(1, "S").source
local integration_directory = source:match("^@(.*)/[^/]+$")
  or (home .. "/.config/omarchy/plugins/ollieedgeley.droidpeek/integrations")
build_info = dofile(integration_directory .. "/build-info.lua")
if type(build_info) ~= "table"
    or type(build_info.release_version) ~= "string"
    or build_info.release_version == "" then
  fail("build info is unavailable")
end

local function json_string(value)
  return '"' .. value:gsub('[%z\1-\31\\"]', function(character)
    local escapes = {
      ['"'] = '\\"',
      ["\\"] = "\\\\",
      ["\b"] = "\\b",
      ["\f"] = "\\f",
      ["\n"] = "\\n",
      ["\r"] = "\\r",
      ["\t"] = "\\t",
    }
    return escapes[character] or string.format("\\u%04x", string.byte(character))
  end) .. '"'
end

local function json_value(value, active)
  local value_type = type(value)
  if value_type == "string" then
    return json_string(value)
  end
  if value_type == "boolean" or value_type == "number" then
    return tostring(value)
  end
  if value_type ~= "table" then
    fail("phone target must be JSON data")
  end
  if active[value] then
    fail("phone target must not contain a cycle")
  end

  active[value] = true
  local keys = {}
  for key in pairs(value) do
    if type(key) ~= "string" then
      active[value] = nil
      fail("phone target object keys must be strings")
    end
    table.insert(keys, key)
  end
  table.sort(keys)

  local fields = {}
  for _, key in ipairs(keys) do
    table.insert(fields, json_string(key) .. ":" .. json_value(value[key], active))
  end
  active[value] = nil
  return "{" .. table.concat(fields, ",") .. "}"
end

local function base64url(value)
  local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
  local encoded = {}
  for index = 1, #value, 3 do
    local first = value:byte(index)
    local second = value:byte(index + 1)
    local third = value:byte(index + 2)
    local bits = first * 65536 + (second or 0) * 256 + (third or 0)

    table.insert(encoded, alphabet:sub(math.floor(bits / 262144) % 64 + 1, math.floor(bits / 262144) % 64 + 1))
    table.insert(encoded, alphabet:sub(math.floor(bits / 4096) % 64 + 1, math.floor(bits / 4096) % 64 + 1))
    if second ~= nil then
      table.insert(encoded, alphabet:sub(math.floor(bits / 64) % 64 + 1, math.floor(bits / 64) % 64 + 1))
    end
    if third ~= nil then
      table.insert(encoded, alphabet:sub(bits % 64 + 1, bits % 64 + 1))
    end
  end
  return table.concat(encoded)
end

local function next_request_id()
  request_sequence = request_sequence + 1
  return string.format(
    "%x-%x-%d",
    os.time(),
    math.floor(os.clock() * 1000000),
    request_sequence
  )
end

local function unix_time_ms()
  local process = io.popen("/usr/bin/date +%s%3N", "r")
  if process == nil then
    return os.time() * 1000
  end
  local value = process:read("*l")
  local closed = process:close()
  local milliseconds = tonumber(value)
  if not closed or milliseconds == nil or milliseconds < 0
      or milliseconds ~= math.floor(milliseconds) then
    return os.time() * 1000
  end
  return milliseconds
end

local function dispatch_target(target, description)
  local envelope = table.concat({
    '{"requestId":',
    json_string(next_request_id()),
    ',"target":',
    json_value(target, {}),
    ',"expiresAtUnixMs":',
    tostring(unix_time_ms() + 2000),
    ',"description":',
    json_string(description),
    "}",
  })
  local command = "omarchy-shell ollieedgeley.droidpeek phoneTarget "
    .. o.shell_quote(base64url(envelope))
  hl.exec_cmd(command)
end

local function close_panel()
  hl.dispatch(hl.dsp.submap("reset"))
  hl.exec_cmd("omarchy-shell shell hide ollieedgeley.droidpeek")
end

local function validated_scrcpy_arguments(arguments)
  if type(arguments) ~= "table" then
    fail("scrcpyArgs must be a list")
  end
  local validated = {}
  local count = 0
  for key, argument in pairs(arguments) do
    if type(key) ~= "number" or key < 1 or key ~= math.floor(key)
        or type(argument) ~= "string" then
      fail("scrcpyArgs must be a dense string list")
    end
    count = count + 1
    local name = argument:match("^(%-%-[^=]+)")
    if name == nil or #argument > 512
        or argument:find("[%z\r\n]")
        or reserved_scrcpy_arguments[name]
        or name:match("^%-%-audio") then
      fail("scrcpy argument is invalid or reserved")
    end
    validated[key] = argument
  end
  if count ~= #arguments then
    fail("scrcpyArgs must be a dense string list")
  end
  if count > 32 then
    fail("scrcpyArgs exceeds its limit")
  end
  return validated
end

local function scrcpy_arguments_json(arguments)
  local encoded = {}
  for index, argument in ipairs(arguments) do
    encoded[index] = json_string(argument)
  end
  return "[" .. table.concat(encoded, ",") .. "]"
end

local function configure(configuration)
  if defining_submap or submap_defined then
    fail("configure must be called once before define_submap")
  end
  if staged_scrcpy_arguments ~= nil then
    fail("configuration is already staged")
  end
  if type(configuration) ~= "table" then
    fail("configuration must be a table")
  end
  local key_count = 0
  for key in pairs(configuration) do
    if key ~= "scrcpyArgs" then
      fail("unknown configuration key")
    end
    key_count = key_count + 1
  end
  if key_count ~= 1 then
    fail("scrcpyArgs is required")
  end
  staged_scrcpy_arguments = validated_scrcpy_arguments(configuration.scrcpyArgs)
end

local function run_helper_line(arguments)
  local process = io.popen(
    o.shell_quote(helper_executable) .. " " .. arguments,
    "r"
  )
  if process == nil then
    fail("unable to start configuration helper")
  end
  local output = process:read("*l")
  local closed, _, exit_code = process:close()
  -- Hyprland owns SIGCHLD and may reap the helper before Lua closes the pipe.
  if not closed and exit_code ~= 10 then
    fail("configuration helper failed")
  end
  return output
end

local function require_helper_version()
  local version = run_helper_line("--version")
  if type(version) ~= "string" or version ~= build_info.release_version then
    fail("configuration helper version mismatch")
  end
end

local function commit_configuration()
  if defining_submap or not submap_defined or staged_scrcpy_arguments == nil
      or configuration_committed then
    fail("commitConfiguration must be called once after define_submap")
  end
  require_helper_version()
  local arguments_json = scrcpy_arguments_json(staged_scrcpy_arguments)
  local revision = run_helper_line(
    "store-scrcpy-args " .. o.shell_quote(base64url(arguments_json))
  )
  if type(revision) ~= "string"
      or not revision:match("^[0-9a-f]+$") or #revision ~= 16 then
    fail("configuration helper returned an invalid revision")
  end
  configuration_committed = true
  hl.exec_cmd(
    "omarchy-shell ollieedgeley.droidpeek configureScrcpy "
      .. o.shell_quote(revision)
      .. " "
      .. o.shell_quote(base64url(arguments_json))
  )
  return revision
end

local api = {
  close_panel = close_panel,
  configure = configure,
  commitConfiguration = commit_configuration,
}

function api.bind(keys, description, target)
  if not defining_submap then
    fail("bindings must be declared inside define_submap")
  end
  if type(keys) ~= "string" or keys == "" then
    fail("binding keys must be a non-empty string")
  end
  if type(description) ~= "string" or description == "" then
    fail("binding description must be a non-empty string")
  end

  local dispatcher
  if target == close_panel then
    dispatcher = close_panel
  else
    dispatcher = function()
      dispatch_target(target, description)
    end
  end
  hl.bind(keys, dispatcher, { description = description })
end

function api.define_submap(name, declarations)
  if name ~= SUBMAP_NAME then
    fail('the only supported submap is "' .. SUBMAP_NAME .. '"')
  end
  if submap_defined then
    fail("the phone submap is already defined")
  end
  if type(declarations) ~= "function" then
    fail("submap declarations must be a function")
  end

  submap_defined = true
  hl.define_submap(SUBMAP_NAME, function()
    defining_submap = true
    local ok, declaration_error = pcall(declarations)
    defining_submap = false
    if not ok then
      error(declaration_error, 0)
    end
  end)
end

return api
