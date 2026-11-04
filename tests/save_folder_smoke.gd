extends SceneTree
## Slot folders: save from a live game, load it back, change the zone.
##
## Player request (22.10): every save is its own folder in the saves
## directory holding the character, the map and the process; a Save rewrites
## every element of the folder. This test drives the real scene: a slot must
## bring the hero back to the saved position, the map must come from the slot
## (not from the seed), and a zone change must put the new zone's map files
## into the slot so the older zone survives a restart.
##
## Run: godot --headless --path . --script res://tests/save_folder_smoke.gd

const Sandbox := preload("res://tests/save_sandbox.gd")
const SLOT := "slot_0"

var _fails: Array[String] = []
var _checks := 0


func _initialize() -> void:
	Sandbox.use_test_dir()
	_run.call_deferred()


func _run() -> void:
	await _start_game()
	var game = current_scene
	var player = game.get("player")
	_check(player != null, "герой на месте")
	if player == null:
		_finish()
		return
	# Save the CURRENT (spawn) position: it is guaranteed walkable, so the load
	# cannot snap the hero to a nearby cell. A hard-coded (1500,1500) was a
	# flaky expectation — it depended on the random seed of the generated map.
	var saved_pos: Vector2 = player.global_position
	player.global_position = saved_pos
	player.gold = 2468
	game.call("_save_to_slot", SLOT)

	_check(FileAccess.file_exists(SaveSystem.part_path(SLOT, SaveSystem.HERO_FILE)),
		"в папке слота есть hero.json")
	_check(FileAccess.file_exists(SaveSystem.part_path(SLOT, SaveSystem.MAP_FILE)),
		"в папке слота есть map.json")
	_check(FileAccess.file_exists(SaveSystem.part_path(SLOT, SaveSystem.PROCESS_FILE)),
		"в папке слота есть process.json")
	var slot_map := SaveSystem.world_map_path(SLOT)
	_check(slot_map != "" and FileAccess.file_exists(slot_map),
		"в папке слота лежит сама карта (.alm): %s" % slot_map.get_file())

	# Портим живое состояние и грузим слот: всё должно вернуться из папки.
	player.gold = 1
	player.global_position = Vector2(32, 32)
	game.call("_load_from_slot", SLOT)
	await create_timer(1.0).timeout
	player = game.get("player")
	_check(int(player.gold) == 2468, "золото вернулось из слота (%d)" % int(player.gold))
	_check(player.global_position.distance_to(saved_pos) < 1.0,
		"герой встал на позицию из слота (%s)" % str(player.global_position))
	var map = game.get("alm_map")
	var map_path := str(map.get("alm_path")) if map != null else ""
	_check(map_path.begins_with(SaveSystem.slot_dir(SLOT)),
		"карта загружена из папки слота (%s)" % map_path)

	# Переход в другой сектор: карта нового сектора ложится в тот же слот.
	var old_sector := Game.map_sector
	await game.call("travel_to_zone", "mid")
	await create_timer(1.2).timeout
	_check(Game.map_zone == "mid", "зона сменилась на mid (%s)" % Game.map_zone)
	var new_sector := Game.map_sector
	_check(new_sector != "", "сектор определён (%s)" % new_sector)
	var zone_map := SaveSystem.restore_zone_map(SLOT, new_sector)
	# Карта нового сектора уже лежит в user://maps/ (игра только что на ней),
	# поэтому restore_zone_map возвращает путь на месте — важно, что он есть.
	_check(zone_map != "" and FileAccess.file_exists(zone_map),
		"карта нового сектора лежит в папке слота (%s)" % zone_map)
	var back_map := SaveSystem.restore_zone_map(SLOT, old_sector)
	_check(back_map != "" and FileAccess.file_exists(back_map),
		"карта прежнего сектора (%s) осталась в слоте (%s)" % [old_sector, back_map])
	_check(is_instance_valid(player), "герой пережил переход между зонами")

	# Загрузка слота ДРУГОГО персонажа прямо из игры (жалоба 23.10): воин
	# сохраняет игру, маг перезаписывает слот — воин загружает слот мага и
	# должен получить спрайт/ману/склад мага, а не остаться воином.
	var warrior_anim := str(player.anim_set_name())
	game.call("_save_to_slot", SLOT)
	Game.hero_class = "mage"
	Game.hero_character_id = "human_m_mage"
	Game.hero_portrait = ""
	Game.hero_name = "Магистр"
	player.equipped = {}
	player.inventory = ["Potion Medium Healing"]
	player.gold = 777
	player.current_mana = 30
	# Маг одевает посох по тем же правилам класса, что и игрок в UI.
	player.equip_item(ItemDB.find("Common Wood Staff"))
	game.call("_save_to_slot", "slot_1")
	var res1 := SaveSystem.load_slot("slot_1")
	var data1: Dictionary = res1.get("data", {})
	var hero1: Dictionary = data1.get("hero", {})
	var saved_class := str(hero1.get("class", ""))
	_check(saved_class == "mage", "слот мага записан с классом mage")
	# Обратно воин в живом состоянии и загружаем слот мага.
	Game.hero_class = "warrior"
	Game.hero_character_id = "human_m_war"
	Game.hero_portrait = ""
	Game.hero_name = "Воин"
	player.reload_hero_state()
	_check(str(player.anim_set_name()) == warrior_anim, "воин вернулся к своему набору")
	game.call("_load_from_slot", "slot_1")
	await create_timer(1.2).timeout
	player = game.get("player")
	var mage_anim := str(player.anim_set_name())
	_check(mage_anim != warrior_anim and mage_anim.find("mage") >= 0,
		"после загрузки слота мага у героя набор мага (%s)" % mage_anim)
	var anim_node = player.get("_anim")
	_check(anim_node != null and str(anim_node.get("set_name")) == mage_anim,
		"спрайт переключён на набор мага (%s)" % (str(anim_node.get("set_name")) if anim_node != null else "нет"))
	# Прежний спрайт-узел должен быть снят с героя: иначе воин стоял бы
	# внизу, а маг рисовался бы поверх него (жалоба 23.10).
	var anim_nodes := 0
	var sprite_nodes := 0
	for ch in player.get_children():
		if ch is UnitAnimBase:
			anim_nodes += 1
		elif ch is Sprite2D:
			sprite_nodes += 1
	_check(anim_nodes == 1 and sprite_nodes == 0,
		"у героя ровно одна анимация (UnitAnim=%d, Sprite2D=%d)" % [anim_nodes, sprite_nodes])
	_check(bool(player.has_mana), "у героя из слота мага есть мана")
	_check(int(player.gold) == 777, "золото из слота мага (%d)" % int(player.gold))
	_check(player.inventory.has("Potion Medium Healing"), "склад из слота мага")
	_check(str(player.equipped.get("weapon", "")) == "Common Wood Staff",
		"посох мага надет (%s)" % str(player.equipped.get("weapon", "")))
	var hp_bar = player.get("health_bar")
	_check(hp_bar != null and bool(hp_bar.has_mana), "полоса маны построена заново для мага")
	# Миникарта не должна помнить прежнюю карту: кэш террейна привязан к узлу Map.
	var ui_node = game.get("ui")
	var minimap_map = ui_node.get("alm_map") if ui_node != null else null
	_check(minimap_map != null and minimap_map == game.get("alm_map"),
		"миникарта привязана к загруженной карте")
	_check(is_instance_valid(ui_node) and int(ui_node.get("_minimap_map_id"))
		== int(game.get("alm_map").get_instance_id()) or ui_node.get("_minimap_base") == null,
		"кэш миникарты сброшен под новую карту")
	_check(Game.hero_name == "Магистр", "имя героя из слота (%s)" % Game.hero_name)
	var doll := InventoryPanel.portrait_path()
	_check(doll == Game.hero_portrait_path() and doll != "", "портрет куклы — от загруженного героя")
	_finish()


func _start_game() -> void:
	Game.hero_class = "warrior"
	Game.hero_gender = "male"
	Game.hero_name = "Тестер"
	Game.hero_character_id = "human_m_war"
	Game.hero_stats = {"strength": 20, "dexterity": 20, "intelligence": 10,
		"vitality": 20, "spirit": 10, "luck": 5}
	Game.map_seed = 4242
	Game.map_zone = "start"
	Game.map_sector = "s41"
	Game.loaded_slot = ""
	var game = load("res://scenes/main.tscn").instantiate()
	root.add_child(game)
	current_scene = game
	await create_timer(0.6).timeout


func _check(cond: bool, label: String) -> void:
	_checks += 1
	if cond:
		print("OK   ", label)
	else:
		print("FAIL ", label)
		_fails.append(label)


func _finish() -> void:
	Sandbox.wipe()
	print("---")
	print("проверок: %d" % _checks)
	if _fails.is_empty():
		print("RESULT: OK save_folder_smoke")
		quit(0)
	else:
		print("RESULT: FAIL save_folder_smoke (провалено: %d)" % _fails.size())
		for f in _fails:
			print("  - ", f)
		quit(1)
