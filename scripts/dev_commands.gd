class_name DevCommands
extends RefCounted
## Whitelisted commands behind the in-game developer console.
## This is deliberately not a GDScript evaluator: a typo must not become code.

const PRIMARY_STATS := ["body", "agility", "mind", "spirit"]
const COMBAT_SKILLS := [
	"blade", "axe", "bludgeon", "pike", "shooting",
	"fire", "water", "air", "earth", "astral",
]
const SKILL_CAP := 200
const STAT_CAP := 100000

var _main: Node2D = null

func setup(main_node: Node2D) -> void:
	_main = main_node

func execute(line: String) -> Dictionary:
	var parts := line.strip_edges().trim_prefix("/").split(" ", false)
	if parts.is_empty():
		return _result(false, Loc.t("ui.dev.unknown"))
	var command := parts[0].to_lower()
	match command:
		"help":
			return _result(true, Loc.t("ui.dev.help"))
		"stats":
			return _stats()
		"buff":
			return _buff(parts)
		"heal":
			return _heal()
		"gold":
			return _gold(parts)
		"give":
			return _give(parts)
		"skill":
			return _skill(parts)
		"zone":
			return _zone(parts)
		"net":
			return _net_status()
		"kimi":
			return _kimi(parts)
	return _result(false, Loc.f("ui.dev.unknown_command", [command]))

func _hero() -> Player:
	return Game.hero as Player

func _result(ok: bool, text: String) -> Dictionary:
	return {"ok": ok, "text": text}

func _stats() -> Dictionary:
	var hero := _hero()
	if hero == null:
		return _result(false, Loc.t("ui.dev.no_hero"))
	return _result(true, Loc.f("ui.dev.stats", [hero.body, hero.agility, hero.mind,
		hero.spirit, hero.current_hp, hero.max_hp, hero.current_mana, hero.max_mana, hero.gold]))

func _buff(parts: PackedStringArray) -> Dictionary:
	var hero := _hero()
	if hero == null:
		return _result(false, Loc.t("ui.dev.no_hero"))
	var multiplier := 10
	if parts.size() > 1:
		if not parts[1].is_valid_int():
			return _result(false, Loc.t("ui.dev.buff_usage"))
		multiplier = int(parts[1])
	if multiplier < 2 or multiplier > 100:
		return _result(false, Loc.t("ui.dev.buff_usage"))
	for field in PRIMARY_STATS:
		var value := mini(STAT_CAP, maxi(1, int(hero.get(field)) * multiplier))
		hero.set(field, value)
		Game.hero_stats[field] = value
	for skill in COMBAT_SKILLS:
		var current := hero.skill_value(skill)
		if current <= 0:
			continue
		var value := mini(SKILL_CAP, current * multiplier)
		hero.set_skill_field(skill + "_skill", value)
		Game.hero_stats[skill] = value
	hero._recall_derived()
	hero.current_hp = hero.max_hp
	hero.current_mana = hero.max_mana
	_refresh_inventory()
	return _result(true, Loc.f("ui.dev.buffed", [multiplier]))

func _heal() -> Dictionary:
	var hero := _hero()
	if hero == null:
		return _result(false, Loc.t("ui.dev.no_hero"))
	hero.current_hp = hero.max_hp
	hero.current_mana = hero.max_mana
	return _result(true, Loc.t("ui.dev.healed"))

func _gold(parts: PackedStringArray) -> Dictionary:
	var hero := _hero()
	if hero == null:
		return _result(false, Loc.t("ui.dev.no_hero"))
	if parts.size() != 2 or not parts[1].is_valid_int():
		return _result(false, Loc.t("ui.dev.gold_usage"))
	var amount := int(parts[1])
	if amount < 1 or amount > 1000000000:
		return _result(false, Loc.t("ui.dev.gold_usage"))
	hero.add_gold(amount)
	_refresh_inventory()
	return _result(true, Loc.f("ui.dev.gold_added", [amount, hero.gold]))

func _give(parts: PackedStringArray) -> Dictionary:
	var hero := _hero()
	if hero == null:
		return _result(false, Loc.t("ui.dev.no_hero"))
	if parts.size() < 2:
		return _result(false, Loc.t("ui.dev.give_usage"))
	var tail := ""
	for i in range(1, parts.size()):
		if i > 1:
			tail += " "
		tail += parts[i]
	tail = tail.strip_edges()
	var count := 1
	var split_at := tail.rfind(" ")
	if split_at > 0:
		var suffix := tail.substr(split_at + 1).strip_edges()
		if suffix.is_valid_int():
			count = int(suffix)
			tail = tail.substr(0, split_at).strip_edges()
	if count < 1 or count > 99 or ItemDB.find(tail).is_empty():
		return _result(false, Loc.f("ui.dev.give_bad", [tail]))
	for _i in range(count):
		hero.add_item(tail)
	_refresh_inventory()
	return _result(true, Loc.f("ui.dev.given", [count, tail]))

func _skill(parts: PackedStringArray) -> Dictionary:
	var hero := _hero()
	if hero == null:
		return _result(false, Loc.t("ui.dev.no_hero"))
	if parts.size() != 3 or not COMBAT_SKILLS.has(parts[1]) or not parts[2].is_valid_int():
		return _result(false, Loc.t("ui.dev.skill_usage"))
	var value := int(parts[2])
	if value < 0 or value > SKILL_CAP:
		return _result(false, Loc.t("ui.dev.skill_usage"))
	var skill := parts[1]
	hero.set_skill_field(skill + "_skill", value)
	Game.hero_stats[skill] = value
	_refresh_inventory()
	return _result(true, Loc.f("ui.dev.skill_set", [skill, value]))

func _zone(parts: PackedStringArray) -> Dictionary:
	if parts.size() != 2:
		return _result(false, Loc.t("ui.dev.zone_usage"))
	if NetSession.is_net_game():
		return _result(false, Loc.t("ui.dev.zone_net"))
	if _main == null or not _main.has_method("travel_to_zone"):
		return _result(false, Loc.t("ui.dev.no_hero"))
	var destination := parts[1].to_lower()
	var wm := Game._world_map()
	if not wm.has(destination) and str(wm.sector_for_tier(destination)) == "":
		return _result(false, Loc.f("ui.dev.zone_bad", [destination]))
	_main.call("travel_to_zone", destination)
	return _result(true, Loc.f("ui.dev.zone_started", [destination]))

func _net_status() -> Dictionary:
	var session := NetSession.active()
	if session == null:
		return _result(true, Loc.t("ui.dev.net_offline"))
	return _result(true, Loc.f("ui.dev.net_status", [session.role, session.port,
		session.other_peer(), str(session.world.get("zone", "")), str(session.world.get("sector", ""))]))

func _kimi(parts: PackedStringArray) -> Dictionary:
	if parts.size() != 2 or not NetSession.BOT_ORDERS.has(parts[1]):
		return _result(false, Loc.t("ui.dev.kimi_usage"))
	var session := NetSession.active()
	if session != null and session.other_peer() != 0:
		session.send_bot_command(parts[1])
		return _result(true, Loc.f("ui.dev.kimi_sent", [parts[1]]))
	# Single-player: drive the local hero with the same bot FSM.
	var hero := _hero()
	if hero == null:
		return _result(false, Loc.t("ui.dev.no_hero"))
	var bot := _find_or_create_bot(hero)
	bot.set_mode(parts[1])
	return _result(true, Loc.f("ui.dev.kimi_local", [parts[1]]))

func _find_or_create_bot(hero: Player) -> NetBotController:
	var main := _main
	if main == null:
		push_error("DevCommands: no main node for local bot")
		return null
	var existing := main.get_node_or_null("LocalBotController") as NetBotController
	if existing != null:
		return existing
	var bot := NetBotController.new()
	bot.name = "LocalBotController"
	main.add_child(bot)
	bot.setup(hero)
	return bot

func _refresh_inventory() -> void:
	if _main == null:
		return
	var ui := _main.get("ui") as CanvasLayer
	if ui != null and ui.has_method("refresh_inventory"):
		ui.call("refresh_inventory")
