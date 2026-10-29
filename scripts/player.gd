extends CharacterBody2D
class_name Player

# Primary stats (the original Allods 2 system)
@export var body: int = 10
@export var mind: int = 10
@export var agility: int = 10
@export var spirit: int = 10
# Weapon and magic skills (0-100, basic for now)
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

# CRAFT skills (workshop, 07.10). They grow ONLY from crafting — the school does
# not have them, otherwise buying with gold would devalue the craft itself. They are not
# added to the school also because school_ui_smoke.gd:98 hardcodes
# _train_buttons[5]; inserting into the list would break the test.
@export var smithing_skill: int = 0
@export var tailoring_skill: int = 0
@export var alchemy_skill: int = 0
@export var mastering_skill: int = 0

var max_hp: int = 100
var max_mana: int = 50
var current_hp: int
var current_mana: int
var state: String = "idle"
var attack_target: Node2D = null
var attack_cooldown: float = 0.0
var _impact_timer := -1.0            # countdown to the strike frame (wind-up); <0 = no strike in flight
var _pending_attack_damage := 0      # damage of the current wind-up (applied at the moment of the strike)
var _swing_target: Node2D = null     # wind-up target (a snapshot); impact hits THAT target, not the live one
var move_speed: float = 120.0
var _path: Array = []        # route (world points — cell centres), without "ice"
var _pending_cast: Dictionary = {}   # current spell preparation (cast_time)
## One-shot "cast wind-up": after a spell is applied (book/scroll/auto)
## we play the whole attack block — the mage raises and lowers the staff, while the magic
## flies out of the character's centre. <=0 = no animation.
var _cast_swing_left := 0.0
var _stuck_frames := 0
var _repath_timer := 0.0

# --- Economy (P0): gold and the inventory ---
var gold: int = 20  # overridden from GameConfig [economy] start_gold in _ready
var inventory: Array = []   # item_db item keys ("Common iron Long Sword", "Potion ...")
## Equipped items: slot ("weapon"/"shield"/"head"/"cloak"/"body"/"hands"/
## "feet"/"amulet"/"ring1"/"ring2") -> item_db key (see ItemDB.EQUIP_SLOTS).
## Before, equipment changed ONLY the animation set (armor_kind/weapon/has_shield) and
## did not remember which item was worn — so get_defense/get_attack/get_absorption
## used pure attribute formulas, and heavy armour with defense 14 gave exactly
## as much as wearing none.
var equipped: Dictionary = {}

# --- Skill experience (as in the developers' UnityAllods/ROM2): ---
# the skill grows with experience: exp = (1.1^skill - 1) * 1000; skill = log_1.1(exp/1000 + 1).
# Experience is given for weapon hits and magic use (by sphere/skill).
const SKILL_NAMES := [
	"blade", "axe", "bludgeon", "pike", "shooting",
	"fire", "water", "air", "earth", "astral",
	"smithing", "tailoring", "alchemy", "mastering",
]
var experience := {}        # name -> experience points for the skill
const UNIT_EXP_BASE := 100  # target experience multiplier (Template.Experience in the original)

## Experience base for damage/kill — from config [progression] unit_exp_base.
## The constant above remains as a fallback value and an override for tests.
func _unit_exp_base() -> int:
	var v := GameConfig.geti("progression", "unit_exp_base")
	return UNIT_EXP_BASE if v <= 0 else v

## Experience points corresponding to a skill level (the inverse formula).
static func skill_to_exp(skill: int) -> int:
	return int((pow(1.1, float(skill)) - 1.0) * 1000.0)

## Skill level from experience points: floor(log_1.1(exp/1000 + 1)).
static func exp_to_skill(e: int) -> int:
	if e <= 0:
		return 0
	return int(floor(log(float(e) / 1000.0 + 1.0) / log(1.1)))

## The hero's total experience across all skills (XP in the panel).
func total_experience() -> int:
	var t := 0
	for name in SKILL_NAMES:
		t += int(experience.get(name, 0))
	return t

## The current skill value by name — for damage/UI.
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

## Restore skill levels from accumulated experience.
##
## WHY. A found bug: the school buys a level THROUGH THE FIELD (school_panel.gd:251
## does `player.set(field, ...)`) and never writes to `experience`. When
## loading, `_apply_hero_choice()` restores the base from hero.stats, and
## `_ready()`, seeing a non-empty `experience`, skips `_init_experience()`. No one
## recalculates the level from experience any more - so levels bought at school
## silently rolled back to the starting ones. Craft skills would have inherited
## exactly the same: they grow FROM EXPERIENCE, and without this cycle they would be lost
## entirely.
func _levels_from_experience() -> void:
	for name in SKILL_NAMES:
		var lvl := exp_to_skill(int(experience.get(name, 0)))
		if lvl > 0:
			_set_skill_value(name, lvl)

## Set a skill level by FIELD NAME ("fire_skill") and synchronise the experience.
##
## The school works with fields (school_panel.gd SKILLS pairs a Russian label with "fire_skill"),
## while gain_skill_exp uses names from SKILL_NAMES ("fire"). Hence trim_suffix.
## A side effect of the method - a fix for the school bug: before, a purchase wrote
## only the field without touching experience, and the level rolled back on load.
func set_skill_field(field: String, v: int) -> void:
	var name := field.trim_suffix("_skill")
	_set_skill_value(name, v)
	if v > 0:
		experience[name] = maxi(int(experience.get(name, 0)), skill_to_exp(v))

## Grant experience to a skill; if the level from experience grew — raise the skill.
func gain_skill_exp(skill_name: String, amount: int) -> void:
	if not SKILL_NAMES.has(skill_name) or amount <= 0:
		return
	var e := int(experience.get(skill_name, 0)) + amount
	experience[skill_name] = e
	var lvl := exp_to_skill(e)
	if lvl > skill_value(skill_name):
		_set_skill_value(skill_name, lvl)
		print("Навык %s повышен до %d!" % [skill_name, lvl])

## Skill from damage dealt (by the hero's weapon type). "" — no experience is given.
func _weapon_skill_name() -> String:
	match weapon:
		"sword": return "blade"
		"axe": return "axe"
		"club": return "bludgeon"
		"pike": return "pike"
		"bow", "xbow": return "shooting"
	return ""

## Experience per hit: as in the developers' MapUnit:
## exp = damage/maxHP * unit Experience * (1 + Mind/100); x2 on a kill.
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
		f *= 2.0  # a kill — twice the experience
	gain_skill_exp(ws, int(f))

## Experience for using magic (by the spell sphere).
func _apply_spell_experience(sphere: String) -> void:
	var ws := sphere.to_lower()
	if not SKILL_NAMES.has(ws):
		return
	# base ~20 * (1 + Mind/100), like the "unit experience" of spells
	gain_skill_exp(ws, int(20.0 * (1.0 + mind / 100.0)))

## --- Encumbrance: item weight in the inventory, overload slows the hero down ---
func get_load() -> float:
	var w := 0.0
	for key in inventory:
		var it := ItemDB.find(str(key))
		w += float(it.get("weight", 0.0))
	return w

## Capacity before overload (Body lets you carry more).
func load_capacity() -> float:
	return 30.0 + body * 10.0

## Speed multiplier from encumbrance: up to capacity — 1.0, overload — down to 0.5.
func _load_penalty() -> float:
	var cap := load_capacity()
	if cap <= 0.0:
		return 1.0
	var load := get_load()
	if load <= cap:
		return 1.0
	return clampf(cap / float(load), 0.5, 1.0)

## Hero magic: learned spells (books) and scroll charges.
## known_spells: "Fire_Ball" -> {"charges": -1} — learned forever (mage, from a book);
## "Fire_Arrow" -> {"charges": 2} — scroll charges (a cast spends a charge, and the scroll
## disappears eventually). Warriors have no mana (max_mana = 0) — scrolls only.
var known_spells: Dictionary = {}
var sphere_books: Dictionary = {}   # "Fire" -> true (the element book was learned by the mage)
var cast_cooldowns: Dictionary = {} # name -> remaining cooldown time
var has_mana: bool = true
var health_bar: HealthBar
var alm_map = null   # CustomMap or AlmMap from the "alm_map" group

# --- Hero equipment (defines the animation set) ---
var armor_kind: String = "heavy"   # "heavy" -> heroes/, "light" -> heroes_l/
var weapon: String = "unarmed"     # unarmed by default — we are debugging that animation
var two_handed: bool = false
var has_shield: bool = false
var _anim: UnitAnimBase = null

func _ready():
	_apply_hero_choice()
	var from_save := not Game.hero_save.is_empty()
	if from_save:
		_apply_hero_save()
	else:
		# Economy (P0): starting gold and the inventory.
		# Starting gold lives in GameConfig [economy] start_gold. IT USED TO BE 20 here -
		# with starting weapon prices of 150-600 the player could not buy their own weapon.
		gold = GameConfig.geti("economy", "start_gold")
		inventory.clear()
		_grant_starter_set()
	# Only mages have mana and read magic books; warriors — scrolls (charges).
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
		# Experience from a save - so the levels must be RECALCULATED from it, not taken
		# as base from hero.stats. Before, a bare `pass` stood here, and purchases at
		# school (which write only the level field) rolled back on load;
		# craft skills growing FROM experience were lost entirely.
		_levels_from_experience()
	else:
		_init_experience()


## Apply Game.hero_save (save load) instead of the starter set.
func _apply_hero_save() -> void:
	_restore_from_hero_save()
	# Rebuild the visuals/attack from the saved equipment (not the starting one).
	# weapon here is the animation KEY (sword/staff/...), not the item_db type
	# ("Long Sword"); otherwise UnitAnim.setup("heroes/Long Sword") and the hero is invisible.
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


## Head/inventory/equipment/experience/skills from Game.hero_save — without recalculating
## animation and stats: the caller does that (see reload_hero_state).
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


## Re-read the class-dependent hero state on the LIVE node (loading a slot of
## another character from the Esc menu).
##
## Before, loading a slot changed only Game.hero_* and the inventory contents, while the
## Player node stayed the same: the new mage hero ran with a warrior sprite and had no
## mana (report 23.10). change_scene used to mask this — now the world
## is swapped in place, and everything class-dependent has to be rebuilt explicitly.
##
## Gear of another class (an old save) stays equipped, but is marked:
## the class rules changed later than those saves were written.
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
	move_speed = _calc_speed()
	# The animation set depends on class, sex and race — the sprite must
	# switch to the new hero.
	_ensure_sprite()
	# The health bar is created once with the max_hp/has_mana of that moment:
	# a mage from a save must gain mana, a warrior must lose it.
	if health_bar != null and is_instance_valid(health_bar):
		health_bar.max_hp = maxi(1, max_hp)
		health_bar.max_mana = maxi(1, max_mana)
		if health_bar.has_mana != has_mana:
			health_bar.has_mana = has_mana
			# The node is detached from its parent immediately, not at the end of the frame: otherwise
			# add_child of the new bar in the same frame would see two nodes.
			remove_child(health_bar)
			health_bar.queue_free()
			health_bar = null
			_create_health_bar()
		health_bar.update_bars(current_hp, current_mana)
	if has_method("refresh_animation"):
		refresh_animation()

## Initial experience from the starting skills (skill -> exp, as in the original:
## exp = (1.1^skill - 1) * 1000). After that the skill grows with the experience gained.
func _init_experience() -> void:
	for name in SKILL_NAMES:
		var lvl := skill_value(name)
		if lvl > 0:
			experience[name] = skill_to_exp(lvl)

## Starting magic is disabled: the mage begins WITHOUT spells in the magic panel.
## At the start they get the book of the simplest spell of the chosen school in the inventory
## (see _grant_starter_set) and learn it by double-clicking the inventory cell.

## Apply the character choice from the start screen (character_select): stats,
## starting equipment. Without a choice (launching main.tscn directly) — default values.
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
	# Mage: starting spells are already in abilities (fireball/heal/lightning)

## Starting gear by hero class (into the inventory — can be worn/sold right away).
func _grant_starter_set() -> void:
	# Keys use the lowercase material: "Common iron Long Sword", not
	# "Common Iron Long Sword". The mismatch did not raise an error - ItemDB.find()
	# returned an empty dictionary, and the hero went into battle naked while the items lay
	# in the inventory. The case was aligned with item_db.json when the metals were lowercased.
	var weapon_key := "Common iron Long Sword" if Game.hero_class != "mage" else "Common Wood Staff"
	inventory.append(weapon_key)
	if Game.hero_stats.get("shield", false):
		inventory.append("Common iron Buckler")
	# There is NO starting armour by the player's decision (01.10): the hero enters battle with
	# a weapon and a shield, the mage — a staff and a book. Before, this handed out
	# "Common Leather Mail" — leather armour removed from the database as an Allods
	# leftover; ItemDB.find() would have returned an empty dictionary without an error.
	#
	# Starting gear is worn at once: otherwise a new hero would enter battle
	# naked (all stats are base attributes) even though the items lie in the inventory.
	equip_item(ItemDB.find(weapon_key))
	if Game.hero_stats.get("shield", false):
		equip_item(ItemDB.find("Common iron Buckler"))
	# At the start the mage gets the book of the simplest spell of the chosen school
	# (learned by double-clicking the inventory cell; the book is spent).
	if Game.hero_class == "mage" and Game.hero_start_book != "":
		inventory.append(Game.hero_start_book)
	# TEMPORARY (magic debugging): hand out ALL database spells, unlock all spheres
	# and do not limit mana/cooldown (can_cast/_commit_cast look at the flag).
	# Turned off with a single Game.debug_magic = false in game.gd.
	if Game.debug_magic and Game.hero_class == "mage":
		for spell in SpellDB.all_spell_names():
			known_spells[str(spell)] = {"charges": -1}
		for sphere in ["Fire", "Water", "Air", "Earth", "Astral"]:
			sphere_books[sphere] = true
	for i in range(3):
		inventory.append("Potion Medium Healing")
	inventory.append("Potion Mana Regeneration")

## --- Inventory ---

func has_item(key: String) -> bool:
	return inventory.has(key)

func add_item(key: String) -> void:
	if key != "":
		inventory.append(key)
		_recall_speed()

## Put gold into the treasury. The method was needed by the loot bag (loot_bag.gd called
## add_gold via has_method), but did not exist: loot gold fell into the
## fallback branch `_player.gold += gold`, and the inventory knew nothing about it.
func add_gold(amount: int) -> void:
	if amount <= 0:
		return
	gold += amount

## Remove an item from the inventory; true — if it was there.
func remove_item(key: String) -> bool:
	var i := inventory.find(key)
	if i < 0:
		return false
	inventory.remove_at(i)
	_recall_speed()
	return true

## Recalculate speed after a weight (encumbrance) change.
func _recall_speed() -> void:
	move_speed = _calc_speed()

## Permanent stats that a potion can raise.
## Database key -> field on Player. In Allods Reaction derives from Agility
## (`reaction := 2 * agility`), hence the database says "reaction" while the code uses agility.
const PERMANENT_STATS := {
	"body": "body",
	"mind": "mind",
	"reaction": "agility",
	"spirit": "spirit",
}

## Parses the item effects and raises stats FOREVER.
## Works for strings like "body=+1" (without "duration" — that is, not a buff).
## Returns the list of applied fields (empty if there are no permanent effects).
func apply_permanent_effects(effects: Array) -> Array:
	var applied: Array = []
	for raw in effects:
		var line := str(raw)
		if "duration" in line:
			continue                      # a temporary effect — not permanent
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
		# We duplicate into Game.hero_stats — it is saved as "stats",
		# so the bonus survives a restart without a schema version change.
		# The key here is `field`, not the database name: the database says "reaction", but
		# _apply_hero_choice() reads "agility" — a write under "reaction" would silently
		# lose the agility bonus on reload.
		if Game.hero_stats is Dictionary:
			Game.hero_stats[field] = int(Game.hero_stats.get(field, 0)) + amount
		applied.append(stat)
	if not applied.is_empty():
		_recall_derived()
	return applied

## Recalculation of derived stats after the primary ones change.
func _recall_derived() -> void:
	var old_hp := max_hp
	var old_mana := max_mana
	max_hp = _calc_max_hp()
	max_mana = _calc_max_mana()
	# Added capacity goes to the player at once: a potion must not heal "into the void".
	current_hp = mini(max_hp, current_hp + maxi(0, max_hp - old_hp))
	current_mana = mini(max_mana, current_mana + maxi(0, max_mana - old_mana))
	_recall_speed()

## Using a potion. A shared path for an inventory click and for a hotkey —
## before, the logic lived inside _on_item_clicked, and there would simply be no second call.
## Spent if EITHER a permanent effect OR a one-off heal/mana worked.
func use_potion(item_key: String) -> bool:
	var item := ItemDB.find(item_key)
	if item.is_empty():
		return false
	if str(item.get("quality", "")) != "Potion":
		return false
	var effects: Array = item.get("effects", [])
	var permanent := apply_permanent_effects(effects)
	# The one-off part keeps the previous values from inventory_panel:
	# they were tuned for balance and need not match the effects in the database.
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
	# Neither permanent nor one-off effect — nothing to drink, the item is not spent.
	if permanent.is_empty() and heal <= 0 and mana <= 0:
		return false
	if not remove_item(item_key):
		return false
	current_hp = mini(max_hp, current_hp + heal)
	if max_mana > 0:
		current_mana = mini(max_mana, current_mana + mana)
	SoundDB.play("magic.heal")
	return true

# --- Derived stats (relations from the original main.txt) ---
func _calc_max_hp() -> int:
	return 20 + body * 8          # Body -> health; body=10 -> 100

func _calc_max_mana() -> int:
	if not has_mana:
		return 0                  # warriors have no mana at all
	return 10 + spirit * 4        # Spirit -> mana (per the manifest); spirit=10 -> 50

func _calc_hp_regen() -> int:
	return 1 + int(body / 5.0)           # HP regen from Body

func _calc_mana_regen() -> int:
	return 1 + int(spirit / 10.0)        # mana regen from Spirit

func _calc_speed() -> float:
	# Hero speed by the original formula (UnityAllods MapHuman):
	# Speed = min(Reaction/5 + 12, 255); Reaction ≈ 2·Agility (derived).
	# In our pixels: base × 7.5 (at agility=10 — the same 120 px/s as before).
	var reaction := 2 * agility
	var base := clampf(float(reaction) / 5.0 + 12.0, 12.0, 255.0)
	var speed := base * 7.5
	# Global speed multiplier from config [movement] speed_multiplier
	# (1.0 by default, that is it changes nothing) — a knob for balance and tests.
	speed *= GameConfig.getf("movement", "speed_multiplier")
	# Encumbrance (item weight in the inventory): overload slows down to 0.5x
	speed *= _load_penalty()
	return speed

## The skill the hero strikes with using the current weapon (blade for a sword etc.).
func _weapon_skill_for_damage() -> int:
	match weapon:
		"axe": return axe_skill
		"bludgeon": return bludgeon_skill
		"pike": return pike_skill
		"shooting": return shooting_skill
		"staff", "magic": return fire_skill
		_: return blade_skill


func get_damage_min() -> int:
	# Weapon: the item base is SCALED by skill and stats — not a copy
	# of damage_min from item_db. A fist is always weaker than any weapon.
	var w := _equipped_item("weapon")
	if not w.is_empty():
		var dmin := int(w.get("damage_min", 0))
		if dmin > 0:
			var sk := _weapon_skill_for_damage()
			var mult := 1.0 + float(sk) / 40.0 + float(agility) / 80.0
			return maxi(1, int(round(float(dmin) * mult)))
	return unarmed_damage_min()


func get_damage_max() -> int:
	var w := _equipped_item("weapon")
	if not w.is_empty():
		var dmax := int(w.get("damage_max", 0))
		if dmax > 0:
			var sk := _weapon_skill_for_damage()
			var mult := 1.0 + float(sk) / 40.0 + float(body) / 60.0
			return maxi(1, int(round(float(dmax) * mult)))
	return unarmed_damage_max()


## Fist / unarmed: strictly below any equippable blade.
func unarmed_damage_min() -> int:
	var sk := _weapon_skill_for_damage()
	return maxi(1, int(body / 6.0) + int(sk / 20.0))


func unarmed_damage_max() -> int:
	return unarmed_damage_min() + maxi(1, int(body / 10.0))

func get_attack() -> int:
	# The weapon to_hit goes into attack (hit chance) instead of being discarded.
	var w := _equipped_item("weapon")
	return int(agility / 2.0) + int(blade_skill / 10.0) \
		+ int(w.get("to_hit", 0)) + StatusEffects.stat_flat(self, "attack")

func get_defense() -> int:
	var base := int(agility / 2.0) + int(body / 4.0)    # Agility -> evasion/defense
	# All worn pieces (armour, helmet, cloak, gloves, boots, amulets, rings,
	# shield) give their defense, and it is taken IN FULL. Attributes are the base, items go on top.
	var bonus := 0
	for it in _equipped_items():
		bonus += int(it.get("defence", 0))
	# The mage shield (Shield) = temporary astral armour, not HP absorption.
	bonus += StatusEffects.shield_armor_defense(self)
	return int(round((base + bonus + StatusEffects.stat_flat(self, "defense")) \
		* StatusEffects.defense_mult(self)))

func get_absorption() -> int:
	# Absorption (a separate armour stat in the original): the sum over all pieces.
	var a := int(body / 4.0)
	for it in _equipped_items():
		a += int(it.get("absorption", 0))
	a += StatusEffects.shield_armor_absorption(self)
	return a

## The item in a slot (an empty dictionary if the slot is empty or the item is not in the database).
func _equipped_item(slot: String) -> Dictionary:
	var key := str(equipped.get(slot, ""))
	if key == "":
		return {}
	var it := ItemDB.find(key)
	return it if not it.is_empty() else {}

## All equipped items (for stats/paper-doll). Empty slots are skipped.
func _equipped_items() -> Array:
	var out: Array = []
	for slot in ItemDB.EQUIP_SLOTS:
		var it := _equipped_item(slot)
		if not it.is_empty():
			out.append(it)
	return out

## Wear an item: the key moves from the inventory into the slot (model A — worn items live
## only in equipped). A swap in the same slot returns the old key to the inventory.
## A two-handed weapon removes the shield — the shield also returns to the inventory.
## true if the item is equipped.
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

## Take an item off a slot: the key returns to the inventory (model A).
## true — it was worn.
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
			# Without armour — the hero base set (heroes/), not the "light" one.
			armor_kind = "heavy"
	refresh_animation()
	return true

func get_sight() -> int:
	return 6 + int(agility / 3.0)                 # per the manifest

## Magic damage: Mind -> spell power (see Game.spell_power — the single formula).
func get_magic_power() -> int:
	return int(mind / 2.0)

## Elemental resistance in percent = spirit (in the original Spirit gives
## resistance) + sphere skill + temporary Protection_from_* buffs.
func _sphere_protection(sphere: String) -> int:
	var skill := sphere_skill(sphere)
	# body/weapon armour magcap — the contribution to elemental resistance: for clothing that is it
	# (Common Leather Mail has magcap=3, heavy armour — 150).
	var gear := int(_equipped_item("body").get("magcap", 0)) \
		+ int(_equipped_item("weapon").get("magcap", 0))
	return spirit + int(skill / 10.0) + int(gear / 10.0) + StatusEffects.resist_bonus(self, sphere)

func get_protection_fire() -> int: return _sphere_protection("Fire")
func get_protection_water() -> int: return _sphere_protection("Water")
func get_protection_air() -> int: return _sphere_protection("Air")
func get_protection_earth() -> int: return _sphere_protection("Earth")
func get_protection_astral() -> int: return int(spirit / 2.0) + StatusEffects.resist_bonus(self, "Astral")  # astral is hardly protected at all

## The current animation set by equipment ("heroes/swordsman_").
##
## PILOT_HERO_SET — which rig/set the hero uses.
## "rig/pilot" = the working stick skeleton (mechanics, not looks).
## "rig/hero_atlas" = cutout from a single atlas (BROKEN: double legs, an extra arm).
## "rig/atlas_v2" = 6 separate parts, 2 views (east + mirror).
##   The rig technically works, but the player rejected its look on 14.10 ("a scarecrow").
## "hero/war_men" = 12 frames from Nano Banana strips (idle1+move4+attack3+dying4),
##   one right-facing profile + mirror. Enabled 14.10.
## "hero/war_women" = the same contract, the warrior woman. The hero's sex picks the set.
## "hero/orc_men" / "hero/orc_women" = the same contract, orc man and orc woman (15.10).
##   The race picks the set, the sex — within the race. Undead (necro) and druid got
##   their own sets on 20.10; the undead and druids — their female sets on 21.10.
## "" = sprite sheets by equipment.
const PILOT_HERO_SET := "hero/war_men"
const PILOT_HERO_SET_UNDEAD := "hero/undead_men"
const PILOT_HERO_SET_DRUID := "hero/druid_men"
const PILOT_HERO_SET_F := "hero/war_women"
const PILOT_HERO_SET_ORK := "hero/orc_men"
const PILOT_HERO_SET_ORK_F := "hero/orc_women"
const PILOT_HERO_SET_UNDEAD_F := "hero/undead_women"
const PILOT_HERO_SET_DRUID_F := "hero/druid_women"
## The mage class (21.10): every mage has their own set by race and sex.
const PILOT_HERO_SET_MAGE := "hero/mage_human_men"
const PILOT_HERO_SET_MAGE_F := "hero/mage_human_women"
const PILOT_HERO_SET_MAGE_ORK := "hero/mage_orc_men"
const PILOT_HERO_SET_MAGE_ORK_F := "hero/mage_orc_women"
const PILOT_HERO_SET_MAGE_UNDEAD := "hero/mage_undead_men"
const PILOT_HERO_SET_MAGE_UNDEAD_F := "hero/mage_undead_women"
const PILOT_HERO_SET_MAGE_DRUID := "hero/mage_druid_men"
const PILOT_HERO_SET_MAGE_DRUID_F := "hero/mage_druid_women"

## PILOT 10.10: a rig instead of sprite sheets if the set has rig.json.
## Rolling back the whole pilot — false on this line. It only works together with
## PILOT_HERO_SET: by itself the rig only turns on where a rig exists.
const PILOT_RIG := false

## The hero's animation set.
##
## Before, a set name was built here from equipment: `heroes/…` for heavy
## armour and magic, `heroes_l/…` for light. Both families are Allods II art and were
## removed on 11.10 together with the assets, so the branch was deleted: building it would give
## a set that is not in the database, and the hero would be left without animation.
##
## Now there is one answer — the pilot rig. When rig sets for armour
## kits appear, the "kit -> rig set" mapping will return here.
func anim_set_name() -> String:
	# Sex picks the set: before 14.10 Game.hero_gender affected nothing and
	# all heroes looked the same. The values are as the character creation
	# screen gives them (character_select.gd); anything else counts as male.
	# Race — since 15.10: orcs have their own set. "orc" is also accepted because
	# that is the race name in `MapGenerator.CITY_RACES` and in old saves.
	var female := str(Game.hero_gender) == "female"
	# The mage class (21.10): mages have their own sets with a robe and a staff,
	# the race layout is the same as for warriors.
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

## Recreate the animation after an equipment change.
func refresh_animation() -> void:
	if _anim == null:
		return
	var set := anim_set_name()
	# The new set may have no rig (the equipment moved the hero to another
	# set). Then the rig must give way to sprite sheets — otherwise the unit
	# would stay a skeleton from the previous set.
	if _anim is RiggedAnim and not RiggedAnim.has_rig(set):
		_anim.queue_free()
		_anim = null
		_ensure_sprite()
		return
	_anim.setup(set)
	_anim.play(UnitAnim.Anim.MOVE, true)
	move_speed = _calc_speed()   # speed is refreshed together with the equipment

## Speed multiplier by height: climbing slows down, descent/flat ground — normal.
## Roads (tile4) — faster than grass.
func _height_speed_factor(target_pos: Vector2) -> float:
	var f := StatusEffects.speed_mult(self)   # Haste/Slow — dynamically, once per frame
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

## Whether the hero may move to a point: walkability (water/barrier) + map bounds.
## Exception: leaving an impassable cell (the hero "inside a tree") is allowed — a step
## inside one's own cell is permitted, to reach the edge and get out.
## Buildings: a hard ban on entering the footprint (grid + the building StaticBody2D).
func _can_move_to(pos: Vector2) -> bool:
	if not alm_map:
		return true
	var cur := Vector2i(int(global_position.x) / 32, int(global_position.y) / 32)
	var nxt := Vector2i(int(pos.x) / 32, int(pos.y) / 32)
	# Building footprint: no entry (even if is_walkable_world lied).
	if nxt != cur and alm_map.has_method("is_structure_cell") \
			and alm_map.is_structure_cell(nxt):
		return false
	if alm_map.is_walkable_world(pos):
		return alm_map.is_within_bounds(pos)
	return nxt == cur

# --- Body movement physics (smooth acceleration/braking, no "ice") ---
## Acceleration/braking - in GameConfig [movement] accel/decel.

## Movement with a walkability check.
## First we try the full vector; if it runs into water/the map border, we try
## moving along each axis separately. Without it the hero "stuck" to the border and could not
## move AT ALL — neither forward, nor along, nor back: a blocked vector
## zeroed the velocity entirely.
##
## Speed while sliding along a wall decreases (the length of the allowed step is taken),
## so this is not "ice" — the hero neither accelerates nor bounces.
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
		# Target speed = allowed step / delta: full speed along the freed axis,
		# zero along the blocked one. Slide frames are not accelerated.
		_last_move_dir = slide.normalized()
		velocity = velocity.move_toward(slide / delta, GameConfig.getf("movement", "accel") * delta)

func _create_health_bar():
	health_bar = preload("res://scripts/health_bar.gd").new()
	health_bar.max_hp = max_hp
	health_bar.max_mana = max_mana
	health_bar.has_mana = has_mana
	add_child(health_bar)

func _ensure_sprite():
	# The old animation is detached from its parent BEFORE add_child of the new one: both are
	# called "UnitAnim". queue_free() frees the node only at the end of the frame, and
	# loading a slot of another hero (reload_hero_state) left the previous
	# sprite (warrior) standing on top of the new one (mage).
	for child in get_children():
		if child is UnitAnimBase:
			remove_child(child)
			child.queue_free()
	_anim = _make_anim_backend(anim_set_name())
	_anim.name = "UnitAnim"
	add_child(_anim)
	refresh_animation()

## Create the animation backend for a set: the rig if there is one, otherwise sprite sheets.
##
## The backends are interchangeable by the UnitAnimBase contract (guard —
## tests/anim_contract_smoke.gd), so the choice boils down to "is there a rig".
## PILOT_RIG disables the swap entirely: the pilot rollback is one line.
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
	# Spell cooldowns
	for spell in cast_cooldowns:
		cast_cooldowns[spell] = max(0.0, float(cast_cooldowns[spell]) - delta)

	# Refresh the health bar
	if health_bar:
		health_bar.update_bars(current_hp, current_mana)

	# Mage auto-cast (package C): healing and buffs without manual targeting.
	_tick_auto_cast(delta)
	# The hero always faces the cursor (player wish 21.10):
	# while idling/starting a cast they turn to the mouse, while moving and fighting —
	# movement/the target picks the direction, as before.
	_update_facing_mouse(delta)

	match state:
		"idle":
			velocity = Vector2.ZERO
			if _anim:
				if _cast_swing_left > 0.0:
					# We play the cast wind-up (play() with the same block does not reset the phase).
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
				# Step tempo follows the COMMANDED speed (acceleration/braking do not "overpump" the cadence)
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
				# Falling: DYING once, then DECAY decomposition (1-2-3), then a pause
				_anim.play(UnitAnim.Anim.DYING)
				if _anim.advance(delta):
					if UnitDB.decay_phases(anim_set_name()) > 0:
						state = "decay"
						_anim.play(UnitAnim.Anim.DECAY)
					else:
						# The block is finished — freeze the LAST frame and go into
						# the corpse state. Without it advance() looped the block back to
						# the first frame (the hero stood up with arms wide open), and
						# any unpause — Esc — replayed the death
						# (player report 14.10). enemy.gd does the same via
						# freeze_last_frame, the hero lacked this step.
						_anim.freeze_last_frame(UnitAnim.Anim.DYING)
						state = "corpse"
						get_tree().paused = true
		"decay":
			velocity = Vector2.ZERO
			if _anim:
				_anim.play(UnitAnim.Anim.DECAY)
				if _anim.advance(delta):
					_anim.freeze_last_frame(UnitAnim.Anim.DECAY)
					state = "corpse"
					get_tree().paused = true
		"corpse":
			# Corpse: no animation, no physics. Unpausing (Esc) no longer
			# restarts the fall — the DYING block has already played.
			velocity = Vector2.ZERO
			if _anim:
				_anim.freeze_last_frame(UnitAnim.Anim.DYING)

	move_and_slide()
	_clamp_to_map()
	_escape_blocking_units()
	_apply_relief_stand()

## Safety net: the hero must not stand outside the map. Unit separation can push
## them over the edge (is_within_bounds allows a 12 px margin), and then further movement
## breaks: any walkability check requires the CURRENT point to be inside.
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

## How many blocked frames we tolerate before clearing the collision with the blocking unit.
const UNSTICK_DELAY := 8
## The radius in which the collision with the unit stays cleared (you cannot come back here).
const UNSTICK_RADIUS := 48.0

var _block_frames := 0
var _unit_exceptions: Array[Node2D] = []
## The last allowed movement direction. When the velocity is killed by a block,
## the direction is needed to ask physics WHO exactly is in the way (test_move).
var _last_move_dir := Vector2.ZERO

## Units are solid to each other (collision_layer 1, mask 1). If the hero is blocked by
## a standing citizen, move_and_slide kills the velocity dead — NPCs have no
## logic to step aside, and the hero "got stuck" for good: at the map border, in
## a passage between houses, at any crowd. After UNSTICK_DELAY blocked frames
## we clear the collision with that specific unit so the hero can squeeze through.
## Walls, trees and other map cells (layer 1) stay solid.
##
## test_move specifically, NOT get_slide_collision(): slide collisions are cached from
## the previous move_and_slide, and if the unit is already freed (an enemy died → queue_free),
## a dead object id stays in the cache — add_collision_exception_with() failed with
## "Parameter "body" is null". A fresh query returns only live bodies.
## Signature (verified in 4.7): test_move(from: Transform2D, motion: Vector2,
## out: KinematicCollision2D) -> bool — the collision comes through the out parameter.
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

## Restore the collision with units the hero has already moved away from.
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

## Stand on the relief: raise the sprite by the cell height (as in Allods16).
func _apply_relief_stand() -> void:
	if _anim == null:
		return
	var h := 0.0
	if alm_map != null and alm_map.has_method("relief_at_world"):
		h = float(alm_map.call("relief_at_world", global_position))
	_anim.position = Vector2(_anim.position.x, -h)
	if health_bar:
		# Above the figure's HEAD, not above the frame canvas: the canvas is 64, the figure ~54.
		# The offset is 16 px (not 6): the aura of blessing lives between the crown
		# and the bar (a 16 px halo), otherwise the bar covers it.
		var top := Game.unit_local_rect(self).position.y
		health_bar.position.y = top - h - 16.0

## Camera focus point: the visual centre of the character (the middle of the figure), not their
## "feet" (global_position). The sprite is drawn up from the soles — if you centre
## on global_position, the hero will always be above the middle of the screen.
func camera_focus() -> Vector2:
	if _anim == null:
		return global_position
	return global_position + Vector2(0, _anim.position.y - _anim.visual_height() * 0.5)

## Spell projectile start point: slightly above the middle of the figure (at the level of the arms/
## chest). Not the "feet" — otherwise the projectile flies out from under the soles.
func cast_origin() -> Vector2:
	if _anim == null:
		return global_position
	return global_position + Vector2(0, _anim.position.y - _anim.visual_height() * 0.62)

func move_to_target(delta):
	if _path.size() > 0:
		_follow_path(delta)
	if _path.size() > 0:
		return
	# An empty path (BFS limit / a partial route to the "nearest to the target" cell):
	# we go STRAIGHT to player_target instead of stopping (otherwise on 192×192 — jerks).
	var dist := Game.player_target.distance_to(global_position)
	if dist > 8.0:
		var dir := Game.safe_dir(global_position, Game.player_target)
		var speed_factor := _height_speed_factor(Game.player_target)
		_move_checked(dir, move_speed * speed_factor, delta)
		if velocity.length_squared() < 1.0:
			# Blocked / target unreachable — we stop instead of twitching.
			state = "idle"
			velocity = Vector2.ZERO
			Game.player_target = global_position
	else:
		state = "idle"
		velocity = Vector2.ZERO

## Start moving along a route (cell centres from alm_map.find_path).
func begin_path(path: Array) -> void:
	_path = path
	_stuck_frames = 0

## A full stop (used when entering a building/during pauses).
func stop_movement() -> void:
	_cancel_casting()
	state = "idle"
	velocity = Vector2.ZERO
	_path.clear()
	Game.player_target = global_position

## Follow the route: to the next point; when blocked for 12 frames — stop.
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
		# The target died (falling/decomposing) — we stop the chase
		if attack_target.is_in_group("enemy") and not Game.enemies.has(attack_target):
			attack_target = null
			state = "idle"
			velocity = Vector2.ZERO
			return
		# Combat distance — between BODIES (the real figure), plus the weapon length.
		var range_to_enemy := Game.units_range(self, attack_target)
		if range_to_enemy <= Game.attack_reach(self):
			_path.clear()
			state = "attack"
			velocity = Vector2.ZERO
			return
		# Path to the enemy: replanning ~1.2 s + a random offset at the start
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
		# The enemy ran out of radius — we catch up instead of swinging at nothing
		if Game.units_range(self, attack_target) > Game.attack_reach(self) + 8.0:
			state = "chase"
			_impact_timer = -1.0
			_swing_target = null
			return
		# The target is dead (corpse/decomposing) — we stop swinging at the corpse
		if not Game.enemies.has(attack_target):
			attack_target = null
			state = "idle"
			velocity = Vector2.ZERO
			_impact_timer = -1.0
			_swing_target = null
			return
		if attack_cooldown <= 0.0 and _impact_timer < 0.0:
			var damage = get_damage_min() + randi() % (get_damage_max() - get_damage_min() + 1)
			# A MAGE with a staff: the strike is a sphere, but now it costs mana.
			# Before, this was free magic: melee damage (body+blade_skill)
			# went through magic_damage for 0 mana — stronger than Fire_Ball for 15 mana.
			if Game.hero_class == "mage" and weapon == "staff":
				var sphere := _active_sphere()
				attack_cooldown = GameConfig.getf("combat", "attack_cooldown")
				# Without mana the staff strikes as a weak physical weapon
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
			# Start of the wind-up: damage and target are fixed HERE.
			# Impact hits _swing_target, not the live attack_target — otherwise
			# _process_action_mode could switch the target between frames.
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
				# Distance is checked again on the strike frame: the target could have run away.
				if Game.units_range(self, victim) > Game.attack_reach(self) + 12.0:
					return
				# Single point: a miss by hit_chance(attack, defense), then Game.deal_damage
				# (armour absorption → take_damage → shield → HP).
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

## The hero turns to the cursor when not already occupied with direction:
## while idling, starting a cast and in the "casting" state. While moving and fighting
## the direction is set by the velocity/target — we do not touch that.
func _update_facing_mouse(delta: float) -> void:
	if _anim == null:
		return
	if state != "idle" and state != "casting":
		return
	# The cursor under the mouse in world coordinates; a dead zone around the hero —
	# so the hero does not twitch when the cursor rests on the character itself.
	var to_mouse := get_global_mouse_position() - global_position
	if to_mouse.length() < 24.0:
		return
	_anim.set_direction_vec(to_mouse)
	if _anim is UnitAnim:
		(_anim as UnitAnim)._advance_rotation(delta)

## The hero's weapon hit sound (SoundDB keys: swing/weapon/bow).
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
	# A short shout — not on every hit, otherwise it turns into mush.
	if randf() < 0.3:
		_hero_voice("attack", randi_range(1, 3))

## Hero voice line: the sex picks the voice set (george / bella).
func _hero_voice(kind: String, idx: int) -> void:
	var set_name := "female" if str(Game.hero_gender) == "female" else "male"
	SoundDB.play("voice.hero.%s.%s.%d" % [set_name, kind, idx])

## Mana for a staff strike (a magic sphere strike).

## Magic damage: base + Mind + sphere skill (as in Allods2).
## Kept for compatibility: the real formula lives in Game.spell_damage /
## Game.spell_power, so damage, healing and shield compute the same thing.
func magic_damage(base: int, sphere: String) -> int:
	return int(round(float(base) * (1.0 + Game.spell_power(self, sphere) / 100.0)))


## The sphere sound for a staff strike (not a full spell).
func _play_sphere_sound(sphere: String) -> void:
	match sphere:
		"Fire": SoundDB.play("magic.fire.bolt")
		"Water": SoundDB.play("magic.ice.bolt")
		"Air": SoundDB.play("magic.lightning")
		"Earth": SoundDB.play("magic.earth.bolt")
		"Astral": SoundDB.play("magic.heal")

## The mage's active sphere (for a staff strike/the sphere panel): the sphere of the starting book,
## otherwise the first already learned one. Fallback — Fire (at the start there is always a sphere book).
func _active_sphere() -> String:
	if Game.hero_start_book != "":
		var b := SpellDB.sphere_of_book(Game.hero_start_book)
		if b != "":
			return b
	for sp in ["Fire", "Water", "Air", "Earth", "Astral"]:
		if sphere_books.get(sp, false):
			return sp
	return "Fire"

## Sphere skill (for UI/damage): 0-100.
func sphere_skill(sphere: String) -> int:
	match sphere:
		"Fire": return fire_skill
		"Water": return water_skill
		"Air": return air_skill
		"Earth": return earth_skill
		"Astral": return astral_skill
	return 0

## Hero spells (for the spell book): learned ones + scrolls with charges.
func known_spell_list() -> Array:
	var out: Array = []
	for name in known_spells:
		out.append(name)
	out.sort()
	return out

## Attacking spells (for the hotkeys) in database order.
func _attack_spells() -> Array:
	var out: Array = []
	for name in known_spell_list():
		var kind := SpellDB.kind_of(name)
		if kind in ["attack", "area"]:
			out.append(name)
	return out

## Whether the hero has a spell (book/scroll) and whether it can be cast now.
func has_spell(name: String) -> bool:
	return known_spells.has(name)

## Spell charges: -1 = learned forever (mage, from a book), 0 = none, N = scrolls.
func spell_charges(name: String) -> int:
	if not known_spells.has(name):
		return 0
	return int(known_spells[name].get("charges", 0))
## Cast cost: the mage pays mana, the warrior — a scroll charge.
## In test mode (Game.debug_magic) mana and cooldown are ignored.
func can_cast(name: String) -> bool:
	if not known_spells.has(name):
		return false
	if state == "casting":
		return false
	if not Game.debug_magic and float(cast_cooldowns.get(name, 0.0)) > 0.0:
		return false
	var charges := spell_charges(name)
	if charges > 0:
		return true       # there is a scroll charge
	if Game.debug_magic:
		return true
	if charges == -1 and has_mana:
		return current_mana >= SpellDB.mana_cost(name)   # the mage pays mana
	return false


## One-shot cast wind-up: the duration is the full attack block of the set
## (all hero sets have 3 phases), with one frame of margin.
func _play_cast_swing() -> void:
	# The caster must stop: casting on the move was impossible visually
	# (player report 21.10). We kill the path and the movement target — otherwise state = "move"
	# returns on the next frame and the hero walks on without finishing the wind-up.
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

## Use a spell by name. Returns true if the cast started.
## With cast_time > 0 it enters the "casting" state and applies the effect later.
func cast_spell(name: String, target_position: Vector2, target_node: Node2D = null) -> bool:
	# Safety net: during a tactical pause we cast neither by click, nor by auto-cast,
	# nor by scroll. Before, there was no check at all (the scene root is Always).
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


## Preparation phase: the hero stands still, a telegraph is shown.
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


## The cast was interrupted by damage or by a target change.
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


## Resource deduction + cooldown + the effect itself. Called at the moment of application.
func _commit_cast(name: String, spell: Dictionary, target_position: Vector2, target: Node2D) -> void:
	var charges := spell_charges(name)
	if charges > 0:
		var left := charges - 1
		if left <= 0:
			known_spells.erase(name)   # the scroll is used up — the cell goes dark
		else:
			known_spells[name]["charges"] = left
	elif has_mana and not Game.debug_magic:
		current_mana = maxi(0, current_mana - SpellDB.mana_cost(name))
	# Cooldown — from knowledge of magic (sphere skill + mind), not just the base.
	cast_cooldowns[name] = Game.spell_cooldown(self, name)
	StatusEffects.break_invisibility(self)   # an attack breaks invisibility
	_cast_spell_effect(name, spell, target_position, target)
	_apply_spell_experience(str(spell.get("sphere", "")))


## Scroll: apply the spell once. RETURNS bool — before it was void,
## and game.gd removed the item unconditionally even if there was no effect.
## power — the scroll power (50 normal / 100 elven): it replaces the hero's
## skill when computing damage.
func apply_scroll_to_target(name: String, target: Node2D, power: float = -1.0) -> bool:
	var spell: Dictionary = SpellDB.get_spell(name)
	if spell.is_empty():
		push_warning("Свиток ссылается на заклинание, которого нет в базе: " + name)
		return false
	if target == null or not is_instance_valid(target):
		return false
	_cast_spell_effect(name, spell, target.global_position, target, power)
	# Cooldown — by the magic embedded in the scroll (50/100), not by the skill of the one
	# who read it: otherwise a warrior would spam scrolls with clicks.
	cast_cooldowns[name] = Game.spell_cooldown(self, name, power)
	_apply_spell_experience(str(spell.get("sphere", "")))
	return true


## A scroll at a POINT (area/wall/at a place) — when there is no unit under the cursor.
func apply_scroll_to_target_point(name: String, point: Vector2, power: float = -1.0) -> bool:
	var spell: Dictionary = SpellDB.get_spell(name)
	if spell.is_empty():
		push_warning("Свиток ссылается на заклинание, которого нет в базе: " + name)
		return false
	_cast_spell_effect(name, spell, point, self, power)
	cast_cooldowns[name] = Game.spell_cooldown(self, name, power)
	_apply_spell_experience(str(spell.get("sphere", "")))
	return true

## Spell sound: the database key, with a per-sphere fallback.
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

## The shared order of applying a spell (a book on the panel OR a scroll with targeting).
## Before there were 5 branches here, and 8 different "buffs" boiled down to one shield.
## power_override — the scroll power (50/100): it replaces the hero's skill when
## computing DAMAGE. For buffs and healing the scroll power is not applied (the player's
## decision: the scroll affects damage only).
func _cast_spell_effect(name: String, spell: Dictionary, target_position: Vector2,
		target_node: Node2D, power_override: float = -1.0) -> void:
	var sphere := str(spell.get("sphere", ""))
	var kind := str(spell.get("kind", "buff"))
	var dmg := int(spell.get("damage", 0))
	var area := float(spell.get("area", 0))
	_play_spell_sound(name, sphere)
	# Cast animation: raising and lowering the staff. The magic flies out of the centre
	# (cast_origin), but the hero does not stand like a post (player report 21.10).
	_play_cast_swing()
	SpellVFX.cast_flash(cast_origin(), sphere)
	# "Self" effects (Drain_Life vampirism) — always on the caster, even if
	# the spell flies away as a projectile.
	_apply_self_effects(spell)

	match kind:
		"attack", "area":
			# Prismatic radiance hits several targets at once.
			if str(spell.get("projectile", "")) == "chain":
				_cast_chain_spell(name, spell, sphere, dmg, area, target_position,
					power_override)
			# Blizzard and poison cloud are not a projectile but a zone with a duration.
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
			# Hostile effects: Curse/Slow/Darkness/Stone_Curse/Control_Spirit
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


## Effects that are always applied to the caster themself (vampirism).
func _apply_self_effects(spell: Dictionary) -> void:
	for e in spell.get("effects", []):
		if not (e is Dictionary):
			continue
		if str((e as Dictionary).get("type", "")) != "vampirism":
			continue
		StatusEffects.apply_spell(self, {"effects": [e]}, self)


## Apply the spell effects to the target and show a permanent aura.
## Before there was only a one-shot aura_ring for 0.45 s: "Fire Protection" lives
## for 90 seconds but was visible for less than a second, and the player did not know the buff lasts.
func _apply_effects(target: Node2D, spell: Dictionary) -> void:
	var applied := StatusEffects.apply_spell(target, spell, self)
	if applied <= 0:
		return
	_attach_auras(target, spell)
	# We draw the one-shot ring ONLY if there is no permanent aura: otherwise at cast time
	# two effects appear at one point at once, and it looks like "it twitched and applied".
	if not _has_persistent_aura(target):
		SpellVFX.aura_ring(target, str(spell.get("sphere", "")), "buff")
	else:
		SpellVFX.ground_dust(target)


## Whether the target has a permanent aura (resistance/shield/wind).
func _has_persistent_aura(target: Node2D) -> bool:
	if not is_instance_valid(target):
		return false
	for c in target.get_children():
		if c is SpellAura:
			return true
	return false


## Permanent auras by effect type: shield — a grid, resistance — a glow
## above the head in the element colour, haste — wind at the feet.
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

## Spell projectile (with animation from assets/projectiles/<folder>/).
## If there is no projectile folder (no effect — Haste/Invisibility/Summon...),
## we apply the spell instantly without a flying projectile.
func _fire_spell_projectile(name: String, sphere: String, dmg: int, area: float,
		target_position: Vector2, power_override: float = -1.0) -> void:
	var final_dmg := Game.spell_damage(self, name, sphere, dmg, power_override)
	if SpellDB.projectile_folder(name) == "":
		# No projectile effect: instant damage at the target/point (e.g. Animate_Dead).
		var enemy := get_nearest_enemy(target_position, 120.0)
		if enemy != null:
					Game.deal_damage(enemy, final_dmg, "magic", sphere, self)
		return
	if area > 0.0:
		# Area: flies to the point, explodes (radius damage from projectile.gd)
		create_spell_projectile(name, cast_origin(), target_position, final_dmg, area)
	else:
		# Single target: the projectile flies to the enemy near the aim point
		var enemy := get_nearest_enemy(target_position, 200.0)
		var to := enemy.global_position if enemy != null else target_position
		create_spell_projectile(name, cast_origin(), to, final_dmg, 0.0)

## Create a projectile with phase animation from the projectile folder.
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
	# Before, the projectile was added to get_tree().root and survived a scene change
	# (restart/portal), holding a reference to a freed hero.
	var scene_root := get_tree().current_scene
	if scene_root != null:
		scene_root.add_child(p)
	else:
		get_tree().root.add_child(p)

## Heal the selected target (the hero by default): HP, but not above the maximum.
## The amount = spell base * power_coef * (1 + spell_power/100) —
## the same formula as damage (before, a separate mind/5 stood here).
func _heal_target(target: Node2D, spell_name: String, base: int) -> void:
	if target == null or not is_instance_valid(target):
		target = self
	var sphere := SpellDB.sphere_of(spell_name)
	var amount := Game.spell_damage(self, spell_name, sphere, maxi(1, -base))
	var before: Variant = target.get("current_hp")
	target.call("heal_amount", amount)
	# A red cross above the head — before, the healing was visible only as a number.
	var after: Variant = target.get("current_hp")
	if after is int and before is int and int(after) > int(before):
		SpellAura.heal_cross(target)


## Restore HP to self or an ally. Returns the amount actually restored.
func heal_amount(amount: int) -> int:
	if amount <= 0 or current_hp >= max_hp:
		return 0
	if state == "dead" or state == "decay" or state == "corpse":
		return 0
	var healed := mini(max_hp, current_hp + amount) - current_hp
	if healed <= 0:
		return 0
	current_hp += healed
	DamageNumber.show_at(global_position, healed, "heal")
	if health_bar:
		health_bar.update_bars(current_hp, current_mana)
	return healed

## Prismatic radiance: lightning from the mage to several targets at once.
## Before it was a single projectile — one hit, while the name
## "radiance" promised a fan-out strike. Targets — up to CHAIN_MAX nearest enemies
## within area of the cast point; lightning is drawn between them.
## The radius of the fan around the aim point. Before, it was also the target search radius
## (max(area, 96) = 96 px), and the tightness was not in the fan but in the fact that targets were searched
## from the CURSOR without any check of the distance to the mage.

func _cast_chain_spell(spell_name: String, spell: Dictionary, sphere: String,
		dmg: int, area: float, target_position: Vector2,
		power_override: float = -1.0) -> void:
	var origin := cast_origin()
	# Spell range is the only reach limit. Before, it was not
	# read from the database at all, and a click 260 px away hit enemies there, no matter how
	# far from the mage they stood: the lightning flew across half the map.
	var reach := SpellDB.range_of(spell_name)
	var targets: Array = _chain_targets(target_position, maxf(area, GameConfig.getf("magic", "chain_radius")),
		origin, reach)
	if targets.is_empty():
		# Nobody in reach — we strike the aim point so the cast is not wasted
		# for nothing.
		_fire_spell_projectile(spell_name, sphere, dmg, area, target_position,
			power_override)
		return
	# Damage through the shared Game.spell_damage: spell power, mind and skill must
	# affect "radiance" the same as projectiles. Before, the raw
	# dmg from the database was passed here, and prismatic radiance was the only spell
	# that completely ignored the mage's progression.
	var final_dmg := Game.spell_damage(self, spell_name, sphere, dmg, power_override)
	# Each target gets its own rainbow colour, otherwise all beams came out in the sphere colour.
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


## Living enemies in the fan around aim, but not farther than reach from the caster point.
##
## ENEMIES only: the beams come from the mage, and hitting allies, neutral residents or
## mercenaries with "prismatic radiance" is wrong — this is damage to enemies.
##
## The two limits do different things and both are needed:
##   * reach (spell range) — the hard reach from the mage;
##   * radius (fan) — the size of the flash around the aim, that is the aim still
##     picks who to hit first. Without sorting by aim, in a fight with a crowd
##     the target would be picked at random.
func _chain_targets(aim: Vector2, radius: float, origin: Vector2,
		reach: float) -> Array:
	var found: Array = []
	for e in Game.enemies:
		if e == null or not is_instance_valid(e):
			continue
		# Node.get() in Godot 4 takes ONE argument, so the
		# corpse state is checked through "a field on the node", not get("state", "").
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
	# We sort by distance to the aim point so the beams fan out from the target.
	found.sort_custom(func(a: Node2D, b: Node2D) -> bool:
		return a.global_position.distance_squared_to(aim) \
			< b.global_position.distance_squared_to(aim))
	var out: Array = []
	for e in found:
		if out.size() >= GameConfig.geti("magic", "chain_max_targets"):
			break
		out.append(e)
	return out


## Wall (Wall of Fire / Wall of Earth). In the original they are DIFFERENT
## (spells.txt): fire burns continuously, earth is an impassable barrier.
## Before it was a 32×32 ColorRect for 2 seconds: no damage and no blocking.
## The wall size is set in CELLS (zone_cells) — by the player's decision 6 × 2,
## and damage, sprite and blocking all take their size from the same rectangle.
func _create_wall(target_position: Vector2, spell_name: String, sphere: String,
		power_override: float = -1.0) -> void:
	var spell := SpellDB.get_spell(spell_name)
	var mode := str(spell.get("wall_mode", "damage"))
	var life := float(spell.get("wall_life", 6.0))
	var cells := _zone_cells(spell, Vector2i(6, 2))
	# Wall orientation: PERPENDICULAR to the cast direction. Looking left or
	# right — the wall stands vertically (2×6), looking up/down — it lies
	# horizontally (6×2). Player 28.10: "the magic should stand vertically".
	var aim := target_position - cast_origin()
	if absf(aim.x) >= absf(aim.y):
		cells = Vector2i(2, 6)
	var dmg := 0
	if mode != "block":
		dmg = Game.spell_damage(self, spell_name, sphere, int(spell.get("damage", 0)),
			power_override)
	SpellVFX.spawn_wall(target_position, sphere, self, life, mode, cells, dmg)


## A zone with a duration: blizzard and poison cloud. Before it was a single
## projectile with one hit — "blizzard" threw one meteor, and "cloud" left
## nothing behind, although both have a 5–6 second dot in the database.
func _create_zone(target_position: Vector2, spell_name: String, sphere: String,
		power_override: float = -1.0) -> void:
	var spell := SpellDB.get_spell(spell_name)
	var style := str(spell.get("zone_style", "cloud"))
	var life := float(spell.get("zone_life", 4.0))
	var cells := _zone_cells(spell, Vector2i(3, 3))
	var dmg := Game.spell_damage(self, spell_name, sphere, int(spell.get("damage", 0)),
		power_override)
	SpellVFX.spawn_zone(target_position, style, sphere, self, life, cells, dmg, 0.5)
	# The zone deals damage and effects (slow, poison) to everyone standing in it.
	StatusEffects.apply_area(target_position, _zone_radius(cells), spell, self)


## The zone size in cells from the database; if the field is missing, the default value.
func _zone_cells(spell: Dictionary, fallback: Vector2i) -> Vector2i:
	var raw: Variant = spell.get("zone_cells", null)
	if raw is Array and (raw as Array).size() >= 2:
		return Vector2i(maxi(1, int((raw as Array)[0])), maxi(1, int((raw as Array)[1])))
	return fallback


## The zone radius in pixels — half its diagonal, for area effects.
func _zone_radius(cells: Vector2i) -> float:
	return Vector2(cells.x * 32, cells.y * 32).length() * 0.5


## Animate_Dead: raise the nearest corpse as an ally for lifespan seconds.
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


## Light (Astral, self): a soft bright sphere around the hero for a few seconds.
## A visual flash marker (the project has no lighting system).
func _cast_light() -> void:
	SpellVFX.spawn_light(global_position, 4.0)

## Summon (Astral, self): an allied minion (a mercenary with a monster set),
## follows the hero and attacks enemies, disappears after 45 seconds (or on death).
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

## Teleport to a point (within the map).
## Teleport to the aim point. The player picks the point (target "point" in the database),
## before the spell was target "self" — there was no targeting, and the hero simply
## did not move anywhere. A refusal due to an impassable cell is now visible.
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

## Area damage around a point (map objects and enemies) through Game.deal_damage_area.
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

## Learn a magic book (mage only, forever): an element book opens the whole
## sphere ("Book Fire"), a single-spell book — only that spell ("Book Fire Arrow").
## The book is spent (leaves the inventory). true — if something was learned.
func learn_book(item_name: String) -> bool:
	if not has_mana:
		return false   # a warrior cannot read magic books
	var sphere := SpellDB.sphere_of_book(item_name)
	var gained: Array = []
	if sphere != "":
		sphere_books[sphere] = true
		for spell in SpellDB.spells_of_sphere(sphere):
			if not known_spells.has(spell):
				known_spells[spell] = {"charges": -1}
				gained.append(spell)
		if gained.is_empty():
			return false   # the whole sphere is already learned — we do not spend the book
		print("Изучена книга стихии %s: +%d заклинаний" % [sphere, gained.size()])
	else:
		var spell := SpellDB.spell_of_book(item_name)
		if spell == "":
			return false
		if known_spells.has(spell) and spell_charges(spell) == -1:
			return false   # already learned forever — we do not spend the book
		known_spells[spell] = {"charges": -1}
		gained.append(spell)
		print("Выучено заклинание из книги: %s" % spell)
	remove_item(item_name)
	return true

## Read a scroll (NON-mage): +1 spell charge per scroll, and the scroll
## is spent. The mage reads scrolls WITH TARGETING from the inventory (see apply_scroll_to_target),
## charges do not accumulate in the magic panel for them.
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

func _create_lightning_effect(from: Vector2, to: Vector2):
	var line = Line2D.new()
	line.width = 3.0
	line.default_color = Color(0.3, 0.6, 1.0, 1.0)
	line.add_point(from)
	
	# Lightning zigzag
	var steps = 8
	for i in range(1, steps):
		var t = float(i) / steps
		var mid = from.lerp(to, t)
		mid.x += randf_range(-20, 20)
		mid.y += randf_range(-20, 20)
		line.add_point(mid)
	
	line.add_point(to)
	get_tree().root.add_child(line)
	
	# A flash at the impact point
	var flash = ColorRect.new()
	flash.color = Color(0.5, 0.7, 1.0, 0.8)
	flash.position = to - Vector2(15, 15)
	flash.size = Vector2(30, 30)
	get_tree().root.add_child(flash)
	
	# Remove after 0.3 seconds
	var timer = get_tree().create_timer(0.3)
	timer.timeout.connect(func():
		if is_instance_valid(line): line.queue_free()
		if is_instance_valid(flash): flash.queue_free()
	)

## Mage auto-cast: healing when HP drops + auto-buffs by tier.
## Does not interrupt manual targeting (pending_spell) and does not work while casting.
var _auto_buff_accum := 0.0
var _auto_heal_accum := 0.0
var _auto_scroll_accum := 0.0


## Mage auto-magic: healing self and the target + buffs by the level from settings.
##
## Before, healing turned on ONLY if the player had manually assigned a heal to RMB
## (`Game.auto_spell`) — by default the mage did not heal at all, even out of combat
## (report 27.10). Now the auto-magic level defaults to "Basic",
## and healing happens by itself while there is mana and the spell is known.
func _tick_auto_cast(delta: float) -> void:
	if state == "casting" or state == "dead" or state == "corpse" \
			or not Game.pending_spell.is_empty():
		return
	if not Game.pending_scroll.is_empty():
		return
	# WARRIOR: no auto-magic levels at all. Only ONE scroll marked
	# with the right button in the magic book, and self only (player 28.10: "a warrior must
	# not be a replacement for a mage").
	if not has_mana:
		_tick_auto_scroll(delta)
		return
	if Game.auto_buff_tier == "none":
		return
	var ratio := GameConfig.getf("magic", "auto_heal_ratio")
	if ratio <= 0.0:
		ratio = 0.45
	# 1) Healing — once per second: 45 % HP threshold, the target from settings.
	_auto_heal_accum += delta
	if _auto_heal_accum >= 1.0:
		_auto_heal_accum = 0.0
		var heal_spell := _auto_heal_spell()
		if heal_spell != "":
			_auto_try_heal(heal_spell, ratio)
	# 2) Buffs by level: one buff per interval so as not to burn mana.
	_auto_buff_accum += delta
	var interval := GameConfig.getf("magic", "auto_buff_interval")
	if interval <= 0.0:
		interval = 2.0
	if _auto_buff_accum >= interval:
		_auto_buff_accum = 0.0
		_auto_try_buffs()


## Auto-cast of the single marked scroll (warrior): self only,
## on the spell cooldown, exactly one scroll per cast.
##
## Safety net against "bought 10 scrolls and burned them in a second": no cast if
## we are already casting, if the spell cooldown has not passed, if the effect is still up
## (for a buff) or HP is above the threshold (for healing).
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
		# Combat scrolls on self are pointless — auto-cast is not assigned.
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
	# Cooldown — by the magic inside the scroll (50/100), not by using the item.
	cast_cooldowns[spell] = Game.spell_cooldown(self, spell, scroll_power)
	_cast_spell_effect(spell, SpellDB.get_spell(spell), global_position, self,
		scroll_power)
	_apply_spell_experience(SpellDB.sphere_of(spell))


## Which heal to use (mage): the manually chosen one (RMB on the book), otherwise the first
## LEARNED healing spell. Scroll charges do not get in here —
## a mage's scrolls are cast manually only.
func _auto_heal_spell() -> String:
	if Game.auto_spell != "" and known_spells.has(Game.auto_spell) \
			and SpellDB.kind_of(Game.auto_spell) == "heal" \
			and spell_charges(Game.auto_spell) == -1:
		return Game.auto_spell
	for sn in known_spells.keys():
		if SpellDB.kind_of(str(sn)) == "heal" and spell_charges(str(sn)) == -1:
			return str(sn)
	return ""


## Who to heal and buff — ONE target list (the setting "Me only / Me and my
## party / Me, my party and neutrals").
## Before, for the "party" mode only `Game.party` (mercenaries) was iterated, and the
## mage is not in it — so they neither healed nor buffed themself.
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


## Buff spells by auto-magic level.
##
## Basic — what is always needed: haste and shield. Medium adds
## blessing and wards against the four elements. Maximum — invisibility as well.
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
		# Auto-magic levels — for LEARNED spells only (mage).
		# Scroll charges are not spent by level: a warrior has one auto-cast and it is set by RMB.
		if spell_charges(sn) != -1:
			continue
		if not can_cast(sn):
			continue
		# Shield (kind "self") applies to the caster only: on an ally
		# the spell would apply to itself anyway, but it would burn mana and
		# cooldown "into the void".
		var self_only := SpellDB.kind_of(sn) == "self"
		var tkind := SpellDB.target_of(sn)
		var rng := SpellDB.range_of(sn)
		for u in candidates:
			if not is_instance_valid(u):
				continue
			if self_only and u != self:
				continue
			# Already under the buff? We look at the EFFECT'S OWN SPHERE, not the spell's.
			# Haste/Bless/Shield/Invisibility have no `sphere` field in the effect, and
			# the check by the spell sphere ("Astral") never matched —
			# the mage recast haste every 10 s while it lasted 20 s.
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
			# Invisibility on self — only if the target == self (the mage shield/mana)
			if sn == "Invisibility" and u != self and rng <= 0.0:
				continue
			if rng > 0.0 and Game.units_range(self, u) > rng:
				continue
			# Protection range 0: self only (or touch — units_range==0)
			if rng <= 0.0 and u != self and Game.units_range(self, u) > 1.0:
				continue
			cast_spell(sn, u.global_position, u)
			return  # one buff per tick — we do not burn mana


func take_damage(damage: int, _attacker: Node2D) -> int:
	# A dead hero takes no more damage
	if state == "dead" or state == "decay" or state == "corpse":
		return 0
	damage = Game.shield_reduce(self, damage)
	if damage <= 0:
		SpellVFX.shield_hit(self)
		SoundDB.play("combat.hit.shield", -6.0)
		return 0
	current_hp -= damage
	# Invisibility breaks on damage, spell preparation — is interrupted
	StatusEffects.break_invisibility(self)
	_cancel_casting()
	if current_hp <= 0:
		# Death: play the DYING fall + DECAY decomposition, then pause
		velocity = Vector2.ZERO
		state = "dead"
		_path.clear()
		Game.player_target = global_position
		_hero_voice("death", 1)
		if health_bar:
			health_bar.visible = false
	elif randf() < 0.45:
		_hero_voice("pain", randi_range(1, 2))
	return damage
