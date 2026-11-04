extends SceneTree
## Death and the game-over screen (04.11).
##
## Player request: a dead hero must stay dead, enemies must stop hitting the
## corpse, and the game must show black -> «ВЫ ПОГИБЛИ» -> the load menu with
## only «Загрузить» and «В главное меню». A mercenary's death must NOT stop the
## game.
##
## Run: godot --headless --path . --script res://tests/game_over_smoke.gd

const Sandbox := preload("res://tests/save_sandbox.gd")

var _fails: Array[String] = []
var _checks := 0
var _game = null
var _player = null


func _initialize() -> void:
	Sandbox.use_test_dir()
	# The scene refuses to start without a chosen hero (it redirects to the
	# character screen), so seed a warrior like the other live-scene tests.
	Game.hero_save = {}
	Game.hero_class = "warrior"
	Game.hero_gender = "male"
	Game.hero_name = "Тест"
	Game.hero_character_id = "human_m_war"
	Game.hero_race = "human"
	Game.hero_stats = {"body": 12, "agility": 11, "mind": 9, "spirit": 8,
		"blade": 20, "axe": 0, "bludgeon": 0, "pike": 0, "shooting": 10,
		"fire": 0, "water": 0, "air": 0, "earth": 0, "astral": 0,
		"weapon": "sword", "shield": true, "armor": "heavy"}
	Game.hero_primary_skill = "blade"
	Game.hero_aux_skill = "shooting"
	Game.hero_dead = false
	call_deferred("_run")


func _check(ok: bool, what: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(what)
	print("DEATH: %s %s" % ["ok  " if ok else "FAIL", what])


func _run() -> void:
	var err := change_scene_to_file("res://scenes/main.tscn")
	if err != OK:
		_check(false, "main.tscn загрузилась")
		_finish()
		return
	await process_frame
	await create_timer(1.0).timeout
	_game = current_scene
	_player = get_first_node_in_group("player")
	_check(_game != null and _player != null, "живая сцена и герой")
	if _game == null or _player == null:
		_finish()
		return

	await _mercenary_keeps_game_alive()
	await _death_sequence()
	await _load_resets_everything()
	_finish()


## A mercenary's death is its own business: no flag, no overlay.
func _mercenary_keeps_game_alive() -> void:
	var merc := Mercenary.new()
	merc.set("anim_set", "ork_mage_a52/t1")
	merc.global_position = _player.global_position + Vector2(64, 0)
	_game.add_child(merc)
	await process_frame
	_check(is_instance_valid(merc), "наёмник создан")
	merc.take_damage(99999, _player)
	await create_timer(0.3).timeout
	_check(not Game.hero_dead, "смерть наёмника не ставит героя мёртвым")
	_check(_game.get("_save_menu") == null, "смерть наёмника не открывает Game Over")
	_check(not Game.is_paused, "смерть наёмника не ставит паузу")
	if is_instance_valid(merc):
		merc.queue_free()


func _death_sequence() -> void:
	# A sentinel autosave: the death must never overwrite it with a corpse.
	_player.gold = 2468
	_game.call("_save_to_slot", SaveSystem.AUTOSAVE_SLOT)
	var before := SaveSystem.load_slot(SaveSystem.AUTOSAVE_SLOT)
	_check(int(before.get("data", {}).get("hero", {}).get("gold", -1)) == 2468,
		"живой автосейв записан (золото 2468)")

	# A wolf next to the hero: it must lose the corpse as a target. Spawn it
	# deterministically — the random starting map may have no ordinary Grey
	# within aggro range.
	var enemy := Enemy.new()
	enemy.anim_set = "monsters/wolf"
	enemy.faction = ""
	enemy.provoked = false
	enemy.global_position = _player.global_position + Vector2(32, 0)
	_game.add_child(enemy)
	await process_frame
	_check(enemy.call("_combat_target_impl") == _player,
		"до смерти враг видит героя целью")

	_player.take_damage(99999, null)
	_check(Game.hero_dead, "смертельный удар ставит Game.hero_dead")
	_check(_player.is_dead, "у героя взведён is_dead")
	_check(_player.state == "dead", "герой в состоянии dead (%s)" % _player.state)
	_check(enemy.call("_combat_target_impl") != _player,
		"мёртвого героя больше не берут целью")

	# The old bug: a panel/stop_movement put the corpse back to idle.
	_player.stop_movement()
	_check(_player.state == "dead", "stop_movement не поднимает труп")
	_check(Game.hero_dead, "флаг смерти не сбрасывается движением")

	# Autosave and manual save are off while dead.
	_game.call("autosave_now")
	_game.call("_save_to_slot", SaveSystem.AUTOSAVE_SLOT)
	var during := SaveSystem.load_slot(SaveSystem.AUTOSAVE_SLOT)
	_check(int(during.get("data", {}).get("hero", {}).get("gold", -1)) == 2468,
		"автосейв не перезаписан трупом")

	# Stage 1: the fall is still running; the title appears after 1 s.
	await create_timer(1.3).timeout
	_check(Game.hero_dead, "после падения флаг смерти держится")
	var death_screen = _game.get("_death_screen")
	_check(death_screen != null and is_instance_valid(death_screen),
		"через 1 с появился чёрный экран с надписью")
	_check(_game.get("_save_menu") == null, "меню загрузки ещё нет")
	if death_screen != null and is_instance_valid(death_screen):
		_check(_find_label(death_screen, "ВЫ ПОГИБЛИ") != null,
			"на экране надпись «ВЫ ПОГИБЛИ»")

	# Stage 2: compact screen with the title, then the load list.
	await create_timer(1.6).timeout
	var menu = _game.get("_save_menu")
	_check(menu != null and is_instance_valid(menu), "открылось меню загрузки")
	if menu == null:
		return
	_check(str(menu.get("_mode")) == "load_only", "меню в режиме load_only")
	_check(menu.get("_backdrop") != null, "под меню чёрный фон")
	_check(Game.is_paused, "мир на паузе (Game.is_paused)")
	_check(paused, "дерево на паузе")
	_check(_find_label(menu, "ВЫ ПОГИБЛИ") != null, "в меню есть заголовок смерти")
	_check(_find_label(menu, "Загрузите сохранение") != null, "есть подсказка загрузки")

	var save_short := Loc.t("ui.save.save_short")
	var delete_short := Loc.t("ui.save.delete_short")
	_check(_count_buttons_with_text(menu, save_short) == 0,
		"в меню смерти нет кнопки «Сохранить»")
	_check(_count_buttons_with_text(menu, delete_short) == 0,
		"в меню смерти нет кнопки «Удалить»")
	_check(_count_buttons_with_text(menu, Loc.t("ui.save.to_main")) == 1,
		"есть кнопка «В главное меню»")
	var app_btn: Button = menu.get("_app_btn")
	_check(app_btn != null and not app_btn.visible, "кнопка «Выйти» скрыта")

	# Esc must not dismiss the game-over screen back into a corpse.
	var esc := InputEventKey.new()
	esc.keycode = KEY_ESCAPE
	esc.pressed = true
	menu.call("_input", esc)
	await process_frame
	_check(is_instance_valid(menu), "Esc не закрывает экран смерти")
	_check(Game.is_paused, "Esc не снимает паузу смерти")

	# World commands are ignored while dead.
	_game.call("_input", esc)
	await process_frame
	_check(_game.get("_save_menu") != null, "Esc не открывает обычное меню поверх")


func _load_resets_everything() -> void:
	var menu = _game.get("_save_menu")
	menu.emit_signal("load_requested", SaveSystem.AUTOSAVE_SLOT)
	await create_timer(2.5).timeout
	_player = get_first_node_in_group("player")
	_check(_player != null, "герой существует после загрузки")
	if _player == null:
		return
	_check(not Game.hero_dead, "Game.hero_dead сброшен загрузкой")
	_check(not _player.is_dead, "is_dead сброшен загрузкой")
	_check(_player.state == "idle", "герой снова idle (%s)" % _player.state)
	_check(not Game.is_paused, "пауза снята после загрузки")
	_check(not paused, "дерево снова идёт")
	_check(_game.get("_save_menu") == null, "экран смерти закрыт")
	_check(_game.get("_death_screen") == null, "чёрный экран закрыт")
	_check(int(_player.gold) == 2468, "загружено живое золото (2468)")
	_check(int(_player.current_hp) > 0, "жизнь положительная (%d)" % int(_player.current_hp))


func _find_label(root: Node, needle: String) -> Label:
	if root is Label and str((root as Label).text).contains(needle):
		return root as Label
	for c in root.get_children():
		var found := _find_label(c, needle)
		if found != null:
			return found
	return null


func _count_buttons_with_text(root: Node, text: String) -> int:
	var n := 0
	if root is Button and str((root as Button).text) == text and (root as Button).visible:
		n += 1
	for c in root.get_children():
		n += _count_buttons_with_text(c, text)
	return n


func _finish() -> void:
	print("")
	if _fails.is_empty():
		print("RESULT: OK game_over_smoke (%d checks)" % _checks)
	else:
		print("RESULT: FAIL game_over_smoke (%d checks, %d fails)" % [_checks, _fails.size()])
		for f in _fails:
			print("  - " + f)
	quit(0 if _fails.is_empty() else 1)
