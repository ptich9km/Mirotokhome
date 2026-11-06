extends SceneTree
## Ground bottles (06.11): health, mana, essence and boss essence must have
## four AI-style frames, and a LootDrop must actually play them (a Sprite2D
## with one texture would be static).
##
## Run: godot --headless --path . --script res://tests/loot_bottle_anim_smoke.gd

var _fails: Array[String] = []
var _checks := 0


func _initialize() -> void:
	call_deferred("_run")


func _check(ok: bool, what: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(what)
	print("BOTTLE: %s %s" % ["ok  " if ok else "FAIL", what])


func _run() -> void:
	var cases := [
		["Potion Small Healing", "health"],
		["Potion Small Mana", "mana"],
		["Magic Essence", "essence"],
		["Boss Core", "boss"],
	]
	for pair in cases:
		var item := ItemDB.find(str(pair[0]))
		var frames := LootIcons.ground_frames_for(item, "small")
		_check(frames.size() == 4, "%s: 4 кадра (%d)" % [pair[1], frames.size()])
		for f in frames:
			if not (f is Texture2D):
				_check(false, "%s: кадр не текстура" % pair[1])
				break

	# The drop plays the frames on its own timer.
	var drop := LootDrop.new()
	drop.items = [{"key": "Potion Small Healing"}]
	root.add_child(drop)
	await process_frame
	var sprite: Sprite2D = null
	for c in drop.get_children():
		if c is Sprite2D:
			sprite = c
			break
	_check(sprite != null, "на земле есть спрайт баночки")
	if sprite != null:
		var frames := LootIcons.ground_frames_for(
			ItemDB.find("Potion Small Healing"), "small")
		_check(sprite.texture == frames[0], "первый кадр выставлен")
		await create_timer(0.3).timeout
		_check(sprite.texture == frames[1], "второй кадр проигран")

	drop.queue_free()
	await process_frame
	_finish()


func _finish() -> void:
	print("")
	if _fails.is_empty():
		print("RESULT: OK loot_bottle_anim_smoke (%d checks)" % _checks)
	else:
		print("RESULT: FAIL loot_bottle_anim_smoke (%d checks, %d fails)"
			% [_checks, _fails.size()])
		for f in _fails:
			print("  - " + f)
	quit(0 if _fails.is_empty() else 1)
