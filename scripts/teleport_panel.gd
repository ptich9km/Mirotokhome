class_name TeleportPanel
extends CanvasLayer
## Teleport master panel (25.11): fast travel between visited cities.
##
## Every city has a teleport master NPC; reaching a city centre for the first
## time records it in Game.visited_cities. The panel lists all recorded cities:
## the current one, the reachable ones (with price), and the locked ones
## (reputation with the city race below Game.TELEPORT_REP_MIN - the master
## refuses to send the hero into a hostile city, player decision 25.11).
##
## Unlike the interior panels the hero is NOT hidden: the master stands on the
## street, and after a hop the hero must land next to the destination master.

signal closed

const PANEL_MIN := Vector2(560, 0)
const LIST_HEIGHT := 320

const PANEL_BG := Color(0.07, 0.06, 0.12, 0.97)
const PANEL_BORDER := Color(0.45, 0.32, 0.80, 1.0)
const ROW_BG := Color(0.13, 0.10, 0.22, 0.95)
const ROW_BORDER := Color(0.32, 0.24, 0.52, 1.0)

var player: Player
var _current_city_id := ""
var _root: Control
var _list: VBoxContainer
var _gold_label: Label
var _hint: Label
var _previous_focus: Control
var _closed := false


func setup(p: Player, current_city_id: String = "") -> void:
	player = p
	_current_city_id = current_city_id


func _ready() -> void:
	layer = 30
	_previous_focus = UiKit.save_focus(self)
	_build()
	_refresh()
	var first: Button = _list.get_node_or_null("Row0/Row/Go") as Button
	if first != null:
		first.call_deferred("grab_focus")
	else:
		# Nothing to focus (empty list): Esc / the close button still work.
		var close_btn: Button = _root.get_node_or_null("Center/Panel/Margin/Column/Footer/Close") as Button
		if close_btn != null:
			close_btn.call_deferred("grab_focus")


func close() -> void:
	if _closed:
		return
	_closed = true
	UiKit.restore_focus(_previous_focus)
	closed.emit()
	queue_free()


func _unhandled_input(event: InputEvent) -> void:
	if UiKit.esc_pressed(event):
		close()
		get_viewport().set_input_as_handled()


## The sector display name: the same name_key chain as Game._sector_name.
func _sector_name(sector_id: String) -> String:
	var wm = load("res://scripts/world/world_map.gd")
	var info: Dictionary = wm.sector(sector_id)
	var key := str(info.get("name_key", ""))
	if key == "":
		return sector_id
	var text := Loc.t(key)
	return sector_id if text == key else text


func _build() -> void:
	_root = Control.new()
	_root.name = "Root"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.theme = UiKit.base_theme()
	add_child(_root)
	_root.add_child(UiKit.make_dim(0.66))

	var center := CenterContainer.new()
	center.name = "Center"
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.add_child(center)

	var panel := PanelContainer.new()
	panel.name = "Panel"
	panel.custom_minimum_size = PANEL_MIN
	panel.add_theme_stylebox_override("panel",
		_card_style(PANEL_BG, PANEL_BORDER, 6, 0))
	center.add_child(panel)

	var margin := MarginContainer.new()
	margin.name = "Margin"
	UiKit.set_margins(margin, 16, 12, 16, 12)
	panel.add_child(margin)

	var column := VBoxContainer.new()
	column.name = "Column"
	column.add_theme_constant_override("separation", 8)
	margin.add_child(column)

	var header := HBoxContainer.new()
	header.name = "Header"
	header.add_theme_constant_override("separation", 12)
	column.add_child(header)

	var title := Label.new()
	title.name = "Title"
	title.text = Loc.t("ui.teleport.title")
	title.add_theme_font_size_override("font_size", 22)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)

	_gold_label = Label.new()
	_gold_label.name = "Gold"
	_gold_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	header.add_child(_gold_label)

	var scroll := ScrollContainer.new()
	scroll.name = "Scroll"
	scroll.custom_minimum_size = Vector2(0, LIST_HEIGHT)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	column.add_child(scroll)

	_list = VBoxContainer.new()
	_list.name = "List"
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 6)
	scroll.add_child(_list)

	_hint = Label.new()
	_hint.name = "Hint"
	_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hint.modulate = Color(1, 0.85, 0.5)
	_hint.visible = false
	column.add_child(_hint)

	var footer := HBoxContainer.new()
	footer.name = "Footer"
	footer.alignment = BoxContainer.ALIGNMENT_END
	column.add_child(footer)

	var close_btn := Button.new()
	close_btn.name = "Close"
	close_btn.text = Loc.t("ui.common.close")
	close_btn.pressed.connect(close)
	footer.add_child(close_btn)


func _refresh() -> void:
	for child in _list.get_children():
		child.queue_free()
	_gold_label.text = Loc.f("ui.teleport.gold", [int(player.gold) if player != null else 0])
	var current_key := ""
	if Game.map_sector != "":
		current_key = "%s|%s|%d|%s" % [Game.map_zone, Game.map_sector,
			Game.map_seed, _current_city_id]
	if Game.visited_cities.is_empty():
		_hint.text = Loc.t("ui.teleport.empty")
		_hint.visible = true
		return
	_hint.visible = false
	var index := 0
	for key in Game.visited_cities.keys():
		_list.add_child(_make_row(str(key), Game.visited_cities[key],
			current_key, index))
		index += 1


func _card_style(bg: Color, border: Color, radius: int, pad: int) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = border
	s.set_border_width_all(1)
	s.set_corner_radius_all(radius)
	s.content_margin_left = pad
	s.content_margin_right = pad
	s.content_margin_top = pad
	s.content_margin_bottom = pad
	return s


func _make_row(key: String, rec: Dictionary, current_key: String, index: int) -> PanelContainer:
	var card := PanelContainer.new()
	card.name = "Row%d" % index
	card.add_theme_stylebox_override("panel", _card_style(ROW_BG, ROW_BORDER, 4, 8))

	var row := HBoxContainer.new()
	row.name = "Row"
	row.add_theme_constant_override("separation", 10)
	card.add_child(row)

	var texts := VBoxContainer.new()
	texts.name = "Texts"
	texts.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(texts)

	var name_label := Label.new()
	name_label.name = "Name"
	name_label.text = "%s — %s" % [str(rec.get("name", "?")),
		_sector_name(str(rec.get("sector", "")))]
	texts.add_child(name_label)

	var status := Label.new()
	status.name = "Status"
	status.modulate = Color(1, 1, 1, 0.72)
	texts.add_child(status)

	var go := Button.new()
	go.name = "Go"
	go.text = Loc.t("ui.teleport.go")
	row.add_child(go)

	var cost := Game.teleport_cost_between(Game.map_sector, str(rec.get("sector", "")))
	var gate := Game.teleport_gate(rec, current_key)
	match gate:
		"here":
			status.text = Loc.t("ui.teleport.here")
			go.disabled = true
		"rep":
			status.text = Loc.t("ui.teleport.locked_rep")
			status.add_theme_color_override("font_color", Color(1, 0.45, 0.4))
			go.disabled = true
		_:
			status.text = Loc.f("ui.teleport.cost", [cost])
			if player == null or int(player.gold) < cost:
				status.text += " — " + Loc.t("ui.teleport.no_gold")
				go.disabled = true
	go.pressed.connect(_on_go.bind(key))
	return card


func _on_go(key: String) -> void:
	var game := get_tree().current_scene
	if game == null or not game.has_method("teleport_to_city"):
		return
	var err: String = game.teleport_to_city(key)
	if err == "":
		close()
		return
	# Validation failed after the refresh (rare): show the reason honestly.
	match err:
		"rep":
			_hint.text = Loc.t("ui.teleport.locked_rep")
		"gold":
			_hint.text = Loc.t("ui.teleport.no_gold")
		_:
			_hint.text = ""
	_hint.visible = _hint.text != ""
