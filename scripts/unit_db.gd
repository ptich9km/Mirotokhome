class_name UnitDB
## База юнитов из assets/units/units_db.json (сгенерирована из units.txt).
## Даёт фазы движения/атаки/смерти, тайминги, размер и якорь по имени набора
## ("heroes/swordsman", "monsters/orc", "humans/mage_st").

const DB_PATH := "res://assets/units/units_db.json"
const TICK := 0.05  # множитель тайминга (единицы "тиков" из units.txt)

## Loot families in summary order (tests/package_a_smoke.gd). Data, not a
## constant: a mod with a new family (say "demon") must reach the summary.
static func loot_families() -> Array:
	return ContentRules.list("units.loot_families")

## Loot family of a set by SPECIES: the fallback path when there is no explicit
## `loot_family` field in units_db.json (the field was written 2026-10-22 by
## tests/gen_gray_loot_family.py for all 50 `monsters/*` sets and takes priority
## — see loot_family_of). The species comes from the art: img2img copies
## `monsters/<species>_t<N>` (tests/gen_grey_tiers.py) carry exactly the same
## species as the original `monsters/<species>`. Without this binding an animal
## (`monsters/wolf...`) would fall into the financial `default` table and drop
## ARMOR AND WEAPONS, while the player's decision of 2026-10-07 was that beasts
## carry no equipment.
## The key is taken from the SPECIES segment only (`monsters/bee_t3` -> `bee`),
## not from the whole name: the tier suffix is cut BEFORE the lookup, otherwise
## tiers 2..5 would not find themselves.
##
## 2026-10-29: the table moved to data (`units.loot_by_species`) — a mod with a
## new beast can state right away what it drops.
static func loot_by_species() -> Dictionary:
	return ContentRules.dict("units.loot_by_species")

static var _db: Dictionary = {}
static var _loaded := false
static var _by_id := {}

static func ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	var f := FileAccess.open(DB_PATH, FileAccess.READ)
	if f == null:
		push_error("UnitDB: не открыть " + DB_PATH)
		return
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if parsed is Dictionary:
		_db = parsed
	# Mods: new sets and stat patches — before the index, so ids reach _by_id.
	ModLoader.overlay("units", _db)
	# Индекс: ID юнита (из units.txt) -> имя набора (для спавна НПЦ из .alm)
	_by_id = {}
	for name in _db:
		var ids: Variant = _db[name].get("ids", null)
		if ids is Array:
			for uid in ids:
				_by_id[int(uid)] = name

## Данные набора по имени ("heroes/swordsman") или {}.
static func get_set(name: String) -> Dictionary:
	ensure_loaded()
	return _db.get(name, {})

## Имя набора по ID юнита (type_id из секции units .alm) или "".
static func set_name_for_id(unit_id: int) -> String:
	ensure_loaded()
	return str(_by_id.get(unit_id, ""))

## Данные набора по ID юнита или {} (если ID неизвестен).
static func get_set_by_id(unit_id: int) -> Dictionary:
	return get_set(set_name_for_id(unit_id))

## Агрессивный ли юнит: наборы монстров с палитрой 5 (орки, гоблины, звери)
## атакуют игрока. Мирные жители/животные (палитра != 5) — не нападают.
## Враждебность набора.
##
## Раньше здесь проверялось `begins_with("monsters/")` И `palette == 5`. После
## удаления арта Аллодов II семейства `monsters/` не существует (11.10), а
## враждебными станут риги Серых с совершенно другим префиксом. Поэтому
## признак враждебности — САМ `palette == 5`, а не имя папки: он переживает
## любую смену семейства. Сегодня поведение то же (palette 5 был только у
## монстров), завтра риг Серых получит palette 5 и станет враждебным сам.
static func is_hostile(name: String) -> bool:
	return int(get_set(name).get("palette", 0)) == ContentRules.int_value("units.hostile_palette", 5)

## Первый кадр набора (для статичного превью в редакторе/палитре).
static func preview_frame(name: String) -> Texture2D:
	var o := get_set(name)
	var folder := str(o.get("folder", name))
	var prefix := str(o.get("prefix", "sprites"))
	if prefix == "" or prefix == "null":
		prefix = "sprites"
	return load(frame_path(folder, prefix, 1))

## Все имена наборов с указанным префиксом ("humans/", "monsters/"), по алфавиту.
static func all_names(prefix: String = "") -> Array:
	ensure_loaded()
	var out: Array = []
	for name in _db:
		if prefix == "" or str(name).begins_with(prefix):
			out.append(name)
	out.sort()
	return out

static func has(name: String) -> bool:
	ensure_loaded()
	return _db.has(name)

## Число кадров в наборе (sprites-00N.png).
static func frame_count(name: String) -> int:
	return int(get_set(name).get("frames", 0))

## Path to a frame (1-based): res://assets/units/<folder>/<prefix>-NNN.png
## Some sets use their own file name prefix (sprites | swordsman | ...).
## A `folder` of the form `mod://<id>/assets/...` resolves into the mod folder —
## that is how a mod can ship its own frame strip without copying it into res://.
static func frame_path(folder: String, prefix: String, frame: int) -> String:
	if ModLoader.is_mod_path(folder):
		return "%s/%s-%03d.png" % [ModLoader.resolve(folder), prefix, frame]
	return "res://assets/units/%s/%s-%03d.png" % [folder, prefix, frame]

## Префикс кадров набора ("sprites" | "swordsman" | ...) из базы.
static func frame_prefix(name: String) -> String:
	var o := get_set(name)
	var p := str(o.get("prefix", ""))
	if p != "" and p != "null":
		return p
	return "sprites"

## Фазы (число направлений x фаз в блоке), с fallback на значения по умолчанию.
static func move_phases(name: String) -> int:
	return int(get_set(name).get("move", 8))

static func attack_phases(name: String) -> int:
	return int(get_set(name).get("attack", 4))

static func dying_phases(name: String) -> int:
	return int(get_set(name).get("dying", 4))

static func cast_phases(name: String) -> int:
	return int(get_set(name).get("cast", 0))

static func idle_phases(name: String) -> int:
	return int(get_set(name).get("idle_phases", 0))

static func decay_phases(name: String) -> int:
	return int(get_set(name).get("decay", 0))

## Число нарисованных направлений в файле (5 для героя с зеркалом правых).
static func dirs(name: String) -> int:
	return int(get_set(name).get("dirs", 8))

## Тайминги (секунды) по фазам блока. Если расписания нет — равномерный дефолт.
static func block_times(name: String, key: String, phases: int) -> Array:
	var o := get_set(name)
	var raw: Variant = o.get(key, null)
	if raw is Array and not raw.is_empty():
		var out: Array = []
		for t in raw:
			out.append(float(t) * TICK)
		return out
	var def: Array = []
	for i in range(phases):
		def.append(0.15)
	return def

## Порядок кадров в блоке (номера фаз). Если пусто — 0..phases-1 по порядку.
static func block_frames(name: String, key: String, phases: int) -> Array:
	var o := get_set(name)
	var raw: Variant = o.get(key, null)
	if raw is Array and not raw.is_empty():
		return raw
	var seq: Array = []
	for i in range(phases):
		seq.append(i)
	return seq

# --- Поля, перенесённые из units.txt (полный порт) ---

## Хитбокс выделения юнита [x1,y1,x2,y2] (для клика/выбора).
static func sel_box(name: String) -> Rect2i:
	var o := get_set(name)
	var raw: Variant = o.get("sel_box", null)
	if raw is Array and raw.size() == 4:
		return Rect2i(int(raw[0]), int(raw[1]), int(raw[2]) - int(raw[0]), int(raw[3]) - int(raw[1]))
	# дефолт: почти весь спрайт
	return Rect2i(16, 16, 96, 96)

## Задержка атаки в тиках (из units.txt AttackDelay).
static func attack_delay(name: String) -> float:
	return float(get_set(name).get("attack_delay", 4)) * TICK

## Номер палитры спрайта (0..7; монстры 5, скелеты 1-2, люди 0).
static func palette(name: String) -> int:
	return int(get_set(name).get("palette", 0))

## Портрет юнита (имя из units.txt InfoPicture).
static func info_picture(name: String) -> String:
	return str(get_set(name).get("info_picture", ""))

## Размер юнита в клетках (1 = обычный, 2 = тролль/огр/катапульта, 3 = дракон).
static func tile_size(name: String) -> int:
	return int(get_set(name).get("tile_size", 1))

## Семейство для лута: beast | insect | humanoid | undead | monstrous.
## Пусто = семейство неизвестно (enemy.gd берёт таблицу `default`).
static func loot_family(name: String) -> String:
	return str(get_set(name).get("loot_family", ""))

## Loot table for the victim `name` (family key of loot_tables.json).
##
## Sources by priority: the explicit `loot_family` field in the base (present on
## all `monsters/*` sets, written by tests/gen_gray_loot_family.py), then the
## species from `units.loot_by_species` (a safety net for new sets without the
## field). The tier suffix is cut before the lookup (`monsters/bee_t3` -> `bee`).
## City sets, heroes and an empty name -> "".
static func loot_family_of(name: String) -> String:
	var explicit := str(get_set(name).get("loot_family", ""))
	if explicit != "":
		return explicit
	if name.begins_with("city_") or not name.contains("/"):
		return ""
	var short := name.get_file()
	var tier_at := short.rfind("_t")
	if tier_at > 0 and short.substr(tier_at + 2).is_valid_int():
		short = short.substr(0, tier_at)
	return str(loot_by_species().get(short, ""))

## Creature type used by weapon-kind resistance (Allods formula):
## human | undead | beast | insect | monster. An explicit `creature_type` field
## wins; otherwise the set name decides. "People" is deliberately narrower than
## loot_family humanoid: a club is bad against people, not against every orc and
## troll (those are monsters, like the original's separate creature kinds).
static func creature_type_of(name: String) -> String:
	var explicit := str(get_set(name).get("creature_type", ""))
	if explicit != "":
		return explicit
	var n := name.to_lower()
	if n.contains("necro") or n.contains("undead") or n.contains("ghost") \
			or n.contains("skeleton") or n.contains("zombie"):
		return "undead"
	if n.contains("orc") or n.contains("goblin") or n.contains("troll") \
			or n.contains("ogre") or n.contains("cannibal") or n.contains("dino") \
			or n.contains("dragon") or n.contains("succubus"):
		return "monster"
	if n.contains("city_human") or n.contains("humans/") or n.contains("human") \
			or n.contains("hero"):
		return "human"
	var fam := loot_family_of(name)
	match fam:
		"beast":
			return "beast"
		"insect":
			return "insect"
		"undead":
			return "undead"
		"humanoid", "monstrous":
			return "monster"
	return "monster"

## Damage percentage of `weapon_kind` against `creature_type` (100 = neutral).
## The table lives in assets/config/content_rules.json under
## `combat.weapon_vs_type`; the Allods source formula is
## `trunc(damage * (100 - resistance) / 100 + 0.75)`, i.e. 125% / 75% here.
static func weapon_percent(weapon_kind: String, creature_type: String) -> int:
	var table := ContentRules.dict("combat.weapon_vs_type")
	var row: Variant = table.get(weapon_kind, null)
	if row is Dictionary:
		return int((row as Dictionary).get(creature_type, 100))
	return 100

## Тир набора (1..5), 0 - если тира нет. Тиры Серых записывает
## tests/gen_grey_tiers_db.py; tests/gray_tier_smoke сверяет поле с суффиксом
## `_tN` в имени набора. Дроп сломанной вещи выбирает металл ПО ТИРУ
## (enemy.gd:_broken_gear -> ItemDB.broken_materials), поэтому тир читается
## здесь, а не разбирается из строки имени в каждом потребителе.
static func tier(name: String) -> int:
	return int(get_set(name).get("tier", 0))

## Босс или дракон? Только они роняют ЦЕЛУЮ вещь вместо сломанной
## ([craft] boss_intact_chance).
##
## Поле `boss: 1` добавлено 07.10. До него признака босса не существовало
## ВООБЩЕ, и tempting-кандидатом был tile_size (дракон 3, тролль 2) - но это
## размер спрайта, а не «босс»: у humans/catapult1 тоже tile_size 2. Строить
## на размере юнита значило заложить мину, которая выстрелит, когда появится
## крупный обычный моб.
static func is_boss(name: String) -> bool:
	return int(get_set(name).get("boss", 0)) != 0

## Зеркалить ли спрайт юнита (Flip=1 — тролли, дракон, летающие).
static func flip(name: String) -> bool:
	return int(get_set(name).get("flip", 0)) != 0

## Высота полёта в пикселях (Z — бат/дракон/саккуб парят над землёй).
static func fly_z(name: String) -> int:
	return int(get_set(name).get("z", 0))

## Фазы анимации костей после смерти (BonePhases — у нежити).
static func bone_phases(name: String) -> int:
	return int(get_set(name).get("bone", 0))

## Тип снаряда дальнобойного юнита (-1 = не стреляет; 1.. = снаряд из проекта).
static func projectile(name: String) -> int:
	return int(get_set(name).get("projectile", -1))

## Задержка выстрела (ShootDelay в тиках).
static func shoot_delay(name: String) -> float:
	return float(get_set(name).get("shoot_delay", 8)) * TICK

## Точка вылета снаряда [x0,y0,x1,y1,...] — 8 пар на каждое направление.
static func shoot_offset(name: String) -> Array:
	var o := get_set(name)
	var raw: Variant = o.get("shoot_offset", null)
	if raw is Array:
		return raw
	return []

## Звуки юнита [атака, ?, боль1, боль2, смерть] — ключи sound_db.json
## (например "voice.monster.wolf.attack"). Пустой массив = юнит молчит.
static func unit_sound(name: String) -> Array:
	var o := get_set(name)
	var raw: Variant = o.get("sound", null)
	if raw is Array:
		return raw
	return []

## Сопротивление набора стихии (вычитается из урона магии). 0 = нет.
## Таблица заполняется tests/gen_unit_resists.py в assets/units/units_db.json.
static func resist_of(name: String, sphere: String) -> int:
	var o := get_set(name)
	var r: Variant = o.get("resist", null)
	if r is Dictionary:
		return int((r as Dictionary).get(str(sphere).to_lower(), 0))
	return 0