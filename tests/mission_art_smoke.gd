extends SceneTree
## Mission sheets of the city heads: QuestIcons owns slugs, paths, frames;
## MVP quest types map to sheets. Run:
##   godot --headless --path . --script res://tests/mission_art_smoke.gd

var _fails: Array[String] = []

func _check(ok: bool, what: String) -> void:
	if not ok:
		_fails.append(what)
	print("MISSION: %s %s" % ["ok  " if ok else "FAIL", what])


func _slugs_ok() -> void:
	var want := {
		"FIND_ITEM": "find_items",
		"GATHER": "alchemy_gather",
		"KILL_SPECIES": "destroy",
		"KILL_GROUP": "destroy",
		"KILL_TARGET": "boss_kill",
	}
	for t in want:
		var slug := QuestIcons.mission_slug_for_type(t)
		_check(slug == want[t], "slug_of(%s)=%s, want %s" % [t, slug, want[t]])


func _frames_ok(slug: String) -> void:
	if not QuestIcons.has_mission_art(slug):
		print("MISSION: (no art yet) " + slug)
		return
	var frames := QuestIcons.mission_frames(slug)
	_check(frames.size() == QuestIcons.MISSION_FRAMES,
		"%s: frames=%d, want %d" % [slug, frames.size(), QuestIcons.MISSION_FRAMES])
	for i in range(QuestIcons.MISSION_FRAMES):
		# An imported PNG is a CompressedTexture2D, not an ImageTexture: casting
		# to ImageTexture returned null and every frame read as "size=null".
		var img: Texture2D = frames[i] as Texture2D
		var size_txt := "null" if img == null else str(img.get_size())
		# Texture2D.get_size() is Vector2; comparing it to Vector2i is a parse
		# error in Godot 4.7 ("Invalid operands Vector2 and Vector2i"), so the
		# comparison has to use the same type.
		_check(img != null and img.get_size() == Vector2(64, 64),
			"%s[%d]: size=%s" % [slug, i, size_txt])


func _run() -> void:
	_slugs_ok()
	_quest_slugs_ok()
	for slug in ["find_items", "destroy", "alchemy_gather", "escort",
			"build_repair", "caravan", "boss_kill", "faction_war", "story_chain"]:
		_frames_ok(slug)


## The sheet must follow the QUEST, not only its type: the two GATHER templates
## are herb picking and faction tags, and the player rightly asked why a faction
## hunt showed a daisy (20.11).
func _quest_slugs_ok() -> void:
	var cases := [
		[{"template": "gather_tags", "type": "GATHER"}, "faction_war",
			"фракционные бирки -> стена щитов"],
		[{"template": "gather_herbs", "type": "GATHER"}, "alchemy_gather",
			"сбор трав -> ромашка"],
		[{"template": "kill_group", "type": "KILL_GROUP"}, "destroy",
			"зачистка окрестностей -> мечи"],
		[{"template": "chain_cas_a1", "type": "KILL_SPECIES",
			"chain_id": "count_after_shift"}, "story_chain",
			"стадия сценария -> золотой ключ"],
		[{"template": "kill_species", "type": "KILL_SPECIES"}, "destroy",
			"охота на вид -> мечи"],
		[{"template": "urgent_hunt", "type": "URGENT"}, "destroy",
			"срочная охота -> мечи, а не старый значок"],
		[{"template": "deliver_tome", "type": "DELIVER"}, "caravan",
			"доставка -> телега, а не старая книга"],
	]
	for case in cases:
		var q: Dictionary = case[0]
		var want: String = case[1]
		var slug := QuestIcons.mission_slug_for_quest(q)
		_check(slug == want, "%s: slug=%s, want %s" % [case[2], slug, want])
	_minimap_icons_ok()


## The minimap sign: a flat 16x16 glyph with its own dark outline, so it survives
## on grass, sand, road and water. No animation - a blinking map is noise.
func _minimap_icons_ok() -> void:
	var size := QuestIcons.MINIMAP_ICON_SIZE
	for slug in ["find_items", "destroy", "alchemy_gather", "faction_war",
			"story_chain"]:
		var icon := QuestIcons.mission_minimap_icon(slug)
		_check(icon != null, "%s: нет знака для миникарты" % slug)
		if icon == null:
			continue
		_check(icon.get_width() == size and icon.get_height() == size,
			"%s: знак миникарты %dx%d, want %d" % [slug, icon.get_width(),
				icon.get_height(), size])
		var solid := 0
		var outline := 0
		for y in range(icon.get_height()):
			for x in range(icon.get_width()):
				var c := icon.get_pixel(x, y)
				if c.a <= 0.05:
					continue
				solid += 1
				if c.r < 0.15 and c.g < 0.15 and c.b < 0.15:
					outline += 1
		_check(solid > size * size / 6, "%s: знак почти пустой (%d px)" % [slug, solid])
		_check(outline > 0, "%s: у знака нет тёмной обводки" % slug)
	_check(QuestIcons.mission_minimap_icon("no_such_slug") == null,
		"неизвестный лист не даёт знак")


func _finish() -> void:
	if _fails.is_empty():
		print("MISSION: RESULT: OK")
	else:
		print("MISSION: RESULT: FAIL (%d): %s" % [_fails.size(), str(_fails)])
	quit(0 if _fails.is_empty() else 1)


func _initialize() -> void:
	_run()
	_finish()
