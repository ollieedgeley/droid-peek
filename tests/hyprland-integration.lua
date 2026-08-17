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
assert(type(calls[1].dispatcher) == "string")
assert(calls[1].dispatcher:match("omarchy%-android%-action' android%-home '' /usr/bin/true$"))
assert(type(calls[2].dispatcher) == "string")
assert(calls[2].dispatcher == calls[1].dispatcher)
assert(type(calls[3].dispatcher) == "string")
assert(calls[3].dispatcher == calls[1].dispatcher)
assert(calls[1].options ~= close_options, "close route options must be copied")
assert(calls[1].options.locked == true, "close route options must be preserved")
assert(calls[1].options.dont_inhibit == true, "configured close must bypass inhibition")
assert(close_options.dont_inhibit == nil, "caller options must remain unchanged")
assert(calls[3].description == nil, "nil close description must be preserved")
assert(calls[4].dispatcher == untagged, "untagged functions must remain untouched")

assert(calls[5].keys == "SUPER + P")
assert(calls[5].description == "Toggle Android panel")
assert(calls[5].dispatcher == "omarchy-shell ollie.android toggle")
assert(calls[5].options ~= panel_options, "panel bypass must not mutate caller options")
assert(calls[5].options.locked == true, "panel locked option must be preserved")
assert(calls[5].options.repeatable == false, "panel repeatable option must be preserved")
assert(calls[5].options.dont_inhibit == true, "panel toggle must bypass shortcut inhibition")
assert(panel_options.dont_inhibit == nil, "caller options must remain unchanged")
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
assert(calls[8].options.dont_inhibit == true, "nil panel options must gain inhibition bypass")

assert(calls[9].keys == "SUPER + SHIFT + B")
assert(calls[9].description == "Browser / Android default browser")
assert(type(calls[9].dispatcher) == "string")
assert(calls[9].dispatcher:match("omarchy%-android%-action' omarchy%-browser '' /usr/bin/true$"))
assert(calls[9].options ~= browser_options, "Android route options must be copied")
assert(calls[9].options.locked == true, "Android route options must be preserved")
assert(calls[9].options.dont_inhibit == true, "configured Android routes must bypass inhibition")
assert(browser_options.dont_inhibit == nil, "caller options must remain unchanged")
assert(calls[10].dispatcher == private_browser, "private browser must remain untouched")
assert(calls[11].dispatcher == terminal, "unsupported bindings must remain untouched")
assert(#executed_commands == 0, "panel bindings must not launch asynchronous commands")
assert(#timers == 0, "panel bindings must not start asynchronous timers")


os.getenv = original_getenv
os.time = original_time
