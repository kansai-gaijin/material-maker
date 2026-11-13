extends RefCounted

## Builds the "MCP" page of the Preferences window: enable the built-in MCP
## server, pick its port and an optional bearer token, and copy the commands
## that register it with coding agents.


class IntOption:
	extends SpinBox
	var config_variable : String

	func init_from_config(config : ConfigFile) -> void:
		if config.has_section_key("config", config_variable):
			value = int(config.get_value("config", config_variable))

	func update_config(config : ConfigFile) -> void:
		config.set_value("config", config_variable, int(value))


class StringOption:
	extends LineEdit
	var config_variable : String

	func init_from_config(config : ConfigFile) -> void:
		if config.has_section_key("config", config_variable):
			text = str(config.get_value("config", config_variable))

	func update_config(config : ConfigFile) -> void:
		config.set_value("config", config_variable, text.strip_edges())


static func _row(parent : Control, label_text : String, control : Control, tooltip : String = "") -> void:
	var row : HBoxContainer = HBoxContainer.new()
	var label : Label = Label.new()
	label.text = label_text
	row.add_child(label)
	control.custom_minimum_size = Vector2(200, 0)
	control.size_flags_horizontal = Control.SIZE_SHRINK_END | Control.SIZE_EXPAND
	control.tooltip_text = tooltip
	row.add_child(control)
	parent.add_child(row)

static func _copy_row(parent : Control, label_text : String, command : String) -> void:
	var row : HBoxContainer = HBoxContainer.new()
	var label : Label = Label.new()
	label.text = label_text
	label.custom_minimum_size = Vector2(110, 0)
	row.add_child(label)
	var field : LineEdit = LineEdit.new()
	field.text = command
	field.editable = false
	field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(field)
	var button : Button = Button.new()
	button.text = "Copy"
	button.pressed.connect(func(): DisplayServer.clipboard_set(command))
	row.add_child(button)
	parent.add_child(row)

static func add_page(tab_container : TabContainer) -> void:
	if tab_container.has_node("MCP"):
		return
	var page : ScrollContainer = ScrollContainer.new()
	page.name = "MCP"
	page.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var box : VBoxContainer = VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	page.add_child(box)

	var enabled : CheckBox = load("res://material_maker/windows/preferences/bool_option.tscn").instantiate()
	enabled.config_variable = "mcp_server_enabled"
	enabled.text = "On"
	enabled.flat = false
	_row(box, "Built-in MCP server", enabled, "Lets coding agents (Claude Code, Codex...) drive Material Maker through the Model Context Protocol. Only accepts connections from this computer.")

	var port : IntOption = IntOption.new()
	port.config_variable = "mcp_server_port"
	port.min_value = 1024
	port.max_value = 65535
	port.step = 1
	port.rounded = true
	_row(box, "Port", port)

	var token : StringOption = StringOption.new()
	token.config_variable = "mcp_server_token"
	token.placeholder_text = "none"
	token.secret = true
	_row(box, "Bearer token (optional)", token, "When set, clients must send \"Authorization: Bearer <token>\".")

	var spacer : Control = Control.new()
	spacer.custom_minimum_size = Vector2(0, 10)
	box.add_child(spacer)

	var server = mm_globals.main_window.mcp_server if mm_globals.main_window != null else null
	var status : Label = Label.new()
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	if server != null and server.is_running():
		status.text = "Listening on " + server.get_url()
	else:
		status.text = "The server is not running. Enable it and press Apply."
	box.add_child(status)

	var url : String = server.get_url() if server != null else "http://127.0.0.1:%d/mcp" % int(mm_globals.get_config("mcp_server_port"))
	_copy_row(box, "Claude Code", "claude mcp add --transport http material-maker " + url)
	_copy_row(box, "Codex", "codex mcp add material-maker --url " + url)

	tab_container.add_child(page)
