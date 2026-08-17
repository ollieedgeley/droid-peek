return {
  -- These are the enabled routes. Remove or comment out a line to disable it.
  routes = {
    ["omarchy.android.panel.toggle"] = "android.panel.toggle",
    ["omarchy.browser"] = "android.browser.default",
    ["omarchy.window.close"] = "android.navigate.home",

    -- ["omarchy.menu"] = "android.launcher.search",
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
