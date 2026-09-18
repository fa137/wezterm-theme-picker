-- WezTerm Theme Picker
--
-- Browse, preview, search and apply every color scheme WezTerm can load.
--
--   - Right-hand preview pane lists all schemes (built-in + color_scheme_dirs)
--   - Each row carries a truecolor swatch of that scheme's actual palette
--   - Navigating re-themes the whole window live, so you preview on your own
--     terminal content, not a canned sample
--   - A search input field at the top; type to filter (letters, digits,
--     space, -, _, .), Backspace to edit
--   - Filter by light/dark (background luminance), favorites-only, and a
--     parent-group drill view for theme families (e.g. Gruvbox Dark (Gogh),
--     Gruvbox Dark (Hard), ... all live under the "Gruvbox Dark" parent)
--   - Every picker key is configurable through `opts.keys`
--   - Enter applies and persists; Esc cancels and restores the old scheme
--
-- Usage in wezterm.lua:
--
--   local theme_picker = wezterm.plugin.require(
--     "https://github.com/fa137/wezterm-theme-picker"
--   )
--   theme_picker.apply_to_config(config)
--
-- The last applied theme plus your favorites are stored in the wezterm state
-- dir so they survive restarts; once a theme has been picked it becomes the
-- startup default.

local wezterm = require("wezterm")
local act = wezterm.action

local M = {}

local DEFAULT_OPTS = {
  -- Hotkey that opens the picker. Lowercase key with explicit SHIFT mods
  -- matches Ctrl+Shift+p unambiguously (uppercase "P" implies shift on its
  -- own and renders as a bare CTRL binding).
  key = "p",
  mods = "CTRL|SHIFT",
  -- How much of the window the preview pane takes (fraction, < 1).
  preview_percent = 0.38,
  -- Long-running inert program for the preview pane. It never receives
  -- input; the picker draws into it with pane:inject_output().
  preview_command = { "sleep", "100000" },
  -- Blank lines inserted between list rows. Set to 0 for a dense list.
  row_padding = 1,
  -- Picker key bindings, by action name. Override any of these with
  -- `keys = { cycle_tone = { key = "F8" }, ... }` in apply_to_config opts.
  keys = {
    move_down = { key = "DownArrow" },
    move_up = { key = "UpArrow" },
    page_down = { key = "PageDown" },
    page_up = { key = "PageUp" },
    jump_end = { key = "End" },
    jump_home = { key = "Home" },
    backspace = { key = "Backspace" },
    accept = { key = "Enter" },
    cancel = { key = "Escape" },
    cycle_tone = { key = "F2" },
    favorites = { key = "F3" },
    favorite = { key = "F4" },
    groups = { key = "F5" },
    reset = { key = "r", mods = "CTRL" },
  },
}

local opts = {}
for k, v in pairs(DEFAULT_OPTS) do
  if type(v) == "table" then
    opts[k] = {}
    for kk, vv in pairs(v) do
      opts[k][kk] = vv
    end
  else
    opts[k] = v
  end
end

-- color_scheme_dirs captured from the config at apply time, so local schemes
-- are enumerated alongside the built-ins.
local scheme_dirs = {}

-- window_id -> picker session state
local pickers = {}

-- name -> true. Loaded from the state file, mutated by the favorite key,
-- and persisted back on every change plus on accept/cancel.
local favorites = {}

-- The set of picker actions, mapped to the EmitEvent names they raise.
local ACTION_EVENTS = {
  move_down = "theme-picker-down",
  move_up = "theme-picker-up",
  page_down = "theme-picker-pagedown",
  page_up = "theme-picker-pageup",
  jump_end = "theme-picker-end",
  jump_home = "theme-picker-home",
  backspace = "theme-picker-backspace",
  accept = "theme-picker-accept",
  cancel = "theme-picker-cancel",
  cycle_tone = "theme-picker-tone",
  favorites = "theme-picker-favs",
  favorite = "theme-picker-fav",
  groups = "theme-picker-groups",
  reset = "theme-picker-reset",
}

-------------------------------------------------------------------------------
-- Color helpers
-------------------------------------------------------------------------------

local function rgb(c)
  if type(c) ~= "string" then
    c = tostring(c)
  end
  if not c then
    return nil
  end
  local r, g, b = c:match("#(%x%x)(%x%x)(%x%x)")
  if not r then
    return nil
  end
  return tonumber(r, 16), tonumber(g, 16), tonumber(b, 16)
end

local function fg24(c)
  local r, g, b = rgb(c)
  if not r then
    return ""
  end
  return string.format("\x1b[38;2;%d;%d;%dm", r, g, b)
end

-- A single full-block cell painted with the given color.
local function swatch_cell(c)
  local f = fg24(c)
  if f == "" then
    return " "
  end
  return f .. "█"
end

-- Relative luminance of an sRGB hex color (W3C formula); nil if unparseable.
local function relative_luminance(c)
  local r, g, b = rgb(c)
  if not r then
    return nil
  end
  local function lin(v)
    v = v / 255
    if v <= 0.03928 then
      return v / 12.92
    end
    return ((v + 0.055) / 1.055) ^ 2.4
  end
  return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
end

-- "light" / "dark" for backgrounds whose luminance is known, nil otherwise.
local function tone_of(bg)
  local lum = relative_luminance(bg)
  if not lum then
    return nil
  end
  return lum >= 0.5 and "light" or "dark"
end

-------------------------------------------------------------------------------
-- Scheme enumeration
-------------------------------------------------------------------------------

local function read_palette(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local text = f:read("*a")
  f:close()
  local ok, d = pcall(wezterm.serde.toml_decode, text)
  if not ok or type(d) ~= "table" then
    return nil
  end
  local colors = d.colors or d
  local ansi = {}
  if type(colors.ansi) == "table" then
    for _, c in ipairs(colors.ansi) do
      ansi[#ansi + 1] = c
    end
  end
  if type(colors.brights) == "table" then
    for _, c in ipairs(colors.brights) do
      ansi[#ansi + 1] = c
    end
  end
  return { ansi = ansi, fg = colors.foreground, bg = colors.background }
end

local function build_scheme_list()
  local list = {}
  local seen = {}

  local ok, builtin = pcall(wezterm.color.get_builtin_schemes)
  if ok and type(builtin) == "table" then
    for name, s in pairs(builtin) do
      list[#list + 1] = {
        name = name,
        ansi = s.ansi,
        fg = s.foreground,
        bg = s.background,
        tone = tone_of(s.background),
      }
      seen[name] = true
    end
  end

  for _, dir in ipairs(scheme_dirs) do
    local ok_dir, entries = pcall(wezterm.read_dir, dir)
    if ok_dir and entries then
      for _, entry in ipairs(entries) do
        local base = entry
          :gsub("%.toml$", "")
          :gsub("%.yaml$", "")
          :gsub("%.yml$", "")
          :gsub("%.ini$", "")
        if base ~= entry and not seen[base] then
          local pal = read_palette(dir .. "/" .. entry)
          list[#list + 1] = {
            name = base,
            ansi = pal and pal.ansi,
            fg = pal and pal.fg,
            bg = pal and pal.bg,
            tone = pal and tone_of(pal.bg),
          }
          seen[base] = true
        end
      end
    end
  end

  table.sort(list, function(a, b)
    return a.name:lower() < b.name:lower()
  end)
  return list
end

-- The "parent" of a scheme is everything before the first " ("; schemes
-- without a parenthetical keep their full name. "Gruvbox Dark (Gogh)" and
-- "Gruvbox Dark (Hard)" therefore share the parent "Gruvbox Dark".
local function parent_of(name)
  return name:match("^(.-) %(") or name
end

-------------------------------------------------------------------------------
-- Persistence
-------------------------------------------------------------------------------

local function state_path()
  local base = wezterm.state_dir or wezterm.config_dir
  return base .. "/theme-picker-state.toml"
end

local function read_state()
  local f = io.open(state_path(), "rb")
  if not f then
    return nil
  end
  local text = f:read("*a")
  f:close()
  local ok, d = pcall(wezterm.serde.toml_decode, text)
  if not ok or type(d) ~= "table" then
    return nil
  end
  return d
end

local function write_state(name, favs)
  local payload = { color_scheme = name, favorites = favs }
  local ok, text = pcall(wezterm.serde.toml_encode, payload)
  if not ok or not text then
    return
  end
  local f = io.open(state_path(), "wb")
  if not f then
    return
  end
  f:write(text)
  f:close()
end

local function favorites_list()
  local arr = {}
  for name in pairs(favorites) do
    arr[#arr + 1] = name
  end
  table.sort(arr)
  return arr
end

-------------------------------------------------------------------------------
-- Rendering
-------------------------------------------------------------------------------

-- How many list rows fit (each row consumes 1 + row_padding lines).
local function visible_rows(st)
  local ok, dims = pcall(function()
    return st.pane:get_dimensions()
  end)
  if ok and dims then
    local budget = math.max(1, dims.viewport_rows - 5)
    return math.max(1, math.floor(budget / (1 + opts.row_padding)))
  end
  return 10
end

local function ensure_visible(st, rows)
  if st.idx < st.scroll then
    st.scroll = st.idx
  end
  local last = st.scroll + rows - 1
  if st.idx > last then
    st.scroll = st.idx - rows + 1
  end
end

local function swatch_str(entry)
  local swatch = {}
  local ansi = entry.ansi
  if type(ansi) == "table" then
    for i = 1, 16 do
      swatch[#swatch + 1] = swatch_cell(ansi[i])
    end
    swatch[#swatch + 1] = "\x1b[0m"
  end
  return table.concat(swatch)
end

local function render_scheme_row(entry, selected, width)
  local marker = selected and "▸ " or "  "
  local fav = favorites[entry.name] and "★ " or "  "
  local name_width = math.max(1, width - 2 - 2 - 16 - 1)
  local name = wezterm.truncate_right(entry.name, name_width)
  local style = selected and "\x1b[1m" or "\x1b[2m"
  return marker .. fav .. swatch_str(entry) .. " " .. style .. name .. "\x1b[0m\r\n"
end

local function render_group_row(st, g, selected, width)
  local marker = selected and "▸ " or "  "
  local label = g.parent .. string.format(" (%d)", g.count)
  local name_width = math.max(1, width - 2 - 16 - 1)
  local name = wezterm.truncate_right(label, name_width)
  local style = selected and "\x1b[1m" or "\x1b[2m"
  return marker .. swatch_str(st.all[g.idx]) .. " " .. style .. name .. "\x1b[0m\r\n"
end

local function hint(action)
  local spec = opts.keys[action]
  local mods = (spec.mods or ""):gsub("|", "+"):lower()
  local names = {
    UpArrow = "↑",
    DownArrow = "↓",
    PageUp = "pgup",
    PageDown = "pgdn",
    Home = "home",
    End = "end",
    Enter = "enter",
    Escape = "esc",
    Backspace = "bksp",
    Space = "space",
  }
  local k = names[spec.key] or spec.key:lower()
  if mods == "" then
    return k
  end
  return mods .. "+" .. k
end

local function list_len(st)
  return st.grouped and #st.groups or #st.filtered
end

local function redraw(st)
  if not st.pane then
    return
  end
  local ok, dims = pcall(function()
    return st.pane:get_dimensions()
  end)
  if not ok or not dims then
    return
  end
  local cols = math.max(20, dims.cols)
  local rows = visible_rows(st)
  local total = list_len(st)
  if st.idx > total then
    st.idx = total
  end
  if st.idx < 1 then
    st.idx = 1
  end
  ensure_visible(st, rows)

  local out = { "\x1b[2J", "\x1b[H", "\x1b[0m" }

  -- Header line with counts and active filter chips.
  local head = string.format(" theme picker  ·  %d / %d schemes", total, #st.all)
  if st.tone ~= "all" then
    head = head .. "  ·  " .. st.tone
  end
  if st.favs_only then
    head = head .. "  ·  favorites only"
  end
  if st.grouped then
    head = head .. "  ·  grouped by parent"
  end
  out[#out + 1] = "\x1b[1;4m" .. wezterm.truncate_right(head, cols) .. "\x1b[0m\r\n"

  -- Search input field.
  local field = " search:"
  if st.query == "" then
    field = field .. " \x1b[2m(type to filter)\x1b[0m"
  else
    field = field .. " \x1b[7m" .. st.query .. "▌\x1b[0m"
  end
  out[#out + 1] = wezterm.truncate_right(field, cols) .. "\r\n\r\n"

  -- List rows.
  if total == 0 then
    local msg = st.favs_only
        and "no favorites yet - press "
        .. hint("favorite")
        .. " on a scheme to add one"
      or "(no matches)"
    out[#out + 1] = "\x1b[2m  " .. msg .. "\x1b[0m\r\n"
  elseif st.grouped then
    for i = st.scroll, math.min(#st.groups, st.scroll + rows - 1) do
      out[#out + 1] = render_group_row(st, st.groups[i], i == st.idx, cols)
      for _ = 1, opts.row_padding do
        out[#out + 1] = "\r\n"
      end
    end
  else
    for i = st.scroll, math.min(#st.filtered, st.scroll + rows - 1) do
      local entry = st.all[st.filtered[i]]
      out[#out + 1] = render_scheme_row(entry, i == st.idx, cols)
      for _ = 1, opts.row_padding do
        out[#out + 1] = "\r\n"
      end
    end
  end

  local footer = string.format(
    "type filter · %s light/dark · %s favs-only · %s fav · %s group · %s reset · %s apply · %s cancel",
    hint("cycle_tone"),
    hint("favorites"),
    hint("favorite"),
    hint("groups"),
    hint("reset"),
    hint("accept"),
    hint("cancel")
  )
  out[#out + 1] =
    "\r\n\x1b[2m" .. wezterm.truncate_right(footer, cols) .. "\x1b[0m"

  pcall(function()
    st.pane:inject_output(table.concat(out))
  end)
end

-------------------------------------------------------------------------------
-- Session logic
-------------------------------------------------------------------------------

local function recompute(st)
  local q = st.query:lower()
  st.filtered = {}
  for i, entry in ipairs(st.all) do
    local nm = entry.name:lower()
    local ok_name = q == "" or nm:find(q, 1, true)
    local ok_tone = st.tone == "all" or entry.tone == nil or entry.tone == st.tone
    local ok_fav = not st.favs_only or favorites[entry.name]
    if ok_name and ok_tone and ok_fav then
      st.filtered[#st.filtered + 1] = i
    end
  end

  local gmap = {}
  st.groups = {}
  for _, i in ipairs(st.filtered) do
    local e = st.all[i]
    local p = parent_of(e.name)
    if not gmap[p] then
      gmap[p] = { parent = p, count = 0, idx = i }
      st.groups[#st.groups + 1] = gmap[p]
    end
    gmap[p].count = gmap[p].count + 1
  end
  table.sort(st.groups, function(a, b)
    return a.parent:lower() < b.parent:lower()
  end)

  st.idx = 1
  st.scroll = 1
end

local function apply_theme(window, name)
  local overrides = window:get_config_overrides() or {}
  overrides.color_scheme = name
  window:set_config_overrides(overrides)
end

local function open_picker(window, pane)
  local wid = window:window_id()
  if pickers[wid] then
    window:toast_notification("Theme Picker", "Picker already open", nil, 1500)
    return
  end

  local current = (window:get_config_overrides() or {}).color_scheme
  if not current then
    current = window:effective_config().color_scheme
  end

  local ok, preview = pcall(function()
    return pane:split {
      direction = "Right",
      size = opts.preview_percent,
      args = opts.preview_command,
    }
  end)
  if not ok or not preview then
    window:toast_notification("Theme Picker", "Could not open preview pane", nil, 2000)
    return
  end

  local st = {
    pane = preview,
    original = current,
    query = "",
    tone = "all",
    favs_only = false,
    grouped = false,
    all = build_scheme_list(),
    filtered = {},
    groups = {},
    idx = 1,
    scroll = 1,
  }
  recompute(st)

  -- Start with the scheme currently applied selected, if it is in the list.
  if current then
    for i, idx in ipairs(st.filtered) do
      if st.all[idx].name == current then
        st.idx = i
        break
      end
    end
  end

  pickers[wid] = st
  redraw(st)
  window:perform_action(act.ActivateKeyTable { name = "theme_picker", one_shot = false }, preview)
end

local function close_picker(window, st, toast)
  pcall(function()
    window:perform_action(act.PopKeyTable, st.pane)
  end)
  pcall(function()
    window:perform_action(act.CloseCurrentPane { confirm = false }, st.pane)
  end)
  pickers[window:window_id()] = nil
  if toast then
    window:toast_notification("Theme Picker", toast, nil, 2000)
  end
end

local function accept(window, st)
  if #st.groups == 0 and #st.filtered == 0 then
    return
  end
  if st.grouped then
    -- Drill into the selected parent: set the query to the parent name and
    -- show its children as a flat searchable list.
    local g = st.groups[st.idx]
    st.query = g.parent
    st.grouped = false
    recompute(st)
    redraw(st)
    return
  end
  local name = st.all[st.filtered[st.idx]].name
  apply_theme(window, name)
  write_state(name, favorites_list())
  close_picker(window, st, "Applied: " .. name)
end

local function cancel(window, st)
  apply_theme(window, st.original)
  write_state(st.original, favorites_list())
  close_picker(window, st, "Cancelled")
end

local function nav(window, fn)
  local st = pickers[window:window_id()]
  if not st then
    return
  end
  fn(st)
  st.idx = math.min(math.max(st.idx, 1), list_len(st))
  redraw(st)
end

local function type_char(window, ch)
  local st = pickers[window:window_id()]
  if not st then
    return
  end
  st.query = st.query .. ch
  recompute(st)
  redraw(st)
end

local function backspace(window)
  local st = pickers[window:window_id()]
  if not st then
    return
  end
  st.query = st.query:sub(1, -2)
  recompute(st)
  redraw(st)
end

local function cycle_tone(window)
  local st = pickers[window:window_id()]
  if not st then
    return
  end
  st.tone = st.tone == "all" and "light" or (st.tone == "light" and "dark" or "all")
  recompute(st)
  redraw(st)
end

local function toggle_favs_only(window)
  local st = pickers[window:window_id()]
  if not st then
    return
  end
  st.favs_only = not st.favs_only
  recompute(st)
  redraw(st)
end

local function toggle_grouped(window)
  local st = pickers[window:window_id()]
  if not st then
    return
  end
  st.grouped = not st.grouped
  redraw(st)
end

local function toggle_favorite(window)
  local st = pickers[window:window_id()]
  if not st or st.grouped or #st.filtered == 0 then
    return
  end
  local name = st.all[st.filtered[st.idx]].name
  favorites[name] = not favorites[name]
  write_state(st.original, favorites_list())
  redraw(st)
end

local function reset(window)
  local st = pickers[window:window_id()]
  if not st then
    return
  end
  st.query = ""
  st.tone = "all"
  st.favs_only = false
  st.grouped = false
  recompute(st)
  redraw(st)
end

-------------------------------------------------------------------------------
-- Key table + events
-------------------------------------------------------------------------------

local function char_key_table_entries()
  local entries = {}

  local function add(key, target)
    entries[#entries + 1] = {
      key = key,
      action = wezterm.action_callback(function(window)
        type_char(window, target)
      end),
    }
  end

  add("Space", " ")
  add("-", "-")
  add("_", "_")
  add(".", ".")
  for i = 0, 9 do
    add(tostring(i), tostring(i))
  end
  for i = string.byte("a"), string.byte("z") do
    local c = string.char(i)
    add(c, c)
    add(string.upper(c), c)
  end

  return entries
end

local function build_key_table()
  local t = char_key_table_entries()
  for action, event in pairs(ACTION_EVENTS) do
    local spec = opts.keys[action]
    local entry = { key = spec.key, action = act.EmitEvent(event) }
    if spec.mods and spec.mods ~= "" then
      entry.mods = spec.mods
    end
    t[#t + 1] = entry
  end
  return t
end

-------------------------------------------------------------------------------
-- apply_to_config - the plugin entry point
-------------------------------------------------------------------------------

local function register_picker()
  wezterm.on("theme-picker-open", open_picker)
  wezterm.on("theme-picker-up", function(window)
    nav(window, function(st)
      st.idx = st.idx - 1
    end)
  end)
  wezterm.on("theme-picker-down", function(window)
    nav(window, function(st)
      st.idx = st.idx + 1
    end)
  end)
  wezterm.on("theme-picker-pageup", function(window)
    nav(window, function(st)
      st.idx = st.idx - visible_rows(st)
    end)
  end)
  wezterm.on("theme-picker-pagedown", function(window)
    nav(window, function(st)
      st.idx = st.idx + visible_rows(st)
    end)
  end)
  wezterm.on("theme-picker-home", function(window)
    nav(window, function(st)
      st.idx = 1
    end)
  end)
  wezterm.on("theme-picker-end", function(window)
    nav(window, function(st)
      st.idx = list_len(st)
    end)
  end)
  wezterm.on("theme-picker-backspace", backspace)
  wezterm.on("theme-picker-tone", cycle_tone)
  wezterm.on("theme-picker-favs", toggle_favs_only)
  wezterm.on("theme-picker-fav", toggle_favorite)
  wezterm.on("theme-picker-groups", toggle_grouped)
  wezterm.on("theme-picker-reset", reset)
  wezterm.on("theme-picker-accept", function(window)
    local p = pickers[window:window_id()]
    if p then
      accept(window, p)
    end
  end)
  wezterm.on("theme-picker-cancel", function(window)
    local p = pickers[window:window_id()]
    if p then
      cancel(window, p)
    end
  end)
end

function M.apply_to_config(config, user_opts)
  if user_opts then
    if user_opts.key then
      opts.key = user_opts.key
    end
    if user_opts.mods then
      opts.mods = user_opts.mods
    end
    if user_opts.preview_percent then
      opts.preview_percent = user_opts.preview_percent
    end
    if user_opts.preview_command then
      opts.preview_command = user_opts.preview_command
    end
    if user_opts.row_padding ~= nil then
      opts.row_padding = user_opts.row_padding
    end
    if user_opts.keys then
      for action, spec in pairs(user_opts.keys) do
        if DEFAULT_OPTS.keys[action] and spec and spec.key then
          opts.keys[action] = { key = spec.key, mods = spec.mods or "" }
        end
      end
    end
  end

  scheme_dirs = config.color_scheme_dirs or {}

  -- A previously picked theme becomes the startup default, and favorites are
  -- restored. Without state we leave config.color_scheme alone (the user's
  -- own default stays).
  local state = read_state()
  if state then
    if type(state.color_scheme) == "string" then
      config.color_scheme = state.color_scheme
    end
    if type(state.favorites) == "table" then
      for _, name in ipairs(state.favorites) do
        favorites[name] = true
      end
    end
  end

  register_picker()

  -- The open key binding.
  config.keys = config.keys or {}
  config.keys[#config.keys + 1] = {
    key = opts.key,
    mods = opts.mods,
    action = act.EmitEvent("theme-picker-open"),
  }

  -- The picker-mode key table (activated while picking).
  config.key_tables = config.key_tables or {}
  config.key_tables.theme_picker = build_key_table()
end

return M