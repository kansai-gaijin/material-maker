extends Node
class_name MMMcpTools

## The tools exposed by Material Maker's built-in MCP server.
##
## Every tool works on the live editor: graph edits go through MMGraphEdit's
## own undo-aware functions (create_nodes, on_connect_node, set_node_parameters,
## ...), so they appear immediately in the open window and the person can
## undo them like any other edit. One tool call = one undo step.

const MAX_RENDER_SIZE : int = 4096
const MAX_RETURNED_IMAGE_SIZE : int = 1024
const LAYOUT_COLUMN_WIDTH : float = 280.0
const LAYOUT_ROW_HEIGHT : float = 160.0

## Node types implemented in code rather than as .mmg files
const BUILTIN_TYPES : Array[String] = [ "buffer", "image", "text", "iterate_buffer", "meshmap", "sdf",
	"switch", "export", "comment", "comment_line", "webcam", "debug", "reroute", "portal", "autoexport" ]
const LIBRARY_ITEM_META_KEYS : Array[String] = [ "display_name", "icon", "icon_data", "tree_item", "library_index", "idx" ]
const ANY_SLOT_TYPE : int = 42

var server : Node = null
var _definitions : Array = []
var _preview_viewport : SubViewport = null
var _busy : bool = false


# ---------------------------------------------------------------------------
# Registry
# ---------------------------------------------------------------------------

static func _schema(properties : Dictionary, required : Array = []) -> Dictionary:
	var s : Dictionary = { type = "object", properties = properties, additionalProperties = false }
	if not required.is_empty():
		s.required = required
	return s

const P_PROJECT : Dictionary = { type = "integer", minimum = 0, description = "Project tab index from get_status. Defaults to the project shown in the editor." }
const P_GRAPH : Dictionary = { type = "string", description = "Group (subgraph) path such as \"my_group\" or \"outer/inner\"; \"\" is the top-level graph. Defaults to the graph currently shown in the editor. Editing tools switch the editor to this graph." }
const P_POSITION : Dictionary = { type = "object", properties = { x = { type = "number" }, y = { type = "number" } }, required = [ "x", "y" ], description = "Graph-space position of the node's top-left corner." }

func get_tool_definitions() -> Array:
	if not _definitions.is_empty():
		return _definitions
	var ro : Dictionary = { readOnlyHint = true, openWorldHint = false }
	var edit : Dictionary = { readOnlyHint = false, destructiveHint = false, openWorldHint = false }
	var edit_idem : Dictionary = { readOnlyHint = false, destructiveHint = false, idempotentHint = true, openWorldHint = false }
	var destructive : Dictionary = { readOnlyHint = false, destructiveHint = true, openWorldHint = false }
	_definitions = [
		_def("get_status", "Get status", "Material Maker version, MCP endpoint, open project tabs (index, kind, file, unsaved changes), the current tab and the graph shown in the editor.",
			_schema({}), ro),
		_def("list_node_types", "List node types", "List the node type names that add_nodes accepts (e.g. \"bricks\", \"perlin\", \"blend2\", \"colorize\"). Prefer search_library for discovery; it is curated and includes useful presets.",
			_schema({ filter = { type = "string", description = "Case-insensitive substring filter on the type name or its label." }, limit = { type = "integer", minimum = 1, maximum = 1000, default = 200 } }), ro),
		_def("search_library", "Search node library", "Search the node library shown in the Library panel (e.g. \"brick\", \"noise\", \"blend\", \"normal map\"). Returns library item paths usable as add_nodes `library_item`, plus the node type behind each.",
			_schema({ query = { type = "string", description = "Words to search for. Empty lists everything." }, limit = { type = "integer", minimum = 1, maximum = 500, default = 30 } }), ro),
		_def("describe_node_type", "Describe node type", "Describe a node type or library item without adding it: parameters (type, default, range, enum values), input ports and output ports with their indices and data types.",
			_schema({ type = { type = "string", description = "Node type name, e.g. \"bricks\"." }, library_item = { type = "string", description = "Library item path from search_library, e.g. \"Pattern/Bricks\"." } }), ro),
		_def("get_graph", "Get graph", "List the nodes of a graph (name, type, position, parameter values, ports and what feeds each input) and its connections.",
			_schema({ project = P_PROJECT, graph = P_GRAPH, include_parameters = { type = "boolean", default = true } }), ro),
		_def("get_node", "Get node", "Full details of one node in a graph: parameter definitions with current values, ports, connections and description.",
			_schema({ project = P_PROJECT, graph = P_GRAPH, node = { type = "string" } }, [ "node" ]), ro),
		_def("render_output", "Render node output", "Render one output of a node to an image and return it (PNG). Optionally save the full-resolution render to a file (.png, .exr, .jpg or .webp).",
			_schema({ project = P_PROJECT, graph = P_GRAPH, node = { type = "string" }, output = { type = "integer", minimum = 0, default = 0 },
				size = { type = "integer", minimum = 16, maximum = MAX_RENDER_SIZE, default = 512, description = "Render resolution in pixels (square)." },
				save_path = { type = "string", description = "Absolute file path to also write the full-resolution image to." },
				return_image = { type = "boolean", default = true, description = "Return the image in the result (downscaled to at most 1024 px)." } }, [ "node" ]),
			{ readOnlyHint = false, destructiveHint = false, idempotentHint = true, openWorldHint = false }),
		_def("render_material_preview", "Render material preview", "Render the project's material on a 3D object (sphere, cube, cylinder, or the object and camera currently set in the 3D preview panel) and return the image.",
			_schema({ project = P_PROJECT, shape = { "type": "string", "enum": [ "sphere", "cube", "cylinder", "current" ], "default": "sphere" }, size = { type = "integer", minimum = 64, maximum = 2048, default = 512 } }), ro),
		_def("capture_view", "Capture view", "Screenshot part of the Material Maker window as the person sees it: the whole window, the graph editor, the 2D preview or the 3D preview panel.",
			_schema({ area = { "type": "string", "enum": [ "window", "graph", "preview_2d", "preview_3d" ], "default": "window" } }), ro),
		_def("get_console", "Get console", "Read the latest lines of Material Maker's console (shader errors, export messages, MCP activity).",
			_schema({ lines = { type = "integer", minimum = 1, maximum = 500, default = 50 } }), ro),
		_def("list_export_targets", "List export targets", "List the export profiles available for the project's material (e.g. \"Godot/Godot 4 Standard\", \"Unity/3D\", \"Unreal/Unreal 5\", \"Blender\").",
			_schema({ project = P_PROJECT }), ro),
		_def("new_material", "New material", "Open a new, empty material project in a new tab and make it current.",
			_schema({}), edit),
		_def("open_project", "Open project", "Open a .ptex material or .mmpp paint project from disk in a tab and make it current.",
			_schema({ path = { type = "string", description = "Absolute path of the file." } }, [ "path" ]), edit),
		_def("save_project", "Save project", "Save a project. Without `path` it saves to the project's existing file; with `path` (an absolute .ptex path) it saves there, like Save As.",
			_schema({ project = P_PROJECT, path = { type = "string" } }), edit_idem),
		_def("switch_project", "Switch project", "Show another open project tab in the editor.",
			_schema({ project = P_PROJECT }, [ "project" ]), edit_idem),
		_def("close_project", "Close project", "Close a project tab. Refuses to close a project with unsaved changes unless discard_changes is true.",
			_schema({ project = P_PROJECT, discard_changes = { type = "boolean", default = false } }, [ "project" ]), destructive),
		_def("open_graph", "Open graph", "Show a group (subgraph) in the graph editor, or \"\" for the top-level graph.",
			_schema({ project = P_PROJECT, graph = P_GRAPH }, [ "graph" ]), edit_idem),
		_def("add_nodes", "Add nodes", "Add one or more nodes and optionally connect them, as a single undo step. Each node gets a local `id` that connections may reference; existing nodes are referenced by name. The final (possibly renamed) node names are returned. Without positions, new nodes are laid out left of the existing ones following their connections.",
			_schema({
				project = P_PROJECT, graph = P_GRAPH,
				nodes = { type = "array", minItems = 1, items = { type = "object", additionalProperties = false, properties = {
					id = { type = "string", description = "Preferred node name and reference for connections. Defaults to the type name." },
					type = { type = "string", description = "Node type from list_node_types / search_library." },
					library_item = { type = "string", description = "Library item path from search_library (uses that preset's parameters). Use either type or library_item." },
					parameters = { type = "object", description = "Parameter values, see describe_node_type. Colors accept \"#rrggbb\", enums accept their label." },
					position = P_POSITION } } },
				connections = { type = "array", items = { type = "object", additionalProperties = false, properties = {
					from = { type = "string" }, from_port = { type = "integer", minimum = 0, default = 0 },
					to = { type = "string" }, to_port = { type = "integer", minimum = 0, default = 0 } }, required = [ "from", "to" ] } }
				}, [ "nodes" ]), edit),
		_def("delete_nodes", "Delete nodes", "Delete nodes (and their connections) from a graph, as a single undo step. The Material node cannot be deleted.",
			_schema({ project = P_PROJECT, graph = P_GRAPH, nodes = { type = "array", minItems = 1, items = { type = "string" } } }, [ "nodes" ]), destructive),
		_def("connect_nodes", "Connect nodes", "Connect output ports to input ports. An input accepts one connection, so an existing one is replaced. Port data types must be compatible.",
			_schema({ project = P_PROJECT, graph = P_GRAPH, connections = { type = "array", minItems = 1, items = { type = "object", additionalProperties = false, properties = {
				from = { type = "string" }, from_port = { type = "integer", minimum = 0, default = 0 },
				to = { type = "string" }, to_port = { type = "integer", minimum = 0, default = 0 } }, required = [ "from", "to" ] } } }, [ "connections" ]), edit),
		_def("disconnect_nodes", "Disconnect nodes", "Remove the connections feeding the given input ports.",
			_schema({ project = P_PROJECT, graph = P_GRAPH, inputs = { type = "array", minItems = 1, items = { type = "object", additionalProperties = false, properties = {
				node = { type = "string" }, port = { type = "integer", minimum = 0, default = 0 } }, required = [ "node" ] } } }, [ "inputs" ]), destructive),
		_def("set_parameters", "Set parameters", "Set parameter values on a node, as a single undo step. Numbers for float/int/size, booleans, enum index or label, colors as \"#rrggbb[aa]\" or {r,g,b,a}, gradients as [{pos, color}] stops. Float parameters also accept Material Maker expressions such as \"$time\".",
			_schema({ project = P_PROJECT, graph = P_GRAPH, node = { type = "string" }, parameters = { type = "object" } }, [ "node", "parameters" ]), edit_idem),
		_def("move_nodes", "Move nodes", "Move nodes to new graph positions.",
			_schema({ project = P_PROJECT, graph = P_GRAPH, positions = { type = "object", description = "Map of node name to {x, y}.", additionalProperties = P_POSITION } }, [ "positions" ]), edit_idem),
		_def("randomize_seed", "Randomize seed", "Give a node with randomness a new seed (or the given one), changing its random variation.",
			_schema({ project = P_PROJECT, graph = P_GRAPH, node = { type = "string" }, seed = { type = "number", minimum = 0, maximum = 1, description = "Seed between 0 and 1. Random if omitted." } }, [ "node" ]), edit),
		_def("create_group", "Create group", "Group nodes into a new subgraph (like Ctrl+G). Returns the group's name and path.",
			_schema({ project = P_PROJECT, graph = P_GRAPH, nodes = { type = "array", minItems = 1, items = { type = "string" } }, label = { type = "string" } }, [ "nodes" ]), edit),
		_def("set_preview", "Set 2D preview", "Show a node output in the 2D preview panel (slot 0) or the second 2D preview panel (slot 1).",
			_schema({ project = P_PROJECT, graph = P_GRAPH, node = { type = "string" }, output = { type = "integer", minimum = 0, default = 0 }, slot = { type = "integer", minimum = 0, maximum = 1, default = 0 }, lock = { type = "boolean", default = false, description = "Lock the preview so clicking other nodes does not replace it." } }, [ "node" ]), edit_idem),
		_def("undo", "Undo", "Undo the last change in a project (any change, made by the person or an agent).",
			_schema({ project = P_PROJECT }), edit),
		_def("redo", "Redo", "Redo the last undone change in a project.",
			_schema({ project = P_PROJECT }), edit),
		_def("export_material", "Export material", "Export the project's material textures and engine files with an export profile from list_export_targets, without dialogs. Existing files that the profile normally asks before overwriting are kept.",
			_schema({ project = P_PROJECT, target = { type = "string", description = "Export profile, e.g. \"Godot/Godot 4 Standard\"." },
				path = { type = "string", description = "Absolute path prefix, e.g. C:/exports/bricks — files are written as bricks_albedo.png etc. An extension, if given, is removed." },
				size = { type = "integer", minimum = 16, maximum = 16384, description = "Texture size in pixels. Defaults to the material's size." },
				include_export_nodes = { type = "boolean", default = false, description = "Also run the graph's Export nodes." } }, [ "target", "path" ]),
			{ readOnlyHint = false, destructiveHint = true, idempotentHint = true, openWorldHint = false }),
	]
	return _definitions

func _def(name : String, title : String, description : String, input_schema : Dictionary, annotations : Dictionary) -> Dictionary:
	var a : Dictionary = annotations.duplicate()
	a.title = title
	return { name = name, title = title, description = description, inputSchema = input_schema, annotations = a, handler = Callable(self, "_tool_" + name) }

func call_tool(definition : Dictionary, arguments : Dictionary) -> Dictionary:
	var schema : Dictionary = definition.inputSchema
	for r in schema.get("required", []):
		if not arguments.has(r):
			return _fail("Missing required argument `%s`." % r)
	for k in arguments.keys():
		if not schema.properties.has(k):
			return _fail("Unknown argument `%s`. Valid arguments: %s." % [ k, ", ".join(PackedStringArray(schema.properties.keys())) ])
	if mm_globals.main_window == null:
		return _fail("Material Maker's main window is not ready yet.")
	# One tool call at a time: tools await renders and frames, and two editing
	# calls interleaving on the same graph would corrupt each other's undo steps.
	while _busy:
		await get_tree().process_frame
	_busy = true
	var edits : bool = not definition.annotations.get("readOnlyHint", false)
	if edits:
		mm_globals.set_tip_text("MCP: " + definition.title, 3, 1)
	var result = await definition.handler.call(arguments)
	if edits:
		# Let the editor's own deferred reactions (selection, previews) run
		# before another call can change the graph again.
		await get_tree().process_frame
		await get_tree().process_frame
	_busy = false
	if not result is Dictionary:
		return _fail("Tool `%s` failed unexpectedly, see the Material Maker console." % definition.name)
	return result


# ---------------------------------------------------------------------------
# Result helpers
# ---------------------------------------------------------------------------

func _ok(data : Dictionary, images : Array = []) -> Dictionary:
	var safe = _safe(data)
	var content : Array = [ { type = "text", text = JSON.stringify(safe, "  ", false) } ]
	for image in images:
		content.append(image)
	return { content = content, structuredContent = safe, isError = false }

func _fail(message : String) -> Dictionary:
	return { content = [ { type = "text", text = message } ], isError = true }

static func _image_content(image : Image) -> Dictionary:
	return { type = "image", data = Marshalls.raw_to_base64(_to_8bit(image).save_png_to_buffer()), mimeType = "image/png" }

static func _to_8bit(image : Image) -> Image:
	if image.get_format() in [ Image.FORMAT_L8, Image.FORMAT_LA8, Image.FORMAT_RGB8, Image.FORMAT_RGBA8 ]:
		return image
	var copy : Image = image.duplicate()
	if copy.is_compressed():
		copy.decompress()
	copy.convert(Image.FORMAT_RGBA8)
	return copy

static func _downscaled(image : Image, max_size : int) -> Image:
	if image.get_width() <= max_size and image.get_height() <= max_size:
		return image
	var copy : Image = _to_8bit(image).duplicate()
	var scale : float = float(max_size) / max(copy.get_width(), copy.get_height())
	copy.resize(max(1, int(copy.get_width() * scale)), max(1, int(copy.get_height() * scale)), Image.INTERPOLATE_LANCZOS)
	return copy

## Converts engine values to something JSON can represent faithfully.
static func _safe(v):
	match typeof(v):
		TYPE_DICTIONARY:
			var d : Dictionary = {}
			for k in v.keys():
				d[str(k)] = _safe(v[k])
			return d
		TYPE_ARRAY, TYPE_PACKED_BYTE_ARRAY, TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_INT64_ARRAY, TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY, TYPE_PACKED_STRING_ARRAY, TYPE_PACKED_VECTOR2_ARRAY, TYPE_PACKED_VECTOR3_ARRAY, TYPE_PACKED_COLOR_ARRAY:
			var a : Array = []
			for e in v:
				a.append(_safe(e))
			return a
		TYPE_VECTOR2, TYPE_VECTOR2I:
			return { x = v.x, y = v.y }
		TYPE_VECTOR3, TYPE_VECTOR3I:
			return { x = v.x, y = v.y, z = v.z }
		TYPE_COLOR:
			return { r = v.r, g = v.g, b = v.b, a = v.a }
		TYPE_FLOAT:
			if is_nan(v) or is_inf(v):
				return null
			return v
		TYPE_STRING_NAME, TYPE_NODE_PATH:
			return str(v)
		TYPE_OBJECT:
			if v == null:
				return null
			if v.has_method("serialize"):
				return _safe(v.serialize())
			return str(v)
		TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_STRING:
			return v
	return str(v)


# ---------------------------------------------------------------------------
# Context helpers
# ---------------------------------------------------------------------------

func _tabs():
	return mm_globals.main_window.projects_panel.get_projects()

## Resolves project / graph arguments. Returns { project, index, graph_edit, graph } or { error }.
## When `show` is true the editor switches to the requested graph, which editing needs.
func _context(args : Dictionary, need_graph : bool = true, show : bool = false) -> Dictionary:
	var tabs = _tabs()
	if tabs.get_tab_count() == 0:
		return { error = "No project is open. Use new_material or open_project." }
	var index : int = tabs.current_tab
	if args.has("project"):
		index = int(args.project)
	if index < 0 or index >= tabs.get_tab_count():
		return { error = "No project tab %d (there are %d, see get_status)." % [ index, tabs.get_tab_count() ] }
	var project = tabs.get_tab(index)
	var ctx : Dictionary = { project = project, index = index, graph_edit = null, graph = null }
	if not need_graph:
		return ctx
	var graph_edit = project.get_graph_edit() if project.has_method("get_graph_edit") else null
	if graph_edit == null or graph_edit.top_generator == null:
		return { error = "Project %d has no node graph." % index }
	ctx.graph_edit = graph_edit
	var graph = graph_edit.generator
	if args.has("graph"):
		var path : String = str(args.graph).strip_edges().trim_prefix("/").trim_suffix("/")
		if path == "" or path == "top":
			graph = graph_edit.top_generator
		else:
			graph = graph_edit.get_node_from_hier_name(path)
			if graph == null or not graph is MMGenGraph:
				return { error = "No group `%s` in project %d. Group paths are listed by get_graph (nodes with is_group)." % [ path, index ] }
	if show and graph != graph_edit.generator:
		_show_graph(graph_edit, graph)
	ctx.graph = graph
	return ctx

func _show_graph(graph_edit, graph : MMGenGraph) -> void:
	if graph == graph_edit.top_generator:
		# edit_subgraph() would flag the top graph as an editable template
		graph_edit.generator.scroll_offset = graph_edit.scroll_offset
		graph_edit.update_view(graph)
	else:
		graph_edit.edit_subgraph(graph)

func _find_generator(graph : Node, node_name : String) -> MMGenBase:
	if node_name == "" or node_name.contains("/"):
		return null
	var n = graph.get_node_or_null(NodePath(node_name))
	return n if n is MMGenBase else null

func _graph_node(graph_edit, generator : MMGenBase) -> GraphElement:
	return graph_edit.get_node_or_null(NodePath("node_" + str(generator.name)))

func _missing_node(graph : Node, node_name : String) -> Dictionary:
	var names : PackedStringArray = []
	for c in graph.get_children():
		if c is MMGenBase:
			names.append(str(c.name))
	return _fail("No node `%s` in graph `%s`. Nodes: %s." % [ node_name, graph.get_hier_name(), ", ".join(names) ])

static func _type_of(generator : MMGenBase) -> String:
	if generator.model != null:
		return str(generator.model)
	return generator.get_type()

static func _slot_type(io_type : String) -> int:
	if mm_io_types.types.has(io_type):
		return int(mm_io_types.types[io_type].slot_type)
	return -1

static func _io_types_compatible(output_type : String, input_type : String) -> bool:
	var a : int = _slot_type(output_type)
	var b : int = _slot_type(input_type)
	return a == b or a == ANY_SLOT_TYPE or b == ANY_SLOT_TYPE

func _is_known_type(type_name : String) -> bool:
	return mm_loader.predefined_generators.has(type_name) or type_name in BUILTIN_TYPES

static func _sanitize_name(n : String) -> String:
	for c in [ ".", ":", "@", "/", "\"", "%", " " ]:
		n = n.replace(c, "_")
	return n

func _type_description(type_name : String) -> String:
	var g = mm_loader.predefined_generators.get(type_name)
	if g is Dictionary:
		for d in [ g, g.get("shader_model", {}) ]:
			if d is Dictionary:
				for k in [ "shortdesc", "longdesc" ]:
					if d.has(k) and str(d[k]) != "":
						return str(d[k])
	return ""

func _type_label(type_name : String) -> String:
	var g = mm_loader.predefined_generators.get(type_name)
	if g is Dictionary:
		if g.get("shader_model") is Dictionary and g.shader_model.has("name"):
			return str(g.shader_model.name)
		if g.has("label"):
			return str(g.label)
	return type_name


# ---------------------------------------------------------------------------
# Node descriptions
# ---------------------------------------------------------------------------

func _ports(generator : MMGenBase, include_sources : bool) -> Dictionary:
	var inputs : Array = []
	var input_defs : Array = generator.get_input_defs()
	var graph = generator.get_parent()
	for i in input_defs.size():
		var d : Dictionary = input_defs[i]
		var port : Dictionary = { index = i, name = d.get("name", ""), type = d.get("type", "") }
		if d.has("label") and str(d.label) != "":
			port.label = str(d.label)
		if d.has("shortdesc") and str(d.shortdesc) != "":
			port.description = str(d.shortdesc)
		if include_sources and graph is MMGenGraph:
			for c in graph.connections:
				if c.to == generator.name and int(c.to_port) == i:
					port.source = { node = c.from, port = int(c.from_port) }
					break
		inputs.append(port)
	var outputs : Array = []
	var output_defs : Array = generator.get_output_defs()
	for i in output_defs.size():
		var d : Dictionary = output_defs[i]
		var port : Dictionary = { index = i, type = d.get("type", "") }
		for k in [ "shortdesc", "name", "label" ]:
			if d.has(k) and str(d[k]) != "":
				port.label = str(d[k])
				break
		if include_sources and graph is MMGenGraph:
			var targets : Array = []
			for c in graph.connections:
				if c.from == generator.name and int(c.from_port) == i:
					targets.append({ node = c.to, port = int(c.to_port) })
			if not targets.is_empty():
				port.targets = targets
		outputs.append(port)
	return { inputs = inputs, outputs = outputs }

func _parameter_values(generator : MMGenBase) -> Dictionary:
	var values : Dictionary = {}
	for p in generator.get_parameter_defs():
		if p.has("name"):
			values[p.name] = MMType.serialize_value(generator.get_parameter(p.name))
	return values

func _parameter_definitions(generator : MMGenBase, with_values : bool) -> Array:
	var defs : Array = []
	for p in generator.get_parameter_defs():
		if not p.has("name"):
			continue
		var d : Dictionary = { name = p.name, type = p.get("type", "") }
		for k in [ "label", "shortdesc", "longdesc", "min", "max", "step", "default", "first", "last" ]:
			if p.has(k) and str(p[k]) != "":
				d[k] = p[k]
		if p.get("type") == "enum" and p.get("values") is Array:
			var values : Array = []
			for i in p.values.size():
				var v = p.values[i]
				values.append({ index = i, label = v.get("name", ""), value = v.get("value", "") })
			d.values = values
		elif p.get("type") == "size":
			d.note = "Value v means a size of 2^(v) pixels (e.g. 10 = 1024)."
		if with_values:
			d.value = MMType.serialize_value(generator.get_parameter(p.name))
		defs.append(d)
	return defs

func _node_summary(generator : MMGenBase, include_parameters : bool) -> Dictionary:
	var type_name : String = _type_of(generator)
	var d : Dictionary = { name = str(generator.name), type = type_name, label = generator.get_type_name(), position = generator.position }
	d.merge(_ports(generator, true))
	if include_parameters:
		d.parameters = _parameter_values(generator)
	if generator is MMGenGraph:
		d.is_group = true
		d.group_path = generator.get_hier_name()
		d.node_count = generator.get_child_count()
	if generator.has_randomness():
		d.seed = generator.seed_value
		if generator.is_seed_locked():
			d.seed_locked = true
	if generator.minimized:
		d.minimized = true
	return d


# ---------------------------------------------------------------------------
# Parameter value conversion
# ---------------------------------------------------------------------------

static func _parse_color(v):
	if v is String:
		var s : String = v.strip_edges()
		if not s.begins_with("#"):
			s = "#" + s
		if not s.is_valid_html_color():
			return null
		var c : Color = Color.html(s)
		return { type = "Color", r = c.r, g = c.g, b = c.b, a = c.a }
	if v is Array and v.size() >= 3:
		return { type = "Color", r = float(v[0]), g = float(v[1]), b = float(v[2]), a = float(v[3]) if v.size() > 3 else 1.0 }
	if v is Dictionary and v.has("r") and v.has("g") and v.has("b"):
		return { type = "Color", r = float(v.r), g = float(v.g), b = float(v.b), a = float(v.get("a", 1.0)) }
	return null

## Returns { value } (serialized, as stored in .ptex files) or { error }.
static func _convert_parameter(def : Dictionary, v) -> Dictionary:
	var t : String = def.get("type", "")
	match t:
		"float":
			if v is float or v is int:
				return { value = float(v) }
			if v is String:
				return { value = v } # expression such as "$time" or "0.5*$p"
			return { error = "expects a number or an expression string" }
		"size", "int":
			if v is float or v is int:
				return { value = int(v) }
			return { error = "expects an integer" }
		"boolean":
			if v is bool:
				return { value = v }
			if v is float or v is int:
				return { value = v != 0 }
			return { error = "expects true or false" }
		"enum":
			var values : Array = def.get("values", [])
			if v is float or v is int:
				if int(v) < 0 or int(v) >= values.size():
					return { error = "index out of range 0..%d" % (values.size() - 1) }
				return { value = int(v) }
			if v is String:
				for i in values.size():
					if str(values[i].get("name", "")).to_lower() == v.to_lower() or str(values[i].get("value", "")).to_lower() == v.to_lower():
						return { value = i }
			var labels : PackedStringArray = []
			for e in values:
				labels.append(str(e.get("name", "")))
			return { error = "expects an index or one of: " + ", ".join(labels) }
		"color":
			var c = _parse_color(v)
			if c == null:
				return { error = "expects \"#rrggbb[aa]\", [r,g,b,a] or {r,g,b,a}" }
			return { value = c }
		"gradient":
			if v is Dictionary and v.get("type") == "Gradient":
				return { value = v }
			if v is Array:
				var points : Array = []
				for stop in v:
					if not stop is Dictionary or not stop.has("pos"):
						return { error = "gradient stops must be {pos, color}" }
					var c = _parse_color(stop.get("color", stop))
					if c == null:
						return { error = "invalid color in gradient stop" }
					points.append({ pos = float(stop.pos), r = c.r, g = c.g, b = c.b, a = c.a })
				return { value = { type = "Gradient", interpolation = 1, points = points } }
			return { error = "expects a list of {pos, color} stops" }
	# curve, polygon, polyline, splines, lattice, pixels, file, string...: pass the serialized form through
	return { value = v }


# ---------------------------------------------------------------------------
# Read-only tools
# ---------------------------------------------------------------------------

func _project_info(index : int, project) -> Dictionary:
	var info : Dictionary = { index = index, kind = project.get_project_type() if project.has_method("get_project_type") else "unknown" }
	var path = project.get("save_path")
	info.path = path if path != null and str(path) != "" else null
	info.unsaved_changes = bool(project.get("need_save"))
	if project.has_method("get_graph_edit"):
		var graph_edit = project.get_graph_edit()
		if graph_edit != null and graph_edit.generator != null:
			info.shown_graph = graph_edit.generator.get_hier_name()
			info.node_count = graph_edit.top_generator.get_child_count() if graph_edit.top_generator != null else 0
	return info

func _tool_get_status(_args : Dictionary) -> Dictionary:
	var tabs = _tabs()
	var projects : Array = []
	for i in tabs.get_tab_count():
		projects.append(_project_info(i, tabs.get_tab(i)))
	return _ok({
		material_maker_version = ProjectSettings.get_setting("application/config/actual_release", ""),
		mcp_endpoint = server.get_url() if server != null else "",
		current_project = tabs.current_tab,
		projects = projects
	})

func _tool_list_node_types(args : Dictionary) -> Dictionary:
	var filter : String = str(args.get("filter", "")).to_lower()
	var limit : int = int(args.get("limit", 200))
	var result : Array = []
	var total : int = 0
	var names : Array = mm_loader.get_generator_list()
	for b in BUILTIN_TYPES:
		if not b in names:
			names.append(b)
	names.sort()
	for n in names:
		var label : String = _type_label(n)
		if filter != "" and not (filter in n.to_lower() or filter in label.to_lower()):
			continue
		total += 1
		if result.size() < limit:
			var entry : Dictionary = { type = n, label = label }
			var desc : String = _type_description(n)
			if desc != "":
				entry.description = desc
			result.append(entry)
	return _ok({ total = total, returned = result.size(), types = result })

func _tool_search_library(args : Dictionary) -> Dictionary:
	var query : String = str(args.get("query", ""))
	var limit : int = int(args.get("limit", 30))
	var items : Array = mm_globals.main_window.node_library_manager.get_items(query)
	items.sort_custom(func(a, b): return a.get("quality", 0.0) > b.get("quality", 0.0))
	var result : Array = []
	for i in items:
		if result.size() >= limit:
			break
		var item : Dictionary = i.item
		var entry : Dictionary = { library_item = i.name, label = item.get("display_name", i.name) }
		if item.has("type"):
			entry.type = item.type
			if not _is_known_type(str(item.type)):
				entry.note = "Prebuilt group: pass this library_item (not the type) to add_nodes / describe_node_type."
			var desc : String = _type_description(item.type)
			if desc != "":
				entry.description = desc
			if item.get("parameters") is Dictionary and not item.parameters.is_empty():
				entry.preset_parameters = item.parameters
		else:
			entry.type = "(multiple nodes)"
		result.append(entry)
	return _ok({ total = items.size(), returned = result.size(), items = result })

func _library_item_data(item_path : String) -> Dictionary:
	var found = mm_globals.main_window.node_library_manager.get_item(item_path)
	if found == null:
		return { error = "No library item `%s`. Use search_library to find item paths." % item_path }
	var data : Dictionary = found.item.duplicate(true)
	for k in LIBRARY_ITEM_META_KEYS:
		data.erase(k)
	if not data.has("type"):
		return { error = "Library item `%s` is a group of several nodes, which add_nodes cannot place. Use its node types individually." % item_path }
	return { data = data }

func _tool_describe_node_type(args : Dictionary) -> Dictionary:
	var data : Dictionary
	if args.has("library_item"):
		var r : Dictionary = _library_item_data(str(args.library_item))
		if r.has("error"):
			return _fail(r.error)
		data = r.data
	elif args.has("type"):
		if not _is_known_type(str(args.type)):
			if str(args.type) == "graph":
				return _fail("`graph` items are prebuilt groups; describe them with `library_item` (the path from search_library).")
			return _fail("Unknown node type `%s`. Use list_node_types or search_library." % args.type)
		data = { type = str(args.type) }
	else:
		return _fail("Give either `type` or `library_item`.")
	var generator : MMGenBase = await mm_loader.create_gen(data)
	if generator == null:
		return _fail("Material Maker could not create a `%s` node." % data.get("type", "?"))
	var info : Dictionary = {
		type = data.type,
		label = generator.get_type_name(),
		description = generator.get_description() if generator.get_description() != "" else _type_description(data.type),
		parameters = _parameter_definitions(generator, args.has("library_item")),
		has_randomness = generator.has_randomness()
	}
	info.merge(_ports(generator, false))
	generator.free()
	return _ok(info)

func _tool_get_graph(args : Dictionary) -> Dictionary:
	var ctx : Dictionary = _context(args)
	if ctx.has("error"):
		return _fail(ctx.error)
	var graph : MMGenGraph = ctx.graph
	var include_parameters : bool = args.get("include_parameters", true)
	var nodes : Array = []
	for c in graph.get_children():
		if c is MMGenBase:
			nodes.append(_node_summary(c, include_parameters))
	var connections : Array = []
	for c in graph.connections:
		connections.append({ from = c.from, from_port = int(c.from_port), to = c.to, to_port = int(c.to_port) })
	return _ok({
		project = ctx.index,
		graph = graph.get_hier_name(),
		label = graph.label,
		shown_in_editor = ctx.graph_edit.generator == graph,
		nodes = nodes,
		connections = connections
	})

func _tool_get_node(args : Dictionary) -> Dictionary:
	var ctx : Dictionary = _context(args)
	if ctx.has("error"):
		return _fail(ctx.error)
	var generator : MMGenBase = _find_generator(ctx.graph, str(args.node))
	if generator == null:
		return _missing_node(ctx.graph, str(args.node))
	var info : Dictionary = _node_summary(generator, false)
	info.parameters = _parameter_definitions(generator, true)
	var desc : String = generator.get_description()
	if desc == "":
		desc = _type_description(_type_of(generator))
	if desc != "":
		info.description = desc
	return _ok(info)

func _tool_render_output(args : Dictionary) -> Dictionary:
	var ctx : Dictionary = _context(args)
	if ctx.has("error"):
		return _fail(ctx.error)
	var generator : MMGenBase = _find_generator(ctx.graph, str(args.node))
	if generator == null:
		return _missing_node(ctx.graph, str(args.node))
	var output : int = int(args.get("output", 0))
	var output_count : int = generator.get_output_defs().size()
	if output < 0 or output >= output_count:
		return _fail("Node `%s` has %d output(s); output %d does not exist." % [ generator.name, output_count, output ])
	var size : int = clampi(int(args.get("size", 512)), 16, MAX_RENDER_SIZE)
	var image : Image = await generator.render_output(output, Vector2i(size, size))
	if image == null or image.is_empty():
		return _fail("Rendering `%s` output %d produced no image (see get_console for shader errors)." % [ generator.name, output ])
	var info : Dictionary = { node = str(generator.name), output = output, output_type = generator.get_output_defs()[output].get("type", ""), size = size }
	if args.has("save_path"):
		var err : Error = _save_image(image, str(args.save_path))
		if err != OK:
			return _fail("Could not write `%s`: %s" % [ args.save_path, error_string(err) ])
		info.saved_to = str(args.save_path)
	var images : Array = []
	if args.get("return_image", true):
		images.append(_image_content(_downscaled(image, MAX_RETURNED_IMAGE_SIZE)))
	return _ok(info, images)

func _save_image(image : Image, path : String) -> Error:
	if not path.is_absolute_path():
		return ERR_FILE_BAD_PATH
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	match path.get_extension().to_lower():
		"exr":
			return image.save_exr(path)
		"jpg", "jpeg":
			return _to_8bit(image).save_jpg(path, 0.92)
		"webp":
			return _to_8bit(image).save_webp(path)
		_:
			return _to_8bit(image).save_png(path)

func _tool_render_material_preview(args : Dictionary) -> Dictionary:
	var ctx : Dictionary = _context(args)
	if ctx.has("error"):
		return _fail(ctx.error)
	var material = ctx.graph_edit.top_generator.get_node_or_null("Material")
	if material == null or not material.has_method("set_3d_previews"):
		return _fail("Project %d has no Material node to preview." % ctx.index)
	var shape : String = str(args.get("shape", "sphere"))
	var index : int = [ "sphere", "cylinder", "cube", "current" ].find(shape)
	if index == -1:
		return _fail("Unknown shape `%s`." % shape)
	var size : int = clampi(int(args.get("size", 512)), 64, 2048)
	if _preview_viewport == null:
		_preview_viewport = load("res://material_maker/tools/share/preview_viewport.tscn").instantiate()
		_preview_viewport.name = "McpPreviewViewport"
		add_child(_preview_viewport)
		await get_tree().process_frame
	_preview_viewport.size = Vector2i(size, size)
	var materials : Dictionary[Node, Array] = { _preview_viewport: _preview_viewport.get_materials() }
	await material.set_3d_previews(materials)
	var pending : int = await _wait_for_renders()
	var texture : ImageTexture = await _preview_viewport.get_preview(index)
	if texture == null:
		return _fail("The preview could not be rendered.")
	var info : Dictionary = { project = ctx.index, shape = shape, size = size }
	if pending > 0:
		info.warning = "%d buffer(s) were still rendering; the preview may be incomplete." % pending
	return _ok(info, [ _image_content(texture.get_image()) ])

## Waits until Material Maker's buffer render queue is empty (or a timeout),
## so previews show finished textures. Returns the number still pending.
func _wait_for_renders(timeout_msec : int = 15000) -> int:
	var deadline : int = Time.get_ticks_msec() + timeout_msec
	var quiet_frames : int = 0
	while Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
		if mm_deps.get_render_queue_size() == 0 and not mm_deps.updating:
			quiet_frames += 1
			if quiet_frames >= 3:
				return 0
		else:
			quiet_frames = 0
	return mm_deps.get_render_queue_size()

func _tool_capture_view(args : Dictionary) -> Dictionary:
	var main_window = mm_globals.main_window
	var area : String = str(args.get("area", "window"))
	await _wait_for_renders(5000)
	await RenderingServer.frame_post_draw
	var image : Image = main_window.get_viewport().get_texture().get_image()
	var control : Control = null
	match area:
		"window":
			pass
		"graph":
			control = main_window.get_current_graph_edit()
		"preview_2d":
			control = main_window.get_panel("Preview2D")
		"preview_3d":
			control = main_window.get_panel("Preview3D")
		_:
			return _fail("Unknown area `%s`." % area)
	if area != "window":
		if control == null or not control.is_visible_in_tree():
			return _fail("The %s panel is not visible in the window right now." % area)
		var scale : float = get_tree().root.content_scale_factor
		var rect : Rect2i = Rect2i(control.get_global_rect().position * scale, control.get_global_rect().size * scale)
		rect = rect.intersection(Rect2i(Vector2i.ZERO, image.get_size()))
		if rect.size.x <= 0 or rect.size.y <= 0:
			return _fail("The %s panel has no visible area." % area)
		image = image.get_region(rect)
	return _ok({ area = area, width = image.get_width(), height = image.get_height() }, [ _image_content(_downscaled(image, 1600)) ])

func _tool_get_console(args : Dictionary) -> Dictionary:
	var count : int = clampi(int(args.get("lines", 50)), 1, 500)
	var history : Array = mm_logger.history
	return _ok({ lines = history.slice(max(0, history.size() - count)) })

func _tool_list_export_targets(args : Dictionary) -> Dictionary:
	var ctx : Dictionary = _context(args)
	if ctx.has("error"):
		return _fail(ctx.error)
	var material = ctx.graph_edit.get_material_node()
	if material == null:
		return _fail("Project %d has no exportable Material node." % ctx.index)
	var targets : Array = []
	for p in material.get_export_profiles():
		var t : Dictionary = { target = p }
		var ext : String = material.get_export_extension(p)
		if ext != "":
			t.extension = ext
		var last : String = material.get_export_path(p)
		if last != "":
			t.last_export_path = last
		targets.append(t)
	return _ok({ project = ctx.index, material_size = material.get_image_size(), targets = targets })


# ---------------------------------------------------------------------------
# Project tools
# ---------------------------------------------------------------------------

func _tool_new_material(_args : Dictionary) -> Dictionary:
	var main_window = mm_globals.main_window
	main_window.new_material()
	await get_tree().process_frame
	var tabs = _tabs()
	return _ok({ project = tabs.current_tab, info = _project_info(tabs.current_tab, tabs.get_tab(tabs.current_tab)) })

func _tool_open_project(args : Dictionary) -> Dictionary:
	var path : String = str(args.path).replace("\\", "/")
	if not path.is_absolute_path():
		return _fail("`path` must be absolute.")
	if not FileAccess.file_exists(path):
		return _fail("No file at `%s`." % path)
	var main_window = mm_globals.main_window
	var tabs = _tabs()
	for i in tabs.get_tab_count():
		var p = tabs.get_tab(i).get("save_path")
		if p != null and str(p).replace("\\", "/") == path:
			tabs.set_current_tab(i)
			return _ok({ project = i, already_open = true, info = _project_info(i, tabs.get_tab(i)) })
	match path.get_extension().to_lower():
		"ptex":
			var generator = await mm_loader.load_gen(path)
			if generator == null:
				return _fail("Material Maker could not load `%s`." % path)
			var graph_edit = main_window.create_new_graph_edit_if_needed()
			graph_edit.set_save_path(path)
			graph_edit.set_new_generator(generator)
			if main_window.current_mesh != null:
				generator.set_current_mesh(main_window.current_mesh)
			main_window.hierarchy.update_from_graph_edit(main_window.get_current_graph_edit())
			main_window.update_preview()
		"mmpp":
			if not main_window.do_load_painting(path):
				return _fail("Material Maker could not load `%s`." % path)
		_:
			return _fail("Only .ptex and .mmpp projects can be opened.")
	main_window.add_recent(path)
	await get_tree().process_frame
	return _ok({ project = tabs.current_tab, info = _project_info(tabs.current_tab, tabs.get_tab(tabs.current_tab)) })

func _tool_save_project(args : Dictionary) -> Dictionary:
	var ctx : Dictionary = _context(args, false)
	if ctx.has("error"):
		return _fail(ctx.error)
	var project = ctx.project
	var path : String = str(args.get("path", ""))
	if path == "":
		var existing = project.get("save_path")
		if existing == null or str(existing) == "":
			return _fail("Project %d has never been saved; give an absolute .ptex `path`." % ctx.index)
		path = str(existing)
	path = path.replace("\\", "/")
	if not path.is_absolute_path():
		return _fail("`path` must be absolute.")
	if not project.has_method("save_file"):
		# Paint projects only save to their own file
		if args.has("path"):
			return _fail("This kind of project can only be saved to its existing file.")
		if not await project.save():
			return _fail("Saving failed, see get_console.")
		return _ok({ project = ctx.index, path = path })
	if path.get_extension().to_lower() != "ptex":
		return _fail("Material projects are saved as .ptex files.")
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	if not await project.save_file(path):
		return _fail("Saving to `%s` failed." % path)
	mm_globals.main_window.add_recent(path)
	return _ok({ project = ctx.index, path = path })

func _tool_switch_project(args : Dictionary) -> Dictionary:
	var ctx : Dictionary = _context(args, false)
	if ctx.has("error"):
		return _fail(ctx.error)
	_tabs().set_current_tab(ctx.index)
	await get_tree().process_frame
	return _ok({ current_project = ctx.index })

func _tool_close_project(args : Dictionary) -> Dictionary:
	var ctx : Dictionary = _context(args, false)
	if ctx.has("error"):
		return _fail(ctx.error)
	var project = ctx.project
	if project.get("need_save") and not args.get("discard_changes", false):
		return _fail("Project %d has unsaved changes. Save it first or pass discard_changes: true." % ctx.index)
	if project.has_method("remove_crash_recovery_file"):
		project.remove_crash_recovery_file()
	_tabs().do_close_tab(ctx.index)
	mm_globals.main_window.update_menus()
	await get_tree().process_frame
	return _ok({ closed = ctx.index, remaining_projects = _tabs().get_tab_count() })


# ---------------------------------------------------------------------------
# Graph editing tools
# ---------------------------------------------------------------------------

func _tool_open_graph(args : Dictionary) -> Dictionary:
	var ctx : Dictionary = _context(args, true, true)
	if ctx.has("error"):
		return _fail(ctx.error)
	return _ok({ project = ctx.index, shown_graph = ctx.graph.get_hier_name(), label = ctx.graph.label })

## Places nodes without explicit positions left of the existing graph, in
## columns ordered by how far each node is from the end of the new chain.
func _auto_layout(graph : MMGenGraph, specs : Array, connections : Array) -> void:
	var pending : Array = []
	for s in specs:
		if not s.has("position"):
			pending.append(s.id)
	if pending.is_empty():
		return
	var min_x : float = INF
	var min_y : float = INF
	for c in graph.get_children():
		if c is MMGenBase:
			min_x = min(min_x, c.position.x)
			min_y = min(min_y, c.position.y)
	if min_x == INF:
		min_x = 0.0
		min_y = 0.0
	# depth = longest path to a node that is not feeding another new node
	var depth : Dictionary = {}
	for id in pending:
		depth[id] = 0
	for _iteration in pending.size():
		var changed : bool = false
		for c in connections:
			if depth.has(c.from) and depth.has(c.to) and depth[c.from] < depth[c.to] + 1 and depth[c.to] + 1 <= pending.size():
				depth[c.from] = depth[c.to] + 1
				changed = true
		if not changed:
			break
	var rows : Dictionary = {}
	for s in specs:
		if depth.has(s.id):
			var d : int = depth[s.id]
			var row : int = rows.get(d, 0)
			rows[d] = row + 1
			s.position = { x = min_x - LAYOUT_COLUMN_WIDTH * (d + 1), y = min_y + LAYOUT_ROW_HEIGHT * row }

func _tool_add_nodes(args : Dictionary) -> Dictionary:
	var ctx : Dictionary = _context(args, true, true)
	if ctx.has("error"):
		return _fail(ctx.error)
	var graph_edit = ctx.graph_edit
	var graph : MMGenGraph = ctx.graph
	if not args.nodes is Array or args.nodes.is_empty():
		return _fail("`nodes` must be a non-empty array.")
	var specs : Array = []
	var ids : Dictionary = {}
	for i in args.nodes.size():
		var n = args.nodes[i]
		if not n is Dictionary:
			return _fail("nodes[%d] must be an object." % i)
		var data : Dictionary
		if n.has("library_item"):
			var r : Dictionary = _library_item_data(str(n.library_item))
			if r.has("error"):
				return _fail("nodes[%d]: %s" % [ i, r.error ])
			data = r.data
		elif n.has("type"):
			var t : String = str(n.type)
			if not _is_known_type(t):
				return _fail("nodes[%d]: unknown node type `%s`. Use list_node_types or search_library." % [ i, t ])
			data = { type = t, parameters = {} }
		else:
			return _fail("nodes[%d] needs a `type` or a `library_item`." % i)
		var id : String = _sanitize_name(str(n.get("id", data.type)))
		if ids.has(id):
			return _fail("nodes[%d]: duplicate id `%s`; give each new node its own id." % [ i, id ])
		ids[id] = i
		data.name = id
		var spec : Dictionary = { id = id, data = data, parameters = n.get("parameters", {}) }
		if not spec.parameters is Dictionary:
			return _fail("nodes[%d].parameters must be an object." % i)
		if n.get("position") is Dictionary:
			spec.position = { x = float(n.position.get("x", 0.0)), y = float(n.position.get("y", 0.0)) }
		specs.append(spec)
	var connections : Array = []
	for c in args.get("connections", []):
		if not c is Dictionary or not c.has("from") or not c.has("to"):
			return _fail("Each connection needs `from` and `to`.")
		connections.append({ from = str(c.from), from_port = int(c.get("from_port", 0)), to = str(c.to), to_port = int(c.get("to_port", 0)) })
	for c in connections:
		for end in [ "from", "to" ]:
			if not ids.has(c[end]) and _find_generator(graph, c[end]) == null:
				return _fail("Connection %s `%s` is neither a new node id nor an existing node." % [ end, c[end] ])
	_auto_layout(graph, specs, connections)
	var data_nodes : Array = []
	for s in specs:
		s.data.node_position = s.position
		data_nodes.append(s.data)
	graph_edit.undoredo.start_group()
	var created : Array = await graph_edit.create_nodes({ nodes = data_nodes, connections = [] }, Vector2.ZERO)
	var names : Dictionary = {}
	for node in created:
		if node.get("generator") != null:
			names[str(node.generator.orig_name)] = str(node.generator.name)
	var warnings : Array = []
	var result_nodes : Array = []
	for s in specs:
		if not names.has(s.id):
			warnings.append("Node `%s` (%s) could not be created." % [ s.id, s.data.get("type", "") ])
			continue
		var generator : MMGenBase = _find_generator(graph, names[s.id])
		if not s.parameters.is_empty():
			var r : Dictionary = _apply_parameters(graph_edit, generator, s.parameters)
			warnings.append_array(r.errors)
		result_nodes.append({ id = s.id, name = names[s.id], type = _type_of(generator), position = generator.position })
	var made : Array = []
	for c in connections:
		var from_name : String = names.get(c.from, c.from)
		var to_name : String = names.get(c.to, c.to)
		var r : Dictionary = _connect(graph_edit, graph, from_name, c.from_port, to_name, c.to_port)
		if r.has("error"):
			warnings.append(r.error)
		else:
			made.append({ from = from_name, from_port = c.from_port, to = to_name, to_port = c.to_port })
	graph_edit.undoredo.end_group()
	var result : Dictionary = { graph = graph.get_hier_name(), nodes = result_nodes, connections = made }
	if not warnings.is_empty():
		result.warnings = warnings
	return _ok(result)

func _apply_parameters(graph_edit, generator : MMGenBase, parameters : Dictionary) -> Dictionary:
	var defs : Dictionary = {}
	for p in generator.get_parameter_defs():
		if p.has("name"):
			defs[p.name] = p
	var converted : Dictionary = {}
	var errors : Array = []
	for k in parameters.keys():
		if not defs.has(k):
			errors.append("`%s` has no parameter `%s` (parameters: %s)." % [ generator.name, k, ", ".join(PackedStringArray(defs.keys())) ])
			continue
		var r : Dictionary = _convert_parameter(defs[k], parameters[k])
		if r.has("error"):
			errors.append("`%s`.%s %s." % [ generator.name, k, r.error ])
		else:
			converted[k] = r.value
	if not converted.is_empty():
		graph_edit.set_node_parameters(generator, converted)
		var graph_node = _graph_node(graph_edit, generator)
		if graph_node != null and graph_node.has_method("update_node") and generator is MMGenGraph:
			graph_node.update_node()
	return { applied = converted.keys(), errors = errors }

func _connect(graph_edit, graph : MMGenGraph, from_name : String, from_port : int, to_name : String, to_port : int) -> Dictionary:
	var from : MMGenBase = _find_generator(graph, from_name)
	var to : MMGenBase = _find_generator(graph, to_name)
	if from == null or to == null:
		return { error = "Cannot connect %s:%d to %s:%d: node `%s` not found." % [ from_name, from_port, to_name, to_port, from_name if from == null else to_name ] }
	var outputs : Array = from.get_output_defs()
	var inputs : Array = to.get_input_defs()
	if from_port < 0 or from_port >= outputs.size():
		return { error = "`%s` has %d output(s); output %d does not exist." % [ from_name, outputs.size(), from_port ] }
	if to_port < 0 or to_port >= inputs.size():
		return { error = "`%s` has %d input(s); input %d does not exist." % [ to_name, inputs.size(), to_port ] }
	var out_type : String = outputs[from_port].get("type", "")
	var in_type : String = inputs[to_port].get("type", "")
	if not _io_types_compatible(out_type, in_type):
		return { error = "Cannot connect %s:%d (%s) to %s:%d (%s): incompatible types." % [ from_name, from_port, out_type, to_name, to_port, in_type ] }
	var from_node = _graph_node(graph_edit, from)
	var to_node = _graph_node(graph_edit, to)
	if from_node == null or to_node == null:
		return { error = "The graph editor is not showing the nodes `%s` and `%s`." % [ from_name, to_name ] }
	graph_edit.on_connect_node(str(from_node.name), from_port, str(to_node.name), to_port)
	for c in graph.connections:
		if c.to == to.name and int(c.to_port) == to_port and c.from == from.name and int(c.from_port) == from_port:
			return {}
	return { error = "Material Maker refused to connect %s:%d to %s:%d (it would create a loop)." % [ from_name, from_port, to_name, to_port ] }

func _tool_delete_nodes(args : Dictionary) -> Dictionary:
	var ctx : Dictionary = _context(args, true, true)
	if ctx.has("error"):
		return _fail(ctx.error)
	var graph_edit = ctx.graph_edit
	var graph : MMGenGraph = ctx.graph
	var targets : Array = []
	for n in args.nodes:
		var generator : MMGenBase = _find_generator(graph, str(n))
		if generator == null:
			return _missing_node(graph, str(n))
		if not generator.can_be_deleted() or generator.name in [ "Material", "Brush" ]:
			return _fail("Node `%s` cannot be deleted." % n)
		var graph_node = _graph_node(graph_edit, generator)
		if graph_node == null:
			return _fail("The graph editor is not showing node `%s`." % n)
		targets.append(graph_node)
	var prev : Dictionary = graph.serialize()
	for t in targets:
		graph_edit.do_remove_node(t)
	var next : Dictionary = graph.serialize()
	graph_edit.undoredo_create_step("Delete nodes", graph.get_hier_name(), prev, next)
	return _ok({ deleted = args.nodes })

func _tool_connect_nodes(args : Dictionary) -> Dictionary:
	var ctx : Dictionary = _context(args, true, true)
	if ctx.has("error"):
		return _fail(ctx.error)
	var made : Array = []
	var errors : Array = []
	ctx.graph_edit.undoredo.start_group()
	for c in args.connections:
		if not c is Dictionary or not c.has("from") or not c.has("to"):
			errors.append("Each connection needs `from` and `to`.")
			continue
		var r : Dictionary = _connect(ctx.graph_edit, ctx.graph, str(c.from), int(c.get("from_port", 0)), str(c.to), int(c.get("to_port", 0)))
		if r.has("error"):
			errors.append(r.error)
		else:
			made.append({ from = str(c.from), from_port = int(c.get("from_port", 0)), to = str(c.to), to_port = int(c.get("to_port", 0)) })
	ctx.graph_edit.undoredo.end_group()
	if made.is_empty() and not errors.is_empty():
		return _fail("\n".join(PackedStringArray(errors)))
	var result : Dictionary = { connected = made }
	if not errors.is_empty():
		result.errors = errors
	return _ok(result)

func _tool_disconnect_nodes(args : Dictionary) -> Dictionary:
	var ctx : Dictionary = _context(args, true, true)
	if ctx.has("error"):
		return _fail(ctx.error)
	var graph_edit = ctx.graph_edit
	var graph : MMGenGraph = ctx.graph
	var removed : Array = []
	var not_connected : Array = []
	graph_edit.undoredo.start_group()
	for input in args.inputs:
		var node_name : String = str(input.get("node", ""))
		var port : int = int(input.get("port", 0))
		var to : MMGenBase = _find_generator(graph, node_name)
		if to == null:
			graph_edit.undoredo.end_group()
			return _missing_node(graph, node_name)
		var source = null
		for c in graph.connections:
			if c.to == to.name and int(c.to_port) == port:
				source = c.duplicate()
				break
		if source == null:
			not_connected.append({ node = node_name, port = port })
			continue
		var from : MMGenBase = _find_generator(graph, source.from)
		graph_edit.on_disconnect_node(str(_graph_node(graph_edit, from).name), int(source.from_port), str(_graph_node(graph_edit, to).name), port)
		removed.append({ from = source.from, from_port = int(source.from_port), to = node_name, to_port = port })
	graph_edit.undoredo.end_group()
	var result : Dictionary = { disconnected = removed }
	if not not_connected.is_empty():
		result.not_connected = not_connected
	return _ok(result)

func _tool_set_parameters(args : Dictionary) -> Dictionary:
	var ctx : Dictionary = _context(args, true, true)
	if ctx.has("error"):
		return _fail(ctx.error)
	var generator : MMGenBase = _find_generator(ctx.graph, str(args.node))
	if generator == null:
		return _missing_node(ctx.graph, str(args.node))
	if not args.parameters is Dictionary or args.parameters.is_empty():
		return _fail("`parameters` must be a non-empty object.")
	var r : Dictionary = _apply_parameters(ctx.graph_edit, generator, args.parameters)
	if r.applied.is_empty():
		return _fail("\n".join(PackedStringArray(r.errors)))
	var result : Dictionary = { node = str(generator.name), applied = r.applied, values = {} }
	for k in r.applied:
		result.values[k] = MMType.serialize_value(generator.get_parameter(k))
	if not r.errors.is_empty():
		result.errors = r.errors
	return _ok(result)

func _tool_move_nodes(args : Dictionary) -> Dictionary:
	var ctx : Dictionary = _context(args, true, true)
	if ctx.has("error"):
		return _fail(ctx.error)
	var graph_edit = ctx.graph_edit
	var graph : MMGenGraph = ctx.graph
	if not args.positions is Dictionary or args.positions.is_empty():
		return _fail("`positions` must map node names to {x, y}.")
	var old_positions : Dictionary = {}
	var new_positions : Dictionary = {}
	for n in args.positions.keys():
		var generator : MMGenBase = _find_generator(graph, str(n))
		if generator == null:
			return _missing_node(graph, str(n))
		var p = args.positions[n]
		if not p is Dictionary or not p.has("x") or not p.has("y"):
			return _fail("Position of `%s` must be {x, y}." % n)
		old_positions[str(generator.name)] = generator.position
		new_positions[str(generator.name)] = Vector2(float(p.x), float(p.y))
	for n in new_positions.keys():
		var generator : MMGenBase = _find_generator(graph, n)
		var graph_node = _graph_node(graph_edit, generator)
		if graph_node != null:
			graph_node.do_set_position(new_positions[n])
		generator.set_position(new_positions[n])
	var parent : String = graph.get_hier_name()
	graph_edit.undoredo.add("Move nodes", [ { type = "move_generators", parent = parent, positions = old_positions } ], [ { type = "move_generators", parent = parent, positions = new_positions } ])
	graph_edit.set_need_save()
	return _ok({ moved = new_positions })

func _tool_randomize_seed(args : Dictionary) -> Dictionary:
	var ctx : Dictionary = _context(args, true, true)
	if ctx.has("error"):
		return _fail(ctx.error)
	var generator : MMGenBase = _find_generator(ctx.graph, str(args.node))
	if generator == null:
		return _missing_node(ctx.graph, str(args.node))
	if not generator.has_randomness():
		return _fail("Node `%s` has no randomness." % generator.name)
	if generator.is_seed_locked():
		return _fail("Node `%s` has a locked seed; unlock it in the editor first." % generator.name)
	var old_seed : float = generator.seed_value
	var new_seed : float = clampf(float(args.get("seed", randf())), 0.0, 1.0)
	generator.set_seed(new_seed)
	var hier : String = generator.get_hier_name()
	ctx.graph_edit.undoredo.add("Change seed", [ { type = "setseed", node = hier, seed = old_seed } ], [ { type = "setseed", node = hier, seed = new_seed } ])
	var graph_node = _graph_node(ctx.graph_edit, generator)
	if graph_node != null and graph_node.has_method("update"):
		graph_node.update()
	ctx.graph_edit.set_need_save()
	return _ok({ node = str(generator.name), seed = new_seed, previous_seed = old_seed })

func _tool_create_group(args : Dictionary) -> Dictionary:
	var ctx : Dictionary = _context(args, true, true)
	if ctx.has("error"):
		return _fail(ctx.error)
	var graph_edit = ctx.graph_edit
	var graph : MMGenGraph = ctx.graph
	var graph_nodes : Array = []
	for n in args.nodes:
		var generator : MMGenBase = _find_generator(graph, str(n))
		if generator == null:
			return _missing_node(graph, str(n))
		if generator.name in [ "Material", "Brush", "gen_inputs", "gen_outputs" ]:
			return _fail("Node `%s` cannot be grouped." % n)
		graph_nodes.append(_graph_node(graph_edit, generator))
	graph_edit.select_none()
	for gn in graph_nodes:
		if gn != null:
			gn.selected = true
	var before : Array = []
	for c in graph.get_children():
		before.append(c)
	graph_edit.create_subgraph()
	var group : MMGenGraph = null
	for c in graph.get_children():
		if c is MMGenGraph and not c in before:
			group = c
	if group == null:
		return _fail("Material Maker did not create a group.")
	if args.has("label") and str(args.label) != "":
		group.set_type_name(str(args.label))
	# Return to the parent graph so following calls keep working where they were
	_show_graph(graph_edit, graph)
	return _ok({ group = str(group.name), group_path = group.get_hier_name(), label = group.label, ports = _ports(group, true) })

func _tool_set_preview(args : Dictionary) -> Dictionary:
	var ctx : Dictionary = _context(args, true, true)
	if ctx.has("error"):
		return _fail(ctx.error)
	var generator : MMGenBase = _find_generator(ctx.graph, str(args.node))
	if generator == null:
		return _missing_node(ctx.graph, str(args.node))
	var output : int = int(args.get("output", 0))
	if output < 0 or output >= generator.get_output_defs().size():
		return _fail("Node `%s` has no output %d." % [ generator.name, output ])
	var slot : int = clampi(int(args.get("slot", 0)), 0, 1)
	var locked : bool = args.get("lock", false)
	var graph_node = _graph_node(ctx.graph_edit, generator)
	var current = ctx.graph_edit.locked_preview[slot] if locked else null
	if locked and current != null and current.generator == generator and current.output_index == output:
		return _ok({ node = str(generator.name), output = output, slot = slot, locked = true })
	ctx.graph_edit.set_current_preview(slot, graph_node, output, locked, not locked)
	return _ok({ node = str(generator.name), output = output, slot = slot, locked = locked })

func _tool_undo(args : Dictionary) -> Dictionary:
	return _undo_redo(args, true)

func _tool_redo(args : Dictionary) -> Dictionary:
	return _undo_redo(args, false)

func _undo_redo(args : Dictionary, undo : bool) -> Dictionary:
	var ctx : Dictionary = _context(args, false)
	if ctx.has("error"):
		return _fail(ctx.error)
	var undoredo = ctx.project.get("undoredo")
	if undoredo == null:
		return _fail("Project %d has no undo history." % ctx.index)
	if undo:
		if not undoredo.can_undo():
			return _fail("Nothing to undo.")
		var action_name : String = undoredo.stack[undoredo.step - 1].name
		undoredo.undo()
		return _ok({ undone = action_name, can_undo = undoredo.can_undo(), can_redo = undoredo.can_redo() })
	if not undoredo.can_redo():
		return _fail("Nothing to redo.")
	var redo_name : String = undoredo.stack[undoredo.step].name
	undoredo.redo()
	return _ok({ redone = redo_name, can_undo = undoredo.can_undo(), can_redo = undoredo.can_redo() })

static func _list_files(dir_path : String) -> Dictionary:
	var files : Dictionary = {}
	var dir : DirAccess = DirAccess.open(dir_path)
	if dir == null:
		return files
	for f in dir.get_files():
		var p : String = dir_path.path_join(f)
		files[p] = FileAccess.get_modified_time(p)
	return files

func _tool_export_material(args : Dictionary) -> Dictionary:
	var ctx : Dictionary = _context(args)
	if ctx.has("error"):
		return _fail(ctx.error)
	var material = ctx.graph_edit.get_material_node()
	if material == null:
		return _fail("Project %d has no exportable Material node." % ctx.index)
	var target : String = str(args.target)
	if not target in material.get_export_profiles():
		return _fail("Unknown export target `%s`. Available: %s." % [ target, ", ".join(PackedStringArray(material.get_export_profiles())) ])
	var path : String = str(args.path).replace("\\", "/")
	if not path.is_absolute_path():
		return _fail("`path` must be an absolute path prefix.")
	if path.get_extension() != "":
		path = path.get_basename()
	var dir_path : String = path.get_base_dir()
	DirAccess.make_dir_recursive_absolute(dir_path)
	var before : Dictionary = _list_files(dir_path)
	var started : int = int(Time.get_unix_time_from_system())
	await material.export_material(path, target, int(args.get("size", 0)), true)
	if args.get("include_export_nodes", false):
		var stack : Array = [ ctx.graph_edit.top_generator ]
		while not stack.is_empty():
			var g = stack.pop_back()
			if g != material and g.has_method("export_material") and not g.has_method("get_export_profiles"):
				await g.export_material(path, target)
			stack.append_array(g.get_children())
	var written : Array = []
	var after : Dictionary = _list_files(dir_path)
	for f in after.keys():
		if not before.has(f) or after[f] != before[f] or after[f] >= started:
			if f.get_file().begins_with(path.get_file()):
				written.append(f)
	written.sort()
	var result : Dictionary = { target = target, prefix = path, files = written }
	if written.is_empty():
		result.note = "No files were written; existing files may have been kept, see get_console."
	return _ok(result)
