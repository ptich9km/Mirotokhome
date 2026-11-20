class_name QuestIcons
extends RefCounted
## Quest icons (22.10): the heads' markers and the quest items. One source of
## truth for the paths used by the panel, the pickup and the marker.
##
## WHERE THE ART LIVES. There is no hand-made art until the player approves
## the AI sheets (tests/gen_quest_art.py -> tests/extract_quest_art.py), so
## every helper returns "" honestly and the caller falls back:
##  * marker - the coloured diamond QuestMarker.color_of(kind), so a head is
##    always visible;
##  * quest card - the item's own icon from item_db, potions/herbs through
##    LootIcons (their item_db icons may be missing);
##  * search spot - the item icon from item_db.
## Once the PNGs land in assets/ui/quest/, all three show them with no code
## change: art is data, not code.
##
## Item icon names match the "icon" field of assets/quests/quest_db.json and
## the "pick" field (which art a found item uses).

const MARKS_DIR := "res://assets/ui/quest/marks/"
const ITEMS_DIR := "res://assets/ui/quest/items/"
const COIN_DIR := "res://assets/ui/quest/coin/"

## Marker kinds: what they mean and how many frames the strip holds.
const MARK_FRAMES := {"available": 4, "ready": 4}

## Gold coin: a sprite too (4 phases of a swaying coin, ai art 22.10). The
## static icon at assets/loot_icons/gold_coin.png stays for the loot pile and
## the HUD counter - LootIcons.gold_icon() is its contract. The animated one
## is shown where the coin is seen moving: the reward row of a quest card.
const COIN_FRAMES := 4
## Frame step of the swaying coin (seconds). Shared by every coin on screen.
const COIN_FRAME_TIME := 0.22

## "pick" of a quest -> quest item icon. One art per class of items.
const PICK_ICON := {
	"quest_scroll": "quest_scroll",
	"quest_amulet": "quest_amulet",
	"quest_book": "quest_book",
	"quest_sword": "quest_sword",
	"quest_armor": "quest_armor",
}

## Class of an item the quest asks for -> quest icon, checked in order. ItemDB
## herbs carry no "icon" field: without this the slot fell back to a generic
## potion jar, which says nothing about what to collect.
const QUEST_ICON_RULES := [
	{"prefix": "Herb ", "icon": "quest_scroll"},
	{"prefix": "Scroll ", "icon": "quest_scroll"},
	{"prefix": "Book ", "icon": "quest_book"},
	{"has": "Amulet", "icon": "quest_amulet"},
]


static func mark_frame(kind: String, index: int) -> Texture2D:
	## Animation frame of a marker; null while the art does not exist.
	var path := mark_frame_path(kind, index)
	if path == "":
		return null
	return load(path) as Texture2D


static func mark_frame_path(kind: String, index: int) -> String:
	if not MARK_FRAMES.has(kind):
		return ""
	var path := "%s%s-%03d.png" % [MARKS_DIR, kind, index]
	return path if ResourceLoader.exists(path) else ""


static func coin_frame_path(index: int) -> String:
	## Frame of the swaying coin ("" while the art does not exist).
	var path := "%sgold_coin-%03d.png" % [COIN_DIR, index]
	return path if ResourceLoader.exists(path) else ""


static func coin_frames() -> Array:
	## All frames of the swaying coin; empty while the art does not exist.
	var out: Array = []
	for i in range(COIN_FRAMES):
		var path := coin_frame_path(i)
		if path == "":
			return []
		out.append(load(path))
	return out


static func coin_frame(index: int) -> Texture2D:
	## One frame by index, the first frame as the fallback.
	var path := coin_frame_path(posmod(index, COIN_FRAMES))
	if path == "":
		path = coin_frame_path(0)
	if path == "":
		return null
	return load(path) as Texture2D


static func coin_icon() -> String:
	## Static coin for a slot that does not animate: the animated face-on frame,
	## otherwise the loot icon every other screen already uses.
	var path := coin_frame_path(0)
	return path if path != "" else LootIcons.gold_icon()


static func has_mark_art(kind: String) -> bool:
	return mark_frame_path(kind, 0) != ""


static func item_icon(icon_name: String) -> String:
	## Path to the quest item icon ("" while the art does not exist).
	if icon_name == "":
		return ""
	var path := ITEMS_DIR + icon_name + ".png"
	return path if ResourceLoader.exists(path) else ""


static func icon_path(icon_name: String) -> String:
	## What to show in a quest card slot: quest art -> item icon -> quest art of
	## the item class -> potion jar.
	## A path rather than a texture, so a test can check the file exists.
	var art := item_icon(icon_name)
	if art != "":
		return art
	var item := ItemDB.find(icon_name)
	if not item.is_empty():
		var own := str(item.get("icon", ""))
		if own != "" and ResourceLoader.exists(own):
			return own
	var by_class := item_icon(item_class_icon(icon_name))
	if by_class != "":
		return by_class
	if item.is_empty():
		return ""
	return LootIcons.icon_for_potion(item, "small")


## Quest icon of an item by its class ("Herb Green Leaf" -> quest_scroll).
static func item_class_icon(item_key: String) -> String:
	# A quest item keeps its base name after the "Quest " mark: match the class
	# on the base, or a quest tome would lose its book icon.
	var key := ItemDB.quest_base(item_key) if ItemDB.is_quest_key(item_key) \
		else str(item_key)
	for rule in QUEST_ICON_RULES:
		var d: Dictionary = rule
		if d.has("prefix") and key.begins_with(str(d["prefix"])):
			return str(d["icon"])
		if d.has("has") and key.contains(str(d["has"])):
			return str(d["icon"])
	return ""


static func icon_texture(icon_name: String) -> Texture2D:
	var path := icon_path(icon_name)
	if path == "":
		return null
	return load(path) as Texture2D


## Icon of the item the player is sent to find (FIND_ITEM): quest art by the
## quest's "pick", otherwise the item icon from item_db.
static func target_icon(pick: String, item_key: String) -> Texture2D:
	var art := item_icon(str(PICK_ICON.get(pick, pick)))
	if art == "":
		art = icon_path(item_key)
	if art == "":
		return null
	return load(art) as Texture2D


## --- Mission sheets of the heads (gameplay missions). -----------------------

## Type of quest ("type" in QuestDB) -> sheet slug. MVP quests have sheets;
## the rest exist for the mission types whose mechanics land later.
static var MISSION_SLUG_BY_TYPE := {
	"FIND_ITEM": "find_items",
	"GATHER": "alchemy_gather",
	"KILL_SPECIES": "destroy",
	"KILL_GROUP": "destroy",
	"KILL_TARGET": "boss_kill",
	## No animated sheet of their own yet: an urgent hunt is a fight, and a
	## delivery is a wagon - a fitting sign beats the legacy 32x32 icon.
	"URGENT": "destroy",
	"DELIVER": "caravan",
	"escort": "escort",
	"build_repair": "build_repair",
	"caravan": "caravan",
	"faction_war": "faction_war",
	"story_chain": "story_chain",
}

## Template id -> sheet, for quests whose TYPE is too coarse to tell them apart.
## "gather_tags" is a GATHER quest like "gather_herbs", but it hunts the rival
## faction for trophy tags, not herbs - the daisy read as weed picking (player,
## 20.11: "это фракционная война, где стена щитов и камни").
const MISSION_SLUG_BY_TEMPLATE := {
	"gather_tags": "faction_war",
}

## Sheet of a whole quest record: a scenario stage always wears the golden key
## (it is one story, not a chore of its own type), then the template override,
## then the type.
static func mission_slug_for_quest(q: Dictionary) -> String:
	if str(q.get("chain_id", "")) != "":
		return "story_chain"
	var by_template: String = MISSION_SLUG_BY_TEMPLATE.get(str(q.get("template", "")), "")
	if by_template != "":
		return by_template
	return mission_slug_for_type(str(q.get("type", "")))

const MISSION_DIR := "res://assets/quests/missions/"
const MISSION_FRAMES := 4
const MISSION_FRAME_TIME := 0.22
## Minimap sign: a flat 16x16 glyph per mission type, drawn by
## tests/gen_minimap_signs.py. The 64x64 mission frames are painterly and turn
## into a dark smudge at minimap scale (measured 20.11), so the map gets its own
## simplified set. The glyph carries its own 1 px outline, so nothing is scaled
## at runtime.
const MINIMAP_DIR := "res://assets/quests/missions/minimap/"
const MINIMAP_ICON_SIZE := 16
## Cache: the minimap stamps these signs every redraw (0.25 s), and load() per
## stamp would be wasted work.
static var _minimap_cache: Dictionary = {}


static func mission_minimap_path(slug: String) -> String:
	if slug == "":
		return ""
	var path := "%s%s.png" % [MINIMAP_DIR, slug]
	return path if ResourceLoader.exists(path) else ""


## Still sign of a mission for the minimap; null while the glyph is missing.
static func mission_minimap_icon(slug: String) -> Image:
	if slug == "":
		return null
	if _minimap_cache.has(slug):
		return _minimap_cache[slug]
	var path := mission_minimap_path(slug)
	if path == "":
		return null
	var tex := load(path) as Texture2D
	var img: Image = tex.get_image() if tex != null else null
	if img == null:
		return null
	_minimap_cache[slug] = img
	return img


static func mission_slug_for_type(t: String) -> String:
	return MISSION_SLUG_BY_TYPE.get(t, "")


static func mission_frame_path(slug: String, index: int) -> String:
	if slug == "":
		return ""
	var path := "%s%s-%03d.png" % [MISSION_DIR, slug, index]
	return path if ResourceLoader.exists(path) else ""


static func mission_frames(slug: String) -> Array:
	## Frames of the sheet; empty while the art does not exist (same contract
	## as mark_frame_path: "" and [] when nothing is there).
	var out: Array = []
	for i in range(MISSION_FRAMES):
		var path := mission_frame_path(slug, i)
		if path == "":
			return []
		out.append(load(path) as Texture2D)
	return out


static func has_mission_art(slug: String) -> bool:
	return mission_frame_path(slug, 0) != ""
