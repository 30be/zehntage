local M = {}

M.config = {
  provider = "claude", -- "gemini" | "groq" | "claude" | "cerebras"
  model = nil, -- optional override; each provider has its own default
  -- Second opinion from Opus through the local Claude Code CLI (`claude -p`,
  -- subscription auth). Prefetched on every lookup; Anki cards are built from
  -- it. false = fast model only.
  opus = true,
}

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

-- Model API (persistent connection) ------------------------------------------

-- One persistent HTTPS connection per host, reused across requests to avoid
-- paying a TLS handshake on every word lookup.
local proxy_script = [[
import sys, json, http.client
conns = {}
def get_conn(host):
    if host not in conns:
        conns[host] = http.client.HTTPSConnection(host)
    return conns[host]

while True:
    line = sys.stdin.readline()
    if not line:
        break
    line = line.strip()
    if not line:
        continue
    req = json.loads(line)
    host = req["host"]
    for _ in range(2):
        try:
            conn = get_conn(host)
            conn.request("POST", req["p"], req["d"].encode("utf-8"), req["h"])
            resp = conn.getresponse()
            print(json.dumps(json.loads(resp.read())), flush=True)
            break
        except Exception as e:
            err = str(e)
            conns[host] = http.client.HTTPSConnection(host)
    else:
        print(json.dumps({"error":{"message":err}}), flush=True)
]]

local proxy_job = nil
local proxy_partial = ""
local proxy_callbacks = {}

local function ensure_proxy()
  if proxy_job then
    return
  end
  proxy_job = vim.fn.jobstart({ "python3", "-c", proxy_script }, {
    stdout_buffered = false,
    on_stdout = function(_, data)
      if not data then
        return
      end
      data[1] = proxy_partial .. data[1]
      proxy_partial = data[#data]
      for i = 1, #data - 1 do
        if data[i] ~= "" and #proxy_callbacks > 0 then
          local cb = table.remove(proxy_callbacks, 1)
          local line = data[i]
          vim.schedule(function()
            cb(line)
          end)
        end
      end
    end,
    on_stderr = function(_, data)
      if data then
        local msg = table.concat(data, "\n"):gsub("^%s+", ""):gsub("%s+$", "")
        if msg ~= "" then
          vim.schedule(function()
            set_float_content(vim.split("Proxy: " .. msg, "\n"))
          end)
        end
      end
    end,
    on_exit = function()
      proxy_job = nil
      proxy_partial = ""
    end,
  })
  if proxy_job <= 0 then
    proxy_job = nil
  end
end

-- Structured-output response schemas, authored once in Gemini's uppercase-type
-- style; to_json_schema() converts them for OpenAI-compatible providers.
local WORD_SCHEMA = {
  type = "OBJECT",
  properties = {
    article = { type = "STRING" },
    translation = { type = "STRING" },
    notes = { type = "STRING" },
    context = { type = "STRING" },
  },
  required = { "article", "translation", "notes", "context" },
}

local TRANSLATE_SCHEMA = {
  type = "OBJECT",
  properties = {
    translation = { type = "STRING" },
  },
  required = { "translation" },
}

local REF_SCHEMA = {
  type = "OBJECT",
  properties = {
    translation = { type = "STRING" },
    notes = { type = "STRING" },
  },
  required = { "translation", "notes" },
}

-- Gemini schemas use uppercase types; Groq/Cerebras want lowercase strict
-- JSON Schema with every property required and additionalProperties: false.
local function to_json_schema(s)
  if type(s) ~= "table" then
    return s
  end
  local out = {}
  if s.type then
    out.type = string.lower(s.type)
  end
  if s.properties then
    out.properties = {}
    for k, v in pairs(s.properties) do
      out.properties[k] = to_json_schema(v)
    end
    out.additionalProperties = false
  end
  if s.items then
    out.items = to_json_schema(s.items)
  end
  if s.required then
    out.required = s.required
  end
  if out.properties and not out.required then
    local req = {}
    for k, _ in pairs(out.properties) do
      table.insert(req, k)
    end
    out.required = req
  end
  return out
end

local function json_system_prompt(schema)
  return "Respond with only a JSON object matching this schema, no other text: "
    .. vim.json.encode(to_json_schema(schema))
end

-- Keep only the outermost {...}, dropping code fences or chatter around it.
local function extract_json(text)
  return text and (text:match("{.*}") or text)
end

-- Provider table: each entry knows its host, default model, API key env var,
-- how to build a request for that API's shape, and how to pull the raw text
-- back out of that API's response shape.
local PROVIDERS = {
  gemini = {
    host = "generativelanguage.googleapis.com",
    default_model = "gemini-3.5-flash-lite",
    key_env = "GEMINI_API_KEY",
    path = function(model)
      return "/v1beta/models/" .. model .. ":generateContent"
    end,
    build = function(model, api_key, prompt, schema)
      local generation_config = { temperature = 0.2 }
      if schema ~= nil then
        generation_config.response_mime_type = "application/json"
        generation_config.response_schema = schema
      end
      local headers = {
        ["Content-Type"] = "application/json",
        ["x-goog-api-key"] = api_key,
      }
      local body = {
        contents = { { parts = { { text = prompt } } } },
        generation_config = generation_config,
      }
      return headers, body
    end,
    parse = function(resp)
      return resp.candidates
        and resp.candidates[1]
        and resp.candidates[1].content
        and resp.candidates[1].content.parts[1].text
    end,
  },
  groq = {
    host = "api.groq.com",
    default_model = "openai/gpt-oss-120b",
    key_env = "GROQ_API_KEY",
    path = function(_)
      return "/openai/v1/chat/completions"
    end,
    build = function(model, api_key, prompt, schema)
      local headers = {
        ["Content-Type"] = "application/json",
        ["Authorization"] = "Bearer " .. api_key,
      }
      -- gpt-oss: 120b gets a fuller reasoning pass ("high"), 20b stays fast at
      -- "low". Qwen3.6 uses a different value set ("default"/"none") for the
      -- same param, so it needs "none" explicitly or it defaults to thinking
      -- mode, which is too slow for this use case.
      local reasoning_effort
      if model:find("gpt-oss", 1, true) then
        reasoning_effort = model:find("120b", 1, true) and "high" or "low"
      else
        reasoning_effort = "none"
      end
      local body = {
        model = model,
        temperature = 0.2,
        reasoning_effort = reasoning_effort,
        stream = false,
        messages = { { role = "user", content = prompt } },
      }
      if schema ~= nil then
        body.response_format = {
          type = "json_schema",
          json_schema = { name = "result", strict = true, schema = to_json_schema(schema) },
        }
      end
      return headers, body
    end,
    parse = function(resp)
      return resp.choices and resp.choices[1] and resp.choices[1].message and resp.choices[1].message.content
    end,
  },
  claude = {
    host = "api.anthropic.com",
    default_model = "claude-haiku-5-5",
    -- A dedicated name first: a global ANTHROPIC_API_KEY would also switch the
    -- Claude Code CLI (used for Opus below) from the subscription to API billing.
    key_env = { "ZEHNTAGE_ANTHROPIC_API_KEY", "ANTHROPIC_API_KEY" },
    path = function(_)
      return "/v1/messages"
    end,
    build = function(model, api_key, prompt, schema)
      local headers = {
        ["Content-Type"] = "application/json",
        ["x-api-key"] = api_key,
        ["anthropic-version"] = "2023-06-01",
      }
      local body = {
        model = model,
        max_tokens = 4096,
        stream = false,
        messages = { { role = "user", content = prompt } },
      }
      -- Haiku 5.5 is the fast path: no thinking pass at low effort. Other
      -- models keep their default thinking, with max_tokens headroom for it.
      -- Exact ID only: Opus 5.5 rejects thinking "disabled" with a 400, so
      -- the most it can be turned down is low effort (brief thinking).
      if model == "claude-haiku-5-5" then
        body.max_tokens = 1024
        body.thinking = { type = "disabled" }
        body.output_config = { effort = "low" }
      elseif model == "claude-opus-5-5" then
        body.output_config = { effort = "low" }
      end
      if schema ~= nil then
        body.system = json_system_prompt(schema)
      end
      return headers, body
    end,
    -- The schema is only a prompt-level hint, and thinking blocks may come
    -- first, so take the text block and trim anything around the JSON.
    parse = function(resp)
      for _, block in ipairs(resp.content or {}) do
        if block.type == "text" then
          return extract_json(block.text)
        end
      end
      return nil
    end,
  },
  cerebras = {
    host = "api.cerebras.ai",
    default_model = "zai-glm-4.7",
    key_env = "CEREBRAS_API_KEY",
    path = function(_)
      return "/v1/chat/completions"
    end,
    build = function(model, api_key, prompt, schema)
      local headers = {
        ["Content-Type"] = "application/json",
        ["Authorization"] = "Bearer " .. api_key,
      }
      local body = {
        model = model,
        temperature = 0.2,
        -- GLM 4.7 non-reasoning — no thinking pass for this quick-translation use case.
        reasoning_effort = "none",
        stream = false,
        messages = { { role = "user", content = prompt } },
      }
      if schema ~= nil then
        body.response_format = {
          type = "json_schema",
          json_schema = { name = "result", strict = true, schema = to_json_schema(schema) },
        }
      end
      return headers, body
    end,
    parse = function(resp)
      return resp.choices and resp.choices[1] and resp.choices[1].message and resp.choices[1].message.content
    end,
  },
}

-- Sends prompt to the configured provider and calls callback(text) with the
-- raw response text once it arrives. schema, if given, requests structured
-- output in whatever form that provider supports.
local function call_model(prompt, callback, schema)
  local provider = PROVIDERS[M.config.provider]
  if not provider then
    set_float_content({ "Unknown provider: " .. tostring(M.config.provider) })
    return
  end

  local key_envs = type(provider.key_env) == "table" and provider.key_env or { provider.key_env }
  local api_key
  for _, name in ipairs(key_envs) do
    if vim.env[name] and vim.env[name] ~= "" then
      api_key = vim.env[name]
      break
    end
  end
  if not api_key then
    set_float_content({ key_envs[1] .. " not set" })
    return
  end

  ensure_proxy()
  if not proxy_job then
    set_float_content({ "Failed to start proxy (python3 required)" })
    return
  end

  local model = M.config.model or provider.default_model
  local headers, body = provider.build(model, api_key, prompt, schema)

  local request = vim.json.encode({
    host = provider.host,
    p = provider.path(model),
    h = headers,
    d = vim.json.encode(body),
  })

  table.insert(proxy_callbacks, function(response_line)
    local ok, resp = pcall(vim.json.decode, response_line)
    if not ok then
      set_float_content({ "Failed to parse response" })
      return
    end
    local text = provider.parse(resp)
    if not text then
      set_float_content(vim.split("Unexpected response:\n" .. response_line, "\n"))
      return
    end
    text = text:match("^%s*(.-)%s*$")
    callback(text)
  end)

  vim.fn.chansend(proxy_job, request .. "\n")
end

-- Opus via the Claude Code CLI ----------------------------------------------

-- One-shot `claude -p` run (Opus, high effort): no tools, no MCP, no settings files (hooks), no
-- saved session, started from the temp dir so no project CLAUDE.md applies.
-- callback(text, err) with the JSON text of the answer.
local function run_opus(prompt, schema, callback)
  local out = {}
  local err_out = {}
  -- env -u: an API key in the environment would bill it instead of the
  -- subscription.
  local job = vim.fn.jobstart({
    "env",
    "-u",
    "ANTHROPIC_API_KEY",
    "claude",
    "-p",
    "--model", "opus",
    "--effort", "high",
    "--tools", "",
    "--strict-mcp-config",
    "--setting-sources", "",
    "--no-session-persistence",
    "--output-format", "json",
    "--system-prompt", json_system_prompt(schema),
  }, {
    cwd = vim.uv.os_tmpdir(),
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      out = data or {}
    end,
    on_stderr = function(_, data)
      err_out = data or {}
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        local raw = table.concat(out, "\n")
        local ok, res = pcall(vim.json.decode, raw)
        if not ok or type(res) ~= "table" then
          local msg = vim.trim(table.concat(err_out, "\n") .. raw):sub(1, 200)
          callback(nil, "claude exited " .. code .. ": " .. msg)
        elseif res.is_error then
          callback(nil, tostring(res.result or "claude reported an error"))
        else
          callback(extract_json(res.result), nil)
        end
      end)
    end,
  })
  if job <= 0 then
    callback(nil, "claude CLI not found")
    return
  end
  vim.fn.chansend(job, prompt)
  vim.fn.chanclose(job, "stdin")
end

-- Opus answers by lookup key ("w:<word>" / "p:<text>"), so a prefetch and a
-- later request share one run. Failed runs are dropped, so a retry starts fresh.
local opus_cache = {}

local function opus_answer(key, prompt, schema, callback)
  local entry = opus_cache[key]
  if entry and entry.text then
    if callback then
      callback(entry.text, nil)
    end
    return
  end
  if not entry then
    entry = { waiters = {} }
    opus_cache[key] = entry
    run_opus(prompt, schema, function(text, err)
      if err then
        opus_cache[key] = nil
      else
        entry.text = text
      end
      for _, cb in ipairs(entry.waiters) do
        cb(text, err)
      end
      entry.waiters = {}
    end)
  end
  if callback then
    table.insert(entry.waiters, callback)
  end
end

-- Prompts -------------------------------------------------------------------

local function word_prompt(word, context)
  return string.format(
    'The learner is a native Russian speaker, fluent in English, learning German. They are studying the word "%s", which appeared in the text below.\n'
      .. "\n"
      .. "Provide four fields:\n"
      .. '- article: if "%s" is a German common noun, return its definite article ("der", "die", or "das"). Otherwise (verbs, adjectives, English/Russian words, anything that is not a noun) return an empty string.\n'
      .. '- translation: "%s" translated into Russian — or into English if the word is itself Russian. Expand abbreviations using the text. For Japanese words, append the pronunciation in brackets.\n'
      .. "- notes: If the studied word is a proper noun naming a real person, place, work, or brand, give a one-sentence encyclopedic abstract — who or what it is and what it is best known for (max ~30 words). Otherwise a short explanation (max ~25 words) that makes the word stick: when the translation loses nuance say what it actually means, and add a memory hook — a compound breakdown, a genuine cognate the learner already knows, a sound-alike, or a vivid image. Never leave this empty.\n"
      .. "- context: the single sentence from the text below that best shows the word in use, trimmed to just that sentence, with the studied word wrapped in <b></b>. If the text below has no usable sentence, invent a short natural one.\n"
      .. "\n"
      .. "Examples:\n"
      .. '- "vollenden" → article: "", translation: "завершить", notes: "voll (\'full\') + enden (\'to end\') — to bring something fully to its end."\n'
      .. '- "Handschuh" → article: "der", translation: "перчатка", notes: "Hand + Schuh (\'shoe\') — literally a \'shoe for the hand\'."\n'
      .. '- "Wetter" → article: "das", translation: "погода", notes: "the English cognate \'weather\' — literally the same word."\n'
      .. "\n"
      .. "Text:\n"
      .. "%s",
    word,
    word,
    word,
    context
  )
end

-- Model JSON → a card entry (as stored in `words`).
local function decode_word(word_raw, text, model)
  local ok, decoded = pcall(vim.json.decode, text)
  if not ok or type(decoded) ~= "table" then
    decoded = { translation = text }
  end
  local article = decoded.article or ""
  if article ~= "der" and article ~= "die" and article ~= "das" then
    article = ""
  end
  return {
    back = decoded.translation or "",
    notes = decoded.notes or "",
    context = decoded.context or "",
    article = article,
    front_full = (article ~= "") and (article .. " " .. word_raw) or word_raw,
    model = model,
  }
end

local function word_lines(entry)
  local lines = { entry.front_full .. " → " .. entry.back }
  if entry.notes ~= "" then
    table.insert(lines, "")
    table.insert(lines, entry.notes)
  end
  return lines
end

-- Floating window -----------------------------------------------------------

set_float_content = function(lines)
  if not float_buf or not vim.api.nvim_buf_is_valid(float_buf) then
    return
  end
  -- Buffer lines can't contain newlines; model text (notes) sometimes does.
  local flat = {}
  for _, l in ipairs(lines) do
    vim.list_extend(flat, vim.split(l, "\n"))
  end
  lines = flat
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

-- Update the float only if it is still the one identified by buf — late
-- answers must not overwrite a float opened since for something else.
local function update_float(buf, lines)
  if buf and buf == float_buf then
    set_float_content(lines)
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
  local word_raw = vim.fn.expand("<cword>")
  local word = word_raw:lower()
  if word == "" then
    return
  end

  if words[word] then
    open_float(words[word].front_full or word_raw, words[word].back, words[word].notes)
    return
  end

  local row = vim.api.nvim_win_get_cursor(0)[1]
  local line_count = vim.api.nvim_buf_line_count(0)
  local start = math.max(0, row - 2)
  local finish = math.min(line_count, row + 1)
  local context_lines = vim.api.nvim_buf_get_lines(0, start, finish, false)
  local context = table.concat(context_lines, "\n")

  local prompt = word_prompt(word_raw, context)
  if M.config.opus then
    opus_answer("w:" .. word, prompt, WORD_SCHEMA) -- prefetch for the card
  end

  -- Show float instantly with loading placeholder
  open_float(word_raw)
  local buf = float_buf

  call_model(prompt, function(text)
    local entry = decode_word(word_raw, text, "fast")
    words[word] = entry
    highlight_buffer(0)
    local lines = word_lines(entry)

    local function push(card, shown)
      if not anki_config() then
        table.insert(shown, "")
        table.insert(shown, "(Anki: ZEHNTAGE_ANKI_URL/KEY not set)")
        update_float(buf, shown)
        return
      end
      anki_request(
        "POST",
        "/zehntage/add",
        { front = card.front_full, back = card.back, notes = card.notes, context = card.context },
        function(_, err)
          if err then
            table.insert(shown, "")
            table.insert(shown, "(Anki: " .. err .. ")")
            update_float(buf, shown)
            vim.notify("ZehnTage: Anki add failed: " .. err, vim.log.levels.WARN)
          end
        end
      )
    end

    if not M.config.opus then
      update_float(buf, lines)
      push(entry, vim.deepcopy(lines))
      return
    end

    -- The card is Opus's answer; the fast one is just there to read meanwhile.
    local waiting = vim.deepcopy(lines)
    table.insert(waiting, "")
    table.insert(waiting, "(Anki: waiting for Opus…)")
    update_float(buf, waiting)
    opus_answer("w:" .. word, prompt, WORD_SCHEMA, function(opus_text, err)
      -- Cleared (or looked up anew) meanwhile → this card is no longer wanted.
      if words[word] ~= entry then
        return
      end
      local card, shown = entry, vim.deepcopy(lines)
      if opus_text then
        card = decode_word(word_raw, opus_text, "Opus")
        words[word] = card
        highlight_buffer(0)
        shown = word_lines(card)
        table.insert(shown, "")
        table.insert(shown, "(card: Opus)")
      else
        table.insert(shown, "")
        table.insert(shown, "(Opus failed: " .. err .. " — saved this answer)")
      end
      update_float(buf, shown)
      push(card, shown)
    end)
  end, WORD_SCHEMA)
end

local function zehntage_clear()
  local word = vim.fn.expand("<cword>"):lower()
  if words[word] then
    local front_to_delete = words[word].front_full or word
    words[word] = nil
    highlight_buffer(0)
    anki_request("POST", "/zehntage/delete", { front = front_to_delete }, function(_, err)
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

-- What to ask about the visual selection: the prompt, its schema, a cache
-- key, and how to turn the answer into float lines. nil for empty selection.
local function selection_request()
  local text = get_visual_selection()
  if text:match("^%s*$") then
    return nil
  end

  local word_count = select(2, text:gsub("%S+", "%0"))
  if word_count > 100 then
    local prompt = string.format(
      "Summarize the text between the === markers in Russian — or in English if the text is itself in Russian. Keep the summary concise (a few sentences, max ~60 words). Summarize only that text, nothing else.\n"
        .. "\n"
        .. "===\n"
        .. "%s\n"
        .. "===",
      text
    )
    return {
      key = "s:" .. text,
      prompt = prompt,
      schema = TRANSLATE_SCHEMA,
      render = function(response_text)
        local ok, decoded = pcall(vim.json.decode, response_text)
        if ok and type(decoded) == "table" and decoded.translation then
          return vim.split(decoded.translation, "\n")
        end
        return vim.split(response_text, "\n")
      end,
    }
  end

  -- Gather surrounding context: the selected lines plus one above and one below.
  local sr = vim.fn.getpos("v")[2]
  local er = vim.fn.getpos(".")[2]
  if vim.fn.mode():match("^[vV\22]") == nil then
    sr, er = vim.fn.getpos("'<")[2], vim.fn.getpos("'>")[2]
  end
  if er < sr then
    sr, er = er, sr
  end
  local line_count = vim.api.nvim_buf_line_count(0)
  local start = math.max(0, sr - 2)
  local finish = math.min(line_count, er + 1)
  local context_lines = vim.api.nvim_buf_get_lines(0, start, finish, false)
  local context = table.concat(context_lines, "\n")

  local prompt = string.format(
    "The reader is a native Russian speaker, fluent in English. Translate and explain the text between the === markers, which they selected while reading the context below.\n"
      .. "\n"
      .. "Provide two fields:\n"
      .. "- translation: the selected text translated into Russian — or, if the selected text is itself in Russian, into English. Render it in the OTHER language; never leave it in its original language. Expand abbreviations using the context. Translate only the text between the markers.\n"
      .. "- notes: a short note (max ~50 words) that helps the reader truly understand it. Write the note in the SAME language as the selected text — if the selected text is in Russian, the note must be in Russian; if it is in English, in English. If it contains or alludes to a literary, biblical, historical, or cultural reference, a named work or person, a joke, an allusion, an idiom, or a double meaning — explain what it refers to and, if it is used ironically or rhetorically or as a joke, what the actual point is. If it quotes or names something famous, consider whether it is commonly misattributed or whether its modern usage differs from the original meaning, and say so. If the text is plain with no such reference, briefly clarify its meaning, nuance, or tone. Never leave notes empty.\n"
      .. "\n"
      .. "Selected text:\n"
      .. "===\n"
      .. "%s\n"
      .. "===\n"
      .. "\n"
      .. "Context:\n"
      .. "%s",
    text,
    context
  )
  return {
    key = "p:" .. text,
    prompt = prompt,
    schema = REF_SCHEMA,
    render = function(response_text)
      local ok, decoded = pcall(vim.json.decode, response_text)
      local translation, notes
      if ok and type(decoded) == "table" and decoded.translation then
        translation = decoded.translation
        notes = decoded.notes or ""
      else
        translation = response_text
        notes = ""
      end
      local lines = vim.split(translation, "\n")
      if notes ~= "" then
        table.insert(lines, "")
        for _, l in ipairs(vim.split(notes, "\n")) do
          table.insert(lines, l)
        end
      end
      return lines
    end,
  }
end

local function zehntage_translate()
  local req = selection_request()
  if not req then
    return
  end
  if M.config.opus then
    opus_answer(req.key, req.prompt, req.schema) -- prefetch for <leader>zo
  end
  open_float({ "Loading..." })
  local buf = float_buf
  call_model(req.prompt, function(response_text)
    update_float(buf, req.render(response_text))
  end, req.schema)
end

-- Opus's answer for the visual selection, or for the word under the cursor.
-- Shares the cache with the prefetch from K / ZehnTageTranslate, so it is
-- usually instant.
local function zehntage_opus()
  local key, prompt, schema, render
  if vim.fn.mode():match("^[vV\22]") then
    local req = selection_request()
    if not req then
      return
    end
    key, prompt, schema, render = req.key, req.prompt, req.schema, req.render
  else
    local word_raw = vim.fn.expand("<cword>")
    if word_raw == "" then
      return
    end
    local row = vim.api.nvim_win_get_cursor(0)[1]
    local line_count = vim.api.nvim_buf_line_count(0)
    local context_lines = vim.api.nvim_buf_get_lines(0, math.max(0, row - 2), math.min(line_count, row + 1), false)
    key = "w:" .. word_raw:lower()
    prompt = word_prompt(word_raw, table.concat(context_lines, "\n"))
    schema = WORD_SCHEMA
    render = function(text)
      return word_lines(decode_word(word_raw, text, "Opus"))
    end
  end

  open_float({ "Opus…" })
  local buf = float_buf
  opus_answer(key, prompt, schema, function(text, err)
    if err then
      update_float(buf, { "Opus failed: " .. err })
      return
    end
    local lines = render(text)
    table.insert(lines, "")
    table.insert(lines, "(Opus)")
    update_float(buf, lines)
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

M.setup = function(opts)
  M.config = vim.tbl_extend("force", M.config, opts or {})
  -- Answers already come from Opus over the API: the CLI second opinion would
  -- only repeat them (and cards are built from the answer as before).
  if M.config.provider == "claude" and (M.config.model or ""):find("opus", 1, true) then
    M.config.opus = false
  end

  -- Source of truth for learned words is the Anki MCP server.
  if anki_config() then
    anki_request("GET", "/zehntage/list", nil, function(list, err)
      if err or type(list) ~= "table" then
        return
      end
      words = {}
      for _, card in ipairs(list) do
        if type(card) == "table" and card.front then
          local front = tostring(card.front)
          local article, bare = "", front
          for _, art in ipairs({ "der", "die", "das" }) do
            local rest = front:match("^" .. art .. "%s+(.+)$")
            if rest then
              article, bare = art, rest
              break
            end
          end
          words[bare:lower()] = {
            back = card.back,
            notes = card.notes,
            context = card.context,
            article = article,
            front_full = front,
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
  vim.api.nvim_create_user_command("ZehnTageOpus", zehntage_opus, { range = true })
  vim.api.nvim_create_user_command("ZehnTageNote", zehntage_note, { nargs = "+" })

  vim.api.nvim_create_autocmd("VimLeave", {
    callback = function()
      if proxy_job then
        vim.fn.jobstop(proxy_job)
      end
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
