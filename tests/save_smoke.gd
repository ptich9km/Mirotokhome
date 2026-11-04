extends SceneTree
## Round-trip мира через НАСТОЯЩИЙ JSON.
##
## Ключевое: сравнивать to_dict() с from_dict() в памяти бессмысленно —
## такой тест проходит и на сломанном коде, потому что Vector2 остаётся
## Vector2. Ломается только запись на диск. Поэтому здесь обязательный путь
##     to_json_dict() → JSON.stringify → JSON.parse_string → JsonSafe.decode
## и только потом сравнение.
##
## Запуск: godot --headless --path . --script res://tests/save_smoke.gd

const WORLD_SCRIPT := "res://scripts/world/world_state.gd"

## The slots live in a scratch directory: a test run must never touch the
## saves of the player (`tests/save_sandbox.gd`).
const Sandbox := preload("res://tests/save_sandbox.gd")

var _fails: Array[String] = []
var _checks := 0

func _initialize() -> void:
	Sandbox.use_test_dir()
	_test_codec_scalars()
	_test_world_roundtrip()
	_test_json_is_actually_safe()
	_test_missing_fields()
	_test_slots_and_backups()
	_test_version_and_corruption()
	_report()

# --- 1. Кодек сам по себе ---

func _test_codec_scalars() -> void:
	var src: Dictionary = {
		"i": 5, "f": 1.5, "s": "текст", "b": true, "nil": null,
		"v2": Vector2(3.5, -7.25), "v2i": Vector2i(4, 9), "v3": Vector3(1, 2, 3),
		"col": Color(0.25, 0.5, 0.75, 0.5),
		"arr": [1, Vector2(1, 2), {"nested": Vector2(8, 9)}],
		"deep": {"a": {"b": {"c": Vector2(-1, -2)}}},
	}
	var text: String = JsonSafe.dump(src)
	var back: Dictionary = JsonSafe.load_string(text) as Dictionary

	_check(back.get("i") == 5, "int пережил JSON")
	_check(back.get("f") == 1.5, "float 1.5 пережил JSON (не превратился в 2)")
	_check(back.get("s") == "текст", "строка пережила JSON")
	_check(back.get("b") == true, "bool пережил JSON")
	_check(back.get("nil") == null, "null пережил JSON")
	_check(back.get("v2") is Vector2 and back.v2 == Vector2(3.5, -7.25),
		"Vector2 восстановился как Vector2 (%s)" % str(back.get("v2")))
	_check(back.get("v2i") is Vector2i and back.v2i == Vector2i(4, 9),
		"Vector2i восстановился как Vector2i")
	_check(back.get("v3") is Vector3 and back.v3 == Vector3(1, 2, 3), "Vector3 восстановился")
	_check(back.get("col") is Color and back.col == Color(0.25, 0.5, 0.75, 0.5),
		"Color восстановился как Color (%s)" % str(back.get("col")))
	_check(back.get("arr") is Array and back.arr.size() == 3, "массив сохранил длину")
	_check(back.arr[1] is Vector2 and back.arr[1] == Vector2(1, 2), "Vector2 внутри массива")
	_check(back.arr[2].nested is Vector2, "Vector2 во вложенном словаре")
	_check(back.deep.a.b.c is Vector2 and back.deep.a.b.c == Vector2(-1, -2),
		"Vector2 на глубине 4 уровней")

# --- 2. Мир целиком через настоящий JSON ---

func _test_world_roundtrip() -> void:
	var st = _fresh_world()
	# Прогоняем тики, чтобы появились журнал, армии с целями, relations.
	var sim = (load("res://scripts/world/world_sim.gd") as GDScript).new(st)
	for i in range(37):
		sim.tick()

	# Слой-2.5 сам раскладывает id-суффиксы и инициализирует стартовый мир.
	# Путь НАМЕРЕННО идёт через to_json_text()/from_json_text() - ровно тот,
	# которым пишет и читает SaveSystem. Раньше тест звал JsonSafe.dump
	# напрямую и потому НЕ ловил мутацию to_json_dict(): тест был зелёным
	# при сломанном пути записи.
	var text: String = st.to_json_text()
	_check(text.length() > 0, "мир сериализуется в непустой JSON (%d символов)" % text.length())

	var st2 = (load(WORLD_SCRIPT) as GDScript).from_json_text(text)
	_check(st2 != null, "мир восстанавливается из JSON-текста")
	if st2 == null:
		return

	_check(st2._u == st._u and st2._c == st._c and st2._f == st._f
			and st2._a == st._a and st2._r == st._r, "счётчики id совпали")
	_check(st2.units.size() == st.units.size(), "юниты: %d = %d" % [st2.units.size(), st.units.size()])
	_check(st2.cities.size() == st.cities.size(), "города: %d = %d" % [st2.cities.size(), st.cities.size()])
	_check(st2.factions.size() == st.factions.size(), "фракции совпали")
	_check(st2.armies.size() == st.armies.size(), "армии совпали")
	_check(st2.regions.size() == st.regions.size(), "регионы совпали")

	_check(st2.day == st.day, "день мира: %d = %d" % [st2.day, st.day])
	_check(is_equal_approx(float(st2.global_threat), float(st.global_threat)),
		"угроза: %f = %f" % [float(st2.global_threat), float(st.global_threat)])
	_check(st2.relations.size() == st.relations.size(), "отношения совпали (%d)" % st2.relations.size())
	_check(st2.journal.size() == st.journal.size(), "журнал: %d = %d" % [st2.journal.size(), st.journal.size()])
	_check(st2.hero.get("name", "") == st.hero.get("name", ""), "имя героя в мире совпало")

	# ТИПЫ, а не только значения: именно их терял старый код.
	_check(st2.hero.get("pos") is Vector2, "hero.pos остался Vector2 (%s)" % str(st2.hero.get("pos")))
	var sample_region: String = str(st.regions.keys()[0])
	_check(st2.regions[sample_region].get("area_px") is Vector2,
		"regions[].area_px остался Vector2")
	var sample_city: String = str(st.cities.keys()[0])
	_check(st2.cities[sample_city].get("pos") is Vector2, "cities[].pos остался Vector2")
	# Armies may have fought to the last man during the 37 ticks; sample only
	# when at least one survived (the old `keys()[0]` crashed on an empty map).
	if st.armies.is_empty():
		_check(true, "armies пуст после симуляции — проверка координат пропущена")
	else:
		var sample_army: String = str(st.armies.keys()[0])
		_check(st2.armies[sample_army].get("pos") is Vector2, "armies[].pos остался Vector2")
		_check(st2.armies[sample_army].get("target") is Vector2, "armies[].target остался Vector2")
	_check(st2.factions[str(st.factions.keys()[0])].get("color") is Color,
		"factions[].color остался Color")

	# Значения координат, а не только тип.
	if st.hero.get("pos") is Vector2 and st2.hero.get("pos") is Vector2:
		_check(st2.hero.pos.distance_to(st.hero.pos) < 0.001, "координата героя совпала")

# --- 3. Честная проверка: JSON не должен терять типы ---

func _test_json_is_actually_safe() -> void:
	# Что было бы БЕЗ JsonSafe: сырой Vector2 в JSON.
	var naive: String = JSON.stringify({"pos": Vector2(3, 4)})
	var naive_back: Variant = JSON.parse_string(naive)
	_check(not (naive_back is Dictionary and (naive_back as Dictionary).get("pos") is Vector2),
		"контроль: сырой Vector2 через JSON НЕ восстанавливается (дефект реален)")
	# С JsonSafe — восстанавливается.
	var safe_back: Variant = JsonSafe.load_string(JsonSafe.dump({"pos": Vector2(3, 4)}))
	_check(safe_back is Dictionary and (safe_back as Dictionary).get("pos") is Vector2,
		"с JsonSafe Vector2 восстанавливается")

# --- 4. Поля, которые раньше терялись ---

func _test_missing_fields() -> void:
	var st = _fresh_world()
	st.day = 12345
	st.global_threat = 0.75
	st.relations["f-1:f-2"] = -40
	st.journal.append({"day": 12345, "kind": "test", "text": "запись"})
	st.hero["name"] = "Ксенодот"
	st.hero["pos"] = Vector2(120.5, 340.25)
	var text: String = JsonSafe.dump(st.to_dict())
	var st2 = (load(WORLD_SCRIPT) as GDScript).from_json_text(text)
	_check(st2.day == 12345, "день мира не обнулился (12345)")
	_check(is_equal_approx(float(st2.global_threat), 0.75), "угроза не обнулилась (0.75)")
	_check(st2.relations.get("f-1:f-2") == -40, "отношения не потерялись")
	_check(st2.journal.size() == 1, "журнал не потерялся")
	_check(st2.hero.get("name") == "Ксенодот", "герой не потерялся")
	_check(st2.hero.get("pos") is Vector2 and st2.hero.pos == Vector2(120.5, 340.25),
		"координата героя пережила дробные значения")

	# Пустой словарь тоже должен грузиться, а не падать.
	var empty = (load(WORLD_SCRIPT) as GDScript).from_json_text("{}")
	_check(empty != null and empty.day == 0, "пустой JSON даёт пустой мир, а не ошибку")
	_check(empty != null and empty.journal is Array, "journal остаётся типизированным массивом")
	# Совсем мусор — не должно падать.
	var junk = (load(WORLD_SCRIPT) as GDScript).from_json_text("не json вовсе")
	_check(junk == null, "битый текст даёт null, а не падение")

# --- 5. Слоты, атомарность, .bak ---

func _wipe_saves() -> void:
	Sandbox.wipe()


func _payload(tag: String, hp: int) -> Dictionary:
	return {
		"version": 1,
		"map": { "seed": 12345, "zone": "mid" },
		"hero": {
			"class": "mage", "name": tag,
			"current_hp": hp, "gold": 77, "pos": Vector2(64.5, 128.25),
			"inventory": ["Common iron Long Sword", "Potion Medium Healing"],
		},
		"world": { "day": hp, "cities": { "c-1": { "pos": Vector2(10, 20) } } },
		"quests": {},
		"meta": { "hero_name": tag, "day": hp },
	}


func _test_slots_and_backups() -> void:
	_wipe_saves()
	# Первая запись: .bak быть не должно - старого файла не было.
	var err := SaveSystem.save("slot_0", _payload("Первый", 10))
	_check(err == "", "первая запись без ошибки (%s)" % err)
	_check(FileAccess.file_exists(SaveSystem.slot_path("slot_0")), "файл слота создан")
	_check(not FileAccess.file_exists(SaveSystem.bak_path("slot_0")),
		"после первой записи .bak не существует (нечего страховать)")
	_check(not FileAccess.file_exists(SaveSystem.tmp_path("slot_0")),
		"временный .tmp не остался на диске")

	var r1 := SaveSystem.load_slot("slot_0")
	_check(not r1.has("error"), "слот читается без ошибки")
	_check(str(r1.get("data", {}).get("hero", {}).get("name", "")) == "Первый",
		"имя героя из файла совпало")
	_check(str(r1.get("meta", {}).get("hero_name", "")) == "Первый",
		"meta читается отдельно от данных")
	# Vector2 должен пережить и save, и load.
	var pos: Variant = r1.get("data", {}).get("hero", {}).get("pos", null)
	_check(pos is Vector2 and pos == Vector2(64.5, 128.25),
		"координата героя пережила запись в файл (%s)" % str(pos))
	var city_pos: Variant = r1.get("data", {}).get("world", {}).get("cities", {}) \
		.get("c-1", {}).get("pos", null)
	_check(city_pos is Vector2, "координата города пережила запись в файл")

	# Вторая запись: предыдущая должна уехать в .bak.
	var err2 := SaveSystem.save("slot_0", _payload("Второй", 20))
	_check(err2 == "", "вторая запись без ошибки (%s)" % err2)
	_check(FileAccess.file_exists(SaveSystem.bak_path("slot_0")),
		".bak появился после второй записи")
	_check(FileAccess.file_exists(SaveSystem.prev_path("slot_0")),
		"снимок прежнего сохранения появился после второй записи")
	var r2 := SaveSystem.load_slot("slot_0")
	_check(str(r2.get("data", {}).get("hero", {}).get("name", "")) == "Второй",
		"после перезаписи в слоте новое имя")
	var b := SaveSystem._read_doc(SaveSystem.prev_path("slot_0"))
	_check(str((b.get("data", {}) as Dictionary).get("hero", {}).get("name", "")) == "Первый",
		"в снимке прежнего сохранения лежит ПРЕДЫДУЩАЯ версия, а не текущая")
	# Список слотов для экрана. Слотов игрока 6 (с 05.10), а не 3: число
	# бралось константой и разъехалось с SaveSystem.PLAYER_SLOTS, из-за чего
	# проверка падала и на чистом master.
	var lst := SaveSystem.list_slots()
	_check(lst.size() == SaveSystem.PLAYER_SLOTS.size() + 1,
		"в списке слоты игрока + автосейв (%d)" % lst.size())
	var first: Dictionary = lst[0]
	_check(first.get("exists") == true, "слот_0 отмечен как существующий")
	_check(str(first.get("meta", {}).get("hero_name", "")) == "Второй",
		"в списке слотов видно имя героя без загрузки данных")
	_check(lst[1].get("exists") == false, "пустой слот отмечен как несуществующий")
	_check(SaveSystem.has_autosave() == false, "автосейва пока нет")

	# Пустой слот - не ошибка, а отсутствие.
	var empty := SaveSystem.load_slot("slot_2")
	_check(empty.is_empty(), "чтение пустого слота даёт пустой словарь, не ошибку")

	# Автосейв.
	var err3 := SaveSystem.save(SaveSystem.AUTOSAVE_SLOT, _payload("Авто", 33))
	_check(err3 == "", "автосейв записан (%s)" % err3)
	_check(SaveSystem.has_autosave(), "has_autosave() стал true")
	_wipe_saves()


# --- 6. Версия и битый файл ---

func _test_version_and_corruption() -> void:
	_wipe_saves()
	SaveSystem.save("slot_1", _payload("Обычный", 5))
	# Файл из будущей версии должен быть отклонён ЦЕЛИКОМ.
	var raw := FileAccess.get_file_as_string(SaveSystem.slot_path("slot_1"))
	var doc: Dictionary = JSON.parse_string(raw) as Dictionary
	doc["version"] = 99
	var f := FileAccess.open(SaveSystem.slot_path("slot_1"), FileAccess.WRITE)
	f.store_string(JSON.stringify(doc))
	f.close()
	var rv := SaveSystem.load_slot("slot_1")
	_check(str(rv.get("error", "")) == "version", "файл новее текущего отклонён")
	_check(int(rv.get("file_version", 0)) == 99, "в отказе видна версия файла")
	_check(not rv.has("data"), "данные из будущей версии НЕ применены частично")

	# Битый файл + валидный .bak -> чтение чинится само.
	# Сначала ДВЕ записи, чтобы .bak содержал валидную v1 (файл из прошлой
	# части проверки версии содержит version=99 и в .bak попал бы именно он).
	_wipe_saves()
	SaveSystem.save("slot_1", _payload("До отката", 4))
	SaveSystem.save("slot_1", _payload("После отката", 5))   # .bak = "До отката", день 4
	var f2 := FileAccess.open(SaveSystem.slot_path("slot_1"), FileAccess.WRITE)
	f2.store_string("{ это не json")
	f2.close()
	var rc := SaveSystem.load_slot("slot_1")
	_check(not rc.has("error"), "битый файл восстановлен из .bak")
	# Мир и прогресс живут в своём элементе слота (решение 22.10): день минувшего
	# сохранения лежит в process.json.bak, а не в hero.json.bak.
	var proc_bak: Dictionary = SaveSystem._read_doc(SaveSystem.bak_of(
		SaveSystem.part_path("slot_1", SaveSystem.PROCESS_FILE)))
	_check(int((proc_bak.get("data", {}) as Dictionary).get("world", {}).get("day", -1)) == 4,
		"в снимке прогресса — день 4, а не текущий")
	_check(SaveSystem._reads_ok(SaveSystem.slot_path("slot_1")),
		"основной файл после отката снова читается")

	# Битый файл БЕЗ .bak - честная ошибка, а не тихая пустая игра.
	_wipe_saves()
	SaveSystem.save("slot_2", _payload("Единственная", 9))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(SaveSystem.bak_path("slot_2")))
	var f3 := FileAccess.open(SaveSystem.slot_path("slot_2"), FileAccess.WRITE)
	f3.store_string("{{{")
	f3.close()
	var rd := SaveSystem.load_slot("slot_2")
	_check(str(rd.get("error", "")) == "corrupt", "битый файл без .bak даёт ошибку corrupt")
	_check(not rd.has("data"), "битые данные не подставлены в игру")
	_wipe_saves()


# --- вспомогательное ---

func _fresh_world():
	var st_script: GDScript = load(WORLD_SCRIPT)
	var st = st_script.new()
	var f_h: Dictionary = st.new_faction("Альянс Света")
	var f_e: Dictionary = st.new_faction("Орды Огня")
	var r: Dictionary = st.new_region("Регион 1")
	var c_h: Dictionary = st.new_city("Город 1", f_h.id, r.id)
	var c_e: Dictionary = st.new_city("Город 2", f_e.id, r.id)
	c_h["pos"] = Vector2(120.5, 300.25)
	c_e["pos"] = Vector2(-64.0, 18.75)
	var u1: Dictionary = st.new_unit(f_h.id, "fire")
	var u2: Dictionary = st.new_unit(f_e.id, "water")
	var a_h: Dictionary = st.new_army(f_h.id, Vector2(300, 400))
	var a_e: Dictionary = st.new_army(f_e.id, Vector2(700, 400))
	a_h["unit_ids"] = [u1.id]
	a_h["target"] = Vector2(710.5, 405.25)
	a_e["unit_ids"] = [u2.id]
	f_h["color"] = Color(1.0, 0.9, 0.2)
	st.relations["%s:%s" % [f_h.id, f_e.id]] = -40
	st.relations["%s:%s" % [f_e.id, f_h.id]] = -40
	return st

func _check(cond: bool, label: String) -> void:
	_checks += 1
	if cond:
		print("OK   ", label)
	else:
		print("FAIL ", label)
		_fails.append(label)

func _report() -> void:
	print("---")
	print("проверок: %d" % _checks)
	if _fails.is_empty():
		print("RESULT: OK save_smoke")
		quit(0)
	else:
		print("RESULT: FAIL save_smoke (провалено: %d)" % _fails.size())
		for f in _fails:
			print("  - ", f)
		quit(1)
