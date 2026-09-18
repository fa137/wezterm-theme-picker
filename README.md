# WezTerm Theme Picker

A live-preview color scheme picker for [WezTerm](https://wezterm.org).

Press the hotkey and a **right-hand preview pane** opens listing every color
scheme WezTerm can load - all built-in schemes plus anything in your
`color_scheme_dirs`. Every row carries a truecolor swatch of that scheme's
actual 16-color palette, and browsing **re-themes the whole window live**, so
you preview each theme against your own terminal content rather than a canned
sample.

## Features

- **All schemes, not a curated list** - built-ins plus your local dirs
- **Truecolor swatches** - each row shows that scheme's real palette
- **Live preview** - arrow through the list and the whole window re-themes
  instantly
- **Search-as-you-type filtering** - letters, digits, space, `-`, `_`, `.`
- **Window-local** - picking in one window never touches the others
- **Persistent** - the last applied theme is remembered across restarts
- **`Enter` applies, `Esc` cancels** and restores the previous theme

## Requirements

- WezTerm `20240203-110809-5046fc22` or newer
  (`wezterm.plugin.require` and `pane:inject_output`)

## Installation

Add to your `wezterm.lua`:

```lua
local wezterm = require("wezterm")

local config = wezterm.config_builder()

-- Load the plugin (clone is cached locally by WezTerm)
local theme_picker = wezterm.plugin.require(
  "https://github.com/fa137/wezterm-theme-picker"
)

-- Wire it up: registers the hotkey, the picker key table, the events,
-- and restores the last picked theme as the startup default.
theme_picker.apply_to_config(config)

return config
```

Then reload the config (`Ctrl+Shift+R`) and press:

| Key | Action |
| --- | --- |
| `Ctrl+Shift+P` | Open the theme picker |
| `↑` / `↓` | Move through the list |
| `PgUp` / `PgDn` | Page through the list |
| `Home` / `End` | Jump to first / last |
| type | Filter as you type |
| `Backspace` | Edit the filter |
| `Enter` | Apply the selected theme |
| `Esc` | Cancel, restore previous theme |

## Configuration

`apply_to_config` accepts an optional options table:

```lua
theme_picker.apply_to_config(config, {
  key = "P",
  mods = "CTRL|SHIFT",      -- hotkey that opens the picker
  preview_percent = 0.38,   -- preview pane width (fraction of the window)
  preview_command = { "sleep", "100000" }, -- inert program for the preview pane
})
```

## How it works

- Opening the picker splits the current pane (`pane:split`) and captures the
  new `Pane` object directly - no shell involved.
- The list is drawn into that pane with `pane:inject_output()`: ANSI escape
  sequences with truecolor swatch cells, so no external process is needed.
- While the picker is open a dedicated key table is active
  (`config.key_tables.theme_picker`), so typing filters and arrows navigate
  instead of reaching the preview pane.
- Every navigation applies `color_scheme` via `window:set_config_overrides`,
  which re-themes the entire window instantly; the picker state is tracked per
  `window_id`, so previewing is window-local.
- `Enter` also writes the chosen scheme to `~/.local/share/wezterm/
  theme-picker-state.toml`, and on the next launch `apply_to_config` reads it
  back and sets it as the startup default.

## Credits

Built with the assistance of [Big Pickle](https://opencode.ai), an AI coding
agent. Maintained by the `fa137` GitHub account.

## License

MIT