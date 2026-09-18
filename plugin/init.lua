-- WezTerm Theme Picker
--
-- Browse, preview, search and apply every color scheme WezTerm can load.
--
--   - Right-hand preview pane lists all schemes (built-in + color_scheme_dirs)
--   - Each row carries a truecolor swatch of that scheme's actual palette
--   - Navigating re-themes the whole window live, so you preview on your own
--     terminal content, not a canned sample
--   - Type to filter (letters, digits, space, -, _, .), Backspace to edit
--   - Enter applies and persists; Esc cancels and restores the old scheme
--
-- Usage in wezterm.lua:
--
--   local theme_picker = wezterm.plugin.require(
--     "https://github.com/fa137/wezterm-theme-picker"
--   )
--   theme_picker.apply_to_config(config)
--
-- The last applied theme is stored in the wezterm state dir so it survives
-- restarts; once a theme has been picked it becomes the startup default.

local wezterm = require("wezterm")
local act = wezterm.action

local M = {}

local DEFAULT_OPTS = {
  -- Hotkey that opens the picker.
  key = "P",
  mods = "CTRL|SHIFT",
  -- How much of the window the preview pane takes (fraction, < 1).
  preview_percent = 0.38,
  -- Long-running inert program for the preview pane. It never receives
  -- input; the picker draws into it with pane:inject_output().
  preview_command = { "sleep", "100000" },
}

local opts = {}
for k, v in pairs(DEFAULT_OPTS) do
  opts[k] = v
end

-- color_scheme_dirs captured from the config at apply time, so local schemes
-- are enumerated alongside the built-ins.
local scheme_dirs = {}

-- window_id -> picker session state
local pickers = {}

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

local function write_state(name)
  local ok, text = pcall(wezterm.serde.toml_encode, { color_scheme = name })
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

-------------------------------------------------------------------------------
-- Rendering
-------------------------------------------------------------------------------

local function visible_rows(st)
  local ok, dims = pcall(function()
    return st.pane:get_dimensions()
  end)
  if ok and dims then
    return math.max(1, dims.viewport_rows - 3)
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

local function render_scheme_row(entry, selected, width)
  local marker = selected and "▸ " or "  "
  local swatch = {}
  local ansi = entry.ansi
  if type(ansi) == "table" then
    for i = 1, 16 do
      swatch[#swatch + 1] = swatch_cell(ansi[i])
    end
    swatch[#swatch + 1] = "\x1b[0m"
  end
  local name_width = math.max(1, width - 2 - 16 - 1)
  local name = wezterm.truncate_right(entry.name, name_width)
  local style = selected and "\x1b[1m" or "\x1b[2m"
  return marker .. table.concat(swatch) .. " " .. style .. name .. "\x1b[0m\r\n"
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

  ensure_visible(st, rows)

  local out = { "\x1b[2J", "\x1b[H", "\x1b[0m" }

  local head = string.format(" theme picker  ·  %d / %d schemes", #st.filtered, #st.all)
  if st.query ~= "" then
    head = head .. "  ·  filter: " .. st.query
  end
  out[#out + 1] = "\x1b[1;4m" .. wezterm.truncate_right(head, cols) .. "\x1b[0m\r\n"

  if #st.filtered == 0 then
    out[#out + 1] = "\x1b[2m  (no matches)\x1b[0m\r\n"
  else
    for i = st.scroll, math.min(#st.filtered, st.scroll + rows - 1) do
      local entry = st.all[st.filtered[i]]
      out[#out + 1] = render_scheme_row(entry, i == st.idx, cols)
    end
  end

  local footer =
    "\x1b[2marrows move · pgup/pgdn page · home/end jump · type to filter · enter apply · esc cancel\x1b[0m"
  out[#out + 1] = "\r\n" .. wezterm.truncate_right(footer, cols)

  pcall(function()
    st.pane:inject_output(table.concat(out))
  end)
end

-------------------------------------------------------------------------------
-- Session logic
-------------------------------------------------------------------------------

local function recompute_filter(st)
  local q = st.query:lower()
  st.filtered = {}
  for i, entry in ipairs(st.all) do
    if q == "" or entry.name:lower():find(q, 1, true) then
      st.filtered[#st.filtered + 1] = i
    end
  end
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
    all = build_scheme_list(),
    filtered = {},
    idx = 1,
    scroll = 1,
  }
  recompute_filter(st)

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
  if #st.filtered == 0 then
    return
  end
  local name = st.all[st.filtered[st.idx]].name
  apply_theme(window, name)
  write_state(name)
  close_picker(window, st, "Applied: " .. name)
end

local function cancel(window, st)
  apply_theme(window, st.original)
  close_picker(window, st, "Cancelled")
end

local function nav(window, fn)
  local st = pickers[window:window_id()]
  if not st then
    return
  end
  fn(st)
  st.idx = math.min(math.max(st.idx, 1), #st.filtered)
  redraw(st)
end

local function type_char(window, ch)
  local st = pickers[window:window_id()]
  if not st then
    return
  end
  st.query = st.query .. ch
  recompute_filter(st)
  redraw(st)
end

local function backspace(window)
  local st = pickers[window:window_id()]
  if not st then
    return
  end
  st.query = st.query:sub(1, -2)
  recompute_filter(st)
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
  t[#t + 1] = { key = "UpArrow", action = act.EmitEvent("theme-picker-up") }
  t[#t + 1] = { key = "DownArrow", action = act.EmitEvent("theme-picker-down") }
  t[#t + 1] = { key = "PageUp", action = act.EmitEvent("theme-picker-pageup") }
  t[#t + 1] = { key = "PageDown", action = act.EmitEvent("theme-picker-pagedown") }
  t[#t + 1] = { key = "Home", action = act.EmitEvent("theme-picker-home") }
  t[#t + 1] = { key = "End", action = act.EmitEvent("theme-picker-end") }
  t[#t + 1] = { key = "Backspace", action = act.EmitEvent("theme-picker-backspace") }
  t[#t + 1] = { key = "Enter", action = act.EmitEvent("theme-picker-accept") }
  t[#t + 1] = { key = "Escape", action = act.EmitEvent("theme-picker-cancel") }
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
      st.idx = #st.filtered
    end)
  end)
  wezterm.on("theme-picker-backspace", backspace)
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
  end

  scheme_dirs = config.color_scheme_dirs or {}

  -- A previously picked theme becomes the startup default. Without state we
  -- leave config.color_scheme alone (the user's own default stays).
  local state = read_state()
  if state and type(state.color_scheme) == "string" then
    config.color_scheme = state.color_scheme
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