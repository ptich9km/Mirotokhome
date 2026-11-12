extends SceneTree
## Books actually teach: the starter spell book, every sphere book and every
## single-spell book (04.11).
##
## The mage used to start with a book that did nothing: `hero_start_book` is
## built from a single spell ("Book Fire Arrow"), while item_db stores only the
## five sphere books. ItemDB.find has a synthesized fallback, so the cell looked
## fine — but the round trip "key -> item -> spell -> learn" was never tested
## for a single-spell book.
##
## What is checked, for a mage hero:
##   1. the starter book of the chosen school exists as an item (quality Book,
##      name, icon) and `learn_book` adds its spell and consumes the book;
##   2. each sphere book teaches the whole sphere and cannot be spent twice;
##   3. all 31 spells round-trip: `make_book_item` -> `ItemDB.find` -> key ->
##      `spell_of_book` -> `learn_book`;
##   4. a warrior cannot learn books (no mana), and a non-book item is refused.
##
## Run: godot --headless --path . --script res://tests/book_learn_smoke.gd

const SCHOOL := "Fire"

var _fails: Array = []
var _checks := 0
var _hero: Player = null


func _initialize() -> void:
	Game.hero_stats = {"body": 10, "agility": 10, "mind": 14, "spirit": 12,
		"blade": 10, "bludgeon": 10, "pike": 10, "shooting": 10,
		"fire": 20, "water": 10, "air": 10, "earth": 10, "astral": 10,
		"weapon": "staff", "shield": false, "armor": "light"}
	Game.hero_class = "mage"
	Game.hero_name = "Маг"
	# Same rule as character_select: the starter is the simplest spell of the
	# school, and the hero gets exactly that book in the bag.
	var starter: String = SpellDB.simplest_spell_of_sphere(SCHOOL)
	Game.hero_start_book = SpellDB.book_key_for_spell(starter)
	call_deferred("_run")


func _check(ok: bool, what: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(what)
	print("BOOK: %s %s" % ["ok  " if ok else "FAIL", what])


func _run() -> void:
	var err := change_scene_to_file("res://scenes/main.tscn")
	if err != OK:
		_check(false, "main.tscn загрузилась")
		_finish()
		return
	await process_frame
	await create_timer(0.8).timeout
	_hero = get_first_node_in_group("player") as Player
	_check(_hero != null, "герой в группе player")
	if _hero == null:
		_finish()
		return
	_check(_hero.has_mana, "герой — маг (есть мана)")

	_starter_book()
	_sphere_books()
	_all_spell_books()
	_guards()
	await _panel_path()

	print("")
	if _fails.is_empty():
		print("RESULT: OK book_learn_smoke (%d checks)" % _checks)
	else:
		print("RESULT: FAIL book_learn_smoke (%d checks, %d fails)" % [_checks, _fails.size()])
		for f in _fails:
			print("  - " + f)
	quit(0 if _fails.is_empty() else 1)


## 5. The same through the real inventory panel: two clicks on the cell must
##    learn the book. This is the path the player actually uses.
func _panel_path() -> void:
	var ui: Node = current_scene.get_node_or_null("UI")
	_check(ui != null, "UI в сцене")
	if ui == null:
		return
	ui.call("open_inventory_panel")
	await process_frame
	await process_frame
	var panel: Node = ui.get("_inventory_panel")
	_check(panel != null, "панель склада открылась")
	if panel == null:
		return

	var key := SpellDB.book_key_for_spell(SpellDB.simplest_spell_of_sphere(SCHOOL))
	_hero.known_spells.clear()
	_hero.sphere_books.clear()
	_hero.inventory = [key]
	panel.call("_refresh_inventory_grid")
	await process_frame

	var items: Array = panel.get("_inventory_items")
	var cell_item: Dictionary = {}
	for it in items:
		if str((it as Dictionary).get("key", "")) == key:
			cell_item = it
	_check(not cell_item.is_empty(), "книга '%s' попала в сетку склада" % key)
	if cell_item.is_empty():
		return

	# Books learn on a SINGLE click (04.11 fix). The old gate wanted a double
	# click within 450 ms — tighter than the Windows default, and a slow but
	# normal double click was swallowed while a single click did nothing.
	panel.call("_on_item_clicked", cell_item)
	var spell := SpellDB.spell_of_book(key)
	_check(_hero.known_spells.has(spell),
		"один клик по книге выучил '%s'" % spell)
	_check(not _hero.inventory.has(key), "после клика книга ушла из склада")
	# The panel was open the whole time: the learned spell must already sit in
	# the spell book without reopening anything (player report 04.11).
	var names: Array = ui.get("_spell_button_names")
	_check(names.has(spell),
		"выученное заклинание сразу попало в панель магии (без переоткрытия)")

	# A warrior gets an explanation instead of a silent no-op.
	_hero.has_mana = false
	_hero.known_spells.clear()
	_hero.sphere_books.clear()
	_hero.inventory = [key]
	panel.call("_refresh_inventory_grid")
	await process_frame
	panel.call("_on_item_clicked", cell_item)
	_check(not _hero.known_spells.has(spell), "воин книгу не выучил через панель")
	_check(_hero.inventory.has(key), "у воина книга осталась в складе")
	_hero.has_mana = true

	# A scroll still needs a deliberate double click: one is not enough.
	_hero.known_spells.clear()
	_hero.sphere_books.clear()
	_hero.inventory = ["Scroll Heal"]
	panel.call("_refresh_inventory_grid")
	await process_frame
	var scroll_item := {}
	var scroll_slots: Array = panel.get("_inventory_slots")
	var scroll_cells: Array = panel.get("_inventory_items")
	for i in range(scroll_cells.size()):
		if str((scroll_cells[i] as Dictionary).get("key", "")) == "Scroll Heal":
			scroll_item = scroll_cells[i]
	_check(not scroll_item.is_empty(), "свиток попал в сетку склада")
	if not scroll_item.is_empty():
		panel.call("_on_item_clicked", scroll_item)
		_check(Game.pending_scroll.is_empty(), "один клик по свитку не начинает каст")
		panel.call("_on_item_clicked", scroll_item, true)
		_check(not (Game.pending_scroll as Dictionary).is_empty(),
			"двойной клик по свитку начинает прицеливание")
		Game.pending_scroll = {}
	panel.close()


## 1. The starter book: it must be a real item and must teach exactly its spell.
func _starter_book() -> void:
	var key := Game.hero_start_book
	var spell := SpellDB.spell_of_book(key)
	_check(key != "", "стартовая книга задана (%s)" % key)
	_check(spell != "", "из ключа '%s' извлекается заклинание" % key)
	_check(_hero.inventory.has(key), "стартовая книга лежит в складе")

	var item := ItemDB.find(key)
	_check(str(item.get("quality", "")) == "Book",
		"стартовая книга есть в базе (quality=%s)" % str(item.get("quality", "")))
	_check(str(item.get("name_ru", "")) != "", "у книги есть название")
	_check(str(item.get("icon", "")) != "", "у книги есть иконка")

	_hero.known_spells.clear()
	_hero.sphere_books.clear()
	var ok := _hero.learn_book(key)
	_check(ok, "learn_book('%s') возвращает true" % key)
	_check(_hero.known_spells.has(spell), "заклинание '%s' выучено" % spell)
	_check(not _hero.inventory.has(key), "книга израсходована")
	_check(not _hero.learn_book(key), "повторное изучение без книги не проходит")


## 2. Element books ("Book Fire"): ONE book = ONE spell. The old rule "a school
##    book opens the whole sphere" was removed by the player's decision (13.11):
##    four spells for one quest relic is a free upgrade, not a reward.
func _sphere_books() -> void:
	for sphere: String in ContentRules.list("spells.spheres"):
		var key := "Book " + sphere
		var item := ItemDB.find(key)
		_check(str(item.get("quality", "")) == "Book", "книга стихии %s есть (%s)" % [sphere, key])
		_check(SpellDB.sphere_of_book(key) == sphere, "%s -> sphere_of_book = %s" % [key, sphere])

		var simplest := SpellDB.simplest_spell_of_sphere(sphere)
		_check(simplest != "", "у стихии %s есть простейшее заклинание" % sphere)
		_check(SpellDB.spell_of_book(key) == simplest,
			"%s учит ОДНО заклинание (%s)" % [key, simplest])

		_hero.known_spells.clear()
		_hero.sphere_books.clear()
		_hero.inventory = [key]
		var ok := _hero.learn_book(key)
		_check(ok, "%s учится" % key)
		_check(_hero.known_spells.has(simplest), "%s выучила '%s'" % [key, simplest])
		_check(not bool(_hero.sphere_books.get(sphere, false)),
			"%s НЕ отмечает сферу выученной" % key)
		var extra := 0
		for s in SpellDB.spells_of_sphere(sphere):
			if s != simplest and _hero.known_spells.has(s):
				extra += 1
		_check(extra == 0, "%s не выдаёт остальные заклинания стихии (лишних %d)"
			% [key, extra])
		_check(not _hero.inventory.has(key), "%s израсходована" % key)


## 3. Every spell has a working book: build -> find -> parse -> learn.
func _all_spell_books() -> void:
	var names: Array = SpellDB.all_spell_names()
	_check(names.size() == 31, "в базе 31 заклинание (%d)" % names.size())
	var bad_item: Array = []
	var bad_key: Array = []
	var bad_spell: Array = []
	var bad_learn: Array = []
	for name in names:
		var s := str(name)
		var built := SpellDB.make_book_item(s)
		if built.is_empty() or str(built.get("quality", "")) != "Book":
			bad_item.append(s)
			continue
		var key := str(built.get("key", ""))
		if key != SpellDB.book_key_for_spell(s):
			bad_key.append("%s -> '%s'" % [s, key])
		var found := ItemDB.find(key)
		if str(found.get("key", "")) != key:
			bad_item.append("%s (find вернул '%s')" % [s, str(found.get("key", ""))])
			continue
		if SpellDB.spell_of_book(key) != s:
			bad_spell.append("%s -> '%s'" % [key, SpellDB.spell_of_book(key)])
			continue
		_hero.known_spells.clear()
		_hero.sphere_books.clear()
		_hero.inventory = [key]
		if not _hero.learn_book(key):
			bad_learn.append(s)
		elif not _hero.known_spells.has(s):
			bad_learn.append(s + " (нет в known_spells)")
	_check(bad_item.is_empty(), "у каждого заклинания есть предмет-книга (%s)" % str(bad_item))
	_check(bad_key.is_empty(), "ключ книги собирается из имени (%s)" % str(bad_key))
	_check(bad_spell.is_empty(), "ключ книги разбирается назад в заклинание (%s)" % str(bad_spell))
	_check(bad_learn.is_empty(), "каждая книга учит своё заклинание (%s)" % str(bad_learn))


## 4. Guards: a warrior cannot learn, a non-book is refused.
func _guards() -> void:
	_hero.known_spells.clear()
	_hero.sphere_books.clear()
	_hero.inventory = ["Book Fire"]
	_hero.has_mana = false
	_check(not _hero.learn_book("Book Fire"), "воин книгу не выучивает")
	_check(_hero.inventory.has("Book Fire"), "воину книга не тратится")
	_hero.has_mana = true

	_hero.inventory = ["Common iron Long Sword"]
	_check(not _hero.learn_book("Common iron Long Sword"), "не-книга не учится")
	_check(not _hero.learn_book("Book No Such Spell"), "книга несуществующего заклинания не учится")


func _finish() -> void:
	print("")
	if _fails.is_empty():
		print("RESULT: OK book_learn_smoke (%d checks)" % _checks)
	else:
		print("RESULT: FAIL book_learn_smoke (%d checks, %d fails)" % [_checks, _fails.size()])
		for f in _fails:
			print("  - " + f)
	quit(0 if _fails.is_empty() else 1)
