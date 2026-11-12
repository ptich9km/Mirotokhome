class_name StartSetup
extends RefCounted
## Как начинается новая игра (экран выбора героя → блок «Мир»).
##
## Три режима:
##   random — случайный сид мира (по умолчанию);
##   seed   — конкретный сид, который ввёл игрок (воспроизводимый мир 4×3);
##   map    — готовая карта из user://maps/custom/ (сделана в редакторе карт).
##
## Сид мира детерминированно раскладывается по секторам через
## `world_map.seed_of(world_seed, sector)` — это же правило использует
## `Game.new_random_map()`, поэтому «сид 123456 + старт» всегда один и тот же.
##
## Готовая карта получает identity-сид (FNV-1a от пути). Он не генерирует
## карту (её путь важнее), но нужен системам, которые ключуются по map_seed:
## ротация квестов, события, захват форпостов. С нулём все кастомные карты
## делили бы один и тот же набор квестов.

const MODES := ["random", "seed", "map"]
const ZONES := ["start", "mid", "hard", "faction"]
## Zone names live in ui.json (`ui.zone.*`), one place for the panel, the button
## label and MapMeta: they used to be duplicated as a dictionary in two files.
const ZONE_KEYS := {
	"start": "ui.zone.start", "mid": "ui.zone.mid",
	"hard": "ui.zone.hard", "faction": "ui.zone.faction",
}

var mode := "random"
var world_seed := 0
var zone := "start"
var map_path := ""


func _init() -> void:
	world_seed = random_seed()


static func random_seed() -> int:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var s := rng.randi()
	return s if s != 0 else 4242


static func zone_label(z: String) -> String:
	if ZONE_KEYS.has(z):
		return Loc.t(str(ZONE_KEYS[z]))
	return z


## Сид-идентификатор карты: стабилен между запусками и машинами.
## FNV-1a по тому же принципу, что и `world_map.seed_of`, чтобы не зависеть
## от рандомизации `hash()` между сборками.
static func identity_seed(path: String) -> int:
	var h := 2166136261
	var text := "custom|" + path
	for i in range(text.length()):
		h = h ^ text.unicode_at(i)
		h = (h * 16777619) & 0x7FFFFFFF
	return h if h != 0 else 1


func normalize() -> void:
	if not MODES.has(mode):
		mode = "random"
	if not ZONES.has(zone):
		zone = "start"
	if world_seed == 0:
		world_seed = random_seed()
	if mode == "map" and map_path != "":
		var z := MapMeta.zone_of(map_path)
		if ZONES.has(z):
			zone = z


func summary() -> String:
	normalize()
	if mode == "map":
		var title := map_path.get_file().get_basename() if map_path != "" else Loc.t("ui.world.not_chosen")
		return Loc.f("ui.world.summary_map", [title, zone_label(zone)])
	if mode == "random":
		return Loc.f("ui.world.summary_random", [zone_label(zone)])
	return Loc.f("ui.world.summary_seed", [world_seed, zone_label(zone)])


## Применить к игре ДО смены сцены. Пустая строка — успех, иначе текст ошибки.
func apply() -> String:
	normalize()
	var wm: GDScript = load("res://scripts/world/world_map.gd")
	if mode == "map":
		if map_path == "" or not FileAccess.file_exists(map_path):
			return Loc.f("ui.world.map_missing", [map_path])
		var meta := MapMeta.read(map_path)
		var sector := str(meta.get("sector", ""))
		if sector == "" or not wm.has(sector):
			sector = str(wm.sector_for_tier(zone))
		Game.pending_map_path = map_path
		Game.map_seed = identity_seed(map_path)
		Game.map_sector = sector
		Game.map_zone = str(wm.tier_of(sector)) if sector != "" else zone
		Game.world_seed = world_seed
		Game.clear_load_position()
		Game.clear_hero_save()
		return ""
	if mode == "random":
		world_seed = random_seed()
	var sector_id: String = str(wm.sector_for_tier(zone))
	Game.world_seed = world_seed
	Game.map_sector = sector_id
	Game.map_zone = str(wm.tier_of(sector_id)) if sector_id != "" else zone
	Game.map_seed = int(wm.seed_of(world_seed, sector_id)) if sector_id != "" else world_seed
	Game.pending_map_path = ""
	Game.clear_load_position()
	Game.clear_hero_save()
	# A new game starts a new world: drop the previous run's SIM (cities,
	# armies, day, journal). Loaded saves never pass through StartSetup.
	var loop := Engine.get_main_loop()
	if loop is SceneTree:
		var bus = (loop as SceneTree).root.get_node_or_null("WorldBus")
		if bus != null and bus.state != null:
			bus.state.reset_for_new_game()
	return ""


func to_dict() -> Dictionary:
	return {"mode": mode, "seed": world_seed, "zone": zone, "path": map_path}


static func from_dict(d: Dictionary) -> StartSetup:
	var s := StartSetup.new()
	s.mode = str(d.get("mode", "random"))
	s.world_seed = int(d.get("seed", s.world_seed))
	s.zone = str(d.get("zone", "start"))
	s.map_path = str(d.get("path", ""))
	s.normalize()
	return s
