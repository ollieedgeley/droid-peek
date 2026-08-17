local integration = assert(arg[1], "integration path")
local calls = {}
local executed_commands = {}
local timers = {}
local dispatches = {}
local close_dispatchers = {}

o = {
  shell_quote = function(value)
    return "'" .. value .. "'"
  end,
  bind = function(keys, description, dispatcher, options)
    table.insert(calls, {
      keys = keys,
      description = description,
      dispatcher = dispatcher,
      options = options,
    })
  end,
}

hl = {
  dsp = {
    window = {
      close = function()
        local dispatcher = {}
        table.insert(close_dispatchers, dispatcher)
        return dispatcher
      end,
    },
  },
  exec_cmd = function(command)
    table.insert(executed_commands, command)
  end,
  timer = function(callback, options)
    local timer = { callback = callback, options = options, enabled = true }
    function timer:set_enabled(enabled)
      self.enabled = enabled
    end
    table.insert(timers, timer)
    return timer
  end,
  dispatch = function(dispatcher)
    table.insert(dispatches, dispatcher)
  end,
}

local original_getenv = os.getenv
local original_time = os.time
os.getenv = function(name)
  if name == "HOME" then
    return "/home/test"
  end
  if name == "XDG_RUNTIME_DIR" then
    return "/tmp"
  end
  return original_getenv(name)
end
os.time = function()
  return 1700000000
end

local android = dofile(integration)
assert(type(android) == "table", "integration must return its public configuration API")
assert(android == o.omarchy_android, "returned API must be the installed global API")
assert(type(android.configure) == "function")
assert(type(android.install_custom_bindings) == "function")

local integration_directory = integration:match("^(.*)/[^/]+$") or "."
local template = dofile(integration_directory .. "/config.example.lua")
android.configure(template)

local malformed_ok, malformed_error = pcall(android.configure, {
  smartDefaults = true,
  routes = { ["omarchy.browser"] = "android.navigate.hmoe" },
  customBindings = {},
})
assert(not malformed_ok, "unknown target must fail configuration")
assert(tostring(malformed_error):match("unknown Android target"))

local invalid_package_ok, invalid_package_error = pcall(function()
  local fresh = dofile(integration)
  fresh.configure({
    smartDefaults = false,
    routes = {},
    customBindings = {
      {
        keys = "SUPER + P",
        action = { type = "android.app.launch", package = "bad package" },
      },
    },
  })
end)
assert(not invalid_package_ok, "invalid package names must fail configuration")
assert(tostring(invalid_package_error):match("invalid Android package"))
android.configure({
  smartDefaults = true,
  routes = {
    ["omarchy.window.close"] = "android.navigate.back",
    ["omarchy.spotify"] = {
      type = "android.app.launch",
      package = "com.spotify.music",
    },
    ["omarchy.editor"] = false,
  },
  customBindings = {
    {
      keys = "CTRL + ALT + SHIFT + P",
      action = "android.navigate.recent-apps",
    },
  },
})

local close = hl.dsp.window.close()
o.bind("SUPER + SHIFT + B", "Browser", { omarchy = "browser" }, { locked = true })
o.bind("SUPER + SHIFT + M", "Music", { omarchy = "spotify" })
o.bind("SUPER + SHIFT + N", "Editor", { omarchy = "editor" })
o.bind("SUPER + Q", "Close window", close)
android.install_custom_bindings()

assert(#calls == 5, "each existing or custom binding must register exactly once")
assert(calls[1].keys == "SUPER + SHIFT + B")
assert(calls[1].description == "Browser / Android default browser")
assert(calls[1].options.locked == true)
assert(type(calls[1].dispatcher) == "string")
assert(calls[1].dispatcher:match("omarchy%-android%-action' omarchy%-browser '' omarchy%-launch%-browser$"))

assert(calls[2].description == "Music / Android launch com.spotify.music")
assert(calls[2].dispatcher:match("omarchy%-android%-action' android%-launch%-app 'com%.spotify%.music' omarchy%-launch%-spotify$"))

assert(type(calls[3].dispatcher) == "table")
assert(calls[3].dispatcher.omarchy == "editor", "false route must preserve original Omarchy action")

assert(type(calls[4].dispatcher) == "function", "opaque close fallback must stay asynchronous")
calls[4].dispatcher()
assert(#executed_commands == 1)
assert(executed_commands[1]:match("android%-back '' /usr/bin/touch"))
assert(executed_commands[1]:match("|| /usr/bin/touch"))

assert(calls[5].keys == "CTRL + ALT + SHIFT + P")
assert(calls[5].description == "Android recent apps")
assert(calls[5].dispatcher:match("android%-recent%-apps '' /usr/bin/true$"))

local duplicate_ok, duplicate_error = pcall(android.install_custom_bindings)
assert(not duplicate_ok, "custom bindings must not install twice")
assert(tostring(duplicate_error):match("already installed"))

local reload_ok, reload_error = pcall(function()
  local reloaded = dofile(integration)
  assert(reloaded == android)
  reloaded.configure(template)
  o.bind("SUPER + SHIFT + B", "Browser", { omarchy = "browser" })
  reloaded.install_custom_bindings()
end)
assert(reload_ok, tostring(reload_error))


os.getenv = original_getenv
os.time = original_time
