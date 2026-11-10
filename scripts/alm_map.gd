extends Node2D
class_name AlmMap
## Developers' map from .alm: a relief mesh with heights and sun lighting
## (Allods16/repo jewalky method): every tile quad is raised to the height of its corners,
## the texture is stretched, brightness is computed from the quad normal and the sun angle.
## Plus: buildings from section id=4 (structures) and obstacles from section id=3.

## Death of a Grey on this map (22.10). The map is the parent of all enemies, so
## the enemy itself does not reach into the bus; QuestSystem subscribes here once.
signal enemy_died(unit: Enemy)

@export var alm_path: String = ""
@export var tile_size := 32   # same property as CustomMap (for the minimap and others)

const TILE := 32
# Mesh height per 1 unit of map height (the original draws 1:1)
const HEIGHT_SCALE := 1.0
## Expansion ceiling for the pathfinding search. Greedy best-first on open terrain
## is usually ~O(path length); the limit is insurance against mazes.
const BFS_MAX_CELLS := 4000

var map_width: int = 0
var map_height: int = 0
var _terrain: PackedByteArray   # byte[0] — autotile variant
var _hflags: PackedByteArray    # byte[1] — terrain type (file-1: 0..3)
var _heights: PackedByteArray   # int8 — relief (0..127)
var _obstacles: PackedByteArray # uint8 — objects (0=none, >0=object)
var _structures: Array = []     # section id=4 — buildings (or the .structures.json sidecar)
var map_units: Array = []       # section id=6 — units (or the .npcs.json sidecar)
var _herbs: Array = []
var _outposts: Array = []       # faction outposts (sidecar .outposts.json)
var _nowalk: Dictionary = {}    # "Impassable" cells (manual marking in the editor)
var _allowwalk: Dictionary = {} # "Allow passage" cells — let units through an obstacle
var solar_angle: float = 0.785398  # sun angle from info (.alm), default 45°

var mesh: MeshInstance2D
## Relief layer: a soft blend of all biome pairs (05.10).
## MeshInstance2D in Godot 4.7 has no surface_override_material — hence a separate node.
var blend_mesh: MeshInstance2D
var _atlas: ImageTexture
var _cell_uv := {}              # "f{v}-r{row}" -> Rect4(u0,v0,u1,v1)
## Interior strips tile1..7 (6 variants), index = terrain type 0..6.
var _blend_strips: Array = []
## Blend maps.
## primary/secondary — the types of the pair (nearest).
## u_border: 0 — depth, ~1 — border; blur ×1 (×3 smeared the seam over 2-3
## cells and gave "a strip of the foreign biome"). The mix in the shader: smoothstep over border.
var _blend_primary: ImageTexture
var _blend_secondary: ImageTexture
var _blend_border: ImageTexture
var _blend_cells := 0
## Terrain chunk rendering (19.10): BlendMesh is cut into CHUNK_CELLS squares,
## visible only inside the camera frame (+CHUNK_MARGIN). The map foundation is 96x96.
const CHUNK_CELLS := 16
const CHUNK_MARGIN := 96.0
var _blend_chunks: Array = []     # blend chunks: {node: MeshInstance2D, rect: Rect2}
var _atlas_cells := 0
const ROAD_T := 3
const MOUNTAIN_T := 1
const WATER_T := 2
const BIOME_COUNT := 7
## How many map cells fit into one blend texture tile (1 = 32px per cell).
const BLEND_CELLS_PER_TEX := 1.0
var _obstacle_db := {}          # .alm obstacle id -> {folder, w, h, cx, cy, phases}
## folder -> HP from assets/map-objects/destructibles.json (04.11).
var _destructible_hp := {}
## Vector2i -> AlmObstacle, so an area spell can find the node by cell.
var _obstacle_nodes := {}
var obstacles_root: Node2D      # obstacle layer (y-sort)
var buildings: Node2D           # building layer (y-sort)
var herbs_root: Node2D
var world_sort: Node2D          # shared y-sort: obstacles + buildings (a crown overlaps the fountain)
var _structure_hits: Array = [] # building hitboxes {x0,x1,y0,y1,picture,type_id}
var _structure_nav: Array = []   # building navigation footprints
var _portal_cells: Array = []   # portal coordinates (Vector2i)
var _portals: Array = []        # [{cell:Vector2i, to:String, dir:String}] — the 4x3 world
var _spawn_cell: Vector2i = Vector2i(-1, -1)
var _portal_markers: Array = [] # PortalMarker instances
var _spawn_marker: Node2D = null

## A single y-sorted layer for obstacles and buildings: the more southern one is on top.
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

## Obstacle table: .alm obstacle id -> sprite parameters (from objects.txt/obj.reg).
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

## Obstacles (.alm obstacles): a tree/stone/statue on cells with id > 0.
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

## Buildings from section id=4 (structures): sprites assets/structures/<folder>/house-NNN.png.
## Frame grid 32x32: fw=TileWidth, fh=FullHeight; the top (fh-th) rows are above the ground.
## Shadow (houseb) and phase animation (Phases>1) — via StructureNode / StructureDB.
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
		# Position: cell (X, Y) = the bottom-left corner of the body; the top is raised by (fh-th) cells
		var x: float = st.get("x", 0.0)
		var y: float = st.get("y", 0.0)
		var dir := int(fj.get("fh", 1)) - int(fj.get("th", 1))
		node.position = Vector2(x * TILE, (y - dir) * TILE)
		buildings.add_child(node)
		placed += 1
		# Building hitbox in cells: the base is the Selection box (structure pixels),
		# otherwise the body of th rows (+ the top (fh-th) visual rows).
		var fw := int(fj.get("fw", 1))
		var th := int(fj.get("th", 1))
		var fh := int(fj.get("fh", th))
		var sel: Rect2i = fj.get("sel", Rect2i())
		if sel.size.x > 0 and sel.size.y > 0:
			# Selection in pixels of the source sprite (fw*fh*32): convert to cells
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
		herb.setup(item_key, icon_path, grid_cell, relief_at_tile(grid_cell.x, grid_cell.y),
			HerbDB.frames_of(item_key), HerbDB.fps_of(item_key))
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

## Build a Node2D building: whole_image (a single PNG) or a house-NNN grid + shadow.
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

## Building description: folder/frame prefix, grid fw x fh (from structures.txt).
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

## Structure data by TypeID: from the structured DB (structure_db.json).
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

## Public: is the cell inside a building footprint (for a hard entry ban).
func is_structure_cell(cell: Vector2i) -> bool:
	return _structure_blocks_cell(cell)

## Public cell blocking (walls of fire/earth for their lifetime).
## Removed by the same call with value=false.
func set_nowalk_cell(cell: Vector2i, value: bool) -> void:
	if value:
		_nowalk[cell] = true
	else:
		_nowalk.erase(cell)

## Is there an active blocking on the cell.
func is_nowalk_cell(cell: Vector2i) -> bool:
	return _nowalk.has(cell)

## The building under the cursor (cell) — for hover; returns a Dictionary or {}.
func structure_at(cell: Vector2i) -> Dictionary:
	for h in _structure_hits:
		if cell.x >= int(h["x0"]) and cell.x <= int(h["x1"]) \
				and cell.y >= int(h["y0"]) and cell.y <= int(h["y1"]):
			return h
	return {}

## Relief: real heights (for visuals and movement speed).
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

# --- Textures: an atlas of all used (file, variant, row) ---

func _used_cells() -> Dictionary:
	## Key "f{file}-v{variant}-r{row}" -> true. file 1..15, variant 0..15, row 0..nrows-1
	##
	## Files 1..7 — interiors, 8..15 — transitions (variant = owner biome A,
	## row = neighbour B*2 + variation). Their key is shared with interiors, because
	## file_n and variant live in different tile bits and cannot be
	## told apart on their own — file_n is what tells them apart.
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
	# Group the needed keys by pair (file, variant). A BMP is a strip
	# of 14 rows, and loading it whole for a single row is wasteful:
	# before, ALL variants of all 15 files were loaded here (up to ~190 images
	# of 32x448) and the unused ones were dropped only AFTER loading.
	var want := {}  # file_n * 16 + variant -> true
	for key in used:
		var s: String = key
		# Search from index 1, not 2: for files 1..7 the number is unambiguous and
		# the separator sits exactly at position 2. With find("-", 2) it was found
		# by itself, substr returned an empty string, interiors silently dropped out of
		# the atlas (12 cells instead of 482) and the cells were simply not drawn.
		var d1: int = s.find("-", 2)
		var d2: int = s.find("-", d1 + 1)
		if d1 < 0 or d2 < 0:
			push_error("AlmMap: не разобрать ключ ячейки: " + s)
			continue
		var f: int = s.substr(1, d1 - 1).to_int()
		var v: int = s.substr(d1 + 2, d2 - d1 - 2).to_int()
		want[f * 16 + v] = true

	# Collect the actual (file, variant, row) with the real number of rows in the file
	var cells: Array = []  # [key, Image32]
	var key_to_cell := {}
	# Files 1..7 — interiors (16 variants, the road tile4 has only 4),
	# files 8..15 — transitions (7 variants = 7 owner biomes).
	# See assets/maps/terrain_tiles_db.json.
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
			# There can be no duplicates: want is unique by (file, variant),
			# and the row key additionally encodes the row number.
			if not used.has(key):
				continue
			var cell_img: Image = img.get_region(Rect2i(0, row * TILE, TILE, TILE))
			cells.append([key, cell_img])
			key_to_cell[key] = cells.size() - 1
	print("AlmMap: загружено %d файлов тайлов из %d используемых пар" % [loaded, want.size()])
	# Invariant: every used cell must make it into the atlas. If a
	# cell dropped out (missing file, wrong row, broken key), _build_relief_mesh
	# would silently skip it via `continue` on a zero UV, and there would be a hole in the ground.
	# Verified on a real bug: 12 cells instead of 482, and all tests were
	# green — only this check catches it.
	if cells.size() != used.size():
		push_error("AlmMap: в атлас попало %d ячеек из %d используемых" % [cells.size(), used.size()])

	# Build the atlas of 64x64 cells (up to 4096)
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

## For debugging: the atlas texture itself.
func get_atlas_texture() -> ImageTexture:
	return _atlas

func _uv_for_cell(file_n: int, variant: int, row: int) -> Vector4:
	var key := "f%d-v%d-r%d" % [file_n, variant, row]
	var r: Vector4 = _cell_uv.get(key, Vector4(0, 0, 0, 0))
	return r

# --- Relief mesh with lighting ---

func _node_h(nx: int, ny: int) -> float:
	## Grid node (cell corner) height, clamped to the map borders.
	var cx := clampi(nx, 0, map_width - 1)
	var cy := clampi(ny, 0, map_height - 1)
	return float(_heights[cy * map_width + cx]) * HEIGHT_SCALE

func _cell_normal(x: int, y: int) -> Vector3:
	## Quad normal (Allods16): u=(32,0,uz), v=(0,32,vz),
	## where uz = h(x+1,y)-h(x,y), vz = h(x,y+1)-h(x,y). n = cross(u,v).
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
	## Cell brightness: |n·sun|*64+96, then contrast (as in Allods16).
	## In the original shade/4 is the index of the brightness palette (0..64, 32 = normal),
	## so we normalise by 128: flat terrain ~1.0, slopes darker.
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

	# Biome field — as in the pilot: type/6 + blur ×3. Not "border 0/1".
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
	# Blur ×1 — a soft edge without a "strip" 2-3 cells deep into the biome.
	border_img = _box_blur_rf(border_img)
	_blend_primary = ImageTexture.create_from_image(prim_img)
	_blend_secondary = ImageTexture.create_from_image(sec_img)
	_blend_border = ImageTexture.create_from_image(border_img)

	_build_blend_assets()

	# ReliefMesh keeps the atlas material (tests/lighting reference it).
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

	# Blend material and shader — shared by all chunks (19.10).
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

	# Chunks of 16×16 cells: the same material and map-wide UVs, but every chunk is
	# its own MeshInstance2D that is hidden outside the camera frame (19.10).
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
					# COLOR.a — brightness only (pilot pattern). Types — in the textures.
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

## Chunk visibility by camera: a chunk outside the frame (+margin) is not drawn.
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

## Pair (secondary, unused_border) — secondary = the most frequent foreign neighbour.
## The mix itself in the shader: over the type/6 field between tid and nid (pilot formula).
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

## Interior strips tile1..7 (6 variants each) for all biomes.
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

## A strip of BMP32x448 variants. Nearest — the texture does not "float".
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

## Spawn world position: from the anchor file "<name>.spawn.json" next to the .alm
## (placed by the map editor) or the map centre (game.gd finds a walkable tile itself).
func get_spawn_pos() -> Vector2:
	var anchor := _load_spawn_anchor()
	if anchor.x >= 0:
		return Vector2(anchor.x * TILE + TILE / 2.0, anchor.y * TILE + TILE / 2.0)
	return Vector2(map_width * TILE / 2.0, map_height * TILE / 2.0)

## Map choice at start. Order:
##  1. An explicitly requested path (Game.pending_map_path) — map editor, loading a save.
##  2. Map by seed (Game.map_seed != 0) — new game: generate or reuse
##     a map in user://maps/. This is exactly where unique maps appear.
##  3. Fallback path from main.tscn — dev mode and autotests. Without a requested seed
##     the game would always load the same gen_smart_01.alm.
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
	# 3. Fallback — alm_path from the scene.

## Spawn cell from the anchor file next to the .alm, or (-1,-1).
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
	# Load spawn from the sidecar
	var sp := _load_spawn_anchor()
	if sp.x >= 0:
		_spawn_cell = sp
		# Create the spawn marker
		var pm := preload("res://scripts/portal_marker.gd").new()
		pm.setup(sp, "spawn_marker")
		pm.z_index = 10
		add_child(pm)
		_spawn_marker = pm
	# Load portal from the sidecar
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
					# Old format: a single portal {x,y} without an address.
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

## Sector portals: [{cell, to, dir}]. An empty to — an old sidecar without an address.
func get_portals() -> Array:
	return _portals

func get_spawn_cell() -> Vector2i:
	return _spawn_cell

## Sidecar files next to the .alm — the editor saves the full state
## of structures and NPCs into them (the .alm itself is not overwritten):
##   "<name>.structures.json" — {"structures": [{x, y, type_id}]}
##   "<name>.npcs.json"       — {"npcs": [{x, y, set}]}
## If a sidecar exists — it OVERRIDES sections 4/6 of the .alm (the editor copies
## them there on first open); otherwise the original sections are used.
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
	# Faction outposts (pack B): a separate sidecar, while the guards travel as
	# ordinary .npcs.json records with an "outpost" field.
	var op: Variant = _read_sidecar(base + ".outposts.json")
	_outposts = op if op != null and op is Array else []
	# Manual "Impassable" marking — the editor writes it next to the .alm
	var n: Variant = _read_sidecar(base + ".nowalk.json")
	_nowalk.clear()
	if n != null and n is Array:
		for pair in n:
			if pair is Array and pair.size() >= 2:
				_nowalk[Vector2i(int(pair[0]), int(pair[1]))] = true
	# Manual "Allow passage" marking — let units through an obstacle (tree/stone)
	var a: Variant = _read_sidecar(base + ".allowwalk.json")
	_allowwalk.clear()
	if a != null and a is Array:
		for pair in a:
			if pair is Array and pair.size() >= 2:
				_allowwalk[Vector2i(int(pair[0]), int(pair[1]))] = true

## Read a sidecar: null — the file is absent (use the .alm sections),
## otherwise an array of records (empty — no entities).
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

## List of map units for spawning: section id=6 (.alm) or the .npcs.json sidecar.
## Records: {x, y — cells, type_id | set, player, hp_max}.
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


## Faction outposts of this map: [{id, faction, name, x, y}].
## Empty for maps without an .outposts.json sidecar (military .alm, old maps).
func outposts() -> Array:
	return _outposts


## Connect an enemy to the map death event (Game._spawn_monster).
## A double connect is impossible: the signal disappears together with the node.
func watch_enemy(unit: Enemy) -> void:
	if unit != null and is_instance_valid(unit) \
			and not unit.died.is_connected(_on_enemy_died):
		unit.died.connect(_on_enemy_died)


func _on_enemy_died(unit: Enemy) -> void:
	enemy_died.emit(unit)


## City heads of this map: city_id -> {race, cells: [[x,y], ...]}.
##
## Quests (QuestSystem) ask the map rather than the sidecar: for generator maps
## city_id is written in every NPC record, for military .alm it is absent — then the head
## without a city gets a stable id "c<x>y<y>" (the same on every load),
## and such a city's offers exist only with it.
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


## City race by the NPC set: "humans"/"ork"/"druid"/"necro".
func _race_of_record(d: Dictionary) -> String:
	var set_name := str(d.get("set", ""))
	if set_name == "" and d.has("type_id"):
		set_name = UnitDB.set_name_for_id(int(d["type_id"]))
	var race := MapGenerator.race_of_set(set_name)
	return race if race != "" else MapGenerator.city_race_for_hero(Game.hero_race)

## --- Queries for movement and the minimap ---

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
	# Manual "Impassable" marking (editor) — takes priority over the automatic one
	if _nowalk.has(Vector2i(tx, ty)):
		return false
	var i := ty * map_width + tx
	var hf := _hflags[i]
	# Nival special values (16..40 — water/barrier in byte[1]) — impassable.
	# The check lives in WalkTable.is_special, because bytes 23..30 are
	# our transition tiles, not Nival ones (see the comment there).
	if WalkTable.is_special(hf):
		return false
	var file_n := AlmLoader.terrain_file_of(hf)
	if file_n < 0:
		return false
	# For a transition tile the variant field stores the owner biome, not the texture
	# number, so we pass 0 to WalkTable: otherwise an override like "2-12"
	# could apply to a transition with a non-existent texture 12.
	var variant := 0
	if file_n == (hf & 0xF) + 1:
		variant = clampi((_terrain[i] >> 4) & 0xF, 0, 15)
	# "Passage cost by texture" table (WalkTable): water (tile3) and
	# overridden variants with cost 0 are impassable; mountains/sand are walkable
	if not WalkTable.walkable(file_n, variant):
		return false
	var allow := _allowwalk.has(Vector2i(tx, ty))
	# An object (tree/stone from obstacles) — impassable (except manually allowwalk-marked cells)
	if not allow and _obstacles.size() > i and _obstacles[i] > 0:
		return false
	# Buildings (section id=4) — impassable by navigation footprint
	if not allow and _structure_blocks_cell(Vector2i(tx, ty)):
		return false
	return true

## Speed multiplier by cell texture (WalkTable, as in the original:
## speed = 8 / passage cost). The road is faster than grass, sand/mountains slower.
func speed_factor_at_world(pos: Vector2) -> float:
	var tx := int(int(pos.x) / float(TILE))
	var ty := int(int(pos.y) / float(TILE))
	if tx < 0 or ty < 0 or tx >= map_width or ty >= map_height:
		return 1.0
	return WalkTable.speed_at(_hflags[ty * map_width + tx], _terrain[ty * map_width + tx])

## Cell type 0..3 for the minimap: 0 grass, 1 mountains, 2 water/barrier, 3 road.
func cell_type_at(tx: int, ty: int) -> int:
	if tx < 0 or ty < 0 or tx >= map_width or ty >= map_height:
		return 0
	var t := AlmLoader.terrain_type(_hflags[ty * map_width + tx])
	if t == -1 or t == -2:
		return 2
	return t

## Reason why a cell is impassable ("", if walkable) — for the coordinate tooltip.
## "Grass" may be occupied by a tree/stone (obstacles), a building or a marking.
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

## --- Path (pathfinding): BFS over the walkability grid, going around obstacles ---

## Path from from_world to to_world in world points (cell centres), without the first
## cell. If the goal is impassable — look for a path to the nearest walkable cell next to it
## (a click on a tree/water leads the hero right to the edge). Empty — no path.
##
## `blocked` — cells held by other units (Diablo 2 pathing): the search goes AROUND
## them instead of driving into a body. The caller builds it with Game.occupied_cells()
## and must leave the watched/target unit out. A fully enclosed goal still returns a
## partial path to the closest reachable cell.
func find_path(from_world: Vector2, to_world: Vector2, blocked: Dictionary = {}) -> Array:
	if not Game.perf_enabled:
		return _find_path_impl(from_world, to_world, blocked)
	var t0 := Time.get_ticks_usec()
	var out := _find_path_impl(from_world, to_world, blocked)
	Game.perf_end("find_path", t0)
	Game.perf_count("find_path_calls")
	return out


## Nearest free cell around `cell` (up to `max_radius` rings): where a click on an
## occupied cell should lead. (-1,-1) — nothing free nearby.
func free_cell_near(cell: Vector2i, blocked: Dictionary, max_radius: int = 2) -> Vector2i:
	if not blocked.has(cell) and _cell_walkable(cell):
		return cell
	var best := Vector2i(-1, -1)
	var best_d := 1.0e18
	for r in range(1, max_radius + 1):
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if absi(dx) != r and absi(dy) != r:
					continue   # ring, not the filled square
				var c := cell + Vector2i(dx, dy)
				if blocked.has(c) or not _cell_walkable(c):
					continue
				var d := float(dx * dx + dy * dy)
				if d < best_d:
					best_d = d
					best = c
		if best.x >= 0:
			return best
	return best


func _find_path_impl(from_world: Vector2, to_world: Vector2, blocked: Dictionary = {}) -> Array:
	var start := _cell_of(from_world)
	var goal := _cell_of(to_world)
	# The hero may stand in a cell that is impassable by marking (stuck/slope):
	# start the path from the nearest WALKABLE cell nearby, otherwise "you cannot return".
	if not _cell_walkable(start):
		start = _nearest_walkable(start, 4)
		if start.x < 0:
			return []
	if not _cell_walkable(goal):
		# The goal is impassable: try the 4 neighbours, take the nearest one
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
			# The goal is deep inside an object/water (none of the 4 neighbours is walkable):
			# go to the nearest land in a spiral, otherwise the click turns into "running
			# in place" at the edge (an empty straight trace in move_to_target).
			var shore := _nearest_walkable(goal, 24)
			if shore.x < 0:
				return []
			goal = shore
		else:
			goal = best

	# The goal is held by another unit (a chase target that died and was replaced,
	# a follower): aim at the nearest free cell, like Diablo 2's PathTargetFree.
	if not blocked.is_empty() and blocked.has(goal):
		var free_goal := free_cell_near(goal, blocked, 2)
		if free_goal.x >= 0:
			goal = free_goal

	# Greedy best-first by the Chebyshev heuristic (integer "buckets" — O(1) extraction).
	# BFS was measured at 360+ ms; a linear minimum over open — another ~50 ms. Buckets cut
	# the selection down to O(1) and keep a long click in the units of ms.
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
		# The nearest non-empty bucket
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
			if not blocked.is_empty() and blocked.has(n):
				continue   # another unit stands here — route around it
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

	# Reconstruct the path and convert it to world points (cell centres)
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


## Heuristic: Chebyshev (admissible with 8-connectivity).
func _heuristic(a: Vector2i, b: Vector2i) -> float:
	return float(maxi(absi(a.x - b.x), absi(a.y - b.y)))

func _cell_walkable(cell: Vector2i) -> bool:
	# Bounds FIRST: int() truncates toward zero, so a point at y = -16 maps to
	# cell 0 inside is_walkable_world and a negative cell looked walkable. The
	# path then carried a waypoint OUTSIDE the map, the hero could never reach it
	# and crept along the border (the "long stalls while walking" report).
	if cell.x < 0 or cell.y < 0 or cell.x >= map_width or cell.y >= map_height:
		return false
	return is_walkable_world(Vector2(cell.x * TILE + TILE / 2.0, cell.y * TILE + TILE / 2.0))

## The nearest walkable cell (a spiral of radius r) or (-1,-1).
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