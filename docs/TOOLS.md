# ce-mcp tool reference

Generated from the running server — 54 tools, v2.0.0.


## Connectivity & diagnostics

### `ce_status`

Arguments: —

Check the bridge is reachable; report CE version, uptime and whether a process is attached. Call this first — it never raises.

### `ce_version`

Arguments: —

Get Cheat Engine version, Lua version, install directory, and the bridge/protocol versions plus the paths it uses for IPC and logging.

### `ce_routes`

Arguments: —

List every command the in-CE bridge actually exposes. Use this when a tool reports 'unknown command' to see what this bridge build supports.

### `ce_capabilities`

Arguments: —

Report which Cheat Engine Lua functions exist in this CE build. Some functions people expect (createPointerScan, findWhatWrites, closeProcess) are not part of CE's Lua API at all; the bridge substitutes its own implementations. Check here before assuming a tool is broken.

### `ce_diagnostics`

Arguments: include_log, log_lines

Run a full self-test of the bridge and return a health report. Covers the JSON codec, temp-directory writability, address parsing, protection-filter validation, presence of the core CE API, and — when a process is attached — a real memory read. Also returns client-side call statistics and, by default, the tail of the bridge log. This is the right first move when something is not behaving as expected.

### `ce_debug_log`

Arguments: limit, level

Read the in-CE bridge's recent log entries (newest last). ``level`` filters to that severity and above: error, warn, info, debug, trace. Every request the bridge handled is logged with its timing, so this shows exactly what Cheat Engine did and where it failed.

### `ce_debug_level`

Arguments: level, to_file

Set the bridge's log verbosity: error, warn, info, debug or trace. ``debug`` traces every request and response; ``trace`` is noisier still. ``to_file`` toggles writing to %TEMP%/cemcp_bridge.log.

### `ce_debug_state`

Arguments: —

Dump the bridge's internal state: attached process, active scan and its settings, background jobs, outstanding allocations, request/error counters and the IPC file paths.


## Process

### `process_list`

Arguments: filter

List running processes (pid + name). Optionally substring-``filter``.

### `process_attach`

Arguments: **process**

Attach to a process by PID (int) or executable name (e.g. 'game.exe'). Required before any scan / read / write. Returns pid, name and whether the target is 64-bit. If this fails, Cheat Engine may need to run as administrator to open the target.

### `process_detach`

Arguments: —

Detach the debugger and clear scan state. Note: Cheat Engine's Lua API has no way to close the process handle, so the target stays selected in CE until you attach to something else.

### `process_current`

Arguments: —

Report which process is currently attached, if any, and whether the debugger is active on it.

### `process_modules`

Arguments: filter

List loaded modules (name, base address, size, path). Optional ``filter``. Module base addresses are the anchor for stable 'module+offset' pointers.

### `process_regions`

Arguments: writable, executable

Enumerate committed memory regions with decoded protection flags. ``writable=True`` keeps only writable regions; ``executable=False`` drops executable ones. Returns total size, so you can see how much memory a scan over the same filter would have to cover.


## Memory

### `memory_read`

Arguments: **address**, type, size, wide, signed

Read a value from memory. ``address`` accepts hex ('0x7FF...'), decimal, a symbol, or 'module+offset'. ``size`` applies to string/aob reads. ``wide`` reads UTF-16 strings. ``type`` is one of: byte, 2byte/word, 4byte/int, 8byte/qword, float, double, string, aob (space-separated hex), pointer.

### `memory_read_batch`

Arguments: **reads**

Read many addresses in one round trip. ``reads`` is a list of objects like {"address": "0x...", "type": "float"}. Each entry reports its own value or error, so one bad address does not fail the batch.

### `memory_write`

Arguments: **address**, **value**, type, wide

Write a value to memory and verify it by reading back. Returns ``previous``, ``readback`` and ``verified``. If ``verified`` is false the game is probably rewriting the address every frame — freeze it with table_add + table_freeze instead. ``type`` is one of: byte, 2byte/word, 4byte/int, 8byte/qword, float, double, string, aob. For aob, pass value as a hex string like 'AA BB CC'.

### `memory_dump`

Arguments: **address**, size

Hex-dump a region of memory (16 bytes/row, hex + ASCII). Max 64 KiB.

### `memory_alloc`

Arguments: size, near

Allocate executable memory in the target (for code caves). Optionally ``near`` an address so 32-bit relative jumps stay in range.

### `memory_free`

Arguments: **address**

Free memory previously allocated with ``memory_alloc``.


## Scanning

### `scan_estimate`

Arguments: value_type, protection, alignment

Report how much memory a scan with these settings would actually cover. Returns matching region count, total megabytes broken down by private / image / mapped memory, the number of addresses to test, and the disk an unknown-value snapshot would consume. Run this before a broad scan — an unknown-value float scan of a large 64-bit game can write many gigabytes.

### `scan_first`

Arguments: value, value_type, scan_type, value2, start, stop, only_one, protection, alignment, regions, wait

Run a first scan over the attached process. ``scan_type``: exact, bigger, smaller, between (needs value2), or unknown. (changed/unchanged/increased/decreased are next-scan only.) ``protection`` defaults to '+W-X-C' — writable, NOT executable, excluding copy-on-write. ``alignment`` defaults to 'auto' (the value's size, capped at 4), matching CE's Fast Scan; pass 'none' only if a value may be unaligned, as that multiplies cost. ``regions`` limits the memory class scanned: 'private' (dynamic game state — much cheaper), 'image', 'private+image', 'mapped', 'all', or 'default'. Returns as soon as the scan finishes or ``wait`` seconds elapse. If ``status`` is 'running', poll scan_status rather than calling again. With scan_type='unknown' the result is a snapshot: count 0 and region_scan=true is expected. Change the value in the target, then narrow with scan_next.

### `scan_next`

Arguments: value, scan_type, value2, compare_to, percentage, wait

Narrow the active scan. ``scan_type``: exact, bigger, smaller, between, changed, unchanged, increased, decreased, increasedby, decreasedby. The usual loop is: let the value change in the target, scan 'changed'; hold it steady, scan 'unchanged'; repeat until few results remain. ``compare_to`` compares against a snapshot saved with scan_save_results instead of the previous scan — useful for A/B state comparisons.

### `scan_status`

Arguments: —

Report the active scan: status, progress percentage, match count and elapsed time. Poll this while a scan reports 'running' or 'cancelling'. With no MCP scan active it reports Cheat Engine's own GUI scan instead.

### `scan_cancel`

Arguments: force

Abort the running scan inside Cheat Engine. Use this rather than abandoning a call — a scan started here keeps running in CE and will block every later request until it finishes. The default asks the scanner to stop at its next safe point and returns status='cancelling'; poll scan_status until it becomes 'cancelled'. Only pass ``force=True`` if a graceful stop will not take: Cheat Engine then pops a modal warning that later scans may misbehave and recommends restarting it.

### `scan_results`

Arguments: limit, offset

Page through the current scan's matches (address + value). Max 1000/call. Reports ``source``: 'mcp' for a scan started here, 'gui' when reading the scan you ran by hand in Cheat Engine's window.

### `scan_save_results`

Arguments: **name**

Save the current scan results under ``name`` so a later scan_next can compare against them with ``compare_to``. Handy for isolating a value that differs between two game states.

### `scan_reset`

Arguments: force

Discard the active scan and free its result file. A running scan is first asked to stop gracefully; while it is still unwinding this returns reset=False and status='cancelling'. Poll scan_status and call scan_reset again after it settles. Finished scans are simply released. ``force=True`` is an explicit last resort because Cheat Engine warns that later scans may misbehave after forced termination.

### `scan_aob`

Arguments: **pattern**, protection

Array-of-bytes pattern scan. ``pattern`` like 'DE AD ?? EF' (?? = wildcard). Defaults to executable memory, since AOB scans usually target code to hook.


## Cheat table

### `table_list`

Arguments: —

List entries in the cheat table (id, description, address, value, active).

### `table_add`

Arguments: **address**, description, type, value

Add an entry to the cheat table. ``address`` may be a literal address or a 'module+offset' expression. Returns the new entry's id.

### `table_remove`

Arguments: **id**

Remove a cheat-table entry by id.

### `table_set_value`

Arguments: **id**, **value**

Set a cheat-table entry's value (writes it to the target) and read back.

### `table_freeze`

Arguments: **id**, frozen

Freeze (or unfreeze) an entry so its value is held constant. This is the reliable way to hold a value the game rewrites every frame.

### `table_enable`

Arguments: **id**, active

Activate/deactivate an entry (e.g. an Auto Assembler 'script' entry).

### `table_hotkey`

Arguments: **id**, **keys**, action, value

Bind a hotkey to an entry. ``action``: 1=toggle freeze, 2=set value, 3=decrease, 4=increase. ``keys`` is a virtual-key code or list of codes.

### `table_save`

Arguments: **path**

Save the current cheat table to a .CT file at ``path`` (on the CE host).

### `table_load`

Arguments: **path**, merge

Load a .CT file. ``merge`` keeps existing entries; otherwise replaces.

### `table_clear`

Arguments: —

Remove all entries from the cheat table.


## Pointers

### `pointer_resolve`

Arguments: **base**, offsets

Resolve a multi-level pointer chain and show every step. Reads the pointer at ``base``, adds offsets[0], reads again, and so on. On failure it reports which level broke, so you can tell a stale base from a wrong offset. Use this to verify a 'module+offset -> [+off] -> [+off]' path before adding it to the cheat table.


## Code

### `disassemble`

Arguments: **address**, count

Disassemble ``count`` instructions from ``address``, with the raw bytes of each instruction split out from the opcode text.

### `assemble`

Arguments: **code**, address

Assemble a single instruction (e.g. 'mov eax,1') to bytes. ``address`` provides context for relative operands.

### `auto_assemble`

Arguments: **script**, enable

Run a Cheat Engine Auto Assembler script — the core of code-injection cheats (godmode, infinite ammo, etc.). The script is syntax-checked first. Pass ``enable=False`` to run the script's [DISABLE] section and revert. Example godmode skeleton:: [ENABLE] aobscanmodule(hook,game.exe,29 87 ?? ?? ?? ??) // sub [edi+x],eax alloc(newmem,128,hook) label(ret) newmem: // do nothing instead of subtracting health jmp ret hook: jmp newmem nop 2 ret: [DISABLE] hook: db 29 87 ?? ?? ?? ?? dealloc(newmem)


## Debugger

### `find_what_writes`

Arguments: **address**, size, duration

Find the instructions that WRITE to ``address`` — the classic way to locate the code that changes a value, and from there its base pointer. Sets a hardware write breakpoint and collects hits in the background, returning a ``job_id`` immediately. Trigger the value in the target, then read the hits with job_status. Each hit records the instruction, how many times it fired, and a register snapshot. ``size`` must be 1, 2, 4 or 8.

### `find_what_accesses`

Arguments: **address**, size, duration

Find instructions that READ OR WRITE ``address``, as a background job. Same mechanics as find_what_writes; useful for finding a base instruction for pointer/structure work. Poll the returned ``job_id`` with job_status.

### `breakpoint`

Arguments: **address**, remove, size, trigger

Set (or with ``remove=True`` clear) a breakpoint at ``address``. ``trigger``: execute, write or access.

### `breakpoint_list`

Arguments: —

List the addresses that currently have breakpoints set.


## Jobs

### `job_status`

Arguments: **job_id**, limit

Get a background job's status and collected results (e.g. the instructions a find_what_writes trace has captured so far).

### `job_list`

Arguments: —

List background jobs with their kind, status and result count.

### `job_cancel`

Arguments: **job_id**

Stop a background job early and return whatever it collected. This also removes any breakpoint the job installed.


## Mono / Unity

### `mono_init`

Arguments: —

Initialise Cheat Engine's Mono data collector (for Unity/Mono games). Call once after attaching, before ``mono_classes``.

### `mono_classes`

Arguments: filter, limit

Enumerate Mono/Unity classes (namespace, name, class pointer). Optional substring ``filter`` matches namespace or name. Requires ``mono_init``.


## Misc

### `speedhack`

Arguments: **speed**

Set the speedhack multiplier (1.0 = normal, 2.0 = double, 0.5 = half). Affects the game's perception of time.

### `lua_execute`

Arguments: **code**

Escape hatch: run arbitrary Lua inside Cheat Engine, capturing print output and the return value. Use when no dedicated tool covers what you need — and prefer a dedicated tool when one exists, since this bypasses the argument validation the others perform.
