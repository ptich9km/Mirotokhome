class_name QuestDB
extends RefCounted
## Town head quest templates (assets/quests/quest_db.json).
##
## DATA ONLY, plus the generation of ONE offer from a template: types,
## counts per difficulty, texts, rewards. World state (what was offered,
## what was taken) lives in QuestSystem - not here, and not in the map.
##
## Project rule: data lives in JSON, not in hardcoded dictionaries. A broken
## file is a push_error and an empty set; the game goes on without quests.

const DB_PATH := "res://assets/quests/quest_db.json"

## MVP types. The rest of the original's types (escort, interception, guard
## massacre, undead summon) need mechanics the game does not have yet.
const TYPES := ["KILL_SPECIES", "KILL_GROUP", "KILL_TARGET", "GATHER",
	"FIND_ITEM", "DELIVER", "URGENT"]

## Beasts from MapGenerator.gray_species() that have an English singular name.
## A target beast is ONE concrete monster: its name goes into the title (%s)
## and the text, so a missing key just means the species is never a target.
const BEAST_SINGULAR := {
	"wolf": "wolf", "dino": "lizard", "squirrel": "mad squirrel",
	"bee": "swarm of bees", "bat": "bat", "ghost": "ghost",
	"dragon": "dragon", "cannibal": "ogre", "troll": "troll",
	"succubus": "succubus",
}

## Plural forms for "Put down %d %s". Redundant in English, kept so the JSON
## templates can address singular and plural through one table.
const BEAST_PLURAL_ACC := {
	"wolf": "wolves", "dino": "lizards", "squirrel": "squirrels",
	"bee": "bees", "bat": "bats", "ghost": "ghosts",
	"dragon": "dragons", "cannibal": "ogres", "troll": "trolls",
	"succubus": "succubi",
}

const DIFFICULTY_NAMES := ["easy", "normal", "hard"]

## populate keys whose value is a number and therefore needs %d in the text.
const NUMERIC_POPULATE := ["count", "minutes"]

## populate keys whose value is a number written as a word (%s).
const WORD_POPULATE := ["count_word"]

## Case of the plural species form per template, separately for the title and
## for the text sentence: a hunt title names the beasts as an object ("Hunt for
## wolves"), while its sentence may need the subject form ("wolves at the
## gates"). A template that is not listed takes the accusative in both, which
## is what a kill order does ("put down five wolves").
const SPECIES_FORM := {
	"kill_species": {"title": "acc", "text": "nom"},
	"urgent_hunt": {"title": "acc", "text": "nom"},
	"chain_cas_a1": {"title": "acc", "text": "nom"},
	"chain_sac_b1": {"title": "acc", "text": "nom"},
	"chain_sac_b5": {"title": "acc", "text": "nom"},
	"chain_qig_d5": {"title": "acc", "text": "nom"},
}

## Chain stages (engine + chain A, 20.11). A stage is an ordinary template that
## additionally names its chain, its stage, the step number, a FIXED difficulty
## (the zone must not reprice a stage of a story line) and what happens when it
## is turned in. Stages never enter the rotation: pick_template skips them.
const EFFECT_OPS := ["hero_rep", "archmage_power", "item", "flag", "feed",
	"sim_relation", "city_loyalty", "outpost_owner"]

## Conditions a stage (or a chain) may put on being offered. Unknown keys are a
## load error: a typo must not silently make a gate always pass.
const REQUIRES_KEYS := ["zone", "cities_min", "day_min", "hero_rep",
	"outposts_min"]

static var _templates: Array[Dictionary] = []
static var _chains: Array[Dictionary] = []
static var _item_names: Dictionary = {}
static var _difficulty_gold: Array = [25, 50, 90]
static var _difficulty_mult: Array = [1.0, 1.8, 3.0]
static var _loaded := false


static func clear_cache() -> void:
	_templates = []
	_chains = []
	_item_names = {}
	_difficulty_gold = [25, 50, 90]
	_difficulty_mult = [1.0, 1.8, 3.0]
	_loaded = false


static func _load() -> void:
	if _loaded:
		return
	_loaded = true
	var f := FileAccess.open(DB_PATH, FileAccess.READ)
	if f == null:
		push_error("QuestDB: cannot open " + DB_PATH)
		return
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if not (parsed is Dictionary):
		push_error("QuestDB: %s is not a JSON object" % DB_PATH)
		return
	var db: Dictionary = parsed
	if db.get("difficulty_gold") is Array:
		_difficulty_gold = db["difficulty_gold"]
	if db.get("difficulty_mult") is Array:
		_difficulty_mult = db["difficulty_mult"]
	if db.get("quest_item_names") is Dictionary:
		_item_names = db["quest_item_names"]
	var list: Variant = db.get("templates", [])
	if not (list is Array):
		push_error("QuestDB: templates is not an array")
		return
	for raw in list:
		var t := _validate(raw)
		if not t.is_empty():
			_templates.append(t)
	var chain_list: Variant = db.get("chains", [])
	if chain_list is Array:
		for raw_chain in chain_list:
			var c := _validate_chain(raw_chain)
			if not c.is_empty():
				_chains.append(c)
	_finalize_chains()


## A chain record: the story line itself. Its stages live in templates[].
static func _validate_chain(raw: Variant) -> Dictionary:
	if not (raw is Dictionary):
		push_error("QuestDB: chain is not an object")
		return {}
	var d: Dictionary = raw
	var id := str(d.get("id", ""))
	if id == "":
		push_error("QuestDB: chain without id")
		return {}
	var race := str(d.get("race", ""))
	if not MapGenerator.CITY_POPULATION.has(race):
		push_error("QuestDB: chain %s - unknown race '%s'" % [id, race])
		return {}
	var title_key := str(d.get("title_key", ""))
	if title_key == "" or not Loc.has_key(title_key):
		push_error("QuestDB: chain %s - unknown title_key '%s'" % [id, title_key])
		return {}
	var stages: Variant = d.get("stages", [])
	if not (stages is Array) or (stages as Array).is_empty():
		push_error("QuestDB: chain %s - stages must be a non-empty array" % id)
		return {}
	if not _requires_valid(d.get("requires", {}), "chain " + id):
		return {}
	return d


## Every stage of a chain exists, and every stage belongs to a real chain.
## Runs after both lists are read: a stage cannot be checked before its chain.
static func _finalize_chains() -> void:
	var keep: Array[Dictionary] = []
	for t in _templates:
		var chain_id := str(t.get("chain", ""))
		if chain_id == "":
			keep.append(t)
			continue
		var c := chain(chain_id)
		if c.is_empty():
			push_error("QuestDB: template %s - unknown chain '%s'"
				% [str(t.get("id", "")), chain_id])
			continue
		var stages: Array = c.get("stages", [])
		if not stages.has(str(t.get("stage", ""))):
			push_error("QuestDB: template %s - stage '%s' is not listed in chain %s"
				% [str(t.get("id", "")), str(t.get("stage", "")), chain_id])
			continue
		keep.append(t)
	_templates = keep


static func _requires_valid(raw: Variant, where: String) -> bool:
	if raw == null:
		return true
	if not (raw is Dictionary):
		push_error("QuestDB: %s - requires is not an object" % where)
		return false
	for key in (raw as Dictionary).keys():
		if not REQUIRES_KEYS.has(str(key)):
			push_error("QuestDB: %s - unknown requires key '%s' (known: %s)"
				% [where, str(key), ", ".join(REQUIRES_KEYS)])
			return false
	return true


## Fields a chain stage adds on top of an ordinary template. Numbers come from
## JSON as floats, so they are narrowed here and the rest of the code can rely
## on ints.
static func _validate_stage_fields(d: Dictionary, id: String) -> bool:
	var stage := str(d.get("stage", ""))
	if stage == "":
		push_error("QuestDB: %s - a chain template needs a stage id" % id)
		return false
	var order_raw: Variant = d.get("order", 1)
	if not (order_raw is float or order_raw is int) or int(order_raw) < 1:
		push_error("QuestDB: %s - order must be a positive number" % id)
		return false
	var diff_raw: Variant = d.get("difficulty", 1)
	if not (diff_raw is float or diff_raw is int) or int(diff_raw) < 1 or int(diff_raw) > 3:
		push_error("QuestDB: %s - difficulty must be 1..3" % id)
		return false
	d["order"] = int(order_raw)
	d["difficulty"] = int(diff_raw)
	if not _requires_valid(d.get("requires", {}), id):
		return false
	var next_raw: Variant = d.get("next", [])
	if not (next_raw is Array):
		push_error("QuestDB: %s - next must be an array of stage ids" % id)
		return false
	var effects_raw: Variant = d.get("effects", [])
	if not (effects_raw is Array):
		push_error("QuestDB: %s - effects must be an array" % id)
		return false
	for raw in (effects_raw as Array):
		if not _effect_valid(raw, id):
			return false
	return true


## One effect: op from the closed list plus the fields that op needs. A broken
## effect is a load error: a quest that silently pays nothing is a bug report.
static func _effect_valid(raw: Variant, id: String) -> bool:
	if not (raw is Dictionary):
		push_error("QuestDB: %s - effect is not an object" % id)
		return false
	var e: Dictionary = raw
	var op := str(e.get("op", ""))
	if not EFFECT_OPS.has(op):
		push_error("QuestDB: %s - unknown effect op '%s' (known: %s)"
			% [id, op, ", ".join(EFFECT_OPS)])
		return false
	match op:
		"hero_rep":
			var race := str(e.get("race", ""))
			if not MapGenerator.CITY_POPULATION.has(race):
				push_error("QuestDB: %s - effect %s: unknown race '%s'" % [id, op, race])
				return false
			# A negative shift is the PRICE of a choice (chain B tags), not a
			# negative reward: it must be visible in the stage text.
			var amount: Variant = e.get("amount", 0)
			if not (amount is float or amount is int) or float(amount) == 0.0:
				push_error("QuestDB: %s - effect %s: amount must be non-zero" % [id, op])
				return false
		"archmage_power":
			var race := str(e.get("race", ""))
			if not MapGenerator.CITY_POPULATION.has(race):
				push_error("QuestDB: %s - effect %s: unknown race '%s'" % [id, op, race])
				return false
			var amount: Variant = e.get("amount", 0)
			if not (amount is float or amount is int) or float(amount) <= 0.0:
				push_error("QuestDB: %s - effect %s: amount must be positive" % [id, op])
				return false
		"sim_relation":
			for side in ["a", "b"]:
				var r := str(e.get(side, ""))
				if not MapGenerator.CITY_POPULATION.has(r):
					push_error("QuestDB: %s - effect sim_relation: unknown race '%s'"
						% [id, r])
					return false
			var amount: Variant = e.get("amount", 0)
			if not (amount is float or amount is int) or float(amount) == 0.0:
				push_error("QuestDB: %s - effect sim_relation: amount must be non-zero" % id)
				return false
		"city_loyalty":
			var race := str(e.get("race", ""))
			if not MapGenerator.CITY_POPULATION.has(race):
				push_error("QuestDB: %s - effect city_loyalty: unknown race '%s'" % [id, race])
				return false
			var amount: Variant = e.get("amount", 0)
			if not (amount is float or amount is int) or float(amount) <= 0.0:
				push_error("QuestDB: %s - effect city_loyalty: amount must be positive" % id)
				return false
		"outpost_owner":
			var faction := str(e.get("faction", ""))
			if not MapGenerator.CITY_POPULATION.has(faction):
				push_error("QuestDB: %s - effect outpost_owner: unknown faction '%s'"
					% [id, faction])
				return false
		"item":
			var key := str(e.get("key", ""))
			if key == "" or ItemDB.find(key).is_empty():
				push_error("QuestDB: %s - effect item: unknown item '%s'" % [id, key])
				return false
		"flag":
			if str(e.get("key", "")) == "":
				push_error("QuestDB: %s - effect flag without a key" % id)
				return false
		"feed":
			var key := str(e.get("key", ""))
			if key == "" or not Loc.has_key(key):
				push_error("QuestDB: %s - effect feed: unknown loc key '%s'" % [id, key])
				return false
	return true


static func _validate(raw: Variant) -> Dictionary:
	if not (raw is Dictionary):
		push_error("QuestDB: template is not an object")
		return {}
	var d: Dictionary = raw
	var id := str(d.get("id", ""))
	var type := str(d.get("type", ""))
	if id == "":
		push_error("QuestDB: template without id")
		return {}
	if not TYPES.has(type):
		push_error("QuestDB: unknown type '%s' in template %s" % [type, id])
		return {}
	var chain_id := str(d.get("chain", ""))
	if chain_id != "" and not _validate_stage_fields(d, id):
		return {}
	var counts: Variant = d.get("count_by_difficulty", [])
	if not (counts is Array) or (counts as Array).size() < 3:
		push_error("QuestDB: %s - count_by_difficulty must hold 3 numbers" % id)
		return {}
	var needs_items := type in ["GATHER", "FIND_ITEM", "DELIVER"]
	var pool: Array = []
	# Пакет E: квест на бирки не держит item_pool — предмет выбирается по
	# фракции-сопернику города (tags_of_rival), поэтому пустой пул законен.
	if needs_items and not bool(d.get("tags_of_rival", false)):
		var raw_pool: Variant = d.get("item_pool", [])
		if not (raw_pool is Array) or (raw_pool as Array).is_empty():
			push_error("QuestDB: %s - type %s without item_pool" % [id, type])
			return {}
		for key in raw_pool:
			if ItemDB.find(str(key)).is_empty():
				push_error("QuestDB: %s - unknown item '%s'" % [id, key])
				return {}
			if quest_item_name(str(key)) == "":
				push_error("QuestDB: %s - item '%s' has no quest_item_names entry"
					% [id, key])
				return {}
			pool.append(str(key))
	d["item_pool"] = pool
	# Player-visible text lives in the locale table, never in this file: the
	# template only names the keys, and a missing key would show up raw on a
	# quest card.
	for field in ["title_key", "text_key"]:
		var key := str(d.get(field, ""))
		if key == "" or not Loc.has_key(key):
			push_error("QuestDB: %s - unknown %s '%s'" % [id, field, key])
			return {}
	# Optional line for a hero of another race: same placeholder contract as the
	# main text, otherwise the card would print a raw %s at a foreign hero.
	var foreign_key := str(d.get("text_key_foreign", ""))
	if foreign_key != "" and not Loc.has_key(foreign_key):
		push_error("QuestDB: %s - unknown text_key_foreign '%s'" % [id, foreign_key])
		return {}
	# populate fixes the ORDER of substitutions and its keys also fix the
	# PLACEHOLDER KIND: a number goes in as %d, a text as %s (a number the words
	# around it need as a word - count_word - goes in as %s too). It fills the
	# TEXT in order; the title reuses the first text key of that order through
	# its only %s. A mismatch would break the runtime formatter ("a number is
	# required") and print raw %s, so such a template is not loaded at all.
	var populate: Variant = d.get("populate", [])
	var order: Array = populate if populate is Array else []
	var text := _text_for_locale(str(d["text_key"]))
	var title_src := _text_for_locale(str(d["title_key"]))
	if not placeholders_fit(text, order):
		push_error("QuestDB: %s - text placeholders do not match populate %s"
			% [id, order])
		return {}
	if foreign_key != "":
		var foreign_text := _text_for_locale(foreign_key)
		if not placeholders_fit(foreign_text, order):
			push_error("QuestDB: %s - foreign text placeholders do not match populate %s"
				% [id, order])
			return {}
	if not placeholders_fit(title_src, order, true):
		push_error("QuestDB: %s - the title needs one text placeholder and a text populate key"
			% id)
		return {}
	return d


## True when the placeholders of the template text, read left to right, are
## exactly the populate keys and match their kind: %d for a number, %s for a
## text. Any other specifier, or a literal % glued to text, is a mismatch too.
##
## A "title" holds either no placeholder at all or one %s, which takes the
## first TEXT key of `order` (a title never shows a bare number).
static func placeholders_fit(text: String, order: Array, title := false) -> bool:
	var found: Array = []
	var i := text.find("%")
	while i >= 0:
		if i + 1 >= text.length():
			return false
		var code := text.substr(i + 1, 1)
		if code != "d" and code != "s":
			return false
		found.append(code)
		i = text.find("%", i + 2)
	if title:
		if found.is_empty():
			return true
		if found.size() != 1 or str(found[0]) != "s":
			return false
		for k in order:
			if not NUMERIC_POPULATE.has(str(k)) and not WORD_POPULATE.has(str(k)):
				return true
		return false
	if found.size() != order.size():
		return false
	for k in range(order.size()):
		var numeric := NUMERIC_POPULATE.has(str(order[k]))
		if numeric != (str(found[k]) == "d"):
			return false
	return true


## All locale versions of a key, the current language first: the card has to
## pick the one that fits this language, and a version with other placeholders
## must not be shown.
static func text_versions(key: String) -> Array:
	var out: Array = []
	for code in Loc.locales_in_use():
		var value := Loc.text_in(key, code)
		if value != "" and not out.has(value):
			out.append(value)
	return out


static func _text_for_locale(key: String) -> String:
	var versions := text_versions(key)
	return "" if versions.is_empty() else str(versions[0])


## Quest name of a quest item in the current locale, with the class word
## ("herb 'Green Leaf'"). Empty when the key has no entry: a missing name must never fall back to the
## shop name of item_db, which may end with a trait such as "4.4".
##
## `short` gives the bare name without the class word, which a title needs: a
## title already says what is being searched for.
static func quest_item_name(item_key: String, short := false) -> String:
	_load()
	var entry: Variant = _item_names.get(item_key, {})
	if not (entry is Dictionary):
		return ""
	var picked := str((entry as Dictionary).get(Loc.locale(), ""))
	if picked == "":
		picked = str((entry as Dictionary).get("ru", ""))
	if short:
		var field := "%s_short" % Loc.locale()
		var bare := str((entry as Dictionary).get(field, ""))
		if bare != "":
			return bare
	return picked


static func templates() -> Array[Dictionary]:
	_load()
	return _templates


static func template(id: String) -> Dictionary:
	for t in templates():
		if str(t.get("id", "")) == id:
			return t
	return {}


static func chains() -> Array[Dictionary]:
	_load()
	return _chains


static func chain(id: String) -> Dictionary:
	if id == "":
		return {}
	_load()
	for c in _chains:
		if str(c.get("id", "")) == id:
			return c
	return {}


## One stage of a chain by its own stage id ("a2").
static func stage(chain_id: String, stage_id: String) -> Dictionary:
	if chain_id == "" or stage_id == "":
		return {}
	for t in templates():
		if str(t.get("chain", "")) == chain_id \
				and str(t.get("stage", "")) == stage_id:
			return t
	return {}


static func is_chain_template(template_id: String) -> bool:
	return str(template(template_id).get("chain", "")) != ""


## Reward/count multiplier for difficulty 1..3.
static func difficulty_mult(difficulty: int) -> float:
	_load()
	var i := clampi(difficulty - 1, 0, _difficulty_mult.size() - 1)
	return float(_difficulty_mult[i])


static func base_gold(difficulty: int) -> int:
	_load()
	var i := clampi(difficulty - 1, 0, _difficulty_gold.size() - 1)
	return int(_difficulty_gold[i])


## Templates available at this difficulty: min_difficulty and tags (DELIVER
## needs at least two towns).
static func templates_for(zone: String, difficulty: int, city_count: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for t in templates():
		# A chain stage is offered by its chain, never by the rotation.
		if str(t.get("chain", "")) != "":
			continue
		if difficulty < int(t.get("min_difficulty", 1)):
			continue
		var tags: Array = t.get("tags", [])
		if tags.has("needs_two_cities") and city_count < 2:
			continue
		out.append(t)
	return out


## Weighted template pick. excluded - ids not offered right now (already in
## this town's offers or already taken).
static func pick_template(rng: RandomNumberGenerator, zone: String,
		difficulty: int, city_count: int, excluded: Array) -> Dictionary:
	var pool := templates_for(zone, difficulty, city_count)
	var total := 0
	for t in pool:
		if excluded.has(str(t.get("id", ""))):
			continue
		total += maxi(1, int(t.get("weight", 1)))
	if total <= 0:
		return {}
	var roll := rng.randi_range(1, total)
	for t in pool:
		if excluded.has(str(t.get("id", ""))):
			continue
		roll -= maxi(1, int(t.get("weight", 1)))
		if roll <= 0:
			return t
	return {}


## Count for one template at a difficulty, with a little jitter.
static func count_for(template_d: Dictionary, difficulty: int,
		rng: RandomNumberGenerator) -> int:
	var counts: Array = template_d.get("count_by_difficulty", [1, 1, 1])
	var base := int(counts[clampi(difficulty - 1, 0, counts.size() - 1)])
	if base <= 1:
		return base
	return maxi(1, base + rng.randi_range(-1, 1))


## Raid size of an URGENT quest: 4-6 beasts, never the generic +-1 jitter.
## A raid of three read as a bug to the player (20.11: "я же говорил пул 4-6"),
## and the template's own counts are 4/5/6.
static func urgent_count(template_d: Dictionary, difficulty: int,
		rng: RandomNumberGenerator) -> int:
	return clampi(count_for(template_d, difficulty, rng), 4, 6)


## Gray set of the needed tier: "monsters/wolf_t2".
##
## `species` is the beast ("wolf"), NOT a set: the tier comes from the zone
## band plus the difficulty shift, and MapGenerator builds the set name.
static func gray_set_for_species(species: String, difficulty: int,
		zone: String, rng: RandomNumberGenerator) -> String:
	var band: Array = MapGenerator.GRAY_TIER_BAND.get(zone, MapGenerator.GRAY_TIER_BAND["mid"])
	var lo := int(band[0])
	var hi := int(band[1])
	var shift := difficulty - 1
	var tier := clampi(lo + shift + rng.randi_range(0, 1), lo, hi)
	return MapGenerator.gray_set_name(species, tier)


## Species that can become a hunt target at this zone and difficulty.
static func species_for_quest(zone: String, difficulty: int,
		rng: RandomNumberGenerator) -> Array:
	var band: Array = MapGenerator.GRAY_TIER_BAND.get(zone, MapGenerator.GRAY_TIER_BAND["mid"])
	var shift := difficulty - 1
	var lo := int(band[0])
	var hi := int(band[1])
	var out: Array = []
	for sp in MapGenerator.gray_species():
		var tier := clampi(lo + shift + rng.randi_range(0, 1), lo, hi)
		if UnitDB.has(MapGenerator.gray_set_name(str(sp), tier)):
			out.append(str(sp))
	return out


## Set of one concrete target monster (KILL_TARGET): same species at the top
## tier of the zone - the pack leader must be tougher than the rest.
static func target_set_for_species(species: String, zone: String) -> String:
	var band: Array = MapGenerator.GRAY_TIER_BAND.get(zone, MapGenerator.GRAY_TIER_BAND["mid"])
	var set_name := MapGenerator.gray_set_name(species, int(band[1]))
	if UnitDB.has(set_name):
		return set_name
	return MapGenerator.gray_set_name(species, int(band[0]))


## The plural form to use for one template: "title" or "text", one of "nom"
## and "acc". QuestSystem._fill asks per card part, so the header and the
## sentence inside it may disagree on the case.
static func species_form(template_id: String, mode: String) -> String:
	var entry: Variant = SPECIES_FORM.get(template_id, {})
	if entry is Dictionary:
		return str((entry as Dictionary).get(mode, "acc"))
	return "acc"


## Species name for a quest text: the localized singular ("wolf"), the English
## table as a fallback. A Russian quest card must not read "wolves".
static func species_title(species: String) -> String:
	var loc_key := "ui.quest.beast." + species
	if Loc.has_key(loc_key):
		return Loc.t(loc_key)
	return str(BEAST_SINGULAR.get(species, species))


## Species plural in the accusative, the form "Put down %d %s" needs (a direct
## object); English has the bare plural.
static func species_plural_acc(species: String) -> String:
	return species_plural(species, "acc")


## Plural species form with the case the template needs: "nom" for a subject
## ("Hunt: wolves"), "acc" for an object ("Put down five wolves"). English has
## one plural for both.
static func species_plural(species: String, form: String) -> String:
	var suffix := "" if form == "acc" else "_" + form
	var loc_key := "ui.quest.beast_pl" + suffix + "." + species
	if Loc.has_key(loc_key):
		return Loc.t(loc_key)
	return str(BEAST_PLURAL_ACC.get(species, species))


## Faction whose reputation the town's quest pays into. Generator city races
## are "humans"/"ork"/... - the same keys MapGenerator.CITY_POPULATION has.
static func faction_of_race(race: String) -> String:
	return race if MapGenerator.CITY_POPULATION.has(race) else ""
