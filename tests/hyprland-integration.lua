local integration = assert(arg[1], "integration path")
local calls = {}

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

dofile(integration)
dofile(integration)

local browser = { omarchy = "browser" }
local private_browser = { omarchy = "browser --private" }
local terminal = { omarchy = "terminal" }
local options = { locked = true }

o.bind("SUPER + SHIFT + B", "Browser", browser, options)
o.bind("SUPER + SHIFT + ALT + B", "Browser (private)", private_browser)
o.bind("SUPER + RETURN", "Terminal", terminal)

assert(#calls == 3, "each binding must be registered exactly once")
assert(calls[1].keys == "SUPER + SHIFT + B")
assert(calls[1].description == "Browser / Android browser")
assert(type(calls[1].dispatcher) == "string")
assert(calls[1].dispatcher:match("omarchy%-android%-action' omarchy%-browser omarchy%-launch%-browser$"))
assert(calls[1].options == options)
assert(calls[2].dispatcher == private_browser, "private browser must remain untouched")
assert(calls[3].dispatcher == terminal, "unsupported bindings must remain untouched")
