class_name Loc
extends RefCounted
## Переключение языка интерфейса RU/ENG.
##
## ## Почему свой класс, а не `tr()`
##
## В проекте было 75 вызовов `tr()`, и все они были **пустышками**: без
## загруженного `.translation` ресурса `tr()` возвращает аргумент как есть. То
## есть инфраструктура выглядела, будто есть, а её не было. Свой класс даёт:
##   * работу в headless-тестах без шага импорта `.translation` (в проекте тесты
##     гоняются headless постоянно, и бинарники в git здесь были бы хрупкостью);
##   * переключение **названий из JSON** (предметы, юниты, здания) тем же
##     механизмом, а не отдельным путём.
##
## ## Правило, без которого локализация ломает игру
##
## Через `Loc` идёт **только отображение**. Данные, по которым принимаются
## решения, читают русское поле напрямую: например `loot_icons.gd:92` разбирает
## кириллицу из `name_ru`, чтобы выбрать иконку зелья. Если завернуть это в
## `Loc`, переключение языка молча поменяет иконки — это игровой баг, а не
## косметика.
##
## ## Хранение выбора
##
## Отдельный `user://settings.cfg`, а НЕ `assets/config/game.cfg`: тот файл —
## дев-тюнинг в git, комментируется `;`, и `GameConfig` не умеет ни строки,
## ни запись в рантайме (`game_config.gd` — только `geti`/`getf` и
## write-once `seed_user_file`).
##
## Файл принадлежит `Settings`, а не `Loc`: иначе два класса с собственным
## кэшем `ConfigFile` затирали бы друг друга (`Loc` сохранил бы файл без
## звука и видео). Здесь только ключ языка.

const TABLE_PATH := "res://assets/locale/ui.json"
## Файл и раздел — в `Settings`, здесь только ключ, чтобы не было двух
## владельцев одного файла.
const SETTINGS_SECTION := "player"
const SETTINGS_KEY := "language"

const DEFAULT_LOCALE := "ru"
const LOCALES := ["ru", "en"]

static var _table: Dictionary = {}
static var _loaded := false
static var _locale := DEFAULT_LOCALE


static func _ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	_locale = DEFAULT_LOCALE
	var f := FileAccess.open(TABLE_PATH, FileAccess.READ)
	if f == null:
		push_warning("Loc: не читается %s — интерфейм останется на ключах"
			% TABLE_PATH)
		return
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	if parsed is Dictionary:
		_table = parsed


## Текущий язык: "ru" или "en".
static func locale() -> String:
	_ensure_loaded()
	return _locale


## Сменить язык. Значение из `LOCALES`, всё прочее игнорируется.
static func set_locale(code: String) -> void:
	_ensure_loaded()
	if not LOCALES.has(code):
		push_warning("Loc: неизвестный язык '%s' — остаётся %s" % [code, _locale])
		return
	_locale = code


static func available() -> Array:
	return LOCALES.duplicate()


## Строка по ключу для текущего языка.
##
## Порядок отката: текущий язык -> русский -> сам ключ. Русский обязателен как
## база: он эталонный, и его наличие проверяет `loc_smoke`.
static func t(key: String) -> String:
	_ensure_loaded()
	var entry = _table.get(key)
	if not (entry is Dictionary):
		return key
	var picked := str((entry as Dictionary).get(_locale, ""))
	if picked == "":
		picked = str((entry as Dictionary).get(DEFAULT_LOCALE, ""))
	if picked == "":
		return key
	return picked


## Строка с подстановкой. `f("ui.load.slot_filled", [1, "Arik", 7])`.
static func f(key: String, args: Array) -> String:
	var pattern := t(key)
	if args.is_empty():
		return pattern
	return pattern % args


## Все ключи таблицы — нужно `loc_smoke`, чтобы находить ключи-сироты и
## неиспользуемые.
static func keys() -> Array:
	_ensure_loaded()
	var out: Array = []
	for k in _table.keys():
		var key := str(k)
		if key.begins_with("_"):
			continue
		out.append(key)
	out.sort()
	return out


## Candidate locales in the fallback order: the current one first, then the
## reference one. Missing entries are reported by loc_smoke, not hidden.
static func locales_in_use() -> Array:
	return [_locale, DEFAULT_LOCALE]


## Is the key in the locale table at all (any language).
static func has_key(key: String) -> bool:
	_ensure_loaded()
	return key != "" and _table.get(key) is Dictionary


## The key in exactly this language ("" when the language has no entry).
static func text_in(key: String, code: String) -> String:
	_ensure_loaded()
	var entry = _table.get(key)
	if not (entry is Dictionary):
		return ""
	return str((entry as Dictionary).get(code, ""))


## A field of a DATA record in the current language: `label_en` when the record
## carries it and the locale is English, otherwise `label` itself. Data files
## (hero_names, hero_directions, content_rules) keep the two columns side by side
## instead of duplicating whole records, so this is the single place that picks.
## A missing or null English column falls back to Russian rather than to "".
static func field(record: Dictionary, key: String) -> String:
	_ensure_loaded()
	if _locale != DEFAULT_LOCALE:
		var translated = record.get(key + "_en", "")
		if translated is String and str(translated) != "":
			return str(translated)
	var base = record.get(key, "")
	return str(base) if base is String else ""


## A `{ru, en}` pair from data (creature type labels): the current language with
## Russian as the fallback. Not the same as `field()`: a pair has no separate
## `_en` column, both languages live inside one value.
static func pair(value: Variant) -> String:
	_ensure_loaded()
	if not (value is Dictionary):
		return str(value) if value is String else ""
	var entry: Dictionary = value
	var picked = entry.get(_locale, "")
	if picked is String and str(picked) != "":
		return str(picked)
	var base = entry.get(DEFAULT_LOCALE, "")
	return str(base) if base is String else ""


## Есть ли в таблице все языки — иначе ключ молча откатится на русский.
static func entry_complete(key: String) -> bool:
	_ensure_loaded()
	var entry = _table.get(key)
	if not (entry is Dictionary):
		return false
	for code in LOCALES:
		if str((entry as Dictionary).get(code, "")) == "":
			return false
	return true


# --- Хранение выбора (файл принадлежит Settings) ---

## Читает язык из `user://settings.cfg`. Битый файл игнорируется — язык молча
## остаётся русским, как и весь остальной конфиг в проекте.
static func load_locale() -> void:
	_ensure_loaded()
	var raw: Variant = Settings.get_value("player", SETTINGS_KEY, DEFAULT_LOCALE)
	var code := str(raw)
	if LOCALES.has(code):
		_locale = code


## Записывает язык. Кэш `Settings` общий, поэтому остальные настройки
## (звук, видео, клавиши) не теряются.
static func save_locale() -> bool:
	_ensure_loaded()
	Settings.set_value("player", SETTINGS_KEY, _locale)
	return Settings.save()


## Удаляет сохранённый язык (для тестов: сброс к русскому).
static func clear_saved() -> void:
	Settings.reset_to_defaults()
	_locale = DEFAULT_LOCALE