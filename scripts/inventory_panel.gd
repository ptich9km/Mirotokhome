class_name InventoryPanel
extends CanvasLayer
## Инвентарь, экипировка и характеристики героя.
##
## Раскладка 2×2 (решение игрока 06.10):
##   1×1 — персонаж (кукла + 10 слотов)
##   1×2 — параметры и характеристики (перенос из HUD StatsPanel)
##   2×1+2×2 — склад со скроллом вниз
## Панель по центру, игра видна по краям (SCREEN_INSET). Без портретов Аллодов.

signal closed
signal inventory_changed

const EQUIP_SLOT_SIZE := Vector2(54, 54)
const INV_SLOT := 62
const INV_GAP := 4
## Склад занимает всю ширину окна: колонки считаются от неё, а не заданы
## шестёркой. Иначе ~530 px ширины пустовали, а предметы уходили вниз и
## включали вертикальный скролл (жалоба игрока 23.10).
const INV_MIN_COLUMNS := 6
const INV_MAX_COLUMNS := 14
## Запас под вертикальный скроллбар. Вычитаем ВСЕГДА, даже когда полосы нет:
## иначе при её появлении ширина меняется, число колонок пересчитывается и
## раскладка «мигает» между 13 и 14 колонками.
const INV_SCROLLBAR_RESERVE := 12.0
const GOLD_COIN_SIZE := 20.0

var player: Player
var _root: MarginContainer
var _panel: PanelContainer
var _previous_focus: Control
var _equip_slots := {}
var _doll: TextureRect = null
var _hero_name: Label = null
var _highlight_slot := ""
var _inventory_slots: Array = []
var _inventory_items: Array = []
var _hover_card: PanelContainer = null
var _gold_label: Label
var _view_tabs: Array[Button] = []
var _view_pages: Array[Control] = []
var _view_group: ButtonGroup = null
var _view_index := 0
var _page_inventory: VBoxContainer = null
var _page_relations: VBoxContainer = null
var _page_crafts: VBoxContainer = null
var _relations_box: VBoxContainer = null
var _crafts_box: VBoxContainer = null
var _gold_coin: TextureRect = null
var _gold_frame := 0
var _gold_anim_t := 0.0
## Essence icons in the bag: they share one slow sway with the header coin.
var _essence_icons: Array[TextureRect] = []
var _essence_frame := 0
var _essence_t := 0.0
var _inventory_grid: GridContainer
var _inventory_scroll: ScrollContainer
var _stats_box: VBoxContainer
var _stats_scroll: ScrollContainer
var _stats_col: VBoxContainer
var _stat_labels := {}
var _hp_label: Label = null
var _mp_label: Label = null
var _shield_label: Label = null
var _stats_refresh_t := 0.0
var _magic_click_key := ""
var _magic_click_time := 0.0

var hovered_item_key: String = ""

const _LABEL_COLOR := UiTheme.TEXT_MUTED
const _VALUE_COLOR := UiTheme.TEXT
const _ACCENT_COLOR := UiTheme.ACCENT
const _HP_COLOR := Color(0.55, 0.85, 0.55)
const _MP_COLOR := Color(0.55, 0.7, 1.0)
const _RESIST_FIRE := Color(1.0, 0.5, 0.35)
const _RESIST_WATER := Color(0.4, 0.6, 1.0)
const _RESIST_AIR := Color(0.7, 0.85, 1.0)
const _RESIST_EARTH := Color(0.7, 0.55, 0.3)
const _RESIST_ASTRAL := Color(0.8, 0.5, 0.9)


## Second click of a double click on a scroll. The engine sets `double_click`
## itself using the OS setting, so pass that flag when you have it: the timer
## below is only a fallback for stylised input (keyboard focus etc.).
## 450 ms used to be the ONLY gate, which is tighter than the Windows default
## (500 ms) — a normal but unhurried double click was swallowed silently, and a
## book simply did not open (player report 04.11).
const MAGIC_DOUBLE_CLICK_MS := 700


func _magic_double_click(item_key: String) -> bool:
	var now := Time.get_ticks_msec()
	var hit := _magic_click_key == item_key and now - _magic_click_time < MAGIC_DOUBLE_CLICK_MS
	_magic_click_key = item_key
	_magic_click_time = now
	return hit


func setup(p: Player) -> void:
	player = p
	layer = 10
	_build_ui()


func _ready() -> void:
	_previous_focus = UiKit.save_focus(self)
	_refresh()
	set_process(true)


func _process(delta: float) -> void:
	_tick_gold_coin(delta)
	_tick_essence_icons(delta)
	# Щит/haste живут по времени — обновляем статы, пока окно открыто.
	_stats_refresh_t += delta
	if _stats_refresh_t < 0.5:
		return
	_stats_refresh_t = 0.0
	_refresh_stats()


## Essence icons of the open bag sway in phase; the list is rebuilt with the grid.
func _tick_essence_icons(delta: float) -> void:
	if _essence_icons.is_empty():
		return
	_essence_icons = _essence_icons.filter(
		func(n): return is_instance_valid(n) and n.is_inside_tree())
	if _essence_icons.is_empty():
		return
	var step := EssenceIcons.tick_frame(delta, _essence_t, _essence_frame)
	_essence_t = float(step["t"])
	var next := int(step["frame"])
	if next == _essence_frame:
		return
	_essence_frame = next
	var frames := EssenceIcons.frames()
	if frames.is_empty():
		return
	for icon in _essence_icons:
		icon.texture = frames[_essence_frame % frames.size()]


## Animated gold coin in the header: the same swaying sprite as a quest reward.
func _tick_gold_coin(delta: float) -> void:
	if _gold_coin == null or not is_instance_valid(_gold_coin):
		return
	_gold_anim_t += delta
	if _gold_anim_t < QuestIcons.COIN_FRAME_TIME:
		return
	_gold_anim_t = 0.0
	_gold_frame = (_gold_frame + 1) % QuestIcons.COIN_FRAMES
	var tex := QuestIcons.coin_frame(_gold_frame)
	if tex != null:
		_gold_coin.texture = tex


func _exit_tree() -> void:
	pass


func close() -> void:
	UiKit.restore_focus(_previous_focus)
	closed.emit()
	queue_free()


func _input(event: InputEvent) -> void:
	if UiKit.esc_pressed(event):
		close()
		get_viewport().set_input_as_handled()


func _update_layout() -> void:
	pass


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
	UiTheme.add_display_label(theme, &"InvTitle", UiTheme.FONT_SECTION, UiTheme.ACCENT)
	UiKit.add_label(theme, &"InvGoldLabel", UiTheme.ACCENT, UiTheme.FONT_SUBHEAD)
	UiKit.add_label(theme, &"InvSection", UiTheme.TEXT_MUTED, UiTheme.FONT_SECTION)
	UiKit.add_label(theme, &"InvStatLabel", UiTheme.TEXT_MUTED, UiTheme.FONT_MICRO)
	UiKit.add_label(theme, &"InvStatValue", UiTheme.TEXT, UiTheme.FONT_MICRO)
	UiKit.add_slot(theme, &"EquipSlot")
	theme.set_stylebox("panel", &"EquipSlotActive", UiKit.panel_style(
		UiTheme.PANEL_INNER.lightened(0.10), UiTheme.ACCENT_DIM,
		UiTheme.RADIUS_SLOT, UiTheme.BORDER_NORMAL))
	UiKit.add_slot(theme, &"InvSlot")
	UiKit.add_button(theme, &"InvClose",
		UiTheme.PANEL_INNER, UiTheme.PANEL_EDGE,
		UiTheme.PANEL_INNER.lightened(0.14), UiTheme.ACCENT_DIM,
		UiTheme.RADIUS_PANEL, UiTheme.SPACE_2)
	UiKit.add_button(theme, &"InvTab",
		UiTheme.TRANSPARENT, UiTheme.TRANSPARENT,
		UiTheme.PANEL_INNER, UiTheme.ACCENT_DIM,
		UiTheme.RADIUS_SLOT, UiTheme.SPACE_1)
	UiKit.add_label(theme, &"InvPageTitle", UiTheme.ACCENT, UiTheme.FONT_SECTION)
	UiKit.add_label(theme, &"InvRowLabel", UiTheme.TEXT, UiTheme.FONT_BODY)
	UiKit.add_label(theme, &"InvRowValue", UiTheme.ACCENT, UiTheme.FONT_BODY)
	UiKit.add_label(theme, &"InvRowNote", UiTheme.TEXT_MUTED, UiTheme.FONT_MICRO)
	UiKit.apply_scrollbar(theme, UiTheme.RADIUS_SLOT, UiTheme.SPACE_1)
	UiKit.add_panel(theme, &"InvPanel",
		UiTheme.PANEL_BG, UiTheme.PANEL_EDGE, UiTheme.RADIUS_FRAME)
	UiKit.add_panel(theme, &"InvSectionPanel",
		UiTheme.PANEL_INNER, UiTheme.PANEL_EDGE.darkened(0.2), UiTheme.RADIUS_PANEL)
	UiKit.add_hover_card_styles(theme)
	return theme


func _build_ui() -> void:
	var dim := UiKit.make_dim(0.45)
	add_child(dim)

	_root = MarginContainer.new()
	_root.name = "InvRoot"
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
	_panel.theme_type_variation = &"InvPanel"
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_panel.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_panel.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	# Вариант A (06.10): классический paper-doll — кукла слева, узкая таблица статов.
	_panel.custom_minimum_size = Vector2(960, 640)
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
	title.theme_type_variation = &"InvTitle"
	title.text = tr("ИНВЕНТАРЬ")
	title.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	header.add_child(title)
	_build_view_tabs(header)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	header.add_child(spacer)
	_gold_coin = TextureRect.new()
	_gold_coin.name = "GoldCoin"
	_gold_coin.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_gold_coin.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_gold_coin.custom_minimum_size = Vector2(GOLD_COIN_SIZE, GOLD_COIN_SIZE)
	_gold_coin.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_gold_coin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_gold_coin.tooltip_text = tr("Золото")
	_gold_coin.texture = QuestIcons.coin_frame(_gold_frame)
	header.add_child(_gold_coin)
	_gold_label = Label.new()
	_gold_label.name = "Gold"
	_gold_label.theme_type_variation = &"InvGoldLabel"
	_gold_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_gold_label.tooltip_text = tr("Золото")
	header.add_child(_gold_label)
	var close_btn := Button.new()
	close_btn.name = "Close"
	close_btn.text = tr("Закрыть")
	close_btn.theme_type_variation = &"InvClose"
	close_btn.custom_minimum_size = Vector2(120, 32)
	close_btn.pressed.connect(close)
	header.add_child(close_btn)

	# Страницы: «Склад» (прежняя раскладка), «Отношения», «Ремесла».
	# Вкладки живут в шапке: отдельная строка отняла бы высоту у склада и
	# вернула бы прокрутку (жалоба игрока 23.10).
	var holder := VBoxContainer.new()
	holder.name = "Pages"
	holder.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_child(holder)
	_page_inventory = VBoxContainer.new()
	_page_inventory.name = "InventoryPage"
	_page_inventory.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_page_inventory.add_theme_constant_override("separation", UiTheme.SPACE_2)
	holder.add_child(_page_inventory)
	_page_relations = _make_page("RelationsPage")
	holder.add_child(_page_relations)
	_page_crafts = _make_page("CraftsPage")
	holder.add_child(_page_crafts)
	_view_pages = [_page_inventory, _page_relations, _page_crafts]
	_set_view(0)

	# Верх: кукла (имя сверху) СЛЕВА | статы расширены вправо.
	# Порядок внутри окна (08.10): прижать paper-doll к левому краю,
	# статы без скролла за счёт ширины колонки. Размер панели 960×640 НЕ меняем.
	var top := HBoxContainer.new()
	top.name = "Top"
	top.alignment = BoxContainer.ALIGNMENT_BEGIN
	top.add_theme_constant_override("separation", UiTheme.SPACE_5)
	top.size_flags_vertical = Control.SIZE_FILL
	# Статам нужна ровно их высота, складу — весь остаток. Раньше оба были
	# EXPAND и делили остаток поровну: у склада оставалось 156 px на 194 px
	# трёх рядов и включался вертикальный скролл (жалоба игрока 23.10).
	# ScrollContainer статов сообщает минимум по содержимому, поэтому top
	# без EXPAND получает именно столько, сколько нужно таблице.
	_page_inventory.add_child(top)

	var equip_col := VBoxContainer.new()
	equip_col.name = "EquipCol"
	equip_col.custom_minimum_size = Vector2(340, 0)
	equip_col.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	equip_col.size_flags_vertical = Control.SIZE_EXPAND_FILL
	equip_col.alignment = BoxContainer.ALIGNMENT_CENTER
	top.add_child(equip_col)
	# Имя героя — НАД куклой (вариант A), не в статах.
	_hero_name = Label.new()
	_hero_name.name = "HeroName"
	_hero_name.theme_type_variation = &"InvStatValue"
	_hero_name.text = Game.hero_name
	_hero_name.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hero_name.add_theme_font_size_override("font_size", UiTheme.FONT_SUBHEAD)
	_hero_name.mouse_filter = Control.MOUSE_FILTER_IGNORE
	equip_col.add_child(_hero_name)
	_build_equipment_area(equip_col)

	# Статы: 560 по ширине, без EXPAND_FILL — иначе инвариант 06.10 (тест).
	# 560 = 928 доступной ширины - 340 куклы - 24 зазора. При 4 ячейках в ряд
	# таблица укладывается в 9 строк (у мага) вместо 15 и не прокручивается.
	var stats_col := VBoxContainer.new()
	stats_col.name = "StatsCol"
	stats_col.custom_minimum_size = Vector2(560, 0)
	stats_col.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	stats_col.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_stats_col = stats_col
	top.add_child(stats_col)
	var stats_title := Label.new()
	stats_title.theme_type_variation = &"InvSection"
	stats_title.text = tr("ХАРАКТЕРИСТИКИ")
	stats_col.add_child(stats_title)
	var stats_panel := PanelContainer.new()
	stats_panel.theme_type_variation = &"InvSectionPanel"
	stats_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	stats_col.add_child(stats_panel)
	var stats_margin := MarginContainer.new()
	UiKit.set_margins(stats_margin, UiTheme.SPACE_2, UiTheme.SPACE_1,
		UiTheme.SPACE_2, UiTheme.SPACE_1)
	stats_panel.add_child(stats_margin)
	_stats_scroll = ScrollContainer.new()
	_stats_scroll.name = "StatsScroll"
	_stats_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_stats_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_stats_scroll.follow_focus = true
	_stats_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_stats_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	stats_margin.add_child(_stats_scroll)
	_stats_box = VBoxContainer.new()
	_stats_box.name = "StatsBox"
	# 2 px, а не 4: четыре ячейки в ряд дают 8–9 строк, и плотность секций
	# освобождает складу ~20 px — этого хватает, чтобы три ряда (33 предмета)
	# влезли без прокрутки при высоте окна 640.
	_stats_box.add_theme_constant_override("separation", 2)
	_stats_box.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	_stats_box.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	_stats_scroll.add_child(_stats_box)
	_setup_stats_area()
	_stats_refresh_t = 0.0

	# Низ: склад на всю ширину
	var inv_col := VBoxContainer.new()
	inv_col.name = "InvCol"
	inv_col.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_page_inventory.add_child(inv_col)
	_build_inventory_area(inv_col)

	_build_hover_card()
	_refresh()


## Вкладки видов: склад, отношения, ремесла. Живут в шапке (height budget).
func _build_view_tabs(header: HBoxContainer) -> void:
	_view_group = ButtonGroup.new()
	var names := ["Склад", "Отношения", "Ремесла"]
	for i in range(names.size()):
		var b := Button.new()
		b.name = "ViewTab%d" % i
		b.text = tr(names[i])
		b.theme_type_variation = &"InvTab"
		b.toggle_mode = true
		b.button_group = _view_group
		b.button_pressed = i == 0
		b.focus_mode = Control.FOCUS_ALL
		b.custom_minimum_size = Vector2(0, 28)
		b.pressed.connect(_set_view.bind(i))
		header.add_child(b)
		_view_tabs.append(b)


## Страница вкладки: заголовок + скролл (на будущее — длинный список рецептов)
## + VBox строк.
func _make_page(page_name: String) -> VBoxContainer:
	var page := VBoxContainer.new()
	page.name = page_name
	page.size_flags_vertical = Control.SIZE_EXPAND_FILL
	page.add_theme_constant_override("separation", UiTheme.SPACE_1)
	page.visible = false
	var title := Label.new()
	title.theme_type_variation = &"InvPageTitle"
	if page_name == "RelationsPage":
		title.text = tr("ОТНОШЕНИЯ")
		_relations_box = VBoxContainer.new()
	elif page_name == "CraftsPage":
		title.text = tr("РЕМЁСЛА")
		_crafts_box = VBoxContainer.new()
	else:
		_relations_box = VBoxContainer.new()
	page.add_child(title)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.follow_focus = true
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	page.add_child(scroll)
	var box := _relations_box if page_name == "RelationsPage" else _crafts_box
	if box == null:
		box = VBoxContainer.new()
	box.name = "Rows"
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", UiTheme.SPACE_1)
	scroll.add_child(box)
	return page


func _set_view(index: int) -> void:
	if _view_pages.is_empty():
		return
	_view_index = clampi(index, 0, _view_pages.size() - 1)
	for i in range(_view_pages.size()):
		_view_pages[i].visible = i == _view_index
	for i in range(_view_tabs.size()):
		_view_tabs[i].set_pressed_no_signal(i == _view_index)
	if _view_index == 1:
		_refresh_relations()
	elif _view_index == 2:
		_refresh_crafts()


## --- Вкладка «Отношения» ------------------------------------------------------
## Ось репутации — раса/фракция (те же ключи, что у квестов главы города).
const FACTION_ORDER := ["humans", "ork", "necro", "druid"]

func _bus_state():
	var bus := get_node_or_null("/root/WorldBus")
	if bus == null or not ("state" in bus):
		return null
	return bus.state


func _rep_status(value: int) -> String:
	var t1 := GameConfig.geti("reputation", "tier_1")
	var t2 := GameConfig.geti("reputation", "tier_2")
	var t3 := GameConfig.geti("reputation", "tier_3")
	if value < 0:
		return tr("вражда")
	if value < t1:
		return tr("нейтрально")
	if value < t2:
		return tr("дружелюбно")
	if value < t3:
		return tr("доверие")
	return tr("союз")


## Что репутация открывает — числа берутся из того же [reputation], что и гейты.
func _rep_unlocks(value: int) -> String:
	var t1 := GameConfig.geti("reputation", "tier_1")
	var t2 := GameConfig.geti("reputation", "tier_2")
	var t3 := GameConfig.geti("reputation", "tier_3")
	var elven := GameConfig.geti("reputation", "elven_rep")
	var merc := 1
	if value >= t1:
		merc = 2
	if value >= t2:
		merc = 3
	if value >= t3:
		merc = 4
	var discount := 0
	if value >= t1:
		discount = GameConfig.geti("reputation", "discount_1")
	if value >= t2:
		discount = GameConfig.geti("reputation", "discount_2")
	if value >= t3:
		discount = GameConfig.geti("reputation", "discount_3")
	var elven_mark := tr("да") if value >= elven else tr("нет")
	return tr("Наёмники %d/4 · эльфийские свитки: %s · скидка %d%%") \
		% [merc, elven_mark, discount]


func _add_row(box: VBoxContainer, label_text: String, value_text: String,
		note: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", UiTheme.SPACE_2)
	var lab := Label.new()
	lab.theme_type_variation = &"InvRowLabel"
	lab.text = label_text
	lab.custom_minimum_size = Vector2(180, 0)
	row.add_child(lab)
	var val := Label.new()
	val.theme_type_variation = &"InvRowValue"
	val.text = value_text
	val.custom_minimum_size = Vector2(120, 0)
	row.add_child(val)
	if note != "":
		var n := Label.new()
		n.theme_type_variation = &"InvRowNote"
		n.text = note
		n.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		n.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(n)
	box.add_child(row)
	return row


func _clear_box(box: VBoxContainer) -> void:
	if box == null:
		return
	for c in box.get_children():
		c.queue_free()


func _refresh_relations() -> void:
	if _relations_box == null:
		return
	_clear_box(_relations_box)
	var st = _bus_state()
	var title := Label.new()
	title.theme_type_variation = &"InvSection"
	title.text = tr("ВАШЕ ОТНОШЕНИЕ")
	_relations_box.add_child(title)
	for race in FACTION_ORDER:
		var value := Game.hero_reputation(str(race))
		var label := Lore.faction_label(str(race))
		var mine := tr(" · ваша фракция") if Lore.hero_race_to_faction(Game.hero_race) == str(race) else ""
		_add_row(_relations_box, label + mine,
			"%d · %s" % [value, _rep_status(value)], _rep_unlocks(value))
	var note := Label.new()
	note.theme_type_variation = &"InvRowNote"
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.text = tr("Репутация растёт за задания главы города и открывает наёмников, эльфийские свитки и скидку.")
	_relations_box.add_child(note)
	if st == null:
		return
	# Отношения фракций между собой (SIM): пары без повторов, значение — к -100..100.
	var title2 := Label.new()
	title2.theme_type_variation = &"InvSection"
	title2.text = tr("ФРАКЦИИ МЕЖДУ СОБОЙ")
	_relations_box.add_child(title2)
	var names := {}
	for fid in st.factions:
		var f: Dictionary = st.factions[fid]
		var race := str(f.get("race", ""))
		var nm := str(f.get("name", ""))
		if nm == "":
			nm = Lore.faction_label(race)
		names[str(fid)] = nm
	var seen := {}
	var pairs := 0
	for key in st.relations:
		var parts := str(key).split(":")
		if parts.size() != 2:
			continue
		var a := parts[0]
		var b := parts[1]
		var pair_key := [a, b]
		pair_key.sort()
		var sig := "%s|%s" % [pair_key[0], pair_key[1]]
		if a == b or seen.has(sig):
			continue
		seen[sig] = true
		var v := int(st.relations[key])
		var left := str(names.get(a, a))
		var right := str(names.get(b, b))
		_add_row(_relations_box, "%s — %s" % [left, right],
			"%d · %s" % [v, _rep_status(v)], "")
		pairs += 1
	if pairs == 0:
		var none := Label.new()
		none.theme_type_variation = &"InvRowNote"
		none.text = tr("Фракции пока не выясняли отношений.")
		_relations_box.add_child(none)


## --- Вкладка «Ремёсла» --------------------------------------------------------
const CRAFT_ROWS := [
	{"key": "smithing", "label": "Кузнец"},
	{"key": "tailoring", "label": "Портной"},
	{"key": "mastering", "label": "Мастер"},
	{"key": "alchemy", "label": "Алхимия"},
]

func _refresh_crafts() -> void:
	if _crafts_box == null:
		return
	_clear_box(_crafts_box)
	var title := Label.new()
	title.theme_type_variation = &"InvSection"
	title.text = tr("ВАШИ НАВЫКИ")
	_crafts_box.add_child(title)
	for entry in CRAFT_ROWS:
		var key := str(entry["key"])
		var level := 0
		var exp_now := 0
		if is_instance_valid(player):
			level = player.skill_value(key)
			exp_now = int(player.experience.get(key, 0))
		var base_exp := Player.skill_to_exp(level)
		var next_exp := Player.skill_to_exp(level + 1)
		var percent := 0
		if next_exp > base_exp:
			percent = clampi(int(round(100.0 * float(exp_now - base_exp) / float(next_exp - base_exp))), 0, 100)
		_add_row(_crafts_box, tr(str(entry["label"])),
			tr("ур. %d") % level,
			tr("до следующего уровня: %d%% (%d/%d опыта)") % [percent, exp_now - base_exp, next_exp - base_exp])
	var note := Label.new()
	note.theme_type_variation = &"InvRowNote"
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.text = tr("Навык растёт от переработки и крафта; рецепты — свитки в складе.")
	_crafts_box.add_child(note)
	# Рецепты в складе по ремеслу: weapon/armor — кузнец, clothes — портной.
	var title2 := Label.new()
	title2.theme_type_variation = &"InvSection"
	title2.text = tr("РЕЦЕПТЫ В СКЛАДЕ")
	_crafts_box.add_child(title2)
	var counts := {}
	var names := {}
	if is_instance_valid(player):
		for raw_key in player.inventory:
			var item := ItemDB.find(str(raw_key))
			if str(item.get("quality", "")) != "Recipe":
				continue
			var bp := str(item.get("bp", ""))
			var kind := "smithing" if bp in ["weapon", "armor"] else ("tailoring" if bp == "clothes" else "mastering")
			counts[kind] = int(counts.get(kind, 0)) + 1
			if not names.has(kind):
				names[kind] = []
			(names[kind] as Array).append(str(item.get("name_ru", raw_key)))
	for entry in CRAFT_ROWS:
		var key := str(entry["key"])
		if key == "alchemy":
			continue
		var n := int(counts.get(key, 0))
		var list := ", ".join(PackedStringArray(names.get(key, []))) if n > 0 else tr("нет")
		_add_row(_crafts_box, tr(str(entry["label"])), "%d" % n, list if n > 0 else "")
	var alchemy := _alchemy_recipe_count()
	_add_row(_crafts_box, tr("Алхимия"), "%d" % alchemy,
		tr("базовые рецепты травника известны сразу"))


func _alchemy_recipe_count() -> int:
	var text := FileAccess.get_file_as_string("res://assets/professions/alchemy/recipes.json")
	if text == "":
		return 0
	var data: Variant = JSON.parse_string(text)
	if not (data is Dictionary):
		return 0
	var list: Variant = (data as Dictionary).get("recipes", [])
	return (list as Array).size() if list is Array else 0


func _build_hover_card() -> void:
	_hover_card = UiKit.make_hover_card(300.0)
	_panel.add_child(_hover_card)


# ─────────────────────── Экипировка 1×1 ───────────────────────

## Портрет для куклы инвентаря.
static func portrait_path() -> String:
	return Game.hero_portrait_path()

func _build_equipment_area(parent: VBoxContainer) -> void:
	var row := HBoxContainer.new()
	row.name = "EquipRow"
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", UiTheme.SPACE_2)
	row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	parent.add_child(row)

	var left_col := VBoxContainer.new()
	left_col.add_theme_constant_override("separation", UiTheme.SPACE_1)
	row.add_child(left_col)
	var mid_col := VBoxContainer.new()
	mid_col.add_theme_constant_override("separation", UiTheme.SPACE_1)
	row.add_child(mid_col)
	var right_col := VBoxContainer.new()
	right_col.add_theme_constant_override("separation", UiTheme.SPACE_1)
	row.add_child(right_col)

	_doll = TextureRect.new()
	var doll_path := portrait_path()
	_doll.texture = load(doll_path) if ResourceLoader.exists(doll_path) else null
	_doll.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_doll.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_doll.custom_minimum_size = Vector2(120, 180)
	_doll.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_doll.mouse_filter = Control.MOUSE_FILTER_IGNORE

	for slot in ["weapon", "shield", "hands", "cloak"]:
		left_col.add_child(_make_equip_slot(slot))
	mid_col.add_child(_make_equip_slot("head"))
	mid_col.add_child(_doll)
	mid_col.add_child(_make_equip_slot("body"))
	for slot in ["amulet", "ring1", "ring2", "feet"]:
		right_col.add_child(_make_equip_slot(slot))


func _make_equip_slot(slot: String) -> Control:
	# Вариант A: без подписи под слотом — только tooltip по наведению/фокусу.
	var panel := PanelContainer.new()
	panel.theme_type_variation = &"EquipSlot"
	panel.custom_minimum_size = EQUIP_SLOT_SIZE
	panel.focus_mode = Control.FOCUS_ALL
	var icon := TextureRect.new()
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(icon)
	panel.gui_input.connect(_on_slot_input.bind(slot))
	panel.focus_entered.connect(func(): _on_slot_focus(slot, true))
	panel.focus_exited.connect(func(): _on_slot_focus(slot, false))
	_attach_slot_card(panel, slot)
	_equip_slots[slot] = {"panel": panel, "icon": icon}
	return panel


func _on_slot_input(event: InputEvent, slot: String) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_on_slot_clicked(slot)


func _on_slot_focus(slot: String, entered: bool) -> void:
	if not entered and _highlight_slot == slot:
		_set_slot_highlight("")
	elif entered and str(player.equipped.get(slot, "")) == "":
		_set_slot_highlight(slot)


func _on_slot_clicked(slot: String) -> void:
	if not is_instance_valid(player):
		return
	var key := str(player.equipped.get(slot, ""))
	if key != "":
		# unequip_slot сам возвращает ключ в склад (модель A, player.gd).
		if player.unequip_slot(slot):
			SoundDB.play("ui.error")
			_set_slot_highlight("")
			_refresh_inventory_grid()
			_refresh_equipment()
			_refresh_stats()
			inventory_changed.emit()
		return
	if _highlight_slot == slot:
		_set_slot_highlight("")
	else:
		_set_slot_highlight(slot)


func _set_slot_highlight(slot: String) -> void:
	_highlight_slot = slot
	for s in ItemDB.EQUIP_SLOTS:
		var cell: Dictionary = _equip_slots.get(s, {})
		if cell.is_empty():
			continue
		var panel: PanelContainer = cell.panel
		if s == slot:
			panel.theme_type_variation = &"EquipSlotActive"
		else:
			panel.theme_type_variation = &"EquipSlot"
	_refresh_inventory_grid()


func _item_matches_slot(item: Dictionary) -> bool:
	if not ItemDB.allows_class(item, Game.hero_class):
		return false
	if _highlight_slot == "":
		return true
	return ItemDB.fits_slot(item, _highlight_slot)


func _refresh_equipment() -> void:
	if not is_instance_valid(player) or _equip_slots.is_empty():
		return
	for slot in ItemDB.EQUIP_SLOTS:
		if not _equip_slots.has(slot):
			continue
		var cell: Dictionary = _equip_slots[slot]
		var icon_rect: TextureRect = cell.icon
		var key := str(player.equipped.get(slot, ""))
		if key == "":
			icon_rect.texture = null
			# Снимаем и свечение: слот пуст, а материал от прежней вещи
			# остался бы и красил бы пустоту.
			icon_rect.material = null
			icon_rect.queue_redraw()
		else:
			var it := ItemDB.find(key)
			icon_rect.texture = load(str(it.get("icon", ""))) if not it.is_empty() else null
			# Свечение уровня крафтовой вещи. Для обычной вещи CraftVFX
			# возвращает null и material просто не назначается - это обычный
			# путь, а не ошибка. Эти 10 узлов ПУЛЕНЫ (создаются один раз в
			# _build_equipment_area), поэтому здесь самое дешёвое место во всём
			# интерфейсе: ноль новых узлов на перерисовку.
			CraftVFX.apply_to_icon(icon_rect, CraftVFX.tier_of_item(it))
			icon_rect.queue_redraw()


# ─────────────────────── Статы 1×2 (сетка по секциям) ───────────────────────

func _setup_stats_area() -> void:
	if _stats_box == null:
		return
	for ch in _stats_box.get_children():
		ch.queue_free()
	_stat_labels.clear()

	# Имя — в EquipCol над куклой, не здесь (вариант A).
	#
	# Жизнь и мана — отдельным блоком НАД атрибутами. В общей сетке они
	# попадали в один ряд с Силой и Ловкостью, и статы читались вперемешку
	# (жалоба игрока 23.10). Ширина 2 ячейки, потому что значения длинные
	# («120 / 120»), а цвет уже отделяет их от нейтральных атрибутов.
	_stats_grid(_stats_box, [
		["Жизнь:", "hp", _HP_COLOR],
		["Мана:", "mp", _MP_COLOR],
	], 2)

	_section_header(tr("АТРИБУТЫ"))
	_stats_grid(_stats_box, [
		["Сила:", "body", _VALUE_COLOR],
		["Ловкость:", "agility", _VALUE_COLOR],
		["Разум:", "mind", _VALUE_COLOR],
		["Дух:", "spirit", _VALUE_COLOR],
	])

	_section_header(tr("БОЙ"))
	_stats_grid(_stats_box, [
		["Урон:", "damage", _VALUE_COLOR],
		["Броня:", "absorption", _VALUE_COLOR],
		["Атака:", "attack", _VALUE_COLOR],
		["Защита:", "defense", _VALUE_COLOR],
	])

	_section_header(tr("НАВЫКИ"))
	if Game.hero_class == "mage":
		_stats_grid(_stats_box, [
			["Магия огня:", "mage_fire", _VALUE_COLOR],
			["Сопр. огню:", "fire", _RESIST_FIRE],
			["Магия воды:", "mage_water", _VALUE_COLOR],
			["Сопр. воде:", "water", _RESIST_WATER],
			["Магия воздуха:", "mage_air", _VALUE_COLOR],
			["Сопр. воздуху:", "air", _RESIST_AIR],
			["Магия земли:", "mage_earth", _VALUE_COLOR],
			["Сопр. земле:", "earth", _RESIST_EARTH],
			["Магия астрала:", "mage_astral", _VALUE_COLOR],
			["Сопр. астралу:", "astral", _RESIST_ASTRAL],
		])
	else:
		_stats_grid(_stats_box, [
			["Меч:", "blade", _VALUE_COLOR],
			["Топор:", "axe", _VALUE_COLOR],
			["Дубина:", "bludgeon", _VALUE_COLOR],
			["Копьё:", "pike", _VALUE_COLOR],
			["Стрельба:", "shooting", _VALUE_COLOR],
		])

	_section_header(tr("ПРОЧЕЕ"))
	_stats_grid(_stats_box, [
		["Нагрузка:", "load", _VALUE_COLOR],
		["Опыт:", "exp", _VALUE_COLOR],
		["Обзор:", "sight", _VALUE_COLOR],
		["Скорость:", "speed", _VALUE_COLOR],
		["Щит:", "shield", _ACCENT_COLOR],
	])

	# Ремёсла. Навыки крафта НЕ покупаются в школе - они растут только от
	# самих ремёсел, поэтому показывать их надо здесь, рядом со всем
	# остальным, а не прятать в мастерскую.
	#
	# Четыре строки, а не по одной на вкладку мастерской: мастер по
	# улучшениям - третья вкладка следующего пакета, но его навык уже
	# существует в player.gd, и пустая строка была бы враньём.
	_section_header(tr("РЕМЁСЛА"))
	_stats_grid(_stats_box, [
		["Кузнец:", "smithing", _VALUE_COLOR],
		["Портной:", "tailoring", _VALUE_COLOR],
		["Алхимик:", "alchemy", _VALUE_COLOR],
		["Мастер:", "mastering", _VALUE_COLOR],
	])
	if _shield_label == null and _stats_box != null:
		# Страховка: строка щита обязана существовать после сборки сетки.
		for c in _stats_box.get_children():
			if c is HBoxContainer:
				for lab in (c as HBoxContainer).get_children():
					if lab is Label and str((lab as Label).text) == "Щит:":
						var sib := (c as HBoxContainer).get_children()
						if sib.size() >= 2 and sib[1] is Label:
							_shield_label = sib[1] as Label
	_refresh_stats()


## Лёгкий заголовок секции: без «леса» HSeparator, только текст + воздух.
func _section_header(title: String, value: String = "", title_only: bool = false) -> Label:
	var hdr := HBoxContainer.new()
	hdr.add_theme_constant_override("separation", UiTheme.SPACE_2)
	hdr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_stats_box.add_child(hdr)
	var t := Label.new()
	t.text = title
	t.theme_type_variation = &"InvSection"
	t.add_theme_font_size_override("font_size", UiTheme.FONT_MICRO)
	t.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hdr.add_child(t)
	if value != "" and title_only:
		var v := Label.new()
		v.text = value
		v.theme_type_variation = &"InvStatValue"
		v.mouse_filter = Control.MOUSE_FILTER_IGNORE
		hdr.add_child(v)
		return v
	return t


## Сетка статов: по умолчанию четыре ячейки в ряд. Две не влезали по высоте
## (13–15 строк) и включали прокрутку, хотя по ширине 560 px запас был большой.
## columns=2 нужен блоку «Жизнь/Мана»: там длинные значения и их всего два.
## Длинные подписи («Сопр. воздуху:») задают естественный минимум ячейки.
func _stats_grid(parent: VBoxContainer, rows: Array, columns: int = 4) -> void:
	var grid := GridContainer.new()
	grid.columns = columns
	grid.add_theme_constant_override("h_separation", UiTheme.SPACE_3)
	grid.add_theme_constant_override("v_separation", 0)
	grid.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(grid)
	for row in rows:
		var pair: Array = row
		_stat_grid_pair(grid, str(pair[0]), str(pair[1]), pair[2] if pair.size() > 2 else _VALUE_COLOR)


func _stat_grid_pair(grid: GridContainer, label: String, key: String, color: Color) -> void:
	# Ячейка Grid = HBox: ярлык 84 px + значение (не EXPAND).
	var cell := HBoxContainer.new()
	cell.add_theme_constant_override("separation", UiTheme.SPACE_1)
	cell.mouse_filter = Control.MOUSE_FILTER_IGNORE
	grid.add_child(cell)

	var ll := Label.new()
	ll.text = label
	ll.custom_minimum_size = Vector2(84, 0)
	ll.theme_type_variation = &"InvStatLabel"
	ll.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cell.add_child(ll)
	var lv := Label.new()
	lv.theme_type_variation = &"InvStatValue"
	lv.size_flags_horizontal = Control.SIZE_SHRINK_END
	lv.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cell.add_child(lv)
	if key == "hp":
		_hp_label = lv
	elif key == "mp":
		_mp_label = lv
	elif key == "shield":
		_shield_label = lv
	elif key != "":
		_stat_labels[key] = lv
	if color != _VALUE_COLOR:
		lv.add_theme_color_override("font_color", color)


func _refresh_stats() -> void:
	if not is_instance_valid(player):
		return
	var p = player
	if is_instance_valid(_hero_name):
		_hero_name.text = Game.hero_name
	_set_stat("body", str(p.body))
	_set_stat("agility", str(p.agility))
	_set_stat("mind", str(p.mind))
	_set_stat("spirit", str(p.spirit))
	if _hp_label != null:
		_hp_label.text = "%d / %d" % [p.current_hp, p.max_hp]
	if _mp_label != null:
		_mp_label.text = "%d / %d" % [p.current_mana, p.max_mana]
	_set_stat("damage", "%d-%d" % [p.get_damage_min(), p.get_damage_max()])
	_set_stat("absorption", str(p.get_absorption()))
	_set_stat("attack", str(p.get_attack()))
	_set_stat("defense", str(p.get_defense()))
	if Game.hero_class == "mage":
		_set_stat("mage_fire", str(p.fire_skill))
		_set_stat("mage_water", str(p.water_skill))
		_set_stat("mage_air", str(p.air_skill))
		_set_stat("mage_earth", str(p.earth_skill))
		_set_stat("mage_astral", str(p.astral_skill))
	else:
		_set_stat("blade", str(p.blade_skill))
		_set_stat("axe", str(p.axe_skill))
		_set_stat("bludgeon", str(p.bludgeon_skill))
		_set_stat("pike", str(p.pike_skill))
		_set_stat("shooting", str(p.shooting_skill))
	_set_stat("smithing", str(p.smithing_skill))
	_set_stat("tailoring", str(p.tailoring_skill))
	_set_stat("alchemy", str(p.alchemy_skill))
	_set_stat("mastering", str(p.mastering_skill))
	_set_stat("fire", str(p.get_protection_fire()))
	_set_stat("water", str(p.get_protection_water()))
	_set_stat("air", str(p.get_protection_air()))
	_set_stat("earth", str(p.get_protection_earth()))
	_set_stat("astral", str(p.get_protection_astral()))
	_set_stat("load", "%.1f/%.0f" % [p.get_load(), p.load_capacity()])
	_set_stat("exp", str(p.total_experience()))
	_set_stat("sight", str(p.get_sight()))
	# Скорость ЭФФЕКТИВНАЯ (Haste/Slow), как в бою — не база move_speed.
	var spd_mult := StatusEffects.speed_mult(p)
	var spd := int(round(float(p.move_speed) * spd_mult))
	_set_stat("speed", str(spd))
	# Щит мага = временная броня (Аллоды): +защита/+поглощение на время.
	if _shield_label != null:
		var sh_def := StatusEffects.shield_armor_defense(p)
		var sh_abs := StatusEffects.shield_armor_absorption(p)
		var sh_t := StatusEffects.shield_armor_time(p)
		if sh_def > 0 or sh_abs > 0:
			_shield_label.text = "+%d/%d · %.0f с" % [sh_def, sh_abs, sh_t]
		else:
			_shield_label.text = "—"


func _set_stat(key: String, value: String) -> void:
	if _stat_labels.has(key):
		_stat_labels[key].text = value


# ─────────────────────── Склад 2×1+2×2 ───────────────────────

func _build_inventory_area(parent: VBoxContainer) -> void:
	var inv_title := Label.new()
	inv_title.theme_type_variation = &"InvSection"
	inv_title.text = tr("СКЛАД")
	parent.add_child(inv_title)

	var scroll := ScrollContainer.new()
	scroll.name = "InvScroll"
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.follow_focus = true
	parent.add_child(scroll)
	_inventory_scroll = scroll

	var grid := GridContainer.new()
	grid.name = "InvGrid"
	grid.columns = INV_MIN_COLUMNS
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_theme_constant_override("h_separation", INV_GAP)
	grid.add_theme_constant_override("v_separation", INV_GAP)
	scroll.add_child(grid)
	_inventory_grid = grid
	# Ширина склада меняется вместе с окном (stretch aspect=expand): держим
	# число колонок в соответствии с ней.
	scroll.resized.connect(_fit_inventory_columns)
	call_deferred("_fit_inventory_columns")


## Подогнать число колонок склада под фактическую ширину области.
func _fit_inventory_columns() -> void:
	if _inventory_grid == null or _inventory_scroll == null:
		return
	var width := _inventory_scroll.size.x - INV_SCROLLBAR_RESERVE
	if width <= 0.0:
		return
	var cols := int(floor((width + INV_GAP) / float(INV_SLOT + INV_GAP)))
	cols = clampi(cols, INV_MIN_COLUMNS, INV_MAX_COLUMNS)
	if _inventory_grid.columns == cols:
		return
	_inventory_grid.columns = cols


func _refresh_inventory_grid() -> void:
	if _inventory_grid == null:
		return
	for s in _inventory_slots:
		if is_instance_valid(s):
			s.queue_free()
	_inventory_slots.clear()
	_inventory_items.clear()
	_essence_icons.clear()

	if not is_instance_valid(player):
		return

	var counts := {}
	for key in player.inventory:
		var k := str(key)
		counts[k] = int(counts.get(k, 0)) + 1

	for key in counts:
		var item := ItemDB.find(str(key))
		if item.is_empty():
			continue
		_add_inventory_slot(item, int(counts[str(key)]))

	if _inventory_slots.is_empty():
		var lab := Label.new()
		lab.text = tr("Склад пуст")
		lab.add_theme_font_size_override("font_size", UiTheme.FONT_SUBHEAD)
		lab.add_theme_color_override("font_color", UiTheme.TEXT_MUTED)
		_inventory_grid.add_child(lab)

	if _gold_label != null and is_instance_valid(player):
		_gold_label.text = "%d" % player.gold


func _add_inventory_slot(item: Dictionary, count: int = 0) -> void:
	var slot := PanelContainer.new()
	slot.theme_type_variation = &"InvSlot"
	slot.custom_minimum_size = Vector2(INV_SLOT, INV_SLOT)
	slot.mouse_filter = Control.MOUSE_FILTER_STOP
	_attach_item_card(slot, item)

	# Gear of the other class is dimmed: the card explains why it cannot be worn.
	if not _item_matches_slot(item):
		slot.modulate = Color(1, 1, 1, 0.30)

	_inventory_grid.add_child(slot)
	_inventory_slots.append(slot)
	_inventory_items.append(item)

	var icon_path := str(item.get("icon", ""))
	var is_essence := str(item.get("quality", "")) == "Essence" and EssenceIcons.has_anim()
	if is_essence:
		icon_path = EssenceIcons.icon()
	if icon_path != "":
		var tex = load(icon_path)
		if tex:
			var icon_rect := TextureRect.new()
			icon_rect.texture = tex
			icon_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			icon_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			icon_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
			icon_rect.offset_left = 4.0
			icon_rect.offset_top = 4.0
			icon_rect.offset_right = -4.0
			icon_rect.offset_bottom = -4.0
			icon_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
			# Свечение уровня крафтовой вещи (обычная - без материала).
			CraftVFX.apply_to_icon(icon_rect, CraftVFX.tier_of_item(item))
			CraftVFX.apply_elven(icon_rect, item)
			if is_essence:
				icon_rect.name = "EssenceIcon"
				icon_rect.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
				_essence_icons.append(icon_rect)
			slot.add_child(icon_rect)

	if count > 1:
		var cnt := Label.new()
		cnt.text = str(count)
		cnt.add_theme_font_size_override("font_size", UiTheme.FONT_MICRO)
		cnt.add_theme_color_override("font_color", UiTheme.ACCENT)
		cnt.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
		cnt.add_theme_constant_override("outline_size", 4)
		cnt.set_anchors_preset(Control.PRESET_TOP_RIGHT)
		cnt.offset_left = -24.0
		cnt.offset_top = 0.0
		cnt.offset_right = -2.0
		cnt.offset_bottom = 18.0
		cnt.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		cnt.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.add_child(cnt)

	# Метка хоткея: предмет назначен на цифру (Game.hotbar).
	var hot_slot := _hotbar_slot_of_key(str(item.get("key", "")))
	if hot_slot >= 0:
		var hk := Label.new()
		hk.text = str(hot_slot + 1)
		hk.add_theme_font_size_override("font_size", UiTheme.FONT_MICRO)
		hk.add_theme_color_override("font_color", UiTheme.ACCENT)
		hk.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
		hk.add_theme_constant_override("outline_size", 4)
		hk.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
		hk.offset_left = 2.0
		hk.offset_top = -16.0
		hk.offset_right = 18.0
		hk.offset_bottom = -2.0
		hk.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		hk.mouse_filter = Control.MOUSE_FILTER_IGNORE
		slot.add_child(hk)

	slot.gui_input.connect(func(event: InputEvent):
		if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			_on_item_clicked(item, (event as InputEventMouseButton).double_click))


func _hotbar_slot_of_key(item_key: String) -> int:
	for slot in Game.hotbar:
		var entry: Dictionary = Game.hotbar.get(slot, {})
		if str(entry.get("kind", "")) == "item" and str(entry.get("key", "")) == item_key:
			return int(slot)
	return -1


func _ui_host() -> Node:
	var p := get_parent()
	while p != null:
		if p.has_method("_begin_scroll_targeting"):
			return p
		p = p.get_parent()
	return null


func _on_item_clicked(item: Dictionary, is_double: bool = false) -> void:
	if not is_instance_valid(player):
		return
	var quality := str(item.get("quality", ""))
	var item_key := str(item.get("key", ""))

	if quality == "Herb":
		return
	if quality == "Book":
		# A book is knowledge, not a cast: one click is enough (player report
		# 04.11 — the double-click gate made the starter book look dead).
		if player.learn_book(item_key):
			SoundDB.play("ui.book_open")
			_refresh_inventory_grid()
			_refresh_equipment()
			inventory_changed.emit()
		else:
			var why := "Книга уже изучена" if player.has_mana \
				else "Книги магии читают только маги"
			_flash_equip_error(why)
		return
	if quality in ["Scroll", "SuperScroll"]:
		# Использовать свиток = прицеливание (как с хоткея). Рыцарь тоже
		# может прочитать свиток боевым действием, не только «выучить заряд».
		# A scroll casts right away, so it keeps the double click: the engine
		# flag first, the timer as a fallback.
		if not (is_double or _magic_double_click(item_key)):
			return
		var spell := SpellDB.spell_from_scroll(item_key)
		if spell == "":
			return
		# Инвентарь закрывается: открытая панель блокирует клики по миру
		# (game.gd is_editor_open), и цель нельзя указать.
		close()
		Game.pending_scroll = {"spell": spell, "item_key": item_key}
		var host := _ui_host()
		if host != null and host.has_method("_begin_scroll_targeting"):
			host._begin_scroll_targeting(item_key)
		SoundDB.play("ui.book_open")
		return
	if quality == "Potion":
		if player.use_potion(item_key):
			_refresh_inventory_grid()
			_refresh_stats()
			inventory_changed.emit()
		return

	var slot := ItemDB.slot_of(item)
	if slot == "shield" and player.two_handed:
		var dish := ItemDB.find(str(player.equipped.get("weapon", "")))
		var dish_name := str(dish.get("name_ru", ""))
		_flash_equip_error("Нужна свободная рука: снимите %s." % dish_name)
		return
	if player.equip_item(item):
		_set_slot_highlight("")
		_refresh_inventory_grid()
		_refresh_equipment()
		_refresh_stats()
		inventory_changed.emit()
	else:
		var why := ItemDB.class_block_text(item, Game.hero_class)
		if why != "":
			_flash_equip_error(why)
		_refresh_inventory_grid()


## Message above the HUD when a piece of gear refuses to go on.
func _flash_equip_error(msg: String) -> void:
	var ui_host := _ui_host()
	if ui_host != null and ui_host.has_method("_flash_targeting_error"):
		ui_host.call("_flash_targeting_error", msg)
	else:
		print(msg)


# ─────────────────────── Hover cards ───────────────────────

func _ensure_card() -> PanelContainer:
	var card := UiKit.make_hover_card(300.0)
	_panel.add_child(card)
	var theme := UiTheme.app_theme()
	UiKit.add_hover_card_styles(theme)
	card.theme = theme
	return card


func _hover_bounds() -> Vector2:
	return _panel.size if is_instance_valid(_panel) else Vector2(1024, 768)


func _hover_at(cell: Control) -> Vector2:
	if not is_instance_valid(_panel) or not is_instance_valid(cell):
		return Vector2.ZERO
	return _panel.get_global_transform().affine_inverse() * cell.global_position


func _item_card_lines(item: Dictionary) -> Array:
	var lines: Array = [str(item.get("name_ru", item.get("key", "Предмет")))]
	var sub: Array[String] = []
	for f in ["quality", "material", "type"]:
		var v := str(item.get(f, ""))
		if v != "" and v != "None":
			sub.append(v)
	if not sub.is_empty():
		lines.append(" · ".join(sub))
	var stats: Array[String] = []
	var dmin := int(item.get("damage_min", 0))
	var dmax := int(item.get("damage_max", 0))
	if dmin > 0 or dmax > 0:
		stats.append("Урон %d–%d" % [dmin, dmax])
	var th := int(item.get("to_hit", 0))
	if th != 0:
		stats.append("Атака +%d" % th)
	var df := int(item.get("defence", 0))
	if df > 0:
		stats.append("Защита %d" % df)
	var ab := int(item.get("absorption", 0))
	if ab > 0:
		stats.append("Поглощение %d" % ab)
	var mc := int(item.get("magcap", 0))
	if mc > 0:
		stats.append("Магия %d" % mc)
	if not stats.is_empty():
		lines.append(" · ".join(stats))
	lines.append("Вес %.1f · Цена %d" % [float(item.get("weight", 0.0)), int(item.get("price", 0))])
	var block := ItemDB.class_block_text(item, Game.hero_class)
	if block != "":
		lines.append("✖ " + block)
	return lines


func _attach_item_card(cell: Control, item: Dictionary) -> void:
	if not is_instance_valid(cell) or item.is_empty():
		return
	var icon_path := str(item.get("icon", ""))
	if str(item.get("quality", "")) == "Essence" and EssenceIcons.has_anim():
		icon_path = EssenceIcons.icon()
	var qcolor := UiKit.quality_color(str(item.get("quality", "")))
	var tier := CraftVFX.tier_of_item(item)
	var hover_key := str(item.get("key", ""))
	cell.mouse_entered.connect(func():
		hovered_item_key = hover_key
		if _hover_card == null:
			_hover_card = _ensure_card()
		UiKit.show_hover_card(_hover_card, _item_card_lines(item),
			_hover_at(cell), _hover_bounds(), icon_path, qcolor, tier))
	cell.mouse_exited.connect(func():
		if hovered_item_key == hover_key:
			hovered_item_key = ""
		if _hover_card != null and _hover_card.visible:
			var mouse_pos := get_viewport().get_mouse_position()
			var cell_rect := Rect2(cell.global_position, cell.size)
			if not cell_rect.has_point(mouse_pos):
				UiKit.hide_hover_card(_hover_card))
	cell.focus_entered.connect(func():
		hovered_item_key = hover_key
		if _hover_card == null:
			_hover_card = _ensure_card()
		UiKit.show_hover_card(_hover_card, _item_card_lines(item),
			_hover_at(cell), _hover_bounds(), icon_path, qcolor, tier))
	cell.focus_exited.connect(func():
		if hovered_item_key == hover_key:
			hovered_item_key = ""
		if _hover_card != null:
			UiKit.hide_hover_card(_hover_card))


func _attach_slot_card(cell: Control, slot: String) -> void:
	if not is_instance_valid(cell):
		return
	cell.mouse_entered.connect(func(): _show_slot_card(cell, slot))
	cell.mouse_exited.connect(func():
		if _hover_card != null and _hover_card.visible:
			var mouse_pos := get_viewport().get_mouse_position()
			var cell_rect := Rect2(cell.global_position, cell.size)
			if not cell_rect.has_point(mouse_pos):
				_hide_slot_card())
	cell.focus_entered.connect(func(): _show_slot_card(cell, slot))
	cell.focus_exited.connect(func(): _hide_slot_card())


func _show_slot_card(cell: Control, slot: String) -> void:
	if not is_instance_valid(player):
		return
	if _hover_card == null:
		_hover_card = _ensure_card()
	var key := str(player.equipped.get(slot, ""))
	if key == "":
		# Empty slot: the card tells what kind of gear goes here for this class.
		var hint: Array = [ItemDB.slot_title(slot),
			"Сюда одевается: " + ItemDB.slot_fits_text(slot, Game.hero_class)]
		UiKit.show_hover_card(_hover_card, hint, _hover_at(cell), _hover_bounds())
		return
	var it := ItemDB.find(key)
	if it.is_empty():
		_hide_slot_card()
		return
	var lines: Array = _item_card_lines(it)
	lines.append("Слот: %s (клик — снять)" % ItemDB.slot_title(slot))
	var icon_path := str(it.get("icon", ""))
	var qcolor := UiKit.quality_color(str(it.get("quality", "")))
	UiKit.show_hover_card(_hover_card, lines, _hover_at(cell), _hover_bounds(),
		icon_path, qcolor, CraftVFX.tier_of_item(it))


func _hide_slot_card() -> void:
	if _hover_card != null:
		UiKit.hide_hover_card(_hover_card)


func _refresh() -> void:
	_refresh_equipment()
	_refresh_inventory_grid()
	_refresh_stats()
	if _view_index == 1:
		_refresh_relations()
	elif _view_index == 2:
		_refresh_crafts()
