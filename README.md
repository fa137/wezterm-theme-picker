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
- **Search input field** - a dedicated input at the top of the picker; type
  to filter as you go (letters, digits, space, `-`, `_`, `.`)
- **Light / dark filter** - cycle `F2` through `all -> light -> dark`; themes
  are classified by the relative luminance of their background
- **Favorites** - press `F4` to favorite a theme, `F3` to show only your
  favorites; favorites persist across restarts
- **Parent-group browsing** - `F5` groups multi-variant families (e.g. all
  `Gruvbox Dark (Gogh)`, `Gruvbox Dark (Hard)`, ... under one `Gruvbox Dark`
  parent); `Enter` drills into a parent's children
- **Configurable keys** - every picker key can be remapped via `opts.keys`
- **Row padding** - configurable blank lines between rows (default 1)
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
-- restores the last picked theme as the startup default, and loads your
-- favorites.
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
| `F2` | Cycle tone filter: `all -> light -> dark` |
| `F3` | Toggle favorites-only view |
| `F4` | Favorite / unfavorite the selected theme |
| `F5` | Toggle parent-group view |
| `Ctrl+r` | Reset query and all filters |
| `Enter` | Apply the selected theme (or drill into a group) |
| `Esc` | Cancel, restore previous theme |

## Configuration

`apply_to_config` accepts an optional options table:

```lua
theme_picker.apply_to_config(config, {
  key = "P",
  mods = "CTRL|SHIFT",      -- hotkey that opens the picker
  preview_percent = 0.38,   -- preview pane width (fraction of the window)
  preview_command = { "sleep", "100000" }, -- inert program for the preview pane
  row_padding = 1,          -- blank lines between list rows (0 = dense)
  keys = {
    -- Remap any picker key. The full set of action names:
    --   move_up      move_down    page_up     page_down
    --   jump_home    jump_end     backspace   accept
    --   cancel       cycle_tone   favorites   favorite
    --   groups       reset
    --
    -- Each action is a table with `key` (required) and `mods` (optional,
    -- e.g. "CTRL|SHIFT"). If mods is omitted the binding uses no modifiers.
    cycle_tone = { key = "F8" },
    favorite = { key = "s", mods = "CTRL|SHIFT" },
    reset = { key = "q", mods = "CTRL" },
  },
})
```

The action keys map to defaults as:

| Action | Default |
| --- | --- |
| `move_up` | `UpArrow` |
| `move_down` | `DownArrow` |
| `page_up` | `PageUp` |
| `page_down` | `PageDown` |
| `jump_home` | `Home` |
| `jump_end` | `End` |
| `backspace` | `Backspace` |
| `accept` | `Enter` |
| `cancel` | `Escape` |
| `cycle_tone` | `F2` |
| `favorites` | `F3` |
| `favorite` | `F4` |
| `groups` | `F5` |
| `reset` | `Ctrl+r` |

## Filtering

- **Text** - anything you type filters by name. Exactly what you type lands
  in the input field at the top of the picker.
- **Light / dark** - `F2` cycles `all -> light -> dark`. A theme is `light`
  when the relative luminance of its background is `>= 0.5` (W3C formula,
  sRGB linearized); schemes with no parseable background are shown in every
  tone mode so nothing disappears.
- **Favorites** - `F4` stars the selected theme; `F3` hides everything else.
  Favorites are stored in the same state file as the applied theme (see
  below) and restored on the next launch.
- **Parent groups** - `F5` switches the list to a grouped view. A scheme's
  parent is everything before the first ` (`: `Gruvbox Dark (Gogh)`,
  `Gruvbox Dark (Hard)` and `Gruvbox Dark (Soft)` all belong to the parent
  `Gruvbox Dark`. Each group row shows the swatch of its first member and the
  member count; `Enter` on a group sets the search query to the parent name
  and shows its children, where you can keep filtering and pick one.

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
- `Enter` writes the chosen scheme to `theme-picker-state.toml` in WezTerm's
  state directory (falling back to the config directory when the state dir is
  unavailable), and on the next launch `apply_to_config` reads it back and
  sets it as the startup default. The same file stores your `favorites` list,
  so stars survive restarts too.

## Credits

Built and maintained by [Big Pickle](https://opencode.ai), an AI coding agent,
made possible by the OpenCode agent harness.

## License

MIT