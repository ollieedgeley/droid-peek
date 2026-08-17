if o == nil then
  require("default.hypr.helpers")
end

local state = o.omarchy_android_hyprland
if state ~= nil and state.api ~= nil then
  state.bindings_seen = 0
  state.custom_bindings_installed = false
  o.bind = state.bind
  return state.api
end

local source_path = debug.getinfo(1, "S").source
local integration_path = source_path:sub(1, 1) == "@" and source_path:sub(2) or source_path
local integration_directory = integration_path:match("^(.*)/[^/]+$") or "."
local catalog = dofile(integration_directory .. "/action-catalog.lua")

state = state or {}
state.close_dispatchers = state.close_dispatchers or setmetatable({}, { __mode = "k" })
state.bindings_seen = 0
state.custom_bindings_installed = false
o.omarchy_android_hyprland = state

local original_bind = o.bind
local dispatcher = o.shell_quote(os.getenv("HOME") .. "/.local/bin/omarchy-android-action")

local source_ids = { ["omarchy.window.close"] = true }
for _, source_id in pairs(catalog.sources) do
  source_ids[source_id] = true
end

local function fail(message)
  error("Omarchy Android: " .. message, 3)
end

local function validate_keys(value, allowed, context)
  if type(value) ~= "table" then
    fail(context .. " must be a table")
  end
  for key in pairs(value) do
    if not allowed[key] then
      fail("unknown " .. context .. " field " .. tostring(key))
    end
  end
end

local function valid_package(package_name)
  if type(package_name) ~= "string"
      or #package_name == 0
      or #package_name > 255
      or package_name:sub(1, 1) == "."
      or package_name:sub(-1) == "."
      or package_name:find("..", 1, true) then
    return false
  end

  local segments = 0
  for segment in package_name:gmatch("[^.]+") do
    if not segment:match("^[A-Za-z][A-Za-z0-9_]*$") then
      return false
    end
    segments = segments + 1
  end
  return segments >= 2
end

local function normalize_target(value)
  if type(value) == "string" then
    local target = catalog.targets[value]
    if target == nil then
      fail("unknown Android target " .. string.format("%q", value))
    end
    return {
      id = value,
      label = target.label,
      action_id = target.actionId,
      argument = "",
      direct_command = target.directCommand,
      append_label = target.appendLabel,
    }
  end

  if type(value) ~= "table" then
    fail("Android target must be a string or table")
  end

  validate_keys(value, { type = true, package = true }, "Android target")
  if value.type ~= "android.app.launch" then
    fail("unknown Android target " .. string.format("%q", tostring(value.type)))
  end
  if not valid_package(value.package) then
    fail("invalid Android package " .. string.format("%q", tostring(value.package)))
  end
  return {
    id = value.type,
    label = "Android launch " .. value.package,
    action_id = "android-launch-app",
    argument = value.package,
  }
end


local function is_array(value)
  if type(value) ~= "table" then
    return false
  end
  local count = 0
  for key in pairs(value) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
      return false
    end
    count = count + 1
  end
  return count == #value
end

local function validate_custom_binding(binding)
  validate_keys(
    binding,
    { keys = true, action = true, description = true, options = true },
    "custom binding"
  )
  if type(binding.keys) ~= "string" or binding.keys == "" then
    fail("custom binding keys must be a non-empty string")
  end
  if binding.description ~= nil and type(binding.description) ~= "string" then
    fail("custom binding description must be a string")
  end
  if binding.options ~= nil and type(binding.options) ~= "table" then
    fail("custom binding options must be a table")
  end
  return {
    keys = binding.keys,
    target = normalize_target(binding.action),
    description = binding.description,
    options = binding.options,
  }
end

local function configure(configuration)
  if state.bindings_seen > 0 then
    fail("configuration must be loaded before Omarchy bindings")
  end
  validate_keys(
    configuration,
    { routes = true, customBindings = true },
    "configuration"
  )

  local configured_routes = configuration.routes
  if type(configured_routes) ~= "table" then
    fail("routes must be a table")
  end
  local routes = {}
  for source_id, target in pairs(configured_routes) do
    if type(source_id) ~= "string" or not source_ids[source_id] then
      fail("unknown Omarchy source " .. string.format("%q", tostring(source_id)))
    end
    routes[source_id] = normalize_target(target)
  end

  local configured_bindings = configuration.customBindings or {}
  if not is_array(configured_bindings) then
    fail("customBindings must be an array")
  end
  local custom_bindings = {}
  for index, binding in ipairs(configured_bindings) do
    custom_bindings[index] = validate_custom_binding(binding)
  end

  state.routes = routes
  state.custom_bindings = custom_bindings
end

local function semantic_command(target)
  return table.concat({
    dispatcher,
    target.action_id,
    o.shell_quote(target.argument),
    "/usr/bin/true",
  }, " ")
end
local function routed_description(description, target)
  if description == nil or target.append_label == false then
    return description
  end
  return description .. " / " .. target.label
end

local function routed_options(options)
  local result = {}
  for key, value in pairs(options or {}) do
    result[key] = value
  end
  result.dont_inhibit = true
  return result
end


local function bind_with_android(keys, description, binding, options)
  state.bindings_seen = state.bindings_seen + 1

  if binding ~= nil and state.close_dispatchers[binding] then
    local target = state.routes["omarchy.window.close"]
    if target == nil then
      return original_bind(keys, description, binding, options)
    end
    if target.direct_command ~= nil then
      return original_bind(
        keys,
        routed_description(description, target),
        target.direct_command,
        routed_options(options)
      )
    end
    return original_bind(
      keys,
      routed_description(description, target),
      semantic_command(target),
      routed_options(options)
    )
  end

  if type(binding) ~= "table" then
    return original_bind(keys, description, binding, options)
  end
  local key, value = next(binding)
  if key ~= "omarchy" or type(value) ~= "string" or next(binding, key) ~= nil then
    return original_bind(keys, description, binding, options)
  end

  local source_id = catalog.sources[value]
  local target = source_id and state.routes[source_id] or nil
  if target == nil then
    return original_bind(keys, description, binding, options)
  end
  if target.direct_command ~= nil then
    return original_bind(
      keys,
      routed_description(description, target),
      target.direct_command,
      routed_options(options)
    )
  end
  return original_bind(
    keys,
    routed_description(description, target),
    semantic_command(target),
    routed_options(options)
  )
end

local function install_custom_bindings()
  if state.custom_bindings_installed then
    fail("custom bindings already installed")
  end
  state.custom_bindings_installed = true
  for _, binding in ipairs(state.custom_bindings) do
    local target = binding.target
    local command = target.direct_command or semantic_command(target)
    original_bind(
      binding.keys,
      binding.description or target.label,
      command,
      routed_options(binding.options)
    )
  end
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

state.routes = {}
state.custom_bindings = {}
state.bind = bind_with_android
state.api = {
  configure = configure,
  install_custom_bindings = install_custom_bindings,
}
o.bind = bind_with_android
o.omarchy_android = state.api

return state.api
