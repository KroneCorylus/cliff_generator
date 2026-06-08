--[[ server.lua — Lua HTTP backend for the Stepped Mountain website.

  POST /generate   body = settings JSON (same shape as "Export settings")
                   -> JSON { R, nSteps, rawField, shapedField, stepGrid, cleanGrid, cliffs }
  GET  /health     -> "ok"
  OPTIONS *        -> CORS preflight

  All generation runs through generate_cliffs.lua, so the website and the engine
  share one implementation. Requires LuaSocket (`require "socket"`).

  Run:   lua server.lua [port]          (default port 8770)
]]

local socket = require("socket")

-- Load the generator without triggering its standalone demo (`if arg then ...`).
local here = (arg and arg[0] and arg[0]:match("^(.*)[/\\]")) or "."
local saved_arg = arg
_G.arg = nil
local M = dofile(here .. "/generate_cliffs.lua")
_G.arg = saved_arg

local PORT = tonumber(arg and arg[1]) or 8770

-- ---------------------------------------------------------------- JSON encode
local function encode(v, buf)
  if v == M.NULL then
    buf[#buf + 1] = "null"
  else
    local t = type(v)
    if t == "number" then
      buf[#buf + 1] = (math.type(v) == "integer") and string.format("%d", v) or string.format("%.6g", v)
    elseif t == "boolean" then
      buf[#buf + 1] = v and "true" or "false"
    elseif t == "string" then
      buf[#buf + 1] = '"' .. v:gsub('[\\"]', "\\%0") .. '"'
    elseif t == "table" then
      if v[1] ~= nil then                       -- dense array
        buf[#buf + 1] = "["
        for i = 1, #v do if i > 1 then buf[#buf + 1] = "," end encode(v[i], buf) end
        buf[#buf + 1] = "]"
      else                                       -- object
        buf[#buf + 1] = "{"
        local first = true
        for k, val in pairs(v) do
          if not first then buf[#buf + 1] = "," end
          first = false
          buf[#buf + 1] = '"' .. tostring(k) .. '":'
          encode(val, buf)
        end
        buf[#buf + 1] = "}"
      end
    else
      buf[#buf + 1] = "null"
    end
  end
end
local function json_encode(v) local b = {}; encode(v, b); return table.concat(b) end

-- ---------------------------------------------------------------- JSON decode
local function json_decode(s)
  local pos = 1
  local parseValue
  local function ws() local _, e = s:find("^[ \t\r\n]*", pos); pos = e + 1 end
  local function parseString()
    pos = pos + 1                                -- skip opening quote
    local buf = {}
    while true do
      local c = s:sub(pos, pos)
      if c == "" then error("unterminated string") end
      if c == '"' then pos = pos + 1; break end
      if c == "\\" then
        local n = s:sub(pos + 1, pos + 1)
        local map = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }
        if n == "u" then buf[#buf + 1] = utf8.char(tonumber(s:sub(pos + 2, pos + 5), 16)); pos = pos + 6
        else buf[#buf + 1] = map[n] or n; pos = pos + 2 end
      else buf[#buf + 1] = c; pos = pos + 1 end
    end
    return table.concat(buf)
  end
  parseValue = function()
    ws()
    local c = s:sub(pos, pos)
    if c == "{" then
      pos = pos + 1; local o = {}; ws()
      if s:sub(pos, pos) == "}" then pos = pos + 1; return o end
      while true do
        ws(); local k = parseString(); ws()
        pos = pos + 1                            -- skip ':'
        o[k] = parseValue(); ws()
        local d = s:sub(pos, pos); pos = pos + 1
        if d == "}" then break elseif d ~= "," then error("expected , or }") end
      end
      return o
    elseif c == "[" then
      pos = pos + 1; local a = {}; ws()
      if s:sub(pos, pos) == "]" then pos = pos + 1; return a end
      while true do
        a[#a + 1] = parseValue(); ws()
        local d = s:sub(pos, pos); pos = pos + 1
        if d == "]" then break elseif d ~= "," then error("expected , or ]") end
      end
      return a
    elseif c == '"' then
      return parseString()
    elseif s:sub(pos, pos + 3) == "true" then pos = pos + 4; return true
    elseif s:sub(pos, pos + 4) == "false" then pos = pos + 5; return false
    elseif s:sub(pos, pos + 3) == "null" then pos = pos + 4; return nil
    else
      local num = s:match("^%-?%d+%.?%d*[eE]?[%+%-]?%d*", pos)
      if not num or num == "" then error("unexpected char at " .. pos) end
      pos = pos + #num
      return tonumber(num)
    end
  end
  return parseValue()
end

-- ---------------------------------------------------------------- routing
local CORS = "Access-Control-Allow-Origin: *\r\n" ..
  "Access-Control-Allow-Methods: POST, GET, OPTIONS\r\n" ..
  "Access-Control-Allow-Headers: Content-Type\r\n"

local function route(method, path, body)
  if method == "OPTIONS" then return "204 No Content", "text/plain", "" end
  if method == "GET" and path == "/health" then return "200 OK", "text/plain", "ok" end
  if method == "POST" and path == "/generate" then
    local ok, cfg = pcall(json_decode, body)
    if not ok or type(cfg) ~= "table" then return "400 Bad Request", "text/plain", "bad json: " .. tostring(cfg) end
    local t0 = socket.gettime()
    local ok2, result, timings = pcall(M.pipeline, cfg, socket.gettime)
    local genMs = (socket.gettime() - t0) * 1000
    if not ok2 then
      print(("generate FAILED (%s): %s"):format(cfg.mode or "?", tostring(result)))
      return "500 Internal Server Error", "text/plain", tostring(result)
    end
    local te = socket.gettime()
    local payload = json_encode(result)
    local encMs = (socket.gettime() - te) * 1000
    print(("generated %dx%d  %s/%s  %d steps  total %.1f ms  ["
        .. "raw %.1f | shaped %.1f | quantize %.1f | clean %.1f | trace %.1f | format %.1f]"
        .. "  json-encode %.1f ms (%.0f KB)"):format(
      result.R, result.R, tostring(cfg.algo), tostring(cfg.mode or "single"), result.nSteps, genMs,
      timings.rawField, timings.shapedField, timings.quantize, timings.clean, timings.trace, timings.format,
      encMs, #payload / 1024))
    return "200 OK", "application/json", payload
  end
  return "404 Not Found", "text/plain", "not found"
end

-- ---------------------------------------------------------------- HTTP loop
local server = assert(socket.bind("0.0.0.0", PORT))
print(("Lua cliff backend listening on http://localhost:%d  (POST /generate)"):format(PORT))

while true do
  local client = server:accept()
  client:settimeout(10)
  local reqline = client:receive("*l")
  if reqline then
    local method, path = reqline:match("^(%S+)%s+(%S+)")
    local headers = {}
    while true do
      local line = client:receive("*l")
      if not line or line == "" then break end
      local k, val = line:match("^(.-):%s*(.*)$")
      if k then headers[k:lower()] = val end
    end
    local body = ""
    local clen = tonumber(headers["content-length"] or "0")
    if clen and clen > 0 then body = client:receive(clen) or "" end

    local ok, status, ctype, payload = pcall(route, method or "", path or "", body)
    if not ok then status, ctype, payload = "500 Internal Server Error", "text/plain", tostring(status) end
    local resp = ("HTTP/1.1 %s\r\n%sContent-Type: %s\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s")
      :format(status, CORS, ctype, #payload, payload)
    client:send(resp)
  end
  client:close()
end
