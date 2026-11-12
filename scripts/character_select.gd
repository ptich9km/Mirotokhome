extends Control
class_name CharacterSelect
## Старт игры: раса + 4 карточки (класс × пол), имя героя.
## Портреты: assets/hero_portraits/{race}_{gender}_{war|mage}.png
## У людей два стиля (human / human2) — toggle на все 4 карточки.
## Старые id mfighter/ffighter/mmage/fmage мигрируются в save_system.

const PORTRAIT_DIR := "res://assets/hero_portraits/"

## Races available on the screen — data (`races` in assets/config/content_rules.json).
## A mod can add a race: its portrait is looked up by the convention
## `<race>_<gender>_<role>`, and the `two_styles` flag enables the second look
## (human/human2 for humans).
static func races() -> Array:
	return ContentRules.list("races")

## Статы пресетов — прежние 4 карточки (пол × класс), без привязки к Аллодовским id.
const PRESETS := [
	{
		"role": "warrior", "gender": "male", "title": "ui.char.class.warrior",
		"desc": "ui.char.desc.warrior_m",
		"stats": {"body": 12, "agility": 11, "mind": 9, "spirit": 8,
			"blade": 30, "bludgeon": 15, "pike": 10, "fire": 5, "water": 5, "air": 5, "earth": 5, "astral": 5,
			"weapon": "sword", "shield": true, "armor": "heavy"},
	},
	{
		"role": "warrior", "gender": "female", "title": "ui.char.class.warrior",
		"desc": "ui.char.desc.warrior_f",
		"stats": {"body": 10, "agility": 13, "mind": 9, "spirit": 8,
			"blade": 30, "bludgeon": 15, "pike": 10, "fire": 5, "water": 5, "air": 5, "earth": 5, "astral": 5,
			"weapon": "sword", "shield": false, "armor": "heavy"},
	},
	{
		"role": "mage", "gender": "male", "title": "ui.char.class.mage",
		"desc": "ui.char.desc.mage_m",
		"stats": {"body": 8, "agility": 9, "mind": 13, "spirit": 12,
			"blade": 5, "bludgeon": 5, "pike": 5,
			"fire": 5, "water": 5, "air": 5, "earth": 5, "astral": 5,
			"weapon": "staff", "shield": false, "armor": "heavy"},
	},
	{
		"role": "mage", "gender": "female", "title": "ui.char.class.mage",
		"desc": "ui.char.desc.mage_f",
		"stats": {"body": 7, "agility": 10, "mind": 12, "spirit": 13,
			"blade": 5, "bludgeon": 5, "pike": 5,
			"fire": 5, "water": 5, "air": 5, "earth": 5, "astral": 5,
			"weapon": "staff", "shield": false, "armor": "heavy"},
	},
]

const MAIN_MENU_SCENE := "res://scenes/main_menu.tscn"

## Легаси id из старых сейвов → новые портреты рас.
const LEGACY_ID := {
	"mfighter": "human_m_war",
	"ffighter": "human_f_war",
	"mmage": "human_m_mage",
	"fmage": "human_f_mage",
}

var _race := "human"
var _style := 1  # 1 | 2 — только у людей
var _race_buttons: Array = []
var _style_btn: Button = null
var CHARACTERS: Array = []  # пересобирается при смене расы/стиля

const CARD_SIZE := Vector2(210, 330)
const CARD_GAP := 24.0
## Greek names live in data, not in code: a pair ru/en per name (see the file's
## own comment for why a pair and not two lists).
const NAMES_PATH := "res://assets/config/hero_names.json"
static var _names_cache: Dictionary = {}

## Пул имён для пола: male / female. Пустой список, если файл не прочитан -
## кнопка «🎲» тогда просто не меняет поле.
static func hero_names(gender: String) -> Array:
	if _names_cache.is_empty():
		var parsed = JSON.parse_string(FileAccess.get_file_as_string(NAMES_PATH))
		if parsed is Dictionary:
			_names_cache = parsed
	var pool = _names_cache.get("female" if gender == "female" else "male", [])
	return pool if pool is Array else []
## Ширина карточки фиксирована, высота — нет: на низком окне (1280×600) ряд карточек
## обязан сжиматься, иначе панель характеристик уезжает за нижний край.
const CARD_WIDTH := 210.0
const CARD_IMAGE_MIN := 120

var selected := 0
var name_input: LineEdit
var _name_btn: Button
var _cards: Array = []
var _name_idx := -1  # последнее сгенерированное имя (для повторной кнопки)
var _root: VBoxContainer   # корневая колонка-раскладка
var _start_btn: Button
var _next_btn: Button
var _back_btn: Button
var _name_row: HBoxContainer

# --- Two-step creation: identity (step 1) and development (step 2) ---
var _step1_box: VBoxContainer
var _step2_box: VBoxContainer
var _title_label: Label
var _subtitle_label: Label
var _dir_list: VBoxContainer
var _dir_detail: VBoxContainer
var _dir_buttons: Dictionary = {}   # skill id -> Button (primary only)
var _aux_button: Button
var _selected_primary := ""
var _detail_skill := ""

# --- «Мир»: сид / зона / готовая карта (пакет «своя игра») ---
var _world_btn: Button
var _world_panel: Node = null     # WorldSetupPanel (CanvasLayer), пока открыта
var _start_setup: StartSetup      # что применится при «В ПУТЬ!»

# --- Настройка героя: атрибуты (склонность = выбранное направление) ---
var _edit: Dictionary = {}          # редактируемые статы (копия пресета)
var _stat_labels := {}              # "body" -> Label значения
var _pool_label: Label
const SKILL_IDS := ["blade", "axe", "bludgeon", "pike", "shooting",
	"fire", "water", "air", "earth", "astral"]
const STATS_ORDER := ["body", "agility", "mind", "spirit"]
const STAT_TITLES := {
	"body": "ui.char.stat.body", "agility": "ui.char.stat.agility",
	"mind": "ui.char.stat.mind", "spirit": "ui.char.stat.spirit",
}

func _ready():
	# Тематический анимированный курсор вместо системной стрелки.
	add_child(load("res://scripts/cursor_layer.gd").new())
	MusicDB.start_playlist.call_deferred()
	_start_setup = StartSetup.from_dict(Game.start_preset) if not Game.start_preset.is_empty() \
		else StartSetup.new()
	Game.start_preset = {}
	_rebuild_characters()
	_apply_theme()
	_setup_background()
	_setup_layout()
	_setup_title()
	_setup_step1()
	_setup_race_row()
	_setup_cards()
	_setup_name_row()
	_setup_step2()
	_setup_directions()
	_setup_editor()
	_setup_step2_buttons()
	_show_step(1)
	_select.call_deferred(0)
	if is_instance_valid(_next_btn):
		_next_btn.call_deferred("grab_focus")


## Portrait key: {race}_{m|f}_{war|mage}, plus a style for humans (human/human2).
## The race comes from data: `two_styles` means two looks (humans only),
## otherwise the portrait is named exactly by the race id. A mod with a new race
## works without code changes.
func _portrait_key(race: String, gender: String, role: String) -> String:
	var g := "m" if gender == "male" else "f"
	var r := "war" if role == "warrior" else "mage"
	if bool(ContentRules.race(race).get("two_styles", false)):
		return ("human" if _style <= 1 else "human2") + "_" + g + "_" + r
	return race + "_" + g + "_" + r


func _rebuild_characters() -> void:
	CHARACTERS.clear()
	for p in PRESETS:
		var key := _portrait_key(_race, str(p["gender"]), str(p["role"]))
		CHARACTERS.append({
			"id": key,
			"title": str(p["title"]),
			"gender": str(p["gender"]),
			"role": str(p["role"]),
			"desc": str(p["desc"]),
			"image": PORTRAIT_DIR + key + ".png",
			"stats": p["stats"],
		})


func _setup_race_row() -> void:
	var row := HBoxContainer.new()
	row.name = "RaceRow"
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 8)
	_step1_box.add_child(row)
	_race_buttons.clear()
	var race_list := races()
	for i in range(race_list.size()):
		var race: Dictionary = race_list[i]
		var b := Button.new()
		b.name = "Race_" + str(race["id"])
		b.text = Loc.field(race, "label")
		b.custom_minimum_size = Vector2(120, 32)
		b.toggle_mode = true
		b.button_pressed = str(race["id"]) == _race
		b.pressed.connect(_on_race_pressed.bind(str(race["id"])))
		row.add_child(b)
		_race_buttons.append(b)
	_style_btn = Button.new()
	_style_btn.name = "StyleBtn"
	_style_btn.custom_minimum_size = Vector2(140, 32)
	_style_btn.visible = _race == "human"
	_style_btn.pressed.connect(_on_style_pressed)
	row.add_child(_style_btn)
	_refresh_style_btn()


func _refresh_style_btn() -> void:
	if _style_btn == null:
		return
	_style_btn.visible = _race == "human"
	_style_btn.text = Loc.t("ui.char.style_a" if _style <= 1 else "ui.char.style_b")


func _on_race_pressed(race_id: String) -> void:
	_race = race_id
	var race_list := races()
	for i in range(_race_buttons.size()):
		var id := ""
		if i < race_list.size() and race_list[i] is Dictionary:
			id = str((race_list[i] as Dictionary).get("id", ""))
		(_race_buttons[i] as Button).button_pressed = id == _race
	_refresh_style_btn()
	_rebuild_characters()
	_refresh_card_images()
	if selected >= CHARACTERS.size():
		selected = 0
	_select(selected)
	SoundDB.play("ui.click")


func _on_style_pressed() -> void:
	_style = 2 if _style <= 1 else 1
	_refresh_style_btn()
	_rebuild_characters()
	_refresh_card_images()
	_select(selected)
	SoundDB.play("ui.click")


func _refresh_card_images() -> void:
	for i in range(_cards.size()):
		if i >= CHARACTERS.size():
			continue
		var card: Control = _cards[i]
		var img: TextureRect = card.get_node_or_null("Box/Img") as TextureRect
		if img != null:
			img.texture = load(str(CHARACTERS[i]["image"]))

## Единая тема экрана вместо разнобоя локальных override на каждом узле.
func _apply_theme() -> void:
	theme = UiKit.base_theme()
	UiKit.add_title(theme, &"CsTitle")
	UiKit.add_label(theme, &"CsSub", Color(0.75, 0.70, 0.60), 18)
	UiKit.add_label(theme, &"CsName", Color(0.95, 0.90, 0.80), 20)
	UiKit.add_label(theme, &"CsDesc", Color(0.85, 0.82, 0.75), 12)
	UiKit.add_label(theme, &"CsStatTitle", UiKit.SECTION_COLOR, 13)
	UiKit.add_gold_label(theme, &"CsPool")
	UiKit.add_panel(theme, &"CsCard", Color(0.12, 0.10, 0.09, 0.92), UiKit.SLOT_BORDER, 6)
	UiKit.add_panel(theme, &"CsEditor", Color(0.10, 0.09, 0.08, 0.94), UiKit.DIALOG_BORDER, 6)
	UiKit.add_button(theme, &"CsStart", Color(0.18, 0.24, 0.16, 0.95),
		UiKit.GOLD_COLOR, Color(0.24, 0.32, 0.20), UiKit.GOLD_COLOR, 6, 8)

func _setup_background() -> void:
	# Тёмный фон-панель на весь экран
	var bg := ColorRect.new()
	bg.color = Color(0.08, 0.06, 0.05, 1.0)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)
	# Горизонт-лента снизу (как каменный пол в оригинале)
	var floor := ColorRect.new()
	floor.color = Color(0.16, 0.12, 0.09, 1.0)
	floor.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	floor.offset_top = -120.0
	floor.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(floor)

## Корневая раскладка экрана: одна колонка-контейнер вместо координат 1280×800.
func _setup_layout() -> void:
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	UiKit.set_margins(margin, 28, 20, 28, 20)
	add_child(margin)
	_root = VBoxContainer.new()
	_root.add_theme_constant_override("separation", 10)
	margin.add_child(_root)
	UiKit.bind_resize(get_window(), _fit_root)

## Подгонка под окно: карточки сжимаются по высоте, отступы не растут.
func _fit_root() -> void:
	if not is_instance_valid(_root):
		return
	var available: float = size.y - 40.0
	var wanted: float = float(CHARACTERS.size()) * 0.0
	# Высота карточек задаётся контейнером; ограничиваем только минимальную,
	# чтобы панель характеристик не уехала за экран на маленьком окне.
	_root.custom_minimum_size = Vector2(0.0, minf(available, 800.0) + wanted)

func _setup_title() -> void:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	_root.add_child(box)
	var title := Label.new()
	title.theme_type_variation = &"CsTitle"
	title.text = "MIROTOKHOME"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)
	_title_label = title
	var sub := Label.new()
	sub.theme_type_variation = &"CsSub"
	sub.text = Loc.t("ui.char.step1")
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(sub)
	_subtitle_label = sub


## Step 1: identity — race, class/gender cards, name. Step 2: development.
func _setup_step1() -> void:
	_step1_box = VBoxContainer.new()
	_step1_box.name = "Step1"
	_step1_box.add_theme_constant_override("separation", 10)
	_step1_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_root.add_child(_step1_box)


func _setup_step2() -> void:
	_step2_box = VBoxContainer.new()
	_step2_box.name = "Step2"
	_step2_box.add_theme_constant_override("separation", 8)
	_step2_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_step2_box.visible = false
	_root.add_child(_step2_box)


## Switch the wizard step. Esc/«Назад» go back here, not to the main menu.
func _show_step(step: int) -> void:
	if is_instance_valid(_step1_box):
		_step1_box.visible = step == 1
	if is_instance_valid(_step2_box):
		_step2_box.visible = step == 2
	if is_instance_valid(_subtitle_label):
		_subtitle_label.text = Loc.t("ui.char.step1") if step == 1 \
			else Loc.t("ui.char.step2")
	if step == 2:
		_refresh_direction_buttons()
		_refresh_direction_detail()
		_refresh_editor()
		if is_instance_valid(_start_btn):
			_start_btn.call_deferred("grab_focus")
	elif is_instance_valid(_next_btn):
		_next_btn.call_deferred("grab_focus")

## Esc — назад в главное меню. До этого экран выбора героя не обрабатывал
## отмену: из «Новой игры» можно было выйти только через «В ПУТЬ!» или
## закрыв окно. Если открыта панель «Мир», Esc закрывает сначала её.
func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed("ui_cancel"):
		return
	if _world_panel != null and is_instance_valid(_world_panel):
		_world_panel.close()
		get_viewport().set_input_as_handled()
		return
	# Step 2 backs out to identity, not all the way to the main menu. The old
	# single-screen behaviour (Esc = menu) remains on step 1.
	if is_instance_valid(_step2_box) and _step2_box.visible:
		SoundDB.play("ui.click")
		get_viewport().set_input_as_handled()
		_show_step(1)
		return
	SoundDB.play("ui.click")
	get_viewport().set_input_as_handled()
	get_tree().change_scene_to_file(MAIN_MENU_SCENE)


func _setup_cards() -> void:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", int(CARD_GAP))
	row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_step1_box.add_child(row)
	for i in range(CHARACTERS.size()):
		row.add_child(_make_card(CHARACTERS[i], i))

## Клик/фокус карточки выбирают персонажа (мышь, клавиатура, геймпад).
func _on_card_input(event: InputEvent, idx: int) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_select(idx)

func _make_card(c: Dictionary, idx: int) -> Control:
	var panel := PanelContainer.new()
	panel.theme_type_variation = &"CsCard"
	panel.custom_minimum_size = Vector2(CARD_WIDTH, 0)
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	panel.focus_mode = Control.FOCUS_ALL
	_cards.append(panel)

	# Единственный прямой потомок карточки: контейнер, который НЕ перехватывает
	# клик (у прямых детей должен быть IGNORE — на этом держится клик по карточке).
	var box := VBoxContainer.new()
	box.name = "Box"
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_theme_constant_override("separation", 4)
	panel.add_child(box)

	# Миниатюра персонажа (портрет расы)
	var img := TextureRect.new()
	img.name = "Img"
	img.texture = load(str(c["image"])) if ResourceLoader.exists(str(c["image"])) else null
	img.custom_minimum_size = Vector2(0, CARD_IMAGE_MIN)
	img.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	img.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	img.size_flags_vertical = Control.SIZE_EXPAND_FILL
	img.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(img)

	# Подпись: класс + пол
	var label := Label.new()
	label.theme_type_variation = &"CsName"
	label.text = "%s\n%s" % [Loc.t(str(c["title"])),
				Loc.t("ui.char.male") if c["gender"] == "male" else Loc.t("ui.char.female")]
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(label)

	# Описание (имя героя появится после выбора)
	var desc := Label.new()
	desc.name = "Desc"
	desc.theme_type_variation = &"CsDesc"
	desc.text = ""
	desc.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	desc.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.custom_minimum_size = Vector2(0, 40)
	desc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(desc)

	panel.gui_input.connect(_on_card_input.bind(idx))
	panel.focus_entered.connect(func(): _select(idx))
	panel.mouse_entered.connect(func(): panel.modulate = Color(1.06, 1.06, 1.02))
	panel.mouse_exited.connect(func(): _update_card_style(panel))
	return panel

func _update_card_style(panel: Control) -> void:
	var idx: int = _cards.find(panel)
	if idx == selected:
		panel.modulate = Color(1.10, 1.10, 1.0)
		panel.add_theme_stylebox_override("panel",
			UiKit.panel_style(Color(0.21, 0.15, 0.09, 0.96), UiKit.DIALOG_BORDER, 6, 3))
	else:
		panel.modulate = Color.WHITE
		panel.remove_theme_stylebox_override("panel")

func _setup_name_row() -> void:
	# Имя и кнопка старта — в одной строке: на невысоком окне отдельная строка
	# на кнопку съедала высоту и выдавливала панель характеристик за край.
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 10)
	_step1_box.add_child(row)
	_name_row = row

	var lab := Label.new()
	lab.text = Loc.t("ui.char.name_label")
	lab.add_theme_font_size_override("font_size", 18)
	lab.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(lab)

	name_input = LineEdit.new()
	name_input.custom_minimum_size = Vector2(260, 40)
	name_input.max_length = 20
	name_input.add_theme_font_size_override("font_size", 18)
	name_input.placeholder_text = Loc.t("ui.char.name_placeholder")
	row.add_child(name_input)

	# Кнопка случайного греческого имени
	_name_btn = Button.new()
	_name_btn.text = Loc.t("ui.char.name_btn")
	_name_btn.custom_minimum_size = Vector2(120, 40)
	_name_btn.tooltip_text = Loc.t("ui.char.name_btn_tip")
	_name_btn.pressed.connect(_random_name)
	row.add_child(_name_btn)

	# «Мир»: сид / зона / готовая карта. Живёт в строке старта, чтобы не
	# съедать высоту отдельной строкой (экран уже впритык на 1280×600).
	_world_btn = Button.new()
	_world_btn.custom_minimum_size = Vector2(260, 40)
	_world_btn.clip_text = true
	_world_btn.tooltip_text = Loc.t("ui.char.world_tip_default")
	_world_btn.pressed.connect(_open_world_panel)
	row.add_child(_world_btn)
	_update_world_button()

	# Шаг 1 → шаг 2. «В ПУТЬ!» живёт на шаге развития: выбор направления
	# обязан случиться до старта.
	_next_btn = Button.new()
	_next_btn.name = "NextStep"
	_next_btn.text = Loc.t("ui.char.next")
	_next_btn.custom_minimum_size = Vector2(220, 48)
	_next_btn.add_theme_font_size_override("font_size", 20)
	_next_btn.pressed.connect(func() -> void:
		SoundDB.play("ui.click")
		_show_step(2))
	row.add_child(_next_btn)

	if name_input.text == "":
		_random_name()

func _update_world_button() -> void:
	if _world_btn == null:
		return
	var text := _start_setup.summary()
	_world_btn.text = Loc.f("ui.char.world_btn", [text])
	_world_btn.tooltip_text = Loc.f("ui.char.world_tip", [text])

func _open_world_panel() -> void:
	SoundDB.play("ui.click")
	if _world_panel != null and is_instance_valid(_world_panel):
		return
	_world_panel = WorldSetupPanel.new()
	add_child(_world_panel)
	_world_panel.applied.connect(_on_world_applied)
	_world_panel.edit_requested.connect(_on_world_edit)
	_world_panel.closed.connect(_on_world_closed)
	_world_panel.open(_start_setup)

func _on_world_applied(setup: StartSetup) -> void:
	_start_setup = setup
	_update_world_button()

func _on_world_closed() -> void:
	_world_panel = null
	if _world_btn != null:
		_world_btn.grab_focus()

## «Открыть редактор» из окна «Мир»: редактор вернётся сюда же, а сделанную
## карту игрок сразу увидит в списке.
func _on_world_edit(map_path: String) -> void:
	Game.editor_return_scene = "res://scenes/character_select.tscn"
	Game.start_preset = _start_setup.to_dict()
	if map_path != "":
		Game.start_preset["mode"] = "map"
		Game.start_preset["path"] = map_path
	get_tree().change_scene_to_file("res://scenes/map_editor.tscn")

func _random_name() -> void:
	var c: Dictionary = CHARACTERS[selected]
	var pool := hero_names(str(c["gender"]))
	if pool.is_empty():
		return
	# не повторяем подряд
	var i := randi() % pool.size()
	if pool.size() > 1 and i == _name_idx:
		i = (i + 1) % pool.size()
	_name_idx = i
	var entry: Dictionary = pool[i]
	name_input.text = str(entry.get(Loc.locale(), str(entry.get("ru", ""))))

func _setup_step2_buttons() -> void:
	var row := HBoxContainer.new()
	row.name = "Step2Buttons"
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 16)
	_step2_box.add_child(row)

	_back_btn = Button.new()
	_back_btn.name = "BackStep"
	_back_btn.text = Loc.t("ui.char.back")
	_back_btn.custom_minimum_size = Vector2(160, 44)
	_back_btn.add_theme_font_size_override("font_size", 18)
	_back_btn.pressed.connect(func() -> void:
		SoundDB.play("ui.click")
		_show_step(1))
	row.add_child(_back_btn)

	_start_btn = Button.new()
	_start_btn.text = Loc.t("ui.char.start")
	_start_btn.custom_minimum_size = Vector2(220, 48)
	_start_btn.add_theme_font_size_override("font_size", 24)
	_start_btn.pressed.connect(_start_game)
	row.add_child(_start_btn)
	# «Продолжить» перенесён в главное меню → «Загрузить игру» (05.10).
## Панель настройки внизу: атрибуты и остаток очков. Направление развития
## выбирается выше, в списке шага 2.
func _setup_editor() -> void:
	var panel := PanelContainer.new()
	panel.theme_type_variation = &"CsEditor"
	_step2_box.add_child(panel)

	var margin := MarginContainer.new()
	UiKit.set_margins(margin, 12, 8, 12, 8)
	panel.add_child(margin)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)
	margin.add_child(col)

	# --- Строка 1: заголовок, четыре характеристики, остаток очков ---
	var row1 := HBoxContainer.new()
	row1.add_theme_constant_override("separation", 10)
	col.add_child(row1)

	var lab := Label.new()
	lab.text = Loc.t("ui.char.stats")
	lab.add_theme_font_size_override("font_size", 15)
	lab.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row1.add_child(lab)

	for stat in STATS_ORDER:
		var box := VBoxContainer.new()
		box.add_theme_constant_override("separation", 2)
		row1.add_child(box)

		var title := Label.new()
		title.theme_type_variation = &"CsStatTitle"
		title.text = str(STAT_TITLES[stat])
		title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		box.add_child(title)

		var line := HBoxContainer.new()
		line.alignment = BoxContainer.ALIGNMENT_CENTER
		line.add_theme_constant_override("separation", 4)
		box.add_child(line)

		var minus := Button.new()
		minus.text = "−"
		minus.custom_minimum_size = Vector2(30, 30)
		minus.pressed.connect(_change_stat.bind(stat, -1))
		line.add_child(minus)

		var val := Label.new()
		val.text = "10"
		val.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		val.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		val.custom_minimum_size = Vector2(40, 30)
		line.add_child(val)
		_stat_labels[stat] = val

		var plus := Button.new()
		plus.text = "+"
		plus.custom_minimum_size = Vector2(30, 30)
		plus.pressed.connect(_change_stat.bind(stat, 1))
		line.add_child(plus)

	_pool_label = Label.new()
	_pool_label.theme_type_variation = &"CsPool"
	_pool_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_pool_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row1.add_child(_pool_label)

	# The link the player asked about: which stat feeds which number.
	var hint := Label.new()
	hint.theme_type_variation = &"CsDesc"
	hint.text = Loc.t("ui.char.stats_hint")
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(hint)

func _change_stat(name: String, delta: int) -> void:
	if not _edit.has(name):
		return
	var v := int(_edit[name])
	var total := 0
	for n in STATS_ORDER:
		total += int(_edit[n])
	var preset: int = int(_edit.get("_preset_total", total))
	var pool: int = preset - total
	if delta < 0:
		if v <= 4:
			return
		_edit[name] = v - 1
	elif delta > 0:
		if v >= 20 or pool <= 0:
			return
		_edit[name] = v + 1
	_refresh_editor()
	_refresh_direction_detail()

# --- Step 2: development directions (replaces the old 10-button affinity row) ---

## Build the step-2 picker: primary buttons on the left, the live description
## on the right, the auxiliary skill below the primaries. Only a class's own
## five directions are shown — a warrior must not invest in magic he cannot use.
func _setup_directions() -> void:
	var row := HBoxContainer.new()
	row.name = "Directions"
	row.add_theme_constant_override("separation", 14)
	row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_step2_box.add_child(row)

	var left := VBoxContainer.new()
	left.name = "DirectionList"
	left.custom_minimum_size = Vector2(280, 0)
	left.add_theme_constant_override("separation", 6)
	left.size_flags_vertical = Control.SIZE_EXPAND_FILL
	row.add_child(left)

	var head := Label.new()
	head.theme_type_variation = &"CsStatTitle"
	head.text = Loc.t("ui.char.main_skill")
	left.add_child(head)

	_dir_list = VBoxContainer.new()
	_dir_list.add_theme_constant_override("separation", 4)
	left.add_child(_dir_list)

	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left.add_child(spacer)

	var aux_head := Label.new()
	aux_head.theme_type_variation = &"CsStatTitle"
	aux_head.text = Loc.t("ui.char.aux_skill")
	left.add_child(aux_head)

	_aux_button = Button.new()
	_aux_button.toggle_mode = true
	_aux_button.custom_minimum_size = Vector2(0, 38)
	_aux_button.add_theme_font_size_override("font_size", 16)
	_aux_button.pressed.connect(func() -> void:
		SoundDB.play("ui.click")
		_detail_skill = str(_aux_button.get_meta("skill", ""))
		_refresh_direction_buttons()
		_refresh_direction_detail())
	left.add_child(_aux_button)

	var scroll := ScrollContainer.new()
	scroll.name = "DirectionDetailScroll"
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	row.add_child(scroll)

	var panel := PanelContainer.new()
	panel.theme_type_variation = &"CsEditor"
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(panel)

	var margin := MarginContainer.new()
	UiKit.set_margins(margin, 14, 10, 14, 10)
	panel.add_child(margin)

	_dir_detail = VBoxContainer.new()
	_dir_detail.add_theme_constant_override("separation", 5)
	_dir_detail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.add_child(_dir_detail)

	_rebuild_direction_buttons()


## Rebuild the primary buttons for the selected class. Called when the class
## (card) changes; the values are always 20/10/0.
func _rebuild_direction_buttons() -> void:
	if _dir_list == null or CHARACTERS.is_empty():
		return
	for c in _dir_list.get_children():
		_dir_list.remove_child(c)
		c.queue_free()
	_dir_buttons.clear()
	var role := str(CHARACTERS[selected]["role"])
	var order: Array = []
	for d in HeroDirections.primaries(role):
		var skill := str((d as Dictionary).get("skill", ""))
		var b := Button.new()
		var label := Loc.field(d as Dictionary, "label")
		b.text = "  " + (label if label != "" else skill)
		b.toggle_mode = true
		b.custom_minimum_size = Vector2(0, 40)
		b.add_theme_font_size_override("font_size", 18)
		b.pressed.connect(func() -> void:
			SoundDB.play("ui.click")
			_pick_direction(skill))
		_dir_list.add_child(b)
		_dir_buttons[skill] = b
		order.append(b)
	var typed: Array[Button] = []
	for b in order:
		typed.append(b as Button)
	UiKit.wire_grid_focus(typed, 1)
	var aux := HeroDirections.aux(role)
	if _aux_button != null:
		var aux_label := Loc.field(aux, "label")
		_aux_button.text = "  " + (aux_label if aux_label != "" else "—") + "  ·  10"
		_aux_button.set_meta("skill", str(aux.get("skill", "")))


## Which skill the step-2 description currently shows (a primary or the aux).
func _pick_direction(skill: String) -> void:
	var d := HeroDirections.by_skill(skill)
	if d.is_empty():
		return
	if str(d.get("role", "")) != "primary":
		_detail_skill = skill
		_refresh_direction_buttons()
		_refresh_direction_detail()
		return
	_apply_direction(skill)
	_refresh_direction_buttons()
	_refresh_direction_detail()
	_refresh_editor()


## 20 / 10 / 0 rule: the chosen direction is 20, the class auxiliary is 10,
## every other skill is 0. The auxiliary can never become the main direction.
func _apply_direction(skill: String) -> void:
	if _edit.is_empty():
		return
	var role := str(CHARACTERS[selected]["role"])
	var d := HeroDirections.by_skill(skill)
	if d.is_empty() or str(d.get("role", "")) != "primary":
		return
	for s in SKILL_IDS:
		_edit[s] = 0
	_edit[skill] = 20
	var aux := HeroDirections.aux(role)
	var aux_skill := str(aux.get("skill", ""))
	if aux_skill != "":
		_edit[aux_skill] = 10
	_edit["_primary"] = skill
	_edit["_aux"] = aux_skill
	_edit["weapon"] = str(d.get("weapon_kind", "sword"))
	_selected_primary = skill
	_detail_skill = skill


func _refresh_direction_buttons() -> void:
	for skill in _dir_buttons:
		var b: Button = _dir_buttons[skill]
		if is_instance_valid(b):
			b.button_pressed = str(skill) == _selected_primary
	if _aux_button != null:
		_aux_button.button_pressed = str(_aux_button.get_meta("skill", "")) == _detail_skill
	# The primary list flows into «В ПУТЬ!» and the auxiliary button too, so a
	# gamepad user is never stuck in the list.
	if is_instance_valid(_start_btn) and not _dir_buttons.is_empty():
		var first: Button = _dir_buttons.get(_selected_primary, _dir_buttons.values()[0])
		_start_btn.focus_neighbor_top = first.get_path()
		var last: Button = _dir_buttons.values()[-1]
		last.focus_neighbor_bottom = _start_btn.get_path()
		if is_instance_valid(_aux_button):
			_aux_button.focus_neighbor_bottom = _start_btn.get_path()


func _add_detail_label(text: String, font_size: int = 13,
		color: Color = Color(0.85, 0.82, 0.75)) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", color)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_dir_detail.add_child(l)
	return l


func _add_detail_list(keys: Array) -> void:
	for k in keys:
		var it := ItemDB.find(str(k))
		var nm := str(it.get("name_ru", str(k)))
		_add_detail_label("  • " + nm, 12, Color(0.80, 0.90, 0.75))


func _starter_keys(role: String, skill: String) -> Array:
	var kind := HeroDirections.weapon_kind_of(skill)
	var book := ""
	if role == "mage":
		var sphere := HeroDirections.sphere_of(skill)
		if sphere != "":
			book = SpellDB.book_key_for_spell(SpellDB.simplest_spell_of_sphere(sphere))
	return Player.starter_items(role, kind, bool(_edit.get("shield", false)), book)


## The whole right-hand card: role, real numbers, the weapon-vs-creature table
## and the exact starter kit. Rebuilt on every direction/attribute change.
func _refresh_direction_detail() -> void:
	if _dir_detail == null or _edit.is_empty() or CHARACTERS.is_empty():
		return
	for c in _dir_detail.get_children():
		_dir_detail.remove_child(c)
		c.queue_free()

	var skill := _detail_skill
	if skill == "":
		skill = _selected_primary
	var d := HeroDirections.by_skill(skill)
	if d.is_empty():
		return
	var role := str(CHARACTERS[selected]["role"])
	var is_aux := str(d.get("role", "")) == "aux"
	var title := Loc.field(d, "label")
	_add_detail_label(title if title != "" else skill, 22, UiKit.SECTION_COLOR)
	_add_detail_label(
		Loc.t("ui.char.skill_aux") if is_aux
		else Loc.t("ui.char.skill_main"),
		13, Color(0.88, 0.78, 0.55))
	_add_detail_label(Loc.field(d, "desc"), 13, Color(0.82, 0.80, 0.74))

	var body := int(_edit.get("body", 10))
	var agility := int(_edit.get("agility", 10))
	var mind := int(_edit.get("mind", 10))
	var spirit := int(_edit.get("spirit", 10))
	var aux_skill := str(_edit.get("_aux", ""))
	var skill_points := int(_edit.get(skill, 0))
	var aux_points := int(_edit.get(aux_skill, 0)) if aux_skill != "" else 0
	var dev := float(skill_points) \
		+ float(aux_points) * GameConfig.getf("skill_stats", "aux_factor")
	var hp := Player.max_hp_of(body) \
		+ int(dev * GameConfig.getf("skill_stats", "hp_per_point"))

	# Gear of the ACTUAL starter kit (the card must not promise 13 defence
	# while the hero starts with a buckler worth 3). The auxiliary card shows
	# the same build, so the gear comes from the chosen primary, not from the
	# auxiliary's example bow.
	var kit_skill := _selected_primary if _selected_primary != "" else skill
	var kit_kind := HeroDirections.weapon_kind_of(kit_skill)
	var kit_weapon := Player.starter_weapon_key(role, kit_kind)
	var kit := _starter_keys(role, kit_skill)
	var gear_def := int(ItemDB.find(kit_weapon).get("defence", 0))
	var gear_abs := int(ItemDB.find(kit_weapon).get("absorption", 0))
	if kit.has("Common bronze Buckler"):
		var buckler := ItemDB.find("Common bronze Buckler")
		gear_def += int(buckler.get("defence", 0))
		gear_abs += int(buckler.get("absorption", 0))
	var defense := Player.defense_of(agility, body, gear_def)
	if role != "mage":
		defense += int(dev * GameConfig.getf("skill_stats", "defense_per_point"))
	var absorption := Player.absorption_of(body, gear_abs)

	_add_detail_label("————————————————————————————————————————————", 9, Color(0.35, 0.30, 0.25))
	_add_detail_label(Loc.f("ui.char.points_line", [int(dev)]),
		12, Color(0.72, 0.68, 0.58))

	if role == "mage":
		var sphere := HeroDirections.sphere_of(skill)
		var sp := Game.spell_power_value(float(skill_points), float(mind))
		var mana := Player.max_mana_of(spirit) \
			+ int(dev * GameConfig.getf("skill_stats", "mana_per_point"))
		_add_detail_label(Loc.f("ui.char.hp_mana", [hp, mana]),
			15, Color(0.95, 0.90, 0.80))
		if sphere != "":
			var starter := SpellDB.simplest_spell_of_sphere(sphere)
			if starter != "":
				var base := SpellDB.damage(starter)
				var coef := SpellDB.power_coef_of(starter)
				var dmg := maxi(SpellDB.min_damage_of(starter),
					int(round(base * coef * (1.0 + sp / 100.0))))
				_add_detail_label(Loc.f("ui.char.magic_line",
					[int(round(sp)), starter.replace("_", " "), dmg,
						SpellDB.mana_cost(starter)]), 13, Color(0.82, 0.86, 0.95))
		if not is_aux:
			_add_detail_label(Loc.t("ui.char.with_you"), 14, Color(0.88, 0.78, 0.55))
			_add_detail_list(_starter_keys(role, skill))
		else:
			_add_detail_label(Loc.t("ui.char.no_book"), 12,
				Color(0.70, 0.66, 0.58))
	else:
		var kind := str(d.get("weapon_kind", "sword"))
		var item_key := Player.starter_weapon_key("warrior", kind)
		if is_aux:
			item_key = "Common bronze Long Bow"
		var item := ItemDB.find(item_key)
		var dmin := int(item.get("damage_min", 0))
		var dmax := int(item.get("damage_max", 0))
		var d_lo := Player.damage_min_of(dmin, skill_points, agility)
		var d_hi := Player.damage_max_of(dmax, skill_points, body)
		var attack := Player.attack_of(agility, skill_points, int(item.get("to_hit", 0)))
		var hit := Game.hit_chance(attack, 10)
		_add_detail_label(Loc.f("ui.char.hp_def_abs", [hp, defense, absorption]),
			15, Color(0.95, 0.90, 0.80))
		_add_detail_label(Loc.f("ui.char.weapon_line",
			[ItemDB.display_name(item), d_lo, d_hi, attack, hit]),
			13, Color(0.90, 0.86, 0.76))
		_add_detail_label(Loc.t("ui.char.against"), 14, Color(0.88, 0.78, 0.55))
		var table := ContentRules.dict("combat.weapon_vs_type")
		var row: Dictionary = table.get(kind, {})
		var labels := ContentRules.dict("combat.creature_types")
		for ctype in labels:
			var pct := int(row.get(ctype, 100))
			var lo := Game.apply_weapon_percent(d_lo, pct)
			var hi := Game.apply_weapon_percent(d_hi, pct)
			var mark := "+" if pct > 100 else ("−" if pct < 100 else "=")
			_add_detail_label("%s %s: %d%%  (%d–%d)"
				% [mark, Loc.pair(labels[ctype]), pct, lo, hi], 12,
				Color(0.78, 0.88, 0.76) if pct > 100 else (
					Color(0.95, 0.72, 0.66) if pct < 100 else Color(0.75, 0.73, 0.68)))
		if not is_aux:
			_add_detail_label(Loc.t("ui.char.with_you"), 14, Color(0.88, 0.78, 0.55))
			_add_detail_list(_starter_keys(role, skill))
		else:
			_add_detail_label(Loc.t("ui.char.no_bow"), 12,
				Color(0.70, 0.66, 0.58))

	var hint := _add_detail_label(
		Loc.t("ui.char.formula"),
		11, Color(0.60, 0.57, 0.50))
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART

## Обновить подписи статов/очков после правок.
func _refresh_editor() -> void:
	if _edit.is_empty():
		return
	var total := 0
	for n in STATS_ORDER:
		(_stat_labels[n] as Label).text = str(_edit[n])
		total += int(_edit[n])
	var preset := int(_edit.get("_preset_total", total))
	_pool_label.text = Loc.f("ui.char.points_left", [preset - total])

func _select(idx: int) -> void:
	if idx < 0 or idx >= CHARACTERS.size():
		return
	selected = idx
	# Редактируемая копия статов пресета + фиксированная сумма («очки»).
	# Skills are NOT preset values any more: the 20/10/0 rule is applied below.
	var base: Dictionary = CHARACTERS[idx]["stats"]
	_edit = base.duplicate(true)
	for s in SKILL_IDS:
		_edit[s] = 0
	var total := 0
	for n in STATS_ORDER:
		total += int(_edit.get(n, 0))
	_edit["_preset_total"] = total

	# Default main direction: the first primary of the class (sword / fire).
	# The player can change it; the choice is never empty.
	var role := str(CHARACTERS[idx]["role"])
	var primaries := HeroDirections.primaries(role)
	if not primaries.is_empty():
		_apply_direction(str((primaries[0] as Dictionary).get("skill", "")))
	_rebuild_direction_buttons()
	_refresh_direction_buttons()
	_refresh_direction_detail()
	_refresh_editor()
	for i in range(_cards.size()):
		_update_card_style(_cards[i])
		var desc: Label = _cards[i].get_node_or_null("Desc")
		if desc:
			desc.text = Loc.t(str(CHARACTERS[i]["desc"])) if i == idx else ""
	SoundDB.play("ui.click")  # click00 — выбор персонажа
	# При смене пола — новое греческое имя
	if name_input.text == "" or _name_idx >= 0:
		_random_name()

func _start_game() -> void:
	var c: Dictionary = CHARACTERS[selected]
	var st: Dictionary = _edit.duplicate(true)
	if st.is_empty():
		st = (c["stats"] as Dictionary).duplicate(true)
	st.erase("_preset_total")
	st.erase("_primary")
	st.erase("_aux")
	Game.hero_class = str(c["role"])
	Game.hero_gender = str(c["gender"])
	Game.hero_name = name_input.text.strip_edges()
	if Game.hero_name == "":
		Game.hero_name = Loc.t("ui.char.default_hero")
	# The skills are already 20 (main) / 10 (aux) / 0 (rest) in _edit.
	Game.hero_primary_skill = str(_edit.get("_primary", _selected_primary))
	Game.hero_aux_skill = str(_edit.get("_aux", ""))
	# Маг: выбранная школа даёт книгу простейшего БОЕВОГО заклинания этой
	# школы (учится одним кликом по ячейке склада).
	Game.hero_start_book = ""
	if Game.hero_class == "mage":
		var sphere := HeroDirections.sphere_of(Game.hero_primary_skill)
		if sphere != "":
			var starter := SpellDB.simplest_spell_of_sphere(sphere)
			Game.hero_start_book = SpellDB.book_key_for_spell(starter)
	Game.hero_stats = st
	Game.hero_character_id = str(c["id"])
	Game.hero_portrait = str(c["image"])
	Game.hero_race = _race
	Game.hero_dead = false
	# Мир из блока «Мир»: случайный сид, конкретный сид или готовая карта.
	# `StartSetup.apply()` сам раскладывает сид мира по секторам через
	# world_map.seed_of (то же правило, что было в new_random_map).
	var err := _start_setup.apply()
	if err != "":
		push_warning("Новая игра не начата: %s" % err)
		_open_world_panel()
		return
	# Новая игра — чистый лист: отряд и хотбар прошлой партии не переносятся.
	# Хотбар раньше вообще не сбрасывался: назначенные клавиши нового героя
	# ссылались на заклинания/предметы прежнего.
	Game.pending_party = []
	Game.hotbar = {}
	SoundDB.play("ui.confirm")  # click_ok
	# Карта 96x96 генерируется в фоне на отдельном экране с полосой прогресса:
	# раньше main.tscn открывался с чёрной паузой на генерацию.
	get_tree().change_scene_to_file("res://scenes/loading.tscn")
