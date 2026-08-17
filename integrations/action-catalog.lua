return {
  sources = {
    ["terminal"] = "omarchy.terminal",
    ["browser"] = "omarchy.browser",
    ["browser --private"] = "omarchy.browser.private",
    ["nautilus"] = "omarchy.file-manager",
    ["nautilus-cwd"] = "omarchy.file-manager.cwd",
    ["editor"] = "omarchy.editor",
    ["terminal-tmux"] = "omarchy.terminal.tmux",
    ["terminal-herdr"] = "omarchy.terminal.herdr",
    ["spotify"] = "omarchy.spotify",
    ["signal"] = "omarchy.signal",
    ["1password"] = "omarchy.passwords",
    ["toggle-android-panel"] = "omarchy.android.panel.toggle",
  },
  targets = {
    ["android.panel.toggle"] = {
      label = "Android panel toggle",
      directCommand = "omarchy-shell ollie.android toggle",
      appendLabel = false,
    },
    ["android.browser.default"] = {
      label = "Android default browser",
      actionId = "omarchy-browser",
    },
    ["android.launcher.search"] = {
      label = "Android launcher search",
      actionId = "omarchy-menu",
    },
    ["android.navigate.back"] = {
      label = "Android Back",
      actionId = "android-back",
    },
    ["android.navigate.home"] = {
      label = "Android Home",
      actionId = "android-home",
    },
    ["android.navigate.recent-apps"] = {
      label = "Android recent apps",
      actionId = "android-recent-apps",
    },
  },
  smartDefaults = {
    ["omarchy.android.panel.toggle"] = "android.panel.toggle",
    ["omarchy.browser"] = "android.browser.default",
    ["omarchy.window.close"] = "android.navigate.home",
  },
}
