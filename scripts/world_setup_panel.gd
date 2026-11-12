class_name WorldSetupPanel
extends CanvasLayer
## Окно «Мир» на экране выбора героя: режим старта, сид, зона, готовая карта.
##
## Сознательно отдельное окно, а не ещё один блок в колонке: character_select
## уже упирается в высоту 1280×600 (это проверяет character_select_ui_smoke).
##
## Мышь, клавиатура и геймпад: все элементы — Control в контейнерах, при
## открытии фокус на «Готово», Esc закрывает окно.

signal applied(start_setup: StartSetup)
signal edit_requested(map_path: String)
signal closed

const PANEL_SIZE := Vector2(760, 590)

var data: StartSetup
var _mode: OptionButton
var _seed_edit: LineEdit
var _zone: OptionButton
var _maps_list: ItemList
var _error: Label
var _seed_row: HBoxContainer
var _map_box: VBoxContainer
var _maps: Array = []
var _selected_path := ""
var _done := false


func open(start_setup: StartSetup) -> void:
	data = start_setup
	_build()
	_refresh_maps()
	_apply_mode()
	_refresh_summary()
	if is_inside_tree():
		_mode.grab_focus.call_deferred()


func close() -> void:
	_close()


func _build() -> void:
	layer = 30
	var theme := UiKit.base_theme()
	UiKit.add_title(theme, &"CsTitle")
	UiKit.add_label(theme, &"CsDesc", Color(0.85, 0.82, 0.75), 12)
	UiKit.add_panel(theme, &"CsEditor", Color(0.10, 0.09, 0.08, 0.94), UiKit.DIALOG_BORDER, 6)
	UiKit.add_button(theme, &"CsStart", Color(0.18, 0.24, 0.16, 0.95),
		UiKit.GOLD_COLOR, Color(0.24, 0.32, 0.20), UiKit.GOLD_COLOR, 6, 8)
	var dim := UiKit.make_dim(0.72)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)

	var panel := PanelContainer.new()
	panel.theme_type_variation = &"CsEditor"
	panel.theme = theme
	panel.custom_minimum_size = PANEL_SIZE
	center.add_child(panel)

	var margin := MarginContainer.new()
	UiKit.set_margins(margin, 22, 16, 22, 16)
	panel.add_child(margin)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 10)
	margin.add_child(col)

	var title := Label.new()
	title.theme_type_variation = &"CsTitle"
	title.text = Loc.t("ui.world.title")
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(title)

	# --- Режим ---
	var mode_row := HBoxContainer.new()
	mode_row.add_theme_constant_override("separation", 10)
	col.add_child(mode_row)
	_add_label(mode_row, Loc.t("ui.world.mode"))
	_mode = OptionButton.new()
	_mode.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_mode.add_item(Loc.t("ui.world.mode_random"), 0)
	_mode.add_item(Loc.t("ui.world.mode_seed"), 1)
	_mode.add_item(Loc.t("ui.world.mode_map"), 2)
	_mode.item_selected.connect(func(_i): _apply_mode(); _refresh_summary())
	mode_row.add_child(_mode)

	# --- Сид ---
	_seed_row = HBoxContainer.new()
	_seed_row.add_theme_constant_override("separation", 10)
	col.add_child(_seed_row)
	_add_label(_seed_row, Loc.t("ui.world.seed"))
	_seed_edit = LineEdit.new()
	_seed_edit.custom_minimum_size = Vector2(260, 38)
	_seed_edit.placeholder_text = "1 … 2147483647"
	_seed_edit.max_length = 10
	_seed_edit.text_changed.connect(_on_seed_text)
	_seed_row.add_child(_seed_edit)
	var dice := Button.new()
	dice.text = Loc.t("ui.world.dice")
	dice.custom_minimum_size = Vector2(160, 38)
	dice.pressed.connect(func():
		_seed_edit.text = str(StartSetup.random_seed())
		_refresh_summary())
	_seed_row.add_child(dice)

	# --- Зона ---
	var zone_row := HBoxContainer.new()
	zone_row.add_theme_constant_override("separation", 10)
	col.add_child(zone_row)
	_add_label(zone_row, Loc.t("ui.world.zone"))
	_zone = OptionButton.new()
	_zone.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for i in range(StartSetup.ZONES.size()):
		_zone.add_item(StartSetup.zone_label(str(StartSetup.ZONES[i])), i)
	_zone.item_selected.connect(func(_i): _refresh_summary())
	zone_row.add_child(_zone)

	# --- Готовые карты ---
	_map_box = VBoxContainer.new()
	_map_box.add_theme_constant_override("separation", 6)
	_map_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(_map_box)

	var map_head := HBoxContainer.new()
	map_head.add_theme_constant_override("separation", 10)
	_map_box.add_child(map_head)
	_add_label(map_head, Loc.t("ui.world.maps_head"))
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	map_head.add_child(spacer)
	var refresh := Button.new()
	refresh.text = Loc.t("ui.world.refresh")
	refresh.pressed.connect(_refresh_maps)
	map_head.add_child(refresh)
	var edit_btn := Button.new()
	edit_btn.text = Loc.t("ui.world.open_editor")
	edit_btn.pressed.connect(_on_edit_requested)
	map_head.add_child(edit_btn)

	_maps_list = ItemList.new()
	_maps_list.custom_minimum_size = Vector2(0, 150)
	_maps_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_maps_list.item_selected.connect(_on_map_selected)
	_map_box.add_child(_maps_list)

	var hint := Label.new()
	hint.theme_type_variation = &"CsDesc"
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.text = Loc.t("ui.world.hint")
	_map_box.add_child(hint)

	_error = Label.new()
	_error.add_theme_color_override("font_color", Color(1.0, 0.45, 0.35))
	_error.text = ""
	col.add_child(_error)

	# --- Кнопки ---
	var buttons := HBoxContainer.new()
	buttons.alignment = BoxContainer.ALIGNMENT_END
	buttons.add_theme_constant_override("separation", 10)
	col.add_child(buttons)
	var cancel := Button.new()
	cancel.text = Loc.t("ui.world.cancel")
	cancel.custom_minimum_size = Vector2(140, 40)
	cancel.pressed.connect(_close)
	buttons.add_child(cancel)
	var ok := Button.new()
	ok.theme_type_variation = &"CsStart"
	ok.text = Loc.t("ui.world.ok")
	ok.custom_minimum_size = Vector2(160, 40)
	ok.pressed.connect(_on_ok)
	buttons.add_child(ok)
	UiKit.wire_grid_focus([cancel, ok], 2)

	_mode.selected = maxi(0, StartSetup.MODES.find(data.mode))
	_zone.selected = maxi(0, StartSetup.ZONES.find(data.zone))
	_seed_edit.text = str(data.world_seed)
	_selected_path = data.map_path
	ok.call_deferred("grab_focus")


func _add_label(parent: HBoxContainer, text: String) -> void:
	var l := Label.new()
	l.text = text
	l.custom_minimum_size = Vector2(150, 0)
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	parent.add_child(l)


func _mode_id() -> String:
	return str(StartSetup.MODES[clampi(_mode.selected, 0, StartSetup.MODES.size() - 1)])


func _apply_mode() -> void:
	var m := _mode_id()
	_seed_row.visible = m == "seed"
	_map_box.visible = m == "map"
	_error.text = ""


func _on_seed_text(text: String) -> void:
	var filtered := ""
	for i in range(text.length()):
		var ch := text.unicode_at(i)
		if ch >= 48 and ch <= 57:
			filtered += String.chr(ch)
	if filtered != text:
		_seed_edit.text = filtered
		_seed_edit.caret_column = filtered.length()
	_refresh_summary()


func _refresh_maps() -> void:
	_maps = MapMeta.list()
	_maps_list.clear()
	var select_index := -1
	for i in range(_maps.size()):
		var m: Dictionary = _maps[i]
		var size := ""
		if int(m.get("w", 0)) > 0 and int(m.get("h", 0)) > 0:
			size = " · %d×%d" % [int(m["w"]), int(m["h"])]
		var marks := ""
		if bool(m.get("has_spawn", false)):
			marks += Loc.t("ui.world.mark_spawn")
		if bool(m.get("has_portal", false)):
			marks += Loc.t("ui.world.mark_portal")
		_maps_list.add_item("%s · %s%s%s" % [
			str(m.get("title", "")), StartSetup.zone_label(str(m.get("zone", "start"))),
			size, marks])
		if str(m.get("path", "")) == _selected_path:
			select_index = i
	if _maps.is_empty():
		_selected_path = ""
		_maps_list.add_item(Loc.t("ui.world.no_maps"))
		_maps_list.set_item_disabled(0, true)
	elif select_index >= 0:
		_maps_list.select(select_index)


func _on_map_selected(index: int) -> void:
	if index < 0 or index >= _maps.size():
		return
	_selected_path = str((_maps[index] as Dictionary).get("path", ""))
	var z := str((_maps[index] as Dictionary).get("zone", "start"))
	_zone.selected = maxi(0, StartSetup.ZONES.find(z))
	_refresh_summary()


func _read_fields() -> String:
	data.mode = _mode_id()
	data.zone = str(StartSetup.ZONES[clampi(_zone.selected, 0, StartSetup.ZONES.size() - 1)])
	var raw := _seed_edit.text.strip_edges()
	var value := int(raw) if raw.is_valid_int() else 0
	if data.mode == "seed":
		if value <= 0:
			_error.text = Loc.t("ui.world.err_seed")
			return "seed"
		data.world_seed = value
	elif data.mode == "map":
		if _selected_path == "":
			_error.text = Loc.t("ui.world.err_map")
			return "map"
		data.map_path = _selected_path
	else:
		data.world_seed = StartSetup.random_seed()
	data.map_path = _selected_path if data.mode == "map" else ""
	return ""


func _on_ok() -> void:
	var err := _read_fields()
	if err != "":
		return
	data.normalize()
	applied.emit(data)
	_close()


func _on_edit_requested() -> void:
	edit_requested.emit(_selected_path)
	_close()


func _refresh_summary() -> void:
	# Сводка живёт на кнопке в character_select; здесь только чистим ошибку.
	_error.text = ""


func _input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		_close()


func _close() -> void:
	if _done:
		return
	_done = true
	closed.emit()
	queue_free()
