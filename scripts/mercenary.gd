extends CharacterBody2D
class_name Mercenary
## Tavern mercenary: follows the hero, attacks enemies (Game.enemies),
## does not level up and wears no armor (as in the original). Death removes it from the squad.

@export var anim_set: String = "merc/human_warrior/t0"
@export var max_hp: int = 70
@export var damage: int = 6
@export var move_speed: float = 90.0
@export var spirit: int = 5                # base magic resistance
## Weapon kind for the Allods table (`` | sword | axe | club | pike | bow).
## An archer fills it in `_ready`: the arrow damage then goes through the same
## `Game.weapon_kind_of` path as a hero's bow.
@export var weapon: String = ""

## --- Role (16.11): the order says WHERE to go, the role says WHAT to do ------
## A mercenary mage that walks into melee is the reported problem: he is hired
## for magic, not for the staff. The role is per mercenary and lives next to the
## squad orders (HUD Follow/Attack/Guard/Stop), which stay global.
const ROLE_MELEE := "melee"    # warrior default: the old swing, unchanged
const ROLE_RANGED := "ranged"  # archer: shoot from the distance
const ROLE_STAFF := "staff"    # mage: swing the staff in close combat
const ROLE_SPELL := "spell"    # mage: keep the distance and cast the chosen spell
const ROLE_HEAL := "heal"      # mage: stay with the party and heal the wounded
const MAGE_ROLES := [ROLE_STAFF, ROLE_SPELL, ROLE_HEAL]
const WARRIOR_ROLES := [ROLE_MELEE]
const ARCHER_ROLES := [ROLE_RANGED]

## "" — the class default: a mage casts, a warrior swings.
@export var role: String = ""
## The chosen spell of the "spell" role ("" — the first unlocked one).
@export var spell: String = ""

var current_hp: int
var attack_cooldown: float = 0.0
var _cast_cd := 0.0
var _heal_cd := 0.0
var _shield_cd := 0.0
var _cast_anim := 0.0                # >0 — the cast gesture is playing

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


## Both directions: the mercenary ignores the hero and the hero ignores the mercenary.
func _bind_owner() -> void:
	var owner_body := Game.hero
	if owner_body == null or not is_instance_valid(owner_body) \
			or not (owner_body is CollisionObject2D):
		return
	add_collision_exception_with(owner_body)
	(owner_body as CollisionObject2D).add_collision_exception_with(self)


## The pair must be released BEFORE the body leaves the tree: a freed body left in
## the hero's exception list makes get_collision_exceptions() throw
## "Parameter \"body\" is null" on the next _escape_blocking_units call.
func _exit_tree() -> void:
	var owner_body := Game.hero
	if owner_body == null or not is_instance_valid(owner_body) \
			or not (owner_body is CollisionObject2D):
		return
	(owner_body as CollisionObject2D).remove_collision_exception_with(self)


func _ready() -> void:
	add_to_group("mercenary")
	if weapon == "" and is_archer():
		weapon = "bow"
	Game.configure_unit_body(self)
	# A hireling is never a wall for its owner (Diablo 2: pets and hirelings do not
	# block the player). Without this the hero physically cannot walk towards a
	# follower standing next to him — the reported "he sticks to me" bug.
	_bind_owner.call_deferred()
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
	_cast_cd = maxf(0.0, _cast_cd - delta)
	_heal_cd = maxf(0.0, _heal_cd - delta)
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
	# Role actions (mage cast / heal) own the frame: they decide the approach
	# distance themselves, so the melee block below must not steal the target.
	if not _tick_role(delta):
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
	if _cast_anim > 0.0 and velocity.length_squared() <= 1.0:
		# The cast gesture: the mage raises the staff instead of swinging it.
		_cast_anim -= delta
		_anim.play(UnitAnim.Anim.ATTACK)
		_anim.advance(delta)
	elif velocity.length_squared() > 1.0:
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


## --- Roles -------------------------------------------------------------------
## The class default: a mage casts from the distance, a warrior swings.
func is_mage() -> bool:
	return anim_set.contains("mage")


## An archer shoots: the `*_archer` sets have a bow drawn in their hands, and
## `attack` frames are the shot, so the melee swing would look like a man
## beating an enemy with a bow.
func is_archer() -> bool:
	return anim_set.contains("archer")


## The role in force. A warrior has no choice: only the swing is drawn for him,
## so a stored "spell" role on a warrior set is ignored instead of shown as broken.
func role_name() -> String:
	if is_mage():
		if role in MAGE_ROLES:
			return role
		return ROLE_SPELL
	if is_archer():
		return ROLE_RANGED
	return ROLE_MELEE


## Roles this set can play — the party panel draws exactly these buttons.
func available_roles() -> Array:
	if is_mage():
		return MAGE_ROLES
	if is_archer():
		return ARCHER_ROLES
	return WARRIOR_ROLES


## Set the role from the UI/save. Returns false for a role this class cannot play.
func set_role(value: String) -> bool:
	var allowed := available_roles()
	if value == "":
		role = ""
		return true
	if not (value in allowed):
		return false
	role = value
	if is_mage():
		_spell_fallback()
	return true


## The face of the city the mercenary came from ("humans"/"ork"/"druid"/"necro"),
## read from the set name. `MapGenerator.race_of_set` only understands the city
## sets (`city_<race>_...`), so a mercenary folder is parsed here.
const SET_RACES := {"human": "humans", "orc": "ork", "druid": "druid", "undead": "necro"}


func race_id() -> String:
	var folder := anim_set.get_slice("/", 1)
	if folder == "":
		folder = anim_set
	var key := folder.get_slice("_", 0)
	return str(SET_RACES.get(key, ""))


## Reputation tier in the hero's faction: the same thresholds the tavern uses.
func rep_tier() -> int:
	var rep := Game.hero_reputation(race_id())
	var t := 0
	if rep >= GameConfig.geti("reputation", "tier_1"):
		t = 1
	if rep >= GameConfig.geti("reputation", "tier_2"):
		t = 2
	if rep >= GameConfig.geti("reputation", "tier_3"):
		t = 3
	return t


## Spells of the race that are already unlocked by reputation, weakest first.
## "Light" mages cast the first element spell, "elite" ones add the school's
## heavy spell (blizzard / prismatic spray / stone curse / wall of fire).
func spell_options() -> Array:
	var tables := ContentRules.dict("merc.spells")
	var own: Array = tables.get(race_id(), [])
	var out: Array = []
	var tier := rep_tier()
	for raw in own:
		if not (raw is Dictionary):
			continue
		var rec: Dictionary = raw
		if int(rec.get("tier", 0)) > tier:
			continue
		var name := str(rec.get("spell", ""))
		if name == "" or not SpellCasting.is_unit_castable(name):
			continue
		out.append({"spell": name, "tier": int(rec.get("tier", 0))})
	return out


## The spell actually cast now: the chosen one when it is still unlocked,
## otherwise the first unlocked spell.
func active_spell() -> String:
	var opts := spell_options()
	if opts.is_empty():
		return ""
	if spell != "":
		for o in opts:
			if str((o as Dictionary).get("spell", "")) == spell:
				return spell
	return str((opts[0] as Dictionary).get("spell", ""))


## Drop a stored spell that is no longer offered (no reputation, data changed).
func _spell_fallback() -> void:
	if spell == "":
		return
	for o in spell_options():
		if str((o as Dictionary).get("spell", "")) == spell:
			return
	spell = ""


## Magic power for `Game.spell_damage`: the database damage belongs to a hero,
## the mercenary's own `damage` is his scale. 0 % would keep the raw spell
## numbers (a 6-damage hireling hitting for 14), so the power is negative and
## puts the first spell exactly at the mercenary's own hit.
func magic_power() -> float:
	var ref := SpellDB.damage(ContentRules.str_value("merc.magic.ref_spell", "Fire_Arrow"))
	if ref <= 0:
		ref = 14
	return (float(damage) / float(ref) - 1.0) * 100.0


## Damage of a cast. `Game.spell_damage` treats a NEGATIVE power as "no override"
## and falls back to the caster's own mind/skill (a mercenary has none, so 0),
## which is why the formula is applied here directly: same numbers, but the
## mercenary's negative power really shrinks the database damage.
func magic_damage(spell_name: String) -> int:
	var base := SpellDB.damage(spell_name)
	if base <= 0:
		return 0
	var coef := SpellDB.power_coef_of(spell_name)
	var raw := float(base) * coef * (1.0 + magic_power() / 100.0)
	return maxi(SpellDB.min_damage_of(spell_name), int(round(raw)))


## Where the spell leaves the body: the chest, not the feet.
func cast_origin() -> Vector2:
	return global_position + Vector2(0.0, -Game.unit_visual_height(self) * 0.6)


## Frames the role owns. Returns true when the frame was consumed, so the melee
## block of `_physics_process` must not run.
func _tick_role(delta: float) -> bool:
	_tick_shield(delta)
	if is_archer():
		return _tick_ranged(delta)
	if not is_mage():
		return false
	match role_name():
		ROLE_SPELL:
			return _tick_spell(delta)
		ROLE_HEAL:
			return _tick_heal(delta)
	return false


## Archer: keep the bow range, loose an arrow when the enemy is inside it.
func _tick_ranged(delta: float) -> bool:
	var target := _order_target()
	if target == null:
		_hold_position(delta)
		return true
	var cfg := ContentRules.dict("merc.ranged")
	var keep := float(cfg.get("keep", 220.0))
	if Game.units_range(self, target) > keep:
		_move_toward(target.global_position, delta)
	else:
		velocity = velocity.move_toward(Vector2.ZERO, 1800.0 * delta)
		_shoot(target)
	return true


## The arrow itself flies as a node: damage lands on arrival, not at the shot,
## so a target that steps behind a wall of bodies is not hit instantly.
func _shoot(target: Node2D) -> void:
	if attack_cooldown > 0.0 or not is_instance_valid(target) or not Game.enemies.has(target):
		return
	var cfg := ContentRules.dict("merc.ranged")
	var arrow := ArrowShot.new()
	arrow.from_pos = cast_origin()
	arrow.to_pos = target.global_position
	arrow.target = target
	arrow.shooter = self
	arrow.damage = damage
	arrow.speed = float(cfg.get("arrow_speed", 520.0))
	var scene_root := get_tree().current_scene if is_inside_tree() else null
	if scene_root != null:
		scene_root.add_child(arrow)
	else:
		add_child(arrow)
	attack_cooldown = GameConfig.getf("combat", "attack_cooldown")
	_cast_anim = 0.45
	SoundDB.play("combat.bow")


## Caster: keep the spell range, cast when the enemy is inside it.
func _tick_spell(delta: float) -> bool:
	var sp := active_spell()
	if sp == "":
		return false
	var target := _order_target()
	if target == null:
		_hold_position(delta)
		return true
	var ratio := float(ContentRules.dict("merc.magic").get("range_ratio", 0.8))
	var keep := maxf(48.0, SpellDB.range_of(sp) * ratio)
	if Game.units_range(self, target) > keep:
		_move_toward(target.global_position, delta)
	else:
		velocity = velocity.move_toward(Vector2.ZERO, 1800.0 * delta)
		_cast_at(target, sp)
	return true


## Healer: never chases an enemy, stays near the party and heals the wounded.
func _tick_heal(delta: float) -> bool:
	var patient := _wounded_ally()
	if patient == null:
		_hold_position(delta)
		return true
	var reach := _heal_range()
	if global_position.distance_to(patient.global_position) > reach * 0.85:
		_move_toward(patient.global_position, delta)
	else:
		velocity = velocity.move_toward(Vector2.ZERO, 1800.0 * delta)
		_heal_patient(patient)
	return true


func _heal_range() -> float:
	return float(ContentRules.dict("merc.heal").get("range", 200.0))


func _heal_patient(patient: Node2D) -> void:
	if _heal_cd > 0.0 or not is_instance_valid(patient):
		return
	if not patient.has_method("heal_amount"):
		return
	var max_life := int(patient.get("max_hp"))
	if max_life <= 0:
		return
	var percent := float(ContentRules.dict("merc.heal").get("percent", 0.08))
	var amount := maxi(1, int(round(float(max_life) * percent)))
	if int(patient.call("heal_amount", amount)) <= 0:
		return
	SpellAura.heal_cross(patient)
	SoundDB.play("magic.heal")
	_cast_anim = 0.5
	_heal_cd = float(ContentRules.dict("merc.heal").get("cooldown", 2.5))


## The most wounded ally in reach: the hero, the party and the mage himself.
## Enemies are never in this list — a healer that healed a monster would be worse
## than no healer at all.
func _wounded_ally() -> Node2D:
	var threshold := GameConfig.getf("magic", "auto_heal_ratio")
	if threshold <= 0.0:
		threshold = 0.45
	var leash := maxf(_heal_range() * 2.0, 320.0)
	var best: Node2D = null
	var worst := threshold
	var units: Array = [self]
	if is_instance_valid(Game.hero):
		units.append(Game.hero)
	for m in Game.party:
		if is_instance_valid(m) and m != self:
			units.append(m)
	for raw in units:
		var u: Node2D = raw as Node2D
		if u == null or not is_instance_valid(u):
			continue
		if "state" in u and str(u.get("state")) in ["dying", "decay", "corpse"]:
			continue
		if not ("current_hp" in u) or not ("max_hp" in u):
			continue
		var max_life := int(u.get("max_hp"))
		if max_life <= 0:
			continue
		var ratio := float(int(u.get("current_hp"))) / float(max_life)
		if ratio >= worst:
			continue
		if u != self and global_position.distance_to(u.global_position) > leash:
			continue
		worst = ratio
		best = u
	return best


## Mages shield themselves: the Allods behaviour the player asked to keep.
## Absorb-shield (not hero armour): a mercenary lives on `shield_reduce`.
func _tick_shield(delta: float) -> void:
	if not is_mage():
		return
	_shield_cd = maxf(0.0, _shield_cd - delta)
	if _shield_cd > 0.0:
		return
	var cfg := ContentRules.dict("merc.magic")
	if _nearest_enemy(float(cfg.get("shield_alarm_radius", 320.0))) == null:
		return
	if int(get_meta("shield_strength", 0)) > 0 and float(get_meta("shield_time", 0.0)) > 0.0:
		return
	var spell_name := str(cfg.get("shield", "Shield"))
	var spell := SpellDB.get_spell(spell_name)
	if spell.is_empty():
		return
	StatusEffects.apply_spell(self, spell, self)
	SpellVFX.aura_ring(self, "Astral", "buff")
	SoundDB.play("magic.shield")
	_shield_cd = float(cfg.get("shield_cooldown", 14.0))


## One cast at a target. The spell kind decides the effect: the same dispatcher
## shape the hero uses, but without hero-only branches (teleport, summon, raise).
func _cast_at(target: Node2D, spell_name: String) -> void:
	if _cast_cd > 0.0 or not is_instance_valid(target) or not Game.enemies.has(target):
		return
	var spell := SpellDB.get_spell(spell_name)
	if spell.is_empty():
		return
	var sphere := SpellDB.sphere_of(spell_name)
	var kind := str(spell.get("kind", "attack"))
	var dmg := magic_damage(spell_name)
	var origin := cast_origin()
	var aim: Vector2 = target.global_position
	match kind:
		"attack", "area":
			if str(spell.get("projectile", "")) == "chain":
				SpellCasting.cast_chain(self, spell_name, aim, origin, dmg,
					float(spell.get("area", 0)))
			elif str(spell.get("zone_style", "")) != "":
				SpellCasting.cast_zone(self, spell_name, sphere, aim, dmg)
			else:
				SpellCasting.launch_projectile(self, spell_name, origin, aim, dmg,
					float(spell.get("area", 0)))
		"debuff":
			StatusEffects.apply_spell(target, spell, self)
			SpellVFX.aura_ring(target, sphere, "debuff")
		"wall":
			SpellCasting.cast_wall(self, spell_name, sphere, aim, origin, dmg)
		_:
			return
	_cast_cd = maxf(0.6, SpellDB.cooldown_of(spell_name))
	_cast_anim = 0.5
	SoundDB.play(SpellDB.sound_of(spell_name))

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
	# The map, not Game.hero: the hero is a unit and never belongs to the
	# "alm_map" group, so the old source returned 0 on every hill.
	var map_node := get_tree().get_first_node_in_group("alm_map")
	if map_node != null and is_instance_valid(map_node) \
			and map_node.has_method("relief_at_world"):
		h = float(map_node.call("relief_at_world", global_position))
	_anim.position = Vector2(_anim.position.x, -h)