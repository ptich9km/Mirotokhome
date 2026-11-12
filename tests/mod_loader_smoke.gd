extends SceneTree
## Mods: loader, order, extends/patch/remove, conflicts, mod:// paths.
##
## The test creates ITS OWN mods in `user://mods/_smoke_*` and removes them at
## the end: the player's mods are never touched and their count is not relied
## on — concrete ids/keys are checked. Entry format — see docs/mods.md.
##
## Run: godot --headless --path . --script res://tests/mod_loader_smoke.gd

var _fails: Array[String] = []

const ROOT := "user://mods"


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	_cleanup()
	_cleanup()
	# In `--script` runs mods are off by default (data is checked against the
	# base) — this test checks mods themselves, so it enables them explicitly.
	ModLoader.set_active(true)
	ModLoader.reset()
	_build_mods()

	var mods := ModLoader.mods()
	var order: Array[String] = []
	for m in mods:
		order.append(str(m["id"]))
	var base_i := order.find("_smoke_base")
	var patch_i := order.find("_smoke_patch")
	_check(base_i >= 0, "мод '_smoke_base' найден")
	_check(patch_i >= 0, "мод '_smoke_patch' найден")
	_check(base_i >= 0 and patch_i >= 0 and base_i < patch_i,
		"load_after: '_smoke_base' применяется раньше '_smoke_patch'")
	_check(order.has("_smoke_bad"), "мод с битым data всё равно в списке (виден игроку)")

	# --- units: a new set via extends + a patch of the base ---
	var hound := UnitDB.get_set("monsters/smoke_hound")
	_check(not hound.is_empty(), "новый набор units загружен")
	_check(int(hound.get("frames", 0)) == 12, "extends: frames унаследованы от wolves (12)")
	_check(str(hound.get("name_ru", "")) == "Смоук-гончая", "extends: своё поле перекрыло базу")
	_check(str(hound.get("prefix", "")) == "sprites", "extends: служебные поля базы на месте")
	_check(int(hound.get("palette", 0)) == 5, "extends: враждебность (palette=5) унаследована")

	var wolf := UnitDB.get_set("monsters/wolf")
	_check(int(wolf.get("w", 0)) == 100, "patch: поле w у базы изменено модом")
	_check(str(wolf.get("smoke_note", "")) == "patched", "patch: добавлено новое поле к базе")
	_check(int(wolf.get("h", 0)) == 64, "patch: нетронутое поле базы сохранилось")

	_check(UnitDB.get_set("monsters/smoke_removable").is_empty(), "remove: набор удалён модом")

	# --- items, spells, structures ---
	var blade := ItemDB.find("Common smoke blade")
	_check(not blade.is_empty(), "новый предмет добавлен")
	_check(str(blade.get("icon", "")).begins_with("user://"), "mod:// путь к иконке развёрнут")
	_check(int(blade.get("damage_min", -1)) == 7, "новый предмет несёт свои статы")
	_check(str(blade.get("type", "")) == "Long Sword",
		"поле type предмета свободно (не занято маршрутизацией into)")

	var bolt := SpellDB.get_spell("Smoke_Bolt")
	_check(str(bolt.get("sphere", "")) == "Fire", "новое заклинание добавлено")
	_check(int(bolt.get("damage", 0)) == 21, "новое заклинание несёт свой урон")

	var house := StructureDB.get_by_id(900)
	_check(str(house.get("folder", "")) == "smoke_house", "новая структура добавлена")
	_check(StructureDB.get_by_id(200).has("folder"), "базовые структуры не пострадали")

	# --- diagnostics ---
	var errs := "\n".join(ModLoader.errors())
	var warns := "\n".join(ModLoader.warnings())
	_check(errs.contains("is already taken"), "конфликт ключей — ошибка с указанием, кто занял")
	_check(errs.contains("_smoke_clash"), "ошибка называет мод-виновника")
	_check(errs.contains("files not found"), "потерянный ассет — ошибка, а не розовый квадрат")
	_check(errs.contains("broken JSON"), "битый файл мода — ошибка, игра работает")
	_check(errs.contains("patch 'monsters/no_such_patch_target'"), "patch несуществующего — ошибка")
	_check(warns.contains("edited by two mods"), "два мода на одном ключе — предупреждение")

	# --- misc ---
	_check(ModLoader.resolve("mod://_smoke_base/assets/blade.png") ==
		"user://mods/_smoke_base/assets/blade.png", "resolve(mod://) даёт путь мода")
	_check(ModLoader.resolve("res://assets/x.png") == "res://assets/x.png", "обычный путь не тронут")
	_check(ModLoader.resolve("mod://no_such_mod/a.png") == "mod://no_such_mod/a.png",
		"resolve несуществующего мода не падает")
	_check(ModLoader.resolve("mod://broken") == "mod://broken", "кривой mod:// не падает")
	var profile := ModLoader.save_profile()
	_check(profile.size() >= 5, "профиль для сейва собирается")
	_check(profile[0].has("id") and profile[0].has("version"), "профиль: id и version")

	_cleanup()
	ModLoader.reset()
	_report()


# --- test mods ----------------------------------------------------------------

func _build_mods() -> void:
	_mkdir(ROOT)
	# 1) base: a new unit via extends, an item, a spell, a structure, a unit to remove
	_write("_smoke_base/mod.json", {
		"id": "_smoke_base", "name": "Smoke Base", "version": "1.0.0",
		"author": "test", "priority": 0, "depends_on": [],
	})
	_write("_smoke_base/assets/blade.png", "not-a-real-png")   # only existence matters
	_write("_smoke_base/data/units.json", [
		{"into": "unit", "key": "monsters/smoke_hound", "extends": "monsters/wolf",
			"name_ru": "Смоук-гончая", "palette": 5, "tier": 1},
		{"into": "unit", "key": "monsters/smoke_removable", "extends": "monsters/wolf"},
	])
	_write("_smoke_base/data/items.json", {
		"entries": [
			{"into": "item", "key": "Common smoke blade", "name_ru": "Дымный клинок",
				"type": "Long Sword", "material": "steel", "quality": "Common",
				"icon": "mod://_smoke_base/assets/blade.png",
				"damage_min": 7, "damage_max": 9, "price": 50},
		],
	})
	_write("_smoke_base/data/spells.json", [
		{"into": "spell", "key": "Smoke_Bolt", "name": "Smoke_Bolt", "sphere": "Fire",
			"damage": 21, "mana_cost": 4},
	])
	_write("_smoke_base/data/structures.json", [
		{"into": "structure", "key": "900", "folder": "smoke_house", "prefix": "house",
			"tile_width": 3, "tile_height": 3},
	])

	# 2) base patch: waits for the base via load_after
	_write("_smoke_patch/mod.json", {
		"id": "_smoke_patch", "name": "Smoke Patch", "version": "1.0.0",
		"load_after": ["_smoke_base"], "affects_save": true,
	})
	_write("_smoke_patch/data/patch.json", [
		{"into": "unit", "op": "patch", "key": "monsters/wolf", "w": 100, "smoke_note": "patched"},
	])

	# 3) a second patcher of the same key -> a patch-conflict warning
	_write("_smoke_patch2/mod.json", {
		"id": "_smoke_patch2", "name": "Smoke Patch 2", "version": "1.0.0",
		"load_after": ["_smoke_patch"], "priority": 1,
	})
	_write("_smoke_patch2/data/patch.json", [
		{"into": "unit", "op": "patch", "key": "monsters/wolf", "h": 64},
	])

	# 4) broken JSON
	_write("_smoke_bad/mod.json", {"id": "_smoke_bad", "name": "Smoke Bad"})
	_write_raw("_smoke_bad/data/broken.json", "{ this is not json")

	# 5) key conflict, a lost asset, remove, patch of a missing key
	_write("_smoke_clash/mod.json", {
		"id": "_smoke_clash", "name": "Smoke Clash", "load_after": ["_smoke_base"],
	})
	_write("_smoke_clash/data/x.json", [
		{"into": "unit", "key": "monsters/wolf", "name_ru": "Перехват"},
		{"into": "unit", "key": "monsters/smoke_lost", "icon": "mod://_smoke_clash/assets/nope.png"},
		{"into": "unit", "op": "remove", "key": "monsters/smoke_removable"},
		{"into": "unit", "op": "patch", "key": "monsters/no_such_patch_target", "name_ru": "нет такого"},
	])


# --- helpers ------------------------------------------------------------------

func _write(rel: String, data: Variant) -> void:
	_write_raw(rel, JSON.stringify(data, "\t"))


func _write_raw(rel: String, text: String) -> void:
	var path := ROOT.path_join(rel)
	var dir := path.get_base_dir()
	if DirAccess.open(dir) == null:
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		_check(false, "не записать " + path)
		return
	f.store_string(text)
	f.close()


func _mkdir(path: String) -> void:
	if DirAccess.open(path) == null:
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path))


func _cleanup() -> void:
	for name in ["_smoke_base", "_smoke_patch", "_smoke_patch2", "_smoke_bad", "_smoke_clash"]:
		_rmrf(ROOT.path_join(name))


func _rmrf(path: String) -> void:
	var da := DirAccess.open(path)
	if da == null:
		return
	da.list_dir_begin()
	var name := da.get_next()
	while name != "":
		var child := path.path_join(name)
		if da.current_is_dir():
			_rmrf(child)
		else:
			DirAccess.remove_absolute(ProjectSettings.globalize_path(child))
		name = da.get_next()
	da.list_dir_end()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _check(cond: bool, label: String) -> void:
	if cond:
		print("OK   ", label)
	else:
		print("FAIL ", label)
		_fails.append(label)


func _report() -> void:
	print("---")
	if _fails.is_empty():
		print("RESULT: OK mod_loader_smoke")
		quit(0)
	else:
		print("RESULT: FAIL mod_loader_smoke (%d)" % _fails.size())
		quit(1)
