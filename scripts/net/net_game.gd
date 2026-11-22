class_name NetGame
extends Node
## In-game network orchestration for the two-player co-op (21.11).
##
## The node is created by `game.gd` as a child of Main when a NetSession is
## online, and removed with the scene. It owns everything that is "shared":
##   * the other player's body (RemoteHero) and its state feed;
##   * the monster registry and the host -> client snapshots;
##   * damage forwarding from the client to the host;
##   * death and rebirth at the map spawn point (no Game Over, items are lost);
##   * loot replication.
##
## Division of ownership, so there is exactly one authority per thing:
##   hero position and HP  -> the peer that drives that hero;
##   monster AI and HP     -> the host;
##   loot rolls            -> the host (the client receives the rolled items).

static var instance: NetGame = null

## Hero state is small and needs smoothness: 12 Hz plus interpolation.
const STATE_HZ := 12.0
## Monster snapshots: 10 Hz. On LAN this is ~200 enemies x ~12 B = ~24 KB/s.
const SNAP_HZ := 10.0
## Respawn delay. Death costs the hero's inventory and equipment (player's
## rule 21.11: "only items are lost"), so it must cost time too.
const RESPAWN_SECONDS := 10.0

var main: Node2D = null
var player: Node2D = null
var remote: RemoteHero = null
var session: NetSession = null
var is_host := false

## host: net_id -> Enemy it simulates.
var _enemies: Dictionary = {}
## client: net_id -> Enemy proxy that only plays what the host sends.
var _proxies: Dictionary = {}
## client: net_id -> position to interpolate towards.
var _targets: Dictionary = {}

var _state_acc := 0.0
var _snap_acc := 0.0
var _join_acc := 0.0
var _spawn_serial := 0
var _profile_acc := 0.0
var _respawning := false
var _respawn_left := 0.0
var _last_dir := Vector2.DOWN
var _applied_state := false

## Stable id of a monster that comes from the map file. Both peers compute the
## same string from the same record, so no id table has to travel.
static func map_enemy_key(cell: Vector2i, set_name: String) -> String:
	return "m%s" % [str(cell.x) + "_" + str(cell.y) + "_" + set_name]

func attach(main_node: Node2D) -> void:
	session = NetSession.active()
	if session == null:
		return
	instance = self
	main = main_node
	player = Game.hero
	is_host = session.is_host()
	name = "NetGame"
	_connect_session()
	session.send_hero_join(hero_info())
	# The other side may have joined while this peer was still on the loading
	# screen (its RPC arrived, but NetGame did not exist). NetSession caches it.
	for peer in session.peer_heroes.keys():
		_spawn_remote(int(peer), session.peer_heroes[peer])

func _exit_tree() -> void:
	if instance == self:
		instance = null

func _connect_session() -> void:
	session.hero_joined.connect(_on_hero_joined)
	session.hero_state.connect(_on_hero_state)
	session.hero_alive.connect(_on_hero_alive)
	session.enemy_snap.connect(_on_enemy_snap)
	session.enemy_spawn.connect(_on_enemy_spawn)
	session.enemy_died.connect(_on_enemy_died)
	session.kill_event.connect(_on_kill_event)
	session.hit_enemy.connect(_on_hit_enemy)
	session.hero_hit.connect(_on_hero_hit)
	session.loot_spawn.connect(_on_loot_spawn)
	session.loot_taken.connect(_on_loot_taken)
	session.server_lost.connect(_on_server_lost)
	session.peer_left.connect(_on_peer_left)
	session.pvp_changed.connect(_on_pvp_changed)

func _on_pvp_changed(on: bool) -> void:
	if remote != null and is_instance_valid(remote):
		remote.set_hostile(on)

func _on_server_lost() -> void:
	_feed(Loc.t("ui.net.lost"))

func _on_peer_left(_id: int) -> void:
	_feed(Loc.t("ui.net.peer_left"))

## What the other player needs to draw this hero and to calculate damage on it.
func hero_info() -> Dictionary:
	if player == null or not is_instance_valid(player):
		return {}
	return {
		"peer": multiplayer.get_unique_id(),
		"name": str(Game.hero_name),
		"anim_set": str(player.call("anim_set_name")),
		"max_hp": int(player.get("max_hp")),
		"max_mana": int(player.get("max_mana")),
		"hp": int(player.get("current_hp")),
		"mana": int(player.get("current_mana")),
		"attack": int(player.call("get_attack")),
		"defense": int(player.call("get_defense")),
		"absorption": int(player.call("get_absorption")),
		"protection": {
			"Fire": int(player.call("get_protection_fire")),
			"Water": int(player.call("get_protection_water")),
			"Air": int(player.call("get_protection_air")),
			"Earth": int(player.call("get_protection_earth")),
			"Astral": int(player.call("get_protection_astral")),
		},
	}

# --- the other player's body ------------------------------------------------

func _on_hero_joined(peer: int, info: Dictionary) -> void:
	if peer == multiplayer.get_unique_id():
		return
	session.peer_heroes[peer] = info
	_spawn_remote(peer, info)
	# A player may join a world that is already running (22.11): everything the
	# host spawned at runtime before this moment must be re-announced, or those
	# monsters stay invisible on the newcomer's screen.
	if is_host:
		for id in _enemies.keys():
			var e: Enemy = _enemies[id]
			if e == null or not is_instance_valid(e):
				continue
			if not str(id).begins_with("r"):
				continue
			session.send_enemy_spawn({
				"id": str(id),
				"set": e.anim_set,
				"pos": e.global_position,
				"hp": e.max_hp,
				"damage": e.damage,
				"faction": e.faction,
				"outpost": e.outpost_id,
				"assault": e.assault_to,
			})

func _spawn_remote(peer: int, info: Dictionary) -> void:
	if remote != null and is_instance_valid(remote):
		return
	if info.is_empty() or main == null:
		return
	remote = RemoteHero.new()
	remote.name = "RemoteHero"
	main.add_child(remote)
	remote.setup(info)
	remote.owner_peer = peer
	remote.global_position = _spawn_point()
	remote.reset_physics_interpolation()
	remote.set_hostile(session.pvp)

func _spawn_point() -> Vector2:
	if main != null and main.get("alm_map") != null:
		var map: Node = main.alm_map
		if map.has_method("get_cities"):
			var cities: Array = map.call("get_cities")
			if not cities.is_empty():
				# Spawn the joining player in the first city, not at the map
				# spawn point: the host already lives there, and a newcomer
				# walking in from the wilderness reads as a bug.
				var c: Dictionary = cities[0]
				var pos := Vector2(float(c.get("x", 0)) * 32.0 + 16.0, float(c.get("y", 0)) * 32.0 + 16.0)
				if map.has_method("is_walkable_world") and map.call("is_walkable_world", pos):
					return pos
		if map.has_method("get_spawn_pos"):
			return map.call("get_spawn_pos")
	return player.global_position if is_instance_valid(player) else Vector2.ZERO

func _on_hero_state(peer: int, pos: Vector2, anim: int, dir: Vector2, hp: int, mana: int) -> void:
	if peer == multiplayer.get_unique_id():
		return
	if remote == null or not is_instance_valid(remote):
		return
	remote.apply_state(pos, anim, dir, hp, mana)

func _on_hero_alive(peer: int, alive: bool, pos: Vector2, hp: int) -> void:
	if peer == multiplayer.get_unique_id():
		return
	if remote == null or not is_instance_valid(remote):
		return
	if alive:
		remote.global_position = pos
		remote.current_hp = maxi(1, hp)
		remote.reset_death_state()
		remote.reset_physics_interpolation()
	else:
		remote.current_hp = 0
		remote._set_alive(false)

# --- per-frame --------------------------------------------------------------

func _process(delta: float) -> void:
	if session == null or not session.is_online():
		return
	if player == null or not is_instance_valid(player):
		return
	# Until the other hero appears, keep repeating the join: the first message
	# may have arrived while this peer was still on the loading screen, and the
	# cache is only read once per attach.
	if remote == null:
		_join_acc += delta
		if _join_acc >= 1.0:
			_join_acc = 0.0
			session.send_hero_join(hero_info())
			for peer in session.peer_heroes.keys():
				_spawn_remote(int(peer), session.peer_heroes[peer])
	_push_own_state(delta)
	if is_host:
		_push_snapshot(delta)
	else:
		_interpolate(delta)
	_tick_respawn(delta)
	# The character is the persistent part of a co-op session (22.11): keep the
	# local file close to the live hero, so a crash costs a minute, not an evening.
	_profile_acc += delta
	if _profile_acc >= 60.0:
		_profile_acc = 0.0
		save_profile()

## Write this player's character to its own disk file.
func save_profile() -> void:
	if player == null or not is_instance_valid(player):
		return
	if session == null or not session.is_online():
		return
	# The headless companion is disposable: it must not claim a human profile slot.
	if Game.net_bot:
		return
	NetProfile.upsert(NetProfile.capture(player))

func _push_own_state(delta: float) -> void:
	_state_acc += delta
	if _state_acc < 1.0 / STATE_HZ:
		return
	_state_acc = 0.0
	if not _applied_state:
		_applied_state = true
	var vel: Vector2 = player.get("velocity")
	if vel.length_squared() > 4.0:
		_last_dir = vel.normalized()
	var anim := UnitAnim.Anim.IDLE
	if bool(player.get("is_dead")):
		anim = UnitAnim.Anim.DYING
	elif str(player.get("state")) == "attack":
		anim = UnitAnim.Anim.ATTACK
	elif vel.length_squared() > 4.0:
		anim = UnitAnim.Anim.MOVE
	session.send_hero_state(player.global_position, anim, _last_dir,
		int(player.get("current_hp")), int(player.get("current_mana")))

# --- monsters: host side ----------------------------------------------------

## Called by game.gd for every monster spawned from the map file.
func register_map_enemy(e: Enemy, key: String) -> void:
	if session == null:
		return
	e.net_id = key
	if is_host:
		_enemies[key] = e
		if not e.died.is_connected(_on_enemy_died_host):
			e.died.connect(_on_enemy_died_host)
	else:
		e.net_proxy = true
		_proxies[key] = e

## Called by Game.make_gray (ambient respawn, raids, events): a runtime monster
## only exists on the host, the client learns about it by message.
func note_runtime_spawn(e: Enemy) -> void:
	if session == null or not is_host:
		return
	_spawn_serial += 1
	var key := "r%d" % _spawn_serial
	e.net_id = key
	_enemies[key] = e
	if not e.died.is_connected(_on_enemy_died_host):
		e.died.connect(_on_enemy_died_host)
	session.send_enemy_spawn({
		"id": key,
		"set": e.anim_set,
		"pos": e.global_position,
		"hp": e.max_hp,
		"damage": e.damage,
		"faction": e.faction,
		"outpost": e.outpost_id,
		"assault": e.assault_to,
	})

func _on_enemy_died_host(unit: Enemy) -> void:
	if session == null or not is_instance_valid(unit):
		return
	var key := str(unit.net_id)
	_enemies.erase(key)
	session.send_enemy_died(key, unit.anim_set, unit.global_position)
	# Quests and the world feed of the client: both peers should "see" the kill.
	session.send_kill_event(unit.anim_set, str(unit.quest_id))

func _push_snapshot(delta: float) -> void:
	_snap_acc += delta
	if _snap_acc < 1.0 / SNAP_HZ:
		return
	_snap_acc = 0.0
	var alive: Array = []
	for key in _enemies.keys():
		var e: Enemy = _enemies[key]
		if e == null or not is_instance_valid(e):
			_enemies.erase(key)
			continue
		if e.state == "corpse" or e.state == "decay":
			continue
		alive.append(e)
	# Unreliable packets above the ENet MTU are dropped, so the state travels in
	# small chunks. Entries are independent, so unordered delivery is fine.
	const CHUNK := 16
	var i := 0
	while i < alive.size():
		var part: Array = alive.slice(i, mini(i + CHUNK, alive.size()))
		session.send_enemy_snap(encode_snapshot(part))
		i += CHUNK

## Monster snapshot codec. Kept static and free of nodes so the smoke test can
## verify the wire format without two processes.
static func encode_snapshot(list: Array) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.put_u16(clampi(list.size(), 0, 65535))
	for e in list:
		var idb := str(e.net_id).to_utf8_buffer()
		buf.put_u8(clampi(idb.size(), 0, 255))
		buf.put_data(idb)
		buf.put_float(e.global_position.x)
		buf.put_float(e.global_position.y)
		buf.put_16(clampi(e.current_hp, 0, 32767))
		var anim := 0
		if e.state == "dying":
			anim = 3
		elif e.state == "attack":
			anim = 2
		elif e.velocity.length_squared() > 4.0:
			anim = 1
		buf.put_u8(anim)
		buf.put_float(e.velocity.x)
		buf.put_float(e.velocity.y)
	return buf.data_array

static func decode_snapshot(bytes: PackedByteArray) -> Array:
	var out: Array = []
	if bytes.is_empty():
		return out
	var buf := StreamPeerBuffer.new()
	buf.data_array = bytes
	var count := buf.get_u16()
	for _i in range(count):
		var idlen := buf.get_u8()
		var chunk: Array = buf.get_data(idlen)
		var id := (chunk[1] as PackedByteArray).get_string_from_utf8()
		var x := buf.get_float()
		var y := buf.get_float()
		var hp := buf.get_16()
		var anim := buf.get_u8()
		var vx := buf.get_float()
		var vy := buf.get_float()
		out.append({"id": id, "pos": Vector2(x, y), "hp": hp, "anim": anim,
			"vel": Vector2(vx, vy)})
	return out

# --- monsters: client side --------------------------------------------------

func _on_enemy_snap(bytes: PackedByteArray) -> void:
	if bytes.is_empty():
		return
	for entry in decode_snapshot(bytes):
		var id := str(entry["id"])
		var p: Enemy = _proxies.get(id)
		if p == null or not is_instance_valid(p):
			continue
		var pos: Vector2 = entry["pos"]
		_targets[id] = pos
		p.net_apply_state(pos, int(entry["hp"]), int(entry["anim"]), entry["vel"])

func _on_enemy_spawn(info: Dictionary) -> void:
	if session == null or is_host:
		return
	var set_name := str(info.get("set", ""))
	if set_name == "" or not UnitDB.has(set_name):
		return
	var beast := Game.make_gray(set_name, info.get("pos", Vector2.ZERO), main)
	if beast == null:
		return
	beast.max_hp = maxi(1, int(info.get("hp", beast.max_hp)))
	beast.current_hp = beast.max_hp
	beast.damage = maxi(0, int(info.get("damage", beast.damage)))
	beast.faction = str(info.get("faction", ""))
	beast.outpost_id = str(info.get("outpost", ""))
	var assault: Variant = info.get("assault", Vector2.INF)
	if assault is Vector2 and assault != Vector2.INF:
		beast.assault_to = assault
	beast.net_proxy = true
	beast.net_id = str(info.get("id", ""))
	_proxies[beast.net_id] = beast

func _on_enemy_died(net_id: String, _set_name: String, _pos: Vector2) -> void:
	var p: Enemy = _proxies.get(net_id)
	_proxies.erase(net_id)
	_targets.erase(net_id)
	if p != null and is_instance_valid(p):
		p.net_play_death()

func _on_kill_event(set_name: String, quest_id: String) -> void:
	var qs := main.get_node_or_null("QuestSystem") if main != null else null
	if qs != null and qs.has_method("notify_killed"):
		qs.call("notify_killed", set_name, quest_id)

func _interpolate(delta: float) -> void:
	var t := minf(1.0, 18.0 * delta)
	for id in _targets.keys():
		var p: Enemy = _proxies.get(id)
		if p == null or not is_instance_valid(p):
			_targets.erase(id)
			continue
		p.global_position = p.global_position.lerp(_targets[id], t)

# --- damage ----------------------------------------------------------------

## Client -> host: a proxy monster took a blow. Returns true when the damage
## was forwarded, so `Game.deal_damage` does not apply it a second time here.
func forward_damage(target: Node2D, dmg: int, kind: String, sphere: String) -> bool:
	if session == null or is_host or dmg <= 0:
		return false
	if not target.has_method("take_damage"):
		return false
	var key := str(target.get("net_id"))
	if key == "" or not _proxies.has(key):
		return false
	session.send_hit_enemy(key, dmg, kind, sphere)
	# Local feedback only: the HP itself comes back in snapshots.
	DamageNumber.show_at(target.global_position, dmg, "damage")
	SpellVFX.hit_flash(target)
	return true

func _on_hit_enemy(net_id: String, dmg: int, _kind: String, _sphere: String) -> void:
	if not is_host:
		return
	var e: Enemy = _enemies.get(net_id)
	if e == null or not is_instance_valid(e):
		return
	if e.state == "dying" or e.state == "corpse" or e.state == "decay":
		return
	e.take_damage(dmg, player)

## Host -> client: a monster hit the client's hero.
func _on_hero_hit(dmg: int) -> void:
	if player == null or not is_instance_valid(player):
		return
	if bool(player.get("is_dead")):
		return
	player.call("take_damage", dmg, null)
	if bool(player.get("is_dead")):
		_on_local_hero_died()

# --- loot -------------------------------------------------------------------

## Called from enemy.gd right after a drop is rolled, so the client gets the
## very same items instead of rolling its own.
func replicate_loot(items: Array, pos: Vector2, potion_size: String) -> void:
	if session == null or not is_host:
		return
	session.send_loot_spawn(items.duplicate(true), pos, potion_size)

func _on_loot_spawn(items: Array, pos: Vector2, potion: String) -> void:
	if main == null:
		return
	var drop: LootDrop = load("res://scripts/loot_drop.gd").new()
	drop.items = items
	drop.potion_size = potion
	drop.global_position = pos
	main.add_child(drop)

func _on_loot_taken(pos: Vector2) -> void:
	on_loot_taken(pos)

## Local player picked up a drop: remove the matching drop on the other peer.
func report_loot_taken(pos: Vector2) -> void:
	if session == null:
		return
	session.send_loot_taken(pos)

func on_loot_taken(pos: Vector2) -> void:
	if main == null:
		return
	for child in main.get_children():
		if child is LootDrop and child.global_position.distance_to(pos) < 1.0:
			child.queue_free()
			return

# --- death and rebirth ------------------------------------------------------

## Death in co-op never ends the game: the hero's body is reset at the map
## spawn point after RESPAWN_SECONDS, and the inventory plus the worn gear are
## gone (player's rule 21.11). Level, skills, spells and gold stay.
func on_local_hero_died() -> void:
	if _respawning:
		return
	_respawning = true
	_respawn_left = RESPAWN_SECONDS
	Game.hero_dead = true
	session.send_hero_alive(false, player.global_position, 0)

func _on_local_hero_died() -> void:
	on_local_hero_died()

func _tick_respawn(delta: float) -> void:
	if not _respawning:
		return
	_respawn_left -= delta
	if _respawn_left > 0.0:
		return
	_respawn_local()

func _respawn_local() -> void:
	_respawning = false
	if player == null or not is_instance_valid(player):
		return
	var spawn_pos := _spawn_point()
	player.call("reset_death_state")
	player.inventory.clear()
	player.equipped.clear()
	player.set("weapon", "")
	player.set("armor_kind", "")
	player.set("two_handed", false)
	player.set("has_shield", false)
	player.call("refresh_animation")
	player.global_position = spawn_pos
	player.reset_physics_interpolation()
	player.set("current_hp", int(player.get("max_hp")))
	player.set("current_mana", int(player.get("max_mana")))
	Game.hero_dead = false
	Game.player_target = spawn_pos
	session.send_hero_alive(true, spawn_pos, int(player.get("current_hp")))
	# Death cost the inventory and the worn gear — the stored character must
	# agree, otherwise the next session would resurrect the lost items.
	save_profile()
	_feed(Loc.t("ui.net.respawned"))
	if main != null and main.get("ui") != null and main.ui.has_method("show_hint"):
		main.ui.call("show_hint", Loc.t("ui.net.respawn_hint"))

func _feed(text: String) -> void:
	if main != null and main.has_method("world_feed"):
		main.call("world_feed", text)
