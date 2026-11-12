class_name WorkshopPanel
extends CanvasLayer

## Мастерская: кузнец / портной / (мастер — позже).
##
## ХОСТ ТАБОВ. Вкладки создаются циклом по CraftDB.CRAFT_KINDS через
## _enabled_kinds(), а не списком литералов: третья вкладка появится включением
## ключа в конфиге плюс одной строкой, и нигде не придётся двигать индексы.
## Порядок и количество табов НЕ пишутся в сейв, поэтому сдвиг индексов не
## сломает сохранение.
##
## TabContainer, а не кнопки-категории как в shop_panel: он даёт навигацию
## стрелками и геймпадом по таб-баре бесплатно, иначе её пришлось бы писать
## руками сразу для трёх вкладок.
##
## Скелет узлов - копия канонического из blacksmith_panel.gd:36-150 и
## alchemy_panel.gd:30-134 (dim -> MarginContainer(SCREEN_INSET) ->
## HBox Center -> PanelContainer -> MarginContainer -> VBoxContainer), с
## TabContainer между шапкой и подвалом.

signal closed
signal inventory_changed

var _panel: PanelContainer
var _root: MarginContainer
var _tabs: TabContainer
var _close_button: Button
var _previous_focus: Control
var _craft_tabs: Array[CraftTab] = []
var _footer_label: Label
var _inv_grid: GridContainer
var _inv_scroll: ScrollContainer
var _inv_title: Label
var _player: Player

## Tab captions are KEYS: a const cannot call `Loc.t()`, and the caption must
## follow the UI language.
const TAB_TITLES := {
	CraftDB.SMITH: "ui.inv.craft.smith",
	CraftDB.TAILOR: "ui.inv.craft.tailor",
	CraftDB.MASTER: "ui.inv.craft.master",
}

const _CELL_INV := Vector2(72, 76)
const _PANEL_MIN := Vector2(900, 620)


func setup(p: Player) -> void:
	layer = 10
	_player = p
	_build_ui(p)


func _ready() -> void:
	_previous_focus = UiKit.save_focus(self)
	_tabs.tab_changed.connect(_on_tab_changed)
	refresh_active()
	_refresh_inventory_shelf()
	_focus_first()


func _build_ui(p: Player) -> void:
	add_child(UiKit.make_dim(0.6))
	_root = MarginContainer.new()
	_root.name = "WorkshopRoot"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UiKit.set_margins(_root, UiTheme.SCREEN_INSET, UiTheme.SCREEN_INSET,
		UiTheme.SCREEN_INSET, UiTheme.SCREEN_INSET)
	_root.theme = _make_theme()
	add_child(_root)

	# Центр + фиксированный размер — как у инвентаря: панель всегда по центру
	# и не «прыгает» при resize (08.10).
	var center := CenterContainer.new()
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(center)

	_panel = PanelContainer.new()
	_panel.theme_type_variation = &"WorkshopPanel"
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_panel.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_panel.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_panel.custom_minimum_size = _PANEL_MIN
	center.add_child(_panel)

	var margin := MarginContainer.new()
	UiKit.set_margins(margin, UiTheme.SPACE_4, UiTheme.SPACE_3, UiTheme.SPACE_4, UiTheme.SPACE_3)
	_panel.add_child(margin)

	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", UiTheme.SPACE_2)
	margin.add_child(content)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", UiTheme.SPACE_3)
	content.add_child(header)

	var title := Label.new()
	title.name = "Title"
	title.theme_type_variation = &"WorkshopTitle"
	title.text = Loc.t("ui.craft.title")
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	header.add_child(title)

	_close_button = Button.new()
	_close_button.name = "Close"
	_close_button.theme_type_variation = &"WorkshopClose"
	_close_button.text = Loc.t("ui.btn.close")
	_close_button.custom_minimum_size = Vector2(120, 32)
	_close_button.focus_mode = Control.FOCUS_ALL
	_close_button.pressed.connect(close)
	header.add_child(_close_button)

	_tabs = TabContainer.new()
	_tabs.name = "Tabs"
	_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_child(_tabs)

	_craft_tabs.clear()
	for kind in _enabled_kinds():
		var tab: CraftTab
		if kind == CraftDB.SMITH:
			tab = CraftSmithTab.new()
		elif kind == CraftDB.TAILOR:
			tab = CraftTailorTab.new()
		else:
			tab = CraftMasterTab.new()
		tab.name = kind
		tab.setup(p, kind)
		tab.request_refresh.connect(refresh_active)
		tab.request_inventory_changed.connect(_on_inventory_changed)
		_tabs.add_child(tab)
		_tabs.set_tab_title(_tabs.get_tab_idx_from_control(tab),
			Loc.t(str(TAB_TITLES.get(kind, kind))))
		_craft_tabs.append(tab)

	# Инвентарь игрока: аккуратная полка внизу панели (как в магазине).
	var inv_panel := PanelContainer.new()
	inv_panel.name = "InvShelfPanel"
	inv_panel.theme_type_variation = &"CraftListPanel"
	inv_panel.size_flags_vertical = Control.SIZE_SHRINK_END
	content.add_child(inv_panel)
	var inv_m := MarginContainer.new()
	UiKit.set_margins(inv_m, UiTheme.SPACE_2, UiTheme.SPACE_1, UiTheme.SPACE_2, UiTheme.SPACE_1)
	inv_panel.add_child(inv_m)
	var inv_col := VBoxContainer.new()
	inv_col.add_theme_constant_override("separation", UiTheme.SPACE_1)
	inv_m.add_child(inv_col)
	_inv_title = Label.new()
	_inv_title.theme_type_variation = &"CraftSection"
	_inv_title.text = Loc.t("ui.craft.inv_title")
	inv_col.add_child(_inv_title)
	_inv_scroll = ScrollContainer.new()
	_inv_scroll.name = "InvShelfScroll"
	_inv_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_inv_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_inv_scroll.follow_focus = true
	_inv_scroll.custom_minimum_size = Vector2(0, 80)
	inv_col.add_child(_inv_scroll)
	_inv_grid = GridContainer.new()
	_inv_grid.name = "InvShelf"
	_inv_grid.columns = 10
	_inv_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_inv_grid.add_theme_constant_override("h_separation", UiTheme.SPACE_1)
	_inv_grid.add_theme_constant_override("v_separation", UiTheme.SPACE_1)
	_inv_scroll.add_child(_inv_grid)

	var footer := HBoxContainer.new()
	footer.add_theme_constant_override("separation", UiTheme.SPACE_2)
	content.add_child(footer)

	_footer_label = Label.new()
	_footer_label.theme_type_variation = &"WorkshopHint"
	_footer_label.text = Loc.t("ui.craft.footer")
	_footer_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	footer.add_child(_footer_label)


func _refresh_inventory_shelf() -> void:
	if _inv_grid == null or not is_instance_valid(_inv_grid):
		return
	UiKit.clear(_inv_grid)
	if not is_instance_valid(_player):
		return
	# Полка показывает материалы/снаряжение. Свитки-рецепты (quality Recipe)
	# НЕ показываем: это ключи разблокировки, они видны в лавке и списке
	# рецептов своей вкладки — иначе один свиток «светится» на всех вкладках.
	var counts := {}
	for raw in _player.inventory:
		var key := str(raw)
		counts[key] = int(counts.get(key, 0)) + 1
	var keys := counts.keys()
	keys.sort()
	for key in keys:
		var item := ItemDB.find(str(key))
		if item.is_empty():
			continue
		if str(item.get("quality", "")) == "Recipe":
			continue
		_inv_grid.add_child(_make_inv_slot(item, int(counts[key])))


func _make_inv_slot(item: Dictionary, count: int) -> PanelContainer:
	var slot := PanelContainer.new()
	slot.theme_type_variation = &"CraftListItem"
	slot.custom_minimum_size = _CELL_INV
	var m := MarginContainer.new()
	UiKit.set_margins(m, UiTheme.SPACE_1, UiTheme.SPACE_1, UiTheme.SPACE_1, UiTheme.SPACE_1)
	slot.add_child(m)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 1)
	m.add_child(box)
	var icon := TextureRect.new()
	var path := str(item.get("icon", ""))
	if not path.is_empty() and ResourceLoader.exists(path):
		icon.texture = load(path)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	icon.size_flags_vertical = Control.SIZE_EXPAND_FILL
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	CraftVFX.apply_to_icon(icon, CraftVFX.tier_of_item(item))
	box.add_child(icon)
	if count > 1:
		var cl := Label.new()
		cl.theme_type_variation = &"CraftHint"
		cl.text = "×%d" % count
		cl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		cl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.add_child(cl)
	slot.tooltip_text = "%s\n%s" % [ItemDB.display_name(item), str(item.get("quality", ""))]
	return slot


func _on_inventory_changed() -> void:
	_refresh_inventory_shelf()
	refresh_active()


## Виды крафта, которые показываются. Третий включается ключом в конфиге,
## поэтому добавление вкладки = одна строка здесь плюс ключ.
func _enabled_kinds() -> Array:
	var out: Array = []
	for kind in CraftDB.CRAFT_KINDS:
		if kind == CraftDB.MASTER and not _master_enabled():
			continue
		out.append(kind)
	return out


func _master_enabled() -> bool:
	return GameConfig.geti("craft", "master_enabled") != 0


func active_tab() -> CraftTab:
	if _tabs == null or _craft_tabs.is_empty():
		return null
	var idx := clampi(_tabs.current_tab, 0, _craft_tabs.size() - 1)
	return _craft_tabs[idx]


func refresh_active() -> void:
	var tab := active_tab()
	if tab != null:
		tab.refresh()
	_refresh_inventory_shelf()


func _on_tab_changed(_index: int) -> void:
	# Фокус вяжется на КАЖДОМ переключении: узлы списка пересоздаются при
	# refresh, и абсолютные пути из wire_grid_focus после этого указывают в
	# пустоту.
	var tab := active_tab()
	if tab == null:
		return
	tab.refresh()
	tab.configure_focus(_close_button)
	_refresh_inventory_shelf()
	_focus_first()


func _focus_first() -> void:
	var tab := active_tab()
	if tab == null:
		return
	var target := tab.first_focus_target()
	if target != null and is_instance_valid(target):
		target.call_deferred("grab_focus")


func _make_theme() -> Theme:
	# Палитра ТОЛЬКО из токенов UiTheme, ни одного литерала Color(...).
	# tests/ui_design_system_smoke.gd падает на инлайн, и это не формальность:
	# инлайн-цвет - это палитра, которая со временем уедет от общей темы, и
	# ровно это уже случалось в проекте (AGENTS §12, панели без UiTheme).
	var theme := UiTheme.app_theme()
	UiKit.apply_scrollbar(theme)
	UiKit.add_panel(theme, &"WorkshopPanel", UiTheme.PANEL_BG,
		UiTheme.PANEL_EDGE, UiTheme.RADIUS_PANEL)
	UiTheme.add_display_label(theme, &"WorkshopTitle", UiTheme.FONT_SECTION,
		UiTheme.ACCENT)
	UiKit.add_label(theme, &"WorkshopHint", UiTheme.TEXT_MUTED, UiTheme.FONT_BODY)
	UiKit.add_button(theme, &"WorkshopClose", UiTheme.BG_DEEP, UiTheme.ACCENT_DIM,
		UiTheme.PANEL_INNER, UiTheme.ACCENT)
	# Таб-бар: без явных стилей уехал бы в дефолт движка — ровно тот дефект,
	# что описан в AGENTS.md §12 05.10 («тема не доходит до контрола»).
	var tab_selected := UiKit.button_style(
		UiTheme.PANEL_INNER, UiTheme.ACCENT, UiTheme.BORDER_NORMAL,
		UiTheme.RADIUS_SLOT, UiTheme.SPACE_3)
	var tab_unselected := UiKit.button_style(
		UiTheme.PANEL_BG, UiTheme.PANEL_EDGE, UiTheme.BORDER_HAIRLINE,
		UiTheme.RADIUS_SLOT, UiTheme.SPACE_3)
	theme.set_stylebox("tab_selected", "TabContainer", tab_selected)
	theme.set_stylebox("tab_unselected", "TabContainer", tab_unselected)
	theme.set_stylebox("tab_hovered", "TabContainer", tab_unselected)
	theme.set_stylebox("panel", "TabContainer", UiKit.panel_style(
		UiTheme.TRANSPARENT, UiTheme.TRANSPARENT, 0, 0))
	theme.set_stylebox("tabbar_background", "TabContainer", UiKit.panel_style(
		UiTheme.TRANSPARENT, UiTheme.TRANSPARENT, 0, 0))
	UiKit.add_panel(theme, &"CraftListPanel", UiTheme.BG_DEEP,
		UiTheme.PANEL_EDGE, UiTheme.RADIUS_PANEL)
	UiKit.add_button(theme, &"CraftListItem", UiTheme.PANEL_BG,
		UiTheme.TRANSPARENT, UiTheme.PANEL_INNER, UiTheme.PANEL_EDGE)
	UiKit.add_button(theme, &"CraftListItemActive", UiTheme.ACCENT_DIM,
		UiTheme.ACCENT, UiTheme.ACCENT, UiTheme.ACCENT)
	UiKit.add_panel(theme, &"CraftTierCard", UiTheme.PANEL_BG,
		UiTheme.SLOT_EDGE, UiTheme.RADIUS_SLOT)
	UiKit.add_panel(theme, &"CraftIngredient", UiTheme.TRANSPARENT,
		UiTheme.TRANSPARENT)
	UiTheme.add_display_label(theme, &"CraftTitle", UiTheme.FONT_SUBHEAD, UiTheme.ACCENT)
	UiTheme.add_display_label(theme, &"CraftSection", UiTheme.FONT_MICRO,
		UiTheme.TEXT_MUTED)
	UiKit.add_label(theme, &"CraftHint", UiTheme.TEXT_MUTED, UiTheme.FONT_MICRO)
	# «Ничего не выбрано» — читаемо: не муted-микро, а нормальный кегль.
	UiKit.add_label(theme, &"CraftEmpty", UiTheme.TEXT, UiTheme.FONT_BODY)
	UiKit.add_label(theme, &"CraftIngredientOk", UiTheme.SUCCESS, UiTheme.FONT_BODY)
	UiKit.add_label(theme, &"CraftIngredientMissing", UiTheme.DANGER, UiTheme.FONT_BODY)
	return theme


func _input(event: InputEvent) -> void:
	if UiKit.esc_pressed(event):
		close()
		get_viewport().set_input_as_handled()


func close() -> void:
	UiKit.restore_focus(_previous_focus)
	closed.emit()
	queue_free()
