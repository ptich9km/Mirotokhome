class_name ArchmagePanel
extends CanvasLayer
## Панель великих магов: военная плата (GDD docs/lore/gdd_archmage.md).
##
## Маг в городе — капитан (NPC `is_archmage`), спрайт `ork_mage_a52/tN` по ступени.
## Источник данных — WorldBus.state.factions[...]["archmage"] (тик по реальному
## времени, sim-мир не тикает). Ставки: слиток / золото / зелье.

signal closed
signal inventory_changed

var player: Player
var _race := ""                 # раса ГОРОДА (не героя): у каждой свой маг
var _city_id := ""              # город, из которого открыли панель ("" — любой)
var _root: MarginContainer
var _panel: PanelContainer
var _name_label: Label
var _city_label: Label
var _rep_label: Label
var _portrait: TextureRect
var _power_bar: ProgressBar
var _power_label: Label
var _stance_label: Label
var _speech_label: Label
var _status_label: Label
var _btn_ingot: Button
var _btn_gold: Button
var _btn_potion: Button
var _close_button: Button
var _previous_focus: Control
var _last_tier := -1

## Tier names are localization KEYS: a const cannot call `Loc.t()`.
const TIER_LABELS := ["ui.mage.tier.0", "ui.mage.tier.1", "ui.mage.tier.2", "ui.mage.tier.3"]


## city_race — раса города, в котором стоит капитан. Пусто — панель открыта не
## из города (тесты, старые вызовы): тогда берём расу героя, как раньше.
func setup(p: Player, city_id: String = "", city_race: String = "") -> void:
	player = p
	_city_id = city_id
	_race = city_race
	layer = 10
	_build_ui()


func _ready() -> void:
	_previous_focus = UiKit.save_focus(self)
	_last_tier = -1
	_refresh()
	_btn_ingot.call_deferred("grab_focus")


func _archmage() -> Dictionary:
	var bus := get_node_or_null("/root/WorldBus")
	if bus == null or bus.state == null:
		return {}
	var axis := _race if _race != "" else Game.hero_race
	return bus.state.get_archmage(axis)


func _ws_script() -> GDScript:
	return load("res://scripts/world/world_state.gd") as GDScript


func _build_ui() -> void:
	var dim := UiKit.make_dim(0.58)
	add_child(dim)

	_root = MarginContainer.new()
	_root.name = "ArchmageRoot"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UiKit.set_margins(_root, UiTheme.SCREEN_INSET, UiTheme.SCREEN_INSET,
		UiTheme.SCREEN_INSET, UiTheme.SCREEN_INSET)
	_root.theme = _make_theme()
	add_child(_root)

	var center := HBoxContainer.new()
	center.name = "Center"
	center.alignment = BoxContainer.ALIGNMENT_CENTER
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(center)
	var side := Control.new()
	side.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	side.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.add_child(side)

	_panel = PanelContainer.new()
	_panel.name = "Panel"
	_panel.theme_type_variation = &"ArchmagePanel"
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_panel.custom_minimum_size = Vector2(520, 420)
	_panel.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_panel.size_flags_vertical = Control.SIZE_SHRINK_CENTER
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

	var title := Label.new()
	title.name = "Title"
	title.theme_type_variation = &"ArchmageTitle"
	title.text = Loc.t("ui.mage.title")
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	content.add_child(title)

	var head := HBoxContainer.new()
	head.name = "Head"
	head.alignment = BoxContainer.ALIGNMENT_CENTER
	head.add_theme_constant_override("separation", UiTheme.SPACE_4)
	content.add_child(head)

	_portrait = TextureRect.new()
	_portrait.name = "Portrait"
	_portrait.custom_minimum_size = Vector2(72, 80)
	_portrait.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_portrait.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_portrait.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_portrait.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	head.add_child(_portrait)

	var head_col := VBoxContainer.new()
	head_col.name = "HeadCol"
	head_col.alignment = BoxContainer.ALIGNMENT_CENTER
	head_col.add_theme_constant_override("separation", UiTheme.SPACE_1)
	head_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(head_col)

	_name_label = Label.new()
	_name_label.name = "MageName"
	_name_label.theme_type_variation = &"ArchmageName"
	_name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	head_col.add_child(_name_label)

	_city_label = Label.new()
	_city_label.name = "CityName"
	_city_label.theme_type_variation = &"ArchmageCity"
	_city_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	head_col.add_child(_city_label)

	_rep_label = Label.new()
	_rep_label.name = "Reputation"
	_rep_label.theme_type_variation = &"ArchmageCity"
	_rep_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	head_col.add_child(_rep_label)

	_power_bar = ProgressBar.new()
	_power_bar.name = "PowerBar"
	_power_bar.min_value = 0.0
	_power_bar.max_value = 100.0
	_power_bar.show_percentage = false
	_power_bar.custom_minimum_size = Vector2(0, 22)
	content.add_child(_power_bar)

	_power_label = Label.new()
	_power_label.name = "PowerLabel"
	_power_label.theme_type_variation = &"ArchmagePower"
	_power_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	content.add_child(_power_label)

	_stance_label = Label.new()
	_stance_label.name = "StanceLabel"
	_stance_label.theme_type_variation = &"ArchmageStance"
	_stance_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	content.add_child(_stance_label)

	_speech_label = Label.new()
	_speech_label.name = "Speech"
	_speech_label.theme_type_variation = &"ArchmageSpeech"
	_speech_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_speech_label.custom_minimum_size = Vector2(0, 72)
	content.add_child(_speech_label)

	var stakes := VBoxContainer.new()
	stakes.name = "Stakes"
	stakes.add_theme_constant_override("separation", UiTheme.SPACE_2)
	content.add_child(stakes)

	_btn_ingot = _make_stake_button(Loc.t("ui.mage.stake_ingot"), _on_stake_ingot)
	stakes.add_child(_btn_ingot)
	_btn_gold = _make_stake_button(Loc.f("ui.mage.stake_gold", [_gold_per_stake()]), _on_stake_gold)
	stakes.add_child(_btn_gold)
	_btn_potion = _make_stake_button(Loc.t("ui.mage.stake_potion"), _on_stake_potion)
	stakes.add_child(_btn_potion)

	_status_label = Label.new()
	_status_label.name = "Status"
	_status_label.theme_type_variation = &"ArchmageStatus"
	_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status_label.custom_minimum_size = Vector2(0, 36)
	content.add_child(_status_label)

	var row := HBoxContainer.new()
	row.name = "Buttons"
	row.add_theme_constant_override("separation", UiTheme.SPACE_2)
	content.add_child(row)

	_close_button = Button.new()
	_close_button.name = "Close"
	_close_button.text = Loc.t("ui.btn.close")
	_close_button.theme_type_variation = &"ArchmageClose"
	_close_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_close_button.pressed.connect(close)
	row.add_child(_close_button)


func _make_stake_button(text: String, handler: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.theme_type_variation = &"ArchmageStake"
	b.custom_minimum_size = Vector2(0, 34)
	b.pressed.connect(handler)
	return b


func _make_theme() -> Theme:
	var theme := UiTheme.app_theme()
	UiKit.add_panel(theme, &"ArchmagePanel",
		UiTheme.PANEL_BG, UiTheme.PANEL_EDGE, UiTheme.RADIUS_PANEL)
	UiKit.add_label(theme, &"ArchmageTitle", UiTheme.ACCENT, UiTheme.FONT_TITLE)
	UiKit.add_label(theme, &"ArchmageName", UiTheme.TEXT, UiTheme.FONT_SECTION)
	UiKit.add_label(theme, &"ArchmageCity", UiTheme.TEXT_MUTED, UiTheme.FONT_BODY)
	UiKit.add_label(theme, &"ArchmagePower", UiTheme.TEXT, UiTheme.FONT_SUBHEAD)
	UiKit.add_label(theme, &"ArchmageStance", UiTheme.TEXT_MUTED, UiTheme.FONT_BODY)
	UiKit.add_label(theme, &"ArchmageSpeech", UiTheme.TEXT, UiTheme.FONT_BODY)
	UiKit.add_label(theme, &"ArchmageStatus", UiTheme.TEXT_MUTED, UiTheme.FONT_MICRO)
	UiKit.add_button(theme, &"ArchmageStake",
		UiTheme.PANEL_INNER, UiTheme.ACCENT_DIM,
		UiTheme.PANEL_INNER.lightened(0.14), UiTheme.ACCENT,
		UiTheme.RADIUS_SLOT, UiTheme.SPACE_2)
	UiKit.add_button(theme, &"ArchmageClose",
		UiTheme.PANEL_INNER, UiTheme.PANEL_EDGE.darkened(0.25),
		UiTheme.PANEL_INNER.lightened(0.12), UiTheme.ACCENT_DIM,
		UiTheme.RADIUS_SLOT, UiTheme.SPACE_2)
	return theme


func _refresh() -> void:
	var am := _archmage()
	var axis := _race if _race != "" else Game.hero_race
	if _rep_label != null:
		_rep_label.text = Loc.f("ui.mage.standing",
			[Lore.faction_label(axis), Game.hero_reputation(axis)])
	if am.is_empty():
		_name_label.text = Loc.t("ui.mage.unavailable")
		_city_label.text = Lore.faction_city(axis)
		_power_label.text = ""
		_stance_label.text = ""
		_speech_label.text = Loc.t("ui.mage.none_here")
		_set_stake_enabled(false, false, false)
		if _portrait != null:
			_portrait.texture = null
			_portrait.visible = false
		return
	var power := float(am.get("power", 0.0))
	var tier := int(am.get("tier", 0))
	var max_power := 100.0
	var cfg := ConfigFile.new()
	if cfg.load("res://assets/config/game.cfg") == OK:
		max_power = float(cfg.get_value("archmage", "power_max", 100.0))
	_power_bar.max_value = max_power
	_power_bar.value = power
	_name_label.text = str(am.get("name", Loc.t("ui.mage.name_default")))
	_city_label.text = str(am.get("city", ""))
	_power_label.text = Loc.f("ui.mage.power", [
		int(round(power)), int(max_power), tier,
		Loc.t(str(TIER_LABELS[clampi(tier, 0, TIER_LABELS.size() - 1)])),
	])
	_stance_label.text = Loc.f("ui.mage.stance", [
		Loc.t("ui.mage.stance.offensive") if str(am.get("stance", "")) == "offensive"
		else Loc.t("ui.mage.stance.defence")])
	if not _speech_label.text.begins_with(Loc.t("ui.mage.speech_begin")):
		_speech_label.text = Loc.t("ui.mage.speech")
	_speak_if_tier_changed(tier)
	_set_portrait(tier)
	_sync_captain_sprite(tier)
	var full := power >= max_power - 0.01
	_set_stake_enabled(not full, not full and _has_gold_stake(), not full and _find_stake_key("potion") != "")
	if full:
		_status_label.text = Loc.t("ui.mage.full")
	else:
		_status_label.text = ""


func _speak_if_tier_changed(tier: int) -> void:
	if _last_tier < 0:
		_last_tier = tier
		return
	if tier == _last_tier:
		return
	_last_tier = tier
	var lines: Array = Lore.archmage_speech(Game.hero_race, "idle")
	if lines.is_empty():
		lines = Lore.archmage_speech(Game.hero_race, "greet")
	if lines.is_empty():
		return
	_speech_label.text = Loc.f("ui.mage.quote", [str(lines[randi() % lines.size()])])


func _set_portrait(tier: int) -> void:
	if _portrait == null:
		return
	var set_name := _captain_set(tier)
	var path := UnitDB.frame_path(set_name, "sprites", 1)
	var tex: Texture2D = null
	if ResourceLoader.exists(path):
		tex = load(path) as Texture2D
	_portrait.texture = tex
	_portrait.visible = tex != null


## Набор капитана = его собственная раса, ступень = tier.
##
## Раньше здесь было жёстко "ork_mage_a52/t%d": в druid-городе маг превращался
## в орка (жалоба игрока 09.10), и это же ломало сам NPC на карте — _sync_
## captain_sprite переписывал anim_set живого капитана. Теперь раса берётся
## у реального NPC, а если его нет (панель открыта не из города) — у расы
## героя через таблицу CITY_POPULATION.
func _captain_set(tier: int) -> String:
	var race := _captain_race()
	var t := clampi(tier, 0, 3)
	if race != "" and MapGenerator.CITY_POPULATION.has(race):
		return str((MapGenerator.CITY_POPULATION[race] as Dictionary).get("captain", ""))
	return "ork_mage_a52/t%d" % t


## Раса капитана из живого NPC-архмага. Сначала ищем мага СВОЕГО города
## (city_id), иначе первого на карте, иначе расу панели/героя.
func _captain_race() -> String:
	if _city_id != "":
		for n in Game.npcs:
			if not is_instance_valid(n) or not bool(n.get("is_archmage")):
				continue
			if str(n.get("city_id")) == _city_id:
				return MapGenerator.race_of_set(str((n as Npc).anim_set))
	for n in Game.npcs:
		if not is_instance_valid(n):
			continue
		if bool(n.get("is_archmage")):
			return MapGenerator.race_of_set(str((n as Npc).anim_set))
	if _race != "":
		return _race
	# Запасной путь: панель могли открыть не из города (тесты, save-load).
	return MapGenerator.city_race_for_hero(Game.hero_race)


func _sync_captain_sprite(tier: int) -> void:
	var scene := get_tree().current_scene
	if scene == null:
		return
	# Ничего не переписываем: капитан уже стоит со своим набором от
	# генератора. Прежний код подставлял ork_mage_a52/tN каждому архмагу и
	# ломал даже druid-город.


func _set_stake_enabled(ingot: bool, gold: bool, potion: bool) -> void:
	_btn_ingot.disabled = not ingot
	_btn_gold.disabled = not gold
	_btn_potion.disabled = not potion


func _has_gold_stake() -> bool:
	if not is_instance_valid(player):
		return false
	return player.gold >= _gold_per_stake()


## Gold the mage takes per stake: read from the SIM script so the button, the
## check and the deduction cannot disagree.
func _gold_per_stake() -> int:
	var ws := _ws_script()
	return int(ws.archmage_gold_per_stake()) if ws != null else 100


func _find_stake_key(kind: String) -> String:
	if not is_instance_valid(player):
		return ""
	for raw in player.inventory:
		var key := str(raw)
		var item := ItemDB.find(key)
		if item.is_empty():
			continue
		if kind == "ingot" and str(item.get("type", "")) == "Ingot":
			return key
		if kind == "potion" and str(item.get("quality", "")) == "Potion":
			return key
	return ""


func _stake_amount(kind: String) -> float:
	var ws := _ws_script()
	if ws == null:
		return 0.0
	return float(ws.archmage_stake(kind))


func _do_stake(kind: String) -> void:
	var bus := get_node_or_null("/root/WorldBus")
	if bus == null or bus.state == null or not is_instance_valid(player):
		return
	var am: Dictionary = bus.state.get_archmage(Game.hero_race)
	if am.is_empty():
		return
	if float(am.get("power", 0.0)) >= 100.0:
		_status_label.text = Loc.t("ui.mage.full")
		return
	var amount := _stake_amount(kind)
	if amount <= 0.0:
		_status_label.text = Loc.t("ui.mage.no_stake")
		return
	if kind == "gold":
		var gps := _gold_per_stake()
		if player.gold < gps:
			_status_label.text = Loc.t("ui.mage.no_gold")
			return
		player.gold -= gps
	else:
		var key := _find_stake_key(kind)
		if key == "":
			_status_label.text = Loc.t("ui.mage.nothing")
			return
		player.remove_item(key)
	var tier_delta: int = bus.state.add_archmage_power(Game.hero_race, amount)
	SoundDB.play("ui.error")
	if tier_delta > 0:
		_status_label.text = Loc.f("ui.mage.grown", [tier_delta])
	elif tier_delta < 0:
		_status_label.text = Loc.t("ui.mage.weaker")
	else:
		_status_label.text = Loc.t("ui.mage.accepted")
	_last_tier = int(bus.state.get_archmage(Game.hero_race).get("tier", _last_tier))
	_refresh()
	inventory_changed.emit()


func _on_stake_ingot() -> void:
	_do_stake("ingot")


func _on_stake_gold() -> void:
	_do_stake("gold")


func _on_stake_potion() -> void:
	_do_stake("potion")


func _input(event: InputEvent) -> void:
	if UiKit.esc_pressed(event):
		close()
		get_viewport().set_input_as_handled()


func close() -> void:
	UiKit.restore_focus(_previous_focus)
	closed.emit()
	queue_free()
