extends SceneTree
## Headless-проверка стека освещения и пост-обработки 2D.
##
## До этой работы в сценах не было НИ ОДНОГО источника света: ни
## CanvasModulate, ни Light2D, ни WorldEnvironment. Картинка рисовалась «как
## есть», и это главная причина ощущения «эффекты из 1990-х»: правило VFX —
## эффект должен излучать и освещать мир, иначе он наклейка.
##
## Проверяет:
##  1. три обязательных слоя на месте: CanvasModulate, WorldEnvironment, пост-пасс;
##  2. background_mode = BG_CANVAS (иначе Environment в 2D молча ничего не делает);
##  3. HDR 2D включён — без него значения >1.0 обрезаются и свечения не будет;
##  4. свет заклинания реально создаётся и светит сферой;
##  5. пост-пасс лежит ПОД HUD, а не поверх (иначе интерфейс темнеет).
##
## Запуск:
##   godot --headless --path . --script res://tests/lighting_smoke.gd

var _fails: Array = []
var _scene_root: Node = null
var _hero: Player = null


func _initialize() -> void:
	Game.hero_stats = {"body": 12, "agility": 11, "mind": 13, "spirit": 12,
		"blade": 10, "bludgeon": 10, "pike": 10, "shooting": 10,
		"fire": 20, "water": 20, "air": 20, "earth": 20, "astral": 20,
		"weapon": "staff", "shield": false, "armor": "light"}
	Game.hero_class = "mage"
	Game.hero_name = "Маг"
	Game.debug_magic = true
	call_deferred("_run")


func _check(ok: bool, what: String) -> void:
	if not ok:
		_fails.append(what)
	print("LIGHT: %s %s" % ["ok  " if ok else "FAIL", what])


func _run() -> void:
	var err := change_scene_to_file("res://scenes/main.tscn")
	if err != OK:
		_check(false, "загрузка main.tscn: %d" % err)
		_finish()
		return
	await process_frame
	await create_timer(0.6).timeout
	_scene_root = current_scene
	_hero = get_first_node_in_group("player") as Player
	_check(_hero != null, "герой загружен")
	if _hero == null:
		_finish()
		return

	_test_ambient()
	_test_environment()
	_test_hdr_2d()
	_test_post_pass_order()
	await _test_spell_light()
	await _test_particles()
	_test_brightness_compensation()
	await _test_auras_unshaded()
	_finish()


# --- 1. CanvasModulate -----------------------------------------------------

func _test_ambient() -> void:
	var ambient: CanvasModulate = _find("Ambient")
	_check(ambient != null, "CanvasModulate создан (без него свет ничего не добавляет)")
	if ambient == null:
		return
	# Не темнота: карта дневная. Проверяем, что приглушение умеренное.
	var luma := ambient.color.r * 0.3 + ambient.color.g * 0.6 + ambient.color.b * 0.1
	_check(luma > 0.6,
		"приглушение окружения умеренное (luma %.2f), карта не уходит в ночь" % luma)


# --- 2. WorldEnvironment ---------------------------------------------------

func _test_environment() -> void:
	var we: WorldEnvironment = _find("WorldEnvironment")
	_check(we != null, "WorldEnvironment создан")
	if we == null or we.environment == null:
		_check(false, "у WorldEnvironment задан ресурс Environment")
		return
	var env := we.environment
	_check(env.background_mode == Environment.BG_CANVAS,
		"background_mode = BG_CANVAS (иначе glow и тональная компрессия в 2D "
			+ "молча не работают, а действует только 3D) — получено %d"
			% int(env.background_mode))
	_check(env.glow_enabled, "glow включён")
	_check(env.glow_intensity > 0.0, "glow_intensity > 0: %.2f" % env.glow_intensity)
	_check(env.glow_strength > 0.0, "glow_strength > 0 (иначе glow не виден)")
	_check(env.glow_hdr_threshold < 1.0,
		"порог HDR ниже 1.0 (%.2f) — при 1.0 не светилось бы ничего"
			% env.glow_hdr_threshold)
	# Уровни задаются через set(), т.к. имена содержат «/».
	_check(env.get("glow_levels/5") > 0.0, "glow_levels/5 задан: %.2f"
		% float(env.get("glow_levels/5")))
	_check(env.background_canvas_max_layer == 0,
		"background_canvas_max_layer = 0 — HUD на своём CanvasLayer не свечится")
	_check(env.tonemap_mode == Environment.TONE_MAPPER_AGX,
		"тональная компрессия AgX (дефолт Godot Linear выглядит плоско)")


# --- 3. HDR 2D -------------------------------------------------------------

func _test_hdr_2d() -> void:
	_check(bool(ProjectSettings.get_setting("rendering/viewport/hdr_2d", false)),
		"в настройках проекта включён hdr_2d (без него значения >1.0 обрезаются)")
	_check(str(ProjectSettings.get_setting(
		"rendering/renderer/rendering_method", "")) == "gl_compatibility",
		"рендерер gl_compatibility (по умолчанию, для старых GPU)")
	_check(root.use_hdr_2d, "hdr_2d реально применён в рантайме")


# --- 4. Пост-пасс под HUD --------------------------------------------------

func _test_post_pass_order() -> void:
	var fx: ColorRect = _find("PostFX")
	_check(fx != null, "пост-пасс (виньетка/зерно) создан")
	if fx == null:
		return
	_check(fx.mouse_filter == Control.MOUSE_FILTER_IGNORE,
		"пост-пасс не перехватывает мышь")
	var sh: Shader = fx.material.shader if fx.material is ShaderMaterial else null
	_check(sh != null and sh.code.contains("vignette_strength"),
		"шейдер пост-пасса содержит виньетку")
	# Порядок: пост-пасс ПЕРВЫМ потомком UI-слоя, иначе он затемнит весь HUD.
	# Узел UI не состоит в группе "ui" — ищем по имени.
	var ui_node: Node = _find("UI")
	_check(ui_node != null, "UI-слой найден")
	if ui_node != null and ui_node.get_child_count() > 0:
		_check(ui_node.get_child(0) == fx,
			"пост-пасс под HUD (первый потомок слоя), иначе интерфейс темнеет")


# --- 5. Свет заклинания ----------------------------------------------------

func _test_spell_light() -> void:
	var before := _count_lights()
	SpellVFX.cast_flash(_hero.global_position, "Fire")
	await process_frame
	var after := _count_lights()
	_check(after > before,
		"вспышка каста создала источник света (%d -> %d)" % [before, after])

	var lights := _all_lights()
	var found_fire := false
	for l in lights:
		var light: PointLight2D = l as PointLight2D
		if light == null:
			continue
		if light.texture != null:
			found_fire = true
			# Свет сферы должен быть тёплым для Fire, а не белым.
			_check(light.color.r >= light.color.b,
				"свет окрашен по сфере (r=%.2f b=%.2f)" % [light.color.r, light.color.b])
	_check(found_fire, "у источника есть процедурная текстура (GradientTexture2D)")

	# Зона тоже должна светить. Свет от предыдущей вспышки к этому моменту
	# ещё мог жив: общий счёт光源 не годится, проверяем свет ПОД САМОЙ зоной.
	await create_timer(1.0).timeout   # даём предыдущему свету погаснуть
	var zone := SpellVFX.spawn_zone(_hero.global_position + Vector2(0, 96),
		"hail", "Water", _hero, 3.0, Vector2i(4, 3), 5)
	await process_frame
	_check(_lights_under(zone).is_empty(),
		"до конца телеграфа зона не светит (подсказка не должна освещать несработавшее)")
	# Ждём конца телеграфа — свет появляется в активной фазе.
	await create_timer(0.9).timeout
	_check(not _lights_under(zone).is_empty(),
		"зона зажгла свет после телеграфа (под зоной источников: %d)"
			% _lights_under(zone).size())
	if zone != null:
		zone.queue_free()
	await process_frame


# --- поиск узлов -----------------------------------------------------------

func _find(node_name: String) -> Node:
	if _scene_root == null:
		return null
	return _scene_root.find_child(node_name, true, false)


func _all_lights() -> Array:
	var out: Array = []
	if _scene_root == null:
		return out
	_collect_lights(_scene_root, out)
	return out


func _collect_lights(node: Node, out: Array) -> void:
	if node is PointLight2D:
		out.append(node)
	for c in node.get_children():
		_collect_lights(c, out)


func _count_lights() -> int:
	return _all_lights().size()


## Свет, являющийся ПОТОМКОМ указанного узла.
func _lights_under(node: Node) -> Array:
	var out: Array = []
	if node == null:
		return out
	for c in node.get_children():
		if c is PointLight2D:
			out.append(c)
	return out


func _finish() -> void:
	if _fails.is_empty():
		print("LIGHT: RESULT: OK")
	else:
		print("LIGHT: RESULT: FAIL (%d): %s" % [_fails.size(), str(_fails)])
	quit(0 if _fails.is_empty() else 1)


# --- 6. Второй слой: частицы ----------------------------------------------

## Частицы дают то, чего принципиально не может статичный шейдер:
## стохастичную высокочастотную детализацию и историю движения.
## Отдельно проверяем, что интерполяция выключена — Godot не поддерживает её
## для 2D-частиц, а в проекте она включена, иначе частицы ступенчатые.
func _test_particles() -> void:
	var scene_node: Node = current_scene
	var before := _count_particles()
	SpellParticles.impact_sparks(scene_node, _hero.global_position,
		SpellVFX.sphere_color("Fire"))
	await process_frame
	var after := _count_particles()
	_check(after > before,
		"попадание породило частицы-искры (%d -> %d)" % [before, after])

	var parts := _all_particles()
	var interp_off := true
	var additive := true
	for p2 in parts:
		var part: GPUParticles2D = p2 as GPUParticles2D
		if part == null:
			continue
		if part.physics_interpolation_mode != Node.PHYSICS_INTERPOLATION_MODE_OFF:
			interp_off = false
		var m := part.material as CanvasItemMaterial
		if m == null or m.blend_mode != CanvasItemMaterial.BLEND_MODE_ADD:
			additive = false
		if m != null and m.light_mode != CanvasItemMaterial.LIGHT_MODE_UNSHADED:
			additive = false
	_check(interp_off,
		"у всех частиц отключена физическая интерполяция (2D-частицы её не "
		+ "поддерживают, а в проекте она включена)")
	_check(additive,
		"частицы аддитивные и unshaded (иначе ломают батчинг и не светятся)")
	_check(bool(parts[0].light_mask == 0) if parts.size() > 0 else true,
		"частицы исключены из каналов освещения (light_mask = 0)")


func _all_particles() -> Array:
	var out: Array = []
	_collect_particles(current_scene, out)
	return out


func _collect_particles(node: Node, out: Array) -> void:
	if node is GPUParticles2D:
		out.append(node)
	for c in node.get_children():
		_collect_particles(c, out)


func _count_particles() -> int:
	return _all_particles().size()


# --- 7. Яркость и самосветящиеся ауры -------------------------------------

## Игрок пожаловался: «все объекты и НПЦ и строения стали тёмные». Причина —
## AgX сажает средние тона вниз, а спрайты живут именно в них (у рельефа своя
## яркость от солнца в вершинных цветах). Компенсируем экспозицией и снимаем
## собственное затемнение CanvasModulate.
func _test_brightness_compensation() -> void:
	var we: WorldEnvironment = _find("WorldEnvironment")
	if we != null and we.environment != null:
		_check(we.environment.tonemap_exposure > 1.0,
			"экспозиция поднята (%.2f) — компенсация просадки средних тон"
				% we.environment.tonemap_exposure)
		_check(we.environment.tonemap_agx_contrast <= 0.9,
			"контраст AgX снижен (%.2f) — меньше провала теней"
				% we.environment.tonemap_agx_contrast)
	var ambient: CanvasModulate = _find("Ambient")
	if ambient != null:
		var luma := ambient.color.r * 0.3 + ambient.color.g * 0.6 + ambient.color.b * 0.1
		_check(luma > 0.94,
			"приглушение окружения почти снято (luma %.2f, было 0.90 и объекты темнели)"
				% luma)


## Ауры должны быть самосветящимися. Без render_mode unshared аура
## считается ОСВЕЩАЕМОЙ, а источников света в сцене нет — значит её гасит
## ambient, и на светлой траве щит с альфой 0.22 пропадал совсем.
func _test_auras_unshaded() -> void:
	_hero.set("known_spells", {"Shield": {"charges": -1},
		"Protection_from_Fire": {"charges": -1}, "Haste": {"charges": -1}})
	_hero.call("_apply_effects", _hero, SpellDB.get_spell("Shield"))
	await process_frame
	var found := 0
	var all_unshaded := true
	for c in _hero.get_children():
		if not (c is SpellAura):
			continue
		found += 1
		var mat := (c as SpellAura)._sprite.material as ShaderMaterial
		if mat == null or mat.shader == null:
			all_unshaded = false
			continue
		var code := mat.shader.code
		if not code.contains("unshaded") or not code.contains("blend_add"):
			all_unshaded = false
	_check(found >= 1, "ауры на герое есть: %d" % found)
	_check(all_unshaded,
		"все ауры самосветящиеся (unshaded + blend_add) — иначе ambient их гасит")
