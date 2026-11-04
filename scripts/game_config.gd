extends RefCounted
class_name GameConfig
##
## Игровой конфиг: все числа, которые можно крутить без правки кода.
##
## Замысел — от файла `import/rates.properties` (настройки сервера AION).
## Оттуда взяты удачные решения: множитель урона и множители HP/PW по тирам
## мобов. Отброшено лишнее: в AION ~80% файла — это `regular/premium/vip`,
## три копии одного множителя ради монетизации; у нас повторять нечего.
##
## Где лежит:
##   res://assets/config/game.cfg  — эталоны, в репозитории
##   user://config/game.cfg        — твои правки, вне git, перекрывают res
##
## Правила, заложенные специально:
##   1. Любой ключ имеет значение по умолчанию. Опечатка в конфиге не должна
##      ронять игру — берём дефолт и пишем предупреждение в лог.
##   2. Дефолты равны тем числам, что были зашиты в код. Появление конфига
##      ничего не меняет в поведении игры, только делает числа видимыми.
##   3. Конфиг читается при старте. Горячей перезагрузки нет.
##

## Пути. USER_PATH — то, что ты крутишь руками.
const RES_PATH := "res://assets/config/game.cfg"
const USER_PATH := "user://config/game.cfg"

## Значения по умолчанию = текущие числа из кода (правило 2).
## Порядок ключей здесь = порядок секций в .cfg.
const DEFAULTS := {
	"combat": {
		"hit_base": 70,             # база попадания, %
		"hit_soften": 5,            # смягчение: шанс = base*(att+soft)/(def+soft)
		"hit_min": 5,
		"hit_max": 95,
		"damage_multiplier": 1.0,   # глобальный множитель урона (взят из AION)
		"attack_cooldown": 1.0,     # раньше продублировано 1.0 в трёх файлах
		"enemy_defense_div": 25,    # было max_hp/25
		# 2 -> 5 (player tuning, 15.10): enemy hits were cutting the fight
		# short. The value has lived in the reference file since then, so the
		# default follows it (rule 2 in the module header).
		"enemy_attack_dmg_div": 5,
		"enemy_attack_hp_div": 30,  # было max_hp/30
		"enemy_absorption_div": 40, # было max_hp/40
		"protection_max": 95,       # потолок сопротивления стихии, %
	},
	"magic": {
		"sp_offset": 15.0,          # SP = навык + разум - offset
		"staff_mana_cost": 4,       # ману за удар посоха
		"chain_min_targets": 4,
		"chain_max_targets": 6,
		"chain_radius": 160.0,
		"auto_heal_ratio": 0.45,    # авто-лечение, когда HP/макс ниже порога
		"auto_buff_interval": 2.0,  # сек между проверками авто-баффов
		"npc_heal_cooldown": 6.0,   # маги-НПЦ: пауза между лечениями, сек
		"npc_heal_percent": 0.12,   # маги-НПЦ: доля максимального HP за лечение
	},
	"economy": {
		"start_gold": 20,           # ТУТ БЫЛО 20. Этап 2 поднимет до 400:
		"sell_price_div": 2,        # продажа = цена / div (зашито в двух местах)
		"loot_gold_multiplier": 1.0,
	},
	"loot": {
		"enemy_potion_chance": 45,   # было randi()%100 < 45
		"enemy_gear_chance": 35,
		"npc_citizen_potion_chance": 50,
		"npc_guard_potion_chance": 25,
		# npc_guard_gear_chance УДАЛЁН 07.10: NPC роняют сломанную вещь
		# ВСЕГДА, а не с шансом. Шанс был частью старой модели, где NPC
		# роняли целую вещь - теперь она сломанная по определению.
	},
	"progression": {
		"unit_exp_base": 100,
	},
	"skill_stats": {
		# The chosen direction (primary skill) and the auxiliary skill give
		# survivability on top of the attributes: life for both classes, mana
		# for a mage, defence for a warrior. The auxiliary counts at 60% of its
		# level (player decision 04.11), so 20 + 10 reads as 26 development
		# points, not 30. Damage is NOT added here: it already scales with the
		# weapon/sphere skill in the damage formulas.
		"hp_per_point": 0.5,
		"mana_per_point": 0.5,
		"defense_per_point": 0.2,
		"aux_factor": 0.6,
	},
	"npc": {
		# Радиус агро городской стражи на Серых. 190 -> 133 (-30%):
		# стража стоит по краям города и не должна хватать Серых по площади.
		"guard_aggro_radius": 133.0,
		# Дальше этого от поста страж не преследует Серого.
		"guard_leash": 380.0,
	},
	"movement": {
		"accel": 1100.0,   # дублируется в player.gd и enemy.gd
		"decel": 1800.0,
		"speed_multiplier": 1.0,
	},
	"autosave": {
		"interval": 60.0,
	},
	"world": {
		# Календарь живой игры (28.10): сколько РЕАЛЬНЫХ секунд длится один
		# игровой день. До этого день мира тикал только в headless sim_runner,
		# поэтому в игре стояли лента мира, угроза и ротация заданий
		# ([quests] offer_ttl_days). 300 с = 5 минут: ротация заданий ~15 мин.
		# 0 или меньше — календарь выключен (прежнее поведение).
		"day_seconds": 300.0,
	},
	"metal": {
		# absorption_min/max — потолок поглощения по металлу. Ссылается тест
		# game_config_smoke; сам игровой код их пока не читает.
		"absorption_min": 1,
		"absorption_max": 6,

		# --- Формула «металл -> статы» (этап 2, 03.10) -------------------
		# Исторически масштабировщик от цены слитка копировал damage из
		# образца, и 554 из 651 предметов фракционных металлов оказались
		# побайтовыми клонами. Теперь статы = база(тип, качество) x
		# (слиток/слиток_реф) ^ exp.
		# Степени подобраны по существующим «настоящим» металлам, чтобы
		# переезд НЕ ломал их: bronze 1.00, iron 1.40 (было 1.38).
		# Монотонность по цене слитка получается САМОЙ по себе, а не
		# таблицей, которую надо поддерживать руками.
		# Пакет A (28.10): 16 фракционных металлов удалены, формула
		# осталась и по-прежнему управляет статами bronze/iron/steel/gold
		# (слитки 2/9/20/80); охраняет её тест metal_stats_smoke.
		"reference_metal": "bronze",   # слиток с множителем ровно 1.0
		"damage_exp": 0.22,
		"to_hit_exp": 0.10,            # точность растёт медленнее урона
		"defence_exp": 0.22,
		"absorption_exp": 0.15,
	},
	"craft": {
		# --- Мастерская (07.10, пакет 1) ---------------------------------
		# Кузнец/Портной/Мастер. Металл в игре существует ТОЛЬКО как
		# производная от убитых НПЦ: сломанная вещь -> переплавка -> слиток
		# -> рецепт. Лавка СЕЙЧАС ещё продаёт броню и оружие — это осознанный
		# долг пакета 2 (см. AGENTS.md), не баг мастерской.

		# Выход переработки сломанной вещи. Количество НЕ зависит от цены
		# металла - кратность выражается качеством вещи, иначе появилась бы
		# четвёртая валюта. Проверено по ценам слитков: bronze 2 ... gold 80
		# (пакет A: фракционные металлы удалены), разброс в 40 раз
		# закрывается тремя ступенями.
		"yield_broken": 1,          # слитков из брони/оружия: Broken
		"yield_broken_fine": 2,     # Broken Fine
		"yield_broken_rare": 4,     # Broken Rare
		# Кузнец даёт ткань «вразрез» с портным: много ткани нужно портному,
		# поэтому из металлической вещи её выходит мало. Обмен асимметричен
		# намеренно - это и есть баланс двух профессий.
		"fabric_from_armor": 1,
		"fabric_from_armor_fine": 2,
		"fabric_from_armor_rare": 2,
		"fabric_from_weapon": 0,
		"fabric_from_weapon_fine": 1,
		"fabric_from_weapon_rare": 1,
		# Одежда мага: ткань + магическая эссенция.
		"fabric_from_garment": 2,
		"fabric_from_garment_fine": 4,
		"fabric_from_garment_rare": 6,
		"essence_from_garment": 1,
		"essence_from_garment_fine": 2,
		"essence_from_garment_rare": 3,

		# --- Шансы трёх уровней крафта -------------------------------
		# 80 / 15 / 5 на навыке 0. Навык сдвигает так, что сумма всегда 100:
		#   обычная    = chance_ordinary - ordinary_step * навык
		#   улучшенная = chance_improved + improved_step * навык
		#   мастерская = chance_master  + master_step  * навык
		# Навык 20 -> 52 / 33 / 15. Обычная зажата снизу floor_ordinary.
		"chance_ordinary": 80.0,
		"chance_improved": 15.0,
		"chance_master": 5.0,
		"ordinary_step": 1.4,
		"improved_step": 0.9,
		"master_step": 0.5,
		"floor_ordinary": 5.0,

		# Множители характеристик крафтовых вещей. Текстура у всех трёх
		# уровней ОДНА, различаются только числа и шейдер свечения.
		"tier_improved_mult": 1.15,
		"tier_master_mult": 1.35,

		# --- Навыки крафта ---------------------------------------------
		# Опыт за создание вещи. Формула роста уровня общая с боевыми
		# навыками (1.1^n в player.skill_to_exp) - она сама замедляет рост.
		"xp_per_craft": 20,
		"xp_per_recycle": 4,
		"xp_tier_bonus": 15,       # доп. опыт за улучшенную/мастерскую вещь

		# Мастер по улучшениям - третья вкладка. Включена 08.10: игрок
		# просил «полностью сделаем».
		"master_enabled": 1,

		# --- Дроп -------------------------------------------------------
		# Шанс эссенции с Серых живёт НЕ здесь, а в assets/config/
		# loot_tables.json рядом с gear_chance/potion_chance: он зависит от
		# семейства (зверь / насекомое / нежить / чудовище), и держать
		# половину таблицы в конфиге, а половину в json - это два источника
		# правды на одно число.
		"boss_intact_chance": 12,  # босс/дракон роняет ЦЕЛУЮ вещь вместо сломанной
	},
	"spawn": {
		# Размер и плотность города. city_gap — зазор между зданиями, его
		# решение от 26.09 («1 -> 2») в коде НЕ было применено: _footprint_fits
		# содержал зашитый 1, а city_layout_smoke подстроился под факт
		# (`gap >= CITY_GAP - 1`) и молча разрешал ему расти.
		#
		# Замер 03.10: при радиусе 8 и зазоре 2 в овал влезает только 3 из 5
		# функциональных зданий (магазин/таверна/кузня/школа/алхимия) — то
		# есть город мог остаться без кузни. Поэтому радиус поднят до 9:
		# зазор 2 сохраняется, все пять зданий помещаются (проверено: 8 -> 3
		# из 5, 9 -> 5 из 5).
		"herb_region_grid": 4,
		"herb_min_distance": 4,
		"city_radius": 9,
		"city_gap": 2,

		# Респавн Серых. Замер 03.10: респавна НЕ БЫЛО вообще — убил всех в зоне,
		# и зона становилась пустой навсегда. Теперь держим лимит.
		# gray_target — сколько живых Серых держим; берётся из зоны, если 0.
		# gray_respawn_min_dist — клеток от героя, чтобы зверь не появлялся на глазах.
		# 07.10 пакет B: target поднят, карты не должны быть «пустыми».
		"gray_target": 150,
		"gray_respawn_seconds": 20.0,
		"gray_respawn_min_dist": 26,
	},
	"grey": {
		# Base stats of a tier-1 Grey (3x.11 cleanup): zone difficulty is NOT
		# set here. A zone picks a tier band (MapGenerator.GRAY_TIER_BAND) and
		# the tier scales these numbers by the [mob_tier] steps. This is the
		# AION rates model: global numbers, per-monster multipliers, and no
		# per-zone DPS.
		#
		# Damage 4-6 -> 18-26 (playtest 04.11): a starter hero absorbs 5-8 and
		# has ~100 HP, so 10-15 raw meant 5-10 per hit and a dozen hits to die
		# — packs were cleared without crafting or potions.
		"hp_min": 25,
		"hp_max": 45,
		"damage_min": 18,
		"damage_max": 26,
	},
	"mob_tier": {
		# Growth per tier above the first: mult = 1 + step * (tier - 1).
		# Tier 5 is x2.4 HP and x2.0 damage over the tier-1 base. The tier
		# itself comes from units_db.json, so the formula lives in one place
		# (MapGenerator.gray_tier_mults) and the numbers live here.
		"hp_step": 0.35,
		"damage_step": 0.25,
	},
	"city": {
		# City NPCs are the same in every zone: a guard is a guard, and zone
		# danger lives in the Grey tiers. Counts are per city. Before 3x.11
		# these numbers were duplicated four times under a per-zone prefix
		# while every zone carried identical values.
		"guard_count_min": 5,
		"guard_count_max": 8,
		"guard_hp_min": 60,
		"guard_hp_max": 100,
		"guard_damage_min": 6,
		"guard_damage_max": 10,
		"captain_hp": 120,
		"captain_damage": 12,
		"citizen_hp": 30,
		"citizen_count_min": 6,
		"citizen_count_max": 9,
	},
	"poi": {
		# Points of interest (ruins, camps, shrines). count = 0 keeps the
		# feature off: there is not enough art yet (player decision 07.10).
		"count": 0,
		"hp": 60,
		"damage": 6,
	},
	"zone_design": {
		# Map design per zone, not combat rates: how many Greys a map holds
		# and how dense the trees are. A Grey's HP and damage come from
		# [grey] plus the tier of its set, so nothing here changes a fight's
		# DPS. Flat prefixed keys because ConfigFile has no nested sections.
		"start.gray_count_min": 40,     "start.gray_count_max": 60,
		"start.tree_density": 0.18,

		"mid.gray_count_min": 120,     "mid.gray_count_max": 150,
		"mid.tree_density": 0.20,

		"hard.gray_count_min": 140,    "hard.gray_count_max": 180,
		"hard.tree_density": 0.22,

		"faction.gray_count_min": 100, "faction.gray_count_max": 130,
		"faction.tree_density": 0.20,
	},
	"events": {
		# Динамические события на карте героя (19.10): стычки NPC vs NPC
		# с таймером жизни в РЕАЛЬНЫХ секундах (день мира слишком груб для
		# двухминутной стычки — [world] day_seconds); маркер события виден на
		# миникарте всегда.
		"enabled": 1,           # включено после проверки 19.10; 0 = выкл
		"spawn_period": 45.0,   # сек между попытками спавна
		"spawn_chance": 35,     # % шанс события на попытку
		"max_active": 2,        # максимум одновременных событий на карте
		"ttl_seconds_min": 90,
		"ttl_seconds_max": 240,
		"spawn_min_dist": 400,  # px от героя до места события
		"spawn_max_dist": 900,
		"members_min": 2,       # размер одной группы стычки
		"members_max": 3,
	},
	"quests": {
		# Квесты главы города (22.10): офферы по сиду карты, ротация по дню
		# мира, награда = золото + репутация фракции + могущество мага +
		# чертёж за сложное задание.
		"enabled": 1,
		"offer_slots": 3,          # сколько офферов держит один город
		"max_active": 5,           # сколько квестов можно взять одновременно
		"offer_ttl_days": 3,       # оффер живёт столько дней мира, потом ротация
		"urgent_seconds": 120.0,   # срок срочного задания, реальные секунды
		"blueprint_min_difficulty": 3,
		"kill_elite_hp_mult": 2.5,
		"kill_elite_dmg_mult": 1.5,
		# gray_kill_base was removed on 03.11: the target count comes from the
		# quest template (`count_by_difficulty` in quest_db.json), the key was
		# read by nobody, so tuning it silently did nothing.
		"rep_base": 5,             # репутация фракции за сложность 1
		"power_base": 0.2,         # могущество мага за сложность 1
		"prep_min_dist": 6,        # клеток от героя до цели при спавне
		"prep_max_dist": 22,
	},
	"reputation": {
		# Репутация героя как пропуск к товарам (28.10). Ключи оси — раса
		# города ("humans"/"ork"/"necro"/"druid"), её пишут квесты главы
		# ([quests] rep_base = 5 за сложность 1).
		#
		# Пороги выбирались по темпу: один сложный квест даёт 15, средний 9,
		# лёгкий 5. Тир 1 = 1 сложный квест, тир 3 = 6 сложных.
		"tier_1": 15,        # второй тир наёмников, рецепты в магазине
		"tier_2": 40,        # третий тир наёмников, эльфийские свитки
		"tier_3": 80,        # четвёртый тир наёмников
		"discount_1": 5,     # скидка магазина, % (накопительно по тирам)
		"discount_2": 10,
		"discount_3": 15,
		"elven_rep": 40,     # с какой репутации продаются эльфийские свитки
		"inn_tier_cost": 40, # доплата за тир наёмника, золото
	},
	"outpost": {
		# Форпосты фракций (пакет B, 28.10). Лагерь вне города: шатёр расы,
		# костёр и стража. Зачистка всех стражников = захват форпоста.
		#
		# В стартовой зоне форпостов нет вовсе (решение игрока): новичок
		# должен встречать только Серых.
		"per_map": 3,        # лагерей на карту (кроме стартовой зоны)
		"guards_min": 3,     # стражников в лагере
		"guards_max": 5,
		"rep_penalty": 5,    # репутация фракции за каждого убитого стражника
		"capture_gold": 40,  # золото за захват форпоста (сверху лута со стражи)
	},
	"debug": {
		# Отладочные переключатели (0 = выкл, 1 = вкл). Ключи заведены, чтобы
		# не править код ради отладки и не оставлять в сборке мусор.
		#
		# perf: профилировщик кадра (29.10). Печатает раз в 2 с таблицу
		# «мс на кадр» по блокам: ИИ стражей/врагов, поиск пути, ховер,
		# сетка расталкивания, туман, квесты, события, UI. Включённый
		# профилировщик сам стоит времени — для замеров, не для игры.
		"perf": 0,
		#
		# all_magic: все 31 заклинание + бесконечная мана для мага. До 03.10 это
		# был жёсткий `static var debug_magic = true` в game.gd. С 04.11 ключ
		# ВЫКЛЮЧЕН по умолчанию: играбельный маг начинает с одной книгой
		# школы (hero_start_book), учит её одним кликом и тратит ману.
		# Включать только для отладки магии: с 1 маг теряет экономику маны и
		# стартовую прокачку — это дисбаланс, который игрок и заметил.
		"all_magic": 0,
		#
		# fog_of_war: туман войны на карте героя (19.10, FogOfWar). Радиус
		# видимости ~14 клеток, исследованное остаётся приглушённым, враги
		# вне видимости скрыты. Включён после проверки игрока 19.10.
		"fog_of_war": 1,
		#
		# show_coords: подпись координат в HUD. По умолчанию выключена —
		# на экране она выглядела как отладочная, из-за чего сборка читалась
		# как debug-сборка, а не как игра.
		"show_coords": 0,
	},
	"archmage": {
		# Великий маг фракции (пакет 3.0, docs/lore/gdd_archmage.md).
		#
		# ВАЖНО про decay_base/decay_threat: это спад ЗА ОДИН ТИК, а тик идёт
		# каждые sim_interval секунд. В сутках 86400/sim_interval тиков, поэтому
		# спад в сутки = decay * 86400/sim_interval.
		#
		# Первая версия была 0.02 + 0.06, и это давало 4.32 спада в СУТКИ
		# (4320 тиков * 0.02) — фракция падала с 60 до 0 за 14 дней, а держать
		# её требовало 216 слитков в день. Прогон tests/sim_archmage_stakes.py
		# показал настоящие числа; см. коммит с этим ключом.
		"sim_interval": 20.0,     # сек между тиками мага
		"decay_base": 0.0005,     # спад за тик при global_threat = 0  -> 2.16/день
		"decay_threat": 0.0015,   # спад за тик при global_threat = 1  -> 8.64/день
		# Ставки платы. Зелье сильнее слитка намеренно: то, что нужно игроку,
		# нужно и фракции — это и есть конфликт выбора.
		"stake_ingot": 1.0,       # слиток любого металла
		"stake_gold": 1.0,        # за gold_per_stake единиц золота
		"stake_potion": 1.5,      # зелье
		"gold_per_stake": 100,    # сколько золота даёт 1.0 платы
		"power_start": 60.0,      # стартовое могущество
		"power_max": 100.0,
		"tier_1": 35.0,           # порог ступени 1 (offensive)
		"tier_2": 65.0,
		"tier_3": 90.0,
	},
	"stress": {
		# Стресс-тест движка (игрок 07.10): 1000×1000, ×100 деревьев/НПЦ.
		# enabled=1 только для прогона; в проде 0.
		"enabled": 0,
		"map_size": 1000,
		"tree_count": 83700,
		"gray_count": 7500,
		"city_guard_count": 2000,
		"city_citizen_count": 1800,
		"gen_version": 99,
	},
}

static var _cfg: ConfigFile = null
static var _loaded := false
static var _unknown_keys: PackedStringArray = PackedStringArray()


static func load_all() -> void:
	## Читает res-эталон, поверх — пользовательский файл. Ошибка любого из
	## них не фатальна: игра идёт на дефолтах.
	_loaded = true
	_unknown_keys = PackedStringArray()
	var cfg := ConfigFile.new()
	var res_err := cfg.load(RES_PATH)
	if res_err != OK:
		push_warning("GameConfig: не читается %s (ошибка %d) — беру дефолты" % [RES_PATH, res_err])
	var user_err := cfg.load(USER_PATH)
	if user_err != OK and user_err != ERR_FILE_NOT_FOUND:
		push_warning("GameConfig: не читается %s (ошибка %d) — он проигнорирован" % [USER_PATH, user_err])
	_cfg = cfg


static func _ensure() -> void:
	if not _loaded:
		load_all()


static func _default_for(section: String, key: String) -> Variant:
	var sec: Variant = DEFAULTS.get(section, null)
	if sec is Dictionary:
		return (sec as Dictionary).get(key, null)
	return null


static func geti(section: String, key: String) -> int:
	_ensure()
	var d: Variant = _default_for(section, key)
	if _cfg != null and _cfg.has_section_key(section, key):
		return int(_cfg.get_value(section, key, d))
	if d == null:
		push_warning("GameConfig: неизвестный ключ %s.%s" % [section, key])
		return 0
	return int(d)


static func getf(section: String, key: String) -> float:
	_ensure()
	var d: Variant = _default_for(section, key)
	if _cfg != null and _cfg.has_section_key(section, key):
		return float(_cfg.get_value(section, key, d))
	if d == null:
		push_warning("GameConfig: неизвестный ключ %s.%s" % [section, key])
		return 0.0
	return float(d)


## A zone design key such as "start.gray_count_min" lives in [zone_design].
## Combat numbers are NOT per zone any more: Greys scale by tier, city NPCs
## are identical everywhere.
static func designi(zone: String, key: String) -> int:
	return geti("zone_design", "%s.%s" % [zone, key])


static func designf(zone: String, key: String) -> float:
	return getf("zone_design", "%s.%s" % [zone, key])


static func unknown_keys() -> PackedStringArray:
	return _unknown_keys


## Все известные ключи — для валидатора и дампа значений.
static func known_keys() -> Array[String]:
	var out: Array[String] = []
	for section in DEFAULTS:
		for key in (DEFAULTS[section] as Dictionary):
			out.append("%s.%s" % [section, key])
	return out


## Скопировать эталон из репозитория в пользовательский файл, чтобы его
## можно было крутить руками. Идемпотентно: если файл уже есть — не трогаем.
static func seed_user_file() -> bool:
	if FileAccess.file_exists(USER_PATH):
		return false
	var cfg := ConfigFile.new()
	if cfg.load(RES_PATH) != OK:
		push_warning("GameConfig: нечего копировать, %s не читается" % RES_PATH)
		return false
	var dir := USER_PATH.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	# set_value для каждого известного ключа, иначе save() создаст пустой файл:
	# ConfigFile не хранит комментарии, а нам нужен читаемый файл.
	for section in DEFAULTS:
		for key in DEFAULTS[section]:
			cfg.set_value(section, key, (DEFAULTS[section] as Dictionary)[key])
	var err := cfg.save(USER_PATH)
	if err != OK:
		push_warning("GameConfig: не записался %s (ошибка %d)" % [USER_PATH, err])
		return false
	return true