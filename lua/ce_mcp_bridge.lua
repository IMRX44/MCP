--[[ ============================================================================
  CE-MCP Bridge  —  File-based IPC (no LuaSocket required)
  ----------------------------------------------------------------------------
  Works on ANY Cheat Engine version (7.x, 6.x, portable) with zero external
  dependencies. Communicates through temp-file pairs instead of TCP sockets,
  so there is nothing to install.

  HOW IT WORKS
    Python side writes  %TEMP%\cemcp_<id>_req.json
    CE side reads it, runs the command, writes %TEMP%\cemcp_<id>_res.json
    Python side reads the response and deletes both files.
    CE polls every 8 ms via a Cheat Engine timer — virtually no latency.

  USAGE
    1. Open Cheat Engine.
    2. Table  ->  Cheat Table Lua Script  (Ctrl+Alt+L)
    3. Paste this entire file and click Execute.
    4. You should see: [CE-MCP] bridge ready  in the output panel.
============================================================================ ]]--

local POLL_MS  = 8
local TEMP_DIR = os.getenv("TEMP") or os.getenv("TMP") or "C:\\Temp"
local PREFIX   = TEMP_DIR .. "\\cemcp_"

local STATE = { running = true, allocs = {} }

local function log(msg) print(("[CE-MCP] %s"):format(tostring(msg))) end

-- ── JSON encoder ──────────────────────────────────────────────────────────
local ESC = { ['"']='\\"', ['\\']='\\\\', ['\b']='\\b', ['\f']='\\f',
              ['\n']='\\n', ['\r']='\\r', ['\t']='\\t' }

local json_encode  -- forward
local function esc(s)
  return '"' .. s:gsub('[%z\1-\31\\"]', function(c)
    return ESC[c] or ('\\u%04x'):format(c:byte()) end) .. '"'
end
local function is_arr(t)
  local n=0
  for k in pairs(t) do
    if type(k)~="number" or k~=math.floor(k) or k<1 then return false end
    if k>n then n=k end
  end
  return n==#t, n
end
json_encode = function(v)
  local t=type(v)
  if v==nil then return "null"
  elseif t=="boolean" then return v and "true" or "false"
  elseif t=="number" then
    if v~=v or v==math.huge or v==-math.huge then return "null" end
    if v%1==0 and math.abs(v)<2^53 then return ("%d"):format(v) end
    return ("%.17g"):format(v)
  elseif t=="string" then return esc(v)
  elseif t=="table" then
    local arr,n=is_arr(v)
    if arr then
      if n==0 then return "[]" end
      local p={}; for i=1,n do p[i]=json_encode(v[i]) end
      return "["..table.concat(p,",").."]"
    else
      local p={}
      for k,val in pairs(v) do
        p[#p+1]=esc(tostring(k))..":"..json_encode(val)
      end
      return "{"..table.concat(p,",").."}"
    end
  end
  return "null"
end

-- ── JSON decoder (full recursive descent) ─────────────────────────────────
local function json_decode(str)
  if not str or str=="" then return {} end
  local pos=1
  local parse_value

  local function skip()
    while pos<=#str do
      local c=str:byte(pos)
      if c==32 or c==9 or c==10 or c==13 then pos=pos+1 else break end
    end
  end

  local function parse_str()
    pos=pos+1
    local buf={}
    while pos<=#str do
      local c=str:sub(pos,pos)
      if c=='"' then pos=pos+1; return table.concat(buf)
      elseif c=='\\' then
        local n=str:sub(pos+1,pos+1)
        local map={n='\n',t='\t',r='\r',b='\b',f='\f',['"']='"',['\\']='\\',['/']=='/'}
        if n=='u' then
          local h=str:sub(pos+2,pos+5)
          local cp=tonumber(h,16) or 0
          if cp<0x80 then buf[#buf+1]=string.char(cp)
          elseif cp<0x800 then
            buf[#buf+1]=string.char(0xC0+math.floor(cp/0x40),0x80+cp%0x40)
          else
            buf[#buf+1]=string.char(0xE0+math.floor(cp/0x1000),
              0x80+math.floor(cp/0x40)%0x40,0x80+cp%0x40)
          end
          pos=pos+4
        else buf[#buf+1]=map[n] or n end
        pos=pos+2
      else buf[#buf+1]=c; pos=pos+1 end
    end
    error("unterminated string")
  end

  local function parse_num()
    local s=pos
    while pos<=#str do
      local c=str:byte(pos)
      if (c>=48 and c<=57) or c==45 or c==43 or c==46 or c==101 or c==69
        then pos=pos+1 else break end
    end
    return tonumber(str:sub(s,pos-1))
  end

  local function parse_arr()
    pos=pos+1; local a={}; skip()
    if str:sub(pos,pos)==']' then pos=pos+1; return a end
    while true do
      a[#a+1]=parse_value(); skip()
      local c=str:sub(pos,pos)
      if c==',' then pos=pos+1; skip()
      elseif c==']' then pos=pos+1; return a
      else error("bad array") end
    end
  end

  local function parse_obj()
    pos=pos+1; local o={}; skip()
    if str:sub(pos,pos)=='}' then pos=pos+1; return o end
    while true do
      skip()
      local k=parse_str(); skip()
      if str:sub(pos,pos)~=':' then error("expected :") end
      pos=pos+1; skip()
      o[k]=parse_value(); skip()
      local c=str:sub(pos,pos)
      if c==',' then pos=pos+1
      elseif c=='}' then pos=pos+1; return o
      else error("bad object") end
    end
  end

  parse_value=function()
    skip()
    local c=str:sub(pos,pos)
    if c=='{' then return parse_obj()
    elseif c=='[' then return parse_arr()
    elseif c=='"' then return parse_str()
    elseif c=='t' then pos=pos+4; return true
    elseif c=='f' then pos=pos+5; return false
    elseif c=='n' then pos=pos+4; return nil
    else return parse_num() end
  end

  skip()
  if pos>#str then return {} end
  local ok,r=pcall(parse_value)
  return ok and r or {}
end

-- ── File helpers ──────────────────────────────────────────────────────────
local function read_file(path)
  local f=io.open(path,"rb"); if not f then return nil end
  local d=f:read("*a"); f:close(); return d
end

local function write_file(path, data)
  local f=io.open(path,"wb"); if not f then return false end
  f:write(data); f:close(); return true
end

local function file_exists(path)
  local f=io.open(path,"rb"); if not f then return false end
  f:close(); return true
end

-- ── Address / type helpers ────────────────────────────────────────────────
local function addr_str(a)
  if not a then return "0x0" end
  return ("0x%X"):format(a)
end

local function to_addr(v)
  if type(v)=="number" then return v end
  if type(v)=="string" then
    if v:match("^0[xX]") then return tonumber(v:sub(3),16) end
    local n=tonumber(v); if n then return n end
    return getAddressSafe(v)
  end
  return nil
end

local VTYPES={
  byte=vtByte,["1byte"]=vtByte,
  word=vtWord,["2byte"]=vtWord,short=vtWord,
  dword=vtDword,["4byte"]=vtDword,int=vtDword,integer=vtDword,
  qword=vtQword,["8byte"]=vtQword,int64=vtQword,long=vtQword,
  float=vtSingle,single=vtSingle,
  double=vtDouble,
  string=vtString,text=vtString,
  aob=vtByteArray,bytes=vtByteArray,bytearray=vtByteArray,
}

local STYPES={
  exact=fsmEqualTo,equals=fsmEqualTo,["="]=fsmEqualTo,
  notequal=fsmNotEqualTo,["!="]=fsmNotEqualTo,
  bigger=fsmBiggerThan,greater=fsmBiggerThan,[">"]=fsmBiggerThan,
  biggerorequal=fsmBiggerThanOrEqual,[">="]=fsmBiggerThanOrEqual,
  smaller=fsmSmallerThan,less=fsmSmallerThan,["<"]=fsmSmallerThan,
  smallerorequal=fsmSmallerThanOrEqual,["<="]=fsmSmallerThanOrEqual,
  between=fsmBetween,
  unknown=fsmUnknownValue,unknownvalue=fsmUnknownValue,
  changed=fsmChanged,unchanged=fsmUnchanged,
  increased=fsmIncreased,decreased=fsmDecreased,
  increasedby=fsmIncreasedValueBy,decreasedby=fsmDecreasedValueBy,
}

-- ══════════════════════════════════════════════════════════════════════════
-- COMMAND HANDLERS  (each receives params table, returns data value)
-- ══════════════════════════════════════════════════════════════════════════
local CMD={}

CMD.ping = function(_)
  return { pong=true, version=getCEVersion() }
end

CMD.ce_version = function(_)
  return { ce_version=getCEVersion(), lua=_VERSION,
           ce_dir=getCheatEngineDir and getCheatEngineDir() or "" }
end

-- ── process ──────────────────────────────────────────────────────────────
CMD.process_list = function(p)
  local filter=(p.filter or ""):lower()
  local out={}
  for _,proc in ipairs(getProcessList()) do
    if filter=="" or proc.name:lower():find(filter,1,true) then
      out[#out+1]={pid=proc.id, name=proc.name}
    end
  end
  return out
end

CMD.process_attach = function(p)
  local target=p.process or p.pid or p.name
  if not target then error("missing process/pid/name") end
  if type(target)=="string" and tonumber(target) then target=tonumber(target) end
  openProcess(target)
  if getOpenedProcessID()==0 then error("failed to attach to "..tostring(target)) end
  return { pid=getOpenedProcessID(), name=getOpenedProcessName(),
           is64bit=targetIs64Bit() }
end

CMD.process_detach = function(_)
  closeProcess(); return { detached=true }
end

CMD.process_current = function(_)
  local pid=getOpenedProcessID()
  if pid==0 then error("no process attached") end
  return { pid=pid, name=getOpenedProcessName(), is64bit=targetIs64Bit() }
end

CMD.process_modules = function(p)
  local filter=(p.filter or ""):lower()
  local out={}
  for _,m in ipairs(enumModules()) do
    if filter=="" or m.Name:lower():find(filter,1,true) then
      out[#out+1]={ name=m.Name, base=addr_str(m.Address),
                    size=m.Size, path=m.PathToFile or m.PathFile or "" }
    end
  end
  return out
end

CMD.process_regions = function(_)
  local out={}
  for _,r in ipairs(enumMemoryRegions()) do
    out[#out+1]={ base=addr_str(r.BaseAddress), size=r.RegionSize,
                  protect=r.Protect, state=r.State }
  end
  return out
end

-- ── raw memory ────────────────────────────────────────────────────────────
CMD.memory_read = function(p)
  local addr=to_addr(p.address); if not addr then error("invalid address") end
  local vt=(p.type or "4byte"):lower()
  local size=tonumber(p.size) or 64
  local val
  if vt=="byte" or vt=="1byte" then val=readBytes(addr,1,false)
  elseif vt=="word" or vt=="2byte" then val=readSmallInteger(addr,p.signed)
  elseif vt=="dword" or vt=="4byte" or vt=="int" then val=readInteger(addr,p.signed)
  elseif vt=="qword" or vt=="8byte" or vt=="int64" then val=readQword(addr)
  elseif vt=="float" then val=readFloat(addr)
  elseif vt=="double" then val=readDouble(addr)
  elseif vt=="pointer" then val=addr_str(readPointer(addr))
  elseif vt=="string" then val=readString(addr,size,p.wide or false)
  elseif vt=="aob" or vt=="bytes" then
    local raw=readBytes(addr,size,true); local h={}
    if raw then for _,b in ipairs(raw) do h[#h+1]=("%02X"):format(b) end end
    val=table.concat(h," ")
  else val=readInteger(addr) end
  return { address=addr_str(addr), type=vt, value=val }
end

CMD.memory_read_batch = function(p)
  local out={}
  for _,r in ipairs(p.reads or {}) do
    local addr=to_addr(r.address)
    if addr then
      local vt=(r.type or "4byte"):lower(); local v
      if vt=="float" then v=readFloat(addr)
      elseif vt=="double" then v=readDouble(addr)
      elseif vt=="qword" or vt=="8byte" then v=readQword(addr)
      elseif vt=="string" then v=readString(addr,r.size or 64,r.wide)
      elseif vt=="byte" then v=readBytes(addr,1,false)
      else v=readInteger(addr) end
      out[#out+1]={ address=addr_str(addr), value=v }
    end
  end
  return out
end

CMD.memory_write = function(p)
  local addr=to_addr(p.address); if not addr then error("invalid address") end
  if p.value==nil then error("missing value") end
  local vt=(p.type or "4byte"):lower()
  if vt=="byte" then writeBytes(addr,tonumber(p.value)&0xFF)
  elseif vt=="word" or vt=="2byte" then writeSmallInteger(addr,tonumber(p.value))
  elseif vt=="dword" or vt=="4byte" or vt=="int" then writeInteger(addr,tonumber(p.value))
  elseif vt=="qword" or vt=="8byte" then writeQword(addr,tonumber(p.value))
  elseif vt=="float" then writeFloat(addr,tonumber(p.value))
  elseif vt=="double" then writeDouble(addr,tonumber(p.value))
  elseif vt=="string" then writeString(addr,tostring(p.value),p.wide or false)
  elseif vt=="aob" or vt=="bytes" then
    local bytes={}
    for h in tostring(p.value):gmatch("%x%x") do bytes[#bytes+1]=tonumber(h,16) end
    writeBytes(addr,bytes)
  else writeInteger(addr,tonumber(p.value)) end
  return { address=addr_str(addr), type=vt, value=p.value, written=true }
end

CMD.memory_dump = function(p)
  local addr=to_addr(p.address); if not addr then error("invalid address") end
  local size=math.min(tonumber(p.size) or 256,65536)
  local bytes=readBytes(addr,size,true); local lines={}
  if bytes then
    for i=1,#bytes,16 do
      local hx,asc={},{}
      for j=i,math.min(i+15,#bytes) do
        local b=bytes[j]; hx[#hx+1]=("%02X"):format(b)
        asc[#asc+1]=(b>=32 and b<127) and string.char(b) or "."
      end
      lines[#lines+1]={ address=addr_str(addr+i-1),
                        hex=table.concat(hx," "), ascii=table.concat(asc) }
    end
  end
  return { address=addr_str(addr), size=size, lines=lines }
end

CMD.memory_alloc = function(p)
  local size=tonumber(p.size) or 4096
  local near=to_addr(p.near)
  local a=near and allocateMemory(size,near) or allocateMemory(size)
  if not a then error("allocation failed") end
  STATE.allocs[addr_str(a)]=size
  return { address=addr_str(a), size=size }
end

CMD.memory_free = function(p)
  local addr=to_addr(p.address); if not addr then error("invalid address") end
  deAlloc(addr); STATE.allocs[addr_str(addr)]=nil
  return { freed=addr_str(addr) }
end

-- ── scanning ──────────────────────────────────────────────────────────────
CMD.scan_first = function(p)
  if getOpenedProcessID()==0 then error("no process attached") end
  local vt=VTYPES[(p.value_type or "4byte"):lower()] or vtDword
  local st=STYPES[(p.scan_type or "exact"):lower()] or fsmEqualTo
  local scanner=createMemScan()
  scanner.OnlyOneResult=(p.only_one==true)
  local sa=to_addr(p.start) or 0
  local so=to_addr(p.stop)  or 0x7fffffffffffffff
  scanner.firstScan(st,vt,rtRounded,
    p.value and tostring(p.value) or "",
    p.value2 and tostring(p.value2) or "",
    sa,so,"+W-C",fsmNotAligned,"",false,false,false,false)
  scanner.waitTillDone()
  local fl=createFoundList(scanner); fl.initialize()
  STATE.scan={ scanner=scanner, found=fl, count=fl.Count,
               value_type=(p.value_type or "4byte") }
  return { count=fl.Count, value_type=STATE.scan.value_type }
end

CMD.scan_next = function(p)
  if not STATE.scan then error("no active scan; call scan_first first") end
  local st=STYPES[(p.scan_type or "exact"):lower()] or fsmEqualTo
  STATE.scan.found.deinitialize()
  STATE.scan.scanner.nextScan(st,rtRounded,
    p.value and tostring(p.value) or "",
    p.value2 and tostring(p.value2) or "",
    false,false,false,false)
  STATE.scan.scanner.waitTillDone()
  STATE.scan.found.initialize()
  STATE.scan.count=STATE.scan.found.Count
  return { count=STATE.scan.count }
end

CMD.scan_results = function(p)
  if not STATE.scan then error("no active scan") end
  local fl=STATE.scan.found
  local total=fl.Count
  local limit=math.min(tonumber(p.limit) or 100,1000)
  local offset=tonumber(p.offset) or 0
  local out={}
  for i=offset,math.min(offset+limit-1,total-1) do
    out[#out+1]={ index=i, address=fl.Address[i], value=fl.Value[i] }
  end
  return { results=out, total=total, offset=offset, limit=limit }
end

CMD.scan_reset = function(_)
  if STATE.scan then
    if STATE.scan.found then STATE.scan.found.destroy() end
    if STATE.scan.scanner then STATE.scan.scanner.destroy() end
    STATE.scan=nil
  end
  return { reset=true }
end

CMD.scan_aob = function(p)
  if not p.pattern then error("missing pattern") end
  local sa=to_addr(p.start) or 0
  local so=to_addr(p.stop)  or 0x7fffffffffffffff
  local results=AOBScan(p.pattern,sa,so,p.protection or "+X-C")
  local out={}
  if results then
    for i=0,results.Count-1 do out[#out+1]=results[i] end
    results.destroy()
  end
  return { pattern=p.pattern, count=#out, results=out }
end

-- ── cheat table ───────────────────────────────────────────────────────────
local function find_record(id)
  local al=getAddressList()
  for i=0,al.Count-1 do
    local e=al.getMemoryRecord(i)
    if e.ID==id then return e,al end
  end
  return nil,al
end

CMD.table_list = function(_)
  local al=getAddressList(); local out={}
  for i=0,al.Count-1 do
    local e=al.getMemoryRecord(i)
    out[#out+1]={ id=e.ID, index=i, description=e.Description,
      address=e.AddressString, value=e.Value, type=e.Type,
      active=e.Active }
  end
  return out
end

CMD.table_add = function(p)
  local al=getAddressList(); local mr=al.createMemoryRecord()
  mr.Description=p.description or "MCP entry"
  mr.Address=tostring(p.address or "0")
  mr.Type=VTYPES[(p.type or "4byte"):lower()] or vtDword
  if p.value~=nil then mr.Value=tostring(p.value) end
  return { id=mr.ID, description=mr.Description, address=mr.AddressString }
end

CMD.table_remove = function(p)
  local id=tonumber(p.id); if not id then error("missing id") end
  local e,al=find_record(id)
  if not e then error("record not found: "..id) end
  al.delete(e); return { removed=id }
end

CMD.table_set_value = function(p)
  local id=tonumber(p.id); if not id then error("missing id") end
  local e=find_record(id); if not e then error("record not found") end
  e.Value=tostring(p.value); return { id=id, value=p.value }
end

CMD.table_freeze = function(p)
  local id=tonumber(p.id); if not id then error("missing id") end
  local e=find_record(id); if not e then error("record not found") end
  local frozen=(p.frozen~=false); e.Active=frozen
  return { id=id, frozen=frozen }
end

CMD.table_enable = function(p)
  local id=tonumber(p.id); if not id then error("missing id") end
  local e=find_record(id); if not e then error("record not found") end
  e.Active=(p.active~=false); return { id=id, active=e.Active }
end

CMD.table_hotkey = function(p)
  local id=tonumber(p.id); if not id then error("missing id") end
  local e=find_record(id); if not e then error("record not found") end
  local keys=p.keys; if type(keys)~="table" then keys={tonumber(keys) or 0} end
  e.createHotkey(keys,tonumber(p.action) or 1)
  return { id=id, hotkey="created" }
end

CMD.table_save = function(p)
  if not p.path then error("missing path") end
  saveTable(p.path); return { saved=p.path }
end

CMD.table_load = function(p)
  if not p.path then error("missing path") end
  loadTable(p.path,p.merge==true)
  return { loaded=p.path, count=getAddressList().Count }
end

CMD.table_clear = function(_)
  local al=getAddressList()
  while al.Count>0 do al.delete(al.getMemoryRecord(0)) end
  return { cleared=true }
end

-- ── pointers ──────────────────────────────────────────────────────────────
CMD.pointer_resolve = function(p)
  local base=to_addr(p.base); if not base then error("invalid base") end
  local offsets=p.offsets or {}
  local cur=base; local chain={addr_str(cur)}
  for _,off in ipairs(offsets) do
    cur=readPointer(cur)
    if not cur or cur==0 then
      return { resolved="NULL", valid=false, chain=chain }
    end
    cur=cur+tonumber(off); chain[#chain+1]=addr_str(cur)
  end
  return { base=addr_str(base), offsets=offsets,
           resolved=addr_str(cur), valid=true, chain=chain }
end

CMD.pointer_scan = function(p)
  local addr=to_addr(p.address); if not addr then error("invalid address") end
  local file=TEMP_DIR.."\\cemcp_pscan_"..os.time()..".PTR"
  local scanner=createPointerScan()
  scanner.scanForPointers({
    address=addr,
    maxLevel=tonumber(p.max_level) or 4,
    structsize=tonumber(p.max_offset) or 2048,
    filename=file,
  })
  return { note="pointer scan started (async)", file=file }
end

-- ── disassembler / assembler ──────────────────────────────────────────────
CMD.disassemble = function(p)
  local addr=to_addr(p.address); if not addr then error("invalid address") end
  local count=tonumber(p.count) or 16; local out,cur={},addr
  for _=1,count do
    local text=disassemble(cur); local size=getInstructionSize(cur)
    out[#out+1]={ address=addr_str(cur), instruction=text, size=size }
    cur=cur+(size>0 and size or 1)
  end
  return out
end

CMD.assemble = function(p)
  if not p.code then error("missing code") end
  local addr=to_addr(p.address) or 0
  local bytes,err=assemble(p.code,addr)
  if not bytes then error(err or "assemble failed") end
  local h={}; for _,b in ipairs(bytes) do h[#h+1]=("%02X"):format(b) end
  return { bytes=table.concat(h," "), count=#bytes }
end

CMD.auto_assemble = function(p)
  if not p.script then error("missing script") end
  local enable=(p.enable~=false)
  local ok,err=autoAssemble(p.script,not enable)
  if ok then return { success=true, enabled=enable }
  else error(err or "auto-assemble failed") end
end

-- ── debugger ──────────────────────────────────────────────────────────────
CMD.find_what_writes = function(p)
  local addr=to_addr(p.address); if not addr then error("invalid address") end
  local dur=math.min(tonumber(p.duration) or 3,30)
  if not debug_isDebugging() then debugProcess(2) end
  local fww=findWhatWrites(addr); sleep(dur*1000)
  local results=fww.getResults and fww.getResults() or {}; fww.stop()
  local out={}
  for _,r in ipairs(results or {}) do
    out[#out+1]={ address=addr_str(r.Address or r.address),
      count=r.Count or r.count, instruction=r.Disassembly or "" }
  end
  return { address=addr_str(addr), instructions=out }
end

CMD.find_what_accesses = function(p)
  local addr=to_addr(p.address); if not addr then error("invalid address") end
  local dur=math.min(tonumber(p.duration) or 3,30)
  if not debug_isDebugging() then debugProcess(2) end
  local fwa=findWhatAccesses(addr); sleep(dur*1000)
  local results=fwa.getResults and fwa.getResults() or {}; fwa.stop()
  local out={}
  for _,r in ipairs(results or {}) do
    out[#out+1]={ address=addr_str(r.Address or r.address),
      count=r.Count or r.count, instruction=r.Disassembly or "" }
  end
  return { address=addr_str(addr), instructions=out }
end

CMD.breakpoint = function(p)
  local addr=to_addr(p.address); if not addr then error("invalid address") end
  if not debug_isDebugging() then debugProcess() end
  if p.remove then debug_removeBreakpoint(addr); return { removed=addr_str(addr) } end
  debug_setBreakpoint(addr,tonumber(p.size) or 1,p.trigger or bptExecute)
  return { breakpoint=addr_str(addr) }
end

-- ── Mono / Unity ──────────────────────────────────────────────────────────
CMD.mono_init = function(_)
  if LaunchMonoDataCollector then LaunchMonoDataCollector() end
  return { mono="initialized" }
end

CMD.mono_classes = function(p)
  if not mono_enumDomains then error("mono not available (call mono_init first)") end
  local filter=(p.filter or ""):lower(); local out={}
  for _,dom in ipairs(mono_enumDomains() or {}) do
    for _,asm in ipairs(mono_enumAssemblies(dom) or {}) do
      local img=mono_getImageFromAssembly(asm)
      for _,cls in ipairs(mono_image_enumClasses(img) or {}) do
        local name=cls.name or mono_class_getName(cls.class or cls)
        local ns=cls.namespace or ""
        if filter=="" or (name and name:lower():find(filter,1,true)) then
          out[#out+1]={ namespace=ns, name=name, class=addr_str(cls.class or cls) }
        end
      end
    end
  end
  return out
end

-- ── speedhack ─────────────────────────────────────────────────────────────
CMD.speedhack = function(p)
  local speed=tonumber(p.speed); if not speed then error("missing speed") end
  speedhack_setSpeed(speed); return { speed=speed }
end

-- ── lua passthrough ───────────────────────────────────────────────────────
CMD.lua_execute = function(p)
  if not p.code then error("missing code") end
  local output={}
  local real_print=print
  _G.print=function(...)
    local a={}; for i=1,select("#",...) do a[i]=tostring(select(i,...)) end
    output[#output+1]=table.concat(a,"\t")
  end
  local ok,result=pcall(function()
    local fn,e=load(p.code,"mcp","t",_G)
    if not fn then error(e) end; return fn()
  end)
  _G.print=real_print
  if ok then return { success=true, output=output,
                      result=result~=nil and tostring(result) or nil }
  else return { success=false, output=output, error=tostring(result) } end
end

-- ══════════════════════════════════════════════════════════════════════════
-- FILE-BASED IPC DISPATCHER
-- ══════════════════════════════════════════════════════════════════════════
local function dispatch(req)
  local cmd_name=req.cmd
  if not cmd_name then
    return { ok=false, error="missing 'cmd' field" }
  end
  local handler=CMD[cmd_name]
  if not handler then
    return { ok=false, error="unknown command: "..tostring(cmd_name) }
  end
  local params=req.params or {}
  local ok,result=pcall(handler,params)
  if ok then return { ok=true, data=result }
  else return { ok=false, error=tostring(result) } end
end

local function scan_for_requests()
  -- Find any file matching cemcp_*_req.json in TEMP
  -- CE Lua has no glob, so we try IDs 0000..9999 via a generation counter
  -- Instead, we use a single well-known file pair for simplicity;
  -- Python serializes requests via a file lock.
  local req_path=PREFIX.."req.json"
  local res_path=PREFIX.."res.json"

  if not file_exists(req_path) then return end

  local raw=read_file(req_path)
  if not raw then return end

  -- Atomically claim it: rename/delete so we don't double-process
  os.remove(req_path)

  local req=json_decode(raw)
  local response=dispatch(req)
  write_file(res_path, json_encode(response))
end

-- ── Start the polling timer ────────────────────────────────────────────────
local timer=createTimer(nil)
timer.Interval=POLL_MS
timer.OnTimer=function()
  if not STATE.running then timer.destroy(); return end
  local ok,err=pcall(scan_for_requests)
  if not ok then log("dispatch error: "..tostring(err)) end
end

-- ── Stop helper ────────────────────────────────────────────────────────────
function ce_mcp_stop()
  STATE.running=false
  log("bridge stopped")
end

log("bridge ready  (polling "..PREFIX.."req.json every "..POLL_MS.."ms)")
log("Send commands via Python MCP server.")
log("To stop: call ce_mcp_stop() in the Lua console.")
