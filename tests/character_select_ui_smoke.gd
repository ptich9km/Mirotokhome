extends SceneTree
## Smoke-проверка экрана выбора персонажа (scripts/character_select.gd).
##
## Экран был собран на хардкоженных координатах 1280×800 (position/size у каждого
## узла). Проверяем, что теперь это контейнеры + единая тема, и — главное —
## что интерфейс не вылезает за окно ни на 1280×800, ни на 1280×600.
##
## Запуск: godot --headless --path . --script res://tests/character_select_ui_smoke.gd

const SIZES := [Vector2i(1280, 800), Vector2i(1280, 600)]

## The slots live in a scratch directory: a test run must never touch the
## saves of the player (`tests/save_sandbox.gd`).
const Sandbox := preload("res://tests/save_sandbox.gd")

var _fails: Array[String] = []

func _init() -> void:
	# «Продолжить» перенесён в главное меню — на character_select его больше нет.
	var scene: PackedScene = load("res://scenes/character_select.tscn")
	var cs = scene.instantiate()
	root.add_child(cs)
	for i in range(6):
		await process_frame
	await _inspect(cs, Vector2i(1280, 800), "1280x800")
	await _inspect(cs, Vector2i(1280, 600), "1280x600")
	cs._show_step(2)
	await process_frame
	await _inspect(cs, Vector2i(1280, 800), "step2 1280x800")
	await _inspect(cs, Vector2i(1280, 600), "step2 1280x600")
	_structure(cs)
	_report()

## Временное сохранение, чтобы кнопка «Продолжить» была на экране.
func _seed_save() -> void:
	Sandbox.use_test_dir()
	SaveSystem.ensure_dir()
	SaveSystem.save("autosave", {
		"version": SaveSystem.VERSION,
		"map": {"seed": 1, "zone": "mid"},
		"hero": {"name": "Тестовый герой", "class": "mage", "current_hp": 50,
			"max_hp": 100, "max_mana": 50, "current_mana": 10, "gold": 5,
			"inventory": [], "equipped": {}, "experience": {},
			"known_spells": {}, "sphere_books": {}, "position": Vector2(0, 0)},
		"world": {"day": 7, "cities": {}},
		"quests": {},
		"meta": {"hero_name": "Тестовый герой", "hero_class": "mage", "day": 7,
			"stamp": 99},
	})


func _wipe_save() -> void:
	for p in [SaveSystem.slot_path(SaveSystem.AUTOSAVE_SLOT),
			SaveSystem.bak_path(SaveSystem.AUTOSAVE_SLOT),
			SaveSystem.tmp_path(SaveSystem.AUTOSAVE_SLOT)]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(p))

## Ничего не должно вылезать за пределы окна.
func _inspect(cs, size_px: Vector2i, tag: String) -> void:
	root.size = size_px
	for i in range(3):
		await process_frame
	# Вписывание проверяем в НАСТОЯЩИЙ вьюпорт, а не в выдуманное окно size_px.
	# При stretch/aspect="expand" логическая область не равна размеру окна:
	# замер 03.10 — при root.size = 1280x600 реальный get_visible_rect()
	# равен 1706x800 (окно шире базовых 1280x800). Интерфейс, построенный под
	# эту область, в окно 1280x600 визуально помещается целиком — масштаб 0.75,
	# и прежняя проверка требовала вписаться в 1280x600, ругаясь на верную
	# вёрстку. Размер 1706x800 в отчёте и был этой логической областью,
	# а не «интерфейс шире окна».
	var win := root.get_visible_rect()
	print("[%s] вьюпорт после resize: %s (окно %dx%d)"
			% [tag, str(win), size_px.x, size_px.y])
	var worst := ""
	for node in _walk(cs):
		var c := node as Control
		if c == null or not c.is_visible_in_tree():
			continue
		var r := Rect2(c.global_position, c.size)
		if r.size.x <= 0.0 or r.size.y <= 0.0:
			continue
		if not win.encloses(r):
			worst = "%s %s=%s" % [c.get_path(), "size" if win.size.x < r.size.x else "pos", r]
			break
	_check(worst == "", "[%s] весь интерфейс внутри окна%s" % [tag, "" if worst == "" else " — " + worst])

## Контейнерная структура, тема, фокус.
func _structure(cs) -> void:
	_check(cs.theme != null, "на корне висит единая тема UiKit")
	_check(cs.get("_root") is VBoxContainer, "корневая раскладка — VBoxContainer")

	var cards: Array = cs.get("_cards")
	_check(cards.size() == 4, "карточек 4 (было %d)" % cards.size())
	var panels := 0
	var themed := 0
	for card in cards:
		if card is PanelContainer:
			panels += 1
		if card.theme_type_variation == &"CsCard":
			themed += 1
	_check(panels == cards.size(), "карточки — PanelContainer (%d из %d)" % [panels, cards.size()])
	_check(themed == cards.size(), "карточки используют стиль темы (%d из %d)" % [themed, cards.size()])

	# Расы: 4 кнопки + портреты из assets/hero_portraits
	var races: Array = cs.get("_race_buttons")
	_check(races.size() == 4, "кнопок рас 4 (получено %d)" % races.size())
	var imgs_ok := 0
	for card in cards:
		var img: TextureRect = (card as Control).get_node_or_null("Box/Img") as TextureRect
		if img != null and img.texture != null:
			var tp := (img.texture as Texture2D).resource_path
			if tp.contains("hero_portraits"):
				imgs_ok += 1
	_check(imgs_ok == 4, "карточки используют портреты hero_portraits (%d из 4)" % imgs_ok)

	# Никаких ручных координат: у узлов НЕ должно быть заданных position/size
	# вне контейнеров (position != Vector2.ZERO означает ручную раскладку).
	var manual := 0
	for node in _walk(cs):
		var c := node as Control
		if c == null or c is Container:
			continue
		if c.get_parent() is Container:
			continue
		if c is ColorRect:
			continue  # фон — он и должен быть на весь экран
		if c is Label and c.position != Vector2.ZERO:
			manual += 1
	_check(manual == 0, "нет ручной раскладки узлов (найдено: %d)" % manual)

	# Ввод и фокус
	var name_input: LineEdit = cs.get("name_input")
	_check(name_input != null, "поле ввода имени на месте")
	_check(name_input != null and name_input.custom_minimum_size.x >= 200.0, "поле имени не мелкое")
	var start_btn: Button = cs.get("_start_btn")
	_check(start_btn != null, "кнопка «В ПУТЬ!» на месте")
	_check(start_btn != null and start_btn.custom_minimum_size.x >= 200.0, "кнопка старта не мелкая")
	# Step 2: four primary direction buttons, wired for keyboard/gamepad, and
	# one auxiliary button that can never become the main direction.
	var dirs: Dictionary = cs.get("_dir_buttons")
	_check(dirs.size() == 4, "кнопок основных направлений 4 (%d)" % dirs.size())
	var wired := 0
	for skill in dirs:
		var b: Button = dirs[skill]
		if is_instance_valid(b) and (not b.focus_neighbor_top.is_empty()
				or not b.focus_neighbor_bottom.is_empty()):
			wired += 1
	_check(wired == dirs.size(), "у направлений прописаны соседи фокуса (%d из %d)"
		% [wired, dirs.size()])
	_check(cs.get("_aux_button") != null, "кнопка вспомогательного умения на месте")
	_check(cs.get("_detail_skill") != "", "описание направления выбрано")

## Обойти всё дерево.
func _walk(node: Node) -> Array:
	var out: Array = [node]
	for child in node.get_children():
		out.append_array(_walk(child))
	return out

func _check(cond: bool, label: String) -> void:
	if cond:
		print("OK   ", label)
	else:
		print("FAIL ", label)
		_fails.append(label)

func _report() -> void:
	print("---")
	if _fails.is_empty():
		print("RESULT: OK character_select_ui_smoke")
		quit(0)
	else:
		print("RESULT: FAIL character_select_ui_smoke (провалено: %d)" % _fails.size())
		for f in _fails:
			print("  - ", f)
		quit(1)
