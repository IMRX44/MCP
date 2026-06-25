"""HTTP client for the Cheat Engine Lua bridge.

The bridge (``lua/ce_mcp_bridge.lua``) runs inside Cheat Engine and exposes a
tiny JSON/HTTP API on localhost. This module is the thin, typed transport the
MCP tools call into. Every bridge response has the shape::

    { "ok": true,  "data": <...> }
    { "ok": false, "error": "<message>" }
"""

from __future__ import annotations

import os
from typing import Any

import httpx


class BridgeError(RuntimeError):
    """Raised when the bridge reports ``ok: false`` or is unreachable."""


class CheatEngineClient:
    """Synchronous-feeling async client for the CE bridge."""

    def __init__(
        self,
        host: str | None = None,
        port: int | None = None,
        timeout: float | None = None,
    ) -> None:
        self.host = host or os.getenv("CE_MCP_HOST", "127.0.0.1")
        self.port = port or int(os.getenv("CE_MCP_PORT", "37712"))
        # Some operations (find-what-writes, long scans) take a while.
        self.timeout = timeout or float(os.getenv("CE_MCP_TIMEOUT", "60"))
        self._base = f"http://{self.host}:{self.port}"
        self._client = httpx.AsyncClient(timeout=self.timeout)

    @property
    def base_url(self) -> str:
        return self._base

    async def call(self, route: str, **params: Any) -> Any:
        """POST ``params`` as JSON to ``route`` and return the ``data`` field.

        Raises :class:`BridgeError` on transport failure or an ``ok: false``
        response, so MCP tool functions can let it propagate as a clean error.
        """
        url = f"{self._base}{route}"
        # Drop None values so the Lua side sees only provided params.
        body = {k: v for k, v in params.items() if v is not None}
        try:
            resp = await self._client.post(url, json=body)
        except httpx.ConnectError as exc:
            raise BridgeError(
                f"Cannot reach the Cheat Engine bridge at {self._base}. "
                "Is Cheat Engine open and ce_mcp_bridge.lua running?"
            ) from exc
        except httpx.HTTPError as exc:
            raise BridgeError(f"HTTP error talking to bridge: {exc}") from exc

        try:
            payload = resp.json()
        except ValueError as exc:
            raise BridgeError(
                f"Bridge returned non-JSON (HTTP {resp.status_code}): "
                f"{resp.text[:200]}"
            ) from exc

        if not isinstance(payload, dict) or not payload.get("ok", False):
            msg = (
                payload.get("error", "unknown error")
                if isinstance(payload, dict)
                else str(payload)
            )
            raise BridgeError(msg)
        return payload.get("data")

    async def ping(self) -> Any:
        return await self.call("/ping")

    async def aclose(self) -> None:
        await self._client.aclose()
