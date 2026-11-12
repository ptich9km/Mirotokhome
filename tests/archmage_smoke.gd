extends SceneTree
## Смоук пакета 3.0 «Великий маг» — шаги TDD 2–4 (Lore, tick, WorldState/Bus).
##
## Проверяет то, что сломается молча:
##  * Lore читает оба JSON и маппит human <-> humans.
##  * TickArchmage: спад = decay_base + decay_threat*threat за тик, power не < 0.
##  * Сходимость с tests/sim_archmage_stakes.py (threat 0 / 0.5 / 1).
##  * new_faction рисует archmage из Lore+GameConfig; get_archmage по расе героя.
##  * Старый мир без archmage -> get_archmage = {}, без ошибки.
##  * Сдача (add_archmage_power) списывает tier один раз, power clamp 0..100.
##  * WorldBus.archmage_tick: по interval тиков power падает, журнал растёт.
##
## Запуск: godot --headless --path . --script res://tests/archmage_smoke.gd

const CFG_PATH := "res://assets/config/game.cfg"
const WORLD_PATH := "res://assets/lore/world.json"
const NPCS_PATH := "res://assets/lore/npcs.json"

const WorldStateSc := preload("res://scripts/world/world_state.gd")
const WorldSimSc := preload("res://scripts/world/world_sim.gd")

var _fails: Array[String] = []
var _checks := 0


func _initialize() -> void:
	call_deferred("_run")


func _check(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(msg)
	print(("  OK  " if ok else "  FAIL") + " " + msg)


func _run() -> void:
	print("-- Lore --")
	_lore_files()
	_lore_race_map()
	_lore_archmages()

	print("-- TickArchmage (формула) --")
	_tick_formula()
	_tick_matches_stakes_py()

	print("-- WorldState --")
	_new_faction_has_archmage()
	_ensure_race_factions()
	_get_archmage_by_race()
	_old_save_without_archmage()
	_add_power_and_tier()

	print("-- WorldBus.archmage_tick --")
	_bus_tick_decay()

	_report()
	quit(0 if _fails.is_empty() else 1)


func _report() -> void:
	print()
	if _fails.is_empty():
		print("RESULT: OK archmage_smoke checks=%d" % _checks)
	else:
		print("RESULT: FAIL archmage_smoke checks=%d fails=%d" % [_checks, _fails.size()])
		for m in _fails:
			print("  - %s" % m)


# --- Lore ----------------------------------------------------------------------

func _lore_files() -> void:
	_check(FileAccess.file_exists(WORLD_PATH), "%s существует" % WORLD_PATH)
	_check(FileAccess.file_exists(NPCS_PATH), "%s существует" % NPCS_PATH)
	Lore.clear_cache()
	_check(Lore.world().size() > 0, "world.json непустой")
	_check(Lore.npcs().size() > 0, "npcs.json непустой")


func _lore_race_map() -> void:
	_check(Lore.hero_race_to_faction("human") == "humans", "human -> humans")
	_check(Lore.hero_race_to_faction("ork") == "ork", "ork -> ork")
	_check(Lore.faction_to_hero_race("humans") == "human", "humans -> human")
	_check(Lore.faction_city("human") == Loc.field(Lore.faction("humans"), "city"),
		"город людей = Небесный покой (=%s)" % Lore.faction_city("human"))
	_check(Lore.faction_archmage("human") == Loc.field(Lore.faction("humans"), "archmage"),
		"маг людей = Маша (=%s)" % Lore.faction_archmage("human"))


func _lore_archmages() -> void:
	for race in ["human", "ork", "necro", "druid"]:
		var mname := Lore.faction_archmage(race)
		var city := Lore.faction_city(race)
		_check(mname != "", "%s: имя мага из world.json" % race)
		_check(city != "", "%s: город из world.json" % race)
		var n := Lore.archmage_npc(race)
		_check(not n.is_empty(), "%s: NPC-маг в npcs.json" % race)
		var greet: Array = Lore.archmage_speech(race, "greet")
		_check(greet.size() > 0, "%s: greet-реплики" % race)
	var seed_d := Lore.archmage_seed("human")
	_check(str(seed_d.get("name", "")) == Loc.field(Lore.faction("humans"), "archmage"),
		"seed human.name из world.json")
	_check(str(seed_d.get("city", "")) == Loc.field(Lore.faction("humans"), "city"),
		"seed human.city из world.json")


# --- TickArchmage --------------------------------------------------------------

func _cfg_f(key: String) -> float:
	var cfg := ConfigFile.new()
	if cfg.load(CFG_PATH) != OK:
		return 0.0
	return float(cfg.get_value("archmage", key, 0.0))


func _tick_formula() -> void:
	var w = WorldStateSc.new()
	var sim = WorldSimSc.new(w)
	var base := _cfg_f("decay_base")
	var per := _cfg_f("decay_threat")
	_check(base > 0.0 and per > 0.0, "decay_base/threat > 0 в game.cfg")
	var p0 := 60.0
	var got0: float = sim.TickArchmage(p0, 0.0)
	var exp0: float = p0 - base
	_check(absf(got0 - exp0) < 0.0001,
		"threat=0: 60 -> %.4f (ожидал %.4f)" % [got0, exp0])
	var got1: float = sim.TickArchmage(p0, 1.0)
	var exp1: float = p0 - (base + per)
	_check(absf(got1 - exp1) < 0.0001,
		"threat=1: 60 -> %.4f (ожидал %.4f)" % [got1, exp1])
	# power не уходит ниже 0
	var deep: float = sim.TickArchmage(0.0001, 1.0)
	_check(deep >= 0.0, "power не < 0 (=%.6f)" % deep)
	# монотонность: больший threat => больший спад
	_check(got1 < got0, "threat=1 даёт меньший power, чем threat=0")


func _tick_matches_stakes_py() -> void:
	# Сходимость с python-моделью: 1000 тиков (20 с) при threat 0.5, без сдачи.
	# power_1000 = 60 - 1000 * (base + per*0.5)
	var w = WorldStateSc.new()
	var sim = WorldSimSc.new(w)
	var power := 60.0
	var threat := 0.5
	for _i in 1000:
		power = sim.TickArchmage(power, threat)
	var d := _cfg_f("decay_base") + _cfg_f("decay_threat") * threat
	var exp: float = maxf(0.0, 60.0 - 1000.0 * d)
	_check(absf(power - exp) < 0.01,
		"1000 тиков threat=0.5: power=%.3f exp=%.3f" % [power, exp])
	# «часов без сдачи» из GDD: 60 / d * 20 / 3600
	var hours := 60.0 / d * 20.0 / 3600.0
	_check(hours > 200.0 and hours < 400.0,
		"часов без сдачи при threat=0.5 в коридоре GDD (=%.1f)" % hours)
	# Ставки платы: читаемые ключи [archmage] (потребитель — панель шага 7)
	_check(absf(WorldStateSc.archmage_stake("ingot") - 1.0) < 0.001,
		"stake_ingot = 1.0 (=%s)" % WorldStateSc.archmage_stake("ingot"))
	_check(absf(WorldStateSc.archmage_stake("potion") - 1.5) < 0.001,
		"stake_potion = 1.5 (=%s)" % WorldStateSc.archmage_stake("potion"))
	_check(WorldStateSc.archmage_gold_per_stake() == 100,
		"gold_per_stake = 100 (=%d)" % WorldStateSc.archmage_gold_per_stake())


# --- WorldState ----------------------------------------------------------------

func _new_faction_has_archmage() -> void:
	var w = WorldStateSc.new()
	var f: Dictionary = w.new_faction("Люди", "human")
	var am: Dictionary = f.get("archmage", {})
	_check(not am.is_empty(), "new_faction кладёт archmage")
	_check(str(am.get("name", "")) == Loc.field(Lore.faction("humans"), "archmage"),
		"archmage.name (=%s)" % am.get("name"))
	_check(str(am.get("city", "")) == Loc.field(Lore.faction("humans"), "city"),
		"archmage.city")
	_check(f.get("race", "") == "human", "faction.race = human")
	var power_start := _cfg_f("power_start")
	_check(absf(float(am.get("power", -1)) - power_start) < 0.001,
		"archmage.power = power_start (%.1f)" % power_start)
	var tier := int(am.get("tier", -1))
	_check(tier >= 0 and tier <= 3, "archmage.tier в 0..3 (=%d)" % tier)
	# без race архмаг-словарь есть, но без имени
	var f2: Dictionary = w.new_faction("Без расы")
	var am2: Dictionary = f2.get("archmage", {})
	_check(am2 is Dictionary, "archmage без race — словарь, не null")
	_check(float(am2.get("power", 0)) > 0.0, "без race power из GameConfig")


## 28.10: у нежити и друидов не было великого мага, потому что WorldState
## создавал только людей и орков. ensure_race_factions добивает четыре расы и
## не дублирует старую фракцию, записанную как "human".
func _ensure_race_factions() -> void:
	var w = WorldStateSc.new()
	_check(w.ensure_race_factions() == 4, "ensure_race_factions создаёт 4 фракции")
	for race in ["humans", "ork", "necro", "druid"]:
		var am: Dictionary = w.get_archmage(str(race))
		_check(not am.is_empty(), "get_archmage(%s) не пуст" % str(race))
	_check(w.ensure_race_factions() == 0, "повторный вызов ничего не добавляет")
	var legacy = WorldStateSc.new()
	legacy.new_faction("Люди", "human")
	var legacy_added: int = legacy.ensure_race_factions()
	_check(legacy_added == 3,
		"старая фракция race=human не дублируется (добавлено %d)" % legacy_added)


func _get_archmage_by_race() -> void:
	var w = WorldStateSc.new()
	w.new_faction("Люди", "human")
	w.new_faction("Орки", "ork")
	var by_race: Dictionary = w.get_archmage("human")
	_check(str(by_race.get("name", "")) == Loc.field(Lore.faction("humans"), "archmage"),
		"get_archmage(\"human\") = Маша (=%s)" % by_race.get("name"))
	var by_ork: Dictionary = w.get_archmage("ork")
	_check(str(by_ork.get("name", "")) == Loc.field(Lore.faction("ork"), "archmage"),
		"get_archmage(\"ork\") = Леша (=%s)" % by_ork.get("name"))
	# lore-ключ
	var by_lore: Dictionary = w.get_archmage("humans")
	_check(str(by_lore.get("name", "")) == Loc.field(Lore.faction("humans"), "archmage"),
		"get_archmage(\"humans\") тоже работает")
	# несуществующая раса
	var none: Dictionary = w.get_archmage("dragon")
	_check(none.is_empty(), "несуществующая раса -> {}")


func _old_save_without_archmage() -> void:
	var w = WorldStateSc.new()
	var id := w._id("f")
	w.factions[id] = { "id": id, "name": "Старая", "color": Color(1, 1, 1), "relations": {} }
	var am: Dictionary = w.get_archmage("Старая")
	_check(am.is_empty(), "фракция без archmage -> {}")
	var n: int = w.add_archmage_power("Старая", 5.0)
	_check(n == 0, "add_archmage_power без мага -> 0")
	# from_dict без archmage
	var ws2 = WorldStateSc.from_dict({ "factions": { "f-1": { "id": "f-1", "name": "X" } } })
	var am2: Dictionary = ws2.get_archmage("f-1")
	_check(am2.is_empty(), "from_dict старого мира -> {}")


func _add_power_and_tier() -> void:
	var w = WorldStateSc.new()
	var f: Dictionary = w.new_faction("Люди", "human")
	var am: Dictionary = f.get("archmage", {})
	var p0 := float(am.get("power", 0))
	var t0 := int(am.get("tier", 1))
	# мелкая сдача: power растёт, tier не обязан меняться
	var d0: int = w.add_archmage_power("human", 0.1)
	_check(absf(float(f.get("archmage", {}).get("power", 0)) - (p0 + 0.1)) < 0.001,
		"power +0.1")
	# большая сдача: tier обязан вырасти (60 -> 100 => tier 3)
	var d1: int = w.add_archmage_power("human", 100.0)
	var am1: Dictionary = f.get("archmage", {})
	_check(float(am1.get("power", 0)) <= 100.0 + 0.001, "power clamp <= 100")
	_check(int(am1.get("tier", 0)) == 3, "tier 3 при power=100 (=%s)" % am1.get("tier"))
	_check(d1 == 3 - t0 or d1 == 3 - int(am.get("tier", t0)),
		"add_archmage_power вернул смену tier (=%d)" % d1)
	_check(str(am1.get("stance", "")) == "offensive", "stance offensive на 100")
	# повторная сдача при 100: power не растёт
	w.add_archmage_power("human", 50.0)
	var am2: Dictionary = f.get("archmage", {})
	_check(absf(float(am2.get("power", 0)) - 100.0) < 0.001, "power не > 100")


# --- WorldBus ------------------------------------------------------------------

func _bus_tick_decay() -> void:
	var bus_script: GDScript = load("res://scripts/world/world_bus.gd")
	var bus = bus_script.new()
	# _ready не вызывается сам — дёргаем вручную как в игре
	bus._ready()
	bus.reset_archmage_timer()
	var am0: Dictionary = bus.state.get_archmage("human")
	_check(not am0.is_empty(), "bus.state: архмаг human на месте")
	var p0 := float(am0.get("power", 0))
	var j0: int = bus.state.journal.size()
	# один интервал = ровно один тик спада
	var interval := _cfg_f("sim_interval")
	var n: int = bus.archmage_tick(interval)
	_check(n == 1, "archmage_tick(interval) == 1 (=%d)" % n)
	var am1: Dictionary = bus.state.get_archmage("human")
	var p1 := float(am1.get("power", 0))
	var d := _cfg_f("decay_base") + _cfg_f("decay_threat") * float(bus.state.global_threat)
	_check(absf(p1 - maxf(0.0, p0 - d)) < 0.001,
		"после 1 тика power %.3f -> %.3f (decay %.4f)" % [p0, p1, d])
	# полсекунды — тика нет
	var n2: int = bus.archmage_tick(interval * 0.4)
	_check(n2 == 0, "неполный интервал не тикает (=%d)" % n2)
	# сим tick() НЕ трогает магов (только реальное время)
	var p_before := float(bus.state.get_archmage("human").get("power", 0))
	bus.advance(5)
	var p_after := float(bus.state.get_archmage("human").get("power", 0))
	_check(absf(p_after - p_before) < 0.001,
		"sim.tick() 5 дней не меняет power мага (%.3f vs %.3f)" % [p_before, p_after])
	_check(bus.state.journal.size() >= j0, "журнал не уменьшился")
	# мутация-контроль: если бы decay был 0, power не упал бы — здесь уже доказано падение
	_check(p1 < p0 or d <= 0.0, "power упал или decay=0")
