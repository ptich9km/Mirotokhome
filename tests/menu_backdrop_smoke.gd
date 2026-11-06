extends SceneTree
## Смоук живого фона главного меню (scripts/menu_backdrop.gd).
##
## Требование игрока: заставка должна быть анимацией из игры, а не статичной
## картинкой (X4 Foundations, Space Engineers). Проверяем, что это правда, а не
## просто `ColorRect`:
##
##  * **Карта реально загрузилась и меш построен.** Иначе фон — пустота, и
##    тест «фон есть» прошёл бы на сером прямоугольнике.
##  * **Фон ДВИГАЕТСЯ.** Статичная заставка — ровно то, от чего уходим.
##  * **Объекты анимируются** (деревья качаются штатной анимацией).
##  * **Статики `Game` не испорчены.** `Game` — `class_name` со `static var`,
##    они переживают смену сцены, а `game.gd:_quit_to_menu()` НЕ обнуляет
##    `map_seed`. Если фон это не восстановит, при возврате в меню
##    `AlmMap._resolve_map_path()` подхватит карту ИГРОКА. Это проверяется
##    сравнением «до/после», а не чтением кода.
##  * **Панель непрозрачная, по краям видна игра.** Отдельное требование игрока:
##    никакого затемнения на весь экран.

const INSET := UiTheme.SCREEN_INSET

var _fails: Array[String] = []
var _checks := 0


func _initialize() -> void:
	call_deferred("_run")


func _check(ok: bool, what: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(what)


func _run() -> void:
	var packed: PackedScene = load("res://scenes/main_menu.tscn")
	_check(packed != null, "main_menu.tscn загружается")
	if packed == null:
		_report()
		quit(1)
		return

	# Статики Game ДО меню: имитация возврата из игры, где map_seed уже стоит.
	var seed_before := 4242
	var zone_before := "hard"
	var path_before := "res://assets/maps/gen/gen_smart_01.alm"
	Game.map_seed = seed_before
	Game.map_zone = zone_before
	Game.pending_map_path = path_before

	var menu = packed.instantiate()
	root.add_child(menu)
	await process_frame
	await process_frame

	_backdrop_exists(menu)
	_map_loaded(menu)
	await _drift_moves(menu)
	_objects_animate(menu)
	_game_statics_intact(seed_before, zone_before, path_before)
	await _panel_opaque_with_visible_edges(menu)

	menu.queue_free()
	await process_frame

	_report()
	quit(0 if _fails.is_empty() else 1)


func _backdrop_exists(menu: Node) -> void:
	var backdrop = menu.get_node_or_null("Backdrop")
	_check(backdrop != null, "в главном меню есть узел Backdrop")
	_check(backdrop is MenuBackdrop, "Backdrop — это MenuBackdrop")
	# Интерфейс обязан быть в CanvasLayer: Camera2D/позиция двигают слой 0, где
	# живут Control, и интерфейс увлекся бы за фон либо съехал бы вместе с ним.
	var ui = menu.get_node_or_null("UI")
	_check(ui is CanvasLayer, "интерфейс меню вынесен в CanvasLayer")


func _map_loaded(menu: Node) -> void:
	var backdrop = menu.get_node_or_null("Backdrop")
	if not (backdrop is MenuBackdrop):
		_check(false, "Backdrop есть, но не MenuBackdrop — карта не проверялась")
		return
	_check(backdrop.is_ready_backdrop(),
		"фон загрузил карту (MenuBackdrop.is_ready_backdrop)")
	var map = backdrop.map_node()
	_check(map != null, "у фона есть узел карты")
	if map == null:
		return
	_check(int(map.map_width) > 0 and int(map.map_height) > 0,
		"карта фона непустая (%dx%d)" % [map.map_width, map.map_height])
	_check(map.get("alm_path") == MenuBackdrop.MAP_PATH,
		"фон грузит предзапечённую карту, а не генерирует на лету")

	# Меш реально построен: без него фон — пустая сетка.
	var meshes := 0
	for c in map.get_children():
		if c is MeshInstance2D:
			meshes += 1
	_check(meshes >= 1, "построен меш рельефа (%d MeshInstance2D)" % meshes)


## Фон обязан двигаться. Считаем по ЗАДАННОМУ времени, а не по кадрам:
## в headless 60 кадров — это доли секунды, и замер по кадрам врал бы в обе
## стороны. Первый вариант теста мерял по кадрам и пропустил дрейф 4.5 px/с,
## на который игрок смотрел и видел «никакой анимации».
func _drift_moves(menu: Node) -> void:
	var backdrop = menu.get_node_or_null("Backdrop")
	if not (backdrop is MenuBackdrop):
		_check(false, "нечем проверять дрейф")
		return
	var p0: Vector2 = backdrop.drift_sample()
	# Симулируем ровно секунду игрового времени.
	backdrop._process(1.0)
	var p1: Vector2 = backdrop.drift_sample()
	var per_sec := p0.distance_to(p1)
	# Пороги подобраны двумя прогонами: игрок отверг и 4.5 px/с («никакой
	# анимации»), и 95 px/с («камера быстро движется»). Сейчас ~23 px/с.
	_check(per_sec > 12.0,
		"фон заметно плывёт: %.1f px за секунду игрового времени" % per_sec)
	# И не должен метаться как смена сцены.
	backdrop._process(1.0)
	var p2: Vector2 = backdrop.drift_sample()
	var per_sec2 := p1.distance_to(p2)
	_check(per_sec2 < 60.0,
		"фон не летит: %.1f px за секунду (игрок просил медленнее)" % per_sec2)

	# Окно обзора должно быть тем, которое отмерил analyze_menu_backdrop, а не
	# соседним участком: первая версия складывала якорь плюсом и смотрела на
	# область, смещённую на (+10, +6.5) клетки от измеренной.
	var map = backdrop.map_node()
	if map != null and int(map.map_width) > 0:
		var ts: float = float(map.tile_size)
		var half: Vector2 = MenuBackdrop.VIEW_CELLS * 0.5
		# Клетка под центром экрана = (центр экрана - позиция узла) / размер клетки.
		# Первая версия проверки использовала формулу от измеренного окна и
		# давала 225 из 128 — ошибка была в проверке, а не в якоре.
		var screen_centre: Vector2 = root.get_visible_rect().size * 0.5
		var seen: Vector2 = (screen_centre - backdrop.drift_sample()) / ts
		_check(seen.x >= 0.0 and seen.x < float(map.map_width),
			"центр экрана попадает в карту по X (клетка %.1f из %d)"
				% [seen.x, map.map_width])
		_check(seen.y >= 0.0 and seen.y < float(map.map_height),
			"центр экрана попадает в карту по Y (клетка %.1f из %d)"
				% [seen.y, map.map_height])
		_check(seen.x - half.x >= 0.0 and seen.x + half.x < float(map.map_width),
			"окно обзора целиком внутри карты по X")
		_check(seen.y - half.y >= 0.0 and seen.y + half.y < float(map.map_height),
			"окно обзора целиком внутри карты по Y")


func _objects_animate(menu: Node) -> void:
	var backdrop = menu.get_node_or_null("Backdrop")
	if not (backdrop is MenuBackdrop):
		return
	var n: int = backdrop.animated_objects()
	_check(n > 0, "на фоне есть анимирующиеся объекты (деревья) — %d" % n)


## Статики Game — самая опасная часть фона.
func _game_statics_intact(seed_before: int, zone_before: String, path_before: String) -> void:
	_check(Game.map_seed == seed_before,
		"фон не сбросил Game.map_seed (=%d)" % Game.map_seed)
	_check(Game.map_zone == zone_before,
		"фон не сбросил Game.map_zone (=%s)" % Game.map_zone)
	_check(Game.pending_map_path == path_before,
		"фон не сбросил Game.pending_map_path")
	_check(Game.hero == null, "фон не создал героя (Game.hero == null)")


## Панель непрозрачная, мир виден по краям. Требование игрока «без прозрачности».
func _panel_opaque_with_visible_edges(menu: Node) -> void:
	var ui = menu.get_node_or_null("UI")
	if ui == null:
		_check(false, "нет CanvasLayer UI — панель не найдена")
		return

	# Полноэкранного затемнения в САМОМ меню быть не должно: именно оно и было
	# «прозрачностью». Затемнение внутри Overlay — другое дело, это подложка под
	# модальным диалогом (Загрузить/Об авторах/Выход), и оно допустимо.
	var full_dim := 0
	var vp: Vector2 = root.get_visible_rect().size
	for n in _all_nodes(ui):
		if n is ColorRect and str(n.name) == "Dim":
			var r := (n as ColorRect).size
			if r.x >= vp.x * 0.95 and r.y >= vp.y * 0.95:
				var under_overlay := false
				var p := n.get_parent()
				while p != null:
					if p.name == "Overlay":
						under_overlay = true
					p = p.get_parent()
				if not under_overlay:
					full_dim += 1
	_check(full_dim == 0,
		"в главном меню нет затемнения на весь экран (найдено %d)" % full_dim)

	var inset = ui.find_child("Inset", true, false)
	_check(inset is MarginContainer, "панель вписана с отступом (Inset)")
	if inset is MarginContainer:
		var ml: int = (inset as MarginContainer).get_theme_constant("margin_left")
		_check(ml == INSET,
			"отступ слева = SCREEN_INSET (%d, по краям видно игру)" % ml)

	var panel = ui.find_child("Panel", true, false)
	_check(panel is PanelContainer, "панель — PanelContainer (не TextureRect)")
	if panel is PanelContainer:
		# Панели две (главная и оверлея), обе с именем "Panel", поэтому стиль
		# берём у ТЕМЫ по её variation, а не у первой найденной панели.
		_check((panel as PanelContainer).theme_type_variation == &"MmPanel",
			"главная панель использует variation MmPanel")
		var sb: StyleBox = null
		var owner: Node = _theme_owner(panel)
		if owner != null and owner is Control:
			sb = (owner as Control).theme.get_stylebox("panel", &"MmPanel")
		elif owner != null and owner is Window:
			sb = (owner as Window).theme.get_stylebox("panel", &"MmPanel")
		_check(sb != null, "у variation MmPanel есть стиль")
		# The panel is a flat stylebox on purpose: the 9-slice frame from
		# assets/ui/frames/ stretched its ornament into thick gold bars along the
		# edges (see the comment in main_menu.gd). The guard still checks that
		# the panel is a visible frame and not a bare transparent box.
		_check(sb is StyleBoxFlat, "панель нарисована плоской рамкой (StyleBoxFlat)")
		if sb is StyleBoxFlat:
			var flat := sb as StyleBoxFlat
			_check(flat.draw_center, "у панели есть заливка")
			_check(flat.border_width_left > 0 and flat.border_width_top > 0,
				"у панели есть рамка (границы > 0)")
		# Панель не должна закрывать весь экран: справа обязан быть виден мир.
		var vp2: Vector2 = root.get_visible_rect().size
		var ps: Vector2 = (panel as PanelContainer).size
		_check(ps.x <= vp2.x * 0.45,
			"панель занимает не больше 45%% ширины (%s против %s)" % [ps, vp2])


func _all_nodes(node: Node) -> Array[Node]:
	var out: Array[Node] = [node]
	for c in node.get_children():
		out.append_array(_all_nodes(c))
	return out


## Ближайший Control или Window с темой вверх по дереву. Godot не
## распространяет тему через CanvasLayer, поэтому искать надо от кнопки, а не
## от корня сцены.
func _theme_owner(node: Node) -> Node:
	var p: Node = node
	while p != null:
		if (p is Control and (p as Control).theme != null) \
				or (p is Window and (p as Window).theme != null):
			return p
		p = p.get_parent()
	return null


func _report() -> void:
	print("RESULT: %s menu_backdrop_smoke (проверок: %d, провалов: %d)"
			% ["OK" if _fails.is_empty() else "FAIL", _checks, _fails.size()])
	for f in _fails:
		print("  FAIL " + f)