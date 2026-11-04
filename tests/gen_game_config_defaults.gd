extends SceneTree
##
## Генератор эталона конфига: res://assets/config/game.cfg из DEFAULTS.
##
## Зачем он, если DEFAULTS и так лежат в коде: чтобы файл в репозитории был
## ЧИТАЕМЫМ и не расходился с кодом. Файл собирается из одного источника
## правды, значит синхронизация не может «разъехаться» — при добавлении ключа
## достаточно дописать его в DEFAULTS и прогнать этот скрипт.
##
## Комментарии в .cfg пишутся через `;` — ConfigFile их понимает, а `#`
## не понимает (проверено по документации Godot 4.7). Сам ConfigFile комментарии
## при сохранении теряет, поэтому шапка и пояснения дописываются текстом.
##
## Запуск:
##   godot --headless --path . --script res://tests/gen_game_config_defaults.gd
##   godot --headless --path . --script res://tests/gen_game_config_defaults.gd -- --check
##

const OUT := "res://assets/config/game.cfg"

## Пояснения к ключам: секция -> ключ -> строка комментария.
## Пустое значение означает «комментарий не нужен».
const NOTES := {
	"combat.hit_base": "база попадания, %",
	"combat.hit_soften": "смягчение: шанс = base*(att+soft)/(def+soft)",
	"combat.damage_multiplier": "ГЛОБАЛЬНЫЙ множитель урона (идея из AION)",
	"combat.attack_cooldown": "ранее продублировано 1.0 в enemy/mercenary/npc",
	"combat.enemy_defense_div": "защита врага = max_hp / это",
	"combat.enemy_attack_dmg_div": "атака врага = damage / это + max_hp / enemy_attack_hp_div",
	"combat.enemy_attack_hp_div": "атака врага = damage / enemy_attack_dmg_div + max_hp / это",
	"combat.enemy_absorption_div": "поглощение врага = max_hp / это",
	"combat.protection_max": "потолок сопротивления стихии, %",
	"magic.sp_offset": "SP = навык + разум - это",
	"magic.auto_heal_ratio": "авто-лечение при HP/макс ниже порога",
	"magic.auto_buff_interval": "сек между проверками авто-баффов",
	"economy.start_gold": "СТАРТОВОЕ ЗОЛОТО. Сейчас 20, а оружие стоит 150-600.",
	"economy.sell_price_div": "продажа в магазине = цена / это",
	"spawn.tree_density": "плотность деревьев на карте",
	"grey.hp_min": "база HP Серых тира 1; тир усиливает шагом mob_tier.hp_step",
	"grey.damage_min": "база урона Серых тира 1",
	"mob_tier.hp_step": "прирост HP за тир: x1.0 (тир 1) … x2.4 (тир 5)",
	"mob_tier.damage_step": "прирост урона за тир: x1.0 … x2.0",
	"city.guard_count_min": "стражей на город",
	"city.guard_hp_min": "городские NPC одинаковы во всех зонах",
	"city.citizen_count_min": "жителей на город",
	"poi.count": "точек интереса на карту; 0 = выключено (мало арта)",
	"zone_design.start.gray_count_min": "дизайн карты, а не боевой рейт: сколько Серых на карте",
	"zone_design.start.tree_density": "плотность деревьев",
	"craft.chance_ordinary": "шанс обычной вещи на навыке 0, %",
	"craft.floor_ordinary": "обычная вещь не опускается ниже этого шанса, %",
	"craft.tier_improved_mult": "множитель характеристик улучшенной вещи",
	"craft.tier_master_mult": "множитель характеристик мастерской вещи",
	"craft.xp_per_craft": "опыт навыка крафта за создание вещи",
	"craft.boss_intact_chance": "босс роняет ЦЕЛУЮ вещь вместо сломанной, %",
	"craft.master_enabled": "вкладка «Мастер» включена",
	"magic.npc_heal_cooldown": "маги-НПЦ: пауза между лечениями, сек",
	"magic.npc_heal_percent": "маги-НПЦ: доля максимального HP за лечение",
	"npc.guard_aggro_radius": "радиус агро городской стражи на Серых",
	"npc.guard_leash": "дальше этого от поста страж не преследует",
	"world.day_seconds": "сек реального времени на день мира: 300 с ~ ротация заданий раз в 15 мин; 0 = выкл",
	"reputation.tier_1": "второй тир наёмников, рецепты в магазине",
	"reputation.tier_2": "третий тир наёмников, эльфийские свитки",
	"reputation.tier_3": "четвёртый тир наёмников",
	"reputation.discount_1": "скидка магазина, % (накопительно по тирам)",
	"reputation.elven_rep": "с какой репутации продаются эльфийские свитки",
	"reputation.inn_tier_cost": "доплата за тир наёмника, золото",
	"outpost.per_map": "лагерей на карту (кроме стартовой зоны)",
	"outpost.guards_min": "стражников в лагере",
	"outpost.rep_penalty": "репутация фракции за каждого убитого стражника",
	"outpost.capture_gold": "золото за захват форпоста (сверху лута со стражи)",
	"debug.perf": "профилировщик кадра: таблица мс/кадр по блокам в консоль",
	"debug.all_magic": "1 = все заклинания и бесконечная мана (для беты)",
	"debug.fog_of_war": "туман войны на карте героя (0/1)",
	"debug.show_coords": "подпись координат в HUD",
}

const HEADERS := {
	"combat": "БОЙ",
	"magic": "МАГИЯ",
	"economy": "ЭКОНОМИКА",
	"loot": "ЛУТ",
	"progression": "ПРОГРЕСС",
	"npc": "СТРАЖА ГОРОДА",
	"movement": "ДВИЖЕНИЕ",
	"autosave": "АВТОСЕЙВ",
	"world": "КАЛЕНДАРЬ ЖИВОЙ ИГРЫ",
	"metal": "МЕТАЛЛ -> СТАТЫ  (двигатель этапа баланса)",
	"craft": "МАСТЕРСКАЯ  (кузнец / портной / мастер)",
	"spawn": "ГЕНЕРАЦИЯ КАРТЫ",
	"grey": "СЕРЫЕ  (база тира 1: HP и урон, без разбивки по зонам)",
	"mob_tier": "ТИРЫ МОБОВ  (прирост HP и урона за тир)",
	"city": "ГОРОДСКИЕ NPC  (одинаковы во всех зонах)",
	"poi": "ТОЧКИ ИНТЕРЕСА  (выключены, пока мало арта)",
	"zone_design": "ДИЗАЙН ЗОН  (плотность Серых и леса, не боевые статы)",
	"events": "СОБЫТИЯ-СТЫЧКИ",
	"quests": "КВЕСТЫ ГЛАВЫ ГОРОДА",
	"reputation": "РЕПУТАЦИЯ (пропуск к товарам таверны и магазина)",
	"outpost": "ФОРПОСТЫ ФРАКЦИЙ",
	"debug": "ОТЛАДОЧНЫЕ ПЕРЕКЛЮЧАТЕЛИ",
	"archmage": "ВЕЛИКИЙ МАГ",
	"stress": "СТРЕСС-ТЕСТ",
}


func _note(section: String, key: String) -> String:
	var n: String = str(NOTES.get("%s.%s" % [section, key], ""))
	return ("    ; " + n) if n != "" else ""


func _fmt(value: Variant) -> String:
	# ConfigFile принимает число, true/false или СТРОЧКУ В КАВЫЧКАХ.
	# Голое `bronze` он не понимает и падает с ERR_PARSE_ERROR (43).
	# Баг был латентным: строковых значений в DEFAULTS до 03.10 не было
	# вовсе, поэтому ветка молчала. Первое значение-строка — metal.reference_metal.
	if value is String:
		return '"%s"' % str(value).replace('"', '\\"')
	if value is float:
		return str(value)
	return str(value)


func build_text() -> String:
	var lines: Array[String] = []
	lines.append("; ============================================================")
	lines.append("; Mirotokhome - игровой конфиг")
	lines.append(";")
	lines.append("; Эталоны по умолчанию. Сгенерировано из DEFAULTS в")
	lines.append("; scripts/game_config.gd - правь значения здесь, потом перезапусти игру.")
	lines.append(";")
	lines.append("; Свои правки держи в user://config/game.cfg - он перекрывает этот")
	lines.append("; файл и не попадает в git. Экспорт: готовится скриптом seed_user_file().")
	lines.append(";")
	lines.append("; ВАЖНО: имена секций и ключей не могут содержать пробелов -")
	lines.append("; ConfigFile молча отрезает всё после первого пробела.")
	lines.append("; ============================================================")

	for section in GameConfig.DEFAULTS:
		lines.append("")
		lines.append("; ============================================================")
		lines.append("; " + str(HEADERS.get(section, section)))
		lines.append("; ============================================================")
		lines.append("[%s]" % section)
		var keys: Array = (GameConfig.DEFAULTS[section] as Dictionary).keys()
		keys.sort()
		for key in keys:
			var note := _note(section, str(key))
			lines.append("%s = %s%s" % [key, _fmt((GameConfig.DEFAULTS[section] as Dictionary)[key]), note])
	lines.append("")
	return "\n".join(lines)


func _init() -> void:
	call_deferred("_run")


func _run() -> void:
	var code := main()
	print("EXIT %d" % code)
	quit(code)


func main() -> int:
	var check_only := false
	for arg in OS.get_cmdline_user_args():
		if arg == "--check":
			check_only = true
	var text := build_text()

	if check_only:
		if not FileAccess.file_exists(OUT):
			print("FAIL: %s не существует" % OUT)
			return 2
		var cur := FileAccess.get_file_as_string(OUT)
		if cur != text:
			print("FAIL: файл разошёлся с DEFAULTS - перегенерируй без --check")
			return 2
		print("RESULT: OK файл совпадает с DEFAULTS (%d строк)" % text.split("\n").size())
		return 0

	DirAccess.make_dir_recursive_absolute(OUT.get_base_dir())
	var f := FileAccess.open(OUT, FileAccess.WRITE)
	if f == null:
		print("FAIL: не записался %s (ошибка %d)" % [OUT, FileAccess.get_open_error()])
		return 2
	f.store_string(text)
	f.close()
	print("записан %s (%d строк, %d секций)" % [OUT, text.split("\n").size(), GameConfig.DEFAULTS.size()])
	print("RESULT: OK gen_game_config_defaults")
	return 0