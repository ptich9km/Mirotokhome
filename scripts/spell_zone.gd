class_name SpellZone
extends Node2D
## Прямоугольная зона заклинания: стена огня, стена земли, метель, ядовитое облако.
##
## Раньше зона была ОДНИМ белым квадратом, растянутым под прямоугольник
## (стена 6×2 = 192×64 px), и это читалось как «глюк на земле»:
##   * UV сжимались в 6 раз по горизонтали, шум в шейдере был локальным —
##     эффект не был привязан к сетке мира и выглядел как наклейка;
##   * центр зоны брался из произвольной позиции кастера, поэтому границы
##     6×2 попадали В СЕРЕДИНУ клеток и визуал ВРАЛ про то, какие клетки накроет;
##   * хак «+4 px поверх» маскировал щели между тайлами, но РАСШИРЯЛ опасную
##     зону за пределы клеток с уроном — в другую сторону;
##   * заливка была 0.85–0.95 альфы: спрайт 6×2 был стеной краски, и юниты
##     в зоне пропадали.
##
## Теперь:
##   * позиция привязана к центру клетки — границы ровно по границам клеток;
##   * вся математика в шейдере идёт в МИРОВЫХ координатах (varying из
##     MODEL_MATRIX), поэтому зерно одинаково у 3×3 и 6×2;
##   * заливка слабая (0.20), яркий контур рисуется ТОЛЬКО по внешнему краю
##     (маска соседей) — 12 клеток читаются как один объект;
##   * фаза подсказки: сначала только контур, потом заливка идёт вдоль
##     длинной оси, и лишь потом начинается урон;
##   * затухание растворением, а не линейным modulate.a;
##   * заливка лежит ПОД слоем юнитов (z_index), чтобы не прятать их.
##
## Класс не привязан к стенам: `SpellWall` — его настроенная разновидность.

const TILE := 32
## Длительность фазы подсказки: игрок должен успеть среагировать. Порог 0.5 с —
## измеренное значение (реакция на неожиданный стимул ~0.25 с, на
## ожидаемый ~0.18 с; подсказка переводит второе в первое).
const TELEGRAPH_TIME := 0.55
## Длительность вспышки в момент попадания.
const SNAP_TIME := 0.08
## Затухание растворением в конце жизни.
const BURN_TIME := 0.5
## Заливка под юнитами, чтобы их не прятать. Контур рисуется вторым
## проходом поверх — иначе герой, стоящий в стене, её не виден.
const FILL_Z := 2
const EDGE_Z := 11
## Языки пламени огненной стены — третий проход, ПОВЕРХ юнитов (решение
## игрока). Заливка и контур зоны остаются под юнитом, поэтому границы
## опасных клеток он не прячет: наземный слой отвечает за «где бьёт»,
## а пламя — за «как выглядит огонь».
const FLAME_Z := 13
## Валуны каменной стены: выше заливки, но НИЖЕ юнитов — стена не должна
## прятать героя, стоящего рядом.
const STONE_Z := 6
## Насколько пламя поднимается вверх от прямоугольника зоны, в клетках.
## Огонь растёт вверх, и это НЕ расширяет опасную зону по клеткам.
const FLAME_RISE := 1.4

## Прямоугольник зоны в клетках (x — вдоль стены, y — толщина).
var cells: Vector2i = Vector2i(6, 2)
var mode: String = "damage"        # damage — жжёт и проходима; block — стена
var style: String = "wall"
## Огненная стена: рисует языки пламени поверх юнитов.
var flame: bool = false
var damage: int = 0
var sphere: String = "Fire"
var damage_owner: Node2D = null
var life_left: float = 6.0
var tick_interval: float = 0.5
var telegraph: float = TELEGRAPH_TIME
var shard_interval: float = 0.22  # для стиля "hail": как часто падает осколок

var _tick_accum: float = 0.0
var _shard_accum: float = 0.0
var _blocked: Array[Vector2i] = []
var _fill: Sprite2D = null
var _edge: Sprite2D = null
## Очаги огня — ОТДЕЛЬНЫЙ спрайт на каждую клетку стены. Раньше был один квад
## на весь прямоугольник, и пламя читалось как размытая плёнка «на все клетки».
var _flames: Array[Sprite2D] = []
## Валуны каменной стены — тоже по одному на клетку.
var _stones: Array[Sprite2D] = []
var _snap_left: float = 0.0
var _light_on: bool = false
## Время жизни эффекта для шейдеров. Раньше бралось из Time.get_ticks_msec():
## это РЕАЛЬНОЕ время, и после тактической паузы пламя/контур прыгали вперёд
## на всю длительность паузы. Накопленный delta идёт только вместе с миром.
var _elapsed: float = 0.0
var _rng := RandomNumberGenerator.new()


## Один раз, при начале активной фазы: свет зоны. Радиус берём от размера
## прямоугольника, иначе свет от 6x2 стены и от 3x3 облака выглядел бы одинаково.
func _ensure_light() -> void:
	if _light_on:
		return
	_light_on = true
	var ps := pixel_size()
	var radius := maxf(ps.x, ps.y) * 0.9
	SpellLighting.make_light(self, SpellVFX.sphere_color(sphere), radius,
		maxf(0.5, life_left), 1.5)
	# Второй слой: угли/искры вдоль зоны, пока она жива.
	SpellParticles.zone_embers(self, ps, SpellVFX.sphere_color(sphere))


## Привязать зону к сетке так, чтобы ЕЁ ГРАНИЦЫ лежали на границах клеток.
##
## Тонкость: центр зоны должен попасть на границу клетки, а НЕ в её середину.
## Для чётного числа клеток (стена 6×2) середина клетки давала сдвиг на полклетки:
## left = c*32 + 16 − 96 = c*32 − 80, то есть 16 px мимо границы. Именно из-за
## этого визуал врал про то, какие клетки накрывает зона.
func snap_to_grid() -> void:
	var c := Vector2i(floor(global_position.x / TILE), floor(global_position.y / TILE))
	var first := c - Vector2i(int(cells.x / 2.0), int(cells.y / 2.0))
	global_position = Vector2(
		float(first.x) * TILE + float(cells.x) * TILE * 0.5,
		float(first.y) * TILE + float(cells.y) * TILE * 0.5)


func configure(dmg: int, cell_size: Vector2i, sp: String, owner_unit: Node2D, life: float) -> void:
	damage = dmg
	cells = Vector2i(maxi(1, cell_size.x), maxi(1, cell_size.y))
	sphere = sp
	damage_owner = owner_unit
	life_left = life


func set_mode(m: String) -> void:
	mode = m


func blocks_path() -> bool:
	return mode == "block"


func deals_damage() -> bool:
	return damage > 0 and mode != "block"


## Размер зоны в пикселях.
func pixel_size() -> Vector2:
	return Vector2(cells.x * TILE, cells.y * TILE)


## Центральная клетка зоны.
## ВНИМАНИЕ: считается через first_cell(), а НЕ как floor(pos/32). После
## snap_to_grid() центр зоны для чётного числа клеток стоит ТОЧНО НА ГРАНИЦЕ
## клеток, и floor() сдвигал бы всю зону на одну клетку.
func center_cell() -> Vector2i:
	return first_cell() + Vector2i(int(cells.x / 2.0), int(cells.y / 2.0))


## Левая верхняя клетка зоны — напрямую из геометрии, без привязки к центру.
func first_cell() -> Vector2i:
	var half := pixel_size() * 0.5
	return Vector2i(
		floor((global_position.x - half.x) / TILE),
		floor((global_position.y - half.y) / TILE))


## Клетки, которые зона накрывает. Верхняя строка — при нечётном cells.y берём
## меньшую половину, чтобы стена не съезжала на полклетки вниз.
func covered_cells() -> Array[Vector2i]:
	var base := first_cell()
	var out: Array[Vector2i] = []
	for dy in range(cells.y):
		for dx in range(cells.x):
			out.append(base + Vector2i(dx, dy))
	return out


## Точка внутри зоны (по мировым координатам).
func covers_point(world_pos: Vector2) -> bool:
	var half := pixel_size() * 0.5
	var d := world_pos - global_position
	return absf(d.x) <= half.x and absf(d.y) <= half.y


## Битовая маска соседей для КЛЕТКИ: бит установлен, если сосед ВНУТРИ зоны.
## Шейдер рисует контур только там, где соседа нет, — поэтому прямоугольник
## из 12 клеток читается как один объект, а не как 12 квадратиков.
func neighbour_mask(cell: Vector2i) -> int:
	var base := first_cell()
	var cx := cell.x - base.x
	var cy := cell.y - base.y
	var m := 0
	if cy - 1 >= 0: m |= 1
	if cx + 1 < cells.x: m |= 2
	if cy + 1 < cells.y: m |= 4
	if cx - 1 >= 0: m |= 8
	# Диагонали нужны только для скругления ВЫПУКЛЫХ внешних углов.
	if cy - 1 >= 0 and cx + 1 < cells.x: m |= 16
	if cy + 1 < cells.y and cx + 1 < cells.x: m |= 32
	if cy + 1 < cells.y and cx - 1 >= 0: m |= 64
	if cy - 1 >= 0 and cx - 1 >= 0: m |= 128
	return m


## Фаза подсказки (урон ещё не идёт).
func in_telegraph() -> bool:
	return telegraph > 0.0


func _ready() -> void:
	# См. projectile.gd: корень сцены Always, поэтому паузу надо запросить явно,
	# иначе зона продолжала жить, тикать урон и гореть на тактической паузе.
	process_mode = PROCESS_MODE_PAUSABLE
	_rng.randomize()
	snap_to_grid()
	_fill = _make_quad(FILL_Z, 1.0)
	_edge = _make_quad(EDGE_Z, 1.0)
	_make_cell_effects()
	_update_shader()
	_tick_accum = tick_interval
	_shard_accum = shard_interval
	# Зона должна ОСВЕЩАТЬ землю вокруг себя, иначе она читается как наклейка.
	# Свет появляется в момент попадания (после телеграфа), а не сразу:
	# подсказка не должна освещать то, что ещё не сработало.
	if blocks_path():
		_block_cells()
	set_process(true)



## Очаги огня и валуны: ОТДЕЛЬНЫЙ спрайт на каждую клетку зоны.
##
## Почему не один квад: шейдер на весь прямоугольник давал «одно пламя на все
## клетки», а у стены земли вообще рисовалось пламя без огня. Игрок попросил,
## чтобы в каждой клетке горел свой огонь и стоял свой камень.
##
## Пламя теперь есть в КАЖДОЙ клетке, но у дальних рядов оно тише: 12
## аддитивных очагов одинаковой яркости складывались и выжигали цвет в белую
## плёнку. Дальний ряд — 50 % яркости, ближний — 100 %.
## У ядовитого облака своё пламя — ЗЕЛЁНОЕ (просьба игрока 28.10): туман плюс
## низкие языки зелёного огня.
func _make_cell_effects() -> void:
	var base := first_cell()
	var cell_h := float(TILE)
	var horizontal := cells.x >= cells.y
	var depth_max := float(maxi(1, cells.y - 1 if horizontal else cells.x - 1))
	for dy in range(cells.y):
		for dx in range(cells.x):
			var c := base + Vector2i(dx, dy)
			var center := Vector2((c.x + 0.5) * TILE, (c.y + 0.5) * TILE)
			var seed := _cell_seed(c)
			# Насколько клетка «дальше» от зрителя (0 = дальняя, 1 = ближняя).
			var depth := float(dy if horizontal else dx)
			var front := 0.5 + 0.5 * (depth / depth_max)
			if style == "wall_fire" or style == "cloud":
				var f := Sprite2D.new()
				f.texture = SpellVFX.white_texture()
				var flame_color := SpellVFX.FLAME_WALL_COLOR
				var rise := FLAME_RISE
				var base_alpha := front
				if style == "cloud":
					# Яд: низкое зелёное пламя, туман под ним остаётся заливкой.
					flame_color = SpellVFX.POISON_FLAME_COLOR
					rise = FLAME_RISE * 0.6
					base_alpha = 0.45 + 0.3 * front
				f.material = SpellVFX.flame_wall_material(flame_color, seed, rise)
				f.z_index = FLAME_Z
				var rise_px := float(TILE) * rise
				var h := cell_h + rise_px
				var ts := f.texture.get_size()
				f.scale = Vector2(cell_h / ts.x, h / ts.y)
				# Низ спрайта = низ клетки, вверх — подъём пламени.
				f.position = to_local(center) + Vector2(0.0, -rise_px * 0.5)
				f.set_meta("base_alpha", base_alpha)
				f.modulate.a = base_alpha
				add_child(f)
				_flames.append(f)
			elif style == "wall_earth":
				var st := Sprite2D.new()
				st.texture = SpellVFX.white_texture()
				st.material = SpellVFX.stone_wall_material(seed)
				st.z_index = STONE_Z
				var ts2 := st.texture.get_size()
				var stone_h := cell_h * 1.35
				st.scale = Vector2(cell_h / ts2.x, stone_h / ts2.y)
				st.position = to_local(center) + Vector2(0.0, (stone_h - cell_h) * 0.5)
				st.set_meta("base_alpha", 1.0)
				add_child(st)
				_stones.append(st)


## Детерминированная «личность» клетки для формы пламени/камня.
func _cell_seed(c: Vector2i) -> float:
	return float(absi(c.x * 73856093 ^ c.y * 19349663) % 1000) / 1000.0


## Квад зоны: шейдер считает по клеткам и рисует контур по внешнему краю,
## поэтому ему дают сетку мира, а не UV квада.
func _make_quad(z: int, edge_boost: float) -> Sprite2D:
	var s := Sprite2D.new()
	s.texture = SpellVFX.white_texture()
	s.material = SpellVFX.ground_material(sphere, style)
	s.z_index = z
	var ps := pixel_size()
	# Текстура 4×4 пикселя, масштабируем чтобы покрыть ps пикселей
	var tex_size := s.texture.get_size()
	s.scale = Vector2(ps.x / tex_size.x, ps.y / tex_size.y)
	s.modulate.a = edge_boost
	add_child(s)
	return s


func _update_shader() -> void:
	for s in [_fill, _edge]:
		if s == null:
			continue
		var mat := s.material as ShaderMaterial
		if mat == null:
			continue
		mat.set_shader_parameter("tile_px", float(TILE))
		mat.set_shader_parameter("style", _style_index())
		mat.set_shader_parameter("cells", Vector2(cells.x, cells.y))
		mat.set_shader_parameter("origin_cell", Vector2(first_cell().x, first_cell().y))


func _style_index() -> int:
	match style:
		"hail": return 1
		"cloud": return 2
		"wall_earth": return 3
		_: return 0


func _exit_tree() -> void:
	_unblock_cells()


func _process(delta: float) -> void:
	life_left -= delta
	_elapsed += delta
	var t := _elapsed
	for s in [_fill, _edge]:
		if s != null and s.material is ShaderMaterial:
			(s.material as ShaderMaterial).set_shader_parameter("time", t)
	# У каждого очага своя фаза (seed): один общий time делал пламя синхронным.
	for i in range(_flames.size()):
		var f := _flames[i]
		if f != null and f.material is ShaderMaterial:
			var seed := float((f.material as ShaderMaterial).get_shader_parameter("seed"))
			(f.material as ShaderMaterial).set_shader_parameter("time", t + seed * 12.0)

	# Фаза подсказки: контур виден, заливки нет, урона нет.
	if telegraph > 0.0:
		telegraph -= delta
		_set_active(0.0)
		# Пламени в фазе подсказки нет: подсказка показывает ТОЛЬКО границы
		# опасных клеток, как в наземной зоне. Языки пламени означают «уже
		# горит» — раньше этого огонь бьёт. Валуны — тоже после подсказки.
		_set_flame_alpha(0.0)
		_set_stone_alpha(0.0)
		# Контур пульсирует, чтобы подсказку нельзя было пропустить.
		_set_edge_alpha(0.55 + 0.45 * sin(t * 9.0))
		if _snap_left <= 0.0 and telegraph <= 0.0:
			_snap_left = SNAP_TIME
		_spawn_shards_if_hail(delta)
		return

	# Вспышка в момент попадания.
	if _snap_left > 0.0:
		_snap_left -= delta
		_set_active(1.0)
		_set_edge_alpha(1.0)
		# Короткая вспышка в момент попадания.
		_set_flame_alpha(1.0)
		_set_stone_alpha(1.0)
		_ensure_light()
		_spawn_shards_if_hail(delta)
		return

	_set_active(1.0)
	_set_edge_alpha(0.55 + 0.45 * sin(t * 5.0))
	# Пламя и камни живут всё время действия.
	_set_flame_alpha(0.85 + 0.15 * sin(t * 6.3))
	_set_stone_alpha(1.0)
	_ensure_light()

	# Растворение на затухании: читается как «сгорает», а не как гаснет UI.
	if life_left < BURN_TIME:
		var burn := 1.0 - life_left / BURN_TIME
		for s in [_fill, _edge]:
			if s != null and s.material is ShaderMaterial:
				(s.material as ShaderMaterial).set_shader_parameter("burn", burn)
		_set_edge_alpha(0.35 * (1.0 - burn) + 0.15)
		# Пламя не исчезает рывком: гаснет плавно, «сгорает».
		_set_flame_alpha(0.85 * (1.0 - burn) * (1.0 - burn))
		_set_stone_alpha(1.0 - burn * 0.85)
	if life_left <= 0.0:
		queue_free()
		return

	_spawn_shards_if_hail(delta)
	if not deals_damage():
		return
	_tick_accum += delta
	if _tick_accum < tick_interval:
		return
	_tick_accum -= tick_interval
	_damage_units()


func _set_active(v: float) -> void:
	for s in [_fill, _edge]:
		if s != null and s.material is ShaderMaterial:
			(s.material as ShaderMaterial).set_shader_parameter("active", v)


## Прозрачность пламени. additive-материал читает modulate.a как множитель
## яркости, поэтому 0 — это честное «нет огня», а не серое пятно.
func _set_flame_alpha(a: float) -> void:
	for f in _flames:
		if f != null:
			# У дальних рядов своя базовая яркость (глубина сцены).
			var base := float(f.get_meta("base_alpha", 1.0))
			f.modulate.a = clampf(a * base, 0.0, 1.0)


## Прозрачность валунов (каменная стена).
func _set_stone_alpha(a: float) -> void:
	for st in _stones:
		if st != null:
			var base := float(st.get_meta("base_alpha", 1.0))
			st.modulate.a = clampf(a * base, 0.0, 1.0)


func _set_edge_alpha(a: float) -> void:
	if _edge != null:
		_edge.modulate.a = clampf(a, 0.0, 1.0)


func _spawn_shards_if_hail(delta: float) -> void:
	if style != "hail":
		return
	_shard_accum += delta
	if _shard_accum >= shard_interval:
		_shard_accum = 0.0
		_spawn_shard()


## Один падающий осколок в случайной точке зоны.
func _spawn_shard() -> void:
	var half := pixel_size() * 0.5
	var p := global_position + Vector2(
		_rng.randf_range(-half.x, half.x),
		_rng.randf_range(-half.y, half.y) - half.y * 0.5)
	SpellVFX.hail_shard(p)


func _damage_units() -> void:
	# Обе точки (зона и юниты) уже лежат в Ground-плоскости, поэтому
	# рельеф вычитать нельзя — иначе зона уезжает на высоту холма.
	for enemy in Game.hostile_units():
		if enemy == null or not is_instance_valid(enemy):
			continue
		if not covers_point(enemy.global_position):
			continue
		Game.deal_damage(enemy, damage, "magic", sphere, damage_owner)


func _block_cells() -> void:
	var map_node := get_tree().get_first_node_in_group("alm_map")
	if map_node == null or not map_node.has_method("set_nowalk_cell"):
		return
	for c in covered_cells():
		map_node.call("set_nowalk_cell", c, true)
		_blocked.append(c)


func _unblock_cells() -> void:
	if _blocked.is_empty():
		return
	var map_node := get_tree().get_first_node_in_group("alm_map")
	if map_node != null and map_node.has_method("set_nowalk_cell"):
		for c in _blocked:
			map_node.call("set_nowalk_cell", c, false)
	_blocked.clear()
