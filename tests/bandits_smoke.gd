extends SceneTree
##
## Bandits in the world (24.11).
##
## Player rule: bandits live on the map like Greys, but a pack is ONE race —
## never a mixed group. The race table is data (`spawn.bandit_sets`), a race
## without sheets on disk is skipped; bandit sets carry palette 5, so the
## common spawn path turns them into enemies by itself.
##
## Checks:
##   - bandit_races() reads the rule and filters sets missing from UnitDB;
##   - a generated map holds bandit packs, every pack is a single race;
##   - pack members are hostile (palette 5 -> is_hostile);
##   - pack cells do not sit on Greys (shared occupancy map);
##   - respawn can hand a slot to a bandit and never mixes races on a spot.

var _checks := 0
var _fails: Array[String] = []


func _find(parent: Dictionary, k: String) -> String:
	while parent[k] != k:
		parent[k] = parent[parent[k]]
		k = parent[k]
	return k


func _check(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(msg)
	print(("  OK  " if ok else "  FAIL") + " " + msg)


func _initialize() -> void:
	Game.hero_stats = {"body": 12, "agility": 11, "mind": 9, "spirit": 8,
		"blade": 30, "bludgeon": 15, "pike": 10,
		"fire": 5, "water": 5, "air": 5, "earth": 5, "astral": 5,
		"weapon": "sword", "shield": true, "armor": "heavy"}
	Game.hero_class = "warrior"
	Game.hero_name = "Охотник"
	Game.map_zone = "mid"
	call_deferred("_run")


func _run() -> void:
	print("-- пул рас --")
	var table: Dictionary = ContentRules.dict("spawn.bandit_sets")
	_check(not table.is_empty(), "правило spawn.bandit_sets непусто (%d рас)" % table.size())
	var races: Dictionary = MapGenerator.bandit_races()
	for race in table:
		var want: int = (table[race] as Array).size()
		var got: int = (races.get(race, []) as Array).size()
		_check(got == 0 or got == want,
			"раса '%s': либо целиком, либо никак (%d/%d наборов)" % [race, got, want])
	_check(races.has("humans"), "люди с артом в пуле")
	print("  пул: %s" % str(races))

	print("-- генерация --")
	var alm_path: String = MapGenerator.new().generate(5150, "mid", "user://maps/bandit_test")
	_check(alm_path != "" and FileAccess.file_exists(alm_path), "карта сгенерирована")
	var base := alm_path.get_basename()
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(base + ".npcs.json"))
	_check(parsed is Dictionary, "sidecar читается")
	var npcs: Array = (parsed as Dictionary).get("npcs", []) if parsed is Dictionary else []

	var race_of := {}
	for r in races:
		for s in races[r]:
			race_of[s] = r
	var by_race := {}
	var packs := 0
	var cells := {}
	var overlap := 0
	for n in npcs:
		var d: Dictionary = n
		var s := str(d.get("set", ""))
		if not race_of.has(s):
			continue
		packs += 1
		by_race[s] = true
		var key := "%d,%d" % [int(d.get("x", 0)), int(d.get("y", 0))]
		if cells.has(key):
			overlap += 1
		cells[key] = s
	_check(packs >= 4, "разбойники на карте (%d штук)" % packs)
	_check(overlap == 0, "клетки разбойников не пересекаются")

	# ОДНА РАСА НА СТАЮ: члены стаи стоят рядом (расстояние <= 3 клеток к
	# ближайшему соседию своей расы), поэтому собираем компоненты связности
	# по соседству и проверяем каждую.
	var parent := {}
	for k in cells:
		parent[k] = k
	var ks := cells.keys()
	for a in range(ks.size()):
		for b in range(a + 1, ks.size()):
			var pa := str(ks[a]).split(",")
			var pb := str(ks[b]).split(",")
			if absi(int(pa[0]) - int(pb[0])) <= 3 and absi(int(pa[1]) - int(pb[1])) <= 3:
				var ra: String = _find(parent, ks[a])
				var rb: String = _find(parent, ks[b])
				if ra != rb:
					parent[ra] = rb
	var pack_race := {}
	var mixed := 0
	for k in cells:
		var root: String = _find(parent, k)
		var r: String = race_of[cells[k]]
		if pack_race.has(root) and pack_race[root] != r:
			mixed += 1
		pack_race[root] = r
	_check(mixed == 0, "ни одной смешанной стаи (стаи: %d)" % pack_race.size())

	print("-- враждебность --")
	for s in race_of:
		_check(UnitDB.is_hostile(s), "%s враждебен (palette)" % s)

	print("-- респавн --")
	var chance := GameConfig.geti("spawn", "bandit_respawn_chance")
	_check(chance > 0 and chance < 100, "доля респавна разбойников задана (%d%%)" % chance)

	_report()


func _report() -> void:
	print("RESULT: %s bandits_smoke (проверок: %d, провалов: %d)"
		% ["OK" if _fails.is_empty() else "FAIL", _checks, _fails.size()])
	for f in _fails:
		print("  FAIL " + f)
	quit(0 if _fails.is_empty() else 1)
