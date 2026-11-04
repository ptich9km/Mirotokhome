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
		"role": "warrior", "gender": "male", "title": "Воин",
		"desc": "Сила и выносливость, меч и щит.",
		"stats": {"body": 12, "agility": 11, "mind": 9, "spirit": 8,
			"blade": 30, "bludgeon": 15, "pike": 10, "fire": 5, "water": 5, "air": 5, "earth": 5, "astral": 5,
			"weapon": "sword", "shield": true, "armor": "heavy"},
	},
	{
		"role": "warrior", "gender": "female", "title": "Воин",
		"desc": "Быстрая и ловкая, лёгкий клинок.",
		"stats": {"body": 10, "agility": 13, "mind": 9, "spirit": 8,
			"blade": 30, "bludgeon": 15, "pike": 10, "fire": 5, "water": 5, "air": 5, "earth": 5, "astral": 5,
			"weapon": "sword", "shield": false, "armor": "heavy"},
	},
	{
		"role": "mage", "gender": "male", "title": "Маг",
		"desc": "Могучий разум, школа магии.",
		"stats": {"body": 8, "agility": 9, "mind": 13, "spirit": 12,
			"blade": 5, "bludgeon": 5, "pike": 5,
			"fire": 5, "water": 5, "air": 5, "earth": 5, "astral": 5,
			"weapon": "staff", "shield": false, "armor": "heavy"},
	},
	{
		"role": "mage", "gender": "female", "title": "Маг",
		"desc": "Дух и интуиция, школа магии.",
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

# Греческие имена (по полу персонажа)
const MALE_NAMES := [
	"Адонис", "Александр", "Аристотель", "Ахилл", "Гектор", "Гелиос",
	"Геракл", "Гиперион", "Демосфен", "Дионис", "Евклид", "Зенон",
	"Икар", "Кирилл", "Леонид", "Ликург", "Милон", "Нестор",
	"Одиссей", "Орест", "Пан", "Парис", "Персей", "Платон",
	"Прокл", "Прометей", "Сократ", "Софокл", "Тезей", "Феникс", "Эдип", "Ясон",
]
const FEMALE_NAMES := [
	"Аглая", "Ариадна", "Артемида", "Аталанта", "Афина", "Галатея",
	"Геката", "Гелика", "Гермиона", "Деметра", "Елена", "Ирида",
	"Ифигения", "Кассандра", "Клеопатра", "Клио", "Кора", "Лаодамия",
	"Леда", "Медея", "Мегара", "Ника", "Олимпиада", "Пандора",
	"Пенелопа", "Персефона", "Рея", "Селена", "София", "Талия", "Хлоя", "Эвридика",
]

const CARD_SIZE := Vector2(210, 330)
const CARD_GAP := 24.0
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
var _name_row: HBoxContainer

# --- «Мир»: сид / зона / готовая карта (пакет «своя игра») ---
var _world_btn: Button
var _world_panel: Node = null     # WorldSetupPanel (CanvasLayer), пока открыта
var _start_setup: StartSetup      # что применится при «В ПУТЬ!»

# --- Настройка героя (как в оригинале): атрибуты и склонность навыка ---
var _edit: Dictionary = {}          # редактируемые статы (копия пресета)
var _stat_labels := {}              # "body" -> Label значения
var _pool_label: Label
var _affinity_buttons: Array[Button] = []   # кнопки склонности (field)
const AFFINITIES := [
	["Меч", "blade"], ["Топор", "axe"], ["Булава", "bludgeon"], ["Копьё", "pike"],
	["Стрельба", "shooting"], ["Огонь", "fire"], ["Вода", "water"],
	["Воздух", "air"], ["Земля", "earth"], ["Астрал", "astral"],
]
const STATS_ORDER := ["body", "agility", "mind", "spirit"]
const STAT_TITLES := {
	"body": "ТЕЛО", "agility": "ЛОВКОСТЬ", "mind": "РАЗУМ", "spirit": "ДУХ",
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
	_setup_race_row()
	_setup_cards()
	_setup_name_row()
	_setup_start_button()
	_setup_editor()
	_select.call_deferred(0)
	if is_instance_valid(_start_btn):
		_start_btn.call_deferred("grab_focus")


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
	_root.add_child(row)
	_race_buttons.clear()
	var race_list := races()
	for i in range(race_list.size()):
		var race: Dictionary = race_list[i]
		var b := Button.new()
		b.name = "Race_" + str(race["id"])
		b.text = str(race["label"])
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
	_style_btn.text = "Стиль A" if _style <= 1 else "Стиль B"


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
	var sub := Label.new()
	sub.theme_type_variation = &"CsSub"
	sub.text = "Выберите героя"
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(sub)

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
	SoundDB.play("ui.click")
	get_viewport().set_input_as_handled()
	get_tree().change_scene_to_file(MAIN_MENU_SCENE)


func _setup_cards() -> void:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", int(CARD_GAP))
	row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_root.add_child(row)
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
	label.text = "%s\n%s" % [c["title"], "Мужчина" if c["gender"] == "male" else "Женщина"]
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
	_root.add_child(row)
	_name_row = row

	var lab := Label.new()
	lab.text = "Имя героя:"
	lab.add_theme_font_size_override("font_size", 18)
	lab.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(lab)

	name_input = LineEdit.new()
	name_input.custom_minimum_size = Vector2(260, 40)
	name_input.max_length = 20
	name_input.add_theme_font_size_override("font_size", 18)
	name_input.placeholder_text = "Введите имя..."
	row.add_child(name_input)

	# Кнопка случайного греческого имени
	_name_btn = Button.new()
	_name_btn.text = "🎲 Имя"
	_name_btn.custom_minimum_size = Vector2(120, 40)
	_name_btn.tooltip_text = "Случайное греческое имя"
	_name_btn.pressed.connect(_random_name)
	row.add_child(_name_btn)

	# «Мир»: сид / зона / готовая карта. Живёт в строке старта, чтобы не
	# съедать высоту отдельной строкой (экран уже впритык на 1280×600).
	_world_btn = Button.new()
	_world_btn.custom_minimum_size = Vector2(260, 40)
	_world_btn.clip_text = true
	_world_btn.tooltip_text = "Начало игры: сид мира, зона или готовая карта"
	_world_btn.pressed.connect(_open_world_panel)
	row.add_child(_world_btn)
	_update_world_button()

	if name_input.text == "":
		_random_name()

func _update_world_button() -> void:
	if _world_btn == null:
		return
	var text := _start_setup.summary()
	_world_btn.text = "Мир: " + text
	_world_btn.tooltip_text = "Начало игры — " + text

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
	var pool: Array = FEMALE_NAMES if c["gender"] == "female" else MALE_NAMES
	# не повторяем подряд
	var i := randi() % pool.size()
	if pool.size() > 1 and i == _name_idx:
		i = (i + 1) % pool.size()
	_name_idx = i
	name_input.text = str(pool[i])

func _setup_start_button() -> void:
	var row: HBoxContainer = _name_row if is_instance_valid(_name_row) else HBoxContainer.new()
	if not is_instance_valid(_name_row):
		row.alignment = BoxContainer.ALIGNMENT_CENTER
		row.add_theme_constant_override("separation", 10)
		_root.add_child(row)
	_start_btn = Button.new()
	_start_btn.text = "В ПУТЬ!"
	_start_btn.custom_minimum_size = Vector2(220, 48)
	_start_btn.add_theme_font_size_override("font_size", 24)
	_start_btn.pressed.connect(_start_game)
	row.add_child(_start_btn)
	# «Продолжить» перенесён в главное меню → «Загрузить игру» (05.10).
## Панель настройки внизу: атрибуты (очки) и склонность навыка (+20).
func _setup_editor() -> void:
	var panel := PanelContainer.new()
	panel.theme_type_variation = &"CsEditor"
	_root.add_child(panel)

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
	lab.text = "Характеристики:"
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

	# --- Строка 2: склонность (+20 к навыку) ---
	var row2 := HBoxContainer.new()
	row2.add_theme_constant_override("separation", 8)
	col.add_child(row2)

	var alab := Label.new()
	alab.text = "Склонность (+20 к навыку):"
	alab.add_theme_font_size_override("font_size", 13)
	alab.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row2.add_child(alab)

	for i in range(AFFINITIES.size()):
		var b := Button.new()
		b.text = str(AFFINITIES[i][0])
		b.toggle_mode = true
		b.custom_minimum_size = Vector2(92, 30)
		b.pressed.connect(_pick_affinity.bind(i))
		row2.add_child(b)
		_affinity_buttons.append(b)
	# Сквозная навигация по ряду кнопок (мышь/клавиатура/геймпад)
	UiKit.wire_grid_focus(_affinity_buttons, AFFINITIES.size())

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

func _pick_affinity(idx: int) -> void:
	for i in range(_affinity_buttons.size()):
		(_affinity_buttons[i] as Button).button_pressed = (i == idx)
	if idx < 0 or idx >= AFFINITIES.size():
		return
	var skill := str(AFFINITIES[idx][1])
	_edit[skill] = 20   # выбранная склонность
	# Маг: выбранная сфера магии — его «школа» (даёт стартовую книгу заклинания).
	if str(CHARACTERS[selected]["role"]) == "mage":
		var sphere := _magic_sphere_of(skill)
		if sphere != "":
			_edit["_school"] = sphere
	_refresh_editor()

## Сфера магии по имени навыка (для выбора школы мага); "" — не магия.
func _magic_sphere_of(skill: String) -> String:
	match skill:
		"fire": return "Fire"
		"water": return "Water"
		"air": return "Air"
		"earth": return "Earth"
		"astral": return "Astral"
	return ""

## Обновить подписи статов/очков после правок.
func _refresh_editor() -> void:
	if _edit.is_empty():
		return
	var total := 0
	for n in STATS_ORDER:
		(_stat_labels[n] as Label).text = str(_edit[n])
		total += int(_edit[n])
	var preset := int(_edit.get("_preset_total", total))
	_pool_label.text = "Очки: %d" % (preset - total)

func _select(idx: int) -> void:
	if idx < 0 or idx >= CHARACTERS.size():
		return
	selected = idx
	# Редактируемая копия статов пресета + фиксированная сумма («очки»)
	var base: Dictionary = CHARACTERS[idx]["stats"]
	_edit = base.duplicate(true)
	_edit.erase("_school")   # сброс выбора школы мага при смене персонажа
	var total := 0
	for n in STATS_ORDER:
		total += int(_edit.get(n, 0))
	_edit["_preset_total"] = total
	_refresh_editor()
	# Сброс склонности
	for i in range(_affinity_buttons.size()):
		(_affinity_buttons[i] as Button).button_pressed = false
	for i in range(_cards.size()):
		_update_card_style(_cards[i])
		var desc: Label = _cards[i].get_node_or_null("Desc")
		if desc:
			desc.text = CHARACTERS[i]["desc"] if i == idx else ""
	SoundDB.play("ui.click")  # click00 — выбор персонажа
	# При смене пола — новое греческое имя
	if name_input.text == "" or _name_idx >= 0:
		_random_name()

func _start_game() -> void:
	var c: Dictionary = CHARACTERS[selected]
	var st: Dictionary = _edit.duplicate(true)
	if st.is_empty():
		st = c["stats"]
	st.erase("_preset_total")
	st.erase("_school")
	Game.hero_class = str(c["role"])
	Game.hero_gender = str(c["gender"])
	Game.hero_name = name_input.text.strip_edges()
	if Game.hero_name == "":
		Game.hero_name = "Герой"
	# Маг: выбранная школа магии развита до 20 очков, в склад кладётся книга
	# простейшего заклинания этой школы (учится одним кликом по ячейке).
	Game.hero_start_book = ""
	if Game.hero_class == "mage":
		var school := str(_edit.get("_school", ""))
		if school == "":
			school = _default_mage_school(st)
		st[school.to_lower()] = 20
		var starter := SpellDB.simplest_spell_of_sphere(school)
		Game.hero_start_book = SpellDB.book_key_for_spell(starter)
	Game.hero_stats = st
	Game.hero_character_id = str(c["id"])
	Game.hero_portrait = str(c["image"])
	Game.hero_race = _race
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

## Школа по умолчанию, если склонность не трогали: первая сфера с навыком >= 20
## в пресете; иначе — Огонь.
func _default_mage_school(st: Dictionary) -> String:
	for sk in ["fire", "water", "air", "earth", "astral"]:
		if int(st.get(sk, 0)) >= 20:
			return _magic_sphere_of(sk)
	return "Fire"
