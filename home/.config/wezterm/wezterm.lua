local wezterm = require 'wezterm'
local config = wezterm.config_builder()
config.font = wezterm.font("FiraCode Nerd Font Mono")
config.font_size = 10.0
config.window_background_opacity = 0.85
config.enable_wayland = false
config.enable_tab_bar = false
config.window_padding = {
  left = 0,
  right = 0,
  top = 0,
  bottom = 0,
}
config.colors = {
  foreground = "#c0caf5",
  background = "#1a1b26",
  cursor_bg = "#c0caf5",
  cursor_fg = "#1a1b26",
  ansi = {
    "#15161e", "#f7768e", "#9ece6a", "#e0af68",
    "#7aa2f7", "#bb9af7", "#7dcfff", "#a9b1d6",
  },
  brights = {
    "#414868", "#f7768e", "#9ece6a", "#e0af68",
    "#7aa2f7", "#bb9af7", "#7dcfff", "#c0caf5",
  },
}
config.mouse_bindings = {
  -- Middle click: paste from Clipboard (for Windows → Wezterm)
  {
    event = { Down = { streak = 1, button = 'Middle' } },
    mods = 'NONE',
    action = wezterm.action.PasteFrom('Clipboard'),
  },
  -- Left button release: finish selection + copy to both Clipboard and Primary
  {
    event = { Up = { streak = 1, button = 'Left' } },
    mods = 'NONE',
    action = wezterm.action.Multiple {
      wezterm.action.CompleteSelection('Clipboard'),
      wezterm.action.CopyTo('Clipboard'),
      wezterm.action.CopyTo('PrimarySelection'),
    },
  },
}
config.canonicalize_pasted_newlines = "LineFeed"
return config
