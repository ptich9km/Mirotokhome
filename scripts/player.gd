extends CharacterBody2D
class_name Player

## Emitted once on a lethal hit. The game owns the death screen and the freeze;
## the actor only latches its own state.
signal died

# Первичные характеристики (оригинальная система Allods 2)
@export var body: int = 10
@export var mind: int = 10
@export var agility: int = 10
@export var spirit: int = 10
# Навыки оружия и магии (0-100, пока базовые)
@export var blade_skill: int = 5
@export var axe_skill: int = 0
@export var bludgeon_skill: int = 0
@export var pike_skill: int = 0
@export var shooting_skill: int = 0
@export var fire_skill: int = 5
@export var water_skill: int = 5
@export var air_skill: int = 5
@export var earth_skill: int = 5
@export var astral_skill: int = 5

# Навыки РЕМЁСЕЛ (мастерская, 07.10). Растут ТОЛЬКО от крафта — в школе их
# нет, иначе покупка за золото обесценила бы само ремесло. В школу они не
# добавлены ещё и потому, что school_ui_smoke.gd:98 жёстко берёт
# _train_buttons[5]; вставка в список сломала бы тест.
@export var smithing_skill: int = 0
@export var tailoring_skill: int = 0
@export var alchemy_skill: int = 0
@export var mastering_skill: int = 0

var max_hp: int = 100
var max_mana: int = 50
var current_hp: int
var current_mana: int
var state: String = "idle"
## Latched death: unlike `state`, nothing (stop_movement, a panel, a load-time
## state reset) may clear it by accident. Only reset_death_state() does.
var is_dead: bool = false
var attack_target: Node2D = null
var attack_cooldown: float = 0.0
var _impact_timer := -1.0            # отсчёт до кадра удара (замах); <0 = нет удара в полёте
var _pending_attack_damage := 0      # урон текущего замаха (применяется в момент удара)
var _swing_target: Node2D = null     # цель замаха (снапшот); impact бьёт ЕЁ, а не live-цель
var move_speed: float = 120.0
var _path: Array = []        # маршрут (мировые точки — центры клеток), без «льда»
var _pending_cast: Dictionary = {}   # текущая подготовка заклинания (cast_time)
## Одноразовый «замах каста»: после применения заклинания (книга/свиток/авто)
## доигрываем attack-блок целиком — маг поднимает и опускает посох, магия
## при этом вылетает из центра персонажа. <=0 = анимации нет.
var _cast_swing_left := 0.0
var _stuck_frames := 0
var _repath_timer := 0.0

# --- Экономика (P0): золото и склад владений ---
var gold: int = 20  # переопределяется из GameConfig [economy] start_gold в _ready
var inventory: Array = []   # ключи предметов item_db ("Common iron Long Sword", "Potion ...")
## Экипированные предметы: слот ("weapon"/"shield"/"head"/"cloak"/"body"/"hands"/
## "feet"/"amulet"/"ring1"/"ring2") -> ключ item_db (см. ItemDB.EQUIP_SLOTS).
## Раньше экипировка меняла ТОЛЬКО набор анимации (armor_kind/weapon/has_shield) и
## не сохраняла, какой предмет надет, — поэтому get_defense/get_attack/get_absorption
## считали чистые формулы по атрибутам, и тяжёлая броня с защитой 14 давала ровно
## столько же, сколько её отсутствие.
var equipped: Dictionary = {}

# --- Опыт по навыкам (как у разработчиков UnityAllods/ROM2): ---
# навык растёт от опыта: exp = (1.1^skill - 1) * 1000; skill = log_1.1(exp/1000 + 1).
# Опыт даётся за удары оружием и применение магии (по сфере/навыку).
const SKILL_NAMES := [
	"blade", "axe", "bludgeon", "pike", "shooting",
	"fire", "water", "air", "earth", "astral",
	"smithing", "tailoring", "alchemy", "mastering",
]
var experience := {}        # name -> очки опыта по навыку
const UNIT_EXP_BASE := 100  # множитель опыта цели (Template.Experience у разработчиков)

## База опыта за урон/убийство — из конфига [progression] unit_exp_base.
## Константа выше осталась запасным значением и перекрытием для тестов.
func _unit_exp_base() -> int:
	var v := GameConfig.geti("progression", "unit_exp_base")
	return UNIT_EXP_BASE if v <= 0 else v

## Очки опыта, соответствующие уровню навыка (обратная формула).
static func skill_to_exp(skill: int) -> int:
	return int((pow(1.1, float(skill)) - 1.0) * 1000.0)

## Уровень навыка из очков опыта: floor(log_1.1(exp/1000 + 1)).
static func exp_to_skill(e: int) -> int:
	if e <= 0:
		return 0
	return int(floor(log(float(e) / 1000.0 + 1.0) / log(1.1)))

## Суммарный опыт героя по всем навыкам (XP в панели).
func total_experience() -> int:
	var t := 0
	for name in SKILL_NAMES:
		t += int(experience.get(name, 0))
	return t

## Текущее значение навыка по имени — для урона/UI.
func skill_value(name: String) -> int:
	match name:
		"blade": return blade_skill
		"axe": return axe_skill
		"bludgeon": return bludgeon_skill
		"pike": return pike_skill
		"shooting": return shooting_skill
		"fire": return fire_skill
		"water": return water_skill
		"air": return air_skill
		"earth": return earth_skill
		"astral": return astral_skill
		"smithing": return smithing_skill
		"tailoring": return tailoring_skill
		"alchemy": return alchemy_skill
		"mastering": return mastering_skill
	return 0

func _set_skill_value(name: String, v: int) -> void:
	match name:
		"blade": blade_skill = v
		"axe": axe_skill = v
		"bludgeon": bludgeon_skill = v
		"pike": pike_skill = v
		"shooting": shooting_skill = v
		"fire": fire_skill = v
		"water": water_skill = v
		"air": air_skill = v
		"earth": earth_skill = v
		"astral": astral_skill = v
		"smithing": smithing_skill = v
		"tailoring": tailoring_skill = v
		"alchemy": alchemy_skill = v
		"mastering": mastering_skill = v

## Восстановить уровни навыков из накопленного опыта.
##
## ЗАЧЕМ. Найденный баг: школа покупает уровень ЧЕРЕЗ ПОЛЕ (school_panel.gd:251
## делает `player.set(field, ...)`) и никогда не пишет в `experience`. При
## загрузке `_apply_hero_choice()` восстанавливает базу из hero.stats, а
## `_ready()` видя непустой `experience` пропускает `_init_experience()`. Никто
## больше не пересчитывает уровень из опыта - то есть купленные в школе
## уровни молча откатывались к стартовым. Крафтовые навыки унаследовали бы
## ровно то же самое: они растут ИЗ ОПЫТА, и без этого цикла терялись бы
## полностью.
func _levels_from_experience() -> void:
	for name in SKILL_NAMES:
		var lvl := exp_to_skill(int(experience.get(name, 0)))
		if lvl > 0:
			_set_skill_value(name, lvl)

## Задать уровень навыка по ИМЕНИ ПОЛЯ ("fire_skill") и синхронизировать опыт.
##
## Школа работает с полями (school_panel.gd SKILLS: ["Огонь", "fire_skill"]),
## а gain_skill_exp - с именами из SKILL_NAMES ("fire"). Отсюда trim_suffix.
## Побочный эффект метода - исправление бага школы: раньше покупка писала
## только поле, опыт не трогала, и уровень откатывался при загрузке.
func set_skill_field(field: String, v: int) -> void:
	var name := field.trim_suffix("_skill")
	_set_skill_value(name, v)
	if v > 0:
		experience[name] = maxi(int(experience.get(name, 0)), skill_to_exp(v))
	# A primary/aux skill level raises life (and mana/defence): refresh the
	# derived maxima so the school purchase is felt immediately.
	_recall_derived()

## Начислить опыт навыку; если уровень из опыта вырос — поднять навык.
func gain_skill_exp(skill_name: String, amount: int) -> void:
	if not SKILL_NAMES.has(skill_name) or amount <= 0:
		return
	var e := int(experience.get(skill_name, 0)) + amount
	experience[skill_name] = e
	var lvl := exp_to_skill(e)
	if lvl > skill_value(skill_name):
		_set_skill_value(skill_name, lvl)
		print("Навык %s повышен до %d!" % [skill_name, lvl])
		_recall_derived()

## Навык из нанесённого урона (по типу оружия героя). "" — опыт не идёт.
func _weapon_skill_name() -> String:
	match weapon:
		"sword": return "blade"
		"axe": return "axe"
		"club": return "bludgeon"
		"pike": return "pike"
		"bow", "xbow": return "shooting"
	return ""

## Опыт за попадание: как у разработчиков MapUnit:
## exp = урон/HPмакс * Experience юнита * (1 + Mind/100); при убийстве x2.
func _apply_attack_experience(target: Node2D, damage: int) -> void:
	var ws := _weapon_skill_name()
	if ws == "" or not is_instance_valid(target):
		return
	var target_hp := 50
	if "max_hp" in target:
		target_hp = maxi(int(target.max_hp), 1)
	var f := float(damage) / float(target_hp) * _unit_exp_base() * (1.0 + mind / 100.0)
	var target_cur := 0
	if "current_hp" in target:
		target_cur = int(target.current_hp)
	if target_cur <= damage:
		f *= 2.0  # убийство — вдвое больше опыта
	gain_skill_exp(ws, int(f))

## Опыт за применение магии (по сфере заклинания).
func _apply_spell_experience(sphere: String) -> void:
	var ws := sphere.to_lower()
	if not SKILL_NAMES.has(ws):
		return
	# база ~20 * (1 + Mind/100), как «опыт юнита» у заклинаний
	gain_skill_exp(ws, int(20.0 * (1.0 + mind / 100.0)))

## --- Нагрузка: вес предметов в инвентаре, перегруз снижает скорость ---
func get_load() -> float:
	var w := 0.0
	for key in inventory:
		var it := ItemDB.find(str(key))
		w += float(it.get("weight", 0.0))
	return w

## Ёмкость до перегруза (Body даёт силу нести больше).
func load_capacity() -> float:
	return 30.0 + body * 10.0

## Множитель скорости от нагрузки: до ёмкости — 1.0, перегруз — до 0.5.
func _load_penalty() -> float:
	var cap := load_capacity()
	if cap <= 0.0:
		return 1.0
	var load := get_load()
	if load <= cap:
		return 1.0
	return clampf(cap / float(load), 0.5, 1.0)

## Магия героя: выученные заклинания (книги) и заряды свитков.
## known_spells: "Fire_Ball" -> {"charges": -1} — выучено навсегда (маг, из книги);
## "Fire_Arrow" -> {"charges": 2} — заряды свитков (каст тратит заряд, свиток
## в итоге исчезает). Воины не имеют маны (max_mana = 0) — только свитки.
var known_spells: Dictionary = {}
var sphere_books: Dictionary = {}   # "Fire" -> true (книга стихии изучена магом)
var cast_cooldowns: Dictionary = {} # имя -> оставшееся время кд
var has_mana: bool = true
var health_bar: HealthBar
var alm_map = null   # CustomMap или AlmMap из группы "alm_map"

# --- Экипировка героя (определяет набор анимаций) ---
var armor_kind: String = "heavy"   # "heavy" -> heroes/, "light" -> heroes_l/
var weapon: String = "unarmed"     # по умолчанию без оружия — отлаживаем его анимацию
var two_handed: bool = false
var has_shield: bool = false
var _anim: UnitAnimBase = null

func _ready():
	_apply_hero_choice()
	var from_save := not Game.hero_save.is_empty()
	if from_save:
		_apply_hero_save()
	else:
		# Экономика (P0): стартовое золото и склад владений.
		# Стартовое золото лежит в GameConfig [economy] start_gold. ТУТ БЫЛО 20 -
		# при стартовой цене оружия 150-600 игрок не мог купить своё же оружие.
		gold = GameConfig.geti("economy", "start_gold")
		inventory.clear()
		_grant_starter_set()
	# Только маги имеют ману и читают книги магии; воины — свитки (заряды).
	has_mana = Game.hero_class == "mage"
	if from_save and int(Game.hero_save.get("max_hp", 0)) > 0:
		max_hp = int(Game.hero_save["max_hp"])
	else:
		max_hp = _calc_max_hp()
	if from_save and int(Game.hero_save.get("max_mana", 0)) > 0:
		max_mana = int(Game.hero_save["max_mana"])
	else:
		max_mana = _calc_max_mana()
	if from_save:
		current_hp = int(Game.hero_save.get("current_hp", max_hp))
		current_mana = int(Game.hero_save.get("current_mana", max_mana))
	else:
		current_hp = max_hp
		current_mana = max_mana
	move_speed = _calc_speed()
	alm_map = get_tree().get_first_node_in_group("alm_map")
	Game.configure_unit_body(self)
	_ensure_sprite()
	_create_health_bar()
	if from_save and not experience.is_empty():
		# Опыт из сейва - значит уровни надо ПЕРЕСЧИТАТЬ из него, а не взять
		# базовые из hero.stats. Раньше здесь стоял голый `pass`, и покупки в
		# школе (которые пишут только поле уровня) откатывались при загрузке;
		# крафтовые навыки, растущие ИЗ опыта, терялись целиком.
		_levels_from_experience()
	else:
		_init_experience()
	# The final skill values decide the skill-derived maxima: an old save may
	# carry a max computed before this rule, so recompute (no delta — loading
	# must not heal by a formula change).
	max_hp = _calc_max_hp()
	max_mana = _calc_max_mana()
	current_hp = clampi(current_hp, 1, maxi(1, max_hp))
	current_mana = clampi(current_mana, 0, maxi(1, max_mana))
	if health_bar != null and is_instance_valid(health_bar):
		health_bar.max_hp = maxi(1, max_hp)
		health_bar.max_mana = maxi(1, max_mana)
		health_bar.update_bars(current_hp, current_mana)


## Применить Game.hero_save (загрузка сейва) вместо стартового набора.
func _apply_hero_save() -> void:
	_restore_from_hero_save()
	# Пересобрать визуал/атаку по экипировке из сейва (не стартовой).
	# weapon — это КИН анимации (sword/staff/...), а не type из item_db
	# ("Long Sword"); иначе UnitAnim.setup("heroes/Long Sword") и герой невидим.
	if equipped.has("weapon"):
		var wkey := str(equipped["weapon"])
		var wit := ItemDB.find(wkey)
		if not wit.is_empty():
			weapon = ItemDB.weapon_kind(wit)
			two_handed = ItemDB.is_two_handed(wit)
	if equipped.has("shield"):
		has_shield = true
	if equipped.has("body"):
		var bit := ItemDB.find(str(equipped["body"]))
		if not bit.is_empty():
			armor_kind = ItemDB.armor_kind(bit)
	# Old saves may carry gear of the other class (the class rule is new): keep
	# it equipped, it is not silently dropped into the bag - equip checks block
	# any NEW piece of the wrong class, the worn one only gets flagged.
	for slot in ItemDB.EQUIP_SLOTS:
		if str(equipped.get(slot, "")) == "":
			continue
		var old_it := ItemDB.find(str(equipped[slot]))
		if not old_it.is_empty() and not ItemDB.allows_class(old_it, Game.hero_class):
			print("Player: надет предмет чужого класса в слоте %s: %s" % [slot, str(equipped[slot])])


## Голова/склад/экипировка/опыт/навыки из Game.hero_save — без пересчёта
## анимации и статов: их делает вызывающий (см. reload_hero_state).
func _restore_from_hero_save() -> void:
	var hs: Dictionary = Game.hero_save
	gold = int(hs.get("gold", 0))
	inventory = []
	var inv: Variant = hs.get("inventory", [])
	if inv is Array:
		for k in inv:
			inventory.append(str(k))
	equipped = {}
	var eq: Variant = hs.get("equipped", {})
	if eq is Dictionary:
		equipped = (eq as Dictionary).duplicate(true)
	known_spells = {}
	var ks: Variant = hs.get("known_spells", {})
	if ks is Dictionary:
		known_spells = (ks as Dictionary).duplicate(true)
	sphere_books = {}
	var sb: Variant = hs.get("sphere_books", {})
	if sb is Dictionary:
		sphere_books = (sb as Dictionary).duplicate(true)
	experience = {}
	var exp: Variant = hs.get("experience", {})
	if exp is Dictionary:
		experience = (exp as Dictionary).duplicate(true)


## Перечитать класс-зависимое состояние героя на ЖИВОМ узле (загрузка слота
## другого персонажа из Esc-меню).
##
## Раньше загрузка слота меняла только Game.hero_* и содержимое склада, а узел
## Player оставался прежним: новый герой-маг бегал спрайтом воина и не имел
## маны (жалоба 23.10). Раньше это маскировал change_scene — теперь мир
## подменяется на месте, и всё, что зависит от класса, надо пересобрать явно.
##
## Снаряжение чужого класса (старый сейв) остаётся надетым, но помечается:
## правила класса изменились позже, чем писались эти сейвы.
func reload_hero_state() -> void:
	var hs: Dictionary = Game.hero_save
	if not hs.is_empty():
		_restore_from_hero_save()
	has_mana = Game.hero_class == "mage"
	max_hp = int(hs.get("max_hp", _calc_max_hp()))
	max_mana = int(hs.get("max_mana", _calc_max_mana()))
	current_hp = clampi(int(hs.get("current_hp", max_hp)), 0, maxi(1, max_hp))
	current_mana = clampi(int(hs.get("current_mana", max_mana)), 0, maxi(1, max_mana))
	weapon = "unarmed"
	two_handed = false
	has_shield = false
	if equipped.has("weapon"):
		var wit := ItemDB.find(str(equipped["weapon"]))
		if not wit.is_empty():
			weapon = ItemDB.weapon_kind(wit)
			two_handed = ItemDB.is_two_handed(wit)
	if equipped.has("shield"):
		has_shield = true
	if equipped.has("body"):
		var bit := ItemDB.find(str(equipped["body"]))
		if not bit.is_empty():
			armor_kind = ItemDB.armor_kind(bit)
	for slot in ItemDB.EQUIP_SLOTS:
		if str(equipped.get(slot, "")) == "":
			continue
		var old_it := ItemDB.find(str(equipped[slot]))
		if not old_it.is_empty() and not ItemDB.allows_class(old_it, Game.hero_class):
			print("Player: надет предмет чужого класса в слоте %s: %s" % [slot, str(equipped[slot])])
	if not experience.is_empty():
		_levels_from_experience()
	if Game.hero_primary_skill == "":
		Game.hero_primary_skill = _infer_primary_skill()
	if Game.hero_aux_skill == "":
		Game.hero_aux_skill = "astral" if Game.hero_class == "mage" else "shooting"
	# The restored skill levels decide the skill-derived maxima (a slot saved
	# before this rule carries an older max).
	max_hp = _calc_max_hp()
	max_mana = _calc_max_mana()
	current_hp = clampi(current_hp, 1, maxi(1, max_hp))
	current_mana = clampi(current_mana, 0, maxi(1, max_mana))
	move_speed = _calc_speed()
	# Набор анимации зависит от класса, пола и расы — спрайт обязан
	# переключиться на нового героя.
	_ensure_sprite()
	# Полоса здоровья создаётся один раз с тогдашними max_hp/has_mana:
	# у мага из сейва должна появиться мана, у воина — исчезнуть.
	if health_bar != null and is_instance_valid(health_bar):
		health_bar.max_hp = maxi(1, max_hp)
		health_bar.max_mana = maxi(1, max_mana)
		if health_bar.has_mana != has_mana:
			health_bar.has_mana = has_mana
			# Узел снимается с родителя сразу, а не в конце кадра: иначе
			# add_child новой полосы в том же кадре увидел бы два узла.
			remove_child(health_bar)
			health_bar.queue_free()
			health_bar = null
			_create_health_bar()
		health_bar.update_bars(current_hp, current_mana)
	if has_method("refresh_animation"):
		refresh_animation()
	reset_death_state()

## Undo the death latch after a slot load / a new game. The actor must be
## visible and idle BEFORE the world is rebuilt; otherwise a loaded hero stayed
## a frozen corpse (the old code never reset `state`).
func reset_death_state() -> void:
	is_dead = false
	state = "idle"
	velocity = Vector2.ZERO
	_path.clear()
	visible = true
	if health_bar != null and is_instance_valid(health_bar):
		health_bar.visible = true
	_cancel_casting()
	Game.hero_dead = false
	Game.player_target = global_position
	if _anim != null:
		_anim.play(UnitAnim.Anim.IDLE)

## Начальный опыт из стартовых навыков (skill -> exp, как у разработчиков:
## exp = (1.1^skill - 1) * 1000). Дальше навык растёт от получаемого опыта.
func _init_experience() -> void:
	for name in SKILL_NAMES:
		var lvl := skill_value(name)
		if lvl > 0:
			experience[name] = skill_to_exp(lvl)

## Стартовая магия отключена: маг начинает БЕЗ заклинаний в панели магии.
## На старте он получает в склад книгу простейшего заклинания выбранной школы
## (см. _grant_starter_set) и учит её одним кликом по ячейке склада.

## Применить выбор персонажа с экрана старта (character_select): характеристики,
## стартовая экипировка. Без выбора (запуск main.tscn напрямую) — значения по умолчанию.
func _apply_hero_choice() -> void:
	var st: Dictionary = Game.hero_stats
	if st.is_empty():
		return
	body = int(st.get("body", body))
	agility = int(st.get("agility", agility))
	mind = int(st.get("mind", mind))
	spirit = int(st.get("spirit", spirit))
	blade_skill = int(st.get("blade", blade_skill))
	axe_skill = int(st.get("axe", axe_skill))
	bludgeon_skill = int(st.get("bludgeon", bludgeon_skill))
	pike_skill = int(st.get("pike", pike_skill))
	shooting_skill = int(st.get("shooting", shooting_skill))
	fire_skill = int(st.get("fire", fire_skill))
	water_skill = int(st.get("water", water_skill))
	air_skill = int(st.get("air", air_skill))
	earth_skill = int(st.get("earth", earth_skill))
	astral_skill = int(st.get("astral", astral_skill))
	weapon = str(st.get("weapon", weapon))
	has_shield = bool(st.get("shield", false))
	armor_kind = str(st.get("armor", armor_kind))
	# Old saves carry no primary/aux names: infer them so the skill-derived
	# life/mana/defence start working without a schema migration.
	if Game.hero_primary_skill == "":
		Game.hero_primary_skill = _infer_primary_skill()
	if Game.hero_aux_skill == "":
		Game.hero_aux_skill = "astral" if Game.hero_class == "mage" else "shooting"

## Best class direction from the current skills — the fallback for old saves.
func _infer_primary_skill() -> String:
	var candidates: Array
	if Game.hero_class == "mage":
		candidates = [["fire", fire_skill], ["water", water_skill],
			["air", air_skill], ["earth", earth_skill]]
	else:
		candidates = [["blade", blade_skill], ["axe", axe_skill],
			["bludgeon", bludgeon_skill], ["pike", pike_skill]]
	var best := ""
	var best_v := -1
	for c in candidates:
		if int(c[1]) > best_v:
			best_v = int(c[1])
			best = str(c[0])
	return best

## Стартовое снаряжение по классу героя (в склад — можно одеть/продать сразу).
func _grant_starter_set() -> void:
	# Ключи в нижнем регистре материала: "Common iron Long Sword", а не
	# "Common Iron Long Sword". Расхождение не падало с ошибкой - ItemDB.find()
	# возвращал пустой словарь, и герой выходил в бой голым, пока вещи лежали
	# в инвентаре. Регистр приведён к item_db.json при переводе металлов вниз.
	#
	# Starter weapon follows the chosen direction and is BRONZE (player
	# decision 04.11): the cheap metal is the opening kit, not iron.
	var keys := starter_items(Game.hero_class, weapon,
		bool(Game.hero_stats.get("shield", false)), Game.hero_start_book)
	for k in keys:
		inventory.append(str(k))
	# Стартовой брони НЕТ по решению игрока (01.10): герой выходит в бой в
	# оружии и щите, у мага — посох и книга.
	#
	# Стартовое снаряжение надевается сразу: иначе новый герой выходил бы в бой
	# голым (все статы — базовые, атрибуты), хотя вещи лежат в инвентаре.
	var weapon_key := starter_weapon_key(Game.hero_class, weapon)
	equip_item(ItemDB.find(weapon_key))
	if inventory.has("Common bronze Buckler"):
		equip_item(ItemDB.find("Common bronze Buckler"))
	# Магу на старте выдаётся только книга его школы (учится одним кликом
	# по ячейке склада; книга расходуется). Весь набор заклинаний и открытые
	# сферы — отладочный режим Game.debug_magic ([debug] all_magic = 1),
	# по умолчанию ВЫКЛЮЧЕН.
	if Game.debug_magic and Game.hero_class == "mage":
		for spell in SpellDB.all_spell_names():
			known_spells[str(spell)] = {"charges": -1}
		for sphere in ["Fire", "Water", "Air", "Earth", "Astral"]:
			sphere_books[sphere] = true

## --- Склад владений ---

func has_item(key: String) -> bool:
	return inventory.has(key)

func add_item(key: String) -> void:
	if key != "":
		inventory.append(key)
		_recall_speed()

## Положить золото в казну. Метод был нужен мешку лута (loot_bag.gd звал
## add_gold по has_method), но не существовал: золото из лута падало в
## запасную ветку `_player.gold += gold`, а склад об этом не знал.
func add_gold(amount: int) -> void:
	if amount <= 0:
		return
	gold += amount

## Убрать предмет из склада; true — если он там был.
func remove_item(key: String) -> bool:
	var i := inventory.find(key)
	if i < 0:
		return false
	inventory.remove_at(i)
	_recall_speed()
	return true

## Пересчитать скорость после изменения веса (нагрузки).
func _recall_speed() -> void:
	move_speed = _calc_speed()

## Постоянные характеристики, которые может поднять зелье.
## Ключ в БД -> поле на Player. Reaction в Аллодах производная от Ловкости
## (`reaction := 2 * agility`), поэтому в базе «reaction», а в коде — agility.
const PERMANENT_STATS := {
	"body": "body",
	"mind": "mind",
	"reaction": "agility",
	"spirit": "spirit",
}

## Разбирает effects предмета и поднимает характеристики НАВСЕГДА.
## Работает для строк вида "body=+1" (без "duration" — то есть не бафф).
## Возвращает список применённых полей (пустой, если постоянных эффектов нет).
func apply_permanent_effects(effects: Array) -> Array:
	var applied: Array = []
	for raw in effects:
		var line := str(raw)
		if "duration" in line:
			continue                      # временный эффект — не постоянный
		var eq := line.find("=")
		if eq < 0:
			continue
		var stat := line.substr(0, eq).strip_edges().to_lower()
		if not PERMANENT_STATS.has(stat):
			continue
		var amount := int(line.substr(eq + 1).replace("+", "").strip_edges())
		if amount == 0:
			continue
		var field: String = str(PERMANENT_STATS[stat])
		set(field, int(get(field)) + amount)
		# Дублируем в Game.hero_stats — он сохраняется в сейве как "stats",
		# поэтому бонус переживает перезапуск без смены версии схемы.
		# Ключ здесь именно `field`, а не имя из БД: в базе "reaction", но
		# _apply_hero_choice() читает "agility" — запись по "reaction" молча
		# потеряла бы бонус ловкости при перезагрузке.
		if Game.hero_stats is Dictionary:
			Game.hero_stats[field] = int(Game.hero_stats.get(field, 0)) + amount
		applied.append(stat)
	if not applied.is_empty():
		_recall_derived()
	return applied

## Пересчёт производных характеристик после смены первичных.
func _recall_derived() -> void:
	var old_hp := max_hp
	var old_mana := max_mana
	max_hp = _calc_max_hp()
	max_mana = _calc_max_mana()
	# Добавленная ёмкость сразу достаётся игроку: зелье не должно лечить «впустую».
	current_hp = mini(max_hp, current_hp + maxi(0, max_hp - old_hp))
	current_mana = mini(max_mana, current_mana + maxi(0, max_mana - old_mana))
	_recall_speed()

## Использование зелья. Общий путь и для клика в инвентаре, и для хоткея —
## раньше логика жила внутри _on_item_clicked, и второго вызова просто не было бы.
## Расходуется, если сработало ЛИБО постоянный эффект, ЛИБО разовый хил/мана.
func use_potion(item_key: String) -> bool:
	var item := ItemDB.find(item_key)
	if item.is_empty():
		return false
	if str(item.get("quality", "")) != "Potion":
		return false
	var effects: Array = item.get("effects", [])
	var permanent := apply_permanent_effects(effects)
	# Разовая часть сохраняет прежние значения из inventory_panel:
	# они подобраны по балансу и не обязаны совпадать с effects из БД.
	var key_l := item_key.to_lower()
	var heal := 0
	var mana := 0
	if "healing" in key_l:
		heal = 60 if "big" in key_l else (30 if "medium" in key_l else 20)
	elif "mana" in key_l:
		mana = 50 if "big" in key_l else (25 if "medium" in key_l else 15)
	elif "regen" in key_l:
		heal = 15
		mana = 10
	# Ни постоянного, ни разового эффекта — пить нечего, предмет не тратим.
	if permanent.is_empty() and heal <= 0 and mana <= 0:
		return false
	if not remove_item(item_key):
		return false
	current_hp = mini(max_hp, current_hp + heal)
	if max_mana > 0:
		current_mana = mini(max_mana, current_mana + mana)
	SoundDB.play("magic.heal")
	return true

# --- Производные характеристики (связи из оригинального main.txt) ---
# ONE source of the formulas for the live player AND the creation preview:
# the screen calls these statics, so its numbers cannot drift from combat.
static func max_hp_of(body_value: int) -> int:
	return 20 + body_value * 8

static func max_mana_of(spirit_value: int) -> int:
	return 10 + spirit_value * 4

static func damage_min_of(base_min: int, skill: int, agility_value: int) -> int:
	return maxi(1, int(round(float(base_min) * (1.0 + float(skill) / 40.0
		+ float(agility_value) / 80.0))))

static func damage_max_of(base_max: int, skill: int, body_value: int) -> int:
	return maxi(1, int(round(float(base_max) * (1.0 + float(skill) / 40.0
		+ float(body_value) / 60.0))))

static func attack_of(agility_value: int, skill: int, to_hit: int) -> int:
	return int(agility_value / 2.0) + int(skill / 10.0) + to_hit

static func defense_of(agility_value: int, body_value: int, gear: int) -> int:
	return int(round(float(int(agility_value / 2.0) + int(body_value / 4.0) + gear)))

static func absorption_of(body_value: int, gear: int) -> int:
	return int(body_value / 4.0) + gear

static func speed_of(agility_value: int) -> float:
	var reaction := 2 * agility_value
	var base := clampf(float(reaction) / 5.0 + 12.0, 12.0, 255.0)
	return base * 7.5 * GameConfig.getf("movement", "speed_multiplier")

## Starter weapon key of a direction. Bronze is the player's decision (04.11):
## a new hero starts with the cheap metal and earns the upgrade.
static func starter_weapon_key(hero_class: String, weapon_kind: String) -> String:
	if hero_class == "mage":
		return "Common Wood Staff"
	match weapon_kind:
		"axe":
			return "Common bronze Axe"
		"club":
			return "Common bronze Mace"
		"pike":
			return "Common bronze Pike"
	return "Common bronze Long Sword"

## Everything a new hero owns, in the order `_grant_starter_set` hands it out.
## The creation screen renders this same list, so the promise is the inventory.
static func starter_items(hero_class: String, weapon_kind: String,
		with_shield: bool, book: String) -> Array:
	var out: Array = [starter_weapon_key(hero_class, weapon_kind)]
	var w := ItemDB.find(str(out[0]))
	if with_shield and not w.is_empty() and not ItemDB.is_two_handed(w):
		out.append("Common bronze Buckler")
	if book != "":
		out.append(book)
	for i in range(3):
		out.append("Potion Medium Healing")
	out.append("Potion Mana Regeneration")
	return out

func primary_skill_value() -> int:
	return skill_value(Game.hero_primary_skill) if Game.hero_primary_skill != "" else 0

func aux_skill_value() -> int:
	return skill_value(Game.hero_aux_skill) if Game.hero_aux_skill != "" else 0

## Development points: the main direction at 100%, the auxiliary at 60%
## ([skill_stats] aux_factor). Life/mana/defence are derived from this.
func development_points() -> float:
	return float(primary_skill_value()) \
		+ float(aux_skill_value()) * GameConfig.getf("skill_stats", "aux_factor")

func max_magic_skill() -> int:
	return maxi(fire_skill, maxi(water_skill, maxi(air_skill,
		maxi(earth_skill, astral_skill))))

func _calc_max_hp() -> int:
	return max_hp_of(body) \
		+ int(development_points() * GameConfig.getf("skill_stats", "hp_per_point"))

func _calc_max_mana() -> int:
	if not has_mana:
		return 0                  # воины не имеют маны вовсе
	return max_mana_of(spirit) \
		+ int(development_points() * GameConfig.getf("skill_stats", "mana_per_point"))

func _calc_hp_regen() -> int:
	return 1 + int(body / 5.0)           # реген HP от Body

func _calc_mana_regen() -> int:
	return 1 + int(spirit / 10.0)        # реген маны от Spirit

func _calc_speed() -> float:
	# Speed = min(Reaction/5 + 12, 255); Reaction ≈ 2·Agility (original
	# derivative). In our pixels: base × 7.5 (agility=10 -> the old 120 px/s).
	return speed_of(agility) * _load_penalty()

## Навык, которым герой бьёт текущим оружием (blade для меча и т.д.).
func _weapon_skill_for_damage() -> int:
	# The weapon's OWN skill. `weapon_kind()` returns "club" for maces, not
	# "bludgeon" — the old name never matched, so a mace silently trained the
	# blade skill. A staff uses the best magic school: a mage's weapon is the
	# school, not fire.
	match weapon:
		"axe":
			return axe_skill
		"club":
			return bludgeon_skill
		"pike":
			return pike_skill
		"bow", "xbow":
			return shooting_skill
		"staff", "magic":
			return max_magic_skill()
		_:
			return blade_skill


func get_damage_min() -> int:
	# Оружие: база предмета МАСШТABIРУЕТСЯ навыком и атрибутами — не копия
	# damage_min из item_db. Кулак всегда слабее любого оружия.
	var w := _equipped_item("weapon")
	if not w.is_empty():
		var dmin := int(w.get("damage_min", 0))
		if dmin > 0:
			return damage_min_of(dmin, _weapon_skill_for_damage(), agility)
	return unarmed_damage_min()


func get_damage_max() -> int:
	var w := _equipped_item("weapon")
	if not w.is_empty():
		var dmax := int(w.get("damage_max", 0))
		if dmax > 0:
			return damage_max_of(dmax, _weapon_skill_for_damage(), body)
	return unarmed_damage_max()


## Кулак / без оружия: строго ниже любого экипируемого клинка.
func unarmed_damage_min() -> int:
	var sk := _weapon_skill_for_damage()
	return maxi(1, int(body / 6.0) + int(sk / 20.0))


func unarmed_damage_max() -> int:
	return unarmed_damage_min() + maxi(1, int(body / 10.0))

func get_attack() -> int:
	# to_hit оружия идёт в атаку (шанс попадания), а не выбрасывается.
	# The weapon's OWN skill, not always blade: an axe must not borrow a
	# swordsman's hit chance.
	var w := _equipped_item("weapon")
	return attack_of(agility, _weapon_skill_for_damage(),
		int(w.get("to_hit", 0)) + StatusEffects.stat_flat(self, "attack"))

func get_defense() -> int:
	var base := int(agility / 2.0) + int(body / 4.0)    # Agility -> уклонение/защита
	# Все надетые части (броня, шлем, плащ, перчатки, сапоги, амулеты, кольца,
	# щит) дают свой defence, и он берётся ПОЛНОСТЬЮ. Атрибуты — база, вещи — поверх.
	var bonus := 0
	for it in _equipped_items():
		bonus += int(it.get("defence", 0))
	# Щит мага (Shield) = временная броня по астралу, не поглощение HP.
	bonus += StatusEffects.shield_armor_defense(self)
	# Warrior's development direction adds defence; a mage gets life/mana and
	# magic damage instead (player decision 04.11).
	if not has_mana:
		bonus += int(development_points() * GameConfig.getf("skill_stats", "defense_per_point"))
	return int(round((base + bonus + StatusEffects.stat_flat(self, "defense")) \
		* StatusEffects.defense_mult(self)))

func get_absorption() -> int:
	# Поглощение (в оригинале — отдельная характеристика брони): сумма по всем частям.
	var a := 0
	for it in _equipped_items():
		a += int(it.get("absorption", 0))
	a += StatusEffects.shield_armor_absorption(self)
	return absorption_of(body, a)

## Предмет в слоте (пустой словарь, если слот пуст или предмета нет в базе).
func _equipped_item(slot: String) -> Dictionary:
	var key := str(equipped.get(slot, ""))
	if key == "":
		return {}
	var it := ItemDB.find(key)
	return it if not it.is_empty() else {}

## Все надетые предметы (для статов/куклы). Пустые слоты пропускаются.
func _equipped_items() -> Array:
	var out: Array = []
	for slot in ItemDB.EQUIP_SLOTS:
		var it := _equipped_item(slot)
		if not it.is_empty():
			out.append(it)
	return out

## Надеть предмет: ключ уходит из склада в слот (модель A — надетое живёт
## только в equipped). Свап в том же слоте возвращает старый ключ в склад.
## Двуручник снимает щит — щит тоже возвращается в склад.
## true, если предмет экипирован.
func equip_item(item: Dictionary) -> bool:
	if not ItemDB.is_equippable(item):
		return false
	if not ItemDB.allows_class(item, Game.hero_class):
		return false
	var slot := ItemDB.slot_of(item)
	if slot == "":
		return false
	if slot == "ring":
		slot = "ring1" if str(equipped.get("ring1", "")) == "" else "ring2"
	if slot == "shield" and two_handed:
		return false
	var key := str(item.get("key", ""))
	var old := str(equipped.get(slot, ""))
	equipped[slot] = key
	match slot:
		"body":
			armor_kind = ItemDB.armor_kind(item)
		"weapon":
			weapon = ItemDB.weapon_kind(item)
			two_handed = ItemDB.is_two_handed(item)
			if two_handed:
				has_shield = false
				var shield_key := str(equipped.get("shield", ""))
				equipped.erase("shield")
				if shield_key != "" and shield_key != key:
					add_item(shield_key)
		"shield":
			has_shield = true
	if old != "" and old != key:
		add_item(old)
	remove_item(key)
	refresh_animation()
	return true

## Снять предмет со слота: ключ возвращается в склад (модель A).
## true — был надет.
func unequip_slot(slot: String) -> bool:
	if slot not in ItemDB.EQUIP_SLOTS:
		return false
	var key := str(equipped.get(slot, ""))
	if key == "":
		return false
	equipped.erase(slot)
	add_item(key)
	match slot:
		"weapon":
			weapon = "unarmed"
			two_handed = false
		"shield":
			has_shield = false
		"body":
			# Без брони — базовый набор героя (heroes/), не «лёгкий».
			armor_kind = "heavy"
	refresh_animation()
	return true

func get_sight() -> int:
	return 6 + int(agility / 3.0)                 # по манифесту

## Урон магии: Mind -> сила заклинаний (см. Game.spell_power — единая формула).
func get_magic_power() -> int:
	return int(mind / 2.0)

## Сопротивление стихии в процентах = дух (в оригинале Spirit даёт
## сопротивление) + навык сферы + временные баффы Protection_from_*.
func _sphere_protection(sphere: String) -> int:
	var skill := sphere_skill(sphere)
	# magcap брони тела/оружия — вклад в сопротивление стихии: у одежды он и есть
	# (у Common Leather Mail magcap=3, у тяжёлой брони — 150).
	var gear := int(_equipped_item("body").get("magcap", 0)) \
		+ int(_equipped_item("weapon").get("magcap", 0))
	return spirit + int(skill / 10.0) + int(gear / 10.0) + StatusEffects.resist_bonus(self, sphere)

func get_protection_fire() -> int: return _sphere_protection("Fire")
func get_protection_water() -> int: return _sphere_protection("Water")
func get_protection_air() -> int: return _sphere_protection("Air")
func get_protection_earth() -> int: return _sphere_protection("Earth")
func get_protection_astral() -> int: return int(spirit / 2.0) + StatusEffects.resist_bonus(self, "Astral")  # астрал почти не защищается

## Текущий набор анимаций по экипировке ("heroes/swordsman_").
##
## PILOT_HERO_SET — какой риг/набор использует герой.
## "rig/pilot" = рабочий палочный скелет (механика, не вид).
## "rig/hero_atlas" = нарезка из целого атласа (СЛОМАНА: двойные ноги, лишняя рука).
## "rig/atlas_v2" = 6 отдельных частей, 2 ракурса (восток + зеркало).
##   Риг технически работает, но игрок отверг его вид 14.10 («чучело»).
## "hero/war_men" = 12 кадров из полос Nano Banana (idle1+move4+attack3+dying4),
##   один профиль вправо + зеркало. Включён 14.10.
## "hero/war_women" = тот же контракт, воительница. Пол героя выбирает набор.
## "hero/orc_men" / "hero/orc_women" = тот же контракт, орк и орчица (15.10).
##   Раса выбирает набор, пол — внутри расы. Нежить (necro) и друид получили
##   свои наборы 20.10; нежить и друиды — свои женские наборы 21.10.
## "" = спрайт-листы по экипировке.
const PILOT_HERO_SET := "hero/war_men"
const PILOT_HERO_SET_UNDEAD := "hero/undead_men"
const PILOT_HERO_SET_DRUID := "hero/druid_men"
const PILOT_HERO_SET_F := "hero/war_women"
const PILOT_HERO_SET_ORK := "hero/orc_men"
const PILOT_HERO_SET_ORK_F := "hero/orc_women"
const PILOT_HERO_SET_UNDEAD_F := "hero/undead_women"
const PILOT_HERO_SET_DRUID_F := "hero/druid_women"
## Класс mage (21.10): у каждого мага свой набор по расе и полу.
const PILOT_HERO_SET_MAGE := "hero/mage_human_men"
const PILOT_HERO_SET_MAGE_F := "hero/mage_human_women"
const PILOT_HERO_SET_MAGE_ORK := "hero/mage_orc_men"
const PILOT_HERO_SET_MAGE_ORK_F := "hero/mage_orc_women"
const PILOT_HERO_SET_MAGE_UNDEAD := "hero/mage_undead_men"
const PILOT_HERO_SET_MAGE_UNDEAD_F := "hero/mage_undead_women"
const PILOT_HERO_SET_MAGE_DRUID := "hero/mage_druid_men"
const PILOT_HERO_SET_MAGE_DRUID_F := "hero/mage_druid_women"

## ПИЛОТ 10.10: риг вместо спрайт-листов, если для набора есть rig.json.
## Откат всего пилота — false в этой строке. Действует только вместе с
## PILOT_HERO_SET: сам по себе риг включается лишь там, где риг есть.
const PILOT_RIG := false

## Набор анимаций героя.
##
## Раньше здесь собиралось имя вида по экипировке: `heroes/…` для тяжёлой
## брони и магии, `heroes_l/…` для лёгкой. Оба семейства — арт Аллодов II и
## вычищены 11.10 вместе с ассетами, поэтому ветка удалена: сборка дала бы
## набор, которого нет в базе, и герой остался бы без анимации.
##
## Теперь ответ один — пилотный риг. Когда появятся риг-наборы броневых
## комплектов, здесь вернётся отображение «комплект -> риг-набор».
func anim_set_name() -> String:
	# Пол выбирает набор: до 14.10 Game.hero_gender ни на что не влиял и
	# все герои выглядели одинаково. Значения — как их отдаёт экран создания
	# героя (character_select.gd), любое другое считается мужским.
	# Раса — с 15.10: у орков свой набор. "orc" тоже принимается, потому что
	# так раса называется в `MapGenerator.CITY_RACES` и в старых сейвах.
	var female := str(Game.hero_gender) == "female"
	# Класс mage (21.10): у магов свои наборы с мантией и посохом,
	# раскладка рас та же, что у воинов.
	if Game.hero_class == "mage":
		match str(Game.hero_race):
			"ork", "orc":
				return PILOT_HERO_SET_MAGE_ORK_F if female else PILOT_HERO_SET_MAGE_ORK
			"necro", "undead":
				return PILOT_HERO_SET_MAGE_UNDEAD_F if female else PILOT_HERO_SET_MAGE_UNDEAD
			"druid":
				return PILOT_HERO_SET_MAGE_DRUID_F if female else PILOT_HERO_SET_MAGE_DRUID
			_:
				return PILOT_HERO_SET_MAGE_F if female else PILOT_HERO_SET_MAGE
	match str(Game.hero_race):
		"ork", "orc":
			return PILOT_HERO_SET_ORK_F if female else PILOT_HERO_SET_ORK
		"necro", "undead":
			return PILOT_HERO_SET_UNDEAD_F if female else PILOT_HERO_SET_UNDEAD
		"druid":
			return PILOT_HERO_SET_DRUID_F if female else PILOT_HERO_SET_DRUID
		_:
			return PILOT_HERO_SET_F if female else PILOT_HERO_SET

## Пересоздать анимацию после смены экипировки.
func refresh_animation() -> void:
	if _anim == null:
		return
	var set := anim_set_name()
	# Новый набор может не иметь рига (экипировка перевела героя на другой
	# набор). Тогда риг обязан уступить место спрайт-листам — иначе юнит
	# остался бы скелетом от прежнего набора.
	if _anim is RiggedAnim and not RiggedAnim.has_rig(set):
		_anim.queue_free()
		_anim = null
		_ensure_sprite()
		return
	_anim.setup(set)
	_anim.play(UnitAnim.Anim.MOVE, true)
	move_speed = _calc_speed()   # скорость обновляется вместе с экипировкой

## Множитель скорости с учётом высоты: подъём замедляет, спуск/равнина — норма.
## Дороги (tile4) — быстрее травы.
func _height_speed_factor(target_pos: Vector2) -> float:
	var f := StatusEffects.speed_mult(self)   # Haste/Slow — динамически, раз в кадр
	if not alm_map:
		return f
	var cur_h: float = float(alm_map.call("height_at_world", global_position))
	var tgt_h: float = float(alm_map.call("height_at_world", target_pos))
	var rise := maxf(0.0, tgt_h - cur_h)
	var penalty := rise * 0.08
	if rise > 0.0 and alm_map.has_method("cell_type_at"):
		var cell := Vector2i(int(target_pos.x) / 32, int(target_pos.y) / 32)
		if int(alm_map.call("cell_type_at", cell.x, cell.y)) == 1:
			penalty = rise * 0.16
	f *= maxf(0.55, 1.0 - penalty)
	if alm_map.has_method("speed_factor_at_world"):
		f *= float(alm_map.call("speed_factor_at_world", target_pos))
	return f

## Можно ли двигаться в точку: проходимость (вода/барьер) + границы карты.
## Исключение: выход ИЗ непроходимой клетки (герой «в дереве») разрешён — шаг
## внутри своей клетки допускается, чтобы дойти до границы и выйти наружу.
## Здания: жёсткий запрет входа в футпринт (сетка + StaticBody2D здания).
func _can_move_to(pos: Vector2) -> bool:
	if not alm_map:
		return true
	var cur := Vector2i(int(global_position.x) / 32, int(global_position.y) / 32)
	var nxt := Vector2i(int(pos.x) / 32, int(pos.y) / 32)
	# Футпринт здания: нельзя входить (даже если is_walkable_world соврал).
	if nxt != cur and alm_map.has_method("is_structure_cell") \
			and alm_map.is_structure_cell(nxt):
		return false
	if alm_map.is_walkable_world(pos):
		return alm_map.is_within_bounds(pos)
	return nxt == cur

# --- Физика движения тела (плавный разгон/торможение, без «льда») ---
## Разгон/торможение - в GameConfig [movement] accel/decel.

## Движение с проверкой проходимости.
## Сначала пробуем полный вектор; если он упирается в воду/границу карты, пробуем
## движение по каждой оси отдельно. Без этого герой «прилипал» к границе и не мог
## сдвинуться ВООБЩЕ — ни вперёд, ни вдоль, ни назад: заблокированный вектор
## обнулял скорость целиком.
##
## Скорость при скольжении вдоль стены снижается (берётся длина разрешённого шага),
## поэтому это не «лёд» — герой не разгоняется и не отскакивает.
func _move_checked(direction: Vector2, speed: float, delta: float):
	direction = Game.movement_direction(self, direction)
	var wanted := direction * speed
	var step := wanted * delta
	if _can_move_to(global_position + step):
		_last_move_dir = direction
		velocity = velocity.move_toward(wanted, GameConfig.getf("movement", "accel") * delta)
		return
	if delta <= 0.0:
		velocity = Vector2.ZERO
		return
	var slide := Vector2.ZERO
	if _can_move_to(global_position + Vector2(step.x, 0.0)):
		slide = Vector2(step.x, 0.0)
	elif _can_move_to(global_position + Vector2(0.0, step.y)):
		slide = Vector2(0.0, step.y)
	if slide == Vector2.ZERO:
		velocity = velocity.move_toward(Vector2.ZERO, GameConfig.getf("movement", "decel") * delta)
	else:
		# Целевая скорость = разрешённый шаг / delta: по освободившейся оси полный ход,
		# по заблокированной — ноль. Кадра «скольжения» не ускоряют.
		_last_move_dir = slide.normalized()
		velocity = velocity.move_toward(slide / delta, GameConfig.getf("movement", "accel") * delta)

func _create_health_bar():
	health_bar = preload("res://scripts/health_bar.gd").new()
	health_bar.max_hp = max_hp
	health_bar.max_mana = max_mana
	health_bar.has_mana = has_mana
	add_child(health_bar)

func _ensure_sprite():
	# Старая анимация снимается с родителя ДО add_child новой: обе зовутся
	# "UnitAnim". queue_free() освобождает узел только в конце кадра, и
	# загрузка слота другого героя (reload_hero_state) оставляла прежний
	# спрайт (воин) стоять поверх нового (маг).
	for child in get_children():
		if child is UnitAnimBase:
			remove_child(child)
			child.queue_free()
	_anim = _make_anim_backend(anim_set_name())
	_anim.name = "UnitAnim"
	add_child(_anim)
	refresh_animation()

## Создать бэкенд анимации для набора: риг, если он есть, иначе спрайт-листы.
##
## Бэкенды взаимозаменяемы по контракту UnitAnimBase (сторож —
## tests/anim_contract_smoke.gd), поэтому выбор сводится к «есть ли риг».
## PILOT_RIG отключает подмену целиком: откат пилота — одна строка.
func _make_anim_backend(set: String) -> UnitAnimBase:
	if PILOT_RIG and RiggedAnim.has_rig(set):
		var r := RiggedAnim.new()
		r.setup(set)
		if r.is_loaded():
			return r
		r.free()
	var a := UnitAnim.new()
	a.setup(set)
	return a

func _physics_process(delta):
	if Game.is_paused:
		return

	attack_cooldown = max(0, attack_cooldown - delta)
	# Кулдауны заклинаний
	for spell in cast_cooldowns:
		cast_cooldowns[spell] = max(0.0, float(cast_cooldowns[spell]) - delta)

	# Обновляем бар здоровья
	if health_bar:
		health_bar.update_bars(current_hp, current_mana)

	# Авто-каст мага (пакет C): лечение и баффы без ручного прицеливания.
	_tick_auto_cast(delta)
	# Герой всегда смотрит в сторону курсора (пожелание игрока 21.10):
	# в стойке/замахе каста доворачивается к мыши, при движении и в бою —
	# направление выбирает движение/цель, как раньше.
	_update_facing_mouse(delta)

	match state:
		"idle":
			velocity = Vector2.ZERO
			if _anim:
				if _cast_swing_left > 0.0:
					# Доигрываем замах каста (play() с тем же блоком не сбросит фазу).
					_cast_swing_left -= delta
					_anim.play(UnitAnim.Anim.ATTACK)
					_anim.speed_scale = 1.0
					_anim.advance(delta)
				else:
					_anim.play(UnitAnim.Anim.IDLE)
		"casting":
			velocity = Vector2.ZERO
			_tick_casting(delta)
			if _anim:
				_anim.play(UnitAnim.Anim.ATTACK)
				_anim.speed_scale = 0.6
				_anim.advance(delta)
		"move":
			move_to_target(delta)
			if _anim:
				_anim.play(UnitAnim.Anim.MOVE)
				_anim.set_direction_vec(velocity)
				# Темп шагов — по КОМАНДНОЙ скорости (разгон/торможение не «перекачивают» каденс)
				_anim.speed_scale = clampf(_height_speed_factor(Game.player_target) / 0.85, 0.5, 2.0)
				_anim.advance(delta)
		"chase":
			chase_target(delta)
			if _anim:
				_anim.play(UnitAnim.Anim.MOVE)
				_anim.set_direction_vec(velocity)
				var walk_f := 1.0
				if attack_target and is_instance_valid(attack_target):
					walk_f = _height_speed_factor(attack_target.global_position)
				_anim.speed_scale = clampf(walk_f / 0.85, 0.5, 2.0)
				_anim.advance(delta)
		"attack":
			attack_enemy(delta)
			if _anim:
				_anim.play(UnitAnim.Anim.ATTACK)
				_anim.speed_scale = 1.0
				_anim.advance(delta)
		"dead":
			velocity = Vector2.ZERO
			if _anim:
				# Падение: DYING один раз, затем разложение DECAY (1-2-3), потом пауза
				_anim.play(UnitAnim.Anim.DYING)
				if _anim.advance(delta):
					if UnitDB.decay_phases(anim_set_name()) > 0:
						state = "decay"
						_anim.play(UnitAnim.Anim.DECAY)
					else:
						# Блок доигран — зафиксировать ПОСЛЕДНИЙ кадр и уйти в
						# состояние трупа. Без этого advance() зацикливал блок на
						# первый кадр (герой вставал с распахнутыми руками), и
						# любое снятие паузы — Esc — проигрывало смерть заново
						# (жалоба игрока 14.10). enemy.gd делает то же через
						# freeze_last_frame, у героя этого шага не было.
						_anim.freeze_last_frame(UnitAnim.Anim.DYING)
						state = "corpse"
		"decay":
			velocity = Vector2.ZERO
			if _anim:
				_anim.play(UnitAnim.Anim.DECAY)
				if _anim.advance(delta):
					_anim.freeze_last_frame(UnitAnim.Anim.DECAY)
					state = "corpse"
		"corpse":
			# Труп: ни анимации, ни физики. Снятие паузы (Esc) больше не
			# перезапускает падение — блок DYING уже отыграл.
			velocity = Vector2.ZERO
			if _anim:
				_anim.freeze_last_frame(UnitAnim.Anim.DYING)

	move_and_slide()
	_clamp_to_map()
	_escape_blocking_units()
	_apply_relief_stand()

## Страховка: герой не должен стоять вне карты. Разделение с юнитами может вытолкнуть
## его за край (is_within_bounds допускает запас12 px), и тогда дальнейшее движение
## ломается: любая проверка проходимости требует, чтобы ТЕКУЩАЯ точка была внутри.
func _clamp_to_map() -> void:
	if alm_map == null or not alm_map.has_method("is_within_bounds"):
		return
	var margin := 12.0
	if alm_map.is_within_bounds(global_position):
		return
	var max_x := float(alm_map.map_width) * 32.0 - margin
	var max_y := float(alm_map.map_height) * 32.0 - margin
	global_position = Vector2(
		clampf(global_position.x, margin, max_x),
		clampf(global_position.y, margin, max_y))
	velocity = Vector2.ZERO

## Сколько кадров упора терпим, прежде чем снять коллизию с мешающим юнитом.
const UNSTICK_DELAY := 8
## Радиус, в котором коллизия с юнитом остаётся снятой (вернуться сюда нельзя).
const UNSTICK_RADIUS := 48.0

var _block_frames := 0
var _unit_exceptions: Array[Node2D] = []
## Последнее разрешённое направление движения. Когда скорость погашена упором,
## направление нужно, чтобы спросить у физики, КТО именно мешает (test_move).
var _last_move_dir := Vector2.ZERO

## Юниты твёрдые друг для друга (collision_layer 1, mask 1). Если герой упирается в
## стоящего гражданина, move_and_slide гасит скорость наглухо — у NPC нет своей
## логики, чтобы разойтись, и герой «застревал» намертво: у границы карты, в
## проходе между домами, у любого скопления. Через UNSTICK_DELAY кадров упора
## снимаем коллизию с конкретным юнитом, чтобы протиснуться.
## Стены, деревья и прочие клетки карты (слой 1) остаются твёрдыми.
##
## Именно test_move, а НЕ get_slide_collision(): slide-коллизии кэшируются с
## прошлого move_and_slide, и если юнит уже освобождён (враг умер → queue_free),
## в кэше остаётся мёртвый object id — add_collision_exception_with() падал с
## «Parameter "body" is null». Свежий запрос возвращает только живые тела.
## Сигнатура (проверена в 4.7): test_move(from: Transform2D, motion: Vector2,
## out: KinematicCollision2D) -> bool — коллизия приходит out-параметром.
func _escape_blocking_units() -> void:
	if state != "move" or velocity.length_squared() >= 1.0:
		_block_frames = 0
		_release_far_exceptions()
		return
	_block_frames += 1
	if _block_frames < UNSTICK_DELAY:
		return
	_block_frames = 0
	if _last_move_dir == Vector2.ZERO:
		return
	var col := KinematicCollision2D.new()
	if not test_move(global_transform, _last_move_dir * 10.0, col):
		return
	var other: Object = col.get_collider()
	if other == null or other == self or not (other is CharacterBody2D):
		return
	if not is_instance_valid(other) or not other.is_inside_tree():
		return
	var unit := other as Node2D
	if get_collision_exceptions().has(unit):
		return
	add_collision_exception_with(unit)
	_unit_exceptions.append(unit)

## Вернуть коллизию с юнитами, от которых герой уже отошёл.
func _release_far_exceptions() -> void:
	if _unit_exceptions.is_empty():
		return
	var keep: Array[Node2D] = []
	for u in _unit_exceptions:
		if not is_instance_valid(u):
			continue
		if global_position.distance_to(u.global_position) < UNSTICK_RADIUS:
			keep.append(u)
		else:
			remove_collision_exception_with(u)
	_unit_exceptions = keep

## Стоять на рельефе: поднять спрайт на высоту клетки (как в Allods16).
func _apply_relief_stand() -> void:
	if _anim == null:
		return
	var h := 0.0
	if alm_map != null and alm_map.has_method("relief_at_world"):
		h = float(alm_map.call("relief_at_world", global_position))
	_anim.position = Vector2(_anim.position.x, -h)
	if health_bar:
		# Над ГОЛОВОЙ фигуры, а не над холстом кадра: холст 64, фигура ~54.
		# Отступ 16 px (а не 6): между макушкой и шкалой живёт аура
		# благословения (16 px нимб), иначе шкала её перекрывает.
		var top := Game.unit_local_rect(self).position.y
		health_bar.position.y = top - h - 16.0

## Точка фокуса камеры: визуальный центр персонажа (середина фигурки), а не его
## «ноги» (global_position). Спрайт рисуется от подошв вверх — если центрировать
## на global_position, герой всегда будет выше середины экрана.
func camera_focus() -> Vector2:
	if _anim == null:
		return global_position
	return global_position + Vector2(0, _anim.position.y - _anim.visual_height() * 0.5)

## Точка старта снаряда заклинания: чуть выше середины фигурки (на уровне рук/
## груди). Не «ноги» — иначе снаряд вылетает из-под ступней.
func cast_origin() -> Vector2:
	if _anim == null:
		return global_position
	return global_position + Vector2(0, _anim.position.y - _anim.visual_height() * 0.62)

func move_to_target(delta):
	if _path.size() > 0:
		_follow_path(delta)
	if _path.size() > 0:
		return
	# Пустой путь (BFS-лимит / частичный маршрут до «ближайшей к цели» клетки):
	# идём НАПРЯМУЮ к player_target, а не встаем (иначе на 192×192 — рывки).
	var dist := Game.player_target.distance_to(global_position)
	if dist > 8.0:
		var dir := Game.safe_dir(global_position, Game.player_target)
		var speed_factor := _height_speed_factor(Game.player_target)
		_move_checked(dir, move_speed * speed_factor, delta)
		if velocity.length_squared() < 1.0:
			# Упёрся / цель недостижима — останавливаемся, не дёргаемся.
			state = "idle"
			velocity = Vector2.ZERO
			Game.player_target = global_position
	else:
		state = "idle"
		velocity = Vector2.ZERO

## Начать движение по маршруту (центры клеток из alm_map.find_path).
func begin_path(path: Array) -> void:
	if is_dead:
		return
	_path = path
	_stuck_frames = 0

## Полная остановка (используется при входе в здание/паузах).
func stop_movement() -> void:
	if is_dead:
		return   # панель не имеет права «поднять» труп в idle
	_cancel_casting()
	state = "idle"
	velocity = Vector2.ZERO
	_path.clear()
	Game.player_target = global_position

## Идти по маршруту: к очередной точке; при упоре 12 кадров — остановиться.
func _follow_path(delta: float) -> void:
	if _path.is_empty():
		return
	var wp: Vector2 = _path[0]
	if global_position.distance_to(wp) <= 6.0:
		_path.pop_front()
		if _path.is_empty():
			return
		wp = _path[0]
	var dir := Game.safe_dir(global_position, wp)
	var speed_factor := _height_speed_factor(wp)
	_move_checked(dir, move_speed * speed_factor, delta)
	if velocity.length_squared() < 1.0:
		_stuck_frames += 1
		if _stuck_frames > 20:
			_path.clear()
			state = "idle"
	else:
		_stuck_frames = 0

func chase_target(delta):
	if attack_target and is_instance_valid(attack_target):
		# Цель умерла (падение/разложение) — прекращаем погоню
		if attack_target.is_in_group("enemy") and not Game.enemies.has(attack_target):
			attack_target = null
			state = "idle"
			velocity = Vector2.ZERO
			return
		# Дистанция боя — между КОРПУСАМИ (реальная фигура), плюс длина оружия.
		var range_to_enemy := Game.units_range(self, attack_target)
		if range_to_enemy <= Game.attack_reach(self):
			_path.clear()
			state = "attack"
			velocity = Vector2.ZERO
			return
		# Путь к врагу: перепланировка ~1.2 с + случайный старт
		if _path.is_empty():
			_repath_timer -= delta
			if _repath_timer <= 0.0:
				_repath_timer = 1.2 + randf() * 0.5
				if alm_map != null and alm_map.has_method("find_path"):
					begin_path(alm_map.find_path(global_position, attack_target.global_position))
		if _path.size() > 0:
			_follow_path(delta)
		else:
			var direction = Game.safe_dir(global_position, attack_target.global_position)
			var speed_factor = _height_speed_factor(attack_target.global_position)
			_move_checked(direction, move_speed * speed_factor, delta)
	else:
		state = "idle"
		velocity = Vector2.ZERO

func attack_enemy(delta):
	if attack_target and is_instance_valid(attack_target):
		# Враг убежал из радиуса — догоняем, а не бьём в пустоту
		if Game.units_range(self, attack_target) > Game.attack_reach(self) + 8.0:
			state = "chase"
			_impact_timer = -1.0
			_swing_target = null
			return
		# Цель мертва (труп/разложение) — прекращаем махать по трупу
		if not Game.enemies.has(attack_target):
			attack_target = null
			state = "idle"
			velocity = Vector2.ZERO
			_impact_timer = -1.0
			_swing_target = null
			return
		if attack_cooldown <= 0.0 and _impact_timer < 0.0:
			var damage = get_damage_min() + randi() % (get_damage_max() - get_damage_min() + 1)
			# МАГ с посохом: удар — сфера, но теперь он платит ману.
			# Раньше это была бесплатная магия: урон ближнего боя (body+blade_skill)
			# шёл через magic_damage за 0 маны — сильнее Fire_Ball за 15 маны.
			if Game.hero_class == "mage" and weapon == "staff":
				var sphere := _active_sphere()
				attack_cooldown = GameConfig.getf("combat", "attack_cooldown")
				# Без маны посох бьёт как слабое физическое оружие
				if not Game.debug_magic and has_mana and current_mana < GameConfig.geti("magic", "staff_mana_cost"):
					Game.deal_damage(attack_target, maxi(1, int(get_damage_min() / 2.0)), "physical", "", self)
					_sound_weapon_attack()
					return
				if Game.is_miss(self, attack_target):
					print("Промах! Шанс был %d%%." % Game.hit_chance(Game.unit_attack(self), Game.unit_defense(attack_target)))
					DamageNumber.show_at(attack_target.global_position, 0, "miss")
				else:
					var staff_dmg := Game.spell_damage(self, "Fire_Arrow", sphere, get_damage_min())
					StatusEffects.break_invisibility(self)
					Game.deal_damage(attack_target, staff_dmg, "magic", sphere, self)
					SpellVFX.impact_burst(attack_target.global_position, sphere, false)
				if not Game.debug_magic:
					current_mana = maxi(0, current_mana - GameConfig.geti("magic", "staff_mana_cost"))
				_play_sphere_sound(sphere)
				_apply_spell_experience(sphere)
				return
			# Старт замаха: урон и цель фиксируются ЗДЕСЬ.
			# Impact бьёт _swing_target, а не live attack_target — иначе
			# _process_action_mode может переключить цель между кадрами.
			print("Атакуем! Урон: ", damage)
			_pending_attack_damage = damage
			_swing_target = attack_target
			_impact_timer = UnitDB.attack_delay(anim_set_name())
			attack_cooldown = GameConfig.getf("combat", "attack_cooldown")
		elif _impact_timer >= 0.0:
			_impact_timer -= delta
			if _impact_timer < 0.0:
				_impact_timer = -1.0
				var victim: Node2D = _swing_target if is_instance_valid(_swing_target) else attack_target
				_swing_target = null
				if victim == null or not Game.enemies.has(victim):
					return
				# Повторная проверка дистанции на кадре удара: цель могла убежать.
				if Game.units_range(self, victim) > Game.attack_reach(self) + 12.0:
					return
				# Единая точка: промах по hit_chance(атака, защита), далее Game.deal_damage
				# (поглощение бронёй → take_damage → щит → HP).
				if Game.is_miss(self, victim):
					print("Промах! Шанс был %d%%." % Game.hit_chance(Game.unit_attack(self), Game.unit_defense(victim)))
				else:
					Game.deal_damage(victim, _pending_attack_damage, "physical", "", self)
					_sound_weapon_attack()
				_apply_attack_experience(victim, _pending_attack_damage)
	else:
		state = "idle"
		_impact_timer = -1.0
		_swing_target = null

## Герой доворачивается к курсору, когда сам не занят направлением:
## в стойке, в замахе каста и в состоянии "casting". В движении и бою
## направление задаёт скорость/цель — туда не лезем.
func _update_facing_mouse(delta: float) -> void:
	if _anim == null:
		return
	if state != "idle" and state != "casting":
		return
	# Курсор под мышью в мировых координатах; мёртвая зона вокруг героя —
	# чтобы не дёргался, когда курсор стоит на самом персонаже.
	var to_mouse := get_global_mouse_position() - global_position
	if to_mouse.length() < 24.0:
		return
	_anim.set_direction_vec(to_mouse)
	if _anim is UnitAnim:
		(_anim as UnitAnim)._advance_rotation(delta)

## Звук удара оружием героя (ключи SoundDB: swing/weapon/bow).
func _sound_weapon_attack() -> void:
	var key := "combat.swing.light"
	match weapon:
		"sword": key = "combat.weapon.sword"
		"axe": key = "combat.weapon.axe"
		"club": key = "combat.weapon.blunt"
		"bow": key = "combat.bow"
		"xbow": key = "combat.bow"
		"pike": key = "combat.swing.heavy"
		"staff": key = "combat.swing.light"
		_:
			var s := str(SoundDB.sound_at(UnitDB.unit_sound(anim_set_name()), 0))
			if s != "":
				key = s
	SoundDB.play(key)
	# Короткий выкрик — не на каждый удар, иначе превращается в кашу.
	if randf() < 0.3:
		_hero_voice("attack", randi_range(1, 3))

## Реплика героя: пол выбирает набор голоса (george / bella).
func _hero_voice(kind: String, idx: int) -> void:
	var set_name := "female" if str(Game.hero_gender) == "female" else "male"
	SoundDB.play("voice.hero.%s.%s.%d" % [set_name, kind, idx])

## Мана за удар посохом (магический сферный удар).

## Магический урон: база + Mind + навык сферы (как в Allods2).
## Оставлено для совместимости: реальная формула живёт в Game.spell_damage /
## Game.spell_power, чтобы урон, лечение и щит считали одно и то же.
func magic_damage(base: int, sphere: String) -> int:
	return int(round(float(base) * (1.0 + Game.spell_power(self, sphere) / 100.0)))


## Звук сферы для удара посохом (не полного заклинания).
func _play_sphere_sound(sphere: String) -> void:
	match sphere:
		"Fire": SoundDB.play("magic.fire.bolt")
		"Water": SoundDB.play("magic.ice.bolt")
		"Air": SoundDB.play("magic.lightning")
		"Earth": SoundDB.play("magic.earth.bolt")
		"Astral": SoundDB.play("magic.heal")

## Активная сфера мага (для удара посохом/панели сфер): сфера стартовой книги,
## иначе первая уже изученная. Fallback — Fire (на старте всегда есть книга сферы).
func _active_sphere() -> String:
	if Game.hero_start_book != "":
		var b := SpellDB.sphere_of_book(Game.hero_start_book)
		if b != "":
			return b
	for sp in ["Fire", "Water", "Air", "Earth", "Astral"]:
		if sphere_books.get(sp, false):
			return sp
	return "Fire"

## Навык сферы (для UI/урона): 0-100.
func sphere_skill(sphere: String) -> int:
	match sphere:
		"Fire": return fire_skill
		"Water": return water_skill
		"Air": return air_skill
		"Earth": return earth_skill
		"Astral": return astral_skill
	return 0

## Заклинания героя (для книги заклинаний): выученные + свитки с зарядами.
func known_spell_list() -> Array:
	var out: Array = []
	for name in known_spells:
		out.append(name)
	out.sort()
	return out

## Атакующие заклинания (для быстрых клавиш) в порядке базы.
func _attack_spells() -> Array:
	var out: Array = []
	for name in known_spell_list():
		var kind := SpellDB.kind_of(name)
		if kind in ["attack", "area"]:
			out.append(name)
	return out

## Есть ли у героя заклинание (книга/свиток) и можно ли кастовать сейчас.
func has_spell(name: String) -> bool:
	return known_spells.has(name)

## Заряды заклинания: -1 = выучено навсегда (маг, из книги), 0 = нет, N = свитки.
func spell_charges(name: String) -> int:
	if not known_spells.has(name):
		return 0
	return int(known_spells[name].get("charges", 0))
## Стоимость каста: маг платит ману, воин — заряд свитка.
## В тест-режиме (Game.debug_magic) мана и кулдаун игнорируются.
func can_cast(name: String) -> bool:
	if not known_spells.has(name):
		return false
	if state == "casting":
		return false
	if not Game.debug_magic and float(cast_cooldowns.get(name, 0.0)) > 0.0:
		return false
	var charges := spell_charges(name)
	if charges > 0:
		return true       # есть заряд свитка
	if Game.debug_magic:
		return true
	if charges == -1 and has_mana:
		return current_mana >= SpellDB.mana_cost(name)   # маг за ману
	return false


## Одноразовый замах каста: длительность — полная сумма attack-блока набора
## (у всех наборов героя 3 фазы), с запасом на кадр.
func _play_cast_swing() -> void:
	# Кастер обязан остановиться: каст на ходу был невозможен визуально
	# (жалоба игрока 21.10). Гасим путь и цель движения — иначе state = "move"
	# вернётся на следующем кадре и герой пойдёт дальше, не доиграв замах.
	_path.clear()
	velocity = Vector2.ZERO
	Game.player_target = global_position
	if state == "move" or state == "chase":
		state = "idle"
	var times: Array = UnitDB.block_times(anim_set_name(), "attack_t", UnitDB.attack_phases(anim_set_name()))
	var total := 0.5
	for t in times:
		total += float(t)
	_cast_swing_left = total
	if _anim:
		_anim.play(UnitAnim.Anim.ATTACK, true)

## Использовать заклинание по имени. Возвращает true, если каст начат.
## При cast_time > 0 входит в состояние "casting" и доводит эффект позже.
func cast_spell(name: String, target_position: Vector2, target_node: Node2D = null) -> bool:
	# Страховка: на тактической паузе не кастуем ни по клику, ни авто-кастом,
	# ни свитком. Раньше проверки не было вовсе (корень сцены Always).
	if Game.is_paused:
		return false
	if not can_cast(name):
		return false
	var spell: Dictionary = SpellDB.get_spell(name)
	if spell.is_empty():
		return false
	var target: Node2D = target_node if is_instance_valid(target_node) else self
	var cast_time := SpellDB.cast_time_of(name)
	if cast_time > 0.0 and not Game.debug_magic:
		_begin_casting(name, spell, target_position, target, cast_time)
		return true
	_commit_cast(name, spell, target_position, target)
	return true


## Фаза подготовки: герой стоит на месте, показывается телеграф.
func _begin_casting(name: String, spell: Dictionary, target_position: Vector2,
		target: Node2D, cast_time: float) -> void:
	_pending_cast = {
		"name": name, "spell": spell,
		"pos": target_position, "target": target,
		"left": cast_time, "total": cast_time,
	}
	state = "casting"
	velocity = Vector2.ZERO
	_path.clear()
	SpellVFX.cast_telegraph(cast_origin(), str(spell.get("sphere", "")), cast_time)


## Каст прерван уроном или сменой цели.
func _cancel_casting() -> void:
	if state == "casting":
		_pending_cast = {}
		state = "idle"


func _tick_casting(delta: float) -> void:
	if state != "casting" or _pending_cast.is_empty():
		return
	_pending_cast["left"] = float(_pending_cast["left"]) - delta
	if float(_pending_cast["left"]) > 0.0:
		return
	var pname := str(_pending_cast["name"])
	var pspell: Dictionary = _pending_cast["spell"]
	var ppos: Vector2 = _pending_cast["pos"]
	var ptarget: Node2D = _pending_cast["target"]
	_pending_cast = {}
	state = "idle"
	_commit_cast(pname, pspell, ppos, ptarget)


## Списание ресурса + кулдаун + сам эффект. Вызывается в момент применения.
func _commit_cast(name: String, spell: Dictionary, target_position: Vector2, target: Node2D) -> void:
	var charges := spell_charges(name)
	if charges > 0:
		var left := charges - 1
		if left <= 0:
			known_spells.erase(name)   # свиток израсходован — ячейка гаснет
		else:
			known_spells[name]["charges"] = left
	elif has_mana and not Game.debug_magic:
		current_mana = maxi(0, current_mana - SpellDB.mana_cost(name))
	# Кулдаун — от познания магии (навык сферы + разум), а не только база.
	cast_cooldowns[name] = Game.spell_cooldown(self, name)
	StatusEffects.break_invisibility(self)   # атака срывает невидимость
	_cast_spell_effect(name, spell, target_position, target)
	_apply_spell_experience(str(spell.get("sphere", "")))


## Свиток: применить заклинание 1 раз. ВОЗВРАЩАЕТ bool — раньше был void,
## и game.gd безусловно удалял предмет, даже если эффекта не было.
## power — сила свитка (50 обычный / 100 эльфийский): ею заменяется навык
## героя при расчёте урона.
func apply_scroll_to_target(name: String, target: Node2D, power: float = -1.0) -> bool:
	var spell: Dictionary = SpellDB.get_spell(name)
	if spell.is_empty():
		push_warning("Свиток ссылается на заклинание, которого нет в базе: " + name)
		return false
	if target == null or not is_instance_valid(target):
		return false
	_cast_spell_effect(name, spell, target.global_position, target, power)
	# Кулдаун — по магии, заложенной в свиток (50/100), а не по навыку того,
	# кто его прочитал: иначе воин спамил бы свитками кликами.
	cast_cooldowns[name] = Game.spell_cooldown(self, name, power)
	_apply_spell_experience(str(spell.get("sphere", "")))
	return true


## Свиток по ТОЧКЕ (area/wall/по месту) — когда под курсором нет юнита.
func apply_scroll_to_target_point(name: String, point: Vector2, power: float = -1.0) -> bool:
	var spell: Dictionary = SpellDB.get_spell(name)
	if spell.is_empty():
		push_warning("Свиток ссылается на заклинание, которого нет в базе: " + name)
		return false
	_cast_spell_effect(name, spell, point, self, power)
	cast_cooldowns[name] = Game.spell_cooldown(self, name, power)
	_apply_spell_experience(str(spell.get("sphere", "")))
	return true

## Звук заклинания: ключ из базы, по сфере на запас.
func _play_spell_sound(name: String, sphere: String) -> void:
	var key := SpellDB.sound_of(name)
	if key == "":
		match sphere:
			"Fire": key = "magic.fire.bolt"
			"Water": key = "magic.ice.bolt"
			"Air": key = "magic.lightning"
			"Earth": key = "magic.earth.bolt"
			"Astral": key = "magic.heal"
	if key != "":
		SoundDB.play(key)

## Общий порядок применения заклинания (книга на панели ИЛИ свиток с прицелом).
## Раньше здесь было 5 веток, и 8 разных «баффов» сводились к одному щиту.
## power_override — сила свитка (50/100): ею заменяется навык героя при
## расчёте УРОНА. Для баффов и лечения сила свитка не применяется (решение
## игрока: свиток влияет только на урон).
func _cast_spell_effect(name: String, spell: Dictionary, target_position: Vector2,
		target_node: Node2D, power_override: float = -1.0) -> void:
	var sphere := str(spell.get("sphere", ""))
	var kind := str(spell.get("kind", "buff"))
	var dmg := int(spell.get("damage", 0))
	var area := float(spell.get("area", 0))
	_play_spell_sound(name, sphere)
	# Анимация каста: подъём и опускание посоха. Магия вылетает из центра
	# (cast_origin), но герой не стоит столбом (жалоба игрока 21.10).
	_play_cast_swing()
	SpellVFX.cast_flash(cast_origin(), sphere)
	# Эффекты «на себя» (вампиризм Drain_Life) — всегда на кастере, даже если
	# заклинание летит снарядом в сторону.
	_apply_self_effects(spell)

	match kind:
		"attack", "area":
			# Призматическое сияние бьёт по нескольким целям сразу.
			if str(spell.get("projectile", "")) == "chain":
				_cast_chain_spell(name, spell, sphere, dmg, area, target_position,
					power_override)
			# Метель и ядовитое облако — не снаряд, а зона с длительностью.
			elif str(spell.get("zone_style", "")) != "":
				_create_zone(target_position, name, sphere, power_override)
			else:
				_fire_spell_projectile(name, sphere, dmg, area, target_position,
					power_override)
		"heal":
			_heal_target(target_node, name, dmg)
		"buff":
			_apply_effects(target_node, spell)
		"debuff":
			# Враждебные эффекты: Curse/Slow/Darkness/Stone_Curse/Control_Spirit
			if area > 0.0:
				StatusEffects.apply_area(target_position, area, spell, self)
			else:
				StatusEffects.apply_spell(target_node, spell, self)
			SpellVFX.aura_ring(target_node, sphere, "debuff")
		"wall":
			_create_wall(target_position, name, sphere, power_override)
		"raise":
			_raise_dead(target_position, name)
		"self":
			match name:
				"Teleport": _teleport_to(target_position)
				"Light": _cast_light()
				"Summon": _cast_summon()
				_: _apply_effects(self, spell)
		_:
			_apply_effects(target_node, spell)


## Эффекты, которые всегда вешаются на самого кастера (вампиризм).
func _apply_self_effects(spell: Dictionary) -> void:
	for e in spell.get("effects", []):
		if not (e is Dictionary):
			continue
		if str((e as Dictionary).get("type", "")) != "vampirism":
			continue
		StatusEffects.apply_spell(self, {"effects": [e]}, self)


## Наложить эффекты заклинания на цель и показать постоянную ауру.
## Раньше был только одноразовый aura_ring на 0.45 с: «Защита от огня» живёт
## 90 секунд, но была видна меньше секунды, и игрок не понимал, что бафф держится.
func _apply_effects(target: Node2D, spell: Dictionary) -> void:
	var applied := StatusEffects.apply_spell(target, spell, self)
	if applied <= 0:
		return
	_attach_auras(target, spell)
	# Одноразовое кольцо рисуем ТОЛЬКО если постоянной ауры нет: иначе на касте
	# сразу два эффекта в одной точке, и выглядит как «дёрнулось и наложилось».
	if not _has_persistent_aura(target):
		SpellVFX.aura_ring(target, str(spell.get("sphere", "")), "buff")
	else:
		SpellVFX.ground_dust(target)


## Есть ли на цели постоянная аура (сопротивление/щит/ветер).
func _has_persistent_aura(target: Node2D) -> bool:
	if not is_instance_valid(target):
		return false
	for c in target.get_children():
		if c is SpellAura:
			return true
	return false


## Постоянные ауры по типу эффекта: щит — сетка, сопротивление — свечение
## над головой в цвет стихии, ускорение — ветер у ног.
func _attach_auras(target: Node2D, spell: Dictionary) -> void:
	for e in spell.get("effects", []):
		if not (e is Dictionary):
			continue
		var effect := e as Dictionary
		var etype := str(effect.get("type", ""))
		var esphere := str(effect.get("sphere", spell.get("sphere", "")))
		match etype:
			"shield":
				SpellAura.attach(target, "shield", esphere, "shield")
			"resist":
				SpellAura.attach(target, "resist", esphere, "resist")
			"haste":
				SpellAura.attach(target, "haste", esphere, "haste")
			"bless":
				SpellAura.attach(target, "bless", esphere, "bless")
			_:
				pass

## Снаряд заклинания (с анимацией из assets/projectiles/<folder>/).
## Если папки снаряда нет (эффект отсутствует — Haste/Invisibility/Summon...),
## применяем заклинание мгновенно без летящего снаряда.
func _fire_spell_projectile(name: String, sphere: String, dmg: int, area: float,
		target_position: Vector2, power_override: float = -1.0) -> void:
	var final_dmg := Game.spell_damage(self, name, sphere, dmg, power_override)
	if SpellDB.projectile_folder(name) == "":
		# Эффекта-снаряда нет: мгновенный урон по цели/точке (напр. Animate_Dead).
		var enemy := get_nearest_enemy(target_position, 120.0)
		if enemy != null:
					Game.deal_damage(enemy, final_dmg, "magic", sphere, self)
		return
	if area > 0.0:
		# Областное: летит к точке, взрывается (урон по радиусу из projectile.gd)
		create_spell_projectile(name, cast_origin(), target_position, final_dmg, area)
	else:
		# Одиночная цель: снаряд летит до врага у точки прицела
		var enemy := get_nearest_enemy(target_position, 200.0)
		var to := enemy.global_position if enemy != null else target_position
		create_spell_projectile(name, cast_origin(), to, final_dmg, 0.0)

## Создать снаряд с анимацией фаз из папки снаряда.
func create_spell_projectile(name: String, from: Vector2, to: Vector2, damage: int, area: float) -> void:
	var scene := preload("res://scenes/projectile.tscn")
	if scene == null:
		return
	var p: Projectile = scene.instantiate()
	p.start_pos = from
	p.target_pos = to
	p.damage = damage
	p.projectile_owner = self
	p.spell_name = name
	p.spell_area = area
	p.speed = SpellDB.projectile_speed_of(name)
	# Раньше снаряд добавлялся в get_tree().root и переживал смену сцены
	# (перезапуск/портал), удерживая ссылку на освобождённого героя.
	var scene_root := get_tree().current_scene
	if scene_root != null:
		scene_root.add_child(p)
	else:
		get_tree().root.add_child(p)

## Лечение выбранной цели (герой по умолчанию): HP, но не выше максимума.
## Величина = база заклинания * power_coef * (1 + spell_power/100) —
## та же формула, что урона (раньше тут стояло отдельное mind/5).
func _heal_target(target: Node2D, spell_name: String, base: int) -> void:
	if target == null or not is_instance_valid(target):
		target = self
	var sphere := SpellDB.sphere_of(spell_name)
	var amount := Game.spell_damage(self, spell_name, sphere, maxi(1, -base))
	var before: Variant = target.get("current_hp")
	target.call("heal_amount", amount)
	# Красный крест над головой — появление лечения было видно только цифрой.
	var after: Variant = target.get("current_hp")
	if after is int and before is int and int(after) > int(before):
		SpellAura.heal_cross(target)


## Восстановить HP себе или союзнику. Возвращает реально восстановленное.
func heal_amount(amount: int) -> int:
	if amount <= 0 or current_hp >= max_hp:
		return 0
	if is_dead or state == "dead" or state == "decay" or state == "corpse":
		return 0
	var healed := mini(max_hp, current_hp + amount) - current_hp
	if healed <= 0:
		return 0
	current_hp += healed
	DamageNumber.show_at(global_position, healed, "heal")
	if health_bar:
		health_bar.update_bars(current_hp, current_mana)
	return healed

## Призматическое сияние: молнии от мага сразу к нескольким целям.
## Раньше это был одиночный снаряд — попадание было одно, а по названию
## «сияние» ожидалось веерное сражение. Цели — до CHAIN_MAX ближайших врагов
## в радиусе area от точки каста; между ними рисуются молнии.
## Радиус веера вокруг точки прицела. Раньше он же был и радиусом поиска целей
## (max(area, 96) = 96 px), и теснота была не в веере, а в том, что цели искались
## от КУРСОРА без всякой проверки расстояния до мага.

func _cast_chain_spell(spell_name: String, spell: Dictionary, sphere: String,
		dmg: int, area: float, target_position: Vector2,
		power_override: float = -1.0) -> void:
	var origin := cast_origin()
	# Дальность заклинания — единственный предел досягаемости. Раньше она из
	# базы не читалась вообще, и клик в 260 px бил врагов там, сколько бы
	# далеко от мага они ни стояли: молния летела через полкарты.
	var reach := SpellDB.range_of(spell_name)
	var targets: Array = _chain_targets(target_position, maxf(area, GameConfig.getf("magic", "chain_radius")),
		origin, reach)
	if targets.is_empty():
		# Никого в досягаемости — бьём в точку прицела, чтобы каст не пропадал
		# впустую.
		_fire_spell_projectile(spell_name, sphere, dmg, area, target_position,
			power_override)
		return
	# Урон через общий Game.spell_damage: сила заклинания, разум и навык должны
	# влиять на «сияние» так же, как на снаряды. Раньше здесь передавался сырой
	# dmg из БД, и призматическое сияние было единственным заклинанием,
	# полностью игнорировавшим развитие мага.
	var final_dmg := Game.spell_damage(self, spell_name, sphere, dmg, power_override)
	# Каждой цели — свой цвет радуги, иначе все лучи выходили цветом сферы.
	var color_index := 0
	for t in targets:
		if not is_instance_valid(t):
			continue
		Game.deal_damage(t, final_dmg, "magic", sphere, self)
		SpellVFX.chain_arc(origin, t.global_position, sphere,
			SpellVFX.rainbow_color(color_index))
		SpellVFX.hit_flash(t)
		color_index += 1
	_apply_spell_experience(sphere)


## Живые враги в веере вокруг aim, но не дальше reach от точки кастера.
##
## Только ВРАГИ: лучи идут от мага, и бить своих, нейтральных жителей или
## наёмников «призматическим сиянием» неправильно — это урон по врагам.
##
## Два ограничения делают разные вещи и оба нужны:
##   * reach (дальность заклинания) — жёсткая досягаемость от мага;
##   * radius (веер) — размер вспышки вокруг прицела, то есть прицел по-прежнему
##     выбирает, в кого бить первым. Без сортировки по прицелу в драке с толпой
##     цель выбиралась бы случайно.
func _chain_targets(aim: Vector2, radius: float, origin: Vector2,
		reach: float) -> Array:
	var found: Array = []
	for e in Game.enemies:
		if e == null or not is_instance_valid(e):
			continue
		# Node.get() в Godot 4 принимает ОДИН аргумент, поэтому состояние
		# трупа проверяем через "поле в узле", а не get("state", "").
		if "state" in e and str(e.get("state")) in ["dying", "decay", "corpse"]:
			continue
		if Game.fog != null and Game.fog.blocks_process(e.global_position):
			continue
		var pos := (e as Node2D).global_position
		if reach > 0.0 and origin.distance_to(pos) > reach:
			continue
		if pos.distance_to(aim) > radius:
			continue
		found.append(e)
	# Сортируем по расстоянию до точки прицела, чтобы лучи шли веером от цели.
	found.sort_custom(func(a: Node2D, b: Node2D) -> bool:
		return a.global_position.distance_squared_to(aim) \
			< b.global_position.distance_squared_to(aim))
	var out: Array = []
	for e in found:
		if out.size() >= GameConfig.geti("magic", "chain_max_targets"):
			break
		out.append(e)
	return out


## Стена (Wall of Fire / Wall of Earth). В оригинале они РАЗНЫЕ
## (spells.txt): огонь непрерывно жжёт, земля — непроходимая преграда.
## Раньше это был ColorRect 32×32 на 2 секунды: без урона и без блокировки.
## Размер стены задаётся в КЛЕТКАХ (zone_cells) — по решению игрока 6 × 2,
## и урон, спрайт и блокировка берут размер из одного и того же прямоугольника.
func _create_wall(target_position: Vector2, spell_name: String, sphere: String,
		power_override: float = -1.0) -> void:
	var spell := SpellDB.get_spell(spell_name)
	var mode := str(spell.get("wall_mode", "damage"))
	var life := float(spell.get("wall_life", 6.0))
	var cells := _zone_cells(spell, Vector2i(6, 2))
	# Ориентация стены: ПЕРПЕНДИКУЛЯРНО направлению каста. Смотрим влево или
	# вправо — стена встаёт вертикально (2×6), смотрим вверх/вниз — лежит
	# горизонтально (6×2). Игрок 28.10: «магия должна становиться вертикально».
	var aim := target_position - cast_origin()
	if absf(aim.x) >= absf(aim.y):
		cells = Vector2i(2, 6)
	var dmg := 0
	if mode != "block":
		dmg = Game.spell_damage(self, spell_name, sphere, int(spell.get("damage", 0)),
			power_override)
	SpellVFX.spawn_wall(target_position, sphere, self, life, mode, cells, dmg)


## Зона с длительностью: метель и ядовитое облако. Раньше это был одиночный
## снаряд с одним попаданием — «метель» бросала один метеор, а «облако» не
## оставляло после себя ничего, хотя в базе у обоих dot на 5–6 секунд.
func _create_zone(target_position: Vector2, spell_name: String, sphere: String,
		power_override: float = -1.0) -> void:
	var spell := SpellDB.get_spell(spell_name)
	var style := str(spell.get("zone_style", "cloud"))
	var life := float(spell.get("zone_life", 4.0))
	var cells := _zone_cells(spell, Vector2i(3, 3))
	var dmg := Game.spell_damage(self, spell_name, sphere, int(spell.get("damage", 0)),
		power_override)
	SpellVFX.spawn_zone(target_position, style, sphere, self, life, cells, dmg, 0.5)
	# Зона наносит урон и эффекты (медлен, яд) всем, кто в ней стоит.
	StatusEffects.apply_area(target_position, _zone_radius(cells), spell, self)


## Размер зоны в клетках из базы; при отсутствии поля — значение по умолчанию.
func _zone_cells(spell: Dictionary, fallback: Vector2i) -> Vector2i:
	var raw: Variant = spell.get("zone_cells", null)
	if raw is Array and (raw as Array).size() >= 2:
		return Vector2i(maxi(1, int((raw as Array)[0])), maxi(1, int((raw as Array)[1])))
	return fallback


## Радиус зоны в пикселях — половина её диагонали, для area-эффектов.
func _zone_radius(cells: Vector2i) -> float:
	return Vector2(cells.x * 32, cells.y * 32).length() * 0.5


## Animate_Dead: поднять ближайший труп в союзника на lifespan секунд.
func _raise_dead(target_position: Vector2, spell_name: String) -> void:
	var best: Node2D = null
	var best_d := 120.0
	for e in Game.enemies:
		if e == null or not is_instance_valid(e):
			continue
		if not (e is Enemy):
			continue
		var st := str(e.get("state"))
		if st != "dying" and st != "decay" and st != "corpse":
			continue
		if Game.fog != null and Game.fog.blocks_process(e.global_position):
			continue
		var d: float = (e.global_position as Vector2).distance_to(target_position)
		if d < best_d:
			best_d = d
			best = e
	if best == null:
		DamageNumber.show_at(target_position, 0, "miss")
		return
	var set_name := str(best.get("anim_set"))
	var lifespan := float(SpellDB.effect_of_type(spell_name, "raise").get("lifespan", 30.0))
	var m := Mercenary.new()
	m.anim_set = set_name
	m.max_hp = 50
	m.damage = 6
	m.move_speed = 100.0
	m.lifespan = lifespan
	m.position = best.global_position
	get_tree().current_scene.add_child(m)
	Game.party.append(m)
	Game.enemies.erase(best)
	best.queue_free()
	SpellVFX.aura_ring(m, SpellDB.sphere_of(spell_name), "buff")
	SoundDB.play("magic.animate_dead")


## Свет (Astral, self): мягкая светлая сфера вокруг героя на несколько секунд.
## Визуальный маркер-вспышка (системы освещения в проекте нет).
func _cast_light() -> void:
	SpellVFX.spawn_light(global_position, 4.0)

## Призыв (Astral, self): союзный миньон (наёмник с монстрячьим сетом),
## следует за героем и атакует врагов, исчезает через 45 секунд (или при смерти).
func _cast_summon() -> void:
	var m := Mercenary.new()
	m.anim_set = "monsters/orc"
	m.max_hp = 60
	m.damage = 8
	m.move_speed = 110.0
	m.lifespan = 45.0
	m.position = global_position + Vector2(30, 6)
	get_tree().current_scene.add_child(m)
	Game.party.append(m)
	SoundDB.play("ui.click")
	print("Призыв: союзный монстр")

## Телепорт к точке (в пределах карты).
## Телепорт в точку прицела. Точку выбирает игрок (target "point" в базе),
## раньше заклинание было target "self" — прицела не было, и герой просто
## никуда не перемещался. Отказ по непроходимой клетке теперь виден.
func _teleport_to(target_position: Vector2) -> void:
	if alm_map and alm_map.has_method("is_walkable_world") and not alm_map.is_walkable_world(target_position):
		SpellVFX.cast_telegraph(target_position, "Astral", 0.2)
		return
	SpellVFX.cast_flash(global_position, "Astral")
	global_position = target_position
	reset_physics_interpolation()
	SpellVFX.cast_flash(target_position, "Astral")
	SpellVFX.aura_ring(self, "Astral", "buff")
	if health_bar:
		health_bar.update_bars(current_hp, current_mana)

## Урон по области вокруг точки (объектам карты и врагам) через Game.deal_damage_area.
func _damage_area_at(pos: Vector2, radius: float, dmg: int, sphere: String = "") -> void:
	if alm_map and alm_map.has_method("damage_area"):
		alm_map.damage_area(pos, radius, dmg)
	var targets: Array = []
	for enemy in Game.enemies:
		if not is_instance_valid(enemy):
			continue
		if Game.fog != null and Game.fog.blocks_process(enemy.global_position):
			continue
		if enemy.global_position.distance_to(pos) <= radius:
			targets.append(enemy)
	Game.deal_damage_area(targets, dmg, "magic", sphere, self)

## Изучить книгу магии (только маг, навсегда): книга стихии открывает всю
## сферу ("Book Fire"), книга одного заклинания — только его ("Book Fire Arrow").
## Книга расходуется (уходит из склада). true — если что-то выучено.
func learn_book(item_name: String) -> bool:
	if not has_mana:
		return false   # воин не может читать книги магии
	var sphere := SpellDB.sphere_of_book(item_name)
	var gained: Array = []
	if sphere != "":
		sphere_books[sphere] = true
		for spell in SpellDB.spells_of_sphere(sphere):
			if not known_spells.has(spell):
				known_spells[spell] = {"charges": -1}
				gained.append(spell)
		if gained.is_empty():
			return false   # вся сфера уже выучена — книгу не тратим
		print("Изучена книга стихии %s: +%d заклинаний" % [sphere, gained.size()])
	else:
		var spell := SpellDB.spell_of_book(item_name)
		if spell == "":
			return false
		if known_spells.has(spell) and spell_charges(spell) == -1:
			return false   # уже выучено навсегда — книгу не тратим
		known_spells[spell] = {"charges": -1}
		gained.append(spell)
		print("Выучено заклинание из книги: %s" % spell)
	remove_item(item_name)
	return true

## Прочитать свиток (НЕ-маг): +1 заряд заклинания за свиток, который при этом
## расходуется. Маг читает свитки ПРИЦЕЛЬНО из склада (см. apply_scroll_to_target),
## заряды в панели магии ему не копятся.
func read_scroll(item_name: String) -> bool:
	if has_mana:
		print("Маг читает свиток прицельно из склада (заряды не копятся).")
		return false
	var spell := SpellDB.spell_from_scroll(item_name)
	if spell == "":
		return false
	if known_spells.has(spell) and spell_charges(spell) == -1:
		print("Это заклинание уже выучено навсегда — свиток не нужен.")
		return false
	if not known_spells.has(spell):
		known_spells[spell] = {"charges": 0}
	known_spells[spell]["charges"] = int(known_spells[spell]["charges"]) + 1
	remove_item(item_name)
	print("Прочитан свиток: %s, зарядов: %d" % [spell, known_spells[spell]["charges"]])
	return true

func get_nearest_enemy(click_pos: Vector2, attack_range: float) -> Node2D:
	var nearest = null
	var min_dist = attack_range

	for enemy in Game.enemies:
		if is_instance_valid(enemy):
			if Game.fog != null and Game.fog.blocks_process(enemy.global_position):
				continue
			var dist = enemy.global_position.distance_to(click_pos)
			if dist < min_dist:
				min_dist = dist
				nearest = enemy

	return nearest

## Авто-каст мага: лечение при падении HP + авто-баффы по ветке.
## Не прерывает ручной прицел (pending_spell) и не работает в casting.
var _auto_buff_accum := 0.0
var _auto_heal_accum := 0.0
var _auto_scroll_accum := 0.0


## Авто-волшебство мага: лечение себя и цели + баффы по уровню из настроек.
##
## Раньше лечение включалось ТОЛЬКО если игрок вручную назначил лечение на ПКМ
## (`Game.auto_spell`) — по умолчанию маг не лечился вообще, даже вне боя
## (жалоба 27.10). Теперь уровень авто-волшебства по умолчанию «Базовое»,
## и лечение идёт само, пока есть мана и заклинание известно.
func _tick_auto_cast(delta: float) -> void:
	if is_dead or state == "casting" or state == "dead" or state == "corpse" \
			or state == "decay" or not Game.pending_spell.is_empty():
		return
	if not Game.pending_scroll.is_empty():
		return
	# ВОИН: никаких уровней авто-волшебства. Только ОДИН свиток, помеченный
	# правой кнопкой в книге магии, и только на себя (игрок 28.10: «воин не
	# должен быть заменой магу»).
	if not has_mana:
		_tick_auto_scroll(delta)
		return
	if Game.auto_buff_tier == "none":
		return
	var ratio := GameConfig.getf("magic", "auto_heal_ratio")
	if ratio <= 0.0:
		ratio = 0.45
	# 1) Лечение — раз в секунду: порог 45 % HP, цель из настроек.
	_auto_heal_accum += delta
	if _auto_heal_accum >= 1.0:
		_auto_heal_accum = 0.0
		var heal_spell := _auto_heal_spell()
		if heal_spell != "":
			_auto_try_heal(heal_spell, ratio)
	# 2) Баффы по уровню: один бафф за интервал, чтобы не выжигать ману.
	_auto_buff_accum += delta
	var interval := GameConfig.getf("magic", "auto_buff_interval")
	if interval <= 0.0:
		interval = 2.0
	if _auto_buff_accum >= interval:
		_auto_buff_accum = 0.0
		_auto_try_buffs()


## Автокаст единственного помеченного свитка (воин): только на себя,
## по кулдауну заклинания, ровно один свиток за каст.
##
## Страховка от «купил 10 свитков и сжёг их за секунду»: каст не идёт, если
## уже кастуем, если кулдаун заклинания не прошёл, если эффект ещё висит
## (для баффа) или HP выше порога (для лечения).
func _tick_auto_scroll(delta: float) -> void:
	var item_key := Game.auto_scroll_item
	if item_key == "":
		return
	var spell := SpellDB.spell_from_scroll(item_key)
	if spell == "":
		Game.auto_scroll_item = ""
		return
	if not has_item(item_key):
		Game.auto_scroll_item = ""
		print("Авто-свиток закончился: %s — пометка снята." % item_key)
		return
	if float(cast_cooldowns.get(spell, 0.0)) > 0.0:
		return
	var kind := SpellDB.kind_of(spell)
	var effs := SpellDB.effects_of(spell)
	var et := ""
	var e_sphere := ""
	if not effs.is_empty():
		et = str((effs[0] as Dictionary).get("type", ""))
		e_sphere = str((effs[0] as Dictionary).get("sphere", ""))
	if kind == "heal":
		var mx := maxi(1, max_hp)
		var ratio := GameConfig.getf("magic", "auto_heal_ratio")
		if ratio <= 0.0:
			ratio = 0.45
		if float(current_hp) / float(mx) >= ratio:
			return
	elif kind in ["buff", "self"] and et != "":
		if StatusEffects.is_active(self, et, e_sphere):
			return
	else:
		# Боевые свитки на себя бессмысленны — автокаст не назначается.
		return
	_auto_scroll_accum += delta
	if _auto_scroll_accum < 1.0:
		return
	_auto_scroll_accum = 0.0
	if not remove_item(item_key):
		Game.auto_scroll_item = ""
		return
	var scroll_item := ItemDB.find(item_key)
	var scroll_power := SpellDB.scroll_power_of(scroll_item)
	# Кулдаун — по магии внутри свитка (50/100), а не по применению предмета.
	cast_cooldowns[spell] = Game.spell_cooldown(self, spell, scroll_power)
	_cast_spell_effect(spell, SpellDB.get_spell(spell), global_position, self,
		scroll_power)
	_apply_spell_experience(SpellDB.sphere_of(spell))


## Каким лечить (маг): выбранное вручную (ПКМ по книге), иначе первое
## ИЗУЧЕННОЕ заклинание лечения. Свиточные заряды сюда не попадают —
## свитки у мага кастуются только вручную.
func _auto_heal_spell() -> String:
	if Game.auto_spell != "" and known_spells.has(Game.auto_spell) \
			and SpellDB.kind_of(Game.auto_spell) == "heal" \
			and spell_charges(Game.auto_spell) == -1:
		return Game.auto_spell
	for sn in known_spells.keys():
		if SpellDB.kind_of(str(sn)) == "heal" and spell_charges(str(sn)) == -1:
			return str(sn)
	return ""


## Кого лечить и баффать — ОДИН список целей (настройка «Только я / Я и моя
## группа / Я, моя группа и нейтраллы»).
## Раньше для режима "party" перебирался только `Game.party` (наёмники), а сам
## маг в него не входит — поэтому он не лечил и не баффал себя.
func _auto_targets() -> Array:
	var out: Array = [self]
	if Game.auto_targets == "self":
		return out
	for m in Game.party:
		if is_instance_valid(m) and m != self:
			out.append(m)
	if Game.auto_targets == "party_neutral":
		for n in Game.npcs:
			if is_instance_valid(n) and n != self:
				out.append(n)
	return out


func _auto_try_heal(spell_name: String, ratio: float) -> void:
	if not can_cast(spell_name):
		return
	var rng := SpellDB.range_of(spell_name)
	var best: Node2D = null
	var best_hp := 1.0
	for u in _auto_targets():
		if not is_instance_valid(u) or not ("current_hp" in u) or not ("max_hp" in u):
			continue
		var mx := int(u.get("max_hp"))
		if mx <= 0:
			continue
		var cur := int(u.get("current_hp"))
		if cur >= mx:
			continue
		var r := float(cur) / float(mx)
		if r >= ratio:
			continue
		if rng > 0.0 and Game.units_range(self, u) > rng:
			continue
		if r < best_hp:
			best_hp = r
			best = u
	if best == null:
		return
	cast_spell(spell_name, best.global_position, best)


## Заклинания баффов по уровню авто-волшебства.
##
## Базовое — то, что нужно всегда: ускорение и щит. Среднее добавляет
## благословение и защиты от четырёх стихий. Максимальное — ещё невидимость.
func _auto_buff_spells_for_tier() -> Array:
	match Game.auto_buff_tier:
		"base":
			return ["Haste", "Shield"]
		"medium":
			return ["Haste", "Shield", "Bless", "Protection_from_Fire",
				"Protection_from_Water", "Protection_from_Air", "Protection_from_Earth"]
		"max":
			return ["Haste", "Shield", "Bless", "Protection_from_Fire",
				"Protection_from_Water", "Protection_from_Air", "Protection_from_Earth",
				"Invisibility"]
	return []


func _auto_try_buffs() -> void:
	var spells := _auto_buff_spells_for_tier()
	if spells.is_empty():
		return
	var candidates := _auto_targets()
	for sn in spells:
		# Уровни авто-волшебства — только для ИЗУЧЕННЫХ заклинаний (маг).
		# Свиточные заряды уровнем не тратятся: у воина автокаст один и по ПКМ.
		if spell_charges(sn) != -1:
			continue
		if not can_cast(sn):
			continue
		# Shield (kind "self") применяется только к кастеру: на союзника
		# заклинание всё равно наложилось бы на себя, но сожгло бы ману и
		# кулдаун «в пустоту».
		var self_only := SpellDB.kind_of(sn) == "self"
		var tkind := SpellDB.target_of(sn)
		var rng := SpellDB.range_of(sn)
		for u in candidates:
			if not is_instance_valid(u):
				continue
			if self_only and u != self:
				continue
			# Уже под баффом? Смотрим СФЕРУ САМОГО ЭФФЕКТА, а не заклинания.
			# У Haste/Bless/Shield/Invisibility поля `sphere` в эффекте нет, и
			# проверка по сфере заклинания ("Astral") не совпадала никогда —
			# маг перекастовывал ускорение каждые 10 с при длительности 20 с.
			var effs := SpellDB.effects_of(sn)
			var need := true
			if not effs.is_empty():
				var e0: Dictionary = effs[0]
				var et := str(e0.get("type", ""))
				var e_sphere := str(e0.get("sphere", ""))
				if et != "" and StatusEffects.is_active(u, et, e_sphere):
					need = false
			if not need:
				continue
			# Невидимость на себя — только если цель == self (щит/мана мага)
			if sn == "Invisibility" and u != self and rng <= 0.0:
				continue
			if rng > 0.0 and Game.units_range(self, u) > rng:
				continue
			# Protection range 0: только self (или касание — units_range==0)
			if rng <= 0.0 and u != self and Game.units_range(self, u) > 1.0:
				continue
			cast_spell(sn, u.global_position, u)
			return  # один бафф за тик — не выжигаем ману


func take_damage(damage: int, _attacker: Node2D) -> int:
	# Мёртвый герой больше не получает урон. `is_dead` — защёлка: `state`
	# мог быть случайно сброшен панелью/stop_movement, и труп «вставал».
	if is_dead or state == "dead" or state == "decay" or state == "corpse":
		return 0
	damage = Game.shield_reduce(self, damage)
	if damage <= 0:
		SpellVFX.shield_hit(self)
		SoundDB.play("combat.hit.shield", -6.0)
		return 0
	current_hp -= damage
	# Невидимость срывается уроном, подготовка заклинания — прерывается
	StatusEffects.break_invisibility(self)
	_cancel_casting()
	if current_hp <= 0:
		# Смерть: играем падение DYING + разложение DECAY. Паузу и экран
		# Game Over ставит ВЛАДЕЛЕЦ (game.gd::_on_hero_died), а не сам актёр:
		# get_tree().paused здесь ничего не останавливал (корень Main — ALWAYS).
		current_hp = 0
		is_dead = true
		Game.hero_dead = true
		velocity = Vector2.ZERO
		state = "dead"
		_path.clear()
		Game.player_target = global_position
		_hero_voice("death", 1)
		if health_bar:
			health_bar.visible = false
		died.emit()
	elif randf() < 0.45:
		_hero_voice("pain", randi_range(1, 2))
	return damage
