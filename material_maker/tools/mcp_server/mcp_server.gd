extends Node
class_name MMMcpServer

## Model Context Protocol server built into Material Maker.
##
## Serves MCP over the Streamable HTTP transport at http://127.0.0.1:<port>/mcp,
## answering every POST with a single application/json message (no SSE).
## It speaks both the session-less 2026-07-28 revision (server/discover, _meta)
## and the older initialize-based revisions that most clients still use.
## Tools live in mcp_tools.gd and run on the main thread, through the same
## functions the UI uses, so everything an agent does shows up live in the
## editor and can be undone with Ctrl+Z.

const SERVER_NAME : String = "material-maker"
const SERVER_TITLE : String = "Material Maker"
const DEFAULT_PORT : int = 8790
const MCP_PATH : String = "/mcp"

const LATEST_STATELESS_VERSION : String = "2026-07-28"
const SUPPORTED_VERSIONS : Array[String] = [ "2026-07-28", "2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05" ]
const LEGACY_DEFAULT_VERSION : String = "2025-11-25"

const ERR_PARSE : int = -32700
const ERR_INVALID_REQUEST : int = -32600
const ERR_METHOD_NOT_FOUND : int = -32601
const ERR_INVALID_PARAMS : int = -32602
const ERR_INTERNAL : int = -32603
const ERR_HEADER_MISMATCH : int = -32020
const ERR_UNSUPPORTED_VERSION : int = -32022

const INSTRUCTIONS : String = """Material Maker is a node-based procedural texture/material editor. This MCP server runs inside the open Material Maker window, so every change appears live and can be undone by the person (or with the undo tool).

Typical workflow:
1. get_status to see open projects; new_material or open_project if needed.
2. search_library / list_node_types to find nodes, describe_node_type for parameters and ports.
3. get_graph to see the current graph (node names, ports, connections). Every material has a node named "Material" whose inputs are the PBR channels (albedo, metallic, roughness, emission, normal, occlusion, depth...).
4. add_nodes (with connections in the same call), connect_nodes, set_parameters, delete_nodes, move_nodes.
5. render_output to look at any node output as an image, capture_view for the 3D preview.
6. save_project and export_material (list_export_targets for profiles such as Godot, Unity, Unreal, Blender).

Ports are referenced by index (0-based); get_graph and describe_node_type list them. Node names are unique inside a graph (e.g. "bricks", "bricks_2"). Groups (subgraphs) are addressed with the optional `graph` argument, a path like "my_group" or "my_group/inner"; omit it for the graph currently shown in the editor."""

var http : MMMcpHttpServer
var tools : MMMcpTools
var port : int = DEFAULT_PORT
var token : String = ""

var _sessions : Dictionary = {}
var _tool_index : Dictionary = {}


func _ready() -> void:
	tools = MMMcpTools.new()
	tools.server = self
	add_child(tools)
	for t in tools.get_tool_definitions():
		_tool_index[t.name] = t
	http = MMMcpHttpServer.new()
	http.name = "HttpServer"
	http.handler = _on_http_request
	add_child(http)

func start(p_port : int, p_token : String = "") -> Error:
	port = p_port
	token = p_token
	var err : Error = http.start(port, "127.0.0.1")
	if err == OK:
		mm_logger.message("MCP server listening on http://127.0.0.1:%d%s" % [ port, MCP_PATH ])
	else:
		mm_logger.error("MCP server could not listen on port %d (%s)" % [ port, error_string(err) ])
	return err

func stop() -> void:
	http.stop()

func get_url() -> String:
	return "http://127.0.0.1:%d%s" % [ port, MCP_PATH ]

func is_running() -> bool:
	return http.is_listening()


# ---------------------------------------------------------------------------
# HTTP layer
# ---------------------------------------------------------------------------

static func _is_loopback_host(host : String) -> bool:
	host = host.strip_edges().to_lower()
	if host.begins_with("["):
		host = host.substr(1, host.find("]")-1)
	elif host.count(":") == 1:
		host = host.left(host.find(":"))
	return host in [ "localhost", "127.0.0.1", "::1" ]

static func _origin_allowed(origin : String) -> bool:
	if origin == "" or origin == "null":
		return origin == ""
	var rest : String = origin
	var scheme_end : int = rest.find("://")
	if scheme_end == -1:
		return false
	rest = rest.substr(scheme_end+3)
	var slash : int = rest.find("/")
	if slash != -1:
		rest = rest.left(slash)
	return _is_loopback_host(rest)

func _json_response(status : int, data, extra_headers : Dictionary = {}) -> Dictionary:
	var headers : Dictionary = { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" }
	headers.merge(extra_headers, true)
	return { status = status, headers = headers, body = JSON.stringify(data, "", false) }

func _error_response(status : int, code : int, message : String, id = null, data = null) -> Dictionary:
	var error : Dictionary = { code = code, message = message }
	if data != null:
		error.data = data
	return _json_response(status, { jsonrpc = "2.0", id = id, error = error })

func _on_http_request(request : Dictionary) -> Dictionary:
	var headers : Dictionary = request.headers
	# DNS-rebinding and cross-site protection
	if not _is_loopback_host(headers.get("host", "127.0.0.1")):
		return { status = 403, headers = { "Content-Type": "text/plain" }, body = "Forbidden host" }
	if headers.has("origin") and not _origin_allowed(headers.origin):
		return { status = 403, headers = { "Content-Type": "text/plain" }, body = "Forbidden origin" }
	if request.path != MCP_PATH and request.path != "/":
		return { status = 404, headers = { "Content-Type": "text/plain" }, body = "Material Maker MCP endpoint is %s" % MCP_PATH }
	if token != "":
		var auth : String = headers.get("authorization", "")
		if auth != "Bearer " + token:
			return { status = 401, headers = { "Content-Type": "text/plain", "WWW-Authenticate": "Bearer" }, body = "Missing or invalid bearer token" }
	match request.method:
		"POST":
			pass
		"DELETE":
			var sid : String = headers.get("mcp-session-id", "")
			if sid != "":
				_sessions.erase(sid)
			return { status = 204, headers = {}, body = "" }
		_:
			# No server-initiated SSE stream is offered.
			return { status = 405, headers = { "Allow": "POST, DELETE", "Content-Type": "text/plain" }, body = "Method not allowed" }
	var header_version : String = headers.get("mcp-protocol-version", "")
	if header_version != "" and not header_version in SUPPORTED_VERSIONS:
		return _error_response(400, ERR_UNSUPPORTED_VERSION, "Unsupported protocol version " + header_version, null, { supported = SUPPORTED_VERSIONS })
	var json : JSON = JSON.new()
	if json.parse(request.body) != OK:
		return _error_response(400, ERR_PARSE, "Parse error: " + json.get_error_message())
	var message = json.data
	var extra_headers : Dictionary = {}
	if message is Array:
		# JSON-RPC batch (2025-03-26)
		if message.is_empty():
			return _error_response(400, ERR_INVALID_REQUEST, "Empty batch")
		var responses : Array = []
		for m in message:
			var r = await _handle_message(m, headers, extra_headers)
			if r != null:
				responses.append(r.body)
		if responses.is_empty():
			return { status = 202, headers = {}, body = "" }
		return _json_response(200, responses, extra_headers)
	var result = await _handle_message(message, headers, extra_headers)
	if result == null:
		return { status = 202, headers = {}, body = "" }
	return _json_response(result.status, result.body, extra_headers)

# Returns null for notifications/responses, or { status, body }
func _handle_message(message, headers : Dictionary, extra_headers : Dictionary):
	if not message is Dictionary or message.get("jsonrpc") != "2.0":
		return { status = 400, body = { jsonrpc = "2.0", id = null, error = { code = ERR_INVALID_REQUEST, message = "Invalid JSON-RPC message" } } }
	if not message.has("method"):
		return null # A response to something we never sent; ignore
	var id = _normalize_id(message.get("id"))
	var method : String = str(message.method)
	var params = message.get("params", {})
	if params == null:
		params = {}
	if not params is Dictionary:
		return { status = 400, body = { jsonrpc = "2.0", id = id, error = { code = ERR_INVALID_PARAMS, message = "params must be an object" } } }
	if headers.has("mcp-method") and headers["mcp-method"] != method:
		return { status = 400, body = { jsonrpc = "2.0", id = id, error = { code = ERR_HEADER_MISMATCH, message = "Mcp-Method header does not match the request body" } } }
	var meta : Dictionary = params.get("_meta", {}) if params.get("_meta") is Dictionary else {}
	var stateless : bool = meta.has("io.modelcontextprotocol/protocolVersion") or headers.get("mcp-protocol-version", "") == LATEST_STATELESS_VERSION
	if not message.has("id"):
		# Notification (notifications/initialized, notifications/cancelled...)
		return null
	var outcome : Dictionary = await _dispatch(method, params, stateless, headers, extra_headers)
	if outcome.has("error"):
		var status : int = 200
		if stateless and outcome.error.code == ERR_METHOD_NOT_FOUND:
			status = 404
		return { status = status, body = { jsonrpc = "2.0", id = id, error = outcome.error } }
	var result : Dictionary = outcome.result
	if stateless:
		result.resultType = "complete"
	return { status = 200, body = { jsonrpc = "2.0", id = id, result = result } }

static func _normalize_id(id):
	if id is float and id == floor(id) and abs(id) < 9007199254740992.0:
		return int(id)
	return id

func _server_info() -> Dictionary:
	return {
		name = SERVER_NAME,
		title = SERVER_TITLE,
		version = str(ProjectSettings.get_setting("application/config/actual_release", "unknown")),
		websiteUrl = "https://www.materialmaker.org"
	}

func _capabilities() -> Dictionary:
	return { tools = { listChanged = false } }

func _dispatch(method : String, params : Dictionary, stateless : bool, headers : Dictionary, extra_headers : Dictionary) -> Dictionary:
	match method:
		"initialize":
			var requested : String = str(params.get("protocolVersion", ""))
			var version : String = requested if requested in SUPPORTED_VERSIONS and requested != LATEST_STATELESS_VERSION else LEGACY_DEFAULT_VERSION
			var session_id : String = _new_session_id()
			_sessions[session_id] = { client = params.get("clientInfo", {}), version = version, created = Time.get_unix_time_from_system() }
			extra_headers["Mcp-Session-Id"] = session_id
			var client : Dictionary = params.get("clientInfo", {}) if params.get("clientInfo") is Dictionary else {}
			mm_logger.message("MCP client connected: %s %s" % [ client.get("name", "unknown"), client.get("version", "") ])
			return { result = {
				protocolVersion = version,
				capabilities = _capabilities(),
				serverInfo = _server_info(),
				instructions = INSTRUCTIONS
			} }
		"server/discover":
			return { result = {
				supportedVersions = SUPPORTED_VERSIONS,
				capabilities = _capabilities(),
				instructions = INSTRUCTIONS,
				_meta = { "io.modelcontextprotocol/serverInfo": _server_info() }
			} }
		"ping":
			return { result = {} }
		"logging/setLevel":
			return { result = {} }
		"tools/list":
			var list : Array = []
			for t in tools.get_tool_definitions():
				var d : Dictionary = { name = t.name, title = t.title, description = t.description, inputSchema = t.inputSchema }
				if t.has("annotations"):
					d.annotations = t.annotations
				list.append(d)
			return { result = { tools = list } }
		"tools/call":
			var tool_name = params.get("name")
			if not tool_name is String or not _tool_index.has(tool_name):
				return { error = { code = ERR_INVALID_PARAMS, message = "Unknown tool: %s" % str(tool_name) } }
			if headers.has("mcp-name") and headers["mcp-name"] != tool_name:
				return { error = { code = ERR_HEADER_MISMATCH, message = "Mcp-Name header does not match the tool name" } }
			var arguments = params.get("arguments", {})
			if arguments == null:
				arguments = {}
			if not arguments is Dictionary:
				return { error = { code = ERR_INVALID_PARAMS, message = "arguments must be an object" } }
			return { result = await tools.call_tool(_tool_index[tool_name], arguments) }
		"resources/list":
			return { result = { resources = [] } }
		"resources/templates/list":
			return { result = { resourceTemplates = [] } }
		"prompts/list":
			return { result = { prompts = [] } }
	return { error = { code = ERR_METHOD_NOT_FOUND, message = "Method not found: " + method } }

func _new_session_id() -> String:
	var crypto : Crypto = Crypto.new()
	return crypto.generate_random_bytes(16).hex_encode()
