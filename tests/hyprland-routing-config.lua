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
assert(#calls == 15, "the release template must enable only the documented active bindings")
assert(configuration_committed, "the template must commit its configuration")
assert(
  table.concat(configured_arguments, "\n")
    == "--keep-active\n--turn-screen-off\n--stay-awake",
  "the template must install the approved scrcpy defaults"
)

assert(calls[1].keys == "SUPER + ALT + A")
assert(calls[1].description == "Close Android panel")
assert(calls[1].target == close_panel, "the mandatory close must use close_panel")

assert(calls[2].keys == "ALT + TAB")
assert(calls[2].description == "Recent apps")
assert(calls[2].target == "android.recent-apps")

assert(calls[3].keys == "SUPER + W")
assert(calls[3].description == "Home")
assert(calls[3].target == "android.navigate.home")

assert(calls[4].keys == "SUPER + C")
assert(calls[4].description == "Copy")
assert(calls[4].target.type == "android.keyevent")
assert(calls[4].target.key == "copy")

assert(calls[5].keys == "SUPER + V")
assert(calls[5].description == "Paste")
assert(calls[5].target.type == "android.keyevent")
assert(calls[5].target.key == "paste")

assert(calls[6].keys == "SUPER + X")
assert(calls[6].description == "Cut")
assert(calls[6].target.type == "android.keyevent")
assert(calls[6].target.key == "cut")

assert(calls[7].keys == "XF86AudioRaiseVolume")
assert(calls[7].description == "Volume up")
assert(calls[7].target.type == "android.keyevent")
assert(calls[7].target.key == "volume-up")

assert(calls[8].keys == "XF86AudioLowerVolume")
assert(calls[8].description == "Volume down")
assert(calls[8].target.type == "android.keyevent")
assert(calls[8].target.key == "volume-down")

assert(calls[9].keys == "XF86AudioMute")
assert(calls[9].description == "Mute")
assert(calls[9].target.type == "android.keyevent")
assert(calls[9].target.key == "volume-mute")

assert(calls[10].keys == "XF86AudioNext")
assert(calls[10].description == "Next track")
assert(calls[10].target.type == "android.keyevent")
assert(calls[10].target.key == "media-next")

assert(calls[11].keys == "ALT + XF86AudioPlay")
assert(calls[11].description == "Next track")
assert(calls[11].target.type == "android.keyevent")
assert(calls[11].target.key == "media-next")

assert(calls[12].keys == "XF86AudioPause")
assert(calls[12].description == "Play/pause")
assert(calls[12].target.type == "android.keyevent")
assert(calls[12].target.key == "media-play-pause")

assert(calls[13].keys == "XF86AudioPlay")
assert(calls[13].description == "Play/pause")
assert(calls[13].target.type == "android.keyevent")
assert(calls[13].target.key == "media-play-pause")

assert(calls[14].keys == "XF86AudioPrev")
assert(calls[14].description == "Previous track")
assert(calls[14].target.type == "android.keyevent")
assert(calls[14].target.key == "media-previous")

assert(calls[15].keys == "ALT + SHIFT + XF86AudioPlay")
assert(calls[15].description == "Previous track")
assert(calls[15].target.type == "android.keyevent")
assert(calls[15].target.key == "media-previous")


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

assert(
  not template_source:find("android.browser.default", 1, true),
  "the template must not mention android.browser.default"
)

for _, call in ipairs(calls) do
  assert(type(call.description) == "string" and call.description ~= "")
  if type(call.target) == "table" then
    assert(call.target.type ~= "android.app.launch")
  end
end

for _, package in ipairs({
  "com.android.chrome",
  "org.mozilla.firefox",
  "com.brave.browser",
  "com.termux",
  "com.basecamp.heycalendar",
  "com.basecamp.hey",
  "com.spotify.music",
  "org.thoughtcrime.securesms",
  "md.obsidian",
  "com.openai.chatgpt",
  "ai.x.grok",
  "com.twitter.android",
  "com.google.android.youtube",
  "com.whatsapp",
  "com.google.android.apps.messaging",
  "com.google.android.apps.photos",
  "com.google.android.apps.maps",
}) do
  local needle = 'package = "' .. package .. '"'
  local found = false
  local start = 1
  while true do
    local index = template_source:find(needle, start, true)
    if not index then
      break
    end
    found = true
    local line_start = template_source:sub(1, index):match(".*\n()") or 1
    local line = template_source:sub(line_start):match("[^\n]*")
    assert(
      line:match("^%s*%-%-"),
      "optional package " .. package .. " must remain commented"
    )
    start = index + 1
  end
  assert(found, "optional package " .. package .. " must appear in the template")
end
