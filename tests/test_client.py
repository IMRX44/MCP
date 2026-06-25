"""Tests for the CE bridge client and server wiring.

These run without Cheat Engine: they verify the transport contract (error
handling, param filtering) and that every MCP tool is registered.
"""

from __future__ import annotations

import asyncio

import pytest

from ce_mcp import server
from ce_mcp.client import BridgeError, CheatEngineClient


def test_all_tools_registered() -> None:
    tools = asyncio.run(server.mcp.list_tools())
    names = {t.name for t in tools}
    # A representative slice of each tool group must be present.
    for expected in {
        "process_attach", "memory_read", "memory_write",
        "scan_first", "scan_next", "scan_aob",
        "table_add", "table_freeze", "pointer_resolve",
        "auto_assemble", "find_what_writes", "mono_classes", "speedhack",
    }:
        assert expected in names, f"missing tool: {expected}"
    assert len(names) >= 40


@pytest.mark.asyncio
async def test_unreachable_bridge_raises_bridge_error() -> None:
    # Port chosen to be (almost certainly) closed.
    c = CheatEngineClient(port=1)
    with pytest.raises(BridgeError) as exc:
        await c.call("/ping")
    assert "bridge" in str(exc.value).lower()
    await c.aclose()


@pytest.mark.asyncio
async def test_tool_returns_error_dict_when_bridge_down() -> None:
    # _call swallows BridgeError into a {"error": ...} dict for the model.
    server._client = CheatEngineClient(port=1)
    result = await server.ce_status()
    assert isinstance(result, dict) and "error" in result
    await server._client.aclose()
    server._client = None
