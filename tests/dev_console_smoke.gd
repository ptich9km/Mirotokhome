extends SceneTree
## Dev console guard (23.11).
##
## Boots the real world, opens the console with ~ and checks that:
##   * the console consumes game keys while open (B/I/W/M/Space/1..9 do nothing);
##   * Esc closes only the console and does not open the save menu;
##   * whitelisted commands run and unknown commands are rejected;
##   * buff synchronises live Player fields with Game.hero_stats;
##   * the panel fits the reference resolutions.
##
## Run: godot --headless --path . --script res://tests/dev_console_smoke.gd

const SEED := 424242

var _checks := 0
var _fails: Array[String] = []

func _init() -> void:
	Game.hero_stats = {"body": 12, "agility": 11, "mind": 9, "spirit": 8,
		"blade": 30, "bludgeon": 15, "pike": 10,
		"fire": 5, "water": 5, "air": 5, "earth": 5, "astral": 5,
		"weapon": "sword", "shield": true, "armor": "heavy"}
	Game.hero_class = "warrior"
	Game.hero_name = "Console"
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

func _press_key(keycode: int) -> void:
	var ev := InputEventKey.new()
	ev.keycode = keycode
	ev.pressed = true
	Input.parse_input_event(ev)

func _run() -> void:
	await process_frame
	var err := change_scene_to_file("res://scenes/main.tscn")
	if err != OK:
		print("RESULT: FAIL dev_console_smoke (main.tscn did not open)")
		quit(1)
		return
	await create_timer(8.0).timeout
	var main := current_scene
	_check(main != null, "the game scene is running")
	if main == null:
		_finish()
		return
	var ui := main.get("ui") as CanvasLayer
	var console := ui.get_node_or_null("DevConsole") as DevConsole
	_check(console != null, "the console is created under UI")
	if console == null:
		_finish()
		return
	_check(not console.visible, "the console starts hidden")
	_check(not paused, "the console does not pause the world")

	_press_key(KEY_QUOTELEFT)
	await process_frame
	_check(console.visible, "~ opens the console")
	_check(console.focus_requested, "the command line requests focus")
	_check(not paused, "opening the console does not pause the world")
	_check(console._root != null and console._root.visible, "the console root is visible")

	# While the console is open, game hotkeys must not fire.
	var paused_before := paused
	_press_key(KEY_B)
	_press_key(KEY_I)
	_press_key(KEY_W)
	_press_key(KEY_M)
	_press_key(KEY_SPACE)
	_press_key(KEY_1)
	await process_frame
	_check(not paused and paused == paused_before, "game keys do not toggle pause")
	_check(main.get("_save_menu") == null, "Esc-key game panels stay closed")

	var hero := Game.hero as Player
	_check(hero != null, "the hero exists")
	if hero != null:
		var body_before := hero.body
		var blade_before := hero.blade_skill
		var result := console.execute("buff 3")
		_check(bool(result.get("ok", false)), "buff executes")
		_check(hero.body == mini(100000, body_before * 3), "buff raises the live body stat")
		_check(int(Game.hero_stats.get("body", 0)) == hero.body, "buff syncs Game.hero_stats")
		_check(hero.blade_skill == mini(200, blade_before * 3), "buff raises combat skills")
		_check(hero.current_hp == hero.max_hp, "buff refills HP")
		_check(hero.current_mana == hero.max_mana, "buff refills mana")
		var bad := console.execute("give No Such Item")
		_check(not bool(bad.get("ok", false)), "unknown item is rejected")
		_check(not hero.inventory.has("No Such Item"), "rejected item is not added")
		var kimi := console.execute("kimi follow")
		_check(bool(kimi.get("ok", false)), "kimi follow works in single-player")
		var bot := main.get_node_or_null("LocalBotController") as NetBotController
		_check(bot != null and bot.mode == "follow", "the local bot controller is created")
		var kimi_bad := console.execute("kimi dance")
		_check(not bool(kimi_bad.get("ok", false)), "unknown kimi order is rejected")

	_press_key(KEY_ESCAPE)
	await process_frame
	_check(not console.visible, "Esc closes the console")
	_check(main.get("_save_menu") == null, "the save menu is not opened by console Esc")

	# The panel must fit the reference resolutions. We verify the anchor math:
	# bottom-wide panel with 16px side margins and 286px height from the bottom.
	var panel := console.get_node("Root/Panel") as Control
	for size in [Vector2i(1280, 800), Vector2i(1280, 600)]:
		var top := float(size.y) + panel.offset_top
		var bottom := float(size.y) + panel.offset_bottom
		_check(panel.offset_left >= 0.0 and panel.offset_right <= 0.0 \
			and top >= 0.0 and bottom <= float(size.y) \
			and (bottom - top) <= float(size.y),
			"the console fits %dx%d" % [size.x, size.y])

	_finish()

func _finish() -> void:
	if _fails.is_empty():
		print("RESULT: OK dev_console_smoke (%d checks)" % _checks)
		quit(0)
	else:
		print("RESULT: FAIL dev_console_smoke (%d checks, %d failed)" % [_checks, _fails.size()])
		quit(1)
