class_name ArrowShot
extends Node2D
## A mercenary archer's arrow. Flies to the target and deals PHYSICAL damage
## through the shared `Game.deal_damage`, so armour and the Allods weapon-kind
## table work exactly as for a melee blow: the shooter counts as a "bow" weapon
## (`Game.weapon_kind_of` reads the `weapon` field), which gives 125 % against
## beasts and 75 % against the undead.
##
## Why not the spell `Projectile`: that one is magic-only (`"magic"` + a sphere),
## draws a procedural spell core from `SpellVFX` and explodes with a spell aura.
## An arrow is a plain physical shot with its own small trail, so it lives here.

const HIT_RADIUS := 10.0
const MAX_FLIGHT := 3.0

var from_pos: Vector2
var to_pos: Vector2
var target: Node2D
var shooter: Node2D
var damage: int = 6
var speed: float = 520.0

var _elapsed := 0.0
var _line: Line2D


func _ready() -> void:
	# Tactical pause must stop the arrow, as it stops spell projectiles.
	process_mode = PROCESS_MODE_PAUSABLE
	global_position = from_pos
	z_index = 5
	_line = Line2D.new()
	_line.width = 2.0
	_line.default_color = Color(0.24, 0.16, 0.09)
	_line.antialiased = false
	_line.points = PackedVector2Array([Vector2(-9, 0), Vector2(4, 0)])
	add_child(_line)
	# The tip: a short brightened segment reads as a metal head at 32 px.
	var tip := Line2D.new()
	tip.width = 3.0
	tip.default_color = Color(0.72, 0.70, 0.66)
	tip.points = PackedVector2Array([Vector2(2, 0), Vector2(7, 0)])
	add_child(tip)
	_aim()


func _process(delta: float) -> void:
	_elapsed += delta
	if _elapsed > MAX_FLIGHT:
		queue_free()
		return
	# Home to the CURRENT target position: a step sideways must not dodge a shot.
	if is_instance_valid(target):
		to_pos = target.global_position + Vector2(0.0, -8.0)
	var to_target := to_pos - global_position
	var dist := to_target.length()
	var step := speed * delta
	if dist <= maxf(HIT_RADIUS, step):
		_hit()
		return
	global_position += to_target / dist * step
	_aim()


func _aim() -> void:
	if _line == null:
		return
	rotation = (to_pos - global_position).angle()


func _hit() -> void:
	if is_instance_valid(target) and is_instance_valid(shooter):
		Game.deal_damage(target, damage, "physical", "", shooter)
	queue_free()
