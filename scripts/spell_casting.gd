class_name SpellCasting
extends RefCounted
## Spell effects that ANY caster can produce: the hero, a mercenary, a summoned
## minion. Before, every one of them lived inside `player.gd`, so a mercenary
## mage could only swing a staff: duplicating the wall/zone/chain code was the
## only alternative, and two copies of magic drift apart.
##
## Each function takes the caster as a `Node2D`: `Game.deal_damage`,
## `Game.spell_damage`, `StatusEffects` and `SpellVFX` already accept any unit.
## The caller owns its own cast animations, sounds and experience.

## Spell projectile with the animation of `assets/projectiles/<folder>/`.
## The projectile dies with the caster (a scene change or a freed unit must not
## leave a stray flying node behind that holds a reference to a dead owner).
static func launch_projectile(caster: Node2D, spell_name: String, from: Vector2,
		to: Vector2, damage: int, area: float) -> void:
	if caster == null or not is_instance_valid(caster):
		return
	if SpellDB.projectile_folder(spell_name) == "":
		return
	var scene: PackedScene = load("res://scenes/projectile.tscn")
	if scene == null:
		return
	var p: Projectile = scene.instantiate()
	p.start_pos = from
	p.target_pos = to
	p.damage = damage
	p.projectile_owner = caster
	p.spell_name = spell_name
	p.spell_area = area
	p.speed = SpellDB.projectile_speed_of(spell_name)
	var scene_root := caster.get_tree().current_scene if caster.is_inside_tree() else null
	if scene_root != null:
		scene_root.add_child(p)
	else:
		caster.get_tree().root.add_child(p)


## A zone with a duration (blizzard, poison cloud): the ground area deals
## damage and applies its effects (slow, poison) to everyone standing in it.
static func cast_zone(caster: Node2D, spell_name: String, sphere: String,
		target_position: Vector2, damage: int) -> void:
	var spell := SpellDB.get_spell(spell_name)
	var style := str(spell.get("zone_style", "cloud"))
	var life := float(spell.get("zone_life", 4.0))
	var cells := zone_cells(spell, Vector2i(3, 3))
	SpellVFX.spawn_zone(target_position, style, sphere, caster, life, cells, damage, 0.5)
	StatusEffects.apply_area(target_position, zone_radius(cells), spell, caster)


## A wall (Wall of Fire / Wall of Earth). The wall is PERPENDICULAR to the cast
## direction: aiming left or right stands it vertically (2×6), up or down lays it
## horizontally (6×2). Damage, sprite and blocking take the size from one cell count.
static func cast_wall(caster: Node2D, spell_name: String, sphere: String,
		target_position: Vector2, origin: Vector2, damage: int) -> void:
	var spell := SpellDB.get_spell(spell_name)
	var mode := str(spell.get("wall_mode", "damage"))
	var life := float(spell.get("wall_life", 6.0))
	var cells := zone_cells(spell, Vector2i(6, 2))
	var aim := target_position - origin
	if absf(aim.x) >= absf(aim.y):
		cells = Vector2i(2, 6)
	SpellVFX.spawn_wall(target_position, sphere, caster, life, mode, cells,
		0 if mode == "block" else damage)


## Prismatic radiance and its kin: one cast, several targets, a lightning arc
## from the caster to each of them. Returns the targets that were hit — the
## caller decides what to do when the list is empty (the hero throws the
## projectile at the aim point so the cast is not wasted).
static func cast_chain(caster: Node2D, spell_name: String, target_position: Vector2,
		origin: Vector2, damage: int, area: float) -> Array:
	var reach := SpellDB.range_of(spell_name)
	var targets := chain_targets(target_position,
		maxf(area, GameConfig.getf("magic", "chain_radius")), origin, reach)
	if targets.is_empty():
		return targets
	var sphere := SpellDB.sphere_of(spell_name)
	var color_index := 0
	for t in targets:
		if not is_instance_valid(t):
			continue
		Game.deal_damage(t, damage, "magic", sphere, caster)
		SpellVFX.chain_arc(origin, t.global_position, sphere,
			SpellVFX.rainbow_color(color_index))
		SpellVFX.hit_flash(t)
		color_index += 1
	return targets


## Living enemies in the fan around the aim, but no farther than the spell
## reach from the caster. Sorted by distance to the aim point, capped by
## `[magic] chain_max_targets`.
static func chain_targets(aim: Vector2, radius: float, origin: Vector2,
		reach: float) -> Array:
	var found: Array = []
	for e in Game.enemies:
		if e == null or not is_instance_valid(e):
			continue
		# Node.get() in Godot 4 takes ONE argument, so the corpse state is read
		# through "a field on the node", not get("state", "").
		if "state" in e and str(e.get("state")) in ["dying", "decay", "corpse"]:
			continue
		if Game.fog != null and Game.fog.blocks_process(e.global_position):
			continue
		var pos: Vector2 = (e as Node2D).global_position
		if reach > 0.0 and origin.distance_to(pos) > reach:
			continue
		if pos.distance_to(aim) > radius:
			continue
		found.append(e)
	# Sorted by distance to the aim point so the beams fan out from the target.
	found.sort_custom(func(a: Node2D, b: Node2D) -> bool:
		return a.global_position.distance_squared_to(aim) \
			< b.global_position.distance_squared_to(aim))
	var out: Array = []
	for e in found:
		if out.size() >= GameConfig.geti("magic", "chain_max_targets"):
			break
		out.append(e)
	return out


## The zone size in cells from the database; the fallback when the field is missing.
static func zone_cells(spell: Dictionary, fallback: Vector2i) -> Vector2i:
	var raw: Variant = spell.get("zone_cells", null)
	if raw is Array and (raw as Array).size() >= 2:
		return Vector2i(maxi(1, int((raw as Array)[0])), maxi(1, int((raw as Array)[1])))
	return fallback


## The zone radius in pixels — half its diagonal, for area effects.
static func zone_radius(cells: Vector2i) -> float:
	return Vector2(cells.x * 32, cells.y * 32).length() * 0.5


## Whether a spell can be cast by a scripted caster that has no progression,
## mana or scroll: only the kinds whose effect does not need hero-only logic
## (Teleport, Summon, Animate_Dead, Light).
static func is_unit_castable(spell_name: String) -> bool:
	var spell := SpellDB.get_spell(spell_name)
	if spell.is_empty():
		return false
	var kind := str(spell.get("kind", ""))
	if kind in ["teleport", "raise", "self"]:
		return false
	if str(spell.get("projectile", "")) == "" and kind != "buff" and kind != "debuff":
		return false
	return true
