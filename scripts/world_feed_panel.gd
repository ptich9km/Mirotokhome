# ============================================================================
# WorldFeedPanel — лента мира в левом нижнем углу (F3).
#
# Это не только отладка: игрок видит, кому принадлежит сектор, что происходит
# в SIM, о чём говорят НПЦ, и куда сходить в городе. F3 добавляет техническую
# строку (генерация/кадры/узлы), обычный режим — только мир и лента.
#
# Окно некликабельно, автообновление без скролла, размеры — доли вьюпорта:
# ширина 28% (320..460), высота 25% (170..280), отступ от края 2 px.
# Без class_name: грузится load()-по-пути.
# ============================================================================
extends CanvasLayer

const W_FRAC := 0.28
const H_FRAC := 0.25
const W_MIN := 320.0
const W_MAX := 460.0
const H_MIN := 170.0
const H_MAX := 280.0
const EDGE := 2.0
const REFRESH := 0.25
const FEED_LINES := 8
const CHATTER_MIN := 140.0
const CHATTER_MAX := 300.0

var _panel: PanelContainer
var _text: RichTextLabel
var _acc := 0.0
var _debug := false
var _chatter_left := 0.0
var _guide_timer := 0.0
var _journal_seen := -1
var _owner_seen: Dictionary = {}
var _guided: Dictionary = {}
var _data: Dictionary = {}
var _rng := RandomNumberGenerator.new()
var _feed_script: GDScript


func setup() -> void:
	layer = 40
	process_mode = Node.PROCESS_MODE_ALWAYS
	_feed_script = load("res://scripts/world/world_feed.gd")
	_rng.randomize()
	_chatter_left = _rng.randf_range(CHATTER_MIN, CHATTER_MAX)
	_load_data()
	_build()
	_apply_rect()
	set_process(true)


func _ready() -> void:
	var vp := get_viewport()
	if vp != null and not vp.size_changed.is_connected(_apply_rect):
		vp.size_changed.connect(_apply_rect)
	_apply_rect()
	_refresh()


func _load_data() -> void:
	var f := FileAccess.open("res://assets/lore/npc_chatter.json", FileAccess.READ)
	if f == null:
		_data = {}
		return
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	_data = parsed as Dictionary if parsed is Dictionary else {}


func _build() -> void:
	_panel = PanelContainer.new()
	_panel.name = "FeedPanel"
	_panel.theme = _make_theme()
	_panel.theme_type_variation = &"FeedPanel"
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.clip_contents = true
	add_child(_panel)

	var margin := MarginContainer.new()
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UiKit.set_margins(margin, int(EDGE), int(EDGE), int(EDGE), int(EDGE))
	_panel.add_child(margin)

	_text = RichTextLabel.new()
	_text.name = "Text"
	_text.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_text.bbcode_enabled = false
	_text.fit_content = false
	_text.scroll_active = false
	_text.add_theme_font_size_override("normal_font_size", UiTheme.FONT_MICRO)
	_text.add_theme_color_override("default_color", UiTheme.TEXT)
	margin.add_child(_text)


func _make_theme() -> Theme:
	var theme := UiTheme.app_theme()
	var style := UiKit.panel_style(UiTheme.BG_DEEP, UiTheme.PANEL_EDGE.darkened(0.2),
		UiTheme.RADIUS_SLOT, 1)
	style.bg_color.a = 0.86
	theme.set_stylebox("panel", "FeedPanel", style)
	return theme


func _apply_rect() -> void:
	if _panel == null:
		return
	var vp := get_viewport()
	var size := vp.get_visible_rect().size if vp != null else Vector2(1280, 800)
	var w := clampf(size.x * W_FRAC, W_MIN, W_MAX)
	var h := clampf(size.y * H_FRAC, H_MIN, H_MAX)
	_panel.anchor_left = 0.0
	_panel.anchor_top = 1.0
	_panel.anchor_right = 0.0
	_panel.anchor_bottom = 1.0
	_panel.offset_left = EDGE
	_panel.offset_right = EDGE + w
	_panel.offset_top = -EDGE - h
	_panel.offset_bottom = -EDGE


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo \
			and event.keycode == KEY_F3:
		_debug = not _debug
		_refresh()
		get_viewport().set_input_as_handled()


func is_debug() -> bool:
	return _debug


func _process(delta: float) -> void:
	_acc += delta
	if _acc >= REFRESH:
		_acc = 0.0
		_refresh()
	# Болтовня НПЦ: 2–3 сообщения за 10 минут, не пачкой.
	if not get_tree().paused:
		_chatter_left -= delta
		if _chatter_left <= 0.0:
			_chatter_left = _rng.randf_range(CHATTER_MIN, CHATTER_MAX)
			_chatter()
		_guide_timer -= delta
		if _guide_timer <= 0.0:
			_guide_timer = 1.0
			_city_guide()


func _refresh() -> void:
	if _text == null:
		return
	var bus := get_node_or_null("/root/WorldBus")
	var state = bus.state if bus != null and "state" in bus else null
	if state != null:
		_sync_journal(state)
		_sync_owners(state)
	var wm := Game._world_map()
	var sector := str(Game.map_sector)
	var s: Dictionary = wm.sector(sector)
	var name_key := str(s.get("name_key", ""))
	var sector_name := Loc.t(name_key)
	if sector_name == name_key:
		sector_name = sector if sector != "" else "—"
	var owner := str(s.get("owner", ""))
	var owner_text := Loc.t("ui.world_map.contested") if owner == "" \
		else Loc.t("ui.world_map.faction." + owner)
	var fps := int(round(Performance.get_monitor(Performance.TIME_FPS)))
	var day := 0 if state == null else int(state.day)

	var lines: Array[String] = []
	lines.append("%s · %s · %d FPS" % [sector_name, owner_text, fps])
	var feed: Array = _feed_script.tail(FEED_LINES) if _feed_script != null else []
	for raw in feed:
		var rec: Dictionary = raw as Dictionary
		var kind := str(rec.get("kind", "world"))
		var prefix := _kind_prefix(kind)
		lines.append(Loc.f("ui.feed.day", [day, prefix, str(rec.get("text", ""))]))
	if lines.size() <= 1:
		lines.append(Loc.t("ui.feed.empty"))
	if _debug:
		var stats: Dictionary = MapGenerator.last_stats
		var gen_ms := int(stats.get("total_ms", 0)) if not stats.is_empty() else 0
		lines.append("gen %dms · npc %d · en %d · draw %d · nodes %d" % [
			gen_ms, Game.npcs.size(), Game.enemies.size(),
			int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
			int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))])
	_text.text = "\n".join(lines)


func _kind_prefix(kind: String) -> String:
	match kind:
		"npc": return ""
		"sim": return Loc.t("ui.feed.kind.sim")
		"you": return Loc.t("ui.feed.kind.you")
		"chat": return Loc.t("ui.feed.kind.chat")
		_: return Loc.t("ui.feed.kind.world")


func _sync_journal(state) -> void:
	var journal: Array = state.journal
	if _journal_seen < 0 or _journal_seen > journal.size():
		_journal_seen = journal.size()
		return
	if journal.size() <= _journal_seen:
		return
	for i in range(_journal_seen, journal.size()):
		var j: Dictionary = journal[i]
		_post("sim", str(j.get("text", "")))
	_journal_seen = journal.size()


func _sync_owners(state) -> void:
	var wm := Game._world_map()
	for id in state.sectors:
		var sid := str(id)
		var o := str((state.sectors[id] as Dictionary).get("owner", ""))
		if _owner_seen.has(sid) and str(_owner_seen[sid]) != o and o != "":
			var info: Dictionary = wm.sector(sid)
			var key := str(info.get("name_key", ""))
			var name := Loc.t(key)
			if name == key:
				name = sid
			_post("world", Loc.f("ui.feed.owner_changed", [name,
				Loc.t("ui.world_map.faction." + o)]))
		_owner_seen[sid] = o


func _chatter() -> void:
	var npc = _nearby_npc()
	if npc == null:
		return
	var data: Dictionary = _data
	var race := MapGenerator.race_of_set(str(npc.get("anim_set")))
	var role := str(npc.get("role"))
	var pool: Array = []
	if role != "" and (data.get("roles", {}) as Dictionary).has(role) and _rng.randf() < 0.35:
		pool = (data.get("roles", {}) as Dictionary)[role] as Array
	elif race != "" and data.has(race):
		pool = data[race] as Array
	if pool.is_empty():
		pool = data.get("generic", []) as Array
	if pool.is_empty():
		return
	var rec: Dictionary = pool[_rng.randi_range(0, pool.size() - 1)]
	var text := str(rec.get("ru", "")) if Loc.locale() == "ru" else str(rec.get("en", ""))
	if text == "":
		return
	var speaker_key := role
	if bool(npc.get("is_archmage")):
		speaker_key = "archmage"
	elif bool(npc.get("is_city_head")):
		speaker_key = "head"
	var speaker := Loc.t("ui.feed.speaker." + speaker_key) if speaker_key != "" \
		else Loc.t("ui.feed.speaker.citizen")
	_post("npc", "%s: «%s»" % [speaker, text])


func _nearby_npc():
	var best = null
	var best_d := 700.0 * 700.0
	for raw in Game.npcs:
		if not is_instance_valid(raw):
			continue
		var n: Node2D = raw as Node2D
		if n == null or Game.hero == null:
			continue
		var d: float = n.global_position.distance_squared_to(Game.hero.global_position)
		if d < best_d:
			best_d = d
			best = n
	return best


func _city_guide() -> void:
	var sector := str(Game.map_sector)
	if sector == "" or _guided.has(sector):
		return
	var has_head := false
	var has_mage := false
	for raw in Game.npcs:
		if not is_instance_valid(raw):
			continue
		var n = raw
		if bool(n.get("is_city_head")):
			has_head = true
		if bool(n.get("is_archmage")):
			has_mage = true
		if has_head or has_mage:
			break
	if not has_head and not has_mage:
		return
	_guided[sector] = true
	var guides: Array = _data.get("guides", []) as Array
	if guides.is_empty():
		return
	var rec: Dictionary = guides[_rng.randi_range(0, guides.size() - 1)]
	var text := str(rec.get("ru", "")) if Loc.locale() == "ru" else str(rec.get("en", ""))
	if text != "":
		_post("world", text)


func _post(kind: String, text: String) -> void:
	if text == "" or _feed_script == null:
		return
	_feed_script.post(kind, text)
