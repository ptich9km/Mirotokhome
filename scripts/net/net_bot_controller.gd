class_name NetBotController
extends Node
## The AI companion that drives the bot's local Player.
##
## It is a small FSM: follow, come, stay, attack. The controller only issues
## high-level orders; Player's own movement/combat code does the walking,
## pathfinding, collision and damage. In co-op the owner peer is the authority
## for its hero, so the bot works exactly like a human player.

const FOLLOW_DISTANCE := 96.0
const COME_DISTANCE := 40.0
const ATTACK_SCAN_RADIUS := 420.0
const REPLAN_SECONDS := 0.8

var mode: String = "follow"          # follow | come | stay | attack
var _player: Player = null
var _anchor: Vector2 = Vector2.ZERO
var _anchor_set := false
var _target: Node2D = null
var _replan := 0.0

func setup(player: Player) -> void:
	_player = player
	set_process(player != null)

func set_mode(new_mode: String) -> void:
	if not NetSession.BOT_ORDERS.has(new_mode):
		return
	mode = new_mode
	_target = null
	_replan = 0.0
	if mode == "stay" and _player != null and is_instance_valid(_player):
		_player.stop_movement()

func _process(delta: float) -> void:
	if _player == null or not is_instance_valid(_player) or _player.is_dead:
		return
	match mode:
		"follow":
			_tick_follow(delta)
		"come":
			_tick_come(delta)
		"attack":
			_tick_attack(delta)
		_:
			pass

func _tick_follow(delta: float) -> void:
	var hero := Game.hero
	if hero == null or not is_instance_valid(hero):
		return
	if _player.global_position.distance_to(hero.global_position) > FOLLOW_DISTANCE:
		_move_to(hero.global_position, delta)

func _tick_come(delta: float) -> void:
	var hero := Game.hero
	if hero == null or not is_instance_valid(hero):
		return
	if _player.global_position.distance_to(hero.global_position) > COME_DISTANCE:
		_move_to(hero.global_position, delta)
	else:
		mode = "follow"

func _tick_attack(delta: float) -> void:
	if _target == null or not is_instance_valid(_target) \
			or not Game.is_attackable(_target):
		_target = _find_target()
	if _target == null:
		return
	_player.attack_target = _target
	_player.state = "chase"

func _find_target() -> Node2D:
	var hero := Game.hero
	var origin := _player.global_position
	if hero != null and is_instance_valid(hero):
		origin = hero.global_position
	var best: Node2D = null
	var best_d := ATTACK_SCAN_RADIUS
	for e in Game.enemies:
		if e == null or not is_instance_valid(e) or not Game.is_attackable(e):
			continue
		var d := origin.distance_to(e.global_position)
		if d < best_d:
			best_d = d
			best = e
	return best

func _move_to(point: Vector2, delta: float) -> void:
	_replan -= delta
	if _player.state != "move" or _replan <= 0.0:
		_replan = REPLAN_SECONDS
		Game.player_target = point
		_player.attack_target = null
		_player.state = "move"
		var map: Node2D = _player.get("alm_map") as Node2D
		if map != null and map.has_method("find_path"):
			_player.begin_path(map.find_path(_player.global_position, point,
				Game.occupied_cells([_player])))
