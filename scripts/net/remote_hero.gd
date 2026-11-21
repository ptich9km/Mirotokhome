class_name RemoteHero
extends CharacterBody2D
## The OTHER player's hero on this machine (21.11).
##
## It is not a Player: no input, no camera, no inventory, no AI. Its body is a
## follower of the state the owner sends (position, animation, direction, HP),
## and it is the target the local monsters hit.
##
## Damage direction: when a local monster hits this body, the hit is FORWARDED
## to the owner, because the owner is the only one who owns that hero's HP,
## mana, shields and death. The body keeps a display HP for its bar and for the
## target calculations.

const BAR_WIDTH := 48.0
const APPEARANCE_KEYS := ["anim_set", "name", "level", "max_hp"]

var owner_peer: int = 0
var hero_name: String = ""
var level: int = 1
var max_hp: int = 100
var max_mana: int = 0
var current_hp: int = 100
var current_mana: int = 0
var is_dead: bool = false

## Combat stats replicated once at join: the local damage math needs them,
## otherwise every monster hit on this body ignored the hero's armour.
var stat_attack: int = 10
var stat_defense: int = 0
var stat_absorption: int = 0
var stat_protection: Dictionary = {}

var health_bar: HealthBar = null
var _anim: UnitAnimBase = null
var _nameplate: Label = null
var _facing := Vector2.DOWN
var _anim_kind := UnitAnim.Anim.IDLE
var _target_pos := Vector2.ZERO
var _has_target := false

func _ready() -> void:
	# Remote bodies must NOT be in the "player" group: loot and the local UI
	# resolve the local hero through it (21.11).
	add_to_group("remote_hero")
	collision_layer = 0
	collision_mask = 0

## info comes from the owner's hero_join message.
func setup(info: Dictionary) -> void:
	owner_peer = int(info.get("peer", 0))
	hero_name = str(info.get("name", "?"))
	level = int(info.get("level", 1))
	max_hp = maxi(1, int(info.get("max_hp", 100)))
	max_mana = maxi(0, int(info.get("max_mana", 0)))
	current_hp = clampi(int(info.get("hp", max_hp)), 0, max_hp)
	current_mana = int(info.get("mana", 0))
	stat_attack = int(info.get("attack", 10))
	stat_defense = int(info.get("defense", 0))
	stat_absorption = int(info.get("absorption", 0))
	var prot: Variant = info.get("protection", {})
	stat_protection = prot if prot is Dictionary else {}
	_build_visual(str(info.get("anim_set", "")))
	_build_bar()
	_add_nameplate()
	_set_alive(current_hp > 0)

func _build_visual(set_name: String) -> void:
	if set_name == "":
		return
	for child in get_children():
		if child is UnitAnimBase:
			remove_child(child)
			child.queue_free()
	var a := UnitAnim.new()
	a.setup(set_name)
	a.name = "UnitAnim"
	add_child(a)
	_anim = a
	_anim.play(UnitAnim.Anim.IDLE, true)

## The other player's name above the figure: with two heroes on screen the
## bodies alone do not say who is who.
func _add_nameplate() -> void:
	var label := Label.new()
	label.name = "Nameplate"
	label.text = hero_name
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 11)
	label.add_theme_color_override("font_color", Color(0.92, 0.90, 0.78))
	label.position = Vector2(-60, -86)
	label.custom_minimum_size = Vector2(120, 0)
	add_child(label)
	_nameplate = label

## At war the other player is a target, and the colour says so (22.11).
func set_hostile(on: bool) -> void:
	if _nameplate == null or not is_instance_valid(_nameplate):
		return
	_nameplate.add_theme_color_override("font_color",
		Color(0.95, 0.34, 0.28) if on else Color(0.92, 0.90, 0.78))

func _build_bar() -> void:
	if health_bar != null and is_instance_valid(health_bar):
		health_bar.queue_free()
	health_bar = preload("res://scripts/health_bar.gd").new()
	health_bar.max_hp = max_hp
	health_bar.max_mana = max_mana
	health_bar.has_mana = max_mana > 0
	add_child(health_bar)
	health_bar.update_bars(current_hp, current_mana)

## State pushed by the owner at ~12 Hz.
func apply_state(pos: Vector2, anim: int, dir: Vector2, hp: int, mana: int) -> void:
	# 12 Hz on a straight line reads as stepping, so the body glides towards the
	# last reported point between packets.
	if not _has_target or global_position.distance_squared_to(pos) > 96.0 * 96.0:
		global_position = pos
	_has_target = true
	_target_pos = pos
	current_hp = clampi(hp, 0, max_hp)
	current_mana = mana
	if dir.length_squared() > 0.001:
		_facing = dir
	if _anim != null:
		if dir.length_squared() > 0.001:
			_anim.set_direction_vec(dir)
		if anim != _anim_kind:
			_anim_kind = anim
			_anim.play(anim)
	if health_bar != null and is_instance_valid(health_bar):
		health_bar.update_bars(current_hp, current_mana)
	_set_alive(current_hp > 0)

func _process(delta: float) -> void:
	if _has_target:
		global_position = global_position.lerp(_target_pos, minf(1.0, 16.0 * delta))

func _set_alive(alive: bool) -> void:
	is_dead = not alive
	if _anim == null:
		return
	if not alive:
		_anim.play(UnitAnim.Anim.DYING, true)
	if health_bar != null and is_instance_valid(health_bar):
		health_bar.visible = alive

## A local monster hit this body: the owner applies the real damage.
func take_damage(dmg: int, _attacker: Node2D) -> int:
	if is_dead or dmg <= 0:
		return 0
	var s := NetSession.active()
	if s != null:
		s.send_hero_hit(dmg)
	return dmg

func reset_death_state() -> void:
	_set_alive(true)
	_anim_kind = UnitAnim.Anim.IDLE
	if _anim != null:
		_anim.play(UnitAnim.Anim.IDLE, true)

# --- stats used by the shared damage math -----------------------------------

func get_attack() -> int:
	return stat_attack

func get_defense() -> int:
	return stat_defense

func get_absorption() -> int:
	return stat_absorption

func get_protection_fire() -> int:   return int(stat_protection.get("Fire", 0))
func get_protection_water() -> int:  return int(stat_protection.get("Water", 0))
func get_protection_air() -> int:    return int(stat_protection.get("Air", 0))
func get_protection_earth() -> int:  return int(stat_protection.get("Earth", 0))
func get_protection_astral() -> int: return int(stat_protection.get("Astral", 0))

func is_dead_body() -> bool:
	return is_dead
