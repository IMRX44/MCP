"""File-based IPC client for the Cheat Engine Lua bridge.

Instead of TCP sockets (which require LuaSocket), the bridge and this client
communicate through a pair of temp files:

  %TEMP%\\cemcp_req.json   — Python writes the request, CE reads & deletes it
  %TEMP%\\cemcp_res.json   — CE writes the response, Python reads & deletes it

CE polls for the request file every 8 ms. Round-trip latency is typically
10–30 ms — imperceptible for interactive use.
"""

from __future__ import annotations

import asyncio
import json
import os
import tempfile
import time
from pathlib import Path
from typing import Any


class BridgeError(RuntimeError):
    """Raised when the bridge reports ok=false or times out."""


class CheatEngineClient:
    def __init__(
        self,
        temp_dir: str | None = None,
        timeout: float | None = None,
    ) -> None:
        td = temp_dir or os.getenv("CE_MCP_TEMP") or tempfile.gettempdir()
        self._req = Path(td) / "cemcp_req.json"
        self._res = Path(td) / "cemcp_res.json"
        self.timeout = timeout or float(os.getenv("CE_MCP_TIMEOUT", "30"))

    async def call(self, cmd: str, **params: Any) -> Any:
        """Send a command to the CE bridge and return the data.

        Raises :class:`BridgeError` on timeout or an ``ok: false`` response.
        """
        body = {k: v for k, v in params.items() if v is not None}
        request = json.dumps({"cmd": cmd, "params": body}, ensure_ascii=False)

        # Clean up any stale files from a previous crashed run.
        self._req.unlink(missing_ok=True)
        self._res.unlink(missing_ok=True)

        # Write the request atomically via a temp file in the same directory
        # so CE's os.remove(req_path) doesn't race with our write.
        tmp = self._req.with_suffix(".tmp")
        tmp.write_text(request, encoding="utf-8")
        tmp.rename(self._req)

        # Poll for the response file.
        deadline = time.monotonic() + self.timeout
        while time.monotonic() < deadline:
            if self._res.exists():
                try:
                    raw = self._res.read_text(encoding="utf-8")
                    self._res.unlink(missing_ok=True)
                except OSError:
                    await asyncio.sleep(0.01)
                    continue
                try:
                    payload = json.loads(raw)
                except json.JSONDecodeError as exc:
                    raise BridgeError(f"CE bridge returned invalid JSON: {raw[:200]}") from exc
                if not isinstance(payload, dict) or not payload.get("ok", False):
                    msg = (
                        payload.get("error", "unknown error")
                        if isinstance(payload, dict)
                        else str(payload)
                    )
                    raise BridgeError(msg)
                return payload.get("data")
            await asyncio.sleep(0.01)

        # Timed out — clean up the request so CE doesn't process it late.
        self._req.unlink(missing_ok=True)
        raise BridgeError(
            f"Timed out waiting for CE bridge response after {self.timeout}s. "
            "Is Cheat Engine open with ce_mcp_bridge.lua executing? "
            "You should see '[CE-MCP] bridge ready' in the CE output panel."
        )

    async def ping(self) -> Any:
        return await self.call("ping")

    async def aclose(self) -> None:
        pass  # no persistent connection to close
