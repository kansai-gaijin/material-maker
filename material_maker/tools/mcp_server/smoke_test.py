"""End-to-end check of Material Maker's built-in MCP server.

Start Material Maker (the server listens on http://127.0.0.1:8790/mcp by
default), then run:

    python smoke_test.py [--url http://127.0.0.1:8790/mcp] [--out DIR]

It opens a new material tab, builds and edits a small graph, renders it,
undoes and redoes, saves and exports into DIR, and exercises both the
initialize-based and the stateless (2026-07-28) protocol revisions.
Only the Python standard library is used.
"""

import argparse
import base64
import json
import os
import sys
import tempfile
import urllib.error
import urllib.request

PASS = 0
FAIL = 0


class Client:
    def __init__(self, url):
        self.url = url
        self.session = None
        self.version = None
        self.next_id = 1

    def post(self, message, headers=None):
        data = json.dumps(message).encode("utf-8")
        h = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream"}
        if self.session:
            h["Mcp-Session-Id"] = self.session
        if self.version:
            h["MCP-Protocol-Version"] = self.version
        h.update(headers or {})
        req = urllib.request.Request(self.url, data=data, headers=h, method="POST")
        try:
            with urllib.request.urlopen(req, timeout=120) as r:
                body = r.read().decode("utf-8")
                return r.status, dict(r.headers), (json.loads(body) if body else None)
        except urllib.error.HTTPError as e:
            body = e.read().decode("utf-8")
            try:
                parsed = json.loads(body)
            except ValueError:
                parsed = body
            return e.code, dict(e.headers), parsed

    def request(self, method, params=None, headers=None):
        msg = {"jsonrpc": "2.0", "id": self.next_id, "method": method, "params": params or {}}
        self.next_id += 1
        return self.post(msg, headers)

    def call(self, name, arguments=None):
        status, _, body = self.request("tools/call", {"name": name, "arguments": arguments or {}})
        if status != 200 or "result" not in body:
            raise RuntimeError(f"{name}: HTTP {status} {body}")
        return body["result"]


def check(label, condition, detail=""):
    global PASS, FAIL
    if condition:
        PASS += 1
        print(f"  ok    {label}")
    else:
        FAIL += 1
        print(f"  FAIL  {label} {detail}")


def tool(client, name, arguments=None, expect_error=False):
    result = client.call(name, arguments)
    is_error = result.get("isError", False)
    text = result["content"][0]["text"] if result.get("content") else ""
    check(f"{name}{' (expected error)' if expect_error else ''}", is_error == expect_error, text[:300])
    return result.get("structuredContent", {}), result


def image_of(result):
    for c in result.get("content", []):
        if c.get("type") == "image":
            return base64.b64decode(c["data"])
    return None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", default="http://127.0.0.1:8790/mcp")
    parser.add_argument("--out", default=os.path.join(tempfile.gettempdir(), "mm_mcp_smoke"))
    args = parser.parse_args()
    out = os.path.abspath(args.out).replace("\\", "/")
    os.makedirs(out, exist_ok=True)
    c = Client(args.url)

    print("protocol")
    status, headers, body = c.request("initialize", {
        "protocolVersion": "2025-06-18", "capabilities": {},
        "clientInfo": {"name": "mm-smoke-test", "version": "1"}})
    check("initialize", status == 200 and body["result"]["protocolVersion"] == "2025-06-18", body)
    c.session = {k.lower(): v for k, v in headers.items()}.get("mcp-session-id")
    c.version = "2025-06-18"
    check("session id issued", bool(c.session))
    status, _, body = c.post({"jsonrpc": "2.0", "method": "notifications/initialized"})
    check("initialized notification -> 202", status == 202)
    status, _, body = c.request("tools/list")
    names = [t["name"] for t in body["result"]["tools"]]
    check("tools/list", "add_nodes" in names and len(names) >= 25, names)
    status, _, body = c.request("nope/nothing")
    check("unknown method -> -32601", body["error"]["code"] == -32601)
    status, _, _ = c.post({"jsonrpc": "2.0", "id": 99, "method": "ping"}, {"Origin": "https://evil.example"})
    check("foreign Origin -> 403", status == 403)
    req = urllib.request.Request(args.url, method="GET")
    try:
        urllib.request.urlopen(req, timeout=10)
        check("GET -> 405", False)
    except urllib.error.HTTPError as e:
        check("GET -> 405", e.code == 405)
    stateless = Client(args.url)
    status, _, body = stateless.request("server/discover", {"_meta": {"io.modelcontextprotocol/protocolVersion": "2026-07-28"}},
                                        {"MCP-Protocol-Version": "2026-07-28", "Mcp-Method": "server/discover"})
    check("server/discover (stateless)", status == 200 and body["result"]["resultType"] == "complete", body)
    status, _, body = stateless.request("tools/list", {"_meta": {"io.modelcontextprotocol/protocolVersion": "2026-07-28"}},
                                        {"MCP-Protocol-Version": "2026-07-28", "Mcp-Method": "tools/list"})
    check("tools/list (stateless)", status == 200 and body["result"]["resultType"] == "complete")
    status, _, body = stateless.request("ping", {}, {"Mcp-Method": "tools/list"})
    check("Mcp-Method mismatch -> -32020", status == 400 and body["error"]["code"] == -32020, body)

    print("discovery")
    data, _ = tool(c, "get_status")
    data, _ = tool(c, "search_library", {"query": "bricks", "limit": 5})
    check("library finds bricks", any("brick" in i["library_item"].lower() for i in data.get("items", [])), data)
    data, _ = tool(c, "list_node_types", {"filter": "perlin"})
    check("perlin type listed", any(t["type"] == "perlin" for t in data.get("types", [])))
    data, _ = tool(c, "describe_node_type", {"type": "bricks"})
    check("bricks has parameters and outputs", len(data.get("parameters", [])) > 3 and len(data.get("outputs", [])) > 0)
    tool(c, "describe_node_type", {"type": "no_such_node"}, expect_error=True)

    print("editing")
    data, _ = tool(c, "new_material")
    project = data["project"]
    data, _ = tool(c, "get_graph", {"project": project})
    material = next(n for n in data["nodes"] if n["name"] == "Material")
    albedo = next(p["index"] for p in material["inputs"] if "albedo" in p["name"])
    roughness = next(p["index"] for p in material["inputs"] if "rough" in p["name"])
    data, _ = tool(c, "add_nodes", {"project": project, "nodes": [
        {"id": "bricks", "type": "bricks", "parameters": {"rows": 8, "columns": 4}},
        {"id": "tint", "type": "colorize", "parameters": {"gradient": [
            {"pos": 0, "color": "#3a1f14"}, {"pos": 1, "color": "#b5562d"}]}},
    ], "connections": [
        {"from": "bricks", "from_port": 0, "to": "tint", "to_port": 0},
        {"from": "tint", "to": "Material", "to_port": albedo},
        {"from": "bricks", "to": "Material", "to_port": roughness},
    ]})
    check("two nodes created", len(data.get("nodes", [])) == 2, data)
    check("three connections made", len(data.get("connections", [])) == 3, data)
    bricks = data["nodes"][0]["name"]
    tint = data["nodes"][1]["name"]
    data, _ = tool(c, "set_parameters", {"project": project, "node": bricks, "parameters": {"mortar": 0.05, "pattern": 1}})
    check("parameters applied", set(data.get("applied", [])) == {"mortar", "pattern"}, data)
    tool(c, "set_parameters", {"project": project, "node": bricks, "parameters": {"not_a_param": 1}}, expect_error=True)
    tool(c, "connect_nodes", {"project": project, "connections": [{"from": tint, "to": bricks, "to_port": 99}]}, expect_error=True)
    data, _ = tool(c, "get_node", {"project": project, "node": bricks})
    check("get_node reports new value", next(p for p in data["parameters"] if p["name"] == "mortar")["value"] == 0.05)
    tool(c, "move_nodes", {"project": project, "positions": {bricks: {"x": -700, "y": 0}}})
    tool(c, "randomize_seed", {"project": project, "node": bricks, "seed": 0.25})
    tool(c, "set_preview", {"project": project, "node": tint})

    print("rendering")
    data, result = tool(c, "render_output", {"project": project, "node": tint, "size": 256, "save_path": out + "/tint.png"})
    png = image_of(result)
    check("render returns a PNG", png is not None and png[:8] == b"\x89PNG\r\n\x1a\n")
    check("render saved to disk", os.path.exists(out + "/tint.png"))
    data, result = tool(c, "render_material_preview", {"project": project, "shape": "sphere", "size": 256})
    check("material preview image", image_of(result) is not None)
    data, result = tool(c, "capture_view", {"area": "window"})
    check("window capture image", image_of(result) is not None)
    data, _ = tool(c, "get_console", {"lines": 10})

    print("undo / redo / delete")
    data, _ = tool(c, "delete_nodes", {"project": project, "nodes": [tint]})
    data, _ = tool(c, "get_graph", {"project": project})
    check("tint deleted", not any(n["name"] == tint for n in data["nodes"]))
    data, _ = tool(c, "undo", {"project": project})
    data, _ = tool(c, "get_graph", {"project": project})
    check("undo restored tint", any(n["name"] == tint for n in data["nodes"]))
    tool(c, "redo", {"project": project})
    tool(c, "undo", {"project": project})
    tool(c, "delete_nodes", {"project": project, "nodes": ["Material"]}, expect_error=True)
    data, _ = tool(c, "disconnect_nodes", {"project": project, "inputs": [{"node": "Material", "port": roughness}]})
    check("disconnected roughness", len(data.get("disconnected", [])) == 1, data)

    print("rendering still works after rapid edits")
    data, _ = tool(c, "add_nodes", {"project": project, "nodes": [{"id": "nm", "type": "normal_map2"}],
                                    "connections": [{"from": bricks, "to": "nm"}, {"from": "nm", "to": "Material", "to_port": 4}]})
    data, result = tool(c, "render_material_preview", {"project": project, "size": 128})
    check("buffers finished rendering", "warning" not in data, data)
    tool(c, "undo", {"project": project})
    data, _ = tool(c, "describe_node_type", {"type": "normal_map2"})
    algo = next((p for p in data.get("parameters", []) if p["name"] == "param2"), {})
    check("linked group parameter resolved", algo.get("type") == "enum" and len(algo.get("values", [])) > 1, algo)
    data, _ = tool(c, "describe_node_type", {"type": "switch"})
    check("builtin switch describes its ports", len(data.get("inputs", [])) > 0, data)

    print("previews of different projects stay separate")
    shots = {}
    others = []
    for color in ("#ff2020", "#2040ff"):
        data, _ = tool(c, "new_material")
        other = data["project"]
        others.append(other)
        tool(c, "add_nodes", {"project": other, "nodes": [{"id": "flat", "type": "uniform", "parameters": {"color": color}}],
                              "connections": [{"from": "flat", "to": "Material", "to_port": 0}]})
        _, result = tool(c, "render_material_preview", {"project": other, "size": 96})
        shots[color] = image_of(result)
    check("red and blue projects render differently", shots["#ff2020"] != shots["#2040ff"])
    for other in reversed(others):
        tool(c, "close_project", {"project": other, "discard_changes": True})
    tool(c, "set_parameters", {"project": project, "node": bricks, "parameters": {"rows": 7}})
    data, _ = tool(c, "render_material_preview", {"project": project, "size": 128})
    check("rendering still works after closing tabs mid-render", "warning" not in data, data)

    print("groups")
    data, _ = tool(c, "create_group", {"project": project, "nodes": [bricks, tint], "label": "Brick wall"})
    group = data.get("group_path", "")
    data, _ = tool(c, "get_graph", {"project": project, "graph": group})
    check("group contains the nodes", len(data.get("nodes", [])) >= 2, data)
    tool(c, "open_graph", {"project": project, "graph": group})
    tool(c, "open_graph", {"project": project, "graph": ""})

    print("save / export")
    data, _ = tool(c, "save_project", {"project": project, "path": out + "/smoke.ptex"})
    check("ptex written", os.path.exists(out + "/smoke.ptex"))
    data, _ = tool(c, "list_export_targets", {"project": project})
    targets = [t["target"] for t in data.get("targets", [])]
    target = next((t for t in targets if t.startswith("Godot")), targets[0] if targets else "")
    data, _ = tool(c, "export_material", {"project": project, "target": target, "path": out + "/export/smoke", "size": 256})
    check(f"export with {target} wrote files", len(data.get("files", [])) > 0, data)
    tool(c, "close_project", {"project": project})

    print(f"\n{PASS} passed, {FAIL} failed")
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
