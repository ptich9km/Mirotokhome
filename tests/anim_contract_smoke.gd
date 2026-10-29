## CONTRACT of an animated unit: everything a rig must be able to do instead of sprite sheets.
##
## Why this test exists (10.10, phase 0 of the move to a 2D rig):
## Units are created BY CODE (`UnitAnim.new()` in player/enemy/npc/mercenary),
## the public surface is 9 members, and `game.gd` reaches it through
## `get_node_or_null("UnitAnim")` + `has_method`, that is by INTERFACE, not
## by class. The "sprite sheets -> rig" migration rests exactly on that: the new
## RiggedAnim plugs in alongside without a single edit in game.gd/spell_vfx/craft_vfx.
##
## But until now NO test guarded the contract: `UnitAnim` is mentioned by only
## 5 tests out of ~60, and even then indirectly. A broken contract would pass every test
## green and then fail in the game.
##
## The test checks TWO layers:
##   1. that the contract members exist (cheap, catches renames);
##   2. that the contract ACTUALLY works on a live instance (expensive, but it is
##      the only check that will not pass on a broken scheme).
##
## If a `rigged_anim.gd` appears, the test picks it up automatically — the backend
## list grows by itself, otherwise a new rig would start without a safety net.
## Every backend has its OWN set: sprite sheets do not load a rig and vice versa.
##
## Run:
##   godot --headless --path . --script res://tests/anim_contract_smoke.gd

extends SceneTree

## The members any unit animation backend must have.
## Format: [name, "method"|"var"].
const CONTRACT: Array = [
	["setup", "method"],
	["play", "method"],
	["advance", "method"],
	["freeze_last_frame", "method"],
	["set_direction_vec", "method"],
	["speed_scale", "var"],
	["sprite_height", "method"],
	["visual_height", "method"],
	["position", "var"],
]

## The backends the test must check. RiggedAnim is picked up if
## the file exists — a hard class reference is avoided on purpose: while the file does
## not exist, such a reference would be a Parse Error and the test would not run at all.
##
## The sprite-sheet reference was moved from `humans/swordsman_` to `ork_mage_a52/t0`
## on 11.10: the Allods families were removed, and keeping the test on their art would
## mean dragging back what was cleaned out. The checks are behavioural (not "phase N
## equals M"), so the set needs no animation blocks — it needs frames.
const BACKENDS: Array = [
	{"name": "UnitAnim", "path": "res://scripts/unit_anim.gd", "set": "ork_mage_a52/t0"},
	{"name": "RiggedAnim", "path": "res://scripts/rigged_anim.gd", "set": "rig/pilot"},
]

## The number of world directions (octants). Duplicates UnitAnim.FULL_DIRS so that
## the test does not depend on the backend loading: the octant check is the contract.
const FULL_DIRS := 8

var _checks := 0
var _fails: Array[String] = []


func _init() -> void:
	call_deferred("_run")


func _check(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(msg)
	print(("  OK  " if ok else "  FAIL") + " " + msg)


func _has_member(obj: Object, member: String, kind: String) -> bool:
	# IMPORTANT (trap §9.2): `has_method` on a Script object sees only
	# STATIC methods, so the check must run on an instance.
	if kind == "method":
		return obj.has_method(member)
	for p in obj.get_property_list():
		if str(p.get("name", "")) == member:
			return true
	return false


func _make_backend(backend: Dictionary) -> Object:
	var script: Variant = load(str(backend["path"]))
	if script == null:
		return null
	var obj: Object = script.new()
	if obj == null:
		return null
	obj.name = "UnitAnim"  # the node name is part of the contract (game.gd finds it by name)
	return obj


## Layer 1: the backend has all the contract members.
func _test_members(label: String, obj: Object) -> void:
	for entry in CONTRACT:
		var member := str(entry[0])
		var kind := str(entry[1])
		_check(_has_member(obj, member, kind),
			"%s: контракт — есть %s `%s`" % [label, kind, member])


## Layer 2: the contract actually works on a live instance.
## Without it the first layer checks only that the names exist: a rename
## is caught, broken logic is not.
func _test_functional(label: String, obj: Object, test_set: String) -> void:
	var anim := obj as Node2D
	if anim == null:
		_check(false, "%s: бэкенд должен быть Node2D" % label)
		return

	if UnitDB.get_set(test_set).is_empty():
		_check(false, "%s: набора `%s` нет в units_db" % [label, test_set])
		return

	anim.setup(test_set)
	_check(str(obj.get("set_name")) == test_set,
		"%s: setup() запомнил набор (`%s`)" % [label, str(obj.get("set_name"))])

	# The node must be in the tree, otherwise game.gd will not find "UnitAnim" via get_node.
	var holder := Node2D.new()
	holder.add_child(anim)
	_check(anim.get_parent() != null, "%s: узел добавлен в дерево" % label)

	# An animated unit must have a non-zero height — game.gd and
	# spell_vfx position the HP bar, the auras and the selection ring by it.
	var sh: float = float(obj.call("sprite_height"))
	var vh: float = float(obj.call("visual_height"))
	_check(sh > 0.0, "%s: sprite_height() > 0 (%.1f)" % [label, sh])
	_check(vh > 0.0, "%s: visual_height() > 0 (%.1f)" % [label, vh])

	# Direction. We check `target_dir`, NOT `dir`: `set_direction_vec`
	# sets the goal, while `dir` turns towards it in _process via the accumulator
	# ROT_STEP_TIME. The first version of the check expected an instant `dir` change
	# and was fake-green by design: in one headless frame the accumulator does not
	# reach 0.05 s, and the check would pass even on broken mapping.
	#
	# The real invariant is the compass octant convention. IMPORTANT: our
	# indexing is COUNTER-CLOCKWISE: 0 = north (back), 7 = north-east,
	# 6 = east, 5 = south-east, 4 = south, 3 = south-west, 2 = west,
	# 1 = north-west.
	#
	# The octant vector i is the Godot angle (90 + i*45), that is (cos a, sin a).
	# The first version of the test built the vector as (sin(i*45), cos(i*45)) — that is
	# a REFLECTION, and the helper together with the expected posmod(-i) stayed mutually
	# consistent, that is the test checked that the code agrees with itself rather than
	# that the directions are correct. It was this helper bug that kept the inverted
	# mirror in RiggedAnim: the player complained that walking left/right the character
	# moves sideways.
	var octant_ok := true
	var detail := ""
	for i in range(FULL_DIRS):
		var v := _octant_vector(i)
		obj.call("set_direction_vec", v)
		var want: int = i
		var got: int = int(obj.get("target_dir"))
		if got != want:
			octant_ok = false
			detail += " октанта[%d] -> %d (ждали %d);" % [i, got, want]
	_check(octant_ok, "%s: set_direction_vec раскладывает вектор по 8 октантам (0=север, против часовой)%s"
		% [label, "" if octant_ok else " — " + detail])

	# Smooth turning must really bring dir to the goal, otherwise the unit
	# stays stuck in an intermediate angle forever.
	# We must NOT use `await process_frame`: in headless the frame delta does not
	# reach ROT_STEP_TIME in a reasonable number of iterations (the same trap as in
	# §12 about "measuring by frames instead of by time"). So we step
	# `_advance_rotation` with an explicit delta — deterministic and without a race.
	obj.call("set_direction_vec", Vector2.RIGHT)
	if _has_member(obj, "_advance_rotation", "method"):
		var steps := 0
		while int(obj.get("target_dir")) >= 0 and steps < 32:
			obj.call("_advance_rotation", 0.06)
			steps += 1
		_check(int(obj.get("target_dir")) < 0,
			"%s: поворот доезжает до цели за %d шагов (target_dir сброшен)"
				% [label, steps])
	else:
		print("-- %s: нет _advance_rotation, шаг доворота не проверяем" % label)

	# Block playback and one-shot behaviour.
	obj.call("play", 0)  # Anim.IDLE
	var anim_after: int = int(obj.get("anim"))
	_check(anim_after == 0, "%s: play(IDLE) выставил anim=0 (получено %d)"
		% [label, anim_after])

	# advance() must return true on a ONE-SHOT block. The first version checked
	# that on IDLE and failed on the rig — and that was a bug in the check, not in
	# the code: in the rig idle really is looped (in sprite sheets the
	# same block cycles the frames and "returns true"). Waiting
	# for an endless loop to finish is pointless, it must be waited for from an attack.
	obj.call("play", 2)  # Anim.ATTACK — a one-shot block
	var finished := false
	for i in range(600):
		if bool(obj.call("advance", 0.05)):
			finished = true
			break
	_check(finished, "%s: advance() вернул true на одноразовом блоке ATTACK" % label)

	# freeze_last_frame must leave the unit on the LAST frame of the block: otherwise
	# the corpse returns to the start and loops instead of lying still.
	#
	# The last frame number differs between backends and is set from the outside NOWHERE: in
	# sprite sheets the phases come from units_db, in the rig — from the number of clip keys.
	# The first version of the check expected a value from units_db and was fake for
	# the rig (it mixed two sources of truth). So we compare not with a number but
	# with BEHAVIOUR: freeze must give an index no less than the maximum the
	# backend showed during normal playback of the same block.
	obj.call("play", 3)  # Anim.DYING
	var max_seen := 0
	for i in range(600):
		if bool(obj.call("advance", 0.05)):
			break
		max_seen = maxi(max_seen, int(obj.get("anim_idx")))
	obj.call("freeze_last_frame", 3)
	var frozen: int = int(obj.get("anim_idx"))
	_check(frozen >= max_seen,
		"%s: freeze_last_frame(DYING) не откатил назад (заморожен %d, в игре доходило до %d)"
			% [label, frozen, max_seen])

	# speed_scale is an ordinary field, the contract requires it to exist and to be 1.0 by default.
	_check(is_equal_approx(float(obj.get("speed_scale")), 1.0),
		"%s: speed_scale по умолчанию 1.0" % label)

	holder.remove_child(anim)
	anim.free()
	holder.free()


## The backend selection condition. Player decides by it whether to take the rig — so
## an error here would silently return the hero to sprite sheets, and the pilot "would not
## work" without a single error in the log.
func _test_backend_selection() -> void:
	if not ResourceLoader.exists("res://scripts/rigged_anim.gd"):
		return
	_check(bool(RiggedAnim.has_rig("rig/pilot")),
		"выбор бэкенда: у `rig/pilot` риг есть")
	_check(not bool(RiggedAnim.has_rig("ork_mage_a52/t0")),
		"выбор бэкенда: у `ork_mage_a52/t0` рига нет (остаёмся на листах)")
	_check(not bool(RiggedAnim.has_rig("нетакого/набора")),
		"выбор бэкенда: несуществующий набор не считается ригом")

	# A set without a rig must give a NOT LOADED rig rather than a rig with an empty
	# skeleton: otherwise the unit would simply disappear instead of falling back to sheets.
	var r := RiggedAnim.new()
	r.setup("ork_mage_a52/t0")
	_check(not r.is_loaded(), "выбор бэкенда: риг без своего rig.json не загружается")
	_check(float(r.call("visual_height")) == 0.0,
		"выбор бэкенда: незагруженный риг не выдаёт высоту (иначе шкала HP уедет)")
	r.free()


## VISIBILITY OF PARTS.
##
## This test checked the contract, the bones, the poses and the rotations — but NOT
## ONCE asked whether the sprites have textures. Because of that it stayed green
## on a completely invisible rig:
##
##   `rig.json` pointed at the folder `assets/units/rig/heroes_pilot/parts/`,
##   and during the Allods cleanup (11.10) the `heroes/` family was cleaned out entirely and
##   the pilot moved to `rig/rig_pilot/`. The reference in JSON stayed on the old path,
##   `load()` returned null, all 19 `Sprite2D` were created empty — the skeleton was there,
##   there was nothing to draw, and in the game the hero was invisible.
##
## The check is on the TEXTURE, not on the number of nodes: an empty `Sprite2D`
## exists and counts as "a rig part", so counting children passed.
func _test_rig_textures() -> void:
	if not ResourceLoader.exists("res://scripts/rigged_anim.gd"):
		return
	var r := RiggedAnim.new()
	r.setup("rig/pilot")
	_check(r.is_loaded(), "рифг: пилотный риг загрузился")
	if r.is_loaded():
		root.add_child(r)
		await process_frame

		var sprites := 0
		var with_tex := 0
		var empty_tex := 0
		var stack: Array = [r as Node]
		while not stack.is_empty():
			var n: Node = stack.pop_back()
			for ch in n.get_children():
				stack.append(ch)
				if ch is Sprite2D:
					sprites += 1
					var t: Texture2D = (ch as Sprite2D).texture
					if t == null:
						empty_tex += 1
						print("  EMPTY TEXTURE: %s" % ch.name)
					else:
						with_tex += 1
		_check(sprites > 0, "рифг: у рига есть части-спрайты (%d)" % sprites)
		_check(with_tex > 0,
			"рифг: у хотя бы одной части есть текстура (%d из %d)" % [with_tex, sprites])
		# Strict equality, not "at least one": an empty part is not drawn and
		# looks like a hole in the character.
		_check(with_tex == sprites,
			"рифг: у ВСЕХ частей есть текстура (%d с текстурой, %d пустых)"
				% [with_tex, empty_tex])

		# The path in rig.json must exist. It is exactly what went out of sync
		# when the folder moved, and this is caught more cheaply than by the picture.
		var cfg: Variant = JSON.parse_string(FileAccess.get_file_as_string(
			"res://assets/units/rig/rig_pilot/rig.json"))
		_check(cfg is Dictionary, "рифг: rig.json читается")
		if cfg is Dictionary:
			var views: Dictionary = (cfg as Dictionary).get("views", {})
			for vk in views.keys():
				var parts_dir := str((views[vk] as Dictionary).get("parts", ""))
				_check(parts_dir != "" and DirAccess.dir_exists_absolute(parts_dir),
					"рифг: папка частей из rig.json существует (%s)" % parts_dir)

		r.queue_free()
		await process_frame
	else:
		r.free()


## Rig rotation: the player complaint "it keeps turning its back".
## The complaint had TWO causes, and both are checked here separately:
##   1. the skeleton was rebuilt on every rotation step (flicker);
##   2. the mirror clicked at the octant border (jitter).
func _test_rig_turning() -> void:
	if not ResourceLoader.exists("res://scripts/rigged_anim.gd"):
		return
	var r := RiggedAnim.new()
	root.add_child(r)
	r.name = "UnitAnim"
	r.setup("rig/pilot")
	if not r.is_loaded():
		_check(false, "поворот рига: пилотный риг не загрузился")
		r.queue_free()
		return

	# The octant vector comes from the common helper — see _octant_vector.
	var vec: Callable = func(i: int) -> Vector2:
		return _octant_vector(i)

	# --- 1. The skeleton is NOT rebuilt when turning inside one view group ---
	# The east octant (2) and the south-east one (3) look the same way, so
	# the view is the same. If _build_view were called on every step, the Hip node
	# would be a DIFFERENT instance — caught by instance_id.
	r.set_direction_vec(vec.call(2))
	for i in range(6):
		r._advance_rotation(0.06)
	var hip_after_east: int = 0
	var hip_node: Node = r.get_node_or_null("Hip")
	if hip_node != null:
		hip_after_east = hip_node.get_instance_id()
	_check(hip_after_east != 0, "поворот рига: узел Hip найден после доворота на восток")

	r.set_direction_vec(vec.call(3))
	for i in range(6):
		r._advance_rotation(0.06)
	var hip_after_se: int = 0
	hip_node = r.get_node_or_null("Hip")
	if hip_node != null:
		hip_after_se = hip_node.get_instance_id()
	_check(hip_after_se == hip_after_east,
		"поворот рига: скелет НЕ пересобран при смене октанта внутри вида (восток->юго-восток)")

	# --- 2. The mirror does NOT click between neighbouring octants looking the same way ---
	# 2 (east) and 3 (south-east) are both right-facing: mirror must stay the same.
	# This is exactly the "jitter" the player complained about.
	var mirror_stable := true
	for probe in [2, 3, 2, 3, 2]:
		var before := _hip_scale_sign(r)
		r.set_direction_vec(vec.call(int(probe)))
		for i in range(8):
			r._advance_rotation(0.06)
		if _hip_scale_sign(r) != before:
			mirror_stable = false
	_check(mirror_stable,
		"поворот рига: зеркало стабильно на октантах, смотрящих в одну сторону")

	# --- 2b. The mirror is ORIENTED, not merely stable ---
	# The pilot art is drawn facing right (faces_east = 1). Octant 6 = east =>
	# no mirror; octant 2 = west => mirror. The stability check
	# (2a) MISSED a flipped sign: the mirror was stable but inverted,
	# and the player saw "walking left/right the character moves sideways". So the sign
	# is checked explicitly, not just "as long as it does not jitter".
	r.set_direction_vec(vec.call(6))   # east
	for i in range(20):
		r._advance_rotation(0.06)
	var east_sign := _hip_scale_sign(r)
	_check(int(r.dir) == 6 and is_equal_approx(east_sign, 1.0),
		"поворот рига: на востоке (октанта 6) арт НЕ отражён (dir=%d, scale.x=%.0f)"
			% [r.dir, east_sign])

	r.set_direction_vec(vec.call(2))   # west
	for i in range(20):
		r._advance_rotation(0.06)
	var west_sign := _hip_scale_sign(r)
	_check(int(r.dir) == 2 and is_equal_approx(west_sign, -1.0),
		"поворот рига: на западе (октанта 2) арт ОТРАЖЁН (dir=%d, scale.x=%.0f)"
			% [r.dir, west_sign])

	# --- 3. The south does not jerk the mirror ---
	# Player complaint: "when it walks down, it sometimes turns the other
	# way, although the vector is one and exact". Cause: cos(270°) in floating
	# point is -1.8e-16, not 0. The condition >= 0 decided "facing west" and
	# enabled the mirror exactly on the south octant. When walking down the octants 4<->5
	# alternate, and the character clicked back and forth.
	# Both "down" octants — 4 (south) and 5 (south-east) — must give the SAME
	# mirror, otherwise steady walking down will jitter.
	r.set_direction_vec(vec.call(6))   # east — set a known state
	for i in range(20):
		r._advance_rotation(0.06)
	var south_sign := _hip_scale_sign(r)
	r.set_direction_vec(vec.call(4))   # exactly south
	for i in range(20):
		r._advance_rotation(0.06)
	var due_south_sign := _hip_scale_sign(r)
	_check(int(r.dir) == 4 and is_equal_approx(due_south_sign, south_sign),
		"поворот рига: на юге (октанта 4) зеркало не щёлкает (scale.x %.0f -> %.0f)"
			% [south_sign, due_south_sign])

	# Full circle: 0..7. The mirror must switch EXACTLY TWICE (on
	# the west side and back). More than two — means the "polar" octants
	# north/south produce false switches.
	r.set_direction_vec(vec.call(0))
	for i in range(20):
		r._advance_rotation(0.06)
	var flips := 0
	var prev := _hip_scale_sign(r)
	for step in range(FULL_DIRS):
		r.set_direction_vec(vec.call(step))
		for i in range(20):
			r._advance_rotation(0.06)
		var now := _hip_scale_sign(r)
		if now != prev:
			flips += 1
			prev = now
	_check(flips == 2,
		"поворот рига: полный круг даёт ровно 2 переключения зеркала (получено %d)" % flips)

	# --- 4. Hysteresis: a single direction "twitch" must not turn the unit ---
	r.set_direction_vec(vec.call(2))
	for i in range(10):
		r._advance_rotation(0.06)
	var dir_before_jitter: int = r.dir
	r.set_direction_vec(vec.call(1))   # jerked one step sideways
	r._advance_rotation(0.06)
	r.set_direction_vec(vec.call(2))   # and came back
	for i in range(10):
		r._advance_rotation(0.06)
	_check(r.dir == dir_before_jitter,
		"поворот рига: одиночный дребезг направления не доворачивает юнита (было %d, стало %d)"
			% [dir_before_jitter, r.dir])

	# --- 4. A sustained turn still brings the unit around ---
	r.set_direction_vec(vec.call(6))   # west, hold
	for i in range(20):
		r._advance_rotation(0.06)
	_check(r.dir == 6, "поворот рига: устойчивое направление доезжает (dir=%d, ждали 6)" % r.dir)

	# --- 5. A one-shot clip RESTARTS on a repeated play() ---
	# Player complaint: "when it attacks, the first time it makes a swing, and then
	# just sounds and you see the health going down". Cause: the game code keeps the
	# "attack" state longer than one swing (hits are gated by cooldown), and
	# play(ATTACK) is called every frame. The first time the clip started, after that
	# play() exited early on `anim == anim_kind`, and the one-shot clip stayed
	# on the last frame forever. Sprite sheets do not have this: there advance()
	# cycles the phases, so the swing repeated by itself.
	# We check BEHAVIOUR: after playing out and a repeated play(ATTACK) the pose
	# must differ from the frozen last one.
	r.play(2)  # ATTACK
	while not r.advance(0.05):
		pass
	var arm := _bone_rotation(r, "ArmFront")
	var held := true
	for i in range(4):
		r.advance(0.05)
		held = is_equal_approx(_bone_rotation(r, "ArmFront"), arm)
	_check(held, "повтор атаки: доигранный клип держит последний кадр")

	r.play(2)  # a repeated swing, WITHOUT reset
	# Checking the POSE here is pointless: the swing clip returns to the start
	# pose on the last key (ArmFront: -10° … -95° … 40° … -10°), so
	# the first and the last frame are indistinguishable and the "pose changed" check would
	# pass even on broken code. So we verify the restart itself — the clip time
	# went back to zero — and that the clip really plays: the swing goes
	# through the extreme phase that is not present at the end.
	var time_after_restart: float = float(r.get("_clip_time"))
	_check(is_equal_approx(time_after_restart, 0.0),
		"повтор атаки: play(ATTACK) ПЕРЕЗАПУСКАЕТ доигранный одноразовый клип (время %.3f)"
			% time_after_restart)
	var windup := false
	for i in range(10):
		r.advance(0.05)
		if _bone_rotation(r, "ArmFront") < -1.0:
			windup = true
			break
	_check(windup, "повтор атаки: после рестарта клип реально проигрывает замах")

	# A frozen corpse must NOT restart: otherwise play(DYING) in the
	# "dead" state would start the fall again, and the dead one would move.
	r.freeze_last_frame(3)  # DYING
	var frozen_rot := _bone_rotation(r, "ArmFront")
	for i in range(6):
		r.play(3)
		r.advance(0.05)
	_check(is_equal_approx(_bone_rotation(r, "ArmFront"), frozen_rot),
		"повтор атаки: замороженный DYING не перезапускается повторным play(DYING)")

	r.queue_free()


## Bone angle by name. The full path is Hip/Torso/<bone>: Torso lies under Hip,
## not under the root, and the first version looked for "Torso/..." — it missed and
## SILENTLY returned 0.0, which is why the "pose stayed" check passed
## for nothing. Now a miss is a test error, not a silent zero.
func _bone_rotation(r: Object, bone_name: String) -> float:
	for path in ["Hip/Torso/" + bone_name, "Hip/" + bone_name, bone_name]:
		var b: Node = r.get_node_or_null(path)
		if b != null:
			return (b as Node2D).rotation
	_check(false, "тест: кость `%s` не найдена — проверка ниже была бы вхолостую"
		% bone_name)
	return 0.0


func _hip_scale_sign(r: Object) -> float:
	var hip: Node = r.get_node_or_null("Hip")
	if hip == null:
		return 0.0
	return signf(float((hip as Node2D).scale.x))


## The ONLY helper "octant -> vector". Extracted on purpose because it had
## to be rewritten: an axis inversion here silently inverted the rig mirror
## (player complaint: "it walks left or right and keeps turning its back").
## The octant vector i is the Godot angle (90 + i*45): 0=north, 6=east, 4=south,
## 2=west. The Godot angle is measured from +x counter-clockwise, so the vector = (cos, sin).
func _octant_vector(i: int) -> Vector2:
	var a := deg_to_rad(90.0 + float(i) * 45.0)
	return Vector2(cos(a), sin(a))


## The atlas rig of the hero: two authored views, sliding on north/south.
##
## The player complaint was "the character faces all 4 directions, although we decided on 2".
## Cause: rig.json held 4 views (N/E/S/W) and a map for all cardinal
## octants. The contract defended here:
##   * exactly TWO views — west and east;
##   * north and south are given to one of them and SLIDE (the view does not change);
##   * the diagonals do not create a new view either;
##   * the parts are not cropped (every texture has its canvas filled with content).
func _test_atlas_rig_two_views() -> void:
	if not ResourceLoader.exists("res://scripts/rigged_anim.gd"):
		return
	var cfg: Variant = JSON.parse_string(FileAccess.get_file_as_string(
		"res://assets/units/rig/rig_hero_atlas/rig.json"))
	if not (cfg is Dictionary):
		_check(false, "атлас: rig.json читается")
		return
	var views: Dictionary = (cfg as Dictionary).get("views", {})
	_check(views.size() == 2,
		"атлас: ровно ДВА authored-ракурса (%d)" % views.size())
	_check(views.has("west") and views.has("east"),
		"атлас: ракурсы называются west и east")
	# faces_east differs — otherwise both views are the same frame
	if views.has("west") and views.has("east"):
		var fw := int((views["west"] as Dictionary).get("faces_east", 0))
		var fe := int((views["east"] as Dictionary).get("faces_east", 0))
		_check(fw != fe,
			"атлас: ракурсы смотрят в разные стороны (west=%d east=%d)" % [fw, fe])

	# Sliding: north and south must not switch the view.
	var r := RiggedAnim.new()
	r.name = "UnitAnim"
	root.add_child(r)
	r.setup("rig/hero_atlas")
	if not r.is_loaded():
		_check(false, "атлас: риг загрузился")
		r.queue_free()
		return
	_check(r.missing_parts().is_empty(),
		"атлас: все текстуры частей на месте (%d отсутствует)" % r.missing_parts().size())

	var wv := str((views.get("west", {}) as Dictionary).get("", ""))
	# full circle: the view changes only on west/east
	var seen: Dictionary = {}
	for oct in range(8):
		r.set_direction_vec(_octant_vector(oct))
		for s in range(10):
			r._advance_rotation(0.06)
		seen[oct] = str(r.view_name)
	_check(seen[0] == seen[4],
		"атлас: север и юг дают один ракурс (N=%s S=%s) — скольжение"
			% [seen[0], seen[4]])
	# The diagonals click to the NEAREST cardinal (1,3 -> west; 5,7 -> east) —
	# that is correct behaviour. The invariant is not that they equal north:
	# it is that they do not produce a THIRD view.
	var allowed: Array[String] = [str(seen[0]), str(seen[6]), str(seen[2])]
	for oct in [1, 3, 5, 7]:
		_check(allowed.has(str(seen[oct])),
			"атлас: диагональ %d берёт существующий ракурс (%s)"
				% [oct, seen[oct]])
	_check(seen[6] != seen[2],
		"атлас: восток и запад — разные ракурсы (E=%s W=%s)"
			% [seen[6], seen[2]])

	# Parts are not cropped and not flipped. There are TWO checks, because each
	# catches its own class of defect:
	#   "empty centre"      — the pivot slipped off the joint (the old center_pivot bug);
	#   "content on the wrong side" — the part is flipped or cropped by
	#     half the canvas, and there is NO empty centre in that case, so the first
	#     check is green for such a defect (verified by mutation: a head
	#     shifted into the lower half of the canvas gives fill 0.50 like a whole one).
	# Anatomy sets the side: the head and the torso hang from the joint ABOVE
	# (neck/pelvis at the bottom of the part), the limbs — from BELOW (shoulder/pelvis/knee above).
	var hangs_from := {"head": -1, "torso": -1,
					   "arm_far": 1, "arm_near": 1, "thigh": 1, "shin": 1}
	# The parts are walked over for EVERY view separately. Before, the check looked
	# at the skeleton in its current state, that is at the last built view:
	# a broken part of the second view passed silently (verified by mutation).
	var total_parts := 0
	var total_hollow := 0
	var total_wrong := 0
	var details: Array[String] = []
	for vname in ["west", "east"]:
		var vdir := Vector2.LEFT if vname == "west" else Vector2.RIGHT
		r.set_direction_vec(vdir)
		for s in range(10):
			r._advance_rotation(0.06)
		_check(str(r.view_name) == vname,
			"атлас: ракурс `%s` действительно строится (получено `%s`)"
				% [vname, r.view_name])
		var found := _scan_parts(r, vname, hangs_from)
		total_parts += int(found["parts"])
		total_hollow += int(found["hollow"])
		total_wrong += int(found["wrong"])
		for d in found["details"]:
			details.append(str(d))

	_check(total_parts > 0,
		"атлас: у рига есть текстуры обоих ракурсов (%d)" % total_parts)
	_check(total_hollow == 0,
		"атлас: pivot каждой части попал в силуэт (пустых: %d %s)"
			% [total_hollow, str(details)])
	_check(total_wrong == 0,
		"атлас: части не перевёрнуты и не срезаны по половине (%s)"
			% str(details))

	r.queue_free()
	await process_frame


## Scan the parts of one view. Returns COUNTERS rather than checking itself:
## in GDScript int is passed by value, and a check inside a separate function
## would silently add nothing outside.
func _scan_parts(r: Node, vname: String, hangs_from: Dictionary) -> Dictionary:
	var parts := 0
	var hollow := 0
	var wrong := 0
	var details: Array[String] = []
	var stack: Array = [r]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for ch in n.get_children():
			stack.append(ch)
			if not (ch is Sprite2D):
				continue
			var t := (ch as Sprite2D).texture
			if t == null:
				continue
			parts += 1
			var fname := str(t.resource_path.get_file()).get_basename()
			var img := t.get_image()
			var w := img.get_width()
			var h := img.get_height()
			var cx := w / 2
			var cy := h / 2
			var opaque := false
			for dy in range(-1, 2):
				for dx in range(-1, 2):
					if img.get_pixel(cli(cx + dx), cli(cy + dy)).a > 0.1:
						opaque = true
			if not opaque:
				hollow += 1
				details.append("%s/%s: пустой центр" % [vname, fname])
				continue
			var up := 0
			var down := 0
			for y in range(h):
				for x in range(w):
					if img.get_pixel(x, y).a <= 0.1:
						continue
					if y < cy:
						up += 1
					else:
						down += 1
			var side := -1 if up > down else 1
			var want: int = int(hangs_from.get(fname, 0))
			if want != 0 and side != want:
				wrong += 1
				details.append("%s/%s: сторона %d, ждали %d"
					% [vname, fname, side, want])
	return {"parts": parts, "hollow": hollow, "wrong": wrong,
			"details": details}


func cli(v: int) -> int:
	return clampi(v, 0, 100000)


func _run() -> void:
	var tested := 0
	for backend in BACKENDS:
		var label := str(backend["name"])
		var path := str(backend["path"])
		if not ResourceLoader.exists(path):
			print("-- %s отсутствует (%s), пропущен" % [label, path])
			continue
		tested += 1
		print("-- проверка бэкенда: %s" % label)
		var obj: Object = _make_backend(backend)
		if obj == null:
			_check(false, "%s: не удалось создать экземпляр" % label)
			continue
		_test_members(label, obj)
		await _test_functional(label, obj, str(backend["set"]))

	_check(tested > 0, "проверен хотя бы один бэкенд анимации")
	_test_backend_selection()
	await _test_rig_textures()
	_test_rig_turning()
	await _test_atlas_rig_two_views()
	_report()


func _report() -> void:
	print("\n==== ИТОГ ====")
	if _fails.is_empty():
		print("RESULT: OK anim_contract_smoke (проверок: %d, провалов: 0)" % _checks)
	else:
		print("RESULT: FAIL anim_contract_smoke (проверок: %d, провалов: %d)"
			% [_checks, _fails.size()])
		for f in _fails:
			print("  FAIL " + f)
	quit(0 if _fails.is_empty() else 1)