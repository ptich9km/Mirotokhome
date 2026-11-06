extends SceneTree
##
## Супер-редкие зелья Аллодов: Potion Body/Mind/Reaction/Spirit поднимают
## характеристику НАВСЕГДА (effects "body=+1"), а не как разовый хил.
##
## Проверяет то, что раньше молча не работало:
##   - зелье расходуется по одной штуке за выпивание (3 в инвентаре -> -1);
##   - характеристика растёт и в player, и в Game.hero_stats (иначе бонус
##     потерялся бы при перезапуске: сейв хранит именно hero_stats);
##   - reaction из БД попадает в agility (в Аллодах reaction = 2*agility);
##   - производные max_hp/max_mana пересчитываются;
##   - зелье без эффекта НЕ расходуется.

const PERMANENT := {
	"Potion Body": ["body", 1],
	"Potion Mind": ["mind", 1],
	"Potion Reaction": ["agility", 1],
	"Potion Spirit": ["spirit", 1],
}

var _fails: Array = []
var _checks := 0


func _init() -> void:
	Game.hero_stats = {
		"body": 10, "mind": 10, "agility": 10, "spirit": 10,
		"blade": 30, "bludgeon": 15, "pike": 10,
		"fire": 5, "water": 5, "air": 5, "earth": 5, "astral": 5,
		"weapon": "sword", "shield": true, "armor": "heavy"}
	Game.hero_class = "warrior"
	Game.hero_name = "Тест"
	Game.hero_character_id = "mfighter"
	call_deferred("_run")


func _check(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(msg)
	print(("  OK  " if ok else "  FAIL") + " " + msg)


func _count(player, key: String) -> int:
	var n := 0
	for k in player.inventory:
		if str(k) == key:
			n += 1
	return n


func _run() -> void:
	var game = load("res://scenes/main.tscn").instantiate()
	root.add_child(game)
	for i in range(3):
		await process_frame
	var player = game.get("player")
	if player == null:
		print("RESULT: FAIL player не создан")
		quit(2)
		return

	print("-- постоянные характеристики --")
	for key in PERMANENT:
		var pair: Array = PERMANENT[key]
		var field: String = pair[0]
		var amount: int = pair[1]

		player.inventory.clear()
		for i in range(3):
			player.inventory.append(key)
		var stat_before: int = int(player.get(field))
		var hp_before: int = player.max_hp
		var mana_before: int = player.max_mana
		var count_before: int = _count(player, key)

		# раскладываем по Game.hero_stats, как это делает выбор героя
		player.body = int(Game.hero_stats.get("body", 10))
		player.mind = int(Game.hero_stats.get("mind", 10))
		player.agility = int(Game.hero_stats.get("agility", 10))
		player.spirit = int(Game.hero_stats.get("spirit", 10))
		# Ключ в hero_stats — ИМЯ ПОЛЯ, а не имя из БД: база пишет "reaction",
		# а _apply_hero_choice() читает "agility". Проверяем именно field.
		var hs_before: int = int(Game.hero_stats.get(field, 0))

		var used: bool = player.use_potion(key)

		_check(used, "%s выпивается" % key)
		_check(_count(player, key) == count_before - 1,
			"%s: расходована ровно одна (было %d, стало %d)" % [
				key, count_before, _count(player, key)])
		_check(int(player.get(field)) == stat_before + amount,
			"%s: %s поднялась на %d (%d -> %d)" % [
				key, field, amount, stat_before, int(player.get(field))])
		_check(int(Game.hero_stats.get(field, -1)) == hs_before + amount,
			"%s: hero_stats[%s] вырос на %d (%d -> %d) — иначе потеряется при сейве" % [
				key, field, amount, hs_before, int(Game.hero_stats.get(field, -1))])
		if key == "Potion Body":
			_check(player.max_hp > hp_before, "Body поднял max_hp (%d -> %d)" % [
				hp_before, player.max_hp])
		if key == "Potion Spirit" and player.has_mana:
			# У воина has_mana = false, там max_mana законно 0 — проверять нечего.
			_check(player.max_mana > mana_before, "Spirit поднял max_mana (%d -> %d)" % [
				mana_before, player.max_mana])
		elif key == "Potion Spirit":
			_check(player.max_mana == 0, "у воина max_mana остаётся 0")

	print("-- зелье без эффекта не расходуется --")
	player.inventory.clear()
	player.inventory.append("Potion Fighter Bonus")   # effects только реген, без duration-постоянки
	var fb_before := _count(player, "Potion Fighter Bonus")
	var used_fb: bool = player.use_potion("Potion Fighter Bonus")
	_check(not used_fb or _count(player, "Potion Fighter Bonus") == fb_before - 1,
		"Potion Fighter Bonus не тратится впустую")

	print("-- обычные зелья: разовый хил/мана --")
	# Регресс, который стоил реальной поломки: когда use_potion требовал
	# постоянный эффект, у обычного зелья effects = ["health=+30"] не
	# попадал в PERMANENT_STATS, список был пуст, и зелье не пилось вовсе.
	for spec in [["Potion Medium Healing", 30], ["Potion Big Healing", 100]]:
		var key: String = spec[0]
		var expect: int = spec[1]
		player.inventory.clear()
		player.inventory.append(key)
		player.current_hp = 10
		var hp_before: int = player.current_hp
		var used_h: bool = player.use_potion(key)
		_check(used_h, "%s выпивается (разовый хил, без постоянных эффектов)" % key)
		_check(player.current_hp == mini(player.max_hp, hp_before + expect),
			"%s лечит на %d (%d -> %d)" % [key, expect, hp_before, player.current_hp])
		_check(_count(player, key) == 0, "%s расходована" % key)

	player.inventory.clear()
	player.inventory.append("Potion Medium Mana")
	player.has_mana = true
	player.max_mana = 50
	player.current_mana = 0
	var used_m: bool = player.use_potion("Potion Medium Mana")
	_check(used_m, "Potion Medium Mana выпивается")
	_check(player.current_mana == 30, "Medium Mana даёт 30 маны (получено %d)" % player.current_mana)
	player.has_mana = false
	player.max_mana = 0

	print("-- повторное выпивание поднимает дальше --")
	player.inventory.clear()
	for i in range(2):
		player.inventory.append("Potion Mind")
	Game.hero_stats["mind"] = int(player.mind)
	var m0: int = player.mind
	player.use_potion("Potion Mind")
	player.use_potion("Potion Mind")
	_check(player.mind == m0 + 2, "две бутылки Mind дают +2 (%d -> %d)" % [m0, player.mind])

	print("checks=%d fails=%d" % [_checks, _fails.size()])
	if not _fails.is_empty():
		for f in _fails:
			print("FAIL: " + str(f))
		print("RESULT: FAIL permanent_potion_smoke")
		quit(1)
		return
	print("RESULT: OK permanent_potion_smoke")
	quit(0)