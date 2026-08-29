"""File-based IPC client for the Cheat Engine Lua bridge.

Instead of TCP sockets (which would need LuaSocket inside Cheat Engine), the
bridge and this client exchange a pair of temp files:

  %TEMP%\\cemcp_req.json   — Python writes the request, CE claims and deletes it
  %TEMP%\\cemcp_res.json   — CE writes the response, Python reads and deletes it

CE polls for the request file every 8 ms, so a round trip costs 10–30 ms.

Protocol v2 adds a per-request ``id``. The bridge echoes it back, which lets the
client throw away a stale response that a *previous*, timed-out call produced —
without that, a slow scan's answer could be handed to the next unrelated call.
"""

from __future__ import annotations

import asyncio
import json
import os
import tempfile
import time
import uuid
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, BinaryIO

from .logging_setup import get_logger

log = get_logger()

PROTOCOL = 2

#: Default per-command timeouts in seconds. Anything not listed uses
#: ``CheatEngineClient.timeout``. Scans return promptly with a "running"
#: status, so they do not need the long tail the old 600 s blanket gave them.
COMMAND_TIMEOUTS: dict[str, float] = {
    "ping": 10.0,
    "ce_version": 10.0,
    "ce_routes": 10.0,
    "debug_log": 15.0,
    "debug_state": 15.0,
    "debug_capabilities": 15.0,
    "debug_set_level": 10.0,
    "debug_selftest": 60.0,
    "process_list": 30.0,
    "process_attach": 30.0,
    "process_regions": 60.0,
    "process_modules": 30.0,
    "memory_read": 15.0,
    "memory_write": 15.0,
    "memory_read_batch": 30.0,
    "memory_dump": 30.0,
    "scan_status": 15.0,
    "scan_cancel": 30.0,
    "scan_reset": 60.0,
    "scan_results": 60.0,
    "scan_estimate": 60.0,
    "scan_aob": 300.0,
    "auto_assemble": 60.0,
    "job_status": 15.0,
    "job_list": 15.0,
}

#: Extra guidance attached to common failures, so the model can self-correct.
_HINTS: tuple[tuple[str, str], ...] = (
    ("no process attached",
     "Call process_list to find the target, then process_attach."),
    ("bridge response",
     ("Cheat Engine is not answering. Confirm CE is open and that the output "
      "panel shows '[CE-MCP] bridge ready'; if not, re-run ce_mcp_bridge.lua.")),
    ("no active scan",
     "Start one with scan_first."),
    ("still running",
     "Poll scan_status until status is 'done', or abort with scan_cancel."),
    ("unknown command",
     "Call ce_routes to list what this bridge build supports."),
    ("createPointerScan",
     ("Pointer scanning is UI-only in Cheat Engine; use pointer_resolve to "
      "verify a chain you already have.")),
)


def _hint_for(message: str) -> str | None:
    low = message.lower()
    for needle, hint in _HINTS:
        if needle.lower() in low:
            return hint
    return None


class BridgeError(RuntimeError):
    """Raised when the bridge reports ``ok: false``, times out, or misbehaves."""

    def __init__(self, message: str, *, command: str | None = None,
                 hint: str | None = None, elapsed: float | None = None) -> None:
        super().__init__(message)
        self.message = message
        self.command = command
        self.hint = hint if hint is not None else _hint_for(message)
        self.elapsed = elapsed

    def as_dict(self) -> dict[str, Any]:
        out: dict[str, Any] = {"error": self.message}
        if self.command:
            out["command"] = self.command
        if self.hint:
            out["hint"] = self.hint
        if self.elapsed is not None:
            out["elapsed_ms"] = round(self.elapsed * 1000)
        return out


@dataclass
class ClientStats:
    """Counters the ce_diagnostics tool reports back to the model."""

    calls: int = 0
    errors: int = 0
    timeouts: int = 0
    stale_responses: int = 0
    total_seconds: float = 0.0
    last_command: str | None = None
    last_error: str | None = None
    per_command: dict[str, int] = field(default_factory=dict)

    def as_dict(self) -> dict[str, Any]:
        return {
            "calls": self.calls,
            "errors": self.errors,
            "timeouts": self.timeouts,
            "stale_responses": self.stale_responses,
            "avg_ms": round(self.total_seconds / self.calls * 1000) if self.calls else 0,
            "last_command": self.last_command,
            "last_error": self.last_error,
            "per_command": dict(sorted(self.per_command.items())),
        }


class CheatEngineClient:
    def __init__(
        self,
        temp_dir: str | None = None,
        timeout: float | None = None,
    ) -> None:
        td = temp_dir or os.getenv("CE_MCP_TEMP") or tempfile.gettempdir()
        self.temp_dir = Path(td)
        self._req = self.temp_dir / "cemcp_req.json"
        self._res = self.temp_dir / "cemcp_res.json"
        self._ipc_lock_path = self.temp_dir / "cemcp_ipc.lock"
        self.timeout = timeout or float(os.getenv("CE_MCP_TIMEOUT", "300"))
        self.poll_interval = float(os.getenv("CE_MCP_POLL", "0.01"))
        self.stats = ClientStats()
        # The IPC uses one fixed file pair, so calls must not interleave.
        self._lock = asyncio.Lock()
        log.info("client ready: temp=%s default_timeout=%.0fs", self.temp_dir, self.timeout)

    # ── internals ────────────────────────────────────────────────────────
    def timeout_for(
        self,
        cmd: str,
        override: float | None = None,
        params: dict[str, Any] | None = None,
    ) -> float:
        if override is not None:
            return float(override)
        budget = COMMAND_TIMEOUTS.get(cmd, self.timeout)
        # A scan blocks in CE for up to its own `wait` window, so the client
        # must outlast it or it would time out on a call that is working fine.
        wait = (params or {}).get("wait")
        if isinstance(wait, (int, float)):
            budget = max(budget, float(wait) + 15.0)
        return budget

    def _write_request(self, payload: str) -> None:
        # Write to a sibling file and rename, so CE never reads a partial request.
        tmp = self._req.with_suffix(".tmp")
        tmp.write_text(payload, encoding="utf-8")
        os.replace(tmp, self._req)

    def _drain_stale(self) -> None:
        """Discard a leftover response from a previous, abandoned call."""
        if self._res.exists():
            try:
                self._res.unlink()
                self.stats.stale_responses += 1
                log.warning("discarded a stale response file left by an earlier call")
            except OSError:
                pass

    def _try_ipc_lock(self) -> BinaryIO | None:
        """Try to lock the shared file channel across OS processes.

        Request IDs stop a stale reply being returned as fresh data, but they
        cannot stop two MCP server processes from deleting each other's fixed
        request/response files.  A one-byte advisory lock serialises ownership
        of that channel and is automatically released if a process exits.
        """
        self.temp_dir.mkdir(parents=True, exist_ok=True)
        handle = self._ipc_lock_path.open("a+b")
        handle.seek(0, os.SEEK_END)
        if handle.tell() == 0:
            handle.write(b"\0")
            handle.flush()
        handle.seek(0)
        try:
            if os.name == "nt":
                import msvcrt

                msvcrt.locking(handle.fileno(), msvcrt.LK_NBLCK, 1)
            else:  # pragma: no cover - the project runs on Windows
                import fcntl

                fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except (OSError, BlockingIOError):
            handle.close()
            return None
        return handle

    @staticmethod
    def _release_ipc_lock(handle: BinaryIO) -> None:
        handle.seek(0)
        try:
            if os.name == "nt":
                import msvcrt

                msvcrt.locking(handle.fileno(), msvcrt.LK_UNLCK, 1)
            else:  # pragma: no cover - the project runs on Windows
                import fcntl

                fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
        finally:
            handle.close()

    @asynccontextmanager
    async def _own_ipc_channel(self, timeout: float) -> AsyncIterator[None]:
        deadline = time.monotonic() + timeout
        handle: BinaryIO | None = None
        while handle is None and time.monotonic() < deadline:
            try:
                handle = self._try_ipc_lock()
            except OSError as exc:
                raise BridgeError(
                    f"cannot open the IPC lock file {self._ipc_lock_path}: {exc}",
                    hint="Check that CE_MCP_TEMP points at a writable directory.",
                ) from exc
            if handle is None:
                await asyncio.sleep(self.poll_interval)

        if handle is None:
            raise BridgeError(
                f"another CE-MCP process held the shared IPC channel for {timeout:.0f}s",
                hint=(
                    "Let the other tool call finish, or configure both MCP clients "
                    "to use the same CE_MCP_TEMP so calls can be serialised safely."
                ),
            )
        try:
            yield
        finally:
            self._release_ipc_lock(handle)

    # ── public API ───────────────────────────────────────────────────────
    async def call(self, cmd: str, *, timeout: float | None = None, **params: Any) -> Any:
        """Send a command to the CE bridge and return its ``data`` payload.

        Raises :class:`BridgeError` on timeout or an ``ok: false`` response.
        """
        budget = self.timeout_for(cmd, timeout, params)
        async with self._lock, self._own_ipc_channel(budget):
            return await self._call_locked(cmd, budget, params)

    async def _call_locked(self, cmd: str, timeout: float | None,
                           params: dict[str, Any]) -> Any:
        body = {k: v for k, v in params.items() if v is not None}
        req_id = uuid.uuid4().hex[:12]
        request = json.dumps(
            {"id": req_id, "cmd": cmd, "params": body, "protocol": PROTOCOL},
            ensure_ascii=False,
        )
        budget = float(timeout) if timeout is not None else self.timeout_for(cmd, params=body)

        self.stats.calls += 1
        self.stats.last_command = cmd
        self.stats.per_command[cmd] = self.stats.per_command.get(cmd, 0) + 1
        log.debug("-> %s id=%s params=%s timeout=%.0fs", cmd, req_id,
                  _short(json.dumps(body, ensure_ascii=False)), budget)

        self._drain_stale()
        self._req.unlink(missing_ok=True)

        started = time.monotonic()
        try:
            self._write_request(request)
        except OSError as exc:
            self.stats.errors += 1
            raise BridgeError(
                f"cannot write the request file {self._req}: {exc}",
                command=cmd,
                hint="Check that CE_MCP_TEMP points at a writable directory.",
            ) from exc

        deadline = started + budget
        while time.monotonic() < deadline:
            if self._res.exists():
                payload = self._read_response(cmd)
                if payload is None:
                    await asyncio.sleep(self.poll_interval)
                    continue

                got_id = payload.get("id")
                if got_id is None:
                    self.stats.errors += 1
                    raise BridgeError(
                        "bridge response has no request id; protocol 2 is required",
                        command=cmd,
                        hint=(
                            "Update and reload ce_mcp_bridge.lua. Older bridges cannot "
                            "safely correlate a late response with the call that made it."
                        ),
                    )
                if got_id != req_id:
                    # A late answer to a call we already gave up on.
                    self.stats.stale_responses += 1
                    log.warning("ignoring response for id=%s while waiting for %s",
                                got_id, req_id)
                    continue
                if payload.get("protocol") != PROTOCOL:
                    self.stats.errors += 1
                    raise BridgeError(
                        f"bridge protocol mismatch: expected {PROTOCOL}, got "
                        f"{payload.get('protocol')!r}",
                        command=cmd,
                        hint="Update and reload ce_mcp_bridge.lua so it uses protocol 2.",
                    )

                elapsed = time.monotonic() - started
                self.stats.total_seconds += elapsed

                if not payload.get("ok", False):
                    msg = payload.get("error") or "unknown bridge error"
                    self.stats.errors += 1
                    self.stats.last_error = f"{cmd}: {msg}"
                    log.warning("<- %s failed in %.0fms: %s", cmd, elapsed * 1000, msg)
                    raise BridgeError(msg, command=cmd, elapsed=elapsed)

                log.debug("<- %s ok in %.0fms", cmd, elapsed * 1000)
                return payload.get("data")

            await asyncio.sleep(self.poll_interval)

        # Timed out. Remove the request so CE does not run it late, and warn
        # that a response may still land (the next call will discard it).
        elapsed = time.monotonic() - started
        self._req.unlink(missing_ok=True)
        self.stats.errors += 1
        self.stats.timeouts += 1
        self.stats.last_error = f"{cmd}: timeout after {budget:.0f}s"
        log.error("<- %s TIMEOUT after %.0fs", cmd, elapsed)
        raise BridgeError(
            f"the Cheat Engine bridge did not answer '{cmd}' within {budget:.0f}s",
            command=cmd,
            elapsed=elapsed,
            hint=(
                "Cheat Engine is either not running the bridge, or is busy in a "
                "long operation started from its own window. Check that the CE "
                "output panel shows '[CE-MCP] bridge ready'. If a scan is "
                "running there, press 'New Scan' in CE to stop it. Raise the "
                "limit with CE_MCP_TIMEOUT if the operation is genuinely slow."
            ),
        )

    def _read_response(self, cmd: str) -> dict[str, Any] | None:
        """Read and delete the response file. ``None`` means 'try again'."""
        try:
            raw = self._res.read_text(encoding="utf-8")
        except OSError:
            return None  # CE is still renaming it into place
        if not raw.strip():
            return None
        try:
            self._res.unlink(missing_ok=True)
        except OSError:
            pass
        try:
            payload = json.loads(raw)
        except json.JSONDecodeError as exc:
            self.stats.errors += 1
            raise BridgeError(
                f"the bridge returned invalid JSON: {_short(raw)}",
                command=cmd,
                hint="Update ce_mcp_bridge.lua — this build may predate protocol 2.",
            ) from exc
        if not isinstance(payload, dict):
            raise BridgeError(
                f"the bridge returned a {type(payload).__name__}, expected an object",
                command=cmd,
            )
        return payload

    async def ping(self) -> Any:
        return await self.call("ping")

    async def health(self) -> dict[str, Any]:
        """Best-effort reachability probe that never raises."""
        try:
            data = await self.call("ping", timeout=5.0)
            return {"reachable": True, **(data if isinstance(data, dict) else {})}
        except BridgeError as exc:
            return {"reachable": False, **exc.as_dict()}

    async def aclose(self) -> None:
        pass  # no persistent connection to close


def _short(s: str, limit: int = 300) -> str:
    return s if len(s) <= limit else f"{s[:limit]}...(+{len(s) - limit})"
