extends SceneTree

## Smoke for the two Kimi civilian sets: DB record resolves and all 12
## frames load through the same paths UnitAnim.setup uses.

func _init() -> void:
	var ok := true
	for set_name in ["npc/townsman_m", "npc/townswoman_f",
			"npc/ork_townsman_m", "npc/ork_townswoman_f",
			"npc/druid_townsman_m", "npc/druid_townswoman_f",
			"npc/necro_townsman_m", "npc/necro_townswoman_f",
			"npc/human_bandit_m", "npc/human_bandit_f",
			"npc/ork_bandit_m", "npc/ork_bandit_f",
			"npc/druid_bandit_m", "npc/druid_bandit_f",
			"npc/necro_bandit_m", "npc/necro_bandit_f"]:
		if UnitDB.get_set(set_name).is_empty():
			print("FAIL no db set ", set_name)
			ok = false
			continue
		var folder := str(UnitDB.get_set(set_name).get("folder", set_name))
		var prefix := UnitDB.frame_prefix(set_name)
		var n: int = UnitDB.frame_count(set_name)
		if n != 12:
			print("FAIL frames ", set_name, " = ", n)
			ok = false
		for i in range(n):
			var path := UnitDB.frame_path(folder, prefix, i + 1)
			if not ResourceLoader.exists(path):
				print("FAIL missing ", path)
				ok = false
		var anim := UnitAnim.new()
		anim.setup(set_name)
		if anim.frames.size() != 12:
			print("FAIL unit_anim frames ", set_name, " = ", anim.frames.size())
			ok = false
		else:
			print("OK ", set_name, " 12 frames, dirs=", UnitDB.dirs(set_name))
	print("RESULT: ", "OK" if ok else "FAIL")
	quit(0 if ok else 1)
