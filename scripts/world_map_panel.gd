extends CanvasLayer
## World map 4x3 (23.10, SIM overlay 26.11).
##
## Shows 12 sectors with their faction owner, difficulty tier and outposts.
## Territory colour comes from WorldBus.state; contested and clashing sectors
## get a non-colour mark plus a pulsing alert. Clicking a sector asks the UI to
## open the teleport panel filtered to that sector, so the player can go help.
##
## Look: UiTheme roles and UiKit variations only. Mouse, keyboard, gamepad:
## a 4-column grid with UiKit.wire_grid_focus, initial focus on the current
## sector, Esc closes.

signal closed
signal travel_requested(sector_id: String)

const PANEL_WIDTH := 1120
const PANEL_HEIGHT := 520
const COLUMNS := 4
const CELL_SIZE := Vector2(252, 120)
const TERRITORY_ALPHA := 0.11
const STRIPE_WIDTH := 5.0
const ALERT_PERIOD := 0.55

var _root: MarginContainer
var _panel: PanelContainer
var _grid: GridContainer
var _previous_focus: Control
var _buttons: Array[Button] = []
var _cells: Dictionary = {}   # sector id -> Button


func setup() -> void:
	layer = 10
	_build_ui()


func _ready() -> void:
	_previous_focus = UiKit.save_focus(self)
	UiKit.animate_in(_root)
	var bus := get_node_or_null("/root/WorldBus")
	if bus != null and bus.has_signal("day_changed") \
			and not bus.day_changed.is_connected(_on_day_changed):
		bus.day_changed.connect(_on_day_changed)
	_refresh()
	if _cells.has(Game.map_sector) and is_instance_valid(_cells[Game.map_sector]):
		_cells[Game.map_sector].call_deferred("grab_focus")
	elif not _buttons.is_empty():
		_buttons[0].call_deferred("grab_focus")


func _on_day_changed(_day: int) -> void:
	_refresh()


func _input(event: InputEvent) -> void:
	if UiKit.esc_pressed(event):
		close()
		get_viewport().set_input_as_handled()


func close() -> void:
	var bus := get_node_or_null("/root/WorldBus")
	if bus != null and bus.has_signal("day_changed") \
			and bus.day_changed.is_connected(_on_day_changed):
		bus.day_changed.disconnect(_on_day_changed)
	UiKit.restore_focus(_previous_focus)
	closed.emit()
	queue_free()


func _make_theme() -> Theme:
	var theme := UiTheme.app_theme()
	UiKit.add_frame(theme, &"WorldPanel", "res://assets/ui/frames/panel_frame.png")
	UiKit.add_label(theme, &"WorldTitle", UiTheme.ACCENT, UiTheme.FONT_TITLE)
	UiKit.add_label(theme, &"WorldSection", UiTheme.ACCENT_DIM, UiTheme.FONT_SECTION)
	UiKit.add_label(theme, &"WorldName", UiTheme.TEXT, UiTheme.FONT_SUBHEAD)
	UiKit.add_label(theme, &"WorldMeta", UiTheme.TEXT_MUTED, UiTheme.FONT_MICRO)
	UiKit.add_label(theme, &"WorldHint", UiTheme.TEXT_MUTED, UiTheme.FONT_MICRO)
	UiKit.add_button(theme, &"WorldCell",
		UiTheme.PANEL_INNER, UiTheme.PANEL_EDGE,
		UiTheme.PANEL_INNER.lightened(0.10), UiTheme.ACCENT,
		UiTheme.RADIUS_SLOT, UiTheme.SPACE_2)
	UiKit.add_button(theme, &"WorldCellCurrent",
		UiTheme.PANEL_INNER.lightened(0.06), UiTheme.ACCENT,
		UiTheme.PANEL_INNER.lightened(0.12), UiTheme.ACCENT,
		UiTheme.RADIUS_SLOT, UiTheme.SPACE_2)
	UiKit.add_button(theme, &"WorldClose",
		UiTheme.PANEL_INNER, UiTheme.PANEL_EDGE.darkened(0.25),
		UiTheme.PANEL_INNER.lightened(0.12), UiTheme.ACCENT_DIM,
		UiTheme.RADIUS_SLOT, UiTheme.SPACE_2)
	return theme


func _build_ui() -> void:
	var dim := UiKit.make_dim(UiTheme.SCRIM.a)
	add_child(dim)

	_root = MarginContainer.new()
	_root.name = "WorldRoot"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UiKit.set_margins(_root, UiTheme.SCREEN_INSET, UiTheme.SCREEN_INSET,
		UiTheme.SCREEN_INSET, UiTheme.SCREEN_INSET)
	_root.theme = _make_theme()
	add_child(_root)

	var center := CenterContainer.new()
	center.name = "Center"
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(center)

	_panel = PanelContainer.new()
	_panel.name = "Panel"
	_panel.theme_type_variation = &"WorldPanel"
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_panel.custom_minimum_size = Vector2(PANEL_WIDTH, PANEL_HEIGHT)
	center.add_child(_panel)

	var margin := MarginContainer.new()
	margin.name = "Margin"
	UiKit.set_margins(margin, UiTheme.SPACE_5, UiTheme.SPACE_4,
		UiTheme.SPACE_5, UiTheme.SPACE_4)
	_panel.add_child(margin)

	var content := VBoxContainer.new()
	content.name = "Content"
	content.add_theme_constant_override("separation", UiTheme.SPACE_3)
	margin.add_child(content)

	var header := HBoxContainer.new()
	header.name = "Header"
	header.add_theme_constant_override("separation", UiTheme.SPACE_3)
	content.add_child(header)

	var title := Label.new()
	title.name = "Title"
	title.theme_type_variation = &"WorldTitle"
	title.text = Loc.t("ui.world_map.title")
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)

	var close_button := Button.new()
	close_button.name = "Close"
	close_button.text = Loc.t("ui.world_map.close")
	close_button.theme_type_variation = &"WorldClose"
	close_button.custom_minimum_size = Vector2(120, 32)
	close_button.pressed.connect(close)
	header.add_child(close_button)

	_grid = GridContainer.new()
	_grid.name = "Grid"
	_grid.columns = COLUMNS
	_grid.add_theme_constant_override("h_separation", UiTheme.SPACE_3)
	_grid.add_theme_constant_override("v_separation", UiTheme.SPACE_3)
	_grid.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_child(_grid)

	var hint := Label.new()
	hint.name = "Hint"
	hint.theme_type_variation = &"WorldHint"
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.text = Loc.t("ui.world_map.hint")
	content.add_child(hint)


func _refresh() -> void:
	UiKit.clear(_grid)
	_buttons.clear()
	_cells.clear()
	var rows := _sector_rows()
	for raw in rows:
		var rec: Dictionary = raw as Dictionary
		var id := str(rec.get("id", ""))
		var button := _make_cell(id, rec)
		_grid.add_child(button)
		_buttons.append(button)
		_cells[id] = button
	UiKit.wire_grid_focus(_buttons, COLUMNS)


func _sector_rows() -> Array:
	var bus = get_node_or_null("/root/WorldBus")
	var state = bus.state if bus != null and "state" in bus else null
	if state != null and not state.sectors.is_empty():
		var out: Array = []
		var wm = load("res://scripts/world/world_map.gd")
		for id in wm.ids():
			var s: Dictionary = state.sector_state(str(id))
			var rec := s.duplicate(true)
			rec["id"] = str(id)
			out.append(rec)
		return out
	# No world state (dev map): show the grid as unexplored.
	var fallback: Array = []
	var map_script = load("res://scripts/world/world_map.gd")
	for id in map_script.ids():
		var s: Dictionary = map_script.sector(str(id))
		s["id"] = str(id)
		s["owner"] = ""
		s["discovered"] = 2 if str(id) == Game.map_sector else 0
		s["outposts"] = []
		fallback.append(s)
	return fallback


## Faction armies currently facing each other in this sector. Only live pairs
## count: a stale enemy_id after an army was erased must not draw a false clash.
static func clash_info(state, sector_id: String) -> Dictionary:
	var out: Dictionary = {}
	if state == null or not ("armies" in state):
		return out
	for aid in state.armies:
		var a: Dictionary = state.armies[aid]
		if str(a.get("sector_id", "")) != sector_id:
			continue
		var enemy_id := str(a.get("enemy_id", ""))
		if enemy_id == "" or not state.armies.has(enemy_id):
			continue
		var fid := str(a.get("faction_id", ""))
		if fid == "":
			continue
		out[fid] = int(out.get(fid, 0)) + 1
	return out


## A sector is contested when it has no capital owner, when a local outpost
## belongs to another faction, or while two SIM armies face each other there.
static func is_contested(state, sector_id: String) -> bool:
	if not clash_info(state, sector_id).is_empty():
		return true
	if state == null or not ("sectors" in state):
		return false
	var rec: Dictionary = state.sector_state(sector_id)
	var owner := str(rec.get("owner", ""))
	if owner == "":
		return true
	if sector_id != Game.map_sector:
		return false
	for raw in Game.outposts:
		var op: Dictionary = raw
		var op_owner := Game.outpost_owner_of(str(op.get("id", "")))
		if op_owner == "":
			op_owner = str(op.get("faction", ""))
		if op_owner != "" and op_owner != owner:
			return true
	return false


## Dark tint plus a bright stripe: the stripe carries the faction identity even
## when the tint is hard to see. Unknown/contested sectors use a neutral colour.
static func territory_color(state, sector_id: String) -> Color:
	if state == null or not ("sectors" in state):
		return Lore.faction_color("")
	var rec: Dictionary = state.sector_state(sector_id)
	var owner := str(rec.get("owner", ""))
	return Lore.faction_color(owner)


func _make_cell(id: String, rec: Dictionary) -> Button:
	var discovered := int(rec.get("discovered", 0))
	var current := id == Game.map_sector
	var button := Button.new()
	button.name = "Sector_" + id
	button.theme_type_variation = &"WorldCellCurrent" if current else &"WorldCell"
	button.custom_minimum_size = CELL_SIZE
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	button.tooltip_text = _tooltip(id, rec, discovered)
	if not current:
		button.pressed.connect(_on_cell_pressed.bind(id))

	var bus = get_node_or_null("/root/WorldBus")
	var world_state = bus.state if bus != null and "state" in bus else null
	var color := territory_color(world_state, id)
	color.a = TERRITORY_ALPHA
	var tint := ColorRect.new()
	tint.name = "TerritoryTint"
	tint.color = color
	tint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tint.set_anchors_preset(Control.PRESET_FULL_RECT)
	button.add_child(tint)

	var stripe := ColorRect.new()
	stripe.name = "TerritoryStripe"
	stripe.color = Color(color.r, color.g, color.b, 0.9)
	stripe.mouse_filter = Control.MOUSE_FILTER_IGNORE
	stripe.anchor_right = 0.0
	stripe.anchor_bottom = 1.0
	stripe.offset_left = 0.0
	stripe.offset_right = STRIPE_WIDTH
	stripe.offset_top = 0.0
	stripe.offset_bottom = 0.0
	button.add_child(stripe)

	var contested := is_contested(world_state, id) and discovered > 0
	if contested:
		var alert := ColorRect.new()
		alert.name = "ContestedAlert"
		alert.color = Color(1.0, 0.62, 0.24, 1.0)
		alert.mouse_filter = Control.MOUSE_FILTER_IGNORE
		alert.set_anchors_preset(Control.PRESET_FULL_RECT)
		alert.modulate.a = 0.12
		button.add_child(alert)
		var pulse := alert.create_tween().set_loops()
		pulse.tween_property(alert, "modulate:a", 0.42, ALERT_PERIOD)
		pulse.tween_property(alert, "modulate:a", 0.12, ALERT_PERIOD)

	var mark_text := ""
	if not clash_info(world_state, id).is_empty():
		mark_text = Loc.t("ui.world_map.clash_mark")
	elif contested:
		mark_text = Loc.t("ui.world_map.contested_mark")
	if mark_text != "":
		var mark := Label.new()
		mark.name = "StateMark"
		mark.text = mark_text
		mark.theme_type_variation = &"WorldMeta"
		mark.mouse_filter = Control.MOUSE_FILTER_IGNORE
		mark.set_anchors_preset(Control.PRESET_TOP_RIGHT)
		mark.offset_left = -32.0
		mark.offset_right = -UiTheme.SPACE_2
		mark.offset_top = UiTheme.SPACE_1
		mark.offset_bottom = 20.0
		button.add_child(mark)

	var box_margin := MarginContainer.new()
	box_margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	box_margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UiKit.set_margins(box_margin, UiTheme.SPACE_3, UiTheme.SPACE_2,
		UiTheme.SPACE_3, UiTheme.SPACE_2)
	button.add_child(box_margin)

	var box := VBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_theme_constant_override("separation", UiTheme.SPACE_1)
	box_margin.add_child(box)

	var name_label := Label.new()
	name_label.name = "Name"
	name_label.theme_type_variation = &"WorldName"
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	name_label.clip_text = true
	name_label.text = _sector_name(id, discovered)
	box.add_child(name_label)

	var meta := Label.new()
	meta.name = "Meta"
	meta.theme_type_variation = &"WorldMeta"
	meta.mouse_filter = Control.MOUSE_FILTER_IGNORE
	meta.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	meta.max_lines_visible = 3
	meta.text = _sector_meta(rec, discovered)
	box.add_child(meta)

	if current:
		var here := Label.new()
		here.name = "Here"
		here.theme_type_variation = &"WorldMeta"
		here.mouse_filter = Control.MOUSE_FILTER_IGNORE
		here.text = Loc.t("ui.world_map.here")
		box.add_child(here)
	return button


func _on_cell_pressed(id: String) -> void:
	travel_requested.emit(id)
	close()


func _sector_name(id: String, discovered: int) -> String:
	if discovered < 1:
		return Loc.t("ui.world_map.unknown")
	var wm = load("res://scripts/world/world_map.gd")
	var key := str(wm.sector(id).get("name_key", ""))
	var text := Loc.t(key)
	return id.to_upper() if text == key else text


func _sector_meta(rec: Dictionary, discovered: int) -> String:
	if discovered < 1:
		return Loc.t("ui.world_map.unexplored")
	var parts: Array = []
	var tier := str(rec.get("tier", "hard"))
	parts.append(Loc.t("ui.world_map.tier." + tier))
	if bool(rec.get("capital", false)) or str(rec.get("capital_of", "")) != "":
		parts.append(Loc.t("ui.world_map.capital"))
	var owner := str(rec.get("owner", ""))
	if owner == "":
		parts.append(Loc.t("ui.world_map.contested"))
	else:
		parts.append(Loc.t("ui.world_map.faction." + owner))
	var outposts: Array = rec.get("outposts", []) as Array
	parts.append(Loc.f("ui.world_map.outposts", [outposts.size()]))
	var bus = get_node_or_null("/root/WorldBus")
	var world_state = bus.state if bus != null and "state" in bus else null
	var fights := clash_info(world_state, str(rec.get("id", "")))
	if not fights.is_empty():
		parts.append(Loc.f("ui.world_map.clash", [fights.size()]))
	if discovered < 2:
		parts.append(Loc.t("ui.world_map.scouted"))
	return " · ".join(parts)


func _tooltip(id: String, rec: Dictionary, discovered: int) -> String:
	var lines: Array = [_sector_name(id, discovered), _sector_meta(rec, discovered)]
	if id != Game.map_sector and discovered > 0:
		lines.append(Loc.t("ui.world_map.travel"))
	var wm = load("res://scripts/world/world_map.gd")
	var ns: Array = wm.neighbors(id)
	if not ns.is_empty():
		var names: Array = []
		for n in ns:
			var nid := str(n)
			var nrec: Dictionary = {}
			var bus = get_node_or_null("/root/WorldBus")
			if bus != null and "state" in bus and bus.state != null:
				nrec = bus.state.sector_state(nid)
			var nd := int(nrec.get("discovered", 0))
			names.append(_sector_name(nid, nd))
		lines.append(Loc.t("ui.world_map.neighbors") + ": " + ", ".join(names))
	return "\n".join(lines)
