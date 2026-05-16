local M = {}

local notes_path = vim.fn.stdpath("data") .. "/zehntage_notes.tsv"
local ns = vim.api.nvim_create_namespace("zehntage")
local words = {}
local float_win = nil
local float_buf = nil

vim.api.nvim_set_hl(0, "ZehnTageWord", { underline = true, fg = "#89b4fa" })

local set_float_content

-- Anki MCP server -----------------------------------------------------------

-- Returns base URL (without trailing /mcp or /) and key, or nil if unset.
local function anki_config()
  local url = vim.env.ZEHNTAGE_ANKI_URL
  local key = vim.env.ZEHNTAGE_ANKI_KEY
  if not url or url == "" or not key or key == "" then
    return nil
  end
  url = url:gsub("/mcp/?$", ""):gsub("/+$", "")
  return url, key
end

-- Async HTTP request to the Anki server via curl.
-- method: "GET" or "POST"; path: e.g. "/zehntage/list"; body: table or nil.
-- callback receives (decoded_json, err_string). Both nil-safe.
local function anki_request(method, path, body, callback)
  local base, key = anki_config()
  if not base then
    if callback then
      callback(nil, "ZEHNTAGE_ANKI_URL/KEY not set")
    end
    return
  end

  local args = {
    "curl",
    "-s",
    "-X",
    method,
    "-H",
    "X-Zehntage-Key: " .. key,
    base .. path,
  }
  if body ~= nil then
    table.insert(args, "-H")
    table.insert(args, "Content-Type: application/json")
    table.insert(args, "-d")
    table.insert(args, vim.json.encode(body))
  end

  local out = {}
  vim.fn.jobstart(args, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      if data then
        for _, l in ipairs(data) do
          out[#out + 1] = l
        end
      end
    end,
    on_exit = function(_, code)
      if not callback then
        return
      end
      local text = table.concat(out, "\n")
      vim.schedule(function()
        if code ~= 0 then
          callback(nil, "Anki server unreachable")
          return
        end
        local ok, decoded = pcall(vim.json.decode, text)
        if not ok then
          callback(nil, "Anki server: bad response")
          return
        end
        callback(decoded, nil)
      end)
    end,
  })
end

-- Gemini API (persistent connection) ----------------------------------------

local proxy_script = [[
import sys, json, http.client
conn = http.client.HTTPSConnection("generativelanguage.googleapis.com")
while True:
    line = sys.stdin.readline()
    if not line:
        break
    line = line.strip()
    if not line:
        continue
    req = json.loads(line)
    for _ in range(2):
        try:
            conn.request("POST", req["p"], req["d"].encode("utf-8"), req["h"])
            resp = conn.getresponse()
            print(json.dumps(json.loads(resp.read())), flush=True)
            break
        except Exception as e:
            err = str(e)
            conn = http.client.HTTPSConnection("generativelanguage.googleapis.com")
    else:
        print(json.dumps({"error":{"message":err}}), flush=True)
]]

local proxy_job = nil
local proxy_partial = ""
local proxy_callbacks = {}

local function ensure_proxy()
  if proxy_job then return end
  proxy_job = vim.fn.jobstart({ "python3", "-c", proxy_script }, {
    stdout_buffered = false,
    on_stdout = function(_, data)
      if not data then return end
      data[1] = proxy_partial .. data[1]
      proxy_partial = data[#data]
      for i = 1, #data - 1 do
        if data[i] ~= "" and #proxy_callbacks > 0 then
          local cb = table.remove(proxy_callbacks, 1)
          local line = data[i]
          vim.schedule(function() cb(line) end)
        end
      end
    end,
    on_stderr = function(_, data)
      if data then
        local msg = table.concat(data, "\n"):gsub("^%s+", ""):gsub("%s+$", "")
        if msg ~= "" then
          vim.schedule(function() set_float_content(vim.split("Proxy: " .. msg, "\n")) end)
        end
      end
    end,
    on_exit = function()
      proxy_job = nil
      proxy_partial = ""
    end,
  })
  if proxy_job <= 0 then proxy_job = nil end
end

-- Gemini structured-output response schemas.
local WORD_SCHEMA = {
  type = "OBJECT",
  properties = {
    translation = { type = "STRING" },
    notes = { type = "STRING" },
    context = { type = "STRING" },
  },
  required = { "translation", "notes", "context" },
}

local TRANSLATE_SCHEMA = {
  type = "OBJECT",
  properties = {
    translation = { type = "STRING" },
  },
  required = { "translation" },
}

local function call_gemini_api(prompt, callback, schema)
  local api_key = vim.env.GEMINI_API_KEY
  if not api_key or api_key == "" then
    set_float_content({ "GEMINI_API_KEY not set" })
    return
  end

  ensure_proxy()
  if not proxy_job then
    set_float_content({ "Failed to start proxy (python3 required)" })
    return
  end

  local model = vim.env.ZEHNTAGE_MODEL or "gemini-3.1-flash-lite"
  local generation_config = { temperature = 0.2 }
  if schema ~= nil then
    generation_config.response_mime_type = "application/json"
    generation_config.response_schema = schema
  end
  local body = vim.json.encode({
    contents = { { parts = { { text = prompt } } } },
    generation_config = generation_config,
  })

  local request = vim.json.encode({
    p = "/v1beta/models/" .. model .. ":generateContent",
    h = {
      ["Content-Type"] = "application/json",
      ["x-goog-api-key"] = api_key,
    },
    d = body,
  })

  table.insert(proxy_callbacks, function(response_line)
    local ok, resp = pcall(vim.json.decode, response_line)
    if not ok then
      set_float_content({ "Failed to parse response" })
      return
    end
    local text = resp.candidates and resp.candidates[1]
      and resp.candidates[1].content.parts[1].text
    if not text then
      set_float_content(vim.split("Unexpected response:\n" .. response_line, "\n"))
      return
    end
    text = text:match("^%s*(.-)%s*$")
    callback(text)
  end)

  vim.fn.chansend(proxy_job, request .. "\n")
end

local function call_gemini(word, context, callback)
  local prompt = string.format(
    'The learner is a native Russian speaker, fluent in English, learning German. They are studying the word "%s", which appeared in the text below.\n'
      .. "\n"
      .. "Provide three fields:\n"
      .. '- translation: "%s" translated into Russian — or into English if the word is itself Russian. Expand abbreviations using the text. For Japanese words, append the pronunciation in brackets.\n'
      .. "- notes: a short explanation, max ~25 words, that makes the word stick. When the translation alone loses nuance, say what the word actually means; always add a memory hook — a compound breakdown, a genuine cognate the learner already knows, a sound-alike, or a vivid image. Never leave this empty.\n"
      .. "- context: the single sentence from the text below that best shows the word in use, trimmed to just that sentence, with the studied word wrapped in <b></b>. If the text below has no usable sentence, invent a short natural one.\n"
      .. "\n"
      .. "Examples (word → translation: notes):\n"
      .. "- vollenden → завершить: voll ('full') + enden ('to end') — to bring something fully to its end.\n"
      .. "- Feierabend → конец рабочего дня: Feier ('celebration') + Abend ('evening') — not just quitting time, but the relaxed free evening after work.\n"
      .. "- Wetter → погода: the English cognate 'weather' — literally the same word.\n"
      .. "\n"
      .. "Text:\n"
      .. "%s",
    word,
    word,
    context
  )
  call_gemini_api(prompt, function(text)
    local ok, decoded = pcall(vim.json.decode, text)
    if not ok or type(decoded) ~= "table" then
      callback(text, "", "")
      return
    end
    callback(decoded.translation or "", decoded.notes or "", decoded.context or "")
  end, WORD_SCHEMA)
end

-- Floating window -----------------------------------------------------------

set_float_content = function(lines)
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

  call_gemini(word, context, function(translation, notes, model_context)
    words[word] = { back = translation, notes = notes, context = model_context }
    highlight_buffer(0)

    -- Update float in-place if still open
    local lines = { word .. " → " .. translation }
    if notes ~= "" then
      table.insert(lines, "")
      table.insert(lines, notes)
    end
    set_float_content(lines)

    -- Push the card to the Anki server (auto-push)
    if anki_config() then
      anki_request(
        "POST",
        "/zehntage/add",
        { front = word, back = translation, notes = notes, context = model_context },
        function(_, err)
          if err then
            local l = vim.deepcopy(lines)
            table.insert(l, "")
            table.insert(l, "(Anki: " .. err .. ")")
            set_float_content(l)
          end
        end
      )
    else
      local l = vim.deepcopy(lines)
      table.insert(l, "")
      table.insert(l, "(Anki: ZEHNTAGE_ANKI_URL/KEY not set)")
      set_float_content(l)
    end
  end)
end

local function zehntage_clear()
  local word = vim.fn.expand("<cword>"):lower()
  if words[word] then
    words[word] = nil
    highlight_buffer(0)
    anki_request("POST", "/zehntage/delete", { front = word }, function(_, err)
      if err then
        vim.notify("ZehnTage: Anki delete failed: " .. err, vim.log.levels.WARN)
      end
    end)
  end
end

local function get_visual_selection()
  -- Use current visual positions (v/., not '</'>) so marks are fresh
  local start_pos = vim.fn.getpos("v")
  local end_pos = vim.fn.getpos(".")
  local mode = vim.fn.mode()
  local ok, region = pcall(vim.fn.getregion, start_pos, end_pos, { type = mode })
  if ok and #region > 0 then
    return table.concat(region, "\n")
  end
  -- Fallback: exit visual mode first to update '< '>
  vim.cmd("normal! " .. vim.api.nvim_replace_termcodes("<Esc>", true, false, true))
  start_pos = vim.fn.getpos("'<")
  end_pos = vim.fn.getpos("'>")
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
    "Translate the text between the === markers into Russian — or into English if it is already Russian. Expand abbreviations using the surrounding words. Translate only that text, nothing else.\n"
      .. "\n"
      .. "===\n"
      .. "%s\n"
      .. "===",
    text
  )
  call_gemini_api(prompt, function(response_text)
    local ok, decoded = pcall(vim.json.decode, response_text)
    local translation
    if ok and type(decoded) == "table" and decoded.translation then
      translation = decoded.translation
    else
      translation = response_text
    end
    set_float_content(vim.split(translation, "\n"))
  end, TRANSLATE_SCHEMA)
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
  -- Source of truth for learned words is the Anki MCP server.
  if anki_config() then
    anki_request("GET", "/zehntage/list", nil, function(list, err)
      if err or type(list) ~= "table" then
        return
      end
      words = {}
      for _, card in ipairs(list) do
        if type(card) == "table" and card.front then
          words[tostring(card.front):lower()] = {
            back = card.back,
            notes = card.notes,
            context = card.context,
          }
        end
      end
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        highlight_buffer(vim.api.nvim_win_get_buf(win))
      end
    end)
  end

  vim.api.nvim_create_user_command("ZehnTage", zehntage, {})
  vim.api.nvim_create_user_command("ZehnTageClear", zehntage_clear, {})
  vim.api.nvim_create_user_command("ZehnTageTranslate", zehntage_translate, { range = true })
  vim.api.nvim_create_user_command("ZehnTageNote", zehntage_note, { nargs = "+" })

  vim.api.nvim_create_autocmd("VimLeave", {
    callback = function()
      if proxy_job then vim.fn.jobstop(proxy_job) end
    end,
  })

  vim.api.nvim_create_autocmd({ "BufEnter", "TextChanged", "TextChangedI" }, {
    group = vim.api.nvim_create_augroup("ZehnTageHighlight", { clear = true }),
    -- pattern = { "*.md", "*.txt" },
    callback = function(ev)
      highlight_buffer(ev.buf)
    end,
  })
end

return M
