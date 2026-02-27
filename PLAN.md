# PLAN.md — Zehntage Plugin Implementation

## Overview

A single-file neovim lua plugin that helps learn German vocabulary while reading.
Cursor on a word → `:ZehnTage` → Gemini translates it with context → shows floating window → saves to TSV for Anki import.
Words from the TSV are highlighted in all markdown/text buffers.

---

## Architecture Decision: Single File

The PROMPT says "try to fit in a single file if possible." We will use **one file**: `lua/zehntage.lua`.
The `plugin/zehntage.lua` file is just the 1-line loader that lazy.nvim expects.

```
.
├── lua/
│   └── zehntage.lua          # Everything lives here (~200 lines)
├── plugin/
│   └── zehntage.lua          # Just: require("zehntage").setup()
```

---

## Step 1: Scaffold — Rename template files

- Delete `lua/plugin_name/module.lua` and `lua/plugin_name/`
- Rename `lua/plugin_name.lua` → `lua/zehntage.lua`
- Rewrite `plugin/zehntage.lua` to just load the module

**plugin/zehntage.lua:**
```lua
require("zehntage").setup()
```

---

## Step 2: Storage — TSV load/save

**File location:** `vim.fn.stdpath("data") .. "/zehntage_words.tsv"`
(resolves to `~/.local/share/nvim/zehntage_words.tsv`)

**Format:**
```
front\tback\tcontext\tnotes
verneinung\tnegation\t<3 context lines>\tcomes from the word 'nein'
```

**Data structure in memory:**
```lua
-- words[front] = { back = "...", context = "...", notes = "..." }
local words = {}
```

**Loading** — read file line-by-line, split by `\t`, skip header. Done once at plugin load via `setup()`, so it's fast. The file is tiny (hundreds of lines max for 10 days of study).

```lua
local tsv_path = vim.fn.stdpath("data") .. "/zehntage_words.tsv"

local function load_words()
  words = {}
  local f = io.open(tsv_path, "r")
  if not f then return end
  local first = true
  for line in f:lines() do
    if first then first = false -- skip header
    else
      local front, back, context, notes = line:match("^(.-)\t(.-)\t(.-)\t(.*)$")
      if front then
        words[front:lower()] = { back = back, context = context, notes = notes }
      end
    end
  end
  f:close()
end
```

**Saving** — rewrite the entire file (it's small). Called after every add/remove.

```lua
local function save_words()
  local f = io.open(tsv_path, "w")
  if not f then return end
  f:write("front\tback\tcontext\tnotes\n")
  for front, data in pairs(words) do
    -- Escape newlines in context so TSV stays single-line per record
    local ctx = data.context:gsub("\n", "\\n")
    local notes = (data.notes or ""):gsub("\n", "\\n")
    f:write(front .. "\t" .. data.back .. "\t" .. ctx .. "\t" .. notes .. "\n")
  end
  f:close()
end
```

---

## Step 3: Gemini API call

**Endpoint:** `https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent`

**Auth:** `x-goog-api-key` header from `$GEMINI_API_KEY`

**Async via `vim.system`** (neovim 0.10+) — non-blocking, callback on completion.

```lua
local function call_gemini(word, context, callback)
  local api_key = vim.env.GEMINI_API_KEY
  if not api_key or api_key == "" then
    vim.notify("GEMINI_API_KEY not set", vim.log.levels.ERROR)
    return
  end

  local prompt = string.format(
    'Given the context below, translate the German word "%s" to English. '
      .. "Add concise notes for better learning/understanding if any. "
      .. 'Return ONLY valid JSON: {"translation":"...","notes":"..."}\n\nContext:\n%s',
    word,
    context
  )

  local body = vim.json.encode({
    contents = { { parts = { { text = prompt } } } },
    generation_config = { temperature = 0.2 },
  })

  vim.system(
    {
      "curl", "-s",
      "-X", "POST",
      "-H", "Content-Type: application/json",
      "-H", "x-goog-api-key: " .. api_key,
      "-d", body,
      "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent",
    },
    {},
    function(result)
      vim.schedule(function()
        if result.code ~= 0 then
          vim.notify("Gemini request failed: " .. (result.stderr or ""), vim.log.levels.ERROR)
          return
        end
        local ok, resp = pcall(vim.json.decode, result.stdout)
        if not ok then
          vim.notify("Failed to parse Gemini response", vim.log.levels.ERROR)
          return
        end
        local text = resp.candidates[1].content.parts[1].text
        -- Strip markdown code fences if present
        text = text:gsub("^```json%s*", ""):gsub("```%s*$", ""):match("^%s*(.-)%s*$")
        local ok2, data = pcall(vim.json.decode, text)
        if ok2 then
          callback(data)
        else
          vim.notify("Gemini returned invalid JSON: " .. text, vim.log.levels.ERROR)
        end
      end)
    end
  )
end
```

**Key decisions:**
- Use `vim.system` (async) → UI stays responsive, no blocking
- `vim.schedule` in callback → safe to call vim APIs from async context
- `temperature = 0.2` → deterministic translations
- Strip markdown code fences → Gemini sometimes wraps JSON in ` ```json `

---

## Step 4: Floating Window

Modeled after the user's `<M-k>` pattern from their DAP config. The approach:
1. First call on a word: open a float, show translation + notes
2. Second call on same word (float already open): focus the float
3. On `CursorMoved`: close the float (same behavior as `<M-k>`)

```lua
local float_win = nil
local float_buf = nil

local function show_float(word, translation, notes)
  -- If float already exists for this word, focus it
  if float_win and vim.api.nvim_win_is_valid(float_win) then
    vim.api.nvim_set_current_win(float_win)
    return
  end

  local lines = { word .. " → " .. translation }
  if notes and notes ~= "" then
    table.insert(lines, "")
    table.insert(lines, notes)
  end

  float_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(float_buf, 0, -1, false, lines)

  -- Bold the word on the first line
  vim.api.nvim_buf_add_highlight(float_buf, -1, "Bold", 0, 0, #word)

  local width = 0
  for _, l in ipairs(lines) do width = math.max(width, #l) end

  float_win = vim.api.nvim_open_win(float_buf, false, {
    relative = "cursor",
    row = 1,
    col = 0,
    width = math.min(width + 2, 60),
    height = #lines,
    style = "minimal",
    border = "rounded",
  })

  -- Auto-close on CursorMoved (same pattern as user's M-k)
  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = 0, -- current buffer only
    once = true,
    callback = function()
      if float_win and vim.api.nvim_win_is_valid(float_win) then
        vim.api.nvim_win_close(float_win, true)
      end
      float_win = nil
      float_buf = nil
    end,
  })
end
```

---

## Step 5: :ZehnTage command

The main command. Pseudocode from PROMPT:

```
let w = word under cursor
if w NOT in words:
    get 3-line context
    call Gemini → get translation + notes
    save to TSV
    show float
else (already known):
    show float with cached data
```

Simple: if already known, show cached float. If new, translate and add.

```lua
local function zehntage()
  local word = vim.fn.expand("<cword>"):lower()
  if word == "" then return end

  -- If already known, show float immediately (no re-query)
  if words[word] then
    show_float(word, words[word].back, words[word].notes)
    return
  end

  -- Get 3-line context: line above, current, line below
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local line_count = vim.api.nvim_buf_line_count(0)
  local start = math.max(0, row - 2)
  local finish = math.min(line_count, row + 1)
  local context_lines = vim.api.nvim_buf_get_lines(0, start, finish, false)
  local context = table.concat(context_lines, "\n")

  -- Call Gemini async
  call_gemini(word, context, function(data)
    words[word] = {
      back = data.translation or "",
      context = context,
      notes = data.notes or "",
    }
    save_words()
    highlight_buffer(0) -- refresh highlights
    show_float(word, data.translation or "", data.notes or "")
  end)
end
```

**Decision:** If the word is already in the list, just show the float with cached data. No re-query. This keeps it fast and avoids unnecessary API calls. Use `:ZehnTageClear` + `:ZehnTage` to refresh a translation.

---

## Step 6: :ZehnTageClear command

Simple removal. "On conflict do nothing" = if word not in list, no-op.

```lua
local function zehntage_clear()
  local word = vim.fn.expand("<cword>"):lower()
  if words[word] then
    words[word] = nil
    save_words()
    highlight_buffer(0) -- refresh highlights
  end
end
```

---

## Step 7: Word Highlighting

Inspired by nvim-colorizer.lua approach but much simpler — we just need to underline/highlight known words.

**Strategy:**
- Use a dedicated namespace: `vim.api.nvim_create_namespace("zehntage")`
- On `BufEnter` and `TextChanged`/`TextChangedI`, scan visible lines for words in our list
- Use `vim.api.nvim_buf_set_extmark` with `hl_group` for highlighting
- Only process visible lines (like colorizer does) for speed

```lua
local ns = vim.api.nvim_create_namespace("zehntage")

-- Define highlight group
vim.api.nvim_set_hl(0, "ZehnTageWord", { underline = true, fg = "#89b4fa" })

local function highlight_buffer(bufnr)
  bufnr = bufnr == 0 and vim.api.nvim_get_current_buf() or bufnr
  if not vim.api.nvim_buf_is_valid(bufnr) then return end

  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

  if vim.tbl_isempty(words) then return end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for i, line in ipairs(lines) do
    local lower_line = line:lower()
    for word, _ in pairs(words) do
      local start = 1
      while true do
        local s, e = lower_line:find(word, start, true) -- plain match
        if not s then break end
        -- Check word boundaries: must not be surrounded by word chars
        local before = s > 1 and lower_line:sub(s - 1, s - 1) or " "
        local after = e < #lower_line and lower_line:sub(e + 1, e + 1) or " "
        if not before:match("%w") and not after:match("%w") then
          vim.api.nvim_buf_set_extmark(bufnr, ns, i - 1, s - 1, {
            end_col = e,
            hl_group = "ZehnTageWord",
          })
        end
        start = e + 1
      end
    end
  end
end
```

**Performance notes:**
- For a vocabulary of ~100-500 words and markdown files of a few hundred lines, this is instant
- We scan the full buffer (not just visible) because the word list is small — no need for the trie/parser complexity of colorizer
- `plain = true` in `find()` means no regex overhead
- We clear+reapply on every trigger — simple and correct

**Autocmds for re-highlighting:**
```lua
vim.api.nvim_create_autocmd({ "BufEnter", "TextChanged", "TextChangedI" }, {
  group = vim.api.nvim_create_augroup("ZehnTageHighlight", { clear = true }),
  pattern = { "*.md", "*.txt" },
  callback = function(ev)
    highlight_buffer(ev.buf)
  end,
})
```

---

## Step 8: setup() and Command Registration

```lua
local M = {}

M.setup = function(opts)
  load_words()

  vim.api.nvim_create_user_command("ZehnTage", zehntage, {})
  vim.api.nvim_create_user_command("ZehnTageClear", zehntage_clear, {})

  -- Set up highlighting autocmds
  vim.api.nvim_create_autocmd({ "BufEnter", "TextChanged", "TextChangedI" }, {
    group = vim.api.nvim_create_augroup("ZehnTageHighlight", { clear = true }),
    pattern = { "*.md", "*.txt" },
    callback = function(ev)
      highlight_buffer(ev.buf)
    end,
  })
end

return M
```

---

## Step 9: Clean Up Template Boilerplate

- Remove `tests/` directory (no tests needed for 10-day sprint)
- Remove `.github/workflows/` CI files or leave them (harmless)
- Update `README.md` to minimal usage docs
- Remove `doc/` directory

---

## Full File Layout After Implementation

```
lua/zehntage.lua     ~180-220 lines, contains:
  - load_words() / save_words()     -- TSV storage
  - call_gemini()                   -- async HTTP via curl
  - show_float()                    -- floating window
  - zehntage() / zehntage_clear()   -- commands
  - highlight_buffer()              -- extmark-based highlighting
  - M.setup()                       -- entry point

plugin/zehntage.lua  1 line:
  require("zehntage").setup()
```

---

## Lazy.nvim Integration (user's config)

```lua
{
  "30be/zehntage",
  opts = {},
  ft = { "markdown", "text" },
  keys = {
    { "<leader>z", "<cmd>ZehnTage<CR>", desc = "ZehnTage add word" },
    { "<leader>c", "<cmd>ZehnTageClear<CR>", desc = "ZehnTage clear word" },
  },
}
```

Since `ft` triggers lazy loading, `setup()` runs only when a markdown/text file is opened. The plugin/zehntage.lua loader combined with lazy.nvim's `opts = {}` will call `require("zehntage").setup({})`.

---

## Edge Cases & Notes

1. **German compound words**: `<cword>` gets the full word under cursor, which is correct for German compounds like "Straßenbahnhaltestelle"
2. **Case handling**: All words stored and looked up as lowercase
3. **Newlines in context**: Escaped as `\n` in TSV to keep one-record-per-line
4. **No API key**: Shows error notification, no crash
5. **Gemini returns code fences**: Stripped before JSON parse
6. **Empty notes**: Gemini may return `""` for notes — handled gracefully
7. **Float on already-known word**: Shows cached translation instantly, no API call
8. **Tab characters in text**: Won't break TSV since German text rarely contains literal tabs