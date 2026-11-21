extends SceneTree
##
## Two-process co-op integration test (22.11): the HOST starts alone with its
## saved (or new) hero, and only later the client joins the world that is
## already running. Checks, in order:
##
##   * the host plays with no second player and nothing blocks it;
##   * the client connects into a RUNNING world and receives its seed from the
##     session (no waiting in a lobby, no shared file);
##   * both heroes are on screen, monster proxies and snapshots work;
##   * the client's blow kills a monster on the host;
##   * death: no Game Over, respawn at the spawn point, items are lost;
##   * peace is the default, either side may declare war, and war is shared.
##
## The map is generated once by the shell and loaded by both processes, so the
## test does not race on the generator cache. Real play generates it locally on
## each machine from the same seed.
##
##   godot --headless --path . --script res://tests/net_coop_probe.gd -- --role host --port 7812
##   godot --headless --path . --script res://tests/net_coop_probe.gd -- --role client --port 7812

const SEED := 7777
const ZONE := "start"
const SECTOR := "s00"
const MAP_PATH := "user://maps/coop_test.alm"

var _role := "host"
var _port := 7812
var _checks := 0
var _fails: Array[String] = []
var _session: NetSession = null

func _init() -> void:
	var args := OS.get_cmdline_user_args()
	for i in range(args.size()):
		if args[i] == "--role" and i + 1 < args.size():
			_role = args[i + 1]
		elif args[i] == "--port" and i + 1 < args.size():
			_port = int(args[i + 1])
	call_deferred("_run")

func _check(ok: bool, what: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(what)
	print(("  OK  " if ok else "  FAIL") + " " + what)

func _hero_stats() -> Dictionary:
	return {"strength": 20, "dexterity": 20, "intelligence": 10,
		"vitality": 20, "spirit": 10, "luck": 5}

func _apply_world(seed_value: int, zone: String, world_seed: int, sector: String,
		race_hint: String) -> void:
	Game.map_seed = seed_value
	Game.map_zone = zone
	Game.world_seed = world_seed
	Game.map_sector = sector
	Game.net_map_race = race_hint
	Game.pending_map_path = MAP_PATH
	Game.startup_loading = false

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

func _run() -> void:
	await process_frame
	_session = NetSession.ensure()
	if _session == null:
		print("RESULT: FAIL net_coop_probe (no session node)")
		quit(1)
		return
	Game.hero_stats = _hero_stats()
	Game.hero_class = "warrior"
	Game.hero_gender = "male"
	Game.hero_name = "Host" if _role == "host" else "Guest"
	Game.hero_character_id = "human_m_war"
	Game.hero_race = "human"
	Game.loaded_slot = ""
	Game.startup_loading = false
	if _role == "host":
		await _run_host()
	else:
		await _run_client()
	if _session != null:
		_session.leave()
	if _fails.is_empty():
		print("RESULT: OK net_coop_probe (%d checks)" % _checks)
		quit(0)
	else:
		print("RESULT: FAIL net_coop_probe (%d checks, %d failed)" % [_checks, _fails.size()])
		quit(1)

# --- host: plays alone first, the guest comes later --------------------------

func _run_host() -> void:
	var err := _session.host(_port)
	_check(err == "", "host started")
	if err != "":
		return
	# The host does not wait for anybody: it builds its world at once.
	_apply_world(SEED, ZONE, 1, SECTOR, "human")
	# Emulates the panel: the world is remembered and published when a peer
	# arrives (nobody is connected yet, so this only stores it).
	_session.send_world_config(SEED, ZONE, 1, SECTOR, "human")
	await process_frame
	var scene_err := change_scene_to_file("res://scenes/main.tscn")
	_check(scene_err == OK, "host loaded the world alone")
	await create_timer(6.0).timeout
	_check(get_nodes_in_group("remote_hero").is_empty(),
		"host plays alone: no other hero yet")
	_check(NetGame.instance != null, "host: NetGame attached")
	_check(not Game.pvp_on(), "peace is the default")

	# The guest needs time to boot the same map and join.
	await create_timer(75.0).timeout
	_check(not get_nodes_in_group("remote_hero").is_empty(),
		"the guest joined the RUNNING world")
	_check(_session.pvp, "the guest's declaration of war reached the host")
	var cfg: Dictionary = NetGame.instance.hero_info() if NetGame.instance != null else {}
	_check(not cfg.is_empty(), "host: its hero info is buildable")
	_check(is_instance_valid(Game.hero), "host hero is alive on its own screen")

# --- client: joins a world that is already being played ----------------------

func _run_client() -> void:
	# Start late on purpose: the world must already be running when we connect.
	await create_timer(12.0).timeout
	var err := _session.join("127.0.0.1", _port)
	_check(err == "", "client join started")
	if err != "":
		return
	var connected := await _wait_signal(_session.connected_ok, 25.0)
	_check(connected, "client connected")
	if not connected:
		return
	# No lobby: the host publishes the world the moment the link is up.
	var cfg_ok := await _wait_signal(_session.world_config, 25.0)
	_check(cfg_ok, "client received the running world's config")
	if not cfg_ok:
		return
	_apply_world(SEED, ZONE, 1, SECTOR, "human")
	var scene_err := change_scene_to_file("res://scenes/main.tscn")
	_check(scene_err == OK, "client loaded the world")
	await create_timer(20.0).timeout
	_check(NetGame.instance != null, "client: NetGame attached")
	_check(get_nodes_in_group("remote_hero").size() == 1, "client: the host hero is on screen")
	var proxies: Dictionary = NetGame.instance._proxies if NetGame.instance != null else {}
	_check(proxies.size() > 0, "client: monster proxies exist (%d)" % proxies.size())
	var targets: Dictionary = NetGame.instance._targets if NetGame.instance != null else {}
	_check(targets.size() > 0, "client: snapshots are arriving (%d)" % targets.size())

	# --- a client blow must reach the host and come back as HP ---------------
	var victim: Enemy = null
	for e in Game.enemies:
		if e == null or not is_instance_valid(e):
			continue
		if not bool(e.get("net_proxy")):
			continue
		if not UnitDB.is_hostile(str(e.anim_set)):
			continue
		victim = e
		break
	_check(victim != null, "client: a hostile proxy to hit")
	if victim != null:
		var hp0 := victim.current_hp
		for _i in range(5):
			Game.deal_damage(victim, 20, "physical", "", Game.hero)
		await create_timer(4.0).timeout
		var gone := not is_instance_valid(victim) or str(victim.state) in ["dying", "corpse", "decay"]
		_check(gone or victim.current_hp < hp0,
			"client damage reached the host (hp %d -> %s)" % [hp0,
				"dead" if gone else str(victim.current_hp)])

	# --- damage addressed at this hero goes through the handler --------------
	var hero: Player = Game.hero as Player
	if hero != null and NetGame.instance != null:
		var before := hero.current_hp
		NetGame.instance._on_hero_hit(5)
		_check(hero.current_hp == maxi(0, before - 5),
			"hero damage from the host is applied locally (%d -> %d)" % [before, hero.current_hp])

	# --- peace by default, war on request (22.11) ----------------------------
	var remote: Node2D = null
	var group := get_nodes_in_group("remote_hero")
	if not group.is_empty():
		remote = group[0] as Node2D
	_check(remote != null, "client: the host's body is reachable")
	if remote != null:
		_check(not Game.pvp_on(), "peace is the default on the client too")
		_check(not Game.hostile_units().has(remote), "at peace the other player is not a target")
		_check(not Game.is_attackable(remote), "at peace the other player cannot be attacked")
		_session.set_pvp(true)
		await create_timer(0.5).timeout
		_check(Game.pvp_on(), "the client may declare war")
		_check(Game.hostile_units().has(remote), "at war the other player is a target")
		_check(Game.is_attackable(remote), "at war the other player can be attacked")
		var dealt := Game.deal_damage(remote, 12, "physical", "", hero)
		_check(dealt > 0, "a blow on the other hero is forwarded (%d)" % dealt)
		_session.set_pvp(false)
		await create_timer(0.3).timeout
		_check(not Game.is_attackable(remote), "peace again removes the target")
		# Leave the war ON: the host asserts that the declaration reached it.
		_session.set_pvp(true)
		await create_timer(0.3).timeout

	# --- death and rebirth (player's rule: no Game Over, items lost) ---------
	if hero != null:
		var main_node := current_scene
		var spawn := Vector2.ZERO
		if main_node != null and main_node.get("alm_map") != null:
			spawn = main_node.alm_map.call("get_spawn_pos")
		hero.add_item("Potion Small Healing")
		hero.take_damage(99999, null)
		await create_timer(0.8).timeout
		_check(Game.hero_dead, "death sets the dead flag")
		_check(main_node != null and main_node.get("_save_menu") == null,
			"no Game Over menu in co-op")
		await create_timer(11.5).timeout
		_check(not hero.is_dead and not Game.hero_dead, "the hero respawned")
		_check(hero.inventory.is_empty() and hero.equipped.is_empty(),
			"items and worn gear are lost on death")
		_check(hero.global_position.distance_to(spawn) < 96.0,
			"respawn happened at the map spawn point")
		_check(hero.current_hp == hero.max_hp, "respawn is at full health")
