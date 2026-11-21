# ============================================================================
# LoadingScene — экран новой игры. Генерирует стартовую карту в фоне и
# передаёт готовый путь в main.tscn. Без class_name (headless).
# ============================================================================
extends CanvasLayer

const MIN_SECONDS := 0.6
const MAIN_SCENE := "res://scenes/main.tscn"
const SELECT_SCENE := "res://scenes/character_select.tscn"

var _view: Control
var _job
var _thread: Thread
var _start_ms := 0
var _finishing := false
var _done := false
## Готовая карта (редактор/«своя игра»): генерировать нечего, только показать
## экран и перейти в мир. Путь пришёл в Game.pending_map_path.
var _custom_path := ""


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	layer = 100
	_start_ms = Time.get_ticks_msec()
	# Тот же живой фон, что в главном меню: он ещё и прогревает атласы карты.
	if DisplayServer.get_name() != "headless":
		var backdrop_script: GDScript = load("res://scripts/menu_backdrop.gd")
		if backdrop_script != null:
			var backdrop = backdrop_script.new()
			backdrop.name = "Backdrop"
			add_child(backdrop)

	var view_script: GDScript = load("res://scripts/loading_view.gd")
	_view = view_script.new()
	_view.setup(Loc.t("ui.loading.new_world"))
	_view.back_requested.connect(_on_back)
	add_child(_view)

	# Конфиг и базы греем в главном потоке: поток-генератор читает их только
	# на чтение, но ленивая загрузка из потока была бы гонкой.
	GameConfig.load_all()
	UnitDB.ensure_loaded()
	StructureDB.ensure_loaded()
	_job = load("res://scripts/world/map_load_job.gd").new()

	# Готовая карта: генерировать нечего. Раньше loading_scene всегда запускал
	# генератор по сиду и в `_complete()` ПЕРЕЗАТИРАЛ pending_map_path —
	# старт с картой из редактора был невозможен.
	var requested := Game.pending_map_path
	if requested != "" and FileAccess.file_exists(requested):
		_custom_path = requested
		_view.set_progress(100, Loc.t("ui.loading.map_ready"))
		set_process(true)
		return

	var wm = load("res://scripts/world/world_map.gd")
	var sector := str(Game.map_sector)
	if sector == "":
		sector = str(wm.sector_for_tier(Game.map_zone))
	var info: Dictionary = wm.sector(sector)
	var tier := str(info.get("tier", Game.map_zone))
	var seed_value := int(Game.map_seed)
	if seed_value == 0:
		seed_value = int(wm.seed_of(Game.world_seed, sector))
	# Co-op (21.11): the map is generated on both machines from the same seed,
	# so the race hint must be the HOST's one, not the local hero's - otherwise
	# the two peers would get different cities.
	var race := str(Game.net_map_race)
	if race == "":
		race = MapGenerator.city_race_for_hero(Game.hero_race)
	var ns: Array = wm.neighbors(sector)
	var size := int(info.get("size", 192))
	var relief := str(info.get("relief", ""))
	_thread = Thread.new()
	var err := _thread.start(_thread_generate.bind(seed_value, tier, sector, size,
		ns, relief, race, _job))
	if err != OK:
		_view.set_error(Loc.t("ui.loading.error_start"))
		set_process(false)
		return
	set_process(true)


func _thread_generate(seed_value: int, tier: String, sector: String, size: int,
		ns: Array, relief: String, race: String, job) -> String:
	return MapGenerator.ensure_map(seed_value, tier, MapGenerator.MAPS_DIR, race,
		sector, size, ns, relief, job)


func _process(_delta: float) -> void:
	if _done or _finishing:
		return
	if _custom_path != "":
		_view.set_progress(100, Loc.t("ui.loading.map_ready"))
		if Time.get_ticks_msec() - _start_ms >= int(MIN_SECONDS * 1000.0):
			_finishing = true
			_complete(_custom_path)
		return
	var snap: Dictionary = _job.snapshot()
	_view.set_progress(int(snap.get("percent", 0)), _phase_text(int(snap.get("phase", 0))))
	if str(snap.get("error", "")) != "":
		_finish_error(str(snap.get("error", "")))
		return
	if _thread != null and not _thread.is_alive():
		var path: String = ""
		if _thread.is_started():
			path = str(_thread.wait_to_finish())
		if path == "" or not FileAccess.file_exists(path):
			_finish_error(Loc.t("ui.loading.error_start"))
			return
		_finishing = true
		_complete(path)


func _complete(path: String) -> void:
	# Минимальное время считаем по часам: _process выше уже не тикает
	# (_finishing), и ожидание по _elapsed зацикливалось.
	while Time.get_ticks_msec() - _start_ms < int(MIN_SECONDS * 1000.0):
		await get_tree().process_frame
	Game.pending_map_path = path
	Game.startup_loading = true
	_done = true
	get_tree().change_scene_to_file(MAIN_SCENE)


func _finish_error(text: String) -> void:
	if _finishing:
		return
	_finishing = true
	_done = true
	_view.set_progress(0, text)
	_view.set_error(text)


func _on_back() -> void:
	get_tree().change_scene_to_file(SELECT_SCENE)


func _phase_text(phase: int) -> String:
	return Loc.t("ui.loading.phase.%d" % clampi(phase, 0, 12))


func _exit_tree() -> void:
	if _thread != null and _thread.is_started():
		_thread.wait_to_finish()
