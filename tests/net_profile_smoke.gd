extends SceneTree
##
## Co-op character persistence (22.11): a hero created in a network session is
## stored on THIS machine and comes back with gold, bag and worn gear, while the
## world itself starts from a new seed every time.
##
## The real `user://net_characters.json` is backed up and restored: the player's
## own heroes must survive a test run.
##
## Run: godot --headless --path . --script res://tests/net_profile_smoke.gd

const SEED := 5555
const NAME := "Профильный"
const BACKUP := "user://net_characters.smoke_backup.json"

var _checks := 0
var _fails: Array[String] = []
var _had_file := false

func _initialize() -> void:
	_had_file = FileAccess.file_exists(NetProfile.PATH)
	if _had_file:
		_copy(NetProfile.PATH, BACKUP)
	Game.hero_stats = {"strength": 20, "dexterity": 20, "intelligence": 10,
		"vitality": 20, "spirit": 10, "luck": 5}
	Game.hero_class = "warrior"
	Game.hero_gender = "male"
	Game.hero_name = NAME
	Game.hero_race = "human"
	Game.hero_character_id = "human_m_war"
	Game.hero_start_book = ""
	Game.hero_primary_skill = "sword"
	Game.hero_aux_skill = "bow"
	Game.hero_save = {}
	Game.map_seed = SEED
	Game.map_zone = "start"
	Game.map_sector = "s00"
	Game.loaded_slot = ""
	Game.pending_map_path = ""
	call_deferred("_run")

func _copy(from: String, to: String) -> void:
	var f := FileAccess.open(from, FileAccess.READ)
	if f == null:
		return
	var text := f.get_as_text()
	f.close()
	var w := FileAccess.open(to, FileAccess.WRITE)
	if w != null:
		w.store_string(text)
		w.close()

func _check(ok: bool, what: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(what)
	print(("  OK  " if ok else "  FAIL") + " " + what)

func _run() -> void:
	# 1) A new-game profile goes through the file and comes back intact.
	NetProfile.upsert(NetProfile.from_new_game())
	var stored := NetProfile.find(NAME)
	_check(not stored.is_empty(), "the new hero is stored")
	_check(str(stored.get("name", "")) == NAME, "stored under its name")
	_check(summary_has(stored, Loc.t("ui.char.class.warrior")), "summary shows the class")

	# 2) Boot the world, earn something, capture the LIVE hero.
	var err := change_scene_to_file("res://scenes/main.tscn")
	_check(err == OK, "the world loads for the first time")
	await create_timer(7.0).timeout
	var player: Player = Game.hero as Player
	_check(player != null, "the hero exists")
	if player == null:
		_finish()
		return
	player.add_gold(123)
	player.add_item("Potion Small Healing")
	var cap := NetProfile.capture(player)
	NetProfile.upsert(cap)
	_check(not (cap.get("save", {}) as Dictionary).is_empty(), "capture writes the hero blob")
	var gained_gold := int(player.gold)

	# 3) Throw the statics away like a fresh session would, then restore.
	Game.hero_save = {}
	Game.hero_stats = {}
	Game.hotbar = {}
	NetProfile.apply(NetProfile.find(NAME))
	_check(Game.hero_name == NAME and not Game.hero_save.is_empty(),
		"apply puts the hero back into the game statics")

	# 4) The world starts again (new map from the same seed) — the hero returns.
	Game.pending_map_path = ""
	Game.map_seed = SEED + 1
	change_scene_to_file("res://scenes/main.tscn")
	await create_timer(7.0).timeout
	var again: Player = Game.hero as Player
	_check(again != null, "the hero exists in the new world")
	if again != null:
		_check(int(again.gold) == gained_gold,
			"gold survived the session (%d)" % int(again.gold))
		_check(again.inventory.has("Potion Small Healing"), "the bag survived the session")
		_check(not again.equipped.is_empty(), "worn gear survived the session")

	# 5) Deleting really deletes.
	NetProfile.remove(NAME)
	_check(NetProfile.find(NAME).is_empty(), "delete removes the hero")
	_finish()

func summary_has(p: Dictionary, part: String) -> bool:
	return NetProfile.summary(p).contains(part)

func _finish() -> void:
	# Restore the player's own file exactly as it was.
	if FileAccess.file_exists(NetProfile.PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(NetProfile.PATH))
	if _had_file:
		_copy(BACKUP, NetProfile.PATH)
		DirAccess.remove_absolute(ProjectSettings.globalize_path(BACKUP))
	if _fails.is_empty():
		print("RESULT: OK net_profile_smoke (%d checks)" % _checks)
		quit(0)
	else:
		print("RESULT: FAIL net_profile_smoke (%d checks, %d failed)" % [_checks, _fails.size()])
		quit(1)
