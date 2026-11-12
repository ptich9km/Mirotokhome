class_name UiKit
extends RefCounted
## Общий UI-слой проекта: палитры, фабрики StyleBox и хелперы вёрстки.
##
## До UiKit в каждой панели лежала своя копия `_make_theme()`, `_set_margins`,
## `_clear_grid`, обработки Esc и восстановления фокуса — четыре побайтово
## одинаковых `_set_margins` и три точных дубликата variation-имён
## (InnTitle ≡ ShopTitle, InnGoldLabel ≡ ShopGoldLabel,
##  InnRecruitSlot ≡ ShopItemSlot). Здесь всё это живёт в одном месте.
##
## Панели передают свою палитру в `base_theme(spec)` и добавляют сверху
## только свои variation-имена, поэтому вид не меняется.

# --- Общие константы палитры (были продублированы в inn и shop) ---
const TITLE_COLOR := Color(1.0, 0.78, 0.36)
const TITLE_SIZE := 28
const GOLD_COLOR := Color(1.0, 0.88, 0.42)
const GOLD_SIZE := 19
const SECTION_COLOR := Color(1.0, 0.76, 0.36)
const SECTION_SIZE := 18
const HINT_COLOR := Color(0.90, 0.84, 0.68)
const HINT_SIZE := 14
## Слот предмета: одинаков в таверне (InnRecruitSlot) и магазине (ShopItemSlot).
const SLOT_BG := Color(0.08, 0.07, 0.08, 0.80)
const SLOT_BORDER := Color(0.58, 0.36, 0.16, 0.96)
## Диалог-панель: inn 0.86 против shop 0.88 — оставляем разные, чтобы не менять вид.
const DIALOG_BORDER := Color(0.72, 0.46, 0.18, 0.96)

const SPHERE_COLORS := {
	"Fire": Color(1.0, 0.4, 0.1),
	"Water": Color(0.2, 0.6, 1.0),
	"Air": Color(0.8, 0.9, 1.0),
	"Earth": Color(0.6, 0.4, 0.2),
	"Astral": Color(0.7, 0.3, 0.9),
}

## Цвет качества предмета для hover card border.
static func quality_color(quality: String) -> Color:
	match quality.to_lower():
		"legendary": return Color(1.0, 0.65, 0.1)    # золотой
		"epic": return Color(0.7, 0.3, 0.9)           # фиолетовый
		"rare": return Color(0.2, 0.5, 1.0)           # синий
		"magic": return Color(0.3, 0.8, 0.9)          # голубой
		"common": return Color(0.6, 0.6, 0.6)         # серый
		_: return Color(0.78, 0.60, 0.26)             # золотой (по умолчанию)


# === Фабрики стилей ===

static func button_style(background: Color, border: Color, width: int = 2,
		radius: int = 6, content_margin: int = 6) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = background
	style.border_color = border
	style.set_border_width_all(width)
	style.set_corner_radius_all(radius)
	style.set_content_margin_all(content_margin)
	return style


static func panel_style(background: Color, border: Color, radius: int = 5,
		width: int = 2) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = background
	style.border_color = border
	style.set_border_width_all(width)
	style.set_corner_radius_all(radius)
	return style


## Кнопка-«чип» без заливки: нормальное состояние полностью прозрачное.
static func ghost_button_style(border: Color, width: int = 2, radius: int = 6,
		content_margin: int = 6) -> StyleBoxFlat:
	return button_style(Color(0, 0, 0, 0), border, width, radius, content_margin)


# === Базовая тема ===

## Спецификация панели. Обязательны только radius/margin — остальное берётся
## из «тёплой» палитры таверны/магазина/кузницы, чтобы кнопки во всём
## интерьере выглядели одинаково.
##   font_size, font_color, radius, margin, disabled, scrollbar,
##   normal_bg, normal_border, hover_bg, hover_border, focus_border
static func base_theme(spec: Dictionary = {}) -> Theme:
	var radius := int(spec.get("radius", 6))
	var margin := int(spec.get("margin", 6))
	var font_size := int(spec.get("font_size", 14))
	var font_color: Color = spec.get("font_color", Color(0.96, 0.88, 0.70))
	var theme := Theme.new()
	theme.default_font_size = font_size
	theme.set_color("font_color", "Label", font_color)
	theme.set_color("font_hover_color", "Button",
		spec.get("font_hover_color", Color(1.0, 0.92, 0.62)))
	theme.set_color("font_pressed_color", "Button",
		spec.get("font_pressed_color", Color(1.0, 1.0, 0.90)))
	theme.set_color("font_focus_color", "Button",
		spec.get("font_focus_color", Color(1.0, 0.90, 0.48)))
	theme.set_color("font_disabled_color", "Button",
		spec.get("font_disabled_color", Color(0.60, 0.55, 0.48)))

	var normal_bg: Color = spec.get("normal_bg", Color(0.24, 0.13, 0.07, 0.96))
	var normal_border: Color = spec.get("normal_border", Color(0.70, 0.40, 0.14))
	var hover_bg: Color = spec.get("hover_bg", Color(0.36, 0.19, 0.08, 0.98))
	var hover_border: Color = spec.get("hover_border", Color(1.0, 0.74, 0.26))
	var pressed_bg: Color = spec.get("pressed_bg", Color(0.15, 0.08, 0.04, 1.0))
	var pressed_border: Color = spec.get("pressed_border", Color(0.66, 0.36, 0.12))
	var disabled_bg: Color = spec.get("disabled_bg", Color(0.094, 0.086, 0.078, 1.0))
	var disabled_border: Color = spec.get("disabled_border", Color(0.35, 0.30, 0.26))
	var focus_border: Color = spec.get("focus_border", Color(1.0, 0.78, 0.20))

	theme.set_stylebox("normal", "Button",
		button_style(normal_bg, normal_border, 2, radius, margin))
	theme.set_stylebox("hover", "Button",
		button_style(hover_bg, hover_border, 2, radius, margin))
	theme.set_stylebox("pressed", "Button",
		button_style(pressed_bg, pressed_border, 2, radius, margin))
	theme.set_stylebox("disabled", "Button",
		button_style(disabled_bg, disabled_border, 2, radius, margin))
	theme.set_stylebox("focus", "Button",
		button_style(Color(normal_bg.r, normal_bg.g, normal_bg.b, 0.0), focus_border, 3,
			radius, margin))
	if bool(spec.get("scrollbar", false)):
		apply_scrollbar(theme, radius, margin)
	return theme


## Золотой стиль полосы прокрутки. Раньше он жил только в shop_panel, поэтому
## скролл рецептов в алхимии оставался системным серым.
static func apply_scrollbar(theme: Theme, radius: int = 5, _margin: int = 4) -> void:
	theme.set_stylebox("scroll", "VScrollBar",
		panel_style(Color(0.04, 0.03, 0.02, 0.38), Color(0, 0, 0, 0), radius))
	theme.set_stylebox("scroll_focus", "VScrollBar",
		panel_style(Color(0.04, 0.03, 0.02, 0.38), Color(0, 0, 0, 0), radius))
	theme.set_stylebox("grabber", "VScrollBar",
		panel_style(Color(0.62, 0.38, 0.16, 0.72), Color(0.94, 0.66, 0.24, 0.90), radius))
	theme.set_stylebox("grabber_highlight", "VScrollBar",
		panel_style(Color(0.82, 0.52, 0.20, 0.88), Color(1.0, 0.80, 0.34, 1.0), radius))
	theme.set_stylebox("grabber_pressed", "VScrollBar",
		panel_style(Color(0.96, 0.64, 0.22, 0.96), Color(1.0, 0.88, 0.48, 1.0), radius))
	theme.set_constant("grabber_minimum_height", "VScrollBar", 24)
	theme.set_constant("grabber_offset", "VScrollBar", 2)
	theme.set_stylebox("grabber_area", "VScrollBar",
		panel_style(Color(0, 0, 0, 0), Color(0, 0, 0, 0), 0))


# === Хелперы variation-имён ===

static func add_label(theme: Theme, name: StringName, color: Color, size: int = 0) -> void:
	theme.set_type_variation(name, &"Label")
	theme.set_color("font_color", name, color)
	if size > 0:
		theme.set_font_size("font_size", name, size)


static func add_panel(theme: Theme, name: StringName, bg: Color, border: Color,
		radius: int = 5) -> void:
	# variation-имя не может совпадать с именем встроенного класса:
	# Theme.set_type_variation() падает с C++-ошибкой на PanelContainer.
	var variation: StringName = name
	if variation == &"PanelContainer":
		push_warning("UiKit.add_panel: variation-имя не должно быть 'PanelContainer', подменено")
		variation = &"PanelContainerVar"
	theme.set_type_variation(variation, &"PanelContainer")
	theme.set_stylebox("panel", variation, panel_style(bg, border, radius))


## Заголовок и сумма золота — общие для таверны, магазина и школы.
static func add_title(theme: Theme, name: StringName, color: Color = TITLE_COLOR,
		size: int = TITLE_SIZE) -> void:
	add_label(theme, name, color, size)


static func add_gold_label(theme: Theme, name: StringName) -> void:
	add_label(theme, name, GOLD_COLOR, GOLD_SIZE)


static func add_slot(theme: Theme, name: StringName) -> void:
	add_panel(theme, name, SLOT_BG, SLOT_BORDER, 5)


## Панель с нарисованной 9-slice рамкой из `assets/ui/frames/`.
##
## Рамки непрозрачные — требование игрока «без прозрачности в меню». Поля
## берутся из `frames_db.json`, который пишет `tests/gen_ui_frames.py`; если
## текстуры нет, панель молча падает назад на `add_panel`, чтобы удалённый ассет
## не уронил меню.
static func add_frame(theme: Theme, name: StringName, tex_path: String,
		fallback_bg: Color = Color(0.071, 0.055, 0.043, 1.0),
		fallback_border: Color = Color(0.478, 0.290, 0.118)) -> void:
	if not ResourceLoader.exists(tex_path):
		push_warning("UiKit.add_frame: нет %s — беру плоскую панель" % tex_path)
		add_panel(theme, name, fallback_bg, fallback_border, 8)
		return
	var tex = load(tex_path)
	if not (tex is Texture2D):
		push_warning("UiKit.add_frame: %s не Texture2D" % tex_path)
		add_panel(theme, name, fallback_bg, fallback_border, 8)
		return
	var db := _frame_margins()
	var m: Dictionary = db.get(name_of_frame(tex_path), {})
	var style := StyleBoxTexture.new()
	style.texture = tex
	# Непрозрачность даёт САМА текстура (тело рамки залито в assets/ui/frames),
	# а не заливка stylebox: у StyleBoxTexture свойства bg_color нет, и попытка
	# задать его роняет скрипт в рантайме.
	if m.has("left"):
		style.texture_margin_left = int(m["left"])
		style.texture_margin_top = int(m["top"])
		style.texture_margin_right = int(m["right"])
		style.texture_margin_bottom = int(m["bottom"])
	theme.set_type_variation(name, &"PanelContainer")
	theme.set_stylebox("panel", name, style)


## Имя рамки по пути: `.../panel_frame.png` -> `panel_frame`.
static func name_of_frame(tex_path: String) -> String:
	return tex_path.get_file().get_basename()


## Поля 9-slice конкретной рамки. Нужны не только `add_frame`, но и
## `NinePatchRect` в вёрстке: декоративную линейку нельзя растягивать как
## картинку, иначе орнамент превращается в полосы.
static func frame_margin_of(tex_path: String) -> Dictionary:
	var db := _frame_margins()
	var m = db.get(name_of_frame(tex_path), {})
	return m if m is Dictionary else {}


## Поля 9-slice из `assets/ui/frames/frames_db.json`. Читается один раз и
## кэшируется: это единственный вход в манифест рамок из кода.
static func _frame_margins() -> Dictionary:
	if _frame_db_cache.size() > 0:
		return _frame_db_cache
	const DB := "res://assets/ui/frames/frames_db.json"
	if not ResourceLoader.exists(DB):
		push_warning("UiKit: нет %s — поля 9-slice беру нулевыми" % DB)
		return _frame_db_cache
	var f := FileAccess.open(DB, FileAccess.READ)
	if f == null:
		return _frame_db_cache
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	if parsed is Dictionary:
		var frames = (parsed as Dictionary).get("frames", {})
		if frames is Dictionary:
			_frame_db_cache = frames
	return _frame_db_cache


static var _frame_db_cache: Dictionary = {}


## Кнопка-вариация из пяти состояний по двум цветам.
static func add_button(theme: Theme, name: StringName, normal: Color, border: Color,
		hover: Color, hover_border: Color, radius: int = 6, margin: int = 6) -> void:
	theme.set_type_variation(name, &"Button")
	theme.set_stylebox("normal", name, button_style(normal, border, 2, radius, margin))
	theme.set_stylebox("hover", name, button_style(hover, hover_border, 2, radius, margin))
	theme.set_stylebox("pressed", name,
		button_style(hover.darkened(0.35), border, 2, radius, margin))
	theme.set_stylebox("disabled", name,
		button_style(Color(0.094, 0.086, 0.078, 1.0), border.darkened(0.45),
			2, radius, margin))
	theme.set_stylebox("focus", name,
		button_style(Color(0, 0, 0, 0), Color(1.0, 0.94, 0.42), 3, radius, margin))


# === Хелперы вёрстки ===

static func set_margins(container: MarginContainer, left: int, top: int,
		right: int, bottom: int) -> void:
	container.add_theme_constant_override("margin_left", left)
	container.add_theme_constant_override("margin_top", top)
	container.add_theme_constant_override("margin_right", right)
	container.add_theme_constant_override("margin_bottom", bottom)


## Затемнение фона под модальным окном. alpha разный у разных панелей,
## поэтому параметр обязательный.
static func make_dim(alpha: float) -> ColorRect:
	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.0, alpha)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	return dim


static func clear(container: Node) -> void:
	for child in container.get_children():
		container.remove_child(child)
		child.queue_free()


## Esc — закрыть панель. Раньше в 4 файлах копия условия, причём в
## school_panel.gd ещё и без `not event.echo` (авто-повтор дёргал панель).
static func esc_pressed(event: InputEvent) -> bool:
	return event is InputEventKey and event.pressed and not event.echo \
			and event.keycode == KEY_ESCAPE


## Запомнить элемент, который был в фокусе до открытия панели.
## Панели — это CanvasLayer, поэтому параметр Node, а не CanvasItem.
static func save_focus(node: Node) -> Control:
	if node == null or not is_instance_valid(node):
		return null
	var viewport := node.get_viewport()
	return null if viewport == null else viewport.gui_get_focus_owner()


static func restore_focus(previous: Control) -> void:
	if previous != null and is_instance_valid(previous):
		previous.call_deferred("grab_focus")


## Навигация по сетке кнопок: соседи влево/вправо/вверх/вниз + Tab.
## Логика перенесена из shop_panel.gd:_wire_grid_focus без изменений.
static func wire_grid_focus(buttons: Array[Button], columns: int) -> void:
	if columns <= 0 or buttons.is_empty():
		return
	for index in range(buttons.size()):
		var row := int(index / float(columns))
		var column := index % columns
		var left: Button = buttons[row * columns + maxi(column - 1, 0)]
		var right: Button = buttons[mini(row * columns + mini(column + 1, columns - 1),
			buttons.size() - 1)]
		buttons[index].focus_neighbor_left = left.get_path()
		buttons[index].focus_neighbor_right = right.get_path()
		buttons[index].focus_neighbor_top = buttons[maxi(index - columns, 0)].get_path()
		buttons[index].focus_neighbor_bottom = buttons[mini(index + columns,
			buttons.size() - 1)].get_path()
		buttons[index].focus_previous = buttons[maxi(index - 1, 0)].get_path()
		buttons[index].focus_next = buttons[mini(index + 1, buttons.size() - 1)].get_path()


## Равномерно масштабирует корень панели под окно от дизайнерского размера.
## Логика перенесена из inn/shop/blacksmith (_DESIGN_SIZE = 1024×1024).
static func fit_design_root(root: Control, design_size: Vector2) -> void:
	if not is_instance_valid(root):
		return
	var viewport := root.get_viewport()
	if viewport == null:
		return
	var viewport_size: Vector2 = viewport.get_visible_rect().size
	var factor := minf(viewport_size.x / design_size.x, viewport_size.y / design_size.y)
	root.scale = Vector2.ONE * factor
	root.position = (viewport_size - design_size * factor) * 0.5


## Подключить пересчёт масштаба к изменению размера окна.
## Передаётся именно handler панели, а не лямбда, — чтобы `_exit_tree` панели
## мог отключить ту же связь (`_update_layout`) по имени метода.
## Источник сигнала: Window (`size_changed`) либо Control (`resized`) — панели
## передают разное, поэтому поддерживаем оба.
static func bind_resize(source: Node, handler: Callable) -> void:
	if source == null or not is_instance_valid(source):
		return
	var signal_name := "resized" if source is Control else "size_changed"
	if not source.has_signal(signal_name):
		return
	if not source.is_connected(signal_name, handler):
		source.connect(signal_name, handler)
	if handler.is_valid():
		handler.call()


# === Анимации панелей ===

## Плавное появление: fade-in + scale 0.95→1.0, TRANS_BACK, 0.2s.
static func animate_in(node: Control) -> void:
	if node == null or not is_instance_valid(node):
		return
	node.modulate.a = 0.0
	node.scale = Vector2(0.95, 0.95)
	var tw := node.create_tween()
	tw.set_parallel(true)
	tw.tween_property(node, "modulate:a", 1.0, 0.2) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_property(node, "scale", Vector2.ONE, 0.2) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


## Плавное закрытие: fade-out + scale → 0.95, потом callback (queue_free).
static func animate_out(node: Control, callback: Callable) -> void:
	if node == null or not is_instance_valid(node):
		callback.call()
		return
	var tw := node.create_tween()
	tw.set_parallel(true)
	tw.tween_property(node, "modulate:a", 0.0, 0.15) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	tw.tween_property(node, "scale", Vector2(0.95, 0.95), 0.15) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	tw.chain().tween_callback(callback)

# --- Карточка предмета у курсора (наведение) ---

## Панель-карточка, которая показывается рядом с курсором при наведении на ячейку.
## Тултипы — один из главных информационных элементов UI: они обязаны быть
## компактными и НЕ перехватывать клики.
##
## Ловушка 06.10: PanelContainer-ребёнок PanelContainer растягивается на весь
## родитель, а MarginContainer/VBox внутри — по умолчанию MOUSE_FILTER_STOP.
## Карточка «расползалась на всё окно» и съедала клики по кнопкам магазина.
## Поэтому: top_level + SHRINK + IGNORE на всём поддереве.
static func make_hover_card(width: float = 300.0) -> PanelContainer:
	var card := PanelContainer.new()
	card.name = "HoverCard"
	card.visible = false
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.top_level = true
	card.z_index = 60
	card.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	card.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	card.grow_horizontal = Control.GROW_DIRECTION_END
	card.grow_vertical = Control.GROW_DIRECTION_END
	card.custom_minimum_size = Vector2(width, 0)
	card.add_theme_stylebox_override("panel",
		panel_style(Color(0.06, 0.05, 0.07, 0.97), Color(0.78, 0.60, 0.26, 0.98), 4, 2))
	var margin := MarginContainer.new()
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_margins(margin, 10, 8, 10, 8)
	card.add_child(margin)
	var box := VBoxContainer.new()
	box.name = "Box"
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_theme_constant_override("separation", 3)
	margin.add_child(box)
	_ignore_mouse_recursive(card)
	return card


## Рекурсивно снять перехват мыши: любой STOP-контейнер внутри карточки
## превращал тултип в «мёртвую зону» поверх панели.
static func _ignore_mouse_recursive(node: Node) -> void:
	var c := node as Control
	if c != null:
		c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for child in node.get_children():
		_ignore_mouse_recursive(child)


## Заполнить карточку строками и показать у точки (локальные координаты parent).
## tier — уровень крафтовой вещи (CraftVFX.TIER_*), -1 = без свечения.
static func show_hover_card(card: PanelContainer, lines: Array, at: Vector2,
		bounds: Vector2, icon_path: String = "", tint: Color = Color(-1, -1, -1, -1),
		tier: int = -1) -> void:
	if card == null or not is_instance_valid(card):
		return
	var box: Node = card.find_child("Box", true, false)
	if box == null or not (box is VBoxContainer):
		return
	clear(box)

	if tint.r >= 0.0:
		var style: StyleBoxFlat = card.get_theme_stylebox("panel").duplicate()
		style.border_color = tint
		card.add_theme_stylebox_override("panel", style)

	if icon_path != "":
		var icon_tex: Texture2D = load(icon_path) if ResourceLoader.exists(icon_path) else null
		if icon_tex != null:
			var icon_row := HBoxContainer.new()
			icon_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
			icon_row.add_theme_constant_override("separation", 8)
			box.add_child(icon_row)
			var icon_rect := TextureRect.new()
			icon_rect.texture = icon_tex
			icon_rect.custom_minimum_size = Vector2(32, 32)
			icon_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			icon_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			icon_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
			# Свечение уровня крафтовой вещи и в карточке: игрок чаще всего
			# видит предмет именно здесь (наведение), а не в сетке.
			CraftVFX.apply_to_icon(icon_rect, tier)
			icon_row.add_child(icon_rect)
			var text_box := VBoxContainer.new()
			text_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
			text_box.add_theme_constant_override("separation", 2)
			icon_row.add_child(text_box)
			var first := true
			for raw in lines:
				var line := str(raw)
				if line.is_empty():
					continue
				var label := Label.new()
				label.text = line
				label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
				label.custom_minimum_size = Vector2(maxf(80.0, card.custom_minimum_size.x - 52.0), 0)
				if first:
					label.theme_type_variation = &"HoverCardTitle"
					first = false
				else:
					label.theme_type_variation = &"HoverCardLine"
				label.mouse_filter = Control.MOUSE_FILTER_IGNORE
				text_box.add_child(label)
	else:
		var first := true
		for raw in lines:
			var line := str(raw)
			if line.is_empty():
				continue
			var label := Label.new()
			label.text = line
			label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			label.custom_minimum_size = Vector2(maxf(80.0, card.custom_minimum_size.x - 20.0), 0)
			if first:
				label.theme_type_variation = &"HoverCardTitle"
				first = false
			else:
				label.theme_type_variation = &"HoverCardLine"
			label.mouse_filter = Control.MOUSE_FILTER_IGNORE
			(box as VBoxContainer).add_child(label)

	var has_content := false
	for child in box.get_children():
		if child.get_child_count() > 0 or (child is Label and child.text != ""):
			has_content = true
			break
	if not has_content:
		hide_hover_card(card)
		return

	# Сжать до содержимого: без reset_size карточка могла унаследовать
	# «весь родитель» от прошлого показа/раскладки контейнера.
	card.reset_size()
	_ignore_mouse_recursive(card)
	card.visible = true
	var size := card.size
	if size.x < 40.0 or size.y < 20.0:
		size = card.get_combined_minimum_size()
	var pos := at + Vector2(18, 10)
	if pos.x + size.x > bounds.x - 8.0:
		pos.x = maxf(8.0, at.x - size.x - 18.0)
	if pos.y + size.y > bounds.y - 8.0:
		pos.y = maxf(8.0, bounds.y - size.y - 8.0)
	card.position = pos


static func hide_hover_card(card: PanelContainer) -> void:
	if card != null and is_instance_valid(card):
		card.visible = false


## Стили variation-имён карточки — общие для всех панелей.
static func add_hover_card_styles(theme: Theme) -> void:
	add_label(theme, &"HoverCardTitle", TITLE_COLOR, 15)
	add_label(theme, &"HoverCardLine", HINT_COLOR, 13)


## Shared text of an item hover card. `class_block` is the class-restriction
## line ("✖ …") that only the inventory shows; the world UI passes "".
static func item_card_lines(item: Dictionary, class_block: String = "") -> Array:
	var lines: Array = [ItemDB.display_name(item)]
	var sub: Array[String] = []
	# JSON `null` reaches GDScript as null, and str(null) is "<null>": potions and
	# books carry `material: null`, which put "<null>" right under the item name.
	for f in ["quality", "material", "type"]:
		var raw = item.get(f, "")
		if not (raw is String):
			continue
		var v := str(raw)
		# Quest goods are their own category and are marked as such in the card.
		if f == "quality" and v == "Quest":
			v = Loc.t("ui.quality.quest")
		if v != "" and v != "None":
			sub.append(v)
	if not sub.is_empty():
		lines.append(" · ".join(sub))
	var stats: Array[String] = []
	var dmin := int(item.get("damage_min", 0))
	var dmax := int(item.get("damage_max", 0))
	if dmin > 0 or dmax > 0:
		stats.append(Loc.f("ui.tip.damage", [dmin, dmax]))
	var th := int(item.get("to_hit", 0))
	if th != 0:
		stats.append(Loc.f("ui.tip.to_hit", [th]))
	var df := int(item.get("defence", 0))
	if df > 0:
		stats.append(Loc.f("ui.tip.defense", [df]))
	var ab := int(item.get("absorption", 0))
	if ab > 0:
		stats.append(Loc.f("ui.tip.absorption", [ab]))
	var mc := int(item.get("magcap", 0))
	if mc > 0:
		stats.append(Loc.f("ui.tip.magic", [mc]))
	if not stats.is_empty():
		lines.append(" · ".join(stats))
	lines.append(Loc.f("ui.tip.weight_price", [
		float(item.get("weight", 0.0)), int(item.get("price", 0))]))
	if class_block != "":
		lines.append("✖ " + class_block)
	return lines
