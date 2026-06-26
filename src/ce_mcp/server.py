"""ce-mcp — MCP server exposing Cheat Engine to AI agents.

Each ``@mcp.tool`` wraps a route on the in-CE Lua bridge. Tools are grouped:

  * Process    — list / attach / detach / inspect modules & regions
  * Memory     — read / write / dump / batch-read raw addresses
  * Scan       — first/next value scans, AOB pattern scans, result paging
  * Table      — build & drive the cheat table (add/freeze/hotkey/save/load)
  * Pointers   — resolve multi-level pointer chains, kick off pointer scans
  * Code       — disassemble, assemble, run Auto Assembler scripts
  * Debugger   — find-what-writes / find-what-accesses, breakpoints
  * Mono       — enumerate Unity/Mono classes
  * Misc       — speedhack, raw Lua escape hatch

Results are returned to the model as JSON-serialisable Python objects.
"""

from __future__ import annotations

from typing import Any

from mcp.server.fastmcp import FastMCP

from .client import BridgeError, CheatEngineClient

mcp = FastMCP(
    "cheat-engine",
    instructions=(
        "Drive Cheat Engine to inspect and modify a running process's memory. "
        "Typical flow: process_list -> process_attach -> scan_first (then "
        "scan_next to narrow) -> scan_results -> table_add/memory_write. "
        "Use pointer_resolve for stable pointer chains and auto_assemble for "
        "code injection / 'godmode' style cheats. Always attach to a process "
        "before scanning or reading memory."
    ),
)

_client: CheatEngineClient | None = None


def client() -> CheatEngineClient:
    global _client
    if _client is None:
        _client = CheatEngineClient()
    return _client


async def _call(cmd: str, **params: Any) -> Any:
    try:
        return await client().call(cmd, **params)
    except BridgeError as exc:
        return {"error": str(exc)}


# ─────────────────────────────────────────────────────────────────────────────
# Connectivity
# ─────────────────────────────────────────────────────────────────────────────
@mcp.tool()
async def ce_status() -> Any:
    """Check the bridge is reachable and report the Cheat Engine version."""
    return await _call("ping")


@mcp.tool()
async def ce_version() -> Any:
    """Get Cheat Engine version, Lua version, and install directory."""
    return await _call("ce_version")


@mcp.tool()
async def ce_routes() -> Any:
    """List every low-level route the in-CE bridge exposes (for debugging)."""
    return await _call("ping")


# ─────────────────────────────────────────────────────────────────────────────
# Process
# ─────────────────────────────────────────────────────────────────────────────
@mcp.tool()
async def process_list(filter: str | None = None) -> Any:
    """List running processes (pid + name). Optionally substring-``filter``."""
    return await _call("process_list", filter=filter)


@mcp.tool()
async def process_attach(process: str | int) -> Any:
    """Attach (open) a process by PID (int) or by executable name (e.g. 'game.exe').

    Required before any scan / read / write. Returns pid, name, and whether the
    target is 64-bit.
    """
    return await _call("process_attach", process=process)


@mcp.tool()
async def process_detach() -> Any:
    """Detach from the currently open process."""
    return await _call("process_detach")


@mcp.tool()
async def process_current() -> Any:
    """Report which process is currently attached, if any."""
    return await _call("process_current")


@mcp.tool()
async def process_modules(filter: str | None = None) -> Any:
    """List loaded modules (name, base address, size, path). Optional ``filter``.

    Module base addresses are the anchor for stable 'module+offset' pointers.
    """
    return await _call("process_modules", filter=filter)


@mcp.tool()
async def process_regions() -> Any:
    """Enumerate committed memory regions (base, size, protection flags)."""
    return await _call("process_regions")


# ─────────────────────────────────────────────────────────────────────────────
# Raw memory
# ─────────────────────────────────────────────────────────────────────────────
@mcp.tool()
async def memory_read(
    address: str,
    type: str = "4byte",
    size: int = 64,
    wide: bool = False,
    signed: bool = False,
) -> Any:
    """Read a value from memory.

    ``address`` accepts hex ('0x7FF...'), decimal, a symbol, or 'module+offset'.
    ``size`` applies to string/aob reads. ``wide`` reads UTF-16 strings.
    type is one of: byte, 2byte/word, 4byte/int, 8byte/qword, float, double,
    string, aob (space-separated hex), pointer.
    """
    return await _call(
        "memory_read", address=address, type=type, size=size,
        wide=wide, signed=signed,
    )


@mcp.tool()
async def memory_read_batch(reads: list[dict]) -> Any:
    """Read many addresses in one round trip.

    ``reads`` is a list of objects like {"address": "0x...", "type": "float"}.
    """
    return await _call("memory_read_batch", reads=reads)


@mcp.tool()
async def memory_write(address: str, value: Any, type: str = "4byte", wide: bool = False) -> Any:
    """Write a value to memory.

    type is one of: byte, 2byte/word, 4byte/int, 8byte/qword, float, double,
    string, aob, pointer. For aob, pass value as a hex string like 'AA BB CC'.
    """
    return await _call("memory_write", address=address, value=value, type=type, wide=wide)


@mcp.tool()
async def memory_dump(address: str, size: int = 256) -> Any:
    """Hex-dump a region of memory (16 bytes/row, hex + ASCII). Max 64 KiB."""
    return await _call("memory_dump", address=address, size=size)


@mcp.tool()
async def memory_alloc(size: int = 4096, near: str | None = None) -> Any:
    """Allocate executable memory in the target (for code caves). Optionally
    ``near`` an address so 32-bit relative jumps remain in range."""
    return await _call("memory_alloc", size=size, near=near)


@mcp.tool()
async def memory_free(address: str) -> Any:
    """Free memory previously allocated with ``memory_alloc``."""
    return await _call("memory_free", address=address)


# ─────────────────────────────────────────────────────────────────────────────
# Scanning
# ─────────────────────────────────────────────────────────────────────────────
@mcp.tool()
async def scan_first(
    value: Any = None,
    value_type: str = "4byte",
    scan_type: str = "exact",
    value2: Any = None,
    start: str | None = None,
    stop: str | None = None,
    only_one: bool = False,
) -> Any:
    """Run a first scan over the attached process and return the match count.

    ``scan_type``: exact, bigger, smaller, between (needs value2), unknown,
    changed, unchanged, increased, decreased, increasedby, decreasedby.
    For 'unknown' start a value-agnostic scan, then narrow with ``scan_next``.
    Use ``scan_results`` to page through matches.
    """
    return await _call(
        "/scan/first", value=value, value_type=value_type, scan_type=scan_type,
        value2=value2, start=start, stop=stop, only_one=only_one,
    )


@mcp.tool()
async def scan_next(value: Any = None, scan_type: str = "exact", value2: Any = None) -> Any:
    """Narrow the active scan (next scan). Same ``scan_type`` vocabulary as
    ``scan_first``. Typical: scan changed/unchanged/increased/decreased while
    the in-game value moves, until few matches remain."""
    return await _call("scan_next", value=value, scan_type=scan_type, value2=value2)


@mcp.tool()
async def scan_results(limit: int = 100, offset: int = 0) -> Any:
    """Page through the current scan's matches (address + value). Max 1000/call."""
    return await _call("scan_results", limit=limit, offset=offset)


@mcp.tool()
async def scan_reset() -> Any:
    """Discard the active scan and free its memory."""
    return await _call("scan_reset")


@mcp.tool()
async def scan_aob(
    pattern: str,
    start: str | None = None,
    stop: str | None = None,
    protection: str | None = None,
) -> Any:
    """Array-of-bytes pattern scan. ``pattern`` like 'DE AD ?? EF' (?? = wildcard).
    Returns matching addresses. Great for finding code to hook."""
    return await _call("scan_aob", pattern=pattern, start=start, stop=stop, protection=protection)


# ─────────────────────────────────────────────────────────────────────────────
# Cheat table
# ─────────────────────────────────────────────────────────────────────────────
@mcp.tool()
async def table_list() -> Any:
    """List entries in the cheat table (id, description, address, value, frozen)."""
    return await _call("table_list")


@mcp.tool()
async def table_add(
    address: str,
    description: str = "MCP entry",
    type: str = "4byte",
    value: Any = None,
) -> Any:
    """Add an entry to the cheat table. ``address`` may be a literal address or a
    'module+offset' expression. Returns the new entry's id."""
    return await _call("table_add", address=address, description=description, type=type, value=value)


@mcp.tool()
async def table_remove(id: int) -> Any:
    """Remove a cheat-table entry by id."""
    return await _call("table_remove", id=id)


@mcp.tool()
async def table_set_value(id: int, value: Any) -> Any:
    """Set the value of a cheat-table entry (writes it to the target)."""
    return await _call("table_set_value", id=id, value=value)


@mcp.tool()
async def table_freeze(id: int, frozen: bool = True) -> Any:
    """Freeze (or unfreeze) a cheat-table entry so its value is held constant."""
    return await _call("table_freeze", id=id, frozen=frozen)


@mcp.tool()
async def table_enable(id: int, active: bool = True) -> Any:
    """Activate/deactivate an entry (e.g. an Auto Assembler 'script' entry)."""
    return await _call("table_enable", id=id, active=active)


@mcp.tool()
async def table_hotkey(id: int, keys: list[int] | int, action: int = 1, value: Any = None) -> Any:
    """Bind a hotkey to an entry. ``action``: 1=toggle freeze, 2=set value,
    3=decrease, 4=increase. ``keys`` is a virtual-key code or list of codes."""
    return await _call("table_hotkey", id=id, keys=keys, action=action, value=value)


@mcp.tool()
async def table_save(path: str) -> Any:
    """Save the current cheat table to a .CT file at ``path`` (on the CE host)."""
    return await _call("table_save", path=path)


@mcp.tool()
async def table_load(path: str, merge: bool = False) -> Any:
    """Load a .CT file. ``merge`` keeps existing entries; otherwise replaces."""
    return await _call("table_load", path=path, merge=merge)


@mcp.tool()
async def table_clear() -> Any:
    """Remove all entries from the cheat table."""
    return await _call("table_clear")


# ─────────────────────────────────────────────────────────────────────────────
# Pointers
# ─────────────────────────────────────────────────────────────────────────────
@mcp.tool()
async def pointer_resolve(base: str, offsets: list[int] | None = None) -> Any:
    """Resolve a multi-level pointer chain.

    Reads the pointer at ``base``, adds offsets[0], reads again, and so on —
    returning the final address and the full chain. Use this to verify a
    'module+offset -> [+off] -> [+off]' path before adding it to the table.
    """
    return await _call("pointer_resolve", base=base, offsets=offsets or [])


@mcp.tool()
async def pointer_scan(address: str, max_level: int = 4, max_offset: int = 2048) -> Any:
    """Start a pointer scan for ``address`` (finds stable pointer paths to it).
    Runs asynchronously inside Cheat Engine; inspect/refine results in CE's UI.
    """
    return await _call("pointer_scan", address=address, max_level=max_level, max_offset=max_offset)


# ─────────────────────────────────────────────────────────────────────────────
# Code: disassemble / assemble / auto assembler
# ─────────────────────────────────────────────────────────────────────────────
@mcp.tool()
async def disassemble(address: str, count: int = 16) -> Any:
    """Disassemble ``count`` instructions starting at ``address``."""
    return await _call("disassemble", address=address, count=count)


@mcp.tool()
async def assemble(code: str, address: str | None = None) -> Any:
    """Assemble a single instruction (e.g. 'mov eax,1') to bytes. ``address``
    provides context for relative operands."""
    return await _call("assemble", code=code, address=address)


@mcp.tool()
async def auto_assemble(script: str, enable: bool = True) -> Any:
    """Run a Cheat Engine Auto Assembler script — the core of code-injection
    cheats (godmode, infinite ammo, etc.).

    Pass ``enable=False`` to run the script's [DISABLE] section to revert.
    Example godmode skeleton::

        [ENABLE]
        aobscanmodule(hook,game.exe,29 87 ?? ?? ?? ??)  // sub [edi+x],eax
        alloc(newmem,128,hook)
        label(ret)
        newmem:
          // do nothing instead of subtracting health
          jmp ret
        hook:
          jmp newmem
          nop 2
        ret:
        [DISABLE]
        hook:
          db 29 87 ?? ?? ?? ??
        dealloc(newmem)
    """
    return await _call("auto_assemble", script=script, enable=enable)


# ─────────────────────────────────────────────────────────────────────────────
# Debugger
# ─────────────────────────────────────────────────────────────────────────────
@mcp.tool()
async def find_what_writes(address: str, duration: int = 3) -> Any:
    """Attach the debugger and collect the instructions that WRITE to
    ``address`` over ``duration`` seconds. The classic way to find the code that
    changes a value (e.g. the instruction that decrements health)."""
    return await _call("find_what_writes", address=address, duration=duration)


@mcp.tool()
async def find_what_accesses(address: str, duration: int = 3) -> Any:
    """Collect instructions that READ OR WRITE ``address`` over ``duration``
    seconds. Useful to find a base instruction for pointer/structure work."""
    return await _call("find_what_accesses", address=address, duration=duration)


@mcp.tool()
async def breakpoint(address: str, remove: bool = False, size: int = 1) -> Any:
    """Set (or, with ``remove=True``, clear) a breakpoint at ``address``."""
    return await _call("breakpoint", address=address, remove=remove, size=size)


# ─────────────────────────────────────────────────────────────────────────────
# Mono / Unity
# ─────────────────────────────────────────────────────────────────────────────
@mcp.tool()
async def mono_init() -> Any:
    """Initialise Cheat Engine's Mono data collector (for Unity/Mono games).
    Call once after attaching, before ``mono_classes``."""
    return await _call("mono_init")


@mcp.tool()
async def mono_classes(filter: str | None = None) -> Any:
    """Enumerate Mono/Unity classes (namespace, name, class pointer). Optional
    substring ``filter``. Requires ``mono_init`` first."""
    return await _call("mono_classes", filter=filter)


# ─────────────────────────────────────────────────────────────────────────────
# Misc
# ─────────────────────────────────────────────────────────────────────────────
@mcp.tool()
async def speedhack(speed: float) -> Any:
    """Set the speedhack multiplier (1.0 = normal, 2.0 = double speed, 0.5 =
    half). Affects the game's perception of time."""
    return await _call("speedhack", speed=speed)


@mcp.tool()
async def lua_execute(code: str) -> Any:
    """Escape hatch: run arbitrary Lua inside Cheat Engine and capture print
    output + return value. Use when no dedicated tool covers what you need."""
    return await _call("lua_execute", code=code)


def main() -> None:
    """Console entry point — runs the MCP server over stdio."""
    mcp.run()


if __name__ == "__main__":
    main()
