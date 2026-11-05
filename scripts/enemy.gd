extends CharacterBody2D
class_name Enemy

@export var max_hp: int = 50
@export var damage: int = 8
@export var move_speed: float = 80.0
@export var aggro_radius: float = 150.0
@export var deaggro_radius: float = 200.0
@export var home_position: Vector2
## Enemy animation set. Empty by default ON PURPOSE: Allods art was removed
## (11.10), there are no Grey sets in the database, and a default pointing at a deleted set
## would mean either a crash in setup() or an invisible enemy. The set comes
## from the map generator at spawn; while the pool is empty, enemies do not spawn at all.
@export var anim_set: String = ""

## Enemy death (22.10): a signal for quests (QuestSystem counts the hunt).
## A quest target beast carries quest_id — that is how the pack leader differs from a regular
## individual of the same set.
signal died(unit: Enemy)

var quest_id: String = ""

var current_hp: int
var state: String = "idle"
var attack_target: Node2D = null
var attack_cooldown: float = 0.0
var _impact_timer := -1.0            # countdown to the hit frame (swing); <0 = no hit in flight
var can_flee: bool = false        # by default the monster fights to the end, does not flee
var _path: Array = []             # route to the player (obstacle avoidance)
var _repath := 0.0
var _corpse_timer := 0.0          # how long the corpse stays before removal (without decay)
var health_bar: HealthBar
var _anim: UnitAnimBase = null
## Event skirmish (19.10): own group tag and opponent tag. Empty = a regular Grey.
var event_tag: String = ""
var foe_group: String = ""

## Faction outpost (package B, 28.10). Empty faction — a regular Grey.
## The outpost guard is NOT an enemy by default: it hits the hero only when hostile
## (faction reputation < 0) or after the hero's hit (provoked). This is
## the player's decision "hostile at bad reputation".
@export var faction: String = ""
@export var outpost_id: String = ""
var provoked: bool = false

func _ready():
	add_to_group("enemy")
	Game.configure_unit_body(self)
	# Initial repath jitter: otherwise all enemies call find_path in the same frame.
	_repath = randf() * 1.2
	current_hp = max_hp
	home_position = global_position
	_create_sprite()
	_create_health_bar()

func _create_health_bar():
	health_bar = preload("res://scripts/health_bar.gd").new()
	health_bar.max_hp = max_hp
	health_bar.has_mana = false  # Enemies have no mana
	add_child(health_bar)

func _create_sprite():
	var old_sprite = get_node_or_null("Sprite")
	if old_sprite:
		old_sprite.queue_free()

	_anim = UnitAnim.new()
	_anim.name = "UnitAnim"
	add_child(_anim)
	_anim.setup(anim_set)
	_anim.play(UnitAnim.Anim.IDLE)

func _physics_process(delta):
	if not Game.perf_enabled:
		_physics_process_impl(delta)
		return
	var t0 := Time.get_ticks_usec()
	_physics_process_impl(delta)
	Game.perf_end("enemy_ai", t0)


func _physics_process_impl(delta):
	if Game.is_paused:
		return
	# P5: far from the hero — the AI sleeps (content untouched, CPU only).
	if Game.hero != null and is_instance_valid(Game.hero):
		if global_position.distance_squared_to(Game.hero.global_position) > 1600.0 * 1600.0:
			velocity = Vector2.ZERO
			return
	# Fog of war (19.10): outside the visible cell the unit does not tick and is not drawn.
	if Game.fog != null and Game.fog.blocks_process(global_position):
		visible = false
		return
	visible = true

	attack_cooldown = max(0, attack_cooldown - delta)

	# The monster died — play the fall animation, then the corpse stays on the ground
	if state == "dying" or state == "decay" or state == "corpse":
		if _anim:
			match state:
				"dying":
					_anim.play(UnitAnim.Anim.DYING)
					if _anim.advance(delta):
						velocity = Vector2.ZERO
						if UnitDB.decay_phases(anim_set) > 0:
							state = "decay"          # decay available (skeleton)
							_anim.play(UnitAnim.Anim.DECAY)
						else:
							state = "corpse"
							_anim.freeze_last_frame(UnitAnim.Anim.DYING)
							_corpse_timer = 5.0      # the corpse lies for 5 s, then disappears
				"decay":
					if _anim.advance(delta):
						_corpse_timer = 3.0         # decayed — lies a little longer
						state = "corpse"
						_anim.freeze_last_frame(UnitAnim.Anim.DECAY)
				"corpse":
					if _corpse_timer > 0.0:
						_corpse_timer -= delta
						if _corpse_timer <= 0.0:
							EventSystem.note_freed()
							queue_free()
							return
		velocity = velocity.move_toward(Vector2.ZERO, GameConfig.getf("movement", "decel") * delta)
		move_and_slide()
		_apply_relief_stand()
		return

	# Update the health bar
	if health_bar:
		health_bar.update_bars(current_hp)

	# Single combat target: the player (priority) or a city guard within aggro range.
	var target: Node2D = _combat_target()
	if target == null:
		velocity = Vector2.ZERO
		move_and_slide()
		# The outpost guard stands with no target (neutral) — it must stand on
		# the relief, otherwise on a hill it sinks into the ground by the relief height.
		_apply_relief_stand()
		return
	attack_target = target

	var distance_to_target = Game.units_range(self, target)
	var hp_percent = float(current_hp) / max_hp

	match state:
		"idle":
			if distance_to_target < aggro_radius:
				state = "chase"
		"chase":
			if distance_to_target > deaggro_radius:
				state = "idle"
				velocity = Vector2.ZERO
			elif distance_to_target < Game.attack_reach(self):
				state = "attack"
				velocity = Vector2.ZERO   # stop and hit instead of running past
			elif hp_percent < 0.15 and can_flee:
				state = "flee"
			else:
				_chase_move(delta, target)
		"attack":
			if distance_to_target > Game.attack_reach(self) + 8.0:
				state = "chase"
				_impact_timer = -1.0
			else:
				# Keep the stop between hits: without it the inertia of the chase
				# carries the monster past the player — it "runs around, now there, now here"
				velocity = velocity.move_toward(Vector2.ZERO, GameConfig.getf("movement", "decel") * delta)
				if attack_cooldown <= 0.0 and _impact_timer < 0.0:
					attack_cooldown = GameConfig.getf("combat", "attack_cooldown")
					# Single damage point (miss + armor absorption) — on the hit frame,
					# not at the start of the swing: the hit sounds according to the animation.
					_impact_timer = UnitDB.attack_delay(anim_set)
				elif _impact_timer >= 0.0:
					_impact_timer -= delta
					if _impact_timer < 0.0:
						_impact_timer = -1.0
						if Game.is_miss(self, target):
							print("%s промахнулся по %s!" % [name, target.name])
						else:
							Game.deal_damage(target, damage, "physical", "", self)
						SoundDB.play(_unit_sound_at(0))
		"flee":
			var flee_direction = Game.safe_dir(target.global_position, global_position)
			_move_checked(flee_direction, effective_speed() * 1.5, delta)
			if distance_to_target > deaggro_radius * 1.5:
				EventSystem.note_freed()
				queue_free()

	# Monster animation by state
	if _anim:
		match state:
			"chase", "flee":
				_anim.play(UnitAnim.Anim.MOVE)
				_anim.set_direction_vec(velocity)
				_anim.advance(delta)
			"attack":
				_anim.play(UnitAnim.Anim.ATTACK)
				_anim.speed_scale = 1.0
				_anim.advance(delta)
			_:
				_anim.play(UnitAnim.Anim.IDLE)

	move_and_slide()
	_apply_relief_stand()

## Stand on the relief: lift the sprite to the cell height (as in Allods16).
## Flying units (Z, monsters bat/dragon/succubus) hover above the ground.
func _apply_relief_stand() -> void:
	if _anim == null:
		return
	var h := 0.0
	var map_node = get_tree().get_first_node_in_group("alm_map")
	if map_node != null and map_node.has_method("relief_at_world"):
		h = float(map_node.call("relief_at_world", global_position))
	# Unit flight height (Z from units.txt; usually 0 = walks on the ground)
	var z := UnitDB.fly_z(anim_set)
	_anim.position = Vector2(_anim.position.x, -(h + z))
	if health_bar:
		# Above the FIGURE's head, not above the frame canvas (see Game.unit_local_rect).
		var top := Game.unit_local_rect(self).position.y
		health_bar.position.y = top - (h + z) - 6.0

# --- Movement physics (smooth accel/decel + walkability) ---
## Accel/decel live in GameConfig [movement] accel/decel.

## Movement with map walkability checks (flyers ignore the ground).
## Like the player: full vector -> X-only -> Y-only. Otherwise, hitting a wall or
## a tree, the enemy killed the whole velocity and "stuck" — it could not
## slide along an obstacle at all.
func _move_checked(direction: Vector2, speed: float, delta: float) -> void:
	direction = Game.movement_direction(self, direction)
	var wanted := direction * speed
	var step := wanted * delta
	if _can_step(step):
		velocity = velocity.move_toward(wanted, GameConfig.getf("movement", "accel") * delta)
		return
	if delta <= 0.0:
		velocity = Vector2.ZERO
		return
	var slide := Vector2.ZERO
	# We always try both axes, not "X, otherwise Y": choosing by closeness to the desired
	# direction (Game.choose_slide) removes jitter near trees and corners.
	var slide_axis := Game.choose_slide(direction,
		_can_step(Vector2(step.x, 0.0)), _can_step(Vector2(0.0, step.y)))
	slide = Vector2(slide_axis.x * step.x, slide_axis.y * step.y)
	if slide == Vector2.ZERO:
		velocity = velocity.move_toward(Vector2.ZERO, GameConfig.getf("movement", "decel") * delta)
	else:
		velocity = velocity.move_toward(slide / delta, GameConfig.getf("movement", "accel") * delta)

## Is the shift allowed: a walkable cell (flyers ignore the ground). Leaving
## OWN unwalkable cell is allowed — otherwise the enemy could not get out by itself.
func _can_step(step: Vector2) -> bool:
	var map_node = get_tree().get_first_node_in_group("alm_map")
	if UnitDB.fly_z(anim_set) > 0 or map_node == null or not map_node.has_method("is_walkable_world"):
		return true
	var next := global_position + step
	return bool(map_node.is_walkable_world(next)) \
		or Vector2i(int(int(global_position.x) / 32.0), int(int(global_position.y) / 32.0)) \
			== Vector2i(int(int(next.x) / 32.0), int(int(next.y) / 32.0))

## Combat target: the player (priority; in aggro or chase — until deaggro) or
## the nearest city guard NPC within aggro range.
## An invisible hero is "not noticed" beyond 40 px, but is seen point-blank.
func _combat_target() -> Node2D:
	if not Game.perf_enabled:
		return _combat_target_impl()
	var t0 := Time.get_ticks_usec()
	var out := _combat_target_impl()
	Game.perf_end("enemy_target_scan", t0)
	return out


func _combat_target_impl() -> Node2D:
	# Event skirmish (19.10): while the enemy is in an event group, it hits
	# the opposite group; a hero's hit on it switches it to the hero
	# (see take_damage). The opponent died or disappeared — the usual logic below.
	if foe_group != "":
		var foe: Node2D = EventSystem.foe_for(self)
		if foe != null:
			return foe
	# Outpost (package B): neutral guards do not notice the hero. Hostility
	# starts at faction reputation < 0 or from the hero's hit (provoked).
	if not is_hostile_to_hero():
		return null
	var player = get_tree().get_first_node_in_group("player")
	if is_instance_valid(player) and not Game.hero_dead:
		var dp := Game.units_range(self, player)
		var committed := state == "chase" or state == "attack" or state == "flee"
		var lim := deaggro_radius if committed else aggro_radius
		lim *= StatusEffects.vision_mult(self)   # Darkness narrows the vision
		if StatusEffects.is_invisible(player) and not committed:
			lim = 40.0
		if dp < lim:
			return player
	var best: Node2D = null
	var bd := deaggro_radius * StatusEffects.vision_mult(self)
	# Culling (29.10): exact geometry only for those NPCs that can
	# be within range; iterating all 28 residents with hitbox math
	# for every ticking enemy — that was the second half of the city frame drop.
	var reach := bd + 128.0
	var reach_sq := reach * reach
	for n in Game.npcs:
		if n == null or not is_instance_valid(n):
			continue
		if not (n is Npc) or n.role != "guard":
			continue
		if StatusEffects.is_invisible(n):
			continue
		var npos: Vector2 = (n as Node2D).global_position
		var dx := npos.x - global_position.x
		var dy := npos.y - global_position.y
		if dx * dx + dy * dy > reach_sq:
			continue
		var d := Game.units_range(self, n)
		if d < bd:
			bd = d
			best = n
	return best

## Can this unit hit the hero. Empty faction — a regular monster (always).
## Outpost: hostility at faction reputation < 0 or after the hero's hit.
func is_hostile_to_hero() -> bool:
	if faction == "":
		return true
	if provoked:
		return true
	return Game.hero_reputation(faction) < 0


## Chase with obstacle avoidance. Replanning about once per 1.2 s + random
## start, so 75 enemies do not call find_path in the same frame (stutters).
func _chase_move(delta: float, target: Node2D) -> void:
	var tpos: Vector2 = target.global_position
	var dist := global_position.distance_to(tpos)
	# A distant target — straight line; path only when there are real obstacles.
	if _path.is_empty() or dist > 400.0:
		_repath -= delta
		if _repath <= 0.0:
			_repath = 1.2 + randf() * 0.6
			var map_node = get_tree().get_first_node_in_group("alm_map")
			if map_node != null and map_node.has_method("find_path") and dist < 500.0:
				_path = map_node.find_path(global_position, tpos)
	if _path.size() > 0:
		var wp: Vector2 = _path[0]
		if global_position.distance_to(wp) <= 8.0:
			_path.pop_front()
		if _path.size() > 0:
			wp = _path[0]
			_move_checked(Game.safe_dir(global_position, wp), effective_speed(), delta)
		else:
			# The path ended — go straight to the target (do not freeze).
			_move_checked(Game.safe_dir(global_position, tpos), effective_speed(), delta)
	else:
		_move_checked(Game.safe_dir(global_position, tpos), effective_speed(), delta)

## --- Derived stats (from monster data, like the hero) ---
## Applied through Game.unit_*: attack->accuracy, defense->evasion,
## absorption->armor, protections -> element resistance (for magic).

func get_attack() -> int:
	return int(damage / float(GameConfig.geti("combat", "enemy_attack_dmg_div"))) \
		+ int(max_hp / float(GameConfig.geti("combat", "enemy_attack_hp_div"))) \
		+ StatusEffects.stat_flat(self, "attack")

func get_defense() -> int:
	var base := int(max_hp / float(GameConfig.geti("combat", "enemy_defense_div")))
	return int(round((base + StatusEffects.stat_flat(self, "defense")) * StatusEffects.defense_mult(self)))

func get_absorption() -> int:
	return int(max_hp / float(GameConfig.geti("combat", "enemy_absorption_div")))

## Element resistance — from the set data (assets/units/units_db.json, field
## "resist"). Before it was max_hp/60, which made a boss with high HP
## almost immune to one element.
func _resist(sphere: String) -> int:
	return UnitDB.resist_of(anim_set, sphere) + StatusEffects.resist_bonus(self, sphere)

func get_protection_fire() -> int:   return _resist("Fire")
func get_protection_water() -> int:  return _resist("Water")
func get_protection_air() -> int:    return _resist("Air")
func get_protection_earth() -> int:  return _resist("Earth")
func get_protection_astral() -> int: return _resist("Astral")

## Speed with Haste/Slow (move_speed is the base, cannot be cached).
func effective_speed() -> float:
	return move_speed * StatusEffects.speed_mult(self)

## Vision with Darkness (Vision ×0.5 etc.).
func effective_sight() -> int:
	return maxi(1, int(get_sight() * StatusEffects.vision_mult(self)))

## Vision in cells (affects the aggro radius — as requested: "vision -> aggro").
func get_sight() -> int:
	return maxi(1, int(move_speed / 8.0) + int(max_hp / 60.0))

## Single incoming damage point: called from Game.deal_damage
## (miss, armor absorption and element protections are already applied there).
## Returns the HP actually removed (after the shield) — Game.deal_damage draws it.
func take_damage(dmg: int, attacker) -> int:
	# A dead monster (corpse/decay) takes no damage — otherwise repeated
	# loot/sounds when swinging at a corpse
	if state == "dying" or state == "decay" or state == "corpse":
		return 0
	if dmg <= 0:
		return 0
	# The hero hit a skirmish participant — it leaves the event and answers the hero.
	if foe_group != "" and is_instance_valid(attacker) \
			and (attacker as Node).is_in_group("player"):
		event_tag = ""
		foe_group = ""
	# A neutral outpost guard becomes hostile after the hero's hit.
	if faction != "" and is_instance_valid(attacker) \
			and (attacker as Node).is_in_group("player"):
		provoked = true
		# They hit the camp — the whole camp rises, not a single guard: otherwise
		# the outpost would be cleared one by one with impunity.
		if outpost_id != "":
			for other in Game.enemies:
				if other == null or not is_instance_valid(other) or other == self:
					continue
				if str(other.get("outpost_id")) == outpost_id:
					other.set("provoked", true)
	# Before, a shield on an enemy did not work: shield_reduce was not called here
	var shielded := Game.shield_reduce(self, dmg)
	if shielded <= 0:
		SpellVFX.shield_hit(self)
		return 0
	current_hp -= shielded
	# On taking damage — start the chase immediately (but do not interrupt the current attack,
	# otherwise after every hit the monster resets the swing)
	if is_instance_valid(attacker):
		if state != "attack":
			state = "chase"
			attack_target = attacker
	if current_hp <= 0:
		SoundDB.play(_unit_sound_at(4))  # death
		# Remove from the enemy list: the hero stops choosing the corpse as a target
		Game.enemies.erase(self)
		EventSystem.note_freed()
		_drop_loot()
		# Outpost: the death of the guards may clear the camp (package B).
		if outpost_id != "":
			Game.on_outpost_guard_died(self)
		state = "dying"
		attack_target = null
		velocity = Vector2.ZERO
		# The corpse does not block movement (complaint: "I trip over loot" — it was the corpse
		# keeping collision_layer=1 for another 5–8 seconds).
		collision_layer = 0
		collision_mask = 0
		if health_bar:
			health_bar.visible = false  # the corpse does not show the bar
		died.emit(self)
	else:
		SoundDB.play_pain(UnitDB.unit_sound(anim_set))  # pain
	return shielded

## Unit sound ID by position in the Sound array (attack/pain1/pain2/death).
func _unit_sound_at(idx: int) -> String:
	return str(SoundDB.sound_at(UnitDB.unit_sound(anim_set), idx))

func _drop_loot():
	# The bag is gone (03.10): the player immediately sees what dropped. The class was renamed
	# loot_bag.gd -> loot_drop.gd, hence the new path and new name here.
	var drop_script: GDScript = load("res://scripts/loot_drop.gd")
	if drop_script == null:
		return
	var drop: LootDrop = drop_script.new()
	drop.items = _make_loot()
	# Potion bottle size by enemy power: an ant corpse and a boss corpse must not
	# look the same. The thresholds are the same as in npc.gd:_potion_size.
	drop.potion_size = "large" if max_hp >= 100 else ("medium" if max_hp >= 55 else "small")
	# Loot at relief height (the unit is lifted to the hill height; without this the icons
	# "sink" below ground level by the relief height)
	var h := _relief_here()
	drop.global_position = global_position + Vector2(randf_range(-22, 22), randf_range(-16, 16) - h)
	# Parent, not get_tree().current_scene: the latter is null in
	# headless scripts and when spawning a unit from a test.
	var host := get_parent()
	if host == null:
		host = get_tree().current_scene
	if host != null:
		host.add_child(drop)

## Relief height under the unit (0 if there is no map).
func _relief_here() -> float:
	var map_node := get_tree().get_first_node_in_group("alm_map")
	if map_node != null and map_node.has_method("relief_at_world"):
		return float(map_node.call("relief_at_world", global_position))
	return 0.0

## Loot by SPECIES family (loot_tables.json + UnitDB.loot_family_of).
## Beasts/insects: gold + herb, WITHOUT weapons/armor (player's decision 07.10).
##
## GEAR DROPS BROKEN SINCE 22.10. The reason is not aesthetics: an intact item
## is melted by the workshop at the "intact" rate (0.8 of the recipe,
## CraftDB.INTACT_RECYCLE_MULT), and it bypassed the broken-quality rate
## (1/2/4 ingots). The player saved intact items from Greys and got ingots past
## the quality. The metal of a broken item is chosen BY ENEMY TIER
## (ItemDB.broken_materials), otherwise a rookie beast would drop radium.
##
## There are TWO items: own gear (armor or weapon) and, with a chance
## `garment_share`, clothing. That was the case before the switch to broken items, but later
## clothing ended up in the same probability line and started eating the armor chance.
func _make_loot() -> Array:
	var family := UnitDB.loot_family_of(anim_set)
	if family == "":
		family = "default"
	var table := _loot_table(family)
	var pool: Array = []
	var gold_mult := float(table.get("gold_mult", 0.6)) * GameConfig.getf("economy", "loot_gold_multiplier")
	var gold_base := 4 + int(max_hp / 5.0)
	var gold := int(round(float(gold_base + randi() % gold_base) * gold_mult))
	if gold > 0:
		pool.append({"gold": gold})
	if randi() % 100 < int(table.get("potion_chance", 20)):
		pool.append({"key": "Potion Medium Healing" if randi() % 2 == 0 else "Potion Mana Regeneration"})
	if randi() % 100 < int(table.get("broken_gear_chance", 20)):
		pool.append_array(_broken_gear(int(table.get("garment_share", 0))))
	# An INTACT item is a rare bonus: bosses and dragons have their own chance
	# ([craft] boss_intact_chance), regular Greys use intact_gear_chance from
	# the table (0 for monstrous).
	var intact_chance := GameConfig.geti("craft", "boss_intact_chance") \
		if UnitDB.is_boss(anim_set) else int(table.get("intact_gear_chance", 0))
	if randi() % 100 < intact_chance:
		var intact := _random_intact_gear()
		if not intact.is_empty():
			pool.append(intact)
	# Faction tag (forge rework package B): an outpost guard carries its own
	# tag always — the player's decision on 28.10 "they drop in any case". This is not
	# luxury, but the only source of the faction ingredient for armor.
	if faction != "":
		var tag := ItemDB.tag_key(faction)
		if tag != "" and not ItemDB.find(tag).is_empty():
			pool.append({"key": tag})
	# Magic essence is the second source alongside the tailor (07.10).
	if randi() % 100 < int(table.get("essence_chance", 0)):
		pool.append({"key": CraftDB.ESSENCE_KEY})
	if randi() % 100 < int(table.get("herb_chance", 0)):
		var herbs: Array = table.get("herbs", [])
		if herbs.size() > 0:
			pool.append({"key": str(herbs[randi() % herbs.size()])})
	return pool


## Loot table from assets/config/loot_tables.json (cached per process).
static var _loot_tables_cache: Dictionary = {}
static var _loot_tables_loaded: bool = false


static func _loot_table(family: String) -> Dictionary:
	if not _loot_tables_loaded:
		_loot_tables_loaded = true
		var path := "res://assets/config/loot_tables.json"
		if ResourceLoader.exists(path):
			var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
			if parsed is Dictionary:
				_loot_tables_cache = parsed as Dictionary
	var t: Dictionary = _loot_tables_cache.get(family, {})
	if t.is_empty():
		t = _loot_tables_cache.get("default", {})
	return t

## Categories and materials of items a Grey wore, for ItemDB.roll_broken_gear.
## A pair "gear + possibly clothing": gear metal — by tier
## (_gear_tier), clothing — linen.
func _gear_options(garment_share: int) -> Array:
	var own := ItemDB.broken_materials("Armor", _gear_tier())
	var options: Array = [
		{"materials": own, "categories": ["Armor", "Weapon"]},
	]
	if garment_share > 0 and randi() % 100 < garment_share:
		options.append({"materials": ItemDB.broken_materials("Garment", _gear_tier()),
			"categories": ["Garment"]})
	return options


## Broken items in the bag: quality, metal and key selection — in
## ItemDB.roll_broken_gear (the same helper is called by NPCs, npc.gd:_random_gear).
func _broken_gear(garment_share: int) -> Array:
	var out: Array = []
	for opt in _gear_options(garment_share):
		var gear := ItemDB.roll_broken_gear(
			(opt as Dictionary).get("materials", []), (opt as Dictionary).get("categories", []))
		if not gear.is_empty():
			out.append(gear)
	return out


## Grey tier (1..5): the set's `tier` field, and when absent — the `_t<N>`
## name suffix. The metal of a broken item grows with the tier (ItemDB.broken_materials):
## a tier 1 wolf must not drop radium.
func _gear_tier() -> int:
	var t := UnitDB.tier(anim_set)
	if t > 0:
		return t
	var short := anim_set.get_file()
	var at := short.rfind("_t")
	if at > 0 and short.substr(at + 2).is_valid_int():
		return int(short.substr(at + 2))
	return 1

## A random INTACT item "by enemy power" (budget = HP × 12), from the real database.
## Only for the rare bonus (intact_gear_chance / bosses): the regular flow
## of gear from Greys is broken (_broken_gear).
func _random_intact_gear() -> Dictionary:
	var budget := maxi(20, max_hp * 12)
	var pool: Array = []
	for it in ItemDB.all():
		if not ItemDB.is_equippable(it):
			continue
		var p := int(it.get("price", 0))
		if p > 0 and p <= budget:
			pool.append(it)
	if pool.is_empty():
		return {}
	return {"key": str((pool[randi() % pool.size()] as Dictionary).get("key", ""))}
