extends SceneTree
## Headless-проверка системы магии игрока.
##
## Проверяет то, что нельзя увидеть без запуска игры:
##  1. консистентность БД (звук/target/cast_time/папки снарядов, свитки -> заклинания);
##  2. тест-режим выдаёт все заклинания базы;
##  3. каждый вид заклинания (attack/area/heal/buff/debuff/wall/self/raise)
##     реально срабатывает и наносит урон/эффект;
##  4. статусы накладываются, меняют статы и ИСТЕКАЮТ по tick;
##  5. формула силы магии растёт от mind и навыка сферы.
##
## Запуск:
##   godot --headless --path . --script res://tests/magic_smoke.gd

const SPELL := "seed/sw_seed"
const DB_PATH := "res://assets/spells/spells_db.json"

var _fails: Array = []


func _initialize() -> void:
	# Отладочный набор магии нужен этому тесту явно: с 04.11 `[debug]
	# all_magic = 0`, и маг в игре стартует с одной книгой школы.
	Game.debug_magic = true
	Game.hero_stats = {"body": 12, "agility": 11, "mind": 13, "spirit": 12,
		"blade": 10, "bludgeon": 10, "pike": 10, "shooting": 10,
		"fire": 20, "water": 20, "air": 20, "earth": 20, "astral": 20,
		"weapon": "staff", "shield": false, "armor": "light"}
	Game.hero_class = "mage"
	Game.hero_name = "Маг"
	call_deferred("_run")


func _check(ok: bool, what: String) -> void:
	if not ok:
		_fails.append(what)
	print("MAGIC: %s %s" % ["ok  " if ok else "FAIL", what])


func _run() -> void:
	# --- 1. База ---------------------------------------------------------
	var db_errors := SpellDB.validate()
	_check(db_errors.is_empty(), "база заклинаний консистентна (%s)" % str(db_errors))
	_test_no_duplicate_keys()
	_check(SpellDB.all_spell_names().size() == 31,
		"в базе 31 заклинание (найдено %d)" % SpellDB.all_spell_names().size())

	# 04.11: стартовое заклинание школы обязано быть БОЕВЫМ. Раньше первым
	# ключом была мана, и маг воздуха/земли получал защитный бафф («мне дали
	# щит — как мне кого-то убить?»).
	for sphere in ["Fire", "Water", "Air", "Earth", "Astral"]:
		var starter := SpellDB.simplest_spell_of_sphere(sphere)
		var kind := SpellDB.kind_of(starter)
		var dmg := SpellDB.damage(starter)
		_check(kind in ["attack", "area"] and dmg > 0,
			"стартовая магия %s боевая: %s (kind=%s, урон=%d)"
				% [sphere, starter, kind, dmg])

	# Каждый свиток мага должен резолвиться в реальное заклинание
	var bad_scrolls: Array = []
	for key in ItemDB.all():
		var k := str(key)
		if not k.begins_with("Scroll "):
			continue
		var sp := SpellDB.spell_from_scroll(k)
		if sp == "" or SpellDB.get_spell(sp).is_empty():
			bad_scrolls.append(k)
	_check(bad_scrolls.is_empty(), "все свитки резолвятся в заклинания (%s)" % str(bad_scrolls))

	# Wall_of_Fire обязан быть стеной (был attack -> бил одиночным снарядом)
	_check(SpellDB.kind_of("Wall_of_Fire") == "wall", "Wall_of_Fire имеет kind=wall")
	_check(SpellDB.effects_of("Curse").size() == 1, "Curse описан эффектом, а не щитом")
	# Стены в оригинале разные: огонь жжёт, земля — преграда
	_check(SpellDB.wall_mode_of("Wall_of_Fire") == "damage", "стена огня — режим damage")
	_check(SpellDB.wall_mode_of("Wall_of_Earth") == "block", "стена земли — режим block")
	_check(not SpellDB.effects_of("Stone_Curse").is_empty()
		and SpellDB.effect_of_type("Stone_Curse", "root").size() > 0,
		"Stone_Curse содержит корень (обездвиживание)")
	# Сопротивление в процентах
	_check(int(SpellDB.effect_of_type("Protection_from_Fire", "resist").get("amount", 0)) >= 20,
		"Protection_from_* даёт сопротивление в процентах (>=20)")

	# --- 2. Загрузка сцены ---------------------------------------------
	var err := change_scene_to_file("res://scenes/main.tscn")
	if err != OK:
		_check(false, "загрузка main.tscn: %d" % err)
		_finish()
		return
	await process_frame
	await create_timer(0.6).timeout

	var hero: Node2D = get_first_node_in_group("player")
	_check(hero != null, "герой загружен")
	if hero == null:
		_finish()
		return

	# --- 3. Тест-режим: все заклинания -----------------------------------
	var known: int = (hero.get("known_spells") as Dictionary).size()
	_check(Game.debug_magic and known == 31,
		"тест-режим: выучено %d/31 заклинаний" % known)

	# --- 4. Формула силы магии (оригинал: навык + разум - 30) --------------
	var p0 := Game.spell_power(hero, "Fire")
	hero.set("fire_skill", 40)
	var p1 := Game.spell_power(hero, "Fire")
	_check(p1 > p0, "навык сферы повышает силу магии (%.1f -> %.1f)" % [p0, p1])
	hero.set("fire_skill", 20)
	var p2 := Game.spell_power(hero, "Fire")
	hero.set("mind", 25)
	var p3 := Game.spell_power(hero, "Fire")
	_check(p3 > p2, "разум повышает силу магии (%.1f -> %.1f)" % [p2, p3])
	# SP не уходит в минус (у новичка навык 5 + разум 9 - 30 = -16)
	hero.set("fire_skill", 5)
	hero.set("mind", 9)
	_check(Game.spell_power(hero, "Fire") >= 0.0, "SP клампится в ноль, не уходит в минус")
	# Форма формулы совпадает с оригиналом: навык + разум - SP_OFFSET.
	hero.set("fire_skill", 45)
	hero.set("mind", 20)
	# Ожидание считаем ОТ КОНСТАНТЫ. Раньше здесь стояло 35.0, то есть был
	# зашит сдвиг 30, и любая его смена валила тест вместо того, чтобы
	# проверять формулу.
	var want_sp: float = 45.0 + 20.0 - GameConfig.getf("magic", "sp_offset")
	_check(absf(Game.spell_power(hero, "Fire") - want_sp) < 0.01,
		("SP = навык+разум-SP_OFFSET (получено %.1f, ждём %.1f)"
			% [Game.spell_power(hero, "Fire"), want_sp]))
	# Регрессия из ручного аудита: маг НА СТАРТЕ обязан иметь силу больше нуля.
	# При SP_OFFSET = 30 было 5 + 13 - 30 = -12 -> кламп в ноль, то есть на
	# всю раннюю игру заклинания не росли с уровнем.
	hero.set("fire_skill", 5)
	hero.set("mind", 13)
	var start_sp := Game.spell_power(hero, "Fire")
	_check(start_sp > 0.0,
		("маг на старте (навык 5, разум 13) имеет SP = %.1f > 0 — сила растёт "
			% start_sp) + "с уровнем, а не забита в ноль")
	# Прокачка навыка сферы обязана поднимать SP: это тот рычаг, которого
	# раньше не было.
	hero.set("fire_skill", 15)
	var trained_sp := Game.spell_power(hero, "Fire")
	_check(trained_sp > start_sp,
		("прокачка навыка сферы 5 -> 15 поднимает SP (%.1f -> %.1f)"
			% [start_sp, trained_sp]))
	hero.set("fire_skill", 25)
	hero.set("mind", 13)
	var base := int(SpellDB.get_spell("Fire_Ball").get("damage", 0))
	var scaled := Game.spell_damage(hero, "Fire_Ball", "Fire", base)
	_check(scaled > base, "урон заклинания масштабируется (база %d -> %d)" % [base, scaled])
	_check(Game.spell_damage(hero, "Heal", "Astral", 22) > 22,
		"лечение масштабируется и сильнее базы (power_coef)")

	# --- 5. Урон по врагу -------------------------------------------------
	var foe := _spawn_foe(hero.global_position + Vector2(120, 0))
	_check(foe != null, "враг для проверки урона создан")
	if foe == null:
		_finish()
		return
	await process_frame

	var hp_before: int = foe.current_hp
	Game.deal_damage(foe, 40, "magic", "Fire", hero)
	await process_frame
	_check(foe.current_hp < hp_before, "магический урон снимает HP (%d -> %d)" % [hp_before, foe.current_hp])

	# Сопротивление — ПРОЦЕНТ от урона (orc: fire 25 %)
	var prot: int = int(foe.call("get_protection_fire"))
	_check(prot > 0, "сопротивление приходит из данных набора (%d %%)" % prot)
	_check(prot <= 95, "сопротивление в допустимых процентах (%d)" % prot)
	var plain := 100
	var reduced := int(round(float(plain) * (1.0 - float(prot) / 100.0)))
	var hp_base := int(foe.current_hp)
	Game.deal_damage(foe, plain, "magic", "Fire", hero)
	await process_frame
	var dealt := hp_base - int(foe.current_hp)
	_check(dealt == reduced, "сопротивление режет урон процентно (ожидали %d, получили %d)"
		% [reduced, dealt])
	# Персистентный бафф режет урон ещё сильнее
	StatusEffects.apply_spell(foe, SpellDB.get_spell("Protection_from_Fire"), hero)
	_check(StatusEffects.resist_bonus(foe, "Fire") >= 20,
		"Protection_from_Fire даёт +20 %% резиста (%d)" % StatusEffects.resist_bonus(foe, "Fire"))
	StatusEffects.clear(foe)

	# --- 6. Статусы: наложение, влияние, истечение -----------------------
	var def0: int = foe.call("get_defense")
	var curse := SpellDB.get_spell("Curse")
	StatusEffects.apply_spell(foe, curse, hero)
	_check(StatusEffects.active_types(foe).has("curse"), "Curse наложен")
	var def1: int = foe.call("get_defense")
	_check(def1 < def0, "Curse снижает защиту (%d -> %d)" % [def0, def1])

	# Повторное наложение не должно складывать бесконечно
	StatusEffects.apply_spell(foe, curse, hero)
	_check(StatusEffects.time_left(foe, "curse") > 0.0, "повторное наложение обновляет таймер")
	_check(float(StatusEffects.active_types(foe).count("curse")) == 1.0,
		"один слот на тип эффекта (без бесконечного стака)")

	# Истечение
	StatusEffects.tick(31.0)
	_check(not StatusEffects.active_types(foe).has("curse"), "Curse истёк по tick")
	_check(foe.call("get_defense") == def0, "защита вернулась после истечения")

	# Haste/Slow меняют скорость
	var slow := SpellDB.get_spell("Slow")
	StatusEffects.apply_spell(foe, slow, hero)
	_check(StatusEffects.speed_mult(foe) < 1.0, "Slow замедляет (x%.2f)" % StatusEffects.speed_mult(foe))
	StatusEffects.clear(foe)
	var haste := SpellDB.get_spell("Haste")
	StatusEffects.apply_spell(foe, haste, hero)
	_check(StatusEffects.speed_mult(foe) > 1.0, "Haste ускоряет (x%.2f)" % StatusEffects.speed_mult(foe))
	StatusEffects.clear(foe)

	# Stone_Curse = корень: цель не двигается
	StatusEffects.apply_spell(foe, SpellDB.get_spell("Stone_Curse"), hero)
	_check(StatusEffects.is_rooted(foe), "Stone_Curse оглушает (корень)")
	_check(StatusEffects.speed_mult(foe) == 0.0, "корень полностью останавливает цель")
	_check(foe.call("effective_speed") == 0.0, "корень обнуляет скорость врага")
	StatusEffects.tick(31.0)
	_check(not StatusEffects.is_rooted(foe), "корень истёк по tick")

	# --- Обратная связь при поглощения -----------------------------------------
	# Из аудита: deal_damage показывал "щит" на ЛЮБОЙ поглощении, а щит считается внутри take_damage
	# и вовсе не попадает в эту ветку. Кроме того, поглощение щитом стрельный урон показывался полным числом.
	_check(DamageNumber.text_for(0, "absorb") == Loc.t("ui.msg.shield"),
		"поглощение щитом подписывает «щит»")
	_check(DamageNumber.text_for(0, "resist") == Loc.t("ui.msg.resist"),
		"поглощение защитой стихии подписывает «стойкость», а не «щит»")
	_check(DamageNumber.text_for(0, "armor") == Loc.t("ui.msg.armor"),
		"поглощение броней подписывает «броня»")
	# Щит съел урон внутри take_damage — теперь deal_damage вовсу показывал
	# полное число. Проверяем: урон снизу не дошёл, а deal_damage всё равно рисовал полное число.
	StatusEffects.clear(foe)
	foe.current_hp = 100
	var shield_hp0 := int(foe.get("current_hp"))
	Game.apply_shield(foe, 500, 30.0)
	var shielded := Game.deal_damage(foe, 40, "physical", "", hero)
	_check(shielded == 0, "урон, съеденный щитом, не пронёс (возвращено %d)" % shielded)
	_check(int(foe.get("current_hp")) == shield_hp0,
		"HP не сдвинулось, когда урон съел щит (%d)" % int(foe.get("current_hp")))
	# А без щита тот же урон должен пройти, иначе проверка выше ничего не значит.
	Game.tick_shields(31.0)
	Game.deal_damage(foe, 40, "physical", "", hero)
	_check(int(foe.get("current_hp")) < shield_hp0,
		"без щита тот же урон проходит (HP %d)" % int(foe.get("current_hp")))

	# --- Яд растёт от силы магии ---------------------------------------------
	# Регрессия из ручного аудита: _tick_dot слал РОВНО dps из базы (Blizzard 3,
	# Poison_Cloud 4) независимо от разума и навыка, то есть два самых долгих
	# заклинания были единственными, чей урон не зависел от развития мага.
	# ВАЖНО: яд у Poison_Cloud водяной (sphere = Water), поэтому растить надо
	# water_skill. Мой первый вариант менял fire_skill и мерил одно и то же
	# значение дважды — тест был зелёным только потому, что сравнивал 5 с 5.
	var dot_spell := SpellDB.get_spell("Poison_Cloud")
	var base_dps := 4.0
	hero.set("water_skill", 5)
	hero.set("mind", 13)
	StatusEffects.clear(foe)
	StatusEffects.apply_spell(foe, dot_spell, hero)
	var weak_dps := _measure_dot(foe)
	var weak_sp := Game.spell_power(hero, "Water")
	_check(absf(weak_dps - base_dps * (1.0 + weak_sp / 100.0)) < 0.6,
		("на старте мага (навык воды 5, разум 13, SP=%.0f) яд = %.1f — "
			% [weak_sp, weak_dps]) + "почти базовые %.0f" % base_dps)
	StatusEffects.clear(foe)
	hero.set("water_skill", 40)
	StatusEffects.apply_spell(foe, dot_spell, hero)
	var strong_dps := _measure_dot(foe)
	var strong_sp := Game.spell_power(hero, "Water")
	_check(strong_dps > weak_dps,
		"сильный маг (навык воды 40, SP=%.0f) яд сильнее стартового: %.1f против %.1f"
			% [strong_sp, strong_dps, weak_dps])
	# Тот же множитель, что у spell_damage: 1 + SP/100.
	var expect := base_dps * (1.0 + strong_sp / 100.0)
	_check(absf(strong_dps - expect) < 0.6,
		"яд масштабируется тем же множителем, что урон заклинания: %.1f против ожидаемых %.1f" % [strong_dps, expect])
	StatusEffects.clear(foe)
	hero.set("water_skill", 20)
	hero.set("mind", 13)

	# Невидимость
	var inv := SpellDB.get_spell("Invisibility")
	StatusEffects.apply_spell(hero, inv, hero)
	_check(StatusEffects.is_invisible(hero), "Invisibility наложена")
	StatusEffects.break_invisibility(hero)
	_check(not StatusEffects.is_invisible(hero), "атака срывает невидимость")

	# Щит (идёт в meta-щит Game)
	StatusEffects.apply_spell(hero, SpellDB.get_spell("Shield"), hero)
	# Щит мага = временная броня (Аллоды), не meta-поглощение HP.
	var sh_def0 := StatusEffects.shield_armor_defense(hero)
	var sh_abs0 := StatusEffects.shield_armor_absorption(hero)
	_check(sh_def0 > 0, "Shield даёт прибавку к Защите (%d)" % sh_def0)
	_check(sh_abs0 >= 0, "Shield считает поглощение (%d)" % sh_abs0)
	_check(StatusEffects.shield_armor_time(hero) > 0.0, "Shield живёт по времени")

	# --- 7. Все виды заклинаний срабатывают ------------------------------
	var kinds := {
		"Fire_Ball": "area", "Ice_Missile": "attack", "Heal": "heal",
		"Haste": "buff", "Curse": "debuff", "Wall_of_Fire": "wall",
		"Light": "self",
	}
	for spell_name in kinds:
		var expected: String = kinds[spell_name]
		_check(SpellDB.kind_of(spell_name) == expected,
			"%s -> kind=%s" % [spell_name, expected])

	# Animate_Dead поднимает труп
	foe.current_hp = 0
	foe.set("state", "corpse")
	var party_before: int = Game.party.size()
	hero.call("_raise_dead", foe.global_position, "Animate_Dead")
	await process_frame
	_check(Game.party.size() == party_before + 1, "Animate_Dead поднимает союзника из трупа")

	# Вампиризм (Drain_Life): урон лечит кастера
	StatusEffects.clear(hero)
	var foe2 := _spawn_foe(hero.global_position + Vector2(100, 0))
	await process_frame
	hero.current_hp = maxi(1, hero.current_hp - 40)
	var hp_pre := int(hero.current_hp)
	hero.call("_cast_spell_effect", "Drain_Life", SpellDB.get_spell("Drain_Life"),
		foe2.global_position, foe2)
	_check(StatusEffects.vampirism_ratio(hero) > 0.0, "Drain_Life даёт кастеру вампиризм")
	Game.deal_damage(foe2, 40, "magic", "Astral", hero)
	await process_frame
	_check(int(hero.current_hp) > hp_pre, "вампиризм лечит кастера за нанесённый урон")
	# Вампиризм НЕ должен попасть на врага или союзника в радиусе
	_check(StatusEffects.vampirism_ratio(foe2) == 0.0, "вампиризм не достался цели")

	# Стена огня: создаётся и наносит урон по тику (режим damage)
	StatusEffects.clear(hero)
	var foe3 := _spawn_foe(hero.global_position + Vector2(80, 0))
	# Враг не должен УБЕЖАТЬ из стены: он агрится на героя и за 0.8 с выходит
	# из полосы (стена теперь перпендикулярна касту и узкая — 2 клетки).
	foe3.set_physics_process(false)
	await process_frame
	hero.call("_create_wall", foe3.global_position, "Wall_of_Fire", "Fire")
	await process_frame
	var wall := _find_wall()
	_check(wall != null, "Wall_of_Fire создаёт зону стены")
	if wall != null:
		_check(wall.deals_damage(), "стена огня жжёт (deals_damage=true)")
		_check(not wall.blocks_path(), "стена огня проходима (blocks_path=false)")
		var w_hp := int(foe3.current_hp)
		await create_timer(0.8).timeout
		_check(int(foe3.current_hp) < w_hp, "стена наносит урон по тику (%d -> %d)"
			% [w_hp, int(foe3.current_hp)])
	if wall != null:
		wall.queue_free()
		await process_frame

	# Стена земли: только преграда, урона нет
	var foe4 := _spawn_foe(hero.global_position + Vector2(200, 0))
	await process_frame
	hero.call("_create_wall", foe4.global_position, "Wall_of_Earth", "Earth")
	await process_frame
	var wall2 := _find_wall()
	_check(wall2 != null, "Wall_of_Earth создаёт стену")
	if wall2 != null:
		_check(wall2.blocks_path(), "стена земли блокирует проход")
		_check(not wall2.deals_damage(), "стена земли не наносит урон")
		var e_hp := int(foe4.current_hp)
		await create_timer(0.8).timeout
		_check(int(foe4.current_hp) == e_hp, "стена земли не ранит (HP %d)" % int(foe4.current_hp))
		wall2.queue_free()
		await process_frame

	Game.hero.set("current_mana", 999)
	_finish()


func _find_wall() -> SpellWall:
	for child in get_root().get_children():
		for c in (child as Node).get_children() if child is Node else []:
			if c is SpellWall:
				return c
	var stack := get_root().find_children("*", "SpellWall", true, false)
	return stack[0] as SpellWall if not stack.is_empty() else null


func _spawn_foe(pos: Vector2) -> Enemy:
	var e := Enemy.new()
	e.name = "MagicTestFoe"
	e.anim_set = SPELL
	e.max_hp = 400
	e.damage = 5
	e.position = pos
	root.add_child(e)
	Game.enemies.append(e)
	return e


## Дубликаты ключей в spells_db.json. JSON их допускает, и БД читает
## ПОСЛЕДНЕЕ вхождение, поэтому старый "range": 0 молча проигрывал новому
## 320, и баг жил незамеченным, пока не попал в ручной аудит. SpellDB.validate()
## такие вещи не видит — он работает с уже разобранным словарём.
## Снять фактический урон одного тика яда (один тик = секунда урона).
##
## Снимаем урон без влияния на врага: специя каждый тик.
func _measure_dot(foe: Node2D) -> float:
	var hp0 := int(foe.get("current_hp"))
	StatusEffects.tick(1.05)
	return float(hp0 - int(foe.get("current_hp")))


func _test_no_duplicate_keys() -> void:
	var text := FileAccess.get_file_as_string(DB_PATH)
	_check(not text.is_empty(), "spells_db.json читается текстом (для поиска дублей)")
	if text.is_empty():
		return
	var dups: Array = []
	for spell_name in SpellDB.all_spell_names():
		var dups_here := _direct_key_dups(text, '"%s": {' % spell_name)
		for k in dups_here:
			dups.append("%s: ключ \"%s\" встречается в блоке дважды" % [spell_name, k])
	_check(dups.is_empty(),
		"в spells_db.json нет дублирующихся ключей (найдено: %s)" % str(dups))


## Ключи ТОЛЬКО на первом уровне вложенности блока заклинания.
##
## Считать все ключи подряд нельзя: у Blizzard два эффекта в массиве effects,
## и у каждого свои "type"/"duration"/"sphere" — это разные объекты, а не
## дубликаты. Дубликат — это когда одно и то же имя повторяется среди
## СОседних ключей самого заклинания, где JSON берёт последнее значение,
## и старое молча пропадает (именно так в базе жил Teleport: "range": 0
## рядом с "range": 320).
func _direct_key_dups(text: String, block_key: String) -> Array:
	var out: Array = []
	var i := text.find(block_key)
	if i < 0:
		return out
	# Открывающая скобка блока идёт сразу за block_key.
	var start := i + block_key.length() - 1
	var depth := 0
	var in_string := false
	var escaped := false
	var seen: Dictionary = {}
	var j := start
	while j < text.length():
		var ch := text[j]
		if in_string:
			if escaped:
				escaped = false
			elif ch == "\\":
				escaped = true
			elif ch == '"':
				in_string = false
			j += 1
			continue
		# Ключ первого уровня проверяем ДО обработки кавычки как начала строки.
		# Порядок важен: если сначала ловить in_string, то кавычка ключа на
		# глубине 1 всегда съедалась как «начало строки», и проверка ключа
		# становилась мёртвым кодом.
		if depth == 1 and ch == '"':
			var name := _read_key_at(text, j)
			if name != "":
				# Нужны две структуры: все встреченные ключи и отдельно повторы.
				if name in seen:
					if not out.has(name):
						out.append(name)
				else:
					seen[name] = true
				# Обязательно перепрыгиваем через двоеточие, а не на один символ:
				# иначе сканирование попадает ВНУТРЬ имени ключа, следующая же
				# кавычка читается как «начало строки», и весь остальной файл
				# уходит в бесконечное чередование кавычек (тест был зелёным).
				var colon := text.find(":", j)
				j = colon + 1 if colon >= 0 else j + 1
				continue
		if ch == '"':
			in_string = true
			j += 1
			continue
		if ch == "{":
			depth += 1
			j += 1
			continue
		if ch == "}":
			depth -= 1
			if depth == 0:
				break
			j += 1
			continue
		j += 1
	return out


## Имя ключа, начинающегося на позиции i (сама кавычка), если сразу после
## закрывающей кавычки идёт двоеточие. Иначе "" — это не ключ.
func _read_key_at(text: String, i: int) -> String:
	var end_q := text.find('"', i + 1)
	if end_q < 0:
		return ""
	var name := text.substr(i + 1, end_q - i - 1)
	var k := end_q + 1
	while k < text.length() and text[k] == " ":
		k += 1
	if k < text.length() and text[k] == ":":
		return name
	return ""


func _finish() -> void:
	if _fails.is_empty():
		print("MAGIC: RESULT: OK")
	else:
		print("MAGIC: RESULT: FAIL (%d): %s" % [_fails.size(), str(_fails)])
	quit()
