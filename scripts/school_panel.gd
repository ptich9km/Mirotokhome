class_name SchoolPanel
extends CanvasLayer
## Школа тренировок (Training School): мгновенно поднять навык за золото.
## Цена растёт с уровнем навыка (как в оригинале — «цены становятся безрассудными»).
##
## Панель переведена на общий UI-слой (UiKit) и контейнеры. До этого она была
## единственной интерьерной панелью на хардкоженных координатах: Panel(340, 90)
## размером 600x620 плюс position/size у каждого узла, локальные theme override,
## свой _input с KEY_ESCAPE и без fit_design_root — на другом размере окна
## панель разъезжалась. Своего фонового арта у школы в проекте нет, поэтому вид
## нейтральный, как у панели алхимии.

signal closed
signal inventory_changed

## Skill rows: the first column is a localization KEY, translated when the row is
## built (a const cannot call `Loc.t()`).
const SKILLS := [
	["ui.skill.blade", "blade_skill"], ["ui.skill.axe", "axe_skill"],
	["ui.skill.bludgeon", "bludgeon_skill"], ["ui.skill.pike", "pike_skill"],
	["ui.skill.shooting", "shooting_skill"], ["ui.skill.fire", "fire_skill"],
	["ui.skill.water", "water_skill"], ["ui.skill.air", "air_skill"],
	["ui.skill.earth", "earth_skill"], ["ui.skill.astral", "astral_skill"],
]

const _DESIGN_WIDTH := 760
const _ROW_HEIGHT := 44

var player: Player
var _rows: Array = []
var _gold_label: Label
var _close_button: Button
var _train_buttons: Array[Button] = []
var _previous_focus: Control
var _content: VBoxContainer
var _scroll: ScrollContainer
var _list: VBoxContainer
var _root: MarginContainer

func setup(p: Player) -> void:
	player = p
	layer = 10
	_build_ui()

func _ready() -> void:
	_previous_focus = UiKit.save_focus(self)
	# Фокус и соседи — только в _ready(): в setup() узлы ещё не в дереве,
	# и get_path() не даёт валидных путей (соседи не прописывались вовсе).
	# Навигация: «строка навыка -> кнопка», 3 кнопки в горизонтальном ряду.
	UiKit.wire_grid_focus(_train_buttons, 3)
	if not _train_buttons.is_empty():
		_train_buttons[0].call_deferred("grab_focus")
	else:
		_close_button.call_deferred("grab_focus")
	_fit_list()
	UiKit.bind_resize(get_window(), _fit_list)
	_refresh()

## Высота списка считается от окна: ScrollContainer тянет минимум по СОДЕРЖИМОМУ
## (10 строк = 554 px), и без этого панель выталкивалась за нижний край на 1280x600.
## Всё остальное (шапка, заголовки, подвал, отступы) измеряем по факту.
const _LIST_MIN := 150.0
const _LIST_MAX := 560.0

func _fit_list() -> void:
	if not is_instance_valid(_scroll) or not is_instance_valid(_content):
		return
	var vp := get_viewport()
	if vp == null:
		return
	var other := 0.0
	for child in _content.get_children():
		if child == _scroll:
			continue
		other += (child as Control).get_combined_minimum_size().y
	other += float(_content.get_theme_constant("separation")) \
		* float(maxi(0, _content.get_child_count() - 1))
	other += 36.0  # внутренние поля панели
	other += 48.0  # внешние поля корня
	var h := float(vp.get_visible_rect().size.y)
	_scroll.custom_minimum_size = Vector2(0.0, clampf(h - other, _LIST_MIN, _LIST_MAX))
	# Самокорректировка: оценка `other` по узлам может промахнуться на несколько
	# пикселей (тема, шрифты), и панель тогда выходит на 4 px за край. Измеряем
	# реальное переполнение и добираем, вместо подгонки константы вручную.
	if is_instance_valid(_root):
		var overflow: float = _root.get_combined_minimum_size().y - h
		if overflow > 0.0:
			_scroll.custom_minimum_size.y = maxf(
				_LIST_MIN, _scroll.custom_minimum_size.y - overflow)

func _build_ui() -> void:
	var dim := UiKit.make_dim(0.66)
	add_child(dim)

	# Корень: контейнер во весь экран, а не Panel с координатами.
	var root := MarginContainer.new()
	root.name = "SchoolRoot"
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UiKit.set_margins(root, 24, 24, 24, 24)
	root.theme = _make_theme()
	add_child(root)
	_root = root

	# Центрируем панель: пустой растягивается, панель имеет свою ширину.
	var center := HBoxContainer.new()
	center.name = "Center"
	center.alignment = BoxContainer.ALIGNMENT_CENTER
	root.add_child(center)
	var side := Control.new()
	side.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	side.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.add_child(side)

	var panel := PanelContainer.new()
	panel.name = "Panel"
	panel.theme_type_variation = &"SchoolPanel"
	panel.custom_minimum_size = Vector2(_DESIGN_WIDTH, 0)
	center.add_child(panel)

	var margin := MarginContainer.new()
	margin.name = "Margin"
	UiKit.set_margins(margin, 20, 18, 20, 18)
	panel.add_child(margin)

	var content := VBoxContainer.new()
	content.name = "Content"
	content.add_theme_constant_override("separation", 12)
	margin.add_child(content)
	_content = content

	# --- Шапка: заголовок + золото ---
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 12)
	content.add_child(header)
	var title := Label.new()
	title.theme_type_variation = &"SchoolTitle"
	title.text = Loc.t("ui.school.title")
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	_gold_label = Label.new()
	_gold_label.theme_type_variation = &"SchoolGold"
	_gold_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	header.add_child(_gold_label)

	# --- Заголовки колонок ---
	var head := HBoxContainer.new()
	head.name = "Head"
	head.add_theme_constant_override("separation", 10)
	content.add_child(head)
	for spec in [["ui.school.skill", 260], ["ui.school.level", 110], ["ui.school.price", 120], ["", 170]]:
		var h := Label.new()
		h.theme_type_variation = &"SchoolColumnTitle"
		h.text = Loc.t(str(spec[0])) if str(spec[0]) != "" else ""
		h.custom_minimum_size = Vector2(float(spec[1]), 24)
		head.add_child(h)

	# --- Список навыков в прокрутке ---
	var scroll := ScrollContainer.new()
	scroll.name = "Scroll"
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.follow_focus = true
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_child(scroll)
	_scroll = scroll

	var list := VBoxContainer.new()
	list.name = "SkillList"
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 6)
	scroll.add_child(list)
	_list = list

	for s in SKILLS:
		list.add_child(_make_row(str(s[0]), str(s[1])))

	# --- Кнопка закрытия ---
	var footer := HBoxContainer.new()
	footer.alignment = BoxContainer.ALIGNMENT_CENTER
	content.add_child(footer)
	_close_button = Button.new()
	_close_button.text = Loc.t("ui.btn.close")
	_close_button.custom_minimum_size = Vector2(160, 38)
	_close_button.pressed.connect(close)
	footer.add_child(_close_button)

## Строка одного навыка: название, уровень, цена, кнопка «Обучить».
func _make_row(skill_name: String, field: String) -> Control:
	var slot := PanelContainer.new()
	slot.theme_type_variation = &"SchoolRow"

	var margin := MarginContainer.new()
	UiKit.set_margins(margin, 10, 6, 10, 6)
	slot.add_child(margin)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	margin.add_child(row)

	var name_lbl := Label.new()
	name_lbl.text = Loc.t(skill_name)
	name_lbl.custom_minimum_size = Vector2(260, _ROW_HEIGHT - 12)
	name_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(name_lbl)

	var val_lbl := Label.new()
	val_lbl.text = "0"
	val_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	val_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	val_lbl.custom_minimum_size = Vector2(110, _ROW_HEIGHT - 12)
	row.add_child(val_lbl)

	var cost_lbl := Label.new()
	cost_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	cost_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	cost_lbl.custom_minimum_size = Vector2(120, _ROW_HEIGHT - 12)
	row.add_child(cost_lbl)

	var btn := Button.new()
	btn.text = Loc.t("ui.school.train")
	btn.custom_minimum_size = Vector2(170, _ROW_HEIGHT - 12)
	btn.focus_mode = Control.FOCUS_ALL
	btn.pressed.connect(_train.bind(field))
	row.add_child(btn)
	_train_buttons.append(btn)

	_rows.append({"field": field, "val": val_lbl, "cost": cost_lbl, "btn": btn})
	return slot

func _train_cost(level: int) -> int:
	return 20 + level * level * 5

func _refresh() -> void:
	if not is_instance_valid(player):
		return
	_gold_label.text = Loc.f("ui.card.gold", [player.gold])
	for r in _rows:
		var level := int(player.get(r["field"]))
		var cost := _train_cost(level)
		(r["val"] as Label).text = str(level)
		(r["cost"] as Label).text = str(cost)
		(r["btn"] as Button).disabled = player.gold < cost

func _train(field: String) -> void:
	if not is_instance_valid(player):
		return
	var level := int(player.get(field))
	var cost := _train_cost(level)
	if player.gold < cost:
		print("Not enough gold!")
		return
	player.gold -= cost
	# set_skill_field, а не player.set: он пишет И поле, И опыт. Раньше здесь
	# был player.set, из-за чего покупка не переживала загрузку сейва.
	player.set_skill_field(field, level + 1)
	SoundDB.play("ui.craft")
	_refresh()
	print("Skill %s -> %d" % [field, level + 1])

func _input(event: InputEvent) -> void:
	if UiKit.esc_pressed(event):
		close()
		get_viewport().set_input_as_handled()

func close() -> void:
	UiKit.restore_focus(_previous_focus)
	closed.emit()
	queue_free()

## Тема школы — токены UiTheme, тот же тёплый стиль, что и у главного меню.
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
	UiKit.add_panel(theme, &"SchoolPanel",
		UiTheme.PANEL_BG, UiTheme.PANEL_EDGE, UiTheme.RADIUS_FRAME)
	UiKit.add_panel(theme, &"SchoolRow",
		UiTheme.PANEL_INNER, UiTheme.PANEL_EDGE.darkened(0.2), UiTheme.RADIUS_SLOT)
	UiTheme.add_display_label(theme, &"SchoolTitle", UiTheme.FONT_SECTION, UiTheme.ACCENT)
	UiKit.add_label(theme, &"SchoolGold", UiTheme.ACCENT, UiTheme.FONT_SUBHEAD)
	UiKit.add_label(theme, &"SchoolColumnTitle", UiTheme.TEXT_MUTED, UiTheme.FONT_BODY)
	return theme
