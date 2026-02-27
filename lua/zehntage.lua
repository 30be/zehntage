local M = {}

local tsv_path = vim.fn.stdpath("data") .. "/zehntage_words.tsv"
local ns = vim.api.nvim_create_namespace("zehntage")
local words = {}
local float_win = nil

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
      local front, back, context, notes = line:match("^(.-)\t(.-)\t(.-)\t(.*)$")
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
  f:write("front\tback\tcontext\tnotes\n")
  for front, data in pairs(words) do
    local ctx = data.context:gsub("\n", "\\n")
    local notes = (data.notes or ""):gsub("\n", "\\n")
    f:write(front .. "\t" .. data.back .. "\t" .. ctx .. "\t" .. notes .. "\n")
  end
  f:close()
end

-- Gemini API ----------------------------------------------------------------

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
    "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent",
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

-- Floating window -----------------------------------------------------------

local function show_float(word, translation, notes)
  if float_win and vim.api.nvim_win_is_valid(float_win) then
    vim.api.nvim_set_current_win(float_win)
    return
  end

  local lines = { word .. " → " .. translation }
  if notes and notes ~= "" then
    table.insert(lines, "")
    table.insert(lines, notes)
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_add_highlight(buf, -1, "Bold", 0, 0, #word)

  local width = 0
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end

  float_win = vim.api.nvim_open_win(buf, false, {
    relative = "cursor",
    row = 1,
    col = 0,
    width = math.min(width + 2, 60),
    height = #lines,
    style = "minimal",
    border = "rounded",
  })

  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = 0,
    once = true,
    callback = function()
      if float_win and vim.api.nvim_win_is_valid(float_win) then
        vim.api.nvim_win_close(float_win, true)
      end
      float_win = nil
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
    show_float(word, words[word].back, words[word].notes)
    return
  end

  local row = vim.api.nvim_win_get_cursor(0)[1]
  local line_count = vim.api.nvim_buf_line_count(0)
  local start = math.max(0, row - 2)
  local finish = math.min(line_count, row + 1)
  local context_lines = vim.api.nvim_buf_get_lines(0, start, finish, false)
  local context = table.concat(context_lines, "\n")

  vim.notify("Translating '" .. word .. "'...", vim.log.levels.INFO)

  call_gemini(word, context, function(data)
    words[word] = {
      back = data.translation or "",
      context = context,
      notes = data.notes or "",
    }
    save_words()
    highlight_buffer(0)
    show_float(word, data.translation or "", data.notes or "")
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

-- Setup ---------------------------------------------------------------------

M.setup = function()
  load_words()

  vim.api.nvim_create_user_command("ZehnTage", zehntage, {})
  vim.api.nvim_create_user_command("ZehnTageClear", zehntage_clear, {})

  vim.api.nvim_create_autocmd({ "BufEnter", "TextChanged", "TextChangedI" }, {
    group = vim.api.nvim_create_augroup("ZehnTageHighlight", { clear = true }),
    pattern = { "*.md", "*.txt" },
    callback = function(ev)
      highlight_buffer(ev.buf)
    end,
  })
end

return M
