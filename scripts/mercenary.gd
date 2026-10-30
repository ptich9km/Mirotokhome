extends CharacterBody2D
class_name Mercenary
## Tavern mercenary: follows the hero, attacks enemies (Game.enemies),
## does not level up and wears no armor (as in the original). Death removes it from the squad.

@export var anim_set: String = "ork_mage_a52/t1"
@export var max_hp: int = 70
@export var damage: int = 6
@export var move_speed: float = 90.0
@export var spirit: int = 5                # base magic resistance

var current_hp: int
var attack_cooldown: float = 0.0
var _impact_timer := -1.0            # countdown to the hit frame (swing); <0 = no hit in flight
var _pending_target: Node2D = null   # target of the current swing (damage on the hit frame)
var state: String = "idle"      # idle | dying | decay | corpse
var lifespan: float = 0.0       # >0 — summoned minion: disappears when the time runs out
var _lifetime: float = 0.0
var _corpse_timer := 0.0
var _anim: UnitAnimBase = null
var _path: Array = []
var _repath: float = 0.0

## --- Squad orders (28.10) ---------------------------------------------------
## Game.action_mode is set by the HUD buttons (Follow/Attack/Guard/Stop) and used to
## move ONLY the hero: mercenaries always ran to the nearest enemy themselves.
## Now the intent is chosen by the mode, and movement stays the same
## (path + steering): decision and movement are separated.
const FOLLOW_GAP := 64.0        # stay behind the hero at this distance
const FOLLOW_RADIUS := 240.0    # search for own enemies within this radius
const FOLLOW_LEASH := 320.0     # do not chase an enemy farther than this from the hero
const ATTACK_RADIUS := 480.0    # "Attack": enemy within this radius from the HERO
const GUARD_RADIUS := 150.0     # "Guard": enemy within this radius from the post
const GUARD_LEASH := 400.0      # the hero moved farther — the post moves along
const STOP_REACH := 8.0         # "Stop": only retaliation within melee reach

var _order: String = ""         # current mode ("" — not read yet)
var _anchor := Vector2.ZERO     # guard post


func _ready() -> void:
	add_to_group("mercenary")
	Game.configure_unit_body(self)
	current_hp = max_hp
	_anim = UnitAnim.new()
	_anim.name = "UnitAnim"
	add_child(_anim)
	_anim.setup(anim_set)
	_anim.play(UnitAnim.Anim.IDLE)

func _physics_process(delta: float) -> void:
	if Game.is_paused or _anim == null:
		return
	attack_cooldown = maxf(0.0, attack_cooldown - delta)
	if lifespan > 0.0:
		_lifetime += delta
		if _lifetime >= lifespan:
			Game.party.erase(self)
			queue_free()
			return
	_apply_relief_stand()

	# The mercenary died: fall → decay (if any) → disappear
	if state == "dying" or state == "decay" or state == "corpse":
		velocity = velocity.move_toward(Vector2.ZERO, 1800.0 * delta)
		match state:
			"dying":
				_anim.play(UnitAnim.Anim.DYING)
				if _anim.advance(delta):
					if UnitDB.decay_phases(anim_set) > 0:
						state = "decay"
						_anim.play(UnitAnim.Anim.DECAY)
					else:
						state = "corpse"
						_anim.freeze_last_frame(UnitAnim.Anim.DYING)
						_corpse_timer = 5.0
			"decay":
				if _anim.advance(delta):
					state = "corpse"
					_anim.freeze_last_frame(UnitAnim.Anim.DECAY)
					_corpse_timer = 3.0
			"corpse":
				_corpse_timer -= delta
				if _corpse_timer <= 0.0:
					queue_free()
					return
		move_and_slide()
		return

	_sync_order()
	var target := _order_target()
	# Hit frame: damage is applied on contact, not at the start of the swing
	if _impact_timer >= 0.0:
		_impact_timer -= delta
		move_and_slide()
		if _impact_timer < 0.0:
			_impact_timer = -1.0
			if is_instance_valid(_pending_target) and Game.enemies.has(_pending_target) \
					and not Game.is_miss(self, _pending_target):
				Game.deal_damage(_pending_target, damage, "physical", "", self)
			_pending_target = null
		return
	if target != null:
		# Combat distance is the gap between BODIES (the same measure as for the hero and enemies),
		# otherwise the mercenary would swing at the air from half a step away.
		if Game.units_range(self, target) > Game.attack_reach(self):
			_move_toward(target.global_position, delta)
		else:
			velocity = Vector2.ZERO
			_attack(target)
	else:
		_hold_position(delta)

	move_and_slide()
	if velocity.length_squared() > 1.0:
		_anim.play(UnitAnim.Anim.MOVE)
		_anim.set_direction_vec(velocity)
		_anim.advance(delta)
	else:
		_anim.play(UnitAnim.Anim.IDLE)

## Read the hero's order. Changing the mode places the guard post at the current spot:
## otherwise "Guard" after a long walk would pull the mercenary back to the old point.
func _sync_order() -> void:
	var mode := Game.action_mode
	if mode == "" or mode == "none":
		mode = "follow"
	if mode == _order:
		return
	_order = mode
	_anchor = global_position

## Target by order. Returns null — no target chosen, so we head to the post.
func _order_target() -> Node2D:
	var hero: Node2D = Game.hero
	match _order:
		"stop":
			# Hold: hit only whoever came within melee reach.
			return _nearest_enemy_from(global_position,
				Game.attack_reach(self) + STOP_REACH)
		"guard":
			return _nearest_enemy_from(_anchor, GUARD_RADIUS)
		"attack":
			if hero == null or not is_instance_valid(hero):
				return _nearest_enemy(ATTACK_RADIUS)
			return _nearest_enemy_from(hero.global_position, ATTACK_RADIUS)
		_:
			# Follow: own enemy nearby, but do not chase far from the hero.
			var enemy := _nearest_enemy(FOLLOW_RADIUS)
			if enemy != null and hero != null and is_instance_valid(hero) \
					and enemy.global_position.distance_to(hero.global_position) > FOLLOW_LEASH:
				return null
			return enemy

## No target: keep formation as ordered.
func _hold_position(delta: float) -> void:
	var hero: Node2D = Game.hero
	match _order:
		"stop":
			velocity = Vector2.ZERO
			_path.clear()
		"guard":
			# The hero moved beyond the leash — the post moves: the guard does not abandon the hero.
			if hero != null and is_instance_valid(hero) \
					and hero.global_position.distance_to(_anchor) > GUARD_LEASH:
				_anchor = global_position
				if global_position.distance_to(hero.global_position) > FOLLOW_GAP:
					_move_toward(hero.global_position, delta)
					return
			if global_position.distance_to(_anchor) > 12.0:
				_move_toward(_anchor, delta)
			else:
				velocity = Vector2.ZERO
				_path.clear()
		_:
			# Follow/Attack with no enemies: stand next to the hero.
			if hero != null and is_instance_valid(hero) \
					and global_position.distance_to(hero.global_position) > FOLLOW_GAP:
				_move_toward(hero.global_position, delta)
			else:
				velocity = Vector2.ZERO
				_path.clear()

func _nearest_enemy(radius: float) -> Node2D:
	return _nearest_enemy_from(global_position, radius)

func _nearest_enemy_from(origin: Vector2, radius: float) -> Node2D:
	var best: Node2D = null
	var best_d := radius
	for e in Game.enemies:
		if not is_instance_valid(e):
			continue
		var d := origin.distance_to(e.global_position)
		if d < best_d:
			best_d = d
			best = e
	return best

func _move_toward(p: Vector2, delta: float) -> void:
	var dist := global_position.distance_to(p)
	if _path.is_empty() or dist > 400.0:
		_repath -= delta
		if _repath <= 0.0:
			_repath = 1.2 + randf() * 0.6
			var map_node := get_tree().get_first_node_in_group("alm_map")
			if map_node != null and map_node.has_method("find_path") and dist < 500.0:
				_path = map_node.find_path(global_position, p)
	var target := p
	if _path.size() > 0:
		var waypoint: Vector2 = _path[0]
		if global_position.distance_to(waypoint) <= 8.0:
			_path.pop_front()
		if _path.size() > 0:
			waypoint = _path[0]
		target = waypoint
	var direction := Game.movement_direction(self, Game.safe_dir(global_position, target))
	var wanted := direction * (move_speed * StatusEffects.speed_mult(self))
	velocity = velocity.move_toward(wanted, 1100.0 * delta)

func _attack(target: Node2D) -> void:
	if attack_cooldown > 0.0 or _impact_timer >= 0.0:
		return
	if not Game.enemies.has(target):
		return
	attack_cooldown = GameConfig.getf("combat", "attack_cooldown")
	# Swing: damage and sound on the hit frame (_impact_timer is processed in _physics_process)
	_pending_target = target
	_impact_timer = UnitDB.attack_delay(anim_set)

func take_damage(dmg: int, _attacker: Node2D) -> int:
	# A dead mercenary takes no damage
	if state == "dying" or state == "decay" or state == "corpse":
		return 0
	dmg = Game.shield_reduce(self, dmg)
	if dmg <= 0:
		SpellVFX.shield_hit(self)
		return 0
	current_hp -= dmg
	if current_hp <= 0:
		current_hp = 0
		SoundDB.play("combat.death")
		Game.party.erase(self)
		velocity = Vector2.ZERO
		state = "dying"
	else:
		SoundDB.play_pain(UnitDB.unit_sound(anim_set))
	return dmg

## Restore HP (healing, vampirism). Returns the amount actually restored.
func heal_amount(amount: int) -> int:
	if amount <= 0 or current_hp >= max_hp:
		return 0
	if state == "dying" or state == "decay" or state == "corpse":
		return 0
	var healed := mini(max_hp, current_hp + amount) - current_hp
	current_hp += healed
	DamageNumber.show_at(global_position, healed, "heal")
	return healed

## --- Derived stats (like enemies/hero) for Game.deal_damage ---
func get_attack() -> int:
	return int(damage / float(GameConfig.geti("combat", "enemy_attack_dmg_div"))) \
		+ int(max_hp / float(GameConfig.geti("combat", "enemy_attack_hp_div"))) \
		+ StatusEffects.stat_flat(self, "attack")

func get_defense() -> int:
	var base := int(max_hp / float(GameConfig.geti("combat", "enemy_defense_div")))
	return int(round((base + StatusEffects.stat_flat(self, "defense")) * StatusEffects.defense_mult(self)))

func get_absorption() -> int:
	return int(max_hp / float(GameConfig.geti("combat", "enemy_absorption_div")))

## Resistance in percent. Before, all get_protection_* were hardcoded 0 —
## the mercenary took full magic damage of any element.
func _resist(sphere: String) -> int:
	return spirit * 2 + StatusEffects.resist_bonus(self, sphere)

func get_protection_fire() -> int:   return _resist("Fire")
func get_protection_water() -> int:  return _resist("Water")
func get_protection_air() -> int:    return _resist("Air")
func get_protection_earth() -> int:  return _resist("Earth")
func get_protection_astral() -> int: return _resist("Astral")

func _apply_relief_stand() -> void:
	var h := 0.0
	var map_node: Node2D = Game.hero
	if map_node != null and is_instance_valid(map_node) \
			and map_node.is_in_group("alm_map") and map_node.has_method("relief_at_world"):
		h = float(map_node.call("relief_at_world", global_position))
	_anim.position = Vector2(_anim.position.x, -h)