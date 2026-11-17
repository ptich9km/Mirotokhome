extends SceneTree
## Mercenary pools per city race, 14.11.
##
## WHAT THIS IS. The inn used to hire `ork_mage_a52/t0..t3` — four static orc
## mages — in every town of every race. Since 14.11 each city race has its own
## pool of animated mercenary sets (assets/units/merc/<race>_<class>, the same
## 12-frame contract as the hero art: idle1 + move4 + attack3 + dying4).
##
## WHAT IT CHECKS.
## 1. Every city race named by CITY_POPULATION has its own pool, and the fallback
##    pool (`inn.candidates`, a map without a city) is not empty.
## 2. Every set named by a pool exists in units_db and its art is on disk.
## 3. The sets are ANIMATED: a mercenary fights and dies, so attack and dying
##    frames must exist. This is the exact defect of the old placeholder.
## 4. No pool points at hero art: a mercenary that reuses `hero/*` would be a copy
##    of the player's own sprite.
## 5. The set belongs to the race of the city it is offered in.
## 6. UnitDB.display_name is a real name, not an internal key or a pipeline note.
##
## Run:
##   godot --headless --path . --script res://tests/merc_pools_smoke.gd

const POOLS := {
	"humans": "merc/human",
	"ork": "merc/orc",
	"druid": "merc/druid",
	"necro": "merc/undead",
}
## Races whose pool also has the t1 (veteran) grade. The other two are one grade
## shorter on purpose: their t1 art is defective (see tests/add_merc_sets_db.py).
const VETERAN := ["ork", "necro", "humans", "druid"]
const FRAMES := 12

var _checks := 0
var _fails: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _check(ok: bool, what: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(what)
	print("MERC: %s %s" % ["ok  " if ok else "FAIL", what])


func _run() -> void:
	_pool_checks()
	_fallback_checks()
	_panel_checks()
	_report()


func _panel_checks() -> void:
	## The data can be right and the panel still look at the wrong key: this is
	## the exact bug of 14.11, so the selection itself is checked, not just the
	## table it reads.
	for race in POOLS:
		var panel: Node = InnPanel.new()
		panel.set("_race", race)
		var pool: Array = panel.call("_candidate_sets")
		_check(pool == ContentRules.list("inn.candidates.%s" % race),
			"%s: the inn panel picks its own race pool" % race)
		panel.free()
	var other: Node = InnPanel.new()
	other.set("_race", "unknown_race")
	_check(other.call("_candidate_sets") == ContentRules.list("inn.candidates"),
		"an unknown race falls back to the general pool")
	other.free()


func _pool_checks() -> void:
	var races: Array = MapGenerator.CITY_POPULATION.keys()
	_check(races.size() == POOLS.size(), "every city race is covered by the test (%d)" % races.size())
	for race in races:
		var key := str(race)
		var pool: Array = ContentRules.list("inn.candidates.%s" % key)
		_check(not pool.is_empty(), "%s: own mercenary pool is not empty" % key)
		if pool.is_empty():
			continue
		var prefix: String = POOLS.get(key, "?")
		if prefix == "?":
			# A race added to CITY_POPULATION later: the test says what to do.
			_check(false, "%s: no expected art prefix in this test — add it" % key)
			continue
		for set_name in pool:
			_set_checks(str(set_name), prefix)
		_check(_has_attack_and_death(pool), "%s: pool has at least one fully animated set" % key)
		# 15.11: the pool is a gear ladder, so a race must offer a veteran grade
		# above the base one, or the reputation tiers change nothing visible.
		if key in VETERAN:
			var t1 := 0
			for set_name in pool:
				if str(set_name).ends_with("/t1"):
					t1 += 1
			_check(t1 > 0, "%s: pool offers the veteran (t1) grade" % key)
			_check(_distinct_grades(pool), "%s: t1 sets are not duplicates of t0" % key)


func _fallback_checks() -> void:
	var pool: Array = ContentRules.list("inn.candidates")
	_check(not pool.is_empty(), "fallback pool (map without a city) is not empty")
	for set_name in pool:
		_set_checks(str(set_name), "merc/")


func _set_checks(set_name: String, prefix: String) -> void:
	var ok := UnitDB.has(set_name)
	_check(ok, "%s is in units_db" % set_name)
	if not ok:
		return
	_check(set_name.begins_with(prefix), "%s belongs to the expected race art %s" % [set_name, prefix])
	_check(not set_name.begins_with("hero/"), "%s is not the player's own hero art" % set_name)
	_check(not set_name.begins_with("ork_mage_a52"), "%s is not the old static placeholder" % set_name)
	var data := UnitDB.get_set(set_name)
	var bad: Array[String] = []
	var want := {
		"frames": FRAMES, "dirs": 1, "move": 4, "attack": 3, "dying": 4, "blocks": 4,
		"w": 64, "h": 64, "cx": 32, "cy": 62,
	}
	for field in want:
		if int(data.get(field, -1)) != int(want[field]):
			bad.append("%s=%s" % [field, data.get(field, -1)])
	_check(bad.is_empty(), "%s has the 12-frame contract %s" % [set_name, ", ".join(bad)])
	var folder := "res://assets/units/%s" % set_name
	var files := 0
	for i in range(1, FRAMES + 1):
		if ResourceLoader.exists("%s/sprites-%03d.png" % [folder, i]):
			files += 1
	_check(files == FRAMES, "%s: %d/%d frames on disk" % [set_name, files, FRAMES])
	var name := UnitDB.display_name(set_name)
	_check(name != "" and name != set_name, "%s: display_name is a real name (%s)" % [set_name, name])


func _distinct_grades(pool: Array) -> bool:
	## A t1 entry must be its own art: same folder, different tier, and the
	## veteran frames must differ from the base frames on disk.
	for set_name in pool:
		var key := str(set_name)
		if not key.ends_with("/t1"):
			continue
		var base := key.substr(0, key.length() - 3) + "/t0"
		var a := "res://assets/units/%s/sprites-001.png" % key
		var b := "res://assets/units/%s/sprites-001.png" % base
		if not FileAccess.file_exists(a) or not FileAccess.file_exists(b):
			return false
		# Compare the source PNG bytes, not Texture2D objects: the loader returns
		# different resource instances for the same file, so identity compares
		# garbage. PackedByteArray has value equality.
		if FileAccess.get_file_as_bytes(a) == FileAccess.get_file_as_bytes(b):
			return false
	return true


func _has_attack_and_death(pool: Array) -> bool:
	for set_name in pool:
		var data := UnitDB.get_set(str(set_name))
		if int(data.get("attack", 0)) > 0 and int(data.get("dying", 0)) > 0:
			return true
	return false


func _report() -> void:
	if _fails.is_empty():
		print("RESULT: OK merc_pools_smoke (проверок: %d)" % _checks)
	else:
		for f in _fails:
			print("  - %s" % f)
		print("RESULT: FAIL merc_pools_smoke (проверок: %d, провалов: %d)" % [_checks, _fails.size()])
	quit(0 if _fails.is_empty() else 1)
