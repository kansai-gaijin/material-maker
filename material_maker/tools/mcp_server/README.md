# Built-in MCP server

Material Maker has a [Model Context Protocol](https://modelcontextprotocol.io)
server built in. While the app is open, coding agents such as Claude Code or
Codex can build and edit material graphs, render node outputs, save and
export — live in the window you are looking at, with every change on the
normal undo stack.

There is no separate process, bridge or add-on to install: the server is part
of the application (`material_maker/tools/mcp_server/`) and speaks MCP's
Streamable HTTP transport directly.

## Connecting

The server starts with Material Maker and listens on
`http://127.0.0.1:8790/mcp` (loopback only).

```bash
claude mcp add --transport http material-maker http://127.0.0.1:8790/mcp
```

```bash
codex mcp add material-maker --url http://127.0.0.1:8790/mcp
```

Any client that supports Streamable HTTP works; for one configured by JSON:

```json
{ "mcpServers": { "material-maker": { "type": "http", "url": "http://127.0.0.1:8790/mcp" } } }
```

**Edit > Preferences > MCP** turns the server on or off, changes the port, sets
an optional bearer token (clients then send `Authorization: Bearer <token>`)
and has copy buttons for the commands above. From the command line,
`--mcp-port=<port>` overrides the port and `--no-mcp` disables the server.

## Agent skill

`skill/material-maker/` is a Claude Code skill that teaches an agent how to
build good materials with these tools: the Material node's channels and
conventions (depth is inverted height, Material Maker's own normal format),
the height-first workflow, how to find nodes and verify results, and two
references written from the manual (`references/concepts.md`,
`references/nodes.md`). Install it by copying the folder into
`~/.claude/skills/`.

## Tools

| Tool | What it does |
| --- | --- |
| `get_status` | Version, endpoint, open project tabs, current tab and shown graph |
| `list_node_types` | Node type names accepted by `add_nodes` |
| `search_library` | Search the Library panel; returns item paths and their node types |
| `describe_node_type` | Parameters (type, range, enum values, defaults) and ports of a type or library item |
| `get_graph` | Nodes, parameter values, ports and connections of a graph or group |
| `get_node` | Full detail of one node, including parameter definitions and current values |
| `render_output` | Render a node output to PNG (returned as an image, optionally saved as png/exr/jpg/webp) |
| `render_material_preview` | Render the material on a sphere, cube, cylinder or the current 3D preview object |
| `capture_view` | Screenshot the window, graph editor, 2D or 3D preview panel |
| `get_console` | Latest console lines (shader errors, export messages) |
| `list_export_targets` | Export profiles of the material (Godot, Unity, Unreal, Blender, ...) |
| `new_material` / `open_project` / `save_project` / `switch_project` / `close_project` | Project tabs, no file dialogs |
| `open_graph` | Show a group (subgraph) or the top-level graph |
| `add_nodes` | Add nodes by type or library item, with parameters and connections, as one undo step |
| `delete_nodes` / `connect_nodes` / `disconnect_nodes` / `move_nodes` | Graph editing |
| `set_parameters` | Set parameters; colors as `#rrggbb`, enums by label, gradients as `[{pos, color}]` |
| `randomize_seed` | New seed for a node with randomness |
| `create_group` | Group nodes into a subgraph (Ctrl+G) |
| `set_preview` | Show a node output in a 2D preview panel |
| `undo` / `redo` | Project undo history |
| `export_material` | Export textures and engine files with a profile, without dialogs |

Groups are addressed with the optional `graph` argument (`"my_group"`,
`"outer/inner"`, `""` for the top level). Ports are 0-based indices, as listed
by `get_graph` and `describe_node_type`. Every material has a `Material` node
whose inputs are the PBR channels.

## Design

- **In the app, on the main thread.** `mcp_http_server.gd` is a small HTTP/1.1
  server on Godot's `TCPServer`, polled from `_process`, so tools can touch
  the scene tree and `await` renders. Tool calls run one at a time.
- **Same code paths as the UI.** Editing tools call `MMGraphEdit`'s own
  functions (`create_nodes`, `on_connect_node`, `set_node_parameters`,
  `undoredo_create_step`, ...). Each tool call is one undo step, so a person
  can step back through what an agent did with Ctrl+Z.
- **No dialogs.** Loading, saving and exporting call the underlying functions
  directly so an agent never blocks on a modal window. Exports keep existing
  files that a profile would normally ask about overwriting.
- **Protocol.** Each POST is answered with one `application/json` message
  (no SSE). Both the `initialize`-based revisions (2024-11-05 to 2025-11-25)
  and the session-less 2026-07-28 revision (`server/discover`, `_meta`) are
  supported. GET returns 405.
- **Safety.** Loopback only; requests with a non-local `Host` or `Origin`
  are refused (DNS rebinding); optional bearer token.

## Testing

With Material Maker running:

```bash
python material_maker/tools/mcp_server/smoke_test.py
```

It opens a new tab, builds, renders, undoes, groups, saves and exports a small
material over real HTTP and checks the protocol edge cases (62 checks).
