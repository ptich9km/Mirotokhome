extends SceneTree
## Smoke package P: перф без отката плотности.
## P1 фаза деревьев, P2 process off, P3 minimap cache, P5 far-AI pause.

var _fails: Array[String] = []
var _checks := 0


func _initialize() -> void:
	call_deferred("_run")


func _check(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(msg)
	print(("  OK  " if ok else "  FAIL") + " " + msg)


## Ключи object_db.json — напрямую из файла.
##
## ObjectDB отдаёт запись по имени (`get_obj`), но НЕ имеет `all()`/`names()`
## — проверил весь файл. Читаем БД саму: сверка должна быть между РАЗНЫМИ
## источниками, иначе получится тождество. Источники здесь такие:
##   - object_db.json  — что справочник обещает
##   - каталог на диске — что реально есть
func _db_names() -> Array[String]:
	var names: Array[String] = []
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(
		ObjectDB.DB_PATH))
	if parsed is Dictionary:
		for k in (parsed as Dictionary).keys():
			names.append(str(k))
	return names


## Папки объектов на диске — те, где реально лежат кадры sprites-NNN.png.
func _disk_names() -> Array[String]:
	var names: Array[String] = []
	var d := DirAccess.open("res://assets/map-objects")
	if d == null:
		return names
	for sub in d.get_directories():
		var folder := sub.get_file()
		var fd := DirAccess.open("res://assets/map-objects/" + folder)
		if fd == null:
			continue
		for f in fd.get_files():
			if f.begins_with("sprites-") and f.ends_with(".png"):
				names.append(folder)
				break
	return names


func _run() -> void:
	print("-- AlmObstacle --")
	var ob := AlmObstacle.new()
	root.add_child(ob)
	# Статичный seedream-объект: все 19 нынешних объектов phases=1/frames=1,
	# поэтому после setup процесс обязан быть выключен.
	ob.setup("tree_oak", 1, 112, 128, 56, 128, 0)
	_check(ob.frame_count <= 1 or not ob.is_processing(),
		"статичный obstacle process off (frames=%d processing=%s)" % [ob.frame_count, str(ob.is_processing())])
	ob.queue_free()

	# Анимированных объектов на карте больше нет: арт Аллодов удалён, а
	# seedream-деревья статичны. Раньше здесь стоял pine1 с 7 фазами, и
	# проверка была ВСЕГДА зелёной только потому, что setup() доверяет
	# справочнику и не смотрит на диск — 7 обещанных кадров при нуле файлов.
	# Теперь инвертировано: подтверждаем, что анимированных объектов нет.
	var animated := 0
	for name in _db_names():
		if int(ObjectDB.frame_count(name)) > 1:
			animated += 1
			print("  анимированный: %s" % name)
	_check(animated == 0,
		"анимированных объектов сейчас нет (после удаления Аллодов), найдено: %d" % animated)

	var ob2 := AlmObstacle.new()
	root.add_child(ob2)
	ob2.setup("tree_oak", 1, 112, 128, 56, 128, 0)
	_check(ob2._timer >= 0.0 and ob2._timer < 1.0, "фаза таймера в диапазоне FRAME_TIME")
	_check(not ob2.is_processing(), "статичный объект не крутит фазы")
	ob2.queue_free()

	print("-- справочник совпадает с диском --")
	# Сторож на тот класс дефекта, который снимаем. ObjectDB обещает frames,
	# но файлы на диске могли исчезнуть — тогда редактор и карта грузят пустоту
	# молча. Раньше это стоило нам невидимого рига и pine1 с 7 кадрами при 0.
	#
	# Обе стороны сверяются по РАЗНЫМ источникам (БД против диска). Сверка
	# источника с самим собой прошла бы всегда.
	var db_names := _db_names()
	var disk_names := _disk_names()
	_check(db_names.size() > 0, "справочник не пуст (%d объектов)" % db_names.size())

	# 1) Запись без папки: справочник обещает объект, которого нет.
	var ghost_db := 0
	for name in db_names:
		if not (name in disk_names):
			ghost_db += 1
			print("  ПРИЗРАК (запись без папки): %s" % name)
	_check(ghost_db == 0, "в справочнике нет записей без папки (%d)" % ghost_db)

	# 2) Папка без записи: объект лежит, но справочник о нём не знает —
	#    редактор не сможет его поставить.
	var ghost_disk := 0
	for name in disk_names:
		if not (name in db_names):
			ghost_disk += 1
			print("  ПРИЗРАК (папка без записи): %s" % name)
	_check(ghost_disk == 0, "на диске нет папок без записи в справочнике (%d)" % ghost_disk)

	# 3) Обещанные кадры физически существуют.
	var empty_frames := 0
	var missing := 0
	for name in db_names:
		var frames := int(ObjectDB.frame_count(name))
		if frames <= 0:
			empty_frames += 1
			print("  БЕЗ КАДРОВ: %s" % name)
			continue
		for f in range(1, frames + 1):
			if not ResourceLoader.exists(ObjectDB.frame_path(name, f)):
				missing += 1
				print("  НЕТ ФАЙЛА: %s кадр %d" % [name, f])
				break
	_check(empty_frames == 0, "у всех объектов frames>0 (нулевых: %d)" % empty_frames)
	_check(missing == 0,
		"у всех объектов файлы кадров на диске (без файлов: %d)" % missing)

	print("-- конфиг плотность не снижена --")
	_check(GameConfig.designi("mid", "gray_count_min") >= 120, "mid.gray_count_min>=120")
	_check(GameConfig.designf("mid", "tree_density") >= 0.18, "mid.tree_density>=0.18 (=%.2f)" % GameConfig.designf("mid", "tree_density"))
	_check(GameConfig.geti("spawn", "gray_target") >= 150, "gray_target>=150")

	print("-- far-AI: код есть --")
	var e_src := FileAccess.get_file_as_string("res://scripts/enemy.gd")
	var n_src := FileAccess.get_file_as_string("res://scripts/npc.gd")
	_check(e_src.contains("1600.0 * 1600.0"), "enemy far-pause порог есть")
	# npc.gd since the guard split uses `sleep_r` (1100 for guards, 1600 for
	# citizens) and compares squared distances; the old literal is gone.
	_check(n_src.contains("var sleep_r :=") and n_src.contains("sleep_r * sleep_r"),
		"npc far-pause порог есть (sleep_r по роли)")

	print("-- minimap cache --")
	var ui_src := FileAccess.get_file_as_string("res://scripts/ui.gd")
	_check(ui_src.contains("_minimap_base"), "ui.gd имеет кэш _minimap_base")
	_check(ui_src.contains("blit_rect"), "ui.gd blit_rect для базы")

	print("-- spatial hash separation --")
	var g_src := FileAccess.get_file_as_string("res://scripts/game.gd")
	_check(g_src.contains("_sep_rebuild_grid"), "game.gd имеет spatial hash для separation")
	_check(g_src.contains("_sep_neighbors"), "game.gd ищет соседей по вёдрам")

	_report()


func _report() -> void:
	print()
	if _fails.is_empty():
		print("RESULT: OK package_p_smoke (checks=%d)" % _checks)
		quit(0)
	else:
		for f in _fails:
			print("FAIL: " + f)
		print("RESULT: FAIL package_p_smoke (checks=%d fails=%d)" % [_checks, _fails.size()])
		quit(1)
