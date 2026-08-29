"""Logging for the ce-mcp server.

An MCP stdio server owns stdout — the protocol lives there. Anything written to
stdout that is not a JSON-RPC frame corrupts the session, so every log record
goes to stderr and, optionally, a rotating file.

Environment:
  CE_MCP_LOG_LEVEL   debug | info | warning | error   (default: info)
  CE_MCP_LOG_FILE    path, or "0" to disable file logging
                     (default: %TEMP%/cemcp_client.log)
  CE_MCP_LOG_STDERR  "0" to silence stderr output
"""

from __future__ import annotations

import logging
import logging.handlers
import os
import sys
import tempfile
from pathlib import Path

LOGGER_NAME = "ce_mcp"
_configured = False


def default_log_path() -> Path:
    return Path(os.getenv("CE_MCP_TEMP") or tempfile.gettempdir()) / "cemcp_client.log"


def setup_logging() -> logging.Logger:
    """Configure and return the ce-mcp logger. Safe to call repeatedly."""
    global _configured
    log = logging.getLogger(LOGGER_NAME)
    if _configured:
        return log

    level_name = (os.getenv("CE_MCP_LOG_LEVEL") or "info").upper()
    level = getattr(logging, level_name, logging.INFO)
    log.setLevel(level)
    log.propagate = False

    fmt = logging.Formatter(
        "%(asctime)s %(levelname)-7s [ce-mcp] %(message)s",
        datefmt="%H:%M:%S",
    )

    if os.getenv("CE_MCP_LOG_STDERR") != "0":
        stream = logging.StreamHandler(sys.stderr)
        stream.setFormatter(fmt)
        log.addHandler(stream)

    file_setting = os.getenv("CE_MCP_LOG_FILE")
    if file_setting != "0":
        path = Path(file_setting) if file_setting else default_log_path()
        try:
            path.parent.mkdir(parents=True, exist_ok=True)
            rotating = logging.handlers.RotatingFileHandler(
                path, maxBytes=4_000_000, backupCount=2, encoding="utf-8"
            )
            rotating.setFormatter(fmt)
            log.addHandler(rotating)
        except OSError as exc:  # a read-only temp dir must not kill the server
            log.warning("file logging disabled (%s): %s", path, exc)

    if not log.handlers:
        log.addHandler(logging.NullHandler())

    _configured = True
    log.debug("logging initialised at %s", level_name)
    return log


def get_logger() -> logging.Logger:
    return setup_logging()
