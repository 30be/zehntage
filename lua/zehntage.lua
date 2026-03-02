local M = {}

local tsv_path = vim.fn.stdpath("data") .. "/zehntage_words.tsv"
local notes_path = vim.fn.stdpath("data") .. "/zehntage_notes.tsv"
local ns = vim.api.nvim_create_namespace("zehntage")
local words = {}
local float_win = nil
local float_buf = nil

vim.api.nvim_set_hl(0, "ZehnTageWord", { underline = true, fg = "#89b4fa" })

-- Storage -------------------------------------------------------------------

local function load_words()
  words = {}
  local f = io.open(tsv_path, "r")
  if not f then
    return
  end
  local first = true
  for line in f:lines() do
    if first then
      first = false
    else
      local front, back, notes, context = line:match("^(.-)|(.-)|(.-)|(.*)$")
      if front then
        words[front:lower()] = { back = back, context = context, notes = notes }
      end
    end
  end
  f:close()
end

local function save_words()
  local f = io.open(tsv_path, "w")
  if not f then
    return
  end
  f:write("front|back|notes|context\n")
  for front, data in pairs(words) do
    local ctx = data.context:gsub("\n", " ")
    -- Bold the learned word in context (case-insensitive)
    local pattern = "(%f[%w])(" .. front:gsub("%a", function(c)
      return "[" .. c:upper() .. c:lower() .. "]"
    end) .. ")(%f[%W])"
    ctx = ctx:gsub(pattern, "%1<b>%2</b>%3")
    local notes = (data.notes or ""):gsub("\n", " ")
    f:write(front .. "|" .. data.back .. "|" .. notes .. "|" .. ctx .. "\n")
  end
  f:close()
end

-- Gemini API ----------------------------------------------------------------

local function call_gemini_api(prompt, callback)
  local api_key = vim.env.GEMINI_API_KEY
  if not api_key or api_key == "" then
    vim.notify("GEMINI_API_KEY not set", vim.log.levels.ERROR)
    return
  end

  local body = vim.json.encode({
    contents = { { parts = { { text = prompt } } } },
    generation_config = { temperature = 0.2 },
  })

  vim.system({
    "curl",
    "-s",
    "-X",
    "POST",
    "-H",
    "Content-Type: application/json",
    "-H",
    "x-goog-api-key: " .. api_key,
    "-d",
    body,
    "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash-lite:generateContent",
  }, {}, function(result)
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
      local text = resp.candidates and resp.candidates[1] and resp.candidates[1].content.parts[1].text
      if not text then
        vim.notify("Unexpected Gemini response format", vim.log.levels.ERROR)
        return
      end
      text = text:gsub("^```json%s*", ""):gsub("```%s*$", ""):match("^%s*(.-)%s*$")
      local ok2, data = pcall(vim.json.decode, text)
      if ok2 then
        callback(data)
      else
        vim.notify("Gemini returned invalid JSON: " .. text, vim.log.levels.ERROR)
      end
    end)
  end)
end

local function call_gemini(word, context, callback)
  local prompt = string.format(
    'Translate the word "%s" to English using context below. '
      .. "Notes: max 15 words. Only something that helps memorize: etymology, word roots, word structure, or a fun fact. "
      .. "No grammar info, no tense, no repeating context. Empty string if nothing useful. "
      .. "Examples:\n"
      .. '- Kutsche→carriage: "From Hungarian kocsi, named after the town Kocs"\n'
      .. '- Schmetterling→butterfly: "From Schmetten (cream) — butterflies were thought to steal milk"\n'
      .. '- Angst→fear: "Same word borrowed into English as-is"\n'
      .. '- Zeitgeist→spirit of the time: ""\n'
      .. 'Return ONLY valid JSON: {"translation":"...","notes":"..."}\n\nContext:\n%s',
    word,
    context
  )
  call_gemini_api(prompt, callback)
end

-- Floating window -----------------------------------------------------------

local function set_float_content(lines)
  if not float_buf or not vim.api.nvim_buf_is_valid(float_buf) then
    return
  end
  vim.api.nvim_buf_set_lines(float_buf, 0, -1, false, lines)

  local max_width = 60
  local width = 0
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  width = math.min(width + 2, max_width)

  local height = 0
  for _, l in ipairs(lines) do
    local w = vim.fn.strdisplaywidth(l)
    height = height + math.max(1, math.ceil(w / width))
  end

  if float_win and vim.api.nvim_win_is_valid(float_win) then
    vim.api.nvim_win_set_config(float_win, { width = width, height = height })
  end
end

local function open_float(word, translation, notes)
  if float_win and vim.api.nvim_win_is_valid(float_win) then
    vim.api.nvim_set_current_win(float_win)
    return
  end

  local lines
  local highlight_len = 0
  if type(word) == "table" then
    lines = word
  elseif translation then
    lines = { word .. " → " .. translation }
    highlight_len = #word
    if notes and notes ~= "" then
      table.insert(lines, "")
      table.insert(lines, notes)
    end
  else
    lines = { word .. " → ..." }
    highlight_len = #word
  end

  float_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(float_buf, 0, -1, false, lines)
  if highlight_len > 0 then
    vim.api.nvim_buf_add_highlight(float_buf, -1, "Bold", 0, 0, highlight_len)
  end

  local max_width = 60
  local width = 0
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  width = math.min(width + 2, max_width)

  local height = 0
  for _, l in ipairs(lines) do
    local w = vim.fn.strdisplaywidth(l)
    height = height + math.max(1, math.ceil(w / width))
  end

  float_win = vim.api.nvim_open_win(float_buf, false, {
    relative = "cursor",
    row = 1,
    col = 0,
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
  })
  vim.wo[float_win].wrap = true
  vim.wo[float_win].linebreak = true

  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = 0,
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

-- Highlighting --------------------------------------------------------------

local function highlight_buffer(bufnr)
  bufnr = (bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

  if vim.tbl_isempty(words) then
    return
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for i, line in ipairs(lines) do
    local lower_line = line:lower()
    for word, _ in pairs(words) do
      local start = 1
      while true do
        local s, e = lower_line:find(word, start, true)
        if not s then
          break
        end
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

-- Commands ------------------------------------------------------------------

local function zehntage()
  local word = vim.fn.expand("<cword>"):lower()
  if word == "" then
    return
  end

  if words[word] then
    open_float(word, words[word].back, words[word].notes)
    return
  end

  local row = vim.api.nvim_win_get_cursor(0)[1]
  local line_count = vim.api.nvim_buf_line_count(0)
  local start = math.max(0, row - 2)
  local finish = math.min(line_count, row + 1)
  local context_lines = vim.api.nvim_buf_get_lines(0, start, finish, false)
  local context = table.concat(context_lines, "\n")

  -- Show float instantly with loading placeholder
  open_float(word)

  call_gemini(word, context, function(data)
    local translation = data.translation or ""
    local notes = data.notes or ""
    words[word] = { back = translation, context = context, notes = notes }
    save_words()
    highlight_buffer(0)

    -- Update float in-place if still open
    local lines = { word .. " → " .. translation }
    if notes ~= "" then
      table.insert(lines, "")
      table.insert(lines, notes)
    end
    set_float_content(lines)
  end)
end

local function zehntage_clear()
  local word = vim.fn.expand("<cword>"):lower()
  if words[word] then
    words[word] = nil
    save_words()
    highlight_buffer(0)
  end
end

local function get_visual_selection()
  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")
  local mode = vim.fn.visualmode()
  local ok, region = pcall(vim.fn.getregion, start_pos, end_pos, { type = mode })
  if ok and #region > 0 then
    return table.concat(region, "\n")
  end
  -- Fallback for older Neovim
  local sr, sc = start_pos[2], start_pos[3]
  local er, ec = end_pos[2], end_pos[3]
  local buf_lines = vim.api.nvim_buf_get_lines(0, sr - 1, er, false)
  if #buf_lines == 0 then
    return ""
  end
  if #buf_lines == 1 then
    buf_lines[1] = buf_lines[1]:sub(sc, ec)
  else
    buf_lines[1] = buf_lines[1]:sub(sc)
    buf_lines[#buf_lines] = buf_lines[#buf_lines]:sub(1, ec)
  end
  return table.concat(buf_lines, "\n")
end

local function zehntage_translate()
  local text = get_visual_selection()
  if text:match("^%s*$") then
    return
  end

  open_float({ "Loading..." })

  local prompt = string.format(
    "You are a translator. Your ONLY job is to translate the exact text between the delimiters below to English. "
      .. "Do NOT paraphrase, summarize, or translate any other text. "
      .. 'Return ONLY valid JSON: {"translation":"..."}\n\n'
      .. "===BEGIN===\n%s\n===END===",
    text
  )
  call_gemini_api(prompt, function(data)
    local translation = data.translation or ""
    set_float_content({ translation })
  end)
end

local function zehntage_note(opts)
  local text = opts.args
  if text:match("^%s*$") then
    vim.notify("Usage: :ZehnTageNote <text>", vim.log.levels.WARN)
    return
  end
  local filename = vim.fn.expand("%:p")
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local f = io.open(notes_path, "a")
  if not f then
    vim.notify("Cannot write to " .. notes_path, vim.log.levels.ERROR)
    return
  end
  f:write(filename .. "\t" .. line .. "\t" .. text .. "\n")
  f:close()
  vim.notify("Note saved", vim.log.levels.INFO)
end

-- Setup ---------------------------------------------------------------------

M.setup = function()
  load_words()

  vim.api.nvim_create_user_command("ZehnTage", zehntage, {})
  vim.api.nvim_create_user_command("ZehnTageClear", zehntage_clear, {})
  vim.api.nvim_create_user_command("ZehnTageTranslate", zehntage_translate, { range = true })
  vim.api.nvim_create_user_command("ZehnTageNote", zehntage_note, { nargs = "+" })

  vim.api.nvim_create_autocmd({ "BufEnter", "TextChanged", "TextChangedI" }, {
    group = vim.api.nvim_create_augroup("ZehnTageHighlight", { clear = true }),
    -- pattern = { "*.md", "*.txt" },
    callback = function(ev)
      highlight_buffer(ev.buf)
    end,
  })
end

return M
