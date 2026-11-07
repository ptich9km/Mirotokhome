class_name AlmObstacle
extends Node2D
## НЕПОДВИЖНЫЙ объект карты-препятствие (.alm obstacle): дерево/камень/статуя.
## Отрисовка и анимация как в Allods16: спрайт с якорем (cx,cy) + отдельная
## тень (spritesb-xxx.png), поднимается на высоту рельефа под собой.
## Два режима кадров:
##  - phases > 1 — анимация (деревья: 7 кадров покачивания), кадры листаются;
##  - phases == 1 — ВАРИАНТ внешнего вида: кадр = index (камни/заборы/кости).

var folder := ""            # имя папки спрайтов: "pine1", "maple2/dead"
var frame_count := 1
# Destructible world object (04.11): HP comes from
# assets/map-objects/destructibles.json. 0 = indestructible (e.g. lantern).
signal destroyed(at: Vector2i)
var cell := Vector2i(-1, -1)
var hp := 0
var max_hp := 0
var destructible := false
var broken := false
var base_index := 0         # вариант кадра (0-based) для phases==1
var reg_w := 128            # размер из реестра (для нормировки якоря)
var reg_h := 128
var cx := 64.0              # якорь в пикселях реестра
var cy := 80.0

var _frame := 0
var _timer := 0.0
var _sprite: Sprite2D
var _shadow: Sprite2D
var _tex_w := 32
var _tex_h := 32
var _frames_dir := ""       # каталог кадров

## Кэш текстур: load() в _apply_frame на КАЖДЫЙ кадр анимации у сотен деревьев
## роняет кадр на любом железе. Ключ — путь, значение — Texture2D.
static var _tex_cache: Dictionary = {}

const FRAME_TIME := 0.5     # секунд на кадр (как у ObjectDB.DEFAULT_FRAME_TIME)

static func _load_cached(path: String) -> Texture2D:
	if _tex_cache.has(path):
		return _tex_cache[path]
	var tex: Texture2D = null
	if ResourceLoader.exists(path):
		tex = load(path)
	_tex_cache[path] = tex
	return tex

func setup(obs_folder: String, n_frames: int, w: int, h: int, a_cx: int, a_cy: int, index: int = 0,
		hp_value: int = 0) -> void:
	folder = obs_folder
	hp = maxi(hp_value, 0)
	max_hp = hp
	destructible = hp > 0
	broken = false
	frame_count = maxi(n_frames, 1)
	base_index = maxi(index, 0)
	reg_w = maxi(w, 1)
	reg_h = maxi(h, 1)
	cx = float(a_cx)
	cy = float(a_cy)
	_frames_dir = "res://assets/map-objects/%s" % folder
	# Real frames on disk: a folder may hold fewer frames than the DB "phases".
	var frame_numbers: Array = AssetFrames.numbers(_frames_dir, "sprites-")
	# A pack may hide the listing entirely — probe the first frame instead.
	if frame_numbers.is_empty() and ResourceLoader.exists("%s/sprites-001.png" % _frames_dir):
		frame_numbers = [1]
	var max_frames := 0
	for num in frame_numbers:
		max_frames = maxi(max_frames, int(num))
	if max_frames > 0:
		frame_count = mini(frame_count, max_frames)
	else:
		# Folder is absent (e.g. fire variants were never extracted): draw nothing.
		frame_count = 0
	_apply_frame()
	_setup_shadow()
	# Статичные варианты (камни/заборы) не анимируются — сразу выключаем process.
	# Иначе Godot всё равно зовёт _process у тысяч узлов каждый кадр.
	if frame_count <= 1 or base_index > 0:
		set_process(false)
	else:
		# Фаза анимации: не давать ВСЕМ деревьям менять кадр в один тик
		# (жалоба 07.10: FPS просел после плотности ~2800 деревьев).
		_timer = randf() * FRAME_TIME

## Создать тень (spritesb-NNN.png) — силуэт объекта; рисуется ПОД спрайтом.
func _setup_shadow() -> void:
	if _shadow == null:
		_shadow = Sprite2D.new()
		_shadow.name = "Shadow"
		_shadow.centered = false
		_shadow.z_index = -1   # под самим объектом (но над землёй)
		add_child(_shadow)
	var idx: int = _pick_frame()
	var tex: Variant = _load_cached("%s/spritesb-%03d.png" % [_frames_dir, idx + 1])
	if tex == null:
		_shadow.visible = false
		return
	_shadow.visible = true
	_shadow.texture = tex
	_shadow.modulate = Color(0.15, 0.15, 0.2, 0.55)  # полупрозрачная тень

## Какой кадр показывать: для phases==1 (вариант) — base_index, иначе кадр анимации.
func _pick_frame() -> int:
	if frame_count <= 1:
		return 0
	if base_index > 0 and frame_count > 1:
		# Варианты внешнего вида (phases==1): кадр из objects.txt Index
		return base_index % frame_count if base_index < frame_count else 0
	return _frame % frame_count

func _apply_frame() -> void:
	if _sprite == null:
		_sprite = Sprite2D.new()
		_sprite.name = "Sprite"
		_sprite.centered = false
		add_child(_sprite)
	if frame_count <= 0:
		visible = false
		return
	var idx: int = _pick_frame()
	var tex: Variant = _load_cached("%s/sprites-%03d.png" % [_frames_dir, idx + 1])
	if tex == null:
		visible = false
		return
	visible = true
	_sprite.texture = tex
	_tex_w = tex.get_width()
	_tex_h = tex.get_height()

## Позиция: узел стоит в ТОЧКЕ ЗЕМЛИ, спрайт смещён внутри на якорь
## (cx, cy) от реестрового размера, как в Allods16.
##
## Именно так, а не position узла = левый верхний угол спрайта. Сортировка
## по Y у Godot идёт по position узла, поэтому при старой схеме сортировались
## ВЕРШИНЫ спрайтов, а не земля: чем объект выше, тем раньше он рисуется.
## Камень (h=56) оказывался на 72 px "выше" дерева (h=128) и перекрывал его,
## хотя стоял на клетку выше по ряду — жалоба игрока 10.10.
func place_at(cell_pos: Vector2i, tile: int, relief: float) -> void:
	cell = cell_pos
	var x := cell.x * tile + tile / 2.0
	var y := cell.y * tile + tile / 2.0 - relief
	position = Vector2(x, y)
	_apply_offsets()

## Смещение спрайтов внутри узла. Тень выравнивается так же, иначе после
## переноса якоря в спрайт она уехала бы в угол.
func _apply_offsets() -> void:
	var off := Vector2(
		-cx / float(reg_w) * float(_tex_w),
		-cy / float(reg_h) * float(_tex_h))
	if _sprite != null:
		_sprite.offset = off
	if _shadow != null:
		_shadow.offset = off

func _process(delta: float) -> void:
	if frame_count <= 1 or base_index > 0:
		return   # статичный вариант — не анимируем
	# Вне камеры — не тикаем (draw всё равно culится движком, CPU щадим).
	if not _in_camera_view():
		return
	_timer += delta
	if _timer >= FRAME_TIME:
		_timer = 0.0
		_frame = (_frame + 1) % frame_count
		_apply_frame()


## Примерно в кадре ли объект (с запасом под shake/lerp камеры).
func _in_camera_view() -> bool:
	var vp := get_viewport()
	if vp == null:
		return true
	var cam := vp.get_camera_2d()
	if cam == null:
		return true
	var vs: Vector2 = vp.get_visible_rect().size
	var zoom: Vector2 = cam.zoom
	if zoom.x <= 0.0 or zoom.y <= 0.0:
		zoom = Vector2.ONE
	var half := Vector2(vs.x * 0.5 / zoom.x, vs.y * 0.5 / zoom.y) + Vector2(96, 96)
	var center: Vector2 = cam.get_screen_center_position()
	var rect := Rect2(center - half, half * 2.0)
	return rect.has_point(global_position)

## Area-spell damage. Returns true only when the object actually lost HP:
## indestructible props (lanterns) and already broken nodes ignore it.
func take_damage(dmg: int) -> bool:
	if broken or not destructible or dmg <= 0:
		return false
	hp -= dmg
	_flash_hit()
	if hp <= 0:
		_break_apart()
	return true

func _flash_hit() -> void:
	if _sprite == null:
		return
	_sprite.modulate = Color(1.45, 1.3, 1.1)
	var t := create_tween()
	t.tween_property(_sprite, "modulate", Color.WHITE, 0.12)

## The map clears the obstacle cell immediately, so pathfinding sees the hole
## at once; the sprite fades out so the hit still reads on screen.
func _break_apart() -> void:
	broken = true
	hp = 0
	set_process(false)
	if _shadow != null:
		_shadow.visible = false
	destroyed.emit(cell)
	if _sprite == null:
		queue_free()
		return
	var t := create_tween()
	t.tween_property(_sprite, "modulate:a", 0.0, 0.15)
	t.tween_callback(queue_free)