extends SceneTree
## NetBotController guard (23.11).
##
## Boots the real world, spawns the controller on the local hero and checks the
## follow/come/stay/attack FSM without a second process.
##
## Run: godot --headless --path . --script res://tests/net_bot_smoke.gd

const SEED := 424242

var _checks := 0
var _fails: Array[String] = []

func _init() -> void:
	Game.hero_stats = {"body": 12, "agility": 11, "mind": 9, "spirit": 8,
		"blade": 30, "bludgeon": 15, "pike": 10,
		"fire": 5, "water": 5, "air": 5, "earth": 5, "astral": 5,
		"weapon": "sword", "shield": true, "armor": "heavy"}
	Game.hero_class = "warrior"
	Game.hero_name = "BotSmoke"
	Game.hero_character_id = "human_m_war"
	Game.hero_race = "human"
	Game.map_seed = SEED
	Game.map_zone = "start"
	Game.map_sector = "s00"
	Game.loaded_slot = ""
	Game.pending_map_path = ""
	Game.net_map_race = ""
	call_deferred("_run")

func _check(ok: bool, what: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(what)
	print(("  OK  " if ok else "  FAIL") + " " + what)

func _run() -> void:
	await process_frame
	var err := change_scene_to_file("res://scenes/main.tscn")
	if err != OK:
		print("RESULT: FAIL net_bot_smoke (main.tscn did not open)")
		quit(1)
		return
	await create_timer(8.0).timeout
	var hero := Game.hero as Player
	_check(hero != null, "the hero exists")
	if hero == null:
		_finish()
		return
	var bot: NetBotController = NetBotController.new()
	bot.name = "NetBotController"
	root.add_child(bot)
	bot.setup(hero)
	_check(bot.mode == "follow", "the default mode is follow")

	var start := hero.global_position
	hero.global_position = start + Vector2(360, 0)
	hero.reset_physics_interpolation()
	await create_timer(2.0).timeout
	_check(hero.global_position.distance_to(start + Vector2(360, 0)) < 300.0,
		"follow closes the distance")

	bot.set_mode("stay")
	await create_timer(0.5).timeout
	_check(str(hero.state) == "idle", "stay stops the hero")

	bot.set_mode("attack")
	await create_timer(1.5).timeout
	_check(bot.mode == "attack", "attack mode is accepted")

	_finish()

func _finish() -> void:
	if _fails.is_empty():
		print("RESULT: OK net_bot_smoke (%d checks)" % _checks)
		quit(0)
	else:
		print("RESULT: FAIL net_bot_smoke (%d checks, %d failed)" % [_checks, _fails.size()])
		quit(1)
