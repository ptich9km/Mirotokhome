class_name InnPanel
extends CanvasLayer

signal closed

const MAX_PARTY := 4
## Mercenary candidates by tier (weaker -> stronger). Data, not a constant:
## a mod can add its own set to the inn (`inn.candidates` in
## assets/config/content_rules.json).
func _candidate_sets() -> Array:
	return ContentRules.list("inn.candidates")

## Dialogue lines live in `assets/locale/ui.json` so the subtitle follows the UI
## language; the index also picks the voice take (`voice.npc.inn.N`).
const TALK_LINE_KEYS := [
	"ui.talk.inn.1",
	"ui.talk.inn.2",
	"ui.talk.inn.3",
	"ui.talk.inn.4",
	"ui.talk.inn.5",
	"ui.talk.inn.6",
]
## 05.10: JPEG taverna.jpeg убран. Сетка 4 колонки, ячейка по контенту.
const _CELL_COLUMNS := 4
const _CELL_SIZE := Vector2(150, 140)

var player: Player
var _root: MarginContainer
var _panel: PanelContainer
var _recruit_grid: GridContainer
var _gold_label: Label
var _rep_label: Label
var _race := ""            # раса города: ось репутации ("" — карта без города)
var _rep := 0              # репутация героя у этой расы на момент открытия
var _party_label: Label
var _rep_hint: Label
var _talk_label: Label
var _talk_button: Button
var _close_button: Button
var _previous_focus: Control
var _hover_card: PanelContainer = null
var _candidates: Array[Dictionary] = []

func setup(p: Player, city_race: String = "") -> void:
	player = p
	_race = city_race
	_rep = Game.hero_reputation(_race)
	layer = 10
	_build_ui()

func _ready() -> void:
	_previous_focus = UiKit.save_focus(self)
	_generate_candidates()
	_refresh()

func _exit_tree() -> void:
	pass

func _build_hover_card() -> void:
	_hover_card = UiKit.make_hover_card(280.0)
	_panel.add_child(_hover_card)

func _attach_hover(slot: Control, entry: Dictionary, set_name: String,
		display_name: String) -> void:
	if _hover_card == null or entry.is_empty():
		return
	var show_at := func() -> void:
		if not is_instance_valid(slot) or not is_instance_valid(_panel):
			return
		var local: Vector2 = _panel.get_global_transform().affine_inverse() * slot.global_position
		UiKit.show_hover_card(_hover_card,
			_hover_lines(entry, set_name, display_name),
			local, _panel.size)
	slot.mouse_entered.connect(show_at)
	slot.mouse_exited.connect(func() -> void: UiKit.hide_hover_card(_hover_card))
	var btn: Button = slot.find_child("Hire", true, false) as Button
	if btn != null:
		btn.focus_entered.connect(show_at)
		btn.focus_exited.connect(func() -> void: UiKit.hide_hover_card(_hover_card))

func _hover_lines(entry: Dictionary, set_name: String, display_name: String) -> Array:
	var lines: Array = [display_name]
	var sub: Array[String] = []
	sub.append(Loc.f("ui.inn.hp", [int(entry.get("hp", 0))]))
	sub.append(Loc.f("ui.inn.damage", [int(entry.get("dmg", 0))]))
	lines.append(" · ".join(sub))
	var note := _hostile_note(set_name)
	if not note.is_empty():
		lines.append(note)
	lines.append(Loc.f("ui.inn.hire_price", [int(entry.get("cost", 0))]))
	return lines

func _build_ui() -> void:
	var dim := UiKit.make_dim(0.58)
	add_child(dim)

	_root = MarginContainer.new()
	_root.name = "InnRoot"
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
	_panel.theme_type_variation = &"InnPanel"
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	center.add_child(_panel)

	var margin := MarginContainer.new()
	margin.name = "Margin"
	UiKit.set_margins(margin, UiTheme.SPACE_4, UiTheme.SPACE_3,
		UiTheme.SPACE_4, UiTheme.SPACE_3)
	_panel.add_child(margin)

	var content := VBoxContainer.new()
	content.name = "Content"
	content.add_theme_constant_override("separation", UiTheme.SPACE_2)
	margin.add_child(content)

	var header := HBoxContainer.new()
	header.name = "Header"
	header.add_theme_constant_override("separation", UiTheme.SPACE_3)
	content.add_child(header)
	var title := Label.new()
	title.name = "Title"
	title.theme_type_variation = &"InnTitle"
	title.text = Loc.t("ui.inn.title")
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	_gold_label = Label.new()
	_gold_label.name = "Gold"
	_gold_label.theme_type_variation = &"InnGoldLabel"
	_gold_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	header.add_child(_gold_label)
	_rep_label = Label.new()
	_rep_label.name = "Reputation"
	_rep_label.theme_type_variation = &"InnGoldLabel"
	_rep_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	header.add_child(_rep_label)
	_close_button = Button.new()
	_close_button.name = "Close"
	_close_button.text = Loc.t("ui.btn.close")
	_close_button.theme_type_variation = &"InnClose"
	_close_button.custom_minimum_size = Vector2(120, 32)
	_close_button.pressed.connect(close)
	header.add_child(_close_button)

	var body := HBoxContainer.new()
	body.name = "Body"
	body.add_theme_constant_override("separation", UiTheme.SPACE_3)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_child(body)

	var recruit_col := VBoxContainer.new()
	recruit_col.name = "RecruitCol"
	recruit_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	recruit_col.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(recruit_col)
	var recruit_title := Label.new()
	recruit_title.theme_type_variation = &"InnSectionLabel"
	recruit_title.text = Loc.t("ui.inn.recruits")
	recruit_col.add_child(recruit_title)
	var scroll := ScrollContainer.new()
	scroll.name = "RecruitScroll"
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.follow_focus = true
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	recruit_col.add_child(scroll)
	_recruit_grid = GridContainer.new()
	_recruit_grid.name = "RecruitGrid"
	_recruit_grid.columns = _CELL_COLUMNS
	_recruit_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_recruit_grid.add_theme_constant_override("h_separation", UiTheme.SPACE_2)
	_recruit_grid.add_theme_constant_override("v_separation", UiTheme.SPACE_2)
	scroll.add_child(_recruit_grid)

	var side_col := VBoxContainer.new()
	side_col.name = "SideCol"
	side_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_child(side_col)
	var panel := PanelContainer.new()
	panel.name = "RecruiterPanel"
	panel.theme_type_variation = &"InnDialogPanel"
	side_col.add_child(panel)
	var mmargin := MarginContainer.new()
	_set_margins(mmargin, UiTheme.SPACE_3, UiTheme.SPACE_2,
		UiTheme.SPACE_3, UiTheme.SPACE_2)
	panel.add_child(mmargin)
	var mcontent := VBoxContainer.new()
	mcontent.name = "Content"
	mcontent.add_theme_constant_override("separation", UiTheme.SPACE_1)
	mmargin.add_child(mcontent)
	var heading := Label.new()
	heading.name = "Heading"
	heading.theme_type_variation = &"InnSectionLabel"
	heading.text = Loc.t("ui.inn.recruiter")
	mcontent.add_child(heading)
	_talk_label = Label.new()
	_talk_label.name = "TalkText"
	_talk_label.text = Loc.t("ui.inn.talk_hint")
	_talk_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_talk_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	mcontent.add_child(_talk_label)
	_talk_button = Button.new()
	_talk_button.name = "Talk"
	_talk_button.text = Loc.t("ui.inn.talk")
	_talk_button.theme_type_variation = &"InnTalkButton"
	_talk_button.custom_minimum_size = Vector2(160, 32)
	_talk_button.pressed.connect(_talk)
	mcontent.add_child(_talk_button)

	_party_label = Label.new()
	_party_label.name = "PartyHint"
	_party_label.theme_type_variation = &"InnHintLabel"
	_party_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_party_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	content.add_child(_party_label)

	_rep_hint = Label.new()
	_rep_hint.name = "ReputationHint"
	_rep_hint.theme_type_variation = &"InnHintLabel"
	_rep_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_rep_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	content.add_child(_rep_hint)

	_build_hover_card()

## Тир наёмников по репутации: 0..3. Пороги — [reputation] tier_1..tier_3;
## _candidate_sets() перечислены от слабого тира к сильному, поэтому тир = индекс.
func _tier() -> int:
	var t := 0
	if _rep >= GameConfig.geti("reputation", "tier_1"):
		t = 1
	if _rep >= GameConfig.geti("reputation", "tier_2"):
		t = 2
	if _rep >= GameConfig.geti("reputation", "tier_3"):
		t = 3
	return t


## Порог репутации для тира (1..3). 0 — тир без порога.
func _tier_threshold(tier_index: int) -> int:
	match tier_index:
		1:
			return GameConfig.geti("reputation", "tier_1")
		2:
			return GameConfig.geti("reputation", "tier_2")
		3:
			return GameConfig.geti("reputation", "tier_3")
	return 0


## Сколько репутации до следующего тира (0 — выше некуда).
func _next_tier_need() -> int:
	var next_tier := _tier() + 1
	if next_tier > _candidate_sets().size() - 1:
		return 0
	return _tier_threshold(next_tier)


## Ячейка-замок для тира выше текущего. Пустые клетки читались как «наёмники
## пропали» (жалоба игрока 28.10) — теперь видно, что и сколько нужно.
func _locked_entry(index: int) -> Dictionary:
	if index < 0 or index >= _candidate_sets().size():
		return {}
	if index <= _tier():
		return {}
	var need := _tier_threshold(index)
	if need <= 0:
		return {}
	return {"set": str(_candidate_sets()[index]), "locked": true, "need": need}


func _generate_candidates() -> void:
	_candidates.clear()
	var tier := _tier()
	var tier_cost := GameConfig.geti("reputation", "inn_tier_cost")
	var pool: Array = _candidate_sets().slice(0, mini(tier + 1, _candidate_sets().size()))
	while not pool.is_empty():
		var index := randi() % pool.size()
		var set_name := str(pool[index])
		pool.remove_at(index)
		_candidates.append({
			"set": set_name,
			"tier": tier,
			"hp": 45 + randi() % 45 + tier * 20,
			"dmg": 4 + randi() % 5 + tier * 2,
			"cost": 30 + randi() % 50 + tier * tier_cost,
		})

func _refresh() -> void:
	_clear_grid(_recruit_grid)
	if _hover_card != null:
		UiKit.hide_hover_card(_hover_card)
	if not is_instance_valid(player):
		return
	_gold_label.text = Loc.f("ui.card.gold", [player.gold])
	if _rep_label != null:
		if _race == "":
			_rep_label.text = Loc.t("ui.inn.rep.none")
		else:
			_rep_label.text = Loc.f("ui.inn.rep.tier",
				[Lore.faction_label(_race), _rep, _tier()])
	_party_label.text = Loc.f("ui.inn.party", [Game.party.size(), MAX_PARTY])
	if _rep_hint != null:
		var next_need := _next_tier_need()
		if _race == "":
			_rep_hint.text = Loc.t("ui.inn.hint.base")
		elif next_need > 0:
			_rep_hint.text = Loc.f("ui.inn.hint.next",
				[Lore.faction_label(_race), _rep, next_need])
		else:
			_rep_hint.text = Loc.f("ui.inn.hint.top",
				[Lore.faction_label(_race), _rep])
	var action_buttons: Array[Button] = []
	var slots_to_fill := maxi(_candidates.size(), _CELL_COLUMNS)
	for index in range(slots_to_fill):
		var entry: Dictionary = _candidates[index] if index < _candidates.size() else _locked_entry(index)
		var slot := _make_recruit_slot(entry)
		_recruit_grid.add_child(slot)
		var hire_button := slot.find_child("Hire", true, false) as Button
		if hire_button != null:
			hire_button.disabled = Game.party.size() >= MAX_PARTY or player.gold < int(entry.get("cost", 0))
			action_buttons.append(hire_button)
	_configure_focus(action_buttons)
	if not action_buttons.is_empty():
		action_buttons[0].call_deferred("grab_focus")
	else:
		_talk_button.call_deferred("grab_focus")

func _make_recruit_slot(entry: Dictionary) -> PanelContainer:
	var slot := PanelContainer.new()
	slot.theme_type_variation = &"InnRecruitSlot"
	slot.custom_minimum_size = _CELL_SIZE

	var margin := MarginContainer.new()
	_set_margins(margin, UiTheme.SPACE_1, UiTheme.SPACE_1, UiTheme.SPACE_1, UiTheme.SPACE_1)
	slot.add_child(margin)

	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 1)
	margin.add_child(content)

	if entry.is_empty():
		return slot

	var set_name := str(entry["set"])
	var display_name := UnitDB.display_name(set_name)
	var portrait := TextureRect.new()
	portrait.texture = UnitDB.preview_frame(set_name)
	portrait.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	portrait.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	portrait.custom_minimum_size = Vector2(48, 48)
	portrait.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	portrait.size_flags_vertical = Control.SIZE_EXPAND_FILL
	portrait.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if bool(entry.get("locked", false)):
		# Замок: портрет приглушён, кнопки найма нет, требование написано.
		portrait.modulate = Color(1, 1, 1, 0.35)
	content.add_child(portrait)

	var name_label := Label.new()
	name_label.text = display_name
	name_label.tooltip_text = display_name
	name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.custom_minimum_size = Vector2(0, 16)
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if bool(entry.get("locked", false)):
		name_label.modulate = Color(1, 1, 1, 0.5)
	content.add_child(name_label)

	if bool(entry.get("locked", false)):
		var need_label := Label.new()
		need_label.name = "Locked"
		need_label.theme_type_variation = &"InnCandidateStats"
		need_label.text = Loc.f("ui.inn.need_rep", [int(entry.get("need", 0))])
		need_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		need_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		need_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
		need_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		content.add_child(need_label)
		return slot

	var hire := Button.new()
	hire.name = "Hire"
	hire.theme_type_variation = &"InnHireButton"
	hire.text = Loc.f("ui.inn.hire_cost", [int(entry["cost"])])
	hire.tooltip_text = "%s — %s\n%s" % [display_name, _hostile_note(set_name),
		Loc.f("ui.inn.hire_cost_tip", [int(entry["cost"])])]
	hire.custom_minimum_size = Vector2(0, 26)
	hire.focus_mode = Control.FOCUS_ALL
	hire.pressed.connect(_hire.bind(entry))
	content.add_child(hire)
	_attach_hover(slot, entry, set_name, display_name)
	return slot

func _configure_focus(buttons: Array[Button]) -> void:
	UiKit.wire_grid_focus(buttons, _CELL_COLUMNS)
	if buttons.is_empty():
		return
	buttons[0].focus_next = _talk_button.get_path()
	buttons[-1].focus_previous = _talk_button.get_path()
	_talk_button.focus_previous = buttons[-1].get_path()
	_talk_button.focus_next = buttons[0].get_path()
	_close_button.focus_previous = _talk_button.get_path()
	_close_button.focus_next = buttons[0].get_path()

func _set_margins(container: MarginContainer, left: int, top: int, right: int, bottom: int) -> void:
	UiKit.set_margins(container, left, top, right, bottom)

func _make_theme() -> Theme:
	var theme := UiTheme.app_theme()
	theme.set_stylebox("normal", "Button", UiKit.button_style(
		UiTheme.PANEL_INNER, UiTheme.PANEL_EDGE,
		UiTheme.BORDER_NORMAL, UiTheme.RADIUS_PANEL, UiTheme.SPACE_2))
	theme.set_stylebox("hover", "Button", UiKit.button_style(
		UiTheme.PANEL_INNER.lightened(0.12), UiTheme.ACCENT_DIM,
		UiTheme.BORDER_NORMAL, UiTheme.RADIUS_PANEL, UiTheme.SPACE_2))
	theme.set_stylebox("pressed", "Button", UiKit.button_style(
		UiTheme.BG_DEEP, UiTheme.PANEL_EDGE,
		UiTheme.BORDER_NORMAL, UiTheme.RADIUS_PANEL, UiTheme.SPACE_2))
	theme.set_stylebox("focus", "Button", UiKit.button_style(
		UiTheme.TRANSPARENT, UiTheme.ACCENT,
		UiTheme.BORDER_FOCUS, UiTheme.RADIUS_PANEL, UiTheme.SPACE_2))
	UiKit.apply_scrollbar(theme, UiTheme.RADIUS_SLOT, UiTheme.SPACE_1)
	UiKit.add_panel(theme, &"InnPanel",
		UiTheme.PANEL_BG, UiTheme.PANEL_EDGE, UiTheme.RADIUS_FRAME)
	UiTheme.add_display_label(theme, &"InnTitle", UiTheme.FONT_TITLE, UiTheme.ACCENT)
	UiKit.add_label(theme, &"InnGoldLabel", UiTheme.ACCENT, UiTheme.FONT_SUBHEAD)
	UiKit.add_label(theme, &"InnSectionLabel", UiTheme.TEXT_MUTED, UiTheme.FONT_SECTION)
	UiKit.add_label(theme, &"InnHintLabel", UiTheme.TEXT_MUTED, UiTheme.FONT_BODY)
	UiKit.add_label(theme, &"InnCandidateStats", UiTheme.TEXT_MUTED, UiTheme.FONT_MICRO)
	UiKit.add_button(theme, &"InnHireButton",
		UiTheme.PANEL_INNER, UiTheme.ACCENT_DIM,
		UiTheme.PANEL_INNER.lightened(0.14), UiTheme.ACCENT,
		UiTheme.RADIUS_SLOT, UiTheme.SPACE_1)
	UiKit.add_button(theme, &"InnTalkButton",
		UiTheme.PANEL_INNER, UiTheme.PANEL_EDGE,
		UiTheme.PANEL_INNER.lightened(0.14), UiTheme.ACCENT_DIM,
		UiTheme.RADIUS_PANEL, UiTheme.SPACE_2)
	UiKit.add_button(theme, &"InnClose",
		UiTheme.PANEL_INNER, UiTheme.PANEL_EDGE.darkened(0.25),
		UiTheme.PANEL_INNER.lightened(0.12), UiTheme.ACCENT_DIM,
		UiTheme.RADIUS_SLOT, UiTheme.SPACE_2)
	UiKit.add_hover_card_styles(theme)
	UiKit.add_slot(theme, &"InnRecruitSlot")
	UiKit.add_panel(theme, &"InnDialogPanel",
		UiTheme.PANEL_INNER, UiTheme.PANEL_EDGE, UiTheme.RADIUS_PANEL)
	return theme

func _clear_grid(grid: GridContainer) -> void:
	UiKit.clear(grid)

func _talk() -> void:
	if not is_instance_valid(_talk_label):
		return
	var idx := randi() % TALK_LINE_KEYS.size()
	var line := Loc.t(str(TALK_LINE_KEYS[idx]))
	_talk_label.text = Loc.f("ui.talk.inn.line", [line])
	# One voice channel: a repeated click restarts the line instead of stacking
	# two speakers on top of each other.
	SoundDB.play_raced_voice("voice.npc.inn", _race, idx + 1)

func _hostile_note(set_name: String) -> String:
	return Loc.t("ui.inn.peaceful") if not UnitDB.is_hostile(set_name) \
		else Loc.t("ui.inn.wild")

func _hire(candidate: Dictionary) -> void:
	if not is_instance_valid(player):
		return
	if Game.party.size() >= MAX_PARTY:
		_talk_label.text = Loc.f("ui.talk.inn.party_full", [MAX_PARTY])
		return
	var cost := int(candidate.get("cost", 0))
	if player.gold < cost:
		_talk_label.text = Loc.f("ui.talk.inn.no_gold", [cost])
		return
	player.gold -= cost
	var mercenary := Mercenary.new()
	mercenary.anim_set = str(candidate["set"])
	mercenary.max_hp = int(candidate["hp"])
	mercenary.damage = int(candidate["dmg"])
	mercenary.position = _spawn_spot()
	var scene := get_tree().current_scene if get_tree() != null else null
	if scene == null:
		scene = get_parent()
	if scene != null:
		scene.add_child(mercenary)
	else:
		add_child(mercenary)
	Game.party.append(mercenary)
	SoundDB.play("ui.click")
	var set_name := str(candidate["set"])
	for index in range(_candidates.size() - 1, -1, -1):
		if str(_candidates[index].get("set", "")) == set_name:
			_candidates.remove_at(index)
			break
	_talk_label.text = Loc.f("ui.talk.inn.hired",
		[UnitDB.display_name(set_name)])
	_refresh()
	print("Hired: %s" % set_name)

func _spawn_spot() -> Vector2:
	var map_node = get_tree().get_first_node_in_group("alm_map")
	var count: int = Game.party.size()
	for attempt in range(12):
		var angle := TAU * float(count) / float(MAX_PARTY) + float(attempt) * 0.5
		var radius := 40.0 + 12.0 * float(attempt % 3)
		var p: Vector2 = player.global_position + Vector2(cos(angle), sin(angle)) * radius
		if map_node == null or not map_node.has_method("is_walkable_world"):
			return p
		if bool(map_node.call("is_walkable_world", p)):
			return p
	return player.global_position

func _input(event: InputEvent) -> void:
	if UiKit.esc_pressed(event):
		close()
		get_viewport().set_input_as_handled()

func close() -> void:
	UiKit.restore_focus(_previous_focus)
	closed.emit()
	queue_free()
