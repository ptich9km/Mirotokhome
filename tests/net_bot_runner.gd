extends SceneTree
## Headless AI companion runner (23.11).
##
## The bot joins the host's world as a normal second client, drives its own
## Player with NetBotController and persists to a dedicated profile name.
## It is a real co-op peer, not a RemoteHero: the host sees it as another hero.
##
##   godot --headless --path . --script res://tests/net_bot_runner.gd -- --port 7812
##   godot --headless --path . --script res://tests/net_bot_runner.gd -- --port 7812 --name Kimi

const MAP_PATH := "user://maps/net_bot_runner.alm"

var _port := 7817
var _name := "Kimi"
var _session: NetSession = null
var _bot: NetBotController = null
var _done := false

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	for i in range(args.size()):
		if args[i] == "--port" and i + 1 < args.size():
			_port = int(args[i + 1])
		elif args[i] == "--name" and i + 1 < args.size():
			_name = args[i + 1]
	call_deferred("_run")

func _run() -> void:
	await process_frame
	_session = NetSession.ensure()
	if _session == null:
		print("RESULT: FAIL net_bot_runner (no session node)")
		quit(1)
		return
	_apply_profile()
	var err := _session.join("127.0.0.1", _port)
	if err != "":
		print("RESULT: FAIL net_bot_runner (%s)" % err)
		quit(1)
		return
	var connected := await _wait_signal(_session.connected_ok, 25.0)
	if not connected:
		print("RESULT: FAIL net_bot_runner (no connection)")
		quit(1)
		return
	var got_world := await _wait_signal(_session.world_config, 25.0)
	if not got_world:
		print("RESULT: FAIL net_bot_runner (no world config)")
		quit(1)
		return
	_apply_world()
	change_scene_to_file("res://scenes/main.tscn")
	await create_timer(20.0).timeout
	if NetGame.instance == null or Game.hero == null:
		print("RESULT: FAIL net_bot_runner (no NetGame/hero)")
		quit(1)
		return
	_bot = NetBotController.new()
	_bot.name = "NetBotController"
	root.add_child(_bot)
	_bot.setup(Game.hero as Player)
	_bot.set_mode("follow")
	print("RESULT: OK net_bot_runner (joined, follow mode)")
	_done = true

func _apply_profile() -> void:
	Game.hero_stats = {"body": 12, "agility": 12, "mind": 10, "spirit": 10,
		"blade": 25, "bludgeon": 10, "pike": 5,
		"fire": 5, "water": 5, "air": 5, "earth": 5, "astral": 5,
		"weapon": "sword", "shield": true, "armor": "heavy"}
	Game.hero_class = "warrior"
	Game.hero_gender = "male"
	Game.hero_name = _name
	Game.hero_character_id = "human_m_war"
	Game.hero_race = "human"
	Game.loaded_slot = ""
	Game.startup_loading = false
	Game.net_bot = true

func _apply_world() -> void:
	var w: Dictionary = _session.world
	Game.map_seed = int(w.get("seed", 0))
	Game.map_zone = str(w.get("zone", "start"))
	Game.world_seed = int(w.get("world_seed", 0))
	Game.map_sector = str(w.get("sector", ""))
	Game.net_map_race = str(w.get("race", ""))
	Game.pending_map_path = MAP_PATH
	Game.clear_load_position()
	Game.clear_hero_save()
	var bus := get_node_or_null("/root/WorldBus")
	if bus != null and bus.state != null:
		bus.state.reset_for_new_game()

func _wait_signal(sig: Signal, seconds: float) -> bool:
	var t := create_timer(seconds)
	var fired := {"ok": false}
	var cb := func(_a = null, _b = null, _c = null, _d = null, _e = null) -> void:
		fired["ok"] = true
	sig.connect(cb, CONNECT_ONE_SHOT)
	while not fired["ok"]:
		await process_frame
		if t.time_left <= 0.0:
			break
	return bool(fired["ok"])

func _finalize() -> void:
	if _session != null:
		_session.leave()
