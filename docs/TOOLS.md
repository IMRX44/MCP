# Tool Reference

Full reference for every MCP tool in `ce-mcp`. Addresses accept hex
(`0x7FF6...`), decimal, a symbol name, or a `module+offset` expression
(e.g. `game.exe+1A2B3C`).

Value `type` vocabulary (where applicable):
`byte`, `2byte`/`word`, `4byte`/`int`, `8byte`/`qword`, `float`, `double`,
`string`, `aob` (space-separated hex), `pointer`.

Scan `scan_type` vocabulary:
`exact`, `notequal`, `bigger`, `smaller`, `between` (needs `value2`),
`unknown`, `changed`, `unchanged`, `increased`, `decreased`,
`increasedby`, `decreasedby`.

---

## Connectivity

| Tool | Args | Returns |
|------|------|---------|
| `ce_status` | — | `{ pong, version }` |
| `ce_version` | — | CE version, Lua version, install dir |
| `ce_routes` | — | List of raw bridge routes |

## Process

| Tool | Args | Description |
|------|------|-------------|
| `process_list` | `filter?` | List processes (pid, name) |
| `process_attach` | `process` (pid or name) | Open a process — **required first** |
| `process_detach` | — | Close the current process |
| `process_current` | — | Which process is attached |
| `process_modules` | `filter?` | Loaded modules (name, base, size, path) |
| `process_regions` | — | Committed memory regions |

## Memory

| Tool | Args | Description |
|------|------|-------------|
| `memory_read` | `address, type=4byte, size=64, wide=false, signed=false` | Read one value |
| `memory_read_batch` | `reads=[{address,type,size?}]` | Read many in one call |
| `memory_write` | `address, value, type=4byte, wide=false` | Write one value |
| `memory_dump` | `address, size=256` | Hex+ASCII dump (≤64 KiB) |
| `memory_alloc` | `size=4096, near?` | Allocate executable memory |
| `memory_free` | `address` | Free allocated memory |

## Scanning

| Tool | Args | Description |
|------|------|-------------|
| `scan_first` | `value?, value_type=4byte, scan_type=exact, value2?, start?, stop?, only_one=false` | First scan; returns match count |
| `scan_next` | `value?, scan_type=exact, value2?` | Narrow the scan |
| `scan_results` | `limit=100, offset=0` | Page matches (≤1000/call) |
| `scan_reset` | — | Discard active scan |
| `scan_aob` | `pattern, start?, stop?, protection?` | AOB pattern scan (`??` wildcard) |

## Cheat table

| Tool | Args | Description |
|------|------|-------------|
| `table_list` | — | List entries |
| `table_add` | `address, description?, type=4byte, value?` | Add entry → returns `id` |
| `table_remove` | `id` | Remove entry |
| `table_set_value` | `id, value` | Set/write entry value |
| `table_freeze` | `id, frozen=true` | Freeze/unfreeze |
| `table_enable` | `id, active=true` | Activate/deactivate (e.g. AA scripts) |
| `table_hotkey` | `id, keys, action=1, value?` | Bind hotkey (1=toggle,2=set,3=dec,4=inc) |
| `table_save` | `path` | Save `.CT` |
| `table_load` | `path, merge=false` | Load `.CT` |
| `table_clear` | — | Remove all entries |

## Pointers

| Tool | Args | Description |
|------|------|-------------|
| `pointer_resolve` | `base, offsets=[]` | Walk a pointer chain; returns final address + chain |
| `pointer_scan` | `address, max_level=4, max_offset=2048` | Start a pointer scan (async, view in CE) |

## Code

| Tool | Args | Description |
|------|------|-------------|
| `disassemble` | `address, count=16` | Disassemble instructions |
| `assemble` | `code, address?` | Assemble one instruction → bytes |
| `auto_assemble` | `script, enable=true` | Run an Auto Assembler script (`enable=false` reverts) |

## Debugger

| Tool | Args | Description |
|------|------|-------------|
| `find_what_writes` | `address, duration=3` | Instructions that write to address |
| `find_what_accesses` | `address, duration=3` | Instructions that read/write address |
| `breakpoint` | `address, remove=false, size=1` | Set/clear a breakpoint |

## Mono / Unity

| Tool | Args | Description |
|------|------|-------------|
| `mono_init` | — | Initialise the Mono data collector |
| `mono_classes` | `filter?` | Enumerate Mono/Unity classes |

## Misc

| Tool | Args | Description |
|------|------|-------------|
| `speedhack` | `speed` | Set time multiplier (1.0 normal) |
| `lua_execute` | `code` | Run arbitrary Lua in CE; returns output + result |
