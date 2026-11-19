class_name QuestPanel
extends CanvasLayer
## Town head quest panel (22.10).
##
## Two modes in one window:
##  * head clicked (city_id not empty) - "Offers" of that city on the left,
##    "Taken from the head" on the right: take / abandon, turn in what is done;
##  * hotkey W (empty city_id) - journal: only taken quests from every city
##    plus history. Same as the original (quest.txt: "press 'W'").
##
## Look - UiTheme roles and UiKit variations only (guard
## tests/ui_design_system_smoke.gd): the panel writes no Color() and no font
## sizes as bare numbers.
## Accessibility: mouse, keyboard and gamepad - a grid of rows with focus
## neighbours (UiKit.wire_grid_focus), initial focus on the first row, Esc
## closes.
##
## Every player-visible string goes through Loc.t() (assets/locale/ui.json)
## under a "ui.quest.*" key: Loc hands the key back when the table has none,
## so an English phrase passed as a key would read English in a Russian game.

signal closed
signal inventory_changed

const ICON_SIZE := Vector2(48, 48)
## Reward coins in a quest card: the swaying sprite, smaller than the item slot.
const COIN_SIZE := Vector2(20, 20)
const COIN_FRAME_TIME := QuestIcons.COIN_FRAME_TIME
## Panel width: two card columns at 1280x800, the world stays visible at the
## edges.
const PANEL_WIDTH := 1100

var player: Player
var city_id: String = ""

var _root: MarginContainer
var _panel: PanelContainer
var _previous_focus: Control
var _title: Label
var _gold_label: Label
var _offers_box: VBoxContainer
var _active_box: VBoxContainer
var _offers_title: Label
var _active_title: Label
var _status: Label
var _close_button: Button
var _row_buttons: Array[Button] = []
var _coin_sprites: Array = []      # TextureRect nodes; Array on purpose (see _refresh)
var _coin_frames: Array = []
var _coin_t := 0.0
var _coin_frame := 0
var _refresh_t := 0.0
var _dirty := false           # quest taken / turned in elsewhere - rebuild cards
var _offers_sig := ""         # journal signature at the last rebuild
var _offer_rows := 0          # first _row_buttons index of the TAKEN column


func setup(p: Player, cid: String = "") -> void:
	player = p
	city_id = cid
	layer = 10
	_build_ui()
	var qs := QuestSystem.instance
	if qs != null and not qs.active_changed.is_connected(_mark_dirty):
		qs.active_changed.connect(_mark_dirty)
		qs.offers_changed.connect(_mark_dirty_city)


func _ready() -> void:
	_previous_focus = UiKit.save_focus(self)
	_refresh()


## Length of one coin frame step (a probe or a test can advance the sway).
func coin_frame_time() -> float:
	return COIN_FRAME_TIME


## The coin sways and the journal follows the bag: a herb the hero picks up
## moves the counter of an active quest, and the runner must be able to ask for
## that without waiting for a frame.
func advance(delta: float) -> void:
	_process(delta)


## Journal changed (item picked, target killed) - the cards are stale.
func _mark_dirty() -> void:
	_dirty = true


func _mark_dirty_city(target_city_id: String) -> void:
	if target_city_id == "" or target_city_id == city_id:
		_dirty = true


func _process(delta: float) -> void:
	_tick_coin(delta)
	# An urgent quest ticks in real time: its counter in the panel must live.
	_refresh_t += delta
	if _refresh_t >= 0.5:
		_refresh_t = 0.0
		# Counter changes - an urgent countdown, a herb added to the bag, a kill
		# elsewhere - come through the journal signature: the right column
		# rebuilds only when a counter really moved, the offers never do.
		_refresh_active_only()
	if _dirty:
		_dirty = false
		_refresh()
		return


func _has_urgent() -> bool:
	var qs := QuestSystem.instance
	if qs == null:
		return false
	for q in qs.active:
		if str(q.get("type", "")) == "URGENT":
			return true
	return false


func _input(event: InputEvent) -> void:
	if UiKit.esc_pressed(event):
		close()
		get_viewport().set_input_as_handled()
		return
	# W открывает журнал из game.gd, а закрывать его game.gd не даёт: открытая
	# панель ставит is_editor_open(). Поэтому W обязан закрывать здесь — иначе
	# «нажал W ещё раз, а журнал висит» (жалоба игрока 28.10).
	if event is InputEventKey and event.pressed and not event.echo \
			and event.keycode == KEY_W and not event.ctrl_pressed:
		close()
		get_viewport().set_input_as_handled()


func close() -> void:
	UiKit.restore_focus(_previous_focus)
	closed.emit()
	queue_free()


## --- Build --------------------------------------------------------------------

func _make_theme() -> Theme:
	var theme := UiTheme.app_theme()
	UiKit.add_frame(theme, &"QuestPanel", "res://assets/ui/frames/panel_frame.png")
	UiKit.add_label(theme, &"QuestTitle", UiTheme.ACCENT, UiTheme.FONT_TITLE)
	UiKit.add_label(theme, &"QuestGoldLabel", UiTheme.ACCENT, UiTheme.FONT_SUBHEAD)
	UiKit.add_label(theme, &"QuestSection", UiTheme.ACCENT_DIM, UiTheme.FONT_SECTION)
	UiKit.add_label(theme, &"QuestName", UiTheme.TEXT, UiTheme.FONT_SUBHEAD)
	UiKit.add_label(theme, &"QuestText", UiTheme.TEXT, UiTheme.FONT_BODY)
	UiKit.add_label(theme, &"QuestHint", UiTheme.TEXT_MUTED, UiTheme.FONT_MICRO)
	UiKit.add_label(theme, &"QuestStatus", UiTheme.ACCENT_DIM, UiTheme.FONT_BODY)
	UiKit.add_label(theme, &"QuestReady", UiTheme.SUCCESS, UiTheme.FONT_BODY)
	UiKit.add_panel(theme, &"QuestCard", UiTheme.PANEL_INNER, UiTheme.SLOT_EDGE,
		UiTheme.RADIUS_SLOT)
	UiKit.add_panel(theme, &"QuestIconSlot", UiTheme.SLOT_BG, UiTheme.SLOT_EDGE,
		UiTheme.RADIUS_SLOT)
	UiKit.add_panel(theme, &"QuestScrollPanel", UiTheme.BG_DEEP, UiTheme.PANEL_EDGE,
		UiTheme.RADIUS_SLOT)
	UiKit.add_button(theme, &"QuestAction",
		UiTheme.PANEL_INNER, UiTheme.ACCENT_DIM,
		UiTheme.PANEL_INNER.lightened(0.14), UiTheme.ACCENT,
		UiTheme.RADIUS_SLOT, UiTheme.SPACE_2)
	UiKit.add_button(theme, &"QuestClose",
		UiTheme.PANEL_INNER, UiTheme.PANEL_EDGE.darkened(0.25),
		UiTheme.PANEL_INNER.lightened(0.12), UiTheme.ACCENT_DIM,
		UiTheme.RADIUS_SLOT, UiTheme.SPACE_2)
	return theme


func _build_ui() -> void:
	var dim := UiKit.make_dim(UiTheme.SCRIM.a)
	add_child(dim)

	_root = MarginContainer.new()
	_root.name = "QuestRoot"
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
	_panel.theme_type_variation = &"QuestPanel"
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_panel.custom_minimum_size = Vector2(PANEL_WIDTH, 600)
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

	_title = Label.new()
	_title.name = "Title"
	_title.theme_type_variation = &"QuestTitle"
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(_title)

	_gold_label = Label.new()
	_gold_label.name = "Gold"
	_gold_label.theme_type_variation = &"QuestGoldLabel"
	_gold_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	header.add_child(_gold_label)

	_close_button = Button.new()
	_close_button.name = "Close"
	_close_button.text = Loc.t("ui.quest.close")
	_close_button.theme_type_variation = &"QuestClose"
	_close_button.custom_minimum_size = Vector2(120, 32)
	_close_button.pressed.connect(close)
	header.add_child(_close_button)

	var columns := HBoxContainer.new()
	columns.name = "Columns"
	columns.add_theme_constant_override("separation", UiTheme.SPACE_4)
	columns.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_child(columns)

	_offers_title = Label.new()
	_offers_title.name = "OffersTitle"
	_offers_title.theme_type_variation = &"QuestSection"
	var offers_col := _make_column("Offers", _offers_title)
	columns.add_child(offers_col[0])
	_offers_box = offers_col[1]

	_active_title = Label.new()
	_active_title.name = "ActiveTitle"
	_active_title.theme_type_variation = &"QuestSection"
	var active_col := _make_column("Active", _active_title)
	columns.add_child(active_col[0])
	_active_box = active_col[1]

	_status = Label.new()
	_status.name = "Status"
	_status.theme_type_variation = &"QuestStatus"
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.custom_minimum_size = Vector2(0, 36)
	content.add_child(_status)

	var hint := Label.new()
	hint.name = "CloseHint"
	hint.theme_type_variation = &"QuestStatus"
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.text = Loc.t("ui.quest.close_hint")
	hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	content.add_child(hint)


## [scroll frame PanelContainer, row VBoxContainer].
func _make_column(column_name: String, title: Label) -> Array:
	var col := VBoxContainer.new()
	col.name = column_name
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_theme_constant_override("separation", UiTheme.SPACE_2)
	col.add_child(title)
	var frame := PanelContainer.new()
	frame.name = column_name + "Frame"
	frame.theme_type_variation = &"QuestScrollPanel"
	frame.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	frame.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(frame)
	var inner_margin := MarginContainer.new()
	inner_margin.name = "Margin"
	UiKit.set_margins(inner_margin, UiTheme.SPACE_2, UiTheme.SPACE_2,
		UiTheme.SPACE_2, UiTheme.SPACE_2)
	frame.add_child(inner_margin)
	var scroll := ScrollContainer.new()
	scroll.name = column_name + "Scroll"
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.follow_focus = true
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	inner_margin.add_child(scroll)
	var box := VBoxContainer.new()
	box.name = column_name + "Box"
	box.add_theme_constant_override("separation", UiTheme.SPACE_2)
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(box)
	return [col, box]


## --- One quest card -----------------------------------------------------------

func _make_card(q: Dictionary, buttons: Array) -> PanelContainer:
	## buttons: [[text, Callable], ...] - action buttons at the bottom.
	var card := PanelContainer.new()
	card.name = "Quest_" + str(q.get("id", ""))
	card.theme_type_variation = &"QuestCard"
	var margin := MarginContainer.new()
	UiKit.set_margins(margin, UiTheme.SPACE_2, UiTheme.SPACE_2,
		UiTheme.SPACE_2, UiTheme.SPACE_2)
	card.add_child(margin)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", UiTheme.SPACE_2)
	margin.add_child(row)

	var slot := PanelContainer.new()
	slot.name = "IconSlot"
	slot.theme_type_variation = &"QuestIconSlot"
	slot.custom_minimum_size = ICON_SIZE
	slot.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	row.add_child(slot)
	var icon := TextureRect.new()
	icon.name = "Icon"
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	icon.custom_minimum_size = ICON_SIZE
	icon.texture = _quest_icon(str(q.get("icon", "")))
	slot.add_child(icon)

	var col := VBoxContainer.new()
	col.name = "Body"
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_theme_constant_override("separation", UiTheme.SPACE_1)
	row.add_child(col)

	# Story lines are marked above the title: a scenario must not read as one
	# more rotating chore.
	var chain_text := _chain_text(q)
	if chain_text != "":
		var chain_label := Label.new()
		chain_label.name = "Chain"
		chain_label.theme_type_variation = &"QuestHint"
		chain_label.text = chain_text
		chain_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		col.add_child(chain_label)

	var name_label := Label.new()
	name_label.name = "Name"
	name_label.theme_type_variation = &"QuestName"
	name_label.text = str(q.get("title", ""))
	name_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(name_label)

	var text_label := Label.new()
	text_label.name = "Text"
	text_label.theme_type_variation = &"QuestText"
	text_label.text = str(q.get("text", ""))
	text_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(text_label)

	var hint := Label.new()
	hint.name = "Hint"
	hint.theme_type_variation = &"QuestHint"
	hint.text = _hint_text(q)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(hint)

	var place_text := _place_text(q)
	if place_text != "":
		var place := Label.new()
		place.name = "Place"
		place.theme_type_variation = &"QuestHint"
		place.text = place_text
		col.add_child(place)

	col.add_child(_reward_row(q))

	if str(q.get("state", "")) == QuestSystem.STATE_READY:
		var ready := Label.new()
		ready.name = "Ready"
		ready.theme_type_variation = &"QuestReady"
		ready.text = _ready_text(q)
		ready.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		col.add_child(ready)

	if not buttons.is_empty():
		var actions := HBoxContainer.new()
		actions.name = "Actions"
		actions.add_theme_constant_override("separation", UiTheme.SPACE_2)
		col.add_child(actions)
		for pair in buttons:
			var btn := Button.new()
			btn.text = str((pair as Array)[0])
			btn.theme_type_variation = &"QuestAction"
			btn.custom_minimum_size = Vector2(0, 30)
			var cb: Callable = (pair as Array)[1]
			btn.pressed.connect(cb)
			actions.add_child(btn)
			_row_buttons.append(btn)
	return card


## Story line badge: "Story: <name>" and "Step 1 of 4". Empty for a rotating
## quest, so an ordinary card keeps its height.
func _chain_text(q: Dictionary) -> String:
	var chain_id := str(q.get("chain_id", ""))
	if chain_id == "":
		return ""
	var parts: Array = []
	var c := QuestDB.chain(chain_id)
	if not c.is_empty():
		parts.append(Loc.f("ui.quest.chain.badge",
			[Loc.t(str(c.get("title_key", "")))]))
	if int(q.get("stages_total", 0)) > 0:
		parts.append(Loc.f("ui.quest.chain.step",
			[int(q.get("order", 1)), int(q.get("stages_total", 0))]))
	return "\n".join(parts)


## Journal mode: which head the quest came from. In the head's panel it is
## pointless - the head is right there.
func _place_text(q: Dictionary) -> String:
	if city_id != "":
		return ""
	var qs := QuestSystem.instance
	var own_city := str(q.get("city_id", ""))
	if qs == null or own_city == "":
		return ""
	return Loc.f("ui.quest.from_head", [qs.city_name(own_city)])


## Line under the name: difficulty, time limit, progress. The reward has its
## own row with the swaying coin sprite (_reward_row).
func _hint_text(q: Dictionary) -> String:
	var parts: Array = []
	var diff := clampi(int(q.get("difficulty", 1)) - 1, 0,
		QuestDB.DIFFICULTY_NAMES.size() - 1)
	parts.append(Loc.f("ui.quest.difficulty",
		[Loc.t("ui.quest.difficulty_" + QuestDB.DIFFICULTY_NAMES[diff])]))
	if str(q.get("type", "")) == "URGENT":
		parts.append(Loc.f("ui.quest.time_left",
			[_time_text(float(q.get("seconds_left", 0.0)))]))
	if str(q.get("type", "")) in ["KILL_SPECIES", "KILL_GROUP", "KILL_TARGET", "URGENT"]:
		parts.append(Loc.f("ui.quest.killed", [int(q.get("progress", 0)),
			int(q.get("need", 1))]))
	elif str(q.get("type", "")) in ["GATHER", "FIND_ITEM", "DELIVER"]:
		parts.append(Loc.f("ui.quest.collected", [int(q.get("progress", 0)),
			int(q.get("need", 1))]))
	var full := " · ".join(parts)
	return full


## Text beside the coin: gold, reputation, blueprint.
func _reward_text(q: Dictionary) -> String:
	var parts: Array = [Loc.f("ui.quest.gold_reward", [int(q.get("gold", 0))])]
	if int(q.get("rep", 0)) != 0:
		parts.append(Loc.f("ui.quest.reputation", [int(q.get("rep", 0))]))
	if str(q.get("blueprint", "")) != "":
		parts.append(Loc.t("ui.quest.blueprint_tag"))
	var full := " · ".join(parts)
	return full


func _ready_text(q: Dictionary) -> String:
	var parts: Array = [Loc.t("ui.quest.done")]
	if str(q.get("blueprint", "")) != "":
		parts.append(Loc.f("ui.quest.blueprint_name", [str(q.get("blueprint", ""))]))
	return " ".join(parts)


func _time_text(seconds: float) -> String:
	var s := maxi(0, int(seconds))
	return "%d:%02d" % [s / 60, s % 60]


func _quest_icon(icon: String) -> Texture2D:
	return QuestIcons.icon_texture(icon)


## Gold of a quest reward: the swaying coin sprite and its amount.
func _reward_row(q: Dictionary) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.name = "Reward"
	row.add_theme_constant_override("separation", UiTheme.SPACE_1)
	var coin := _make_coin()
	if coin != null:
		row.add_child(coin)
	var amount := Label.new()
	amount.name = "Gold"
	amount.theme_type_variation = &"QuestHint"
	amount.text = _reward_text(q)
	amount.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(amount)
	return row


## One swaying coin; null while the art does not exist (the text stays).
func _make_coin() -> TextureRect:
	if _coin_frames.is_empty():
		var loaded: Array = QuestIcons.coin_frames()
		if loaded.is_empty():
			return null
		_coin_frames = loaded
	var coin := TextureRect.new()
	coin.name = "Coin"
	coin.texture = _coin_frames[0]
	coin.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	coin.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	coin.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	coin.custom_minimum_size = COIN_SIZE
	coin.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_coin_sprites.append(coin)
	return coin


## The coin sway is slow and constant: all coins in the panel share the phase.
func _tick_coin(delta: float) -> void:
	if _coin_frames.size() <= 1:
		return
	_coin_sprites = _coin_sprites.filter(
		func(n): return is_instance_valid(n) and n.is_inside_tree())
	if _coin_sprites.is_empty():
		return
	_coin_t += delta
	if _coin_t < COIN_FRAME_TIME:
		return
	_coin_t = 0.0
	_coin_frame = (_coin_frame + 1) % _coin_frames.size()
	var live: Array = []
	for coin in _coin_sprites:
		coin.texture = _coin_frames[_coin_frame]
		live.append(coin)
	_coin_sprites = live


## --- Refresh ------------------------------------------------------------------

func _refresh() -> void:
	if _offers_box == null:
		return
	# An old coin dies with its card, so the list is emptied BEFORE the boxes
	# are cleared; _fill_offers/_fill_active then add the coins of the new
	# cards. The nodes only leave the tree at the frame end (queue_free), so
	# they are hidden and forgotten RIGHT NOW: the counts must agree at once.
	for old in _coin_sprites:
		if is_instance_valid(old):
			old.visible = false
	_coin_sprites.clear()
	_row_buttons.clear()
	UiKit.clear(_offers_box)
	UiKit.clear(_active_box)
	var qs := QuestSystem.instance
	if qs == null:
		_title.text = Loc.t("ui.quest.panel_title")
		_status.text = Loc.t("ui.quest.msg_disabled")
		return
	# The bag may have changed since the last frame (a herb picked up): the
	# cards must show the real count, not the one taken when the quest was taken.
	qs.sync_inventory()
	_gold_label.text = Loc.f("ui.quest.gold_total",
		[int(player.gold) if is_instance_valid(player) else 0])
	if city_id != "":
		_title.text = Loc.f("ui.quest.head_of", [qs.city_name(city_id).to_upper()])
		_offers_title.text = Loc.t("ui.quest.offers")
		_offers_box.visible = true
		_fill_offers(qs)
	else:
		_title.text = Loc.t("ui.quest.journal_title")
		_offers_title.text = ""
		_offers_box.visible = false
	_active_title.text = Loc.f("ui.quest.taken_count", [
		qs.active.size(), GameConfig.geti("quests", "max_active")])
	_offers_sig = _signature(qs)
	_offer_rows = _row_buttons.size()
	_fill_active(qs)
	var rows := _row_buttons.duplicate()
	if not rows.is_empty():
		UiKit.wire_grid_focus(rows, 1)
		rows[0].call_deferred("grab_focus")
	else:
		_close_button.call_deferred("grab_focus")


## Journal signature: changes on a real progress move, on a state move and on
## an urgent countdown tick (the panel only rebuilds the right column when it
## differs, so a stable journal costs nothing).
func _signature(qs: QuestSystem) -> String:
	var parts: Array = []
	for q in qs.active:
		parts.append("%s:%s:%d:%d" % [str(q.get("id", "")), str(q.get("state", "")),
			int(q.get("progress", 0)), int(round(float(q.get("seconds_left", 0.0))))])
	return ";".join(parts)


## Right column only: a counter moved, there is no reason to touch the offers.
## Focus lives through a rebuild: a keyboard player keeps the card they were
## on, and a screen reader does not lose the place.
func _refresh_active_only() -> void:
	var qs := QuestSystem.instance
	if qs == null:
		return
	if _signature(qs) == _offers_sig:
		return
	_offers_sig = _signature(qs)
	var focus_owner := get_viewport().gui_get_focus_owner()
	var focus_text := ""
	if focus_owner is Button:
		focus_text = (focus_owner as Button).text
	var active_buttons: Array[Button] = []
	for btn in _row_buttons.slice(_offer_rows):
		if _active_box.is_ancestor_of(btn):
			active_buttons.append(btn)
	for btn in active_buttons:
		_row_buttons.erase(btn)
	_coin_sprites = _coin_sprites.filter(
		func(n): return is_instance_valid(n) and _active_box.is_ancestor_of(n))
	UiKit.clear(_active_box)
	_fill_active(qs)
	if focus_text == "":
		return
	for btn in _row_buttons:
		if btn.text == focus_text:
			btn.call_deferred("grab_focus")
			break


func _fill_offers(qs: QuestSystem) -> void:
	var offers := qs.head_offers(city_id)
	if offers.is_empty():
		var empty := Label.new()
		empty.name = "OffersEmpty"
		empty.theme_type_variation = &"QuestHint"
		empty.text = Loc.t("ui.quest.offers_empty")
		empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_offers_box.add_child(empty)
		return
	for q in offers:
		var qid := str(q.get("id", ""))
		var card := _make_card(q, [[Loc.t("ui.quest.action_take"), _on_accept.bind(qid)]])
		_offers_box.add_child(card)


func _fill_active(qs: QuestSystem) -> void:
	var shown := 0
	for q in qs.active:
		var qid := str(q.get("id", ""))
		var own_city := str(q.get("city_id", ""))
		var here := city_id == "" or own_city == city_id
		# In the journal (W) there is no head next to the card: the card itself
		# says which head the quest came from through _place_text().
		var buttons: Array = []
		if str(q.get("state", "")) == QuestSystem.STATE_READY and here:
			buttons.append([Loc.t("ui.quest.action_turn_in"), _on_turn_in.bind(qid)])
		buttons.append([Loc.t("ui.quest.action_abandon"), _on_abandon.bind(qid)])
		var card := _make_card(q, buttons)
		_active_box.add_child(card)
		shown += 1
	if shown > 0:
		return
	var empty := Label.new()
	empty.name = "ActiveEmpty"
	empty.theme_type_variation = &"QuestHint"
	empty.text = Loc.t("ui.quest.active_empty")
	empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_active_box.add_child(empty)


## --- Actions ------------------------------------------------------------------

func _on_accept(quest_id: String) -> void:
	var qs := QuestSystem.instance
	if qs == null:
		return
	var err := qs.accept(city_id, quest_id)
	_status.text = err if err != "" else Loc.t("ui.quest.msg_taken")
	SoundDB.play("ui.confirm" if err == "" else "ui.error")
	inventory_changed.emit()
	_refresh()


func _on_abandon(quest_id: String) -> void:
	var qs := QuestSystem.instance
	if qs == null:
		return
	if qs.abandon(quest_id):
		_status.text = Loc.t("ui.quest.msg_abandoned")
	else:
		_status.text = Loc.t("ui.quest.msg_no_quest")
	inventory_changed.emit()
	_refresh()


func _on_turn_in(quest_id: String) -> void:
	var qs := QuestSystem.instance
	if qs == null:
		return
	# A reward summary starts with a digit ("25 gold"); a refusal is a message.
	# The quest is NOT gone on a refusal - a finished quest stays in the journal
	# until it is really turned in.
	var res := qs.turn_in(city_id, quest_id)
	if qs.quest_by_id(quest_id).is_empty():
		_status.text = Loc.f("ui.quest.msg_turned_in", [res])
	else:
		_status.text = res
	inventory_changed.emit()
	_refresh()
