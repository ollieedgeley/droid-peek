local supplied_path = assert(arg[1], "integration path")
local integration_directory = supplied_path:match("^(.*)/[^/]+$") or "."
local integration = integration_directory .. "/phone-bindings.lua"

local bindings = {}
local submaps = {}
local dispatches = {}
local execution_events = {}
local active_submap = nil

local function record_command(command)
  table.insert(execution_events, { kind = "command", command = command })
end

o = {
  bind = function()
    error("phone bindings must not intercept desktop bindings")
  end,
  shell_quote = function(value)
    return "[" .. value .. "]"
  end,
}

hl = {
  bind = function(keys, dispatcher, options)
    table.insert(bindings, {
      submap = active_submap,
      keys = keys,
      dispatcher = dispatcher,
      options = options,
    })
  end,
  define_submap = function(name, callback)
    table.insert(submaps, name)
    local previous_submap = active_submap
    active_submap = name
    callback()
    active_submap = previous_submap
  end,
  dispatch = function(dispatcher)
    table.insert(dispatches, dispatcher)
    if dispatcher.kind == "command" then
      record_command(dispatcher.command)
    elseif dispatcher.kind == "submap" then
      table.insert(execution_events, { kind = "submap", name = dispatcher.name })
    end
  end,
  exec_cmd = record_command,
  dsp = {
    exec_cmd = function(command)
      return { kind = "command", command = command }
    end,
    submap = function(name)
      return { kind = "submap", name = name }
    end,
  },
}

local desktop_bind = o.bind
local now_seconds = 1700000000
local original_time = os.time
os.time = function()
  return now_seconds
end

local function decode_base64url(encoded)
  local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
  local output = {}
  local buffer = 0
  local buffered_bits = 0

  for index = 1, #encoded do
    local value = assert(
      alphabet:find(encoded:sub(index, index), 1, true),
      "envelope is not base64url"
    ) - 1
    buffer = buffer * 64 + value
    buffered_bits = buffered_bits + 6
    while buffered_bits >= 8 do
      buffered_bits = buffered_bits - 8
      local divisor = 2 ^ buffered_bits
      table.insert(output, string.char(math.floor(buffer / divisor) % 256))
      buffer = buffer % divisor
    end
  end

  return table.concat(output)
end

local function command_envelope(command)
  local encoded = command:match(
    "^omarchy%-shell ollie%.android phone%-target %[([A-Za-z0-9_-]+)%]$"
  )
  assert(encoded ~= nil, "target must use the phone-target shell endpoint")
  assert(not encoded:find("=", 1, true), "base64url envelope must omit padding")
  return decode_base64url(encoded)
end

local function json_string(json, field)
  return json:match('"' .. field .. '"%s*:%s*"([^"]+)"')
end

local function json_integer(json, field)
  local value = json:match('"' .. field .. '"%s*:%s*(%d+)')
  return value and tonumber(value) or nil
end

local wrong_name_api = dofile(integration)
local wrong_name_ok = pcall(wrong_name_api.define_submap, "other-submap", function() end)
assert(not wrong_name_ok, "only the named omarchy-android submap is supported")
assert(#submaps == 0, "an invalid submap name must not reach Hyprland")

local android = dofile(integration)
assert(type(android) == "table", "integration must return the phone-binding API")
assert(type(android.define_submap) == "function")
assert(type(android.bind) == "function")
assert(type(android.close_panel) == "function")
assert(android.configure == nil, "retired routes configuration must not remain")
assert(android.install_custom_bindings == nil, "retired customBindings API must not remain")
assert(android.routes == nil, "the API must not expose a routing table")
assert(o.bind == desktop_bind, "loading phone bindings must not wrap o.bind")

android.define_submap("omarchy-android", function()
  android.bind("SUPER + ESCAPE", "Close Android panel", android.close_panel)
  android.bind("SUPER + SHIFT + B", "Browser", "android.browser.default")
  android.bind("SUPER + W", "Home", "android.navigate.home")
  android.bind("SUPER + ALT + P", "Package", {
    type = "android.app.launch",
    package = "com.example.files",
  })
  android.bind("SUPER + U", "Unsupported target", "android.unsupported")
end)

assert(#submaps == 1, "the API must define exactly one submap")
assert(submaps[1] == "omarchy-android")
assert(#bindings == 5, "only declared phone bindings may be registered")
for _, binding in ipairs(bindings) do
  assert(binding.submap == "omarchy-android", "phone bindings must stay inside their submap")
  assert(type(binding.dispatcher) == "function", "deadlines must be created at dispatch time")
  assert(type(binding.options) == "table")
  assert(type(binding.options.description) == "string")
end
assert(bindings[1].options.description == "Close Android panel")
assert(bindings[2].options.description == "Browser")

for _, binding in ipairs(bindings) do
  assert(binding.keys ~= "SUPER + Q", "unsupported desktop chords must remain inert")
end
assert(o.bind == desktop_bind, "defining the submap must not intercept desktop bindings")

local duplicate_ok = pcall(android.define_submap, "omarchy-android", function() end)
assert(not duplicate_ok, "the API must not define a second submap")
assert(#submaps == 1, "a duplicate definition must not reach Hyprland")

bindings[1].dispatcher()
assert(#execution_events == 2, "close must request panel close and reset synchronously")
assert(execution_events[1].kind == "submap")
assert(execution_events[1].name == "reset")
assert(execution_events[2].kind == "command")
assert(execution_events[2].command == "omarchy-shell ollie.android close")

now_seconds = 1700000030
bindings[2].dispatcher()
local browser_json = command_envelope(execution_events[3].command)
assert(json_string(browser_json, "target") == "android.browser.default")
assert(json_integer(browser_json, "expiresAtUnixMs") == 1700000032000)
local first_request_id = json_string(browser_json, "requestId")
assert(first_request_id ~= nil and first_request_id:match("^[A-Za-z0-9-]+$"))

bindings[2].dispatcher()
local repeated_json = command_envelope(execution_events[4].command)
assert(
  json_string(repeated_json, "requestId") ~= first_request_id,
  "each dispatch must have a fresh requestId"
)

bindings[4].dispatcher()
local package_json = command_envelope(execution_events[5].command)
assert(package_json:match('"target"%s*:%s*{'), "typed target must stay an object")
assert(json_string(package_json, "type") == "android.app.launch")
assert(json_string(package_json, "package") == "com.example.files")
assert(json_integer(package_json, "expiresAtUnixMs") == 1700000032000)

local invalid_target_ok, invalid_target_error = pcall(bindings[5].dispatcher)
assert(invalid_target_ok, tostring(invalid_target_error))
local invalid_json = command_envelope(execution_events[6].command)
assert(json_string(invalid_json, "target") == "android.unsupported")
assert(
  #execution_events == 6,
  "an invalid target must be consumed by phone-target without desktop fallback"
)

os.time = original_time
