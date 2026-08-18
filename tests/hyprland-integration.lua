local supplied_path = assert(arg[1], "integration path")
local integration_directory = supplied_path:match("^(.*)/[^/]+$") or "."
local integration = integration_directory .. "/phone-bindings.lua"

local bindings = {}
local submaps = {}
local dispatches = {}
local execution_events = {}
local active_submap = nil
local stored_config_commands = {}

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
local now_milliseconds = 1700000000125
local original_popen = io.popen
io.popen = function(command, mode)
  if command == "/usr/bin/date +%s%3N" then
    assert(mode == "r", "deadline clock must be read-only")
    return {
      read = function(_, format)
        assert(format == "*l")
        return tostring(now_milliseconds)
      end,
      close = function()
        return true
      end,
    }
  end
  assert(
    command:match("^%[omarchy%-android%-helper%] store%-scrcpy%-args %[([A-Za-z0-9_-]+)%]$"),
    "configure must call the fixed plugin helper store subcommand"
  )
  assert(mode == "r", "configuration store command must be read-only")
  table.insert(stored_config_commands, command)
  return {
    read = function(_, format)
      assert(format == "*l")
      return "0123456789abcdef"
    end,
    close = function()
      return nil, "No child processes", 10
    end,
  }
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
    "^omarchy%-shell ollie%.android phoneTarget %[([A-Za-z0-9_-]+)%]$"
  )
  assert(encoded ~= nil, "target must use the phoneTarget shell endpoint")
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
assert(type(android.configure) == "function")
assert(type(android.commitConfiguration) == "function")
assert(android.install_custom_bindings == nil, "retired customBindings API must not remain")
assert(android.routes == nil, "the API must not expose a routing table")
assert(o.bind == desktop_bind, "loading phone bindings must not wrap o.bind")

for _, invalid in ipairs({
  "not-a-table",
  {},
  { unknown = {} },
  { scrcpyArgs = "not-a-list" },
  { scrcpyArgs = { [1] = "--keep-active", [3] = "--stay-awake" } },
  { scrcpyArgs = { "" } },
  { scrcpyArgs = { "-w" } },
  { scrcpyArgs = { "--serial=device" } },
  { scrcpyArgs = { "--no-cleanup" } },
  { scrcpyArgs = { "--audio-codec=opus" } },
  { scrcpyArgs = { string.rep("x", 513) } },
  { scrcpyArgs = {
    "--x01", "--x02", "--x03", "--x04", "--x05", "--x06", "--x07", "--x08",
    "--x09", "--x10", "--x11", "--x12", "--x13", "--x14", "--x15", "--x16",
    "--x17", "--x18", "--x19", "--x20", "--x21", "--x22", "--x23", "--x24",
    "--x25", "--x26", "--x27", "--x28", "--x29", "--x30", "--x31", "--x32",
    "--x33",
  } },
}) do
  assert(not pcall(android.configure, invalid), "invalid configuration must fail closed")
end
assert(#stored_config_commands == 0)

android.configure({
  scrcpyArgs = {
    "--keep-active",
    "--turn-screen-off",
    "--stay-awake",
    "--window-title=Téléphone",
  },
})
assert(#stored_config_commands == 0, "configure must only stage")

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
now_milliseconds = 1700000030125
bindings[2].dispatcher()
local browser_json = command_envelope(execution_events[3].command)
assert(json_string(browser_json, "target") == "android.browser.default")
assert(json_integer(browser_json, "expiresAtUnixMs") == 1700000032125)
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
assert(json_integer(package_json, "expiresAtUnixMs") == 1700000032125)

local invalid_target_ok, invalid_target_error = pcall(bindings[5].dispatcher)
assert(invalid_target_ok, tostring(invalid_target_error))
local invalid_json = command_envelope(execution_events[6].command)
assert(json_string(invalid_json, "target") == "android.unsupported")
assert(
  #execution_events == 6,
  "an invalid target must be consumed by phone-target without desktop fallback"
)

local revision = android.commitConfiguration()
assert(revision == "0123456789abcdef")
assert(#stored_config_commands == 1)
local stored_envelope = stored_config_commands[1]:match(
  " store%-scrcpy%-args %[([A-Za-z0-9_-]+)%]$"
)
local stored_json = decode_base64url(assert(stored_envelope))
assert(stored_json:match('^%["%-%-keep%-active","%-%-turn%-screen%-off",'))
assert(stored_json:find("Téléphone", 1, true))
local configure_command = execution_events[7].command
local configure_revision, configure_envelope = configure_command:match(
  "^omarchy%-shell ollie%.android configureScrcpy %[([0-9a-f]+)%] %[([A-Za-z0-9_-]+)%]$"
)
assert(configure_revision == revision)
assert(decode_base64url(assert(configure_envelope)) == stored_json)
assert(not pcall(android.commitConfiguration), "configuration may be committed only once")
assert(
  not pcall(android.configure, { scrcpyArgs = { "--stay-awake" } }),
  "configuration may be declared only once"
)
assert(#stored_config_commands == 1, "rejected calls must not reach the helper")
os.time = original_time
io.popen = original_popen
