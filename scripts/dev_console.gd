class_name DevConsole
extends CanvasLayer
## A small bottom console for deterministic developer and companion commands.
## It never pauses the world: in co-op the other hero and monsters keep running.
## CanvasLayer (not Control) so it always draws above the game UI.

static var instance: DevConsole = null

var _main: Node2D = null
var _commands := DevCommands.new()
var _output: RichTextLabel = null
var _input_line: LineEdit = null
var _history: Array[String] = []
var _history_index := 0
## Set by open() so tests can verify focus intent without a window manager.
var focus_requested := false
var _root: Control = null

static func console_is_open() -> bool:
	return instance != null and is_instance_valid(instance) and instance.visible

func setup(main_node: Node2D) -> void:
	_main = main_node
	_commands.setup(main_node)

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	name = "DevConsole"
	layer = 95
	_build_ui()
	visible = false
	instance = self

func _exit_tree() -> void:
	if instance == self:
		instance = null

func _build_ui() -> void:
	_root = Control.new()
	_root.name = "Root"
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_root)

	var panel := PanelContainer.new()
	panel.name = "Panel"
	panel.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	panel.offset_left = 16.0
	panel.offset_top = -286.0
	panel.offset_right = -16.0
	panel.offset_bottom = -16.0
	panel.theme = UiKit.base_theme({"font_size": 16, "scrollbar": true})
	_root.add_child(panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_top", 10)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_bottom", 10)
	panel.add_child(margin)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 8)
	margin.add_child(column)

	var title := Label.new()
	title.text = Loc.t("ui.dev.title")
	title.theme_type_variation = &"SectionTitle"
	column.add_child(title)

	_output = RichTextLabel.new()
	_output.name = "Output"
	_output.bbcode_enabled = false
	_output.scroll_following = true
	_output.custom_minimum_size = Vector2(0, 174)
	_output.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_output.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(_output)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	column.add_child(row)
	var prompt := Label.new()
	prompt.text = ">"
	row.add_child(prompt)

	_input_line = LineEdit.new()
	_input_line.name = "CommandLine"
	_input_line.placeholder_text = Loc.t("ui.dev.placeholder")
	_input_line.max_length = 512
	_input_line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_input_line.text_submitted.connect(_on_text_submitted)
	row.add_child(_input_line)

func open() -> void:
	visible = true
	_history_index = _history.size()
	if _input_line != null:
		_input_line.clear()
		focus_requested = true
		_input_line.grab_focus.call_deferred()

func close() -> void:
	visible = false
	focus_requested = false
	if _input_line != null:
		_input_line.release_focus()

func toggle() -> void:
	if visible:
		close()
	else:
		open()

func _input(event: InputEvent) -> void:
	if not (event is InputEventKey):
		return
	var key := event as InputEventKey
	if not key.pressed or key.echo:
		return
	if key.keycode == KEY_QUOTELEFT or key.keycode == KEY_ASCIITILDE:
		toggle()
		get_viewport().set_input_as_handled()
		return
	if not visible:
		return
	if key.keycode == KEY_ESCAPE:
		close()
		get_viewport().set_input_as_handled()
	elif key.keycode == KEY_UP:
		_history_step(-1)
		get_viewport().set_input_as_handled()
	elif key.keycode == KEY_DOWN:
		_history_step(1)
		get_viewport().set_input_as_handled()

func _unhandled_input(event: InputEvent) -> void:
	# CanvasLayer does not receive _input the same way as Control; also hook
	# _unhandled_input so ~ works even when a panel already consumed the event.
	if not (event is InputEventKey):
		return
	var key := event as InputEventKey
	if not key.pressed or key.echo:
		return
	if key.keycode == KEY_QUOTELEFT or key.keycode == KEY_ASCIITILDE:
		toggle()
		get_viewport().set_input_as_handled()

func _history_step(direction: int) -> void:
	if _history.is_empty() or _input_line == null:
		return
	_history_index = clampi(_history_index + direction, 0, _history.size())
	if _history_index == _history.size():
		_input_line.clear()
	else:
		_input_line.text = _history[_history_index]
		_input_line.caret_column = _input_line.text.length()

func _on_text_submitted(text: String) -> void:
	var command := text.strip_edges()
	if _input_line != null:
		_input_line.clear()
	if command == "":
		return
	_history.append(command)
	if _history.size() > 30:
		_history.pop_front()
	_history_index = _history.size()
	append_line("> " + command)
	var result := execute(command)
	append_line(str(result.get("text", "")))

## Public entry point for smoke tests and automation. The console stays open.
func execute(command: String) -> Dictionary:
	return _commands.execute(command)

func append_line(text: String) -> void:
	if _output != null:
		_output.append_text(text + "\n")
