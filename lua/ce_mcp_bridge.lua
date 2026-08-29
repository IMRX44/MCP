--[[ ============================================================================
  CE-MCP Bridge  v2.0.0  —  File-based IPC (no LuaSocket required)
  ----------------------------------------------------------------------------
  Runs inside Cheat Engine and services commands from the ce-mcp Python server.

  WHAT'S NEW IN v2
    * Request/response correlation IDs — a late response from a timed-out call
      can no longer be mistaken for the answer to the next call.
    * Non-blocking job system — scans and breakpoint traces no longer freeze
      Cheat Engine or wedge the bridge. Poll with scan_status / job_status,
      abort with scan_cancel / job_cancel.
    * Structured logging — levelled ring buffer + log file, every request
      traced with timing. Read it back over the wire with debug_log.
    * Runtime capability probing — tools that depend on a CE function that
      does not exist in this build fail with a precise message instead of a
      bare "attempt to call a nil value".
    * Fast-scan alignment on by default (matches CE's GUI) — roughly a 4x
      cut in scan time and result-file size versus the old unaligned scans.

  USAGE
    Put this file in  <Cheat Engine>\autorun\  and restart Cheat Engine, or
    paste it into Table -> Cheat Table Lua Script (Ctrl+Alt+L) and Execute.
    You should see  [CE-MCP] bridge ready  in the output panel.

  Stop it with  ce_mcp_stop()  ;  restart with  ce_mcp_start().
============================================================================ ]]--

local BRIDGE_VERSION  = "2.0.0"
local PROTOCOL        = 2
local POLL_MS         = 8
local LOG_RING_MAX    = 400
local PARAM_LOG_CHARS = 300

local TEMP_DIR = os.getenv("CE_MCP_TEMP") or os.getenv("TEMP") or os.getenv("TMP") or "C:\\Temp"
local PREFIX   = TEMP_DIR .. "\\cemcp_"
local REQ_PATH = PREFIX .. "req.json"
local RES_PATH = PREFIX .. "res.json"
local LOG_PATH = PREFIX .. "bridge.log"

-- ══════════════════════════════════════════════════════════════════════════
-- STATE
-- ══════════════════════════════════════════════════════════════════════════
local STATE = {
  running    = true,
  busy       = false,   -- dispatcher re-entrancy guard
  allocs     = {},
  scan       = nil,
  jobs       = {},
  next_job   = 1,
  started_at = os.time(),
  requests   = 0,
  errors     = 0,
  last_req   = nil,
  last_error = nil,
}

-- ══════════════════════════════════════════════════════════════════════════
-- LOGGING
-- ══════════════════════════════════════════════════════════════════════════
local LEVELS  = { error = 1, warn = 2, info = 3, debug = 4, trace = 5 }
local LEVEL_NAME = { "error", "warn", "info", "debug", "trace" }

local LOG = {
  ring       = {},
  ring_pos   = 0,
  seq        = 0,
  level      = LEVELS[(os.getenv("CE_MCP_LOG_LEVEL") or "info"):lower()] or LEVELS.info,
  to_file    = (os.getenv("CE_MCP_LOG_FILE") ~= "0"),
  to_console = true,
}

local function now_ms()
  return math.floor(os.clock() * 1000)
end

local function stamp()
  return os.date("%H:%M:%S")
end

local function log_at(level, msg)
  if level > LOG.level then return end
  LOG.seq = LOG.seq + 1
  local name = LEVEL_NAME[level] or "info"
  local line = ("%s [%s] %s"):format(stamp(), name, tostring(msg))

  -- ring buffer (fixed size, overwrites oldest)
  LOG.ring_pos = (LOG.ring_pos % LOG_RING_MAX) + 1
  LOG.ring[LOG.ring_pos] = { seq = LOG.seq, level = name, time = stamp(), msg = tostring(msg) }

  if LOG.to_console and level <= LEVELS.info then
    print("[CE-MCP] " .. tostring(msg))
  end
  if LOG.to_file then
    local f = io.open(LOG_PATH, "a")
    if f then f:write(line, "\n"); f:close() end
  end
end

local function logf(level, fmt, ...)
  if LEVELS[level] and LEVELS[level] > LOG.level then return end
  local ok, s = pcall(string.format, fmt, ...)
  log_at(LEVELS[level] or LEVELS.info, ok and s or fmt)
end

local function log_error(...) logf("error", ...) end
local function log_warn(...)  logf("warn",  ...) end
local function log_info(...)  logf("info",  ...) end
local function log_debug(...) logf("debug", ...) end
local function log_trace(...) logf("trace", ...) end

--- Return the most recent `n` ring entries, oldest first.
local function log_tail(n, min_level)
  n = math.min(tonumber(n) or 100, LOG_RING_MAX)
  local minl = LEVELS[tostring(min_level or "trace"):lower()] or LEVELS.trace
  local all = {}
  for i = 1, LOG_RING_MAX do
    local idx = ((LOG.ring_pos + i - 1) % LOG_RING_MAX) + 1
    local e = LOG.ring[idx]
    if e and (LEVELS[e.level] or 3) <= minl then all[#all + 1] = e end
  end
  local out = {}
  for i = math.max(1, #all - n + 1), #all do out[#out + 1] = all[i] end
  return out
end

-- ══════════════════════════════════════════════════════════════════════════
-- JSON
-- ══════════════════════════════════════════════════════════════════════════
local ARRAY_MT = {}
--- Mark a table so it always encodes as a JSON array, even when empty.
local function arr(t) return setmetatable(t or {}, ARRAY_MT) end

local ESC = { ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f',
              ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }

local function esc(s)
  return '"' .. s:gsub('[%z\1-\31\\"]', function(c)
    return ESC[c] or ('\\u%04x'):format(c:byte())
  end) .. '"'
end

local function is_arr(t)
  local n = 0
  for k in pairs(t) do
    if type(k) ~= "number" or k ~= math.floor(k) or k < 1 then return false, 0 end
    if k > n then n = k end
  end
  return (n == #t), n
end

local json_encode
json_encode = function(v, depth)
  depth = (depth or 0) + 1
  if depth > 64 then return '"<max depth>"' end
  local t = type(v)
  if v == nil then return "null"
  elseif t == "boolean" then return v and "true" or "false"
  elseif t == "number" then
    if v ~= v or v == math.huge or v == -math.huge then return "null" end
    if v % 1 == 0 and math.abs(v) < 9007199254740992 then return ("%d"):format(v) end
    return ("%.17g"):format(v)
  elseif t == "string" then return esc(v)
  elseif t == "table" then
    local forced = getmetatable(v) == ARRAY_MT
    local ok, n = is_arr(v)
    if forced or (ok and n > 0) then
      local p = {}
      for i = 1, (forced and #v or n) do p[i] = json_encode(v[i], depth) end
      return "[" .. table.concat(p, ",") .. "]"
    end
    local p = {}
    for k, val in pairs(v) do
      if val ~= nil then p[#p + 1] = esc(tostring(k)) .. ":" .. json_encode(val, depth) end
    end
    return "{" .. table.concat(p, ",") .. "}"
  end
  return "null"
end

--- Recursive-descent JSON parser. Returns value, or nil + error message.
local function json_decode(str)
  if not str or str == "" then return nil, "empty input" end
  local pos = 1
  local parse_value

  local function skip()
    while pos <= #str do
      local c = str:byte(pos)
      if c == 32 or c == 9 or c == 10 or c == 13 then pos = pos + 1 else break end
    end
  end

  local function parse_str()
    pos = pos + 1
    local buf = {}
    while pos <= #str do
      local c = str:sub(pos, pos)
      if c == '"' then pos = pos + 1; return table.concat(buf)
      elseif c == '\\' then
        local n = str:sub(pos + 1, pos + 1)
        if n == 'u' then
          local cp = tonumber(str:sub(pos + 2, pos + 5), 16) or 0
          if cp < 0x80 then buf[#buf + 1] = string.char(cp)
          elseif cp < 0x800 then
            buf[#buf + 1] = string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
          else
            buf[#buf + 1] = string.char(0xE0 + math.floor(cp / 0x1000),
                                        0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
          end
          pos = pos + 6
        else
          local m = { n = '\n', t = '\t', r = '\r', b = '\b', f = '\f',
                      ['"'] = '"', ['/'] = '/', ['\\'] = '\\' }
          buf[#buf + 1] = m[n] or n
          pos = pos + 2
        end
      else buf[#buf + 1] = c; pos = pos + 1 end
    end
    error("unterminated string at " .. pos)
  end

  local function parse_num()
    local s = pos
    while pos <= #str do
      local c = str:byte(pos)
      if (c >= 48 and c <= 57) or c == 45 or c == 43 or c == 46 or c == 101 or c == 69
        then pos = pos + 1 else break end
    end
    local n = tonumber(str:sub(s, pos - 1))
    if n == nil then error("bad number at " .. s) end
    return n
  end

  local function parse_arr()
    pos = pos + 1; local a = {}; skip()
    if str:sub(pos, pos) == ']' then pos = pos + 1; return arr(a) end
    while true do
      a[#a + 1] = parse_value(); skip()
      local c = str:sub(pos, pos)
      if c == ',' then pos = pos + 1; skip()
      elseif c == ']' then pos = pos + 1; return arr(a)
      else error("expected , or ] at " .. pos) end
    end
  end

  local function parse_obj()
    pos = pos + 1; local o = {}; skip()
    if str:sub(pos, pos) == '}' then pos = pos + 1; return o end
    while true do
      skip()
      if str:sub(pos, pos) ~= '"' then error("expected object key at " .. pos) end
      local k = parse_str(); skip()
      if str:sub(pos, pos) ~= ':' then error("expected : at " .. pos) end
      pos = pos + 1; skip()
      o[k] = parse_value(); skip()
      local c = str:sub(pos, pos)
      if c == ',' then pos = pos + 1
      elseif c == '}' then pos = pos + 1; return o
      else error("expected , or } at " .. pos) end
    end
  end

  parse_value = function()
    skip()
    local c = str:sub(pos, pos)
    if c == '{' then return parse_obj()
    elseif c == '[' then return parse_arr()
    elseif c == '"' then return parse_str()
    elseif str:sub(pos, pos + 3) == "true"  then pos = pos + 4; return true
    elseif str:sub(pos, pos + 4) == "false" then pos = pos + 5; return false
    elseif str:sub(pos, pos + 3) == "null"  then pos = pos + 4; return nil
    else return parse_num() end
  end

  local ok, r = pcall(parse_value)
  if not ok then return nil, tostring(r) end
  return r
end

-- ══════════════════════════════════════════════════════════════════════════
-- FILE HELPERS
-- ══════════════════════════════════════════════════════════════════════════
local function read_file(path)
  local f = io.open(path, "rb"); if not f then return nil end
  local d = f:read("*a"); f:close(); return d
end

local function write_file(path, data)
  -- Write to a sibling temp file then rename, so the reader never observes a
  -- half-written response.
  local tmp = path .. ".part"
  local f = io.open(tmp, "wb"); if not f then return false, "cannot open " .. tmp end
  f:write(data); f:close()
  os.remove(path)
  local ok, err = os.rename(tmp, path)
  if not ok then return false, tostring(err) end
  return true
end

local function file_exists(path)
  local f = io.open(path, "rb"); if not f then return false end
  f:close(); return true
end

-- ══════════════════════════════════════════════════════════════════════════
-- CAPABILITY PROBING
-- ══════════════════════════════════════════════════════════════════════════
-- Several functions the original bridge called simply do not exist in Cheat
-- Engine's Lua API (closeProcess, findWhatWrites, createPointerScan, ...).
-- Probe once at load so handlers can fail with a precise message.
local PROBED = {
  "getProcesslist", "getProcessList", "openProcess", "closeProcess",
  "getOpenedProcessID", "getOpenedProcessName", "targetIs64Bit",
  "enumModules", "enumMemoryRegions", "getAddressSafe", "getAddressList",
  "readInteger", "readFloat", "readQword", "readDouble", "readBytes",
  "readString", "readPointer", "readSmallInteger",
  "writeInteger", "writeFloat", "writeQword", "writeDouble", "writeBytes",
  "writeString", "writeSmallInteger",
  "allocateMemory", "deAlloc",
  "createMemScan", "createFoundList", "getCurrentMemscan",
  "setSpecialScanOptionsOverride",
  "AOBScan", "AOBScanUnique",
  "disassemble", "getInstructionSize", "assemble", "autoAssemble",
  "debugProcess", "debug_isDebugging", "debug_setBreakpoint",
  "debug_removeBreakpoint", "debug_continueFromBreakpoint",
  "debug_getBreakpointList", "detachIfPossible",
  "createPointerScan", "findWhatWrites", "findWhatAccesses",
  "speedhack_setSpeed", "saveTable", "loadTable",
  "LaunchMonoDataCollector", "mono_enumDomains", "createTimer",
  "getCEVersion", "getCheatEngineDir",
}

local CAPS = {}
local function probe_caps()
  for _, n in ipairs(PROBED) do CAPS[n] = (type(rawget(_G, n)) == "function") end
  CAPS.process_var = (type(rawget(_G, "process")) ~= "nil")
end
probe_caps()

--- Fetch a required CE global or raise a message naming exactly what's absent.
local function need(name, why)
  local fn = rawget(_G, name)
  if type(fn) ~= "function" then
    error(("Cheat Engine %s does not provide %s()%s"):format(
      (CAPS.getCEVersion and tostring(getCEVersion()) or "this build"),
      name, why and (" — " .. why) or ""), 0)
  end
  return fn
end

-- ══════════════════════════════════════════════════════════════════════════
-- ADDRESS / TYPE HELPERS
-- ══════════════════════════════════════════════════════════════════════════
local function to_int(a)
  if type(a) ~= "number" then return nil end
  if math.tointeger then
    local i = math.tointeger(a)
    if i then return i end
  end
  return math.floor(a)
end

local function addr_str(a)
  if a == nil then return nil end
  if type(a) == "string" then return a end
  local i = to_int(a)
  if not i then return tostring(a) end
  return ("0x%X"):format(i)
end

local function to_addr(v)
  if type(v) == "number" then return to_int(v) end
  if type(v) ~= "string" then return nil end
  local s = v:match("^%s*(.-)%s*$")
  if s == "" then return nil end
  if s:match("^0[xX]%x+$") then return tonumber(s:sub(3), 16) end
  local n = tonumber(s)
  if n then return to_int(n) end
  if s:match("^%x+$") then
    local h = tonumber(s, 16)
    if h then return h end
  end
  if CAPS.getAddressSafe then return getAddressSafe(s) end
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

-- Byte width per value type, used to pick a sane fast-scan alignment.
local VTYPE_SIZE = {
  byte = 1, ["1byte"] = 1,
  word = 2, ["2byte"] = 2, short = 2,
  dword = 4, ["4byte"] = 4, int = 4, integer = 4,
  qword = 8, ["8byte"] = 8, int64 = 8, long = 8,
  float = 4, single = 4,
  double = 8,
  string = 1, text = 1,
  aob = 1, bytes = 1, bytearray = 1,
}

-- Scan options. CE exposes these as so* globals; the numeric fallbacks match
-- CE 7.x's TScanOption ordering for builds where the globals are absent.
local STYPES = {
  exact = soExactValue or 1, equals = soExactValue or 1, ["="] = soExactValue or 1,
  between = soValueBetween or 2,
  bigger = soBiggerThan or 3, greater = soBiggerThan or 3, [">"] = soBiggerThan or 3,
  smaller = soSmallerThan or 4, less = soSmallerThan or 4, ["<"] = soSmallerThan or 4,
  increased = soIncreasedValue or 5, increasedby = soIncreasedValueBy or 6,
  decreased = soDecreasedValue or 7, decreasedby = soDecreasedValueBy or 8,
  changed = soChanged or 9, unchanged = soUnchanged or 10,
  unknown = soUnknownValue or 0, unknownvalue = soUnknownValue or 0,
}

-- Scan types that are only legal on a *next* scan.
local NEXT_ONLY = {
  increased = true, increasedby = true, decreased = true, decreasedby = true,
  changed = true, unchanged = true,
}
-- Scan types that require a value.
local NEEDS_VALUE = {
  exact = true, equals = true, ["="] = true, between = true,
  bigger = true, greater = true, [">"] = true,
  smaller = true, less = true, ["<"] = true,
  increasedby = true, decreasedby = true,
}

local ROUNDING = { rounded = rtRounded, truncated = rtTruncated, extreme = rtExtremerounded }

--- Validate a CE protection filter such as "+W-X-C".
local function check_protection(p)
  if p == nil or p == "" then return "" end
  if type(p) ~= "string" then error("protection must be a string like '+W-X-C'", 0) end
  local rest = p:gsub("[%+%-%*][XWCxwc]", "")
  if rest ~= "" then
    error(("invalid protection %q — expected +/-/* followed by X, W or C (e.g. '+W-X-C')"):format(p), 0)
  end
  return p
end

local function require_process()
  if not CAPS.getOpenedProcessID or getOpenedProcessID() == 0 then
    error("no process attached — call process_attach first", 0)
  end
end

--- CE has no getOpenedProcessName(); the global `process` holds the module name.
local function opened_process_name()
  local p = rawget(_G, "process")
  if type(p) == "string" and p ~= "" then return p end
  if CAPS.getOpenedProcessName then
    local ok, n = pcall(getOpenedProcessName)
    if ok and n then return n end
  end
  return nil
end

local function truncate(s, n)
  s = tostring(s)
  if #s <= n then return s end
  return s:sub(1, n) .. ("...(+%d)"):format(#s - n)
end

-- ══════════════════════════════════════════════════════════════════════════
-- JOBS  (non-blocking long-running work)
-- ══════════════════════════════════════════════════════════════════════════
local function job_new(kind, meta)
  local id = STATE.next_job
  STATE.next_job = id + 1
  local job = {
    id = id, kind = kind, status = "running",
    started = os.time(), started_ms = now_ms(),
    meta = meta or {}, data = arr({}), count = 0,
  }
  STATE.jobs[id] = job
  log_info("job %d started (%s)", id, kind)
  return job
end

local function job_finish(job, status, err)
  if job.status ~= "running" then return end
  job.status = status or "done"
  job.error = err
  job.elapsed_ms = now_ms() - job.started_ms
  if job.timer then
    local ok = pcall(function() job.timer.destroy() end)
    if not ok then log_warn("job %d: timer destroy failed", job.id) end
    job.timer = nil
  end
  if job.cleanup then
    local ok, e = pcall(job.cleanup, job)
    if not ok then log_warn("job %d cleanup failed: %s", job.id, tostring(e)) end
    job.cleanup = nil
  end
  log_info("job %d %s after %dms (%d records)", job.id, job.status, job.elapsed_ms or -1, job.count)
end

local function job_view(job, limit)
  limit = math.min(tonumber(limit) or 50, 1000)
  local recs = arr({})
  for i = 1, math.min(limit, #job.data) do recs[i] = job.data[i] end
  return {
    job_id = job.id, kind = job.kind, status = job.status,
    error = job.error, count = job.count,
    elapsed_ms = job.elapsed_ms or (now_ms() - job.started_ms),
    meta = job.meta, results = recs,
    truncated = (#job.data > #recs),
  }
end

-- ══════════════════════════════════════════════════════════════════════════
-- COMMAND HANDLERS
-- ══════════════════════════════════════════════════════════════════════════
local CMD = {}

-- ── connectivity & diagnostics ────────────────────────────────────────────
CMD.ping = function(_)
  return {
    pong = true,
    bridge_version = BRIDGE_VERSION,
    protocol = PROTOCOL,
    ce_version = CAPS.getCEVersion and getCEVersion() or nil,
    process_attached = (CAPS.getOpenedProcessID and getOpenedProcessID() ~= 0) or false,
    uptime_s = os.time() - STATE.started_at,
    requests_served = STATE.requests,
  }
end

CMD.ce_version = function(_)
  return {
    ce_version = CAPS.getCEVersion and getCEVersion() or nil,
    lua = _VERSION,
    ce_dir = CAPS.getCheatEngineDir and getCheatEngineDir() or "",
    bridge_version = BRIDGE_VERSION,
    protocol = PROTOCOL,
    temp_dir = TEMP_DIR,
    log_file = LOG.to_file and LOG_PATH or nil,
  }
end

CMD.ce_routes = function(_)
  local names = {}
  for k in pairs(CMD) do names[#names + 1] = k end
  table.sort(names)
  return { count = #names, routes = arr(names), protocol = PROTOCOL }
end

CMD.debug_capabilities = function(_)
  local present, missing = {}, {}
  for _, n in ipairs(PROBED) do
    if CAPS[n] then present[#present + 1] = n else missing[#missing + 1] = n end
  end
  table.sort(present); table.sort(missing)
  return {
    ce_version = CAPS.getCEVersion and getCEVersion() or nil,
    lua = _VERSION,
    present = arr(present),
    missing = arr(missing),
    notes = arr({
      "createPointerScan / findWhatWrites / findWhatAccesses / closeProcess are " ..
      "NOT part of Cheat Engine's Lua API in any known build. The bridge " ..
      "implements the equivalents itself (see find_what_writes, process_detach).",
    }),
  }
end

CMD.debug_log = function(p)
  local entries = log_tail(p.limit or 100, p.level)
  return {
    entries = arr(entries),
    log_file = LOG.to_file and LOG_PATH or nil,
    level = LEVEL_NAME[LOG.level],
    ring_capacity = LOG_RING_MAX,
    total_logged = LOG.seq,
  }
end

CMD.debug_set_level = function(p)
  local want = tostring(p.level or "info"):lower()
  local lv = LEVELS[want]
  if not lv then error("level must be one of: error, warn, info, debug, trace", 0) end
  LOG.level = lv
  if p.to_file ~= nil then LOG.to_file = (p.to_file == true) end
  log_info("log level set to %s (file=%s)", want, tostring(LOG.to_file))
  return { level = want, to_file = LOG.to_file, log_file = LOG_PATH }
end

CMD.debug_state = function(_)
  local jobs = {}
  for id, j in pairs(STATE.jobs) do
    jobs[#jobs + 1] = { id = id, kind = j.kind, status = j.status, count = j.count }
  end
  table.sort(jobs, function(a, b) return a.id < b.id end)

  local scan
  if STATE.scan then
    local s = STATE.scan
    scan = {
      phase = s.phase, value_type = s.value_type, scan_type = s.scan_type,
      protection = s.protection, alignment = s.alignment,
      done = s.done, count = s.count, region_scan = s.region_scan,
      error = s.error, started_ago_ms = now_ms() - s.started_ms,
      foundlist_open = (s.found ~= nil),
    }
  end

  local allocs = {}
  for a, sz in pairs(STATE.allocs) do allocs[#allocs + 1] = { address = a, size = sz } end

  return {
    bridge_version = BRIDGE_VERSION,
    uptime_s = os.time() - STATE.started_at,
    requests = STATE.requests, errors = STATE.errors,
    last_request = STATE.last_req, last_error = STATE.last_error,
    process = (CAPS.getOpenedProcessID and getOpenedProcessID() ~= 0) and {
      pid = getOpenedProcessID(), name = opened_process_name(),
      is64bit = CAPS.targetIs64Bit and targetIs64Bit() or nil,
      debugging = CAPS.debug_isDebugging and debug_isDebugging() or false,
    } or nil,
    scan = scan,
    jobs = arr(jobs),
    allocations = arr(allocs),
    paths = { request = REQ_PATH, response = RES_PATH, log = LOG_PATH },
  }
end

--- End-to-end self test. Every check is independent and reports its own error.
CMD.debug_selftest = function(_)
  local checks = arr({})
  local function check(name, fn, opts)
    opts = opts or {}
    local t0 = now_ms()
    local ok, res = pcall(fn)
    checks[#checks + 1] = {
      name = name,
      status = ok and "pass" or (opts.optional and "skip" or "fail"),
      detail = ok and (res ~= nil and tostring(res) or "ok") or tostring(res),
      ms = now_ms() - t0,
    }
    return ok
  end

  check("json roundtrip", function()
    local src = { a = 1, b = "x\"y", c = arr({ 1, 2, 3 }), d = true, e = 1.5 }
    local decoded, err = json_decode(json_encode(src))
    if not decoded then error("decode failed: " .. tostring(err)) end
    assert(decoded.a == 1 and decoded.b == 'x"y' and #decoded.c == 3 and decoded.d == true,
           "roundtrip mismatch")
    return "encode/decode ok"
  end)

  check("temp dir writable", function()
    local probe = PREFIX .. "selftest.tmp"
    if not write_file(probe, "ok") then error("cannot write " .. probe) end
    local back = read_file(probe)
    os.remove(probe)
    assert(back == "ok", "readback mismatch")
    return TEMP_DIR
  end)

  check("address parsing", function()
    assert(to_addr("0x140000000") == 0x140000000, "hex with 0x")
    assert(to_addr("140000000") == 140000000, "decimal")
    assert(to_addr(4096) == 4096, "number")
    assert(addr_str(0x1000) == "0x1000", "addr_str")
    return "ok"
  end)

  check("protection filter validation", function()
    check_protection("+W-X-C")
    local ok = pcall(check_protection, "+Q")
    assert(not ok, "invalid filter was accepted")
    return "+W-X-C accepted, +Q rejected"
  end)

  check("core CE api present", function()
    local missing = {}
    for _, n in ipairs({ "createMemScan", "createFoundList", "openProcess",
                         "readInteger", "writeInteger", "enumMemoryRegions" }) do
      if not CAPS[n] then missing[#missing + 1] = n end
    end
    assert(#missing == 0, "missing: " .. table.concat(missing, ", "))
    return "all present"
  end)

  check("process attached", function()
    require_process()
    return ("pid=%d name=%s"):format(getOpenedProcessID(), tostring(opened_process_name()))
  end, { optional = true })

  check("memory read", function()
    require_process()
    local regions = enumMemoryRegions()
    for _, r in ipairs(regions) do
      if r.State == 0x1000 and r.Protect and r.Protect ~= 0x01 then
        local b = readBytes(r.BaseAddress, 4, true)
        if b and #b == 4 then
          return ("read 4 bytes at %s"):format(addr_str(r.BaseAddress))
        end
      end
    end
    error("no readable region found")
  end, { optional = true })

  check("memscan construction", function()
    local sc = createMemScan()
    assert(sc, "createMemScan returned nil")
    local has_progress = (type(sc.getProgress) == "function")
    local has_terminate = (type(sc.terminateScan) == "function")
    local has_wait = (type(sc.waitTillDone) == "function")
    pcall(function() sc.destroy() end)
    return ("progress=%s terminate=%s wait=%s")
      :format(tostring(has_progress), tostring(has_terminate), tostring(has_wait))
  end)

  local pass, fail, skip = 0, 0, 0
  for _, c in ipairs(checks) do
    if c.status == "pass" then pass = pass + 1
    elseif c.status == "fail" then fail = fail + 1
    else skip = skip + 1 end
  end
  return {
    checks = checks,
    summary = { passed = pass, failed = fail, skipped = skip },
    healthy = (fail == 0),
  }
end

-- ── process ───────────────────────────────────────────────────────────────
CMD.process_list = function(p)
  local getter = rawget(_G, "getProcesslist") or rawget(_G, "getProcessList")
  if not getter then error("Cheat Engine provides no getProcesslist()", 0) end
  local filter = tostring(p.filter or ""):lower()
  local raw = getter()
  local out = {}
  -- CE has returned several shapes across versions; accept them all.
  for k, v in pairs(raw or {}) do
    local pid, name
    if type(v) == "table" then
      pid  = v.id or v.ID or v.pid or v.PID
      name = v.name or v.Name or v.processname
    elseif type(v) == "string" then
      local hexpid, nm = v:match("^(%x+)%s*%-%s*(.+)$")
      if hexpid and tonumber(k) == nil then
        pid, name = tonumber(hexpid, 16), nm
      elseif hexpid then
        pid, name = tonumber(hexpid, 16), nm
      else
        pid, name = tonumber(k), v
      end
    end
    if name and pid and (filter == "" or name:lower():find(filter, 1, true)) then
      out[#out + 1] = { pid = pid, name = name }
    end
  end
  table.sort(out, function(a, b) return (a.name or ""):lower() < (b.name or ""):lower() end)
  return { count = #out, processes = arr(out) }
end

CMD.process_attach = function(p)
  need("openProcess")
  local target = p.process or p.pid or p.name
  if target == nil then error("missing 'process' (pid or executable name)", 0) end
  if type(target) == "string" and tonumber(target) then target = tonumber(target) end

  local ok, err = pcall(openProcess, target)
  if not ok then error(("openProcess(%s) failed: %s"):format(tostring(target), tostring(err)), 0) end

  local pid = getOpenedProcessID()
  if pid == 0 then
    error(("failed to attach to %s — not running, or Cheat Engine lacks rights " ..
           "(try running CE as administrator)"):format(tostring(target)), 0)
  end
  log_info("attached to pid %d (%s)", pid, tostring(opened_process_name()))
  return {
    pid = pid,
    name = opened_process_name() or tostring(target),
    is64bit = CAPS.targetIs64Bit and targetIs64Bit() or nil,
  }
end

CMD.process_detach = function(_)
  -- Cheat Engine has no closeProcess(). The closest supported action is
  -- detaching the debugger; the process handle itself stays open until CE
  -- attaches to something else.
  if STATE.scan then
    local ok_reset, reset = pcall(CMD.scan_reset, {})
    if not ok_reset then error("could not release the previous scan: " .. tostring(reset), 0) end
    if not reset.reset then
      error("active scan is still cancelling; poll scan_status until it is " ..
            "cancelled, then call scan_reset (or force it explicitly)", 0)
    end
  end
  local detached_debugger = false
  if CAPS.debug_isDebugging and debug_isDebugging() then
    if CAPS.detachIfPossible then detachIfPossible(); detached_debugger = true end
  end
  return {
    debugger_detached = detached_debugger,
    process_handle_released = false,
    note = "Cheat Engine exposes no closeProcess() to Lua. The debugger was " ..
           "detached and scan state cleared; attach elsewhere with process_attach " ..
           "to release the current target.",
  }
end

CMD.process_current = function(_)
  local pid = CAPS.getOpenedProcessID and getOpenedProcessID() or 0
  if pid == 0 then return { attached = false } end
  return {
    attached = true, pid = pid, name = opened_process_name(),
    is64bit = CAPS.targetIs64Bit and targetIs64Bit() or nil,
    debugging = CAPS.debug_isDebugging and debug_isDebugging() or false,
  }
end

CMD.process_modules = function(p)
  require_process(); need("enumModules")
  local filter = tostring(p.filter or ""):lower()
  local out = {}
  for _, m in ipairs(enumModules() or {}) do
    local name = m.Name or m.name or ""
    if filter == "" or name:lower():find(filter, 1, true) then
      out[#out + 1] = {
        name = name,
        base = addr_str(m.Address or m.address),
        size = m.Size or m.size,
        path = m.PathToFile or m.PathFile or m.Path or "",
        is64bit = m.Is64Bit,
      }
    end
  end
  return { count = #out, modules = arr(out) }
end

-- Windows memory constants, for readable region reporting.
local PAGE_NAMES = {
  [0x01] = "NOACCESS", [0x02] = "READONLY", [0x04] = "READWRITE",
  [0x08] = "WRITECOPY", [0x10] = "EXECUTE", [0x20] = "EXECUTE_READ",
  [0x40] = "EXECUTE_READWRITE", [0x80] = "EXECUTE_WRITECOPY",
}
local MEM_COMMIT, MEM_PRIVATE, MEM_MAPPED, MEM_IMAGE = 0x1000, 0x20000, 0x40000, 0x1000000

local function protect_info(prot)
  local base = prot % 0x100
  local flags = PAGE_NAMES[base] or ("0x%X"):format(prot)
  local exec = (base == 0x10 or base == 0x20 or base == 0x40 or base == 0x80)
  local write = (base == 0x04 or base == 0x08 or base == 0x40 or base == 0x80)
  local cow = (base == 0x08 or base == 0x80)
  return flags, exec, write, cow
end

--- Decode a CE protection filter ("+W-X-C") into required/forbidden flags.
--- nil means "don't care".
local function protection_rules(protection)
  local function rule(letter)
    local sign = protection:match("([%+%-%*])" .. letter)
             or protection:match("([%+%-%*])" .. letter:lower())
    if sign == "+" then return true elseif sign == "-" then return false end
    return nil
  end
  return rule("X"), rule("W"), rule("C")
end

--- Measure the committed memory in [sa, so] that a protection filter accepts.
local function measure_range(protection, sa, so)
  local want_x, want_w, want_c = protection_rules(protection or "")
  local bytes, count = 0, 0
  local by_type = { private = 0, image = 0, mapped = 0, other = 0 }
  local committed_in_range = 0
  for _, r in ipairs(enumMemoryRegions() or {}) do
    local base = r.BaseAddress or 0
    local size = r.RegionSize or 0
    -- Clip the region to the requested range.
    local lo = math.max(base, sa or 0)
    local hi = math.min(base + size, so or math.maxinteger)
    if r.State == MEM_COMMIT and hi > lo then
      committed_in_range = committed_in_range + (hi - lo)
      local _, exec, write, cow = protect_info(r.Protect or 0)
      local keep = true
      if want_x ~= nil and exec ~= want_x then keep = false end
      if want_w ~= nil and write ~= want_w then keep = false end
      if want_c ~= nil and cow ~= want_c then keep = false end
      if keep then
        bytes = bytes + (hi - lo)
        count = count + 1
        local k = (r.Type == MEM_PRIVATE and "private") or (r.Type == MEM_IMAGE and "image")
               or (r.Type == MEM_MAPPED and "mapped") or "other"
        by_type[k] = by_type[k] + (hi - lo)
      end
    end
  end
  return { bytes = bytes, regions = count, by_type = by_type,
           committed_in_range = committed_in_range }
end

--- Explain why a scan found nothing, using the actual memory map.
local function diagnose_empty_scan(protection, sa, so)
  local ok, m = pcall(measure_range, protection, sa, so)
  if not ok then return nil end
  local bounded = (sa or 0) > 0 or (so or 0) < 0x7fffffffffffffff
  if m.committed_in_range == 0 then
    return bounded
      and ("The range %s..%s contains no committed memory at all."):format(addr_str(sa), addr_str(so))
      or "The process has no committed memory — is it still running?"
  end
  if m.bytes == 0 then
    local where = bounded and (" in %s..%s"):format(addr_str(sa), addr_str(so)) or ""
    return ("No memory%s matches protection %q, although %.1f MB is committed " ..
            "there. A module's image pages are read-only or executable, so " ..
            "'+W-X-C' excludes them — scan without start/stop, or relax the filter.")
      :format(where, protection, m.committed_in_range / 1048576)
  end
  return ("%.1f MB across %d regions matched protection %q, so the filter is " ..
          "not the problem — check the value type and the value itself.")
    :format(m.bytes / 1048576, m.regions, protection)
end

CMD.process_regions = function(p)
  require_process(); need("enumMemoryRegions")
  local want_writable = (p.writable == true)
  local exclude_exec  = (p.executable == false)
  local out, total = {}, 0
  for _, r in ipairs(enumMemoryRegions() or {}) do
    local flags, exec, write, cow = protect_info(r.Protect or 0)
    local keep = (r.State == MEM_COMMIT)
    if keep and want_writable and not write then keep = false end
    if keep and exclude_exec and exec then keep = false end
    if keep then
      total = total + (r.RegionSize or 0)
      out[#out + 1] = {
        base = addr_str(r.BaseAddress), size = r.RegionSize,
        protect = flags, protect_raw = r.Protect,
        executable = exec, writable = write, copy_on_write = cow,
        type = (r.Type == MEM_PRIVATE and "private")
            or (r.Type == MEM_MAPPED and "mapped")
            or (r.Type == MEM_IMAGE and "image") or r.Type,
        mapped_file = r.Extra,
      }
    end
  end
  return {
    count = #out, total_bytes = total,
    total_mb = math.floor(total / 1048576 * 100) / 100,
    regions = arr(out),
  }
end

-- ── raw memory ────────────────────────────────────────────────────────────
local function read_typed(addr, vt, size, wide, signed)
  vt = tostring(vt or "4byte"):lower()
  if vt == "byte" or vt == "1byte" then return readBytes(addr, 1, false)
  elseif vt == "word" or vt == "2byte" or vt == "short" then return readSmallInteger(addr, signed)
  elseif vt == "dword" or vt == "4byte" or vt == "int" or vt == "integer" then
    return readInteger(addr, signed)
  elseif vt == "qword" or vt == "8byte" or vt == "int64" then return readQword(addr)
  elseif vt == "float" or vt == "single" then return readFloat(addr)
  elseif vt == "double" then return readDouble(addr)
  elseif vt == "pointer" then return addr_str(readPointer(addr))
  elseif vt == "string" or vt == "text" then return readString(addr, size or 64, wide or false)
  elseif vt == "aob" or vt == "bytes" then
    local raw = readBytes(addr, size or 16, true)
    if not raw then return nil end
    local h = {}
    for _, b in ipairs(raw) do h[#h + 1] = ("%02X"):format(b) end
    return table.concat(h, " ")
  end
  error(("unknown value type %q"):format(vt), 0)
end

CMD.memory_read = function(p)
  require_process()
  local addr = to_addr(p.address)
  if not addr then error(("cannot resolve address %q"):format(tostring(p.address)), 0) end
  local vt = tostring(p.type or "4byte"):lower()
  local val = read_typed(addr, vt, tonumber(p.size) or 64, p.wide, p.signed)
  if val == nil then
    error(("read failed at %s — page not readable or process gone"):format(addr_str(addr)), 0)
  end
  return { address = addr_str(addr), type = vt, value = val }
end

CMD.memory_read_batch = function(p)
  require_process()
  local out = {}
  for _, r in ipairs(p.reads or {}) do
    local addr = to_addr(r.address)
    if not addr then
      out[#out + 1] = { address = tostring(r.address), error = "unresolvable address" }
    else
      local vt = tostring(r.type or "4byte"):lower()
      local ok, v = pcall(read_typed, addr, vt, tonumber(r.size) or 64, r.wide, r.signed)
      if ok and v ~= nil then
        out[#out + 1] = { address = addr_str(addr), type = vt, value = v }
      else
        out[#out + 1] = { address = addr_str(addr), type = vt,
                          error = ok and "unreadable" or tostring(v) }
      end
    end
  end
  return { count = #out, reads = arr(out) }
end

CMD.memory_write = function(p)
  require_process()
  local addr = to_addr(p.address)
  if not addr then error(("cannot resolve address %q"):format(tostring(p.address)), 0) end
  if p.value == nil then error("missing 'value'", 0) end
  local vt = tostring(p.type or "4byte"):lower()

  local before = nil
  pcall(function() before = read_typed(addr, vt, 64, p.wide, false) end)

  local function num(what)
    local n = tonumber(p.value)
    if not n then error(("value %q is not a number (type %s)"):format(tostring(p.value), what), 0) end
    return n
  end

  if vt == "byte" or vt == "1byte" then writeBytes(addr, math.floor(num(vt)) % 256)
  elseif vt == "word" or vt == "2byte" or vt == "short" then writeSmallInteger(addr, num(vt))
  elseif vt == "dword" or vt == "4byte" or vt == "int" or vt == "integer" then
    writeInteger(addr, num(vt))
  elseif vt == "qword" or vt == "8byte" or vt == "int64" then writeQword(addr, num(vt))
  elseif vt == "float" or vt == "single" then writeFloat(addr, num(vt))
  elseif vt == "double" then writeDouble(addr, num(vt))
  elseif vt == "string" or vt == "text" then writeString(addr, tostring(p.value), p.wide or false)
  elseif vt == "aob" or vt == "bytes" then
    local bytes = {}
    for h in tostring(p.value):gmatch("%x%x") do bytes[#bytes + 1] = tonumber(h, 16) end
    if #bytes == 0 then error("aob value contained no hex byte pairs", 0) end
    writeBytes(addr, bytes)
  else error(("unknown value type %q"):format(vt), 0) end

  -- Read back so the caller knows the write actually landed.
  local after = nil
  pcall(function() after = read_typed(addr, vt, 64, p.wide, false) end)
  local verified = (after ~= nil) and (tostring(after) == tostring(p.value)
                    or math.abs((tonumber(after) or 0) - (tonumber(p.value) or 0)) < 1e-4)

  log_debug("write %s %s = %s (verified=%s)", vt, addr_str(addr), tostring(p.value), tostring(verified))
  return {
    address = addr_str(addr), type = vt,
    previous = before, requested = p.value, readback = after,
    verified = verified,
    note = (not verified) and "read-back does not match — the game may be " ..
           "overwriting this address every frame; consider table_freeze" or nil,
  }
end

CMD.memory_dump = function(p)
  require_process()
  local addr = to_addr(p.address)
  if not addr then error(("cannot resolve address %q"):format(tostring(p.address)), 0) end
  local size = math.min(math.max(tonumber(p.size) or 256, 1), 65536)
  local bytes = readBytes(addr, size, true)
  if not bytes then
    error(("cannot read %d bytes at %s — page not readable"):format(size, addr_str(addr)), 0)
  end
  local lines = {}
  for i = 1, #bytes, 16 do
    local hx, asc = {}, {}
    for j = i, math.min(i + 15, #bytes) do
      local b = bytes[j]
      hx[#hx + 1] = ("%02X"):format(b)
      asc[#asc + 1] = (b >= 32 and b < 127) and string.char(b) or "."
    end
    lines[#lines + 1] = {
      address = addr_str(addr + i - 1),
      hex = table.concat(hx, " "),
      ascii = table.concat(asc),
    }
  end
  return { address = addr_str(addr), size = #bytes, lines = arr(lines) }
end

CMD.memory_alloc = function(p)
  require_process(); need("allocateMemory")
  local size = tonumber(p.size) or 4096
  local near = to_addr(p.near)
  local a = near and allocateMemory(size, near) or allocateMemory(size)
  if not a or a == 0 then error("allocation failed (target may be out of address space)", 0) end
  STATE.allocs[addr_str(a)] = size
  log_info("allocated %d bytes at %s", size, addr_str(a))
  return { address = addr_str(a), size = size }
end

CMD.memory_free = function(p)
  need("deAlloc")
  local addr = to_addr(p.address)
  if not addr then error("invalid address", 0) end
  deAlloc(addr)
  STATE.allocs[addr_str(addr)] = nil
  return { freed = addr_str(addr) }
end

-- ══════════════════════════════════════════════════════════════════════════
-- SCANNING
-- ══════════════════════════════════════════════════════════════════════════

--- Wait for a memscan in bounded slices. Returns true when the scan finished.
local function scan_wait(sc, seconds)
  if type(sc.waitTillDone) ~= "function" then return true end
  local budget = math.floor(math.max(tonumber(seconds) or 0, 0) * 1000)
  -- A single probe with a tiny timeout tells us whether it is already done.
  local ok, done = pcall(function() return sc.waitTillDone(budget > 0 and 0 or 1) end)
  if not ok then
    -- This build's waitTillDone rejects a timeout argument; fall back to a
    -- blocking wait only when the caller asked us to wait at all.
    if budget <= 0 then return false end
    local ok2 = pcall(function() sc.waitTillDone() end)
    return ok2
  end
  if done then return true end
  local step = 100
  while budget > 0 do
    local slice = math.min(step, budget)
    local ok3, d = pcall(function() return sc.waitTillDone(slice) end)
    if not ok3 then return false end
    if d then return true end
    budget = budget - slice
  end
  return false
end

local function scan_progress(sc)
  if type(sc.getProgress) ~= "function" then return nil end
  local ok, pr = pcall(function() return sc.getProgress() end)
  if not ok or type(pr) ~= "table" then return nil end
  local total, scanned = pr.TotalAddressesToScan, pr.CurrentlyScanned
  local pct
  if total and scanned and total > 0 then
    pct = math.floor(scanned / total * 1000) / 10
  end
  return {
    total_addresses = total, scanned = scanned,
    results_found = pr.ResultsFound, percent = pct,
  }
end

--- Materialise the found list once a scan has finished.
local function scan_finalize(s)
  if s.done then return end
  s.done = true
  s.elapsed_ms = now_ms() - s.started_ms

  if s.cancelling then
    s.cancelling = false
    s.cancelled = true
    s.error = "cancelled by client"
    log_info("scan cancellation completed in %dms", s.elapsed_ms)
    return
  end

  local sc = s.scanner
  local err
  pcall(function() err = sc.ErrorString end)
  if err and err ~= "" then
    s.error = tostring(err)
    -- CE reports "No readable memory found ... attached to a live process" for
    -- what is usually an empty range/protection intersection. Say what is
    -- actually wrong, using the real memory map.
    if s.error:lower():find("readable memory", 1, true) then
      s.diagnosis = diagnose_empty_scan(s.protection, s.start_addr, s.stop_addr)
    end
    log_error("scan failed: %s%s", s.error, s.diagnosis and (" | " .. s.diagnosis) or "")
    return
  end

  -- An unknown-initial-value scan records a snapshot, not addresses. CE's own
  -- GUI shows no rows for it either; results only exist after a next scan.
  local region_scan = false
  pcall(function() region_scan = (sc.LastScanWasRegionScan == true) end)
  s.region_scan = region_scan

  if region_scan then
    s.count = 0
    s.note = "Unknown-initial-value scan stores a snapshot only; it produces no " ..
             "addresses until you narrow it with scan_next (changed/unchanged/...)."
    log_info("scan snapshot complete in %dms (region scan, no addresses yet)", s.elapsed_ms)
    return
  end

  local ok, e = pcall(function()
    if not s.found then s.found = createFoundList(sc) end
    s.found.initialize()
    s.count = s.found.Count
  end)
  if not ok then
    s.error = "could not open result list: " .. tostring(e)
    s.count = 0
    log_error("%s", s.error)
    return
  end
  log_info("scan complete in %dms — %d results", s.elapsed_ms, s.count or 0)
end

local function scan_state_view(s, extra)
  local status
  if s.cancelling then status = "cancelling"
  elseif s.cancelled then status = "cancelled"
  elseif s.done then status = s.error and "error" or "done"
  else status = "running" end
  local v = {
    status = status,
    phase = s.phase,
    value_type = s.value_type, scan_type = s.scan_type,
    protection = s.protection, alignment = s.alignment,
    count = s.count, region_scan = s.region_scan,
    error = s.error, note = s.note, diagnosis = s.diagnosis,
    elapsed_ms = s.elapsed_ms or (now_ms() - s.started_ms),
  }
  if not s.done then v.progress = scan_progress(s.scanner) end
  for k, val in pairs(extra or {}) do v[k] = val end
  return v
end

--- Apply MEM_PRIVATE / MEM_IMAGE / MEM_MAPPED filtering.
local REGION_PRESETS = {
  private = { MEM_PRIVATE = true,  MEM_IMAGE = false, MEM_MAPPED = false },
  image   = { MEM_PRIVATE = false, MEM_IMAGE = true,  MEM_MAPPED = false },
  mapped  = { MEM_PRIVATE = false, MEM_IMAGE = false, MEM_MAPPED = true  },
  all     = { MEM_PRIVATE = true,  MEM_IMAGE = true,  MEM_MAPPED = true  },
  ["private+image"] = { MEM_PRIVATE = true, MEM_IMAGE = true, MEM_MAPPED = false },
}

local function apply_regions(pref)
  if pref == nil then return nil end
  local key = tostring(pref):lower()
  if key == "default" then
    if CAPS.setSpecialScanOptionsOverride then setSpecialScanOptionsOverride({}) end
    return "default"
  end
  local preset = REGION_PRESETS[key]
  if not preset then
    error(("unknown regions %q — use private, image, mapped, private+image, all or default"):format(key), 0)
  end
  if not CAPS.setSpecialScanOptionsOverride then
    log_warn("regions=%s ignored: this CE build has no setSpecialScanOptionsOverride", key)
    return nil
  end
  setSpecialScanOptionsOverride(preset)
  return key
end

--- Resolve the fast-scan alignment for a value type.
local function resolve_alignment(align, vtname)
  local a = align
  if a == nil or tostring(a):lower() == "auto" then
    local sz = VTYPE_SIZE[vtname] or 4
    return (fsmAligned or 1), tostring(math.min(sz, 4)), ("auto(%d)"):format(math.min(sz, 4))
  end
  local s = tostring(a):lower()
  if s == "none" or s == "0" or s == "false" then
    return (fsmNotAligned or 0), "", "none"
  end
  local n = tonumber(s)
  if n and n >= 1 then
    return (fsmAligned or 1), tostring(math.floor(n)), tostring(math.floor(n))
  end
  error(("invalid alignment %q — use 'auto', 'none', or a byte count like 4"):format(tostring(align)), 0)
end

CMD.scan_first = function(p)
  require_process(); need("createMemScan"); need("createFoundList")

  local vtname = tostring(p.value_type or "4byte"):lower()
  local vt = VTYPES[vtname]
  if not vt then error(("unknown value_type %q"):format(vtname), 0) end

  local stname = tostring(p.scan_type or "exact"):lower()
  local st = STYPES[stname]
  if not st then error(("unknown scan_type %q"):format(stname), 0) end
  if NEXT_ONLY[stname] then
    error(("scan_type %q is only valid on scan_next — start with 'unknown' or 'exact'"):format(stname), 0)
  end
  if NEEDS_VALUE[stname] and p.value == nil then
    error(("scan_type %q requires a 'value'"):format(stname), 0)
  end
  if stname == "between" and p.value2 == nil then
    error("scan_type 'between' requires both 'value' and 'value2'", 0)
  end

  local protection = check_protection(p.protection == nil and "+W-X-C" or p.protection)
  local align_mode, align_param, align_label = resolve_alignment(p.alignment, vtname)
  local rounding = ROUNDING[tostring(p.rounding or "rounded"):lower()] or rtRounded

  -- Replace any previous scan so we never leak a scanner + result file.
  if STATE.scan then
    local ok_reset, reset = pcall(CMD.scan_reset, {})
    if not ok_reset then error("could not release the previous scan: " .. tostring(reset), 0) end
    if not reset.reset then
      error("previous scan is still cancelling; poll scan_status until it is " ..
            "cancelled, then call scan_reset (or force it explicitly)", 0)
    end
  end

  local regions_applied = apply_regions(p.regions)

  local sa = to_addr(p.start) or 0
  local so = to_addr(p.stop) or 0x7fffffffffffffff
  if so <= sa then error("'stop' must be greater than 'start'", 0) end

  local scanner = createMemScan()
  if p.only_one == true then
    if type(scanner.setOnlyOneResult) == "function" then scanner.setOnlyOneResult(true)
    else scanner.OnlyOneResult = true end
  end

  local s = {
    scanner = scanner, found = nil, phase = "first",
    value_type = vtname, scan_type = stname,
    protection = protection, alignment = align_label,
    regions = regions_applied,
    start_addr = sa, stop_addr = so,
    started_ms = now_ms(), done = false, count = nil,
  }
  STATE.scan = s

  log_info("scan_first %s/%s protection=%s alignment=%s range=%s..%s regions=%s",
           vtname, stname, protection, align_label, addr_str(sa), addr_str(so),
           tostring(regions_applied or "ce-default"))

  local ok, err = pcall(function()
    scanner.firstScan(
      st, vt, rounding,
      p.value ~= nil and tostring(p.value) or "",
      p.value2 ~= nil and tostring(p.value2) or "",
      sa, so, protection,
      align_mode, align_param,
      p.hex == true, true, p.unicode == true, p.case_sensitive == true)
  end)
  if not ok then
    STATE.scan = nil
    pcall(function() scanner.destroy() end)
    error("firstScan rejected by Cheat Engine: " .. tostring(err), 0)
  end

  local finished = scan_wait(scanner, p.wait == nil and 3.0 or tonumber(p.wait) or 0)
  if finished then scan_finalize(s) end

  local view = scan_state_view(s)
  if not s.done then
    view.hint = "Scan still running. Poll scan_status; abort with scan_cancel."
  elseif s.region_scan then
    view.hint = "Change the value in the target, then call scan_next with " ..
                "scan_type 'changed' (or 'unchanged'/'increased'/'decreased')."
  elseif (s.count or 0) == 0 and not s.error then
    view.diagnosis = diagnose_empty_scan(s.protection, s.start_addr, s.stop_addr)
    view.hint = "No matches — see 'diagnosis'. The default +W-X-C excludes " ..
                "executable and copy-on-write pages, so a module's own image " ..
                "range will never match it."
  end
  return view
end

CMD.scan_next = function(p)
  local s = STATE.scan
  if s and s.cancelling then error("previous scan is still cancelling; poll scan_status", 0) end
  if s and s.cancelled then error("previous scan was cancelled; call scan_reset first", 0) end
  if not s then error("no active scan — call scan_first first", 0) end
  if s.error then error("previous scan failed: " .. tostring(s.error), 0) end
  if not s.done then
    error("previous scan is still running — poll scan_status until status is 'done'", 0)
  end

  local stname = tostring(p.scan_type or "exact"):lower()
  local st = STYPES[stname]
  if not st then error(("unknown scan_type %q"):format(stname), 0) end
  if stname == "unknown" or stname == "unknownvalue" then
    error("scan_type 'unknown' is only valid on scan_first", 0)
  end
  if NEEDS_VALUE[stname] and p.value == nil then
    error(("scan_type %q requires a 'value'"):format(stname), 0)
  end

  local rounding = ROUNDING[tostring(p.rounding or "rounded"):lower()] or rtRounded

  -- The result file must be closed before the scanner rewrites it.
  if s.found then pcall(function() s.found.deinitialize() end) end

  s.phase = "next"
  s.scan_type = stname
  s.done = false
  s.error = nil
  s.note = nil
  s.region_scan = false
  s.started_ms = now_ms()
  s.elapsed_ms = nil

  log_info("scan_next %s value=%s compare_to=%s", stname,
           tostring(p.value), tostring(p.compare_to))

  local ok, err = pcall(function()
    s.scanner.nextScan(
      st, rounding,
      p.value ~= nil and tostring(p.value) or "",
      p.value2 ~= nil and tostring(p.value2) or "",
      p.hex == true, true, p.unicode == true, p.case_sensitive == true,
      p.percentage == true, p.compare_to)
  end)
  if not ok then
    s.done = true
    s.error = "nextScan rejected by Cheat Engine: " .. tostring(err)
    error(s.error, 0)
  end

  local finished = scan_wait(s.scanner, p.wait == nil and 3.0 or tonumber(p.wait) or 0)
  if finished then scan_finalize(s) end

  local view = scan_state_view(s)
  if not s.done then
    view.hint = "Scan still running. Poll scan_status; abort with scan_cancel."
  elseif (s.count or 0) > 0 and (s.count or 0) <= 50 then
    view.hint = "Few enough results to inspect — call scan_results."
  end
  return view
end

CMD.scan_status = function(_)
  local s = STATE.scan
  if not s then
    -- Fall back to reporting the GUI scan, if the user is driving CE by hand.
    if CAPS.getCurrentMemscan then
      local ok, ms = pcall(getCurrentMemscan)
      if ok and ms then
        local fl
        pcall(function() fl = ms.FoundList end)
        local cnt
        pcall(function() cnt = fl and fl.Count or ms.FoundCount end)
        return { status = "none", source = "gui", gui_count = cnt,
                 note = "No MCP scan active; reporting Cheat Engine's GUI scan." }
      end
    end
    return { status = "none" }
  end
  if not s.done then
    if scan_wait(s.scanner, 0) then scan_finalize(s) end
  end
  return scan_state_view(s, { source = "mcp" })
end

--- Stop a scanner. Graceful by default: Cheat Engine pops a modal warning and
--- recommends a restart after a *forced* terminate, so only force on request.
local function stop_scanner(s, force)
  if not s or not s.scanner then return false, false, "scanner unavailable" end
  if s.done then return false, false, "scanner already finished" end
  if type(s.scanner.terminateScan) ~= "function" then
    return false, false, "terminateScan is unavailable"
  end
  local ok, err = pcall(function() s.scanner.terminateScan(force == true) end)
  if not ok then return false, false, tostring(err) end
  return true, (force == true), nil
end

CMD.scan_cancel = function(p)
  local s = STATE.scan
  if not s then return { cancelled = false, note = "no active scan" } end
  if s.done then
    return { cancelled = false, already_finished = true,
             note = "The scan had already finished; nothing to terminate. " ..
                    "Use scan_reset to release its results." }
  end
  local force = (p.force == true)
  if s.cancelling and not force then
    return { cancelled = true, status = "cancelling", forced = false,
             note = "Cancellation is already pending. Poll scan_status; " ..
                    "retry with force=true only if it will not finish." }
  end
  local terminated, forced, terminate_error = stop_scanner(s, force)
  if force and not terminated then
    s.cancelling = true
    log_error("forced scan termination failed: %s", tostring(terminate_error))
    return {
      cancelled = false, status = "cancelling", terminate_called = false,
      forced = false, error = "forced termination failed: " .. tostring(terminate_error),
      note = "The scanner was retained and may still be running. Poll scan_status; " ..
             "restart Cheat Engine if it cannot be stopped safely.",
    }
  end
  if forced then
    s.done = true
    s.cancelled = true
    s.error = "cancelled by client"
  else
    s.cancelling = true
  end
  log_warn("scan cancelled by client (terminated=%s force=%s)",
           tostring(terminated), tostring(force))

  local note
  if not terminated then
    note = "Cheat Engine could not accept terminateScan (" ..
           tostring(terminate_error) .. "); the scan may still be running. " ..
           "Press 'New Scan' in the Cheat Engine window."
  elseif forced then
    note = "Scan force-terminated. Cheat Engine will warn that subsequent scans " ..
           "may misbehave and recommend a restart — take that seriously."
  else
    note = "Scan asked to stop. It unwinds at the next safe point; poll " ..
           "scan_status. If it will not stop, retry with force=true (Cheat " ..
           "Engine then recommends restarting it)."
  end
  return {
    cancelled = true, status = forced and "cancelled" or "cancelling",
    terminate_called = terminated, forced = forced, note = note,
  }
end

CMD.scan_results = function(p)
  local fl, source, total
  local s = STATE.scan

  if s and s.found and s.done and not s.error then
    fl, source = s.found, "mcp"
  elseif s and not s.done then
    return { results = arr({}), total = 0, source = "mcp",
             status = s.cancelling and "cancelling" or "running",
             progress = scan_progress(s.scanner),
             note = s.cancelling and
                    "Scan cancellation is still unwinding; poll scan_status."
                    or "Scan still running — poll scan_status." }
  elseif s and s.region_scan then
    return { results = arr({}), total = 0, source = "mcp", status = "snapshot",
             note = s.note }
  else
    if not CAPS.getCurrentMemscan then error("no active scan", 0) end
    local ok, ms = pcall(getCurrentMemscan)
    if not ok or not ms then error("no active MCP scan and no Cheat Engine GUI scan", 0) end
    local ok2, gfl = pcall(function() return ms.FoundList end)
    if not ok2 or not gfl then
      error("no active MCP scan; Cheat Engine's GUI scan has no result list open", 0)
    end
    fl, source = gfl, "gui"
  end

  local ok, cnt = pcall(function() return fl.Count end)
  if not ok then error("result list is not readable: " .. tostring(cnt), 0) end
  total = cnt or 0

  -- A scan still writing its result file can report a nonsense count.
  if total < 0 or total > 4294967295 then
    error(("result list reports an implausible count (%s) — the scan is probably " ..
           "still finishing. Poll scan_status first."):format(tostring(total)), 0)
  end

  local limit = math.min(math.max(tonumber(p.limit) or 100, 1), 1000)
  local offset = math.max(tonumber(p.offset) or 0, 0)
  local out = {}
  for i = offset, math.min(offset + limit - 1, total - 1) do
    local okr, a, v = pcall(function() return fl.Address[i], fl.Value[i] end)
    if okr then out[#out + 1] = { index = i, address = a, value = v }
    else out[#out + 1] = { index = i, error = tostring(a) } end
  end
  return {
    results = arr(out), total = total, offset = offset, limit = limit,
    returned = #out, source = source,
    has_more = (offset + #out) < total,
  }
end

CMD.scan_save_results = function(p)
  local s = STATE.scan
  if not s or not s.done then error("no completed scan to save", 0) end
  local name = tostring(p.name or "")
  if name == "" then error("missing 'name'", 0) end
  if type(s.scanner.saveCurrentResults) ~= "function" then
    error("this Cheat Engine build has no saveCurrentResults()", 0)
  end
  s.scanner.saveCurrentResults(name)
  log_info("saved scan results as %q", name)
  return { saved = name,
           note = ("Pass compare_to=%q to scan_next to compare against this snapshot."):format(name) }
end

CMD.scan_reset = function(p)
  local s = STATE.scan
  if not s then return { reset = false, note = "no active scan" } end
  if not s.done and scan_wait(s.scanner, 0) then scan_finalize(s) end
  local was_running = not s.done
  local force = p and p.force == true
  local terminated = false
  if was_running then
    if force then
      local _, forced, terminate_error
      terminated, forced, terminate_error = stop_scanner(s, true)
      if not terminated or not forced then
        s.cancelling = true
        return {
          reset = false, was_running = true, status = "cancelling",
          terminate_called = false, forced = false,
          error = "forced termination failed: " .. tostring(terminate_error),
          note = "The scanner was retained because Cheat Engine did not confirm " ..
                 "termination. Restart Cheat Engine if it cannot be stopped safely.",
        }
      end
      s.done = true
      s.cancelling = false
      s.cancelled = true
      s.error = "cancelled by client"
    else
      if not s.cancelling then
        terminated = stop_scanner(s, false)
        s.cancelling = true
      end
      return {
        reset = false, was_running = true, status = "cancelling",
        terminate_called = terminated,
        note = "The running scan was asked to stop but has not finished " ..
               "unwinding. Poll scan_status, then call scan_reset again; use " ..
               "force=true only if graceful cancellation will not finish.",
      }
    end
  end
  if s.found then pcall(function() s.found.deinitialize() end) end
  if s.found then pcall(function() s.found.destroy() end) end
  if s.scanner then pcall(function() s.scanner.destroy() end) end
  STATE.scan = nil
  log_info("scan reset — scanner and result file released (was_running=%s)",
           tostring(was_running))
  return {
    reset = true, was_running = was_running, terminate_called = terminated,
    note = was_running and "A running scan was asked to stop before release." or nil,
  }
end

--- Report how much memory a scan with these settings would actually cover.
CMD.scan_estimate = function(p)
  require_process(); need("enumMemoryRegions")
  local protection = check_protection(p.protection == nil and "+W-X-C" or p.protection)
  local vtname = tostring(p.value_type or "4byte"):lower()
  local _, _, align_label = resolve_alignment(p.alignment, vtname)
  local stride = tonumber(align_label:match("(%d+)")) or 1

  local sa = to_addr(p.start) or 0
  local so = to_addr(p.stop) or 0x7fffffffffffffff
  local m = measure_range(protection, sa, so)
  local bytes, count, by_type = m.bytes, m.regions, m.by_type

  local addresses = math.floor(bytes / math.max(stride, 1))
  -- CE's unknown-value result file stores the value plus bookkeeping per address.
  local snapshot_bytes = addresses * ((VTYPE_SIZE[vtname] or 4) + 4)
  return {
    protection = protection, alignment = align_label, value_type = vtname,
    regions = count,
    bytes = bytes, mb = math.floor(bytes / 1048576 * 100) / 100,
    addresses_to_scan = addresses,
    by_type_mb = {
      private = math.floor(by_type.private / 1048576 * 100) / 100,
      image = math.floor(by_type.image / 1048576 * 100) / 100,
      mapped = math.floor(by_type.mapped / 1048576 * 100) / 100,
      other = math.floor(by_type.other / 1048576 * 100) / 100,
    },
    unknown_scan_disk_mb = math.floor(snapshot_bytes / 1048576 * 100) / 100,
    advice = snapshot_bytes > 4 * 1024 * 1024 * 1024
      and "An unknown-value scan here would write multiple GB. Narrow it with " ..
          "regions='private', a tighter start/stop, or a specific value."
      or nil,
  }
end

CMD.scan_aob = function(p)
  require_process(); need("AOBScan")
  if not p.pattern then error("missing 'pattern'", 0) end
  local protection = check_protection(p.protection == nil and "+X-C" or p.protection)
  local t0 = now_ms()
  local results = AOBScan(p.pattern, protection)
  local out = {}
  if results then
    local ok, cnt = pcall(function() return results.Count end)
    if ok then
      for i = 0, math.min(cnt, 5000) - 1 do out[#out + 1] = results[i] end
    end
    pcall(function() results.destroy() end)
  end
  log_info("scan_aob %q -> %d hits in %dms", tostring(p.pattern), #out, now_ms() - t0)
  return {
    pattern = p.pattern, protection = protection,
    count = #out, results = arr(out), elapsed_ms = now_ms() - t0,
  }
end

-- ── cheat table ───────────────────────────────────────────────────────────
local function find_record(id)
  local al = getAddressList()
  for i = 0, al.Count - 1 do
    local e = al.getMemoryRecord(i)
    if e.ID == id then return e, al end
  end
  return nil, al
end

local function need_record(id)
  local n = tonumber(id)
  if not n then error("missing or non-numeric 'id'", 0) end
  local e = find_record(n)
  if not e then error(("cheat table has no entry with id %d — call table_list"):format(n), 0) end
  return e, n
end

CMD.table_list = function(_)
  need("getAddressList")
  local al = getAddressList()
  local out = {}
  for i = 0, al.Count - 1 do
    local e = al.getMemoryRecord(i)
    local v
    pcall(function() v = e.Value end)
    out[#out + 1] = {
      id = e.ID, index = i, description = e.Description,
      address = e.AddressString, value = v, type = e.Type, active = e.Active,
    }
  end
  return { count = #out, entries = arr(out) }
end

CMD.table_add = function(p)
  need("getAddressList")
  if p.address == nil then error("missing 'address'", 0) end
  local al = getAddressList()
  local mr = al.createMemoryRecord()
  mr.Description = tostring(p.description or "MCP entry")
  mr.Address = tostring(p.address)
  local vtname = tostring(p.type or "4byte"):lower()
  mr.Type = VTYPES[vtname] or vtDword
  if p.value ~= nil then pcall(function() mr.Value = tostring(p.value) end)  end
  local shown
  pcall(function() shown = mr.Value end)
  return { id = mr.ID, description = mr.Description,
           address = mr.AddressString, type = vtname, value = shown }
end

CMD.table_remove = function(p)
  local e, id = need_record(p.id)
  local al = getAddressList()
  al.delete(e)
  return { removed = id }
end

CMD.table_set_value = function(p)
  local e, id = need_record(p.id)
  if p.value == nil then error("missing 'value'", 0) end
  e.Value = tostring(p.value)
  local back
  pcall(function() back = e.Value end)
  return { id = id, requested = p.value, readback = back }
end

CMD.table_freeze = function(p)
  local e, id = need_record(p.id)
  local frozen = (p.frozen ~= false)
  e.Active = frozen
  return { id = id, frozen = frozen, active = e.Active }
end

CMD.table_enable = function(p)
  local e, id = need_record(p.id)
  e.Active = (p.active ~= false)
  return { id = id, active = e.Active }
end

CMD.table_hotkey = function(p)
  local e, id = need_record(p.id)
  local keys = p.keys
  if type(keys) ~= "table" then keys = { tonumber(keys) or 0 } end
  local action = tonumber(p.action) or 1
  local ok, err = pcall(function()
    if p.value ~= nil then e.createHotkey(keys, action, tostring(p.value))
    else e.createHotkey(keys, action) end
  end)
  if not ok then error("createHotkey failed: " .. tostring(err), 0) end
  return { id = id, action = action, keys = arr(keys) }
end

CMD.table_save = function(p)
  need("saveTable")
  if not p.path then error("missing 'path'", 0) end
  saveTable(p.path)
  return { saved = p.path }
end

CMD.table_load = function(p)
  need("loadTable")
  if not p.path then error("missing 'path'", 0) end
  if not file_exists(p.path) then error(("no such file: %s"):format(p.path), 0) end
  loadTable(p.path, p.merge == true)
  return { loaded = p.path, count = getAddressList().Count }
end

CMD.table_clear = function(_)
  need("getAddressList")
  local al = getAddressList()
  local removed = 0
  while al.Count > 0 do
    al.delete(al.getMemoryRecord(0))
    removed = removed + 1
    if removed > 100000 then break end
  end
  return { cleared = true, removed = removed }
end

-- ── pointers ──────────────────────────────────────────────────────────────
CMD.pointer_resolve = function(p)
  require_process()
  local base = to_addr(p.base)
  if not base then error(("cannot resolve base %q"):format(tostring(p.base)), 0) end
  local offsets = p.offsets or {}
  local cur = base
  local chain = { { address = addr_str(cur), step = "base" } }
  for i, off in ipairs(offsets) do
    local ptr = readPointer(cur)
    if not ptr or ptr == 0 then
      return {
        base = addr_str(base), offsets = arr(offsets), valid = false,
        broken_at_level = i, chain = arr(chain),
        error = ("pointer at %s is null — chain breaks at level %d"):format(addr_str(cur), i),
      }
    end
    cur = ptr + math.floor(tonumber(off) or 0)
    chain[#chain + 1] = {
      address = addr_str(cur), step = ("[%s]+0x%X"):format(addr_str(ptr), math.floor(tonumber(off) or 0)),
      deref = addr_str(ptr),
    }
  end
  return {
    base = addr_str(base), offsets = arr(offsets),
    resolved = addr_str(cur), valid = true, chain = arr(chain),
  }
end

CMD.pointer_scan = function(_)
  error("Cheat Engine exposes no pointer-scan API to Lua (there is no " ..
        "createPointerScan). Run the pointer scan from CE's UI: right-click the " ..
        "address -> 'Pointer scan for this address'. Use pointer_resolve to " ..
        "verify a chain once you have one.", 0)
end

-- ── disassembler / assembler ──────────────────────────────────────────────
CMD.disassemble = function(p)
  require_process(); need("disassemble"); need("getInstructionSize")
  local addr = to_addr(p.address)
  if not addr then error(("cannot resolve address %q"):format(tostring(p.address)), 0) end
  local count = math.min(math.max(tonumber(p.count) or 16, 1), 512)
  local out, cur = {}, addr
  for _ = 1, count do
    local ok, text = pcall(_G.disassemble, cur)
    if not ok then break end
    local size = getInstructionSize(cur) or 1
    -- CE returns "address - bytes - opcode : extra"; split it for readability.
    local bytes, opcode = tostring(text):match("^[^%-]+%-%s*([%x%s]-)%s*%-%s*(.+)$")
    out[#out + 1] = {
      address = addr_str(cur),
      bytes = bytes and bytes:match("^%s*(.-)%s*$") or nil,
      instruction = opcode or tostring(text),
      raw = (opcode == nil) and tostring(text) or nil,
      size = size,
    }
    cur = cur + (size > 0 and size or 1)
  end
  return { address = addr_str(addr), count = #out, instructions = arr(out) }
end

CMD.assemble = function(p)
  need("assemble")
  if not p.code then error("missing 'code'", 0) end
  local addr = to_addr(p.address) or 0
  local ok, bytes = pcall(_G.assemble, p.code, addr)
  if not ok or not bytes then
    error(("assemble failed for %q: %s"):format(tostring(p.code), tostring(bytes)), 0)
  end
  local h = {}
  for _, b in ipairs(bytes) do h[#h + 1] = ("%02X"):format(b) end
  return { code = p.code, address = addr_str(addr),
           bytes = table.concat(h, " "), length = #bytes }
end

CMD.auto_assemble = function(p)
  need("autoAssemble")
  if not p.script then error("missing 'script'", 0) end
  local enable = (p.enable ~= false)

  if rawget(_G, "autoAssembleCheck") then
    local okc, cerr = autoAssembleCheck(p.script, enable, false)
    if okc == false then
      error(("auto-assembler script has a syntax error: %s"):format(tostring(cerr)), 0)
    end
  end

  -- autoAssemble(text, disableInfo): passing the [DISABLE] flag runs the
  -- disable section, which is how a script is reverted.
  local ok, err = pcall(function() return autoAssemble(p.script, not enable) end)
  if not ok then error("auto-assemble raised: " .. tostring(err), 0) end
  if err == false or err == nil then
    error("auto-assemble failed — check that the aobscan/module names resolve " ..
          "against the attached process", 0)
  end
  log_info("auto_assemble %s ok", enable and "[ENABLE]" or "[DISABLE]")
  return { success = true, section = enable and "ENABLE" or "DISABLE" }
end

-- ── debugger ──────────────────────────────────────────────────────────────
-- CE has no findWhatWrites()/findWhatAccesses() in Lua. Build the equivalent
-- from a data breakpoint plus a callback, run as a background job so the
-- bridge keeps answering while the trace collects.
local function start_watchpoint(p, trigger, kind)
  require_process()
  need("debug_setBreakpoint"); need("debug_removeBreakpoint")

  local addr = to_addr(p.address)
  if not addr then error(("cannot resolve address %q"):format(tostring(p.address)), 0) end
  local size = tonumber(p.size) or 4
  if size ~= 1 and size ~= 2 and size ~= 4 and size ~= 8 then
    error("size must be 1, 2, 4 or 8 (hardware breakpoints only support these)", 0)
  end
  local duration = math.min(math.max(tonumber(p.duration) or 5, 1), 120)

  if not debug_isDebugging() then
    -- VEH debugging is the least intrusive interface for most games.
    local iface = tonumber(p.debugger) or 2
    local ok, err = pcall(debugProcess, iface)
    if not ok then error("could not start the debugger: " .. tostring(err), 0) end
  end

  local job = job_new(kind, {
    address = addr_str(addr), size = size, duration_s = duration, trigger = kind,
  })
  local seen = {}

  local function on_hit()
    local rip = rawget(_G, "RIP") or rawget(_G, "EIP")
    if rip then
      local key = tostring(rip)
      local rec = seen[key]
      if rec then
        rec.hits = rec.hits + 1
      else
        local txt
        pcall(function() txt = _G.disassemble(rip) end)
        rec = {
          instruction_address = addr_str(rip),
          instruction = txt and tostring(txt):match("%-%s*[%x%s]-%s*%-%s*(.+)$") or txt,
          hits = 1,
        }
        -- Capture register state once, so the caller can work out the base pointer.
        local regs = {}
        for _, r in ipairs({ "RAX", "RBX", "RCX", "RDX", "RSI", "RDI", "RBP", "RSP",
                             "EAX", "EBX", "ECX", "EDX", "ESI", "EDI", "EBP", "ESP" }) do
          local v = rawget(_G, r)
          if v then regs[r] = addr_str(v) end
        end
        rec.registers = regs
        seen[key] = rec
        job.data[#job.data + 1] = rec
        job.count = #job.data
      end
    end
    if CAPS.debug_continueFromBreakpoint then
      pcall(debug_continueFromBreakpoint, co_run)
    end
    return 1  -- handled; do not update the CE UI
  end

  local ok, err = pcall(debug_setBreakpoint, addr, size, trigger, on_hit)
  if not ok then
    job_finish(job, "error", "debug_setBreakpoint failed: " .. tostring(err))
    error(job.error, 0)
  end

  job.cleanup = function()
    pcall(debug_removeBreakpoint, addr)
  end

  -- Stop the trace after `duration` without blocking the dispatcher.
  local timer = createTimer(nil)
  timer.Interval = duration * 1000
  timer.OnTimer = function()
    job_finish(job, "done")
  end
  job.timer = timer

  return {
    job_id = job.id, kind = kind, status = "running",
    address = addr_str(addr), duration_s = duration,
    hint = ("Trigger the value in-game now. Poll job_status with job_id=%d; " ..
            "results arrive as instructions hit the breakpoint."):format(job.id),
  }
end

CMD.find_what_writes = function(p)
  return start_watchpoint(p, bptWrite, "find_what_writes")
end

CMD.find_what_accesses = function(p)
  return start_watchpoint(p, bptAccess, "find_what_accesses")
end

CMD.breakpoint = function(p)
  require_process()
  need("debug_setBreakpoint")
  local addr = to_addr(p.address)
  if not addr then error(("cannot resolve address %q"):format(tostring(p.address)), 0) end
  if p.remove then
    debug_removeBreakpoint(addr)
    return { removed = addr_str(addr) }
  end
  if not debug_isDebugging() then debugProcess(tonumber(p.debugger) or 2) end
  local trig = bptExecute
  local tname = tostring(p.trigger or "execute"):lower()
  if tname == "write" then trig = bptWrite elseif tname == "access" then trig = bptAccess end
  debug_setBreakpoint(addr, tonumber(p.size) or 1, trig)
  return { breakpoint = addr_str(addr), trigger = tname }
end

CMD.breakpoint_list = function(_)
  if not CAPS.debug_getBreakpointList then error("debug_getBreakpointList unavailable", 0) end
  local out = {}
  for _, a in pairs(debug_getBreakpointList() or {}) do out[#out + 1] = addr_str(a) end
  return { count = #out, breakpoints = arr(out) }
end

-- ── jobs ──────────────────────────────────────────────────────────────────
CMD.job_status = function(p)
  local id = tonumber(p.job_id)
  if not id then error("missing 'job_id'", 0) end
  local job = STATE.jobs[id]
  if not job then error(("no job with id %d"):format(id), 0) end
  return job_view(job, p.limit)
end

CMD.job_list = function(_)
  local out = {}
  for id, j in pairs(STATE.jobs) do
    out[#out + 1] = { job_id = id, kind = j.kind, status = j.status,
                      count = j.count, started = j.started }
  end
  table.sort(out, function(a, b) return a.job_id < b.job_id end)
  return { count = #out, jobs = arr(out) }
end

CMD.job_cancel = function(p)
  local id = tonumber(p.job_id)
  if not id then error("missing 'job_id'", 0) end
  local job = STATE.jobs[id]
  if not job then error(("no job with id %d"):format(id), 0) end
  job_finish(job, "cancelled")
  return job_view(job, p.limit)
end

-- ── Mono / Unity ──────────────────────────────────────────────────────────
CMD.mono_init = function(_)
  require_process()
  if not CAPS.LaunchMonoDataCollector then
    error("Mono support is not loaded — this needs CE's monoscript.lua in the " ..
          "autorun folder and a Mono/Unity target", 0)
  end
  local ok, res = pcall(LaunchMonoDataCollector)
  if not ok then error("LaunchMonoDataCollector failed: " .. tostring(res), 0) end
  return { initialized = true, result = res and tostring(res) or nil }
end

CMD.mono_classes = function(p)
  if not rawget(_G, "mono_enumDomains") then
    error("mono not available — call mono_init first (target must be Mono/Unity)", 0)
  end
  local filter = tostring(p.filter or ""):lower()
  local limit = math.min(tonumber(p.limit) or 500, 5000)
  local out = {}
  for _, dom in ipairs(mono_enumDomains() or {}) do
    for _, asm in ipairs(mono_enumAssemblies(dom) or {}) do
      local img = mono_getImageFromAssembly(asm)
      for _, cls in ipairs(mono_image_enumClasses(img) or {}) do
        local name = cls.name or (mono_class_getName and mono_class_getName(cls.class or cls))
        local ns = cls.namespace or ""
        if name and (filter == "" or name:lower():find(filter, 1, true)
                     or ns:lower():find(filter, 1, true)) then
          out[#out + 1] = { namespace = ns, name = name, class = addr_str(cls.class or cls) }
          if #out >= limit then
            return { count = #out, truncated = true, classes = arr(out) }
          end
        end
      end
    end
  end
  return { count = #out, truncated = false, classes = arr(out) }
end

-- ── misc ──────────────────────────────────────────────────────────────────
CMD.speedhack = function(p)
  require_process(); need("speedhack_setSpeed")
  local speed = tonumber(p.speed)
  if not speed then error("missing numeric 'speed'", 0) end
  if speed <= 0 or speed > 1000 then error("speed must be between 0 (exclusive) and 1000", 0) end
  speedhack_setSpeed(speed)
  return { speed = speed }
end

CMD.lua_execute = function(p)
  if not p.code then error("missing 'code'", 0) end
  local output = {}
  local real_print = print
  _G.print = function(...)
    local a = {}
    for i = 1, select("#", ...) do a[i] = tostring((select(i, ...))) end
    output[#output + 1] = table.concat(a, "\t")
  end
  local ok, result = pcall(function()
    local fn, e = load(p.code, "ce-mcp", "t", _G)
    if not fn then error(e, 0) end
    return fn()
  end)
  _G.print = real_print
  if ok then
    return { success = true, output = arr(output),
             result = result ~= nil and tostring(result) or nil }
  end
  return { success = false, output = arr(output), error = tostring(result) }
end

-- ══════════════════════════════════════════════════════════════════════════
-- DISPATCHER
-- ══════════════════════════════════════════════════════════════════════════
local function dispatch(req)
  local id = req and req.id
  local cmd_name = req and req.cmd
  if req and req.protocol ~= PROTOCOL then
    return {
      id = id, ok = false, protocol = PROTOCOL,
      error = ("protocol mismatch: bridge requires %d, request supplied %s")
        :format(PROTOCOL, tostring(req.protocol)),
    }
  end
  if type(id) ~= "string" or id == "" then
    return { id = id, ok = false, protocol = PROTOCOL,
             error = "protocol 2 requests require a non-empty string 'id'" }
  end
  if not cmd_name then
    return { id = id, ok = false, error = "request has no 'cmd' field" }
  end
  local handler = CMD[cmd_name]
  if not handler then
    local names = {}
    for k in pairs(CMD) do names[#names + 1] = k end
    table.sort(names)
    return { id = id, ok = false,
             error = ("unknown command %q — call ce_routes for the list"):format(tostring(cmd_name)),
             known = arr(names) }
  end

  local params = req.params or {}
  STATE.requests = STATE.requests + 1
  STATE.last_req = cmd_name
  log_debug("-> %s %s", cmd_name, truncate(json_encode(params), PARAM_LOG_CHARS))

  local t0 = now_ms()
  local ok, result = pcall(handler, params)
  local ms = now_ms() - t0

  if ok then
    log_debug("<- %s ok in %dms", cmd_name, ms)
    return { id = id, ok = true, data = result, elapsed_ms = ms }
  end

  STATE.errors = STATE.errors + 1
  local msg = tostring(result)
  STATE.last_error = { cmd = cmd_name, error = msg, at = os.date("%H:%M:%S") }
  log_error("<- %s FAILED in %dms: %s", cmd_name, ms, msg)
  return { id = id, ok = false, error = msg, command = cmd_name, elapsed_ms = ms }
end

local function service_once()
  if not file_exists(REQ_PATH) then return end

  local raw = read_file(REQ_PATH)
  os.remove(REQ_PATH)          -- claim it before doing any work
  if not raw or raw == "" then return end

  local req, err = json_decode(raw)
  local response
  if not req then
    log_error("malformed request: %s | raw=%s", tostring(err), truncate(raw, 200))
    response = { ok = false, error = "malformed JSON request: " .. tostring(err) }
  elseif type(req) ~= "table" then
    response = { ok = false, error = "request must be a JSON object" }
  else
    response = dispatch(req)
  end

  response.bridge_version = BRIDGE_VERSION
  response.protocol = PROTOCOL
  local encoded
  local ok, e = pcall(function() encoded = json_encode(response) end)
  if not ok then
    log_error("response encoding failed: %s", tostring(e))
    encoded = json_encode({ id = response.id, ok = false,
                            error = "bridge could not encode the response: " .. tostring(e) })
  end
  local wrote, werr = write_file(RES_PATH, encoded)
  if not wrote then log_error("could not write response file: %s", tostring(werr)) end
end

-- ══════════════════════════════════════════════════════════════════════════
-- TIMER / LIFECYCLE
-- ══════════════════════════════════════════════════════════════════════════
local poll_timer

local function stop_bridge()
  STATE.running = false
  if poll_timer then
    pcall(function() poll_timer.destroy() end)
    poll_timer = nil
  end
  for _, j in pairs(STATE.jobs) do
    if j.status == "running" then job_finish(j, "cancelled") end
  end
  log_info("bridge stopped")
end

local function start_bridge()
  if poll_timer then return end
  STATE.running = true
  poll_timer = createTimer(nil)
  poll_timer.Interval = POLL_MS
  poll_timer.OnTimer = function()
    if not STATE.running then stop_bridge(); return end
    if STATE.busy then return end          -- never re-enter a running handler
    STATE.busy = true
    local ok, err = pcall(service_once)
    STATE.busy = false
    if not ok then
      log_error("dispatcher crashed: %s", tostring(err))
      -- Always answer, or the client sits until its timeout.
      pcall(write_file, RES_PATH,
            json_encode({ ok = false, error = "bridge dispatcher error: " .. tostring(err),
                          bridge_version = BRIDGE_VERSION }))
    end
  end
end

-- Public control surface (callable from CE's Lua console).
function ce_mcp_stop()  stop_bridge() end
function ce_mcp_start() start_bridge(); log_info("bridge restarted") end
function ce_mcp_status()
  print(json_encode(CMD.debug_state({})))
end

-- Clear anything left over from a previous CE session.
os.remove(REQ_PATH)
os.remove(RES_PATH)

start_bridge()

log_info("bridge ready — v%s protocol %d, polling every %dms", BRIDGE_VERSION, PROTOCOL, POLL_MS)
log_info("request=%s  log=%s", REQ_PATH, LOG.to_file and LOG_PATH or "(disabled)")
do
  local missing = {}
  for _, n in ipairs({ "closeProcess", "createPointerScan", "findWhatWrites", "findWhatAccesses" }) do
    if not CAPS[n] then missing[#missing + 1] = n end
  end
  if #missing > 0 then
    log_info("note: this CE build lacks %s — the bridge substitutes its own " ..
             "implementations", table.concat(missing, ", "))
  end
end
log_info("controls: ce_mcp_stop() / ce_mcp_start() / ce_mcp_status()")
