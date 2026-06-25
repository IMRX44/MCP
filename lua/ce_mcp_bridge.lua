--[[ ============================================================================
  CE-MCP Bridge  —  Cheat Engine side HTTP server
  ----------------------------------------------------------------------------
  Exposes Cheat Engine's full automation surface over a tiny localhost HTTP/JSON
  API so an external MCP server (Python) can drive it on behalf of an AI agent.

  USAGE
    1. Open Cheat Engine.
    2. Table menu  ->  "Cheat Table Lua Script"  (Ctrl+Alt+L)  -> paste this file
       OR  File -> "Load Script" and select this file, then click Execute.
    3. The bridge starts an HTTP listener on 127.0.0.1:37712.
    4. Start the Python MCP server (it talks to this bridge).

  SECURITY
    Binds to loopback only. No auth — anything that can reach localhost:37712 can
    drive Cheat Engine. Treat it like a debugger you opened yourself.

  Protocol: HTTP/1.1, JSON request body, JSON response { ok, data | error }.
============================================================================ ]]--

local PORT  = 37712
local HOST  = "127.0.0.1"
local TICK  = 5          -- ms timer interval for the accept loop

----------------------------------------------------------------------------
-- Logging
----------------------------------------------------------------------------
local function log(msg) print(("[CE-MCP] %s"):format(tostring(msg))) end

----------------------------------------------------------------------------
-- JSON encoder
----------------------------------------------------------------------------
local json = {}

local ESCAPES = {
  ['"']='\\"', ['\\']='\\\\', ['\b']='\\b', ['\f']='\\f',
  ['\n']='\\n', ['\r']='\\r', ['\t']='\\t',
}

local function esc_str(s)
  return '"' .. s:gsub('[%z\1-\31\\"]', function(c)
    return ESCAPES[c] or ('\\u%04x'):format(c:byte())
  end) .. '"'
end

local function is_array(t)
  local n = 0
  for k in pairs(t) do
    if type(k) ~= "number" or k % 1 ~= 0 or k < 1 then return false end
    if k > n then n = k end
  end
  return n == #t, n
end

function json.encode(v)
  local t = type(v)
  if v == nil then return "null"
  elseif t == "boolean" then return v and "true" or "false"
  elseif t == "number" then
    if v ~= v or v == math.huge or v == -math.huge then return "null" end
    if v % 1 == 0 and math.abs(v) < 2^53 then return ("%d"):format(v) end
    return ("%.17g"):format(v)
  elseif t == "string" then return esc_str(v)
  elseif t == "table" then
    local arr, n = is_array(v)
    if arr then
      if n == 0 then return "[]" end
      local out = {}
      for i = 1, n do out[i] = json.encode(v[i]) end
      return "[" .. table.concat(out, ",") .. "]"
    else
      local out = {}
      for k, val in pairs(v) do
        out[#out + 1] = esc_str(tostring(k)) .. ":" .. json.encode(val)
      end
      return "{" .. table.concat(out, ",") .. "}"
    end
  end
  return "null"
end

----------------------------------------------------------------------------
-- JSON decoder (recursive descent, full spec)
----------------------------------------------------------------------------
local function json_decode(str)
  local pos = 1
  local len = #str

  local parse_value  -- forward decl

  local function skip_ws()
    while pos <= len do
      local c = str:byte(pos)
      if c == 32 or c == 9 or c == 10 or c == 13 then pos = pos + 1 else break end
    end
  end

  local function parse_string()
    pos = pos + 1 -- skip opening quote
    local buf = {}
    while pos <= len do
      local c = str:sub(pos, pos)
      if c == '"' then pos = pos + 1; return table.concat(buf)
      elseif c == '\\' then
        local n = str:sub(pos + 1, pos + 1)
        if     n == 'n' then buf[#buf+1] = '\n'
        elseif n == 't' then buf[#buf+1] = '\t'
        elseif n == 'r' then buf[#buf+1] = '\r'
        elseif n == 'b' then buf[#buf+1] = '\b'
        elseif n == 'f' then buf[#buf+1] = '\f'
        elseif n == '/' then buf[#buf+1] = '/'
        elseif n == '"' then buf[#buf+1] = '"'
        elseif n == '\\' then buf[#buf+1] = '\\'
        elseif n == 'u' then
          local hex = str:sub(pos + 2, pos + 5)
          local cp = tonumber(hex, 16) or 0
          -- minimal UTF-8 encode (BMP)
          if cp < 0x80 then buf[#buf+1] = string.char(cp)
          elseif cp < 0x800 then
            buf[#buf+1] = string.char(0xC0 + math.floor(cp/0x40), 0x80 + cp%0x40)
          else
            buf[#buf+1] = string.char(0xE0 + math.floor(cp/0x1000),
              0x80 + math.floor(cp/0x40)%0x40, 0x80 + cp%0x40)
          end
          pos = pos + 4
        else buf[#buf+1] = n end
        pos = pos + 2
      else buf[#buf+1] = c; pos = pos + 1 end
    end
    error("unterminated string")
  end

  local function parse_number()
    local start = pos
    while pos <= len do
      local c = str:byte(pos)
      -- 0-9, -, +, ., e, E
      if (c >= 48 and c <= 57) or c == 45 or c == 43 or c == 46
         or c == 101 or c == 69 then pos = pos + 1 else break end
    end
    return tonumber(str:sub(start, pos - 1))
  end

  local function parse_array()
    pos = pos + 1 -- skip [
    local arr = {}
    skip_ws()
    if str:sub(pos, pos) == ']' then pos = pos + 1; return arr end
    while true do
      arr[#arr + 1] = parse_value()
      skip_ws()
      local c = str:sub(pos, pos)
      if c == ',' then pos = pos + 1; skip_ws()
      elseif c == ']' then pos = pos + 1; return arr
      else error("expected , or ] in array") end
    end
  end

  local function parse_object()
    pos = pos + 1 -- skip {
    local obj = {}
    skip_ws()
    if str:sub(pos, pos) == '}' then pos = pos + 1; return obj end
    while true do
      skip_ws()
      if str:sub(pos, pos) ~= '"' then error("expected string key") end
      local key = parse_string()
      skip_ws()
      if str:sub(pos, pos) ~= ':' then error("expected :") end
      pos = pos + 1
      skip_ws()
      obj[key] = parse_value()
      skip_ws()
      local c = str:sub(pos, pos)
      if c == ',' then pos = pos + 1
      elseif c == '}' then pos = pos + 1; return obj
      else error("expected , or } in object") end
    end
  end

  parse_value = function()
    skip_ws()
    local c = str:sub(pos, pos)
    if c == '{' then return parse_object()
    elseif c == '[' then return parse_array()
    elseif c == '"' then return parse_string()
    elseif c == 't' then pos = pos + 4; return true
    elseif c == 'f' then pos = pos + 5; return false
    elseif c == 'n' then pos = pos + 4; return nil
    else return parse_number() end
  end

  skip_ws()
  if pos > len then return {} end
  local ok, result = pcall(parse_value)
  if ok then return result end
  return {}
end

json.decode = json_decode

----------------------------------------------------------------------------
-- Shared state
----------------------------------------------------------------------------
local STATE = {
  scan      = nil,   -- { scanner, found, count, value_type }
  allocs    = {},    -- addr_str -> size
  running   = true,
}

----------------------------------------------------------------------------
-- Address / type helpers
----------------------------------------------------------------------------
local function addr_str(a)
  if not a then return "0x0" end
  return ("0x%X"):format(a)
end

local function to_addr(v)
  if type(v) == "number" then return v end
  if type(v) == "string" then
    if v:match("^0[xX]") then return tonumber(v:sub(3), 16) end
    local n = tonumber(v)
    if n then return n end
    return getAddressSafe(v)   -- module+offset / symbol
  end
  return nil
end

local VTYPES = {
  byte = vtByte, ["1byte"] = vtByte,
  word = vtWord, ["2byte"] = vtWord, short = vtWord,
  dword = vtDword, ["4byte"] = vtDword, int = vtDword, integer = vtDword,
  qword = vtQword, ["8byte"] = vtQword, int64 = vtQword, long = vtQword,
  float = vtSingle, single = vtSingle,
  double = vtDouble,
  string = vtString, text = vtString,
  aob = vtByteArray, bytes = vtByteArray, bytearray = vtByteArray,
}

local SCANTYPES = {
  exact = fsmEqualTo, equals = fsmEqualTo, ["="] = fsmEqualTo,
  notequal = fsmNotEqualTo, ["!="] = fsmNotEqualTo,
  bigger = fsmBiggerThan, greater = fsmBiggerThan, [">"] = fsmBiggerThan,
  biggerorequal = fsmBiggerThanOrEqual, [">="] = fsmBiggerThanOrEqual,
  smaller = fsmSmallerThan, less = fsmSmallerThan, ["<"] = fsmSmallerThan,
  smallerorequal = fsmSmallerThanOrEqual, ["<="] = fsmSmallerThanOrEqual,
  between = fsmBetween,
  unknown = fsmUnknownValue, unknownvalue = fsmUnknownValue,
  changed = fsmChanged, unchanged = fsmUnchanged,
  increased = fsmIncreased, decreased = fsmDecreased,
  increasedby = fsmIncreasedValueBy, decreasedby = fsmDecreasedValueBy,
}

----------------------------------------------------------------------------
-- HTTP plumbing
----------------------------------------------------------------------------
local function send_response(client, code, payload)
  local status = ({ [200]="200 OK", [400]="400 Bad Request",
    [404]="404 Not Found", [500]="500 Internal Server Error" })[code]
    or (tostring(code) .. " Status")
  local body = json.encode(payload)
  client:send(table.concat({
    "HTTP/1.1 " .. status,
    "Content-Type: application/json",
    "Access-Control-Allow-Origin: *",
    "Content-Length: " .. #body,
    "Connection: close",
    "", body,
  }, "\r\n"))
  client:close()
end

local function reply_ok(client, data)  send_response(client, 200, { ok = true,  data = data }) end
local function reply_err(client, msg, code) send_response(client, code or 500, { ok = false, error = tostring(msg) }) end

----------------------------------------------------------------------------
-- Route table
----------------------------------------------------------------------------
local R = {}

-- helper to require a param
local function need(p, key, client)
  local v = p[key]
  if v == nil then reply_err(client, "missing parameter: " .. key, 400); return nil, false end
  return v, true
end

-- ── meta ──────────────────────────────────────────────────────────────────
R["/ping"] = function(c) reply_ok(c, { pong = true, version = getCEVersion() }) end

R["/routes"] = function(c)
  local r = {}; for k in pairs(R) do r[#r+1] = k end; table.sort(r)
  reply_ok(c, r)
end

R["/ce/version"] = function(c)
  reply_ok(c, { ce_version = getCEVersion(), lua = _VERSION,
                ce_dir = getCheatEngineDir and getCheatEngineDir() or "" })
end

-- ── process ───────────────────────────────────────────────────────────────
R["/process/list"] = function(c, _, p)
  local filter = (p.filter or ""):lower()
  local out = {}
  for _, proc in ipairs(getProcessList()) do
    if filter == "" or proc.name:lower():find(filter, 1, true) then
      out[#out + 1] = { pid = proc.id, name = proc.name }
    end
  end
  reply_ok(c, out)
end

R["/process/attach"] = function(c, _, p)
  local target = p.process or p.pid or p.name
  if target == nil then return reply_err(c, "missing process/pid/name", 400) end
  if type(target) == "string" and tonumber(target) then target = tonumber(target) end
  openProcess(target)
  if getOpenedProcessID() ~= 0 then
    reply_ok(c, { pid = getOpenedProcessID(), name = getOpenedProcessName(),
                  is64bit = targetIs64Bit() })
  else
    reply_err(c, "failed to attach to " .. tostring(target))
  end
end

R["/process/detach"] = function(c)
  closeProcess(); reply_ok(c, { detached = true })
end

R["/process/current"] = function(c)
  local pid = getOpenedProcessID()
  if pid == 0 then return reply_err(c, "no process attached") end
  reply_ok(c, { pid = pid, name = getOpenedProcessName(), is64bit = targetIs64Bit() })
end

R["/process/modules"] = function(c, _, p)
  local filter = (p.filter or ""):lower()
  local out = {}
  for _, m in ipairs(enumModules()) do
    if filter == "" or m.Name:lower():find(filter, 1, true) then
      out[#out + 1] = { name = m.Name, base = addr_str(m.Address),
                        size = m.Size, path = m.PathToFile or m.PathFile or "" }
    end
  end
  reply_ok(c, out)
end

R["/process/regions"] = function(c)
  local out = {}
  for _, r in ipairs(enumMemoryRegions()) do
    out[#out + 1] = { base = addr_str(r.BaseAddress), size = r.RegionSize,
                      protect = r.Protect, state = r.State, type = r.Type }
  end
  reply_ok(c, out)
end

-- ── raw memory read ───────────────────────────────────────────────────────
R["/memory/read"] = function(c, _, p)
  local addr = to_addr(p.address); if not addr then return reply_err(c, "invalid address", 400) end
  local vt = (p.type or "4byte"):lower()
  local size = tonumber(p.size) or 64
  local val
  if vt == "byte" or vt == "1byte" then val = readBytes(addr, 1, false)
  elseif vt == "word" or vt == "2byte" then val = readSmallInteger(addr, p.signed)
  elseif vt == "dword" or vt == "4byte" or vt == "int" then val = readInteger(addr, p.signed)
  elseif vt == "qword" or vt == "8byte" or vt == "int64" then val = readQword(addr)
  elseif vt == "float" then val = readFloat(addr)
  elseif vt == "double" then val = readDouble(addr)
  elseif vt == "pointer" then val = addr_str(readPointer(addr))
  elseif vt == "string" then val = readString(addr, size, p.wide or false)
  elseif vt == "aob" or vt == "bytes" then
    local raw = readBytes(addr, size, true); local h = {}
    if raw then for _, b in ipairs(raw) do h[#h+1] = ("%02X"):format(b) end end
    val = table.concat(h, " ")
  else val = readInteger(addr) end
  reply_ok(c, { address = addr_str(addr), type = vt, value = val })
end

R["/memory/read_batch"] = function(c, _, p)
  local reads = p.reads or {}
  local out = {}
  for _, r in ipairs(reads) do
    local addr = to_addr(r.address)
    if addr then
      local vt = (r.type or "4byte"):lower()
      local v
      if vt == "float" then v = readFloat(addr)
      elseif vt == "double" then v = readDouble(addr)
      elseif vt == "8byte" or vt == "qword" then v = readQword(addr)
      elseif vt == "string" then v = readString(addr, r.size or 64, r.wide)
      elseif vt == "byte" then v = readBytes(addr, 1, false)
      else v = readInteger(addr) end
      out[#out + 1] = { address = addr_str(addr), value = v }
    end
  end
  reply_ok(c, out)
end

-- ── raw memory write ──────────────────────────────────────────────────────
R["/memory/write"] = function(c, _, p)
  local addr = to_addr(p.address); if not addr then return reply_err(c, "invalid address", 400) end
  if p.value == nil then return reply_err(c, "missing value", 400) end
  local vt = (p.type or "4byte"):lower()
  if vt == "byte" or vt == "1byte" then writeBytes(addr, tonumber(p.value) & 0xFF)
  elseif vt == "word" or vt == "2byte" then writeSmallInteger(addr, tonumber(p.value))
  elseif vt == "dword" or vt == "4byte" or vt == "int" then writeInteger(addr, tonumber(p.value))
  elseif vt == "qword" or vt == "8byte" or vt == "int64" then writeQword(addr, tonumber(p.value))
  elseif vt == "float" then writeFloat(addr, tonumber(p.value))
  elseif vt == "double" then writeDouble(addr, tonumber(p.value))
  elseif vt == "string" then writeString(addr, tostring(p.value), p.wide or false)
  elseif vt == "aob" or vt == "bytes" then
    local bytes = {}
    for h in tostring(p.value):gmatch("%x%x") do bytes[#bytes+1] = tonumber(h, 16) end
    writeBytes(addr, bytes)
  else writeInteger(addr, tonumber(p.value)) end
  reply_ok(c, { address = addr_str(addr), type = vt, value = p.value, written = true })
end

R["/memory/dump"] = function(c, _, p)
  local addr = to_addr(p.address); if not addr then return reply_err(c, "invalid address", 400) end
  local size = math.min(tonumber(p.size) or 256, 65536)
  local bytes = readBytes(addr, size, true)
  local lines = {}
  if bytes then
    for i = 1, #bytes, 16 do
      local hx, asc = {}, {}
      for j = i, math.min(i + 15, #bytes) do
        local b = bytes[j]
        hx[#hx+1] = ("%02X"):format(b)
        asc[#asc+1] = (b >= 32 and b < 127) and string.char(b) or "."
      end
      lines[#lines+1] = { address = addr_str(addr + i - 1),
                          hex = table.concat(hx, " "), ascii = table.concat(asc) }
    end
  end
  reply_ok(c, { address = addr_str(addr), size = size, lines = lines })
end

-- ── memory allocation / protection ────────────────────────────────────────
R["/memory/alloc"] = function(c, _, p)
  local size = tonumber(p.size) or 4096
  local near = to_addr(p.near)
  local a = near and allocateMemory(size, near) or allocateMemory(size)
  if not a then return reply_err(c, "allocation failed") end
  STATE.allocs[addr_str(a)] = size
  reply_ok(c, { address = addr_str(a), size = size })
end

R["/memory/free"] = function(c, _, p)
  local addr = to_addr(p.address); if not addr then return reply_err(c, "invalid address", 400) end
  deAlloc(addr); STATE.allocs[addr_str(addr)] = nil
  reply_ok(c, { freed = addr_str(addr) })
end

-- ── scanning ──────────────────────────────────────────────────────────────
R["/scan/first"] = function(c, _, p)
  if getOpenedProcessID() == 0 then return reply_err(c, "no process attached") end
  local vt = VTYPES[(p.value_type or "4byte"):lower()] or vtDword
  local st = SCANTYPES[(p.scan_type or "exact"):lower()] or fsmEqualTo
  local scanner = createMemScan()
  scanner.OnlyOneResult = (p.only_one == true)
  local start_a = to_addr(p.start) or 0
  local stop_a  = to_addr(p.stop)  or 0x7fffffffffffffff
  scanner.firstScan(st, vt, rtRounded,
    p.value and tostring(p.value) or "", p.value2 and tostring(p.value2) or "",
    start_a, stop_a, "+W-C", fsmNotAligned, "", false, false, false, false)
  scanner.waitTillDone()
  local fl = createFoundList(scanner); fl.initialize()
  STATE.scan = { scanner = scanner, found = fl, count = fl.Count,
                 value_type = (p.value_type or "4byte") }
  reply_ok(c, { count = fl.Count, value_type = STATE.scan.value_type })
end

R["/scan/next"] = function(c, _, p)
  if not STATE.scan then return reply_err(c, "no active scan; call /scan/first") end
  local st = SCANTYPES[(p.scan_type or "exact"):lower()] or fsmEqualTo
  STATE.scan.found.deinitialize()
  STATE.scan.scanner.nextScan(st, rtRounded,
    p.value and tostring(p.value) or "", p.value2 and tostring(p.value2) or "",
    false, false, false, false)
  STATE.scan.scanner.waitTillDone()
  STATE.scan.found.initialize()
  STATE.scan.count = STATE.scan.found.Count
  reply_ok(c, { count = STATE.scan.count })
end

R["/scan/results"] = function(c, _, p)
  if not STATE.scan then return reply_err(c, "no active scan") end
  local fl = STATE.scan.found
  local total = fl.Count
  local limit = math.min(tonumber(p.limit) or 100, 1000)
  local offset = tonumber(p.offset) or 0
  local out = {}
  for i = offset, math.min(offset + limit - 1, total - 1) do
    out[#out + 1] = { index = i, address = fl.Address[i], value = fl.Value[i] }
  end
  reply_ok(c, { results = out, total = total, offset = offset, limit = limit })
end

R["/scan/reset"] = function(c)
  if STATE.scan then
    if STATE.scan.found then STATE.scan.found.destroy() end
    if STATE.scan.scanner then STATE.scan.scanner.destroy() end
    STATE.scan = nil
  end
  reply_ok(c, { reset = true })
end

R["/scan/aob"] = function(c, _, p)
  local pattern, ok = need(p, "pattern", c); if not ok then return end
  local start_a = to_addr(p.start) or 0
  local stop_a  = to_addr(p.stop)  or 0x7fffffffffffffff
  local results = AOBScan(pattern, start_a, stop_a, p.protection or "+X-C")
  local out = {}
  if results then
    for i = 0, results.Count - 1 do out[#out + 1] = results[i] end
    results.destroy()
  end
  reply_ok(c, { pattern = pattern, count = #out, results = out })
end

-- ── cheat table / address list ────────────────────────────────────────────
local function find_record(id)
  local al = getAddressList()
  for i = 0, al.Count - 1 do
    local e = al.getMemoryRecord(i)
    if e.ID == id then return e, al end
  end
  return nil, al
end

R["/table/list"] = function(c)
  local al = getAddressList()
  local out = {}
  for i = 0, al.Count - 1 do
    local e = al.getMemoryRecord(i)
    out[#out + 1] = { id = e.ID, index = i, description = e.Description,
      address = e.AddressString, value = e.Value, type = e.Type,
      active = e.Active, frozen = (e.Active and e.AllowIncrease == false) }
  end
  reply_ok(c, out)
end

R["/table/add"] = function(c, _, p)
  local al = getAddressList()
  local mr = al.createMemoryRecord()
  mr.Description = p.description or "MCP entry"
  mr.Address     = tostring(p.address or "0")
  mr.Type        = VTYPES[(p.type or "4byte"):lower()] or vtDword
  if p.value ~= nil then mr.Value = tostring(p.value) end
  reply_ok(c, { id = mr.ID, description = mr.Description, address = mr.AddressString })
end

R["/table/remove"] = function(c, _, p)
  local id = tonumber(p.id); if not id then return reply_err(c, "missing id", 400) end
  local e, al = find_record(id)
  if not e then return reply_err(c, "record not found: " .. id, 404) end
  al.delete(e); reply_ok(c, { removed = id })
end

R["/table/set_value"] = function(c, _, p)
  local id = tonumber(p.id); if not id then return reply_err(c, "missing id", 400) end
  local e = find_record(id); if not e then return reply_err(c, "record not found", 404) end
  e.Value = tostring(p.value); reply_ok(c, { id = id, value = p.value })
end

R["/table/freeze"] = function(c, _, p)
  local id = tonumber(p.id); if not id then return reply_err(c, "missing id", 400) end
  local e = find_record(id); if not e then return reply_err(c, "record not found", 404) end
  local frozen = (p.frozen ~= false)
  e.Active = frozen
  reply_ok(c, { id = id, frozen = frozen })
end

R["/table/enable"] = function(c, _, p)
  local id = tonumber(p.id); if not id then return reply_err(c, "missing id", 400) end
  local e = find_record(id); if not e then return reply_err(c, "record not found", 404) end
  e.Active = (p.active ~= false)
  reply_ok(c, { id = id, active = e.Active })
end

R["/table/hotkey"] = function(c, _, p)
  local id = tonumber(p.id); if not id then return reply_err(c, "missing id", 400) end
  local e = find_record(id); if not e then return reply_err(c, "record not found", 404) end
  local keys = p.keys
  if type(keys) ~= "table" then keys = { tonumber(keys) or 0 } end
  local hk = e.createHotkey(keys, tonumber(p.action) or 1)
  if p.value ~= nil then hk.Value = tostring(p.value) end
  reply_ok(c, { id = id, hotkey = "created" })
end

R["/table/load"] = function(c, _, p)
  local path = need(p, "path", c); if not path then return end
  reload = false; loadTable(path, p.merge == true)
  reply_ok(c, { loaded = path, count = getAddressList().Count })
end

R["/table/save"] = function(c, _, p)
  local path = need(p, "path", c); if not path then return end
  saveTable(path); reply_ok(c, { saved = path })
end

R["/table/clear"] = function(c)
  local al = getAddressList()
  while al.Count > 0 do al.delete(al.getMemoryRecord(0)) end
  reply_ok(c, { cleared = true })
end

-- ── pointers ──────────────────────────────────────────────────────────────
R["/pointer/resolve"] = function(c, _, p)
  local base = to_addr(p.base); if not base then return reply_err(c, "invalid base", 400) end
  local cur = base
  local offsets = p.offsets or {}
  local chain = { addr_str(cur) }
  for _, off in ipairs(offsets) do
    cur = readPointer(cur)
    if not cur or cur == 0 then
      return reply_ok(c, { resolved = "NULL", valid = false, chain = chain })
    end
    cur = cur + tonumber(off)
    chain[#chain + 1] = addr_str(cur)
  end
  reply_ok(c, { base = addr_str(base), offsets = offsets,
                resolved = addr_str(cur), valid = true, chain = chain })
end

R["/pointer/scan"] = function(c, _, p)
  local addr = to_addr(p.address); if not addr then return reply_err(c, "invalid address", 400) end
  local file = (os.getenv("TEMP") or ".") .. "\\cemcp_" .. os.time() .. ".PTR"
  local ps = getAddressList()  -- placeholder to ensure process ctx
  local scanner = createPointerScan()
  scanner.scanForPointers({
    address = addr, maxLevel = tonumber(p.max_level) or 4,
    structsize = tonumber(p.max_offset) or 2048,
    filename = file,
  })
  reply_ok(c, { note = "pointer scan started (async); open result in CE UI", file = file })
end

-- ── disassembler / assembler ──────────────────────────────────────────────
R["/disassemble"] = function(c, _, p)
  local addr = to_addr(p.address); if not addr then return reply_err(c, "invalid address", 400) end
  local count = tonumber(p.count) or 16
  local out, cur = {}, addr
  for _ = 1, count do
    local text = disassemble(cur)
    local size = getInstructionSize(cur)
    out[#out + 1] = { address = addr_str(cur), instruction = text, size = size }
    cur = cur + (size > 0 and size or 1)
  end
  reply_ok(c, out)
end

R["/assemble"] = function(c, _, p)
  local code = need(p, "code", c); if not code then return end
  local addr = to_addr(p.address) or 0
  local bytes, err = assemble(code, addr)
  if not bytes then return reply_err(c, err or "assemble failed") end
  local h = {}; for _, b in ipairs(bytes) do h[#h+1] = ("%02X"):format(b) end
  reply_ok(c, { bytes = table.concat(h, " "), count = #bytes })
end

R["/autoassemble"] = function(c, _, p)
  local script = need(p, "script", c); if not script then return end
  local enable = (p.enable ~= false)
  local ok, err = autoAssemble(script, not enable)
  if ok then reply_ok(c, { success = true, enabled = enable })
  else reply_err(c, err or "auto-assemble failed") end
end

-- ── debugger ──────────────────────────────────────────────────────────────
R["/debugger/find_what_writes"] = function(c, _, p)
  local addr = to_addr(p.address); if not addr then return reply_err(c, "invalid address", 400) end
  local dur = math.min(tonumber(p.duration) or 3, 30)
  if not debug_isDebugging() then debugProcess(2) end
  local found = createFindWhatWritesRecord and nil
  local fww = findWhatWrites(addr)
  sleep(dur * 1000)
  local results = fww.getResults and fww.getResults() or {}
  fww.stop()
  local out = {}
  for _, r in ipairs(results or {}) do
    out[#out + 1] = { address = addr_str(r.Address or r.address),
      count = r.Count or r.count, instruction = r.Disassembly or r.opcode or "" }
  end
  reply_ok(c, { address = addr_str(addr), instructions = out })
end

R["/debugger/find_what_accesses"] = function(c, _, p)
  local addr = to_addr(p.address); if not addr then return reply_err(c, "invalid address", 400) end
  local dur = math.min(tonumber(p.duration) or 3, 30)
  if not debug_isDebugging() then debugProcess(2) end
  local fwa = findWhatAccesses(addr)
  sleep(dur * 1000)
  local results = fwa.getResults and fwa.getResults() or {}
  fwa.stop()
  local out = {}
  for _, r in ipairs(results or {}) do
    out[#out + 1] = { address = addr_str(r.Address or r.address),
      count = r.Count or r.count, instruction = r.Disassembly or r.opcode or "" }
  end
  reply_ok(c, { address = addr_str(addr), instructions = out })
end

R["/debugger/breakpoint"] = function(c, _, p)
  local addr = to_addr(p.address); if not addr then return reply_err(c, "invalid address", 400) end
  if not debug_isDebugging() then debugProcess() end
  if p.remove then debug_removeBreakpoint(addr); return reply_ok(c, { removed = addr_str(addr) }) end
  debug_setBreakpoint(addr, tonumber(p.size) or 1, p.trigger or bptExecute)
  reply_ok(c, { breakpoint = addr_str(addr) })
end

-- ── speedhack ─────────────────────────────────────────────────────────────
R["/speedhack/set"] = function(c, _, p)
  local speed = tonumber(p.speed); if not speed then return reply_err(c, "missing speed", 400) end
  speedhack_setSpeed(speed); reply_ok(c, { speed = speed })
end

-- ── Mono / Unity ──────────────────────────────────────────────────────────
R["/mono/classes"] = function(c, _, p)
  if not mono_enumDomains then return reply_err(c, "mono not loaded; call /mono/init") end
  local filter = (p.filter or ""):lower()
  local out = {}
  for _, dom in ipairs(mono_enumDomains() or {}) do
    for _, asm in ipairs(mono_enumAssemblies(dom) or {}) do
      local img = mono_getImageFromAssembly(asm)
      for _, cls in ipairs(mono_image_enumClasses(img) or {}) do
        local name = cls.name or mono_class_getName(cls.class or cls)
        local ns = cls.namespace or ""
        if filter == "" or (name and name:lower():find(filter, 1, true)) then
          out[#out + 1] = { namespace = ns, name = name,
                            class = addr_str(cls.class or cls) }
        end
      end
    end
  end
  reply_ok(c, out)
end

R["/mono/init"] = function(c)
  if LaunchMonoDataCollector then LaunchMonoDataCollector() end
  reply_ok(c, { mono = "initialized" })
end

-- ── lua passthrough (power user / escape hatch) ───────────────────────────
R["/lua/execute"] = function(c, _, p)
  local code = need(p, "code", c); if not code then return end
  local output = {}
  local real_print = print
  _G.print = function(...)
    local a = {}; for i = 1, select("#", ...) do a[i] = tostring(select(i, ...)) end
    output[#output + 1] = table.concat(a, "\t")
  end
  local ok, result = pcall(function()
    local fn, e = load(code, "mcp", "t", _G)
    if not fn then error(e) end
    return fn()
  end)
  _G.print = real_print
  if ok then reply_ok(c, { success = true, output = output,
                           result = result ~= nil and tostring(result) or nil })
  else reply_ok(c, { success = false, output = output, error = tostring(result) }) end
end

----------------------------------------------------------------------------
-- Request dispatch
----------------------------------------------------------------------------
local function handle_client(client)
  client:settimeout(5)
  local line = client:receive("*l")
  if not line then client:close(); return end
  local method, path = line:match("^(%u+)%s+(%S+)")
  if not method then client:close(); return end

  -- headers
  local content_length = 0
  while true do
    local h = client:receive("*l")
    if not h or h == "" then break end
    local k, v = h:match("^([%w%-]+):%s*(.+)")
    if k and k:lower() == "content-length" then content_length = tonumber(v) or 0 end
  end

  local route = path:match("^([^?]+)")
  local params = {}

  -- query string params
  local qs = path:match("%?(.+)$")
  if qs then
    for k, v in qs:gmatch("([^&=]+)=([^&]*)") do
      params[k] = v:gsub("%%(%x%x)", function(x) return string.char(tonumber(x, 16)) end)
    end
  end

  -- JSON body
  if content_length > 0 then
    local body = client:receive(content_length)
    if body then
      local parsed = json.decode(body)
      if type(parsed) == "table" then
        for k, v in pairs(parsed) do params[k] = v end
      end
    end
  end

  local handler = R[route]
  if not handler then
    return send_response(client, 404, { ok = false, error = "no route: " .. route })
  end
  local ok, err = pcall(handler, client, method, params)
  if not ok then pcall(reply_err, client, err) end
end

----------------------------------------------------------------------------
-- Server bootstrap (non-blocking accept loop on a CE timer)
----------------------------------------------------------------------------
local function start()
  local socket = require("socket")
  local server, err = socket.bind(HOST, PORT)
  if not server then return log("bind failed: " .. tostring(err)) end
  server:settimeout(0)
  log(("listening on http://%s:%d"):format(HOST, PORT))

  local timer = createTimer(nil)
  timer.Interval = TICK
  timer.OnTimer = function()
    if not STATE.running then timer.destroy(); server:close(); return end
    local client = server:accept()
    if client then pcall(handle_client, client) end
  end
end

-- expose a stopper for convenience
function ce_mcp_stop() STATE.running = false; log("stopping...") end

local ok, e = pcall(start)
if not ok then log("startup error: " .. tostring(e)) end
