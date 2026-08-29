"""Run the Lua bridge specification under Cheat Engine's own Lua 5.3.

``bridge_spec.lua`` stubs the Cheat Engine API and drives the bridge through
its real file-IPC path, so the Lua half is covered without CE running.

Skipped when Cheat Engine's lua53 DLL is not present (e.g. CI on Linux).
"""

from __future__ import annotations

import tempfile
from pathlib import Path

import pytest

from .lua_harness import Lua, LuaError, find_lua_dll

ROOT = Path(__file__).resolve().parent.parent
BRIDGE = ROOT / "lua" / "ce_mcp_bridge.lua"
SPEC = Path(__file__).resolve().parent / "bridge_spec.lua"

_DLL = find_lua_dll()
requires_lua = pytest.mark.skipif(
    _DLL is None, reason="Cheat Engine's lua53 DLL not found (set CE_MCP_LUA_DLL)"
)


@requires_lua
def test_bridge_compiles() -> None:
    with Lua(_DLL) as lua:
        lua.check_syntax(BRIDGE.read_text(encoding="utf-8"))


@requires_lua
def test_bridge_spec_passes() -> None:
    tmp = tempfile.mkdtemp(prefix="cemcp_spec_")
    prelude = f"TEST_TEMP = [[{tmp}]]\nBRIDGE_PATH = [[{BRIDGE}]]\n"
    source = prelude + SPEC.read_text(encoding="utf-8")
    with Lua(_DLL) as lua:
        try:
            lua.run(source)
        except LuaError as exc:
            pytest.fail(f"bridge_spec.lua failed: {exc}")


@requires_lua
def test_bridge_declares_current_version() -> None:
    """The Lua and Python halves must agree on the protocol version."""
    from ce_mcp import __version__
    from ce_mcp.client import PROTOCOL

    text = BRIDGE.read_text(encoding="utf-8")
    assert f'BRIDGE_VERSION  = "{__version__}"' in text
    assert f"PROTOCOL        = {PROTOCOL}" in text
