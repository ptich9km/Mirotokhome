class_name MapObject
extends Node2D
## Игровой объект карты (map-objects): покадровая анимация из ObjectDB,
## HP и переход в разрушенный (dead) вид при уроне по области.

const DEFAULT_HP := 40

var obj_name := ""
var cell := Vector2i(-1, -1)
var hp: int = DEFAULT_HP
var destroyed := false
var destructible := false

var _sprite: Sprite2D
var _shadow: Sprite2D
var _frames: Array = []       # Texture2D кадры sprites-00N.png (1-based -> idx 0..)
var _anim_order: Array = []   # порядок кадров из anim_frame (индексы в _frames)
var _anim_times: Array = []   # длительность кадра в секундах
var _anim_idx := 0
var _time := 0.0

## Создать объект: name из ObjectDB, cell - клетка, extra - смещение спрайта (якорь).
## variant — индекс кадра для статичных объектов с вариантами (камни/заборы, Index из objects.txt).
## animated=false — редактор: показываем один кадр, без анимации (не грузит расписание).
func setup(name: String, cell_pos: Vector2i, tile_size: int, anchor: Vector2 = Vector2.ZERO, variant: int = 0, animated: bool = true) -> void:
	obj_name = name
	cell = cell_pos

	var o := ObjectDB.get_obj(name)
	destructible = ObjectDB.is_destructible(name)
	hp = DEFAULT_HP

	# Кадры анимации (1..frames)
	var frames: int = ObjectDB.frame_count(name)
	if frames < 1:
		frames = 1
	for i in range(1, frames + 1):
		var tex: Variant = load(ObjectDB.frame_path(name, i))
		if tex != null:
			_frames.append(tex)

	_sprite = Sprite2D.new()
	_sprite.centered = false   # рисуем от левого-верхнего угла, якорь через offset
	_sprite.offset = -anchor
	add_child(_sprite)

	# Data-driven size (20.11): "scale" in object_db lets one prop be drawn
	# smaller than its texture without touching the PNG. The anchor stays put:
	# the offset is applied before the node scale, so the anchor point still
	# maps to the origin.
	var sc := float(o.get("scale", 1.0))
	if sc > 0.0 and not is_equal_approx(sc, 1.0):
		_sprite.scale = Vector2(sc, sc)

	# Тень spritesb-NNN.png (у объектов Allods2 есть отдельный слой-силуэт)
	_shadow = Sprite2D.new()
	_shadow.centered = false
	_shadow.offset = -anchor
	_shadow.z_index = -1
	_shadow.scale = Vector2(sc, sc)
	add_child(_shadow)
	_apply_shadow(variant)

	# Порядок и тайминги анимации. Анимируем ТОЛЬКО если в базе явно задан
	# anim_frame (расписание) И объект не в "статичном" режиме (редактор).
	var raw_anim: Variant = o.get("anim_frame", null)
	if animated and raw_anim is Array and not raw_anim.is_empty():
		_anim_order = ObjectDB.anim_frames(name)
		_anim_times = ObjectDB.anim_times(name)
		if _anim_times.size() == _anim_order.size():
			_anim_idx = 0
			_time = 0.0
			_apply_frame(_anim_order[0])
		else:
			_anim_order = []
			_apply_frame(clampi(variant, 0, _frames.size() - 1))
			set_process(false)
	else:
		# Статичный объект - кадр варианта (или первый)
		_anim_order = []
		_apply_frame(clampi(variant, 0, _frames.size() - 1))
		set_process(false)
	_process_enabled_check()

## Тень spritesb-NNN.png — силуэт объекта (полупрозрачный, под спрайтом).
func _apply_shadow(variant: int) -> void:
	if _shadow == null:
		return
	var idx := clampi(variant, 0, maxi(_frames.size() - 1, 0))
	var tex: Variant = load("res://assets/map-objects/%s/spritesb-%03d.png" % [obj_name, idx + 1])
	if tex == null:
		_shadow.visible = false
		return
	_shadow.visible = true
	_shadow.texture = tex
	_shadow.modulate = Color(0.15, 0.15, 0.2, 0.55)

func _process_enabled_check() -> void:
	pass

func _apply_frame(idx: int) -> void:
	if idx >= 0 and idx < _frames.size():
		_sprite.texture = _frames[idx]

func _process(delta: float) -> void:
	if destroyed or _anim_order.is_empty():
		return
	_time += delta
	var t: float = _anim_times[_anim_idx % _anim_times.size()]
	if _time >= t:
		_time = 0.0
		_anim_idx += 1
		var idx: int = _anim_order[_anim_idx % _anim_order.size()]
		_apply_frame(idx)

## Урон по объекту. Если объект неразрушаем (нет dead-папки) - урон игнорируется.
func take_damage(dmg: int) -> void:
	if destroyed or not destructible:
		return
	hp -= dmg
	if hp <= 0:
		_destroy()

func _destroy() -> void:
	destroyed = true
	var dead := ObjectDB.dead_path(obj_name)
	var tex: Variant = load(dead) if dead != "" else null
	if tex != null:
		_sprite.texture = tex
	set_process(false)