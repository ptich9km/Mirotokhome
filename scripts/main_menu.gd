extends Control
class_name MainMenu
## Главное меню Mirotokhome.
##
## Кнопки: Новая игра / Загрузить игру (6 слотов) / Моды / Сетевая игра /
## Об авторах / Выйти (с подтверждением) + переключатель языка RU/ENG.
## «Продолжить» живёт только здесь — на character_select его больше нет.
##
## ## Что изменилось 05.10 (дизайн-система)
##
##  * Фон — ЖИВОЙ: `MenuBackdrop` грузит настоящий `.alm` и плавно его
##    двигает. Раньше был плоский `ColorRect`.
##  * Меню — непрозрачная панель, отступ `UiTheme.SCREEN_INSET` от края, по
##    краям виден мир. Раньше панель плавала в полупрозрачном затемнении.
##  * Оформление — из `UiTheme`, не инлайн. Раньше здесь стояло
##    `theme = theme`: локальная переменная затеняла свойство `Control.theme`,
##    тема строилась и выбрасывалась, и всё меню рисовалось на дефолтной теме
##    движка — все variation-имена (`MmTitle`, `MmMenuBtn`...) не резолвились.
##  * Строки — через `Loc`, язык переключается на лету без перезапуска.
##
## ## Почему интерфейс в CanvasLayer
##
## `Camera2D` и фон двигают canvas слоя 0, где живут `Control`. Поэтому мир
## вынесен в отдельный узел (позиция сглаживается сама), а весь интерфейс —
## в `CanvasLayer` поверх.

const GAME_VERSION := "0.1.0"
const GAME_AUTHOR := "ptich9km"
const GAME_LORE_KEY := "ui.about.lore"

const MENU_PATH := "res://scenes/main_menu.tscn"
const CHAR_SELECT_PATH := "res://scenes/character_select.tscn"
const GAME_PATH := "res://scenes/main.tscn"

const FRAME_PANEL := "res://assets/ui/frames/panel_frame.png"
const FRAME_WINDOW := "res://assets/ui/frames/window_frame.png"
const TEX_DIVIDER := "res://assets/ui/frames/divider.png"

## Слои: интерфейс должен быть НАД миром и над затемнением оверлея.
const UI_LAYER := 10
const OVERLAY_SCRIM_LAYER := 11

## Ширина панели меню. Экран справа остаётся под живой мир.
const PANEL_WIDTH := 420.0

var _menu_box: VBoxContainer
var _panel: PanelContainer
var _ui: CanvasLayer
var _ui_root: Control
var _overlay: Control
var _overlay_title: Label
var _overlay_body: VBoxContainer
var _menu_buttons: Array[Button] = []
var _lang_row: HBoxContainer
var _settings: SettingsPanel
var _mods_panel: ModsPanel
var _quit_confirm := false
var _fit_root: Control


func _ready() -> void:
	# Saved volume/video/key bindings must survive a restart. Before 04.11
	# apply_all() was never called, so the settings file only lived in the
	# panel's session; the game ignored every saved value.
	Settings.apply_all(get_tree().root)
	Loc.load_locale()
	MusicDB.start_playlist.call_deferred()
	# Тематический анимированный курсор вместо системной стрелки.
	add_child(load("res://scripts/cursor_layer.gd").new())
	_setup_backdrop()
	_setup_ui_layer()
	# Тема назначается ПОСЛЕ создания слоя: она должна лежать на Control
	# ВНУТРИ CanvasLayer.
	_apply_theme()
	_setup_layout()
	_setup_title()
	_setup_menu()
	_setup_language()
	_setup_footer()
	_setup_overlay()
	_refresh_language()
	if not _menu_buttons.is_empty():
		_menu_buttons[0].call_deferred("grab_focus")
	UiKit.bind_resize(get_window(), _update_layout)
	call_deferred("_update_layout")


# === Тема ===

func _apply_theme() -> void:
	var theme := UiTheme.app_theme()
	theme.set_stylebox("normal", "Button", UiKit.button_style(
		UiTheme.PANEL_BG.lightened(0.04), UiTheme.PANEL_EDGE,
		UiTheme.BORDER_NORMAL, UiTheme.RADIUS_PANEL, UiTheme.SPACE_2))
	theme.set_stylebox("hover", "Button", UiKit.button_style(
		UiTheme.PANEL_BG.lightened(0.14), UiTheme.ACCENT_DIM,
		UiTheme.BORDER_NORMAL, UiTheme.RADIUS_PANEL, UiTheme.SPACE_2))
	theme.set_stylebox("pressed", "Button", UiKit.button_style(
		UiTheme.BG_DEEP, UiTheme.PANEL_EDGE,
		UiTheme.BORDER_NORMAL, UiTheme.RADIUS_PANEL, UiTheme.SPACE_2))
	theme.set_stylebox("disabled", "Button", UiKit.button_style(
		UiTheme.BG_DEEP, UiTheme.PANEL_EDGE.darkened(0.4),
		UiTheme.BORDER_HAIRLINE, UiTheme.RADIUS_PANEL, UiTheme.SPACE_2))
	theme.set_stylebox("focus", "Button", UiKit.button_style(
		Color(0, 0, 0, 0), UiTheme.ACCENT,
		UiTheme.BORDER_FOCUS, UiTheme.RADIUS_PANEL, UiTheme.SPACE_2))

	# Панель без 9-slice: рамка panel_frame при растяжении давала толстые
	# золотые полосы по краям (полосы margins 28 px тянулись на всю высоту).
	# Орнамент-линейка (divider) остаётся отдельным NinePatchRect.
	UiKit.add_panel(theme, &"MmPanel",
		UiTheme.PANEL_BG, UiTheme.PANEL_EDGE, UiTheme.RADIUS_FRAME)
	UiKit.add_panel(theme, &"MmOverlay",
		UiTheme.PANEL_BG, UiTheme.ACCENT_DIM, UiTheme.RADIUS_FRAME)

	# Заголовок экрана — антиква крупным кеглем. Фирменное имя не переводится.
	UiTheme.add_display_label(theme, &"MmTitle", UiTheme.FONT_SCREEN, UiTheme.ACCENT)
	UiKit.add_label(theme, &"MmSub", UiTheme.TEXT_MUTED, UiTheme.FONT_BODY)
	UiKit.add_label(theme, &"MmFooter", UiTheme.TEXT_OFF, UiTheme.FONT_MICRO)
	UiKit.add_label(theme, &"MmBody", UiTheme.TEXT, UiTheme.FONT_BODY)
	UiTheme.add_display_label(theme, &"MmOverlayTitle", UiTheme.FONT_TITLE,
		UiTheme.ACCENT)

	UiKit.add_button(theme, &"MmMenuBtn",
		UiTheme.PANEL_BG.lightened(0.04), UiTheme.PANEL_EDGE,
		UiTheme.PANEL_BG.lightened(0.14), UiTheme.ACCENT_DIM,
		UiTheme.RADIUS_PANEL, UiTheme.SPACE_3)
	UiKit.add_button(theme, &"MmSlotBtn",
		UiTheme.PANEL_INNER, UiTheme.PANEL_EDGE.darkened(0.2),
		UiTheme.PANEL_INNER.lightened(0.12), UiTheme.ACCENT_DIM,
		UiTheme.RADIUS_SLOT, UiTheme.SPACE_2)
	UiKit.add_button(theme, &"MmLangBtn",
		UiTheme.PANEL_INNER, UiTheme.PANEL_EDGE.darkened(0.3),
		UiTheme.PANEL_INNER.lightened(0.12), UiTheme.ACCENT,
		UiTheme.RADIUS_SLOT, UiTheme.SPACE_2)
	# Активный язык: рамка золотая, заливка плотнее — состояние видно без цвета.
	UiKit.add_button(theme, &"MmLangActive",
		UiTheme.PANEL_INNER.lightened(0.18), UiTheme.ACCENT,
		UiTheme.PANEL_INNER.lightened(0.18), UiTheme.ACCENT,
		UiTheme.RADIUS_SLOT, UiTheme.SPACE_2)

	# Главное: присвоение свойства. Раньше тут было `theme = theme` — локальная
	# переменная затеняла `Control.theme`, тема выбрасывалась.
	#
	# И НЕ на корень сцены: Godot распространяет тему только по Control-дереву и
	# Window, `CanvasLayer` в этом обходе не прозрачен. Тема на корне доходила
	# до мира, но НЕ до кнопок в CanvasLayer — они рисовались дефолтным стилем
	# движка. Проверено замером: bg (0.1,0.1,0.1,0.6), border (0.8,0.8,0.8,1.0).
	_ui_root.theme = theme


# === Живой фон ===

func _setup_backdrop() -> void:
	var backdrop := MenuBackdrop.new()
	backdrop.name = "Backdrop"
	add_child(backdrop)


func _setup_ui_layer() -> void:
	_ui = CanvasLayer.new()
	_ui.name = "UI"
	_ui.layer = UI_LAYER
	add_child(_ui)

	# Корневой Control слоя. Именно на нём живёт тема — см. `_apply_theme`.
	_ui_root = Control.new()
	_ui_root.name = "Root"
	_ui_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_ui_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ui.add_child(_ui_root)


# === Вёрстка ===

func _setup_layout() -> void:
	# Затемнения НЕТ: панель непрозрачная, и по краям должен быть виден мир.
	var inset := MarginContainer.new()
	inset.name = "Inset"
	inset.set_anchors_preset(Control.PRESET_FULL_RECT)
	UiKit.set_margins(inset, UiTheme.SCREEN_INSET, UiTheme.SCREEN_INSET,
		UiTheme.SCREEN_INSET, UiTheme.SCREEN_INSET)
	_ui_root.add_child(inset)

	# Панель прижата ВЛЕВО, а не по центру. При центрировании она закрывала
	# ровно то место, где плывёт камера: панель занимала 38% ширины и 46%
	# высоты, и дрейф был видно только если смотреть в узкую полосу по краям.
	# Слева меню — справа мир, как в X4 и Space Engineers.
	var row := HBoxContainer.new()
	row.name = "Row"
	row.alignment = BoxContainer.ALIGNMENT_BEGIN
	inset.add_child(row)

	var column := VBoxContainer.new()
	column.name = "Column"
	column.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	column.custom_minimum_size = Vector2(PANEL_WIDTH, 0)
	row.add_child(column)

	_panel = PanelContainer.new()
	_panel.name = "Panel"
	_panel.theme_type_variation = &"MmPanel"
	_panel.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	column.add_child(_panel)

	var margin := MarginContainer.new()
	margin.name = "PanelMargin"
	UiKit.set_margins(margin, UiTheme.SPACE_6, UiTheme.SPACE_5,
		UiTheme.SPACE_6, UiTheme.SPACE_5)
	_panel.add_child(margin)

	var inner := VBoxContainer.new()
	inner.name = "Inner"
	inner.add_theme_constant_override("separation", UiTheme.SPACE_2)
	margin.add_child(inner)

	_fit_root = CenterContainer.new()
	_fit_root.name = "FitRoot"
	inner.add_child(_fit_root)

	_menu_box = VBoxContainer.new()
	_menu_box.name = "Menu"
	_menu_box.alignment = BoxContainer.ALIGNMENT_CENTER
	_menu_box.add_theme_constant_override("separation", UiTheme.SPACE_2)
	_fit_root.add_child(_menu_box)


func _update_layout() -> void:
	if not is_instance_valid(_menu_box):
		return
	var vp := get_viewport()
	if vp == null:
		return
	var vs: Vector2 = vp.get_visible_rect().size
	# На узком окне панель не должна съесть весь мир: минимум треть экрана
	# оставляем под фон.
	var want: float = clampf(vs.x * 0.3, 260.0, PANEL_WIDTH)
	_menu_box.custom_minimum_size = Vector2(want, 0)
	var column := find_child("Column", true, false)
	if column is Control:
		(column as Control).custom_minimum_size = Vector2(want + UiTheme.SPACE_6 * 2.0, 0)


func _setup_title() -> void:
	var title := Label.new()
	title.name = "Title"
	title.theme_type_variation = &"MmTitle"
	title.text = Loc.t("ui.brand.title")
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_menu_box.add_child(title)

	var sub := Label.new()
	sub.name = "Subtitle"
	sub.theme_type_variation = &"MmSub"
	sub.text = Loc.t("ui.brand.subtitle")
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_menu_box.add_child(sub)

	_menu_box.add_child(_make_divider(UiTheme.SPACE_3))


func _make_divider(_spacer_before: int) -> NinePatchRect:
	# Именно NinePatchRect, а не TextureRect: текстура линейки 64 px
	# растягивалась STRETCH_SCALE до ширины панели (420 px, в 6.5 раза) и
	# орнамент размазывался в толстые жёлтые полосы. Девять-слой тянет только
	# середину, а ромб по краям остаётся ромбом.
	var rect := NinePatchRect.new()
	rect.name = "Divider"
	if ResourceLoader.exists(TEX_DIVIDER):
		rect.texture = load(TEX_DIVIDER)
	var m: Dictionary = UiKit.frame_margin_of(TEX_DIVIDER)
	rect.patch_margin_left = int(m.get("left", 24))
	rect.patch_margin_right = int(m.get("right", 24))
	rect.patch_margin_top = int(m.get("top", 7))
	rect.patch_margin_bottom = int(m.get("bottom", 7))
	rect.custom_minimum_size = Vector2(0, 16)
	rect.modulate = UiTheme.ACCENT_DIM
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return rect


func _setup_menu() -> void:
	var items := [
		["ui.menu.new_game", _on_new_game],
		["ui.menu.load_game", _on_load_game],
		["ui.menu.mods", _on_mods],
		["ui.menu.network", _on_network],
		["ui.menu.about", _on_about],
		["ui.menu.map_editor", _on_map_editor],
		["ui.menu.settings", _on_settings],
		["ui.menu.quit", _on_quit_pressed],
	]
	for i in range(items.size()):
		var key := str(items[i][0])
		var b := Button.new()
		# Имя узла НЕ содержит ключ перевода: Godot санитизирует точки, и
		# `ui.menu.new_game` превращается в `ui_menu_new_game` — искать по нему
		# потом невозможно. Ключ лежит в метаданных, имя стабильное.
		b.name = "Menu%d" % i
		b.set_meta("loc_key", key)
		b.theme_type_variation = &"MmMenuBtn"
		b.text = Loc.t(key)
		b.custom_minimum_size = Vector2(300, 44)
		b.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		b.pressed.connect(items[i][1])
		_menu_box.add_child(b)
		_menu_buttons.append(b)
	UiKit.wire_grid_focus(_menu_buttons, 1)
	# Нижняя линейка — зеркало верхней (линия + ромбы по краям).
	_menu_box.add_child(_make_divider(UiTheme.SPACE_3))


## Кнопка главного меню по ключу перевода. Именно так, а не по имени узла:
## см. замечание в `_setup_menu`.
func menu_button(key: String) -> Button:
	for b in _menu_buttons:
		if is_instance_valid(b) and str(b.get_meta("loc_key", "")) == key:
			return b
	return null


## Переключатель языка. Подписи всегда на своём языке («Русский» / «English»),
## так игрок узнаёт язык, не читая меню.
func _setup_language() -> void:
	_lang_row = HBoxContainer.new()
	_lang_row.name = "Language"
	_lang_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_lang_row.add_theme_constant_override("separation", UiTheme.SPACE_2)
	_menu_box.add_child(_lang_row)

	var caption := Label.new()
	caption.theme_type_variation = &"MmFooter"
	caption.text = Loc.t("ui.lang.title")
	caption.custom_minimum_size = Vector2(90, 0)
	caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_lang_row.add_child(caption)

	var langs: Array[Button] = []
	for code in Loc.available():
		var b := Button.new()
		b.name = "Lang_" + code
		b.text = Loc.t("ui.lang." + code)
		b.custom_minimum_size = Vector2(96, 32)
		b.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		b.pressed.connect(_on_language_pressed.bind(code))
		_lang_row.add_child(b)
		langs.append(b)
	UiKit.wire_grid_focus(langs, langs.size())

	# Язык должен быть фокусируем, но не первым: фокус остаётся на «Новая игра».
	if not langs.is_empty():
		var first_menu := _menu_buttons[0]
		langs[langs.size() - 1].focus_neighbor_bottom = first_menu.get_path()
		first_menu.focus_neighbor_bottom = langs[0].get_path()
		langs[0].focus_neighbor_top = first_menu.get_path()


func _setup_footer() -> void:
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, UiTheme.SPACE_5)
	_menu_box.add_child(spacer)
	var foot := Label.new()
	foot.name = "Footer"
	foot.theme_type_variation = &"MmFooter"
	foot.text = Loc.f("ui.footer.build", [GAME_VERSION, GAME_AUTHOR])
	foot.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_menu_box.add_child(foot)


# === Смена языка ===

func _on_language_pressed(code: String) -> void:
	SoundDB.play("ui.click")
	Loc.set_locale(code)
	Loc.save_locale()
	# Пересобираем подписи на месте: перезапуск ради смены языка неуместен.
	_relocalize()
	_refresh_language()


## Обновляет ТОЛЬКО подписи. Структуру не трогаем — иначе потерялся бы фокус
## и открытый оверлей.
func _relocalize() -> void:
	var sub := find_child("Subtitle", true, false)
	if sub is Label:
		(sub as Label).text = Loc.t("ui.brand.subtitle")
	for b in _menu_buttons:
		var key := str(b.get_meta("loc_key", ""))
		if key != "":
			b.text = Loc.t(key)
	var foot := find_child("Footer", true, false)
	if foot is Label:
		(foot as Label).text = Loc.f("ui.footer.build", [GAME_VERSION, GAME_AUTHOR])
	if is_instance_valid(_lang_row):
		for c in _lang_row.get_children():
			if c is Label:
				(c as Label).text = Loc.t("ui.lang.title")


## Подсвечивает активный язык. Состояние видно и по рамке, и по насыщенности —
## не только цветом.
##
## Активный язык НЕ помечается `disabled`: disabled-стиль приглушённый, и на
## игровом экране кнопка выглядела полупрозрачной («стеклянной»). Состояние
## держит variation `MmLangActive`.
func _refresh_language() -> void:
	if not is_instance_valid(_lang_row):
		return
	for c in _lang_row.get_children():
		if not (c is Button):
			continue
		var code := str(c.name).replace("Lang_", "")
		c.theme_type_variation = &"MmLangActive" if code == Loc.locale() \
			else &"MmLangBtn"


# === Навигация ===

func _set_menu_visible(on: bool) -> void:
	# Прячем ВСЮ панель, а не только список кнопок. Раньше скрывался `_menu_box`,
	# и слева оставалась пустая рамка: игрок видел «подложку, уехавшую влево и
	# сузившуюся до одной строки», пока открыт оверлей.
	if is_instance_valid(_panel):
		_panel.visible = on
	elif is_instance_valid(_menu_box):
		_menu_box.visible = on


func _open_overlay(title_key: String, build_body: Callable) -> void:
	_quit_confirm = false
	_set_menu_visible(false)
	if is_instance_valid(_overlay):
		_overlay.visible = true
		_overlay_title.text = Loc.t(title_key)
	UiKit.clear(_overlay_body)
	build_body.call(_overlay_body)
	var first := _first_button(_overlay_body)
	if first != null:
		first.grab_focus()


func _close_overlay() -> void:
	if is_instance_valid(_overlay):
		_overlay.visible = false
	_set_menu_visible(true)
	if not _menu_buttons.is_empty():
		_menu_buttons[0].grab_focus()


func _first_button(node: Node) -> Button:
	if node is Button:
		return node
	for c in node.get_children():
		var b := _first_button(c)
		if b != null:
			return b
	return null


func _unhandled_input(event: InputEvent) -> void:
	if UiKit.esc_pressed(event):
		if is_instance_valid(_overlay) and _overlay.visible:
			get_viewport().set_input_as_handled()
			_close_overlay()
			return
		if not _menu_buttons.is_empty():
			_menu_buttons[0].grab_focus()


# === Действия ===

func _on_new_game() -> void:
	SoundDB.play("ui.click")
	get_tree().change_scene_to_file(CHAR_SELECT_PATH)


func _on_load_game() -> void:
	SoundDB.play("ui.click")
	_open_overlay("ui.menu.load_game", _build_load_body)


func _on_mods() -> void:
	SoundDB.play("ui.click")
	if _mods_panel != null and is_instance_valid(_mods_panel):
		return
	_mods_panel = ModsPanel.new()
	_mods_panel.name = "ModsPanel"
	_mods_panel.closed.connect(_on_mods_closed)
	add_child(_mods_panel)


func _on_mods_closed() -> void:
	# The panel frees itself (queue_free inside close), so we only forget the
	# reference: a second free() on an already freed node would be an error.
	_mods_panel = null


func _on_network() -> void:
	SoundDB.play("ui.click")
	_open_overlay("ui.menu.network", _build_network_body)


func _on_about() -> void:
	SoundDB.play("ui.click")
	_open_overlay("ui.menu.about", _build_about_body)


## Редактор карт — обычная сцена, доступная всем. Возврат по F9/«Назад» —
## в главное меню (Game.editor_return_scene).
func _on_map_editor() -> void:
	SoundDB.play("ui.click")
	Game.editor_return_scene = "res://scenes/main_menu.tscn"
	get_tree().change_scene_to_file("res://scenes/map_editor.tscn")


## Настройки — отдельное окно поверх меню, а не экран в списке: у него свой
## `CanvasLayer` со своим затемнением и своя панель. Так его можно переиспользовать
## из игры (Esc -> Настройки) без копирования вёрстки.
func _on_settings() -> void:
	SoundDB.play("ui.click")
	if _settings != null and is_instance_valid(_settings):
		return
	# Главное меню прячется целиком, а не закрывается затемнением: игрок просил
	# «без прозрачности», и полупрозрачная подложка — это ровно она. За панелью
	# настроек остаётся живой мир, а не текст меню.
	_ui_root.visible = false
	_settings = SettingsPanel.new()
	_settings.name = "SettingsPanel"
	_settings.setup()
	_settings.closed.connect(_on_settings_closed)
	add_child(_settings)


func _on_settings_closed() -> void:
	if _settings != null and is_instance_valid(_settings):
		_settings.queue_free()
	_settings = null
	if is_instance_valid(_ui_root):
		_ui_root.visible = true
	# Esc перехватывается самой панелью настроек в её `_input`, поэтому сюда
	# управление долетает только после её закрытия.
	if not _menu_buttons.is_empty():
		_menu_buttons[0].grab_focus()


func _on_quit_pressed() -> void:
	SoundDB.play("ui.click")
	_quit_confirm = true
	_open_overlay("ui.quit.title", _build_quit_body)


func _build_back_button(parent: VBoxContainer) -> Button:
	parent.add_child(_make_divider(UiTheme.SPACE_3))
	var b := Button.new()
	b.name = "Back"
	b.theme_type_variation = &"MmMenuBtn"
	b.text = Loc.t("ui.common.back")
	b.custom_minimum_size = Vector2(200, 38)
	b.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	b.pressed.connect(_close_overlay)
	parent.add_child(b)
	return b


func _make_body_label(parent: VBoxContainer, min_width: float) -> Label:
	var lab := Label.new()
	lab.theme_type_variation = &"MmBody"
	lab.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lab.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lab.custom_minimum_size = Vector2(min_width, 0)
	parent.add_child(lab)
	return lab


# --- Загрузить игру (6 слотов) ---

func _build_load_body(parent: VBoxContainer) -> void:
	var slots: Array = SaveSystem.list_slots()
	var player_slots: Array = []
	for s in slots:
		if str(s.get("slot", "")).begins_with("slot_"):
			player_slots.append(s)
	player_slots.sort_custom(func(a, b): return str(a.get("slot")) < str(b.get("slot")))
	if player_slots.is_empty():
		var empty := _make_body_label(parent, 420)
		empty.text = Loc.t("ui.load.none")
		_build_back_button(parent)
		return
	var btns: Array[Button] = []
	for s in player_slots:
		var slot := str(s.get("slot", ""))
		var exists := bool(s.get("exists", false))
		var meta: Dictionary = s.get("meta", {})
		var n := int(slot.get_slice("_", 1)) + 1
		var b := Button.new()
		b.name = "Slot_" + slot
		b.theme_type_variation = &"MmSlotBtn"
		b.custom_minimum_size = Vector2(360, 40)
		b.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		b.clip_text = true
		b.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		if exists:
			b.text = Loc.f("ui.load.slot_filled", [
				n, str(meta.get("hero_name", Loc.t("ui.common.hero"))),
				int(meta.get("day", 0))])
			b.pressed.connect(_on_load_slot.bind(slot))
		else:
			b.text = Loc.f("ui.load.slot_empty", [n])
			b.disabled = true
		parent.add_child(b)
		btns.append(b)
	var back := _build_back_button(parent)
	btns.append(back)
	UiKit.wire_grid_focus(btns, 1)


func _on_load_slot(slot: String) -> void:
	var res := SaveSystem.load_slot(slot)
	var err := str(res.get("error", ""))
	if err == "version":
		_flash_overlay_status(Loc.t("ui.load.err_newer"))
		return
	if err == "corrupt":
		_flash_overlay_status(Loc.t("ui.load.err_corrupt"))
		return
	if res.is_empty():
		_flash_overlay_status(Loc.t("ui.load.err_empty"))
		return
	var data: Dictionary = res.get("data", {})
	# slot — чтобы карта пришла из папки сохранения (файлы `.alm` + sidecar-ы),
	# а не перегенерировалась по сиду: перегенерация другим кодом давала другой мир.
	SaveSystem.apply_payload(data, null, slot)
	_restore_world(data.get("world", {}))
	SoundDB.play("ui.confirm")
	get_tree().change_scene_to_file(GAME_PATH)


func _restore_world(world_data: Variant) -> void:
	if not (world_data is Dictionary) or (world_data as Dictionary).is_empty():
		return
	var ws_script: GDScript = load("res://scripts/world/world_state.gd")
	var restored = ws_script.from_json_text(JsonSafe.dump(world_data))
	if restored == null:
		return
	var bus = get_tree().root.get_node_or_null("WorldBus")
	if bus == null:
		return
	bus.state = restored
	if "sim" in bus and bus.sim != null and "state" in bus.sim:
		bus.sim.state = restored


func _flash_overlay_status(msg: String) -> void:
	var lab := _overlay_body.get_node_or_null("Status")
	if lab == null:
		lab = Label.new()
		lab.name = "Status"
		lab.theme_type_variation = &"MmFooter"
		lab.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_overlay_body.add_child(lab)
	(lab as Label).text = msg


# --- mods / network / about / quit ---

func _build_network_body(parent: VBoxContainer) -> void:
	# `_make_body_label` уже добавляет метку в parent. Второй add_child роняет
	# узел с «already has a parent» — тот же класс, что был в настройках.
	var lab := _make_body_label(parent, 420)
	lab.text = Loc.t("ui.network.body")
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", UiTheme.SPACE_3)
	parent.add_child(row)
	for key in ["ui.network.host", "ui.network.find"]:
		var b := Button.new()
		b.theme_type_variation = &"MmMenuBtn"
		b.text = Loc.t(key)
		b.custom_minimum_size = Vector2(180, 38)
		b.disabled = true
		row.add_child(b)
	_build_back_button(parent)


func _build_about_body(parent: VBoxContainer) -> void:
	var lab := _make_body_label(parent, 460)
	lab.text = "%s\n\n%s" % [Loc.t(GAME_LORE_KEY),
		Loc.f("ui.about.credits", [GAME_VERSION, GAME_AUTHOR])]
	_build_back_button(parent)


func _build_quit_body(parent: VBoxContainer) -> void:
	var lab := _make_body_label(parent, 420)
	lab.text = Loc.t("ui.quit.confirm")
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", UiTheme.SPACE_4)
	parent.add_child(row)
	var yes := Button.new()
	yes.name = "Yes"
	yes.theme_type_variation = &"MmMenuBtn"
	yes.text = Loc.t("ui.common.yes")
	yes.custom_minimum_size = Vector2(130, 40)
	yes.pressed.connect(_on_quit_yes)
	row.add_child(yes)
	var no := Button.new()
	no.name = "No"
	no.theme_type_variation = &"MmMenuBtn"
	no.text = Loc.t("ui.common.no")
	no.custom_minimum_size = Vector2(130, 40)
	no.pressed.connect(_close_overlay)
	row.add_child(no)
	yes.grab_focus()


func _on_quit_yes() -> void:
	get_tree().quit()


# === Оверлей ===

func _setup_overlay() -> void:
	_overlay = Control.new()
	_overlay.name = "Overlay"
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.visible = false
	# Оверлей — потомок `_ui_root`, а НЕ самого CanvasLayer. Тема живёт на
	# `_ui_root`, а `CanvasLayer` распространение темы не переносит: оверлей в
	# слое получал дефолтные кнопки движка с alpha 0.6, то есть прозрачные.
	_ui_root.add_child(_overlay)

	# Затемнения НЕТ — то же правило, что у главного меню: игрок просил «без
	# прозрачности, по краям видно игру». Полноэкранная подложка давала
	# «область затемнения слева» от централизованной панели.
	var inset := MarginContainer.new()
	inset.name = "Inset"
	inset.set_anchors_preset(Control.PRESET_FULL_RECT)
	UiKit.set_margins(inset, UiTheme.SCREEN_INSET, UiTheme.SCREEN_INSET,
		UiTheme.SCREEN_INSET, UiTheme.SCREEN_INSET)
	_overlay.add_child(inset)

	var center := CenterContainer.new()
	center.name = "Center"
	inset.add_child(center)

	var panel := PanelContainer.new()
	panel.name = "Panel"
	panel.theme_type_variation = &"MmOverlay"
	panel.custom_minimum_size = Vector2(560, 0)
	center.add_child(panel)

	var margin := MarginContainer.new()
	UiKit.set_margins(margin, UiTheme.SPACE_6, UiTheme.SPACE_5,
		UiTheme.SPACE_6, UiTheme.SPACE_5)
	panel.add_child(margin)

	var box := VBoxContainer.new()
	box.name = "Box"
	box.add_theme_constant_override("separation", UiTheme.SPACE_3)
	margin.add_child(box)

	_overlay_title = Label.new()
	_overlay_title.name = "OverlayTitle"
	_overlay_title.theme_type_variation = &"MmOverlayTitle"
	_overlay_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_overlay_title)
	box.add_child(_make_divider(UiTheme.SPACE_2))

	_overlay_body = VBoxContainer.new()
	_overlay_body.name = "OverlayBody"
	_overlay_body.add_theme_constant_override("separation", UiTheme.SPACE_2)
	_overlay_body.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_child(_overlay_body)