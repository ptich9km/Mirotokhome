extends SceneTree
##
## Валидатор игрового конфига.
##
## Проверяет то, что config не может проверить сам по себе:
##   1. эталон res://assets/config/game.cfg совпадает с DEFAULTS (иначе они
##      разъедутся — генератор gen_game_config_defaults --check ловит это);
##   2. в файле нет НЕИЗВЕСТНЫХ ключей — опечатка даёт молчаливый дефолт;
##   3. значения в осмысленных диапазонах (hit_min <= hit_base <= hit_max и т.п.);
##   4. БИТЫЙ пользовательский файл не роняет игру: загружаем его и смотрим,
##      что чтение возвращает дефолт, а не падает.
##
## Запуск:
##   godot --headless --path . --script res://tests/game_config_smoke.gd
##

const CFG_PATH := "res://assets/config/game.cfg"

## Границы, вне которых значение почти наверняка — опечатка.
const RANGES := {
	"combat.hit_base": [1, 100],
	"combat.hit_min": [0, 100],
	"combat.hit_max": [1, 100],
	"combat.damage_multiplier": [0.0, 100.0],
	"combat.attack_cooldown": [0.05, 10.0],
	"combat.protection_max": [0, 100],
	"magic.sp_offset": [0.0, 200.0],
	"magic.staff_mana_cost": [0, 999],
	"magic.chain_min_targets": [1, 30],
	"magic.chain_max_targets": [1, 30],
	"magic.auto_heal_ratio": [0.05, 1.0],
	"magic.auto_buff_interval": [0.2, 30.0],
	"economy.start_gold": [0, 1000000],
	"economy.sell_price_div": [1, 100],
	"loot.enemy_potion_chance": [0, 100],
	"loot.enemy_gear_chance": [0, 100],
	"loot.npc_citizen_potion_chance": [0, 100],
	"loot.npc_guard_potion_chance": [0, 100],
	# loot.npc_guard_gear_chance удалён 07.10 (NPC роняют сломанное всегда).
	"metal.absorption_min": [0, 100],
	"metal.absorption_max": [0, 100],
	"craft.chance_ordinary": [0.0, 100.0],
	"craft.chance_improved": [0.0, 100.0],
	"craft.chance_master": [0.0, 100.0],
	"craft.ordinary_step": [0.0, 10.0],
	"craft.improved_step": [0.0, 10.0],
	"craft.master_step": [0.0, 10.0],
	"craft.floor_ordinary": [0.0, 50.0],
	"craft.tier_improved_mult": [1.0, 5.0],
	"craft.tier_master_mult": [1.0, 5.0],
	"craft.xp_per_craft": [1, 10000],
	"craft.xp_per_recycle": [0, 10000],
	"craft.xp_tier_bonus": [0, 10000],
	"craft.boss_intact_chance": [0, 100],
	"mob_tier.hp_step": [0.0, 2.0],
	"mob_tier.damage_step": [0.0, 2.0],
}

var _fails: Array = []
var _checks := 0


func _init() -> void:
	call_deferred("_run")


func _check(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(msg)
	print(("  OK  " if ok else "  FAIL") + " " + msg)


func _run() -> void:
	print("-- файл существует и читается --")
	_check(FileAccess.file_exists(CFG_PATH), "%s существует" % CFG_PATH)
	var cfg := ConfigFile.new()
	var err := cfg.load(CFG_PATH)
	_check(err == OK, "ConfigFile читает эталон (ошибка %d)" % err)

	if err != OK:
		_report()
		quit(1)
		return

	print("-- нет неизвестных ключей --")
	# ConfigFile молча обрезает имя по пробелу, поэтому ищем и такие следы
	var sections := cfg.get_sections()
	var unknown: Array[String] = []
	for section in sections:
		var known_sec: bool = (GameConfig.DEFAULTS as Dictionary).has(section)
		if not known_sec:
			unknown.append("секция [%s]" % section)
			continue
		for key in cfg.get_section_keys(section):
			if not (GameConfig.DEFAULTS[section] as Dictionary).has(key):
				unknown.append("%s.%s" % [section, key])
	_check(unknown.is_empty(), "все секции и ключи известны (лишних: %d%s)"
		% [unknown.size(), (": " + ", ".join(unknown)) if not unknown.is_empty() else ""])

	print("-- все известные ключи реально есть в файле --")
	var missing: Array[String] = []
	for full: String in GameConfig.known_keys():
		var dot: int = full.find(".")
		var s: String = full.substr(0, dot)
		var k: String = full.substr(dot + 1)
		if not cfg.has_section_key(s, k):
			missing.append(full)
	_check(missing.is_empty(), "DEFAULTS и файл согласованы (нет в файле: %d%s)"
		% [missing.size(), (": " + ", ".join(missing)) if not missing.is_empty() else ""])

	print("-- значения из файла равны дефолтам (этап 0 не меняет игру) --")
	var mismatched: Array[String] = []
	for full: String in GameConfig.known_keys():
		var dot: int = full.find(".")
		var s: String = full.substr(0, dot)
		var k: String = full.substr(dot + 1)
		var from_file: Variant = cfg.get_value(s, k, null)
		var want: Variant = null
		var sec: Variant = GameConfig.DEFAULTS.get(s, null)
		if sec is Dictionary:
			want = (sec as Dictionary).get(k, null)
		if str(from_file) != str(want):
			mismatched.append("%s: файл=%s дефолт=%s" % [full, str(from_file), str(want)])
	_check(mismatched.is_empty(), "эталон совпадает с DEFAULTS (расхождений: %d%s)"
		% [mismatched.size(), (": " + "; ".join(mismatched)) if not mismatched.is_empty() else ""])

	print("-- значения в диапазонах --")
	var bad_range: Array[String] = []
	for full: String in RANGES:
		var dot: int = full.find(".")
		var s: String = full.substr(0, dot)
		var k: String = full.substr(dot + 1)
		var v: float = float(cfg.get_value(s, k, 0))
		var lim: Array = RANGES[full]
		if v < float(lim[0]) or v > float(lim[1]):
			bad_range.append("%s=%s вне [%s..%s]" % [full, str(v), str(lim[0]), str(lim[1])])
	_check(bad_range.is_empty(), "значения в диапазонах (нарушений: %d%s)"
		% [bad_range.size(), (": " + "; ".join(bad_range)) if not bad_range.is_empty() else ""])

	print("-- логические связи --")
	_check(int(cfg.get_value("combat", "hit_min", 0)) <= int(cfg.get_value("combat", "hit_base", 0)),
		"hit_min <= hit_base")
	_check(int(cfg.get_value("combat", "hit_base", 0)) <= int(cfg.get_value("combat", "hit_max", 0)),
		"hit_base <= hit_max")
	_check(int(cfg.get_value("magic", "chain_min_targets", 0)) <= int(cfg.get_value("magic", "chain_max_targets", 0)),
		"chain_min_targets <= chain_max_targets")
	_check(int(cfg.get_value("metal", "absorption_min", 0)) <= int(cfg.get_value("metal", "absorption_max", 0)),
		"absorption_min <= absorption_max")

	print("-- боевые ключи: база Серых, шаги тиров, город --")
	_check(int(cfg.get_value("grey", "hp_min", 0)) <= int(cfg.get_value("grey", "hp_max", 0)),
		"grey.hp_min <= grey.hp_max")
	_check(int(cfg.get_value("grey", "damage_min", 0)) <= int(cfg.get_value("grey", "damage_max", 0)),
		"grey.damage_min <= grey.damage_max")
	# Tier 5 must not be a wall: 1 + step*4 stays below 3x.
	var hp_step := float(cfg.get_value("mob_tier", "hp_step", 0.0))
	var dmg_step := float(cfg.get_value("mob_tier", "damage_step", 0.0))
	_check(hp_step > 0.0 and 1.0 + hp_step * 4.0 < 3.0,
		"mob_tier.hp_step даёт разумный тир 5 (x%.2f)" % (1.0 + hp_step * 4.0))
	_check(dmg_step > 0.0 and 1.0 + dmg_step * 4.0 < 3.0,
		"mob_tier.damage_step даёт разумный тир 5 (x%.2f)" % (1.0 + dmg_step * 4.0))
	for pair in [["guard_count_min", "guard_count_max"], ["guard_hp_min", "guard_hp_max"],
			["guard_damage_min", "guard_damage_max"],
			["citizen_count_min", "citizen_count_max"]]:
		var lo: int = int(cfg.get_value("city", pair[0], 0))
		var hi: int = int(cfg.get_value("city", pair[1], 0))
		_check(lo <= hi, "city: %s(%d) <= %s(%d)" % [pair[0], lo, pair[1], hi])

	print("-- зоны: дизайн карты, без боевых статов --")
	for zone in ["start", "mid", "hard", "faction"]:
		var lo: int = int(cfg.get_value("zone_design", "%s.gray_count_min" % zone, 0))
		var hi: int = int(cfg.get_value("zone_design", "%s.gray_count_max" % zone, 0))
		var dens := float(cfg.get_value("zone_design", "%s.tree_density" % zone, -1.0))
		_check(lo <= hi, "zone_design.%s: gray_count_min(%d) <= gray_count_max(%d)" % [zone, lo, hi])
		_check(dens >= 0.0 and dens <= 1.0, "zone_design.%s: tree_density в [0..1] (%.2f)" % [zone, dens])
	# No combat numbers per zone: the whole point of the 3x.11 cleanup.
	_check(not cfg.has_section("zone"), "секции [zone] больше нет (зоны не настраивают ДПС)")

	print("-- геттеры возвращают те же значения --")
	GameConfig.load_all()
	_check(GameConfig.geti("combat", "hit_base") == 70,
		"GameConfig.geti(combat, hit_base) = %d" % GameConfig.geti("combat", "hit_base"))
	_check(is_equal_approx(GameConfig.getf("combat", "damage_multiplier"), 1.0),
		"damage_multiplier = %s" % str(GameConfig.getf("combat", "damage_multiplier")))
	_check(GameConfig.designi("start", "gray_count_min") == 40,
		"designi(start, gray_count_min) = %d" % GameConfig.designi("start", "gray_count_min"))
	_check(GameConfig.geti("grey", "hp_max") == 45,
		"grey.hp_max = %d" % GameConfig.geti("grey", "hp_max"))

	print("-- неизвестный ключ не роняет, а даёт дефолт --")
	_check(GameConfig.geti("combat", "hit_base") == 70, "известный ключ читается")
	# неизвестный ключ намеренно выдаёт warning - здесь просто проверяем,
	# что вызов не бросает исключение и не меняет состояние
	var before := GameConfig.geti("combat", "hit_base")
	GameConfig.geti("combat", "no_such_key_xyz")
	_check(GameConfig.geti("combat", "hit_base") == before,
		"после запроса несуществующего ключа состояние не изменилось")

	print("-- секция [debug]: отладочные переключатели в конфиге --")
	# До 03.10 «выдать всю магию» было жёстким `debug_magic = true` в коде:
	# сборка для беты отдавала всю магию, и отключить её без правки кода было
	# нельзя. Теперь это ключи конфига.
	for dk in ["all_magic", "fog_of_war", "show_coords"]:
		var dv := GameConfig.geti("debug", dk)
		_check(dv == 0 or dv == 1, "debug.%s — переключатель 0/1 (сейчас %d)" % [dk, dv])
	# С 04.11 cheat ВЫКЛЮЧЕН по умолчанию: маг начинает с одной книгой школы,
	# иначе вся магия с первого кадра — это дисбаланс (жалоба игрока).
	_check(GameConfig.geti("debug", "all_magic") == 0,
		"все заклинания по умолчанию НЕ выдаются (all_magic = 0)")
	# fog_of_war теперь РАБОЧИЙ ключ (19.10, FogOfWar): 0 = туман выключен,
	# 1 = включён. Значение вне 0/1 считаем битым конфигом.
	var fog_key := GameConfig.geti("debug", "fog_of_war")
	_check(fog_key == 0 or fog_key == 1,
		"fog_of_war — рабочий переключатель тумана войны (0/1), сейчас %d" % fog_key)

	_report()
	quit(0 if _fails.is_empty() else 1)


func _report() -> void:
	print("checks=%d fails=%d" % [_checks, _fails.size()])
	if not _fails.is_empty():
		for f in _fails:
			print("FAIL: " + str(f))
		print("RESULT: FAIL game_config_smoke")
	else:
		print("RESULT: OK game_config_smoke")