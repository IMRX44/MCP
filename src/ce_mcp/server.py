"""ce-mcp — MCP server exposing Cheat Engine to AI agents.

Each ``@mcp.tool`` wraps one command on the in-CE Lua bridge. Tools are grouped:

  * Connectivity — status, version, route list, self-test, live log tail
  * Process      — list / attach / inspect modules & memory regions
  * Memory       — read / write / dump / batch-read raw addresses
  * Scan         — first/next value scans, AOB patterns, paging, cost estimate
  * Table        — build & drive the cheat table (add/freeze/hotkey/save/load)
  * Pointers     — resolve multi-level pointer chains
  * Code         — disassemble, assemble, run Auto Assembler scripts
  * Debugger     — data breakpoints that report what writes/reads an address
  * Jobs         — poll and cancel background work
  * Mono         — enumerate Unity/Mono classes
  * Misc         — speedhack, raw Lua escape hatch

Failures come back as ``{"error": ..., "hint": ...}`` rather than raising, so a
model can read the reason and correct itself in the next call.
"""

from __future__ import annotations

import os
from typing import Any

from mcp.server.fastmcp import FastMCP

from . import __version__
from .client import BridgeError, CheatEngineClient
from .logging_setup import get_logger

log = get_logger()

mcp = FastMCP(
    "cheat-engine",
    instructions=(
        "Drive Cheat Engine to inspect and modify a running process's memory.\n"
        "\n"
        "Start with ce_status. If anything behaves oddly, ce_diagnostics runs a "
        "full self-test and ce_debug_log returns the bridge's recent log.\n"
        "\n"
        "Typical value hunt:\n"
        "  1. process_list -> process_attach\n"
        "  2. scan_estimate to see how much memory the scan will cover\n"
        "  3. scan_first (value_type + either an exact value or scan_type='unknown')\n"
        "  4. change the value in the target, then scan_next with 'changed', "
        "'unchanged', 'increased' or 'decreased'; repeat until few results remain\n"
        "  5. scan_results -> memory_write or table_add/table_freeze\n"
        "\n"
        "Scans run in the background: scan_first and scan_next return "
        "status='running' if they need longer than the wait window. Poll "
        "scan_status and abort with scan_cancel — never just retry.\n"
        "\n"
        "An 'unknown' first scan stores a snapshot and reports count 0 with "
        "region_scan=true. That is correct, not a failure: addresses only "
        "appear after the first scan_next.\n"
        "\n"
        "Scans default to protection '+W-X-C' (writable, non-executable, "
        "excluding copy-on-write) and 4-byte alignment, which is both safe and "
        "far cheaper than scanning everything. Pass regions='private' to cut "
        "the scanned range further when a scan is too large.\n"
        "\n"
        "Use pointer_resolve to verify a stable pointer chain, and "
        "auto_assemble for code injection. Always attach to a process first."
    ),
)

_client: CheatEngineClient | None = None


def client() -> CheatEngineClient:
    global _client
    if _client is None:
        _client = CheatEngineClient()
    return _client


async def _call(cmd: str, **params: Any) -> Any:
    """Invoke a bridge command, returning errors as data instead of raising."""
    try:
        return await client().call(cmd, **params)
    except BridgeError as exc:
        return exc.as_dict()
    except Exception as exc:  # never let an unexpected fault kill the session
        log.exception("unexpected failure in %s", cmd)
        return {"error": f"{type(exc).__name__}: {exc}", "command": cmd}


# ─────────────────────────────────────────────────────────────────────────────
# Connectivity & diagnostics
# ─────────────────────────────────────────────────────────────────────────────
@mcp.tool()
async def ce_status() -> Any:
    """Check the bridge is reachable; report CE version, uptime and whether a
    process is attached. Call this first — it never raises."""
    return await client().health()


@mcp.tool()
async def ce_version() -> Any:
    """Get Cheat Engine version, Lua version, install directory, and the
    bridge/protocol versions plus the paths it uses for IPC and logging."""
    return await _call("ce_version")


@mcp.tool()
async def ce_routes() -> Any:
    """List every command the in-CE bridge actually exposes. Use this when a
    tool reports 'unknown command' to see what this bridge build supports."""
    return await _call("ce_routes")


@mcp.tool()
async def ce_capabilities() -> Any:
    """Report which Cheat Engine Lua functions exist in this CE build.

    Some functions people expect (createPointerScan, findWhatWrites,
    closeProcess) are not part of CE's Lua API at all; the bridge substitutes
    its own implementations. Check here before assuming a tool is broken.
    """
    return await _call("debug_capabilities")


@mcp.tool()
async def ce_diagnostics(include_log: bool = True, log_lines: int = 40) -> Any:
    """Run a full self-test of the bridge and return a health report.

    Covers the JSON codec, temp-directory writability, address parsing,
    protection-filter validation, presence of the core CE API, and — when a
    process is attached — a real memory read. Also returns client-side call
    statistics and, by default, the tail of the bridge log. This is the right
    first move when something is not behaving as expected.
    """
    report: dict[str, Any] = {
        "server_version": __version__,
        "config": {
            "temp_dir": str(client().temp_dir),
            "default_timeout_s": client().timeout,
            "log_level": os.getenv("CE_MCP_LOG_LEVEL", "info"),
        },
    }
    report["bridge"] = await client().health()

    if report["bridge"].get("reachable"):
        report["selftest"] = await _call("debug_selftest")
        report["capabilities"] = await _call("debug_capabilities")
        report["state"] = await _call("debug_state")
        if include_log:
            report["log"] = await _call("debug_log", limit=log_lines)
        selftest = report["selftest"]
        report["healthy"] = bool(isinstance(selftest, dict) and selftest.get("healthy"))
    else:
        report["healthy"] = False
        report["next_step"] = (
            "Cheat Engine is not answering. Open CE and confirm the output panel "
            "shows '[CE-MCP] bridge ready'. The bridge lives in "
            "<Cheat Engine>\\autorun\\ce_mcp_bridge.lua."
        )

    # Read counters last, so they include the probes above rather than a
    # snapshot taken before any of them ran.
    report["client"] = client().stats.as_dict()
    return report


@mcp.tool()
async def ce_debug_log(limit: int = 100, level: str = "trace") -> Any:
    """Read the in-CE bridge's recent log entries (newest last).

    ``level`` filters to that severity and above: error, warn, info, debug,
    trace. Every request the bridge handled is logged with its timing, so this
    shows exactly what Cheat Engine did and where it failed.
    """
    return await _call("debug_log", limit=limit, level=level)


@mcp.tool()
async def ce_debug_level(level: str = "info", to_file: bool | None = None) -> Any:
    """Set the bridge's log verbosity: error, warn, info, debug or trace.

    ``debug`` traces every request and response; ``trace`` is noisier still.
    ``to_file`` toggles writing to %TEMP%/cemcp_bridge.log.
    """
    return await _call("debug_set_level", level=level, to_file=to_file)


@mcp.tool()
async def ce_debug_state() -> Any:
    """Dump the bridge's internal state: attached process, active scan and its
    settings, background jobs, outstanding allocations, request/error counters
    and the IPC file paths."""
    return await _call("debug_state")


# ─────────────────────────────────────────────────────────────────────────────
# Process
# ─────────────────────────────────────────────────────────────────────────────
@mcp.tool()
async def process_list(filter: str | None = None) -> Any:
    """List running processes (pid + name). Optionally substring-``filter``."""
    return await _call("process_list", filter=filter)


@mcp.tool()
async def process_attach(process: str | int) -> Any:
    """Attach to a process by PID (int) or executable name (e.g. 'game.exe').

    Required before any scan / read / write. Returns pid, name and whether the
    target is 64-bit. If this fails, Cheat Engine may need to run as
    administrator to open the target.
    """
    return await _call("process_attach", process=process)


@mcp.tool()
async def process_detach() -> Any:
    """Detach the debugger and clear scan state.

    Note: Cheat Engine's Lua API has no way to close the process handle, so the
    target stays selected in CE until you attach to something else.
    """
    return await _call("process_detach")


@mcp.tool()
async def process_current() -> Any:
    """Report which process is currently attached, if any, and whether the
    debugger is active on it."""
    return await _call("process_current")


@mcp.tool()
async def process_modules(filter: str | None = None) -> Any:
    """List loaded modules (name, base address, size, path). Optional ``filter``.

    Module base addresses are the anchor for stable 'module+offset' pointers.
    """
    return await _call("process_modules", filter=filter)


@mcp.tool()
async def process_regions(
    writable: bool = False,
    executable: bool | None = None,
) -> Any:
    """Enumerate committed memory regions with decoded protection flags.

    ``writable=True`` keeps only writable regions; ``executable=False`` drops
    executable ones. Returns total size, so you can see how much memory a scan
    over the same filter would have to cover.
    """
    return await _call("process_regions", writable=writable, executable=executable)


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
    ``type`` is one of: byte, 2byte/word, 4byte/int, 8byte/qword, float, double,
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
    Each entry reports its own value or error, so one bad address does not
    fail the batch.
    """
    return await _call("memory_read_batch", reads=reads)


@mcp.tool()
async def memory_write(
    address: str,
    value: Any,
    type: str = "4byte",
    wide: bool = False,
) -> Any:
    """Write a value to memory and verify it by reading back.

    Returns ``previous``, ``readback`` and ``verified``. If ``verified`` is
    false the game is probably rewriting the address every frame — freeze it
    with table_add + table_freeze instead.

    ``type`` is one of: byte, 2byte/word, 4byte/int, 8byte/qword, float, double,
    string, aob. For aob, pass value as a hex string like 'AA BB CC'.
    """
    return await _call("memory_write", address=address, value=value, type=type, wide=wide)


@mcp.tool()
async def memory_dump(address: str, size: int = 256) -> Any:
    """Hex-dump a region of memory (16 bytes/row, hex + ASCII). Max 64 KiB."""
    return await _call("memory_dump", address=address, size=size)


@mcp.tool()
async def memory_alloc(size: int = 4096, near: str | None = None) -> Any:
    """Allocate executable memory in the target (for code caves). Optionally
    ``near`` an address so 32-bit relative jumps stay in range."""
    return await _call("memory_alloc", size=size, near=near)


@mcp.tool()
async def memory_free(address: str) -> Any:
    """Free memory previously allocated with ``memory_alloc``."""
    return await _call("memory_free", address=address)


# ─────────────────────────────────────────────────────────────────────────────
# Scanning
# ─────────────────────────────────────────────────────────────────────────────
@mcp.tool()
async def scan_estimate(
    value_type: str = "4byte",
    protection: str = "+W-X-C",
    alignment: str = "auto",
) -> Any:
    """Report how much memory a scan with these settings would actually cover.

    Returns matching region count, total megabytes broken down by private /
    image / mapped memory, the number of addresses to test, and the disk an
    unknown-value snapshot would consume. Run this before a broad scan — an
    unknown-value float scan of a large 64-bit game can write many gigabytes.
    """
    return await _call(
        "scan_estimate", value_type=value_type,
        protection=protection, alignment=alignment,
    )


@mcp.tool()
async def scan_first(
    value: Any = None,
    value_type: str = "4byte",
    scan_type: str = "exact",
    value2: Any = None,
    start: str | None = None,
    stop: str | None = None,
    only_one: bool = False,
    protection: str = "+W-X-C",
    alignment: str = "auto",
    regions: str | None = None,
    wait: float = 3.0,
) -> Any:
    """Run a first scan over the attached process.

    ``scan_type``: exact, bigger, smaller, between (needs value2), or unknown.
    (changed/unchanged/increased/decreased are next-scan only.)

    ``protection`` defaults to '+W-X-C' — writable, NOT executable, excluding
    copy-on-write. ``alignment`` defaults to 'auto' (the value's size, capped at
    4), matching CE's Fast Scan; pass 'none' only if a value may be unaligned,
    as that multiplies cost. ``regions`` limits the memory class scanned:
    'private' (dynamic game state — much cheaper), 'image', 'private+image',
    'mapped', 'all', or 'default'.

    Returns as soon as the scan finishes or ``wait`` seconds elapse. If
    ``status`` is 'running', poll scan_status rather than calling again.

    With scan_type='unknown' the result is a snapshot: count 0 and
    region_scan=true is expected. Change the value in the target, then narrow
    with scan_next.
    """
    return await _call(
        "scan_first", value=value, value_type=value_type, scan_type=scan_type,
        value2=value2, start=start, stop=stop, only_one=only_one,
        protection=protection, alignment=alignment, regions=regions, wait=wait,
    )


@mcp.tool()
async def scan_next(
    value: Any = None,
    scan_type: str = "exact",
    value2: Any = None,
    compare_to: str | None = None,
    percentage: bool = False,
    wait: float = 3.0,
) -> Any:
    """Narrow the active scan.

    ``scan_type``: exact, bigger, smaller, between, changed, unchanged,
    increased, decreased, increasedby, decreasedby.

    The usual loop is: let the value change in the target, scan 'changed'; hold
    it steady, scan 'unchanged'; repeat until few results remain.

    ``compare_to`` compares against a snapshot saved with scan_save_results
    instead of the previous scan — useful for A/B state comparisons.
    """
    return await _call(
        "scan_next", value=value, scan_type=scan_type, value2=value2,
        compare_to=compare_to, percentage=percentage, wait=wait,
    )


@mcp.tool()
async def scan_status() -> Any:
    """Report the active scan: status, progress percentage, match count and
    elapsed time. Poll this while a scan reports 'running'. With no MCP scan
    active it reports Cheat Engine's own GUI scan instead."""
    return await _call("scan_status")


@mcp.tool()
async def scan_cancel(force: bool = False) -> Any:
    """Abort the running scan inside Cheat Engine.

    Use this rather than abandoning a call — a scan started here keeps running
    in CE and will block every later request until it finishes.

    The default asks the scanner to stop at its next safe point. Only pass
    ``force=True`` if a graceful stop will not take: Cheat Engine then pops a
    modal warning that later scans may misbehave and recommends restarting it.
    """
    return await _call("scan_cancel", force=force)


@mcp.tool()
async def scan_results(limit: int = 100, offset: int = 0) -> Any:
    """Page through the current scan's matches (address + value). Max 1000/call.

    Reports ``source``: 'mcp' for a scan started here, 'gui' when reading the
    scan you ran by hand in Cheat Engine's window.
    """
    return await _call("scan_results", limit=limit, offset=offset)


@mcp.tool()
async def scan_save_results(name: str) -> Any:
    """Save the current scan results under ``name`` so a later scan_next can
    compare against them with ``compare_to``. Handy for isolating a value that
    differs between two game states."""
    return await _call("scan_save_results", name=name)


@mcp.tool()
async def scan_reset(force: bool = False) -> Any:
    """Discard the active scan and free its result file.

    A scan that is still running is asked to stop first, gracefully. Finished
    scans are simply released — they are never terminated, which is what makes
    Cheat Engine warn about subsequent scans misbehaving.
    """
    return await _call("scan_reset", force=force)


@mcp.tool()
async def scan_aob(pattern: str, protection: str = "+X-C") -> Any:
    """Array-of-bytes pattern scan. ``pattern`` like 'DE AD ?? EF' (?? = wildcard).

    Defaults to executable memory, since AOB scans usually target code to hook.
    """
    return await _call("scan_aob", pattern=pattern, protection=protection)


# ─────────────────────────────────────────────────────────────────────────────
# Cheat table
# ─────────────────────────────────────────────────────────────────────────────
@mcp.tool()
async def table_list() -> Any:
    """List entries in the cheat table (id, description, address, value, active)."""
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
    return await _call(
        "table_add", address=address, description=description, type=type, value=value
    )


@mcp.tool()
async def table_remove(id: int) -> Any:
    """Remove a cheat-table entry by id."""
    return await _call("table_remove", id=id)


@mcp.tool()
async def table_set_value(id: int, value: Any) -> Any:
    """Set a cheat-table entry's value (writes it to the target) and read back."""
    return await _call("table_set_value", id=id, value=value)


@mcp.tool()
async def table_freeze(id: int, frozen: bool = True) -> Any:
    """Freeze (or unfreeze) an entry so its value is held constant. This is the
    reliable way to hold a value the game rewrites every frame."""
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
    """Resolve a multi-level pointer chain and show every step.

    Reads the pointer at ``base``, adds offsets[0], reads again, and so on.
    On failure it reports which level broke, so you can tell a stale base from
    a wrong offset. Use this to verify a 'module+offset -> [+off] -> [+off]'
    path before adding it to the cheat table.
    """
    return await _call("pointer_resolve", base=base, offsets=offsets or [])


# ─────────────────────────────────────────────────────────────────────────────
# Code: disassemble / assemble / auto assembler
# ─────────────────────────────────────────────────────────────────────────────
@mcp.tool()
async def disassemble(address: str, count: int = 16) -> Any:
    """Disassemble ``count`` instructions from ``address``, with the raw bytes
    of each instruction split out from the opcode text."""
    return await _call("disassemble", address=address, count=count)


@mcp.tool()
async def assemble(code: str, address: str | None = None) -> Any:
    """Assemble a single instruction (e.g. 'mov eax,1') to bytes. ``address``
    provides context for relative operands."""
    return await _call("assemble", code=code, address=address)


@mcp.tool()
async def auto_assemble(script: str, enable: bool = True) -> Any:
    """Run a Cheat Engine Auto Assembler script — the core of code-injection
    cheats (godmode, infinite ammo, etc.). The script is syntax-checked first.

    Pass ``enable=False`` to run the script's [DISABLE] section and revert.
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
async def find_what_writes(address: str, size: int = 4, duration: int = 10) -> Any:
    """Find the instructions that WRITE to ``address`` — the classic way to
    locate the code that changes a value, and from there its base pointer.

    Sets a hardware write breakpoint and collects hits in the background,
    returning a ``job_id`` immediately. Trigger the value in the target, then
    read the hits with job_status. Each hit records the instruction, how many
    times it fired, and a register snapshot. ``size`` must be 1, 2, 4 or 8.
    """
    return await _call("find_what_writes", address=address, size=size, duration=duration)


@mcp.tool()
async def find_what_accesses(address: str, size: int = 4, duration: int = 10) -> Any:
    """Find instructions that READ OR WRITE ``address``, as a background job.

    Same mechanics as find_what_writes; useful for finding a base instruction
    for pointer/structure work. Poll the returned ``job_id`` with job_status.
    """
    return await _call("find_what_accesses", address=address, size=size, duration=duration)


@mcp.tool()
async def breakpoint(
    address: str,
    remove: bool = False,
    size: int = 1,
    trigger: str = "execute",
) -> Any:
    """Set (or with ``remove=True`` clear) a breakpoint at ``address``.
    ``trigger``: execute, write or access."""
    return await _call(
        "breakpoint", address=address, remove=remove, size=size, trigger=trigger
    )


@mcp.tool()
async def breakpoint_list() -> Any:
    """List the addresses that currently have breakpoints set."""
    return await _call("breakpoint_list")


# ─────────────────────────────────────────────────────────────────────────────
# Jobs
# ─────────────────────────────────────────────────────────────────────────────
@mcp.tool()
async def job_status(job_id: int, limit: int = 50) -> Any:
    """Get a background job's status and collected results (e.g. the
    instructions a find_what_writes trace has captured so far)."""
    return await _call("job_status", job_id=job_id, limit=limit)


@mcp.tool()
async def job_list() -> Any:
    """List background jobs with their kind, status and result count."""
    return await _call("job_list")


@mcp.tool()
async def job_cancel(job_id: int) -> Any:
    """Stop a background job early and return whatever it collected. This also
    removes any breakpoint the job installed."""
    return await _call("job_cancel", job_id=job_id)


# ─────────────────────────────────────────────────────────────────────────────
# Mono / Unity
# ─────────────────────────────────────────────────────────────────────────────
@mcp.tool()
async def mono_init() -> Any:
    """Initialise Cheat Engine's Mono data collector (for Unity/Mono games).
    Call once after attaching, before ``mono_classes``."""
    return await _call("mono_init")


@mcp.tool()
async def mono_classes(filter: str | None = None, limit: int = 500) -> Any:
    """Enumerate Mono/Unity classes (namespace, name, class pointer). Optional
    substring ``filter`` matches namespace or name. Requires ``mono_init``."""
    return await _call("mono_classes", filter=filter, limit=limit)


# ─────────────────────────────────────────────────────────────────────────────
# Misc
# ─────────────────────────────────────────────────────────────────────────────
@mcp.tool()
async def speedhack(speed: float) -> Any:
    """Set the speedhack multiplier (1.0 = normal, 2.0 = double, 0.5 = half).
    Affects the game's perception of time."""
    return await _call("speedhack", speed=speed)


@mcp.tool()
async def lua_execute(code: str) -> Any:
    """Escape hatch: run arbitrary Lua inside Cheat Engine, capturing print
    output and the return value. Use when no dedicated tool covers what you
    need — and prefer a dedicated tool when one exists, since this bypasses
    the argument validation the others perform."""
    return await _call("lua_execute", code=code)


def main() -> None:
    """Console entry point — runs the MCP server over stdio."""
    log.info("ce-mcp %s starting (stdio)", __version__)
    mcp.run()


if __name__ == "__main__":
    main()
