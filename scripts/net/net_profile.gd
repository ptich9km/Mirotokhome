class_name NetProfile
extends RefCounted
## Persistent co-op characters (22.11).
##
## The world of a co-op session is built from scratch every time (a fresh seed,
## as the player asked: "a new session starts the seed from zero"), but the
## CHARACTER survives: skills, spells, gold, equipment and the bag are stored on
## the machine of the player who owns them. The server keeps its heroes, the
## client keeps its own — nobody's file is on the other machine.
##
## The stored shape is deliberately the same blob the single-player save writes
## for a hero (`SaveSystem.build_payload`), so `Player` restores it through the
## existing `Game.hero_save` path without a second code path.

const PATH := "user://net_characters.json"
const VERSION := 1

## The file is a list, not a dictionary: the order is the display order and the
## newest hero sits first.
static func load_all() -> Array:
	var data := _read()
	var list: Variant = data.get("characters", [])
	if not (list is Array):
		return []
	var out: Array = []
	for raw in list:
		if raw is Dictionary and str((raw as Dictionary).get("name", "")) != "":
			out.append(raw)
	return out

static func find(hero_name: String) -> Dictionary:
	for p in load_all():
		if str(p.get("name", "")) == hero_name:
			return p
	return {}

## Add or replace a hero with the same name. A new hero replaces an older one:
## the name is the identity of a character in this game (there is no level-up
## screen where two "Айвен" would be told apart).
static func upsert(profile: Dictionary) -> void:
	if profile.is_empty() or str(profile.get("name", "")) == "":
		return
	var list := load_all()
	var replaced := false
	for i in range(list.size()):
		if str((list[i] as Dictionary).get("name", "")) == str(profile.get("name", "")):
			list[i] = profile
			replaced = true
			break
	if not replaced:
		list.insert(0, profile)
	_write({"version": VERSION, "characters": list})

static func remove(hero_name: String) -> void:
	var kept: Array = []
	for p in load_all():
		if str(p.get("name", "")) != hero_name:
			kept.append(p)
	_write({"version": VERSION, "characters": kept})

static func _read() -> Dictionary:
	if not FileAccess.file_exists(PATH):
		return {}
	var f := FileAccess.open(PATH, FileAccess.READ)
	if f == null:
		return {}
	var text := f.get_as_text()
	f.close()
	var parsed: Variant = JSON.parse_string(text)
	return parsed if parsed is Dictionary else {}

static func _write(data: Dictionary) -> void:
	var f := FileAccess.open(PATH, FileAccess.WRITE)
	if f == null:
		push_error("NetProfile: cannot write " + PATH)
		return
	f.store_string(JSON.stringify(data, "\t"))
	f.close()

## A hero created on the character screen: no save blob yet, so the first spawn
## grants the starter set exactly like a normal new game.
static func from_new_game() -> Dictionary:
	return {
		"version": VERSION,
		"name": str(Game.hero_name),
		"class": str(Game.hero_class),
		"gender": str(Game.hero_gender),
		"race": str(Game.hero_race),
		"character_id": str(Game.hero_character_id),
		"portrait": str(Game.hero_portrait),
		"stats": Game.hero_stats.duplicate(true),
		"start_book": str(Game.hero_start_book),
		"primary": str(Game.hero_primary_skill),
		"aux": str(Game.hero_aux_skill),
		"save": {},
		"hotbar": Game.hotbar.duplicate(true),
		"stamp": int(Time.get_unix_time_from_system()),
	}

## Snapshot of the LIVE hero. Called on death (items are lost — the file must
## agree), on leaving the world and on a timer, so the next session inherits the
## state that was actually reached.
static func capture(player) -> Dictionary:
	if player == null or not is_instance_valid(player):
		return {}
	var save := {
		"max_hp": int(player.get("max_hp")),
		"max_mana": int(player.get("max_mana")),
		"current_hp": int(player.get("current_hp")),
		"current_mana": int(player.get("current_mana")),
		"gold": int(player.get("gold")),
		"inventory": (player.get("inventory") as Array).duplicate(),
		"equipped": (player.get("equipped") as Dictionary).duplicate(true),
		"experience": (player.get("experience") as Dictionary).duplicate(true),
		"known_spells": (player.get("known_spells") as Dictionary).duplicate(true),
		"known_recipes": (player.get("known_recipes") as Array).duplicate(),
		"sphere_books": (player.get("sphere_books") as Dictionary).duplicate(true),
	}
	return {
		"version": VERSION,
		"name": str(Game.hero_name),
		"class": str(Game.hero_class),
		"gender": str(Game.hero_gender),
		"race": str(Game.hero_race),
		"character_id": str(Game.hero_character_id),
		"portrait": str(Game.hero_portrait),
		"stats": Game.hero_stats.duplicate(true),
		"start_book": str(Game.hero_start_book),
		"primary": str(Game.hero_primary_skill),
		"aux": str(Game.hero_aux_skill),
		"save": save,
		"hotbar": Game.hotbar.duplicate(true),
		"stamp": int(Time.get_unix_time_from_system()),
	}

## Put a stored hero back into the Game statics. MUST run after any
## `StartSetup.apply()`/`clear_hero_save()`: those wipe the hero blob.
static func apply(profile: Dictionary) -> void:
	if profile.is_empty():
		return
	Game.hero_name = str(profile.get("name", Game.hero_name))
	Game.hero_class = str(profile.get("class", Game.hero_class))
	Game.hero_gender = str(profile.get("gender", Game.hero_gender))
	Game.hero_race = str(profile.get("race", Game.hero_race))
	Game.hero_character_id = str(profile.get("character_id", Game.hero_character_id))
	Game.hero_portrait = str(profile.get("portrait", Game.hero_portrait))
	var stats: Variant = profile.get("stats", {})
	Game.hero_stats = (stats as Dictionary).duplicate(true) if stats is Dictionary else {}
	Game.hero_start_book = str(profile.get("start_book", ""))
	Game.hero_primary_skill = str(profile.get("primary", ""))
	Game.hero_aux_skill = str(profile.get("aux", ""))
	var save: Variant = profile.get("save", {})
	Game.hero_save = (save as Dictionary).duplicate(true) if save is Dictionary else {}
	var hotbar: Variant = profile.get("hotbar", {})
	Game.hotbar = (hotbar as Dictionary).duplicate(true) if hotbar is Dictionary else {}
	Game.pending_party = []
	Game.hero_dead = false

## One line for the picker: class, race, gold and how much is learned.
static func summary(p: Dictionary) -> String:
	var cls := str(p.get("class", "warrior"))
	var class_label := Loc.t("ui.char.class.mage") if cls == "mage" else Loc.t("ui.char.class.warrior")
	var race_label := Lore.faction_label(str(p.get("race", "")))
	var save: Dictionary = p.get("save", {}) if p.get("save") is Dictionary else {}
	var gold := int(save.get("gold", 0))
	var spells := 0
	if save.get("known_spells") is Dictionary:
		spells = (save["known_spells"] as Dictionary).size()
	return Loc.f("ui.net.char.summary", [class_label, race_label, gold, spells])
