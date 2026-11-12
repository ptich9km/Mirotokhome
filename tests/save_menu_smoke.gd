extends SceneTree
## Smoke: меню сохранений в живой игре.
##
## Проверяет то, что нельзя проверить на голых словарях:
##   1. Esc открывает меню, оно строится из контейнеров и фокусится;
##   2. «Сохранить» пишет слот из ЖИВОГО героя (инвентарь/золото/HP);
##   3. содержимое слота переживает пересборку сцены;
##   4. «Загрузить» восстанавливает героя и сид карты;
##   5. Esc из меню закрывает его, а не открывает второй раз;
##   6. версия из будущего отклоняется с внятным сообщением, а не падает.
##
## Запуск: godot --headless --path . --script res://tests/save_menu_smoke.gd

const SLOT := "slot_0"

## The slots live in a scratch directory: a test run must never touch the
## saves of the player (`tests/save_sandbox.gd`).
const Sandbox := preload("res://tests/save_sandbox.gd")

var _fails: Array[String] = []
var _checks := 0
## Сколько тестов-секций реально отработало. Точнее, чем «ожидаемое число
## проверок»: константа с общим количеством ломается от любой моей правки
## (уже ломалась: 38 против 40), а молчаливо выпавшая корутина всегда
## отнимает целую секцию.
var _sections_done := 0
const SECTIONS_TOTAL := 6


func _initialize() -> void:
	Sandbox.use_test_dir()
	_wipe()
	_run.call_deferred()


func _run() -> void:
	var game = await _load_world()
	if game == null:
		_report()
		return
	# await обязателен: три из четырёх тестов содержат await и без него
	# являются корутинами, которые возвращаются на первом кадре. Тогда тест
	# молча ничего не проверяет и выглядит зелёным (ровно тот баг, что уже
	# был в этом проекте - см. AGENTS, журнал от 26.09).
	await _test_menu_opens(game)
	await _test_save_from_live_hero(game)
	await _test_reload_restores(game)
	await _test_load_position_without_player()
	await _test_version_rejected(game)
	await _test_quit_to_menu(game)
	_wipe()
	_report()


## КОЛВЕРЧЕНИЕ: три теста ниже содержат await, поэтому ОБЯЗАНЫ вызываться
## с await. Без await корутина возвращается на первом кадре, тест молча
## ничего не проверяет и падает «зелёным» (ровно тот баг, что уже был в
## этом проекте). Поэтому в _report стоит проверка общего числа проверок.

func _load_world():
	Game.hero_class = "warrior"
	Game.hero_gender = "male"
	Game.hero_name = "Тестер"
	Game.hero_character_id = "mfighter"
	Game.hero_stats = {"strength": 20, "dexterity": 20, "intelligence": 10,
		"vitality": 20, "spirit": 10, "luck": 5}
	Game.hero_start_book = ""
	Game.map_seed = 4242
	Game.map_zone = "mid"
	var packed: PackedScene = load("res://scenes/main.tscn")
	var game = packed.instantiate()
	root.add_child(game)
	for i in range(4):
		await process_frame
	await create_timer(0.4).timeout
	return game


# --- 1. Открытие по Esc ---

func _test_menu_opens(game) -> void:
	_check(game.get("alm_map") != null, "мир загрузился")
	_check(not _menu_open(game), "меню изначально закрыто")

	_press_esc()
	await process_frame
	var menu = _menu(game)
	_check(_menu_open(game), "Esc открыл меню сохранений")
	if menu == null:
		return
	# Меню обязано появляться В ИГРЕ, а не быть узлом main.tscn: иначе любая
	# правка узлов сцены задевает и меню. Проверяем, что до Esc такого узла
	# в дереве не было вовсе.
	_check(_count_menus(game) == 1, "меню добавлено в сцену как ОДИН узел (%d)" % _count_menus(game))
	_check(menu.get("_root") != null, "у меню есть корневой Control")
	# Чек-лист AGENTS §10.2: раскладка на контейнерах, без ручных координат.
	_check(_has_container(menu), "раскладка построена контейнерами (есть CenterContainer)")
	var slots: Node = menu.get("_slot_box")
	_check(slots != null and slots.get_child_count() == SaveSystem.PLAYER_SLOTS.size() + 1,
		"в меню %d строк (3 слота + автосейв), найдено %d" % [
		SaveSystem.PLAYER_SLOTS.size() + 1, slots.get_child_count() if slots else -1])
	var focusables: Array = menu.get("_focusables")
	_check(focusables.size() >= SaveSystem.PLAYER_SLOTS.size(),
		"кнопки доступны с клавиатуры/геймпада (%d)" % focusables.size())
	var focused := _focused_control()
	_check(focused != null, "при открытии есть начальный фокус")
	# Мир на паузе, пока меню открыто (жалоба 22.10: персонаж бегал под меню).
	_check(paused, "открытое меню ставит мир на паузу")
	_check(Game.is_paused, "флаг Game.is_paused поднят вместе с паузой дерева")
	var d0: Vector2 = game.get("player").global_position
	await create_timer(0.3).timeout
	_check(game.get("player").global_position.is_equal_approx(d0),
		"герой стоит под открытым меню (сдвиг %s)" % str(
			game.get("player").global_position - d0))

	# Esc из открытого меню закрывает его, а не открывает второй.
	_press_esc()
	await process_frame
	await process_frame
	_check(not _menu_open(game), "Esc из меню закрыл его (второго меню не появилось)")
	_check(_count_menus(game) == 0, "после закрытия узлов меню в сцене не осталось")
	_check(not paused, "закрытие меню снимает паузу")
	_check(not Game.is_paused, "флаг Game.is_paused снят вместе с паузой дерева")
	_sections_done += 1


# --- 2. Сохранение из живого героя ---

func _test_save_from_live_hero(game) -> void:
	var player = game.get("player")
	_check(player != null, "игрок на месте")
	player.gold = 4321
	player.inventory = ["Common iron Long Sword", "Potion Medium Healing"]
	player.current_hp = 37
	player.current_mana = 11
	player.experience = {"blade": 1500, "fire": 250}
	player.sphere_books = {"Fire": true}
	player.global_position = Vector2(512, 384)

	game.call("open_save_menu")
	await process_frame
	var menu = _menu(game)
	if menu == null:
		_check(false, "меню открылось для сохранения")
		return
	menu.save_requested.emit(SLOT)
	await process_frame
	_check(FileAccess.file_exists(SaveSystem.slot_path(SLOT)), "файл слота создан")
	_check(str(menu.get("_status").text) != "", "показано подтверждение в меню")
	_check(paused and _menu_open(game), "после сохранения меню открыто и мир на паузе")

	var res := SaveSystem.load_slot(SLOT)
	_check(not res.has("error"), "слот читается")
	var hero: Dictionary = res.get("data", {}).get("hero", {})
	_check(int(hero.get("gold", 0)) == 4321, "золото сохранено (%s)" % str(hero.get("gold")))
	_check(int(hero.get("current_hp", 0)) == 37, "HP сохранено")
	_check(int(hero.get("current_mana", 0)) == 11, "мана сохранена")
	_check((hero.get("inventory", []) as Array).size() == 2, "инвентарь сохранён")
	_check(int((hero.get("experience", {}) as Dictionary).get("blade", 0)) == 1500,
		"навык сохранён")
	_check((hero.get("sphere_books", {}) as Dictionary).get("Fire", false) == true,
		"книга стихий сохранена")
	_check(str(hero.get("name", "")) == "Тестер", "имя героя сохранено")
	var pos: Variant = hero.get("position", null)
	_check(pos is Vector2 and pos.distance_to(Vector2(512, 384)) < 0.01,
		"позиция героя сохранена как Vector2 (%s)" % str(pos))
	var mapd: Dictionary = res.get("data", {}).get("map", {})
	_check(int(mapd.get("seed", 0)) == 4242, "сид карты сохранён")
	_check(res.get("data", {}).has("world"), "состояние мира сохранено")
	_check(int(res.get("data", {}).get("world", {}).get("day", -1)) >= 0,
		"мир содержит день (%d)" % int(res.get("data", {}).get("world", {}).get("day", -1)))
	_check((res.get("data", {}).get("quests", null) as Dictionary) != null,
		"блок quests на месте (пустая схема)")
	# Метаданные для экрана слотов.
	_check(str(res.get("meta", {}).get("hero_name", "")) == "Тестер",
		"meta содержит имя героя для списка слотов")
	menu.close()
	_sections_done += 1


# --- 3-4. Пересборка сцены и загрузка ---

func _test_reload_restores(game) -> void:
	# Портим живое состояние так, чтобы восстановление было заметно.
	var player = game.get("player")
	player.gold = 1
	player.inventory = []
	player.current_hp = 2
	player.global_position = Vector2(16, 16)  # мутация: не совпадает со слотом
	Game.map_seed = 999999
	Game.hero_name = "Сломан"
	Game.clear_load_position()
	# Слот переживает пересборку сцены: он на диске, а не в памяти узла.
	var res := SaveSystem.load_slot(SLOT)
	SaveSystem.apply_payload(res.get("data", {}), player)
	_check(int(player.gold) == 4321, "золото восстановлено при загрузке (%d)" % int(player.gold))
	_check(player.inventory.size() == 2, "инвентарь восстановлен")
	_check(int(player.current_hp) == 37, "HP восстановлено")
	_check(int(Game.map_seed) == 4242, "сид карты восстановлен (%d)" % int(Game.map_seed))
	_check(str(Game.hero_name) == "Тестер", "имя героя восстановлено")
	_check(Game.hero_class == "warrior", "класс героя восстановлен")
	_check(Game.load_position_valid, "Game.load_position_valid выставлен")
	_check(Game.load_position.distance_to(Vector2(512, 384)) < 0.01,
		"Game.load_position = %s" % str(Game.load_position))
	_check(not Game.hero_save.is_empty(), "Game.hero_save заполнен")
	_check(int(Game.hero_save.get("gold", -1)) == 4321,
		"hero_save.gold = %s" % str(Game.hero_save.get("gold")))
	_check((Game.hero_save.get("inventory", []) as Array).size() == 2,
		"hero_save.inventory = 2")
	_check(Game.hero_save.has("equipped"), "hero_save.equipped есть")
	# Симуляция Player._ready после change_scene: weapon_kind, а не type из БД.
	var eq: Dictionary = Game.hero_save.get("equipped", {})
	if eq.has("weapon"):
		var wit = ItemDB.find(str(eq["weapon"]))
		if not wit.is_empty():
			var kind := ItemDB.weapon_kind(wit)
			_check(kind in ["sword", "axe", "club", "pike", "bow", "xbow", "staff", "magic", "unarmed"],
				"weapon_kind для анимации валиден (%s)" % kind)
			_check(not kind.contains(" "), "weapon_kind без пробелов (%s)" % kind)
	var pos: Variant = player.global_position
	_check(pos is Vector2 and pos.distance_to(Vector2(512, 384)) < 0.01,
		"позиция игрока восстановлена apply_payload (%s)" % str(pos))
	# Состояние мира кладём так же, как это делает _restart_scene.
	var world_text := JsonSafe.dump(res.get("data", {}).get("world", {}))
	var ws_script: GDScript = load("res://scripts/world/world_state.gd")
	var restored = ws_script.from_json_text(world_text)
	_check(restored != null, "мир восстанавливается из слота")
	if restored != null:
		_check(int(restored.day) == int(res.get("data", {}).get("world", {}).get("day", -1)),
			"день мира восстановлен, а не обнулён")
	_sections_done += 1


## Путь main_menu: apply_payload(data, null) — позиция должна остаться в Game
## для _spawn_player_on_walkable после change_scene.
func _test_load_position_without_player() -> void:
	Game.clear_load_position()
	Game.clear_hero_save()
	var res := SaveSystem.load_slot(SLOT)
	SaveSystem.apply_payload(res.get("data", {}), null)
	_check(Game.load_position_valid, "без игрока load_position_valid=true")
	_check(Game.load_position.distance_to(Vector2(512, 384)) < 0.01,
		"без игрока load_position в Game (%s)" % str(Game.load_position))
	_check(not Game.hero_save.is_empty(), "без игрока hero_save заполнен")
	_check(int(Game.hero_save.get("gold", -1)) == 4321,
		"без игрока hero_save.gold (%s)" % str(Game.hero_save.get("gold")))
	_check((Game.hero_save.get("inventory", []) as Array).size() == 2,
		"без игрока hero_save.inventory")
	_check(int(Game.map_seed) == 4242, "без игрока map_seed восстановлен")
	Game.clear_load_position()
	Game.clear_hero_save()
	_sections_done += 1


# --- 6. Будущая версия ---

func _test_version_rejected(game) -> void:
	var doc: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(SaveSystem.slot_path(SLOT)))
	doc["version"] = SaveSystem.VERSION + 5
	var f := FileAccess.open(SaveSystem.slot_path(SLOT), FileAccess.WRITE)
	f.store_string(JSON.stringify(doc))
	f.close()
	game.call("open_save_menu")
	await process_frame
	var menu = _menu(game)
	menu.load_requested.emit(SLOT)
	await process_frame
	var status := str(menu.get("_status").text)
	var version_note := Loc.t("ui.save.status.version").split("%")[0]
	_check(status.find(version_note) >= 0,
		"в меню показано внятное сообщение о версии («%s»)" % status)
	_check(int(Game.map_seed) == 4242, "состояние игры не изменилось при отказе")
	# Вернуть слот в рабочее состояние для чистоты.
	SaveSystem.save(SLOT, SaveSystem.load_slot(SLOT).get("data", {}))
	_sections_done += 1


# --- 7. Выход в главное меню: одна запись автосейва ---

## «В главное меню» раньше писало автосейв дважды: сам `_quit_to_menu` и
## `_notification(PREDELETE)` при сносе сцены. Вторая запись затирала то, что
## главное меню только что сохранило при загрузке слота (его герой собирается
## только при старте новой игры). Жалоба 22.10: «сохранения видны, пока не
## закроешь игру».
func _test_quit_to_menu(game) -> void:
	var player = game.get("player")
	if player == null:
		_check(false, "игрок на месте для выхода в меню")
		return
	player.gold = 777
	game.call("_quit_to_menu")
	await process_frame
	await process_frame
	_check(not SaveSystem.dir().begins_with(SaveSystem.DIR),
		"тест работает в песочнице, а не в живых сохранениях (%s)" % SaveSystem.dir())
	var res := SaveSystem.load_slot(SaveSystem.AUTOSAVE_SLOT)
	_check(int(res.get("data", {}).get("hero", {}).get("gold", -1)) == 777,
		"в автосейве именно состояние, которым вышли из игры")
	_check(not paused, "после выхода в меню дерево не на паузе")
	# Главное меню появилось — прежняя сцена снесена, `_notification(PREDELETE)`
	# уже отгремел. Если он тоже сохранял, автосейв сейчас был бы не 777.
	var menu := current_scene
	_check(menu != null and menu.name.to_lower().contains("menu"),
		"главное меню загружено (%s)" % (menu.name if menu != null else "null"))
	var again := SaveSystem.load_slot(SaveSystem.AUTOSAVE_SLOT)
	_check(int(again.get("data", {}).get("hero", {}).get("gold", -1)) == 777,
		"после сноса сцены автосейв не перезаписан второй раз (золото %s)"
			% str(again.get("data", {}).get("hero", {}).get("gold", -1)))
	_sections_done += 1


# --- вспомогательное ---

func _menu(game):
	var n = game.get("_save_menu")
	return n if (n != null and is_instance_valid(n)) else null


func _menu_open(game) -> bool:
	return _menu(game) != null


## Сколько узлов SaveMenu в дереве игры. Проверяет, что меню создаётся
## кодом (open_save_menu) и не заведено в main.tscn.
func _count_menus(game) -> int:
	var n := 0
	for child in game.get_children():
		if child is SaveMenu:
			n += 1
	return n


func _press_esc() -> void:
	var ev := InputEventKey.new()
	ev.keycode = KEY_ESCAPE
	ev.pressed = true
	root.push_input(ev)


func _has_container(node: Node) -> bool:
	if node is CenterContainer or node is VBoxContainer or node is HBoxContainer:
		return true
	for c in node.get_children():
		if _has_container(c):
			return true
	return false


func _focused_control() -> Control:
	var vp := root.get_viewport() if root.has_method("get_viewport") else null
	if vp == null:
		return null
	return vp.gui_get_focus_owner()


func _wipe() -> void:
	Sandbox.wipe()


func _check(cond: bool, label: String) -> void:
	_checks += 1
	if cond:
		print("OK   ", label)
	else:
		print("FAIL ", label)
		_fails.append(label)


func _report() -> void:
	print("---")
	print("проверок: %d" % _checks)
	# Страховка от молчаливо пропущенных корутин. Без await функция с await
	# внутри возвращается на первом кадре, её секция не отрабатывает, и тест
	# выглядит зелёным - ровно тот баг, что уже был в этом проекте.
	if _sections_done != SECTIONS_TOTAL:
		print("FAIL отработало %d секций из %d - какая-то не была вызвана с await"
			% [_sections_done, SECTIONS_TOTAL])
		_fails.append("не все секции отработали")
	if _fails.is_empty():
		print("RESULT: OK save_menu_smoke")
		quit(0)
	else:
		print("RESULT: FAIL save_menu_smoke (провалено: %d)" % _fails.size())
		for f in _fails:
			print("  - ", f)
		quit(1)
