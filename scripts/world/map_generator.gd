class_name MapGenerator
extends RefCounted
## Умный генератор .alm на основе паттернов оригинальных карт Nival
## (корпус удалён 29.10; паттерны зафиксированы в shapes_db/transition_db).
## Noise → terrain → переходы из transition_db → высоты → дороги → объекты.
##
## Вызывается из игры по сиду: `MapGenerator.new().generate(seed, zone, dir)`.
## CLI-обёртка для пакетной генерации — tests/gen_smart_map.gd.
##
## Инвариант потоков случайности: каждый поток = `seed + (старая константа - BASE_SEED)`.
## Смещения подобраны так, чтобы потоки трав и алхимии оставались ИЗОЛИРОВАННЫМИ от
## основного потока — иначе изменение числа трав сдвинуло бы расстановку НПЦ и Серых.
## При seed == BASE_SEED генератор обязан выдать байт-в-байт прежний gen_smart_01.alm.

const DB_PATH := "res://assets/maps/transition_db.json"
const SHAPES_PATH := "res://assets/maps/shapes_db.json"
## Каталог генерируемых карт в user:// — res:// в экспортированной игре только для чтения.
const MAPS_DIR := "user://maps/"
## Размер карты по умолчанию. В стресс-режиме ([stress] enabled=1)
## перекрывается stress.map_size (игрок 07.10: 1000×1000).
var W := 192
var H := 192
## Сид, которым вызывался генератор до появления параметризации. Служит опорой для
## смещений потоков и эталоном для регрессионной проверки идентичности карты.
const BASE_SEED := 4242
## Смещения RNG-потоков относительно основного. ВАЖНО: это РАЗНОСТЬ старой
## константы и BASE_SEED, а не сама константа: stream_seed = seed + смещение.
const STREAM_HERBS := 4400       ## 8642 - 4242
const STREAM_ALCHEMY := 3058     ## 7300 - 4242 (+ city_index)
const STREAM_OBJECTS := -3465    ## 777 - 4242 (_obj_noise.seed)
const STREAM_TERRAIN := -4200    ## 42 - 4242 (rng.seed и elev_noise.seed)
const STREAM_JITTER := 5757      ## 9999 - 4242 (jitter_noise.seed)
const STREAM_INTERIOR := -4235   ## 7 - 4242 (_interior_noise.seed)
const STREAM_INTERIOR_HI := -4143 ## 99 - 4242 (_interior_hi.seed)
const STREAM_POI := -3042        ## 1200 - 4242 (точки интереса, 03.10)

## Куда писать результат (задаётся в generate()).
var _out_dir: String = ""
## Базовое имя файлов без расширения: <basename>.alm + sidecar-ы с тем же префиксом.
var _basename: String = "gen_smart_01"
## Имя карты, записываемое ВНУТРЬ заголовка .alm (поле name, смещение 68). Не путать
## с именем файла: для воспроизводства прежнего gen_smart_01.alm нужны оба = "gen_smart_01".
var _map_name: String = "gen_smart_01"
## Сид текущей генерации.
var _seed: int = BASE_SEED
## Профиль зоны: start | mid | hard | faction.
var _zone: String = "mid"
## Мир 4x3 (23.10): id сектора ("s41"), его соседи (id) и рельеф.
var _sector: String = ""
var _neighbors: Array = []
var _relief: String = "plains"
var _portals_out: Array = []
## Фоновая загрузка (23.10): прогресс для экрана загрузки, может быть null.
var _job = null
## Статистика последней генерации для F3-панели (мс по фазам, источник).
static var last_stats: Dictionary = {}
const STAT_PHASES := ["start", "terrain", "cities", "roads", "relief", "portals",
	"city", "objects", "herbs", "greys", "tiles", "heights", "save"]
var _stats_t0 := 0
var _stats_last := 0
var _stats_phases: Dictionary = {}
## Раса героя, переданная явно (поток не должен зависеть от Game.hero_race).
var _race_hint: String = ""
## Тип A -> tile-файл для .alm (песок/грязь/почва — свои BMP-файлы)
const TERRAIN_FILE := {0: 1, 1: 2, 2: 3, 3: 4, 4: 5, 5: 6, 6: 7}
## 8-bit peer mask bit order — must match tests/analyze_shapes.gd
const SHAPE_DIRS := [
	Vector2i(0, -1), Vector2i(1, -1), Vector2i(1, 0), Vector2i(1, 1),
	Vector2i(0, 1), Vector2i(-1, 1), Vector2i(-1, 0), Vector2i(-1, -1),
]

var _tiles := PackedInt32Array()
var _heights := PackedByteArray()
var _obstacles := PackedByteArray()
var _terrain := PackedByteArray()
var _field := PackedFloat32Array()
var _water_thr: float = 0.0
var _mountain_thr: float = 0.0

# Спавн (структуры/npc sidecar-ами): зарезервированные клетки и выходные записи.
var _reserved := {}           # Vector2i -> true (здания, спавн, портал)
var _structures_out: Array = []   # {x, y, type_id}
var _npcs_out: Array = []         # {x, y, set, role, patrol, post, hp_max, damage}
var _herbs_out: Array = []        # {x, y, item, icon}
var _gray_cells := {}             # "x,y" -> true, занятые Серыми клетки (03.10)
var _interest_out: Array = []     # {x, y, kind, label, members} — якоря точек интереса
var _obj_noise: FastNoiseLite

# Transition DB
var _rules: Dictionary = {}
var _interior: Dictionary = {}
# Shape table: "type:maskstr" -> {tiles: [{file,variant,row,w}...], total}
var _shapes: Dictionary = {}
# Interior base textures per type: "0" -> {tiles: [{file,variant,row,w}...], total}
var _base_int: Dictionary = {}
# Универсальный «краевой» row на тип (самый частый среди border-масок).
var _edge_rows := {}
# Шум для интерьера (пер-клеточный, без жёстких worley-чанков).
var _interior_noise: FastNoiseLite
var _interior_hi: FastNoiseLite
# Сдвиг домена шума на тип, чтобы типы не копировали друг друга.
const _NOISE_OFFSETS := {0: 1234, 1: 5678, 2: 9012, 3: 3456, 4: 7890, 5: 2345, 6: 6789}
var _stat_exact := 0
var _stat_subset := 0
var _stat_rules := 0
var _stat_transition := 0

## Порядок направлений перехода. Должен совпадать с directions.order
## в assets/maps/terrain_tiles_db.json и с gen_transition_tiles.py:
## file_n = 8 + индекс в этом массиве.
const _TRANSITION_DIR_ORDER := ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]

## Базовое имя файлов карты: map_<seed>_<sector>[_<race>] для секторов мира,
## map_<seed>_<zone>[_<race>] для старых вызовов/тестов.
static func map_basename(seed_value: int, zone: String, race: String = "",
		sector: String = "") -> String:
	var tail: String = ("_" + race) if race != "" else ""
	var tag: String = sector if sector != "" else zone
	return "map_%d_%s%s" % [seed_value, tag, tail]

## Версия генератора. Записывается в .npcs.json и проверяется при загрузке.
##
## ЗАЧЕМ. Замер 03.10: подняли плотность Серых с 15 до 71 на карту, но в игре
## оставалось 15. Причина: `ensure_map` переиспользовал УЖЕ СГЕНЕРИРОВАННУЮ карту
## из user://maps/, а её .npcs.json был датирован 28.09 — то есть создан до
## изменения настроек. Настройки влияли только на новые карты, а старых в
## user://maps/ лежало 58 файлов.
##
## Теперь при несовпадении версии карта перегенерируется сама. Меняешь
## city_gap, плотность Серых или правила разведения — поднимаешь GEN_VERSION.
## 05.10: v7 — односторонний переход t < n (двойной берег).
## v8 — сглаживание осиротевших клеток 1×1/1×2 + бленд смежных биомов.
## v9 — здания городов из арта Alice (structure_id 200..206).
## v10 — футпринт Alice 3×3 (4×3 не влезал в овал, inn/house не ставились).
##
## v26 (15.10) — Серые получили настоящий арт: monsters/wolf, monsters/bee,
## monsters/dragon. До этого в пуле стояла подмена monsters/hero_dummy (арт
## героя, чтобы было на чём тестировать бой). Бамп обязателен: sidecar старой
## версии лежит на диске и `ensure_map` вернул бы его как свежий.
##
## v25 (14.10) — ВРЕМЕННО наполнены пулы Серых набором `monsters/hero_dummy`
## (арт героя, palette=5). Игроку нужно было проверить в игре анимацию удара и
## смерти героя, а монстров в проекте нет: весь арт Аллодов удалён.
##
## v24 (11.10) — ПУСТЫЕ ПУЛЫ СЕРЫХ. Весь арт Аллодов II удалён, вместе с ним
## удалены 41 набор `monsters/*`. Без бампа этого номера уже сгенерированные
## карты продолжают ссылаться на удалённые наборы: sidecar лежит на диске, и
## `ensure_map` вернул бы его как свежий. Это тот же класс, что и любой другой
## смысловой бамп здесь — кэш карты молча переживает удаление данных.
# 27: тиры Серых — полосы по зонам, респавн читает ту же полосу.
# 28: добавлены людоед и тролль (9 видов вместо 7). Без бампа старые карты в
# user:// остались бы без них.
# 29: добавлена суккуб (10 видов). У неё `attack: 0` — фазы удара нет по
# решению игрока, урон при этом наносится как у всех.
# 30: туман войны + чанки террейна (19.10).
# 31 (23.10): мир 4x3 — карта сектора со своим размером (96..192) и порталами
# по каждой границе с соседом. Старые карты без сектора остаются совместимы.
# 32 (28.10): форпосты фракций (пакет B) — 3 лагеря на карту вне стартовой зоны,
# sidecar .outposts.json и стража с бирками.
# 33 (29.10): арт Аллодов удалён из игры — ids 1..179 снесены, форпосты стоят из
# наших seedream-построек, вместо костра проп. Без бампа старые карты в user://
# ссылались бы на удалённые папки (здания молча исчезали бы).
# 34 (30.10): вариация кромки и выбор interior-текстуры берутся из собственного
# `_cell_hash` вместо `hash(Vector2i)` — карты те же по смыслу, но другие по
# байтам; без бампа `ensure_map` вернул бы старые .alm с диска.
const GEN_VERSION := 34

## Путь к карте по сиду. Если карта уже сгенерирована той же версией генератора —
## переиспользуем её, иначе генерируем заново. Пустая строка при ошибке.
##
## Наличие .npcs.json проверяется не просто «для аккуратности»: если запись оборвалась
## на середине, .alm может существовать, а sidecar-ы — нет, и карта загрузится
## без зданий, НПЦ и трав.
static func ensure_map(seed_value: int, zone: String = "mid", dir: String = MAPS_DIR,
		race: String = "", sector: String = "", size: int = 0,
		neighbors: Array = [], relief: String = "", job = null) -> String:
	# race пустой -> берём расу героя: расы городов зависят от неё (10.10).
	if race == "":
		race = _hero_faction()
	var base: String = map_basename(seed_value, zone, race, sector)
	var path: String = dir + base + ".alm"
	var npcs_path: String = dir + base + ".npcs.json"
	if FileAccess.file_exists(path) and FileAccess.file_exists(npcs_path):
		if _saved_gen_version(npcs_path) == GEN_VERSION:
			if job != null:
				job.set_progress(100, 12)
			last_stats = {
				"source": "cache", "total_ms": 0, "phases": {},
				"size": size, "sector": sector, "gen_version": GEN_VERSION,
			}
			return path
		print("MapGenerator: версия генератора изменилась (%d -> %d), карта %s перегенерируется"
				% [_saved_gen_version(npcs_path), GEN_VERSION, base])
	return MapGenerator.new().generate(seed_value, zone, dir, "", "", race,
		sector, size, neighbors, relief, job)


## Раса героя -> id фракции для города. Пусто, если для неё нет CITY_POPULATION
## (страховка на будущее: раса в hero_race может появиться раньше арта).
static func _hero_faction() -> String:
	return city_race_for_hero(Game.hero_race)

## Версия, записанная в sidecar (-1 = файла нет или поле нечитаемо).
static func _saved_gen_version(npcs_path: String) -> int:
	var f := FileAccess.open(npcs_path, FileAccess.READ)
	if f == null:
		return -1
	var txt := f.get_as_text()
	f.close()
	var parsed: Variant = JSON.parse_string(txt)
	if not (parsed is Dictionary):
		return -1
	return int((parsed as Dictionary).get("gen_version", -1))

## Сгенерировать карту по сиду. Возвращает путь к .alm (пустая строка при ошибке).
## dir — каталог с завершающим слэшем (обычно "user://maps/").
## basename_override — имя файлов без расширения; пусто = "map_<seed>_<zone>".
## map_name_override — имя карты внутри заголовка .alm; пусто = basename.
##   Оверрайды нужны регрессионному тесту идентичности, чтобы побайтово воспроизвести
##   прежний gen_smart_01.alm (см. BASE_SEED).
func generate(seed_value: int, zone: String = "mid", dir: String = "res://assets/maps/gen/",
		basename_override: String = "", map_name_override: String = "",
		race: String = "", sector: String = "", size: int = 0,
		neighbors: Array = [], relief: String = "", job = null) -> String:
	_seed = seed_value
	_zone = zone
	_sector = sector
	_neighbors = neighbors.duplicate()
	_relief = relief if relief != "" else "plains"
	_race_hint = race
	_job = job
	_stats_t0 = Time.get_ticks_msec()
	_stats_last = _stats_t0
	_stats_phases = {}
	_report(1, 0)
	_out_dir = dir
	_basename = basename_override
	if _basename == "":
		_basename = map_basename(_seed, _zone, race, _sector)
	_map_name = map_name_override
	if _map_name == "":
		_map_name = _basename
	_apply_stress_overrides()
	if size > 0 and GameConfig.geti("stress", "enabled") == 0:
		W = clampi(size, 64, 2000)
		H = W
	_load_db()
	_generate()
	_save()
	last_stats = {
		"source": "generated", "total_ms": Time.get_ticks_msec() - _stats_t0,
		"phases": _stats_phases.duplicate(), "size": W, "sector": _sector,
		"gen_version": GEN_VERSION,
	}
	return _out_dir + _basename + ".alm"


## Стресс-режим движка: размер карты и счётчики контента из [stress].
## В обычной игре enabled=0 — поведение не меняется.
func _apply_stress_overrides() -> void:
	var enabled := GameConfig.geti("stress", "enabled") != 0
	if not enabled:
		W = 192
		H = 192
		return
	var size := GameConfig.geti("stress", "map_size")
	W = clampi(size, 64, 2000)
	H = W
	print("STRESS: карта %dx%d, деревья=%d, Серые=%d, стражи=%d, жители=%d" % [
		W, H,
		GameConfig.geti("stress", "tree_count"),
		GameConfig.geti("stress", "gray_count"),
		GameConfig.geti("stress", "city_guard_count"),
		GameConfig.geti("stress", "city_citizen_count"),
	])

func _load_db() -> void:
	var f := FileAccess.open(DB_PATH, FileAccess.READ)
	if f == null:
		return
	var json: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if json is Dictionary:
		_rules = json.get("rules", {})
		_interior = json.get("interior", {})
	print("DB: %d rules, %d interior" % [_rules.size(), _interior.size()])
	var sf := FileAccess.open(SHAPES_PATH, FileAccess.READ)
	if sf != null:
		var sjson: Variant = JSON.parse_string(sf.get_as_text())
		sf.close()
		if sjson is Dictionary:
			_shapes = sjson.get("shapes", {})
			_base_int = sjson.get("interior", {})
	print("SHAPES: %d entries, base textures for %d types" % [_shapes.size(), _base_int.size()])
	_compute_edge_rows()

## «Краевой» row на тип: самый частотный row среди форм с >=1 кардинальным
## битом (N/E/S/W) и >= MIN_CELLS клеток. Для травы/гор это «универсальный
## край» (row 4 в анализе pvm-карт), для воды/дороги — свои краевые rows.
func _compute_edge_rows() -> void:
	const MIN_CELLS := 20
	var cardinal_bits := 0x55  # биты N, E, S, W (0,2,4,6)
	var rows_by_type := {}  # t -> {row: total_weight}
	for key in _shapes:
		var parts: Array = String(key).split(":")
		if parts.size() < 2:
			continue
		var t: int = int(parts[0])
		if t < 0 or t > 6:
			continue
		var mask := _mask_from_str(parts[1])
		if mask == 0 or mask & cardinal_bits == 0:
			continue
		var entry: Dictionary = _shapes[key]
		var total: int = int(entry.get("total", 0))
		if total < MIN_CELLS:
			continue
		for ti in entry.get("tiles", []):
			var r: int = int(ti.get("row", -1))
			var w: int = int(ti.get("w", 0))
			if r < 0:
				continue
			if not rows_by_type.has(t):
				rows_by_type[t] = {}
			rows_by_type[t][r] = int(rows_by_type[t].get(r, 0)) + w
	_edge_rows.clear()
	for t in rows_by_type:
		var best_row := -1
		var best_w := 0
		for r in rows_by_type[t]:
			if int(rows_by_type[t][r]) > best_w:
				best_w = int(rows_by_type[t][r])
				best_row = int(r)
		if best_row >= 0:
			_edge_rows[t] = best_row
	print("EDGE_ROWS: %s" % str(_edge_rows))

func _get_rule(type_a: int, dir: String, type_b: int) -> Dictionary:
	# Try with sub numbers first (NW1, NW2, N1, N2 etc)
	for sub in ["1", "2"]:
		var key: String = "%d:%s%s:%d" % [type_a, dir, sub, type_b]
		var spec: Dictionary = _rules.get(key, {})
		if not spec.is_empty():
			return spec
	# Fallback to base direction
	return _rules.get("%d:%s:%d" % [type_a, dir, type_b], {})

# === Генерация ===

## Прогресс для экрана загрузки. job может быть null (тесты, dev).
func _report(percent: int, phase: int) -> void:
	var now := Time.get_ticks_msec()
	_stats_phases[str(phase)] = now - _stats_last
	_stats_last = now
	if _job != null:
		_job.set_progress(percent, phase)


func _generate() -> void:
	var n: int = W * H
	_terrain.resize(n)
	_tiles.resize(n)
	_heights.resize(n)
	_obstacles.resize(n)
	_obstacles.fill(0)
	_reserved.clear()
	_structures_out.clear()
	_npcs_out.clear()
	_herbs_out.clear()
	_outposts_out.clear()
	_outpost_reach.clear()

	# 1. Почва Voronoi (база, без гор/воды/дороги)
	_place_terrain(n)
	_report(12, 1)

	var rng := rng_from_seed(_seed)

	# 2. Города: овалы ~11×11 дорогой (type 3), по профилю зоны
	_place_cities(rng)
	_report(28, 2)

	# 3. Дороги: MST по городам + A*-коридоры ширины 2
	_connect_cities(rng)
	_report(42, 3)

	# 4. Горы/вода поверх экстремумов рельефа, не перетирая дорогу (3)
	_place_mountains_water()
	# 4b. Убрать «осиротевшие» клетки 1×1 / 1×2 чужого биома внутри поля.
	_smooth_isolated_terrain()
	_report(50, 4)

	# 5. Portal + Spawn маркеры (у города №0)
	_place_portal_spawn()
	_report(56, 5)

	# 6. City content: здания + НПЦ городов (после известных спавна/портала)
	_place_city_content(rng)
	_report(66, 6)

	# 6b. Мелкий декор вокруг городов (бочки/ящики/фонари seedream)
	_place_city_props(rng)

	# 6c. Форпосты фракций (пакет B): 3 лагеря вне городов, в стартовой зоне 0.
	# Свой поток RNG — деревья/травы/Серые не сдвигаются от появления лагерей.
	_place_outposts(rng_from_seed(_seed + STREAM_OUTPOSTS))

	# 7. Деревья/объекты (заполняют _obstacles, обходя города/дороги/спавн)
	_place_objects(rng)
	_report(78, 7)

	# 8. Травы: отдельные collectible-узлы, не препятствия
	_place_herbs(rng_from_seed(_seed + STREAM_HERBS))
	_report(84, 8)

	# 9. Серые: кластеры у дорог и в лесу (только на не-занятых клетках)
	_place_greys(rng)
	_report(90, 9)

	# 9b. Точки интереса вне городов: статичные группы NPC. Выключено по
	# умолчанию (poi.count = 0), включает игрок.
	# Отдельный поток RNG, чтобы включение точек интереса НЕ сдвигало
	# деревья, травы и Серых — иначе старая карта менялась бы целиком.
	_place_interest_points(rng_from_seed(_seed + STREAM_POI))

	# 10. Tiles with transitions from DB
	for y in range(H):
		for x in range(W):
			var i: int = y * W + x
			_tiles[i] = _pick_tile(_terrain[i], x, y)
	_report(96, 10)

	# 11. Heights: non-road first, then road interpolation from the completed field
	for y in range(H):
		for x in range(W):
			var i: int = y * W + x
			if _terrain[i] != 3:
				_heights[i] = _pick_height(x, y, _terrain[i], _field[i])
	_smooth_nonroad_heights()
	for y in range(H):
		for x in range(W):
			var i: int = y * W + x
			if _terrain[i] == 3:
				_heights[i] = _pick_height(x, y, _terrain[i], _field[i])
	_report(99, 11)

func rng_from_seed(s: int) -> RandomNumberGenerator:
	var r := RandomNumberGenerator.new()
	r.seed = s
	return r

# === Профили зон: число городов по сложности ===
# Профиль зоны задаётся параметром generate() в поле _zone (start | mid | hard | faction).
const ZONE_CITY_COUNTS := {
	"start": [1, 1],
	"mid": [1, 3],
	"hard": [4, 5],
	"faction": [2, 3],
}

# Геометрия города.
# CITY_RADIUS — половина овала дороги: 8 даёт овал 17×17 (было 7 -> 15×15,
# и дома на 4-6 клетках не помещались в кольцо, здания вытеснялись наружу).
# CITY_GAP — свободных клеток вокруг каждого здания (была 1, дома слипались).
const CITY_RADIUS := 8
const CITY_GAP := 2

## Радиус и зазор города — из конфига [spawn]. Константы выше остались
## запасным значением и перекрытием для тестов, которые подставляют свои.
static func city_radius() -> int:
	var v := GameConfig.geti("spawn", "city_radius")
	return CITY_RADIUS if v <= 0 else v

static func city_gap() -> int:
	var v := GameConfig.geti("spawn", "city_gap")
	return CITY_GAP if v <= 0 else v

static func herb_region_grid() -> int:
	var v := GameConfig.geti("spawn", "herb_region_grid")
	return HERB_REGION_GRID if v <= 0 else v

static func herb_min_distance() -> int:
	var v := GameConfig.geti("spawn", "herb_min_distance")
	return HERB_MIN_DISTANCE if v <= 0 else v

## Выступ здания вверх для КАЖДОГО проверяемого футпринта (full_height − h).
## Передаётся в _footprint_fits через поле: GDScript не даёт передавать его
## аргументом без засорения сигнатуры у всех вызывающих.
var _pending_vis_rows: int = 0

# Серые (монстры palette=5 — UnitDB.is_hostile) по зоне: кластеры у дорог и в лесах.
#
# ПУЛЫ ПУСТЫ — и это НЕ ошибка, а следствие решения игрока от 11.10: весь арт
# Аллодов II удалён из репозитория, вместе с ним удалены 41 набор `monsters/*`.
# Подставлять вместо них городских стражников (`city_*`) нельзя: это мирные
# NPC, и такой подставой мы бы тихо соврали, что монстры есть.
#
# ЧТО БУДЕТ, когда появятся риги Серых: набор рига подключается по тому же
# пути, что и любой другой — записью в units_db.json и папкой
# assets/units/rig/<набор>/. Списки ниже ожидают обычные ключи наборов, менять
# код спавна не потребуется, только заполнить эти пути.
const GRAY_POOL_EMPTY: Array = []

# 15.10: настоящий арт Серых. Сделаны тем же конвейером, что и герой
# (tests/gen_monster_strip.py + tests/extract_monster_nb.py), модель
# google/gemini-nano-banana-2.1 — она единственная держит одно и то же животное
# между вызовами. seedream-5-0-flash втрое дешевле ($0.018 против $0.059), но
# на контрольном опыте стойка и бег вышли РАЗНЫМИ зверьями.
#
# monsters/succubus НЕ включён: полосы `move` и `die` не успели сгенерироваться,
# квота Gemini кончилась на два вызова раньше. Набор появится, как только
# добьём эти две полосы.
const GRAY_POOL_TEST: Array = [
	"monsters/wolf", "monsters/dino", "monsters/squirrel",
	"monsters/bee", "monsters/bat", "monsters/ghost", "monsters/dragon",
]

# Grey tiers. Every species has 5 sets: tier 1 is the beast itself, without a
# recolour (`monsters/<species>`); tiers 2..5 are recoloured copies
# `monsters/<species>_t<N>`. The recolour is free (zero API calls), the
# generator is tests/gen_grey_tiers.py.
#
# 2026-10-30: the species list moved to data (`spawn.gray_species`) — a mod can
# add its own beast and it starts to appear in the world. Missing sets (for
# example a mod with tier 1 only) are filtered out: the pool must never offer a
# spawn of a set that does not exist.
static func gray_species() -> Array:
	return ContentRules.list("spawn.gray_species")

# Полоса тиров по зонам (решение игрока): чем глубже, тем опаснее вид.
#  start   1-2  новичок не встречает элит
#  mid     2-3  обычная охота, первые древние
#  hard    3-4  опасные, легендарные
#  faction 4-5  элиты и владыки
const GRAY_TIER_BAND := {
	"start": [1, 2],
	"mid": [2, 3],
	"hard": [3, 4],
	"faction": [4, 5],
}

# Усиление за тир поверх базовых статов Серых ([grey] в game.cfg).
# Тир 1 — x1.0, тир 5 — hp x2.4, урон x2.0. Шаги живут в [mob_tier], чтобы
# баланс правился в одном месте, а не в коде. Тир берётся из units_db.json,
# а не разбирается из имени: имя — это строка, база — источник истины.
static func gray_tier_mults(set_name: String) -> Array:
	var tier := int(UnitDB.get_set(set_name).get("tier", 1))
	var step := float(maxi(tier - 1, 0))
	return [1.0 + GameConfig.getf("mob_tier", "hp_step") * step,
		1.0 + GameConfig.getf("mob_tier", "damage_step") * step]


static func gray_set_name(species: String, tier: int) -> String:
	return "monsters/%s" % species if tier <= 1 else "monsters/%s_t%d" % [species, tier]


## Zone set pool: all species × the tiers of its band (existing sets only).
static func gray_pool_for_zone(zone: String) -> Array:
	var band: Array = GRAY_TIER_BAND.get(zone, GRAY_TIER_BAND["mid"])
	var out: Array = []
	for sp in gray_species():
		for t in range(int(band[0]), int(band[1]) + 1):
			var set_name := gray_set_name(str(sp), t)
			if UnitDB.has(set_name):
				out.append(set_name)
	return out


# Здания в городах: функциональные + жильё + декор (folder -> StructureDB).
# 10.10: арт seedream (tests/extract_seedream_buildings.py), папки *_sN.
# Старые Alice-папки (shop3/inn4/...) остались на диске, но в пулах не используются.
const SHOP_FOLDERS := ["shop_s1"]
const ALCHEMY_FOLDERS := ["druidshop_s1"]
const INN_FOLDERS := ["inn_s1", "inn_s2"]
const TRAIN_FOLDERS := ["train_s1"]
const BLACKSMITH_FOLDERS := ["blacksmith_s1"]

## Housing and decor by city race (keys = faction id in world.json).
## Every race has its own building style — an orc city does not look human.
## 2026-10-29: moved to data (`map.house_folders` / `map.decor_folders`) — a mod
## with a new building set or a new faction needs no code change.
static func house_folders() -> Dictionary:
	return ContentRules.dict("map.house_folders")


static func decor_folders() -> Dictionary:
	return ContentRules.dict("map.decor_folders")

## Small map decor (seedream, alm_objects.json IDs 193-199).
## Placed around cities: barrels/crates/sacks near buildings, lanterns along
## roads. The list lives in data (`map.city_props`); lantern 197 is placed by a
## dedicated branch next to roads.
const LANTERN_PROP_ID := 197

## Зоны, в которых генератор ставит портал.
##
## 03.10: было только ["start"], и игрок решил добавить "mid" — без этого
## выход из зоны новичка ведёт в никуда и зон становится ровно одна.
## ВАЖНО: `_drop_portal_json()` вызывается для зон из этого списка и стирает
## старый sidecar. Если добавить зону в список и забыть убрать вызов, то
## генератор сотрёт портал, который сам же только что поставил.
const ZONES_WITH_PORTAL := ["start", "mid"]

# НПЦ городов.
## Раса города -> наборы спрайтов. Ключи = id фракций в assets/lore/world.json
## (там же label/race/archmage). Тир = роль: граждане t0/t1, стражи t1/t2,
## капитан-великий-маг t3.
## У каждой расы два набора (маг + воин) - это осознанно: в городе должны быть
## и простые жители, и те, кто держит оружие, а не 16 копий одного силуэта.
## 10.10 (позже): нежить тоже получила атлас (city_necro_mage/city_necro_warrior),
## поэтому necro теперь полноценный город, а не откат на первую доступную расу.
const CITY_POPULATION := {
	"humans": {
		"guards": ["city_human_mage/t1", "city_human_warrior/t2"],
		"citizens": ["city_human_mage/t0", "city_human_warrior/t1"],
		"captain": "city_human_mage/t3",
		"head": "city_human_mage/t2",
	},
	"ork": {
		"guards": ["city_ork_mage/t1", "city_ork_warrior/t2"],
		"citizens": ["city_ork_mage/t0", "city_ork_warrior/t1"],
		"captain": "city_ork_mage/t3",
		"head": "city_ork_mage/t2",
	},
	"druid": {
		"guards": ["city_druid_mage/t1", "city_druid_warrior/t2"],
		"citizens": ["city_druid_mage/t0", "city_druid_warrior/t1"],
		"captain": "city_druid_mage/t3",
		"head": "city_druid_mage/t2",
	},
	"necro": {
		"guards": ["city_necro_mage/t1", "city_necro_warrior/t2"],
		"citizens": ["city_necro_mage/t0", "city_necro_warrior/t1"],
		"captain": "city_necro_mage/t3",
		"head": "city_necro_mage/t2",
	},
}
## Расы, между которым�� города делятся по кругу. necro исключена, пока нет
## арта (см. CITY_POPULATION). Стартовая зона - первая раса, не "hero":
## при "hero" не было бы ни одного NPC в городе новичка.
const CITY_RACES := ["humans", "ork", "druid", "necro"]

# Объекты по биому: seedream-спрайты (alm_objects.json ID 200-211).
# Старые аллодовские ID 1-192 из пулов убраны (папки удалены с диска).
const TREE_GRASS := [200, 201, 202, 205, 210, 211]   # oak, oak2, pine, bush_berry, rock, rock2
const TREE_SOIL := [203, 204, 205, 210, 211]         # birch, willow, bush_berry, rock, rock2
const TREE_SAND := [206, 207, 210]                   # palm, cactus, rock
const TREE_MUD := [208, 209, 204, 210]               # dead, thorn, willow, rock
const HERB_ITEMS := [
	{"item": "Herb Green Leaf", "icon": "res://assets/professions/herbalism/green_leaf.png"},
	{"item": "Herb White Flower", "icon": "res://assets/professions/herbalism/white_flower.png"},
	{"item": "Herb Red Berry", "icon": "res://assets/professions/herbalism/red_berry.png"},
	{"item": "Herb Tall Grass", "icon": "res://assets/professions/herbalism/tall_grass.png"},
	{"item": "Herb Lavender", "icon": "res://assets/professions/herbalism/lavender.png"},
	{"item": "Herb Mint", "icon": "res://assets/professions/herbalism/mint.png"},
	{"item": "Herb Dandelion", "icon": "res://assets/professions/herbalism/dandelion.png"},
	{"item": "Herb Broad Leaf", "icon": "res://assets/professions/herbalism/broad_leaf.png"},
]
const HERB_TARGET_COUNTS := {"start": 70, "mid": 90, "hard": 110, "faction": 100}
const HERB_REGION_GRID := 4
const HERB_MIN_DISTANCE := 4

## Разведение Серых по карте (03.10). GRAY_MIN_DISTANCE — минимальная
## дистанция между любыми двумя Серыми, иначе кластеры жмутся в угол.
## GRAY_REGION_GRID — на сколько частей делим карту для отчёта о покрытии.
const GRAY_MIN_DISTANCE := 4
const GRAY_REGION_GRID := 3
const GRAY_MIN_SPAWN_DISTANCE := 14   # не тыкать зверя прямо в лицо новичку

## Тематические встречи (пакет D, 07.10): улей, логово, стая — как в Аллодах.
##
## СПИСОК ПУСТ, как и пулы GRAY_ZONE: все наборы `monsters/*` удалены вместе с
## артом Аллодов II (11.10). Логика расстановки и сами виды встреч не тронуты —
## они оживут, как только появятся риги Серых, и для этого достаточно вернуть
## записи сюда. До тех пор ни одна стая не ставится, и это видно в отчёте
## генератора (`gray_count=0`), а не как падение.
##
## Что сюда вернётся (набор -> вид встречи):
##   bee  -> bee_hive       wolf  -> wolf_pack     spider -> spider_den
##   squirrel -> squirrel_herd  orc/goblin -> orc_camp
##   ogre -> ogre_lair      troll -> troll_lair    bat    -> bat_swarm
const ENCOUNTER_KINDS: Array = []

## --- Форпосты фракций (пакет B переработки ковки, 28.10) -------------------
##
## Решение игрока: по ТРИ захватываемых форпоста на карту, в стартовой зоне
## фракционных воинов нет вовсе (там только Серые). Форпост — это маленький
## лагерь вне города: шатёр расы, костёр и 3–6 стражников с бирками в луте.
##
## Почему свои поток RNG как у трав/POI: добавление форпостов не должно
## сдвигать деревья, травы и Серых — иначе каждая старая карта менялась бы
## целиком. STREAM_OUTPOSTS занимает свой диапазон.
const STREAM_OUTPOSTS := -2718
const OUTPOST_FACTIONS: Array = ["humans", "ork", "necro", "druid"]
## Шатёр/дом лагеря по расам. Все имена обязаны быть в structure_db.json
## (проверяется генератором, иначе лагерь останется без постройки).
## 28.10: Аллодовские tent/vigvam/necro/druidhouse удалены вместе с ids 1..179 —
## лагеря стоят из наших seedream-построек (те же папки, что жильё/декор).
const OUTPOST_CAMPS := {
	"humans": ["barracks_s1", "barracks_s2"],
	"ork": ["ork_house_b1", "ork_house_b2"],
	"necro": ["necro_house_b1", "necro_house_b2"],
	"druid": ["druid_house_b1", "druid_house_b2"],
}
## Имена форпостов для журнала мира и захвата. Отдельно от расы: игрок видит
## «Форпост Орды», а не «ork».
const OUTPOST_NAMES := {
	"humans": "Форпост Альянса",
	"ork": "Форпост Орды",
	"necro": "Форпост Пожинателей",
	"druid": "Форпост Круга",
}
const OUTPOST_PROP_ID := 193  ## бочка у шатра: центр лагеря без Аллодовского костра
const OUTPOST_MIN_CITY_DISTANCE := 20
const OUTPOST_MIN_SPAWN_DISTANCE := 16
const OUTPOST_MIN_EACH_OTHER := 20
## Радиус лагеря в клетках: шатёр + костёр + посты стражи.
const OUTPOST_RADIUS := 4

var _outposts_out: Array = []  # {id, faction, name, x, y, guards}
## Достижимые от спавна клетки на момент расстановки лагерей: лагерь в
## карманe за горами был бы недоступен игроку, а значит мёртвым контентом.
var _outpost_reach: Dictionary = {}

var _spawn_pos: Vector2i = Vector2i(-1, -1)
var _portal_pos: Vector2i = Vector2i(-1, -1)
var _cities: Array = []  # [{pos: Vector2i, faction: String}]

## Этап 2: города. Центры — на базовой земле, разнесённые (мин. дистанция),
## заливка овалом ~11×11 дорогой (type 3). Количество — из профиля зоны.
func _place_cities(rng: RandomNumberGenerator) -> void:
	_cities.clear()
	var range_arr: Array = ZONE_CITY_COUNTS.get(_zone, [1, 3])
	var count: int = rng.randi_range(int(range_arr[0]), int(range_arr[1]))
	var min_city_dist := 20
	var attempts := 0
	while _cities.size() < count and attempts < 500:
		attempts += 1
		var cx: int = rng.randi_range(8, W - 9)
		var cy: int = rng.randi_range(8, H - 9)
		var p := Vector2i(cx, cy)
		# Центр города — только на базовой земле (0/4/5/6), не на воде/горах/дороге
		var t: int = _terrain[p.y * W + p.x]
		if t == 1 or t == 2 or t == 3:
			continue
		# Разнесение: не ближе min_city_dist к уже размещённым городам
		var far_enough := true
		for c in _cities:
			if p.distance_to(c["pos"]) < min_city_dist:
				far_enough = false
				break
		if not far_enough:
			continue
		_cities.append({"pos": p, "faction": _faction_for(_cities.size())})
		_fill_city_oval(p, city_radius(), city_radius())
	print("CITIES: %d/%d (zone=%s)" % [_cities.size(), count, _zone])

## Раса города (id из CITY_POPULATION / world.json).
##
## 10.10: ПЕРВЫЙ город — раса героя. До этого расы шли по кругу CITY_RACES от
## нуля, то есть первый город всегда был humans, и за орка/друида герой попадал
## в чужой город (жалоба игрока: «у всех кроме людей NPC не соответствуют
## расе»). Остальные города — по кругу, начиная с расы героя, чтобы порядок
## был тот же, но поворот вокруг оси.
##
## неcro был исключён, пока не было атласа нежити. С приходом арта (10.10,
## позже) каждая раса героя даёт свой город, без отката.
func _faction_for(i: int) -> String:
	var order := _race_order()
	if order.is_empty():
		return ""
	return str(order[i % order.size()])


## Расы городов в порядке появления: сначала раса героя, потом остальные.
func _race_order() -> Array:
	var out: Array = []
	var hero := _race_hint if _race_hint != "" else city_race_for_hero(Game.hero_race)
	if hero != "":
		out.append(hero)
	for r in CITY_RACES:
		if not out.has(r):
			out.append(r)
	return out

## Залитый овал дорогой (type 3), диаметр (2*rx+1)×(2*ry+1).
func _fill_city_oval(center: Vector2i, rx: int, ry: int) -> void:
	for dy in range(-ry, ry + 1):
		for dx in range(-rx, rx + 1):
			var fx: float = float(dx) / float(rx)
			var fy: float = float(dy) / float(ry)
			if fx * fx + fy * fy > 1.0:
				continue
			var x: int = center.x + dx
			var y: int = center.y + dy
			if x < 1 or y < 1 or x >= W - 1 or y >= H - 1:
				continue
			_terrain[y * W + x] = 3

## Этап 3: дороги — MST по городам (Прим, ближайший сосед) + A*-коридоры ширины 2.
func _connect_cities(rng: RandomNumberGenerator) -> void:
	if _cities.size() < 2:
		return
	var in_tree := {}
	in_tree[0] = true
	var connected: Array = [0]
	while connected.size() < _cities.size():
		var best_i := -1
		var best_j := -1
		var best_d := 1 << 30
		for i in connected:
			for j in range(_cities.size()):
				if in_tree.has(j):
					continue
				var d: int = _cities[i]["pos"].distance_squared_to(_cities[j]["pos"])
				if d < best_d:
					best_d = d
					best_i = i
					best_j = j
		if best_j < 0:
			break
		_carve_road_between(_cities[best_i]["pos"], _cities[best_j]["pos"], rng)
		in_tree[best_j] = true
		connected.append(best_j)

## A* между двумя точками + лента ширины 2 (перпендикулярно сегменту).
func _carve_road_between(a: Vector2i, b: Vector2i, rng: RandomNumberGenerator) -> void:
	var path: Array = _a_star(a, b, rng)
	if path.is_empty():
		path = _a_star(b, a, rng)
	if path.is_empty():
		return
	for i in range(path.size()):
		var p: Vector2i = path[i]
		# Направление сегмента для перпендикулярной полосы ширины 2
		var seg := Vector2i(0, 0)
		if i + 1 < path.size():
			seg = Vector2i(path[i + 1]) - p
		elif i > 0:
			seg = p - Vector2i(path[i - 1])
		var lane := Vector2i(-seg.y, seg.x) if seg != Vector2i.ZERO else Vector2i(1, 0)
		if lane.x + lane.y < 0:
			lane = -lane
		_set_land_road(p)
		_set_land_road(p + lane)

## Этап 4: горы/вода по экстремумам рельефа. Никогда не трогаем дорогу (3):
## города и дорожная сеть остаются проходимыми — «горы/вода защищают дороги».
func _place_mountains_water() -> void:
	for y in range(H):
		for x in range(W):
			var i: int = y * W + x
			if _terrain[i] == 3:
				continue
			var elev: float = _field[i]
			if elev < _water_thr:
				_terrain[i] = 2
			elif elev > _mountain_thr:
				_terrain[i] = 1

## Убрать одиночные блоки 1×1 / 1×2 чужого биома внутри массива.
## Клетка меняет тип, если среди 8 соседей есть тип с count >= 5, а своих
## (того же типа, что она) <= 2. Кромка большого озера/гор не трогается
## (там своих соседей >= 3). Дорога (3) не перетирается.
func _smooth_isolated_terrain() -> void:
	var changed := 0
	for _pass in range(2):
		var marks := {}
		for y in range(1, H - 1):
			for x in range(1, W - 1):
				var i: int = y * W + x
				var t: int = _terrain[i]
				if t == 3:
					continue
				var own := 0
				var counts := {}
				for dy in range(-1, 2):
					for dx in range(-1, 2):
						if dx == 0 and dy == 0:
							continue
						var nt: int = _terrain[(y + dy) * W + (x + dx)]
						if nt == t:
							own += 1
						elif nt >= 0:
							counts[nt] = int(counts.get(nt, 0)) + 1
				if own > 2:
					continue
				var best_t := -1
				var best_c := 0
				for nt in counts:
					if int(counts[nt]) > best_c:
						best_c = int(counts[nt])
						best_t = int(nt)
				if best_t >= 0 and best_c >= 5 and best_t != 3:
					marks[i] = best_t
		for i in marks:
			_terrain[i] = int(marks[i])
			changed += 1
	if changed > 0:
		print("SMOOTH: сглажено осиротевших клеток: %d" % changed)

## Этап 5: спавн у первого города, портал на противоположном краю.
##
## Спавн сид-зависимый (через _find_land_near): жёсткий центр карты ломал
## gen_seeds_smoke, который требует, чтобы sidecar-ы различались для разных
## сидов. Смена поведения — осознанный откат e28fc374.
func _place_portal_spawn() -> void:
	if _cities.is_empty():
		return
	var city0: Vector2i = _cities[0]["pos"]
	_spawn_pos = _find_land_near(city0, 8)
	_save_spawn_json()
	_reserved[_spawn_pos] = true
	if _sector != "" and not _neighbors.is_empty():
		# Мир 4x3: по порталу на каждую границу с соседом по стороне.
		_place_sector_portals(city0)
	elif _zone in ZONES_WITH_PORTAL:
		# Старый режим (карты вне мира секторов): один портал вдалеке.
		_portal_pos = _find_land_far(city0, 40)
		_save_portal_json()
		_reserved[_portal_pos] = true
	else:
		# Удаляем возможный старый sidecar: карта могла быть сгенерирована до
		# того, как портал стал зональным, а alm_map.gd читает .portal.json, если
		# файл есть. Без этого удаления зона без портала всё равно показывала
		# бы маркер от старой генерации.
		_drop_portal_json()
	if _spawn_pos.x >= 0:
		print("SPAWN: (%d, %d)" % [_spawn_pos.x, _spawn_pos.y])
	if _portals_out.size() > 0:
		var parts: Array = []
		for p in _portals_out:
			parts.append("%s->%s (%d,%d)" % [p["dir"], p["to"], int(p["x"]), int(p["y"])])
		print("PORTALS: " + ", ".join(parts))
	elif _portal_pos.x >= 0:
		print("PORTAL: (%d, %d)" % [_portal_pos.x, _portal_pos.y])
	else:
		print("PORTAL: нет (zone=%s)" % _zone)


## Портал на границе сектора, соответствующей направлению на соседа.
## Клетка обязана быть проходимой и достижимой от первого города — иначе
## игрок увидит маркер, до которого нельзя дойти.
func _place_sector_portals(city0: Vector2i) -> void:
	_portals_out.clear()
	_portal_pos = Vector2i(-1, -1)
	var wm = load("res://scripts/world/world_map.gd")
	# Проходимая область считается ОДИН раз: раньше BFS запускался на каждую
	# клетку приграничной полосы, и переход в сектор 192x192 занимал десятки
	# секунд (замер 23.10: world_map_smoke 142 с).
	var reach := _reachable_cells(city0)
	for raw_n in _neighbors:
		var nid := str(raw_n)
		var dir := str(wm.dir_of(_sector, nid))
		if dir == "":
			continue
		var cell := _find_edge_land(dir, city0, reach)
		if cell.x < 0:
			push_warning("MapGenerator: нет проходимой клетки у границы %s сектора %s" % [dir, _sector])
			continue
		_portals_out.append({
			"x": cell.x, "y": cell.y, "dir": dir, "to": nid,
		})
		_reserved[cell] = true
	_save_portals_json()


## Клетка у края карты в направлении dir, максимально далеко от городов и уже
## поставленных порталов, достижимая пешком от city0.
func _find_edge_land(dir: String, city0: Vector2i, reach: Dictionary) -> Vector2i:
	var best := Vector2i(-1, -1)
	var best_score := -1
	var xs: Array = []
	var ys: Array = []
	match dir:
		"N":
			ys = range(4, mini(14, H - 4))
			xs = range(4, W - 4)
		"S":
			ys = range(maxi(4, H - 14), H - 4)
			xs = range(4, W - 4)
		"W":
			xs = range(4, mini(14, W - 4))
			ys = range(4, H - 4)
		"E":
			xs = range(maxi(4, W - 14), W - 4)
			ys = range(4, H - 4)
		_:
			return best
	for y in ys:
		for x in xs:
			var p := Vector2i(x, y)
			var idx: int = y * W + x
			if not _walkable_terrain(int(_terrain[idx])):
				continue
			if _reserved.has(p):
				continue
			if not reach.has(p):
				continue
			var dcity := 1 << 20
			for c in _cities:
				dcity = mini(dcity, p.distance_squared_to(c["pos"]))
			var dport := 1 << 20
			for pp in _portals_out:
				dport = mini(dport, p.distance_squared_to(Vector2i(int(pp["x"]), int(pp["y"]))))
			if dcity < 12 * 12 or dport < 10 * 10:
				continue
			var edge := mini(mini(x, W - 1 - x), mini(y, H - 1 - y))
			var score := int(sqrt(float(dcity)) * 3.0 + sqrt(float(dport)) * 2.0 - float(edge))
			if score > best_score:
				best_score = score
				best = p
	return best


func _walkable_terrain(t: int) -> bool:
	return t == 0 or t == 3 or t == 4 or t == 5 or t == 6


## Все клетки, достижимые пешком от start (вода 2 и горы 1 непроходимы).
func _reachable_cells(start: Vector2i) -> Dictionary:
	var out := {}
	if start.x < 0 or start.y < 0:
		return out
	out[start] = true
	var queue: Array = [start]
	while not queue.is_empty():
		var p: Vector2i = queue.pop_front()
		for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var q: Vector2i = p + d
			if q.x < 1 or q.y < 1 or q.x >= W - 1 or q.y >= H - 1:
				continue
			if out.has(q):
				continue
			if not _walkable_terrain(int(_terrain[q.y * W + q.x])):
				continue
			out[q] = true
			queue.append(q)
	return out


# === Спавн: здания + НПЦ городов, деревья, Серые ===

## Ближайшая базовая земля (0 трава, 4 почва, 5 песок, 6 грязь) рядом с origin.
func _find_land_near(origin: Vector2i, radius: int) -> Vector2i:
	for r in range(1, radius + 1):
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if abs(dx) != r and abs(dy) != r:
					continue
				var p := Vector2i(origin.x + dx, origin.y + dy)
				if p.x >= 1 and p.y >= 1 and p.x < W - 1 and p.y < H - 1:
					var t: int = _terrain[p.y * W + p.x]
					if t == 0 or t == 4 or t == 5 or t == 6:
						return p
	return Vector2i(-1, -1)

## Базовая земля далеко от origin, ближе к краю карты.
func _find_land_far(origin: Vector2i, min_dist: int) -> Vector2i:
	var best := Vector2i(-1, -1)
	var best_score := -1
	for y in range(3, H - 3):
		for x in range(3, W - 3):
			var t: int = _terrain[y * W + x]
			if t != 0 and t != 4 and t != 5 and t != 6:
				continue
			var p := Vector2i(x, y)
			var dist: float = p.distance_to(origin)
			if dist < min_dist:
				continue
			# Оценка: дальше от origin + ближе к краю карты
			var edge_dist: float = mini(mini(x, W - 1 - x), mini(y, H - 1 - y))
			var score: int = int(dist * 2.0 - edge_dist * 3.0)
			if score > best_score:
				best_score = score
				best = p
	return best

# === Спавн: здания + НПЦ городов, деревья, Серые ===

## Спека здания по папке: {id, w, h, fh} из structure_db.json или {}.
## `fh` (full_height) — полная высота СПРАЙТА, а `h` (tile_height) — только
## футпринт. Разница идёт ВВЕРХ от футпринта (крыша, башня, вывеска).
## Раньше `fh` здесь не возвращался, из-за чего vis_rows всегда был 0: выступ
## здания не резервировался, и дома наезжали друг на друга визуально.
## `sel` из базы НЕ используем осознанно: в structure_db.json он
## самопротиворечив (у kaarginn3 — [12, 82, 0, 82], x0 > x1), брать из него
## футпринт значило бы угадывать.
func _structure_spec(folder: String) -> Dictionary:
	if not StructureDB.has(folder):
		return {}
	var def := StructureDB.get_structure(folder)
	var tid := int(def.get("id", 0))
	if tid <= 0:
		return {}
	var tile_h := int(def.get("tile_height", 1))
	return {
		"id": tid,
		"w": int(def.get("tile_width", 1)),
		"h": tile_h,
		"fh": maxi(tile_h, int(def.get("full_height", tile_h))),
	}

## Этап 6: здания + НПЦ для каждого города. Запись в sidecar-ы structures/npcs.
func _place_city_content(rng: RandomNumberGenerator) -> void:
	for city_index in range(_cities.size()):
		var c: Dictionary = _cities[city_index]
		var center: Vector2i = c["pos"]
		var alchemy_rng := rng_from_seed(_seed + STREAM_ALCHEMY + city_index)
		var alchemy_folder: String = str(_pick(alchemy_rng, ALCHEMY_FOLDERS))
		var plan: Array = [
			_pick(rng, TRAIN_FOLDERS),
			alchemy_folder,
			_pick(rng, BLACKSMITH_FOLDERS),
			_pick(rng, SHOP_FOLDERS),
			_pick(rng, INN_FOLDERS),
		]
		# Один жилой дом на город - по решению игрока (мы не симулятор городов).
		# Раса дома/декора = раса города: орочий город строит орочье жильё.
		var race := str(c.get("faction", "humans"))
		var house_pool: Array = house_folders().get(race, house_folders().get("humans", []))
		var decor_pool: Array = decor_folders().get(race, decor_folders().get("humans", []))
		plan.append(_pick(rng, house_pool))
		plan.append(_pick(rng, decor_pool))
		for folder in plan:
			var spec := _structure_spec(folder)
			if spec.is_empty():
				continue
			_place_city_building(center, spec)
		_place_city_npcs(rng, center, race, city_id_of(city_index))
	print("STRUCTURES_COUNT: %d" % _structures_out.size())

## 6b. Мелкий декор вокруг городов: бочки/ящики/мешки/фонари (seedream).
## Декор - на траве/почве внутри овала, не у самих зданий.
## Фонари (197) - ТОЛЬКО на траве, примыкающей к дороге (фонарный столб
## у тротуара), с дистанцией >= 3 клеток между фонарями, чтобы не сбивались
## сгустком в центре площади.
func _place_city_props(rng: RandomNumberGenerator) -> void:
	# Prop pool comes from data (`map.city_props`); the lantern is placed by a
	# dedicated branch next to roads, so it is excluded from the general pool.
	var prop_pool: Array = []
	for p in ContentRules.list("map.city_props"):
		if int(p) != LANTERN_PROP_ID:
			prop_pool.append(int(p))
	if prop_pool.is_empty():
		prop_pool = [193]
	var placed := 0
	var lantern_cells: Array[Vector2i] = []
	for c in _cities:
		var center: Vector2i = c["pos"]
		var cr := city_radius()  # овал +1 клетка «тротуара» снаружи
		var want := rng.randi_range(5, 8)
		var tries := 0
		var got := 0
		while got < want and tries < want * 24:
			tries += 1
			var r := rng.randi_range(2, cr + 1)
			var dx := rng.randi_range(-r, r)
			var dy := rng.randi_range(-r, r)
			if cr > 0:
				var fx := float(dx) / float(cr + 1)
				var fy := float(dy) / float(cr + 1)
				if fx * fx + fy * fy > 1.0:
					continue
			var cell := center + Vector2i(dx, dy)
			if cell.x < 1 or cell.y < 1 or cell.x >= W - 1 or cell.y >= H - 1:
				continue
			var idx := cell.y * W + cell.x
			var t := _terrain[idx]
			# декор только на суше вне дороги: трава/почва
			if t != 0 and t != 4:
				continue
			if _obstacles[idx] != 0 or _reserved.has(cell):
				continue
			# не лезть на свес зданий
			var touch_bldg := false
			for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1),
					Vector2i(1, 1), Vector2i(-1, -1), Vector2i(1, -1), Vector2i(-1, 1)]:
				if _reserved.has(cell + d):
					touch_bldg = true
					break
			if touch_bldg:
				continue
			var near_rd := _near_road(cell)
			var prop_id: int
			if near_rd:
				# фонарь у тротуара, но не чаще 1 на 3 клетки
				var too_close := false
				for lc in lantern_cells:
					if maxi(abs(lc.x - cell.x), abs(lc.y - cell.y)) < 3:
						too_close = true
						break
				if too_close or rng.randf() > 0.45:
					continue
				prop_id = 197
				lantern_cells.append(cell)
			else:
				prop_id = int(_pick(rng, prop_pool))
			_obstacles[idx] = prop_id
			got += 1
			placed += 1
	print("CITY_PROPS: %d (ламп=%d)" % [placed, lantern_cells.size()])

## Поставить здание (spec) в кольцо вокруг центра города, не на площадь.
## Кольцо расширено до CITY_RADIUS (было 7) под овал 17×17, а в проверку
## передаётся выступ вверх (fh - h), чтобы здания не наезжали друг на друга.
func _place_city_building(center: Vector2i, spec: Dictionary) -> bool:
	var w := int(spec["w"])
	var h := int(spec["h"])
	var full_h: int = int(spec.get("fh", h))
	var vis_rows: int = maxi(0, full_h - h)  # визуальный выступ здания выше футпринта
	_pending_vis_rows = vis_rows
	for r in range(2, city_radius() + 1):
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if abs(dx) != r and abs(dy) != r:
					continue
				var tl := center + Vector2i(dx, dy)
				if not _footprint_fits(tl, w, h, center):
					continue
				_structures_out.append({"x": tl.x, "y": tl.y, "type_id": int(spec["id"])})
				# Резервируем футпринт
				for yy in range(h):
					for xx in range(w):
						_reserved[tl + Vector2i(xx, yy)] = true
				# Резервируем визуальный выступ вверх (чтобы НПЦ не стояли на крыше)
				for vy in range(vis_rows):
					for xx in range(w):
						_reserved[tl + Vector2i(xx, -vy - 1)] = true
				return true
	return false

## Футпринт здания помещается внутри овала города на дороге, не на площади,
## не пересекая спавн/портал/уже занятые клетки и оставляя зазор.
## Зазор CITY_GAP клетки с каждой стороны (была 1 — дома стояли вплотную и
## визуально слипались). Проверяется и сам футпринт, и выступ вверх на fh - h
## строк: иначе крыша одного дома попадала на крышу соседнего.
func _footprint_fits(tl: Vector2i, w: int, h: int, center: Vector2i) -> bool:
	for yy in range(h):
		for xx in range(w):
			var c := tl + Vector2i(xx, yy)
			if c.x < 1 or c.y < 1 or c.x >= W - 1 or c.y >= H - 1:
				return false
			if _terrain[c.y * W + c.x] != 3:
				return false
	var vis_rows := _pending_vis_rows
	# Зазор берётся из [spawn] city_gap. Раньше здесь стоял зашитый 1, хотя
	# константа CITY_GAP и комментарий обещали 2 — то есть решение игрока
	# от 26.09 («зазор 1 -> 2») в коде не было применено, и city_layout_smoke
	# подстроился под факт (`gap >= CITY_GAP - 1`).
	for yy in range(-city_gap() - vis_rows, h + city_gap()):
		for xx in range(-city_gap(), w + city_gap()):
			var c := tl + Vector2i(xx, yy)
			if c.x < 1 or c.y < 1 or c.x >= W - 1 or c.y >= H - 1:
				return false
			if _reserved.has(c) or c == _spawn_pos or c == _portal_pos:
				return false
			# Кольцо вокруг здания шириной CITY_GAP свободно от других зданий.
			var d := maxi(abs(c.x - center.x), abs(c.y - center.y))
			if d <= 1 or d > city_radius():
				return false
	return true

## НПЦ города: стражи (первые 2 патрульные, остальные на постах — по краям
## города, см. _guard_post_cell), капитан, глава города, жители у площади.
## Все стоят; патруль — только первые 2 стража.
##
## Глава (22.10) — отдельный NPC ролью "head": у него квесты и маркер «!»
## (scripts/quest_marker.gd). Стоит у площади рядом с капитаном, но на кольце
## жителей — в толпе капитан и глава не должны сливаться.
func _place_city_npcs(rng: RandomNumberGenerator, center: Vector2i,
		race: String, city_id: String) -> void:
	var pop: Dictionary = CITY_POPULATION.get(race, {})
	if pop.is_empty():
		push_error("MapGenerator: нет CITY_POPULATION для расы '%s' - город останется без NPC" % race)
		return
	var posts_taken := {}
	var guard_rings: Array = [
		Vector2i(city_radius(), city_radius() - 1),
		Vector2i(city_radius() - 1, city_radius()),
	]
	var citizens_offsets: Array = [
		Vector2i(3, 0), Vector2i(-3, 0), Vector2i(0, 3), Vector2i(0, -3),
		Vector2i(3, 3), Vector2i(-3, 3), Vector2i(3, -3), Vector2i(-3, -3),
		Vector2i(4, 0), Vector2i(-4, 0), Vector2i(0, 4), Vector2i(0, -4),
		Vector2i(5, 0), Vector2i(-5, 0), Vector2i(0, 5), Vector2i(0, -5),
		Vector2i(5, 3), Vector2i(-5, 3), Vector2i(5, -3), Vector2i(-5, -3),
		Vector2i(3, 5), Vector2i(-3, 5), Vector2i(3, -5), Vector2i(-3, -5),
	]
	var guards_n := rng.randi_range(
		GameConfig.geti("city", "guard_count_min"), GameConfig.geti("city", "guard_count_max"))
	if GameConfig.geti("stress", "enabled") != 0:
		guards_n = GameConfig.geti("stress", "city_guard_count")
	for i in range(guards_n):
		var post := _guard_post_cell(center, guard_rings, i, guards_n, posts_taken)
		if post.x < 0:
			continue
		var set_name: String = _pick(rng, pop["guards"])
		# City guards are the same in every zone ([city]); zone danger is the
		# Grey tier band, not a per-zone guard stat.
		var hp := rng.randi_range(
			GameConfig.geti("city", "guard_hp_min"), GameConfig.geti("city", "guard_hp_max"))
		var dmg := rng.randi_range(
			GameConfig.geti("city", "guard_damage_min"), GameConfig.geti("city", "guard_damage_max"))
		_npcs_out.append(_npc_rec(post, set_name, "guard", i < 2, hp, dmg, city_id, center))
	# Captain at the square — also the town archmage (player decision 07.10),
	# a mage of ITS OWN race (09.10): an orc town must not get a druid mage.
	var cap := _post_cell(center, [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)], posts_taken)
	if cap.x >= 0:
		var cap_rec := _npc_rec(cap, str(pop["captain"]), "guard", false,
			GameConfig.geti("city", "captain_hp"), GameConfig.geti("city", "captain_damage"),
			city_id)
		# The captain keeps the square, the edge rule is about the ordinary guards.
		cap_rec.erase("city_x")
		cap_rec.erase("city_y")
		cap_rec["archmage"] = true
		_npcs_out.append(cap_rec)
	# Town head — the quest giver. Stands by the square, set of its own race.
	var head_set := str(pop.get("head", pop["citizens"][0]))
	var head := _post_cell(center, [Vector2i(0, 1), Vector2i(0, -1),
		Vector2i(1, 1), Vector2i(-1, 1), Vector2i(1, -1), Vector2i(-1, -1)], posts_taken)
	if head.x >= 0:
		var head_rec := _npc_rec(head, head_set, "head", false,
			GameConfig.geti("city", "citizen_hp"), 0, city_id)
		head_rec["head"] = true
		_npcs_out.append(head_rec)
	# Citizens (standing, no patrol) — rings 3–4
	var cit_n := rng.randi_range(
		GameConfig.geti("city", "citizen_count_min"), GameConfig.geti("city", "citizen_count_max"))
	if GameConfig.geti("stress", "enabled") != 0:
		cit_n = GameConfig.geti("stress", "city_citizen_count")
	for i in range(cit_n):
		var post := _post_cell(center, citizens_offsets, posts_taken)
		if post.x < 0:
			continue
		var set_name: String = _pick(rng, pop["citizens"])
		_npcs_out.append(_npc_rec(post, set_name, "citizen", false,
			GameConfig.geti("city", "citizen_hp"), 0, city_id, center))

## id города для квестов: "c<индекс>t<раса-в-списке>". Индекс — порядок
## города в генераторе; суффикс t0.. повторяет расу из CITY_RACES.
## Городам из военного .alm (без генератора) индексы выдаёт AlmMap.
func _city_race(city_index: int) -> String:
	var order := _race_order()
	if order.is_empty():
		return ""
	return str(order[city_index % order.size()])


static func city_id_of(city_index: int) -> String:
	return "c%dt%d" % [city_index, city_index % maxi(1, CITY_RACES.size())]

## Раса по имени набора: "city_human_mage/t1" -> "humans", "city_ork_warrior/t0"
## -> "ork", "city_druid_mage/t2" -> "druid". Наборы названы по корню без
## хвоста "s" (human, а не humans) и с суффиксом роли (_mage/_warrior), поэтому
## сравнение идёт по корню, а не конкатенацией. Пусто, если набор не наш.
static func race_of_set(set_name: String) -> String:
	if not set_name.begins_with("city_"):
		return ""
	var seg := set_name.trim_prefix("city_").get_slice("/", 0)
	for suffix in ["_mage", "_warrior"]:
		seg = seg.trim_suffix(suffix)
	# Сегмент = id расы из world.json. ВАЖНО: для орков это "ork", а не
	# "orc" — 10.10 тут стоял ["orc", "ork"], и потому городской орк-маг
	# возвращал "" (подпись фракции «Прохожий», тест на расу города падал).
	# Тест при этом был зелёным, потому что проверял СВОЮ копию разбора, а
	# не эту функцию.
	for race in CITY_RACES:
		if seg == race or seg + "s" == race:
			return race
	return ""


## Раса героя -> id фракции (human -> humans). Неизвестная раса даёт "" —
## вызывающий код обязан это учесть, а не молча получить первую в списке.
static func race_of_hero(hero_race: String) -> String:
	match hero_race:
		"human": return "humans"
		"ork": return "ork"
		"druid": return "druid"
		# 10.10 (позже): был "" — у нежити не было атласа, и город за нежить
		# откатывался на первую доступную расу. Теперь атлас есть.
		"necro": return "necro"
		_: return ""


## id фракции героя, но только если для неё есть CITY_POPULATION.
## Проверка остаётся осмысленной: она страхует от расы без арта, если такую
## добавят в hero_race раньше, чем появится набор спрайтов.
static func city_race_for_hero(hero_race: String) -> String:
	var race := race_of_hero(hero_race)
	if race != "" and CITY_POPULATION.has(race):
		return race
	return ""


## Свободный пост: клетка дороги в городе, не на площади, не занята.
func _post_cell(center: Vector2i, offsets: Array, taken: Dictionary) -> Vector2i:
	for off in offsets:
		var c: Vector2i = center + off
		if c.x < 1 or c.y < 1 or c.x >= W - 1 or c.y >= H - 1:
			continue
		if _terrain[c.y * W + c.x] != 3:
			continue
		if _reserved.has(c) or taken.has(c):
			continue
		if c == _spawn_pos or c == _portal_pos:
			continue
		taken[c] = true
		return c
	return Vector2i(-1, -1)

## Пост стражи на ВНЕШНЕМ кольце города. Стража стоит по краю (решение
## игрока 22.10: в центре её было слишком много и она путалась под ногами),
## а площадь остаётся капитану, главе и жителям. Кандидаты — клетки
## внутреннего и внешнего кольца овала в порядке обхода по кругу со сдвигом,
## равномерно по периметру; первым берётся ближайший к выезду (оси N/S/E/W).
func _guard_post_cell(center: Vector2i, rings: Array, index: int, total: int,
		taken: Dictionary) -> Vector2i:
	var cands: Array[Vector2i] = []
	for ring in rings:
		var rx := int((ring as Vector2i).x)
		var ry := int((ring as Vector2i).y)
		for dy in range(-ry, ry + 1):
			for dx in range(-rx, rx + 1):
				var fx := float(dx) / float(maxi(1, rx))
				var fy := float(dy) / float(maxi(1, ry))
				if fx * fx + fy * fy > 1.0:
					continue
				if absi(dx) < rx - 1 and absi(dy) < ry - 1:
					continue
				var c := center + Vector2i(dx, dy)
				if cands.has(c):
					continue
				cands.append(c)
	if cands.is_empty():
		return _post_cell(center, [Vector2i(2, 0), Vector2i(-2, 0)], taken)
	var step := maxi(1, cands.size() / maxi(1, total))
	for i in range(cands.size()):
		var c: Vector2i = cands[(index * step + i) % cands.size()]
		if _guard_post_free(c, center, taken):
			taken[c] = true
			return c
	for c2 in cands:
		var cc: Vector2i = c2
		if _guard_post_free(cc, center, taken):
			taken[cc] = true
			return cc
	return Vector2i(-1, -1)


## Клетка годится под пост стражи: дорога города, свободна от зданий/декора,
## не спавн и не портал, не занята другим NPC и не на площади.
func _guard_post_free(c: Vector2i, center: Vector2i, taken: Dictionary) -> bool:
	if c.x < 1 or c.y < 1 or c.x >= W - 1 or c.y >= H - 1:
		return false
	if _terrain[c.y * W + c.x] != 3:
		return false
	if _reserved.has(c) or taken.has(c):
		return false
	if c == _spawn_pos or c == _portal_pos:
		return false
	return maxi(absi(c.x - center.x), absi(c.y - center.y)) > 2


func _npc_rec(post: Vector2i, set_name: String, role: String, patrol: bool,
		hp: int, dmg: int, city_id: String = "",
		center: Vector2i = Vector2i(-1, -1)) -> Dictionary:
	var rec := {
		"x": post.x, "y": post.y, "set": set_name,
		"role": role, "patrol": patrol,
		"post": [post.x, post.y],
		"hp_max": hp, "damage": dmg,
		"city_id": city_id,
	}
	if center.x >= 0 and center.y >= 0:
		# Town centre: lets the town tests place the guards by distance to it.
		rec["city_x"] = center.x
		rec["city_y"] = center.y
	return rec

## Этап 8: точки интереса ВНЕ городов.
##
## Что это и зачем. Решение игрока (03.10): «масштаб по зонам + точки
## интереса, без бродячих NPC». То есть мир вне городов не должен быть
## пустым (сейчас там только Серые и деревья), но и бродячих NPC, которых
## нигде не найти, игрок не хочет. Поэтому точка интереса — это маленькая
## СТАТИЧНАЯ группа NPC на одном месте: стоят, не патрулируют, не лезут
## ни в какие дела.
##
## Почему НЕ свой sidecar. Первая мысль была завести .interest.json и
## новый загрузчик в alm_map.gd. Отказался сознательно: точка интереса —
## это просто NPC, а NPC уже умеют грузиться из .npcs.json. Новый файл +
## новый путь загрузки + новый код спавна = втрое больше мест, где можно
## ошибиться, ради функции, выключенной по умолчанию. Поэтому POI пишутся
## обычными записями в .npcs.json с добавленным полем "poi".
##
## Выключено по умолчанию: poi.count = 0 ([poi]).
## Пока игрок не поднимет число, поведение игры не отличается от прежнего.
const POI_KINDS := [
	# Аллодовские humans/* убраны (07.10). Пока арта мало — точки выключены
	# (poi.count=0). Под ork_mage вернём, когда будет достаточно ступеней.
]

## Минимальные дистанции POI (клетки). Отдельны от трав: точка интереса
## должна быть заметна издалека, трава — нет.
const POI_MIN_CITY_DISTANCE := 18     # далеко от города (решение игрока 03.10)
const POI_MIN_SPAWN_DISTANCE := 14    # не ближе спавна/портала
const POI_MIN_EACH_OTHER := 16         # разрежены между собой


func _place_interest_points(rng: RandomNumberGenerator) -> void:
	var target := GameConfig.geti("poi", "count")
	if target <= 0:
		print("POI: выключено (poi.count=0)")
		return
	var placed := 0
	var tries := 0
	while placed < target and tries < 600:
		tries += 1
		var anchor := Vector2i(rng.randi_range(3, W - 4), rng.randi_range(3, H - 4))
		if not _poi_cell_ok(anchor):
			continue
		var kind: Dictionary = POI_KINDS[rng.randi() % POI_KINDS.size()]
		# небольшая группа вокруг якоря: 2-3 NPC, стоят рядом
		var members := rng.randi_range(2, 3)
		var hp := GameConfig.geti("poi", "hp")
		var dmg := GameConfig.geti("poi", "damage")
		var taken := 0
		for i in range(members):
			var spot := anchor + Vector2i(rng.randi_range(-2, 2), rng.randi_range(-2, 2))
			if not _poi_spot_ok(spot):
				continue
			var set_name: String = str(kind["sets"][i % (kind["sets"] as Array).size()])
			var rec := _npc_rec(spot, set_name, "guard", false, hp, dmg)
			rec["poi"] = str(kind["kind"])
			rec["poi_label"] = str(kind["label"])
			_npcs_out.append(rec)
			taken += 1
		if taken > 0:
			_interest_out.append({
				"x": anchor.x, "y": anchor.y,
				"kind": str(kind["kind"]), "label": str(kind["label"]),
				"members": taken,
			})
			placed += 1
	print("POI: %d/%d kind=%s" % [placed, target,
		", ".join(POI_KINDS.map(func(k: Dictionary) -> String: return str(k["kind"])))])


## Якорь точки интереса: суша, не в городе, не у спавна/портала, не на дороге,
## не занято объектом. Как _herb_cell_ok, но с другими дистанциями.
func _poi_cell_ok(cell: Vector2i) -> bool:
	if cell.x < 3 or cell.y < 3 or cell.x >= W - 3 or cell.y >= H - 3:
		return false
	var terrain := _terrain[cell.y * W + cell.x]
	if terrain != 0 and terrain != 4:      # трава или почва; воду/горы/песок/грязь — нет
		return false
	if _obstacles[cell.y * W + cell.x] != 0:
		return false
	if _reserved.has(cell) or _near_road(cell):
		return false
	if _near_city(cell, POI_MIN_CITY_DISTANCE):
		return false
	if _near_point(cell, _spawn_pos, POI_MIN_SPAWN_DISTANCE):
		return false
	if _near_point(cell, _portal_pos, POI_MIN_SPAWN_DISTANCE):
		return false
	for record in _interest_out:
		var dx := absi(cell.x - int(record.get("x", -1)))
		var dy := absi(cell.y - int(record.get("y", -1)))
		if dx < POI_MIN_EACH_OTHER and dy < POI_MIN_EACH_OTHER:
			return false
	return true


func _poi_spot_ok(cell: Vector2i) -> bool:
	if cell.x < 2 or cell.y < 2 or cell.x >= W - 2 or cell.y >= H - 2:
		return false
	if _obstacles[cell.y * W + cell.x] != 0 or _reserved.has(cell):
		return false
	for record in _npcs_out:
		if int(record.get("x", -1)) == cell.x and int(record.get("y", -1)) == cell.y:
			return false
	return true


# --- Форпосты фракций (пакет B переработки ковки) --------------------------

## Этап 6c: форпосты. Ставится ПОСЛЕ городов/декора и ДО деревьев: лагерь
## резервирует клетки, и лес/травы/Серые обходят его сами.
##
## Стартовая зона намеренно пуста (решение игрока 28.10): «в начальном нет
## никаких фракционных воинов, только серые». Поэтому там 0 форпостов, и это
## не ошибка генератора, а правило.
func _place_outposts(rng: RandomNumberGenerator) -> void:
	_outposts_out.clear()
	var target := GameConfig.geti("outpost", "per_map")
	if _zone == "start":
		target = 0
	if target <= 0:
		print("OUTPOSTS: 0 (зона %s)" % _zone)
		return
	# Фракции не повторяются, пока их хватает: три лагеря одной и той же расы
	# на одной карте читались бы как один лагерь, размноженный копипастой.
	var factions: Array = OUTPOST_FACTIONS.duplicate()
	_shuffle(rng, factions)
	# Достижимость от спавна: карман за горами не должен съесть лагерь.
	_outpost_reach = _reachable_cells(_spawn_pos)
	var placed := 0
	var tries := 0
	while placed < target and tries < 500:
		tries += 1
		var anchor := Vector2i(rng.randi_range(3, W - 4), rng.randi_range(3, H - 4))
		if not _outpost_cell_ok(anchor):
			continue
		var faction := str(factions[placed % factions.size()])
		if _build_outpost(placed, faction, anchor, rng):
			placed += 1
	var names: Array = []
	for o in _outposts_out:
		names.append(str((o as Dictionary)["faction"]))
	print("OUTPOSTS: %d/%d (%s)" % [placed, target, ", ".join(names)])


## Якорь лагеря: суша вне дороги, не у города/спавна/портала и не рядом с
## другим лагерем. Терраин — любой проходимый (трава/почва/песок/грязь).
func _outpost_cell_ok(cell: Vector2i) -> bool:
	if cell.x < OUTPOST_RADIUS + 2 or cell.y < OUTPOST_RADIUS + 2 \
			or cell.x >= W - OUTPOST_RADIUS - 2 or cell.y >= H - OUTPOST_RADIUS - 2:
		return false
	if not _outpost_terrain_ok(cell):
		return false
	if _obstacles[cell.y * W + cell.x] != 0 or _reserved.has(cell):
		return false
	if not _outpost_reach.is_empty() and not _outpost_reach.has(cell):
		return false
	if _near_road(cell) or _near_city(cell, OUTPOST_MIN_CITY_DISTANCE):
		return false
	if _near_point(cell, _spawn_pos, OUTPOST_MIN_SPAWN_DISTANCE):
		return false
	if _near_point(cell, _portal_pos, OUTPOST_MIN_SPAWN_DISTANCE):
		return false
	for o in _outposts_out:
		var d: Dictionary = o
		if absi(cell.x - int(d["x"])) < OUTPOST_MIN_EACH_OTHER \
				and absi(cell.y - int(d["y"])) < OUTPOST_MIN_EACH_OTHER:
			return false
	return true


## Проходимый биом под лагерь. Горы/вода не годятся: шатёр стоял бы в озере.
func _outpost_terrain_ok(cell: Vector2i) -> bool:
	if cell.x < 0 or cell.y < 0 or cell.x >= W or cell.y >= H:
		return false
	var t := _terrain[cell.y * W + cell.x]
	return t == 0 or t == 4 or t == 5 or t == 6


## Собрать один лагерь. false — не нашлось места под шатёр (якорь пропадает).
func _build_outpost(index: int, faction: String, anchor: Vector2i,
		rng: RandomNumberGenerator) -> bool:
	var camps: Array = OUTPOST_CAMPS.get(faction, [])
	if camps.is_empty():
		return false
	var spec := _structure_spec(str(_pick(rng, camps)))
	if spec.is_empty():
		push_error("MapGenerator: нет постройки лагеря для '%s'" % faction)
		return false
	var camp_cell := _place_camp_building(anchor, spec)
	if camp_cell.x < 0:
		return false
	# Метка лагеря: проп у шатра (бочка), а не Аллодовский костёр.
	# Проп живёт в поле препятствий, как мелкий декор городов (`_place_city_props`),
	# и не занимает футпринт структуры.
	var prop_cell := _free_camp_cell(anchor, {}, 1)
	if prop_cell.x >= 0:
		_obstacles[prop_cell.y * W + prop_cell.x] = OUTPOST_PROP_ID
		_reserved[prop_cell] = true
	# Стража: тир зоны задаёт и набор, и силу (как у городских стражей).
	var tier := _outpost_tier()
	var token := "human" if faction == "humans" else faction
	var count := GameConfig.geti("outpost", "guards_min") \
		+ rng.randi_range(0, maxi(0, GameConfig.geti("outpost", "guards_max")
			- GameConfig.geti("outpost", "guards_min")))
	var hp := rng.randi_range(GameConfig.geti("city", "guard_hp_min"),
		GameConfig.geti("city", "guard_hp_max"))
	var dmg := rng.randi_range(GameConfig.geti("city", "guard_damage_min"),
		GameConfig.geti("city", "guard_damage_max"))
	var oid := "op%d" % index
	var taken := {}
	for i in range(count):
		var slot := anchor + Vector2i(rng.randi_range(-2, 2), rng.randi_range(-2, 2))
		var spot := _free_camp_cell(slot, taken, 2)
		if spot.x < 0:
			continue
		taken[spot] = true
		_reserved[spot] = true
		var role := "mage" if i == 1 and count >= 3 else "warrior"
		var set_name := "city_%s_%s/t%d" % [token, role, tier]
		if not UnitDB.has(set_name):
			set_name = "city_%s_warrior/t%d" % [token, tier]
		if not UnitDB.has(set_name):
			continue
		var rec := _npc_rec(spot, set_name, "guard", false, hp, dmg)
		rec["faction"] = faction
		rec["outpost"] = oid
		_npcs_out.append(rec)
	_outposts_out.append({
		"id": oid,
		"faction": faction,
		"name": str(OUTPOST_NAMES.get(faction, "Форпост")),
		"x": anchor.x, "y": anchor.y,
	})
	return true


## Поставить шатёр лагеря: свободный футпринт в радиусе лагеря. В отличие от
## города, дорога не нужна — лагерь стоит на земле.
func _place_camp_building(anchor: Vector2i, spec: Dictionary) -> Vector2i:
	var w := int(spec["w"])
	var h := int(spec["h"])
	var vis_rows: int = maxi(0, int(spec.get("fh", h)) - h)
	for r in range(0, OUTPOST_RADIUS):
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if r > 0 and abs(dx) != r and abs(dy) != r:
					continue
				var tl := anchor + Vector2i(dx, dy) - Vector2i(w >> 1, h - 1)
				if not _camp_footprint_fits(tl, w, h, anchor, vis_rows):
					continue
				_structures_out.append({"x": tl.x, "y": tl.y, "type_id": int(spec["id"])})
				for yy in range(h):
					for xx in range(w):
						_reserved[tl + Vector2i(xx, yy)] = true
				for vy in range(vis_rows):
					for xx in range(w):
						_reserved[tl + Vector2i(xx, -vy - 1)] = true
				_reserved[anchor] = true
				return anchor
	return Vector2i(-1, -1)


func _camp_footprint_fits(tl: Vector2i, w: int, h: int, anchor: Vector2i,
		vis_rows: int) -> bool:
	for yy in range(h):
		for xx in range(w):
			var c := tl + Vector2i(xx, yy)
			if not _outpost_terrain_ok(c):
				return false
			if _obstacles[c.y * W + c.x] != 0 or _reserved.has(c):
				return false
			if not _outpost_reach.is_empty() and not _outpost_reach.has(c):
				return false
			if c == _spawn_pos or c == _portal_pos:
				return false
			if maxi(absi(c.x - anchor.x), absi(c.y - anchor.y)) > OUTPOST_RADIUS:
				return false
	for vy in range(vis_rows):
		var roof := tl + Vector2i(0, -vy - 1)
		if roof.y < 1:
			return false
	return true


## Свободная клетка лагеря рядом с желаемой (радиус radius, не занята).
func _free_camp_cell(want: Vector2i, taken: Dictionary, radius: int) -> Vector2i:
	if _camp_cell_free(want, taken):
		return want
	for r in range(1, radius + 1):
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if abs(dx) != r and abs(dy) != r:
					continue
				var c := want + Vector2i(dx, dy)
				if _camp_cell_free(c, taken):
					return c
	return Vector2i(-1, -1)


func _camp_cell_free(c: Vector2i, taken: Dictionary) -> bool:
	if not _outpost_terrain_ok(c):
		return false
	if _obstacles[c.y * W + c.x] != 0:
		return false
	if taken.has(c) or _reserved.has(c):
		return false
	if c == _spawn_pos or c == _portal_pos:
		return false
	if not _outpost_reach.is_empty() and not _outpost_reach.has(c):
		return false
	return true


## Тир стражи по зоне: старт пуст, дальше набор и сила растут. t0..t3 есть у
## всех четырёх городских наборов (units_db.json, city_*_warrior/tN).
func _outpost_tier() -> int:
	match _zone:
		"mid": return 1
		"hard": return 2
		"faction": return 3
	return 0


## Этап 7: деревья/объекты в _obstacles (ID из alm_objects.json). Кластерный
## шум по биому; не ставим на дорогу, у дорог, в городах и у спавна/портала.
# Tree density per zone lives in [zone_design] (map design, not combat rates).
func _zone_tree_density() -> float:
	var v := GameConfig.designf(_zone, "tree_density")
	return 0.08 if v < 0.0 else v


func _place_objects(rng: RandomNumberGenerator) -> void:
	if _obj_noise == null:
		_obj_noise = FastNoiseLite.new()
		_obj_noise.seed = _seed + STREAM_OBJECTS
		_obj_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
		_obj_noise.frequency = 1.0 / 16.0
		_obj_noise.fractal_octaves = 2
	var density: float = _zone_tree_density()
	for y in range(H):
		for x in range(W):
			var t := _terrain[y * W + x]
			if t != 0 and t != 4 and t != 5 and t != 6:
				continue
			var cell := Vector2i(x, y)
			if _reserved.has(cell) or _near_road(cell) or _near_city(cell, 6):
				continue
			if _near_point(cell, _spawn_pos, 3) or _near_point(cell, _portal_pos, 3):
				continue
			if _obj_noise.get_noise_2d(x, y) > 0.0 and rng.randf() < density:
				_obstacles[y * W + x] = _tree_id(rng, t)
	# Стресс: добиваем деревья до абсолютного счётчика [stress] tree_count.
	if GameConfig.geti("stress", "enabled") != 0:
		_fill_stress_trees(rng)


func _fill_stress_trees(rng: RandomNumberGenerator) -> void:
	var want := GameConfig.geti("stress", "tree_count")
	if want <= 0:
		return
	var placed := 0
	for i in range(W * H):
		if _obstacles[i] != 0:
			placed += 1
	var tries := 0
	var max_tries := want * 6
	while placed < want and tries < max_tries:
		tries += 1
		var x := rng.randi_range(2, W - 3)
		var y := rng.randi_range(2, H - 3)
		var idx := y * W + x
		if _obstacles[idx] != 0:
			continue
		var t := _terrain[idx]
		if t != 0 and t != 4 and t != 5 and t != 6:
			continue
		var cell := Vector2i(x, y)
		if _reserved.has(cell) or _near_road(cell) or _near_city(cell, 4):
			continue
		if _near_point(cell, _spawn_pos, 2) or _near_point(cell, _portal_pos, 2):
			continue
		_obstacles[idx] = _tree_id(rng, t)
		placed += 1
	print("STRESS trees: %d (tries=%d)" % [placed, tries])

## Сосед-дорога рядом? (клиренс: дерево не примыкает к дороге)
func _near_road(cell: Vector2i) -> bool:
	for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		var n: Vector2i = cell + d
		if n.x < 0 or n.y < 0 or n.x >= W or n.y >= H:
			continue
		if _terrain[n.y * W + n.x] == 3:
			return true
	return false

func _near_city(cell: Vector2i, r: int) -> bool:
	for c in _cities:
		var cc: Vector2i = c["pos"]
		if maxi(abs(cell.x - cc.x), abs(cell.y - cc.y)) <= r:
			return true
	return false

func _near_point(cell: Vector2i, p: Vector2i, r: int) -> bool:
	if p.x < 0:
		return false
	return maxi(abs(cell.x - p.x), abs(cell.y - p.y)) <= r

func _tree_id(rng: RandomNumberGenerator, t: int) -> int:
	var pool: Array
	match t:
		4: pool = TREE_SOIL
		5: pool = TREE_SAND
		6: pool = TREE_MUD
		_: pool = TREE_GRASS
	return int(_pick(rng, pool))

func _place_herbs(rng: RandomNumberGenerator) -> void:
	var target_count: int = int(HERB_TARGET_COUNTS.get(_zone, 26))
	var herb_index := rng.randi() % HERB_ITEMS.size()
	var regions_filled := 0
	var region_width := int(W / float(herb_region_grid()))
	var region_height := int(H / float(herb_region_grid()))
	for region_y in range(herb_region_grid()):
		for region_x in range(herb_region_grid()):
			var min_x := region_x * region_width + 2
			var max_x := mini((region_x + 1) * region_width - 3, W - 3)
			var min_y := region_y * region_height + 2
			var max_y := mini((region_y + 1) * region_height - 3, H - 3)
			for attempt in range(80):
				var cell := Vector2i(rng.randi_range(min_x, max_x), rng.randi_range(min_y, max_y))
				if not _herb_cell_ok(cell) or not _herb_spacing_ok(cell):
					continue
				herb_index = _append_herb(cell, herb_index)
				regions_filled += 1
				break
	var tries := 0
	while _herbs_out.size() < target_count and tries < 1200:
		tries += 1
		var cell := Vector2i(rng.randi_range(2, W - 3), rng.randi_range(2, H - 3))
		if not _herb_cell_ok(cell) or not _herb_spacing_ok(cell):
			continue
		herb_index = _append_herb(cell, herb_index)
	print("HERBS: %d/%d regions=%d/%d min_distance=%d" % [
		_herbs_out.size(), target_count, regions_filled, herb_region_grid() * herb_region_grid(), herb_min_distance()])

func _append_herb(cell: Vector2i, herb_index: int) -> int:
	var herb: Dictionary = HERB_ITEMS[herb_index % HERB_ITEMS.size()]
	_herbs_out.append({
		"x": cell.x, "y": cell.y,
		"item": str(herb["item"]), "icon": str(herb["icon"]),
	})
	return herb_index + 1

func _herb_spacing_ok(cell: Vector2i) -> bool:
	for record in _herbs_out:
		var dx := absi(cell.x - int(record.get("x", -1)))
		var dy := absi(cell.y - int(record.get("y", -1)))
		if dx < herb_min_distance() and dy < herb_min_distance():
			return false
	return true

func _herb_cell_ok(cell: Vector2i) -> bool:
	if cell.x < 2 or cell.y < 2 or cell.x >= W - 2 or cell.y >= H - 2:
		return false
	var terrain := _terrain[cell.y * W + cell.x]
	if terrain != 0 and terrain != 4:
		return false
	if _obstacles[cell.y * W + cell.x] != 0:
		return false
	if _reserved.has(cell) or _near_road(cell) or _near_city(cell, 6):
		return false
	if _near_point(cell, _spawn_pos, 8) or _near_point(cell, _portal_pos, 8):
		return false
	for record in _herbs_out:
		if int(record.get("x", -1)) == cell.x and int(record.get("y", -1)) == cell.y:
			return false
	return true

## Этап 9: Серые — кластеры у дорог (сбоку) и в лесных массивах. Только на
## свободных клетках, вне городов и не ближе 20 клеток к спавну.
##
## Замер 03.10 (жалоба игрока «1 Серый на карте»): при 15 Серых на 6 клетках
## сидело по 2-3 врага, и все они жались в одну половину карты (y=74..118).
## Две причины: якорь кластера не проверялся на занятость, и якоря выбирались
## независимо, так что все шли из одного и того же случайного угла.
## Теперь сначала обходим РЕГИОНЫ по очереди и по кластеру в каждом, а уже
## потом добираем случайно — так покрытие карты гарантировано.
func _place_greys(rng: RandomNumberGenerator) -> void:
	var count: int = rng.randi_range(
		GameConfig.designi(_zone, "gray_count_min"), GameConfig.designi(_zone, "gray_count_max"))
	if GameConfig.geti("stress", "enabled") != 0:
		count = GameConfig.geti("stress", "gray_count")
	var placed := 0
	var encounter_seq := 0

	# Список регионов в перемешанном порядке — чтобы зоны «раньше» не выбирались
	# всегда одинаково и карта не была предсказуемой.
	var regions: Array = []
	for ry in range(GRAY_REGION_GRID):
		for rx in range(GRAY_REGION_GRID):
			regions.append(Vector2i(rx, ry))
	_shuffle(rng, regions)

	# Пакет D: сначала тематические встречи (улей/логово/стая), ~35% квоты.
	var encounter_budget := int(ceil(float(count) * 0.35))
	var kinds: Array = ENCOUNTER_KINDS.duplicate()
	_shuffle(rng, kinds)
	var kinds_used := 0
	var tries_e := 0
	while placed < encounter_budget and kinds_used < kinds.size() and tries_e < 200:
		tries_e += 1
		var ed: Dictionary = kinds[kinds_used % kinds.size()]
		kinds_used += 1
		var anchor := _encounter_anchor(rng, str(ed.get("near", "any")))
		if anchor.x < 0:
			continue
		placed += _spawn_encounter(rng, anchor, ed, encounter_seq)
		encounter_seq += 1

	for reg in regions:
		if placed >= count:
			break
		var anchor := _gray_anchor_in_region(rng, reg)
		if anchor.x < 0:
			continue
		placed += _gray_cluster(rng, anchor)

	# Добор: если регионы не дали нужного количества (мало дорог/леса в части
	# карты), берём любые подходящие якоря.
	var tries := 0
	while placed < count and tries < 800:
		tries += 1
		var anchor := Vector2i(-1, -1)
		if rng.randf() < 0.5:
			var road := _road_anchor(rng)
			if road.x >= 0:
				anchor = _side_road_cell(rng, road)
		else:
			anchor = _forest_anchor(rng)
		if anchor.x < 0 or not _gray_anchor_ok(anchor):
			continue
		placed += _gray_cluster(rng, anchor)

	var regions_used := {}
	for k in _gray_cells.keys():
		var p := str(k).split(",")
		regions_used["%d,%d" % [int(int(p[0]) * GRAY_REGION_GRID / float(W)),
			int(int(p[1]) * GRAY_REGION_GRID / float(H))]] = true
	print("GRAY: %d/%d клеток=%d регионов=%d/%d" % [
		placed, count, _gray_cells.size(), regions_used.size(),
		GRAY_REGION_GRID * GRAY_REGION_GRID])


## Якорь Серого внутри конкретного региона карты (сетка GRAY_REGION_GRID).
## Две попытки: сначала ищем клетку рядом с дорогой или лесом (звери выглядят
## как звери), а если в регионе такого нет — берём любую свободную сушу.
## Без второй попытки регионы без дорог и леса оставались пустыми: замер
## 03.10 давал 3 региона из 9.
func _gray_anchor_in_region(rng: RandomNumberGenerator, reg: Vector2i) -> Vector2i:
	var rw := int(W / float(GRAY_REGION_GRID))
	var rh := int(H / float(GRAY_REGION_GRID))
	var x0 := reg.x * rw
	var y0 := reg.y * rh
	var fallback := Vector2i(-1, -1)
	for attempt in range(60):
		var c := Vector2i(rng.randi_range(x0 + 2, x0 + rw - 3),
			rng.randi_range(y0 + 2, y0 + rh - 3))
		if not _gray_cell_ok(c):
			continue
		if _near_point(c, _spawn_pos, GRAY_MIN_SPAWN_DISTANCE):
			continue
		if not _gray_anchor_ok(c):
			continue
		if _near_road(c) or _forest_anchor_ok(c):
			return c
		if fallback.x < 0:
			fallback = c
	return fallback


## Есть ли вокруг клетки хотя бы два дерева (объекта) — признак лесной местности.
func _forest_anchor_ok(c: Vector2i) -> bool:
	var trees := 0
	for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		var n: Vector2i = c + d
		if n.x < 0 or n.y < 0 or n.x >= W or n.y >= H:
			continue
		if _obstacles[n.y * W + n.x] > 0:
			trees += 1
	return trees >= 2


## Перемешивание массива по rng генератору (глобальный random.* не используем —
## иначе генерация перестанет быть детерминированной по сиду).
func _shuffle(rng: RandomNumberGenerator, arr: Array) -> void:
	for i in range(arr.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp: Variant = arr[i]
		arr[i] = arr[j]
		arr[j] = tmp


## Якорь кластера не должен совпадать с уже занятым и должен быть отделён от
## других якорей, иначе все Серые слипаются в одном углу карты.
func _gray_anchor_ok(anchor: Vector2i) -> bool:
	if _gray_cells.has("%d,%d" % [anchor.x, anchor.y]):
		return false
	for k in _gray_cells.keys():
		var p := str(k).split(",")
		var dx := absi(anchor.x - int(p[0]))
		var dy := absi(anchor.y - int(p[1]))
		if dx < GRAY_MIN_DISTANCE and dy < GRAY_MIN_DISTANCE:
			return false
	return true

## Случайная клетка дороги вне городов и подальше от спавна.
func _road_anchor(rng: RandomNumberGenerator) -> Vector2i:
	var tries := 0
	while tries < 400:
		tries += 1
		var x := rng.randi_range(2, W - 3)
		var y := rng.randi_range(2, H - 3)
		if _terrain[y * W + x] != 3:
			continue
		var c := Vector2i(x, y)
		if _near_city(c, 6) or _near_point(c, _spawn_pos, 24):
			continue
		return c
	return Vector2i(-1, -1)

## Сбоку от дороги (1–2 клетки в сторону, только проходимая земля).
func _side_road_cell(rng: RandomNumberGenerator, road: Vector2i) -> Vector2i:
	var dirs: Array = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	for step in range(1, 3):
		for attempt in range(8):
			var dir: Vector2i = dirs[rng.randi() % dirs.size()]
			var c: Vector2i = road + dir * step
			if _gray_cell_ok(c):
				return c
	return road

## Лесная точка: вокруг >=2 деревьев (obstacles), клетка свободна.
func _forest_anchor(rng: RandomNumberGenerator) -> Vector2i:
	var tries := 0
	while tries < 500:
		tries += 1
		var x := rng.randi_range(2, W - 3)
		var y := rng.randi_range(2, H - 3)
		var c := Vector2i(x, y)
		if not _gray_cell_ok(c) or _near_point(c, _spawn_pos, 20):
			continue
		var trees := 0
		for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var n: Vector2i = c + d
			if n.x < 0 or n.y < 0 or n.x >= W or n.y >= H:
				continue
			if _obstacles[n.y * W + n.x] > 0:
				trees += 1
		if trees >= 2:
			return c
	return Vector2i(-1, -1)

## Клетка пригодна для Серого: суша, без объекта/здания/спавна/портала, вне городов.
func _gray_cell_ok(c: Vector2i) -> bool:
	if c.x < 2 or c.y < 2 or c.x >= W - 2 or c.y >= H - 2:
		return false
	var t := _terrain[c.y * W + c.x]
	if t != 0 and t != 4 and t != 5 and t != 6:
		return false
	if _obstacles[c.y * W + c.x] > 0:
		return false
	if _reserved.has(c) or c == _spawn_pos or c == _portal_pos:
		return false
	if _near_city(c, 6):
		return false
	# Клетка уже занята другим Серым. Без этой проверки кластеры накладывались:
	# их якоря подбирались независимо, и на 6 клетках сидело по 2-3 врага.
	if _gray_cells.has("%d,%d" % [c.x, c.y]):
		return false
	return true

## Кластер из 2–4 Серых вокруг anchor (ячейки разнесены).
##
## ПУСТОЙ ПУЛ = СЕРЫХ НЕТ. Все наборы монстров удалены вместе с артом Аллодов
## (11.10), и без этой проверки `_pick(rng, [])` возвращал null, который
## присваивался в `String` — SCRIPT ERROR в самом генераторе карты. Раньше
## пустой пул был невозможен, поэтому ветка не была написана.
func _gray_cluster(rng: RandomNumberGenerator, anchor: Vector2i) -> int:
	var pool: Array = gray_pool_for_zone(_zone)
	if pool.is_empty():
		return 0
	var cells: Array = [anchor]
	for i in range(1, 3):
		var c := _near_gray_cell(rng, anchor, cells)
		if c.x < 0:
			break
		cells.append(c)
	for i in range(cells.size()):
		var cc: Vector2i = cells[i]
		_gray_cells["%d,%d" % [cc.x, cc.y]] = true
		var set_name: String = str(_pick(rng, pool))
		# The tier scales the global [grey] base (see gray_tier_mults), so the
		# zone band, not a per-zone DPS table, decides how hard a map hits.
		var mults: Array = gray_tier_mults(set_name)
		var hp := int(round(float(rng.randi_range(
			GameConfig.geti("grey", "hp_min"), GameConfig.geti("grey", "hp_max")))
			* float(mults[0])))
		var dmg := int(round(float(rng.randi_range(
			GameConfig.geti("grey", "damage_min"), GameConfig.geti("grey", "damage_max")))
			* float(mults[1])))
		_npcs_out.append({
			"x": int(cc.x), "y": int(cc.y), "set": set_name,
			"hp_max": hp, "damage": dmg,
		})
	return cells.size()


## Якорь тематической встречи: forest/road/any.
func _encounter_anchor(rng: RandomNumberGenerator, near: String) -> Vector2i:
	match near:
		"forest":
			var f := _forest_anchor(rng)
			if f.x >= 0 and _gray_anchor_ok(f):
				return f
			return Vector2i(-1, -1)
		"road":
			var road := _road_anchor(rng)
			if road.x >= 0:
				var c := _side_road_cell(rng, road)
				if c.x >= 0 and _gray_anchor_ok(c):
					return c
			return Vector2i(-1, -1)
		_:
			for attempt in range(20):
				var c := Vector2i(rng.randi_range(4, W - 5), rng.randi_range(4, H - 5))
				if _gray_cell_ok(c) and _gray_anchor_ok(c):
					return c
			return Vector2i(-1, -1)


## Поставить встречу: 1 «ядро» (сильнее) + members-1 обычных вокруг.
func _spawn_encounter(rng: RandomNumberGenerator, anchor: Vector2i, ed: Dictionary, eid: int) -> int:
	var sets: Array = ed.get("sets", [])
	if sets.is_empty():
		return 0   # нет наборов — стая не ставится (см. ENCOUNTER_KINDS)
	var members: Array = ed.get("members", [2, 3])
	var n := rng.randi_range(int(members[0]), int(members[1]))
	var hp_mult := float(ed.get("hp_mult", 1.0))
	var dmg_mult := float(ed.get("dmg_mult", 1.0))
	var kind := str(ed.get("kind", "wild"))
	var cells: Array = [anchor]
	for i in range(1, n):
		var c := _near_gray_cell(rng, anchor, cells)
		if c.x < 0:
			break
		cells.append(c)
	for i in range(cells.size()):
		var cc: Vector2i = cells[i]
		_gray_cells["%d,%d" % [cc.x, cc.y]] = true
		var set_name: String = str(sets[i % sets.size()])
		var is_core := i == 0
		var hp := int(round(float(rng.randi_range(
			GameConfig.geti("grey", "hp_min"), GameConfig.geti("grey", "hp_max"))) * hp_mult * (1.25 if is_core else 1.0)))
		var dmg := int(round(float(rng.randi_range(
			GameConfig.geti("grey", "damage_min"), GameConfig.geti("grey", "damage_max"))) * dmg_mult))
		var rec := {
			"x": int(cc.x), "y": int(cc.y), "set": set_name,
			"hp_max": hp, "damage": dmg,
			"encounter_kind": kind,
			"encounter_id": eid,
			"home_x": int(anchor.x), "home_y": int(anchor.y),
		}
		if is_core:
			rec["encounter_core"] = true
		_npcs_out.append(rec)
	print("ENCOUNTER %s id=%d members=%d core=%s" % [kind, eid, cells.size(), str(ed.get("label", ""))])
	return cells.size()

## Соседняя клетка для кластера. ВАЖНО: массив `taken` здесь ТОЛЬКО читается.
## Раньше сюда писали `taken.append(c)`, а вызывающий код потом делал
## `cells.append(c)` — а массив передаётся по ССЫЛКЕ, и клетка попадала в
## список дважды. Кластер из 3 превращался в 5 записей, две из них на одной
## клетке: замер 03.10 давал 15 Серых на 9 клетках, и игрок видел «1 Серый».
func _near_gray_cell(rng: RandomNumberGenerator, anchor: Vector2i, taken: Array) -> Vector2i:
	for attempt in range(12):
		var off := Vector2i(rng.randi_range(-2, 2), rng.randi_range(-2, 2))
		if off == Vector2i.ZERO:
			continue
		var c: Vector2i = anchor + off
		if taken.has(c) or not _gray_cell_ok(c):
			continue
		return c
	return Vector2i(-1, -1)

func _pick(rng: RandomNumberGenerator, arr: Array) -> Variant:
	if arr.is_empty():
		return null
	return arr[rng.randi() % arr.size()]

func _save_spawn_json() -> void:
	if _spawn_pos.x < 0:
		return
	var path: String = _out_dir + _basename + ".spawn.json"
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify({"x": _spawn_pos.x, "y": _spawn_pos.y}))
	f.close()

func _save_portal_json() -> void:
	if _portal_pos.x < 0:
		return
	var path: String = _out_dir + _basename + ".portal.json"
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify({"x": _portal_pos.x, "y": _portal_pos.y}))
	f.close()

## Новый формат sidecar: массив порталов по границам сектора.
func _save_portals_json() -> void:
	var path: String = _out_dir + _basename + ".portal.json"
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify({"portals": _portals_out}))
	f.close()

## Удалить sidecar портала, если карта перегенерируется в зоне без портала.
func _drop_portal_json() -> void:
	var path: String = _out_dir + _basename + ".portal.json"
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
		print("PORTAL: старый sidecar удалён (%s)" % path)

func _a_star(start: Vector2i, goal: Vector2i, rng: RandomNumberGenerator) -> Array:
	var came: Dictionary = {}
	var gscore: Dictionary = {}
	var fscore: Dictionary = {}
	var gk := start.y * W + start.x
	var gk2 := goal.y * W + goal.x
	gscore[gk] = 0
	fscore[gk] = _astar_h(start, goal)
	var open: Array = [gk]
	while not open.is_empty():
		# выбираем минимальный fscore
		var best_i := 0
		var best_f := -1
		for i in range(open.size()):
			var f := int(fscore.get(open[i], 1 << 30))
			if best_f < 0 or f < best_f:
				best_f = f
				best_i = i
		var cur: int = open[best_i]
		open.remove_at(best_i)
		if cur == gk2:
			# восстанавливаем путь
			var out: Array = []
			var c := cur
			while c != gk:
				var cc: Vector2i = Vector2i(c % W, int(c / float(W)))
				out.push_front(cc)
				c = int(came.get(c, gk))
			out.push_front(start)
			return out
		var cp: Vector2i = Vector2i(cur % W, int(cur / float(W)))
		# Направление, с которого пришли (для штрафа за поворот)
		var dir_from_prev := Vector2i(0, 0)
		if came.has(cur):
			var prev_p: Vector2i = Vector2i(int(came[cur]) % W, int(int(came[cur]) / float(W)))
			dir_from_prev = cp - prev_p
		for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var np: Vector2i = cp + d
			if not _is_road_cell(np.x, np.y):
				continue
			var nk: int = np.y * W + np.x
			# Базовая цена шага + штраф за горы (дорога любит траву)
			var stepcost := 10
			if _terrain[nk] == 1:
				stepcost = 18
			# Лёгкое отталкивание от воды: в оригиналах дорога почти не примыкает
			# к воде (adj 0–9%), держимся на расстоянии 1 клетки.
			var near_water_cost := 0
			for wd in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var wn: Vector2i = np + wd
				if wn.x >= 0 and wn.y >= 0 and wn.x < W and wn.y < H and _terrain[wn.y * W + wn.x] == 2:
					near_water_cost = 3
					break
			var penalty := 0
			if dir_from_prev != Vector2i.ZERO and dir_from_prev != d:
				penalty = 6
			# детерминированный шум клетки для извилистости трассы
			var jitter: int = (abs(cp.x * 7919 + cp.y * 104729) % 9) - 4
			var tentative: int = int(gscore.get(cur, 1 << 30)) + stepcost + penalty + near_water_cost + jitter
			if tentative < int(gscore.get(nk, 1 << 30)):
				came[nk] = cur
				gscore[nk] = tentative
				fscore[nk] = tentative + _astar_h(np, goal)
				if not open.has(nk):
					open.append(nk)
	return []

func _astar_h(p: Vector2i, goal: Vector2i) -> int:
	return absi(goal.x - p.x) + absi(goal.y - p.y)

func _is_road_cell(x: int, y: int) -> bool:
	if x < 1 or y < 1 or x >= W - 1 or y >= H - 1:
		return false
	var t: int = _terrain[y * W + x]
	return t != 2  # Всё кроме воды проходимо для дороги

func _set_land_road(p: Vector2i) -> void:
	if p.x < 0 or p.y < 0 or p.x >= W or p.y >= H:
		return
	var idx: int = p.y * W + p.x
	var t: int = _terrain[idx]
	if t == 2:
		return
	_terrain[idx] = 3

func _place_terrain(n: int) -> void:
	# === Этап 1: почва Voronoi (база). Горы/вода/дорога добавляются позже ===
	# Только базовые типы: 0 трава, 4 почва, 5 песок, 6 грязь.
	# Опорные точки: тип -> количество
	var seed_counts := {0: 3, 4: 2, 5: 2, 6: 1}

	var rng := RandomNumberGenerator.new()
	rng.seed = _seed + STREAM_TERRAIN

	# Шум для деформации границ (создаёт извилистые берега/границы биомов)
	var jitter_noise := FastNoiseLite.new()
	jitter_noise.seed = _seed + STREAM_JITTER
	jitter_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	jitter_noise.frequency = 1.0 / 20.0
	jitter_noise.fractal_octaves = 3

	# Поле высот: используется гор/воды этапом 4 и высотами (шаг 7)
	var elev_noise := FastNoiseLite.new()
	elev_noise.seed = _seed + STREAM_TERRAIN
	elev_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	elev_noise.frequency = 1.0 / 40.0
	elev_noise.fractal_octaves = 4
	elev_noise.fractal_gain = 0.5

	# Генерируем опорные точки
	var seeds: Array = []
	for t in seed_counts:
		for i in range(seed_counts[t]):
			var sx: float = rng.randf_range(5.0, W - 6.0)
			var sy: float = rng.randf_range(5.0, H - 6.0)
			seeds.append({"pos": Vector2(sx, sy), "type": t})

	var field := PackedFloat32Array()
	field.resize(n)

	# Для каждой клетки — ближайшая опорная точка
	for i in range(n):
		var x: float = float(i % W)
		var y: float = float(int(i / float(W)))
		var elev: float = (elev_noise.get_noise_2d(x, y) + 1.0) * 0.5
		field[i] = elev

		# Ищем ближайшую опорную точку с шумовым смещением
		var best_type: int = 0
		var best_dist: float = 1e30
		for s in seeds:
			var sp: Vector2 = s["pos"]
			# Базовое расстояние
			var dx: float = x - sp.x
			var dy: float = y - sp.y
			var dist: float = dx * dx + dy * dy
			# Шумовое смещение для органичных границ (~10% от расстояния)
			var jx: float = jitter_noise.get_noise_2d(x * 3.0, y * 3.0)
			var jy: float = jitter_noise.get_noise_2d(x * 3.0 + 100, y * 3.0 + 100)
			dist += (jx * dx + jy * dy) * 3.0
			if dist < best_dist:
				best_dist = dist
				best_type = s["type"]

		_terrain[i] = best_type

	# Сохраняем field и пороги для высот.
	# Рельеф сектора (23.10) меняет ДОЛЮ непроходимого, но не основу: горы/вода
	# остаются барьерами по краям и между областями, а не биомом.
	_field = field
	var sorted := field.duplicate()
	sorted.sort()
	var water_pct := 0.10
	var mountain_pct := 0.90
	match _relief:
		"coast":
			water_pct = 0.14
		"marsh":
			water_pct = 0.16
		"hills":
			mountain_pct = 0.88
		"ridges":
			mountain_pct = 0.82
		"plains":
			mountain_pct = 0.94
	_water_thr = sorted[clampi(int(water_pct * n), 0, n - 1)]
	_mountain_thr = sorted[clampi(int(mountain_pct * n), 0, n - 1)]

func _pick_tile(t: int, x: int, y: int) -> int:
	var s: Dictionary = _sides(x, y)
	# Переходная кромка имеет приоритет над shape/rules: файлы tile1..7
	# бесшовные и кромок не содержат, поэтому exact-формы из аудита .alm
	# на них не дают ничего — только шов. См. terrain_tiles_db.json.
	var trans: int = _transition_tile(t, s, x, y)
	if trans >= 0:
		_stat_transition += 1
		return trans
	var mask := _mask_from_sides(s, t)
	if mask == 0:
		return _interior_tile(t, x, y)
	# 1. Exact shape from real-map audit (weighted top tiles)
	var spec := _shape_lookup(t, mask, x, y)
	if not spec.is_empty():
		_stat_exact += 1
		return AlmLoader.tile_from_spec(spec)
	# 2. Fallback: old directional rules (first matching direction)
	_stat_rules += 1
	return _edge_tile(t, s, x, y)

## Направление перехода для клетки: -1, если перехода нет.
## Порядок совпадает с directions.order в terrain_tiles_db.json и с ключами
## _sides(): N, NE, E, SE, S, SW, W, NW. Кардинальные берутся раньше
## диагональных — так же вела себя оригинальная transition_db.
##
## 05.10 (два правила):
## 1) Односторонний переход: смешиваем только если t < n (мой тип меньше
##    типа соседа). Сосед с большим типом остаётся чистым интерьером.
##    Иначе обе стороны границы режут навстречу: у края A-плитки чистый B,
##    у края B-плитки чистый A → на шве жёсткий B|A посреди смеси,
##    «двойной берег» (жалоба игрока, 05.10: вода-песок с двух сторон).
## 2) Диагональ пропускается, если шов к n уже у кардинальных соседей
##    угла (_diag_covered). См. комментарий к _diag_covered.
func _transition_dir(s: Dictionary, t: int, x: int, y: int) -> int:
	for d in _TRANSITION_DIR_ORDER:
		var n: int = s[d]
		if n < 0 or n == t:
			continue
		# Старший тип не смешивается в младший — переход поставит сосед.
		if t > n:
			continue
		if d == "NE" or d == "SE" or d == "SW" or d == "NW":
			if _diag_covered(x, y, t, n, d):
				continue
		return _TRANSITION_DIR_ORDER.find(d)
	return -1

## Кардинальные соседи в углу диагонали d (ключи _sides()).
const _DIAG_CARDINALS := {
	"NE": ["N", "E"],
	"SE": ["S", "E"],
	"SW": ["S", "W"],
	"NW": ["N", "W"],
}
const _CARDINAL_OFFSET := {
	"N": Vector2i(0, -1),
	"S": Vector2i(0, 1),
	"E": Vector2i(1, 0),
	"W": Vector2i(-1, 0),
}

## Значение террейна вне карты = -1.
func _terrain_at(x: int, y: int) -> int:
	if x < 0 or y < 0 or x >= W or y >= H:
		return -1
	return _terrain[y * W + x]

## Диагональ к типу n «покрыта», если кардинальный сосед в этом углу имеет
## тип t (свой) и у этого кардинального соседа есть кардинальный сосед типа n.
##
## ГЕОМЕТРИЯ: у чистой диагонали (оба кардинала == t) диагональный сосед
## ВСЕГДА кардинален для обоих угловых клеток (NW ячейки = W у N-соседа).
## Значит чистые диагональные переходы фактически отключаются — по решению
## игрока (05.10): лишний угловой срез поверх уже подрезанных соседей не нужен.
## Границу держат кардинальные переходы на клетках, соприкасающихся с n.
func _diag_covered(x: int, y: int, t: int, n: int, d: String) -> bool:
	var cards: Array = _DIAG_CARDINALS.get(d, [])
	for cdir in cards:
		var off: Vector2i = _CARDINAL_OFFSET[cdir]
		var cx: int = x + int(off.x)
		var cy: int = y + int(off.y)
		if _terrain_at(cx, cy) != t:
			continue
		for aoff in _CARDINAL_OFFSET.values():
			var a: Vector2i = aoff
			if _terrain_at(cx + int(a.x), cy + int(a.y)) == n:
				return true
	return false

## Stable per-cell hash.
##
## `hash(Vector2i)` is engine-defined and Godot may change it between versions,
## which would silently reshuffle generated maps while the seed stayed the same.
## This mixing formula is ours (same constants as `_interior_tile`), so a cell
## keeps its value across engine upgrades. No player data depends on the exact
## numbers, only determinism does.
func _cell_hash(x: int, y: int) -> int:
	return absi(x * 19349663 ^ y * 83492791)

## Переходный тайл A -> B по направлению dir_index. -1, если перехода нет.
##
## Известное ограничение: угловая клетка с двумя отличающимися соседями
## получает бленд только по одному (первому) направлению. Бленд по двум
## краям сразу потребовал бы отдельных угловых плиток — это 4 файла на пару
## типов, в формате .alm для них нет места.
func _transition_tile(t: int, s: Dictionary, x: int, y: int) -> int:
	var dir_index: int = _transition_dir(s, t, x, y)
	if dir_index < 0:
		return -1
	var b: int = s[_TRANSITION_DIR_ORDER[dir_index]]
	if b < 0 or b > 6:
		return -1
	var file_n: int = AlmLoader.TRANSITION_FILE_MIN + dir_index
	# row = B * 2 + вариация. Вариацию берём от координаты клетки, чтобы
	# соседние кромки не были одинаковыми, но оставались детерминированными.
	var variation: int = _cell_hash(x, y) % 2
	var row: int = b * 2 + variation
	return AlmLoader.tile_encode_transition(file_n, t, row)

## Bit layout must match tests/analyze_shapes.gd: [N, NE, E, SE, S, SW, W, NW]
const CARDINAL_BITS := 0x55  # биты N(0), E(2), S(4), W(6)
## Варианты кромки травы, визуально почти идентичные (L1 4-20 тыс).
## v0/v2/v3 — «почвенные» (L1 26-46 тыс): на ровной кромке выглядят
## врезанными квадратами, сценаристы на простые границы их не ставили.
const GRASS_EDGE_VARIANTS := [1, 5, 9, 12, 13, 14]
func _mask_from_sides(s: Dictionary, t: int) -> int:
	var mask := 0
	var dirs := ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
	for d in range(8):
		var n: int = s[dirs[d]]
		if n != -1 and n != t:
			mask |= (1 << d)
	return mask

func _mask_str(mask: int) -> String:
	var out := ""
	for d in range(8):
		out += "1" if (mask & (1 << (7 - d))) != 0 else "0"
	return out

## Exact shape -> hybrid (types 4-6 borrow grass topology) -> nearest mask.
## Returns {file, variant, row} or {} if nothing found.
func _shape_lookup(t: int, mask: int, x: int, y: int) -> Dictionary:
	var key := "%d:%s" % [t, _mask_str(mask)]
	if _shapes.has(key):
		return _shape_tile(t, _shapes[key], x, y, mask)
	# Hybrid: soil/sand/mud have no real art — borrow grass(0) shapes,
	# re-render into their own tile file via TERRAIN_FILE.
	if t >= 4:
		var tkey := "0:%s" % _mask_str(mask)
		if _shapes.has(tkey):
			return _shape_tile(t, _shapes[tkey], x, y, mask)
	# Nearest mask by Hamming distance for this type (or grass for 4-6)
	_stat_subset += 1
	var best_key := ""
	var best_dist := 99
	var best_total := -1
	var types: Array = [t] if t <= 3 else [t, 0]
	for tt in types:
		var prefix := "%d:" % tt
		for k in _shapes:
			var ks: String = str(k)
			if not ks.begins_with(prefix):
				continue
			var sm := _mask_from_str(ks.substr(prefix.length()))
			var dist := _popcount(sm ^ mask)
			var total: int = _shapes[k].get("total", 0)
			if dist < best_dist or (dist == best_dist and total > best_total):
				best_dist = dist
				best_key = ks
				best_total = total
	if best_key.is_empty():
		return {}
	return _shape_tile(t, _shapes[best_key], x, y, mask)

## Весовой выбор из формы. Для граничных клеток с кардинальной маской
## сужаем кандидатов до «краевого» row типа — иначе топ-тайл может быть
## внутренней текстурой и рвать ровную линию кромки.
func _shape_tile(t: int, entry: Dictionary, x: int, y: int, mask: int) -> Dictionary:
	var tiles: Array = entry.get("tiles", [])
	if tiles.is_empty():
		return {}
	var candidates: Array = tiles
	if mask & CARDINAL_BITS != 0:
		var art_t := t if t <= 3 else 0
		# Универсальный «край» есть только у травы (0) и гор (1) — один row на
		# любой кардинальный переход. Вода анимирована (rows 0..7), дорога имеет
		# свои краевые rows по соседям — им единый row навязывать нельзя.
		if (art_t == 0 or art_t == 1) and _edge_rows.has(art_t):
			var er: int = _edge_rows[art_t]
			var filtered: Array = []
			for ti in tiles:
				if int(ti.get("row", -1)) == er:
					# Кромка травы: только «зелёные» варианты. v0/v2/v3 — темнее,
					# выглядят «квадратами почвы» на ровной линии, их сценаристы
					# не ставили на простые кромки. Семейство v1/v5/v9/v12/v13/v14
					# пиксельно почти идентично (L1 4-20 тыс vs 26-46 тыс у v0/2/3).
					if art_t == 0 and int(ti.get("variant", -1)) in GRASS_EDGE_VARIANTS:
						filtered.append(ti)
					elif art_t != 0:
						filtered.append(ti)
			if filtered.is_empty():
				# Краевых кандидатов нет — пусть _pick_tile уйдёт в rules-fallback
				# (ровная кромка по типу соседа), а не возьмёт внутренние текстуры.
				return {}
			candidates = filtered
	var total := 0
	for ti in candidates:
		total += int(ti.get("w", 0))
	if total <= 0:
		return {}
	var h: int = _cell_hash(x, y)
	var r: int = h % total
	var acc := 0
	var picked: Dictionary = candidates[candidates.size() - 1]
	for ti in candidates:
		acc += int(ti.get("w", 0))
		if r < acc:
			picked = ti
			break
	var out := {
		"file": int(picked.get("file", 1)),
		"variant": int(picked.get("variant", 0)),
		"row": int(picked.get("row", 0)),
	}
	if t >= 4:
		out["file"] = int(TERRAIN_FILE.get(t, out["file"]))
	return out

func _mask_from_str(s: String) -> int:
	var m := 0
	for i in range(mini(8, s.length())):
		if s[i] == "1":
			m |= 1 << (7 - i)
	return m

func _popcount(v: int) -> int:
	var c := 0
	for i in range(8):
		if v & (1 << i):
			c += 1
	return c

func _sides(x: int, y: int) -> Dictionary:
	var t: int = _terrain[y * W + x]
	var r := {"N": -1, "S": -1, "E": -1, "W": -1,
			  "NE": -1, "NW": -1, "SE": -1, "SW": -1}
	if y > 0:     r["N"]  = _terrain[(y - 1) * W + x]
	if y < H - 1: r["S"]  = _terrain[(y + 1) * W + x]
	if x < W - 1: r["E"]  = _terrain[y * W + x + 1]
	if x > 0:     r["W"]  = _terrain[y * W + x - 1]
	if y > 0 and x < W - 1: r["NE"] = _terrain[(y - 1) * W + x + 1]
	if y > 0 and x > 0:     r["NW"] = _terrain[(y - 1) * W + x - 1]
	if y < H - 1 and x < W - 1: r["SE"] = _terrain[(y + 1) * W + x + 1]
	if y < H - 1 and x > 0:     r["SW"] = _terrain[(y + 1) * W + x - 1]
	return r

func _interior_tile(t: int, x: int, y: int = -1) -> int:
	# 1. Base textures from real maps: low-frequency noise per cell -> one of
	#    top-6 tiles. Плавное поле даёт связные «поля» без жёстких worley-чанков.
	var base: Dictionary = _base_int.get(str(t), {})
	var tiles: Array = base.get("tiles", [])
	if not tiles.is_empty():
		var total := 0
		for ti in tiles:
			total += int(ti.get("w", 0))
		var val := _interior_value(x, y, t, total)
		var pick: Dictionary = tiles[tiles.size() - 1]
		if total > 0:
			var r: int = val
			var acc := 0
			for ti in tiles:
				acc += int(ti.get("w", 0))
				if r < acc:
					pick = ti
					break
		var spec := {
			"file": int(pick.get("file", 1)),
			"variant": int(pick.get("variant", 0)),
			"row": int(pick.get("row", 0)),
		}
		if t >= 4:
			spec["file"] = int(TERRAIN_FILE.get(t, spec["file"]))
		return AlmLoader.tile_from_spec(spec)

	# 2. A1-A6 interior variants from rules
	var a_variants: Array = []
	for iv in range(1, 7):
		var key: String = "%d:A%d:%d" % [t, iv, t]
		var spec: Dictionary = _rules.get(key, {})
		if not spec.is_empty():
			a_variants.append(spec)
	if a_variants.size() > 0:
		# Vary across cells via coordinates (constant hash was a bug:
		# same variant for the whole map).
		var hseed: int = 17
		if x >= 0 and y >= 0:
			hseed = abs(t * 73856093 + x * 19349663 + y * 83492791)
		var idx: int = hseed % a_variants.size()
		var spec: Dictionary = a_variants[idx]
		return AlmLoader.tile_from_spec(_spec_for_type(t, spec))

	# 3. Fallback to interior dict
	var key := str(t)
	if _interior.has(key):
		return AlmLoader.tile_from_spec(_spec_for_type(t, _interior[key]))
	match t:
		0: return AlmLoader.tile_from_spec({"file": 1, "variant": 1, "row": 1})
		1: return AlmLoader.tile_from_spec({"file": 2, "variant": 15, "row": 3})
		2: return AlmLoader.tile_from_spec({"file": 3, "variant": 3, "row": 0})
		3: return AlmLoader.tile_from_spec({"file": 4, "variant": 3, "row": 0})
	return 0

## Плавный низкочастотный шум (частота ~1/14) + лёгкий локальный компонент.
	## Возвращает индекс в диапазоне [0, total): соседние клетки коррелируют —
	## связные «поля» без жёстких 8x8-чанков и без «шахматки».
func _interior_value(x: int, y: int, t: int, total: int) -> int:
	if _interior_noise == null:
		_interior_noise = FastNoiseLite.new()
		_interior_noise.seed = _seed + STREAM_INTERIOR
		_interior_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
		_interior_noise.frequency = 1.0 / 14.0
	if _interior_hi == null:
		_interior_hi = FastNoiseLite.new()
		_interior_hi.seed = _seed + STREAM_INTERIOR_HI
		_interior_hi.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
		_interior_hi.frequency = 1.0 / 60.0
	# Сдвиг домена на тип: базовый сид + шаг типа (7 + t*131 / 99 + t*271).
	_interior_noise.seed = _seed + STREAM_INTERIOR + t * 131
	_interior_hi.seed = _seed + STREAM_INTERIOR_HI + t * 271
	var off: int = _NOISE_OFFSETS.get(t, 0)
	var f1: float = (_interior_noise.get_noise_2d(float(x) + off, float(y)) + 1.0) * 0.5
	var f2: float = (_interior_hi.get_noise_2d(float(x) * 2.0 + off, float(y) * 2.0) + 1.0) * 0.5
	var f: float = clampf(f1 * 0.8 + f2 * 0.2, 0.0, 1.0)
	return clampi(int(f * float(total)) % maxi(1, total), 0, maxi(0, total - 1))

func _edge_tile(t: int, s: Dictionary, x: int, y: int) -> int:
	# Collect all directions where neighbor differs
	var cardinal_diff: Array = []
	var diagonal_diff: Array = []
	for d in ["N", "S", "E", "W"]:
		if s[d] != -1 and s[d] != t:
			cardinal_diff.append(d)
	for d in ["NE", "NW", "SE", "SW"]:
		if s[d] != -1 and s[d] != t:
			diagonal_diff.append(d)

	# Try cardinal rules first
	for d in cardinal_diff:
		var neighbor: int = s[d]
		var spec: Dictionary = _get_rule(t, d, neighbor)
		if not spec.is_empty():
			# Правила для травы дают v0r4 («почва»). На кромке травы это
			# «врезанный квадрат» — нормализуем вариант до зелёного семейства.
			if t == 0 and int(spec.get("variant", -1)) in [0, 2, 3]:
				spec = {"file": 1, "variant": 13, "row": int(spec.get("row", 4))}
			return AlmLoader.tile_from_spec(_spec_for_type(t, spec))

	# Try diagonal rules
	for d in diagonal_diff:
		var neighbor: int = s[d]
		var spec: Dictionary = _get_rule(t, d, neighbor)
		if not spec.is_empty():
			return AlmLoader.tile_from_spec(_spec_for_type(t, spec))

	# No rule found — use interior
	return _interior_tile(t, x, y)

## file из правила -> file для кодировки типа A (.alm)
## Теперь palette хранит правильный file, remap не нужен.
func _spec_for_type(type_a: int, spec: Dictionary) -> Dictionary:
	var out := spec.duplicate(true)
	out["variant"] = int(spec.get("variant", 0))
	out["row"] = int(spec.get("row", 0))
	# Для типов >=4: перезаписываем file через TERRAIN_FILE
	if type_a >= 4:
		out["file"] = int(TERRAIN_FILE.get(type_a, out["file"]))
	return out

func _pick_height(x: int, y: int, t: int, field_value: float) -> int:
	# Псевдо-высота: noise field определяет И terrain И высоту.
	# Вода всегда низкая, горы высокие, остальные — средние с вариацией.
	match t:
		2: # Вода: 0-15 (всегда низко)
			return int(round(clampf(field_value * 15.0, 0.0, 15.0)))
		1: # Горы: 40-127 (высокие пики)
			var lo: float = _water_thr
			var hi: float = 1.0
			var span: float = maxf(0.0001, hi - lo)
			var u: float = clampf((field_value - lo) / span, 0.0, 1.0)
			return int(round(clampf(40.0 + u * 87.0, 40.0, 127.0)))
		0: # Трава: 10-60 (холмы)
			var lo: float = _water_thr
			var hi: float = _mountain_thr
			var span: float = maxf(0.0001, hi - lo)
			var u: float = clampf((field_value - lo) / span, 0.0, 1.0)
			return int(round(clampf(10.0 + u * 50.0, 10.0, 60.0)))
		4: # Почва: 10-50 (средняя)
			var lo: float = _water_thr
			var hi: float = _mountain_thr
			var span: float = maxf(0.0001, hi - lo)
			var u: float = clampf((field_value - lo) / span, 0.0, 1.0)
			return int(round(clampf(10.0 + u * 40.0, 10.0, 50.0)))
		5: # Песок: 5-35 (низина)
			var lo: float = _water_thr
			var hi: float = _mountain_thr
			var span: float = maxf(0.0001, hi - lo)
			var u: float = clampf((field_value - lo) / span, 0.0, 1.0)
			return int(round(clampf(5.0 + u * 30.0, 5.0, 35.0)))
		6: # Грязь: 8-33 (болото)
			var lo: float = _water_thr
			var hi: float = _mountain_thr
			var span: float = maxf(0.0001, hi - lo)
			var u: float = clampf((field_value - lo) / span, 0.0, 1.0)
			return int(round(clampf(8.0 + u * 25.0, 8.0, 33.0)))
		3: # Дорога: интерполяция от соседей
			return _interpolate_road_height(x, y)
		_: # Остальные: средняя
			return int(round(clampf(field_value * 60.0, 10.0, 60.0)))

func _interpolate_road_height(x: int, y: int) -> int:
	# Дорога: среднее от соседних не-дорожных клеток.
	var sum := 0.0
	var cnt := 0
	for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		var nx: int = x + d.x
		var ny: int = y + d.y
		if nx < 0 or ny < 0 or nx >= W or ny >= H:
			continue
		var nt: int = _terrain[ny * W + nx]
		if nt != 3:
			sum += float(_heights[ny * W + nx])
			cnt += 1
	if cnt > 0:
		return int(round(sum / float(cnt)))
	# Нет соседей — берём из field
	return int(round(clampf(_field[y * W + x] * 40.0, 10.0, 40.0)))

func _smooth_nonroad_heights() -> void:
	var source := _heights.duplicate()
	for y in range(H):
		for x in range(W):
			var i: int = y * W + x
			if _terrain[i] == 3:
				continue
			var sum := 0.0
			var count := 0
			for dy in range(-1, 2):
				for dx in range(-1, 2):
					var nx: int = x + dx
					var ny: int = y + dy
					if nx < 0 or ny < 0 or nx >= W or ny >= H:
						continue
					var ni: int = ny * W + nx
					if _terrain[ni] == 3:
						continue
					sum += float(source[ni])
					count += 1
			if count > 0:
				_heights[i] = clampi(int(round(sum / float(count))), 0, 127)

func _box_blur(field: PackedFloat32Array) -> PackedFloat32Array:
	# Лёгкое сглаживание (3×3): сохраняет извилистость берега, убирая только
	# одиночные пиксели-артефакты шума.
	var out: PackedFloat32Array = field.duplicate()
	for y in range(H):
		for x in range(W):
			var sum := 0.0
			var cnt := 0
			for dy in range(-1, 2):
				for dx in range(-1, 2):
					var nx: int = x + dx
					var ny: int = y + dy
					if nx < 0 or ny < 0 or nx >= W or ny >= H:
						continue
					sum += field[ny * W + nx]
					cnt += 1
			out[y * W + x] = sum / float(cnt)
	return out

# === Сохранение ===

func _save() -> void:
	DirAccess.make_dir_recursive_absolute(_out_dir)
	var path: String = _out_dir + _basename + ".alm"
	var data: PackedByteArray = _write_alm()
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		print("ERROR: " + path)
		return
	f.store_buffer(data)
	f.close()
	var m: Dictionary = AlmLoader.load_map(path)
	if not m.is_empty():
		print("OK: %dx%d, tiles=%d, heights=%d" % [
			int(m["width"]), int(m["height"]),
			int(m["tiles"].size()), int(m["heights"].size()),
		])
		# Статистика
		var tc := {}
		for i in range(W * H):
			var tt: int = _terrain[i]
			tc[tt] = tc.get(tt, 0) + 1
		var total: float = W * H
		var terrain_parts: Array = []
		var terrain_names := {0: "трава", 1: "горы", 2: "вода", 3: "дорога", 4: "почва", 5: "песок", 6: "грязь"}
		for tt in terrain_names:
			var cnt: int = tc.get(tt, 0)
			if cnt > 0:
				terrain_parts.append("%s=%.1f%%" % [terrain_names[tt], cnt * 100.0 / total])
		print("Terrain: " + ", ".join(terrain_parts))
		print("Shapes: exact=%d subset=%d rules-fallback=%d transitions=%d" % [
			_stat_exact, _stat_subset, _stat_rules, _stat_transition])
		_road_stats(tc.get(3, 0))
		var obj_count := 0
		for v in _obstacles:
			if v > 0:
				obj_count += 1
		print("Объектов: %d (%.1f%%)" % [obj_count, obj_count * 100.0 / total])
		# Спавн sidecar-ами (buildings + NPC)
		_save_sidecars()
		_validate_city_content()
		var guards := 0
		var citizens := 0
		var greys := 0
		for n in _npcs_out:
			match str(n.get("role", "")):
				"guard": guards += 1
				"citizen": citizens += 1
				_: greys += 1
		print("Спавн: зданий=%d НПЦ=%d (стражи=%d жители=%d серые=%d) трав=%d" % [
			_structures_out.size(), _npcs_out.size(), guards, citizens, greys, _herbs_out.size()])
	else:
		print("ERROR load_map")
	print("Сохранено: " + path)
	_report(100, 12)

## Sidecar-ы спавна: структуры и NPC (грузит alm_map.gd/_load_sidecars).
func _save_sidecars() -> void:
	var f := FileAccess.open(_out_dir + _basename + ".structures.json", FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify({"structures": _structures_out}))
		f.close()
	var n := FileAccess.open(_out_dir + _basename + ".npcs.json", FileAccess.WRITE)
	if n:
		# gen_version — чтобы ensure_map перегенерировал карту после правки
		# настроек генерации (плотность, зазоры, разведение). См. GEN_VERSION.
		n.store_string(JSON.stringify({"npcs": _npcs_out, "gen_version": GEN_VERSION}))
		n.close()
	var h := FileAccess.open(_out_dir + _basename + ".herbs.json", FileAccess.WRITE)
	if h:
		h.store_string(JSON.stringify({"herbs": _herbs_out}))
		h.close()
	# Форпосты (пакет B): отдельный sidecar, чтобы игра знала, ЧЬИ лагеря на
	# карте и сколько стражи осталось до захвата.
	var o := FileAccess.open(_out_dir + _basename + ".outposts.json", FileAccess.WRITE)
	if o:
		o.store_string(JSON.stringify({"outposts": _outposts_out}))
		o.close()

func _validate_city_content() -> void:
	var required := ["shop", "inn", "blacksmith", "train", "druidshop"]
	var missing: Array = []
	for prefix in required:
		var count := 0
		for structure in _structures_out:
			var folder := str(StructureDB.get_by_id(int(structure.get("type_id", 0))).get("folder", ""))
			if folder.begins_with(prefix):
				count += 1
		if count < _cities.size():
			missing.append("%s=%d/%d" % [prefix, count, _cities.size()])
	print("CITY_CONTENT: missing=%s" % str(missing))

func _road_stats(road_cells: int) -> void:
	# Компоненты связности дороги (4-соседи)
	var seen := {}
	var comps: Array = []
	for y in range(H):
		for x in range(W):
			var idx: int = y * W + x
			if seen.has(idx) or _terrain[idx] != 3:
				continue
			var size := 0
			var st: Array = [Vector2i(x, y)]
			seen[idx] = true
			while not st.is_empty():
				var p: Vector2i = st.pop_back()
				size += 1
				for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
					var n: Vector2i = p + d
					if n.x < 0 or n.y < 0 or n.x >= W or n.y >= H:
						continue
					var nk: int = n.y * W + n.x
					if seen.has(nk) or _terrain[nk] != 3:
						continue
					seen[nk] = true
					st.push_back(n)
			comps.append(size)
	comps.sort()
	comps.reverse()
	# bbox главного компонента и ширина дороги
	var main_bbox := Rect2i()
	var main_flat := 0
	var width_cnt := {}
	var adj_cnt := {}
	if not comps.is_empty():
		var ms := 0
		for y in range(H):
			for x in range(W):
				var idx: int = y * W + x
				if _terrain[idx] != 3:
					continue
				if ms == 0:
					main_bbox = Rect2i(Vector2i(x, y), Vector2i(1, 1))
					ms = 1
				else:
					if x < main_bbox.position.x:
						main_bbox.position.x = x
					if y < main_bbox.position.y:
						main_bbox.position.y = y
					if x - main_bbox.position.x + 1 > main_bbox.size.x:
						main_bbox.size.x = x - main_bbox.position.x + 1
					if y - main_bbox.position.y + 1 > main_bbox.size.y:
						main_bbox.size.y = y - main_bbox.position.y + 1
		# ширина: сколько дорожных клеток в колонке bbox (гориз. маршрут) или строке
		for y in range(main_bbox.position.y, main_bbox.position.y + main_bbox.size.y):
			var cnt := 0
			for x in range(main_bbox.position.x, main_bbox.position.x + main_bbox.size.x):
				if _terrain[y * W + x] == 3:
					cnt += 1
			if cnt > 0:
				width_cnt[cnt] = width_cnt.get(cnt, 0) + 1
				main_flat += cnt
		# примыкание: доля соседей дороги по terrain
		for y in range(H):
			for x in range(W):
				var idx: int = y * W + x
				if _terrain[idx] != 3:
					continue
				for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
					var n: Vector2i = Vector2i(x, y) + d
					if n.x < 0 or n.y < 0 or n.x >= W or n.y >= H:
						continue
					var nt: int = _terrain[n.y * W + n.x]
					if nt != 3 and nt != -1:
						adj_cnt[nt] = adj_cnt.get(nt, 0) + 1
	print("ROAD: cells=%d comps=%s bbox=%s widths=%s adj=%s" % [
		road_cells, str(comps), str(main_bbox), str(width_cnt), str(adj_cnt)])

func _write_alm() -> PackedByteArray:
	# Полный writer теперь один — в AlmLoader (его же зовёт редактор карт).
	return AlmLoader.build_map_bytes(W, H, _tiles, _heights, _obstacles, _map_name)
