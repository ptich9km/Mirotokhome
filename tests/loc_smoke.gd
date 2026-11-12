extends SceneTree
## Смоук переключения языка RU/ENG (scripts/loc.gd, assets/locale/ui.json).
##
## Закрывает то, что локализация ломает «молча»:
##
##  * **Ключ не найден -> показан сам ключ.** Без проверки интерфейс молча
##    показывает `ui.menu.new_game` вместо текста.
##  * **Ключ есть только в одном языке.** Тогда в этом языке строка падает на
##    русский — заметно, но легко пропустить. Проверяем полноту всех записей.
##  * **Ключ-сирота в .json.** Уже не используется, но лежит: чинит его
##    бесполезно, а удалить забывают.
##  * **Выбор языка не переживает перезапуск.** Тогда игроку приходится
##    переключать каждый раз.
##  * **Локализация не должна трогать игровые данные.** Это главная ловушка:
##    `loot_icons.gd:92` разбирает кириллицу из `name_ru`, чтобы выбрать иконку
##    зелья. Если завернуть это в Loc, смена языка поменяет иконки — игровой
##    баг, а не косметика. Проверяем, что в режиме EN иконка та же.
##
## Запуск: godot --headless --path . --script res://tests/loc_smoke.gd

const LOC_TABLE := "res://assets/locale/ui.json"

## Файлы, где ключи Loc встречаются. Сверяется с таблицей, чтобы ключ,
## удалённый из .json, не остался в коде.
const CODE_USERS := [
	"res://scripts/main_menu.gd",
	"res://scripts/save_menu.gd",
	"res://scripts/settings_panel.gd",
]

## Где искать использование ключей. Весь проект, а не три файла: панели
## (склад, лавка, таверна) берут свои строки из этой же таблицы.
const CODE_ROOTS := ["res://scripts", "res://ui"]

var _fails: Array[String] = []
var _checks := 0


func _initialize() -> void:
	call_deferred("_run")


func _check(ok: bool, what: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(what)


func _run() -> void:
	Loc.clear_saved()
	Loc.set_locale("ru")

	_table_shape()
	_no_cyrillic_in_english()
	_no_key_shown_raw()
	_keys_used_in_code()
	_item_names_render_in_both_languages()
	_data_english_columns()
	_language_switch_changes_main_menu()
	_persistence()
	_locale_does_not_touch_game_data()

	_report()
	quit(0 if _fails.is_empty() else 1)


# --- Таблица: полнота и мусор ---

func _table_shape() -> void:
	var f := FileAccess.open(LOC_TABLE, FileAccess.READ)
	if f == null:
		_check(false, "%s читается" % LOC_TABLE)
		return
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	_check(parsed is Dictionary, "%s — валидный JSON-объект" % LOC_TABLE)
	if not (parsed is Dictionary):
		return
	var keys: Array = Loc.keys()
	_check(keys.size() >= 40,
		"в таблице не меньше 40 ключей (=%d)" % keys.size())
	for k in keys:
		_check(Loc.entry_complete(str(k)),
			"ключ %s переведён на оба языка" % k)


## Английский не должен содержать кириллицу. Один забытый русский остаток в
## английской строке — это и есть «почти переведено».
##
## Исключение — названия языков в самом языке: кнопка «Русский» обязана
## называться «Русский» и в английском меню, иначе игрок не узнаёт переключатель.
const NATIVE_NAME_KEYS := ["ui.lang.ru", "ui.lang.en"]


func _no_cyrillic_in_english() -> void:
	var f := FileAccess.open(LOC_TABLE, FileAccess.READ)
	if f == null:
		return
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	if not (parsed is Dictionary):
		return
	for k in (parsed as Dictionary).keys():
		var key := str(k)
		if key.begins_with("_"):
			continue
		if NATIVE_NAME_KEYS.has(key):
			continue
		var entry = (parsed as Dictionary)[key]
		if not (entry is Dictionary):
			continue
		var en := str((entry as Dictionary).get("en", ""))
		var cyr := ""
		for i in en.length():
			if en.unicode_at(i) >= 0x0400 and en.unicode_at(i) <= 0x04FF:
				cyr += en[i]
		_check(cyr.is_empty(), "в переводе %s нет кириллицы (найдено: %s)" % [key, cyr])


## Ни один ключ не должен показываться игроку как есть.
func _no_key_shown_raw() -> void:
	Loc.set_locale("ru")
	for k in Loc.keys():
		var ru := Loc.t(str(k))
		_check(not ru.begins_with("ui."),
			"в русском ключ %s отдаёт текст, а не ключ" % k)
	Loc.set_locale("en")
	for k in Loc.keys():
		var en := Loc.t(str(k))
		_check(not en.begins_with("ui."),
			"в английском ключ %s отдаёт текст, а не ключ" % k)
	Loc.set_locale("ru")


## Каждый ключ из таблицы обязан где-то использоваться: иначе он протух.
##
## Ключ, собранный в рантайме (`"ui.loading.phase." + str(i)`), поиском целиком не
## находится. Раньше условие проверяло наличие ОДНОГО шаблона `"ui.lang." +` во
## всём коде и на этом пропускало ВСЕ ключи подряд — проверка не работала вовсе.
## Теперь правило общее: если в коде есть литерал-префикс ключа (`ui.quest.beast.`),
## ключ считается используемым динамически и учитывается отдельно.
func _keys_used_in_code() -> void:
	var code := _all_code()
	var dynamic := 0
	for k in Loc.keys():
		var key := str(k)
		if code.contains(key):
			_check(true, "ключ %s используется в коде" % key)
			continue
		if _has_dynamic_prefix(code, key):
			dynamic += 1
			continue
		_check(false, "ключ %s не используется нигде (протух)" % key)
	print("loc: ключей по динамическому префиксу %d" % dynamic)


## Есть ли в коде литерал-префикс ключа, от самого длинного к самому короткому:
## "ui.quest.beast.bat" -> "ui.quest.beast." -> "ui.quest." -> "ui.".
func _has_dynamic_prefix(code: String, key: String) -> bool:
	var parts := key.split(".")
	for i in range(parts.size() - 1, 0, -1):
		var prefix := ".".join(parts.slice(0, i)) + "."
		if code.contains(prefix):
			return true
	return false


## Весь GDScript проекта, одним куском: ключ может жить в любой панели.
func _all_code() -> String:
	var out := ""
	for root in CODE_ROOTS:
		var files: Array[String] = []
		_collect(root, files)
		for p in files:
			var f := FileAccess.open(p, FileAccess.READ)
			if f == null:
				_check(false, "%s читается" % p)
				continue
			out += f.get_as_text()
			f.close()
	return out


func _collect(dir_path: String, out: Array[String]) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if name.begins_with("."):
			name = dir.get_next()
			continue
		var full: String = dir_path.path_join(name)
		if dir.current_is_dir():
			_collect(full, out)
		elif name.get_extension().to_lower() == "gd":
			out.append(full)
		name = dir.get_next()
	dir.list_dir_end()


## English columns of the DATA files the UI reads directly. A record without an
## English column silently shows Russian in the English mode and nothing else
## notices: these files are not part of ui.json, so the key checks skip them.
func _data_english_columns() -> void:
	var directions = _read_json("res://assets/config/hero_directions.json")
	if directions is Dictionary:
		var total := 0
		var without: Array[String] = []
		for role in ["warrior", "mage"]:
			for entry in (directions as Dictionary).get(role, []):
				var rec: Dictionary = entry
				total += 1
				var skill := str(rec.get("skill", "?"))
				if str(rec.get("label_en", "")).strip_edges() == "":
					without.append(skill + ".label_en")
				if str(rec.get("desc_en", "")).strip_edges() == "":
					without.append(skill + ".desc_en")
		_check(total >= 10, "направлений развития не меньше 10 (сейчас %d)" % total)
		_check(without.is_empty(), "у направлений нет английской колонки: %s" % str(without))

	var names = _read_json("res://assets/config/hero_names.json")
	if names is Dictionary:
		for pool in ["male", "female"]:
			var list = (names as Dictionary).get(pool, [])
			var missing: Array[String] = []
			for entry in list:
				var rec: Dictionary = entry
				if str(rec.get("ru", "")).strip_edges() == "" or str(rec.get("en", "")).strip_edges() == "":
					missing.append(str(rec))
			_check(list.size() >= 20, "имён в пуле %s не меньше 20 (сейчас %d)" % [pool, list.size()])
			_check(missing.is_empty(), "в пуле %s есть имя без ru или en: %s" % [pool, str(missing)])

	var spells = _read_json("res://assets/spells/spells_db.json")
	if spells is Dictionary:
		var no_en: Array[String] = []
		for key in spells:
			if str(key).begins_with("_"):
				continue
			var rec: Dictionary = spells[key]
			if str(rec.get("ru", "")).strip_edges() == "" or str(rec.get("en", "")).strip_edges() == "":
				no_en.append(str(key))
		_check(not no_en.is_empty() or (spells as Dictionary).size() > 20,
			"заклинания читаются из базы")
		_check(no_en.is_empty(), "у заклинания нет русского или английского имени: %s"
			% str(no_en))

	var rules = _read_json("res://assets/config/content_rules.json")
	if rules is Array:
		var races: Array = []
		var creatures := {}
		for entry in rules:
			var rec: Dictionary = entry
			if str(rec.get("key", "")) == "races":
				races = rec.get("value", [])
			elif str(rec.get("key", "")) == "combat.creature_types":
				creatures = rec.get("value", {})
		var no_en: Array[String] = []
		for raw in races:
			var race: Dictionary = raw
			if str(race.get("label_en", "")).strip_edges() == "":
				no_en.append(str(race.get("id", "?")))
		_check(not races.is_empty(), "расы читаются из правил контента")
		_check(no_en.is_empty(), "у рас нет label_en: %s" % str(no_en))
		var bad_types: Array[String] = []
		for type_id in creatures:
			var pair = creatures[type_id]
			if not (pair is Dictionary):
				bad_types.append(str(type_id))
				continue
			var p: Dictionary = pair
			if str(p.get("ru", "")).strip_edges() == "" or str(p.get("en", "")).strip_edges() == "":
				bad_types.append(str(type_id))
		_check(not creatures.is_empty(), "типы существ читаются из правил контента")
		_check(bad_types.is_empty(), "тип существа без пары ru/en: %s" % str(bad_types))

	# Synthesized single-spell book: the item name must follow the spell in BOTH
	# languages. It used to be named just "Book" in English, so a mage saw a book
	# with no idea which spell was inside.
	var book := SpellDB.make_book_item("Fire_Arrow")
	var spell_rec := SpellDB.get_spell("Fire_Arrow")
	_check(str(book.get("name_ru", "")).contains(str(spell_rec.get("ru", "?"))),
		"книга заклинания названа по-русски (%s)" % str(book.get("name_ru", "")))
	_check(str(book.get("name_en", "")).contains(str(spell_rec.get("en", "?"))),
		"книга заклинания названа по-английски (%s)" % str(book.get("name_en", "")))
	var sphere_book := SpellDB.make_sphere_book("Water")
	_check(str(sphere_book.get("name_ru", "")).contains("Вода")
			and str(sphere_book.get("name_en", "")).contains("Water"),
		"книга школы названа в обоих языках (%s / %s)"
			% [str(sphere_book.get("name_ru", "")), str(sphere_book.get("name_en", ""))])


func _read_json(path: String):
	var text := FileAccess.get_file_as_string(path)
	if text == "":
		_check(false, "%s читается" % path)
		return null
	var parsed = JSON.parse_string(text)
	_check(parsed != null, "%s — валидный JSON" % path)
	return parsed


## Item names and cards in both languages: non-empty and free of "<null>".
## JSON `null` arrives in GDScript as null and `str(null)` is "<null>" - that is
## how "<null>" appeared under a potion name (potions carry `material: null`).
func _item_names_render_in_both_languages() -> void:
	_check(not ItemDB.all().is_empty(), "база предметов не пуста")
	for code in ["ru", "en"]:
		Loc.set_locale(code)
		var empty: Array[String] = []
		var nulls: Array[String] = []
		for raw in ItemDB.all():
			var item: Dictionary = raw
			var key := str(item.get("key", "?"))
			var title := ItemDB.display_name(item)
			if title.strip_edges() == "":
				empty.append(key)
			if title.contains("<null>"):
				nulls.append(key)
			for line in UiKit.item_card_lines(item):
				if str(line).contains("<null>"):
					nulls.append(key)
					break
		_check(empty.is_empty(), "пустые имена предметов (%s): %s"
			% [code, str(empty.slice(0, 5))])
		_check(nulls.is_empty(), "'<null>' в имени или карточке предмета (%s): %s"
			% [code, str(nulls.slice(0, 5))])
	Loc.set_locale("ru")


# --- Переключение без перезапуска ---

func _language_switch_changes_main_menu() -> void:
	var packed: PackedScene = load("res://scenes/main_menu.tscn")
	_check(packed != null, "main_menu.tscn загружается")
	if packed == null:
		return
	Loc.set_locale("ru")
	var menu = packed.instantiate()
	root.add_child(menu)
	await process_frame
	await process_frame

	# Кнопка ищется по ключу перевода через meta: Godot выедает точки из имён
	# узлов, `ui.menu.new_game` становится `ui_menu_new_game`.
	var btn = menu.menu_button("ui.menu.new_game")
	_check(btn is Button, "кнопка «Новая игра» найдена по ключу-имени")
	var ru_text := ""
	if btn is Button:
		ru_text = (btn as Button).text
	_check(ru_text == "Новая игра", "в RU кнопка = «Новая игра» (получено «%s»)" % ru_text)

	# Нажимаем переключатель языка так же, как игрок.
	var en_btn := menu.find_child("Lang_en", true, false)
	_check(en_btn is Button, "кнопка переключения на EN найдена")
	if en_btn is Button:
		(en_btn as Button).pressed.emit()
		await process_frame

	_check(Loc.locale() == "en", "язык переключился на en")
	var en_text := ""
	if btn is Button:
		en_text = (btn as Button).text
	_check(en_text == "New Game",
		"в EN кнопка = «New Game» (получено «%s»)" % en_text)
	_check(en_text != ru_text, "подпись действительно изменилась")

	# Заголовок-фирма не переводится, но подзаголовок должен.
	var sub := menu.find_child("Subtitle", true, false)
	_check(sub is Label, "подзаголовок найден")
	if sub is Label:
		_check((sub as Label).text == "A sandbox and tactical RPG",
			"подзаголовок переведён (получено «%s»)" % (sub as Label).text)

	menu.queue_free()
	await process_frame


# --- Хранение выбора ---

func _persistence() -> void:
	Loc.clear_saved()
	Loc.set_locale("en")
	_check(Loc.save_locale(), "выбор языка записан в user://settings.cfg")
	_check(FileAccess.file_exists(Settings.PATH), "settings.cfg существует")
	Loc.set_locale("ru")
	Loc.load_locale()
	_check(Loc.locale() == "en", "после reload() язык остался en (выбор пережил запуск)")

	# Мусорный файл не должен ломать игру.
	var f := FileAccess.open(Settings.PATH, FileAccess.WRITE)
	f.store_string("language=klingon\nэто не конфиг")
	f.close()
	# Перечитываем файл: без reload кэш Settings остаётся тёплым, и проверка
	# прошла бы на старом добром файле, а не на битом.
	Settings.reload_from_disk()
	Loc.set_locale("ru")
	Loc.load_locale()
	_check(Loc.locale() == Loc.DEFAULT_LOCALE,
		"битый settings.cfg игнорируется, язык откатывается к умолчанию (%s)" % Loc.locale())
	Loc.clear_saved()
	Loc.set_locale("ru")


# --- Локализация не трогает игровые данные ---

func _locale_does_not_touch_game_data() -> void:
	# LootIcons выбирает иконку зелья, разбирая кириллицу из name_ru
	# (loot_icons.gd:92 `_is_mana_potion`). Если бы это поехало через Loc,
	# смена языка молча поменяла бы иконки — игровой баг, а не косметика.
	var potions := ["Potion Medium Healing", "Potion Medium Mana",
		"Potion Big Healing", "Potion Antipoison"]
	var ru_icons: Array = []
	for p in potions:
		var item := ItemDB.find(p)
		if item.is_empty():
			continue
		ru_icons.append(LootIcons.icon_for(item))
	Loc.set_locale("en")
	var en_icons: Array = []
	for p in potions:
		var item := ItemDB.find(p)
		if item.is_empty():
			continue
		en_icons.append(LootIcons.icon_for(item))
	Loc.set_locale("ru")
	_check(ru_icons == en_icons,
		"иконки зелий не зависят от языка интерфейса (%s vs %s)"
			% [str(ru_icons), str(en_icons)])
	_check(not ru_icons.is_empty(), "иконки зелий вообще нашлись")


func _report() -> void:
	print("RESULT: %s loc_smoke (проверок: %d, провалов: %d)"
			% ["OK" if _fails.is_empty() else "FAIL", _checks, _fails.size()])
	for f in _fails:
		print("  FAIL " + f)