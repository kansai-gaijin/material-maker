extends Node
class_name MMMcpHttpServer

## Minimal HTTP/1.1 server used by the built-in MCP server.
##
## It only accepts loopback connections, understands Content-Length bodies,
## supports keep-alive and hands each complete request to `handler`, a
## Callable that takes a request Dictionary and returns (possibly after
## awaiting) a response Dictionary { status, headers, body }.
## Everything runs on the main thread, polled from _process, so request
## handlers may freely touch the scene tree.

const MAX_HEADER_SIZE : int = 64 * 1024
const MAX_BODY_SIZE : int = 64 * 1024 * 1024
const IDLE_TIMEOUT_MSEC : int = 30_000
const KEEP_ALIVE_HINT_SEC : int = 25

const STATUS_TEXT : Dictionary = {
	200: "OK", 202: "Accepted", 204: "No Content", 400: "Bad Request",
	401: "Unauthorized", 403: "Forbidden", 404: "Not Found",
	405: "Method Not Allowed", 411: "Length Required", 413: "Payload Too Large",
	415: "Unsupported Media Type", 500: "Internal Server Error"
}

class Connection:
	extends RefCounted
	var peer : StreamPeerTCP
	var buffer : PackedByteArray = PackedByteArray()
	var scan_from : int = 0
	var busy : bool = false
	var closed : bool = false
	var last_activity : int = 0

var handler : Callable
var bind_address : String = "127.0.0.1"
var port : int = 0

var _server : TCPServer = null
var _connections : Array[Connection] = []


func start(p_port : int, p_bind_address : String = "127.0.0.1") -> Error:
	stop()
	port = p_port
	bind_address = p_bind_address
	_server = TCPServer.new()
	var err : Error = _server.listen(port, bind_address)
	if err != OK:
		_server = null
		return err
	set_process(true)
	return OK

func stop() -> void:
	for c in _connections:
		c.closed = true
		c.peer.disconnect_from_host()
	_connections.clear()
	if _server != null:
		_server.stop()
		_server = null
	set_process(false)

func is_listening() -> bool:
	return _server != null and _server.is_listening()

func _exit_tree() -> void:
	stop()

func _process(_delta : float) -> void:
	if _server == null:
		return
	while _server.is_connection_available():
		var c : Connection = Connection.new()
		c.peer = _server.take_connection()
		c.peer.set_no_delay(true)
		c.last_activity = Time.get_ticks_msec()
		_connections.append(c)
	var now : int = Time.get_ticks_msec()
	for c in _connections.duplicate():
		if c.closed:
			_connections.erase(c)
			continue
		c.peer.poll()
		var status : int = c.peer.get_status()
		if status != StreamPeerTCP.STATUS_CONNECTED:
			if not c.busy:
				_close(c)
			continue
		var available : int = c.peer.get_available_bytes()
		if available > 0:
			var chunk : Array = c.peer.get_partial_data(available)
			if chunk[0] == OK:
				c.buffer.append_array(chunk[1])
				c.last_activity = now
		if not c.busy and not c.buffer.is_empty():
			_try_dispatch(c)
		elif not c.busy and now - c.last_activity > IDLE_TIMEOUT_MSEC:
			_close(c)

func _close(c : Connection) -> void:
	c.closed = true
	c.peer.disconnect_from_host()
	_connections.erase(c)

func _find_header_end(c : Connection) -> int:
	var b : PackedByteArray = c.buffer
	var i : int = max(c.scan_from, 0)
	while i + 3 < b.size():
		if b[i] == 13 and b[i+1] == 10 and b[i+2] == 13 and b[i+3] == 10:
			return i
		i += 1
	c.scan_from = max(b.size() - 3, 0)
	return -1

func _try_dispatch(c : Connection) -> void:
	var header_end : int = _find_header_end(c)
	if header_end == -1:
		if c.buffer.size() > MAX_HEADER_SIZE:
			_send_and_close(c, 413, "Headers too large")
		return
	var head : String = c.buffer.slice(0, header_end).get_string_from_ascii()
	var lines : PackedStringArray = head.split("\r\n")
	var request_line : PackedStringArray = lines[0].split(" ")
	if request_line.size() < 3:
		_send_and_close(c, 400, "Malformed request line")
		return
	var headers : Dictionary = {}
	for i in range(1, lines.size()):
		var colon : int = lines[i].find(":")
		if colon > 0:
			headers[lines[i].left(colon).strip_edges().to_lower()] = lines[i].substr(colon+1).strip_edges()
	if headers.get("transfer-encoding", "").to_lower().contains("chunked"):
		_send_and_close(c, 411, "Chunked request bodies are not supported, send Content-Length")
		return
	var content_length : int = 0
	if headers.has("content-length"):
		var cl : String = headers["content-length"]
		if not cl.is_valid_int() or cl.to_int() < 0:
			_send_and_close(c, 400, "Invalid Content-Length")
			return
		content_length = cl.to_int()
	if content_length > MAX_BODY_SIZE:
		_send_and_close(c, 413, "Request body too large")
		return
	var body_start : int = header_end + 4
	if c.buffer.size() < body_start + content_length:
		return # Wait for the rest of the body
	var body : PackedByteArray = c.buffer.slice(body_start, body_start + content_length)
	c.buffer = c.buffer.slice(body_start + content_length)
	c.scan_from = 0
	var path : String = request_line[1]
	var query : String = ""
	var q : int = path.find("?")
	if q != -1:
		query = path.substr(q+1)
		path = path.left(q)
	var request : Dictionary = {
		method = request_line[0].to_upper(),
		path = path,
		query = query,
		version = request_line[2],
		headers = headers,
		body = body.get_string_from_utf8(),
		remote_address = c.peer.get_connected_host()
	}
	c.busy = true
	_handle(c, request)

func _handle(c : Connection, request : Dictionary) -> void:
	var response = null
	if handler.is_valid():
		response = await handler.call(request)
	if not response is Dictionary:
		response = { status = 500, body = "No handler" }
	c.busy = false
	if c.closed:
		return
	var keep_alive : bool = request.version == "HTTP/1.1" and request.headers.get("connection", "").to_lower() != "close"
	_write_response(c, response, keep_alive)
	if not keep_alive:
		_close(c)
	else:
		c.last_activity = Time.get_ticks_msec()

func _send_and_close(c : Connection, status : int, message : String) -> void:
	_write_response(c, { status = status, headers = { "Content-Type": "text/plain; charset=utf-8" }, body = message }, false)
	_close(c)

func _write_response(c : Connection, response : Dictionary, keep_alive : bool) -> void:
	var status : int = response.get("status", 200)
	var body = response.get("body", "")
	var body_bytes : PackedByteArray = body if body is PackedByteArray else str(body).to_utf8_buffer()
	var header_text : String = "HTTP/1.1 %d %s\r\n" % [ status, STATUS_TEXT.get(status, "Unknown") ]
	var headers : Dictionary = response.get("headers", {})
	for k in headers.keys():
		header_text += "%s: %s\r\n" % [ k, headers[k] ]
	header_text += "Content-Length: %d\r\n" % body_bytes.size()
	if keep_alive:
		header_text += "Connection: keep-alive\r\nKeep-Alive: timeout=%d\r\n" % KEEP_ALIVE_HINT_SEC
	else:
		header_text += "Connection: close\r\n"
	header_text += "\r\n"
	var data : PackedByteArray = header_text.to_ascii_buffer()
	data.append_array(body_bytes)
	c.peer.put_data(data)
