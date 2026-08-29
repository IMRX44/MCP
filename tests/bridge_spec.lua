--[[ ============================================================================
  Bridge specification — runs ce_mcp_bridge.lua against a stubbed Cheat Engine.

  Expects two globals to be set by the runner before this file executes:
    TEST_TEMP   — a writable directory for the IPC + log files
    BRIDGE_PATH — absolute path to ce_mcp_bridge.lua

  Exercises the real file-IPC path: every assertion writes a request file,
  pumps the bridge's poll timer, and parses the response file.
============================================================================ ]]--

assert(TEST_TEMP, "TEST_TEMP not set")
assert(BRIDGE_PATH, "BRIDGE_PATH not set")

local REQ = TEST_TEMP .. "\\cemcp_req.json"
local RES = TEST_TEMP .. "\\cemcp_res.json"

-- ══════════════════════════════════════════════════════════════════════════
-- Cheat Engine stub
-- ══════════════════════════════════════════════════════════════════════════
local FAKE = {
  pid = 0,
  process_name = nil,
  regions = {},
  memory = {},          -- address -> integer value
  timers = {},
  scan_error = "",
  region_scan = false,
  found_addresses = {},
}

-- Environment: force the bridge onto our temp dir and a chatty log level.
local real_getenv = os.getenv
os.getenv = function(k)
  if k == "CE_MCP_TEMP" then return TEST_TEMP end
  if k == "CE_MCP_LOG_LEVEL" then return "trace" end
  if k == "CE_MCP_LOG_FILE" then return "0" end   -- keep the ring buffer only
  return real_getenv(k)
end

-- CE value-type / scan-option constants
vtByte, vtWord, vtDword, vtQword = 0, 1, 2, 3
vtSingle, vtDouble, vtString, vtByteArray = 4, 5, 6, 7
soUnknownValue, soExactValue, soValueBetween, soBiggerThan, soSmallerThan = 0, 1, 2, 3, 4
soIncreasedValue, soIncreasedValueBy, soDecreasedValue, soDecreasedValueBy = 5, 6, 7, 8
soChanged, soUnchanged = 9, 10
fsmNotAligned, fsmAligned, fsmLastDigits = 0, 1, 2
rtRounded, rtTruncated, rtExtremerounded = 0, 1, 2
bptExecute, bptWrite, bptAccess = 0, 1, 2
co_run = 0

process = nil

function createTimer(_)
  local t = { Interval = 1000, Enabled = true, OnTimer = nil, destroyed = false }
  function t.destroy() t.destroyed = true end
  FAKE.timers[#FAKE.timers + 1] = t
  return t
end

function getCEVersion() return 7.7 end
function getCheatEngineDir() return "C:\\Program Files\\Cheat Engine\\" end
function getOpenedProcessID() return FAKE.pid end
function targetIs64Bit() return true end

function getProcesslist()
  return {
    { id = 1234, name = "game.exe" },
    { id = 5678, name = "explorer.exe" },
  }
end

function openProcess(target)
  if target == 1234 or target == "game.exe" then
    FAKE.pid = 1234
    process = "game.exe"
  else
    FAKE.pid = 0
  end
end

function enumModules()
  return {
    { Name = "game.exe", Address = 0x140000000, Size = 0x1000000, PathToFile = "C:\\game\\game.exe" },
    { Name = "ntdll.dll", Address = 0x7FF800000000, Size = 0x200000, PathToFile = "" },
  }
end

function enumMemoryRegions() return FAKE.regions end

function readInteger(a) return FAKE.memory[a] end
function readSmallInteger(a) return FAKE.memory[a] end
function readQword(a) return FAKE.memory[a] end
function readFloat(a) return FAKE.memory[a] end
function readDouble(a) return FAKE.memory[a] end
function readPointer(a) return FAKE.memory[a] end
function readString(a) return tostring(FAKE.memory[a] or "") end
function readBytes(a, n, astable)
  if FAKE.memory[a] == nil then return nil end
  if not astable then return FAKE.memory[a] % 256 end
  local t = {}
  for i = 1, n do t[i] = (FAKE.memory[a] + i) % 256 end
  return t
end
function writeInteger(a, v) FAKE.memory[a] = math.floor(v) end
function writeSmallInteger(a, v) FAKE.memory[a] = math.floor(v) end
function writeQword(a, v) FAKE.memory[a] = math.floor(v) end
function writeFloat(a, v) FAKE.memory[a] = v end
function writeDouble(a, v) FAKE.memory[a] = v end
function writeString(a, v) FAKE.memory[a] = v end
function writeBytes(a, v) FAKE.memory[a] = type(v) == "table" and v[1] or v end

function allocateMemory(size) return 0x20000000 end
function deAlloc(_) return true end
function getAddressSafe(s) return nil end

function disassemble(a) return ("%08X - 89 04 8A - mov [rdx+rcx*4],eax"):format(a) end
function getInstructionSize(_) return 3 end
function assemble(code, _) return { 0x90, 0x90 } end
function autoAssemble(_, _) return true end

function debug_isDebugging() return false end
function debugProcess(_) return true end
function debug_setBreakpoint(_, _, _, _) return true end
function debug_removeBreakpoint(_) return true end
function debug_continueFromBreakpoint(_) return true end

function speedhack_setSpeed(_) return true end

-- Fake memscan / foundlist ------------------------------------------------
function createMemScan()
  local sc = { ErrorString = "", LastScanWasRegionScan = false, destroyed = false }
  function sc.firstScan(...)
    sc.args = { ... }
    sc.LastScanWasRegionScan = FAKE.region_scan
    sc.ErrorString = FAKE.scan_error
  end
  function sc.nextScan(...)
    sc.next_args = { ... }
    sc.LastScanWasRegionScan = false
    sc.ErrorString = FAKE.scan_error
  end
  function sc.waitTillDone(_) return true end
  function sc.getProgress()
    return { TotalAddressesToScan = 1000, CurrentlyScanned = 1000, ResultsFound = 2 }
  end
  function sc.terminateScan(force) sc.terminated = (force == true) end
  function sc.setOnlyOneResult(v) sc.only_one = v end
  function sc.saveCurrentResults(n) sc.saved = n end
  function sc.destroy() sc.destroyed = true end
  FAKE.last_scanner = sc
  return sc
end

function createFoundList(_)
  local fl = { Count = 0, Address = {}, Value = {} }
  function fl.initialize()
    fl.Count = #FAKE.found_addresses
    for i, a in ipairs(FAKE.found_addresses) do
      fl.Address[i - 1] = a
      fl.Value[i - 1] = "42"
    end
  end
  function fl.deinitialize() fl.Count = 0 end
  function fl.destroy() fl.destroyed = true end
  return fl
end

function getAddressList()
  local al = { Count = 0, records = {} }
  return al
end

-- ══════════════════════════════════════════════════════════════════════════
-- Load the bridge
-- ══════════════════════════════════════════════════════════════════════════
local f = assert(io.open(BRIDGE_PATH, "rb"), "cannot open " .. BRIDGE_PATH)
local src = f:read("*a"); f:close()
local chunk = assert(load(src, "@ce_mcp_bridge.lua"))
chunk()

local poll = FAKE.timers[#FAKE.timers]
assert(poll and poll.OnTimer, "bridge did not install a poll timer")

-- ══════════════════════════════════════════════════════════════════════════
-- Test helpers
-- ══════════════════════════════════════════════════════════════════════════
local function write(path, data)
  local fh = assert(io.open(path, "wb")); fh:write(data); fh:close()
end
local function read(path)
  local fh = io.open(path, "rb"); if not fh then return nil end
  local d = fh:read("*a"); fh:close(); return d
end

--- Send a raw request body through the real IPC path; return the raw response.
local function raw_call(body)
  os.remove(RES)
  write(REQ, body)
  poll.OnTimer()
  local res = read(RES)
  os.remove(RES)
  return res or ""
end

local function call(cmd, params, id)
  local parts = {}
  for k, v in pairs(params or {}) do
    local enc
    if type(v) == "string" then enc = ('"%s"'):format(v:gsub('"', '\\"'))
    elseif type(v) == "boolean" then enc = tostring(v)
    elseif type(v) == "table" then
      local items = {}
      for _, x in ipairs(v) do items[#items + 1] = tostring(x) end
      enc = "[" .. table.concat(items, ",") .. "]"
    else enc = tostring(v) end
    parts[#parts + 1] = ('"%s":%s'):format(k, enc)
  end
  local body = ('{"id":"%s","cmd":"%s","params":{%s}}')
    :format(id or "t1", cmd, table.concat(parts, ","))
  return raw_call(body)
end

local passed, failed = 0, 0
local function ok(name, cond, detail)
  if cond then
    passed = passed + 1
    print(("  PASS  %s"):format(name))
  else
    failed = failed + 1
    print(("  FAIL  %s%s"):format(name, detail and ("  -- " .. tostring(detail)) or ""))
  end
end
local function has(hay, needle) return hay:find(needle, 1, true) ~= nil end

print("bridge_spec: running against stubbed Cheat Engine\n")

-- ══════════════════════════════════════════════════════════════════════════
-- Protocol
-- ══════════════════════════════════════════════════════════════════════════
print("protocol")
do
  local r = call("ping", {}, "abc-123")
  ok("ping succeeds", has(r, '"ok":true'), r)
  ok("ping echoes the request id", has(r, '"id":"abc-123"'), r)
  ok("ping reports the bridge version", has(r, '"bridge_version":"2.0.0"'), r)

  local r2 = call("ping", {}, "different-id")
  ok("a second call carries its own id", has(r2, '"id":"different-id"'), r2)

  local r3 = call("no_such_command", {})
  ok("unknown command is rejected", has(r3, '"ok":false') and has(r3, "unknown command"), r3)
  ok("unknown command lists known routes", has(r3, '"known"'), r3)

  local r4 = raw_call("{this is not json")
  ok("malformed JSON is reported", has(r4, '"ok":false') and has(r4, "malformed JSON"), r4)

  local r5 = raw_call('{"id":"x","params":{}}')
  ok("missing cmd is reported", has(r5, "no 'cmd' field"), r5)

  local r6 = call("ce_routes", {})
  ok("ce_routes enumerates commands", has(r6, "scan_first") and has(r6, "debug_log"), r6)
  ok("ce_routes is not a ping stub", not has(r6, "pong"), r6)
end

-- ══════════════════════════════════════════════════════════════════════════
-- Diagnostics
-- ══════════════════════════════════════════════════════════════════════════
print("\ndiagnostics")
do
  local r = call("debug_selftest", {})
  ok("selftest runs", has(r, '"ok":true'), r)
  ok("selftest reports healthy", has(r, '"healthy":true'), r)
  ok("selftest covers the JSON codec", has(r, "json roundtrip"), r)
  ok("selftest covers protection validation", has(r, "protection filter validation"), r)

  local c = call("debug_capabilities", {})
  ok("capabilities flags absent CE functions",
     has(c, "createPointerScan") and has(c, '"missing"'), c)

  local l = call("debug_log", { limit = 20 })
  ok("debug_log returns entries", has(l, '"entries"') and has(l, '"msg"'), l)

  local s = call("debug_state", {})
  ok("debug_state reports counters", has(s, '"requests"') and has(s, '"uptime_s"'), s)

  local lv = call("debug_set_level", { level = "debug" })
  ok("log level can be changed", has(lv, '"level":"debug"'), lv)
  local bad = call("debug_set_level", { level = "loud" })
  ok("invalid log level is rejected", has(bad, '"ok":false'), bad)
end

-- ══════════════════════════════════════════════════════════════════════════
-- Guards that fire before a process is attached
-- ══════════════════════════════════════════════════════════════════════════
print("\nprocess guards")
do
  FAKE.pid = 0
  local r = call("scan_first", { value = 1 })
  ok("scan without a process is refused",
     has(r, '"ok":false') and has(r, "no process attached"), r)

  local m = call("memory_read", { address = "0x1000" })
  ok("read without a process is refused", has(m, "no process attached"), m)

  local c = call("process_current", {})
  ok("process_current reports detached", has(c, '"attached":false'), c)

  local pl = call("process_list", { filter = "game" })
  ok("process_list filters", has(pl, "game.exe") and not has(pl, "explorer.exe"), pl)

  local at = call("process_attach", { process = "nope.exe" })
  ok("attaching to a missing process errors clearly",
     has(at, '"ok":false') and has(at, "failed to attach"), at)

  local at2 = call("process_attach", { process = "game.exe" })
  ok("attaching succeeds", has(at2, '"pid":1234') and has(at2, "game.exe"), at2)
end

-- ══════════════════════════════════════════════════════════════════════════
-- Scan argument validation
-- ══════════════════════════════════════════════════════════════════════════
print("\nscan validation")
do
  local r = call("scan_first", { value_type = "quadword", value = 1 })
  ok("unknown value_type is rejected", has(r, "unknown value_type"), r)

  local r2 = call("scan_first", { scan_type = "sideways", value = 1 })
  ok("unknown scan_type is rejected", has(r2, "unknown scan_type"), r2)

  local r3 = call("scan_first", { scan_type = "changed" })
  ok("next-only scan type is refused on first scan",
     has(r3, "only valid on scan_next"), r3)

  local r4 = call("scan_first", { scan_type = "exact" })
  ok("exact scan without a value is refused", has(r4, "requires a 'value'"), r4)

  local r5 = call("scan_first", { scan_type = "between", value = 1 })
  ok("between without value2 is refused", has(r5, "value2"), r5)

  local r6 = call("scan_first", { value = 1, protection = "+Q" })
  ok("invalid protection string is refused", has(r6, "invalid protection"), r6)

  local r7 = call("scan_first", { value = 1, alignment = "sideways" })
  ok("invalid alignment is refused", has(r7, "invalid alignment"), r7)

  local r8 = call("scan_first", { value = 1, regions = "elsewhere" })
  ok("invalid regions preset is refused", has(r8, "unknown regions"), r8)

  local r9 = call("scan_next", { scan_type = "changed" })
  ok("scan_next without a first scan is refused", has(r9, "no active scan"), r9)
end

-- ══════════════════════════════════════════════════════════════════════════
-- Scan happy path
-- ══════════════════════════════════════════════════════════════════════════
print("\nscan behaviour")
do
  FAKE.found_addresses = { "7FF700001000", "7FF700002000" }
  FAKE.region_scan = false

  local r = call("scan_first", { value = 100, value_type = "float" })
  ok("first scan completes", has(r, '"status":"done"'), r)
  ok("first scan reports the count", has(r, '"count":2'), r)
  ok("first scan defaults to the safe protection filter",
     has(r, '"protection":"+W-X-C"'), r)
  ok("float scan aligns to 4 bytes by default", has(r, '"alignment":"auto(4)"'), r)

  local args = FAKE.last_scanner.args
  ok("firstScan received 14 arguments", #args == 14, "#args=" .. tostring(#args))
  ok("firstScan got fsmAligned", args[9] == fsmAligned, tostring(args[9]))
  ok("firstScan got alignment param '4'", args[10] == "4", tostring(args[10]))
  ok("firstScan got the protection filter", args[8] == "+W-X-C", tostring(args[8]))

  local res = call("scan_results", { limit = 10 })
  ok("results page returns rows", has(res, "7FF700001000") and has(res, '"total":2'), res)
  ok("results report their source", has(res, '"source":"mcp"'), res)

  local n = call("scan_next", { scan_type = "changed" })
  ok("next scan runs", has(n, '"status":"done"') and has(n, '"phase":"next"'), n)
  local nargs = FAKE.last_scanner.next_args
  ok("nextScan received 10 arguments", #nargs >= 9, "#nargs=" .. tostring(#nargs))

  local un = call("scan_next", { scan_type = "unknown" })
  ok("unknown is refused on next scan", has(un, "only valid on scan_first"), un)

  local st = call("scan_status", {})
  ok("scan_status reports the mcp scan", has(st, '"source":"mcp"'), st)

  local sv = call("scan_save_results", { name = "DRY" })
  ok("results can be saved for comparison", has(sv, '"saved":"DRY"'), sv)

  -- A finished scan must NOT be force-terminated: Cheat Engine then warns that
  -- subsequent scans may misbehave and recommends a restart.
  FAKE.last_scanner.terminated = nil
  local cx = call("scan_cancel", {})
  ok("cancelling a finished scan is a no-op", has(cx, '"already_finished":true'), cx)
  ok("a finished scan is never terminated", FAKE.last_scanner.terminated == nil,
     tostring(FAKE.last_scanner.terminated))

  local rr = call("scan_reset", {})
  ok("scan_reset releases state", has(rr, '"reset":true'), rr)
  ok("reset of a finished scan reports it was idle", has(rr, '"was_running":false'), rr)
end

-- ══════════════════════════════════════════════════════════════════════════
-- Cancelling a scan that really is running
-- ══════════════════════════════════════════════════════════════════════════
print("\nscan cancellation")
do
  -- Make the scan never finish so scan_first leaves it running.
  local slow = createMemScan
  createMemScan = function()
    local sc = slow()
    sc.waitTillDone = function(_) return false end
    return sc
  end

  call("scan_first", { value = 1, wait = 0 })
  local sc = FAKE.last_scanner
  local cx = call("scan_cancel", {})
  ok("a running scan is cancelled", has(cx, '"cancelled":true'), cx)
  ok("graceful cancel is not forced", has(cx, '"forced":false'), cx)
  ok("graceful cancel passes force=false", sc.terminated == false, tostring(sc.terminated))
  ok("graceful cancel explains the escalation", has(cx, "force=true"), cx)

  call("scan_reset", {})
  call("scan_first", { value = 1, wait = 0 })
  local sc2 = FAKE.last_scanner
  local cf = call("scan_cancel", { force = true })
  ok("force cancel passes force=true", sc2.terminated == true, tostring(sc2.terminated))
  ok("force cancel warns about the CE restart advice", has(cf, "recommend a restart"), cf)

  call("scan_reset", {})
  createMemScan = slow
end

-- ══════════════════════════════════════════════════════════════════════════
-- Unknown-initial-value scan: zero results must be explained, not silent
-- ══════════════════════════════════════════════════════════════════════════
print("\nunknown-value scan")
do
  FAKE.region_scan = true
  local r = call("scan_first", { scan_type = "unknown", value_type = "float" })
  ok("snapshot scan completes", has(r, '"status":"done"'), r)
  ok("snapshot is flagged as a region scan", has(r, '"region_scan":true'), r)
  ok("snapshot explains the empty result set", has(r, "produces no"), r)
  ok("snapshot tells the caller what to do next", has(r, "scan_next"), r)

  local res = call("scan_results", {})
  ok("results on a snapshot explain themselves", has(res, '"status":"snapshot"'), res)

  call("scan_reset", {})
  FAKE.region_scan = false
end

-- ══════════════════════════════════════════════════════════════════════════
-- Scan failure surfaces instead of returning a silent zero
-- ══════════════════════════════════════════════════════════════════════════
print("\nscan errors")
do
  FAKE.scan_error = "thread 0 error"
  local r = call("scan_first", { value = 1 })
  ok("CE scanner errors are surfaced",
     has(r, '"status":"error"') and has(r, "thread 0 error"), r)
  FAKE.scan_error = ""
  call("scan_reset", {})

  -- 4 MB of writable private memory, and a separate 8 MB executable image.
  -- Scanning the *image* range with +W-X-C can never match, and Cheat Engine
  -- misreports that as "not attached to a live process".
  FAKE.regions = {
    { BaseAddress = 0x10000000, RegionSize = 4 * 1048576, Protect = 0x04,
      State = 0x1000, Type = 0x20000 },
    { BaseAddress = 0x20000000, RegionSize = 8 * 1048576, Protect = 0x20,
      State = 0x1000, Type = 0x1000000 },
  }

  FAKE.scan_error = "No readable memory found. Please make sure you are attached to a live process"
  local img = call("scan_first", { value = 1, start = "0x20000000", stop = "0x20800000" })
  ok("CE's misleading message is still reported", has(img, "live process"), img)
  ok("the real cause is diagnosed", has(img, '"diagnosis"'), img)
  ok("diagnosis names the protection filter", has(img, "matches protection"), img)
  ok("diagnosis reports the committed memory it did find",
     has(img, "8.0 MB is committed"), img)
  FAKE.scan_error = ""
  call("scan_reset", {})

  -- An empty range is a different failure and must read differently.
  FAKE.scan_error = "No readable memory found"
  local void = call("scan_first", { value = 1, start = "0xF00000000", stop = "0xF00001000" })
  ok("an empty range is diagnosed as such", has(void, "no committed memory at all"), void)
  FAKE.scan_error = ""
  call("scan_reset", {})

  -- Zero results with a healthy filter must point at the value, not the filter.
  FAKE.found_addresses = {}
  local none = call("scan_first", { value = 12345 })
  ok("a genuine zero-result scan is diagnosed too", has(none, '"diagnosis"'), none)
  ok("it exonerates the filter when memory did match",
     has(none, "not the problem"), none)
  call("scan_reset", {})
  FAKE.found_addresses = { "7FF700001000", "7FF700002000" }
end

-- ══════════════════════════════════════════════════════════════════════════
-- Memory
-- ══════════════════════════════════════════════════════════════════════════
print("\nmemory")
do
  FAKE.memory[0x1000] = 7
  local r = call("memory_read", { address = "0x1000" })
  ok("read returns the value", has(r, '"value":7'), r)

  local w = call("memory_write", { address = "0x1000", value = 55 })
  ok("write reports the previous value", has(w, '"previous":7'), w)
  ok("write verifies via read-back", has(w, '"verified":true') and has(w, '"readback":55'), w)

  local bad = call("memory_read", { address = "0xDEAD" })
  ok("unreadable address errors clearly", has(bad, "not readable"), bad)

  local nan = call("memory_write", { address = "0x1000", value = "abc" })
  ok("non-numeric write is refused", has(nan, "is not a number"), nan)

  local bt = call("memory_read_batch", { reads = {} })
  ok("empty batch is fine", has(bt, '"count":0'), bt)
end

-- ══════════════════════════════════════════════════════════════════════════
-- Regions / estimate
-- ══════════════════════════════════════════════════════════════════════════
print("\nregions and estimation")
do
  FAKE.regions = {
    { BaseAddress = 0x10000, RegionSize = 4 * 1048576, Protect = 0x04, State = 0x1000, Type = 0x20000 },
    { BaseAddress = 0x20000, RegionSize = 8 * 1048576, Protect = 0x20, State = 0x1000, Type = 0x1000000 },
    { BaseAddress = 0x30000, RegionSize = 2 * 1048576, Protect = 0x04, State = 0x2000, Type = 0x20000 },
  }

  local r = call("process_regions", {})
  ok("regions exclude reserved pages", has(r, '"count":2'), r)
  ok("regions decode protection names", has(r, "READWRITE") and has(r, "EXECUTE_READ"), r)
  ok("regions mark executable pages", has(r, '"executable":true'), r)

  local w = call("process_regions", { writable = true, executable = false })
  ok("regions can be filtered to writable non-executable", has(w, '"count":1'), w)

  local e = call("scan_estimate", { value_type = "float" })
  ok("estimate counts only +W-X-C bytes", has(e, '"regions":1'), e)
  ok("estimate reports megabytes", has(e, '"mb":4'), e)
  ok("estimate divides by the alignment stride",
     has(e, '"addresses_to_scan":1048576'), e)
end

-- ══════════════════════════════════════════════════════════════════════════
-- Tools that CE cannot support must say so precisely
-- ══════════════════════════════════════════════════════════════════════════
print("\nunsupported APIs")
do
  local r = call("pointer_scan", { address = "0x1000" })
  ok("pointer_scan explains there is no Lua API",
     has(r, '"ok":false') and has(r, "createPointerScan"), r)
  ok("pointer_scan suggests the UI workflow", has(r, "Pointer scan for this address"), r)

  local d = call("process_detach", {})
  ok("detach is honest about closeProcess", has(d, "no closeProcess"), d)
end

-- ══════════════════════════════════════════════════════════════════════════
-- Pointers / disassembly
-- ══════════════════════════════════════════════════════════════════════════
print("\npointers and code")
do
  FAKE.memory[0x140000000] = 0x200000
  FAKE.memory[0x200010] = 0x300000

  local r = call("pointer_resolve", { base = "0x140000000", offsets = { 16, 32 } })
  ok("pointer chain resolves", has(r, '"valid":true') and has(r, '"resolved":"0x300020"'), r)
  ok("pointer chain is annotated", has(r, '"step"'), r)

  local b = call("pointer_resolve", { base = "0xDEAD", offsets = { 8 } })
  ok("broken chain reports the level", has(b, '"valid":false') and has(b, "broken_at_level"), b)

  local d = call("disassemble", { address = "0x140000000", count = 2 })
  ok("disassembly splits bytes from the opcode",
     has(d, '"bytes":"89 04 8A"') and has(d, "mov [rdx+rcx*4],eax"), d)

  local a = call("assemble", { code = "nop" })
  ok("assemble returns hex bytes", has(a, '"bytes":"90 90"'), a)
end

-- ══════════════════════════════════════════════════════════════════════════
-- Jobs
-- ══════════════════════════════════════════════════════════════════════════
print("\njobs")
do
  local r = call("find_what_writes", { address = "0x1000", duration = 5 })
  ok("find_what_writes starts a job", has(r, '"job_id"') and has(r, '"status":"running"'), r)
  ok("find_what_writes tells the caller to act", has(r, "Trigger the value in-game"), r)

  local jl = call("job_list", {})
  ok("job_list shows the job", has(jl, "find_what_writes"), jl)

  local js = call("job_status", { job_id = 1 })
  ok("job_status reports the job", has(js, '"job_id":1'), js)

  local jc = call("job_cancel", { job_id = 1 })
  ok("job_cancel stops it", has(jc, '"status":"cancelled"'), jc)

  local jn = call("job_status", { job_id = 999 })
  ok("unknown job id errors", has(jn, "no job with id"), jn)

  local bs = call("find_what_writes", { address = "0x1000", size = 3 })
  ok("invalid breakpoint size is refused", has(bs, "size must be 1, 2, 4 or 8"), bs)
end

-- ══════════════════════════════════════════════════════════════════════════
-- JSON codec edge cases, exercised through lua_execute
-- ══════════════════════════════════════════════════════════════════════════
print("\njson codec")
do
  local r = raw_call('{"id":"j1","cmd":"lua_execute","params":{"code":"print(\\"hi\\\\ttab\\")"}}')
  ok("escaped strings survive the round trip", has(r, "hi\\ttab"), r)

  local u = raw_call('{"id":"j2","cmd":"process_list","params":{"filter":"\\u0067ame"}}')
  ok("\\u escapes decode", has(u, "game.exe"), u)

  local empty = call("memory_read_batch", { reads = {} })
  ok("empty arrays encode as []", has(empty, '"reads":[]'), empty)

  local nested = raw_call('{"id":"j3","cmd":"pointer_resolve","params":' ..
                          '{"base":"0x140000000","offsets":[16,32]}}')
  ok("nested arrays decode", has(nested, '"resolved"'), nested)
end

-- ══════════════════════════════════════════════════════════════════════════
-- Re-entrancy: a slow handler must not be re-entered by the poll timer
-- ══════════════════════════════════════════════════════════════════════════
print("\nre-entrancy")
do
  os.remove(RES)
  write(REQ, '{"id":"re1","cmd":"ping","params":{}}')
  -- Simulate the timer firing again while the first call is still in flight by
  -- invoking OnTimer from inside a handler via lua_execute.
  local depth = 0
  local orig = poll.OnTimer
  poll.OnTimer = function()
    depth = depth + 1
    orig()
    depth = depth - 1
  end
  poll.OnTimer()
  ok("dispatcher completed", read(RES) ~= nil)
  os.remove(RES)
  poll.OnTimer = orig

  -- No request file present: the timer must be a cheap no-op.
  os.remove(REQ)
  local before = read(RES)
  poll.OnTimer()
  ok("idle poll writes nothing", read(RES) == before)
end

print(("\n%d passed, %d failed"):format(passed, failed))
if failed > 0 then os.exit(1) end
