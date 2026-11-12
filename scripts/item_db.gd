class_name ItemDB
extends Node
## База всех 491 предметов игры: assets/items/item_db.json (из data.bin + иконки).
## Данные настоящие: цена/вес/урон/защита из оригинальной игры (англ. релиз),
## имена на русском сгенерированы по матрицам качество+материал+тип.
## Классификация слота/оружия — для экипировки героя.

const DB_PATH := "res://assets/items/item_db.json"

## Type lists live in data (`assets/config/content_rules.json`, `items.*`): a mod
## can add a new weapon or armor type without touching code. Twelve constants
## used to sit here, and a new type was unreachable for mods at all.
static func type_list(key: String) -> Array:
	return ContentRules.shared_list("items." + key)
## Все слоты экипировки героя, в порядке отображения на панели персонажа.
const EQUIP_SLOTS: Array[String] = [
	"weapon", "shield", "head", "cloak", "body", "hands", "feet", "amulet", "ring1", "ring2",
]

## Русское название слота для подписи/тултипа панели персонажа.
static func slot_title(slot: String) -> String:
	match slot:
		"weapon": return Loc.t("ui.slot.weapon")
		"shield": return Loc.t("ui.slot.shield")
		"head": return Loc.t("ui.slot.head")
		"cloak": return Loc.t("ui.slot.cloak")
		"body": return Loc.t("ui.slot.body")
		"hands": return Loc.t("ui.slot.hands")
		"feet": return Loc.t("ui.slot.feet")
		"amulet": return Loc.t("ui.slot.amulet")
		"ring1", "ring2": return Loc.t("ui.slot.ring")
	return "—"

static var _items: Array = []
static var _by_key := {}
static var _loaded := false

static func ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	var f := FileAccess.open(DB_PATH, FileAccess.READ)
	if f == null:
		push_error("ItemDB: cannot open " + DB_PATH)
		return
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if parsed is not Array:
		push_error("ItemDB: broken JSON")
		return
	for raw in parsed:
		if raw is Dictionary:
			_items.append(raw)
	# Mods are applied before indexes are built: patches mutate parsed records.
	ModLoader.overlay("items", _items)
	_by_key = {}
	for raw in _items:
		var it: Dictionary = raw
		_by_key[str(it.get("key", ""))] = it
	print("ItemDB: loaded %d items" % _items.size())

static func all() -> Array:
	ensure_loaded()
	return _items

## A forged item keeps its plus level in the KEY: "Crafted iron Long Sword +3#a7".
## The base record is cloned and its stats are grown deterministically from the
## seed, so an inventory of plain strings still distinguishes two copies.
static func split_plus_key(key: String) -> Dictionary:
	var body := key
	var seed := ""
	var hash_at := body.rfind("#")
	if hash_at >= 0:
		seed = body.substr(hash_at + 1)
		body = body.substr(0, hash_at)
	var at := body.rfind(" +")
	if at < 0:
		return {"base": key, "plus": 0, "seed": ""}
	var tail := body.substr(at + 2).strip_edges()
	if not tail.is_valid_int():
		return {"base": key, "plus": 0, "seed": ""}
	return {"base": body.substr(0, at), "plus": int(tail), "seed": seed}


static func base_key(key: String) -> String:
	return str(split_plus_key(key).get("base", key))


static func plus_of(key: String) -> int:
	return int(split_plus_key(key).get("plus", 0))


static func plus_key(base: String, plus: int, seed: String) -> String:
	if plus <= 0:
		return base
	return "%s +%d#%s" % [base, plus, seed]


## Deterministic per-plus roll from the class pool. The seed is part of the key,
## so save/load and a second look at the item show the same numbers.
static func _plus_mods(base: Dictionary, plus: int, seed: String) -> Dictionary:
	var pool: Array = []
	var slot := slot_of(base)
	if slot == "weapon":
		pool = [{"damage_min": 1, "damage_max": 1}, {"to_hit": 1}]
	elif slot == "shield":
		pool = [{"defence": 1}, {"absorption": 1}]
	elif slot in ["body", "head", "hands", "feet"]:
		pool = [{"defence": 1}, {"absorption": 1}, {"magcap": 2}]
	elif slot == "cloak":
		pool = [{"defence": 1}, {"magcap": 2}]
	if pool.is_empty():
		pool = [{"defence": 1}]
	var mods := {}
	var base_key_text := str(base.get("key", ""))
	for level in range(1, plus + 1):
		var rng := RandomNumberGenerator.new()
		rng.seed = _stable_hash(base_key_text) + _stable_hash(seed) * 31 \
			+ level * 2654435761
		var picked: Dictionary = pool[rng.randi_range(0, pool.size() - 1)]
		for field in picked:
			mods[field] = int(mods.get(field, 0)) + int(picked[field])
	return mods


static func _stable_hash(text: String) -> int:
	var h := 2166136261
	for byte in text.to_utf8_buffer():
		h = (h ^ int(byte)) * 16777619
	return h & 0x7FFFFFFF


static func _synthesize_plus(base: Dictionary, plus: int, seed: String) -> Dictionary:
	var out: Dictionary = base.duplicate(true)
	var mods := _plus_mods(base, plus, seed)
	for field in mods:
		out[field] = int(out.get(field, 0)) + int(mods[field])
	out["key"] = plus_key(str(base.get("key", "")), plus, seed)
	out["base_key"] = str(base.get("key", ""))
	out["plus"] = plus
	out["plus_seed"] = seed
	out["mods"] = mods
	out["price"] = int(round(float(base.get("price", 0)) * (1.0 + 0.12 * plus)))
	var suffix := " +%d" % plus
	out["name_ru"] = str(base.get("name_ru", base.get("key", ""))) + suffix
	out["name_en"] = str(base.get("name_en", base.get("key", ""))) + suffix
	return out


static func find(key: String) -> Dictionary:
	ensure_loaded()
	var found: Dictionary = _by_key.get(key, {})
	if found.is_empty():
		var parts := split_plus_key(key)
		if int(parts.get("plus", 0)) > 0:
			var base: Dictionary = _by_key.get(str(parts.get("base", "")), {})
			if not base.is_empty():
				return _synthesize_plus(base, int(parts["plus"]), str(parts.get("seed", "")))
	if found.is_empty() and is_quest_key(key):
		return make_quest_item(quest_base(key))
	if found.is_empty() and key.begins_with("Book "):
		# Spell book: the base only stores books of the five vanilla spheres,
		# while shops build books from SpellDB (SpellDB.make_book_item) — so a
		# modded school is sold but has no item_db record. Without this fallback
		# the item in the inventory would be "empty" (no name/icon/price).
		var sphere := SpellDB.sphere_of_book(key)
		if sphere != "":
			return SpellDB.make_sphere_book(sphere)
		return SpellDB.book_item(key)
	return found


## Quest items: a SEPARATE category of goods that exist only for a quest (player
## decision 13.11). They look and read like the thing they stand for, but they
## are a parcel, not property: no reading, no selling, no equipping. The base
## item itself stays an ordinary thing of the world.
const QUEST_PREFIX := "Quest "

static func is_quest_key(key: String) -> bool:
	return str(key).begins_with(QUEST_PREFIX)

static func quest_key(base_key: String) -> String:
	return QUEST_PREFIX + str(base_key)

## Base item key of a quest item ("" when the key is not a quest item).
static func quest_base(key: String) -> String:
	return str(key).trim_prefix(QUEST_PREFIX) if is_quest_key(key) else ""

static func is_quest_item(item: Dictionary) -> bool:
	return str(item.get("quality", "")) == "Quest"

## The quest copy of a base item. Price 0 and no weight: the bag shows it as a
## quest good, and nothing can be done with it except hand it over. The record is
## COPIED from the base, so the name and icon follow the base in both languages
## without this class reading the language columns itself.
static func make_quest_item(base_key: String) -> Dictionary:
	var base := find(base_key)
	var item := base.duplicate(true) if not base.is_empty() else {}
	item["key"] = quest_key(base_key)
	item["quality"] = "Quest"
	item["quest_base"] = str(base_key)
	item["type"] = ""
	item["price"] = 0
	item["weight"] = 0.0
	item["effects"] = []
	return item

## Слот экипировки: weapon / shield / head / cloak / body / hands / feet / amulet / ring.
## Кольцо возвращает "ring" — конкретный слот ring1/ring2 выбирает player.equip_item().
## "" — предмет не экипируется или тип неизвестен.
## The item name in the current language. Falls back to the Russian name and then
## to the key: a record without `name_en` shows the Russian name rather than an
## internal key, which is more readable than "sword_bronze" in a tooltip.
## JSON `null` arrives as null and `str(null)` is "<null>", so type is checked:
## a null field must not turn into a literal "<null>" in the UI.
static func display_name(item: Dictionary) -> String:
	if Loc.locale() == "en":
		var en = item.get("name_en", "")
		if en is String and str(en) != "":
			return str(en)
	var ru = item.get("name_ru", "")
	if ru is String and str(ru) != "":
		return str(ru)
	return str(item.get("key", ""))


static func slot_of(item: Dictionary) -> String:
	var t := str(item.get("type", ""))
	if t in type_list("weapon_types"):
		return "weapon"
	if t in type_list("shield_types"):
		return "shield"
	if t in type_list("head_types"):
		return "head"
	if t in type_list("cloak_types"):
		return "cloak"
	if t in type_list("body_types"):
		return "body"
	if t in type_list("hands_types"):
		return "hands"
	if t in type_list("feet_types"):
		return "feet"
	if t in type_list("amulet_types"):
		return "amulet"
	if t in type_list("ring_types"):
		return "ring"
	return ""

## Подходит ли предмет в слот (ring принимает и ring1/ring2).
static func fits_slot(item: Dictionary, slot: String) -> bool:
	var s := slot_of(item)
	if s == "":
		return false
	if s == "ring":
		return slot == "ring" or slot == "ring1" or slot == "ring2"
	return s == slot

## Все предметы базы, подходящие в слот (для подсветки совместимых предметов инвентаря).
static func items_for_slot(slot: String) -> Array:
	ensure_loaded()
	var out: Array = []
	for it in _items:
		if fits_slot(it, slot):
			out.append(it)
	return out

## Тип оружия для анимаций героя (unarmed/sword/axe/club/pike/bow/xbow/staff/magic).
static func weapon_kind(item: Dictionary) -> String:
	var t := str(item.get("type", ""))
	if t in type_list("sword_types"):
		return "sword"
	if t in type_list("club_types"):
		return "club"
	if t in ["Axe", "Two Handed Axe"]:
		return "axe"
	if t in ["Pike", "Lance", "Halberd"]:
		return "pike"
	if t in ["Staff", "Shaman Staff"]:
		return "staff"
	if t in ["Short Bow", "Long Bow"]:
		return "bow"
	if t in ["Crossbow"]:
		return "xbow"
	return "unarmed"

static func is_two_handed(item: Dictionary) -> bool:
	var t := str(item.get("type", ""))
	return t in type_list("two_handed_types")

## Лёгкая броня (кожа/ткань) — набор heroes_l/, тяжёлая (металл) — heroes/.
static func armor_kind(item: Dictionary) -> String:
	var m := str(item.get("material", ""))
	var t := str(item.get("type", ""))
	# "Linen" - лён (ткань плащей, tests/gen_cloak_items.py). Плащи и рубашки
	# относятся к тряпкам по ТИПУ (is_cloth ниже), но материал перечислен и
	# здесь, чтобы одежда из льна была лёгкой и если тип когда-то изменится.
	# Пакет C+D (29.10): "Leather" — кожа лёгкого фракционного комплекта
	# (решение игрока «давай кожу»). Раньше кожа была выведена из игры; теперь
	# вернулась как материал лёгкой брони и НЕ переплавляется в слитки.
	var is_light_mat := m in ["Linen", "None", "Leather"]
	var is_cloth := t in ["Cloak", "Cape", "Robe", "Dress", "Hat", "Low Hat", "Cap"]
	if is_light_mat or is_cloth:
		return "light"
	return "heavy"

## Types that cannot be worn even though their quality is a normal one.
const _INGOT_TYPE := "Ingot"

## General gate: not a book/scroll/potion/quest/ingot/broken/craft material.
static func is_equippable(item: Dictionary) -> bool:
	var q := str(item.get("quality", ""))
	if q in NON_GEAR_QUALITY:
		return false
	if str(item.get("type", "")) == _INGOT_TYPE:
		return false
	return true

## Non-wearable qualities: broken gear and craft materials are raw stuff.
## "Tag" — фракционная бирка (пакет B): трофей-ингредиент, не снаряжение.
const NON_GEAR_QUALITY := [
	"Book", "Potion", "Scroll", "SuperScroll", "Quest", "Herb",
	"Broken", "Broken Fine", "Broken Rare",
	"Fabric", "Essence", "Recipe", "Tag",
]

## Class restrictions (22.10 player decision): a warrior wears metal armor
## and non-magical weapons only, a mage wears cloth (linen) and staves only
## and carries no shield. Amulets, rings and cloaks fit both classes.
const CLASS_WARRIOR := "warrior"
const CLASS_MAGE := "mage"
const _BOTH_CLASS_SLOTS := ["amulet", "ring", "cloak"]

static func class_of(hero_class: String) -> String:
	return CLASS_MAGE if hero_class == CLASS_MAGE else CLASS_WARRIOR

## Does the item fit the hero class? Non-gear and unknown slots answer true:
## this guard only covers the class split, is_equippable stays the general one.
## Accepts both the abstract slot ("ring", "weapon") and a concrete one
## ("ring1", "ring2"): callers hand in their own cell name.
static func allows_class(item: Dictionary, hero_class: String) -> bool:
	var slot := slot_of(item)
	var cls := class_of(hero_class)
	if slot in ["ring1", "ring2"]:
		slot = "ring"
	if slot == "" or slot in _BOTH_CLASS_SLOTS:
		return true
	if cls == CLASS_MAGE:
		if slot != "weapon":
			return armor_kind(item) == "light"
		return weapon_kind(item) == "staff"
	if weapon_kind(item) == "staff":
		return false
	if slot == "weapon" or slot == "shield":
		return true
	return armor_kind(item) == "heavy"

## Why the item does not fit the class (for cards and hints). "" if it fits.
static func class_block_text(item: Dictionary, hero_class: String) -> String:
	if allows_class(item, hero_class):
		return ""
	if class_of(hero_class) == CLASS_MAGE:
		if slot_of(item) == "shield":
			return Loc.t("ui.class.mage_no_shield")
		if slot_of(item) == "weapon":
			return Loc.t("ui.class.mage_staff_only")
		return Loc.t("ui.class.mage_cloth_only")
	if weapon_kind(item) == "staff":
		return Loc.t("ui.class.war_no_staff")
	return Loc.t("ui.class.war_metal_only")

## What kind of gear the slot takes for the class (Russian, for empty-slot hints).
static func slot_fits_text(slot: String, hero_class: String) -> String:
	var mage := class_of(hero_class) == CLASS_MAGE
	match slot:
		"weapon": return Loc.t("ui.slot.fits.staff" if mage else "ui.slot.fits.weapon")
		"shield": return Loc.t("ui.slot.fits.shield_mage" if mage else "ui.slot.fits.shield")
		"head": return Loc.t("ui.slot.fits.head_mage" if mage else "ui.slot.fits.head")
		"cloak": return Loc.t("ui.slot.fits.cloak")
		"body": return Loc.t("ui.slot.fits.body_mage" if mage else "ui.slot.fits.body")
		"hands": return Loc.t("ui.slot.fits.hands_mage" if mage else "ui.slot.fits.hands")
		"feet": return Loc.t("ui.slot.fits.feet_mage" if mage else "ui.slot.fits.feet")
		"amulet": return Loc.t("ui.slot.fits.amulet")
		"ring1", "ring2": return Loc.t("ui.slot.fits.ring")
	return "—"

## --- Сломанные вещи и ресурсы крафта (мастерская, 07.10) -----------------
## Качество сломанной вещи. "" - если это не сломанная вещь.
const BROKEN_QUALITIES := ["Broken", "Broken Fine", "Broken Rare"]

## Ключ сломанной вещи для ровно этой пары (материал, категория, качество).
## Категория: "Armor" | "Weapon" | "Garment". "" если такой записи нет.
## Порядок слов в ключе ("Broken Fine iron Armor") обязателен: контракт
## tests/item_key_literal_smoke.gd:111 требует, чтобы сегмент материала в
## ключе совпадал с полем `material` в ТОЧНОМ регистре.
static func broken_key(material: String, category: String, quality: String) -> String:
	if material == "" or category == "" or not BROKEN_QUALITIES.has(quality):
		return ""
	var parts := ["Broken"]
	if quality != "Broken":
		parts.append(quality.split(" ", 1)[1])
	parts.append(material)
	parts.append(category)
	return " ".join(parts)

## Качество сломанной вещи ("Broken"/"Broken Fine"/"Broken Rare") или "".
static func broken_quality(item: Dictionary) -> String:
	var q := str(item.get("quality", ""))
	return q if BROKEN_QUALITIES.has(q) else ""

## Сломанная вещь? Читает ТОЛЬКО качество, а не type: у ресурсов крафта type
## тоже не в списках слотов, и путать их нельзя.
static func is_broken(item: Dictionary) -> bool:
	return broken_quality(item) != ""

## Ресурс крафта (ткань/эссенция)? Нужен, чтобы исключить их из продажи в
## лавке и из подсчёта «сколько вещей можно надеть».
static func is_craft_material(item: Dictionary) -> bool:
	var q := str(item.get("quality", ""))
	return q == "Fabric" or q == "Essence"

## Запись базы по (материал, категория, качество). {} если нет.
static func broken_item_for(material: String, category: String, quality: String) -> Dictionary:
	var key := broken_key(material, category, quality)
	return find(key) if key != "" else {}

## Категория сломанной вещи: "Armor" | "Weapon" | "Garment" или "".
static func broken_category(item: Dictionary) -> String:
	if not is_broken(item):
		return ""
	var t := str(item.get("type", ""))
	return t.substr("Broken ".length()) if t.begins_with("Broken ") else ""

## Есть ли сломанная вещь этой категории из этого материала хоть в каком-то
## качестве. Нужно дропу: «есть ли вообще что уронить».
static func has_broken(material: String, category: String) -> bool:
	for q in BROKEN_QUALITIES:
		if broken_key(material, category, q) != "":
			return true
	return false

## Металлы лут-сломанного для категории с учётом ТИРА убитого (1..5).
##
## Смысл: сломанное падает с Серых и НПЦ как сырьё для кузницы, поэтому
## металл должен расти вместе с силой врага, а не выпадать случайно по всей
## таблице. Иначе волк-новичок ронял бы мусор, а переплавка на старте не
## имела бы смысла. Полосы (пакет A: 16 фракционных металлов удалены,
## остаются только четыре общих):
##   тир <= 0 или <= 2 -> bronze, iron (старт/обучение);
##   тир 3             -> iron, steel;
##   тир >= 4          -> steel.
## Одежда мага — только лён (material "Linen" в точном регистре, как в базе).
static func broken_materials(category: String, tier: int) -> Array:
	if category == "Garment":
		return ["Linen"]
	if tier >= 4:
		return ["steel"]
	if tier == 3:
		return ["iron", "steel"]
	return ["bronze", "iron"]

## Взвешенное качество сломанной вещи: 60 / 25 / 15 (обычный мусор падает
## чаще добротного, редкий — почти нет). Порядок — от обычного к редкому,
## иначе случайный выбор дал бы «редкий» в трети случаев.
static func roll_broken_quality() -> String:
	var roll := randi() % 100
	if roll < 60:
		return "Broken"
	if roll < 85:
		return "Broken Fine"
	return "Broken Rare"

## Сопутствующие компоненты переплавки. Сломанная броня — это ещё и ткань под
## металлом: без неё броня с Серых давала бы только слитки, а портному (рецепты
## требуют Fabric) нечего было бы брать. Одежда — сплошная ткань
## (CraftDB.fabric_from_garment = 2). Оружие ткани не даёт
## (fabric_from_weapon = 0) и оценивается только металлом.
const SMELT_PARTS := {
	"Armor": {"fabric": 1},
	"Weapon": {},
	"Garment": {"fabric": 2},
}

## Случайная СЛОМАННАЯ вещь: {"key": ...} или {} если записей нет.
##
## Общая точка для всех, кто роняет снаряжение: НПЦ (npc.gd:_random_gear)
## и Серые (enemy.gd:_random_gear). Раньше каждая копировала выбор качества
## и подбор металла по роли, и правила успевали разойтись.
##
## `materials` — список материалов-кандидатов (политика вызывающего: роль
## НПЦ или тир Серого), `categories` — какие категории вещи он вообще носит.
## Сломанная вещь — это же вещь в разобранном виде, поэтому из неё
## переплавляется не один металл: под металлом брони всегда есть ткань
## (SMELT_PARTS), иначе ткань в мастерскую приходила бы только от НПЦ.
## Категория не из SMELT_PARTS — пустой результат, а не молча угаданное.
## Выбранное качество — взвешенное; если записи этого качества нет, берётся
## ближайшее существующее, поэтому ключ никогда не указывает в пустоту.
static func roll_broken_gear(materials: Array, categories: Array) -> Dictionary:
	if materials.is_empty() or categories.is_empty():
		return {}
	var category := str(categories[randi() % categories.size()])
	if not SMELT_PARTS.has(category):
		return {}
	var material := str(materials[randi() % materials.size()])
	var key := broken_key(material, category, roll_broken_quality())
	if find(key).is_empty():
		key = ""
		for q in BROKEN_QUALITIES:
			var k := broken_key(material, category, q)
			if k != "" and not find(k).is_empty():
				key = k
				break
	if key == "":
		return {}
	return {"key": key}

## Металлы, которые переплавляет кузница. Регистр важен: материал в item_db
## хранится в нижнем регистре (bronze, iron...) - так же, как названы файлы
## иконок. Пакет A: 16 фракционных металлов удалены из игры, остались только
## четыре общих. Кожа/дерево/ткань сюда НЕ входят: кузнец их не берёт
## (см. is_smeltable).
const _SMELTABLE := [
	"bronze", "iron", "steel", "gold",
]

static func is_smeltable(item: Dictionary) -> bool:
	# Слиток — это уже результат переплавки. Материал у него металлический, но
	# переплавлять его в себя нельзя (иначе «iron Ingot → iron Ingot»).
	if str(item.get("type", "")) == _INGOT_TYPE:
		return false
	return str(item.get("material", "")) in _SMELTABLE

## Ключ предмета-слитка для материала ("", если такого металла нет).
## Материал приходит в нижнем регистре, и ключ слитка такой же: "iron Ingot".
## Раньше ключ строился как "%s Ingot" % material, что работало только при
## заглавном регистре в базе; после перевода металлов вниз переплавка находила
## слиток лишь у части металлов, молча ничего не выдавая.
static func ingot_key(material: String) -> String:
	if material == "":
		return ""
	var ingot: Dictionary = find("%s Ingot" % material.to_lower())
	return str(ingot.get("key", ""))

## Бирки фракций (пакет B переработки ковки, 28.10). Ось — раса фракции,
## та же, что у репутации: humans/ork/necro/druid. Бирка падает со стражника
## форпоста и уходит в рецепты фракционной брони (пакет D).
const TAG_OF_RACE := {
	"humans": "Alliance Tag",
	"ork": "Horde Tag",
	"necro": "Reaper Tag",
	"druid": "Circle Tag",
}

## Ключ бирки расы ("" — такой фракции нет).
static func tag_key(race: String) -> String:
	return str(TAG_OF_RACE.get(race, ""))

## Это бирка-трофей? Читает type, а не quality: «Tag» в quality занят
## отдельно, чтобы бирка не попала в таблицу сломанных вещей.
static func is_tag(item: Dictionary) -> bool:
	return str(item.get("type", "")) == "Trophy"

## Это вещь фракционного набора (пакет C+D)? У неё есть поле `faction`
## (humans/ork/necro/druid): текстура своя в faction_sets/, а металл — сталь.
## Нужно тестам (материал в ключе/имени не обязан совпадать) и лавкам.
static func is_faction_set(item: Dictionary) -> bool:
	return str(item.get("faction", "")) != ""

## Предметы для инвентаря: все экипируемые в порядке базы.
static func equippable_items() -> Array:
	ensure_loaded()
	var out: Array = []
	for it in _items:
		if is_equippable(it):
			out.append(it)
	return out