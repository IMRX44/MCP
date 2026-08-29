# 🧠 ce-mcp — Cheat Engine MCP Server

> Give an AI agent **full, programmatic control of [Cheat Engine](https://cheatengine.org/)** through the [Model Context Protocol](https://modelcontextprotocol.io).

`ce-mcp` lets a model like Claude attach to a running process, scan and edit
memory, build cheat tables, resolve pointer chains, disassemble/assemble code,
run Auto Assembler scripts, and inspect Unity/Mono games — the same workflow a
human reverse-engineer follows in the Cheat Engine UI, exposed as clean MCP
tools.

```
"Attach to the game, find my health value, then freeze it."
        │
   ┌────▼─────────┐    MCP/stdio    ┌──────────────┐   temp-file   ┌──────────────┐
   │   AI agent   │ ───────────────▶│  ce-mcp      │ ─────────────▶│ Cheat Engine │
   │ (Claude etc) │ ◀───────────────│ (Python,     │ ◀─────────────│ Lua bridge   │
   └──────────────┘                 │  FastMCP)    │  JSON + id    │ (in-process) │
                                    └──────────────┘               └──────────────┘
```

---

## ✨ Why this design

Cheat Engine has no external API — its automation surface lives entirely in its
embedded Lua engine. `ce-mcp` bridges that gap with two cooperating halves:

| Half | Lives in | Job |
|------|----------|-----|
| **Lua bridge** (`lua/ce_mcp_bridge.lua`) | Inside Cheat Engine | Calls CE's Lua API directly — scanning, reading/writing, AA, debugger, Mono. Ships its own JSON codec, structured logging and a job scheduler. No external deps. |
| **MCP server** (`src/ce_mcp/`) | Python process | Speaks MCP over stdio to the agent and translates each tool call into a bridge command. Built on the official `mcp` SDK (FastMCP). |

The two talk through a pair of temp files (`%TEMP%\cemcp_req.json` /
`cemcp_res.json`) rather than a socket, so there is no LuaSocket dependency and
nothing to install inside Cheat Engine. Every request carries an `id` that the
bridge echoes back, so a late reply to a call that already timed out can never
be mistaken for the answer to the next one.

---

## 🛠️ Capabilities

**54 tools** covering effectively the whole manual workflow — see
[docs/TOOLS.md](docs/TOOLS.md) for the generated reference.

| Group | Tools |
|-------|-------|
| **Connectivity & diagnostics** | `ce_status`, `ce_version`, `ce_routes`, `ce_capabilities`, `ce_diagnostics`, `ce_debug_log`, `ce_debug_level`, `ce_debug_state` |
| **Process** | `process_list`, `process_attach`, `process_detach`, `process_current`, `process_modules`, `process_regions` |
| **Memory** | `memory_read`, `memory_read_batch`, `memory_write`, `memory_dump`, `memory_alloc`, `memory_free` |
| **Scanning** | `scan_estimate`, `scan_first`, `scan_next`, `scan_status`, `scan_cancel`, `scan_results`, `scan_save_results`, `scan_reset`, `scan_aob` |
| **Cheat table** | `table_list`, `table_add`, `table_remove`, `table_set_value`, `table_freeze`, `table_enable`, `table_hotkey`, `table_save`, `table_load`, `table_clear` |
| **Pointers** | `pointer_resolve` |
| **Code** | `disassemble`, `assemble`, `auto_assemble` |
| **Debugger** | `find_what_writes`, `find_what_accesses`, `breakpoint`, `breakpoint_list` |
| **Jobs** | `job_status`, `job_list`, `job_cancel` |
| **Mono/Unity** | `mono_init`, `mono_classes` |
| **Misc** | `speedhack`, `lua_execute` (raw Lua escape hatch) |

Every scan type Cheat Engine supports is available: `exact`, `bigger`,
`smaller`, `between`, `unknown`, `changed`, `unchanged`, `increased`,
`decreased`, `increasedby`, `decreasedby`. Every value type too: `byte` … `qword`,
`float`, `double`, `string` (incl. UTF-16), and AOB byte arrays with wildcards.

---

## 🚀 Quick start

### 1. Requirements
- **Windows** with **Cheat Engine 7.x** installed
- **Python 3.10+**

### 2. Install the Python server
```bash
git clone https://github.com/imrx44/mcp.git
cd mcp
pip install -e .
# or, without packaging:  pip install -r requirements.txt
```

### 3. Start the in-CE bridge
1. Open Cheat Engine.
2. **Table ▸ Cheat Table Lua Script** (`Ctrl+Alt+L`).
3. Paste the contents of [`lua/ce_mcp_bridge.lua`](lua/ce_mcp_bridge.lua) and click **Execute**.
4. The CE console prints: `[CE-MCP] listening on http://127.0.0.1:37712`.

> 💡 To auto-start it every time, drop the file into Cheat Engine's
> `autorun/` folder.

### 4. Wire it into your MCP client
Add the block from [`examples/claude_desktop_config.json`](examples/claude_desktop_config.json)
to your Claude Desktop config (or any MCP client), pointing `PYTHONPATH` at this
repo's `src/`. Restart the client and the `cheat-engine` tools appear.

### 5. Verify
Ask the agent: *"Run ce_status."* — you should get the Cheat Engine version back.

---

## 🎮 Example: freeze your health (end to end)

A natural-language session the agent can now carry out by itself:

```
1. process_list  filter="game"            → find the pid
2. process_attach process="game.exe"
3. scan_first  value=100  value_type="4byte"  scan_type="exact"
   ... take damage in-game ...
4. scan_next   value=92  scan_type="exact"
   ... repeat until one result remains ...
5. scan_results                            → 0x1F3A4C20
6. table_add   address="0x1F3A4C20"  description="Health"  type="4byte"
7. table_freeze id=<id>                    → health locked
```

And a code-injection ("godmode") cheat via Auto Assembler:

```python
auto_assemble(script="""
[ENABLE]
aobscanmodule(hpHook,game.exe,29 87 ?? ?? ?? ??)   // sub [edi+offset],eax
alloc(newmem,128,hpHook)
label(ret)
newmem:
  // skip the subtract → take no damage
  jmp ret
hpHook:
  jmp newmem
  nop 2
ret:
[DISABLE]
hpHook:
  db 29 87 ?? ?? ?? ??
dealloc(newmem)
""")
```

---

## ⚙️ Configuration

The Python server reads these environment variables:

| Variable | Default | Meaning |
|----------|---------|---------|
| `CE_MCP_HOST` | `127.0.0.1` | Bridge host |
| `CE_MCP_PORT` | `37712` | Bridge port (must match the Lua file) |
| `CE_MCP_TIMEOUT` | `60` | HTTP timeout (s) — raise for long scans |

---

## 🔒 Security notes

- The bridge binds to **loopback only** and has **no authentication** — anything
  that can reach `localhost:37712` can drive Cheat Engine. Don't expose the port.
- This is a debugging / reverse-engineering tool. Use it on software **you own or
  are authorised to analyse**, and respect the terms of service of online games.

---

## 🧩 Architecture details

- **No external Lua dependencies.** The bridge implements its own recursive-descent
  JSON encoder/decoder, so it runs on a stock Cheat Engine install.
- **Non-blocking server.** The HTTP accept loop runs on a CE timer, so it never
  freezes the Cheat Engine UI.
- **Stateful scan session.** `scan_first` creates a CE `MemScan`/`FoundList` that
  later `scan_next`/`scan_results`/`scan_reset` calls operate on — mirroring the UI.
- **Clean error contract.** Every response is `{ ok, data | error }`; the Python
  client raises a typed `BridgeError` that tools surface as a readable message.

See [`docs/TOOLS.md`](docs/TOOLS.md) for the full per-tool reference.

---

## 📁 Project layout

```
MCP/
├── lua/
│   └── ce_mcp_bridge.lua        # In-Cheat-Engine HTTP/JSON bridge
├── src/ce_mcp/
│   ├── server.py                # FastMCP server + all tool definitions
│   ├── client.py                # Async HTTP client for the bridge
│   ├── __main__.py              # python -m ce_mcp
│   └── __init__.py
├── examples/
│   └── claude_desktop_config.json
├── docs/
│   └── TOOLS.md                 # Full tool reference
├── pyproject.toml
├── requirements.txt
└── README.md
```

---

## 📜 License

MIT — see [`LICENSE`](LICENSE).

*Not affiliated with Cheat Engine or its author. "Cheat Engine" is the property
of its respective owners.*
