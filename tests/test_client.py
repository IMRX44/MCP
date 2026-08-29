"""Tests for the ce-mcp Python side — no Cheat Engine required.

A ``FakeBridge`` stands in for the Lua side: it watches the request file and
writes responses, so the real IPC path (atomic write, id correlation, stale
response handling, timeouts) is exercised end to end.
"""

from __future__ import annotations

import asyncio
import json
from pathlib import Path
from typing import Any

import pytest

from ce_mcp import server
from ce_mcp.client import COMMAND_TIMEOUTS, BridgeError, CheatEngineClient


# ─────────────────────────────────────────────────────────────────────────────
# Fake bridge
# ─────────────────────────────────────────────────────────────────────────────
class FakeBridge:
    """Minimal stand-in for the in-CE Lua bridge."""

    def __init__(self, tmp: Path) -> None:
        self.req = tmp / "cemcp_req.json"
        self.res = tmp / "cemcp_res.json"
        self.seen: list[dict[str, Any]] = []
        self._task: asyncio.Task | None = None
        self.echo_id = True
        self.delay = 0.0
        self.handler = self._default_handler

    @staticmethod
    def _default_handler(req: dict[str, Any]) -> dict[str, Any]:
        return {"ok": True, "data": {"cmd": req.get("cmd"), "params": req.get("params")}}

    async def _serve(self) -> None:
        while True:
            if self.req.exists():
                try:
                    raw = self.req.read_text(encoding="utf-8")
                    self.req.unlink(missing_ok=True)
                except OSError:
                    await asyncio.sleep(0.005)
                    continue
                req = json.loads(raw)
                self.seen.append(req)
                if self.delay:
                    await asyncio.sleep(self.delay)
                payload = self.handler(req)
                if self.echo_id and "id" not in payload:
                    payload["id"] = req.get("id")
                self.res.write_text(json.dumps(payload), encoding="utf-8")
            await asyncio.sleep(0.005)

    def start(self) -> None:
        self._task = asyncio.create_task(self._serve())

    async def stop(self) -> None:
        if self._task:
            self._task.cancel()
            try:
                await self._task
            except asyncio.CancelledError:
                pass


@pytest.fixture
async def bridge(tmp_path: Path):
    b = FakeBridge(tmp_path)
    b.start()
    yield b
    await b.stop()


@pytest.fixture
def client(tmp_path: Path) -> CheatEngineClient:
    return CheatEngineClient(temp_dir=str(tmp_path), timeout=3.0)


# ─────────────────────────────────────────────────────────────────────────────
# Tool surface
# ─────────────────────────────────────────────────────────────────────────────
def test_all_tools_registered() -> None:
    tools = asyncio.run(server.mcp.list_tools())
    names = {t.name for t in tools}
    for expected in {
        "process_attach", "memory_read", "memory_write",
        "scan_first", "scan_next", "scan_aob",
        "table_add", "table_freeze", "pointer_resolve",
        "auto_assemble", "find_what_writes", "mono_classes", "speedhack",
        # v2 additions
        "ce_diagnostics", "ce_debug_log", "ce_capabilities",
        "scan_status", "scan_cancel", "scan_estimate", "scan_save_results",
        "job_status", "job_list", "job_cancel",
    }:
        assert expected in names, f"missing tool: {expected}"
    assert len(names) >= 50


def test_every_tool_is_documented() -> None:
    tools = asyncio.run(server.mcp.list_tools())
    undocumented = [t.name for t in tools if not (t.description or "").strip()]
    assert not undocumented, f"tools without a description: {undocumented}"


def test_pointer_scan_tool_was_removed() -> None:
    """CE has no Lua pointer-scan API; exposing the tool only misleads."""
    names = {t.name for t in asyncio.run(server.mcp.list_tools())}
    assert "pointer_scan" not in names


# ─────────────────────────────────────────────────────────────────────────────
# Round trip
# ─────────────────────────────────────────────────────────────────────────────
@pytest.mark.asyncio
async def test_roundtrip(bridge: FakeBridge, client: CheatEngineClient) -> None:
    result = await client.call("ping")
    assert result["cmd"] == "ping"
    assert bridge.seen[0]["cmd"] == "ping"


@pytest.mark.asyncio
async def test_request_carries_a_unique_id(bridge: FakeBridge, client: CheatEngineClient) -> None:
    await client.call("ping")
    await client.call("ping")
    ids = [r["id"] for r in bridge.seen]
    assert len(ids) == 2 and ids[0] != ids[1]
    assert all(isinstance(i, str) and i for i in ids)


@pytest.mark.asyncio
async def test_none_params_are_dropped(bridge: FakeBridge, client: CheatEngineClient) -> None:
    await client.call("process_list", filter=None, other="keep")
    params = bridge.seen[0]["params"]
    assert "filter" not in params
    assert params["other"] == "keep"


@pytest.mark.asyncio
async def test_error_response_raises_with_hint(bridge: FakeBridge, client: CheatEngineClient) -> None:
    bridge.handler = lambda req: {"ok": False, "error": "no process attached — call process_attach first"}
    with pytest.raises(BridgeError) as exc:
        await client.call("scan_first")
    assert exc.value.command == "scan_first"
    assert "process_attach" in (exc.value.hint or "")


@pytest.mark.asyncio
async def test_invalid_json_response_is_reported(tmp_path: Path, client: CheatEngineClient) -> None:
    async def write_garbage() -> None:
        req = tmp_path / "cemcp_req.json"
        for _ in range(300):
            await asyncio.sleep(0.005)
            if req.exists():
                req.unlink(missing_ok=True)
                (tmp_path / "cemcp_res.json").write_text("{not json", encoding="utf-8")
                return

    task = asyncio.create_task(write_garbage())
    with pytest.raises(BridgeError) as exc:
        await client.call("ping")
    assert "invalid JSON" in str(exc.value)
    await task


# ─────────────────────────────────────────────────────────────────────────────
# The bug this protocol version exists to fix
# ─────────────────────────────────────────────────────────────────────────────
@pytest.mark.asyncio
async def test_stale_response_is_not_mistaken_for_the_answer(
    tmp_path: Path, bridge: FakeBridge, client: CheatEngineClient
) -> None:
    """A leftover response from an abandoned call must never be returned."""
    (tmp_path / "cemcp_res.json").write_text(
        json.dumps({"id": "an-old-call", "ok": True, "data": {"stale": True}}),
        encoding="utf-8",
    )
    result = await client.call("ping")
    assert result != {"stale": True}
    assert result["cmd"] == "ping"
    assert client.stats.stale_responses >= 1


@pytest.mark.asyncio
async def test_mismatched_id_is_skipped_and_waiting_continues(
    tmp_path: Path, client: CheatEngineClient
) -> None:
    async def answer_wrong_then_right() -> None:
        req = tmp_path / "cemcp_req.json"
        res = tmp_path / "cemcp_res.json"
        for _ in range(300):
            await asyncio.sleep(0.005)
            if req.exists():
                real_id = json.loads(req.read_text())["id"]
                req.unlink(missing_ok=True)
                res.write_text(json.dumps({"id": "wrong", "ok": True, "data": "no"}))
                await asyncio.sleep(0.05)
                res.write_text(json.dumps({"id": real_id, "ok": True, "data": "yes"}))
                return

    task = asyncio.create_task(answer_wrong_then_right())
    assert await client.call("ping") == "yes"
    await task


@pytest.mark.asyncio
async def test_calls_are_serialised(bridge: FakeBridge, client: CheatEngineClient) -> None:
    """Concurrent tool calls share one file pair, so they must not interleave."""
    bridge.delay = 0.02
    results = await asyncio.gather(*[client.call("ping", n=i) for i in range(5)])
    assert len(results) == 5
    assert len(bridge.seen) == 5
    assert len({r["id"] for r in bridge.seen}) == 5


# ─────────────────────────────────────────────────────────────────────────────
# Timeouts
# ─────────────────────────────────────────────────────────────────────────────
@pytest.mark.asyncio
async def test_timeout_raises_with_actionable_hint(tmp_path: Path) -> None:
    c = CheatEngineClient(temp_dir=str(tmp_path), timeout=0.15)
    with pytest.raises(BridgeError) as exc:
        await c.call("some_slow_command")
    assert "did not answer" in str(exc.value)
    assert "bridge ready" in (exc.value.hint or "")
    assert c.stats.timeouts == 1


@pytest.mark.asyncio
async def test_timeout_removes_the_request_file(tmp_path: Path) -> None:
    c = CheatEngineClient(temp_dir=str(tmp_path), timeout=0.15)
    with pytest.raises(BridgeError):
        await c.call("ping")
    assert not (tmp_path / "cemcp_req.json").exists()


def test_per_command_timeouts() -> None:
    c = CheatEngineClient(temp_dir=".", timeout=300.0)
    assert c.timeout_for("ping") == COMMAND_TIMEOUTS["ping"]
    assert c.timeout_for("ping") < 30, "a ping should fail fast, not hang for minutes"
    assert c.timeout_for("scan_aob") > c.timeout_for("ping")
    assert c.timeout_for("unlisted_command") == 300.0
    assert c.timeout_for("ping", 42.0) == 42.0


def test_a_long_scan_wait_extends_the_client_timeout() -> None:
    """The client must outlast the window the bridge blocks for."""
    c = CheatEngineClient(temp_dir=".", timeout=60.0)
    assert c.timeout_for("scan_first", None, {"wait": 3.0}) == 60.0
    assert c.timeout_for("scan_first", None, {"wait": 120.0}) == 135.0
    assert c.timeout_for("scan_status", None, {"wait": 120.0}) == 135.0
    assert c.timeout_for("scan_first", 5.0, {"wait": 120.0}) == 5.0, "explicit override wins"


# ─────────────────────────────────────────────────────────────────────────────
# Stats & health
# ─────────────────────────────────────────────────────────────────────────────
@pytest.mark.asyncio
async def test_stats_track_calls_and_errors(bridge: FakeBridge, client: CheatEngineClient) -> None:
    await client.call("ping")
    bridge.handler = lambda req: {"ok": False, "error": "boom"}
    with pytest.raises(BridgeError):
        await client.call("scan_first")
    stats = client.stats.as_dict()
    assert stats["calls"] == 2
    assert stats["errors"] == 1
    assert stats["per_command"] == {"ping": 1, "scan_first": 1}
    assert "boom" in stats["last_error"]


@pytest.mark.asyncio
async def test_health_never_raises(tmp_path: Path) -> None:
    c = CheatEngineClient(temp_dir=str(tmp_path), timeout=0.15)
    health = await c.health()
    assert health["reachable"] is False
    assert "hint" in health


@pytest.mark.asyncio
async def test_health_reports_reachable(bridge: FakeBridge, client: CheatEngineClient) -> None:
    bridge.handler = lambda req: {"ok": True, "data": {"pong": True, "ce_version": 7.7}}
    health = await client.health()
    assert health["reachable"] is True
    assert health["ce_version"] == 7.7


# ─────────────────────────────────────────────────────────────────────────────
# Server-level error surfacing
# ─────────────────────────────────────────────────────────────────────────────
@pytest.mark.asyncio
async def test_tools_return_error_dicts_rather_than_raising(tmp_path: Path) -> None:
    server._client = CheatEngineClient(temp_dir=str(tmp_path), timeout=0.15)
    try:
        result = await server.ce_status()
        assert isinstance(result, dict) and result["reachable"] is False

        result = await server.memory_read(address="0x1000")
        assert isinstance(result, dict) and "error" in result
        assert "hint" in result
    finally:
        server._client = None


@pytest.mark.asyncio
async def test_diagnostics_short_circuits_when_bridge_is_down(tmp_path: Path) -> None:
    server._client = CheatEngineClient(temp_dir=str(tmp_path), timeout=0.15)
    try:
        report = await server.ce_diagnostics()
        assert report["healthy"] is False
        assert "autorun" in report["next_step"]
        # It must not have gone on to run every probe against a dead bridge.
        assert "selftest" not in report
    finally:
        server._client = None


@pytest.mark.asyncio
async def test_diagnostics_aggregates_when_bridge_is_up(
    bridge: FakeBridge, tmp_path: Path
) -> None:
    def handler(req: dict[str, Any]) -> dict[str, Any]:
        cmd = req["cmd"]
        if cmd == "ping":
            return {"ok": True, "data": {"pong": True, "ce_version": 7.7}}
        if cmd == "debug_selftest":
            return {"ok": True, "data": {"healthy": True, "summary": {"failed": 0}}}
        return {"ok": True, "data": {cmd: "ok"}}

    bridge.handler = handler
    server._client = CheatEngineClient(temp_dir=str(tmp_path), timeout=3.0)
    try:
        report = await server.ce_diagnostics(log_lines=5)
        assert report["healthy"] is True
        assert report["bridge"]["reachable"] is True
        assert "capabilities" in report and "state" in report and "log" in report
        assert report["client"]["calls"] >= 4
    finally:
        server._client = None
