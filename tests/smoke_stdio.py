"""End-to-end smoke test: launch the real MCP server and talk to it over stdio.

Verifies the server starts, speaks MCP, exposes its tools, and that every tool
either works or returns a readable error -- without needing Cheat Engine.

    python tests/smoke_stdio.py            # bridge may be down; errors expected
    python tests/smoke_stdio.py --live     # requires CE with the bridge loaded
"""

from __future__ import annotations

import asyncio
import os
import sys
from pathlib import Path

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "src"

# Tools that are safe to call blind: they only read, and need no arguments.
READ_ONLY_PROBES: list[tuple[str, dict]] = [
    ("ce_status", {}),
    ("ce_version", {}),
    ("ce_routes", {}),
    ("ce_capabilities", {}),
    ("ce_debug_state", {}),
    ("ce_debug_log", {"limit": 5}),
    ("ce_diagnostics", {"include_log": False}),
    ("process_current", {}),
    ("process_list", {"filter": "explorer"}),
    ("scan_status", {}),
    ("job_list", {}),
    ("table_list", {}),
]


def _text(result) -> str:
    parts = []
    for c in result.content:
        parts.append(getattr(c, "text", "") or "")
    return " ".join(parts)


async def main(live: bool) -> int:
    env = dict(os.environ)
    env["PYTHONPATH"] = str(SRC)
    env.setdefault("CE_MCP_LOG_LEVEL", "warning")
    env.setdefault("CE_MCP_TIMEOUT", "10")

    params = StdioServerParameters(
        command=sys.executable, args=["-m", "ce_mcp"], env=env
    )

    failures = 0
    async with stdio_client(params) as (read, write):
        async with ClientSession(read, write) as session:
            init = await session.initialize()
            print(f"connected: {init.serverInfo.name} v{init.serverInfo.version}")

            tools = (await session.list_tools()).tools
            print(f"tools exposed: {len(tools)}")
            undocumented = [t.name for t in tools if not (t.description or "").strip()]
            if undocumented:
                print(f"  FAIL undocumented tools: {undocumented}")
                failures += 1

            print("\nprobing read-only tools:")
            for name, args in READ_ONLY_PROBES:
                if name not in {t.name for t in tools}:
                    print(f"  FAIL {name}: not exposed")
                    failures += 1
                    continue
                try:
                    res = await session.call_tool(name, args)
                except Exception as exc:
                    print(f"  FAIL {name}: raised {type(exc).__name__}: {exc}")
                    failures += 1
                    continue

                body = _text(res)
                if res.isError:
                    print(f"  FAIL {name}: protocol-level error {body[:160]}")
                    failures += 1
                elif '"error"' in body or "'error'" in body:
                    if live:
                        print(f"  FAIL {name}: {body[:200]}")
                        failures += 1
                    else:
                        has_hint = "hint" in body
                        mark = "ok " if has_hint else "WEAK"
                        if not has_hint:
                            failures += 1
                        print(f"  {mark} {name}: error carries hint={has_hint}")
                else:
                    print(f"  ok  {name}: {body[:120]}")

            # An unknown tool must be rejected cleanly, not crash the server.
            try:
                bad = await session.call_tool("no_such_tool", {})
                print(f"\nunknown tool handled: isError={bad.isError}")
            except Exception as exc:
                print(f"\nunknown tool raised {type(exc).__name__} (acceptable)")

            # The server must still be alive afterwards.
            again = await session.call_tool("ce_status", {})
            print(f"server alive after bad call: {not again.isError}")

    print(f"\n{'PASS' if failures == 0 else 'FAIL'} — {failures} problem(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main("--live" in sys.argv)))
