if o == nil then
  require("default.hypr.helpers")
end

local SUBMAP_NAME = "omarchy-android"
local submap_defined = false
local defining_submap = false
local request_sequence = 0

local function fail(message)
  error("omarchy-android: " .. message, 3)
end

local function json_string(value)
  return '"' .. value:gsub('[%z\1-\31\\"]', function(character)
    local escapes = {
      ['"'] = '\\"',
      ["\\"] = "\\\\",
      ["\b"] = "\\b",
      ["\f"] = "\\f",
      ["\n"] = "\\n",
      ["\r"] = "\\r",
      ["\t"] = "\\t",
    }
    return escapes[character] or string.format("\\u%04x", string.byte(character))
  end) .. '"'
end

local function json_value(value, active)
  local value_type = type(value)
  if value_type == "string" then
    return json_string(value)
  end
  if value_type == "boolean" or value_type == "number" then
    return tostring(value)
  end
  if value_type ~= "table" then
    fail("phone target must be JSON data")
  end
  if active[value] then
    fail("phone target must not contain a cycle")
  end

  active[value] = true
  local keys = {}
  for key in pairs(value) do
    if type(key) ~= "string" then
      active[value] = nil
      fail("phone target object keys must be strings")
    end
    table.insert(keys, key)
  end
  table.sort(keys)

  local fields = {}
  for _, key in ipairs(keys) do
    table.insert(fields, json_string(key) .. ":" .. json_value(value[key], active))
  end
  active[value] = nil
  return "{" .. table.concat(fields, ",") .. "}"
end

local function base64url(value)
  local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
  local encoded = {}
  for index = 1, #value, 3 do
    local first = value:byte(index)
    local second = value:byte(index + 1)
    local third = value:byte(index + 2)
    local bits = first * 65536 + (second or 0) * 256 + (third or 0)

    table.insert(encoded, alphabet:sub(math.floor(bits / 262144) % 64 + 1, math.floor(bits / 262144) % 64 + 1))
    table.insert(encoded, alphabet:sub(math.floor(bits / 4096) % 64 + 1, math.floor(bits / 4096) % 64 + 1))
    if second ~= nil then
      table.insert(encoded, alphabet:sub(math.floor(bits / 64) % 64 + 1, math.floor(bits / 64) % 64 + 1))
    end
    if third ~= nil then
      table.insert(encoded, alphabet:sub(bits % 64 + 1, bits % 64 + 1))
    end
  end
  return table.concat(encoded)
end

local function next_request_id()
  request_sequence = request_sequence + 1
  return string.format(
    "%x-%x-%d",
    os.time(),
    math.floor(os.clock() * 1000000),
    request_sequence
  )
end

local function unix_time_ms()
  local process = io.popen("/usr/bin/date +%s%3N", "r")
  if process == nil then
    fail("unable to read the wall clock")
  end
  local value = process:read("*l")
  local closed = process:close()
  local milliseconds = tonumber(value)
  if not closed or milliseconds == nil or milliseconds < 0
      or milliseconds ~= math.floor(milliseconds) then
    fail("unable to read the wall clock")
  end
  return milliseconds
end

local function dispatch_target(target)
  local envelope = table.concat({
    '{"requestId":',
    json_string(next_request_id()),
    ',"target":',
    json_value(target, {}),
    ',"expiresAtUnixMs":',
    tostring(unix_time_ms() + 2000),
    "}",
  })
  local command = "omarchy-shell ollie.android phone-target "
    .. o.shell_quote(base64url(envelope))
  hl.exec_cmd(command)
end

local function close_panel()
  hl.dispatch(hl.dsp.submap("reset"))
  hl.exec_cmd("omarchy-shell ollie.android close")
end

local api = {
  close_panel = close_panel,
}

function api.bind(keys, description, target)
  if not defining_submap then
    fail("bindings must be declared inside define_submap")
  end
  if type(keys) ~= "string" or keys == "" then
    fail("binding keys must be a non-empty string")
  end
  if type(description) ~= "string" or description == "" then
    fail("binding description must be a non-empty string")
  end

  local dispatcher
  if target == close_panel then
    dispatcher = close_panel
  else
    dispatcher = function()
      dispatch_target(target)
    end
  end
  hl.bind(keys, dispatcher, { description = description })
end

function api.define_submap(name, declarations)
  if name ~= SUBMAP_NAME then
    fail('the only supported submap is "' .. SUBMAP_NAME .. '"')
  end
  if submap_defined then
    fail("the phone submap is already defined")
  end
  if type(declarations) ~= "function" then
    fail("submap declarations must be a function")
  end

  submap_defined = true
  hl.define_submap(SUBMAP_NAME, function()
    defining_submap = true
    local ok, declaration_error = pcall(declarations)
    defining_submap = false
    if not ok then
      error(declaration_error, 0)
    end
  end)
end

return api
