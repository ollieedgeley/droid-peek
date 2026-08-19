local supplied_path = assert(arg[1], "integration path")
local integration_directory = supplied_path:match("^(.*)/[^/]+$") or "."
local template_path = integration_directory .. "/omarchy-android.lua.example"

local calls = {}
local submaps = {}
local api_requests = {}
local configured_arguments = nil
local configuration_committed = false
local close_panel = function() end
local android = {
  close_panel = close_panel,
  configure = function(configuration)
    assert(#submaps == 0, "configuration must precede the submap")
    configured_arguments = configuration.scrcpyArgs
  end,
  commitConfiguration = function()
    assert(#submaps == 1, "configuration commit must follow the submap")
    configuration_committed = true
  end,
  define_submap = function(name, callback)
    table.insert(submaps, name)
    callback()
  end,
  bind = function(keys, description, target)
    table.insert(calls, {
      keys = keys,
      description = description,
      target = target,
    })
  end,
}

local original_dofile = dofile
local original_getenv = os.getenv
os.getenv = function(name)
  if name == "HOME" then
    return "/temporary-home"
  end
  return original_getenv(name)
end

dofile = function(path)
  table.insert(api_requests, path)
  assert(
    path
      == "/temporary-home/.config/omarchy/plugins/ollie.android/integrations/phone-bindings.lua",
    "the user template must load the plugin-owned phone-binding API"
  )
  return android
end

local template_file = assert(io.open(template_path, "r"))
local template_source = template_file:read("*a")
template_file:close()

local template_ok, template_error = pcall(original_dofile, template_path)
dofile = original_dofile
os.getenv = original_getenv
assert(template_ok, tostring(template_error))

assert(#api_requests == 1, "the template must load exactly one plugin API")
assert(#submaps == 1, "the template must define exactly one named submap")
assert(submaps[1] == "omarchy-android")
assert(#calls == 4, "the release template must enable only the four documented bindings")
assert(configuration_committed, "the template must commit its configuration")
assert(
  table.concat(configured_arguments, "\n")
    == "--keep-active\n--turn-screen-off\n--stay-awake",
  "the template must install the approved scrcpy defaults"
)

assert(calls[1].keys == "SUPER + ALT + A")
assert(calls[1].description == "Close Android panel")
assert(calls[1].target == close_panel, "the mandatory close must use close_panel")

assert(calls[2].keys == "SUPER + SHIFT + RETURN")
assert(calls[2].description == "Browser")
assert(calls[2].target == "android.browser.default")

assert(calls[3].keys == "SUPER + SHIFT + B")
assert(calls[3].description == "Browser")
assert(calls[3].target == "android.browser.default")

assert(calls[4].keys == "SUPER + W")
assert(calls[4].description == "Close current window")
assert(calls[4].target == "android.navigate.home")

local enabled_keys = {}
for _, call in ipairs(calls) do
  assert(enabled_keys[call.keys] == nil, "the release template must not duplicate a chord")
  enabled_keys[call.keys] = true
end
for _, desktop_only_key in ipairs({
  "SUPER + SPACE",
  "SUPER + SHIFT + F",
  "SUPER + SHIFT + M",
  "SUPER + Q",
}) do
  assert(
    enabled_keys[desktop_only_key] == nil,
    "unsupported desktop chords must be inert in phone mode"
  )
end

for _, retired_name in ipairs({
  "routes",
  "customBindings",
  "smartDefaults",
  "actionId",
  "action-catalog",
  "commandPassthrough",
  "install_custom_bindings",
}) do
  assert(
    not template_source:find(retired_name, 1, true),
    "template retains retired routing field " .. retired_name
  )
end
