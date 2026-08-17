if o == nil then
  require("default.hypr.helpers")
end

local state = o.omarchy_android_hyprland
if state == nil then
  state = {
    close_dispatchers = setmetatable({}, { __mode = "k" }),
    fallback_counter = 0,
  }
  o.omarchy_android_hyprland = state
end

if state.close_factory == nil then
  local original_close_factory = hl.dsp.window.close
  state.close_factory = function(...)
    local close_dispatcher = original_close_factory(...)
    state.close_dispatchers[close_dispatcher] = true
    return close_dispatcher
  end
  hl.dsp.window.close = state.close_factory
end

if o.bind == state.bind then
  return
end

local original_bind = o.bind
local dispatcher = o.shell_quote(os.getenv("HOME") .. "/.local/bin/omarchy-android-action")
local mappings = {
  ["toggle-android-panel"] = {
    command = "omarchy-shell ollie.android toggle",
  },
  browser = {
    action = "omarchy-browser",
    fallback = "omarchy-launch-browser",
    label = "Android browser",
  },
}

local function close_with_android(fallback)
  return function()
    local runtime_directory = os.getenv("XDG_RUNTIME_DIR")
    if runtime_directory == nil or runtime_directory == "" then
      hl.dispatch(fallback)
      return
    end

    state.fallback_counter = state.fallback_counter + 1
    local marker = runtime_directory
      .. "/omarchy-android-fallback-"
      .. os.time()
      .. "-"
      .. state.fallback_counter
    os.remove(marker)

    local finished = false
    local polls = 0
    local watcher
    local function finish(dispatch_fallback)
      if finished then
        return
      end
      finished = true
      os.remove(marker)
      if watcher ~= nil then
        watcher:set_enabled(false)
      end
      if dispatch_fallback then
        hl.dispatch(fallback)
      end
    end

    watcher = hl.timer(function()
      if finished then
        return
      end

      local fallback_marker = io.open(marker, "r")
      if fallback_marker ~= nil then
        fallback_marker:close()
        finish(true)
        return
      end

      polls = polls + 1
      if polls >= 160 then
        finish(false)
      end
    end, { timeout = 50, type = "repeat" })

    local command = table.concat({
      "/usr/bin/timeout --signal=KILL 7",
      dispatcher,
      "omarchy-close-current-window",
      "/usr/bin/touch",
      o.shell_quote(marker),
      "|| /usr/bin/touch",
      o.shell_quote(marker),
    }, " ")
    local launched = pcall(hl.exec_cmd, command)
    if not launched then
      finish(true)
    end
  end
end

local function mapped_semantic(binding)
  if type(binding) ~= "table" then
    return nil
  end

  local key, value = next(binding)
  if key ~= "omarchy" or next(binding, key) ~= nil then
    return nil
  end
  return mappings[value]
end

local function bind_with_android(keys, description, binding, options)
  if binding ~= nil and state.close_dispatchers[binding] then
    local close_description = description
    if close_description ~= nil then
      close_description = close_description .. " / Android close current window"
    end
    return original_bind(
      keys,
      close_description,
      close_with_android(binding),
      options
    )
  end

  local semantic = mapped_semantic(binding)
  if not semantic then
    return original_bind(keys, description, binding, options)
  end
  if semantic.command ~= nil then
    return original_bind(keys, description, semantic.command, options)
  end


  local command = table.concat({
    dispatcher,
    semantic.action,
    semantic.fallback,
  }, " ")
  local mapped_description = description
  if mapped_description ~= nil then
    mapped_description = mapped_description .. " / " .. semantic.label
  end
  return original_bind(keys, mapped_description, command, options)
end

state.bind = bind_with_android
o.omarchy_android_bind = bind_with_android
o.bind = bind_with_android
