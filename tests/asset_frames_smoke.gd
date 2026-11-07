extends SceneTree
## Export-safe sprite folder listings (07.11).
##
## An exported .pck lists imported textures as "<name>.png.import" and never the
## source ".png", while the editor lists both. A frame counter that checks
## ends_with(".png") therefore finds nothing in a build and silently hides the
## object - that is how trees and props disappeared from the Windows build.
## AssetFrames is the single place that knows about it.
##
## Run: godot --headless --path . --script res://tests/asset_frames_smoke.gd

var _fails: Array[String] = []
var _checks := 0


func _initialize() -> void:
	call_deferred("_run")


func _check(ok: bool, what: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(what)
	print("AFRAMES: %s %s" % ["ok  " if ok else "FAIL", what])


func _run() -> void:
	# 1. Editor listing: source names AND ".import" stubs -> no double counting.
	var editor_listing: Array = [
		"sprites-001.png", "sprites-001.png.import",
		"sprites-002.png", "sprites-002.png.import",
		"sprites-003.png", "sprites-003.png.import",
		"spritesb-001.png", "spritesb-001.png.import",
	]
	_check(AssetFrames.numbers_from(editor_listing, "sprites-") == [1, 2, 3],
		"листинг редактора: 3 кадра, дубли .import не считаются")

	# 2. Pack listing: only ".import" stubs -> frames are still found.
	var pack_listing: Array = [
		"sprites-001.png.import", "sprites-002.png.import", "sprites-003.png.import",
		"spritesb-001.png.import",
	]
	_check(AssetFrames.numbers_from(pack_listing, "sprites-") == [1, 2, 3],
		"листинг пакета: кадры найдены по .import")

	# 3. Unrelated names are ignored, foreign prefixes are not mixed.
	var mixed: Array = [
		"sprites-001.png.import", "house-004.png.import", "readme.txt",
		"sprites-abc.png.import", "sprites-.png", "sprites-002.png.import",
	]
	_check(AssetFrames.numbers_from(mixed, "sprites-") == [1, 2],
		"мусор и чужие префиксы отброшены")

	# 4. Folder listing on disk still works (editor side of the same call).
	var tree: Array = AssetFrames.numbers("res://assets/map-objects/tree_oak", "sprites-")
	_check(tree.size() >= 1 and int(tree[0]) == 1, "tree_oak: кадр 1 найден")
	var houses: Array = AssetFrames.numbers("res://assets/structures", "house-")
	_check(houses.is_empty(), "нет папки кадров — пустой список, а не падение")

	# 5. File names are built back from numbers (order matters for animation).
	var files: Array = AssetFrames.file_names("res://assets/map-objects/tree_oak", "sprites-")
	_check(files.size() == tree.size(), "file_names совпадает по числу")
	if not files.is_empty():
		_check(str(files[0]) == "sprites-001.png", "file_names: первый кадр с ведущими нулями")

	# 6. Regression guard for the real bug: an obstacle built in a pack-like
	# world must stay visible. AlmObstacle asks AssetFrames, so a folder whose
	# only entry is a ".import" stub must still produce a frame.
	var ob := AlmObstacle.new()
	ob.setup("tree_oak", 7, 128, 128, 64, 96, 0, 100)
	root.add_child(ob)
	var has_tex := false
	for c in ob.get_children():
		if c is Sprite2D and c.texture != null:
			has_tex = true
	_check(ob.visible and ob.frame_count >= 1 and has_tex,
		"AlmObstacle tree_oak видим и с текстурой")
	ob.free()

	# 7. Projectiles count frames the same way (magic animation in a build).
	var fireball := SpellDB.projectile_frames("Fire_Ball")
	_check(fireball > 0, "Fire_Ball: кадры снаряда найдены (%d)" % fireball)
	_check(SpellDB.projectile_icon("Fire_Ball").begins_with("res://assets/projectiles/"),
		"Fire_Ball: иконка снаряда найдена")

	_finish()


func _finish() -> void:
	print("")
	if _fails.is_empty():
		print("RESULT: OK asset_frames_smoke (%d checks)" % _checks)
	else:
		print("RESULT: FAIL asset_frames_smoke (%d checks, %d fails)"
			% [_checks, _fails.size()])
		for f in _fails:
			print("  FAIL: %s" % f)
	quit()
