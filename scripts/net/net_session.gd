class_name NetSession
extends Node
## Network session of a two-player co-op game (21.11).
##
## The node lives on the scene tree ROOT under the fixed name "NetSession",
## so its path is /root/NetSession on BOTH peers - RPC routing needs identical
## paths. It is created by NetPanel (from the main menu) and survives scene
## changes, so the connection outlives the menu -> character select -> world
## transitions.
##
## TRANSPORT. Godot's high-level ENet (UDP). The player asked for "TCP/IP":
## the address part is right, the protocol is not - ENet is UDP with its own
## reliability and ordering layers, which is what an action game needs. TCP
## streams would stall every snapshot behind one lost packet.
##
## AUTHORITY MODEL (deliberately simple, because it is a family co-op):
##   * each peer simulates its OWN hero and sends its state to the other side;
##   * the HOST simulates every monster and every monster hit. The client's
##     monsters are visual proxies: their AI is off, positions and HP come
##     from the host in snapshots;
##   * the client's melee/magic against a proxy is forwarded to the host as
##     "this enemy takes N damage" - the host is the one who kills it;
##   * loot is generated on the host and replicated as a visual: each peer
##     collects its own copy (co-op with a child: nobody fights over gold).
##
## This node only moves messages. All game decisions live in NetGame.

signal connected_ok
signal peer_joined(id: int)
signal peer_left(id: int)
signal connect_failed
signal server_lost
signal hello_received(info: Dictionary)
signal world_config(seed_value: int, zone: String, world_seed: int, sector: String, race_hint: String)
signal hero_joined(peer: int, info: Dictionary)
signal hero_state(peer: int, pos: Vector2, anim: int, dir: Vector2, hp: int, mana: int)
signal enemy_snap(bytes: PackedByteArray)
signal enemy_spawn(info: Dictionary)
signal enemy_died(net_id: String, set_name: String, pos: Vector2)
signal kill_event(set_name: String, quest_id: String)
signal hit_enemy(net_id: String, dmg: int, kind: String, sphere: String)
signal hero_hit(dmg: int)
signal hero_alive(peer: int, alive: bool, pos: Vector2, hp: int)
signal loot_spawn(items: Array, pos: Vector2, potion: String)
signal loot_taken(pos: Vector2)
signal pvp_changed(on: bool)
## A deterministic companion order (23.11). The bot is a normal co-op peer;
## this message only tells its AI which high-level order to execute.
signal bot_command(command: String)

const DEFAULT_PORT := 7777
const BOT_ORDERS := ["follow", "come", "stay", "attack"]
const MAX_PEERS := 2
const NODE_NAME := "NetSession"

static var instance: NetSession = null

var role: String = "offline"        # offline | host | client
var port: int = DEFAULT_PORT
var joined_peers: Array[int] = []   # for the host: connected client ids
## Last hero_join message per peer. The other side may still be on the loading
## screen when it arrives, so NetGame reads this cache on attach.
var peer_heroes: Dictionary = {}
## Last world config from the host. The client may still be in the menu when the
## host presses "Start", so the message is remembered, not only emitted.
var world: Dictionary = {}
## War between the players (22.11). Peace by default; ANY player may declare war
## and it applies to both at once. Lives only for the session.
var pvp := false
var lost_reason: String = ""

## Peer id of the other player, or 0 when nobody is connected.
func other_peer() -> int:
	if role == "host":
		return joined_peers[0] if not joined_peers.is_empty() else 0
	if role == "client":
		return 1
	return 0

func is_online() -> bool:
	return role == "host" or role == "client"

func is_host() -> bool:
	return role == "host"

func is_client() -> bool:
	return role == "client"

## Create (or reuse) the root node. Called before any scene that needs it.
static func ensure() -> NetSession:
	if instance != null and is_instance_valid(instance):
		return instance
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return null
	var node := NetSession.new()
	node.name = NODE_NAME
	tree.root.add_child(node)
	instance = node
	return node

## Session of the running game, or null when the game is single-player.
static func active() -> NetSession:
	if instance != null and is_instance_valid(instance) and instance.is_online():
		return instance
	return null

static func is_net_game() -> bool:
	return active() != null

func _ready() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_lost)

# --- starting a session -------------------------------------------------------

func host(host_port: int = DEFAULT_PORT, player_name: String = "") -> String:
	if multiplayer == null:
		return Loc.f("ui.net.error_host", ["not in tree"])
	leave()
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(host_port, MAX_PEERS)
	if err != OK:
		return Loc.f("ui.net.error_host", [str(err)])
	multiplayer.multiplayer_peer = peer
	role = "host"
	port = host_port
	lost_reason = ""
	return ""

func join(ip: String, host_port: int = DEFAULT_PORT) -> String:
	if multiplayer == null:
		return Loc.f("ui.net.error_join", ["not in tree"])
	leave()
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(ip.strip_edges(), host_port)
	if err != OK:
		return Loc.f("ui.net.error_join", [str(err)])
	multiplayer.multiplayer_peer = peer
	role = "client"
	port = host_port
	lost_reason = ""
	return ""

func leave() -> void:
	joined_peers.clear()
	peer_heroes.clear()
	world.clear()
	_apply_pvp(false)
	role = "offline"
	if multiplayer == null:
		return
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()

func _on_peer_connected(id: int) -> void:
	if role != "host":
		return
	if not joined_peers.has(id):
		joined_peers.append(id)
	# A new session starts at peace (player's rule 22.11).
	_apply_pvp(false)
	# The world may already be running: a late player must receive it at once.
	if not world.is_empty():
		world_config_rpc.rpc_id(id, int(world.get("seed", 0)), str(world.get("zone", "")),
			int(world.get("world_seed", 0)), str(world.get("sector", "")),
			str(world.get("race", "")))
	peer_joined.emit(id)

func _on_peer_disconnected(id: int) -> void:
	joined_peers.erase(id)
	peer_left.emit(id)

func _on_connected() -> void:
	if role != "client":
		return
	_apply_pvp(false)
	hello.rpc_id(1, {"name": str(Game.hero_name)})
	connected_ok.emit()

func _on_connection_failed() -> void:
	role = "offline"
	connect_failed.emit()

func _on_server_lost() -> void:
	if role != "client":
		return
	role = "offline"
	lost_reason = "server_lost"
	server_lost.emit()

# --- handshake ----------------------------------------------------------------

@rpc("any_peer", "call_remote", "reliable")
func hello(info: Dictionary) -> void:
	hello_received.emit(info)

## Host -> client: which world the host generated.
@rpc("authority", "call_remote", "reliable")
func world_config_rpc(seed_value: int, zone: String, world_seed: int, sector: String,
		race_hint: String) -> void:
	world = {
		"seed": seed_value, "zone": zone, "world_seed": world_seed,
		"sector": sector, "race": race_hint,
	}
	world_config.emit(seed_value, zone, world_seed, sector, race_hint)

func send_world_config(seed_value: int, zone: String, world_seed: int, sector: String,
		race_hint: String) -> void:
	# The host remembers its own world: a player may join hours later.
	world = {
		"seed": seed_value, "zone": zone, "world_seed": world_seed,
		"sector": sector, "race": race_hint,
	}
	var target := other_peer()
	if target != 0:
		world_config_rpc.rpc_id(target, seed_value, zone, world_seed, sector, race_hint)

# --- peace / war between the players -----------------------------------------

## Declare peace or war. Either player may call it; the state is shared.
func set_pvp(on: bool) -> void:
	if not is_online():
		return
	_apply_pvp(on)
	var target := other_peer()
	if target != 0:
		pvp_rpc.rpc_id(target, on)

func _apply_pvp(on: bool) -> void:
	if pvp == on:
		return
	pvp = on
	pvp_changed.emit(on)

@rpc("any_peer", "call_remote", "reliable")
func pvp_rpc(on: bool) -> void:
	_apply_pvp(on)

## Companion order: any peer may suggest one, the receiving bot executes it.
## This is an AI order, not a gameplay authority transfer.
func send_bot_command(command: String) -> void:
	if not is_online() or not BOT_ORDERS.has(command):
		return
	var target := other_peer()
	if target != 0:
		bot_command_rpc.rpc_id(target, command)

@rpc("any_peer", "call_remote", "reliable")
func bot_command_rpc(command: String) -> void:
	if not BOT_ORDERS.has(command):
		return
	bot_command.emit(command)

## Both peers tell the other side what their hero looks like.
@rpc("any_peer", "call_remote", "reliable")
func hero_join_rpc(info: Dictionary) -> void:
	var sender := multiplayer.get_remote_sender_id()
	var peer := sender if sender != 0 else multiplayer.get_unique_id()
	peer_heroes[peer] = info
	hero_joined.emit(peer, info)

func send_hero_join(info: Dictionary) -> void:
	var target := other_peer()
	if target != 0:
		hero_join_rpc.rpc_id(target, info)

# --- per-frame state ----------------------------------------------------------

## Each peer sends its OWN hero. Called on the authority side only.
func send_hero_state(pos: Vector2, anim: int, dir: Vector2, hp: int, mana: int) -> void:
	var target := other_peer()
	if target == 0:
		return
	hero_state_rpc.rpc_id(target, pos, anim, dir, hp, mana)

@rpc("any_peer", "call_remote", "unreliable_ordered")
func hero_state_rpc(pos: Vector2, anim: int, dir: Vector2, hp: int, mana: int) -> void:
	var sender := multiplayer.get_remote_sender_id()
	hero_state.emit(sender, pos, anim, dir, hp, mana)

## Host -> client: every monster it simulates.
func send_enemy_snap(bytes: PackedByteArray) -> void:
	var target := other_peer()
	if target == 0:
		return
	enemy_snap_rpc.rpc_id(target, bytes)

@rpc("authority", "call_remote", "unreliable_ordered")
func enemy_snap_rpc(bytes: PackedByteArray) -> void:
	enemy_snap.emit(bytes)

# --- reliable events ----------------------------------------------------------

func send_enemy_spawn(info: Dictionary) -> void:
	var target := other_peer()
	if target != 0:
		enemy_spawn_rpc.rpc_id(target, info)

@rpc("authority", "call_remote", "reliable")
func enemy_spawn_rpc(info: Dictionary) -> void:
	enemy_spawn.emit(info)

func send_enemy_died(net_id: String, set_name: String, pos: Vector2) -> void:
	var target := other_peer()
	if target != 0:
		enemy_died_rpc.rpc_id(target, net_id, set_name, pos)

@rpc("authority", "call_remote", "reliable")
func enemy_died_rpc(net_id: String, set_name: String, pos: Vector2) -> void:
	enemy_died.emit(net_id, set_name, pos)

func send_kill_event(set_name: String, quest_id: String) -> void:
	var target := other_peer()
	if target != 0:
		kill_event_rpc.rpc_id(target, set_name, quest_id)

@rpc("authority", "call_remote", "reliable")
func kill_event_rpc(set_name: String, quest_id: String) -> void:
	kill_event.emit(set_name, quest_id)

## Client -> host: my blow on a monster. The host applies it.
func send_hit_enemy(net_id: String, dmg: int, kind: String, sphere: String) -> void:
	if role == "client":
		hit_enemy_rpc.rpc_id(1, net_id, dmg, kind, sphere)

@rpc("any_peer", "call_remote", "reliable")
func hit_enemy_rpc(net_id: String, dmg: int, kind: String, sphere: String) -> void:
	hit_enemy.emit(net_id, dmg, kind, sphere)

## Host -> client: a monster hit your hero (the client owns its own HP).
func send_hero_hit(dmg: int) -> void:
	var target := other_peer()
	if target != 0:
		hero_hit_rpc.rpc_id(target, dmg)

## A monster hit the receiving hero, or — at war — the other PLAYER's hero.
## `any_peer` because both sides send it: the host for monsters, the client for
## its own blows on the host's hero (PvP, 22.11).
@rpc("any_peer", "call_remote", "reliable")
func hero_hit_rpc(dmg: int) -> void:
	var sender := multiplayer.get_remote_sender_id()
	# Only the host's monsters may hurt a hero at peace; a player may hurt the
	# other hero only when the war is declared.
	if sender != 1 and not pvp:
		return
	hero_hit.emit(dmg)

## Death and rebirth of a hero, sent by its owner.
func send_hero_alive(alive: bool, pos: Vector2, hp: int) -> void:
	var target := other_peer()
	if target != 0:
		hero_alive_rpc.rpc_id(target, alive, pos, hp)

@rpc("any_peer", "call_remote", "reliable")
func hero_alive_rpc(alive: bool, pos: Vector2, hp: int) -> void:
	var sender := multiplayer.get_remote_sender_id()
	hero_alive.emit(sender, alive, pos, hp)

## Host -> client: loot appeared on the ground.
func send_loot_spawn(items: Array, pos: Vector2, potion: String) -> void:
	var target := other_peer()
	if target != 0:
		loot_spawn_rpc.rpc_id(target, items, pos, potion)

@rpc("authority", "call_remote", "reliable")
func loot_spawn_rpc(items: Array, pos: Vector2, potion: String) -> void:
	loot_spawn.emit(items, pos, potion)

## Either peer -> the other: a drop was collected, remove it from the ground.
func send_loot_taken(pos: Vector2) -> void:
	var target := other_peer()
	if target != 0:
		loot_taken_rpc.rpc_id(target, pos)

@rpc("any_peer", "call_remote", "reliable")
func loot_taken_rpc(pos: Vector2) -> void:
	loot_taken.emit(pos)
