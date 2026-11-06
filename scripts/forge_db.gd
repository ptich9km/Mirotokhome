class_name ForgeDB
extends RefCounted
## Master forge: +1..+7 on a crafted item (04.11).
##
## Quality stays a craft result (Crafted/Fine/Master). The master only raises
## the plus level, and every plus rolls one class-appropriate bonus. The roll is
## stored as a seed inside the item key, so plain-string inventories and saves
## still keep two copies apart.
##
## Costs: common catalyst (Magic Essence) + the item's own material. +6/+7 also
## need a Boss Core and are not guaranteed: failure keeps the item (soft fail).

const MAX_PLUS := 7
const ESSENCE_KEY := "Magic Essence"
const BOSS_CORE := "Boss Core"

## Minimum mastering skill for a target plus. +1..+3 are open to everyone.
const SKILL_REQ := [0, 0, 0, 0, 10, 20, 40, 60]
## Quality cap: a Crafted item cannot reach +7.
## Only gear the hero crafted himself can be improved. Loot, starter and
## vendor items are not masterwork material - they do not even appear in the
## master's list.
const QUALITY_CAP := {
	"Crafted": 3,
	"Crafted Fine": 5,
	"Crafted Master": 7,
}
const SUCCESS := {6: 40, 7: 25}


static func is_forgeable(item: Dictionary) -> bool:
	return QUALITY_CAP.has(str(item.get("quality", "")))


static func cap_for(item: Dictionary, player: Player) -> int:
	var cap := int(QUALITY_CAP.get(str(item.get("quality", "")), 0))
	if cap <= 0 or not is_instance_valid(player):
		return 0
	var skill := player.skill_value("mastering")
	for plus in range(1, MAX_PLUS + 1):
		if skill < int(SKILL_REQ[plus]):
			cap = mini(cap, plus - 1)
			break
	return cap


static func next_plus(item: Dictionary) -> int:
	return ItemDB.plus_of(str(item.get("key", ""))) + 1


static func success_chance(target: int) -> int:
	return int(SUCCESS.get(target, 100))


## Everything the next step asks for. An empty target (>cap or max) gives {}.
static func cost(item: Dictionary, target: int = -1) -> Dictionary:
	if target < 0:
		target = next_plus(item)
	if target <= 0 or target > MAX_PLUS:
		return {}
	var ingot_key := ItemDB.ingot_key(str(item.get("material", "")))
	var resource_key := ingot_key if ingot_key != "" else CraftDB.FABRIC_KEY
	var ingot_n: int = [0, 2, 3, 4, 5, 6, 8, 10][target]
	var essence_n: int = [0, 1, 1, 2, 2, 3, 4, 5][target]
	var boss_n: int = 1 if target == 6 else (2 if target == 7 else 0)
	return {
		"resource": resource_key,
		"resource_count": ingot_n,
		"essence": essence_n,
		"boss_core": boss_n,
	}


static func can_upgrade(item: Dictionary, player: Player) -> String:
	if not is_instance_valid(player) or item.is_empty():
		return "Нет предмета"
	if not ItemDB.is_equippable(item):
		return "Это не снаряжение"
	if not is_forgeable(item):
		return "Улучшать можно только скравченные героем вещи"
	var plus := ItemDB.plus_of(str(item.get("key", "")))
	if plus >= MAX_PLUS:
		return "Уже +7"
	var cap := cap_for(item, player)
	if plus + 1 > cap:
		if cap <= 0:
			return "Это качество не улучшается"
		return "Нужен навык мастера для +%d" % (plus + 1)
	return ""


static func _has(player: Player, key: String, need: int) -> bool:
	if need <= 0:
		return true
	var n := 0
	for raw in player.inventory:
		if str(raw) == key:
			n += 1
	return n >= need


static func _spend(player: Player, key: String, need: int) -> void:
	for _i in need:
		player.remove_item(key)


## Main action. Returns {"ok", "message", "new_key"}.
static func upgrade(player: Player, key: String,
		rng: RandomNumberGenerator = null, roll_override: int = -1) -> Dictionary:
	var item := ItemDB.find(key)
	if item.is_empty():
		return {"ok": false, "message": "Предмет не найден", "new_key": ""}
	var block := can_upgrade(item, player)
	if block != "":
		return {"ok": false, "message": block, "new_key": key}
	var target := next_plus(item)
	var c := cost(item, target)
	var resource := str(c.get("resource", ""))
	var need_res := int(c.get("resource_count", 0))
	var need_ess := int(c.get("essence", 0))
	var need_boss := int(c.get("boss_core", 0))
	if not _has(player, resource, need_res):
		return {"ok": false, "message": "Не хватает: %s" % _name_of(resource), "new_key": key}
	if not _has(player, ESSENCE_KEY, need_ess):
		return {"ok": false, "message": "Не хватает: %s" % _name_of(ESSENCE_KEY), "new_key": key}
	if not _has(player, BOSS_CORE, need_boss):
		return {"ok": false, "message": "Не хватает: %s" % _name_of(BOSS_CORE), "new_key": key}

	_spend(player, resource, need_res)
	_spend(player, ESSENCE_KEY, need_ess)
	_spend(player, BOSS_CORE, need_boss)

	var chance := success_chance(target)
	var roll := roll_override
	if roll < 0:
		roll = rng.randi_range(0, 99) if rng != null else randi() % 100
	var success := chance >= 100 or roll < chance
	if success:
		# Keep the item's seed: the first N bonuses must not reroll when the
		# next plus is added (the seed is what makes +1..+5 stable).
		var seed := str(ItemDB.split_plus_key(key).get("seed", ""))
		if seed == "":
			seed = "%x" % (randi() & 0xffff)
		var new_key := ItemDB.plus_key(ItemDB.base_key(key), target, seed)
		_replace(player, key, new_key)
		player.gain_skill_exp("mastering", 15 + target * 5)
		return {"ok": true, "message": "Улучшено до +%d" % target, "new_key": new_key}

	# Soft fail: the item survives. A +7 attempt from +6 falls back to +5 by
	# the player's decision; a +6 attempt stays at +5.
	var fallback := 5 if target >= 6 else ItemDB.plus_of(key)
	var new_key := key
	if fallback < ItemDB.plus_of(key):
		var seed := str(ItemDB.split_plus_key(key).get("seed", ""))
		new_key = ItemDB.plus_key(ItemDB.base_key(key), fallback, seed)
		_replace(player, key, new_key)
	player.gain_skill_exp("mastering", 5)
	return {"ok": false, "message": "Неудача — вещь осталась", "new_key": new_key}


static func _replace(player: Player, old_key: String, new_key: String) -> void:
	if old_key == new_key:
		return
	player.remove_item(old_key)
	player.add_item(new_key)
	for slot in player.equipped:
		if str(player.equipped[slot]) == old_key:
			player.equipped[slot] = new_key


static func _name_of(key: String) -> String:
	var it := ItemDB.find(key)
	if it.is_empty():
		return key
	return str(it.get("name_ru", key))
