class_name SettingsPanel
extends CanvasLayer
## Окно настроек: графика, звук, переназначение клавиш.
##
## Панель создаётся кодом, как и остальные интерьеры. Стили — из `UiTheme`,
## вёрстка — контейнеры.
##
## ## Что здесь настоящее
##
## Сделано по-настоящему ровно то, что работает:
##
##  * **Звук** — Master и раздельные шины Music/SFX/Voice/Ambient;
##    `SoundDB.ensure_buses()` создаёт их при старте, панель меняет громкости
##    на лету (`Settings.apply_audio`).
##  * **Графика** — полный экран, vsync и масштаб интерфейса реально
##    применяются (`DisplayServer`, `content_scale_factor`).
##  * **Клавиши** — 6 действий из `project.godot [input]`; сохранённые клавиши
##    применяет `Settings.apply_all()` при старте (main_menu), сброс возвращает
##    раскладку project.godot.
##
## Пока не сделано: «разрешение/сглаживание» — Forward+ умеет, но менять их
## во время игры — отдельная задача.
##
## Список разделов в `_build_tabs`; активный — в `_select_tab`.

signal closed

const REBIND_WAIT_NONE := 0
const REBIND_WAIT_KEY := 1

var _root: Control
var _panel: PanelContainer
var _title: Label
var _tabs: HBoxContainer
var _body: VBoxContainer
var _status: Label
var _hint: Label
var _tab_buttons: Array[Button] = []
var _tab_index := 0
var _rebind_wait := REBIND_WAIT_NONE
var _rebind_action := ""
var _rebind_rows: Dictionary = {}
var _previous_focus: Control


func setup() -> void:
	layer = 30


func _ready() -> void:
	_previous_focus = UiKit.save_focus(self)
	_build()
	var first := _tab_buttons[0] if not _tab_buttons.is_empty() else null
	if first != null:
		first.call_deferred("grab_focus")


# === Сборка ===

func _build() -> void:
	_root = Control.new()
	_root.name = "Root"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_root)

	# Затемнения нет — то же правило, что в главном меню: панель непрозрачная и
	# вписана с отступом, полноэкранная подложка давала «область затемнения».
	var inset := MarginContainer.new()
	inset.name = "Inset"
	inset.set_anchors_preset(Control.PRESET_FULL_RECT)
	UiKit.set_margins(inset, UiTheme.SCREEN_INSET, UiTheme.SCREEN_INSET,
		UiTheme.SCREEN_INSET, UiTheme.SCREEN_INSET)
	_root.add_child(inset)

	var center := CenterContainer.new()
	inset.add_child(center)

	_panel = PanelContainer.new()
	_panel.name = "Panel"
	_panel.theme_type_variation = &"SetPanel"
	_panel.custom_minimum_size = Vector2(560, 0)
	center.add_child(_panel)

	var margin := MarginContainer.new()
	UiKit.set_margins(margin, UiTheme.SPACE_6, UiTheme.SPACE_5,
		UiTheme.SPACE_6, UiTheme.SPACE_5)
	_panel.add_child(margin)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", UiTheme.SPACE_3)
	margin.add_child(column)

	_title = Label.new()
	_title.name = "Title"
	_title.theme_type_variation = &"SetTitle"
	_title.text = Loc.t("ui.settings.title")
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(_title)

	_tabs = HBoxContainer.new()
	_tabs.name = "Tabs"
	_tabs.alignment = BoxContainer.ALIGNMENT_CENTER
	_tabs.add_theme_constant_override("separation", UiTheme.SPACE_2)
	column.add_child(_tabs)
	_build_tabs()

	column.add_child(_make_rule())

	_body = VBoxContainer.new()
	_body.name = "Body"
	_body.add_theme_constant_override("separation", UiTheme.SPACE_2)
	_body.custom_minimum_size = Vector2(480, 300)
	column.add_child(_body)

	_hint = Label.new()
	_hint.name = "Hint"
	_hint.theme_type_variation = &"SetHint"
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_hint)

	_status = Label.new()
	_status.name = "Status"
	_status.theme_type_variation = &"SetHint"
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(_status)

	var row := HBoxContainer.new()
	row.name = "Buttons"
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", UiTheme.SPACE_2)
	column.add_child(row)

	var reset := Button.new()
	reset.name = "ResetDefaults"
	reset.theme_type_variation = &"SetGhost"
	reset.text = Loc.t("ui.settings.reset")
	reset.custom_minimum_size = Vector2(180, 36)
	reset.pressed.connect(_on_reset)
	row.add_child(reset)

	var close_btn := Button.new()
	close_btn.name = "Close"
	close_btn.theme_type_variation = &"SetPrimary"
	close_btn.text = Loc.t("ui.common.close")
	close_btn.custom_minimum_size = Vector2(160, 36)
	# Имя НЕ `close`: локальная переменная затенила бы метод close() и
	# connect() получил бы Button вместо Callable.
	close_btn.pressed.connect(close)
	row.add_child(close_btn)

	_apply_theme()
	_select_tab(0)
	UiKit.wire_grid_focus(_tab_buttons, _tab_buttons.size())


func _build_tabs() -> void:
	var keys := ["ui.settings.tab_video", "ui.settings.tab_audio",
		"ui.settings.tab_magic", "ui.settings.tab_input"]
	for i in range(keys.size()):
		var b := Button.new()
		b.name = "Tab%d" % i
		b.theme_type_variation = &"SetTab"
		b.text = Loc.t(str(keys[i]))
		b.custom_minimum_size = Vector2(140, 34)
		b.pressed.connect(_select_tab.bind(i))
		_tabs.add_child(b)
		_tab_buttons.append(b)


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
	theme.set_stylebox("focus", "Button", UiKit.button_style(
		Color(0, 0, 0, 0), UiTheme.ACCENT,
		UiTheme.BORDER_FOCUS, UiTheme.RADIUS_PANEL, UiTheme.SPACE_2))

	# Без 9-slice: window_frame при растяжении давал толстые золотые полосы.
	UiKit.add_panel(theme, &"SetPanel",
		UiTheme.PANEL_BG, UiTheme.PANEL_EDGE, UiTheme.RADIUS_FRAME)
	UiTheme.add_display_label(theme, &"SetTitle", UiTheme.FONT_TITLE, UiTheme.ACCENT)
	UiKit.add_label(theme, &"SetHint", UiTheme.TEXT_MUTED, UiTheme.FONT_MICRO)
	UiKit.add_label(theme, &"SetRowLabel", UiTheme.TEXT, UiTheme.FONT_BODY)
	UiKit.add_label(theme, &"SetRowValue", UiTheme.ACCENT, UiTheme.FONT_BODY)
	UiKit.add_label(theme, &"SetStub", UiTheme.TEXT_OFF, UiTheme.FONT_MICRO)
	UiKit.add_button(theme, &"SetTab", UiTheme.PANEL_INNER, UiTheme.PANEL_EDGE.darkened(0.25),
		UiTheme.PANEL_INNER.lightened(0.12), UiTheme.ACCENT_DIM,
		UiTheme.RADIUS_SLOT, UiTheme.SPACE_2)
	UiKit.add_button(theme, &"SetTabActive", UiTheme.PANEL_INNER.lightened(0.16),
		UiTheme.ACCENT, UiTheme.PANEL_INNER.lightened(0.16), UiTheme.ACCENT,
		UiTheme.RADIUS_SLOT, UiTheme.SPACE_2)
	UiKit.add_button(theme, &"SetPrimary", UiTheme.PANEL_BG.lightened(0.06), UiTheme.PANEL_EDGE,
		UiTheme.PANEL_BG.lightened(0.16), UiTheme.ACCENT_DIM,
		UiTheme.RADIUS_PANEL, UiTheme.SPACE_3)
	UiKit.add_button(theme, &"SetGhost", UiTheme.BG_DEEP, UiTheme.PANEL_EDGE.darkened(0.25),
		UiTheme.PANEL_INNER, UiTheme.PANEL_EDGE,
		UiTheme.RADIUS_PANEL, UiTheme.SPACE_2)
	UiKit.add_button(theme, &"SetValueBtn", UiTheme.PANEL_INNER, UiTheme.PANEL_EDGE,
		UiTheme.PANEL_INNER.lightened(0.14), UiTheme.ACCENT,
		UiTheme.RADIUS_SLOT, UiTheme.SPACE_2)
	_root.theme = theme


func _make_rule() -> NinePatchRect:
	# NinePatchRect, а не TextureRect: линейка 64 px при STRETCH_SCALE
	# растягивалась до 480 px, и орнамент превращался в толстые жёлтые полосы.
	var rect := NinePatchRect.new()
	rect.name = "Rule"
	if ResourceLoader.exists(MainMenu.TEX_DIVIDER):
		rect.texture = load(MainMenu.TEX_DIVIDER)
	var m: Dictionary = UiKit.frame_margin_of(MainMenu.TEX_DIVIDER)
	rect.patch_margin_left = int(m.get("left", 24))
	rect.patch_margin_right = int(m.get("right", 24))
	rect.patch_margin_top = int(m.get("top", 7))
	rect.patch_margin_bottom = int(m.get("bottom", 7))
	rect.custom_minimum_size = Vector2(0, 14)
	rect.modulate = UiTheme.ACCENT_DIM
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return rect


# === Разделы ===

func _select_tab(index: int) -> void:
	_tab_index = clampi(index, 0, maxi(_tab_buttons.size() - 1, 0))
	for i in range(_tab_buttons.size()):
		var active := i == _tab_index
		_tab_buttons[i].theme_type_variation = &"SetTabActive" if active else &"SetTab"
		_tab_buttons[i].disabled = active
	UiKit.clear(_body)
	_rebind_wait = REBIND_WAIT_NONE
	_rebind_action = ""
	_rebind_rows.clear()
	match _tab_index:
		0:
			_build_video_tab()
		1:
			_build_audio_tab()
		2:
			_build_magic_tab()
		_:
			_build_input_tab()
	_hint.text = Loc.t("ui.settings.hint_%d" % _tab_index)
	_status.text = ""


## Строка настройки: подпись слева, значение и кнопка справа.
func _make_row(label_key: String, value_text: String, value_button: Button,
		btn_min := Vector2(150, 30)) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", UiTheme.SPACE_3)
	var lab := Label.new()
	lab.theme_type_variation = &"SetRowLabel"
	lab.text = Loc.t(label_key)
	lab.custom_minimum_size = Vector2(230, 0)
	row.add_child(lab)
	if value_button != null:
		value_button.custom_minimum_size = btn_min
		value_button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		row.add_child(value_button)
	else:
		var val := Label.new()
		val.theme_type_variation = &"SetRowValue"
		val.text = value_text
		row.add_child(val)
	_body.add_child(row)
	return row


## Переключатель вкл/выкл — кнопка с двумя состояниями, а не чекбокс: тот
## отрисовался бы системным стилем и выбился бы из панели.
func _make_toggle(label_key: String, current: bool, on_pressed: Callable) -> Button:
	var b := Button.new()
	b.theme_type_variation = &"SetValueBtn"
	b.text = _on_off(current)
	b.pressed.connect(on_pressed)
	return b


func _on_off(v: bool) -> String:
	return Loc.t("ui.settings.on") if v else Loc.t("ui.settings.off")


func _build_video_tab() -> void:
	var root := get_tree().root

	var fs_btn := _make_toggle("ui.settings.fullscreen", Settings.fullscreen(),
		_on_fullscreen)
	_make_row("ui.settings.fullscreen", "", fs_btn)

	var vs_btn := _make_toggle("ui.settings.vsync", Settings.vsync(), _on_vsync)
	_make_row("ui.settings.vsync", "", vs_btn)

	# Масштаб интерфейса — самое полезное из трёх: панели собираются под 1280x800.
	var scale_btn := Button.new()
	scale_btn.name = "UiScale"
	scale_btn.theme_type_variation = &"SetValueBtn"
	# `_scale_row` сам добавляет строку в тело — второй add_child уронил бы
	# узел с ошибкой «already has a parent».
	_scale_row(scale_btn)

	var stub := Label.new()
	stub.theme_type_variation = &"SetStub"
	stub.text = Loc.t("ui.settings.stub_video")
	stub.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	stub.custom_minimum_size = Vector2(480, 0)
	_body.add_child(stub)


func _scale_row(btn: Button) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", UiTheme.SPACE_3)
	var lab := Label.new()
	lab.theme_type_variation = &"SetRowLabel"
	lab.text = Loc.t("ui.settings.ui_scale")
	lab.custom_minimum_size = Vector2(230, 0)
	row.add_child(lab)
	var minus := Button.new()
	minus.name = "ScaleDown"
	minus.theme_type_variation = &"SetValueBtn"
	minus.text = "-"
	minus.custom_minimum_size = Vector2(40, 30)
	minus.pressed.connect(_on_ui_scale_step.bind(-0.05))
	row.add_child(minus)
	btn.text = "%d%%" % int(round(Settings.ui_scale() * 100.0))
	row.add_child(btn)
	var plus := Button.new()
	plus.name = "ScaleUp"
	plus.theme_type_variation = &"SetValueBtn"
	plus.text = "+"
	plus.custom_minimum_size = Vector2(40, 30)
	plus.pressed.connect(_on_ui_scale_step.bind(0.05))
	row.add_child(plus)
	_body.add_child(row)
	return row


## Раздел «Магия»: авто-волшебство мага.
##
## Уровень и цель — единственное место, где это меняется (раньше был скрытый
## Alt+ПКМ по книге, и игрок его не находил). Настройки живут в статиках Game и
## НЕ сохраняются в сейв: после загрузки — «Базовое» и «Я и моя группа».
func _build_magic_tab() -> void:
	_choice_row("ui.settings.auto_magic", [
		["base", "ui.settings.auto_level_base"],
		["medium", "ui.settings.auto_level_medium"],
		["max", "ui.settings.auto_level_max"],
	], Game.auto_buff_tier, _on_auto_tier)
	_choice_row("ui.settings.auto_target", [
		["self", "ui.settings.auto_target_self"],
		["party", "ui.settings.auto_target_party"],
		["party_neutral", "ui.settings.auto_target_neutral"],
	], Game.auto_targets, _on_auto_target)
	var stub := Label.new()
	stub.theme_type_variation = &"SetStub"
	stub.text = Loc.t("ui.settings.stub_magic")
	stub.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	stub.custom_minimum_size = Vector2(480, 0)
	_body.add_child(stub)


## Строка выбора из нескольких вариантов: подпись слева, кнопки справа.
## Активный вариант подсвечен и выключен (как вкладки), фокус ходит стрелками.
func _choice_row(label_key: String, options: Array, current: String,
		on_pick: Callable) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", UiTheme.SPACE_2)
	var lab := Label.new()
	lab.theme_type_variation = &"SetRowLabel"
	lab.text = Loc.t(label_key)
	lab.custom_minimum_size = Vector2(200, 0)
	lab.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	row.add_child(lab)
	var buttons: Array[Button] = []
	for opt in options:
		var pair: Array = opt
		var value := str(pair[0])
		var b := Button.new()
		b.name = "Opt_%s" % value
		b.text = Loc.t(str(pair[1]))
		b.custom_minimum_size = Vector2(150, 30)
		var active := value == current
		b.theme_type_variation = &"SetTabActive" if active else &"SetValueBtn"
		b.disabled = active
		b.pressed.connect(func() -> void:
			on_pick.call(value))
		row.add_child(b)
		buttons.append(b)
	_body.add_child(row)
	UiKit.wire_grid_focus(buttons, buttons.size())
	return row


func _on_auto_tier(value: String) -> void:
	Game.auto_buff_tier = value
	_select_tab(_tab_index)


func _on_auto_target(value: String) -> void:
	Game.auto_targets = value
	_select_tab(_tab_index)


func _build_audio_tab() -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", UiTheme.SPACE_3)
	var lab := Label.new()
	lab.theme_type_variation = &"SetRowLabel"
	lab.text = Loc.t("ui.settings.master_volume")
	lab.custom_minimum_size = Vector2(230, 0)
	row.add_child(lab)
	var minus := Button.new()
	minus.name = "VolDown"
	minus.theme_type_variation = &"SetValueBtn"
	minus.text = "-"
	minus.custom_minimum_size = Vector2(40, 30)
	minus.pressed.connect(_on_volume_step.bind(-0.1))
	row.add_child(minus)
	var val := Label.new()
	val.name = "MasterVolume"
	val.theme_type_variation = &"SetRowValue"
	val.text = "%d%%" % int(round(Settings.master_volume() * 100.0))
	val.custom_minimum_size = Vector2(80, 0)
	val.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	row.add_child(val)
	var plus := Button.new()
	plus.name = "VolUp"
	plus.theme_type_variation = &"SetValueBtn"
	plus.text = "+"
	plus.custom_minimum_size = Vector2(40, 30)
	plus.pressed.connect(_on_volume_step.bind(0.1))
	row.add_child(plus)
	_body.add_child(row)

	var mute := _make_toggle("ui.settings.mute", Settings.muted(), _on_mute)
	_make_row("ui.settings.mute", "", mute)

	_body.add_child(_volume_row("ui.settings.music_volume", "music", Settings.music_volume()))
	_body.add_child(_volume_row("ui.settings.sfx_volume", "sfx", Settings.sfx_volume()))
	_body.add_child(_volume_row("ui.settings.voice_volume", "voice", Settings.voice_volume()))


## Строка ползунка для отдельной шины: `kind` = music|sfx|voice.
func _volume_row(label_key: String, kind: String, value: float) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", UiTheme.SPACE_3)
	var lab := Label.new()
	lab.theme_type_variation = &"SetRowLabel"
	lab.text = Loc.t(label_key)
	lab.custom_minimum_size = Vector2(230, 0)
	row.add_child(lab)
	var minus := Button.new()
	minus.theme_type_variation = &"SetValueBtn"
	minus.text = "-"
	minus.custom_minimum_size = Vector2(40, 30)
	minus.pressed.connect(_on_bus_volume_step.bind(kind, -0.1))
	row.add_child(minus)
	var val := Label.new()
	val.name = "Vol_" + kind
	val.theme_type_variation = &"SetRowValue"
	val.text = "%d%%" % int(round(value * 100.0))
	val.custom_minimum_size = Vector2(80, 0)
	val.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	row.add_child(val)
	var plus := Button.new()
	plus.theme_type_variation = &"SetValueBtn"
	plus.text = "+"
	plus.custom_minimum_size = Vector2(40, 30)
	plus.pressed.connect(_on_bus_volume_step.bind(kind, 0.1))
	row.add_child(plus)
	return row


func _build_input_tab() -> void:
	for entry in Settings.REBINDABLE:
		var action := str(entry[0])
		var label_key := str(entry[1])
		var btn := Button.new()
		btn.name = "Key_" + action
		btn.theme_type_variation = &"SetValueBtn"
		btn.custom_minimum_size = Vector2(150, 30)
		btn.pressed.connect(_start_rebind.bind(action))
		_rebind_rows[action] = btn
		_make_row(label_key, "", btn)
		_refresh_key_text(action)


## Человеческое имя клавиши вместо кода: «Esc», «F1», «Пробел».
static func key_label(keycode: int) -> String:
	if keycode == 0:
		return Loc.t("ui.settings.key_default")
	return OS.get_keycode_string(keycode)


func _refresh_key_text(action: String) -> void:
	var btn = _rebind_rows.get(action)
	if btn is Button:
		(btn as Button).text = key_label(Settings.key_for(action))


# === Действия ===

func _on_fullscreen() -> void:
	Settings.set_fullscreen(not Settings.fullscreen())
	Settings.save()
	Settings.apply_video(get_tree().root)
	_rebuild_current()


func _on_vsync() -> void:
	Settings.set_vsync(not Settings.vsync())
	Settings.save()
	Settings.apply_video(get_tree().root)
	_rebuild_current()


func _on_mute() -> void:
	Settings.set_muted(not Settings.muted())
	Settings.save()
	Settings.apply_audio()
	_rebuild_current()


func _on_volume_step(delta: float) -> void:
	Settings.set_master_volume(Settings.master_volume() + delta)
	Settings.save()
	Settings.apply_audio()
	var val := _body.find_child("MasterVolume", true, false)
	if val is Label:
		(val as Label).text = "%d%%" % int(round(Settings.master_volume() * 100.0))


## Громкость отдельной шины (music/sfx/voice). UI и Ambient идут следом:
## UI — от эффектов, Ambient — от музыки (SoundDB.apply_volumes).
func _on_bus_volume_step(kind: String, delta: float) -> void:
	var value := 0.0
	if kind == "music":
		Settings.set_music_volume(Settings.music_volume() + delta)
		value = Settings.music_volume()
	elif kind == "sfx":
		Settings.set_sfx_volume(Settings.sfx_volume() + delta)
		value = Settings.sfx_volume()
	else:
		Settings.set_voice_volume(Settings.voice_volume() + delta)
		value = Settings.voice_volume()
	Settings.save()
	SoundDB.ensure_buses()
	var val := _body.find_child("Vol_" + kind, true, false)
	if val is Label:
		(val as Label).text = "%d%%" % int(round(value * 100.0))


func _on_ui_scale_step(delta: float) -> void:
	Settings.set_ui_scale(Settings.ui_scale() + delta)
	Settings.save()
	Settings.apply_video(get_tree().root)
	_rebuild_current()


func _rebuild_current() -> void:
	_select_tab(_tab_index)


func _start_rebind(action: String) -> void:
	_rebind_wait = REBIND_WAIT_KEY
	_rebind_action = action
	_status.text = Loc.t("ui.settings.press_key")
	var btn = _rebind_rows.get(action)
	if btn is Button:
		(btn as Button).text = Loc.t("ui.settings.listening")


func _on_unhandled_input(event: InputEvent) -> void:
	if _rebind_wait != REBIND_WAIT_KEY:
		return
	if not (event is InputEventKey):
		return
	var key := event as InputEventKey
	if not key.pressed:
		return
	get_viewport().set_input_as_handled()
	_rebind_wait = REBIND_WAIT_NONE
	# Esc во время ожидания — отмена, а не назначение Esc на действие.
	if key.keycode == KEY_ESCAPE:
		_status.text = ""
		_refresh_key_text(_rebind_action)
		_rebind_action = ""
		return
	var clash := Settings.conflict_for(key.keycode, _rebind_action)
	if clash != "":
		_status.text = Loc.t("ui.settings.conflict") % Loc.t(
			_clash_label(clash))
		_refresh_key_text(_rebind_action)
		_rebind_action = ""
		return
	Settings.set_key_for(_rebind_action, key.keycode)
	Settings.save()
	_apply_key(_rebind_action, key.keycode)
	_status.text = Loc.t("ui.settings.key_set") % key_label(key.keycode)
	_refresh_key_text(_rebind_action)
	_rebind_action = ""


func _clash_label(action: String) -> String:
	for entry in Settings.REBINDABLE:
		if str(entry[0]) == action:
			return str(entry[1])
	return action


## Замена события в InputMap делается в рантайме, а не правкой `project.godot`:
## иначе пришлось бы трогать input map (approval gate) и забивать игроку
## раскладку в репозитории.
func _apply_key(action: String, keycode: int) -> void:
	if not InputMap.has_action(action):
		return
	for ev in InputMap.action_get_events(action):
		if ev is InputEventKey:
			InputMap.action_erase_event(action, ev)
	var e := InputEventKey.new()
	e.physical_keycode = keycode
	InputMap.action_add_event(action, e)


func _on_reset() -> void:
	Settings.reset_to_defaults()
	# Drop session rebinds too: reset must restore project.godot defaults, not
	# only delete settings.cfg.
	InputMap.load_from_project_settings()
	Settings.apply_input()
	_rebuild_current()
	_status.text = Loc.t("ui.settings.reset_done")


func _input(event: InputEvent) -> void:
	if UiKit.esc_pressed(event):
		close()
		get_viewport().set_input_as_handled()


func close() -> void:
	UiKit.restore_focus(_previous_focus)
	closed.emit()
	queue_free()