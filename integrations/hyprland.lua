if o == nil then
  require("default.hypr.helpers")
end

if o.bind == o.omarchy_android_bind then
  return
end

local original_bind = o.bind
local dispatcher = o.shell_quote(os.getenv("HOME") .. "/.local/bin/omarchy-android-action")
local mappings = {
  browser = {
    action = "omarchy-browser",
    fallback = "omarchy-launch-browser",
    label = "Android browser",
  },
}

local function bind_with_android(keys, description, binding, options)
  local semantic = type(binding) == "table" and mappings[binding.omarchy] or nil
  if not semantic then
    return original_bind(keys, description, binding, options)
  end

  local command = table.concat({
    dispatcher,
    semantic.action,
    semantic.fallback,
  }, " ")
  return original_bind(keys, description .. " / " .. semantic.label, command, options)
end

o.omarchy_android_bind = bind_with_android
o.bind = bind_with_android
