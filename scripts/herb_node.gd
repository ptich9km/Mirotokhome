class_name HerbNode
extends Area2D
## A gatherable herb on the map. Regrows after a while.
##
## The sprite is static by default (one frame). `frame_count`/`fps` come from
## HerbDB, so the moment an animated strip replaces a still icon the herb starts
## swaying without touching this class - the same data path as LootDrop bottles.

const REGROW_SECONDS := 180.0

var item_key := ""
var icon_path := ""
var cell := Vector2i(-1, -1)
var regrow_seconds := REGROW_SECONDS
var available := true
var tier := 1

var _sprite: Sprite2D
var _frames: Array[Texture2D] = []
var _fps := 0
var _frame_index := 0
var _frame_accum := 0.0


func setup(key: String, path: String, grid_cell: Vector2i, relief: float,
		frame_count: int = 1, fps: int = 0) -> void:
	item_key = key
	icon_path = path
	cell = grid_cell
	tier = HerbDB.tier_of(key)
	position = Vector2(grid_cell.x * 32 + 16, grid_cell.y * 32 + 16 - relief)
	monitoring = false
	monitorable = false
	_sprite = Sprite2D.new()
	_sprite.name = "HerbSprite"
	_sprite.texture = load(path) as Texture2D
	_sprite.centered = true
	add_child(_sprite)
	_fps = maxi(0, fps)
	_frames = _load_frames(path, frame_count)
	## Start on frame 0, not on the still icon: the frames are drawn by a
	## different tool than the icon and occupy a slightly different box, so
	## showing the icon for the first 1/fps s reads as a flicker.
	if not _frames.is_empty():
		_sprite.texture = _frames[0]
	var shape := CircleShape2D.new()
	shape.radius = 18.0
	var collision := CollisionShape2D.new()
	collision.shape = shape
	add_child(collision)


## Animated strips live next to the still icon as `<name>_frame00.png` ...
## `<name>_frameNN.png`. A missing strip falls back to the still icon, so the
## data may promise animation before the art exists.
func _load_frames(path: String, frame_count: int) -> Array[Texture2D]:
	var out: Array[Texture2D] = []
	if frame_count <= 1 or _fps <= 0:
		return out
	var base := path.get_basename()
	for index in range(frame_count):
		var frame_path := "%s_frame%02d.png" % [base, index]
		if not ResourceLoader.exists(frame_path):
			out.clear()
			return out
		out.append(load(frame_path) as Texture2D)
	return out


func _ready() -> void:
	add_to_group("herb_resource")
	set_process(not _frames.is_empty())


func _process(delta: float) -> void:
	if _frames.is_empty() or not is_instance_valid(_sprite):
		return
	_frame_accum += delta
	var step := 1.0 / float(_fps)
	while _frame_accum >= step:
		_frame_accum -= step
		_frame_index = (_frame_index + 1) % _frames.size()
		_sprite.texture = _frames[_frame_index]


func is_available() -> bool:
	return available


func contains_point(world_position: Vector2) -> bool:
	return available and global_position.distance_to(world_position) <= 28.0


func harvest() -> bool:
	if not available:
		return false
	available = false
	if is_instance_valid(_sprite):
		_sprite.visible = false
	var timer := get_tree().create_timer(regrow_seconds)
	timer.timeout.connect(_restore)
	return true


func _restore() -> void:
	if not is_inside_tree():
		return
	available = true
	if is_instance_valid(_sprite):
		_sprite.visible = true
