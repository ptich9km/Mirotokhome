class_name NetPanel
extends CanvasLayer
## "Network game" window of the main menu (21.11, two modes since 22.11).
##
## MODE 1 — connection. Two roles: create a game (host) or connect by address.
## The host does NOT wait for the second player: as soon as the server is up the
## panel offers "choose a hero", and the other player may join later, including
## into a world that is already running.
##
## MODE 2 — hero picker. Every peer keeps its own characters on its own disk
## (`NetProfile`): the next session starts a fresh world (new seed), but the
## character keeps skills, spells, gold and equipment. A new hero goes through
## the usual character screen and is stored when the game starts.
##
## The connection itself lives on the root node NetSession, so it survives the
## menu -> picker -> loading -> world path.

signal closed

const PANEL_SIZE := Vector2(640, 480)
const DEFAULT_PORT := NetSession.DEFAULT_PORT

var _mode := "connect"          # connect | characters
var _session: NetSession
var _busy := false
var _chosen: Dictionary = {}
var _pending_start := false

var _root_box: VBoxContainer
var _status: Label
var _ip_edit: LineEdit
var _port_edit: LineEdit
var _host_btn: Button
var _join_btn: Button
var _continue_btn: Button
var _previous_focus: Control = null

func open() -> void:
	_session = NetSession.ensure()
	_previous_focus = UiKit.save_focus(self)
	_build()
	if _session != null and _session.is_online():
		_mode = "characters"
		_fill()
	if is_inside_tree():
		_focus_first.call_deferred()

func close() -> void:
	if _session != null:
		_session.leave()
	closed.emit()
	queue_free()

func _focus_first() -> void:
	var b := _first_button(_root_box)
	if b != null:
		b.grab_focus()

func _first_button(node: Node) -> Button:
	if node == null:
		return null
	for c in node.get_children():
		if c is Button and (c as Button).visible and not (c as Button).disabled:
			return c
		var deep := _first_button(c)
		if deep != null:
			return deep
	return null

# --- shell -------------------------------------------------------------------

func _build() -> void:
	name = "NetPanel"
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

	_root_box = VBoxContainer.new()
	_root_box.add_theme_constant_override("separation", 10)
	margin.add_child(_root_box)
	_fill()

## Rebuild the body only: the shell (dim + centered panel) stays.
func _fill() -> void:
	for c in _root_box.get_children():
		_root_box.remove_child(c)
		c.queue_free()
	var title := Label.new()
	title.theme_type_variation = &"CsTitle"
	title.text = Loc.t("ui.net.title") if _mode == "connect" else Loc.t("ui.net.char.title")
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_root_box.add_child(title)
	if _mode == "connect":
		_fill_connect()
	else:
		_fill_characters()
	if is_inside_tree():
		_focus_first.call_deferred()

func _build_back_button() -> void:
	var back := Button.new()
	back.theme_type_variation = &"CsStart"
	back.text = Loc.t("ui.common.back")
	back.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	back.pressed.connect(close)
	_root_box.add_child(back)

func _unhandled_input(event: InputEvent) -> void:
	if UiKit.esc_pressed(event):
		close()
		get_viewport().set_input_as_handled()

# --- mode 1: connection ------------------------------------------------------

func _fill_connect() -> void:
	var hint := Label.new()
	hint.theme_type_variation = &"CsDesc"
	hint.text = Loc.t("ui.net.body")
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.custom_minimum_size = Vector2(PANEL_SIZE.x - 60, 0)
	_root_box.add_child(hint)

	var addr_row := HBoxContainer.new()
	addr_row.add_theme_constant_override("separation", 10)
	_root_box.add_child(addr_row)
	var addr_label := Label.new()
	addr_label.theme_type_variation = &"CsDesc"
	addr_label.text = Loc.t("ui.net.address")
	addr_row.add_child(addr_label)
	_ip_edit = LineEdit.new()
	_ip_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_ip_edit.text = "127.0.0.1"
	_ip_edit.placeholder_text = "192.168.0.10"
	addr_row.add_child(_ip_edit)
	_port_edit = LineEdit.new()
	_port_edit.custom_minimum_size = Vector2(90, 0)
	_port_edit.text = str(DEFAULT_PORT)
	addr_row.add_child(_port_edit)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	_root_box.add_child(row)
	_host_btn = Button.new()
	_host_btn.theme_type_variation = &"CsStart"
	_host_btn.text = Loc.t("ui.net.host")
	_host_btn.custom_minimum_size = Vector2(0, 46)
	_host_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_host_btn.pressed.connect(_on_host)
	row.add_child(_host_btn)
	_join_btn = Button.new()
	_join_btn.theme_type_variation = &"CsStart"
	_join_btn.text = Loc.t("ui.net.join")
	_join_btn.custom_minimum_size = Vector2(0, 46)
	_join_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_join_btn.pressed.connect(_on_join)
	row.add_child(_join_btn)

	# Shown only once the server is up: the host does not have to wait for anyone.
	_continue_btn = Button.new()
	_continue_btn.theme_type_variation = &"CsStart"
	_continue_btn.text = Loc.t("ui.net.choose_hero")
	_continue_btn.custom_minimum_size = Vector2(0, 44)
	_continue_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_continue_btn.visible = false
	_continue_btn.pressed.connect(_open_characters)
	_root_box.add_child(_continue_btn)

	_status = Label.new()
	_status.theme_type_variation = &"CsDesc"
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.custom_minimum_size = Vector2(PANEL_SIZE.x - 60, 64)
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_root_box.add_child(_status)

	_build_back_button()
	if _session != null and _session.is_online():
		_show_status(Loc.t("ui.net.connected"))

func _port() -> int:
	var p := int(_port_edit.text.strip_edges())
	if p < 1024 or p > 65535:
		p = DEFAULT_PORT
	return p

func _on_host() -> void:
	if _busy:
		return
	_busy = true
	_set_buttons_enabled(false)
	var err := _session.host(_port())
	if err != "":
		_show_status(err)
		_busy = false
		_set_buttons_enabled(true)
		return
	_show_status(Loc.f("ui.net.waiting_peer", [str(_port())]) + "\n"
		+ Loc.f("ui.net.your_ip", [_local_ip()]) + "\n"
		+ Loc.t("ui.net.host_hint"))
	if _continue_btn != null:
		_continue_btn.visible = true
		_continue_btn.disabled = false
		_continue_btn.grab_focus()
	if not _session.peer_joined.is_connected(_on_peer_joined):
		_session.peer_joined.connect(_on_peer_joined)

func _on_join() -> void:
	if _busy:
		return
	_busy = true
	_set_buttons_enabled(false)
	_show_status(Loc.t("ui.net.connecting"))
	_session.connected_ok.connect(_on_connected, CONNECT_ONE_SHOT)
	_session.connect_failed.connect(_on_failed, CONNECT_ONE_SHOT)
	_session.server_lost.connect(_on_failed, CONNECT_ONE_SHOT)
	var err := _session.join(_ip_edit.text, _port())
	if err != "":
		_show_status(err)
		_busy = false
		_set_buttons_enabled(true)

func _on_peer_joined(_id: int) -> void:
	# The host may stay here or already be playing; we never move the host.
	_show_status(Loc.t("ui.net.peer_joined") + "\n" + Loc.t("ui.net.host_hint"))

func _on_connected() -> void:
	_open_characters()

func _on_failed() -> void:
	_busy = false
	_set_buttons_enabled(true)
	_show_status(Loc.t("ui.net.failed"))

func _set_buttons_enabled(on: bool) -> void:
	if _host_btn != null:
		_host_btn.disabled = not on
	if _join_btn != null:
		_join_btn.disabled = not on
	if _ip_edit != null:
		_ip_edit.editable = on
	if _port_edit != null:
		_port_edit.editable = on

func _show_status(text: String) -> void:
	if _status != null:
		_status.text = text

func _local_ip() -> String:
	for addr in IP.get_local_addresses():
		var a := str(addr)
		if a.contains(":"):
			continue
		if a.begins_with("127.") or a.begins_with("169.254."):
			continue
		return a
	return "127.0.0.1"

# --- mode 2: hero picker -----------------------------------------------------

func _open_characters() -> void:
	_mode = "characters"
	_fill()

func _fill_characters() -> void:
	var hint := Label.new()
	hint.theme_type_variation = &"CsDesc"
	hint.text = Loc.t("ui.net.char.body")
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.custom_minimum_size = Vector2(PANEL_SIZE.x - 60, 0)
	_root_box.add_child(hint)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, 210)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_root_box.add_child(scroll)

	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 6)
	scroll.add_child(list)

	var heroes := NetProfile.load_all()
	if heroes.is_empty():
		var none := Label.new()
		none.theme_type_variation = &"CsDesc"
		none.text = Loc.t("ui.net.char.none")
		none.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		list.add_child(none)
	for profile in heroes:
		list.add_child(_hero_row(profile))

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	_root_box.add_child(row)
	var create := Button.new()
	create.theme_type_variation = &"CsStart"
	create.text = Loc.t("ui.net.char.create")
	create.custom_minimum_size = Vector2(0, 44)
	create.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	create.pressed.connect(_on_create_hero)
	row.add_child(create)

	_status = Label.new()
	_status.theme_type_variation = &"CsDesc"
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.custom_minimum_size = Vector2(PANEL_SIZE.x - 60, 40)
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_root_box.add_child(_status)
	if not _session.is_host() and not _session.world.is_empty():
		_show_status(Loc.t("ui.net.char.world_ready"))

	_build_back_button()
	if not _session.world_config.is_connected(_on_world_ready):
		_session.world_config.connect(_on_world_ready)

func _hero_row(profile: Dictionary) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var text := Label.new()
	text.theme_type_variation = &"InvRowLabel"
	text.text = str(profile.get("name", "?"))
	text.custom_minimum_size = Vector2(150, 0)
	row.add_child(text)
	var desc := Label.new()
	desc.theme_type_variation = &"CsDesc"
	desc.text = NetProfile.summary(profile)
	desc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	row.add_child(desc)
	var play := Button.new()
	play.text = Loc.t("ui.net.char.play")
	play.custom_minimum_size = Vector2(110, 36)
	play.pressed.connect(func() -> void: _start_with(profile))
	row.add_child(play)
	var del := Button.new()
	del.text = Loc.t("ui.net.char.delete")
	del.custom_minimum_size = Vector2(100, 36)
	del.pressed.connect(func() -> void:
		NetProfile.remove(str(profile.get("name", "")))
		_fill())
	row.add_child(del)
	return row

func _on_create_hero() -> void:
	# The connection stays alive; character_select stores the new hero when the
	# player presses "Start" (both host and client paths, 22.11).
	get_tree().change_scene_to_file("res://scenes/character_select.tscn")

## The host's world, once it exists, is also broadcast; the client only waits
## for that message when it has to (the host is still choosing).
func _on_world_ready(_seed: int, _zone: String, _ws: int, _sector: String, _race: String) -> void:
	if _mode != "characters":
		return
	_show_status(Loc.t("ui.net.char.world_ready"))
	if _pending_start:
		_start_client()

func _start_with(profile: Dictionary) -> void:
	_chosen = profile
	if _session.is_host():
		_start_host()
		return
	_pending_start = true
	if _session.world.is_empty():
		_show_status(Loc.t("ui.net.waiting_host"))
		return
	_start_client()

func _start_host() -> void:
	# A fresh world every session (player's rule: the seed starts from zero), the
	# character comes from the saved profile.
	var setup := StartSetup.new()
	var err := setup.apply()
	if err != "":
		_show_status(err)
		return
	Game.net_map_race = MapGenerator.city_race_for_hero(str(_chosen.get("race", "human")))
	NetProfile.apply(_chosen)
	Game.pending_party = []
	_session.send_world_config(Game.map_seed, Game.map_zone, Game.world_seed,
		Game.map_sector, Game.net_map_race)
	get_tree().change_scene_to_file("res://scenes/loading.tscn")

func _start_client() -> void:
	var w: Dictionary = _session.world
	if w.is_empty():
		_show_status(Loc.t("ui.net.waiting_host"))
		return
	Game.map_seed = int(w.get("seed", 0))
	Game.map_zone = str(w.get("zone", "start"))
	Game.world_seed = int(w.get("world_seed", 0))
	Game.map_sector = str(w.get("sector", ""))
	Game.net_map_race = str(w.get("race", ""))
	Game.pending_map_path = ""
	Game.clear_load_position()
	Game.clear_hero_save()
	NetProfile.apply(_chosen)
	var bus = get_node_or_null("/root/WorldBus")
	if bus != null and bus.state != null:
		bus.state.reset_for_new_game()
	get_tree().change_scene_to_file("res://scenes/loading.tscn")
