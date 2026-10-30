class_name PortalMarker extends Node2D
## Animated map marker: portal (teleport) or spawn (start point).

const TILE := 32

var _sprite: Sprite2D
var _shadow: Sprite2D
var _time := 0.0
var _frame := 0
var _frames: Array[Texture2D] = []
var _type: String = ""
var cell: Vector2i = Vector2i(-1, -1)

const FRAME_TIME := 0.15

func setup(pos: Vector2i, type: String) -> void:
	cell = pos
	_type = type
	_load_frames()
	# Position: cell center, anchor at the bottom of the sprite
	position = Vector2(pos.x * TILE + TILE / 2, pos.y * TILE + TILE / 2)

func _load_frames() -> void:
	var dir: String = ""
	var prefix: String = ""
	match _type:
		"portal":
			dir = "res://assets/sprites/portal/"
			prefix = "portal"
		"spawn_marker":
			dir = "res://assets/sprites/spawn/"
			prefix = "spawn"
		_:
			return
	for i in range(4):
		var path: String = "%s%s_frame_%02d.png" % [dir, prefix, i]
		if not ResourceLoader.exists(path):
			continue
		var tex: Texture2D = load(path)
		if tex != null:
			_frames.append(tex)
	# Sprite
	_sprite = Sprite2D.new()
	_sprite.centered = true
	if _frames.size() > 0:
		_sprite.texture = _frames[0]
	add_child(_sprite)
	# Shadow
	_shadow = Sprite2D.new()
	_shadow.centered = true
	_shadow.z_index = -1
	_shadow.modulate = Color(0.15, 0.15, 0.2, 0.45)
	if _frames.size() > 0:
		_shadow.texture = _frames[0]
	add_child(_shadow)

func _process(delta: float) -> void:
	if _frames.size() <= 1:
		return
	_time += delta
	if _time >= FRAME_TIME:
		_time -= FRAME_TIME
		_frame = (_frame + 1) % _frames.size()
		_sprite.texture = _frames[_frame]
		_shadow.texture = _frames[_frame]

func get_type() -> String:
	return _type

func get_cell() -> Vector2i:
	return cell
