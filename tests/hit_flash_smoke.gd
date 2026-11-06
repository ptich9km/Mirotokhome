extends SceneTree
## Overlapping hit flashes (player report 06.11: "during combat the hero turned
## red and now walks around permanently red").
##
## A hit flash tints the unit for 0.1 s, a shield flash for 0.12 s. Each flash
## used to capture the CURRENT tint as the colour to restore, so a shield flash
## that started right after a hit restored the red tint - forever. The newest
## flash now owns the colour and every flash restores the resting one.
##
## Run: godot --headless --path . --script res://tests/hit_flash_smoke.gd

var _fails: Array[String] = []
var _checks := 0


func _initialize() -> void:
	call_deferred("_run")


func _check(ok: bool, what: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(what)
	print("FLASH: %s %s" % ["ok  " if ok else "FAIL", what])


func _make_unit() -> Node2D:
	var host := Node2D.new()
	var anim := Node2D.new()
	anim.name = "UnitAnim"
	host.add_child(anim)
	root.add_child(host)
	return host


func _anim_of(host: Node2D) -> Node2D:
	return host.get_node("UnitAnim") as Node2D


func _run() -> void:
	# 1. A hit during a hit does not stick.
	var unit := _make_unit()
	SpellVFX.hit_flash(unit)
	SpellVFX.hit_flash(unit)
	await create_timer(0.25).timeout
	_check(_anim_of(unit).modulate == Color.WHITE, "двойной удар возвращает белый")

	# 2. A hit, then a shield flash (longer than the hit).
	SpellVFX.hit_flash(unit)
	SpellVFX.shield_hit(unit)
	await create_timer(0.3).timeout
	_check(_anim_of(unit).modulate == Color.WHITE,
		"удар + вспышка щита возвращают белый")

	# 3. A shield flash, then a hit (shorter than the shield).
	SpellVFX.shield_hit(unit)
	SpellVFX.hit_flash(unit)
	await create_timer(0.3).timeout
	_check(_anim_of(unit).modulate == Color.WHITE,
		"щит + удар возвращают белый")

	# 4. The tint is really applied while the flash is running.
	SpellVFX.hit_flash(unit)
	await process_frame
	_check(_anim_of(unit).modulate != Color.WHITE, "во время вспышки цвет меняется")
	await create_timer(0.25).timeout
	_check(_anim_of(unit).modulate == Color.WHITE, "после вспышки цвет возвращается")

	# 5. The resting colour is restored, not white: a rigged sprite that carries
	#    its own tone must get it back.
	var toned := _make_unit()
	var base := Color(0.8, 0.85, 1.0, 0.9)
	_anim_of(toned).modulate = base
	SpellVFX.hit_flash(toned)
	SpellVFX.shield_hit(toned)
	await create_timer(0.3).timeout
	_check(_anim_of(toned).modulate == base, "возвращается собственный тон юнита")

	unit.queue_free()
	toned.queue_free()
	await process_frame
	_finish()


func _finish() -> void:
	print("")
	if _fails.is_empty():
		print("RESULT: OK hit_flash_smoke (%d checks)" % _checks)
	else:
		print("RESULT: FAIL hit_flash_smoke (%d checks, %d fails)"
			% [_checks, _fails.size()])
		for f in _fails:
			print("  - " + f)
	quit(0 if _fails.is_empty() else 1)
