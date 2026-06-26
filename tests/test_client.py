"""Tests for ce-mcp — run without Cheat Engine."""
from __future__ import annotations

import asyncio
import os
import json
import tempfile
from pathlib import Path

import pytest
from ce_mcp import server
from ce_mcp.client import BridgeError, CheatEngineClient


def test_all_tools_registered() -> None:
    tools = asyncio.run(server.mcp.list_tools())
    names = {t.name for t in tools}
    for expected in {
        "process_attach", "memory_read", "memory_write",
        "scan_first", "scan_next", "scan_aob",
        "table_add", "table_freeze", "pointer_resolve",
        "auto_assemble", "find_what_writes", "mono_classes", "speedhack",
    }:
        assert expected in names, f"missing tool: {expected}"
    assert len(names) >= 40


@pytest.mark.asyncio
async def test_timeout_raises_bridge_error(tmp_path: Path) -> None:
    c = CheatEngineClient(temp_dir=str(tmp_path), timeout=0.1)
    with pytest.raises(BridgeError) as exc:
        await c.call("ping")
    assert "timed out" in str(exc.value).lower()


@pytest.mark.asyncio
async def test_file_roundtrip(tmp_path: Path) -> None:
    """Simulate CE writing a response and verify the client reads it."""
    c = CheatEngineClient(temp_dir=str(tmp_path), timeout=2.0)
    res_path = tmp_path / "cemcp_res.json"

    async def fake_ce():
        # wait until req appears, then write response
        req = tmp_path / "cemcp_req.json"
        for _ in range(200):
            await asyncio.sleep(0.01)
            if req.exists():
                req.unlink(missing_ok=True)
                res_path.write_text(json.dumps({"ok": True, "data": {"pong": True}}))
                return

    asyncio.create_task(fake_ce())
    result = await c.call("ping")
    assert result == {"pong": True}


@pytest.mark.asyncio
async def test_tool_returns_error_dict_when_bridge_down(tmp_path: Path) -> None:
    server._client = CheatEngineClient(temp_dir=str(tmp_path), timeout=0.1)
    result = await server.ce_status()
    assert isinstance(result, dict) and "error" in result
    server._client = None
