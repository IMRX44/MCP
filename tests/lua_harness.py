"""Run Lua files under Cheat Engine's own Lua 5.3 runtime via ctypes.

This lets the bridge's pure-Lua logic (JSON codec, address parsing, argument
validation, the dispatcher) be tested on any machine, with the Cheat Engine
API replaced by stubs -- no CE process required.
"""

from __future__ import annotations

import ctypes
import os
from pathlib import Path
from typing import Self

CE_DIRS = [
    r"C:\Program Files\Cheat Engine",
    r"C:\Program Files (x86)\Cheat Engine",
]
DLL_NAMES = ["lua53-64.dll", "lua53-32.dll"]

LUA_OK = 0
LUA_MULTRET = -1


def find_lua_dll() -> str | None:
    env = os.getenv("CE_MCP_LUA_DLL")
    if env and Path(env).exists():
        return env
    for d in CE_DIRS:
        for n in DLL_NAMES:
            p = Path(d) / n
            if p.exists():
                return str(p)
    return None


class LuaError(RuntimeError):
    pass


class Lua:
    """A minimal Lua 5.3 state: load a chunk, call it, read the error."""

    def __init__(self, dll_path: str) -> None:
        self._lib = ctypes.CDLL(dll_path)
        lib = self._lib
        lib.luaL_newstate.restype = ctypes.c_void_p
        lib.luaL_openlibs.argtypes = [ctypes.c_void_p]
        lib.luaL_loadstring.argtypes = [ctypes.c_void_p, ctypes.c_char_p]
        lib.luaL_loadstring.restype = ctypes.c_int
        lib.lua_pcallk.argtypes = [
            ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_int,
            ctypes.c_void_p, ctypes.c_void_p,
        ]
        lib.lua_pcallk.restype = ctypes.c_int
        lib.lua_tolstring.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p]
        lib.lua_tolstring.restype = ctypes.c_char_p
        lib.lua_settop.argtypes = [ctypes.c_void_p, ctypes.c_int]
        lib.lua_close.argtypes = [ctypes.c_void_p]

        self.L = ctypes.c_void_p(lib.luaL_newstate())
        if not self.L:
            raise LuaError("luaL_newstate failed")
        lib.luaL_openlibs(self.L)

    def _err(self) -> str:
        msg = self._lib.lua_tolstring(self.L, -1, None)
        self._lib.lua_settop(self.L, -2)
        return msg.decode("utf-8", "replace") if msg else "<no message>"

    def check_syntax(self, source: str) -> None:
        """Compile without running. Raises LuaError on a syntax error."""
        if self._lib.luaL_loadstring(self.L, source.encode("utf-8")) != LUA_OK:
            raise LuaError(self._err())
        self._lib.lua_settop(self.L, -2)

    def run(self, source: str) -> None:
        """Compile and execute. Raises LuaError on syntax or runtime error."""
        if self._lib.luaL_loadstring(self.L, source.encode("utf-8")) != LUA_OK:
            raise LuaError("syntax: " + self._err())
        if self._lib.lua_pcallk(self.L, 0, LUA_MULTRET, 0, None, None) != LUA_OK:
            raise LuaError("runtime: " + self._err())

    def close(self) -> None:
        if getattr(self, "L", None):
            self._lib.lua_close(self.L)
            self.L = None

    def __enter__(self) -> Self:
        return self

    def __exit__(self, *exc: object) -> None:
        self.close()
