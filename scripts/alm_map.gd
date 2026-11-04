extends Node2D
class_name AlmMap
## Карта разработчиков из .alm: рельефный меш с высотами и освещением от солнца
## (методика Allods16/repo jewalky): каждый тайл-квад поднят на высоту углов,
## текстура растягивается, яркость считается от нормали квада и угла солнца.
## Плюс: здания из секции id=4 (структуры) и препятствия из section id=3.

## Смерть Серого на этой карте (22.10). Карта — родитель всех врагов, поэтому
## сам враг в шину не лезет; QuestSystem подписан сюда один раз.
signal enemy_died(unit: Enemy)

@export var alm_path: String = ""
@export var tile_size := 32   # свойство как у CustomMap (для миникарты и др.)

const TILE := 32
# Высота меша на 1 единицу высоты карты (оригинал рисует 1:1)
const HEIGHT_SCALE := 1.0
## Потолок раскрытий поиска пути. Жадный best-first на открытой местности
## обычно ~O(длина пути); лимит — страховка от лабиринтов.
const BFS_MAX_CELLS := 4000

var map_width: int = 0
var map_height: int = 0
var _terrain: PackedByteArray   # byte[0] — вариант автайла
var _hflags: PackedByteArray    # byte[1] — тип terrain (файл-1: 0..3)
var _heights: PackedByteArray   # int8 — рельеф (0..127)
var _obstacles: PackedByteArray # uint8 — объекты (0=нет, >0=объект)
var _structures: Array = []     # секция id=4 — здания (или sidecar .structures.json)
var map_units: Array = []       # секция id=6 — юниты (или sidecar .npcs.json)
var _herbs: Array = []
var _outposts: Array = []       # форпосты фракций (sidecar .outposts.json)
var _nowalk: Dictionary = {}    # клетки «Нельзя пройти» (ручная разметка в редакторе)
var _allowwalk: Dictionary = {} # клетки «Разрешить проход» — пускать сквозь препятствие
var solar_angle: float = 0.785398  # угол солнца из info (.alm), default 45°

var mesh: MeshInstance2D
## Слой рельефа: мягкая смесь всех пар биомов (05.10).
## MeshInstance2D в Godot 4.7 нет surface_override_material — отдельный узел.
var blend_mesh: MeshInstance2D
var _atlas: ImageTexture
var _cell_uv := {}              # "f{v}-r{row}" -> Rect4(u0,v0,u1,v1)
## Полосы интерьеров tile1..7 (6 вариантов), индекс = terrain type 0..6.
var _blend_strips: Array = []
## Карты бленда.
## primary/secondary — типы пары (nearest).
## u_border: 0 — глубина, ~1 — граница; блюр ×1 (×3 размазывал шов на 2-3
## клетки и давал «полосу чужого биома»). mix в шейдере: smoothstep по border.
var _blend_primary: ImageTexture
var _blend_secondary: ImageTexture
var _blend_border: ImageTexture
var _blend_cells := 0
## Чанк-рендер террейна (19.10): BlendMesh режется на квадраты CHUNK_CELLS,
## видимые только в кадре камеры (+CHUNK_MARGIN). Фундамент карт 96x96.
const CHUNK_CELLS := 16
const CHUNK_MARGIN := 96.0
var _blend_chunks: Array = []     # чанки бленда: {node: MeshInstance2D, rect: Rect2}
var _atlas_cells := 0
const ROAD_T := 3
const MOUNTAIN_T := 1
const WATER_T := 2
const BIOME_COUNT := 7
## Сколько клеток карты в одну плитку текстуры бленда (1 = 32px на клетку).
const BLEND_CELLS_PER_TEX := 1.0
var _obstacle_db := {}          # .alm obstacle id -> {folder, w, h, cx, cy, phases}
## folder -> HP from assets/map-objects/destructibles.json (04.11).
var _destructible_hp := {}
## Vector2i -> AlmObstacle, so an area spell can find the node by cell.
var _obstacle_nodes := {}
var obstacles_root: Node2D      # слой препятствий (y-sort)
var buildings: Node2D           # слой зданий (y-sort)
var herbs_root: Node2D
var world_sort: Node2D          # общий y-sort: препятствия + здания (крона перекрывает фонтан)
var _structure_hits: Array = [] # хитбоксы зданий {x0,x1,y0,y1,picture,type_id}
var _structure_nav: Array = []   # навигационные футпринты зданий
var _portal_cells: Array = []   # координаты порталов (Vector2i)
var _portals: Array = []        # [{cell:Vector2i, to:String, dir:String}] — мир 4x3
var _spawn_cell: Vector2i = Vector2i(-1, -1)
var _portal_markers: Array = [] # PortalMarker instances
var _spawn_marker: Node2D = null

## Единый слой с y-сортировкой для препятствий и зданий: южнее — поверх.
func _ensure_world_sort() -> Node2D:
	if world_sort == null:
		world_sort = Node2D.new()
		world_sort.name = "WorldSort"
		world_sort.y_sort_enabled = true
		add_child(world_sort)
	return world_sort


const _DIRS_4: Array[Vector2i] = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
const _DIRS_8: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
	Vector2i(1, 1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(-1, -1)
]

func _ready() -> void:
	add_to_group("alm_map")
	_resolve_map_path()
	if alm_path.is_empty():
		push_warning("AlmMap: alm_path не задан")
		return
	
	var data := AlmLoader.load_map(alm_path)
	if data.is_empty():
		return
	map_width = data["width"]
	map_height = data["height"]
	_terrain = data["terrain"]
	_hflags = data["hflags"]
	_heights = data["heights"]
	_obstacles = data["obstacles"]
	_structures = data.get("structures", [])
	map_units = data.get("units", [])
	_load_sidecars()
	var info: Dictionary = data.get("info", {})
	solar_angle = float(info.get("solar_angle", 0.785398))
	_load_obstacle_db()
	_load_destructible_db()
	_build_atlas()
	_build_relief_mesh()
	_build_obstacles()
	_build_structures()
	_build_herbs()
	_load_portal_spawn()
	print("AlmMap: %s %dx%d клеток, структур %d, солнце %s°" % [alm_path.get_file(), map_width, map_height, _structures.size(), str(rad_to_deg(solar_angle))])

## Таблица препятствий: .alm obstacle id -> параметры спрайта (из objects.txt/obj.reg).
func _load_obstacle_db() -> void:
	var f := FileAccess.open("res://assets/map-objects/alm_objects.json", FileAccess.READ)
	if f == null:
		push_warning("AlmMap: нет alm_objects.json — препятствия не будут показаны")
		return
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if parsed is Dictionary:
		_obstacle_db = parsed

## HP of destructible obstacle folders. Missing folder = indestructible.
func _load_destructible_db() -> void:
	_destructible_hp.clear()
	var f := FileAccess.open("res://assets/map-objects/destructibles.json", FileAccess.READ)
	if f == null:
		push_warning("AlmMap: нет destructibles.json — объекты не разрушаются")
		return
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if parsed is Dictionary:
		_destructible_hp = parsed

## Препятствия (.alm obstacles): дерево/камень/статуя на клетках с id > 0.
func _build_obstacles() -> void:
	_obstacle_nodes.clear()
	if obstacles_root == null:
		obstacles_root = Node2D.new()
		obstacles_root.name = "Obstacles"
		obstacles_root.y_sort_enabled = true
		_ensure_world_sort().add_child(obstacles_root)
	for y in range(map_height):
		for x in range(map_width):
			var oid := _obstacles[y * map_width + x]
			if oid == 0:
				continue
			var spec: Dictionary = _obstacle_db.get(str(oid), {})
			if spec.is_empty():
				continue
			var folder := str(spec.get("folder", ""))
			if folder.is_empty():
				continue
			var ob := AlmObstacle.new()
			ob.setup(folder, int(spec.get("phases", 1)),
				int(spec.get("w", 128)), int(spec.get("h", 128)),
				int(spec.get("cx", 64)), int(spec.get("cy", 96)),
				int(spec.get("index", 0)),
				int(_destructible_hp.get(folder, 0)))
			ob.place_at(Vector2i(x, y), TILE, relief_at_tile(x, y))
			ob.destroyed.connect(_on_obstacle_destroyed)
			obstacles_root.add_child(ob)
			_obstacle_nodes[Vector2i(x, y)] = ob

## Здания из секции id=4 (structures): спрайты assets/structures/<папка>/house-NNN.png.
## Сетка кадров 32x32: fw=TileWidth, fh=FullHeight; верхние (fh-th) рядов — выше земли.
## Тень (houseb) и анимация фаз (Phases>1) — через StructureNode / StructureDB.
func _build_structures() -> void:
	if _structures.is_empty():
		return
	if buildings == null:
		buildings = Node2D.new()
		buildings.name = "Buildings"
		buildings.y_sort_enabled = true
		_ensure_world_sort().add_child(buildings)
	var placed := 0
	var missing := 0
	for st in _structures:
		var type_id := int(st.get("type_id", 0))
		if type_id <= 0:
			continue
		var fj := _structure_frame_job(type_id, st)
		if fj.is_empty():
			missing += 1
			continue
		var node := _make_structure(fj)
		if node == null:
			missing += 1
			continue
		# Позиция: клетка (X, Y) = левый-нижний угол корпуса; верх поднят на (fh-th) клеток
		var x: float = st.get("x", 0.0)
		var y: float = st.get("y", 0.0)
		var dir := int(fj.get("fh", 1)) - int(fj.get("th", 1))
		node.position = Vector2(x * TILE, (y - dir) * TILE)
		buildings.add_child(node)
		placed += 1
		# Хитбокс здания в клетках: база — Selection-бокс (пиксели структуры),
		# иначе корпус th рядов (+верхние (fh-th) визуальные ряды).
		var fw := int(fj.get("fw", 1))
		var th := int(fj.get("th", 1))
		var fh := int(fj.get("fh", th))
		var sel: Rect2i = fj.get("sel", Rect2i())
		if sel.size.x > 0 and sel.size.y > 0:
			# Selection в пикселях исходного спрайта (fw*fh*32): переводим в клетки
			var tw := int(fj.get("fw", 1)) * 32
			var thh := int(fj.get("fh", th)) * 32
			var sx := int(x) + sel.position.x * fw / tw
			var sy := int(y) - (fh - th) + (sel.position.y * fh / thh)
			var sw := maxi(1, int(ceil(sel.size.x * fw / float(tw))))
			var sh := maxi(1, int(ceil(sel.size.y * fh / float(thh))))
			_structure_hits.append({
				"x0": sx, "x1": sx + sw - 1,
				"y0": sy, "y1": sy + sh - 1,
				"picture": str(fj.get("picture", "")),
				"type_id": type_id,
				"ax": int(x), "ay": int(y),
			})
		else:
			_structure_hits.append({
				"x0": int(x), "x1": int(x) + fw - 1,
				"y0": int(y) - (fh - th), "y1": int(y) + th - 1,
				"picture": str(fj.get("picture", "")),
				"type_id": type_id,
				"ax": int(x), "ay": int(y),
			})
		_structure_nav.append({
			"x0": int(x), "x1": int(x) + fw - 1,
			"y0": int(y), "y1": int(y) + th - 1,
		})
	print("AlmMap: зданий создано %d, пропущено %d" % [placed, missing])

func _build_herbs() -> void:
	if _herbs.is_empty():
		return
	if herbs_root == null:
		herbs_root = Node2D.new()
		herbs_root.name = "Herbs"
		herbs_root.y_sort_enabled = true
		_ensure_world_sort().add_child(herbs_root)
	var placed := 0
	for record in _herbs:
		var item_key := str(record.get("item", ""))
		var icon_path := str(record.get("icon", ""))
		var grid_cell := Vector2i(int(record.get("x", -1)), int(record.get("y", -1)))
		if ItemDB.find(item_key).is_empty() or not ResourceLoader.exists(icon_path):
			continue
		if grid_cell.x < 0 or grid_cell.y < 0 or grid_cell.x >= map_width or grid_cell.y >= map_height:
			continue
		var herb := HerbNode.new()
		herb.setup(item_key, icon_path, grid_cell, relief_at_tile(grid_cell.x, grid_cell.y))
		herbs_root.add_child(herb)
		placed += 1
	print("AlmMap: трав создано %d/%d" % [placed, _herbs.size()])

func herb_at_position(world_position: Vector2) -> HerbNode:
	for node in get_tree().get_nodes_in_group("herb_resource"):
		var herb := node as HerbNode
		if herb != null and herb.contains_point(world_position):
			return herb
	return null

func get_herbs() -> Array:
	return _herbs

## Собрать Node2D-здание: whole_image (одна PNG) или сетка house-NNN + тень.
func _make_structure(job: Dictionary) -> Node2D:
	var node := StructureNode.new()
	node.folder = str(job["dir"])
	node.fw = int(job["fw"])
	node.th = int(job["th"])
	node.fh = int(job["fh"])
	node.whole_image = bool(job.get("whole_image", false))
	var anim_times: Array = job.get("anim_times", [])
	node.set_anim_times(anim_times)
	node.use_anim = int(job.get("phases", 1)) > 1 and not node.whole_image
	node.max_blocks = int(job.get("phases", 0))
	node.build()
	return node

## Описание здания: папка/префикс кадров, сетка fw x fh (из structures.txt).
var _structure_jobs := {}
func _structure_frame_job(type_id: int, st: Dictionary) -> Dictionary:
	if _structure_jobs.has(type_id):
		var cached: Dictionary = _structure_jobs[type_id]
		return cached
	var def := _structure_def(type_id)
	if def.is_empty():
		_structure_jobs[type_id] = {}
		return {}
	var dir_name := str(def.get("folder", "")).to_lower()
	if dir_name.is_empty():
		_structure_jobs[type_id] = {}
		return {}
	var prefix := str(def.get("prefix", "house"))
	if prefix.is_empty():
		prefix = "house"
	var fw := int(def.get("tile_width", 1))
	var th := int(def.get("tile_height", 1))
	var fh := int(def.get("full_height", th))
	var sel := Rect2i(0, 0, 0, 0)
	if def.has("sel") and (def["sel"] as Array).size() == 4:
		var s: Array = def["sel"]
		sel = Rect2i(int(s[0]), int(s[2]), int(s[1]) - int(s[0]), int(s[3]) - int(s[2]))
	var job := {
		"dir": dir_name, "prefix": prefix, "fw": fw, "th": th, "fh": fh,
		"picture": str(def.get("picture", "")),
		"phases": int(def.get("phases", 1)),
		"anim_times": StructureDB.anim_time(dir_name, int(def.get("phases", 1))),
		"sel": sel,
		"whole_image": int(def.get("whole_image", 0)) != 0,
	}
	_structure_jobs[type_id] = job
	return job

## Данные структуры по TypeID: из структурированной БД (structure_db.json).
var _structure_defs := {}
func _structure_def(type_id: int) -> Dictionary:
	if _structure_defs.has(type_id):
		return _structure_defs[type_id]
	var def := StructureDB.get_by_id(type_id)
	_structure_defs[type_id] = def
	return def

func _structure_blocks_cell(cell: Vector2i) -> bool:
	for h in _structure_nav:
		if cell.x >= int(h["x0"]) and cell.x <= int(h["x1"]) \
				and cell.y >= int(h["y0"]) and cell.y <= int(h["y1"]):
			return true
	return false

## Публично: клетка внутри футпринта здания (для жёсткого запрета входа).
func is_structure_cell(cell: Vector2i) -> bool:
	return _structure_blocks_cell(cell)

## Публичная блокировка клетки (стены огня/земли на время жизни).
## Снимается тем же вызовом с value=false.
func set_nowalk_cell(cell: Vector2i, value: bool) -> void:
	if value:
		_nowalk[cell] = true
	else:
		_nowalk.erase(cell)

## Есть ли активная блокировка клетки.
func is_nowalk_cell(cell: Vector2i) -> bool:
	return _nowalk.has(cell)

## Здание под курсором (клетка cell) — для ховера; возвращает Dictionary или {}.
func structure_at(cell: Vector2i) -> Dictionary:
	for h in _structure_hits:
		if cell.x >= int(h["x0"]) and cell.x <= int(h["x1"]) \
				and cell.y >= int(h["y0"]) and cell.y <= int(h["y1"]):
			return h
	return {}

## Рельеф: настоящие высоты (для визуала и скорости движения).
func relief_at_tile(x: int, y: int) -> float:
	if x < 0 or y < 0 or x >= map_width or y >= map_height:
		return 0.0
	return float(_heights[y * map_width + x]) * HEIGHT_SCALE

func relief_at_world(pos: Vector2) -> float:
	var gx := pos.x / float(TILE)
	var gy := pos.y / float(TILE)
	var x0 := int(floor(gx))
	var y0 := int(floor(gy))
	var x1 := x0 + 1
	var y0_local := y0
	var tx := gx - float(x0)
	var ty := gy - float(y0)
	var h00 := relief_at_tile(x0, y0_local)
	var h10 := relief_at_tile(x1, y0_local)
	var h01 := relief_at_tile(x0, y0_local + 1)
	var h11 := relief_at_tile(x1, y0_local + 1)
	var top := lerpf(h00, h10, tx)
	var bottom := lerpf(h01, h11, tx)
	return lerpf(top, bottom, ty)

# --- Текстуры: атлас всех используемых (файл, вариант, ряд) ---

func _used_cells() -> Dictionary:
	## Ключ "f{file}-v{variant}-r{row}" -> true. file 1..15, variant 0..15, row 0..nrows-1
	##
	## Файлы 1..7 — интерьеры, 8..15 — переходы (variant = биом-владелец A,
	## row = сосед B*2 + вариация). Ключ у них общий с интерьерами, потому что
	## file_n и variant лежат в разных битах тайла и по отдельности не
	## различаются — различает их сам file_n.
	var used := {}
	for i in range(map_width * map_height):
		var tile_id: int = _terrain[i] | (_hflags[i] << 8)
		var file_n := (_hflags[i] & 0xF) + 1
		var vmax: int = 4 if file_n == 4 else 16
		var variant := clampi((_terrain[i] >> 4) & 0xF, 0, vmax - 1)
		var row := _terrain[i] & 0xF
		used["f%d-v%d-r%d" % [file_n, variant, row]] = true
	return used

func _build_atlas() -> void:
	var used := _used_cells()
	# Сгруппировать нужные ключи по паре (файл, вариант). BMP - это полоса
	# из 14 рядов, и грузить её целиком ради одного ряда расточительно:
	# раньше здесь загружались ВСЕ варианты всех 15 файлов (до ~190 картинок
	# 32x448) и только ПОСЛЕ загрузки отбрасывались неиспользуемые.
	var want := {}  # file_n * 16 + variant -> true
	for key in used:
		var s: String = key
		# Искать с индекса 1, а не 2: у файлов 1..7 номер однозначный и
		# разделитель стоит ровно на позиции 2. С find("-", 2) он находился
		# сам, substr отдавал пустую строку, интерьеры молча выпадали из
		# атласа (12 ячеек вместо 482) и клетки просто не рисовались.
		var d1: int = s.find("-", 2)
		var d2: int = s.find("-", d1 + 1)
		if d1 < 0 or d2 < 0:
			push_error("AlmMap: не разобрать ключ ячейки: " + s)
			continue
		var f: int = s.substr(1, d1 - 1).to_int()
		var v: int = s.substr(d1 + 2, d2 - d1 - 2).to_int()
		want[f * 16 + v] = true

	# Соберём фактические (файл, вариант, ряд) с реальным числом рядов в файле
	var cells: Array = []  # [key, Image32]
	var key_to_cell := {}
	# Файлы 1..7 — интерьеры (16 вариантов, у дороги tile4 всего 4),
	# файлы 8..15 — переходы (7 вариантов = 7 биомов-владельцев).
	# См. assets/maps/terrain_tiles_db.json.
	var vmax_by_file := {1: 16, 2: 16, 3: 16, 4: 4, 5: 16, 6: 16, 7: 16,
		8: 7, 9: 7, 10: 7, 11: 7, 12: 7, 13: 7, 14: 7, 15: 7}
	var loaded := 0
	for want_key in want:
		var file_n: int = int(int(want_key) / 16.0)
		var variant: int = int(want_key) % 16
		if variant >= int(vmax_by_file.get(file_n, 16)):
			continue
		var path := "res://assets/terrain/tile%d-%02d.bmp" % [file_n, variant]
		if not ResourceLoader.exists(path):
			continue
		loaded += 1
		var tex: Texture2D = load(path)
		var img: Image = tex.get_image()
		img.convert(Image.FORMAT_RGBA8)
		var nrows: int = int(img.get_height() / float(TILE))
		for row in range(nrows):
			var key := "f%d-v%d-r%d" % [file_n, variant, row]
			# Дублей быть не может: want уникален по (файл, вариант),
			# а ключ ряда дополнительно кодирует номер ряда.
			if not used.has(key):
				continue
			var cell_img: Image = img.get_region(Rect2i(0, row * TILE, TILE, TILE))
			cells.append([key, cell_img])
			key_to_cell[key] = cells.size() - 1
	print("AlmMap: загружено %d файлов тайлов из %d используемых пар" % [loaded, want.size()])
	# Инвариант: каждая используемая клетка обязана попасть в атлас. Если
	# клетка выпала (нет файла, неверный ряд, битый ключ), _build_relief_mesh
	# молча пропустит её `continue` по нулевому UV, и в земле будет дыра.
	# Проверялось на реальном баге: 12 ячеек вместо 482, и все тесты были
	# зелёные - ловится только здесь.
	if cells.size() != used.size():
		push_error("AlmMap: в атлас попало %d ячеек из %d используемых" % [cells.size(), used.size()])

	# Собираем атлас 64x64 ячейки (до 4096)
	var atlas := Image.create(64 * TILE, 64 * TILE, false, Image.FORMAT_RGBA8)
	atlas.fill(Color(0, 0, 0, 0))
	_cell_uv.clear()
	var atlas_w := 64.0 * TILE
	var half_px := 0.5 / atlas_w
	for idx in range(cells.size()):
		var key: String = cells[idx][0]
		var cimg: Image = cells[idx][1]
		var cx := idx % 64
		var cy := int(idx / 64.0)
		atlas.blit_rect(cimg, Rect2i(0, 0, TILE, TILE), Vector2i(cx * TILE, cy * TILE))
		# UV inset ±0.5 px to avoid sampling at cell boundaries (grid seams)
		var u0 := float(cx * TILE) / atlas_w + half_px
		var v0 := float(cy * TILE) / atlas_w + half_px
		var u1 := float((cx + 1) * TILE) / atlas_w - half_px
		var v1 := float((cy + 1) * TILE) / atlas_w - half_px
		_cell_uv[key] = Vector4(u0, v0, u1, v1)
	_atlas = ImageTexture.create_from_image(atlas)
	print("AlmMap: атлас %d ячеек" % cells.size())

## Для отладки: сама текстура атласа.
func get_atlas_texture() -> ImageTexture:
	return _atlas

func _uv_for_cell(file_n: int, variant: int, row: int) -> Vector4:
	var key := "f%d-v%d-r%d" % [file_n, variant, row]
	var r: Vector4 = _cell_uv.get(key, Vector4(0, 0, 0, 0))
	return r

# --- Рельефный меш с освещением ---

func _node_h(nx: int, ny: int) -> float:
	## Высота узла сетки (угла клетки), с клампом к границам карты.
	var cx := clampi(nx, 0, map_width - 1)
	var cy := clampi(ny, 0, map_height - 1)
	return float(_heights[cy * map_width + cx]) * HEIGHT_SCALE

func _cell_normal(x: int, y: int) -> Vector3:
	## Нормаль квада (Allods16): u=(32,0,uz), v=(0,32,vz),
	## где uz = h(x+1,y)-h(x,y), vz = h(x,y+1)-h(x,y). n = cross(u,v).
	var uz := _node_h(x + 1, y) - _node_h(x, y)
	var vz := _node_h(x, y + 1) - _node_h(x, y)
	# cross((32,0,uz),(0,32,vz)) = (-32*uz, -32*vz, 1024)
	var n := Vector3(-32.0 * uz, -32.0 * vz, 1024.0)
	return n.normalized()

func _sun_dir() -> Vector3:
	var a := solar_angle
	var s := Vector3(cos(a), sin(a), -0.75)
	return s.normalized()

func _brightness(x: int, y: int) -> float:
	## Яркость клетки: |n·sun|*64+96, затем контраст (как в Allods16).
	## В оригинале shade/4 — индекс яркостной палитры (0..64, 32 = норма),
	## поэтому нормируем на 128: плоский террейн ~1.0, склоны темнее.
	var n := _cell_normal(x, y)
	var sun := _sun_dir()
	var dot := absf(n.dot(sun))
	var b := dot * 64.0 + 96.0
	b = (b - 128.0) * 0.75 + 128.0
	return clampf(b / 128.0, 0.25, 1.0)

func _build_relief_mesh() -> void:
	if mesh == null:
		mesh = MeshInstance2D.new()
		mesh.name = "ReliefMesh"
		mesh.z_index = -1
		add_child(mesh)

	# Поле биомов — как у пилота: type/6 + блюр ×3. Не «border 0/1».
	var types := PackedInt32Array()
	types.resize(map_width * map_height)
	for i in range(types.size()):
		types[i] = AlmLoader.terrain_type(_hflags[i])

	var prim_img := Image.create(map_width, map_height, false, Image.FORMAT_RF)
	var sec_img := Image.create(map_width, map_height, false, Image.FORMAT_RF)
	var border_img := Image.create(map_width, map_height, false, Image.FORMAT_RF)
	for y in range(map_height):
		for x in range(map_width):
			var i := y * map_width + x
			var t: int = types[i]
			if t < 0:
				t = 0
			var pair := _blend_pair(types, x, y, t)
			prim_img.set_pixel(x, y, Color(float(t) / 6.0, 0, 0, 1))
			sec_img.set_pixel(x, y, Color(float(pair["n"]) / 6.0, 0, 0, 1))
			border_img.set_pixel(x, y, Color(float(pair["border"]), 0, 0, 1))
	# Блюр ×1 — мягкая кромка без «полосы» на 2-3 клетки вглубь биома.
	border_img = _box_blur_rf(border_img)
	_blend_primary = ImageTexture.create_from_image(prim_img)
	_blend_secondary = ImageTexture.create_from_image(sec_img)
	_blend_border = ImageTexture.create_from_image(border_img)

	_build_blend_assets()

	# ReliefMesh остаётся с материалом атласа (тесты/освещение ссылаются).
	var amesh := ArrayMesh.new()
	var mat := ShaderMaterial.new()
	var shader := Shader.new()
	shader.code = """shader_type canvas_item;
uniform sampler2D u_atlas;
void fragment() {
	vec4 tex = texture(u_atlas, UV);
	COLOR = vec4(tex.rgb * COLOR.a, 1.0);
}"""
	mat.shader = shader
	mat.set_shader_parameter("u_atlas", _atlas)
	mesh.mesh = amesh
	mesh.material = mat

	# Материал и шейдер бленда — общие для всех чанков (19.10).
	var mat_b := ShaderMaterial.new()
	var sh_b := Shader.new()
	sh_b.code = """shader_type canvas_item;
uniform sampler2D u_primary : filter_nearest, repeat_disable;
uniform sampler2D u_secondary : filter_nearest, repeat_disable;
uniform sampler2D u_border : filter_linear, repeat_disable;
uniform sampler2D u_t0 : filter_nearest, repeat_disable;
uniform sampler2D u_t1 : filter_nearest, repeat_disable;
uniform sampler2D u_t2 : filter_nearest, repeat_disable;
uniform sampler2D u_t3 : filter_nearest, repeat_disable;
uniform sampler2D u_t4 : filter_nearest, repeat_disable;
uniform sampler2D u_t5 : filter_nearest, repeat_disable;
uniform sampler2D u_t6 : filter_nearest, repeat_disable;
uniform float u_noise_amp : hint_range(0.0, 0.3) = 0.03;
uniform vec2 u_map_cells = vec2(128.0, 128.0);

float hash12(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

vec3 sample_biome(float id, vec2 local, vec2 cell, float salt) {
	float vi = floor(hash12(cell + vec2(salt, salt * 1.7)) * 6.0);
	vec2 uv = vec2(local.x, (local.y + vi) / 6.0);
	if (id < 0.5) return texture(u_t0, uv).rgb;
	if (id < 1.5) return texture(u_t1, uv).rgb;
	if (id < 2.5) return texture(u_t2, uv).rgb;
	if (id < 3.5) return texture(u_t3, uv).rgb;
	if (id < 4.5) return texture(u_t4, uv).rgb;
	if (id < 5.5) return texture(u_t5, uv).rgb;
	return texture(u_t6, uv).rgb;
}

void fragment() {
	vec2 cell = floor(UV * u_map_cells);
	vec2 cuv = (cell + 0.5) / u_map_cells;
	float tid = floor(texture(u_primary, cuv).r * 6.0 + 0.5);
	float nid = floor(texture(u_secondary, cuv).r * 6.0 + 0.5);
	// Поле границы (0..1 после блюра). Работает и для смежных типов
	// (гора–трава 1/6 vs 0), где type/6-smoothstep был почти ступенькой.
	float s = texture(u_border, UV).r;
	float m = smoothstep(0.38, 0.68, s);
	m += (hash12(cell) - 0.5) * u_noise_amp;
	m = clamp(m, 0.0, 1.0);
	// primary не растворяется: максимум ~55% secondary.
	m = min(m, 0.55);
	// Дорога: кромка видимая, но мягче прочих пар.
	if (abs(tid - 3.0) < 0.5 || abs(nid - 3.0) < 0.5) {
		m = min(m, 0.42);
	}
	vec2 local = fract(UV * u_map_cells);
	vec3 a = sample_biome(tid, local, cell, 3.1);
	vec3 b = sample_biome(nid, local, cell, 11.3);
	COLOR = vec4(mix(a, b, m) * COLOR.a, 1.0);
}"""
	mat_b.shader = sh_b
	mat_b.set_shader_parameter("u_primary", _blend_primary)
	mat_b.set_shader_parameter("u_secondary", _blend_secondary)
	mat_b.set_shader_parameter("u_border", _blend_border)
	for bi in range(BIOME_COUNT):
		mat_b.set_shader_parameter("u_t%d" % bi, _blend_strips[bi])
	mat_b.set_shader_parameter("u_map_cells", Vector2(map_width, map_height))

	# Чанки 16×16 клеток: тот же материал и UV всей карты, но каждый чанк —
	# свой MeshInstance2D, который скрывается вне кадра камеры (19.10).
	var chunks_x := int(ceil(map_width / float(CHUNK_CELLS)))
	var chunks_y := int(ceil(map_height / float(CHUNK_CELLS)))
	for cy in range(chunks_y):
		for cx in range(chunks_x):
			var st_c := SurfaceTool.new()
			st_c.begin(Mesh.PRIMITIVE_TRIANGLES)
			var y_to := mini((cy + 1) * CHUNK_CELLS, map_height)
			var x_to := mini((cx + 1) * CHUNK_CELLS, map_width)
			for y in range(cy * CHUNK_CELLS, y_to):
				for x in range(cx * CHUNK_CELLS, x_to):
					var i := y * map_width + x
					var t: int = types[i]
					if t < 0:
						continue
					var h00 := _node_h(x, y)
					var h10 := _node_h(x + 1, y)
					var h01 := _node_h(x, y + 1)
					var h11 := _node_h(x + 1, y + 1)
					var p00 := Vector3(x * TILE, y * TILE - h00, 0)
					var p10 := Vector3((x + 1) * TILE, y * TILE - h10, 0)
					var p01 := Vector3(x * TILE, (y + 1) * TILE - h01, 0)
					var p11 := Vector3((x + 1) * TILE, (y + 1) * TILE - h11, 0)
					var br := _brightness(x, y)
					# COLOR.a — только яркость (паттерн пилота). Типы — в текстурах.
					st_c.set_color(Color(1.0, 1.0, 1.0, br))
					var u0 := float(x) / float(map_width)
					var v0 := float(y) / float(map_height)
					var u1 := float(x + 1) / float(map_width)
					var v1 := float(y + 1) / float(map_height)
					st_c.set_uv(Vector2(u0, v0)); st_c.add_vertex(p00)
					st_c.set_uv(Vector2(u1, v0)); st_c.add_vertex(p10)
					st_c.set_uv(Vector2(u0, v1)); st_c.add_vertex(p01)
					st_c.set_uv(Vector2(u1, v0)); st_c.add_vertex(p10)
					st_c.set_uv(Vector2(u1, v1)); st_c.add_vertex(p11)
					st_c.set_uv(Vector2(u0, v1)); st_c.add_vertex(p01)
					_blend_cells += 1
			var arr_c: Array = st_c.commit_to_arrays()
			if arr_c.is_empty():
				continue
			var verts: PackedVector3Array = arr_c[Mesh.ARRAY_VERTEX]
			if verts.size() == 0:
				continue
			var bmesh := ArrayMesh.new()
			bmesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr_c)
			var mi := MeshInstance2D.new()
			mi.mesh = bmesh
			mi.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
			mi.material = mat_b
			mi.z_index = mesh.z_index
			mi.name = "BlendChunk_%d_%d" % [cx, cy]
			add_child(mi)
			_blend_chunks.append({
				"node": mi,
				"rect": Rect2(cx * CHUNK_CELLS * TILE, cy * CHUNK_CELLS * TILE,
					CHUNK_CELLS * TILE, CHUNK_CELLS * TILE),
			})
			if blend_mesh == null:
				blend_mesh = mi
				blend_mesh.name = "BlendMesh"

	print("AlmMap: меш собран (бленд=%d, полос=%d, чанков=%d)" % [
		_blend_cells, _blend_strips.size(), _blend_chunks.size()])

## Видимость чанков по камере: чанк вне кадра (+запас) не рисуется.
func _process(_delta: float) -> void:
	if _blend_chunks.is_empty():
		return
	var vp := get_viewport()
	if vp == null:
		return
	var cam := vp.get_camera_2d()
	if cam == null:
		return
	var vs: Vector2 = vp.get_visible_rect().size
	var zoom: Vector2 = cam.zoom
	if zoom.x <= 0.0 or zoom.y <= 0.0:
		zoom = Vector2.ONE
	var half := Vector2(vs.x * 0.5 / zoom.x, vs.y * 0.5 / zoom.y) + Vector2(CHUNK_MARGIN, CHUNK_MARGIN)
	var center: Vector2 = cam.get_screen_center_position()
	var view := Rect2(center - half, half * 2.0)
	for c in _blend_chunks:
		var node: MeshInstance2D = c["node"]
		if node == null or not is_instance_valid(node):
			continue
		node.visible = (c["rect"] as Rect2).intersects(view)

## Пара (secondary, unused_border) — secondary = самый частый чужой сосед.
## Сам mix в шейдере: по полю type/6 между tid и nid (формула пилота).
func _blend_pair(types: PackedInt32Array, x: int, y: int, t: int) -> Dictionary:
	var counts := {}
	var foreign := 0
	for d in _DIRS_8:
		var nx := x + d.x
		var ny := y + d.y
		if nx < 0 or ny < 0 or nx >= map_width or ny >= map_height:
			continue
		var nt: int = types[ny * map_width + nx]
		if nt < 0 or nt == t:
			continue
		foreign += 1
		counts[nt] = int(counts.get(nt, 0)) + 1
	if foreign == 0:
		return {"n": t, "border": 0.0}
	var second := t
	var best := 0
	for nt in counts:
		if int(counts[nt]) > best:
			best = int(counts[nt])
			second = int(nt)
	if (t == WATER_T or t == MOUNTAIN_T) and foreign >= 5:
		return {"n": t, "border": 0.0}
	return {"n": second, "border": 1.0}

## Полосы интерьеров tile1..7 (по 6 вариантов) для всех биомов.
func _build_blend_assets() -> void:
	if _blend_strips.size() == BIOME_COUNT:
		return
	_blend_strips.clear()
	for bi in range(BIOME_COUNT):
		var file_n := bi + 1
		var path := "res://assets/terrain/tile%d-00.bmp" % file_n
		var strip := _load_blend_strip(path)
		if strip == null:
			push_error("AlmMap: нет полосы биома %d (%s)" % [bi, path])
			var empty := Image.create(TILE, TILE * 6, false, Image.FORMAT_RGBA8)
			strip = ImageTexture.create_from_image(empty)
		_blend_strips.append(strip)
	print("AlmMap: blend-полосы: %d биомов" % _blend_strips.size())

## Полоса из вариантов BMP32x448. Nearest — текстура не «плывёт».
func _load_blend_strip(path: String) -> ImageTexture:
	if not ResourceLoader.exists(path):
		return null
	var tex: Texture2D = load(path)
	var img: Image = tex.get_image()
	img.convert(Image.FORMAT_RGBA8)
	var variants := mini(6, img.get_height() / TILE)
	if variants <= 0:
		return null
	var strip := Image.create(TILE, TILE * variants, false, Image.FORMAT_RGBA8)
	for r in range(variants):
		strip.blit_rect(img, Rect2i(0, r * TILE, TILE, TILE), Vector2i(0, r * TILE))
	return ImageTexture.create_from_image(strip)

func _box_blur_rf(src: Image) -> Image:
	var dst := src.duplicate()
	var w := src.get_width()
	var h := src.get_height()
	for y in range(h):
		for x in range(w):
			var acc := 0.0
			for dy in range(-1, 2):
				for dx in range(-1, 2):
					acc += src.get_pixel(clampi(x + dx, 0, w - 1), clampi(y + dy, 0, h - 1)).r
			dst.set_pixel(x, y, Color(acc / 9.0, 0.0, 0.0, 1.0))
	return dst

## Мировая позиция спавна: из файла-якоря "<имя>.spawn.json" рядом с .alm
## (ставится в редакторе карт) или центр карты (game.gd сам ищет проходимый тайл).
func get_spawn_pos() -> Vector2:
	var anchor := _load_spawn_anchor()
	if anchor.x >= 0:
		return Vector2(anchor.x * TILE + TILE / 2.0, anchor.y * TILE + TILE / 2.0)
	return Vector2(map_width * TILE / 2.0, map_height * TILE / 2.0)

## Выбор карты при старте. Порядок:
##  1. Явно запрошенный путь (Game.pending_map_path) — редактор карт, загрузка сохранения.
##  2. Карта по сиду (Game.map_seed != 0) — новая игра: генерируем или переиспользуем
##     карту в user://maps/. Именно здесь появляются неповторимые карты.
##  3. Запасной путь из main.tscn — dev-режим и автотесты. Без запрошенного сида
##     игра всегда грузила бы один и тот же gen_smart_01.alm.
func _resolve_map_path() -> void:
	var requested: String = Game.pending_map_path
	if requested != "" and FileAccess.file_exists(requested):
		print("AlmMap: запрошенная карта: %s" % requested)
		alm_path = requested
		return
	if Game.map_seed != 0:
		var generated: String = ""
		if Game.map_sector != "":
			var wm = load("res://scripts/world/world_map.gd")
			var info: Dictionary = wm.sector(Game.map_sector)
			generated = MapGenerator.ensure_map(Game.map_seed, Game.map_zone,
				MapGenerator.MAPS_DIR, "", Game.map_sector,
				int(info.get("size", 192)), wm.neighbors(Game.map_sector),
				str(info.get("relief", "")))
		else:
			generated = MapGenerator.ensure_map(Game.map_seed, Game.map_zone)
		if generated != "" and FileAccess.file_exists(generated):
			print("AlmMap: карта по сиду %d (%s/%s): %s" % [Game.map_seed,
				Game.map_zone, Game.map_sector, generated])
			alm_path = generated
			return
		push_warning("AlmMap: не удалось получить карту по сиду %d" % Game.map_seed)
	# 3. Запасной вариант — alm_path из сцены.

## Клетка спавна из файла-якоря рядом с .alm, или (-1,-1).
func _load_spawn_anchor() -> Vector2i:
	if alm_path.is_empty():
		return Vector2i(-1, -1)
	var anchor_path := alm_path.get_basename() + ".spawn.json"
	if not FileAccess.file_exists(anchor_path):
		return Vector2i(-1, -1)
	var f := FileAccess.open(anchor_path, FileAccess.READ)
	if f == null:
		return Vector2i(-1, -1)
	var json: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if json is not Dictionary:
		return Vector2i(-1, -1)
	return Vector2i(int(json.get("x", -1)), int(json.get("y", -1)))

func _load_portal_spawn() -> void:
	# Загрузка spawn из sidecar
	var sp := _load_spawn_anchor()
	if sp.x >= 0:
		_spawn_cell = sp
		# Создаём маркер спавна
		var pm := preload("res://scripts/portal_marker.gd").new()
		pm.setup(sp, "spawn_marker")
		pm.z_index = 10
		add_child(pm)
		_spawn_marker = pm
	# Загрузка portal из sidecar
	var portal_path: String = ""
	if not alm_path.is_empty():
		portal_path = alm_path.get_basename() + ".portal.json"
	if portal_path != "" and FileAccess.file_exists(portal_path):
		var f := FileAccess.open(portal_path, FileAccess.READ)
		if f != null:
			var json: Variant = JSON.parse_string(f.get_as_text())
			f.close()
			if json is Dictionary:
				var records: Array = []
				if (json as Dictionary).has("portals"):
					records = (json as Dictionary).get("portals", []) as Array
				else:
					# Старый формат: один портал {x,y} без адреса.
					records = [json]
				for raw in records:
					if not (raw is Dictionary):
						continue
					var rec: Dictionary = raw as Dictionary
					var pp := Vector2i(int(rec.get("x", -1)), int(rec.get("y", -1)))
					if pp.x < 0:
						continue
					var to := str(rec.get("to", ""))
					var dir := str(rec.get("dir", ""))
					_portals.append({"cell": pp, "to": to, "dir": dir})
					_portal_cells.append(pp)
					var pm2 := preload("res://scripts/portal_marker.gd").new()
					pm2.setup(pp, "portal")
					pm2.z_index = 10
					add_child(pm2)
					_portal_markers.append(pm2)

func get_portal_cells() -> Array:
	return _portal_cells

## Порталы сектора: [{cell, to, dir}]. Пустой to — старый sidecar без адреса.
func get_portals() -> Array:
	return _portals

func get_spawn_cell() -> Vector2i:
	return _spawn_cell

## Sidecar-файлы рядом с .alm — редактор сохраняет в них полное состояние
## структур и НПЦ (сам .alm не перезаписывается):
##   "<имя>.structures.json" — {"structures": [{x, y, type_id}]}
##   "<имя>.npcs.json"       — {"npcs": [{x, y, set}]}
## Если sidecar существует — он ПЕРЕКРЫВАЕТ секции 4/6 .alm (редактор копирует
## их туда при первом открытии); иначе работают оригинальные секции.
func _load_sidecars() -> void:
	if alm_path.is_empty():
		return
	var base := alm_path.get_basename()
	var s: Variant = _read_sidecar(base + ".structures.json")
	if s != null and s is Array:
		_structures = s
	var u: Variant = _read_sidecar(base + ".npcs.json")
	if u != null and u is Array:
		map_units = u
	var h: Variant = _read_sidecar(base + ".herbs.json")
	if h != null and h is Array:
		_herbs = h
	# Форпосты фракций (пакет B): отдельный sidecar, стражники при этом едут
	# обычными записями .npcs.json с полем "outpost".
	var op: Variant = _read_sidecar(base + ".outposts.json")
	_outposts = op if op != null and op is Array else []
	# Ручная разметка «Нельзя пройти» — редактор пишет её рядом с .alm
	var n: Variant = _read_sidecar(base + ".nowalk.json")
	_nowalk.clear()
	if n != null and n is Array:
		for pair in n:
			if pair is Array and pair.size() >= 2:
				_nowalk[Vector2i(int(pair[0]), int(pair[1]))] = true
	# Ручная разметка «Разрешить проход» — пускать сквозь препятствие (дерево/камень)
	var a: Variant = _read_sidecar(base + ".allowwalk.json")
	_allowwalk.clear()
	if a != null and a is Array:
		for pair in a:
			if pair is Array and pair.size() >= 2:
				_allowwalk[Vector2i(int(pair[0]), int(pair[1]))] = true

## Прочитать sidecar: null — файла нет (использовать секции .alm),
## иначе массив записей (пустой — сущностей нет).
func _read_sidecar(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		return null
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if parsed is Dictionary:
		if parsed.has("structures") and parsed["structures"] is Array:
			return parsed["structures"]
		if parsed.has("npcs") and parsed["npcs"] is Array:
			return parsed["npcs"]
		if parsed.has("herbs") and parsed["herbs"] is Array:
			return parsed["herbs"]
		if parsed.has("nowalk") and parsed["nowalk"] is Array:
			return parsed["nowalk"]
		if parsed.has("allowwalk") and parsed["allowwalk"] is Array:
			return parsed["allowwalk"]
		if parsed.has("outposts") and parsed["outposts"] is Array:
			return parsed["outposts"]
		return []
	if parsed is Array:
		return parsed
	return []

## Список юнитов карты для спавна: секция id=6 (.alm) или sidecar .npcs.json.
## Записи: {x, y — клетки, type_id | set, player, hp_max}.
func get_units() -> Array:
	return map_units


## City list for the SIM layer (04.11): one record per city head, carrying the
## race, the averaged centre cell and the population (all NPCs of that city).
## Custom maps without city_id still produce one city per head.
func get_cities() -> Array:
	var heads := city_heads()
	var out: Array = []
	for cid in heads:
		var rec: Dictionary = heads[cid]
		var cells: Array = rec.get("cells", [])
		if cells.is_empty():
			continue
		var sx := 0
		var sy := 0
		for c in cells:
			sx += int(c[0])
			sy += int(c[1])
		var pop := 0
		for d in map_units:
			if str(d.get("city_id", "")) == str(cid):
				pop += 1
		out.append({
			"id": str(cid),
			"race": str(rec.get("race", "")),
			"x": int(round(float(sx) / float(cells.size()))),
			"y": int(round(float(sy) / float(cells.size()))),
			"population": maxi(1, pop),
		})
	return out


## Форпосты фракций этой карты: [{id, faction, name, x, y}].
## Пусто у карт без sidecar .outposts.json (военные .alm, старые карты).
func outposts() -> Array:
	return _outposts


## Подключить врага к событию смерти карты (Game._spawn_monster).
## Двойной коннект не возможен: сигнал исчезает вместе с узлом.
func watch_enemy(unit: Enemy) -> void:
	if unit != null and is_instance_valid(unit) \
			and not unit.died.is_connected(_on_enemy_died):
		unit.died.connect(_on_enemy_died)


func _on_enemy_died(unit: Enemy) -> void:
	enemy_died.emit(unit)


## Главы городов этой карты: city_id -> {race, cells: [[x,y], ...]}.
##
## Квесты (QuestSystem) спрашивают карту, а не sidecar: у карт генератора
## city_id записан в каждой НПЦ-записи, у военных .alm его нет — тогда глава
## без города получает стабильный id "c<x>y<y>" (одинаков при каждой загрузке),
## а офферы такого города есть только у него самого.
func city_heads() -> Dictionary:
	var out := {}
	for rec in map_units:
		if not (rec is Dictionary):
			continue
		var d: Dictionary = rec
		var is_head := bool(d.get("head", false)) \
			or str(d.get("role", "")) == "head"
		if not is_head:
			continue
		var cid := str(d.get("city_id", ""))
		if cid == "":
			cid = "c%dx%d" % [_cell_x(d), _cell_y(d)]
		if not out.has(cid):
			out[cid] = {"race": _race_of_record(d), "cells": []}
		(out[cid]["cells"] as Array).append([_cell_x(d), _cell_y(d)])
	return out


func _cell_x(d: Dictionary) -> int:
	return int(d.get("x", 0))


func _cell_y(d: Dictionary) -> int:
	return int(d.get("y", 0))


## Раса города по набору НПЦ: "humans"/"ork"/"druid"/"necro".
func _race_of_record(d: Dictionary) -> String:
	var set_name := str(d.get("set", ""))
	if set_name == "" and d.has("type_id"):
		set_name = UnitDB.set_name_for_id(int(d["type_id"]))
	var race := MapGenerator.race_of_set(set_name)
	return race if race != "" else MapGenerator.city_race_for_hero(Game.hero_race)

## --- Запросы для движения и миникарты ---

func _cell_of(pos: Vector2) -> Vector2i:
	return Vector2i(int(int(pos.x) / float(TILE)), int(int(pos.y) / float(TILE)))

func height_at_tile(tx: int, ty: int) -> int:
	if tx < 0 or ty < 0 or tx >= map_width or ty >= map_height:
		return 0
	var i := ty * map_width + tx
	if i < 0 or i >= _heights.size():
		return 0
	return int(_heights[i])

func height_at_world(pos: Vector2) -> int:
	return int(round(relief_at_world(pos)))

func flag_at_world(pos: Vector2) -> int:
	var tx := int(int(pos.x) / float(TILE))
	var ty := int(int(pos.y) / float(TILE))
	if tx < 0 or ty < 0 or tx >= map_width or ty >= map_height:
		return AlmLoader.TileFlag.BARRIER
	return AlmLoader.classify(_hflags[ty * map_width + tx])

func is_walkable_world(pos: Vector2) -> bool:
	var tx := int(int(pos.x) / float(TILE))
	var ty := int(int(pos.y) / float(TILE))
	if tx < 0 or ty < 0 or tx >= map_width or ty >= map_height:
		return false
	# Ручная разметка «Нельзя пройти» (редактор) — приоритет над автоматикой
	if _nowalk.has(Vector2i(tx, ty)):
		return false
	var i := ty * map_width + tx
	var hf := _hflags[i]
	# Спец-значения Nival (16..40 - вода/барьер в byte[1]) — непроходимы.
	# Проверка живёт в WalkTable.is_special, потому что байты 23..30 -
	# это наши переходные тайлы, а не Nival (см. комментарий там).
	if WalkTable.is_special(hf):
		return false
	var file_n := AlmLoader.terrain_file_of(hf)
	if file_n < 0:
		return false
	# У переходного тайла поле variant хранит биом-владельца, а не номер
	# текстуры, поэтому в WalkTable отдаём 0: иначе оверрайд вида "2-12"
	# мог бы примениться к переходу с несуществующей текстурой 12.
	var variant := 0
	if file_n == (hf & 0xF) + 1:
		variant = clampi((_terrain[i] >> 4) & 0xF, 0, 15)
	# Таблица «цены прохода по текстуре» (WalkTable): вода (tile3) и
	# переопределённые варианты с ценой 0 — непроходимы; горы/песок — проходимы
	if not WalkTable.walkable(file_n, variant):
		return false
	var allow := _allowwalk.has(Vector2i(tx, ty))
	# Объект (дерево/камень из obstacles) — непроходимо (кроме allowwalk-разметки)
	if not allow and _obstacles.size() > i and _obstacles[i] > 0:
		return false
	# Здания (секция id=4) — непроходимы по навигационному футпринту
	if not allow and _structure_blocks_cell(Vector2i(tx, ty)):
		return false
	return true

## Множитель скорости по текстуре клетки (WalkTable, как у разработчиков:
## скорость = 8 / цена прохода). Дорога быстрее травы, песок/горы медленнее.
func speed_factor_at_world(pos: Vector2) -> float:
	var tx := int(int(pos.x) / float(TILE))
	var ty := int(int(pos.y) / float(TILE))
	if tx < 0 or ty < 0 or tx >= map_width or ty >= map_height:
		return 1.0
	return WalkTable.speed_at(_hflags[ty * map_width + tx], _terrain[ty * map_width + tx])

## Тип клетки 0..3 для миникарты: 0 трава, 1 горы, 2 вода/барьер, 3 дорога.
func cell_type_at(tx: int, ty: int) -> int:
	if tx < 0 or ty < 0 or tx >= map_width or ty >= map_height:
		return 0
	var t := AlmLoader.terrain_type(_hflags[ty * map_width + tx])
	if t == -1 or t == -2:
		return 2
	return t

## Причина непроходимости клетки («», если проходима) — для подсказки координат.
## «Трава» может быть занята деревом/камнем (obstacles), зданием или разметкой.
func blocked_reason(cell: Vector2i) -> String:
	if cell.x < 0 or cell.y < 0 or cell.x >= map_width or cell.y >= map_height:
		return "вне карты"
	if _nowalk.has(cell):
		return "запрет разметки"
	var i := cell.y * map_width + cell.x
	var hf := _hflags[i]
	if WalkTable.is_special(hf):
		return "барьер (спец-тайл)"
	var file_n := AlmLoader.terrain_file_of(hf)
	if file_n < 0:
		return "барьер (неизвестный тип тайла)"
	var variant := 0
	if file_n == (hf & 0xF) + 1:
		variant = clampi((_terrain[i] >> 4) & 0xF, 0, 15)
	if not WalkTable.walkable(file_n, variant):
		if file_n == WalkTable.WATER_FILE:
			return "вода (tile3)"
		if file_n == WalkTable.MOUNTAIN_FILE:
			return "горы (tile2) — непроходимы"
		return "непроходимая текстура (tile%d-%02d)" % [file_n, variant]
	if _obstacles.size() > i and _obstacles[i] > 0:
		return "дерево/камень"
	if _structure_blocks_cell(cell):
		return "здание"
	return ""

func is_within_bounds(pos: Vector2, margin: float = 12.0) -> bool:
	var min_x := margin
	var min_y := margin
	var max_x := map_width * TILE - margin
	var max_y := map_height * TILE - margin
	return pos.x >= min_x and pos.y >= min_y and pos.x <= max_x and pos.y <= max_y

## --- Путь (pathfinding): BFS по сетке проходимости, обход препятствий ---

## Путь от from_world до to_world в мировых точках (центры клеток), без первой
## клетки. Если цель непроходима — ищем путь к ближайшей проходимой рядом с ней
## (клик по дереву/воде подводит героя к самому краю). Пустой — пути нет.
func find_path(from_world: Vector2, to_world: Vector2) -> Array:
	if not Game.perf_enabled:
		return _find_path_impl(from_world, to_world)
	var t0 := Time.get_ticks_usec()
	var out := _find_path_impl(from_world, to_world)
	Game.perf_end("find_path", t0)
	Game.perf_count("find_path_calls")
	return out


func _find_path_impl(from_world: Vector2, to_world: Vector2) -> Array:
	var start := _cell_of(from_world)
	var goal := _cell_of(to_world)
	# Герой может стоять в клетке, которая по разметке непроходима (упёрся/склон):
	# путь начинаем от ближайшей ПРОХОДИМОЙ клетки рядом, иначе «нельзя вернуться».
	if not _cell_walkable(start):
		start = _nearest_walkable(start, 4)
		if start.x < 0:
			return []
	if not _cell_walkable(goal):
		# Цель непроходима: пробуем 4 соседей, берём ближайшего
		var best: Vector2i = goal
		var best_d := -1.0
		for d in _DIRS_4:
			var n := goal + d
			if _cell_walkable(n):
				var dist := from_world.distance_squared_to(Vector2(n.x * TILE + TILE / 2.0, n.y * TILE + TILE / 2.0))
				if best_d < 0.0 or dist < best_d:
					best_d = dist
					best = n
		if best_d < 0.0:
			# Цель глубоко в объекте/воде (ни один из 4 соседей не проходим):
			# идём к ближайшей суше спиралью, иначе клик превращается в «бег
			# на месте» у кромки (пустая прямая трассировка в move_to_target).
			var shore := _nearest_walkable(goal, 24)
			if shore.x < 0:
				return []
			goal = shore
		else:
			goal = best

	# Жадный best-first по эвристике Чебышёва (целые «ведёрки» — O(1) извлечение).
	# BFS мерился 360+ мс; линейный минимум по open — ещё ~50 мс. Вёдра срезают
	# выборку до O(1) и держат длинный клик в единицах мс.
	var prev := {}
	var g_cost := {start: 0.0}
	var h0 := _heuristic(start, goal)
	var buckets: Array = []
	_ensure_bucket(buckets, int(h0))
	(buckets[int(h0)] as Array).append(start)
	var min_h := int(h0)
	var closed := {}
	var expanded := 0
	var best := Vector2i(-1, -1)
	var best_h := 1.0e18
	var hit_limit := false
	while true:
		# Ближайшая непустая ведро
		while min_h < buckets.size() and (buckets[min_h] as Array).is_empty():
			min_h += 1
		if min_h >= buckets.size():
			break
		if expanded >= BFS_MAX_CELLS:
			hit_limit = true
			break
		var bucket: Array = buckets[min_h]
		var cur: Vector2i = bucket.pop_back()
		if closed.has(cur):
			continue
		closed[cur] = true
		expanded += 1
		var h_cur := _heuristic(cur, goal)
		if h_cur < best_h:
			best_h = h_cur
			best = cur
		if cur == goal:
			best = cur
			break
		var g_cur: float = float(g_cost.get(cur, 1.0e18))
		for d in _DIRS_8:
			var n := cur + d
			if closed.has(n) or not _cell_walkable(n):
				continue
			if _structure_blocks_cell(n):
				continue
			if d.x != 0 and d.y != 0:
				var side1 := cur + Vector2i(d.x, 0)
				var side2 := cur + Vector2i(0, d.y)
				if not _cell_walkable(side1) or not _cell_walkable(side2):
					continue
				if _structure_blocks_cell(side1) or _structure_blocks_cell(side2):
					continue
			var step := 1.4142 if (d.x != 0 and d.y != 0) else 1.0
			var ng := g_cur + step
			if ng >= float(g_cost.get(n, 1.0e18)):
				continue
			g_cost[n] = ng
			prev[n] = cur
			var hn := int(_heuristic(n, goal))
			_ensure_bucket(buckets, hn)
			(buckets[hn] as Array).append(n)
			if hn < min_h:
				min_h = hn
	if best.x < 0:
		return []
	var end_cell: Vector2i = goal
	if hit_limit or not closed.has(goal):
		if best.x < 0:
			return []
		end_cell = best

	# Восстановить путь и перевести в мировые точки (центры клеток)
	var cells: Array = []
	var c := end_cell
	var guard := 0
	while c != start and guard < expanded + 8:
		cells.append(c)
		if not prev.has(c):
			break
		c = prev[c]
		guard += 1
	cells.reverse()
	if cells.is_empty():
		return []
	var out: Array = []
	for cell in cells:
		out.append(Vector2(cell.x * TILE + TILE / 2.0, cell.y * TILE + TILE / 2.0))
	return out


func _ensure_bucket(buckets: Array, h: int) -> void:
	while buckets.size() <= h:
		buckets.append([])


## Эвристика: Чебышёв (допустима при 8-связности).
func _heuristic(a: Vector2i, b: Vector2i) -> float:
	return float(maxi(absi(a.x - b.x), absi(a.y - b.y)))

func _cell_walkable(cell: Vector2i) -> bool:
	return is_walkable_world(Vector2(cell.x * TILE + TILE / 2.0, cell.y * TILE + TILE / 2.0))

## Ближайшая проходимая клетка (спираль радиуса r) или (-1,-1).
func _nearest_walkable(cell: Vector2i, r: int) -> Vector2i:
	if _cell_walkable(cell):
		return cell
	for radius in range(1, r + 1):
		for dy in range(-radius, radius + 1):
			for dx in range(-radius, radius + 1):
				if abs(dx) != radius and abs(dy) != radius:
					continue
				var c := cell + Vector2i(dx, dy)
				if _cell_walkable(c):
					return c
	return Vector2i(-1, -1)

func tile_id_at(cell: Vector2i) -> int:
	if cell.x < 0 or cell.y < 0 or cell.x >= map_width or cell.y >= map_height:
		return -1
	return _hflags[cell.y * map_width + cell.x]

## Area-spell damage against world objects (trees, rocks, barrels). The cell
## becomes walkable the moment the object breaks, so pathfinding and the click
## marker agree with what the player sees.
func damage_area(world_pos: Vector2, radius: float, dmg: int) -> void:
	if radius <= 0.0 or dmg <= 0:
		return
	var center := _cell_of(world_pos)
	var reach := int(ceil(radius / float(TILE))) + 1
	for ty in range(center.y - reach, center.y + reach + 1):
		for tx in range(center.x - reach, center.x + reach + 1):
			if tx < 0 or ty < 0 or tx >= map_width or ty >= map_height:
				continue
			var at := Vector2i(tx, ty)
			var ob: AlmObstacle = _obstacle_nodes.get(at)
			if ob == null or not is_instance_valid(ob):
				continue
			# Compare against the CELL's ground point: the node itself is raised
			# by relief, and a tree on a hill must not dodge a fireball.
			var ground := Vector2(tx * TILE + TILE / 2.0, ty * TILE + TILE / 2.0)
			if ground.distance_to(world_pos) > radius + TILE * 0.5:
				continue
			ob.take_damage(dmg)


func _on_obstacle_destroyed(at: Vector2i) -> void:
	_obstacle_nodes.erase(at)
	if at.x < 0 or at.y < 0 or at.x >= map_width or at.y >= map_height:
		return
	var i := at.y * map_width + at.x
	if i >= 0 and i < _obstacles.size():
		_obstacles[i] = 0