return {
  -- Apply the reviewed mappings from integrations/action-catalog.lua.
  smartDefaults = true,

  -- Override or disable a smart route by stable Omarchy source ID.
  routes = {
    -- ["omarchy.browser"] = "android.browser.default",
    -- ["omarchy.window.close"] = "android.navigate.home",
    -- ["omarchy.menu"] = false,
  },

  -- Add Android-only chords when no existing Omarchy action should own them.
  customBindings = {
    -- {
    --   keys = "CTRL + ALT + SHIFT + P",
    --   action = { type = "android.app.launch", package = "com.example.app" },
    -- },
    -- { keys = "SUPER + ALT + LEFT", action = "android.navigate.back" },
  },
}
