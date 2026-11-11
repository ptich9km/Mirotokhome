extends SceneTree
## Headless check of the quest marker height (player report 06.11):
## the "!"/"?" icon sat at the crotch instead of above the head.
##
## The height used to come from `UnitDB.sel_box().position.y` — a coordinate
## INSIDE the texture (10 px for a 64 px frame), not "pixels above the feet" —
## and was clamped to 24 px, which is waist level on a 54 px figure.
##
## Run:
##   godot --headless --path . --script res://tests/quest_marker_height_smoke.gd

var _fails: Array = []
var _npc: Npc = null

## A real quest giver set from the generator (city head of the human city).
const HEAD_SET := "city_human_head/t0"
## marks/*.png are 24x24 and the sprite is centred on the marker origin.
const MARKER_HALF := 12.0


func _initialize() -> void:
	Game.hero_stats = {"body": 10, "agility": 10, "mind": 10, "spirit": 10,
		"blade": 0, "bludgeon": 0, "pike": 0, "shooting": 0,
		"fire": 0, "water": 0, "air": 0, "earth": 0, "astral": 0,
		"weapon": "staff", "shield": false, "armor": "light"}
	Game.hero_class = "mage"
	Game.hero_name = "Маг"
	call_deferred("_run")


func _check(ok: bool, what: String) -> void:
	if not ok:
		_fails.append(what)
	print("QUESTMARK: %s %s" % ["ok  " if ok else "FAIL", what])


func _run() -> void:
	var err := change_scene_to_file("res://scenes/main.tscn")
	if err != OK:
		_check(false, "main.tscn не загрузился")
		_finish()
		return
	await process_frame
	await create_timer(0.8).timeout

	# A head of a city on a live map: the same node the generator spawns.
	_npc = Npc.new()
	_npc.name = "NpcMarkerProbe"
	_npc.anim_set = HEAD_SET
	_npc.role = "head"
	_npc.is_city_head = true
	_npc.city_id = "probe"
	var player := get_first_node_in_group("player") as Node2D
	_npc.position = player.global_position + Vector2(96, 0) if player != null \
		else Vector2(320, 320)
	current_scene.add_child(_npc)
	await process_frame
	await process_frame

	var marker: QuestMarker = _npc.quest_marker
	_check(marker != null, "маркер создан")
	if marker == null:
		_finish()
		return

	# The head of the figure in unit coordinates (feet ≈ 0, crown is negative y).
	var figure_top := 0.0
	if _npc._anim != null:
		var r: Rect2 = _npc._anim.content_rect()
		figure_top = -r.position.y
	_check(figure_top > 20.0, "верх фигуры измерен (%.1f px)" % figure_top)

	# The marker bobs by a couple of pixels, so the check leaves that room.
	var h: float = -marker.position.y
	_check(h > figure_top + 10.0,
		"маркер выше макушки: %.1f > %.1f + 10" % [h, figure_top])
	_check(h - MARKER_HALF > figure_top - 1.0,
		"иконка не налезает на голову: низ %.1f, макушка %.1f"
			% [h - MARKER_HALF, figure_top])
	_check(h - MARKER_HALF - figure_top <= 12.0,
		"зазор не раздут: %.1f px" % [h - MARKER_HALF - figure_top])
	_check(h > 40.0, "высота не прежние 24 px (%.1f)" % h)

	_finish()


func _finish() -> void:
	if _fails.is_empty():
		print("QUESTMARK: RESULT: OK")
	else:
		print("QUESTMARK: RESULT: FAIL (%d): %s" % [_fails.size(), str(_fails)])
	quit(0 if _fails.is_empty() else 1)
