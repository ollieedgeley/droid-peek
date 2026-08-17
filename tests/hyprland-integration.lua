local integration = assert(arg[1], "integration path")
local calls = {}
local close_dispatchers = {}
local executed_commands = {}
local timers = {}
local timer_state_changes = {}
local dispatches = {}

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
    local timer = {
      callback = callback,
      options = options,
      enabled = true,
    }
    timer.set_enabled = function(self_or_enabled, maybe_enabled)
      local enabled = maybe_enabled
      if enabled == nil then
        enabled = self_or_enabled
      end
      timer.enabled = enabled
      table.insert(timer_state_changes, {
        timer = timer,
        enabled = enabled,
      })
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
local installed_bind = o.bind
local installed_close_factory = hl.dsp.window.close
assert(dofile(integration) == android)
android.configure({
  routes = {
    ["omarchy.android.panel.toggle"] = "android.panel.toggle",
    ["omarchy.browser"] = "android.browser.default",
    ["omarchy.window.close"] = "android.navigate.home",
  },
  customBindings = {},
})

assert(o.bind == installed_bind, "duplicate loading must not wrap bindings twice")
assert(hl.dsp.window.close == installed_close_factory, "duplicate loading must not wrap close twice")

local stock_close = hl.dsp.window.close()
local custom_close = hl.dsp.window.close()
local nil_description_close = hl.dsp.window.close()
local untagged = function() end
local close_options = { locked = true, repeatable = false }
local browser = { omarchy = "browser" }
local private_browser = { omarchy = "browser --private" }
local terminal = { omarchy = "terminal" }
local browser_options = { locked = true }
local android_panel = { omarchy = "toggle-android-panel" }
local ambiguous_android_panel = { omarchy = "toggle-android-panel --extra" }
local extra_field_android_panel = { omarchy = "toggle-android-panel", extra = true }
local nil_description_android_panel = { omarchy = "toggle-android-panel" }
local panel_options = { locked = true, repeatable = false }

assert(stock_close ~= custom_close, "close factory must return a fresh dispatcher")
assert(stock_close ~= nil_description_close, "close factory must return a fresh dispatcher")
assert(custom_close ~= nil_description_close, "close factory must return a fresh dispatcher")
assert(type(stock_close) == "table", "stock close must be opaque before wrapping")
assert(type(custom_close) == "table", "custom close must be opaque before wrapping")
assert(type(nil_description_close) == "table", "nil-description close must be opaque before wrapping")
assert(close_dispatchers[1] == stock_close, "stock close must be tagged without replacing it")
assert(close_dispatchers[2] == custom_close, "custom close must be tagged without replacing it")
assert(
  close_dispatchers[3] == nil_description_close,
  "nil-description close must be tagged without replacing it"
)

o.bind("SUPER + W", "Close window", stock_close, close_options)
o.bind("SUPER + SHIFT + W", "Close custom window", custom_close)
local nil_description_ok, nil_description_error = pcall(
  o.bind,
  "SUPER + ALT + W",
  nil,
  nil_description_close
)
assert(
  nil_description_ok,
  "nil-description close must register without error: " .. tostring(nil_description_error)
)
o.bind("SUPER + X", "Arbitrary function", untagged)
o.bind("SUPER + P", "Toggle Android panel", android_panel, panel_options)
o.bind("SUPER + SHIFT + P", "Ambiguous Android panel", ambiguous_android_panel)
o.bind("SUPER + CTRL + P", "Extra-field Android panel", extra_field_android_panel)
local nil_description_panel_ok, nil_description_panel_error = pcall(
  o.bind,
  "SUPER + ALT + P",
  nil,
  nil_description_android_panel
)
assert(
  nil_description_panel_ok,
  "nil-description panel must register without error: " .. tostring(nil_description_panel_error)
)
o.bind("SUPER + SHIFT + B", "Browser", browser, browser_options)
o.bind("SUPER + SHIFT + ALT + B", "Browser (private)", private_browser)
o.bind("SUPER + RETURN", "Terminal", terminal)
assert(o.bind == installed_bind, "loader must remain active for later user bindings")

assert(#calls == 11, "each binding must be registered exactly once")
assert(type(calls[1].dispatcher) == "function")
assert(calls[1].dispatcher ~= stock_close, "stock close must be wrapped")
assert(type(calls[2].dispatcher) == "function")
assert(calls[2].dispatcher ~= custom_close, "custom close must be wrapped")
assert(type(calls[3].dispatcher) == "function")
assert(calls[3].dispatcher ~= nil_description_close, "nil-description close must be wrapped")
assert(calls[1].dispatcher ~= calls[2].dispatcher, "each close must retain its own fallback")
assert(calls[1].dispatcher ~= calls[3].dispatcher, "each close must be wrapped independently")
assert(calls[2].dispatcher ~= calls[3].dispatcher, "each close must be wrapped independently")
assert(calls[1].options == close_options, "close binding options must be preserved")
assert(calls[3].description == nil, "nil close description must be preserved")
assert(calls[4].dispatcher == untagged, "untagged functions must remain untouched")

assert(calls[5].keys == "SUPER + P")
assert(calls[5].description == "Toggle Android panel")
assert(calls[5].dispatcher == "omarchy-shell ollie.android toggle")
assert(calls[5].options == panel_options, "panel binding options must be preserved")
assert(
  calls[6].dispatcher == ambiguous_android_panel,
  "ambiguous panel declarations must remain untouched"
)
assert(
  calls[7].dispatcher == extra_field_android_panel,
  "extra-field panel declarations must preserve the exact original object"
)
assert(calls[8].dispatcher == "omarchy-shell ollie.android toggle")
assert(calls[8].description == nil, "nil panel description must be preserved")
assert(calls[8].options == nil, "nil panel options must be preserved")

assert(calls[9].keys == "SUPER + SHIFT + B")
assert(calls[9].description == "Browser / Android default browser")
assert(type(calls[9].dispatcher) == "string")
assert(calls[9].dispatcher:match("omarchy%-android%-action' omarchy%-browser '' omarchy%-launch%-browser$"))
assert(calls[9].options == browser_options)
assert(calls[10].dispatcher == private_browser, "private browser must remain untouched")
assert(calls[11].dispatcher == terminal, "unsupported bindings must remain untouched")
assert(#executed_commands == 0, "panel bindings must not launch asynchronous commands")
assert(#timers == 0, "panel bindings must not start asynchronous timers")

local marker = "/tmp/omarchy-android-fallback-1700000000-1"
local function marker_exists()
  local file = io.open(marker, "r")
  if file == nil then
    return false
  end
  file:close()
  return true
end

local function write_marker()
  local file = assert(io.open(marker, "w"))
  file:close()
end

write_marker()
calls[1].dispatcher()

assert(#executed_commands == 1, "close must launch one semantic action")
local expected_close_command = table.concat({
  "/usr/bin/timeout --signal=KILL 7",
  "'/home/test/.local/bin/omarchy-android-action'",
  "android-home",
  "''",
  "/usr/bin/touch",
  "'" .. marker .. "'",
  "|| /usr/bin/touch",
  "'" .. marker .. "'",
}, " ")
assert(
  executed_commands[1] == expected_close_command,
  "close must use the exact absolute non-catchable KILL timeout wrapper"
)
assert(executed_commands[1]:find(
  "'/home/test/.local/bin/omarchy-android-action' android-home ''",
  1,
  true
))
assert(executed_commands[1]:find("/usr/bin/touch '" .. marker .. "'", 1, true))
assert(executed_commands[1]:find("|| /usr/bin/touch '" .. marker .. "'", 1, true))
assert(not marker_exists(), "stale fallback marker must be removed before launch")
assert(#dispatches == 0, "fallback must not run while the semantic action is pending")

assert(#timers == 1, "close must start one fallback watcher")
assert(timers[1].options.timeout == 50)
assert(timers[1].options.type == "repeat")
assert(timers[1].enabled)

timers[1].callback()
assert(#dispatches == 0, "missing marker must not dispatch the fallback")
assert(timers[1].enabled, "watcher must remain active while the action is pending")

write_marker()
timers[1].callback()
assert(#dispatches == 1, "fallback marker must dispatch exactly once")
assert(dispatches[1] == stock_close, "fallback must dispatch the exact original close dispatcher")
assert(not marker_exists(), "handled fallback marker must be removed")
assert(not timers[1].enabled, "fallback watcher must disable itself after dispatch")
assert(#timer_state_changes == 1)
assert(timer_state_changes[1].timer == timers[1])
assert(timer_state_changes[1].enabled == false)

timers[1].callback()
assert(#dispatches == 1, "repeated timer callbacks must not dispatch twice")

calls[2].dispatcher()
assert(#timers == 2, "each close invocation must own its fallback watcher")
for _ = 1, 159 do
  timers[2].callback()
end
assert(timers[2].enabled, "empty watcher must remain active before its cleanup limit")
assert(#dispatches == 1, "empty watcher polls must not dispatch a fallback")
timers[2].callback()
assert(not timers[2].enabled, "empty watcher must disable itself at its cleanup limit")
assert(#dispatches == 1, "watcher cleanup must not dispatch a fallback")

os.getenv = original_getenv
os.time = original_time
