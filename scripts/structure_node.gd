class_name StructureNode
extends Node2D
## Здание из .alm (структура).
##
## Два режима:
## 1) Сетка (Allods): кадры house-001..N по тайлам 32×32 (fw×fh) + тень houseb.
## 2) whole_image (арт Alice): ОДНА PNG на всё здание (house-001.png = весь дом),
##    без нарезки и без houseb — иначе Godot шумит «Resource not found».
##
## Сетка: frame = block * (fw*fh) + (fw*ly + lx) + 1.

const TILE := 32  # размер тайла структуры

var folder := ""          # папка спрайтов ("mill1", "church")
var fw := 1               # тайлов по X
var th := 1               # корпус по Y (стоит на этих рядах)
var fh := 1               # всего рядов по Y
var sel_box := Rect2i(0, 0, 96, 96)  # хитбокс выделения [x1,y1,w,h]
var shadow_y := 0         # сдвиг тени по Y из реестра
var use_anim := true      # проигрывать анимацию фаз, если есть
var max_blocks := 0       # ограничение числа блоков (0 = без ограничений)
var whole_image := false  # один спрайт house-001.png (не сетка тайлов)

var _blocks := 1          # число блоков кадров (база + фазы)
var _valid_blocks: Array = [0]  # блоки, пригодные для анимации (0 = база)
var _tiles: Array = []    # Sprite2D по тайлам (индекс = ly*fw+lx)
var _shadow_tiles: Array = []  # тени houseb по тайлам
var _phase := 0           # текущий блок анимации
var _timer := 0.0
var _times: Array = []    # длительности кадров-фаз (секунды)
var _active := false      # есть анимация

func _ready() -> void:
	if _tiles.is_empty():
		_build()

## Собрать спрайты. Может перестроить при смене данных.
func build() -> void:
	for s in _tiles:
		s.queue_free()
	for s in _shadow_tiles:
		s.queue_free()
	_tiles.clear()
	_shadow_tiles.clear()
	_phase = 0
	_build()

func _build() -> void:
	# --- Режим «одно здание = один файл» (Alice) ---
	if whole_image:
		_blocks = 1
		_valid_blocks = [0]
		_active = false
		var s := Sprite2D.new()
		s.name = "Whole"
		s.centered = false
		s.position = Vector2.ZERO
		var path := "res://assets/structures/%s/house-001.png" % folder
		if ResourceLoader.exists(path):
			s.texture = load(path)
		add_child(s)
		_tiles.append(s)
		_add_footprint_body()
		return

	# --- Сетка тайлов (Allods) ---
	# Определить число блоков по реальным кадрам в папке
	var grid := fw * fh
	# Frame numbers through AssetFrames: pack listings name imported textures
	# "<name>.png.import", a raw ".png" check would see no frames at all.
	var max_frame := 0
	for num in AssetFrames.numbers("res://assets/structures/%s" % folder, "house-"):
		max_frame = maxi(max_frame, int(num))
	if max_frame <= 0 and grid > 0:
		return  # папки нет — не рисуем
	# Полных блоков: floor. Неполный хвост (church 50 при grid 20, bridge3 36 при 24)
	# — частичная анимация — показываем только базу (без лишних фаз).
	_blocks = maxi(1, int(int(max_frame) / float(maxi(grid, 1))))
	if max_frame % grid != 0:
		_blocks = 1  # частичная анимация: статичная база
	# Ограничение по DB phases (чтобы не показывать лишние кадры, например у колодцев)
	if max_blocks > 0:
		_blocks = mini(_blocks, max_blocks)
	_phase = 0
	_active = use_anim and _blocks > 1

	# Отсев «мусорных» фаз: заглушка-пустышка (битый конверт) заменяет реальный
	# тайл фазы, и здание мигает дырками — выглядит как разрушенное.
	# Сравниваем КАЖДЫЙ тайл фазы с соответствующим тайлом базового блока, а не
	# абсолютные байты: легитимный «пустой» тайл (небо, угол) одинаково мал в обоих
	# блоках, а заглушка — в разы меньше базы. Абсолютный порог неприменим: пустые
	# тайлы есть и в здоровых анимациях (castle house-047 = 83 б, mill1 house-034),
	# и порог «меньше 160 байт» погасил бы 20 зданий, включая все лавки друидов.
	# Раньше проверялся только ПЕРВЫЙ тайл фазы, из-за чего битые пропускались:
	# у train1 house-013 = 190 б (порог проходит), а house-014 = 118 б и
	# house-015 = 83 б — крыша исчезала на второй фазе.
	#
	# Отбрасывается ТОЛЬКО битая фаза, а не вся анимация: у mill2 из 6 фаз бита
	# одна (house-030 = 83 б против базовых 325 б), и мельница должна крутиться.
	_valid_blocks = [0]
	if _active:
		for b in range(1, _blocks):
			if not _is_phase_broken(b, grid):
				_valid_blocks.append(b)
		_active = use_anim and _valid_blocks.size() > 1

	# Тайлы (все блоки берём из первого блока: блок 0 — база)
	for ly in range(fh):
		for lx in range(fw):
			var idx := _tiles.size()
			var ts := Sprite2D.new()
			ts.name = "Tile%d" % idx
			ts.position = Vector2(lx * TILE, ly * TILE)
			add_child(ts)
			_tiles.append(ts)
	# Тень: только если в папке ЕСТЬ houseb-001 (у Alice теней нет — не создаём,
	# иначе _apply_frame шумит Resource not found на каждой клетке).
	var shadow_off := float(fh - th) * TILE
	if ResourceLoader.exists("res://assets/structures/%s/houseb-001.png" % folder):
		for ly in range(fh):
			for lx in range(fw):
				var sh := Sprite2D.new()
				sh.name = "Shadow%d" % _shadow_tiles.size()
				sh.position = Vector2(lx * TILE, ly * TILE + shadow_off)
				sh.z_index = -2
				sh.modulate = Color(1, 1, 1, 0.4)
				add_child(sh)
				_shadow_tiles.append(sh)
	_apply_frame()
	_add_footprint_body()

## Физический барьер по футпринту (корпус th, не крыша).
## Юниты: CharacterBody2D layer=1 mask=1 (Game.configure_unit_body) —
## move_and_slide упирается в StaticBody2D, как в стену. Сетка навигации
## (_structure_nav) остаётся для find_path; физика страхует «впритирк».
## Узел здания стоит на (x, y-(fh-th)); корпус — клетки y..y+th-1.
## Центр shape относительно узла: X = fw*TILE/2, Y = (fh - th/2)*TILE.
func _add_footprint_body() -> void:
	var old := get_node_or_null("FootprintBody")
	if old != null:
		old.queue_free()
	var body := StaticBody2D.new()
	body.name = "FootprintBody"
	body.collision_layer = 1   # юниты с mask=1 упираются
	body.collision_mask = 0    # зданию не нужно «чувствовать» других
	var shape_node := CollisionShape2D.new()
	shape_node.name = "Shape"
	var rect := RectangleShape2D.new()
	# +2 px страховка от туннелирования на высоких скоростях
	rect.size = Vector2(float(fw) * TILE + 2.0, float(th) * TILE + 2.0)
	shape_node.shape = rect
	shape_node.position = Vector2(
		float(fw) * TILE * 0.5,
		(float(fh) - float(th) * 0.5) * TILE
	)
	body.add_child(shape_node)
	add_child(body)

## Размер файла кадра house-NNN в байтах (-1, если файла нет).
func _house_size(frame: int) -> int:
	var path := "res://assets/structures/%s/house-%03d.png" % [folder, frame]
	if not ResourceLoader.exists(path):
		return -1
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return -1
	var sz := f.get_length()
	f.close()
	return sz

## Порог «тайл фазы — заглушка»: меньше 30% размера того же тайла базового блока.
## Подобран по всем зданиям с анимацией, на глаз проверен по кадрам:
##   битые   0.034..0.255 — blacksmith1/2, train1/2/3, inn1/2, tower_m, mill2
##   здоровые 0.380..0.969 — mill1 (house-028 = 131 б, реальный тайл), mill3,
##                           castle, все druid*, tower1/2
const BROKEN_PHASE_RATIO := 0.30

## Фаза b — битая, если хоть один её тайл в разы меньше базового (заглушка).
func _is_phase_broken(block: int, grid: int) -> bool:
	for i in range(grid):
		var base_size := _house_size(i + 1)
		var phase_size := _house_size(block * grid + i + 1)
		# Отсутствующий кадр — это не «битый», это недокачанный набор: молча
		# оставляем как есть, _apply_frame() подставит базовый тайл.
		if base_size <= 0 or phase_size < 0:
			continue
		if base_size > 0 and float(phase_size) / float(base_size) < BROKEN_PHASE_RATIO:
			return true
	return false

## Применить текущую фазу ко всем тайлам.
## _phase — индекс в _valid_blocks, а НЕ номер блока: битые фазы вычеркнуты,
## и анимация идёт только по пригодным (у mill2 пропускается фаза 3).
## Текстуры кэшируются: load() на каждый кадр анимации зданий даёт рывки.
static var _tex_cache: Dictionary = {}

static func _load_cached(path: String) -> Texture2D:
	if _tex_cache.has(path):
		return _tex_cache[path]
	var tex: Texture2D = null
	if ResourceLoader.exists(path):
		tex = load(path)
	_tex_cache[path] = tex
	return tex

func _apply_frame() -> void:
	if whole_image:
		if _tiles.is_empty():
			return
		var path := "res://assets/structures/%s/house-001.png" % folder
		var tex := _load_cached(path)
		if tex != null:
			var ts := _tiles[0] as Sprite2D
			ts.texture = tex
			# Спрайт 128 px на футпринте 3x3 (96 px): центрируем по Х,
			# прижимаем низ к нижнему краю футпринта - крыша свешивается
			# вверх и по бокам, как в настоящих RPG-зданиях.
			var fw_px := float(fw) * TILE
			var fh_px := float(fh) * TILE
			var tw := float(tex.get_width())
			var th := float(tex.get_height())
			ts.position = Vector2((fw_px - tw) * 0.5, fh_px - th)
		return
	var grid := fw * fh
	var block: int = _current_block()
	for i in range(_tiles.size()):
		var frame := block * grid + i + 1
		var path := "res://assets/structures/%s/house-%03d.png" % [folder, frame]
		var tex := _load_cached(path)
		if tex == null:
			path = "res://assets/structures/%s/house-%03d.png" % [folder, i + 1]
			tex = _load_cached(path)
		if tex != null:
			(_tiles[i] as Sprite2D).texture = tex
	for i in range(_shadow_tiles.size()):
		var sh := _shadow_tiles[i] as Sprite2D
		var spath := "res://assets/structures/%s/houseb-%03d.png" % [folder, i + 1]
		var stex := _load_cached(spath)
		if stex != null:
			sh.texture = stex
			sh.visible = true
		else:
			sh.visible = false

## Номер блока для текущего индекса фазы.
func _current_block() -> int:
	if _valid_blocks.is_empty():
		return 0
	return int(_valid_blocks[_phase % _valid_blocks.size()])

func _process(delta: float) -> void:
	if not _active or _times.is_empty():
		return
	_timer += delta
	if _timer >= _times[_phase % _times.size()]:
		_timer = 0.0
		_phase = (_phase + 1) % _valid_blocks.size()
		_apply_frame()

## Установить расписание фаз (секунды на фазу) из StructureDB.
func set_anim_times(times: Array) -> void:
	_times = times
	if _times.is_empty() and _blocks > 1:
		_times = []
		for i in range(_blocks):
			_times.append(0.15)