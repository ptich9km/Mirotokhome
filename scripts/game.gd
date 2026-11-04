extends Node2D
class_name Game

@onready var alm_map: Node2D = $Map
@onready var player: CharacterBody2D = $Player
@onready var camera: Camera2D = $Camera2D
@onready var ui: CanvasLayer = $UI

## Единое направление между двумя точками. Vector2.normalized() на НУЛЕВОМ векторе
## (юнит стоит ровно на вейпоинте) печатает в консоль C++-предупреждение
## «Vector2 cannot be normalized, the elements must be finite», поэтому нормализуем
## только вектор длиной больше порога.
static func safe_dir(from: Vector2, to: Vector2, fallback: Vector2 = Vector2.ZERO) -> Vector2:
	var d := to - from
	if d.length_squared() < 0.0001:
		return fallback
	return d.normalized()

## Компасная октанта вектора направления: 0..7, ЕДИНСТВЕННЫЙ источник конвенции.
##
## ИНДЕКСАЦИЯ КОНТРИКЛОКОВАЯ, 0 = СЕВЕР (вверх экрана):
##   0=север  7=северо-восток  6=восток  5=юго-восток
##   4=юг     3=юго-запад      2=запад  1=северо-запад
##
## Вынесено из UnitAnim.set_direction_vec, потому что конвенцию теперь читают
## ДВА бэкенда анимации (спрайт-листы и 2D-риг). Дублировать формулу означало
## бы, что рано или поздно риг начнёт смотреть не туда — а направление в бою
## игровая информация, а не украшение. Сторож: tests/anim_contract_smoke.gd.
static func unit_octant(dir_vec: Vector2) -> int:
	if dir_vec.length_squared() < 0.001:
		return -1
	var ang := rad_to_deg(dir_vec.angle())  # -180..180, 0 = вправо
	var d := int(round((ang - 90.0) / 45.0)) % 8
	if d < 0:
		d += 8
	return d

## Ближайший кардинальный октант: диагональ схлопывается на соседний кардинал.
## Нужен ригу, где нарисовано 3 ракурса (юг/восток/север), а мир запрашивает 8.
static func snap_octant_to_cardinal(octant: int) -> int:
	if octant < 0:
		return -1
	return posmod(int(round(float(octant) / 2.0)) * 2, 8)

## Разрешён ли шаг юнита по карте (общая проходимость для игрока и NPC).
static var is_paused: bool = false
static var player_target: Vector2 = Vector2.ZERO
static var enemies: Array = []
static var npcs: Array = []               # мирные жители (Npc) вне Game.enemies
static var hero: Node2D = null            # игрок (для наёмников/лута)
static var fog: FogOfWar = null         # fog of war of the hero map (19.10)
static var pending_fog_rle: String = "" # saved fog mask, applied by FogOfWar
static var pending_events: Array = []   # saved events, applied by EventSystem
## Сохранённые квесты (офферы, активные, история): их применяет QuestSystem.
## Пусто — новая игра; applied=true — блок уже прочитан (не применяем дважды).
static var pending_quests: Dictionary = {}
static var pending_quests_applied: bool = false
## Форпосты фракций (пакет B, 28.10): что стоит на текущей карте и какие уже
## захвачены. Ключ захвата включает карту (зона|сектор|сид), потому что id
## лагеря ("op0") повторяется на каждой карте.
static var outposts: Array = []
static var outposts_captured: Dictionary = {}
static var pending_outposts_captured: Dictionary = {}
static var _hit_sfx_ms: int = 0          # троттл звука попадания (единая точка урона)
## Slot the running game came from ("" — new game). The slot folder holds the
## map files, so a zone change reuses its maps instead of regenerating them.
static var loaded_slot: String = ""
static var party: Array = []              # наёмники (Mercenary) из таверны
## Отряд из сейва v2: данные без узлов. game.gd создаёт наёмников, когда карта
## уже собрана (наёмнику нужен проходимый тайл). Пусто — восстанавливать нечего.
static var pending_party: Array = []
static var mana_regen_accum: float = 0.0
static var _trauma: float = 0.0
static var _trauma_t: float = 0.0
static var action_mode: String = "none"  # none, follow, attack, guard
static var action_target: Node2D = null
static var pending_scroll: Dictionary = {}   # прицеливание свитка: {"spell","item_key"}
## Контекст для тематического курсора (cursor_layer.gd):
## "" — обычный, "cast" — прицел (по pending_*), "buy" — магазин,
## "work" — мастерская. Ставится в ui.gd open_shop/open_workshop.
static var cursor_context: String = ""
static var pending_spell: Dictionary = {}    # выбор заклинания из книги: {"name"}
static var hotbar: Dictionary = {}           # быстрый вызов: слот 0..8 (клавиши 1..9) -> имя заклинания
## Авто-волшебство мага: настройки в Esc → Настройки (раздел «Магия»).
## auto_buff_tier: base (ускорение+щит) | medium (+благословение и защиты) | max (+невидимость).
## auto_targets:  self (только я) | party (я и группа) | party_neutral (я, группа и нейтраллы).
## auto_spell — ручное предпочтение лечения (ПКМ по книге); если пусто, берётся
## первое изученное заклинание лечения.
static var auto_spell: String = ""
static var auto_buff_tier: String = "base"
static var auto_targets: String = "party"
## Воин: ЕДИНСТВЕННЫЙ свиток, помеченный правой кнопкой в книге магии.
## Автоматически кастуется только на себя, по кулдауну заклинания, тратя 1 свиток.
static var auto_scroll_item: String = ""
static var _spell_targeting_frame: int = -1  # кадр, когда начато прицеливание (защита от двойного каста)
## Отладочные переключатели. Источник правды — game.cfg [debug], чтобы не
## править код ради каждой отладки. Значение читается ОДИН раз при старте;
## тесты и дебаг присваивают переменную напрямую как раньше (перекрытие).
static var debug_magic: bool = GameConfig.geti("debug", "all_magic") != 0
## Профилировщик кадра (29.10, разбор просадки в городе). Включается
## [debug] perf = 1 или присваиванием Game.perf_enabled = true из теста.
## Копит МИКРОсекунды по именам блоков и число вызовов, раз в 2 с печатает
## таблицу «мс на кадр». Нужен, чтобы не гадать, кто ест кадр: ИИ, поиск пути,
## ховер, туман или UI.
static var perf_enabled: bool = GameConfig.geti("debug", "perf") != 0
static var perf_usec: Dictionary = {}
static var perf_calls: Dictionary = {}
static var perf_frames: int = 0
static var _perf_since_ms: int = 0
static var _perf_wall_usec: int = 0
static var _perf_last_usec: int = 0


## Начать замер блока. Возвращает метку времени (0 — профилировщик выключен).
static func perf_begin() -> int:
	return Time.get_ticks_usec() if perf_enabled else 0


## Закрыть замер блока: key — имя блока в таблице.
static func perf_end(key: String, t0: int) -> void:
	if not perf_enabled or t0 == 0:
		return
	perf_usec[key] = int(perf_usec.get(key, 0)) + (Time.get_ticks_usec() - t0)


## Счётчик событий (например, число вызовов поиска пути), не время.
static func perf_count(key: String, amount: int = 1) -> void:
	if not perf_enabled:
		return
	perf_calls[key] = int(perf_calls.get(key, 0)) + amount


## Кадр закончился: раз в 2 секунды печатаем таблицу и обнуляем счётчики.
## Wall-время считается между вызовами (обычно из Game._process), то есть это
## реальная длительность кадра, а не сумма замеренных блоков.
static func perf_frame() -> void:
	if not perf_enabled:
		return
	perf_frames += 1
	var now_us := Time.get_ticks_usec()
	if _perf_last_usec != 0:
		_perf_wall_usec += now_us - _perf_last_usec
	_perf_last_usec = now_us
	var now := Time.get_ticks_msec()
	if _perf_since_ms == 0:
		_perf_since_ms = now
		return
	if now - _perf_since_ms < 2000:
		return
	var frames := maxi(1, perf_frames)
	var wall_ms := float(_perf_wall_usec) / 1000.0
	var lines: Array = []
	var total := 0.0
	for key in perf_usec:
		var ms := float(int(perf_usec[key])) / 1000.0 / float(frames)
		total += ms
		var calls := int(perf_calls.get(key, 0))
		var per_frame := float(calls) / float(frames)
		lines.append("%8.2f ms  %-14s (%6.1f выз/кадр)" % [ms, key, per_frame])
	lines.sort()
	print("--- PERF  кадров: %d, кадр: %.1f мс (%.1f FPS) ---" % [
		frames, wall_ms / float(frames), 1000.0 * float(frames) / maxf(1.0, wall_ms)])
	for l in lines:
		print(l)
	for ck in perf_calls:
		if perf_usec.has(ck):
			continue
		print("%8s     %-14s (%6.1f выз/кадр)" % ["", ck,
			float(int(perf_calls[ck])) / float(frames)])
	print("     сумма замеренных блоков: %.2f мс/кадр" % total)
	perf_usec.clear()
	perf_calls.clear()
	perf_frames = 0
	_perf_wall_usec = 0
	_perf_since_ms = now

# --- Защитные баффы (книги/свитки защиты, Shield): уменьшение входящего урона ---
static func apply_shield(unit: Node2D, strength: int, seconds: float) -> void:
	if not is_instance_valid(unit):
		return
	unit.set_meta("shield_strength", int(unit.get_meta("shield_strength", 0)) + strength)
	unit.set_meta("shield_time", float(unit.get_meta("shield_time", 0.0)) + seconds)

static func shield_reduce(unit: Node2D, dmg: int) -> int:
	if not is_instance_valid(unit):
		return dmg
	var strength := int(unit.get_meta("shield_strength", 0))
	if strength <= 0:
		return dmg
	unit.set_meta("shield_strength", strength - dmg)
	var out := maxi(0, dmg - strength)
	if out == 0:
		print("%s: щит поглотил весь урон!" % unit.name)
	return out

## --- Общая математика боя: характеристики -> шанс/урон (для ЛЮБОГО юнита) ---

## Шанс попадания, % — ОТНОСИТЕЛЬНАЯ формула.
##
## Раньше было `50 + атака − защита` (кламп 5..95). Это абсолютная разность, и
## она ломалась, как только в бой включилась экипировка: тяжёлая броня даёт
## defence 14, щит ещё 4, и герой с бронёй держал 50 + 8 − 23 = 35 %, а гоблин
## с атакой 4 — 5 % (нижний кламп). Вся броня мира упиралась в пол, и
## «статы экипировки не работают» выглядело как «работает, но незаметно».
##
## Теперь шанс — отношение силы атаки к силе защиты, поэтому одинаково
## работает и для гоблина (атака 4), и для тролля (атака 30), и для брони.
##   равные статы            -> BASE (70 %)
##   защита вдвое выше       -> примерно вдвое ниже
##   атака вдвое выше        -> упёрётся в MAX
## Константы комбат-формул перенесены в GameConfig (assets/config/game.cfg),
## чтобы их можно было крутить без правки кода. Значения по умолчанию равны
## прежним константам, поэтому поведение игры не меняется.
static func hit_chance(attack: int, defense: int) -> int:
	var soften := GameConfig.geti("combat", "hit_soften")
	var a := float(attack) + soften
	var d := float(defense) + soften
	if d <= 0.0:
		return GameConfig.geti("combat", "hit_max")
	return clampi(int(round(float(GameConfig.geti("combat", "hit_base")) * a / d)),
		GameConfig.geti("combat", "hit_min"), GameConfig.geti("combat", "hit_max"))

## Промах? Юниты с методами get_attack()/get_defense() участвуют полностью.
static func is_miss(attacker: Node2D, defender: Node2D) -> bool:
	var atk := 0
	var dfs := 0
	if attacker != null and attacker.has_method("get_attack"):
		atk = int(attacker.call("get_attack"))
	if defender != null and defender.has_method("get_defense"):
		dfs = int(defender.call("get_defense"))
	return randi() % 100 >= hit_chance(atk, dfs)

## Точность юнита (если есть метод — иначе 0).
static func unit_attack(u: Node2D) -> int:
	return int(u.call("get_attack")) if u != null and u.has_method("get_attack") else 0

## Защита юнита (уклонение/броня).
static func unit_defense(u: Node2D) -> int:
	return int(u.call("get_defense")) if u != null and u.has_method("get_defense") else 0

## Поглощение (материал/броня): get_absorption() — есть у героя и врагов.
static func unit_absorption(u: Node2D) -> int:
	return int(u.call("get_absorption")) if u != null and u.has_method("get_absorption") else 0

## Weapon damage kind of a unit for the Allods weapon-kind resistance:
## sword | axe | club | pike | bow. "" means the blow bypasses the table
## (bare hands, a staff — its normal hit is magic anyway, a ranged row that
## the original would clear to slot zero).
static func weapon_kind_of(u: Node2D) -> String:
	if u == null or not is_instance_valid(u) or not ("weapon" in u):
		return ""
	match str(u.get("weapon")):
		"sword", "axe", "club", "pike":
			return str(u.get("weapon"))
		"bow", "xbow":
			return "bow"
	return ""

## Creature type of a damage target: human | undead | beast | insect | monster.
## The hero is always human; a unit without an animation set (a crate, a wall)
## returns "" so the weapon table is skipped.
static func creature_type_of(u: Node2D) -> String:
	if u == null or not is_instance_valid(u):
		return ""
	if u is Player:
		return "human"
	if "anim_set" in u:
		var set_name := str(u.get("anim_set"))
		if set_name != "":
			return UnitDB.creature_type_of(set_name)
	return ""

## Allods weapon-kind damage: `percent` is 125 / 100 / 75 …; the `+75` is the
## source's 0.75 rounding before truncation.
static func apply_weapon_percent(dmg: int, percent: int) -> int:
	if percent == 100:
		return maxi(0, dmg)
	return maxi(0, int((dmg * percent + 75) / 100.0))

## Spell power from the raw numbers (no caster node): skill + mind - offset.
## The creation screen uses it to show a mage's damage before the hero exists.
static func spell_power_value(skill: float, mind: float) -> float:
	return maxf(0.0, skill + mind - GameConfig.getf("magic", "sp_offset"))

## Сопротивление стихии в ПРОЦЕНТАХ: сколько процентов магического урона
## не пройдёт. Так в оригинале (main.txt: «shows the percentage of the
## magical effects… which will not affect the character») и это не ломается
## от больших чисел, в отличие от плоского вычитания.
static func unit_protection(u: Node2D, sphere: String) -> int:
	if u == null or sphere == "":
		return 0
	var m := "get_protection_%s" % sphere.to_lower()
	if u.has_method(m):
		return clampi(int(u.call(m)), 0, GameConfig.geti("combat", "protection_max"))
	return 0

## --- Сила магии: ОДИН стат на урон, лечение, щит и вампиризм ---
## Формула оригинала (Allods II): SP = навык сферы + разум - 30.
## Кламп в ноль обязателен: при навыке 5 и разуме 9 выходит -16, а оригинал
## на таких значениях ломается (SP>255 — баг переполнения байта).
static func spell_power(caster: Node2D, sphere: String) -> float:
	if caster == null or not is_instance_valid(caster):
		return 0.0
	var mind := 0.0
	if "mind" in caster:
		mind = float(caster.get("mind"))
	var skill := 0.0
	if caster.has_method("sphere_skill"):
		skill = float(caster.call("sphere_skill", sphere))
	return spell_power_value(skill, mind) + float(StatusEffects.stat_flat(caster, "power"))


## Кулдаун заклинания от ПОЗНАНИЯ магии, а не только база из spells_db.
##
## База (`cooldown` в базе) — «повторное применение того же заклинания». Но у
## опытного мага то же заклинание должно быть готово раньше: навык сферы и
## разум (та же SP-формула, что у урона) сокращают кулдаун до 50 % на высоком
## навыке. Нижняя граница 0.5 с — иначе на максимуме получается спам.
##
## power_override — для СВИТКОВ: «познание» берётся из силы заклинания,
## заложенной в свиток (50 обычный, 100 эльфийский), а не из навыка воина.
## То есть кулдаун считается по магии внутри свитка, а не «по применению
## предмета» (отдельного кулдауна предмета в проекте нет и не нужно).
static func spell_cooldown(caster: Node2D, spell_name: String,
		power_override: float = -1.0) -> float:
	var base := SpellDB.cooldown_of(spell_name)
	if base <= 0.0:
		return 0.0
	var sphere := SpellDB.sphere_of(spell_name)
	var power := power_override if power_override >= 0.0 else spell_power(caster, sphere)
	power = clampf(power, 0.0, 100.0)
	return maxf(0.5, base * (1.0 - 0.5 * power / 100.0))


## Порог силы магии: SP = навык сферы + разум - offset.
##
## offset лежит в GameConfig: [magic] sp_offset.
##
## В оригинале Allods II здесь стоит 30, и константа верная ДЛЯ ОРИГИНАЛЬНЫХ
## статов: у мага 6-го уровня разум ~84. Наши статы в 7–10 раз меньше
## (маг на старте mind = 13, навык сферы = 5), и при смещении 30 получалось
## 5 + 13 - 30 = -12, то есть SP ноль на всю раннюю игру: заклинания не
## росли с уровнем вообще, и Fire_Ball (база 26) бил ровно базой. Это подтвердил
## ручной аудит.
## Смещение 15 выбрано игроком: на старте мага SP = 3, при прокачке навыка
## сферы 5 -> 15 получаем SP = 13 (+13 % урона), к 30 — SP = 28. Форма
## оригинала сохранена, масштаб приведён к нашим числам.
## Урон заклинания с учётом силы кастера и множителя заклинания.
## final = base * power_coef * (1 + spell_power/100)
static func spell_damage(caster: Node2D, spell_name: String, sphere: String,
		base_damage: int, power_override: float = -1.0) -> int:
	var coef := SpellDB.power_coef_of(spell_name)
	# Свиток несёт свою силу (50 — обычный, 100 — эльфийский). Раньше это
	# число не использовалось вовсе: свиток кастовался навыком героя, и
	# эльфийский не был сильнее обычного.
	var power := power_override if power_override >= 0.0 else spell_power(caster, sphere)
	var raw := float(base_damage) * coef * (1.0 + power / 100.0)
	return maxi(SpellDB.min_damage_of(spell_name), int(round(raw)))


## ЕДИНАЯ точка урона: физика -> поглощение; магия -> защиты стихий; далее щит и HP.
## Возвращает фактически нанесённый урон (0 — если всё поглощён/промах).
static func deal_damage(target: Node2D, dmg: int, kind: String, sphere: String, attacker: Node2D) -> int:
	if not is_instance_valid(target) or dmg <= 0:
		return 0
	# Глобальный множитель урона - главный рычаг баланса (идея из AION).
	# Применяется здесь, в ЕДИНОЙ точке урона, поэтому множитель одинаков
	# для ближнего боя, магии, снарядов и AoE.
	var final := int(round(float(dmg) * GameConfig.getf("combat", "damage_multiplier")))
	if kind == "magic":
		# Сопротивление — процент от урона (как в оригинале)
		var prot := unit_protection(target, sphere)
		final = maxi(0, int(round(float(dmg) * (1.0 - float(prot) / 100.0))))
	else:
		final = maxi(0, final - unit_absorption(target))
		# Allods weapon-kind resistance: a physical blow is reduced (or
		# boosted) by the target's creature type. Only a weapon with a known
		# kind takes part — bare hands, a staff's weak hit and magic do not.
		# Source formula: trunc(damage * (100 - resistance) / 100 + 0.75),
		# i.e. 125% vs undead for a club is resistance -25.
		var wkind := weapon_kind_of(attacker)
		if wkind != "":
			var ctype := creature_type_of(target)
			if ctype != "":
				final = apply_weapon_percent(final, UnitDB.weapon_percent(wkind, ctype))
	if final <= 0:
		# Полное поглощение ДО take_damage. Причина важна игроку: «стойкость» —
		# защита стихии, «броня» — физический удар. Раньше обе подписи были
		# «щит», и щит тут ни при чём (щиты считаются внутри take_damage).
		DamageNumber.show_at(target.global_position, 0,
			"resist" if kind == "magic" else "armor")
		return 0
	var dealt := 0
	if target.has_method("take_damage"):
		dealt = target.call("take_damage", final, attacker)
	# take_damage вернул 0 — урон съел ЩИТ внутри юнита. Показывать полное
	# число было прямой ложью: игрок видел «40» там, где не пришлось ни одного
	# урона. Теперь показываем, что удар дошёл, но его закрыл щит.
	if not (dealt is int) or int(dealt) <= 0:
		DamageNumber.show_at(target.global_position, 0, "absorb")
		return 0
	final = int(dealt)
	# Единственное место, где рисуется урон: иначе числа дублировались
	# в projectile.gd и enemy.gd, и показывали сырое, а не фактическое значение.
	DamageNumber.show_at(target.global_position, final, "damage")
	SpellVFX.hit_flash(target)
	# Физический удар озвучиваем в единой точке урона: так звук получают и
	# герой, и наёмники, и стычки NPC, а не только те ветки, где его не забыли.
	if kind != "magic":
		var now := Time.get_ticks_msec()
		if now - _hit_sfx_ms > 55:
			_hit_sfx_ms = now
			var hit_key := "combat.hit.armor" if unit_absorption(target) >= 8 \
				else "combat.hit.flesh"
			SoundDB.play(hit_key, -4.0)
	if kind == "magic" and is_instance_valid(attacker):
		_apply_vampirism(attacker, final)
	return final


## Вампиризм (Drain_Life): часть нанесённого магией урона возвращается кастеру.
static func _apply_vampirism(caster: Node2D, dealt: int) -> void:
	var ratio := StatusEffects.vampirism_ratio(caster)
	if ratio <= 0.0 or dealt <= 0:
		return
	var amount := maxi(1, int(float(dealt) * ratio))
	if caster.has_method("heal_amount"):
		caster.call("heal_amount", amount)


## Нанести урон всем целям в радиусе (для областных заклинаний/взрывов).
static func deal_damage_area(targets: Array, dmg: int, kind: String, sphere: String, attacker: Node2D) -> void:
	for t in targets:
		if is_instance_valid(t):
			deal_damage(t, dmg, kind, sphere, attacker)

static func tick_shields(delta: float) -> void:
	var units: Array = [Game.hero]
	units.append_array(Game.enemies)
	units.append_array(Game.npcs)
	units.append_array(Game.party)
	for u in units:
		if u == null or not is_instance_valid(u):
			continue
		if not u.has_meta("shield_time"):
			continue
		var t := float(u.get_meta("shield_time", 0.0)) - delta
		if t > 0.0:
			u.set_meta("shield_time", t)
		else:
			u.set_meta("shield_time", 0.0)
			u.set_meta("shield_strength", 0)

static func configure_unit_body(unit: Node2D, radius: float = 12.0) -> void:
	if not (unit is CharacterBody2D):
		return
	var body := unit as CharacterBody2D
	# Слой 1 = стены/здания/боевые юниты. Маска 1 = чувствуем layer 1.
	# Мирные NPC (жители, маг города) после этого вызова переезжают на слой 2 —
	# герой через них ходит, иначе в городе 30+ NPC «упираются» в толпу.
	body.collision_layer = 1
	body.collision_mask = 1
	# motion_mode НЕ трогаем: в top-down интуитивно хочется MOTION_MODE_FLOATING,
	# но это проверено и отвергнуто — на dev-карте герой застревал в кармане между
	# двумя препятствиями (fuzz_edge: 1 застревание из 62 вместо 0), потому что
	# в GROUNDED скользящая поверхность классифицируется как «пол» и выталкивает
	# героя из узкого места, а в FLOATING любая коллизия — глухая стена.
	# Настоящая причина «езды по рельсам» была не в этом, а в гашении скорости
	# целиком — починено раздельным скольжением по осям в player/enemy.
	var shape_node: CollisionShape2D = null
	for child in body.get_children():
		if child is CollisionShape2D:
			shape_node = child as CollisionShape2D
			break
	if shape_node == null:
		shape_node = CollisionShape2D.new()
		shape_node.name = "Collision"
		body.add_child(shape_node)
	if shape_node.shape == null:
		var shape := CircleShape2D.new()
		shape.radius = radius
		shape_node.shape = shape

## Разделение юнитов, чтобы не слипались. Раньше здесь каждый кадр
## аллоцировал Array из ВСЕХ юнитов и мерил дистанцию до каждого —
## на 75 врагах это O(n²) в физике. Теперь: буфер без аллокации,
## ранний выход, мирные NPC (слой 2) не толкают друг друга.
const SEP_DIST := 24.0
const SEP_DIST_SQ := SEP_DIST * SEP_DIST
const SEP_SKIP_SQ := 40.0 * 40.0
static var _sep_acc := Vector2.ZERO
## P4: пространственная сетка для separation — раз в кадр строим вёдра 64px,
## ищем только соседей. Без этого NPC×2 снова даст O(n²) в физике.
const SEP_GRID_CELL := 64.0
static var _sep_grid: Dictionary = {}
static var _sep_grid_frame: int = -1


static func _sep_bucket_key(pos: Vector2) -> String:
	return "%d,%d" % [int(floor(pos.x / SEP_GRID_CELL)), int(floor(pos.y / SEP_GRID_CELL))]


static func _sep_insert(unit) -> void:
	# Параметр БЕЗ типа намеренно: типизированный `unit: Node2D` проверяется
	# движком ДО входа в тело, и на освобождённом узле падает вся функция -
	# is_instance_valid внутри уже не спасает. Жалоба игрока 09.10:
	# "Invalid type in function '_sep_insert' ... argument 1 (previously freed)".
	# Сторож: tests/stale_units_smoke.gd. Источник чинится в Main._ready().
	if unit == null or not is_instance_valid(unit) or not (unit is Node2D):
		return
	var key := _sep_bucket_key(unit.global_position)
	var arr: Array = _sep_grid.get(key, [])
	arr.append(unit)
	_sep_grid[key] = arr


static func _sep_rebuild_grid() -> void:
	var f := Engine.get_physics_frames()
	if f == _sep_grid_frame:
		return
	var t0 := perf_begin()
	_sep_grid_frame = f
	_sep_grid.clear()
	if is_instance_valid(Game.hero):
		_sep_insert(Game.hero)
	for other in Game.enemies:
		_sep_insert(other)
	for other in Game.npcs:
		_sep_insert(other)
	for other in Game.party:
		_sep_insert(other)
	perf_end("sep_grid", t0)


static func _sep_neighbors(pos: Vector2) -> Array:
	var out: Array = []
	var cx := int(floor(pos.x / SEP_GRID_CELL))
	var cy := int(floor(pos.y / SEP_GRID_CELL))
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			var key := "%d,%d" % [cx + dx, cy + dy]
			var arr: Array = _sep_grid.get(key, [])
			for u in arr:
				out.append(u)
	return out


static func movement_direction(unit: Node2D, desired: Vector2) -> Vector2:
	if desired.length_squared() <= 0.0001:
		return Vector2.ZERO
	_sep_acc = Vector2.ZERO
	var my_pos: Vector2 = unit.global_position
	var my_layer: int = 1
	if unit is CollisionObject2D:
		my_layer = (unit as CollisionObject2D).collision_layer
	_sep_rebuild_grid()
	var found := 0
	for other in _sep_neighbors(my_pos):
		if found >= 6:
			break
		if other == unit or not is_instance_valid(other):
			continue
		found += _sep_push(my_pos, my_layer, other)
	var separation := _sep_acc
	var result := desired.normalized() + separation * 1.5
	return result.normalized() if result.length_squared() > 0.0001 else desired.normalized()


## Один юнит: если рядом — добавить вклад в _sep_acc. Возвращает 0/1.
static func _sep_push(my_pos: Vector2, my_layer: int, other: Node) -> int:
	if other == null or not is_instance_valid(other) or not (other is Node2D):
		return 0
	if other is CollisionObject2D and my_layer == 2 \
			and (other as CollisionObject2D).collision_layer == 2:
		return 0
	var opos: Vector2 = (other as Node2D).global_position
	var dx := my_pos.x - opos.x
	var dy := my_pos.y - opos.y
	var dist_sq := dx * dx + dy * dy
	if dist_sq > SEP_SKIP_SQ or dist_sq < 0.01:
		return 0
	var distance := sqrt(dist_sq)
	if distance >= SEP_DIST:
		return 0
	var w := (SEP_DIST - distance) / SEP_DIST
	_sep_acc.x += dx / distance * w
	_sep_acc.y += dy / distance * w
	return 1


## Лучшее скольжение, когда полный шаг заблокирован.
##
## Зачем. Раньше одно и то же было продублировано в трёх местах, и все три
## варианта выбирали ось ПО ПОРЯДКУ (`if can_x ... elif can_y ...`), а не по
## близости к направлению движения. При перекрытом диагональном шаге (дерево,
## угол здания) юнит шёл строго по X, даже если «правильным» было Y. Звери у
## деревьев дёргались лошадью: шаг в диагональ превращался в шаг по одной оси.
## Замер 03.10 показал, что при свободном движении по диагонали 179 кадров
## из 179 были диагональными (угол 0.998) — то есть ломало именно СКОЛЬЖЕНИЕ,
## а не сама походка.
##
## Возвращает единичную ось (или ZERO, если нельзя ни туда, ни сюда).
static func choose_slide(desired: Vector2, can_x: bool, can_y: bool) -> Vector2:
	if can_x and can_y:
		# Обе свободны — берём ту, что вносит большую часть движения.
		var wx := absf(desired.x)
		var wy := absf(desired.y)
		var total := wx + wy
		if total <= 0.0:
			return Vector2.ZERO
		return Vector2(signf(desired.x), 0.0) if wx >= wy else Vector2(0.0, signf(desired.y))
	if can_x:
		return Vector2(signf(desired.x), 0.0)
	if can_y:
		return Vector2(0.0, signf(desired.y))
	return Vector2.ZERO

var _select_ring: SelectRing = null       # подсветка цели (ховер/атака)
var _pending_building := ""               # здание, к которому герой подходит («вход»)
var _pending_s: Dictionary = {}           # структура-цель ожидающего входа
var _pending_herb: HerbNode = null
var _pending_archmage: Node2D = null      # капитан-маг, к которому подходим
var _pending_city_head: Node2D = null     # глава города, к которому подходим
var _save_menu: SaveMenu = null
## Death sequence (04.11): the actor emits `died`, the game owns the 1 s fall,
## the full-screen title and the load menu. One flag prevents a second lethal
## hit (or a re-entrant signal) from stacking two screens.
var _death_screen: CanvasLayer = null
var _death_sequence_running := false
## Сцена уступает место главному меню или процесс завершается (_quit_to_menu/
## _quit_app): автосейв уже записан, при сносе узла повторять его нельзя.
var _leaving_for_quit: bool = false
var _autosave_accum: float = 0.0
## Интервал автосейва. 60 с - компромисс: чаще - лишний ввод-вывод, реже -
## можно потерять минуты прогресса при аварии. Первый автосейв приходит
## через 60 с после старта, а не сразу, поэтому отдельного "минимального
## времени" не нужно.
const AUTOSAVE_INTERVAL := 60.0

## Интервал автосейва — из конфига [autosave] interval. Константа выше
## осталась как запасное значение и как перекрытие для тестов.
static func autosave_interval() -> float:
	var v := GameConfig.getf("autosave", "interval")
	return AUTOSAVE_INTERVAL if v <= 0.0 else v

# --- Выбор героя на старте (сцена character_select) ---
static var hero_class: String = "warrior"   # warrior | mage
static var hero_gender: String = "male"     # male | female
static var hero_name: String = "Герой"
static var hero_character_id: String = "human_m_war"  # id портрета расы
static var hero_portrait: String = ""       # res:// путь к портрету
static var hero_race: String = "human"      # human | necro | druid | ork
static var hero_stats: Dictionary = {}      # стартовые характеристики
static var hero_start_book: String = ""     # книга простейшего заклинания школы мага
## The chosen development direction (skill id: blade/axe/.../fire/...). Its
## level drives survivability: life for both classes, mana for a mage,
## defence for a warrior. The auxiliary skill counts at 60% (see [skill_stats]).
static var hero_primary_skill: String = ""
static var hero_aux_skill: String = ""
## Death latch (package 2 will own the screen): set on a lethal hit, reset by a
## new game or a slot load. Kept here now so character creation can clear it.
static var hero_dead: bool = false
## Позиция героя из сохранения. Кладёт SaveSystem.apply_payload; применяет
## _spawn_player_on_walkable после пересборки сцены (иначе герой всегда на спавне).
static var load_position: Vector2 = Vector2.ZERO
static var load_position_valid: bool = false

## Runtime-состояние героя из сейва (gold/inventory/equipped/HP/spells/...).
## change_scene пересоздаёт Player, и _ready выдавал стартовый набор —
## золото и инвентарь «терялись», хотя лежали в файле. Пустой словарь =
## новая игра (стартовый gold/starter set).
static var hero_save: Dictionary = {}

static func clear_load_position() -> void:
	load_position = Vector2.ZERO
	load_position_valid = false


static func clear_hero_save() -> void:
	hero_save = {}
	# Новая игра/новая карта: захваченные форпосты прежнего мира не должны
	# «протекать» в новый (ключ включает сид, но старые ключи копились бы).
	outposts.clear()
	outposts_captured.clear()
	pending_outposts_captured.clear()

## Путь портрета: явный hero_portrait или сборка из character_id (с легаси-маппингом).
static func hero_portrait_path() -> String:
	if hero_portrait != "" and ResourceLoader.exists(hero_portrait):
		return hero_portrait
	var cid := hero_character_id
	var legacy := {
		"mfighter": "human_m_war", "ffighter": "human_f_war",
		"mmage": "human_m_mage", "fmage": "human_f_mage",
	}
	if legacy.has(cid):
		cid = str(legacy[cid])
	return "res://assets/hero_portraits/%s.png" % cid

# --- Выбор карты ---
## Явно запрошенный путь к .alm. Не пусто только когда путь задан вручную:
## редактор карт (F9 «Назад в игру») или загрузка сохранения. Имеет приоритет над сидом.
static var pending_map_path: String = ""
## Сид карты новой игры. 0 = карта не запрошена, AlmMap берёт запасной путь из main.tscn
## (детерминированный dev-режим и автотесты — им случайная карта мешала бы).
static var map_seed: int = 0
static var map_zone: String = "mid"   # start | mid | hard | faction (ТИР сектора)
## Сид мира 4x3 и текущий сектор ("s41"). map_seed выводится из них.
static var world_seed: int = 0
static var map_sector: String = ""
## Новую игру открыли через loading.tscn: main должен показать оверлей,
## пока идёт расселение и прогрев, а не мигать пустой картой.
static var startup_loading: bool = false

## Куда вернуться из редактора карт по Esc/F9: главное меню или выбор героя.
## Пустая строка — поведение по умолчанию (главное меню).
static var editor_return_scene: String = ""

## Настройки новой игры, переданные из редактора карт («Играть эту карту»).
## character_select читает их один раз в _ready и очищает.
static var start_preset: Dictionary = {}

static func _world_map() -> GDScript:
	return load("res://scripts/world/world_map.gd") as GDScript

## Сид конкретного сектора от сида мира.
static func sector_seed(sector_id: String) -> int:
	if sector_id == "":
		return map_seed
	var bus := _world_bus_static()
	var st: Dictionary = {}
	if bus != null and bus.state != null:
		st = bus.state.sector_state(sector_id)
	if not st.is_empty() and int(st.get("seed", 0)) != 0:
		return int(st.get("seed", 0))
	return int(_world_map().seed_of(world_seed, sector_id))


## Автолоад по имени класса в headless-скрипте не резолвится (проверено
## 23.10: "Identifier not found: WorldBus"). Берём узел из дерева.
static func _world_bus_static() -> Node:
	var loop := Engine.get_main_loop()
	if loop == null or not (loop is SceneTree):
		return null
	var scene := loop as SceneTree
	if scene.root == null:
		return null
	return scene.root.get_node_or_null("WorldBus")


## Репутация героя у фракции (расы) — для витрин: таверна и магазин (28.10).
## Пустая раса (карта без городов) — репутации нет, витрина работает как раньше.
static func hero_reputation(race: String) -> int:
	if race == "":
		return 0
	var bus := _world_bus_static()
	if bus == null or not ("state" in bus) or bus.state == null:
		return 0
	return int(bus.state.hero_rep(race))


# --- Форпосты фракций (пакет B переработки ковки) --------------------------

## Ключ захвата: id лагеря уникален только внутри карты, а карты у секторов
## свои. Сид+зона+сектор остаются те же после сохранения и загрузки (имя файла
## карты меняется на save_<slot>, поэтому имя в ключ не годится).
static func outpost_key(oid: String) -> String:
	if oid == "":
		return ""
	return "%s|%s|%d|%s" % [str(map_zone), str(map_sector), int(map_seed), oid]


## Перечитать форпосты карты. Вызывается после сборки/загрузки карты и ДО
## спавна юнитов: иначе стража уже захваченных лагерей успела бы появиться.
static func reload_outposts(map_node = null) -> void:
	outposts = []
	if map_node != null and is_instance_valid(map_node) \
			and map_node.has_method("outposts"):
		var raw: Variant = map_node.call("outposts")
		if raw is Array:
			outposts = (raw as Array).duplicate(true)
	# Захваченное пришло из сейва: переносим один раз, дальше живёт в словаре.
	if not pending_outposts_captured.is_empty():
		for key in pending_outposts_captured:
			outposts_captured[str(key)] = true
		pending_outposts_captured.clear()


## Захвачен ли форпост текущей карты.
static func is_outpost_captured(oid: String) -> bool:
	return outposts_captured.has(outpost_key(oid))


## Умер стражник форпоста: падение репутации фракции и, если лагерь зачищен,
## его захват. Вызывает enemy.gd из take_damage (после лута и сигнала died).
static func on_outpost_guard_died(unit: Node2D) -> void:
	if unit == null or not is_instance_valid(unit):
		return
	var oid := str(unit.get("outpost_id"))
	if oid == "":
		return
	var faction := str(unit.get("faction"))
	if faction != "":
		var bus := _world_bus_static()
		if bus != null and ("state" in bus) and bus.state != null:
			bus.state.add_hero_reputation(faction, -GameConfig.geti("outpost", "rep_penalty"))
	# Живые стражники того же лагеря? Труп уже вычищен из Game.enemies.
	for e in enemies:
		if e != null and is_instance_valid(e) and str(e.get("outpost_id")) == oid:
			return
	var key := outpost_key(oid)
	if key == "" or outposts_captured.has(key):
		return
	outposts_captured[key] = true
	var gold := GameConfig.geti("outpost", "capture_gold")
	if hero != null and is_instance_valid(hero) and hero.has_method("add_gold"):
		hero.call("add_gold", gold)
	var name := oid
	for o in outposts:
		if str((o as Dictionary).get("id", "")) == oid:
			name = str((o as Dictionary).get("name", oid))
			break
	var bus2 := _world_bus_static()
	if bus2 != null and ("state" in bus2) and bus2.state != null:
		bus2.state.log_entry("outpost", "%s захвачен" % name)
	# Захват даёт чертежи наборов этой фракции (пакет C+D): взял лагерь —
	# узнал, как куют их броню. Лавки (пакет F) добавят второй источник.
	var scrolls := CraftDB.recipe_ids_of_faction(faction)
	var given := 0
	if hero != null and is_instance_valid(hero) and hero.has_method("add_item"):
		for rid in scrolls:
			var scroll_key := CraftDB.recipe_scroll_key(str(rid))
			if ItemDB.find(scroll_key).is_empty():
				continue
			if not CraftDB.has_recipe_scroll(hero, str(rid)):
				hero.call("add_item", scroll_key)
				given += 1
	var wf = load("res://scripts/world/world_feed.gd")
	if wf != null:
		var tail := "" if given == 0 else ", чертежей: %d" % given
		wf.post("world", "%s захвачен (+%d золота%s)" % [name, gold, tail])
	print("OUTPOST captured: %s (%s), +%d gold, +%d scrolls" % [name, oid, gold, given])


func _world_bus() -> Node:
	if not is_inside_tree():
		return null
	return get_tree().root.get_node_or_null("WorldBus")

## Новая карта со случайным сидом. Вызывается из character_select перед стартом.
## zone может быть тиром (start/mid/hard/faction) или id сектора ("s41").
static func new_random_map(zone: String = "mid") -> void:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	world_seed = rng.randi()
	if world_seed == 0:
		world_seed = 4242
	var wm := _world_map()
	var sector := zone if wm.has(zone) else str(wm.sector_for_tier(zone))
	map_sector = sector
	map_zone = str(wm.tier_of(sector)) if sector != "" else zone
	map_seed = int(wm.seed_of(world_seed, sector)) if sector != "" else rng.randi()
	pending_map_path = ""
	clear_load_position()
	clear_hero_save()

## Конкретная карта по сиду (загрузка сохранения, тесты).
static func request_map_by_seed(seed_value: int, zone: String = "mid") -> void:
	map_seed = seed_value
	map_zone = zone
	map_sector = ""
	world_seed = 0
	pending_map_path = ""
	clear_load_position()
	clear_hero_save()

## Явно заданный файл карты (редактор, отладочные сцены).
static func request_map_by_path(path: String) -> void:
	pending_map_path = path
	map_seed = 0
	map_sector = ""
	clear_load_position()
	clear_hero_save()

const PLAYER_SPEED: float = 120.0

const POSTFX_SHADER := """shader_type canvas_item;
render_mode unshaded, blend_mix;

// Виньетка и зерно. В Environment в Godot 4 таких полей нет ни в одной версии.
uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_linear;
uniform float vignette_strength : hint_range(0.0, 1.0) = 0.34;
uniform float vignette_softness : hint_range(0.05, 1.5) = 0.62;
uniform float grain : hint_range(0.0, 0.15) = 0.022;

float hash21(vec2 p) {
	return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
}

void fragment() {
	vec2 c = SCREEN_UV - vec2(0.5);
	// Учитываем соотношение сторон, иначе виньетка овальная на широком окне.
	c.x *= 0.62;
	float v = 1.0 - vignette_strength * smoothstep(0.18, 0.72, length(c) * vignette_softness * 2.0);
	vec3 col = textureLod(screen_texture, SCREEN_UV, 0.0).rgb * v;
	col += (hash21(SCREEN_UV * 1024.0 + fract(TIME) * 91.7) - 0.5) * grain;
	COLOR = vec4(col, 1.0);
}"""

# --- Свет и пост-обработка 2D ---

## Приглушение окружения. Почти нейтральное.
## Первая версия была 0.88 — и игрок пожаловался, что «все объекты, НПЦ и
## строения стали тёмные». Причина в том, что у рельефа своя яркость от солнца
## зашита в вершинные цвета (`AlmMap._brightness`), а спрайты её не имеют и
## живут в средних тонах — там AgX сажает яркость вниз сильнее всего.
## Свет заклинаний при 0.97 не гаснет: он кратковременный и идёт с энергией
## 1.5–2.2, запаса хватает.
const AMBIENT := Color(0.97, 0.98, 1.0, 1.0)

func _setup_rendering() -> void:
	_setup_ambient()
	_setup_environment()
	_setup_post_pass()


## CanvasModulate — базовая яркость всего холста. Без него аддитивные
## источники света не могут ничего добавить: холст и так рисуется в полную
## яркость. Действует ТОЛЬКО на свой слой, поэтому UI на своём CanvasLayer
## не затрагивается.
func _setup_ambient() -> void:
	if get_node_or_null("Ambient") != null:
		return
	var ambient := CanvasModulate.new()
	ambient.name = "Ambient"
	ambient.color = AMBIENT
	add_child(ambient)


## WorldEnvironment: glow + тональная компрессия для 2D.
##
## background_mode ОБЯЗАН быть BG_CANVAS (3). Со значением по умолчанию
## (BG_CLEAR_COLOR) Environment влияет ТОЛЬКО на 3D, а в чисто 2D-проекте это
## значит «ничего не делает» — самая частая потеря времени при настройке.
##
## Цвета каналов > 1.0 в шейдерах заклинаний дают избирательное свечение:
## раньше 2D был RGBA8 и значения обрезались до 1.0, то есть «ярче белого»
## было невозможно в принципе. Теперь работает hdr_2d.
func _setup_environment() -> void:
	if get_node_or_null("WorldEnvironment") != null:
		return
	var env := Environment.new()
	env.background_mode = Environment.BG_CANVAS
	env.glow_enabled = true
	env.glow_intensity = 0.45
	env.glow_bloom = 0.08
	env.glow_strength = 1.1
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_SCREEN
	# Порог чуть ниже 1.0: с hdr_2d в кадре почти нет по-настоящему белых
	# пикселей, и при 1.0 не светилось бы ничего.
	env.glow_hdr_threshold = 0.92
	# Имена уровней glow содержат «/», к таким свойствам нельзя обращаться
	# присваиванием (только через set()) — прямой доступ не парсится.
	env.set("glow_levels/4", 0.2)
	env.set("glow_levels/5", 0.35)
	env.set("glow_levels/6", 0.18)
	# AgX оставлен: он даёт «цветную» землю, которая понравилась. Но он же
	# сажает средние тона вниз, а спрайты живут именно в них — компенсируем
	# экспозицией и убираем лишний контраст теней.
	env.tonemap_mode = Environment.TONE_MAPPER_AGX
	env.tonemap_exposure = 1.25
	env.tonemap_agx_contrast = 0.85
	# UI на CanvasLayer с layer > 0 и так исключён из пост-обработки.
	env.background_canvas_max_layer = 0

	var node := WorldEnvironment.new()
	node.name = "WorldEnvironment"
	node.environment = env
	add_child(node)


## Пост-пасс: виньетка + зерно. В Environment в Godot 4 виньетки НЕТ ни в одной
## версии — её всегда делают своим шейдером.
##
## Кладётся ПЕРВЫМ потомком UI-CanvasLayer: тогда HUD рисуется поверх и не
## затемняется, а сам слой (layer 1) не попадает под glow.
func _setup_post_pass() -> void:
	# Узел UI в main.tscn НЕ состоит в группе "ui" (там нет строки groups = [...]),
	# поэтому искать его по группе нельзя — берём уже сохранённую ссылку `ui`.
	var ui_node: Node = ui
	if ui_node == null:
		ui_node = get_tree().get_first_node_in_group("ui")
	if ui_node == null:
		ui_node = find_child("UI", true, false)
	if ui_node == null:
		return
	if ui_node.get_node_or_null("PostFX") != null:
		return
	var layer: CanvasLayer = ui_node as CanvasLayer
	if layer == null:
		return
	var rect := ColorRect.new()
	rect.name = "PostFX"
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sh := Shader.new()
	sh.code = POSTFX_SHADER
	var mat := ShaderMaterial.new()
	mat.shader = sh
	rect.material = mat
	rect.color = Color(1, 1, 1, 1)
	layer.add_child(rect)
	# Переносим наверх списка детей, чтобы HUD был ПОВЕРХ пост-обработки.
	layer.move_child(rect, 0)


func _ready():  # Инициализация мира и боя
	process_mode = PROCESS_MODE_ALWAYS  # Работает даже на паузе
	# Direct main.tscn launch (F6/tests) bypasses the main menu, which is the
	# normal place where saved key bindings are applied.
	Settings.apply_input()
	# A fresh main scene is a fresh life: the death flag is static and could
	# survive a redirect/restart from a dead run.
	Game.hero_dead = false
	_death_sequence_running = false
	MusicDB.start_playlist.call_deferred()

	# Тематический анимированный курсор (обычный + прицел, см. cursor_layer.gd).
	add_child(load("res://scripts/cursor_layer.gd").new())

	# С 21.10: физическая интерполяция проекта (physics/common) заставляет
	# Camera2D переключаться на physics-процесс и печатать WARNING, если
	# callback = IDLE. Камера и так двигается в _physics_process (lerp по
	# герою) — задаём PHYSICS явно, вар не печатается, дёрганья нет.
	camera.process_callback = Camera2D.CAMERA2D_PROCESS_PHYSICS

	# Свет и пост-обработка 2D. Без них эффекты рисуются «как есть» и выглядят
	# наклейками: правило VFX — эффект должен излучать и освещать мир.
	_setup_rendering()

	# Сброс режимов прицеливания (статика переживает перезапуск сцены)
	pending_scroll = {}
	pending_spell = {}
	_spell_targeting_frame = -1
	# Авто-каст НЕ сбрасываем: игрок задал его в книге и ждёт, что маг лечит.

	# Страховка: если main.tscn запущен напрямую (F6, отладка) без выбора
	# персонажа на старте — уходим на экран выбора героя.
	if Game.hero_stats.is_empty():
		get_tree().call_deferred("change_scene_to_file", "res://scenes/character_select.tscn")
		return

	# Спавним игрока на проходимом тайле в центре карты
	_ensure_world_state()
	_sync_sim_from_map()
	# Свежая сцена начинает ленту с одной строки прибытия: после загрузки
	# сохранения не должно оставаться болтовни прошлой сессии.
	var wf = load("res://scripts/world/world_feed.gd")
	wf.clear()
	wf.post("world", Loc.f("ui.feed.arrival", [_sector_name(Game.map_sector)]))
	_spawn_player_on_walkable()
	Game.hero = player
	Game.hero_dead = false
	_death_sequence_running = false
	if is_instance_valid(player) and player.has_signal("died") \
			and not player.died.is_connected(_on_hero_died):
		player.died.connect(_on_hero_died)
	Game.party.clear()
	_restore_pending_party()
	# enemies/npcs — static var, они ПЕРЕЖИВАЮТ смену сцены: узлы прежней
	# карты к этому моменту уже освобождены движком, но остаются в массивах.
	# Раньше чистился только party, и новая игра ловила
	# `_sep_insert(unit: Node2D)`: argument 1 (previously freed) — падение на
	# типизированном параметре происходит ДО входа в тело функции, поэтому
	# is_instance_valid внутри _sep_insert не помогает.
	# Это же чинит хвост в _alive_gray_count (считал мёртвые узлы).
	Game.enemies.clear()
	Game.npcs.clear()
	# Форпосты карты — ДО спавна юнитов: стража захваченных лагерей не появляется.
	Game.reload_outposts(alm_map)
	_sep_grid.clear()
	_sep_grid_frame = -1
	# НПЦ и монстры из карты (.alm секция units или sidecar .npcs.json)
	if Game.startup_loading:
		Game.startup_loading = false
		_show_loading(Loc.t("ui.loading.assembly"))
		_spawn_map_units(Callable(self, "_on_startup_spawned"))
	else:
		_spawn_map_units()

	# Fog of war + dynamic events (19.10): nodes find the map via group.
	var fog_node := FogOfWar.new()
	fog_node.name = "FogOfWar"
	add_child(fog_node)
	var events_node := EventSystem.new()
	events_node.name = "EventSystem"
	add_child(events_node)
	var quests_node := QuestSystem.new()
	quests_node.name = "QuestSystem"
	add_child(quests_node)

	if camera and player:
		camera.position = player.camera_focus()
		camera.make_current()

	await get_tree().process_frame

	# Находим врагов (группа "enemy": враг из сцены + спавн из карты)
	enemies.clear()
	for child in get_children():
		if child.is_in_group("enemy"):
			enemies.append(child)
			print("  Враг найден: ", child.name, " HP=", child.max_hp if "max_hp" in child else "?")

	print("Всего врагов: ", enemies.size())

	# Добавляем игрока в группу "player" для врагов
	player.add_to_group("player")

	if ui:
		ui.setup_ui(player)
	_setup_world_feed()

	_select_ring = SelectRing.new()
	_select_ring.name = "SelectRing"
	_select_ring.z_index = 9
	add_child(_select_ring)
	_select_ring.visible = false

	# Сохранения: троттл автосейва. Первый автосейв не раньше, чем
	# AUTOSAVE_MIN_SECONDS от старта, иначе он сработал бы на пустой партии
	# сразу при входе в игру.
	_autosave_accum = 0.0
	set_process_unhandled_input(true)

func _spawn_player_on_walkable():
	var mw: int = int(alm_map.get("map_width"))
	var mh: int = int(alm_map.get("map_height"))
	if not alm_map or mw == 0:
		return
	# 0) Позиция из сохранения (одноразово): герой встаёт туда, где сохранился.
	if load_position_valid:
		var lp: Vector2 = load_position
		if alm_map.call("is_walkable_world", lp):
			player.global_position = lp
			player.reset_physics_interpolation()
			clear_load_position()
			return
		clear_load_position()
	# 1) Точка спавна, заданная в карте (тип «Спавн»)
	var spawn_pos: Vector2 = alm_map.call("get_spawn_pos")
	if alm_map.call("is_walkable_world", spawn_pos):
		player.global_position = spawn_pos
		player.reset_physics_interpolation()
		return
	# 2) Запасной вариант — проходимый тайл от центра
	var cx := int(mw / 2.0)
	var cy := int(mh / 2.0)
	for r in range(0, 20):
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				var tx := cx + dx
				var ty := cy + dy
				var ts: int = int(alm_map.get("tile_size"))
				var wx := tx * ts + ts / 2.0
				var wy := ty * ts + ts / 2.0
				if alm_map.call("is_walkable_world", Vector2(wx, wy)):
					player.global_position = Vector2(wx, wy)
					player.reset_physics_interpolation()
					return


## Восстановить отряд из сейва v2. Зовётся после сборки карты и постановки
## героя: позиция наёмника из сейва проверяется на проходимость, иначе он
## встаёт рядом с героем (клетку могли занять зданием при перегенерации).
func _restore_pending_party() -> void:
	if Game.pending_party.is_empty():
		return
	var saved: Array = Game.pending_party
	Game.pending_party = []
	for i in range(saved.size()):
		var raw: Variant = saved[i]
		if not (raw is Dictionary):
			continue
		var rec: Dictionary = raw
		var mercenary := Mercenary.new()
		mercenary.anim_set = str(rec.get("set", mercenary.anim_set))
		mercenary.max_hp = maxi(1, int(rec.get("hp_max", mercenary.max_hp)))
		mercenary.damage = maxi(0, int(rec.get("damage", mercenary.damage)))
		mercenary.spirit = maxi(0, int(rec.get("spirit", mercenary.spirit)))
		mercenary.move_speed = maxf(10.0, float(rec.get("speed", mercenary.move_speed)))
		add_child(mercenary)
		var saved_pos := Vector2(float(rec.get("x", 0.0)), float(rec.get("y", 0.0)))
		var on_land := false
		if is_instance_valid(alm_map) and alm_map.has_method("is_walkable_world") \
				and saved_pos != Vector2.ZERO:
			on_land = bool(alm_map.call("is_walkable_world", saved_pos))
		if on_land:
			mercenary.global_position = saved_pos
		elif is_instance_valid(player):
			mercenary.global_position = player.global_position \
				+ Vector2(32.0 * float(i + 1), 0.0)
		mercenary.reset_physics_interpolation()
		mercenary.current_hp = clampi(int(rec.get("hp", mercenary.max_hp)),
			1, mercenary.max_hp)
		Game.party.append(mercenary)


## Снять живой отряд перед загрузкой слота: иначе в сцене остались бы наёмники
## прошлой партии, и к ним добавились бы наёмники из сейва.
func _clear_party_nodes() -> void:
	for m in Game.party:
		if is_instance_valid(m):
			(m as Node).queue_free()
	Game.party.clear()

## Спавн НПЦ/монстров из данных карты: .alm секция units (type_id) или
## sidecar .npcs.json (set). Агрессия — UnitDB.is_hostile (монстры palette=5).
func _spawn_map_units(done: Callable = Callable()) -> void:
	if alm_map == null or not alm_map.has_method("get_units"):
		if done.is_valid():
			done.call()
		return
	var recs: Array = alm_map.call("get_units")
	var spawned := 0
	for rec in recs:
		var set_name := ""
		if rec.has("set"):
			set_name = str(rec["set"])
		elif rec.has("type_id"):
			set_name = UnitDB.set_name_for_id(int(rec["type_id"]))
		if set_name == "" or not UnitDB.has(set_name):
			continue
		# Захваченный форпост стражи не имеет: лагерь уже за героем.
		var oid := str(rec.get("outpost", ""))
		if oid != "" and is_outpost_captured(oid):
			continue
		var raw_cell := Vector2i(int(rec.get("x", 0)), int(rec.get("y", 0)))
		var open_pos := _find_open_spot(raw_cell, int(alm_map.get("tile_size")))
		if open_pos.x < 0.0:
			continue
		if UnitDB.is_hostile(set_name) or oid != "":
			_spawn_monster(set_name, open_pos, rec)
		else:
			_spawn_npc(set_name, open_pos, rec)
		spawned += 1
		# Пачки: 190 НПЦ за один кадр давали заметный всплеск после перехода.
		# Оверлей загрузки в это время ещё висит, полоса идёт 60..95%.
		if spawned % 24 == 0:
			_on_spawn_batch(spawned, recs.size())
			# Карта могла быть снесена прямо во время спавна (смена сцены в
			# тестах/переход между зонами): тогда get_tree() уже null, и
			# await падал с "null instance". Остаток спавна бессмыслен.
			if not is_inside_tree():
				return
			await get_tree().process_frame
	print("Карта: спавн юнитов %d" % spawned)
	_on_spawn_batch(recs.size(), recs.size())
	if done.is_valid():
		done.call()


func _on_spawn_batch(spawned: int, total: int) -> void:
	if _loading_view == null or not is_instance_valid(_loading_view):
		return
	var frac := float(spawned) / float(maxi(1, total))
	_loading_view.set_progress(int(60.0 + 35.0 * frac), Loc.t("ui.loading.assembly"))


## После стартового расселения: пара кадров на шейдеры и снятие оверлея.
func _on_startup_spawned() -> void:
	for _i in 3:
		await get_tree().process_frame
	_hide_loading()

func _spawn_monster(set_name: String, pos: Vector2, rec: Dictionary) -> void:
	var e := Enemy.new()
	var oid := str(rec.get("outpost", ""))
	# Имя узла: у стражи форпоста набор одинаковый (city_ork_warrior/t1), и без
	# id лагеря в отладочном выводе все стражники были бы «Monster_t1».
	e.name = ("Outpost_%s_%s" % [oid, set_name.get_file()]) if oid != "" \
		else "Monster_" + set_name.get_file()
	e.anim_set = set_name
	var hp := int(rec.get("hp_max", 0))
	if hp > 0:
		e.max_hp = hp
	var dmg := int(rec.get("damage", 0))
	if dmg > 0:
		e.damage = dmg
	# Форпост (пакет B): фракция и id лагеря едут в записи .npcs.json.
	e.faction = str(rec.get("faction", ""))
	e.outpost_id = str(rec.get("outpost", ""))
	e.position = pos
	e.home_position = pos
	add_child(e)
	enemies.append(e)
	if alm_map != null and alm_map.has_method("watch_enemy"):
		alm_map.call("watch_enemy", e)

func _spawn_npc(set_name: String, pos: Vector2, rec: Dictionary) -> void:
	var n := Npc.new()
	n.name = "Npc_" + set_name.get_file()
	n.anim_set = set_name
	n.position = pos
	n.home = pos
	var role := str(rec.get("role", "citizen"))
	n.role = role
	n.is_patrol = bool(rec.get("patrol", false))
	n.is_archmage = bool(rec.get("archmage", false))
	n.is_city_head = bool(rec.get("head", false)) or role == "head"
	n.city_id = str(rec.get("city_id", ""))
	var post: Array = rec.get("post", [])
	if post.size() >= 2:
		var post_cell := Vector2i(int(post[0]), int(post[1]))
		var post_pos := _find_open_spot(post_cell, int(alm_map.get("tile_size")))
		n.post = post_pos if post_pos.x >= 0.0 else pos
	var hp := int(rec.get("hp_max", 0))
	if hp > 0:
		n.max_hp = hp
	var dmg := int(rec.get("damage", 0))
	if dmg > 0:
		n.damage = dmg
	add_child(n)
	npcs.append(n)

## Ищем проходимую клетку рядом со спавном, у которой есть проходимые соседи
## (минимум 2 из 4) — чтобы персонаж не оказался в тупике. Возвращаем центр
## клетки в мировых координатах или Vector2(-1,-1), если в радиусе 6 нет места.
func _find_open_spot(start: Vector2i, ts: int) -> Vector2:
	if _is_open_spot(start.x, start.y):
		return Vector2(start.x * ts + ts / 2.0, start.y * ts + ts / 2.0)
	for r in range(1, 7):
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if abs(dx) != r and abs(dy) != r:
					continue  # только кольцо на расстоянии r
				var tx := start.x + dx
				var ty := start.y + dy
				if _is_open_spot(tx, ty):
					return Vector2(tx * ts + ts / 2.0, ty * ts + ts / 2.0)
	return Vector2(-1, -1)

## Клетка проходима и имеет >=2 проходимых соседей (не закуток).
func _is_open_spot(tx: int, ty: int) -> bool:
	var ts: int = alm_map.tile_size
	var wx: int = tx * ts + int(ts / 2.0)
	var wy: int = ty * ts + int(ts / 2.0)
	if not alm_map.is_walkable_world(Vector2(wx, wy)):
		return false
	var open_neighbors := 0
	for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		var nx: int = tx + d.x
		var ny: int = ty + d.y
		if nx < 0 or ny < 0 or nx >= alm_map.map_width or ny >= alm_map.map_height:
			continue
		if alm_map.is_walkable_world(Vector2(nx * ts + ts / 2.0, ny * ts + ts / 2.0)):
			open_neighbors += 1
	return open_neighbors >= 2

## Hotbar slot 0..8 for this event. cast_1..3 are rebindable InputMap actions;
## keys 4..9 stay fixed until cast_4..9 are added to project.godot.
func _cast_slot_of(event: InputEvent) -> int:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return -1
	for i in range(3):
		if event.is_action_pressed("cast_%d" % (i + 1)):
			return i
	var key := (event as InputEventKey).keycode
	if key >= KEY_4 and key <= KEY_9:
		return key - KEY_1
	return -1


func _input(event):
	# Dead hero: every world command and the normal Esc menu are off. The
	# game-over panel has its own _input and still receives the event; Esc is
	# deliberately ignored there (player decision 04.11).
	if Game.hero_dead:
		return
	# Окно портала само обрабатывает Esc (Esc = «Остаться»).
	if _portal_confirm != null and is_instance_valid(_portal_confirm):
		return
	# Тактическая пауза: мир замер, значит и приказы/магия недоступны.
	# Раньше _input продолжал работать (корень сцены Always), и клик по миру
	# или хоткей 1..9 запускали заклинание прямо на паузе. Блокируем только
	# их: Esc, Space и панели (I/B/W/M) — это интерфейс, он обязан работать.
	if is_paused:
		if event is InputEventMouseButton:
			return
		if _cast_slot_of(event) >= 0:
			return
	# Прицеливание (свиток или заклинание книги): ПКМ или ESC отменяет.
	# Свиток НЕ тратится, мана/заряд НЕ списываются.
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_RIGHT:
		if not Game.pending_scroll.is_empty() or not Game.pending_spell.is_empty():
			cancel_targeting()
			return
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		if not Game.pending_scroll.is_empty() or not Game.pending_spell.is_empty():
			cancel_targeting()
			return
		# Открытое меню сохранений само перехватывает Esc и закрывается.
		if _save_menu != null and is_instance_valid(_save_menu):
			return
		open_save_menu()
		return

	# Быстрые клавиши (как у разработчиков): Ctrl+1..9 назначает на цифровую
	# клавишу либо выбранную магию, либо расходник под курсором; 1..9 (без Ctrl)
	# применяет назначенное: заклинание — с прицеливанием, зелье — сразу,
	# свиток — с выбором цели кликом.
	if event is InputEventKey and event.pressed and not event.echo:
		var slot := _cast_slot_of(event)
		if slot >= 0:
			if event.ctrl_pressed:
				var sn := str(Game.pending_spell.get("name", ""))
				if sn != "":
					Game.hotbar[slot] = {"kind": "spell", "name": sn}
					print("Быстрая клавиша %d -> %s" % [slot + 1, sn])
					if ui != null and ui.has_method("_notify_hotbar_assigned"):
						ui._notify_hotbar_assigned(slot, sn)
					return
				var iu := hovered_item_key()
				if iu != "":
					var item := ItemDB.find(iu)
					if not item.is_empty():
						Game.hotbar[slot] = {"kind": "item", "key": iu}
						print("Быстрая клавиша %d -> %s" % [slot + 1, iu])
						if ui != null and ui.has_method("_notify_item_assigned"):
							ui._notify_item_assigned(slot, iu)
						return
				return
			if not event.ctrl_pressed:
				var entry: Dictionary = Game.hotbar.get(slot, {})
				match str(entry.get("kind", "")):
					"spell":
						if ui != null and ui.has_method("_quick_cast"):
							ui._quick_cast(str(entry.get("name", "")))
					"item":
						_use_hotbar_item(str(entry.get("key", "")))
				return

	# Both actions are world clicks: attack_click is the second binding for the
	# same contextual action (click an enemy to attack, ground to move).
	if event is InputEventMouseButton and event.pressed \
			and (event.is_action_pressed("move_click") \
				or event.is_action_pressed("attack_click")):
		# Клики по интерфейсу (книга заклинаний, инвентарь, панели, магазин/таверна)
		# не должны двигать/атаковать героя по карте
		if ui != null and ui.has_method("is_editor_open") and ui.is_editor_open():
			return
		if ui != null and ui.has_method("is_pointer_over_ui") and ui.is_pointer_over_ui(event.position):
			return
		var world_position = get_global_mouse_position()
		# Чтение свитка мага: клик выбирает цель (врага или себя/союзника)
		if not Game.pending_scroll.is_empty():
			_resolve_scroll_click(world_position)
			return
		# Заклинание из книги: клик выбирает цель для выбранной магии
		if not Game.pending_spell.is_empty():
			_resolve_spell_click(world_position)
			return
		handle_click(world_position)

	if event is InputEventKey and event.pressed and not event.echo \
			and event.is_action_pressed("pause"):
		is_paused = !is_paused
		get_tree().paused = is_paused
		return

	# Рестарт по Ctrl+R
	if event is InputEventKey and event.pressed and event.keycode == KEY_R and event.ctrl_pressed:
		get_tree().reload_current_scene()

	# Открыть инвентарь по I
	if event is InputEventKey and event.pressed and event.keycode == KEY_I:
		if ui:
			ui.open_inventory_panel()

	# Toggle магий по B
	if event is InputEventKey and event.pressed and event.keycode == KEY_B:
		if ui:
			ui.toggle_spells()

	# Журнал квестов по W (как в оригинале, quest.txt: «press 'W'»)
	if event is InputEventKey and event.pressed and event.keycode == KEY_W \
			and not event.ctrl_pressed:
		if ui and not ui.is_editor_open():
			ui.open_quests()

	# Карта мира по M (23.10)
	if event is InputEventKey and event.pressed and event.keycode == KEY_M \
			and not event.ctrl_pressed:
		if ui:
			ui.open_world_map()

func handle_click(world_position: Vector2):
	# Тактическая пауза: клик по миру — это приказ герою, на паузе его нет.
	if is_paused:
		return
	if Game.hero_dead:
		return
	# Герой мёртв (падение/разложение) — управление не работает
	if is_instance_valid(player) and player.state in ["dead", "decay"]:
		return
	print("Клик в: ", world_position)
	_pending_herb = null
	_pending_building = ""
	_pending_s = {}
	_pending_archmage = null
	_pending_city_head = null

	# Клик по зданию (функциональному или декоративному): всегда к двери.
	# Функциональное — при подходе меню + герой «внутри»; декоративное — только подход.
	var cell := Vector2i(int(int(world_position.x) / 32.0), int(int(world_position.y) / 32.0))
	if alm_map != null and alm_map.has_method("structure_at"):
		var s: Dictionary = alm_map.call("structure_at", cell)
		if not s.is_empty():
			_building_click(_structure_kind(int(s.get("type_id", 0))), s)
			return
	if alm_map != null and alm_map.has_method("herb_at_position"):
		var herb := alm_map.call("herb_at_position", world_position) as HerbNode
		if herb != null:
			_herb_click(herb)
			return
	# Клик по великому магу (капитан): подходим / открываем панель.
	var mage = _archmage_at_position(world_position)
	if mage != null:
		_archmage_click(mage)
		return
	# Клик по главе города: подходим / открываем квесты города.
	var head = _city_head_at_position(world_position)
	if head != null:
		_city_head_click(head)
		return

	var enemy = get_enemy_at_position(world_position)
	if enemy:
		print("Атака врага!")
		player.attack_target = enemy
		player.state = "chase"
	else:
		print("Движение к: ", world_position)
		player_target = world_position
		player.state = "move"
		player.attack_target = null
		# Маршрут с обходом препятствий (pathfinding по клеткам), не «по прямой»
		if alm_map != null and alm_map.has_method("find_path"):
			player.begin_path(alm_map.find_path(player.global_position, world_position))

## Функциональная роль здания (StructureDB).
## Логика переехала в StructureDB.kind_of — она была продублирована копией в
## tests/alice_buildings_smoke.gd, и правка роли в игре и в тесте разъезжалась
## молча. Теперь тест зовёт настоящий код.
func _structure_kind(type_id: int) -> String:
	return StructureDB.kind_of(type_id)

## Клик по зданию: подходим к двери (южный край футпринта).
## kind != "" — функциональное (магазин/таверна/…): при подходе меню.
## kind == "" — декоративное: только подход, герой остаётся на карте.
func _building_click(kind: String, s: Dictionary) -> void:
	if ui == null or not is_instance_valid(player):
		return
	var door := _door_point(s)
	if kind != "" and player.global_position.distance_to(door) <= 90.0:
		_pending_building = ""
		_pending_s = {}
		_open_building_kind(kind, s)
		return
	_pending_building = kind
	_pending_s = s
	player.stop_movement()
	player_target = door
	player.state = "move"
	player.attack_target = null
	if alm_map != null and alm_map.has_method("find_path"):
		player.begin_path(alm_map.find_path(player.global_position, door))

func _open_building_kind(kind: String, s: Dictionary = {}) -> void:
	if ui == null:
		return
	# Репутация (28.10): таверна и магазин работают с репутацией героя у
	# фракции ГОРОДА. Раса города уже лежит в city_heads() (её пишет генератор),
	# а здание ищет ближайшую главу — отдельного city_id у здания нет.
	var race := _city_race_at_world(_door_point(s)) if not s.is_empty() else ""
	match kind:
		"shop": ui.open_shop(race)
		"alchemy": ui.open_alchemy()
		"inn": ui.open_inn(race)
		"school": ui.open_school()
		"workshop": ui.open_workshop()


## Раса города, ближайшего к точке мира ("" — на карте нет глав/города).
## Нужна панелям таверны и магазина: репутация героя считается по фракции.
func _city_race_at_world(p: Vector2) -> String:
	if alm_map == null or not alm_map.has_method("city_heads"):
		return ""
	var heads: Dictionary = alm_map.call("city_heads")
	if heads.is_empty():
		return ""
	var ts := int(alm_map.get("tile_size"))
	var best := ""
	var best_d := INF
	for cid in heads:
		var rec: Dictionary = heads[cid]
		for cell in (rec.get("cells", []) as Array):
			if not (cell is Array) or (cell as Array).size() < 2:
				continue
			var cx := int((cell as Array)[0])
			var cy := int((cell as Array)[1])
			var d := p.distance_to(Vector2(cx * ts + ts / 2.0, cy * ts + ts / 2.0))
			if d < best_d:
				best_d = d
				best = str(rec.get("race", ""))
	return best

func _herb_click(herb: HerbNode) -> void:
	if not is_instance_valid(herb) or not herb.is_available():
		return
	_pending_building = ""
	player.attack_target = null
	if player.global_position.distance_to(herb.global_position) <= 52.0:
		_harvest_herb(herb)
		return
	_pending_herb = herb
	player_target = herb.global_position
	player.state = "move"
	if alm_map != null and alm_map.has_method("find_path"):
		player.begin_path(alm_map.find_path(player.global_position, herb.global_position))

func _process_pending_herb() -> void:
	if _pending_herb == null:
		return
	if not is_instance_valid(_pending_herb) or not _pending_herb.is_available():
		_pending_herb = null
		return
	if player.global_position.distance_to(_pending_herb.global_position) <= 52.0:
		var herb := _pending_herb
		_pending_herb = null
		_harvest_herb(herb)

func _harvest_herb(herb: HerbNode) -> void:
	if not is_instance_valid(herb) or not herb.harvest():
		return
	player.add_item(herb.item_key)
	if is_instance_valid(ui):
		ui.refresh_inventory()
	SoundDB.play("ui.click")
	print("Собрана трава: %s" % herb.item_key)

## Великий маг города (капитан) под курсором.
func _archmage_at_position(click_pos: Vector2) -> Node2D:
	for n in npcs:
		if not is_instance_valid(n):
			continue
		if not ("is_archmage" in n) or not bool(n.is_archmage):
			continue
		if unit_hover_hit(n, click_pos, 8.0):
			return n
	return null

## Клик по магу: если рядом — панель, иначе подходим.
func _archmage_click(mage: Node2D) -> void:
	if ui == null or not is_instance_valid(player) or not is_instance_valid(mage):
		return
	_pending_building = ""
	_pending_s = {}
	_pending_herb = null
	player.attack_target = null
	_pending_city_head = null
	if player.global_position.distance_to(mage.global_position) <= 90.0:
		var ctx := _archmage_context(mage)
		ui.open_archmage(str(ctx.get("city_id", "")), str(ctx.get("race", "")))
		return
	_pending_archmage = mage
	player_target = mage.global_position
	player.state = "move"
	if alm_map != null and alm_map.has_method("find_path"):
		player.begin_path(alm_map.find_path(player.global_position, mage.global_position))

func _process_pending_archmage() -> void:
	if _pending_archmage == null:
		return
	if not is_instance_valid(_pending_archmage) or ui == null:
		_pending_archmage = null
		return
	if player.global_position.distance_to(_pending_archmage.global_position) <= 90.0:
		var mage := _pending_archmage
		_pending_archmage = null
		var ctx := _archmage_context(mage)
		ui.open_archmage(str(ctx.get("city_id", "")), str(ctx.get("race", "")))


## Контекст великого мага для панели: город и его раса. Раса берётся из
## city_heads() по city_id NPC; запасной путь — по имени набора капитана
## («city_druid_mage/t3» -> druid). Пусто — панель откатится на расу героя.
func _archmage_context(mage: Node) -> Dictionary:
	var city_id := ""
	if "city_id" in mage:
		city_id = str(mage.get("city_id"))
	var race := ""
	if city_id != "" and alm_map != null and alm_map.has_method("city_heads"):
		var heads: Dictionary = alm_map.call("city_heads")
		var rec: Dictionary = heads.get(city_id, {})
		race = str(rec.get("race", ""))
	if race == "" and "anim_set" in mage:
		race = MapGenerator.race_of_set(str(mage.get("anim_set")))
	return {"city_id": city_id, "race": race}


## Глава города под курсором (NPC ролью "head").
func _city_head_at_position(click_pos: Vector2) -> Node2D:
	for n in npcs:
		if not is_instance_valid(n):
			continue
		if not ("is_city_head" in n) or not bool(n.is_city_head):
			continue
		if unit_hover_hit(n, click_pos, 8.0):
			return n
	return null


## Клик по главе: если рядом — панель квестов, иначе подходим (как у мага).
func _city_head_click(head: Node2D) -> void:
	if ui == null or not is_instance_valid(player) or not is_instance_valid(head):
		return
	_pending_building = ""
	_pending_s = {}
	_pending_herb = null
	_pending_archmage = null
	player.attack_target = null
	if player.global_position.distance_to(head.global_position) <= 90.0:
		ui.open_quests(str(head.get("city_id")))
		return
	_pending_city_head = head
	player_target = head.global_position
	player.state = "move"
	if alm_map != null and alm_map.has_method("find_path"):
		player.begin_path(alm_map.find_path(player.global_position, head.global_position))


func _process_pending_city_head() -> void:
	if _pending_city_head == null:
		return
	if not is_instance_valid(_pending_city_head) or ui == null:
		_pending_city_head = null
		return
	if player.global_position.distance_to(_pending_city_head.global_position) <= 90.0:
		var cid := str(_pending_city_head.get("city_id"))
		_pending_city_head = null
		ui.open_quests(cid)


## Точка входа (дверь): проходимая клетка под южным краем корпуса здания.
func _door_point(s: Dictionary) -> Vector2:
	var def := StructureDB.get_by_id(int(s.get("type_id", 0)))
	var fw := int(def.get("tile_width", 1))
	var th := int(def.get("tile_height", 1))
	var x := int(s.get("ax", 0))
	var y := int(s.get("ay", 0))
	var base := Vector2i(x + int(fw / 2.0), y + th)
	for r in range(3):
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if abs(dx) != r and abs(dy) != r:
					continue
				var c := base + Vector2i(dx, dy)
				var p := Vector2(c.x * 32.0 + 16.0, c.y * 32.0 + 16.0)
				if alm_map != null and alm_map.has_method("is_walkable_world") \
						and alm_map.is_walkable_world(p):
					return p
	return Vector2(x * 32.0 + fw * 16.0, (y + th) * 32.0)

## Когда герой подошёл к двери — «входим»: меню (функциональное) или остановка.
func _process_pending_building() -> void:
	if _pending_s.is_empty() or not is_instance_valid(player):
		return
	var door := _door_point(_pending_s)
	if player.global_position.distance_to(door) > 80.0:
		return
	var k := _pending_building
	var s := _pending_s
	_pending_building = ""
	_pending_s = {}
	player.stop_movement()
	# Декоративное (k==""): герой остаётся видимым у стены, меню нет.
	if k != "":
		_open_building_kind(k, s)

## Юнит под курсором (враг ИЛИ мирный НПЦ) по видимой области корпуса.
func _hover_unit() -> Node2D:
	if not is_instance_valid(player):
		return null
	var mouse := player.get_global_mouse_position()
	# Отсечение (29.10): раньше точный хит-бокс считался для КАЖДОГО врага и
	# НПЦ карты каждый кадр (160+28), хотя под курсором может быть только
	# соседняя фигура. Дешёвое сравнение по центрам снимает почти всё.
	var reach_sq := 128.0 * 128.0
	for e in enemies:
		if is_instance_valid(e) and (e as Node2D).global_position.distance_squared_to(mouse) <= reach_sq \
				and unit_hover_hit(e, mouse):
			return e
	for e in npcs:
		if is_instance_valid(e) and (e as Node2D).global_position.distance_squared_to(mouse) <= reach_sq \
				and unit_hover_hit(e, mouse):
			return e
	return null

## ВЫСОТА спрайта юнита над его основанием (px) — то, насколько высоко надо
## поднять эффект, чтобы он оказался над головой, а не внутри тела.
##
## Берётся из UnitAnim.visual_height(): это реальная высота кадра с учётом
## масштаба. Нельзя брать _unit_metrics() — это ФУТПРИНТ (сколько клеток
## занимает юнит): для героя с tile_size 1 это 32 px, тогда как спрайт выше, и
## эффект по этой высоте оказывался у персонажа внутри (жалоба игрока).
##
## У всех четырёх типов юнитов (player/enemy/npc/mercenary) узел анимации
## называется "UnitAnim".
##
## Возвращает высоту ФИГУРЫ, а не кадра: кадры у нас единого холста (64×64),
## а фигура внутри занимает ~54 px, и над головой остаётся пустое поле.
## Раньше здесь возвращался холст, и всё, что считается «от высоты» (ауры,
## крест лечения, камера, точка каста), уезжало вверх/вниз на ~10 px.
static func unit_visual_height(u: Node2D) -> float:
	var r := unit_local_rect(u)
	if r.size.y > 0.0:
		return r.size.y
	return 32.0


## Рамка фигуры в ЛОКАЛЬНЫХ координатах юнита: ноги ≈ 0, макушка — отрицательный y.
## Источник — реальные непрозрачные пиксели текущего кадра.
static func unit_local_rect(u: Node2D) -> Rect2:
	if not is_instance_valid(u):
		return Rect2(Vector2(-12, -40), Vector2(24, 40))
	var anim := u.get_node_or_null("UnitAnim")
	if anim != null and anim.has_method("content_rect"):
		var r: Rect2 = anim.call("content_rect")
		if r.size.x > 0.5 and r.size.y > 0.5:
			return r
	# Заглушка: 24×40 — прежняя приблизительная фигура.
	return Rect2(Vector2(-12, -40), Vector2(24, 40))


## Кэш рамок содержимого текстур. Кадр 64×64 сканируется один раз.
static var _content_cache: Dictionary = {}


## Рамка НЕПРОЗРАЧНОГО содержимого текстуры в её пикселях (кэшируется).
## Альфа-порог 0.06: сглаженные края и почти прозрачный ореол не должны
## растягивать рамку до всего холста.
static func texture_content_rect(tex: Texture2D) -> Rect2:
	if tex == null:
		return Rect2()
	var key := tex.resource_path
	if key == "":
		key = "id:%d" % tex.get_instance_id()
	if _content_cache.has(key):
		return _content_cache[key]
	var img: Image = tex.get_image()
	if img == null:
		_content_cache[key] = Rect2()
		return Rect2()
	if img.is_compressed():
		img.decompress()
	var w := img.get_width()
	var h := img.get_height()
	var min_x := w
	var min_y := h
	var max_x := -1
	var max_y := -1
	for y in range(h):
		for x in range(w):
			if img.get_pixel(x, y).a > 0.06:
				if x < min_x:
					min_x = x
				if x > max_x:
					max_x = x
				if y < min_y:
					min_y = y
				if y > max_y:
					max_y = y
	var out := Rect2()
	if max_x >= min_x and max_y >= min_y:
		out = Rect2(min_x, min_y, max_x - min_x + 1, max_y - min_y + 1)
	_content_cache[key] = out
	return out


## Сколько пикселей зазора между ТЕЛАМИ нужно, чтобы достать ударом.
## Копьё — 20, посох — 14, меч/топор — 10, палица — 8, кулак/когти — 10.
const REACH_BY_WEAPON := {
	"club": 8.0, "axe": 10.0, "sword": 10.0, "pike": 20.0,
	"staff": 14.0, "unarmed": 10.0, "bow": 10.0,
}
const REACH_DEFAULT := 10.0


## Длина удара конкретного юнита: оружие героя или типовая лапа монстра.
static func attack_reach(u: Node2D) -> float:
	if is_instance_valid(u) and u is Player:
		return float(REACH_BY_WEAPON.get(str(u.get("weapon")), REACH_DEFAULT))
	return REACH_DEFAULT

## Размер спрайта юнита (w, h). static: считается только по anim_set, своего
## состояния не читает — вызывается и из Game, и из SpellAura.
##
## ВНИМАНИЕ: это ФУТПРИНТ (сколько клеток занимает юнит), а НЕ высота спрайта.
## Для высоты (куда вешать эффекты над головой) есть unit_visual_height().
static func _unit_metrics(u: Node2D) -> Array:
	var set_name := ""
	if "anim_set" in u:
		set_name = str(u.get("anim_set"))
	if set_name == "" and u is Player:
		set_name = (u as Player).anim_set_name()
	# Размер спрайта юнита в пикселях. Раньше читались поля "w"/"h" из units_db.json,
	# но их там НЕТ — срабатывала заглушка 128, и кольцо выделения было шириной 144 px
	# независимо от юнита (для гнома — круг втрое шире него самого).
	var w := 32
	var h := 32
	if set_name != "":
		var ts: int = maxi(1, UnitDB.tile_size(set_name))
		w = ts * 32
		h = ts * 32
	return [w, h]

## Точка кольца выделения: центр тела юнита. Спрайт рисуется вверх от точки
## «пола» и поднимается на рельефе — без учёта этого кольцо «висит в пустоте».
func _target_ring_pos(u: Node2D) -> Vector2:
	var m := _unit_metrics(u)
	var rise := 0.0
	if alm_map != null and alm_map.has_method("relief_at_world"):
		rise = float(alm_map.call("relief_at_world", u.global_position))
	return Vector2(u.global_position.x, u.global_position.y - float(m[1]) * 0.55 - rise)

## Подсветка цели: враг под курсором / текущая цель атаки (красное кольцо)
## или мирный НПЦ под курсором (жёлтое кольцо).
func _update_target_ring() -> void:
	var target: Node2D = null
	var hostile := false
	if is_instance_valid(player) and is_instance_valid(player.attack_target) \
			and player.state in ["chase", "attack"]:
		target = player.attack_target
		hostile = true
	else:
		target = _hover_unit()
		hostile = target != null and enemies.has(target)
	if _select_ring == null:
		return
	if is_instance_valid(target):
		_select_ring.visible = true
		_select_ring.color = Color(1, 0.3, 0.2, 0.9) if hostile else Color(0.95, 0.85, 0.35, 0.9)
		_select_ring.global_position = _target_ring_pos(target)
		var m := _unit_metrics(target)
		_select_ring.radius = maxf(22.0, float(m[0]) / 2.0 + 8.0)
	else:
		_select_ring.visible = false

func get_enemy_at_position(click_pos: Vector2) -> Node2D:
	for enemy in enemies:
		if is_instance_valid(enemy) and unit_hover_hit(enemy, click_pos, 8.0):
			return enemy
	return null

## Свиток мага: клик выбрал цель. Враг — для урона/области/стены,
## герой или союзник (НПЦ/наёмник) — для лечения/защиты/баффа.
## Ключ предмета под курсором в открытом инвентаре ("" = панель закрыта или
## курсор не над ячейкой). Нужен для назначения расходника на хоткей.
func hovered_item_key() -> String:
	if ui == null or not is_instance_valid(ui):
		return ""
	var panel = ui.get("_inventory_panel")
	if panel == null or not is_instance_valid(panel):
		return ""
	return str(panel.get("hovered_item_key"))


## Применение расходника с хоткея. Зелье выпивается сразу, свиток входит в
## прицеливание — ровно как клик по нему в инвентаре.
func _use_hotbar_item(item_key: String) -> void:
	if item_key == "":
		return
	var item := ItemDB.find(item_key)
	if item.is_empty():
		Game.hotbar.erase(_hotbar_slot_of(item_key))
		return
	if not is_instance_valid(player) or not player.has_item(item_key):
		_flash_cast_error("Нет такого расходника в инвентаре.")
		return
	match str(item.get("quality", "")):
		"Potion":
			if player.use_potion(item_key):
				if ui != null and ui.has_method("refresh_inventory"):
					ui.refresh_inventory()
				if ui != null and ui.has_method("refresh_inventory"):
					ui.refresh_inventory()
				if ui != null and ui.has_method("_update_gold") and player != null:
					ui._update_gold(int(player.gold))
		"Scroll", "SuperScroll":
			var spell_name := str(item.get("type", ""))
			Game.pending_scroll = {"spell": spell_name, "item_key": item_key}
			# Курсор-прицел + подсказка, как при выборе свитка из инвентаря.
			if ui != null and ui.has_method("_begin_scroll_targeting"):
				ui._begin_scroll_targeting(item_key)
			else:
				_flash_cast_error("Выберите цель для свитка.")
		_:
			_flash_cast_error("Этот предмет нельзя применить с хоткея.")


func _hotbar_slot_of(item_key: String) -> int:
	for slot in Game.hotbar:
		var entry: Dictionary = Game.hotbar.get(slot, {})
		if str(entry.get("kind", "")) == "item" and str(entry.get("key", "")) == item_key:
			return int(slot)
	return -1


func _resolve_scroll_click(world_position: Vector2) -> void:
	if not is_instance_valid(player):
		return
	var spell := str(Game.pending_scroll.get("spell", ""))
	if spell == "":
		return
	var target_kind := SpellDB.target_of(spell)
	var target: Node2D = null
	if target_kind == "enemy":
		target = get_enemy_at_position(world_position)
		if target == null:
			target = player.get_nearest_enemy(world_position, 220.0)
		if target == null:
			_flash_cast_error("Нет врага под курсором — укажите противника.")
			return
	elif target_kind == "point":
		var under := get_enemy_at_position(world_position)
		if under != null:
			world_position = under.global_position
	else:
		target = _ally_at_position(world_position)
		if target == null:
			# Аналогично книгам: щит/бафф накладывается на героя по умолчанию
			if SpellDB.kind_of(spell) == "buff":
				target = player
			else:
				_flash_cast_error("Укажите героя или союзника для этого заклинания.")
				return

	# Дальность из базы (раньше не проверялась вообще)
	var max_range := SpellDB.range_of(spell)
	if max_range > 0.0 and target_kind != "self" \
			and player.cast_origin().distance_to(world_position) > max_range:
		_flash_cast_error("Слишком далеко: «%s» достаёт на %d м." % [spell, int(max_range / 32.0)])
		return

	# Предмет списывается ТОЛЬКО если эффект применился: раньше remove_item
	# вызывался безусловно, и свитки «Scroll Fire Wall» просто исчезали.
	# Сила свитка (50/100) берётся из его effects и заменяет навык героя.
	var item_key := str(Game.pending_scroll.get("item_key", ""))
	var scroll_power := SpellDB.scroll_power_of(ItemDB.find(item_key))
	var applied := false
	if target != null:
		applied = player.apply_scroll_to_target(spell, target, scroll_power)
	else:
		applied = player.apply_scroll_to_target_point(spell, world_position, scroll_power)
	if not applied:
		_flash_cast_error("Заклинание не сработало — предмет не потрачен.")
		return
	player.remove_item(str(Game.pending_scroll.get("item_key", "")))
	Game.pending_scroll = {}
	if ui != null and ui.has_method("_finish_scroll_targeting"):
		ui._finish_scroll_targeting()


func _flash_cast_error(msg: String) -> void:
	print(msg)
	if ui != null and ui.has_method("_flash_targeting_error"):
		ui._flash_targeting_error(msg)

## Заклинание из книги: клик выбрал цель. Атака/область/стена — по врагу или
## точке, лечение/защита/бафф — по герою или союзнику. Мана/заряд списываются
## только при успешном касте.
func _resolve_spell_click(world_position: Vector2) -> void:
	if is_paused:
		return
	if not is_instance_valid(player):
		return
	var name := str(Game.pending_spell.get("name", ""))
	if name == "":
		return
	# Защита: не кастовать в тот же кадр, что и выбор магии из книги
	if Engine.get_process_frames() == Game._spell_targeting_frame:
		return
	var target_kind := SpellDB.target_of(name)
	var target_position := world_position
	var target_node: Node2D = null
	var ok := true
	var enemy := get_enemy_at_position(world_position)

	match target_kind:
		"enemy":
			if enemy != null:
				target_node = enemy
				target_position = enemy.global_position
			else:
				enemy = player.get_nearest_enemy(world_position, 220.0)
				if enemy == null:
					ok = false
				else:
					target_node = enemy
					target_position = enemy.global_position
		"point":
			if enemy != null:
				target_position = enemy.global_position
		"ally":
			var ally := _ally_at_position(world_position)
			if ally == null:
				# Щиты/баффи удобно накладывать на себя, не целясь точно
				if SpellDB.kind_of(name) == "buff":
					ally = player
				else:
					ok = false
			if ally != null:
				target_position = ally.global_position
				target_node = ally
		_:
			target_node = player
			target_position = player.global_position

	if not ok:
		var msg := "Укажите ВРАГА для «%s» (ПКМ/ESC — отмена)." % name \
			if target_kind == "enemy" else "Укажите ГЕРОЯ или СОЮЗНИКА для «%s»." % name
		print(msg)
		if ui != null and ui.has_method("_flash_targeting_error"):
			ui._flash_targeting_error(msg)
		return

	# Дальность из базы: раньше поле range вообще не читалось, поэтому можно
	# было кастовать через полкарты (включая телепорт).
	var max_range := SpellDB.range_of(name)
	if max_range > 0.0 and target_kind != "self":
		var origin: Vector2 = player.cast_origin()
		if origin.distance_to(target_position) > max_range:
			var rmsg := "Слишком далеко: «%s» достаёт на %d м." % [name, int(max_range / 32.0)]
			if ui != null and ui.has_method("_flash_targeting_error"):
				ui._flash_targeting_error(rmsg)
			return

	if not player.cast_spell(name, target_position, target_node):
		print("Не удалось кастовать: " + name)
	if ui != null and ui.has_method("_finish_spell_targeting"):
		ui._finish_spell_targeting()

## Цель-союзник под курсором: сам герой, мирный НПЦ или наёмник.
func _ally_at_position(world_position: Vector2) -> Node2D:
	if is_instance_valid(player) and unit_hover_hit(player, world_position, 8.0):
		return player
	for n in npcs:
		if is_instance_valid(n) and unit_hover_hit(n, world_position, 8.0):
			return n
	for m in party:
		if is_instance_valid(m) and unit_hover_hit(m, world_position, 8.0):
			return m
	return null

## Отмена прицеливания (свиток или заклинание книги). НЕ тратится.
func cancel_targeting() -> void:
	Game.pending_scroll = {}
	Game.pending_spell = {}
	Game._spell_targeting_frame = -1
	if ui != null and ui.has_method("_cancel_targeting"):
		ui._cancel_targeting()

## Хит-бокс юнита в мире — по РЕАЛЬНОЙ фигуре.
##
## История: сначала бокс собирался из units_db `w/h` (128) + `sel_box`; там
## `sel_box` почти нигде нет, и заглушка 96×96 давала «меч достаёт на 4–5
## клеток». Потом добавили проверку «sel_box дефолтный при w>=128», но у ВСЕХ
## наших наборов w=h=64, проверка не срабатывала, и юниты продолжали носить
## бокс 96×96 — да ещё смещённый: `position + (-32,-64) + (16,16)` = от −16 до
## +80 по X, то есть на 56 px вправо от центра.
##
## Теперь: явный `sel_box` берём, только если он реально лежит внутри кадра;
## иначе — рамка тела по стойке (`UnitAnim.body_rect()`), а не по холсту и не
## по кадру удара (меч/посох не должны раздувать тело).
static func unit_hit_rect(u: Node2D) -> Rect2:
	var t0 := perf_begin()
	var out := _unit_hit_rect_impl(u)
	perf_end("hit_rect", t0)
	return out


static func _unit_hit_rect_impl(u: Node2D) -> Rect2:
	if not is_instance_valid(u):
		return Rect2()
	var set_name := ""
	if "anim_set" in u:
		set_name = str(u.get("anim_set"))
	if set_name == "" and u is Player:
		set_name = (u as Player).anim_set_name()
	if set_name != "":
		var o := UnitDB.get_set(set_name)
		var raw: Variant = o.get("sel_box", null)
		if raw is Array and (raw as Array).size() == 4:
			var cw := int(o.get("w", 128))
			var ch := int(o.get("h", 128))
			var sb := UnitDB.sel_box(set_name)
			var inside := sb.position.x >= 0 and sb.position.y >= 0 \
				and sb.position.x + sb.size.x <= cw and sb.position.y + sb.size.y <= ch \
				and sb.size.x > 0 and sb.size.y > 0
			if inside:
				var base := u.global_position + Vector2(-cw / 2.0, -float(ch))
				return Rect2(base + Vector2(sb.position), Vector2(sb.size))
	# Реальное тело: рамка стойки в локальных координатах + мировая позиция.
	var body := unit_body_rect(u)
	if body.size.x > 0.5 and body.size.y > 0.5:
		return body
	var local := unit_local_rect(u)
	return Rect2(u.global_position + local.position, local.size)


## Рамка ТЕЛА в мире: по кадру стойки, а не по текущему (кадр удара шире).
static func unit_body_rect(u: Node2D) -> Rect2:
	var t0 := perf_begin()
	var out := _unit_body_rect_impl(u)
	perf_end("body_rect", t0)
	return out


static func _unit_body_rect_impl(u: Node2D) -> Rect2:
	if not is_instance_valid(u):
		return Rect2()
	var anim := u.get_node_or_null("UnitAnim")
	if anim != null and anim.has_method("body_rect"):
		var r: Rect2 = anim.call("body_rect")
		if r.size.x > 0.5 and r.size.y > 0.5:
			return Rect2(u.global_position + r.position, r.size)
	var local := unit_local_rect(u)
	return Rect2(u.global_position + local.position, local.size)

## Пиксельный ховер: попадание по непрозрачному пикселю текущего кадра.
##
## unit_hit_rect строится из легаси sel_box/аппроксимации и у части наборов
## не совпадает с видимым силуэтом (жалоба игрока: «надо целиться ниже»).
## Здесь — точный тест по альфа-каналу; fallback — unit_hit_rect, если
## спрайта/текстуры нет (битые наборы, смерть без кадров).
static var _alpha_cache: Dictionary = {}   # Texture2D -> Dictionary{столбец x -> Dictionary{y: true}}
static func unit_hover_hit(u: Node2D, world_pos: Vector2, slack: float = 6.0) -> bool:
	if not is_instance_valid(u):
		return false
	var anim: Node = u.get_node_or_null("UnitAnim")
	var sprite: Sprite2D = null
	if anim != null:
		sprite = anim.get_node_or_null("Sprite") as Sprite2D
	var tex: Texture2D = null
	if sprite != null and sprite.texture != null and is_instance_valid(sprite.texture):
		tex = sprite.texture
	if tex == null:
		return unit_hit_rect(u).grow(slack).has_point(world_pos)
	# Точка в локальных координатах спрайта (учитывает рельеф/позицию узла).
	var lp := sprite.to_local(world_pos)
	var sx := sprite.scale.x
	var sy := sprite.scale.y
	if is_equal_approx(sx, 0.0) or is_equal_approx(sy, 0.0):
		return unit_hit_rect(u).grow(slack).has_point(world_pos)
	var px := int(floor(lp.x / sx))
	var py := int(floor(lp.y / sy))
	var w := tex.get_width()
	var h := tex.get_height()
	if sprite.flip_h:
		px = w - 1 - px
	# Вне кадра — прежний rect с допуском (люфты, тени, широкие хвосты).
	if px < -int(slack) or py < -int(slack) or px >= w + int(slack) or py >= h + int(slack):
		return unit_hit_rect(u).grow(slack).has_point(world_pos)
	var img := tex.get_image()
	if img == null:
		return unit_hit_rect(u).grow(slack).has_point(world_pos)
	var mask: Dictionary = _alpha_cache.get(tex, {})
	if mask.is_empty():
		mask = _build_alpha_mask(img)
		_alpha_cache[tex] = mask
	var cx := clampi(px, 0, w - 1)
	var cy := clampi(py, 0, h - 1)
	var col: Dictionary = mask.get(cx, {})
	if col.has(cy):
		return true
	# Непрозрачный пиксель не под курсором: допуск slack по 4 направлениям.
	var s := int(ceil(slack))
	for off in [[s, 0], [-s, 0], [0, s], [0, -s]]:
		var nx: int = cx + int(off[0])
		var ny: int = cy + int(off[1])
		if nx >= 0 and nx < w and ny >= 0 and ny < h:
			if (mask.get(nx, {}) as Dictionary).has(ny):
				return true
	return false

## Маска непрозрачных пикселей: столбец x -> множество y (порог альфы 8/255).
static func _build_alpha_mask(img: Image) -> Dictionary:
	var mask := {}
	for x in range(img.get_width()):
		var col := {}
		for y in range(img.get_height()):
			if img.get_pixel(x, y).a8 > 8:
				col[y] = true
		if not col.is_empty():
			mask[x] = col
	return mask

## Расстояние между КОРПУСАМИ юнитов (хит-бокс к хит-боксу; 0 при пересечении).
## Для боя: юниты встают вплотную телами и атакуют, а не «издалека по центру».
static func units_range(a: Node2D, b: Node2D) -> float:
	perf_count("units_range_calls")
	var ra := unit_hit_rect(a)
	var rb := unit_hit_rect(b)
	if ra.intersects(rb):
		return 0.0
	var dx := maxf(0.0, maxf(ra.position.x - (rb.position.x + rb.size.x),
		rb.position.x - (ra.position.x + ra.size.x)))
	var dy := maxf(0.0, maxf(ra.position.y - (rb.position.y + rb.size.y),
		rb.position.y - (ra.position.y + ra.size.y)))
	return sqrt(dx * dx + dy * dy)

## Добавить травму камере (экранная тряска). amount: 0.0–1.0.
static func camera_trauma(amount: float) -> void:
	_trauma = clampf(_trauma + amount, 0.0, 1.0)

func _physics_process(delta):
	# Камера в том же тике, что и герой: иначе на high-refresh
	# lerp в _process «дёргает» картинку относительно physics-interpolated
	# позиции юнита (жалоба игрока 07.10).
	if is_instance_valid(player) and camera:
		# Камеру двигаем явно в physics-процессе — значит и обрабатывать её
		# позицию она обязана в том же тике. process_callback = PHYSICS задан
		# в _ready выше/в сцене; включение physics-интерполяции проекта
		# заставляет движок сам "переопределять" камеру на physics-режим —
		# это штатно и печатает WARNING. Глушим вывод вар на этом узле.
		camera.position = camera.position.lerp(player.camera_focus(), 8.0 * delta)
		if _trauma > 0.0:
			_trauma = maxf(_trauma - 1.2 * delta, 0.0)
			var shake := _trauma * _trauma
			_trauma_t += delta * 30.0
			camera.offset = Vector2(
				8.0 * shake * sin(_trauma_t * 1.7),
				6.0 * shake * sin(_trauma_t * 2.3)
			)
		else:
			camera.offset = Vector2.ZERO


func _process(delta):
	if not Game.perf_enabled:
		_process_impl(delta)
		return
	var t0 := Time.get_ticks_usec()
	_process_impl(delta)
	Game.perf_end("game", t0)
	Game.perf_frame()


func _process_impl(delta):
	if is_paused:
		return
	_gray_respawn_tick(delta)
	if is_instance_valid(player) and camera:
		_autosave_tick(delta)
		# Камера уже в _physics_process — здесь только UI/реген/таймеры.
	if is_instance_valid(ui) and is_instance_valid(player):
		ui.update_ui(player, delta)
	
	# Регенерация героя: HP и мана по статам, а не жёсткая «+1 мана/с».
	# Раньше мана качалась 1/с независимо от Spirit, а HP не регенерировался.
	_regen_hero(delta)
	
	# Обработка режимов действий
	_process_action_mode()
	if Game.perf_enabled:
		var th := Time.get_ticks_usec()
		_update_target_ring()
		Game.perf_end("hover", th)
	else:
		_update_target_ring()
	_process_pending_building()
	_process_pending_herb()
	_process_pending_archmage()
	_process_pending_city_head()
	Game.tick_shields(delta)
	StatusEffects.tick(delta)
	_check_portal()
	_tick_world_clock(delta)


## Календарь мира (28.10). Живёт здесь, а не в WorldBus._process: пауза уже
## проверена выше (`is_paused`), а headless sim_runner не поднимает автолоады.
func _tick_world_clock(delta: float) -> void:
	var bus := _world_bus()
	if bus == null or not bus.has_method("tick_day"):
		return
	bus.call("tick_day", delta)


## F3-лента мира: сектор/владелец/FPS, события SIM, болтовня НПЦ. F3
## добавляет технические цифры. Размеры — доли вьюпорта.
func _setup_world_feed() -> void:
	if _world_feed_panel != null and is_instance_valid(_world_feed_panel):
		return
	var script: GDScript = load("res://scripts/world_feed_panel.gd")
	_world_feed_panel = script.new()
	_world_feed_panel.setup()
	add_child(_world_feed_panel)


## Регенерация героя раз в секунду: HP = 1 + Body/5, мана = 1 + Spirit/10.
func _regen_hero(delta: float) -> void:
	if not is_instance_valid(player):
		return
	if Game.hero_dead or player.state == "dead" or player.state == "decay":
		return
	mana_regen_accum += delta
	if mana_regen_accum < 1.0:
		return
	mana_regen_accum -= 1.0
	if player.current_hp < player.max_hp:
		player.heal_amount(player._calc_hp_regen())
	if player.has_mana and player.current_mana < player.max_mana:
		var gain: int = player._calc_mana_regen()
		player.current_mana = mini(player.max_mana, player.current_mana + gain)
		DamageNumber.show_at(player.global_position, gain, "mana")

func _check_portal() -> void:
	if not is_instance_valid(player) or not is_instance_valid(alm_map):
		return
	if _travelling or (_portal_confirm != null and is_instance_valid(_portal_confirm)):
		return
	var TILE: int = 32
	var cell := Vector2i(int(int(player.global_position.x) / float(TILE)), int(int(player.global_position.y) / float(TILE)))
	var portal := _portal_at(cell)
	if portal.is_empty():
		# Сошёл с портала — снова можно спрашивать.
		_portal_armed = true
		_portal_prompt_cell = Vector2i(-1, -1)
		return
	if not _portal_armed:
		return
	if _portal_prompt_cell == cell:
		return
	_portal_prompt_cell = cell
	_show_portal_confirm(portal)


## Портал под клеткой: новый формат с адресом или старый sidecar без адреса.
func _portal_at(cell: Vector2i) -> Dictionary:
	var portals: Array = alm_map.call("get_portals") if alm_map.has_method("get_portals") else []
	for raw in portals:
		if raw is Dictionary and Vector2i((raw as Dictionary).get("cell", Vector2i(-1, -1))) == cell:
			return raw as Dictionary
	var cells: Array = alm_map.call("get_portal_cells")
	for pc in cells:
		if cell == pc:
			return {"cell": cell, "to": "", "dir": ""}
	return {}


## Мировая позиция портала, который ведёт обратно в from_sector. Прибытие
## через портал ставит героя сюда, а не на спавн у города.
func _arrival_portal_pos(from_sector: String) -> Vector2:
	if from_sector == "" or not is_instance_valid(alm_map):
		return Vector2(-1, -1)
	var portals: Array = alm_map.call("get_portals") if alm_map.has_method("get_portals") else []
	var ts: int = int(alm_map.get("tile_size"))
	for raw in portals:
		if not (raw is Dictionary):
			continue
		var rec: Dictionary = raw as Dictionary
		if str(rec.get("to", "")) != from_sector:
			continue
		var cell: Vector2i = rec.get("cell", Vector2i(-1, -1))
		if cell.x < 0:
			continue
		return Vector2(cell.x * ts + ts / 2.0, cell.y * ts + ts / 2.0)
	return Vector2(-1, -1)


func _sector_name(sector_id: String) -> String:
	if sector_id == "":
		return Loc.t("ui.portal.unknown")
	var wm := Game._world_map()
	var info: Dictionary = wm.sector(sector_id)
	if info.is_empty():
		return sector_id
	var key := str(info.get("name_key", ""))
	if key == "":
		return sector_id
	var text := Loc.t(key)
	return sector_id if text == key else text


func _show_portal_confirm(portal: Dictionary) -> void:
	if _portal_confirm != null and is_instance_valid(_portal_confirm):
		return
	_portal_pause_before = get_tree().paused
	get_tree().paused = true
	var script: GDScript = load("res://scripts/portal_confirm.gd")
	_portal_confirm = script.new()
	_portal_confirm.setup(_sector_name(Game.map_sector), _sector_name(str(portal.get("to", ""))))
	_portal_confirm.answered.connect(_on_portal_answer.bind(portal))
	add_child(_portal_confirm)


func _on_portal_answer(travel: bool, portal: Dictionary) -> void:
	_portal_confirm = null
	get_tree().paused = _portal_pause_before
	if not travel:
		return
	_portal_prompt_cell = Vector2i(-1, -1)
	_on_portal_enter(str(portal.get("to", "")))

func _on_portal_enter(target_sector: String = "") -> void:
	if target_sector != "":
		# Автосейв ДО смены сектора: иначе после телепортации точка «до портала» потеряна.
		autosave_now()
		travel_to_sector(target_sector)
		return
	# Старая карта без адреса: цепочка start -> mid -> hard.
	var next_zone := str(PORTAL_CHAIN.get(Game.map_zone, ""))
	if next_zone == "":
		print("Портал из зоны '%s' ведёт в никуда — конец маршрута" % Game.map_zone)
		return
	autosave_now()
	travel_to_zone(next_zone)


## Куда ведёт портал: start -> mid -> hard. В hard/faction портала нет,
## это конец маршрута (так и задумано игроком).
const PORTAL_CHAIN := {"start": "mid", "mid": "hard"}

var _travelling := false
var _world_feed_panel = null
## Портал: после прибытия не срабатывает, пока герой не сойдёт с клетки.
var _portal_armed := true
## Клетка, где уже спросили: стоя на ней, повторно не спрашиваем.
var _portal_prompt_cell := Vector2i(-1, -1)
var _portal_confirm = null
var _portal_pause_before := false

# --- Экран загрузки перехода (23.10) -----------------------------------------
var _loading_layer: CanvasLayer = null
var _loading_view: Control = null
var _loading_job = null
var _loading_thread: Thread = null
var _loading_start_ms := 0


func _show_loading(title: String) -> void:
	if _loading_layer != null and is_instance_valid(_loading_layer):
		return
	_loading_layer = CanvasLayer.new()
	_loading_layer.name = "LoadOverlay"
	_loading_layer.layer = 60
	add_child(_loading_layer)
	var view_script: GDScript = load("res://scripts/loading_view.gd")
	_loading_view = view_script.new()
	_loading_view.setup(title)
	_loading_view.back_requested.connect(_hide_loading)
	_loading_layer.add_child(_loading_view)
	_loading_start_ms = Time.get_ticks_msec()


func _hide_loading() -> void:
	if _loading_layer != null and is_instance_valid(_loading_layer):
		_loading_layer.queue_free()
	_loading_layer = null
	_loading_view = null
	_loading_job = null
	_loading_thread = null


func _tick_loading() -> void:
	if _loading_job == null or _loading_view == null or not is_instance_valid(_loading_view):
		return
	var snap: Dictionary = _loading_job.snapshot()
	_loading_view.set_progress(int(snap.get("percent", 0)),
		Loc.t("ui.loading.phase.%d" % clampi(int(snap.get("phase", 0)), 0, 12)))


func _thread_generate_sector(seed_value: int, tier: String, sector: String, size: int,
		ns: Array, relief: String, race: String, job) -> String:
	return MapGenerator.ensure_map(seed_value, tier, MapGenerator.MAPS_DIR, race,
		sector, size, ns, relief, job)


## Переход по тиру — совместимая обёртка (тесты, старые вызовы).
func travel_to_zone(zone: String) -> void:
	var wm := Game._world_map()
	if wm.has(zone):
		travel_to_sector(zone)
		return
	var sector := str(wm.sector_for_tier(zone))
	if sector == "":
		push_error("Переход: нет сектора для тира '%s'" % zone)
		return
	travel_to_sector(sector)


## Переход в соседний сектор по адресу портала (мир 4x3).
func travel_to_sector(sector_id: String) -> void:
	if _travelling or sector_id == "":
		return
	if not is_instance_valid(player):
		return
	var wm := Game._world_map()
	if not wm.has(sector_id):
		push_error("Переход: неизвестный сектор '%s'" % sector_id)
		return
	_travelling = true
	_ensure_world_state()
	var was_paused := get_tree().paused
	get_tree().paused = true
	var info: Dictionary = wm.sector(sector_id)
	var tier := str(info.get("tier", "hard"))
	var seed_value := Game.sector_seed(sector_id)
	var from_sector := Game.map_sector
	_save_sector_fog(from_sector)

	# Генерация — в фоне, с полосой прогресса. Карта 192x192 после фикса BFS
	# занимает ~1.5 с, но и это не должно выглядеть зависанием.
	_show_loading(Loc.t("ui.loading.travel"))
	GameConfig.load_all()
	UnitDB.ensure_loaded()
	StructureDB.ensure_loaded()
	var job = load("res://scripts/world/map_load_job.gd").new()
	_loading_job = job
	var race := MapGenerator.city_race_for_hero(Game.hero_race)
	var ns: Array = wm.neighbors(sector_id)
	var size := int(info.get("size", 192))
	var relief := str(info.get("relief", ""))
	var new_path := ""
	# Посещённый сектор берём из папки слота: карта уже с построенным миром и
	# не должна перегенерироваться по сиду.
	if loaded_slot != "":
		new_path = SaveSystem.restore_zone_map(loaded_slot, sector_id)
		if new_path != "":
			_loading_view.set_progress(100, 12)
	if new_path == "":
		_loading_thread = Thread.new()
		var err := _loading_thread.start(_thread_generate_sector.bind(seed_value, tier,
			sector_id, size, ns, relief, race, job))
		if err != OK:
			_loading_view.set_error(Loc.t("ui.loading.error_start"))
			_travelling = false
			get_tree().paused = was_paused
			return
		while _loading_thread.is_alive():
			_tick_loading()
			await get_tree().process_frame
		new_path = str(_loading_thread.wait_to_finish())
	if new_path == "" or not FileAccess.file_exists(new_path):
		_loading_view.set_error(Loc.t("ui.loading.error_travel"))
		_travelling = false
		get_tree().paused = was_paused
		return

	await _swap_map(new_path, tier, false, sector_id, from_sector, seed_value)
	Game.map_sector = sector_id
	Game.map_zone = tier
	Game.map_seed = seed_value
	var wf = load("res://scripts/world/world_feed.gd")
	wf.post("you", Loc.f("ui.feed.travel", [_sector_name(from_sector), _sector_name(sector_id)]))
	var bus := _world_bus()
	if bus != null and bus.state != null and not bus.state.sectors.is_empty():
		bus.state.discover_sector(sector_id)
	_apply_sector_fog(sector_id)
	# Папка слота держит карты ВСЕХ посещённых секторов (22.10): после перезапуска
	# игра идёт из слота, и возврат не должен рождать карту с нулевым миром.
	if loaded_slot != "":
		var store_err := SaveSystem.store_zone_map(loaded_slot, new_path)
		if store_err != "":
			push_warning("SaveSystem: карта сектора '%s' не легла в слот %s: %s" % [sector_id, loaded_slot, store_err])

	# Прогрев: шейдеры и первые кадры карты компилируются/рисуются под оверлеем.
	while Time.get_ticks_msec() - _loading_start_ms < 600:
		await get_tree().process_frame
	for _i in 3:
		await get_tree().process_frame
	_hide_loading()
	get_tree().paused = was_paused
	_travelling = false
	print("Переход: сектор '%s' (%s), карта %s" % [sector_id, tier, new_path])


## Подготовить текущий мир 4x3, если его ещё нет (новая игра / dev-карта).
func _ensure_world_state() -> void:
	var bus := _world_bus()
	if bus == null or bus.state == null:
		return
	if bus.state.sectors.is_empty() or int(bus.state.world_seed) != int(Game.world_seed):
		var start_owner := MapGenerator.city_race_for_hero(Game.hero_race)
		bus.state.init_world(Game.world_seed, start_owner)
	# Четыре фракции обязательны (28.10): у нежити и друидов должен быть
	# великий маг. Старые сейвы приходят с двумя — добиваем здесь, мир не трогаем.
	if bus.state.has_method("ensure_race_factions"):
		bus.state.ensure_race_factions()
	# Календарь начинается заново: вход в игру и переход в другой сектор не
	# должны «докручивать» день, накопленный прошлой сценой/сессией.
	if bus.has_method("reset_day_timer"):
		bus.call("reset_day_timer")


## Build the SIM from the live map's cities (04.11). The first real map replaces
## the hardcoded sandbox; a loaded save keeps its economy because
## WorldBus.sync_sector_map is a no-op once the sector already has cities.
func _sync_sim_from_map() -> void:
	var bus := _world_bus()
	if bus == null or bus.state == null or alm_map == null:
		return
	if not alm_map.has_method("get_cities"):
		return
	var cities: Array = alm_map.call("get_cities")
	if cities.is_empty():
		return
	var sector := Game.map_sector
	if sector == "":
		sector = "zone:" + Game.map_zone
	var region_name := Game.map_zone
	if Game.map_sector != "":
		region_name = _sector_name(Game.map_sector)
	bus.call("sync_sector_map", sector, cities, region_name)


## Карта сектора для перехода: сначала из слота (посещённый сектор), потом из
## Туман текущего сектора уезжает в состояние мира перед сменой карты.
func _save_sector_fog(sector_id: String) -> void:
	var bus := _world_bus()
	if sector_id == "" or Game.fog == null or bus == null or bus.state == null:
		return
	if not bus.state.sectors.has(sector_id):
		return
	var rle := Game.fog.mask_rle()
	var s: Dictionary = bus.state.sectors[sector_id]
	s["fog"] = rle
	bus.state.sectors[sector_id] = s


## Туман нового сектора: пересобрать маску под размер карты и применить.
func _apply_sector_fog(sector_id: String) -> void:
	var bus := _world_bus()
	if sector_id == "" or Game.fog == null or bus == null or bus.state == null:
		return
	var s: Dictionary = bus.state.sector_state(sector_id)
	Game.fog._setup()
	var rle := str(s.get("fog", ""))
	if rle != "":
		Game.fog.apply_rle(rle)
	else:
		Game.pending_fog_rle = ""


## Карта зоны для перехода. Если слот, из которого идёт игра, держит эту
## зону рядом со старым состоянием мира (22.10: карта — целыми файлами в
## папке сохранения), она возвращается оттуда, а не плодит карту по сиду с
## новым состоянием мира.
func _zone_map_path(zone: String, seed_value: int) -> String:
	if loaded_slot != "":
		var from_slot := SaveSystem.restore_zone_map(loaded_slot, zone)
		if from_slot != "":
			return from_slot
	return MapGenerator.ensure_map(seed_value, zone, MapGenerator.MAPS_DIR)


## Пересоздать узел Map и переселить на него героя и партию.
## from_slot — карта пришла из папки этого слота (загрузка игры): тогда точка
## входа — позиция героя из сейва, а не спавн новой карты.
## map_seed_value — сид НОВОЙ карты (переход между секторами): его надо
## применить ДО спавна стражи форпостов, иначе ключ захвата считается по
## сиду прежней карты.
func _swap_map(new_path: String, zone: String, from_slot: bool = false,
		sector: String = "", arrival_from: String = "",
		map_seed_value: int = 0) -> void:
	_clear_world_units()
	# Зона меняется ДО создания карты: AlmMap._ready и спавн используют
	# Game.map_zone, и он должен уже совпадать с новой картой.
	Game.map_zone = zone
	if sector != "":
		Game.map_sector = sector
	if map_seed_value != 0:
		Game.map_seed = map_seed_value
	Game.pending_map_path = new_path
	if is_instance_valid(alm_map):
		remove_child(alm_map)
		alm_map.queue_free()
	var fresh := Node2D.new()
	fresh.name = "Map"
	fresh.set_script(load("res://scripts/alm_map.gd"))
	fresh.set("tile_size", 32)
	fresh.set("alm_path", new_path)
	add_child(fresh)
	move_child(fresh, 0)
	alm_map = fresh
	# Узел Map новый, а UI переживает подмену: без перепривязки миникарта
	# продолжала рисовать кэш прежней карты.
	if is_instance_valid(ui) and ui.has_method("rebind_map"):
		ui.rebind_map()
	if from_slot and load_position_valid:
		# Позиция из сейва и так лежит в Game — здесь нужен только флаг:
		# если не найти её в кадре загрузки, герой встанет на спавн
		# (прошлое поведение).
		pass
	await get_tree().process_frame
	await get_tree().process_frame
	_portal_armed = true
	_portal_prompt_cell = Vector2i(-1, -1)
	# Загрузка слота: герой встаёт там, где сохранился (если клетка проходима).
	if from_slot and load_position_valid:
		_portal_armed = false
		var saved_pos: Vector2 = load_position
		if alm_map.call("is_walkable_world", saved_pos):
			player.global_position = saved_pos
		else:
			# Клетка сохранилась непроходимой (под зданием/водой): ищем
			# ближайшую открытую вокруг неё, а не отдаём героя спавну карты.
			var ts: int = int(alm_map.get("tile_size"))
			var start := Vector2i(int(saved_pos.x / float(ts)), int(saved_pos.y / float(ts)))
			var spot: Vector2 = _find_open_spot(start, ts)
			if spot.x >= 0.0:
				player.global_position = spot
			else:
				var fallback: Vector2 = alm_map.call("get_spawn_pos")
				if fallback != Vector2.ZERO:
					player.global_position = fallback
		player.reset_physics_interpolation()
		player.stop_movement()
		Game.clear_load_position()
	else:
		var arrival := _arrival_portal_pos(arrival_from)
		if arrival.x >= 0.0:
			player.global_position = arrival
			_portal_armed = false
			_portal_prompt_cell = Vector2i(-1, -1)
		else:
			var sp: Vector2 = alm_map.call("get_spawn_pos")
			if sp != Vector2.ZERO:
				player.global_position = sp
		player.reset_physics_interpolation()
		player.stop_movement()
	for m in Game.party:
		var unit: Node2D = m as Node2D
		if is_instance_valid(unit):
			unit.global_position = player.global_position + Vector2(32, 0)
			unit.reset_physics_interpolation()
	Game.reload_outposts(alm_map)
	await _spawn_map_units()
	if camera != null and is_instance_valid(player):
		camera.position = player.camera_focus()
		camera.make_current()


## Снести всё, что принадлежит прежней карте: врагов, NPC и их мешки с лутом.
## Без этого после перехода на карте остались бы юниты прошлой зоны, а
## Game.enemies/npcs копились бы впустую.
func _clear_world_units() -> void:
	for u in Game.enemies:
		var e: Node = u as Node
		if is_instance_valid(e):
			e.queue_free()
	Game.enemies.clear()
	for n in Game.npcs:
		var node: Node = n as Node
		if is_instance_valid(node):
			node.queue_free()
	Game.npcs.clear()
	# Мешки с лутом лежат отдельными узлами рядом с юнитами.
	for child in get_children():
		# Мешки лута переименованы в LootDrop (03.10), но группа осталась
		# прежней — на неё завязана очистка при переходе между зонами.
		if child.is_in_group("loot_bag") or child.name.begins_with("LootDrop"):
			child.queue_free()
	if is_instance_valid(player):
		player.stop_movement()

## --- Респавн Серых (03.10) --------------------------------------------------
##
## Замер: респавна не было НИКАКОГО. Убил всех в зоне — зона пустая навсегда,
## и «карта скучная» со временем становилась только скучнее. Теперь держим
## лимит: если живых меньше цели, через каждые N секунд появляется один зверь
## вдали от героя.
var _gray_respawn_accum := 0.0

func _alive_gray_count() -> int:
	var n := 0
	for e in Game.enemies:
		var unit: Node = e as Node
		if not is_instance_valid(unit):
			continue
		if UnitDB.has(str(unit.get("anim_set"))) and UnitDB.is_hostile(str(unit.get("anim_set"))):
			n += 1
	return n

func _gray_respawn_tick(delta: float) -> void:
	var period := GameConfig.getf("spawn", "gray_respawn_seconds")
	if period <= 0.0:
		return
	var target := GameConfig.geti("spawn", "gray_target")
	if target <= 0:
		target = maxi(GameConfig.designi(Game.map_zone, "gray_count_min"),
			GameConfig.designi(Game.map_zone, "gray_count_max"))
	if not is_instance_valid(player) or not is_instance_valid(alm_map):
		return
	_gray_respawn_accum += delta
	if _gray_respawn_accum < period:
		return
	_gray_respawn_accum = 0.0
	if _alive_gray_count() >= target:
		return
	var cell := _gray_respawn_cell()
	if cell.x < 0:
		return
	# Пул берётся из ТОЙ ЖЕ полосы тиров, что и при генерации карты. Если
	# респавн брал бы пул напрямую, в стартовой зоне появились бы тиры 4-5.
	var pool: Array = MapGenerator.gray_pool_for_zone(Game.map_zone)
	if pool.is_empty():
		return
	var set_name: String = str(pool[randi() % pool.size()])
	var spot := _find_open_spot(cell, int(alm_map.get("tile_size")))
	if spot.x < 0.0:
		return
	var e2 := Enemy.new()
	e2.name = "Monster_" + set_name.get_file()
	e2.anim_set = set_name
	# Тир усиливает респавненного зверя так же, как при генерации карты.
	var mults: Array = MapGenerator.gray_tier_mults(set_name)
	e2.max_hp = int(round(float(randi_range(GameConfig.geti("grey", "hp_min"),
		GameConfig.geti("grey", "hp_max"))) * float(mults[0])))
	e2.damage = int(round(float(randi_range(GameConfig.geti("grey", "damage_min"),
		GameConfig.geti("grey", "damage_max"))) * float(mults[1])))
	e2.position = spot
	e2.home_position = spot
	add_child(e2)
	Game.enemies.append(e2)

## Случайная проходимая клетка не ближе gray_respawn_min_dist от героя.
func _gray_respawn_cell() -> Vector2i:
	var min_d := maxi(4, GameConfig.geti("spawn", "gray_respawn_min_dist"))
	var mw: int = int(alm_map.get("map_width"))
	var mh: int = int(alm_map.get("map_height"))
	if mw <= 0 or mh <= 0:
		return Vector2i(-1, -1)
	var px := int(player.global_position.x / 32.0)
	var py := int(player.global_position.y / 32.0)
	for _i in range(80):
		var c := Vector2i(randi_range(2, mw - 3), randi_range(2, mh - 3))
		if absi(c.x - px) < min_d or absi(c.y - py) < min_d:
			continue
		if not alm_map.call("is_walkable_world", Vector2(c.x * 32 + 16, c.y * 32 + 16)):
			continue
		return c
	return Vector2i(-1, -1)


func _process_action_mode():
	if action_mode == "none" or action_mode == "stop" or not is_instance_valid(player):
		return
	
	match action_mode:
		"follow":
			# Идти за ближайшим союзником (пока за ближайшим NPC)
			if action_target and is_instance_valid(action_target):
				player.attack_target = action_target
				player.state = "chase"
		"attack":
			# Атаковать ближайшего врага
			if enemies.size() > 0:
				var nearest = null
				var min_dist = 9999.0
				for e in enemies:
					if is_instance_valid(e):
						var d = e.global_position.distance_to(player.global_position)
						if d < min_dist:
							min_dist = d
							nearest = e
				if nearest:
					player.attack_target = nearest
					player.state = "chase"
		"guard":
			# Стоять на месте и атаковать врагов в радиусе
			if player.state == "idle":
				for e in enemies:
					if is_instance_valid(e) and e.global_position.distance_to(player.global_position) < 150:
						player.attack_target = e
						player.state = "chase"
						break

# === Сохранения ===
#
# Меню само ничего не сохраняет: оно только сообщает о нажатии. Всё
# сохранение и загрузка - здесь, потому что только у game.gd есть живой
# игрок, WorldBus с состоянием мира и сцена, которую надо пересобрать.

## The hero has fallen. The world keeps rendering for one second so the fall
## is readable, but the hero is already no target and every command is blocked
## by Game.hero_dead. Then the black title, then the compact load menu.
const DEATH_TO_TITLE := 1.0
const DEATH_TO_MENU := 1.0

func _on_hero_died() -> void:
	if _death_sequence_running:
		return
	_death_sequence_running = true
	Game.hero_dead = true
	await get_tree().create_timer(DEATH_TO_TITLE).timeout
	if not is_instance_valid(player) or not player.is_dead:
		_death_sequence_running = false
		return
	_death_screen = DeathScreen.new()
	add_child(_death_screen)
	await get_tree().create_timer(DEATH_TO_MENU).timeout
	if not is_instance_valid(player) or not player.is_dead:
		return
	# Freeze the world with the REAL flag: the root Main is PROCESS_MODE_ALWAYS,
	# so SceneTree.paused alone never stopped enemies or the hero (the old
	# death only paused the tree and the corpse kept getting hit).
	Game.is_paused = true
	get_tree().paused = true
	if is_instance_valid(_death_screen):
		_death_screen.queue_free()
		_death_screen = null
	_open_game_over()

## Load-only save menu under a black screen. No Save/Delete, no Esc close,
## only «Загрузить» and «В главное меню» (player decision 04.11).
func _open_game_over() -> void:
	if _save_menu != null and is_instance_valid(_save_menu):
		return
	_save_menu = SaveMenu.new()
	_save_menu.setup("load_only", Loc.t("ui.gameover.title"),
		Loc.t("ui.gameover.hint"))
	_save_menu.load_requested.connect(_load_from_slot)
	_save_menu.quit_requested.connect(_quit_to_menu)
	_save_menu.quit_app_requested.connect(_quit_app)
	_save_menu.closed.connect(func() -> void:
		_save_menu = null)
	add_child(_save_menu)

## Reset every death-owned flag before a slot rebuild. Must run BEFORE
## _restart_scene: _set_menu_pause() refuses to unpause a corpse.
func _close_game_over() -> void:
	_death_sequence_running = false
	if is_instance_valid(_death_screen):
		_death_screen.queue_free()
		_death_screen = null
	if _save_menu != null and is_instance_valid(_save_menu):
		var menu := _save_menu
		_save_menu = null
		menu.queue_free()
	Game.hero_dead = false
	Game.is_paused = false
	get_tree().paused = false
	if is_instance_valid(player) and player.has_method("reset_death_state"):
		player.call("reset_death_state")

## Открыть меню сохранений (Esc). Повторный вызов игнорируется.
##
## Пока меню открыто, мир стоит на паузе (жалоба игрока 22.10: «вызвал меню
## сохранения, сделал сохранение — персонаж бегает»). Пауза ставится и
## снимается здесь, а не в SaveMenu: меню можно закрыть Esc, «В главное меню»
## или завершением процесса, и во всех путях снятие должно быть в одном месте.
func open_save_menu() -> void:
	if _save_menu != null and is_instance_valid(_save_menu):
		return
	_set_menu_pause(true)
	_save_menu = SaveMenu.new()
	_save_menu.setup()
	_save_menu.save_requested.connect(_save_to_slot)
	_save_menu.load_requested.connect(_load_from_slot)
	_save_menu.delete_requested.connect(_delete_slot)
	_save_menu.quit_requested.connect(_quit_to_menu)
	_save_menu.quit_app_requested.connect(_quit_app)
	_save_menu.closed.connect(func() -> void:
		_save_menu = null
		_set_menu_pause(false))
	add_child(_save_menu)


## Мир на паузе, пока открыто меню сохранений. Герой мёртв — паузу держит
## экран смерти (_on_hero_died), снимать её обычным путём нельзя.
func _set_menu_pause(on: bool) -> void:
	if Game.hero_dead:
		return
	if is_instance_valid(player) and player.state in ["dead", "decay", "corpse"]:
		return
	Game.is_paused = on
	get_tree().paused = on


## Снять паузу меню на путях, где SaveMenu не испускает closed: «В главное
## меню», выход из игры, перезагрузка сцены при загрузке слота. Дерево на
## паузе не создаёт узлы (instantiate в SAFE-режиме вернёт null), поэтому
## без этого загрузка из меню не пересобрала бы мир.
func _menu_release_pause() -> void:
	_set_menu_pause(false)


## Собрать payload из живого состояния. world приходит снаружи, чтобы
## тест мог подставить свой WorldState без поднятия сцены.
func _build_save_payload() -> Dictionary:
	var world_dict: Dictionary = {}
	# WorldBus - это AUTOLOAD, а не GDExtension-синглтон, поэтому
	# Engine.has_singleton() его не видит: берём узел из дерева сцены.
	if is_inside_tree():
		var bus = get_node_or_null("/root/WorldBus")
		if bus != null and "state" in bus and bus.state != null:
			world_dict = bus.state.to_dict()
	return SaveSystem.build_payload(player, world_dict)


func _save_to_slot(slot: String) -> void:
	# Never write a corpse: the autosave on quit/interior must not destroy the
	# last living save after a game over.
	if Game.hero_dead:
		return
	var err := SaveSystem.save(slot, _build_save_payload())
	if err != "":
		if _save_menu != null and is_instance_valid(_save_menu):
			_save_menu.set_status(tr("Не удалось сохранить: %s") % err)
		else:
			push_error("SaveSystem: " + err)
		return
	if _save_menu != null and is_instance_valid(_save_menu):
		_save_menu.set_status(tr("Сохранено в слот."))
		_save_menu._refresh()


func _load_from_slot(slot: String) -> void:
	var res := SaveSystem.load_slot(slot)
	var err_kind := str(res.get("error", ""))
	if err_kind == "version":
		_set_menu_status(tr("Сохранение сделано более новой версией игры (файл v%d, игра v%d) — загрузка отменена.")
			% [int(res.get("file_version", 0)), SaveSystem.VERSION])
		return
	if err_kind == "corrupt":
		_set_menu_status(tr("Файл сохранения повреждён и резервной копии нет."))
		return
	if res.is_empty():
		_set_menu_status(tr("Слот пуст."))
		return
	# A game-over load must release the corpse/pause/menu BEFORE _restart_scene:
	# _set_menu_pause() refuses to unpause while player.state is dead, and the
	# old menu would stay on top of the rebuilt world.
	_close_game_over()
	# Сначала применяем героя и карту слота, потом пересобираем сцену:
	# AlmMap читает Game.pending_map_path/map_seed/map_zone в _ready.
	SaveSystem.apply_payload(res.get("data", {}), player, slot)
	loaded_slot = slot
	_restart_scene(slot)


## Удаление слота: папка слота становится пустой (решение игрока 22.10),
## а не исчезает: в ней остаются hero/map/process без данных.
func _delete_slot(slot: String) -> void:
	SaveSystem.clear_slot(slot)
	if _save_menu != null and is_instance_valid(_save_menu):
		_save_menu.set_status(tr("Слот удалён."))
		_save_menu._refresh()


func _quit_to_menu() -> void:
	# Autosave first: while the hero is dead _save_to_slot is a no-op, so the
	# last living save survives «В главное меню» from the game-over screen.
	_save_to_slot(SaveSystem.AUTOSAVE_SLOT)
	_close_game_over()
	# Паузу обязательно снять: иначе главное меню откроется в остановленном
	# дереве — без анимации фона и без реакции на ввод. Меню сохранений ставит
	# паузу при открытии (22.10), и «В главное меню» не испускает closed.
	_menu_release_pause()
	is_paused = false
	get_tree().paused = false
	_set_leaving_scene(true)
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")


## Полный выход из процесса (кнопка «Выйти из игры» в Esc-меню).
func _quit_app() -> void:
	# Same order as «В главное меню»: save (skipped while dead), release the
	# death screen, then let the process go.
	_save_to_slot(SaveSystem.AUTOSAVE_SLOT)
	_close_game_over()
	_menu_release_pause()
	_set_leaving_scene(true)
	get_tree().quit()


## Сцена уступает место меню или процесс завершается: автосейв при сносе узла
## больше не нужен. Без этого флага главное меню получало ДВЕ записи
## автосейва подряд — оно само пишет его при загрузке слота (`main_menu.gd:_on_load_slot`)
## и героя оно пересобирает только при старте новой игры: вторая запись
## затирала то, что меню только что записало, старым состоянием сцены.
func _set_leaving_scene(on: bool) -> void:
	_leaving_for_quit = on


## Пересобрать игру из сохранённого состояния: мир кладём в WorldBus,
## карту берём из папки слота и подменяем на живой сцене.
##
## change_scene_to_file здесь НЕ подходит: новая Main._ready сбрасывает
## партию, а главное — осиротевшая корутина старой сцены падала на первом же
## кадре новой (`data.tree is null`) и точка входа из сейва терялась.
## Горячая замена карты (_swap_map) героя и партию сохраняет.
func _restart_scene(slot: String) -> void:
	# Дерево на паузе не создаёт узлы: меню сохранений ставит паузу.
	_menu_release_pause()
	_restore_world_from_slot(slot)
	_clear_party_nodes()
	if not is_instance_valid(player) or not is_instance_valid(alm_map):
		get_tree().change_scene_to_file("res://scenes/main.tscn")
		return
	# Слот мог быть записан ДРУГИМ персонажем (класс/пол/раса/портрет):
	# узел Player живёт в этой сцене и сам не пересобирается, поэтому
	# перечитываем его класс-зависимое состояние до спавна юнитов карты:
	# тогда и город соберётся с расой нового героя.
	if player.has_method("reload_hero_state"):
		player.reload_hero_state()
	var map_path := SaveSystem.world_map_path(slot)
	if map_path == "":
		map_path = _zone_map_path(Game.map_zone, Game.map_seed)
	if map_path == "" or not FileAccess.file_exists(map_path):
		push_error("SaveSystem: карта слота '%s' не найдена" % slot)
		get_tree().change_scene_to_file("res://scenes/main.tscn")
		return
	await _swap_map(map_path, Game.map_zone, true, Game.map_sector)
	_apply_sector_fog(Game.map_sector)
	_restore_pending_party()
	# HUD после подмены героя: книга магии (у воина/мага разные панели),
	# золото и видимость нижней панели.
	_refresh_ui_after_hero_swap()


## Обновить HUD после загрузки слота другого персонажа. Панели (инвентарь,
## магазин и т.п.) создаются заново при каждом открытии и читают Game.*,
## но уже открытые в момент загрузки показывали бы героя другого класса —
## их закрываем (меню сохранений и так ставит игру на паузу).
func _refresh_ui_after_hero_swap() -> void:
	if is_instance_valid(player):
		Game.hero = player
	# ui — @onready-типизированная ссылка на узел UI.
	if not is_instance_valid(ui):
		return
	ui.close_all_panels()
	ui.rebind_map()
	ui.refresh_spell_book()
	ui._update_gold(int(player.gold) if is_instance_valid(player) else 0)
	ui._update_bottom_panel_visibility()
	ui.refresh_inventory()


## Мир (SIM-состояние) из слота → WorldBus. Симулятор держит ссылку на
## СТАРЫЙ WorldState, иначе после загрузки он продолжил бы тикать по
## прежнему миру, а не по загруженному.
func _restore_world_from_slot(slot: String) -> void:
	var res := SaveSystem.load_slot(slot)
	var data: Dictionary = res.get("data", {})
	var world_text := JsonSafe.dump(data.get("world", {}))
	var ws_script: GDScript = load("res://scripts/world/world_state.gd")
	var restored = ws_script.from_json_text(world_text)
	var bus = get_node_or_null("/root/WorldBus")
	if bus == null or not ("state" in bus) or restored == null:
		return
	bus.state = restored
	if "sim" in bus and bus.sim != null and "state" in bus.sim:
		bus.sim.state = restored
	# Старый сейв мог не знать про фракции нежити/друидов (28.10).
	if bus.state.has_method("ensure_race_factions"):
		bus.state.ensure_race_factions()
	if bus.has_method("reset_day_timer"):
		bus.call("reset_day_timer")


func _set_menu_status(text: String) -> void:
	if _save_menu != null and is_instance_valid(_save_menu):
		_save_menu.set_status(text)


## Разовый автосейв (портал, выход из интерьера). Тот же слот, что и таймер.
func autosave_now() -> void:
	if Game.hero_dead:
		return
	if not is_instance_valid(player):
		return
	if _save_menu != null and is_instance_valid(_save_menu):
		return
	var err := SaveSystem.save(SaveSystem.AUTOSAVE_SLOT, _build_save_payload())
	if err != "":
		push_error("SaveSystem autosave: " + err)


## Автосейв по таймеру. Пропускаем, если открыто меню сохранений (иначе
## игрок жмёт «Сохранить» и тут же получает автосейв поверх).
func _autosave_tick(delta: float) -> void:
	if Game.hero_dead:
		return
	_autosave_accum += delta
	if _autosave_accum < autosave_interval():
		return
	_autosave_accum = 0.0
	if _save_menu != null and is_instance_valid(_save_menu):
		return
	if not is_instance_valid(player):
		return
	SaveSystem.save(SaveSystem.AUTOSAVE_SLOT, _build_save_payload())


## Сохранить при закрытии окна и при выходе из игры. Вызывается из
## project.godot (autoload-free), поэтому подписка выполняется здесь.
## NOTIFICATION_PREDELETE намеренно НЕ используется: этот сигнал приходит
## на КАЖДУЮ загрузку сцены и перезапуск (_restart_scene), где состояние уже
## принадлежит новой сцене, а старый игрок уже уступил его сохранению.
## Пропускается, если сцена сама сохранилась и уступает место меню
## (см. _set_leaving_scene): иначе автосейв записывался бы дважды.
func _notification(what: int) -> void:
	if what != NOTIFICATION_WM_CLOSE_REQUEST:
		return
	if _leaving_for_quit or not is_inside_tree():
		return
	if Game.hero_dead:
		return
	if is_instance_valid(player):
		SaveSystem.save(SaveSystem.AUTOSAVE_SLOT, _build_save_payload())
