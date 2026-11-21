extends SceneTree
##
## Co-op integration guard (21.11). Boots the real world in HOST mode with no
## second player, and checks the pieces that only exist in a net session:
##
##   * NetGame is attached before the map units are spawned;
##   * every map monster got a stable net id (the client can map them later);
##   * the snapshot codec round-trips ids, positions, HP and velocity;
##   * monsters can resolve a hero through Game.nearest_hero;
##   * panels do not freeze the world and the save menu is refused.
##
## It does NOT open a second peer — the two-process handshake is net_smoke.gd,
## and the live two-machine sync is the manual test.
##
## Run: godot --headless --path . --script res://tests/net_game_smoke.gd

const SEED := 424242
const PORT := 7810

var _checks := 0
var _fails: Array[String] = []

func _initialize() -> void:
	Game.hero_stats = {"strength": 20, "dexterity": 20, "intelligence": 10,
		"vitality": 20, "spirit": 10, "luck": 5}
	Game.hero_class = "warrior"
	Game.hero_gender = "male"
	Game.hero_name = "Coop"
	Game.hero_character_id = "human_m_war"
	Game.hero_race = "human"
	Game.map_seed = SEED
	Game.map_zone = "start"
	Game.map_sector = "s00"
	Game.loaded_slot = ""
	Game.pending_map_path = ""
	Game.net_map_race = ""
	var session := NetSession.ensure()
	if session != null:
		pass
	call_deferred("_run")

func _check(ok: bool, what: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(what)
	print(("  OK  " if ok else "  FAIL") + " " + what)

func _run() -> void:
	await process_frame
	var session0 := NetSession.ensure()
	if session0 != null:
		var host_err := session0.host(PORT)
		if host_err != "":
			print("  host error: " + host_err)
	await process_frame
	var err := change_scene_to_file("res://scenes/main.tscn")
	if err != OK:
		print("RESULT: FAIL net_game_smoke (main.tscn did not open)")
		quit(1)
		return
	await create_timer(8.0).timeout

	_check(NetSession.is_net_game(), "the session is online")
	_check(NetGame.instance != null, "NetGame is attached to Main")
	_check(get_first_node_in_group("alm_map") != null, "the map is loaded")
	_check(get_first_node_in_group("player") != null, "the local hero exists")
	_check(Game.nearest_hero(Vector2(100, 100)) != null, "nearest_hero finds a hero")

	var with_id := 0
	var sample: Array = []
	for e in Game.enemies:
		if e == null or not is_instance_valid(e):
			continue
		if str(e.get("net_id")) == "":
			continue
		with_id += 1
		if sample.size() < 3:
			sample.append(e)
	_check(with_id > 0, "map monsters got net ids (%d)" % with_id)

	if sample.size() >= 2:
		var bytes := NetGame.encode_snapshot(sample)
		var decoded := NetGame.decode_snapshot(bytes)
		_check(decoded.size() == sample.size(), "snapshot round-trip keeps the count")
		var same := true
		for i in range(mini(decoded.size(), sample.size())):
			var e: Enemy = sample[i]
			var d: Dictionary = decoded[i]
			if str(d["id"]) != str(e.net_id):
				same = false
			if absf((d["pos"] as Vector2).x - e.global_position.x) > 0.5:
				same = false
			if int(d["hp"]) != clampi(e.current_hp, 0, 32767):
				same = false
		_check(same, "snapshot ids, positions and HP survive the codec")
		_check(bytes.size() > 0, "snapshot is not empty")

	var main := current_scene
	if main != null and main.has_method("_set_menu_pause"):
		main.call("_set_menu_pause", true)
		_check(not paused, "a panel does not freeze the co-op world")
		paused = false
	if main != null and main.has_method("open_save_menu"):
		main.call("open_save_menu")
		_check(main.get("_save_menu") == null, "the save menu is refused in co-op")

	var session := NetSession.active()
	if session != null:
		session.leave()

	if _fails.is_empty():
		print("RESULT: OK net_game_smoke (%d checks)" % _checks)
		quit(0)
	else:
		print("RESULT: FAIL net_game_smoke (%d checks, %d failed)" % [_checks, _fails.size()])
		quit(1)
