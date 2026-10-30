class_name SpellDB
## Spell database from assets/spells/spells_db.json (assembled from spells.txt +
## castSpell scrolls in item_db + projectiles.reg). Provides sphere, damage, mana,
## projectile animation and icon by spell name ("Fire_Ball").

const DB_PATH := "res://assets/spells/spells_db.json"

static var _db: Dictionary = {}
static var _loaded := false
static var _by_lower := {}   # spell name (lowercase) -> real name

static func ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	var f := FileAccess.open(DB_PATH, FileAccess.READ)
	if f == null:
		push_error("SpellDB: не открыть " + DB_PATH)
		return
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if parsed is Dictionary:
		_db = parsed
	ModLoader.overlay("spells", _db)

## Spell data by name ("Fire_Ball") or {}.
static func get_spell(name: String) -> Dictionary:
	ensure_loaded()
	return _db.get(name, {})

## Element book ("Book Fire") -> sphere name ("Fire"). "" if not a book.
## The sphere list lives in data (assets/config/content_rules.json, "spells.spheres"):
## a mod can add a new magic school, and scrolls/books pick it up automatically.
static func sphere_of_book(book_name: String) -> String:
	var n := str(book_name).to_lower()
	if n.begins_with("book "):
		var sphere := n.trim_prefix("book ").capitalize()
		if sphere in ContentRules.list("spells.spheres"):
			return sphere
	return ""

## Which element books exist (for the item dictionary).
static func book_item_names() -> Array:
	var out: Array = []
	for sphere in ContentRules.list("spells.spheres"):
		out.append("Book " + str(sphere))
	return out

## Spells of a sphere ("Fire") in database order.
static func spells_of_sphere(sphere: String) -> Array:
	ensure_loaded()
	var out: Array = []
	for name in _db:
		if str(_db[name].get("sphere", "")) == sphere:
			out.append(name)
	out.sort()
	return out

## Projectile damage from the database (base before bonuses).
static func damage(name: String) -> int:
	return int(get_spell(name).get("damage", 0))

## Mana cost.
static func mana_cost(name: String) -> int:
	return int(get_spell(name).get("mana_cost", 0))

## Range (pixels; 0 = self/no range).
static func range_of(name: String) -> float:
	return float(get_spell(name).get("range", 0))

## Area radius (0 = single target).
static func area_of(name: String) -> float:
	return float(get_spell(name).get("area", 0))

## Kind: attack/area/heal/buff/wall/self/debuff/raise.
static func kind_of(name: String) -> String:
	return str(get_spell(name).get("kind", "buff"))

## All spell names in the database (alphabetical) — for test mode and validation.
static func all_spell_names() -> Array:
	ensure_loaded()
	var out: Array = []
	for name in _db:
		out.append(name)
	out.sort()
	return out

## Spell cooldown in seconds (there used to be a single 0.8 s in code).
static func cooldown_of(name: String) -> float:
	return float(get_spell(name).get("cooldown", 0.8))

## Cast wind-up time in seconds (0 = instant).
static func cast_time_of(name: String) -> float:
	return float(get_spell(name).get("cast_time", 0.0))

## Projectile speed in px/s (0 = no projectile).
static func projectile_speed_of(name: String) -> float:
	return float(get_spell(name).get("projectile_speed", 0.0))

## Who can be targeted: enemy/ally/point/self.
static func target_of(name: String) -> String:
	return str(get_spell(name).get("target", "enemy"))

## Spell power multiplier (nuke 1.0, heal > 1).
static func power_coef_of(name: String) -> float:
	return float(get_spell(name).get("power_coef", 1.0))

static func min_damage_of(name: String) -> int:
	return int(get_spell(name).get("min_damage", 1))

## Wall mode: "damage" (fire — burns) or "block" (earth — barrier).
static func wall_mode_of(name: String) -> String:
	return str(get_spell(name).get("wall_mode", "damage"))

static func wall_width_of(name: String) -> float:
	return float(get_spell(name).get("wall_width", 64.0))

static func wall_life_of(name: String) -> float:
	return float(get_spell(name).get("wall_life", 6.0))

## Spell effects: [{"type": "slow", "mult": 0.55, "duration": 12}, ...].
static func effects_of(name: String) -> Array:
	var raw: Variant = get_spell(name).get("effects", [])
	return raw if raw is Array else []

## The first effect of type type or {} (for example "vampirism", "raise").
static func effect_of_type(name: String, type: String) -> Dictionary:
	for e in effects_of(name):
		if str(e.get("type", "")) == type:
			return e
	return {}

## Database check: [errors] — every scroll resolves, every spell
## has a sound and cast fields are filled. Used in tests/magic_smoke.gd.
static func validate() -> Array:
	ensure_loaded()
	var errs: Array = []
	for name in all_spell_names():
		var o: Dictionary = _db[name]
		if str(o.get("sound", "")) == "":
			errs.append("%s: нет звука" % name)
		if str(o.get("ru", "")) == "":
			errs.append("%s: нет ru" % name)
		if str(o.get("target", "")) == "":
			errs.append("%s: нет target" % name)
		if float(o.get("cast_time", -1.0)) < 0.0:
			errs.append("%s: некорректный cast_time" % name)
		var folder := str(o.get("projectile", ""))
		var kind := str(o.get("kind", ""))
		if kind in ["attack", "area"] and folder == "":
			errs.append("%s: атакующее без папки снаряда" % name)
		if folder != "" and not DirAccess.dir_exists_absolute("res://assets/projectiles/%s" % folder):
			errs.append("%s: нет папки снаряда %s" % [name, folder])
	return errs

## Spell sphere.
static func sphere_of(name: String) -> String:
	return str(get_spell(name).get("sphere", ""))

## Projectile frame folder (assets/projectiles/<folder>/sprites-NNN.png).
static func projectile_folder(name: String) -> String:
	return str(get_spell(name).get("projectile", ""))

## Spell sound (SoundDB key; "" = none/not set).
static func sound_of(name: String) -> String:
	return str(get_spell(name).get("sound", ""))

## Book of Magic spell icon: assets/spells/{snake}.png (ChatGPT, 31 pcs.).
## index — position in BOOK_SPELLS (0..23).
static func book_icon_path(index: int) -> String:
	if index < 0 or index >= BOOK_SPELLS.size():
		return ""
	var spell := str(BOOK_SPELLS[index])
	return "res://assets/spells/%s.png" % spell.to_lower().replace("-", "_").replace(" ", "_")

## Spell icon (regular, from inventory -000.png).
static func icon_of(name: String) -> String:
	var o := get_spell(name)
	var icons: Dictionary = o.get("icons", {})
	return str(icons.get("scroll", ""))

static var _proj_icon_cache: Dictionary = {}

## Magic icon from the real registry projectile (projectiles.reg): the "fullest"
## (by opaque pixels) frame assets/projectiles/<folder>/sprites-NNN.png.
## Cached; "" if there is no sprite.
static func projectile_icon(name: String) -> String:
	if _proj_icon_cache.has(name):
		return _proj_icon_cache[name]
	var folder := projectile_folder(name)
	var res := ""
	if folder != "":
		var dir := DirAccess.open("res://assets/projectiles/%s" % folder)
		if dir != null:
			var files: Array = []
			dir.list_dir_begin()
			var fn := dir.get_next()
			while fn != "":
				if fn.begins_with("sprites-") and fn.ends_with(".png"):
					files.append(fn)
				fn = dir.get_next()
			dir.list_dir_end()
			files.sort()
			var best := ""
			var best_area := -1
			for f in files:
				var tex: Texture2D = load("res://assets/projectiles/%s/%s" % [folder, f])
				if tex == null:
					continue
				var img := tex.get_image()
				var area := 0
				for y in img.get_height():
					for x in img.get_width():
						if img.get_pixel(x, y).a > 0.5:
							area += 1
				if area > best_area:
					best_area = area
					best = "%s/%s" % [folder, f]
			if best != "":
				res = "res://assets/projectiles/%s" % best
	_proj_icon_cache[name] = res
	return res

## Number of projectile animation frames in the folder (count sprites-NNN.png files).
static func projectile_frames(name: String) -> int:
	var folder := projectile_folder(name)
	if folder == "":
		return 0
	var dir := DirAccess.open("res://assets/projectiles/%s" % folder)
	var n := 0
	if dir != null:
		dir.list_dir_begin()
		var fn := dir.get_next()
		while fn != "":
			if fn.begins_with("sprites-") and fn.ends_with(".png"):
				n += 1
			fn = dir.get_next()
		dir.list_dir_end()
	return n

## Spell from a scroll name ("Scroll Fire Ball"/"SuperScroll Fire Ball") or "".
## Position (0..23) in the Book of Magic: panel slot 1..24 = magic projectile icon.
const BOOK_SPELLS := [
	"Fire_Arrow", "Fire_Ball", "Wall_of_Fire", "Protection_from_Fire",
	"Heal", "Bless", "Haste", "Drain_Life",
	"Protection_from_Air", "Invisibility", "Prismatic_Spray", "Lightning",
	"Ice_Missile", "Poison_Cloud", "Blizzard", "Protection_from_Water",
	"Summon", "Animate_Dead", "Teleport", "Shield",
	"Protection_from_Earth", "Stone_Curse", "Wall_of_Earth", "Stone_Missile",
]
## Spell index in the canonical Book of Magic (0..23) or -1 if it is not from the book.
static func book_index(name: String) -> int:
	return BOOK_SPELLS.find(str(name))

## Spell from a scroll name ("Scroll Fire Ball"/"SuperScroll Fire Ball") or "".
static func spell_from_scroll(item_name: String) -> String:
	var n := str(item_name)
	for prefix in ["Scroll ", "SuperScroll ", "Elven Scroll ", "Эльфийский свиток: ",
			"Свиток: ", "Quest "]:
		if n.begins_with(prefix):
			var rest := n.trim_prefix(prefix)
			# "Fire Ball" -> "Fire_Ball"
			return rest.replace(" ", "_")
	return ""


## Scroll power from its effects: "castSpell=Fire_Ball:50" -> 50.0, ":100" -> 100.0.
## -1.0 — if the power is not set (then the cast uses the hero's skill).
## We work with the item dictionary, not the key: SpellDB must not depend
## on ItemDB (circular class reference).
static func scroll_power_of(item: Dictionary) -> float:
	for raw in item.get("effects", []):
		var s := str(raw)
		if not s.begins_with("castSpell="):
			continue
		var parts := s.split(":")
		# "castSpell=Fire_Ball:50" → ["castSpell=Fire_Ball", "50"]: the power is the last
		# part. Before, it said `>= 3` here and the power was always read as -1.
		if parts.size() >= 2:
			return float(parts[parts.size() - 1])
	return -1.0

## Spell name by its literal (case-insensitive): "" if none.
static func _resolve_spell(literal: String) -> String:
	ensure_loaded()
	if _by_lower.is_empty():
		for name in _db:
			_by_lower[str(name).to_lower()] = name
	return str(_by_lower.get(str(literal).to_lower(), ""))

## Spell from a single-spell book key ("Book Fire Arrow" -> "Fire_Arrow").
## "" — if it is not a spell book (element books are handled separately).
static func spell_of_book(item_key: String) -> String:
	var n := str(item_key).to_lower().trim_prefix("book ").strip_edges()
	if n in ["fire", "water", "air", "earth", "astral"]:
		return ""   # element book — opens the whole sphere
	return _resolve_spell(n.replace(" ", "_"))

## Item key of a single-spell book ("Fire_Arrow" -> "Book Fire Arrow").
static func book_key_for_spell(spell: String) -> String:
	return "Book " + str(spell).replace("_", " ")

## Sphere book as an item. item_db holds only the five vanilla books; a modded
## school has no record there, yet the shop still sells the book — so ItemDB
## takes it from here (fallback in item_db.find).
static func make_sphere_book(sphere: String) -> Dictionary:
	if sphere == "":
		return {}
	return {
		"key": "Book " + sphere,
		"name_ru": "Книга: " + sphere,
		"name_en": "Book",
		"quality": "Book",
		"type": sphere,
		"price": 0,
		"weight": 10.0,
		"level": 1,
		"icon": str(BOOK_ICONS.get(sphere, BOOK_ICONS["Fire"])),
		"sphere": sphere,
	}


## Item-book by inventory key ("Book Fire Arrow") or {} (not a book).
static func book_item(item_key: String) -> Dictionary:
	var spell := spell_of_book(item_key)
	if spell == "":
		return {}
	return make_book_item(spell)

## Element book icon (for single-spell books of this sphere).
## Element book icon. Before, Allods book icons lived here, moved
## from assets/inventory/ to assets/items/sphere_books/ before that folder was deleted.
## Now the element symbol spells from assets/spells/ are used (sliced by
## tests/extract_chatgpt_magic.py from the ChatGPTMagic1.png atlas), and the folder
## sphere_books/ was deleted as orphaned.
const BOOK_ICONS := {
	"Fire": "res://assets/spells/book_fire.png",
	"Water": "res://assets/spells/book_water.png",
	"Air": "res://assets/spells/book_air.png",
	"Earth": "res://assets/spells/book_earth.png",
	"Astral": "res://assets/spells/book_astral.png",
}

## Synthesize the "single-spell book" item (for the inventory and the shop counter).
static func make_book_item(spell: String) -> Dictionary:
	var o := get_spell(spell)
	if o.is_empty():
		return {}
	var sphere := str(o.get("sphere", ""))
	return {
		"key": book_key_for_spell(spell),
		"name_ru": "Книга: " + str(o.get("ru", spell)),
		"name_en": "Book",
		"quality": "Book",
		"type": sphere,
		"price": 50 + int(o.get("mana_cost", 0)) * 20,
		"weight": 1.0,
		"level": 1,
		"icon": str(BOOK_ICONS.get(sphere, BOOK_ICONS["Fire"])),
		"sphere": sphere,
	}

## The simplest spell of a sphere: minimum mana, attack/heal preferred.
static func simplest_spell_of_sphere(sphere: String) -> String:
	ensure_loaded()
	var best := ""
	var best_key: Array = []
	for name in _db:
		if str(_db[name].get("sphere", "")) != sphere:
			continue
		var o: Dictionary = _db[name]
		var kind := str(o.get("kind", ""))
		var pref := 2
		if kind in ["attack", "area"]:
			pref = 0
		elif kind == "heal":
			pref = 1
		var key := [int(o.get("mana_cost", 0)), pref, int(o.get("damage", 0)), name]
		if best_key.is_empty() or key < best_key:
			best_key = key
			best = name
	return best

## All spells in shop counter order (sphere, then cheaper).
static func catalog_spells() -> Array:
	ensure_loaded()
	var order := {"Fire": 0, "Water": 1, "Air": 2, "Earth": 3, "Astral": 4}
	var out: Array = []
	for name in _db:
		out.append(name)
	out.sort_custom(func(a, b):
		var oa: Dictionary = _db[a]
		var ob: Dictionary = _db[b]
		var sa := int(order.get(str(oa.get("sphere", "")), 9))
		var sb := int(order.get(str(ob.get("sphere", "")), 9))
		if sa != sb:
			return sa < sb
		var ma := int(oa.get("mana_cost", 0))
		var mb := int(ob.get("mana_cost", 0))
		if ma != mb:
			return ma < mb
		return str(a) < str(b))
	return out