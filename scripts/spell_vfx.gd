class_name SpellVFX
extends Node
## Procedural visual effects of spells: ONLY shaders and generated
## particles. The ready-made frames in assets/projecticles/* are not used at runtime.
##
## Important: a Shader is compiled once per sphere and cached. Before,
## make_projectile created new Image/Shader/ShaderMaterial on EVERY
## cast — the shader was recompiled on every shot.
##
## Spheres: Fire plasma, Water hexacrystal, Air lightning, Earth cracks,
##        Astral starfield.

const SPHERE_COLORS := {
	"Fire": Color(1.0, 0.4, 0.1),
	"Water": Color(0.2, 0.6, 1.0),
	"Air": Color(0.8, 0.9, 1.0),
	"Earth": Color(0.6, 0.4, 0.2),
	"Astral": Color(0.7, 0.3, 0.9),
}

# --- Cache (shader compilation is expensive, it is created once) ---
static var _shader_cache: Dictionary = {}
static var _wall_shader_cache: Dictionary = {}
static var _ground_shader_cache: Dictionary = {}
static var _aux_shader_cache: Dictionary = {}
static var _white_tex: ImageTexture = null
static var _spark_tex: Dictionary = {}


static func white_texture() -> ImageTexture:
	if _white_tex == null:
		var img := Image.create(4, 4, false, Image.FORMAT_RGBA8)
		img.fill(Color.WHITE)
		_white_tex = ImageTexture.create_from_image(img)
	return _white_tex


static func spark_texture(color: Color) -> ImageTexture:
	var key := color.to_html(false)
	if _spark_tex.has(key):
		return _spark_tex[key]
	var img := Image.create(3, 3, false, Image.FORMAT_RGBA8)
	img.fill(color)
	var tex := ImageTexture.create_from_image(img)
	_spark_tex[key] = tex
	return tex


## The projectile shader for a sphere (compiled once).
static func projectile_shader(sphere: String) -> Shader:
	if _shader_cache.has(sphere):
		var cached: Shader = _shader_cache[sphere]
		return cached
	var sh := Shader.new()
	sh.code = _shader_code_for(sphere)
	_shader_cache[sphere] = sh
	return sh


static func _shader_code_for(sphere: String) -> String:
	match sphere:
		"Fire": return _fire_shader()
		"Water": return _ice_shader()
		"Air": return _lightning_shader()
		"Earth": return _stone_shader()
		_: return _astral_shader()


static func _sphere_color(sphere: String) -> Color:
	return SPHERE_COLORS.get(sphere, Color.WHITE)


## PROTECTION colours — a separate table.
## We do not touch the global SPHERE_COLORS: fire is orange there (1.0, 0.4, 0.1),
## and that is how it should look on projectiles and walls. The player asked that
## protections read as: fire — red, water — blue, lightning — light blue,
## earth — light brown.
const RESIST_COLORS := {
	"Fire": Color(1.0, 0.18, 0.12),     # red
	"Water": Color(0.15, 0.5, 1.0),    # blue
	# Air and earth were deliberately MOVED AWAY from their colour neighbours: the former
	# "light blue" and "light brown" were confused with water and fire when
	# protections hang at the same time. Air — pale yellow (a discharge), earth —
	# olive-grey stone.
	"Air": Color(0.96, 0.94, 0.66),     # pale yellow
	"Earth": Color(0.68, 0.74, 0.52),   # olive grey
	"Astral": Color(0.85, 0.6, 1.0),    # just in case
}

## Protection colour by sphere (for the breeze ring around the body).
static func resist_color(sphere: String) -> Color:
	return RESIST_COLORS.get(sphere, Color.WHITE)


## The "school" number for the breeze shader: 0 fire, 1 water, 2 air, 3 earth.
## It is needed because for same-size protections the difference must come NOT only
## from colour (that is a channel unavailable to 8–10 % of men): every school has its own
## jet motion — embers upward, ripples, slanted stripes, dust.
const RESIST_SCHOOLS := {
	"Fire": 0, "Water": 1, "Air": 2, "Earth": 3, "Astral": 3,
}


static func resist_school(sphere: String) -> int:
	return int(RESIST_SCHOOLS.get(sphere, 3))


## Set the SIZE IN PIXELS on the sprite rather than a scale multiplier.
##
## Before, auras set scale = 0.45…1.6 on a 4×4 px texture: the icon
## came out 2–6 pixels, that is "a dot that floats". The scale must
## be computed from the texture size, otherwise the same code gives a different
## result when the white texture changes.
static func fit_px(s: Sprite2D, w: float, h: float) -> void:
	if s == null or s.texture == null:
		return
	var ts := s.texture.get_size()
	s.scale = Vector2(maxf(1.0, w) / maxf(1.0, ts.x), maxf(1.0, h) / maxf(1.0, ts.y))


## Sprite size in pixels (for tests and for positioning effects).
static func sprite_px(s: Sprite2D) -> Vector2:
	if s == null or s.texture == null:
		return Vector2.ZERO
	return s.texture.get_size() * s.scale

## Public access to the sphere colour: used by the auras and zones that
## are tinted by element (fire resistance — orange, cold — light blue).
static func sphere_color(sphere: String) -> Color:
	return _sphere_color(sphere)


## A helper shader by key (ring/glow/wall) — also compiled once.
static func aux_shader(key: String, code: String) -> Shader:
	if _aux_shader_cache.has(key):
		var cached: Shader = _aux_shader_cache[key]
		return cached
	var sh := Shader.new()
	sh.code = code
	_aux_shader_cache[key] = sh
	return sh


static func _scene() -> Node:
	return Engine.get_main_loop().current_scene as Node


## The effect Tween that stops together with the world.
##
## By default a Tween pause mode is BOUND: the tween freezes only if the owner
## node is paused. Here the owner is the scene root (Game) with PROCESS_MODE_ALWAYS,
## which is why flashes, telegraphs and sparks kept playing on tactical pause.
## STOP stops the tween by SceneTree.paused regardless of the owner.
static func world_tween(scene: Node) -> Tween:
	var tw := scene.create_tween()
	tw.set_pause_mode(Tween.TWEEN_PAUSE_STOP)
	return tw


# --- Projectile ---------------------------------------------------------------

## Create a spell projectile sprite. The material is own (own time), the shader is shared.
static func make_projectile(spell_name: String) -> Sprite2D:
	var sphere := SpellDB.sphere_of(spell_name)
	var sprite := Sprite2D.new()
	sprite.z_index = 5
	sprite.texture = white_texture()
	var mat := ShaderMaterial.new()
	mat.shader = projectile_shader(sphere)
	mat.set_shader_parameter("color", _sphere_color(sphere))
	mat.set_shader_parameter("time", 0.0)
	sprite.material = mat
	sprite.scale = Vector2(2.0, 2.0)
	return sprite


## Update the time in the shader (every frame).
static func update_shader_time(sprite: Sprite2D, _delta: float, elapsed: float) -> void:
	if sprite != null and sprite.material is ShaderMaterial:
		(sprite.material as ShaderMaterial).set_shader_parameter("time", elapsed)


# --- Cast -----------------------------------------------------------------

## Flash at the start of a cast (a ring growing outwards).
static func cast_flash(pos: Vector2, sphere: String) -> void:
	var scene := _scene()
	if scene == null:
		return
	# Light on a cast: without it the flash is just a bright picture, not a source.
	# The node is created in the scene so it joins y-sorting together with the effect.
	var holder := Node2D.new()
	holder.position = pos
	scene.add_child(holder)
	SpellLighting.burst_light(holder, _sphere_color(sphere), 58.0, 0.4)
	var color := _sphere_color(sphere)
	var flash := Sprite2D.new()
	flash.z_index = 10
	flash.texture = white_texture()
	var mat := ShaderMaterial.new()
	mat.shader = projectile_shader(sphere)
	mat.set_shader_parameter("color", color)
	mat.set_shader_parameter("time", 0.0)
	flash.material = mat
	flash.position = pos
	flash.scale = Vector2.ZERO
	flash.modulate.a = 0.8
	scene.add_child(flash)
	var tw := world_tween(scene)
	tw.set_parallel(true)
	tw.tween_property(flash, "scale", Vector2(4.0, 4.0), 0.15).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_property(flash, "modulate:a", 0.0, 0.2)
	tw.chain().tween_callback(flash.queue_free)


## Preparation telegraph of a spell: a ring shrinking towards the cast moment.
## Shown for cast_time seconds — the player sees when the spell will go off.
static func cast_telegraph(pos: Vector2, sphere: String, cast_time: float) -> void:
	var scene := _scene()
	if scene == null:
		return
	var ring := Sprite2D.new()
	ring.z_index = 9
	ring.texture = white_texture()
	var mat := ShaderMaterial.new()
	mat.shader = aux_shader("ring", _ring_shader())
	mat.set_shader_parameter("color", _sphere_color(sphere))
	ring.material = mat
	ring.position = pos
	ring.scale = Vector2(6.0, 6.0)
	ring.modulate.a = 0.7
	scene.add_child(ring)
	var tw := world_tween(scene)
	tw.set_parallel(true)
	tw.tween_property(ring, "scale", Vector2(1.2, 1.2), cast_time).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tw.tween_property(ring, "modulate:a", 0.95, cast_time)
	tw.chain().tween_callback(ring.queue_free)


## Aura around a unit: buff (warm) or debuff (purple).
## A one-off burst for 0.45 s. Long effects (shield, Protection_from_*, Haste)
## last for minutes, so they need SpellAura — see spawn_aura().
static func aura_ring(unit: Node2D, sphere: String, kind: String) -> void:
	if not is_instance_valid(unit):
		return
	var scene := _scene()
	if scene == null:
		return
	var color := _sphere_color(sphere)
	if kind == "debuff":
		color = Color(0.75, 0.25, 0.95)
	elif kind == "heal":
		color = Color(0.4, 1.0, 0.5)
	var count := 10
	for i in range(count):
		var p := Sprite2D.new()
		p.z_index = 7
		p.texture = spark_texture(color)
		p.position = unit.global_position
		p.modulate.a = 0.9
		scene.add_child(p)
		var angle := TAU * i / count
		var target := unit.global_position + Vector2(cos(angle), sin(angle)) * 34.0
		var tw := world_tween(scene)
		tw.set_parallel(true)
		tw.tween_property(p, "position", target, 0.45).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		tw.tween_property(p, "modulate:a", 0.0, 0.5)
		tw.chain().tween_callback(p.queue_free)


# --- Hit --------------------------------------------------------------------

## Explosion on hit: a core + scattering sparks.
static func impact_burst(pos: Vector2, sphere: String, is_aoe: bool) -> void:
	var scene := _scene()
	if scene != null:
		var light_holder := Node2D.new()
		light_holder.position = pos
		scene.add_child(light_holder)
		SpellLighting.burst_light(light_holder, _sphere_color(sphere),
			90.0 if is_aoe else 52.0, 0.45)
		# SECOND LAYER: particles give what a static shader cannot —
		# stochastic detail and a history of motion.
		if is_aoe:
			SpellParticles.aoe_debris(scene, pos, _sphere_color(sphere))
		else:
			SpellParticles.impact_sparks(scene, pos, _sphere_color(sphere))
	if scene == null:
		return
	var color := _sphere_color(sphere)
	var count := 14 if is_aoe else 7
	for i in range(count):
		var p := Sprite2D.new()
		p.z_index = 8
		p.texture = spark_texture(color)
		p.position = pos
		p.modulate.a = 0.9
		scene.add_child(p)
		var angle := TAU * i / count + randf_range(-0.3, 0.3)
		var dist := randf_range(30.0, 70.0) if is_aoe else randf_range(14.0, 36.0)
		var target := pos + Vector2(cos(angle), sin(angle)) * dist
		var tw := world_tween(scene)
		tw.set_parallel(true)
		tw.tween_property(p, "position", target, 0.25).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_QUAD)
		tw.tween_property(p, "modulate:a", 0.0, 0.3)
		tw.tween_property(p, "scale", Vector2(0.3, 0.3), 0.3)
		tw.chain().tween_callback(p.queue_free)


## Light (Astral, self): a soft glow around the hero.
static func spawn_light(pos: Vector2, life: float) -> void:
	var scene := _scene()
	if scene == null:
		return
	var glow := Sprite2D.new()
	glow.z_index = 2
	glow.texture = white_texture()
	var mat := ShaderMaterial.new()
	mat.shader = aux_shader("glow", _glow_shader())
	mat.set_shader_parameter("color", Color(1.0, 0.95, 0.7))
	mat.set_shader_parameter("time", 0.0)
	glow.material = mat
	glow.position = pos
	glow.scale = Vector2(7.0, 7.0)
	glow.modulate.a = 0.35
	scene.add_child(glow)
	var tw := world_tween(scene)
	tw.tween_property(glow, "modulate:a", 0.18, life * 0.5)
	tw.tween_property(glow, "modulate:a", 0.35, life * 0.5)
	tw.tween_callback(glow.queue_free)


## Lightning between two points (prismatic radiance, chain spells).
## Before, a "multi-target" spell had only a single projectile, so there was
## nothing to draw a fan with.
## A rainbow for prismatic radiance: every target gets its own colour.
## Before, all beams were painted in the SPHERE colour (Air — light blue), that is
## "prismatic" radiance looked like several identical blue lightning bolts.
const RAINBOW := [
	Color(1.0, 0.22, 0.22),   # red
	Color(1.0, 0.62, 0.15),   # orange
	Color(1.0, 0.95, 0.25),   # yellow
	Color(0.35, 0.95, 0.35),  # green
	Color(0.25, 0.7, 1.0),    # cyan
	Color(0.55, 0.4, 1.0),    # blue
	Color(0.95, 0.4, 0.95),   # violet
]


## Rainbow colour by target index (cycling around).
static func rainbow_color(index: int) -> Color:
	if RAINBOW.is_empty():
		return Color.WHITE
	return RAINBOW[posmod(index, RAINBOW.size())]


## Lightning between two points. color_override — set a custom colour (rainbow);
## if it is not set (alpha < 0), the sphere colour is taken.
static func chain_arc(from: Vector2, to: Vector2, sphere: String,
		color_override: Color = Color(-1.0, -1.0, -1.0, 0.0)) -> void:
	var scene := _scene()
	if scene == null:
		return
	var color := color_override if color_override.a >= 0.0 else _sphere_color(sphere)
	var d := to - from
	var length := d.length()
	if length < 1.0:
		return
	# A polyline of 5 segments. The amplitude GROWS towards the middle and falls towards the ends:
	# before, all inner points had the same spread, and the zigzag read
	# as a periodic saw — the eye catches the repeat in ~200 ms. The cone gives
	# a "flash" in the middle and clean ends at the emitter and at the target.
	var points: Array[Vector2] = []
	var steps := 5
	var normal := Vector2(-d.y, d.x).normalized()
	for i in range(steps + 1):
		var t := float(i) / float(steps)
		# Triangular envelope: 0 at the ends, 1 in the middle.
		var env := 1.0 - absf(t * 2.0 - 1.0)
		var jitter := 0.0 if (i == 0 or i == steps) else length * 0.10 * env
		points.append(from + d * t + normal * randf_range(-jitter, jitter))
	# A glow layer under the main discharge — otherwise the thin line is barely visible.
	for pass_index in range(2):
		var line := Line2D.new()
		line.z_index = 9
		line.width = 14.0 if pass_index == 0 else 3.0
		line.default_color = color
		line.begin_cap_mode = Line2D.LINE_CAP_ROUND
		line.end_cap_mode = Line2D.LINE_CAP_ROUND
		line.joint_mode = Line2D.LINE_JOINT_ROUND
		if pass_index == 0:
			line.default_color = Color(color.r, color.g, color.b, 0.3)
		# In Godot 4 Line2D has no add_points() method — the points are set by a property.
		line.points = points
		scene.add_child(line)
		var tw := world_tween(scene)
		tw.tween_interval(0.16 if pass_index == 0 else 0.1)
		tw.tween_property(line, "modulate:a", 0.0, 0.12)
		tw.tween_callback(line.queue_free)


## A short burst at the FEET: dust/sparks on the ground when a buff is applied.
## Before, on a buff cast a ring of sparks was drawn around the unit AND at the same time
## a permanent aura appeared — two effects at one point read as "it jerked
## and applied". Now for buffs with a permanent aura the ring is replaced by dust
## at the ground: it stresses that the effect applied and does not argue with the aura.
static func ground_dust(unit: Node2D) -> void:
	var scene := _scene()
	if scene == null or not is_instance_valid(unit):
		return
	var color := _sphere_color("Earth")
	for i in range(7):
		var p := Sprite2D.new()
		p.z_index = 3
		p.texture = spark_texture(color)
		p.position = unit.global_position
		p.modulate.a = 0.75
		scene.add_child(p)
		var angle := TAU * i / 7.0
		var target := unit.global_position + Vector2(cos(angle), sin(angle) * 0.4) * 30.0
		var tw := world_tween(scene)
		tw.set_parallel(true)
		tw.tween_property(p, "position", target, 0.5).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		tw.tween_property(p, "modulate:a", 0.0, 0.5)
		tw.chain().tween_callback(p.queue_free)


## Wall of fire/earth: a node with ticking damage and/or cell blocking.
## The size comes in CELLS (6 × 2), not in pixels: before, the damage radius,
## the sprite width and the cell block were set by three different numbers and did not match.
static func spawn_wall(pos: Vector2, sphere: String, owner_unit: Node2D, life: float,
		mode: String = "damage", cells: Vector2i = SpellWall.DEFAULT_CELLS,
		damage: int = 0) -> SpellWall:
	var scene := _scene()
	if scene == null:
		return null
	var wall := SpellWall.new()
	wall.position = pos
	wall.set_mode(mode)
	# Style and the presence of flame tongues — by sphere. In the original the walls are DIFFERENT
	# (spells.txt): fire burns continuously, earth — an impassable barrier.
	# Fire gets a third layer over the units, earth stays flat.
	wall.flame = sphere == "Fire"
	wall.style = "wall_fire" if wall.flame else "wall_earth"
	# IMPORTANT: configure BEFORE add_child. `_ready()` runs INSIDE add_child and
	# builds the quads/hearths from `cells`; before, it saw the default 6×2, and a vertical
	# wall 2×6 was drawn horizontal, while a 3×3 zone was drawn as a 6×2 stripe.
	wall.configure(damage, cells, sphere, owner_unit, life)
	scene.add_child(wall)
	return wall


## A spell zone of a generic kind: blizzard, poisonous cloud.
## The style picks the drawing ("hail" — falling shards, "cloud" — mist),
## mode "damage" — ticks damage, "block" — an impassable barrier.
static func spawn_zone(pos: Vector2, style: String, sphere: String, owner_unit: Node2D,
		life: float, cells: Vector2i, damage: int, tick_interval: float = 0.5) -> SpellZone:
	var scene := _scene()
	if scene == null:
		return null
	var zone := SpellZone.new()
	zone.position = pos
	zone.style = style
	zone.mode = "damage"
	zone.tick_interval = maxf(0.1, tick_interval)
	# configure BEFORE add_child: _ready() builds the quads from cells (see spawn_wall).
	zone.configure(damage, cells, sphere, owner_unit, life)
	scene.add_child(zone)
	return zone


## A falling ice shard of the blizzard.
static func hail_shard(pos: Vector2) -> void:
	var scene := _scene()
	if scene == null:
		return
	var s := Sprite2D.new()
	s.z_index = 9
	s.texture = spark_texture(Color(0.8, 0.92, 1.0))
	s.position = pos + Vector2(0, -26)
	s.scale = Vector2(1.6, 3.0)
	s.material = zone_material("shard", Color(0.85, 0.94, 1.0, 1.0))
	s.modulate.a = 0.95
	scene.add_child(s)
	var tw := world_tween(scene)
	tw.set_parallel(true)
	tw.tween_property(s, "position", pos + Vector2(0, 8), 0.28).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tw.tween_property(s, "modulate:a", 0.0, 0.28)
	tw.chain().tween_callback(s.queue_free)


## Material of a zone/shard. The cache is shared (aux_shader), otherwise for every
## shard a new Shader would be compiled.
static func zone_material(style: String, color: Color) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	# render_mode is substituted by style: auras over a unit are self-illuminated
	# (unshaded + additive), ground zones blend with the ground.
	mat.shader = aux_shader("zone_" + style, _zone_shader_with_mode(style))
	mat.set_shader_parameter("color", color)
	mat.set_shader_parameter("time", 0.0)
	return mat


## The colour of the fire wall. The player asked for an EVEN red-orange: the Fire sphere
## gives (1.0, 0.4, 0.1), and on a 6×2 field with HDR it read as a ginger film.
## The flame tongues keep one hue, and the brightness comes from the core, not from a hue shift.
const FLAME_WALL_COLOR := Color(1.0, 0.30, 0.06)
## The poisonous cloud burns with a GREEN flame (player request 28.10): the mist is
## green, and the flame tongues must be the same colour, not orange.
const POISON_FLAME_COLOR := Color(0.40, 0.95, 0.28)


## Material of ONE fire hearth: the wall now has its own flame in every cell
## instead of one stretched film over the whole rectangle (player complaint 28.10).
## seed changes the tongue shape from cell to cell.
static func flame_wall_material(color: Color, seed: float = 0.0,
		rise: float = 1.4) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = aux_shader("flame_wall", _flame_wall_shader())
	mat.set_shader_parameter("color", color)
	mat.set_shader_parameter("time", 0.0)
	mat.set_shader_parameter("rise", rise)
	mat.set_shader_parameter("seed", seed)
	return mat


static func _flame_wall_shader() -> String:
	return """shader_type canvas_item;
render_mode blend_add, unshaded;
uniform vec4 color : source_color = vec4(1.0, 0.30, 0.06, 1.0);
uniform float time : hint_range(0.0, 100.0) = 0.0;
uniform float rise : hint_range(0.0, 4.0) = 1.4;
uniform float seed : hint_range(0.0, 1.0) = 0.0;

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash21(i);
	float b = hash21(i + vec2(1.0, 0.0));
	float c = hash21(i + vec2(0.0, 1.0));
	float d = hash21(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

float fbm(vec2 p) {
	float v = 0.0;
	float amp = 0.5;
	for (int i = 0; i < 4; i++) {
		v += amp * vnoise(p);
		p = p * 2.03 + vec2(1.7, 9.2);
		amp *= 0.5;
	}
	return v;
}

void fragment() {
	// h: 0 у земли, 1 на верхушке квада. Клетка — нижние 1/(1+rise).
	float h = clamp(1.0 - UV.y, 0.0, 1.0);
	float cell_top = 1.0 / (1.0 + rise);
	float in_cell = clamp(h / max(cell_top, 0.001), 0.0, 1.0);

	// Доменное искажение: иначе все языки одинаковой формы.
	vec2 q = vec2(UV.x * 4.2 + seed * 7.3, h * 3.4 - time * 1.15 + seed * 3.1);
	float warp = fbm(q * 1.6 + vec2(0.0, -time * 0.45));
	q.x += (warp - 0.5) * 1.1;

	float n = fbm(q);
	// Язык: у земли широкий, кверху рвётся и сужается.
	float t = 1.0 - in_cell;
	float body = smoothstep(0.52 - t * 0.24, 0.94 - t * 0.24, n);
	body *= 1.0 - smoothstep(0.55, 1.0, in_cell) * 0.55;

	// Выше клетки — только кончики, которые гаснут к верху квада.
	if (h > cell_top) {
		float k = (h - cell_top) / max(1.0 - cell_top, 0.001);
		body *= max(0.0, 1.0 - k * 1.25);
	}

	// У земли огонь плотнее — там горит, а не дымит. Небольшая добавка:
	// 12 аддитивных очагов складываются, и большая даёт розовую плёнку.
	float base_glow = (1.0 - smoothstep(0.0, 0.20, in_cell)) * 0.22;
	float m = clamp(body + base_glow, 0.0, 1.0);
	if (m < 0.03) {
		discard;
	}
	vec3 col = mix(color.rgb * 1.10, color.rgb * 0.55 + vec3(0.80, 0.62, 0.30),
		body * 0.30);
	COLOR = vec4(col * m * 1.35, 1.0);
}"""


## Stone wall: a boulder in the cell. Before, the earth wall was drawn by the same
## "fiery" shader without a flame — the player saw "something burns and a grid".
## Now it is stone: a rounded block, light top, dark bottom, a chip.
static func stone_wall_material(seed: float = 0.0) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = aux_shader("stone_wall", _stone_wall_shader())
	mat.set_shader_parameter("seed", seed)
	return mat


static func _stone_wall_shader() -> String:
	return """shader_type canvas_item;
render_mode blend_mix, unshaded;
uniform vec4 color : source_color = vec4(0.62, 0.57, 0.50, 1.0);
uniform float seed : hint_range(0.0, 1.0) = 0.0;

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash21(i), hash21(i + vec2(1.0, 0.0)), f.x),
	           mix(hash21(i + vec2(0.0, 1.0)), hash21(i + vec2(1.0, 1.0)), f.x), f.y);
}

float ridged(vec2 p) {
	float v = 0.0;
	float a = 0.5;
	for (int k = 0; k < 3; k++) {
		v += a * (1.0 - abs(vnoise(p) * 2.0 - 1.0));
		p = p * 2.11 + 5.7;
		a *= 0.5;
	}
	return v;
}

void fragment() {
	// Глыба: скруглённый блок, центр чуть выше середины квада. Ширина больше
	// клетки — соседние валуны перекрываются и стена читается кучей камней,
	// а не рядом отдельных «яиц».
	vec2 p = UV - vec2(0.5, 0.58);
	float d = length(vec2(p.x * 0.95, p.y * 0.98));
	float body = 1.0 - smoothstep(0.40, 0.46, d);
	if (body < 0.02) {
		discard;
	}
	// Скальная фактура: рваные грани + тонкие трещины.
	float grain = vnoise(UV * 9.0 + seed * 13.0);
	float cracks = ridged(UV * 4.5 + seed * 7.0);
	float crack = 1.0 - smoothstep(0.0, 0.10, abs(cracks - 0.62));

	// Светлый верх, тёмное основание — «камень стоит на земле».
	float top = smoothstep(0.30, -0.30, p.y);
	float bottom = smoothstep(-0.20, 0.45, p.y);
	vec3 col = color.rgb * (0.70 + 0.55 * top - 0.28 * bottom);
	col *= 0.86 + 0.22 * grain;
	col = mix(col, col * 0.55, crack * 0.7);
	COLOR = vec4(col, 1.0);
}"""


## Ground spell zone. One shader for wall/blizzard/cloud.
##
## The key difference from before: all the maths runs in WORLD coordinates
## rather than in UV. Before, one white quad 4x4 was stretched to 192x64 and the UVs
## were squeezed 6 times horizontally — hence the "glitch on the ground" and the feeling
## that the effect is "not in the cells". The world grid gives the same grain scale
## for a 3x3 cloud and a 6x2 wall, and ties the effect to the world cells.
##
## nb — a bitmask of neighbours: 1=N 2=E 4=S 8=W 16=NE 32=SE 64=SW 128=NW.
## The outline is drawn ONLY on the sides where there is no neighbour, so 12 cells
## read as one rectangle rather than as 12 little squares.
static func _ground_shader() -> String:
	return """shader_type canvas_item;
render_mode blend_mix;

uniform vec4 color : source_color = vec4(1.0, 0.4, 0.1, 1.0);
uniform vec4 rim_color : source_color = vec4(1.0, 0.95, 0.7, 1.0);
uniform float time : hint_range(0.0, 100.0) = 0.0;
uniform float tile_px = 32.0;
// Стиль: 0 = огонь, 1 = метель, 2 = ядовитое облако, 3 = каменная стена.
uniform int style : hint_range(0, 3) = 0;
uniform vec2 cells = vec2(6.0, 2.0);
uniform vec2 origin_cell = vec2(0.0, 0.0);
// Множитель яркости заливки: у огня заливка — выжженная земля (тёмная),
// у облака — сам туман (светлее). Раньше один и тот же цвет делал огонь
// «светящимся прямоугольником».
uniform float fill_shade : hint_range(0.0, 1.0) = 0.7;
// Фаза: 0 = телеграф (только контур), 1 = активна.
uniform float active = 0.0;
// 0..1 — растворение на затухании.
uniform float burn = 0.0;
// Заливка намеренно слабая: юниты в зоне должны оставаться видимыми.
uniform float fill_a : hint_range(0.0, 1.0) = 0.2;
uniform float edge_w : hint_range(1.0, 8.0) = 3.0;

varying vec2 world;

void vertex() {
	world = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy;
}

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), f.x),
	           mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), f.x), f.y);
}

float fbm(vec2 p) {
	float v = 0.0;
	float a = 0.5;
	for (int k = 0; k < 3; k++) {
		v += a * vnoise(p);
		p = p * 2.03 + 11.3;
		a *= 0.5;
	}
	return v;
}

// Профиль контура. GLSL не поддерживает вложенные функции (это C), поэтому
// объявляем на верхнем уровне и передаём толщину параметром.
float edge(float d, float lw) {
	return 1.0 - smoothstep(lw * 0.4, lw, d);
}

// Шум в МИРОВЫХ координатах + domain warping: одна гладкая волна
// превращается в органическое самоперекрывающееся поле.
float field(vec2 w) {
	vec2 p = w / 42.0;
	vec2 q = vec2(fbm(p + vec2(0.0, time * 0.25)),
	              fbm(p + vec2(5.2, 1.3) - vec2(time * 0.2, 0.0)));
	vec2 r = vec2(fbm(p + 3.0 * q + vec2(1.7, 9.2)),
	              fbm(p + 3.0 * q + vec2(8.3, 2.8)));
	return fbm(p + 2.5 * r);
}

void fragment() {
	vec2 w = world;
	vec2 size_px = cells * tile_px;
	vec2 rel = w - origin_cell * tile_px;          // 0..size
	vec2 cuv = fract(w / tile_px);
	vec2 cell = floor(w / tile_px) - origin_cell;  // 0..cells-1

	// --- Контур: маска соседей СЧИТАЕТСЯ ЗДЕСЬ, по каждой клетке.
	// Раньше приходило одно число nb для ЦЕНТРАЛЬНОЙ клетки, и у стены 6×2
	// контур рисовался только с одной стороны, а «сетка» шла от покадрового
	// soft. Теперь стенка рисуется только там, где соседа нет.
	bool n_out = cell.y <= 0.0;
	bool s_out = cell.y >= cells.y - 1.0;
	bool w_out = cell.x <= 0.0;
	bool e_out = cell.x >= cells.x - 1.0;

	float lw = edge_w / tile_px;

	float border = 0.0;
	if (n_out) { border = max(border, edge(cuv.y, lw)); }
	if (s_out) { border = max(border, edge(1.0 - cuv.y, lw)); }
	if (w_out) { border = max(border, edge(cuv.x, lw)); }
	if (e_out) { border = max(border, edge(1.0 - cuv.x, lw)); }

	// Внешние углы скругляем (только выпуклые: внутри зоны угла нет).
	float rr = 0.34;
	if (n_out && w_out) { border *= 1.0 - smoothstep(0.0, rr, length(vec2(cuv.x, cuv.y)) - rr); }
	if (n_out && e_out) { border *= 1.0 - smoothstep(0.0, rr, length(vec2(1.0 - cuv.x, cuv.y)) - rr); }
	if (s_out && w_out) { border *= 1.0 - smoothstep(0.0, rr, length(vec2(cuv.x, 1.0 - cuv.y)) - rr); }
	if (s_out && e_out) { border *= 1.0 - smoothstep(0.0, rr, length(vec2(1.0 - cuv.x, 1.0 - cuv.y)) - rr); }

	// Телеграф: заливка идёт вдоль длинной оси зоны, по клеткам.
	float along = cells.x > 1.0 ? (cell.x) / (cells.x - 1.0) : 0.0;
	if (cells.y > cells.x) {
		along = cells.y > 1.0 ? (cell.y) / (cells.y - 1.0) : 0.0;
	}
	float wipe = clamp(along, 0.0, 1.0);

	// Мягкий край — от ВНЕШНЕГО прямоугольника зоны, а не от каждой клетки:
	// иначе каждая клетка подсвечивается рамкой и видна «сетка».
	float d_edge = min(min(rel.x, size_px.x - rel.x), min(rel.y, size_px.y - rel.y));
	float soft = smoothstep(0.0, 6.0, d_edge);

	// --- Заливка по стилю: у каждой школы свой рисунок, а не «что-то горит».
	float n = field(w);
	float fill = 0.0;
	if (style == 0) {
		// ОГОНЬ: тлеющая земля под языками пламени. Плотность рваная — иначе
		// заливка читается ровным оранжевым прямоугольником.
		float flick = 0.5 + 0.5 * fbm(vec2(w.x * 0.08, w.y * 0.12 - time * 0.9));
		fill = pow(clamp(n, 0.0, 1.0), 1.4) * (0.45 + 0.55 * flick);
	} else if (style == 1) {
		// МЕТЕЛЬ: косые полосы позёмки по ветру + морозная дымка.
		float streak = fract((w.x + w.y * 1.6) / 34.0 - time * 1.15);
		float lines = smoothstep(0.0, 0.16, streak) * smoothstep(0.62, 0.30, streak);
		fill = 0.15 + 0.85 * max(lines, pow(clamp(n, 0.0, 1.0), 1.6));
	} else if (style == 2) {
		// ЯД: клубы тумана в мировых координатах, плотнее в клубах.
		float a = fbm(w / 30.0 + vec2(time * 0.12, -time * 0.20));
		float b = fbm(w / 60.0 - vec2(time * 0.08, time * 0.05));
		fill = smoothstep(0.30, 0.70, a * 0.65 + b * 0.55);
	} else {
		// ЗЕМЛЯ: тёмная корка и каменная крошка у основания стены.
		float grit = vnoise(w * 0.55);
		float height_fade = 1.0 - clamp(rel.y / max(1.0, size_px.y), 0.0, 1.0) * 0.55;
		fill = (0.30 + 0.55 * smoothstep(0.40, 0.80, grit)) * height_fade;
	}

	float alpha_fill = fill_a * soft * fill * active
		* step(wipe, mix(-0.15, 1.25, active));
	float alpha_edge = border * (0.55 + 0.45 * sin(time * 5.0)) * (0.25 + 0.75 * active);

	// Растворение на затухании вместо линейного затухания modulate.a.
	float e = smoothstep(burn, burn + 0.18, n);
	float a = (alpha_fill * e + alpha_edge * (1.0 - burn)) * soft;
	if (a < 0.004) {
		discard;
	}

	// Ярче к центру (правило «это излучает свет»), но НЕ чисто белый:
	// 0% и 100% принадлежат интерфейсу, а не эффекту.
	vec3 base = color.rgb * fill_shade;
	vec3 col = mix(base * 0.65, base, n);
	col = mix(col, rim_color.rgb, border * 0.6);
	COLOR = vec4(col, a);
}"""


## Fill colour by STYLE rather than by spell sphere: poison is Water, and by
## the sphere colour it was blue. Now the style sets the palette.
const STYLE_COLORS := {
	"wall_fire": Color(1.0, 0.36, 0.10),
	"wall_earth": Color(0.52, 0.46, 0.36),
	"hail": Color(0.72, 0.88, 1.0),
	"cloud": Color(0.22, 0.58, 0.16),
}

## Fill density by style. Fire/blizzard — an almost transparent underlay (everything
## readable comes from the second layer: flame tongues and shards), poison — denser, because
## the mist IS the effect.
const STYLE_FILL := {
	"wall_fire": 0.0,
	"wall_earth": 0.20,
	"hail": 0.34,
	"cloud": 0.50,
}

## Fill brightness: fire — scorched dark ground (0.35), mist — light.
const STYLE_SHADE := {
	"wall_fire": 0.35,
	"wall_earth": 0.70,
	"hail": 0.85,
	"cloud": 0.90,
}


static func style_shade(style: String) -> float:
	return float(STYLE_SHADE.get(style, 0.7))


static func style_fill(style: String) -> float:
	return float(STYLE_FILL.get(style, 0.18))


static func style_color(style: String) -> Color:
	return STYLE_COLORS.get(style, Color(1.0, 0.4, 0.1))

## Material of the ground zone. One shader for all styles (the style is a uniform int),
## because their logic is the same. The colour is taken by STYLE: before it came
## from the spell sphere, and the poisonous cloud (Water sphere) was blue.
static func ground_material(sphere: String, style: String) -> ShaderMaterial:
	if _ground_shader_cache.is_empty():
		var sh := Shader.new()
		sh.code = _ground_shader()
		_ground_shader_cache["ground"] = sh
	var mat := ShaderMaterial.new()
	var cached: Shader = _ground_shader_cache["ground"]
	mat.shader = cached
	var col := style_color(style) if style != "wall" else _sphere_color(sphere)
	mat.set_shader_parameter("color", col)
	mat.set_shader_parameter("rim_color", col.lerp(Color(1, 1, 1), 0.55))
	mat.set_shader_parameter("fill_a", style_fill(style))
	mat.set_shader_parameter("fill_shade", style_shade(style))
	mat.set_shader_parameter("time", 0.0)
	mat.set_shader_parameter("active", 0.0)
	mat.set_shader_parameter("burn", 0.0)
	return mat


static func wall_material(sphere: String) -> ShaderMaterial:
	if not _wall_shader_cache.has(sphere):
		var sh := Shader.new()
		sh.code = _wall_shader()
		_wall_shader_cache[sphere] = sh
	var mat := ShaderMaterial.new()
	var cached: Shader = _wall_shader_cache[sphere]
	mat.shader = cached
	mat.set_shader_parameter("color", _sphere_color(sphere))
	mat.set_shader_parameter("time", 0.0)
	return mat


# --- Flashes on a unit ---------------------------------------------------------

## A hit on a shield: a light blue flash. Before it was never called once.
static func shield_hit(unit: Node2D) -> void:
	_flash_unit(unit, Color(0.5, 0.7, 1.0, 1.0), 0.12)


## Flash of taking damage.
static func hit_flash(unit: Node2D) -> void:
	_flash_unit(unit, Color(1.0, 0.3, 0.3, 1.0), 0.1)


## An invisible unit is visible as semi-transparent (for debugging and hits).
static func invisible_tint(unit: Node2D, alpha: float) -> void:
	if is_instance_valid(unit):
		unit.modulate.a = clampf(alpha, 0.15, 1.0)


## Resting colours of the units that are flashing right now, keyed by the
## animation node. Without it a second flash (a hit during a hit, or a hit
## during a shield flash) captured the red tint as the "original" and painted
## the hero permanently red after combat.
static var _flash_base: Dictionary = {}
## Sequence per animation node: only the newest flash may restore the colour.
static var _flash_seq: Dictionary = {}


static func _flash_unit(unit: Node2D, color: Color, seconds: float) -> void:
	if not is_instance_valid(unit):
		return
	var anim := unit.get_node_or_null("UnitAnim")
	if anim == null:
		return
	var id := anim.get_instance_id()
	if not _flash_base.has(id):
		_flash_base[id] = anim.modulate
	var seq := int(_flash_seq.get(id, 0)) + 1
	_flash_seq[id] = seq
	anim.modulate = color
	var tree := unit.get_tree()
	if tree == null:
		_restore_flash(anim, id)
		return
	await tree.create_timer(seconds, true, false, true).timeout
	# A newer flash is still running: it owns the colour and will restore it.
	if int(_flash_seq.get(id, 0)) != seq:
		return
	_restore_flash(anim, id)


static func _restore_flash(anim: Node, id: int) -> void:
	var base: Color = _flash_base.get(id, Color.WHITE)
	_flash_base.erase(id)
	_flash_seq.erase(id)
	if is_instance_valid(anim):
		anim.modulate = base


# === Shaders ===

static func _noise_prelude() -> String:
	return """float hash21(vec2 p) {
	return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash21(i), hash21(i + vec2(1.0, 0.0)), f.x),
	           mix(hash21(i + vec2(0.0, 1.0)), hash21(i + vec2(1.0, 1.0)), f.x), f.y);
}

float fbm2(vec2 p) {
	float v = 0.0;
	float a = 0.5;
	for (int k = 0; k < 4; k++) {
		v += a * vnoise(p);
		p = p * 2.03 + 11.3;
		a *= 0.5;
	}
	return v;
}

float ridged(vec2 p) {
	float v = 0.0;
	float a = 0.5;
	for (int k = 0; k < 3; k++) {
		v += a * (1.0 - abs(vnoise(p) * 2.0 - 1.0));
		p = p * 2.11 + 5.7;
		a *= 0.5;
	}
	return v;
}

// Domain warping: вложенный fbm применяется к КООРДИНАТЕ, а не к значению.
// Превращает одну гладкую периодичную волну в органическое самоперекрывающееся
// поле. Это главное отличие от прежних шейдеров на голых sin/cos: синус
// идеально периодичен, глаз ловит это за ~200 мс и читает картинку как
// синтетическую (эффект из демосцены, а не «магия»).
float warped(vec2 p, float t) {
	vec2 q = vec2(fbm2(p + vec2(0.0, t * 0.25)),
	              fbm2(p + vec2(5.2, 1.3) - vec2(t * 0.2, 0.0)));
	vec2 r = vec2(fbm2(p + 3.0 * q + vec2(1.7, 9.2)),
	              fbm2(p + 3.0 * q + vec2(8.3, 2.8)));
	return fbm2(p + 2.2 * r);
}

// Профиль круга: 1 в центре, 0 у края. Эффект ДОЛЖЕН быть ярче к центру —
// равномерная яркость не имеет фокуса и читается как плоская наклейка.
float core(float d) {
	return pow(max(0.0, 1.0 - d), 1.6);
}

"""
## Fire. Before: sin(uv.x*9 + t*6) * cos(uv.y*11 - t*4) — a periodic
## grid that read as "the 1990s". Now: warped noise, vertical
## rise, a bright core with a value ABOVE 1.0 (needed for bloom with hdr_2d).
static func _fire_shader() -> String:
	return """shader_type canvas_item;
render_mode blend_add, unshaded;
uniform vec4 color : source_color = vec4(1.0, 0.4, 0.1, 1.0);
uniform float time : hint_range(0.0, 100.0) = 0.0;

float hash21(vec2 p) {
	return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash21(i), hash21(i + vec2(1.0, 0.0)), f.x),
	           mix(hash21(i + vec2(0.0, 1.0)), hash21(i + vec2(1.0, 1.0)), f.x), f.y);
}

float fbm2(vec2 p) {
	float v = 0.0;
	float a = 0.5;
	for (int k = 0; k < 4; k++) {
		v += a * vnoise(p);
		p = p * 2.03 + 11.3;
		a *= 0.5;
	}
	return v;
}

float ridged(vec2 p) {
	float v = 0.0;
	float a = 0.5;
	for (int k = 0; k < 3; k++) {
		v += a * (1.0 - abs(vnoise(p) * 2.0 - 1.0));
		p = p * 2.11 + 5.7;
		a *= 0.5;
	}
	return v;
}

// Domain warping: вложенный fbm применяется к КООРДИНАТЕ, а не к значению.
// Превращает одну гладкую периодичную волну в органическое самоперекрывающееся
// поле. Это главное отличие от прежних шейдеров на голых sin/cos: синус
// идеально периодичен, глаз ловит это за ~200 мс и читает картинку как
// синтетическую (эффект из демосцены, а не «магия»).
float warped(vec2 p, float t) {
	vec2 q = vec2(fbm2(p + vec2(0.0, t * 0.25)),
	              fbm2(p + vec2(5.2, 1.3) - vec2(t * 0.2, 0.0)));
	vec2 r = vec2(fbm2(p + 3.0 * q + vec2(1.7, 9.2)),
	              fbm2(p + 3.0 * q + vec2(8.3, 2.8)));
	return fbm2(p + 2.2 * r);
}

// Профиль круга: 1 в центре, 0 у края. Эффект ДОЛЖЕН быть ярче к центру —
// равномерная яркость не имеет фокуса и читается как плоская наклейка.
float core(float d) {
	return pow(max(0.0, 1.0 - d), 1.6);
}



void fragment() {
	vec2 uv = UV;
	float d = length(uv - vec2(0.5)) * 2.0;
	if (d > 1.0) { discard; }
	vec2 p = vec2(uv.x * 3.0, uv.y * 2.2 - time * 0.9);
	float n = warped(p, time);
	float flame = pow(max(0.0, n * 1.35 - 0.18), 1.5);
	float body = core(d) * (0.45 + 0.85 * flame);
	// Тёмный ободок -> цвет сферы -> горячее ядро. НЕ чисто белый:
	// 0% и 100% в эффектах читаются как интерфейс, а не как магия.
	vec3 col = mix(color.rgb * 0.45, color.rgb, flame);
	col = mix(col, vec3(1.0, 0.86, 0.55), core(d) * 0.55);
	// Ядро выводим за 1.0 — hdr_2d превращает это в свечение.
	COLOR = vec4(col * body * 1.7, 1.0);
}"""


## Ice: a ridged texture gives sharp facets that fbm cannot.
static func _ice_shader() -> String:
	return """shader_type canvas_item;
render_mode blend_add, unshaded;
uniform vec4 color : source_color = vec4(0.2, 0.6, 1.0, 1.0);
uniform float time : hint_range(0.0, 100.0) = 0.0;

float hash21(vec2 p) {
	return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash21(i), hash21(i + vec2(1.0, 0.0)), f.x),
	           mix(hash21(i + vec2(0.0, 1.0)), hash21(i + vec2(1.0, 1.0)), f.x), f.y);
}

float fbm2(vec2 p) {
	float v = 0.0;
	float a = 0.5;
	for (int k = 0; k < 4; k++) {
		v += a * vnoise(p);
		p = p * 2.03 + 11.3;
		a *= 0.5;
	}
	return v;
}

float ridged(vec2 p) {
	float v = 0.0;
	float a = 0.5;
	for (int k = 0; k < 3; k++) {
		v += a * (1.0 - abs(vnoise(p) * 2.0 - 1.0));
		p = p * 2.11 + 5.7;
		a *= 0.5;
	}
	return v;
}

// Domain warping: вложенный fbm применяется к КООРДИНАТЕ, а не к значению.
// Превращает одну гладкую периодичную волну в органическое самоперекрывающееся
// поле. Это главное отличие от прежних шейдеров на голых sin/cos: синус
// идеально периодичен, глаз ловит это за ~200 мс и читает картинку как
// синтетическую (эффект из демосцены, а не «магия»).
float warped(vec2 p, float t) {
	vec2 q = vec2(fbm2(p + vec2(0.0, t * 0.25)),
	              fbm2(p + vec2(5.2, 1.3) - vec2(t * 0.2, 0.0)));
	vec2 r = vec2(fbm2(p + 3.0 * q + vec2(1.7, 9.2)),
	              fbm2(p + 3.0 * q + vec2(8.3, 2.8)));
	return fbm2(p + 2.2 * r);
}

// Профиль круга: 1 в центре, 0 у края. Эффект ДОЛЖЕН быть ярче к центру —
// равномерная яркость не имеет фокуса и читается как плоская наклейка.
float core(float d) {
	return pow(max(0.0, 1.0 - d), 1.6);
}



void fragment() {
	vec2 uv = UV;
	float d = length(uv - vec2(0.5)) * 2.0;
	if (d > 1.0) { discard; }
	vec2 p = uv * 4.0 + vec2(time * 0.2, -time * 0.35);
	float cr = ridged(p) * ridged(p * 1.7 + 3.3);
	float facet = pow(clamp(cr, 0.0, 1.0), 2.2);
	float body = core(d) * (0.3 + 1.1 * facet);
	vec3 col = mix(color.rgb * 0.5, color.rgb, facet);
	col = mix(col, vec3(0.85, 0.95, 1.0), core(d) * 0.6);
	COLOR = vec4(col * body * 1.5, 1.0);
}"""


## Lightning: branches from ridged noise + a thin hot channel. High contrast,
## a narrow band — otherwise it looks like a glowing spot rather than a discharge.
static func _lightning_shader() -> String:
	return """shader_type canvas_item;
render_mode blend_add, unshaded;
uniform vec4 color : source_color = vec4(0.8, 0.9, 1.0, 1.0);
uniform float time : hint_range(0.0, 100.0) = 0.0;

float hash21(vec2 p) {
	return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash21(i), hash21(i + vec2(1.0, 0.0)), f.x),
	           mix(hash21(i + vec2(0.0, 1.0)), hash21(i + vec2(1.0, 1.0)), f.x), f.y);
}

float fbm2(vec2 p) {
	float v = 0.0;
	float a = 0.5;
	for (int k = 0; k < 4; k++) {
		v += a * vnoise(p);
		p = p * 2.03 + 11.3;
		a *= 0.5;
	}
	return v;
}

float ridged(vec2 p) {
	float v = 0.0;
	float a = 0.5;
	for (int k = 0; k < 3; k++) {
		v += a * (1.0 - abs(vnoise(p) * 2.0 - 1.0));
		p = p * 2.11 + 5.7;
		a *= 0.5;
	}
	return v;
}

// Domain warping: вложенный fbm применяется к КООРДИНАТЕ, а не к значению.
// Превращает одну гладкую периодичную волну в органическое самоперекрывающееся
// поле. Это главное отличие от прежних шейдеров на голых sin/cos: синус
// идеально периодичен, глаз ловит это за ~200 мс и читает картинку как
// синтетическую (эффект из демосцены, а не «магия»).
float warped(vec2 p, float t) {
	vec2 q = vec2(fbm2(p + vec2(0.0, t * 0.25)),
	              fbm2(p + vec2(5.2, 1.3) - vec2(t * 0.2, 0.0)));
	vec2 r = vec2(fbm2(p + 3.0 * q + vec2(1.7, 9.2)),
	              fbm2(p + 3.0 * q + vec2(8.3, 2.8)));
	return fbm2(p + 2.2 * r);
}

// Профиль круга: 1 в центре, 0 у края. Эффект ДОЛЖЕН быть ярче к центру —
// равномерная яркость не имеет фокуса и читается как плоская наклейка.
float core(float d) {
	return pow(max(0.0, 1.0 - d), 1.6);
}



void fragment() {
	vec2 uv = UV;
	float d = length(uv - vec2(0.5)) * 2.0;
	if (d > 1.0) { discard; }
	vec2 p = vec2(uv.x * 3.0, uv.y * 1.2);
	float br = ridged(p * 2.0 + vec2(0.0, time * 1.4));
	float branch = pow(clamp(br, 0.0, 1.0), 6.0);
	float channel = pow(max(0.0, 1.0 - abs(uv.x - 0.5) * 3.2), 3.0);
	float flicker = 0.72 + 0.28 * fbm2(vec2(time * 6.0, 0.0));
	float body = (branch * 0.9 + channel * 0.8) * flicker * core(d);
	vec3 col = mix(color.rgb * 0.6, color.rgb, channel);
	col = mix(col, vec3(0.95, 0.98, 1.0), channel * 0.7);
	COLOR = vec4(col * body * 2.0, 1.0);
}"""


## Stone: cracks. Ridged noise with a threshold gives thin branching cracks
## that fbm cannot (its borders are too soft).
static func _stone_shader() -> String:
	return """shader_type canvas_item;
render_mode blend_add, unshaded;
uniform vec4 color : source_color = vec4(0.6, 0.4, 0.2, 1.0);
uniform float time : hint_range(0.0, 100.0) = 0.0;

float hash21(vec2 p) {
	return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash21(i), hash21(i + vec2(1.0, 0.0)), f.x),
	           mix(hash21(i + vec2(0.0, 1.0)), hash21(i + vec2(1.0, 1.0)), f.x), f.y);
}

float fbm2(vec2 p) {
	float v = 0.0;
	float a = 0.5;
	for (int k = 0; k < 4; k++) {
		v += a * vnoise(p);
		p = p * 2.03 + 11.3;
		a *= 0.5;
	}
	return v;
}

float ridged(vec2 p) {
	float v = 0.0;
	float a = 0.5;
	for (int k = 0; k < 3; k++) {
		v += a * (1.0 - abs(vnoise(p) * 2.0 - 1.0));
		p = p * 2.11 + 5.7;
		a *= 0.5;
	}
	return v;
}

// Domain warping: вложенный fbm применяется к КООРДИНАТЕ, а не к значению.
// Превращает одну гладкую периодичную волну в органическое самоперекрывающееся
// поле. Это главное отличие от прежних шейдеров на голых sin/cos: синус
// идеально периодичен, глаз ловит это за ~200 мс и читает картинку как
// синтетическую (эффект из демосцены, а не «магия»).
float warped(vec2 p, float t) {
	vec2 q = vec2(fbm2(p + vec2(0.0, t * 0.25)),
	              fbm2(p + vec2(5.2, 1.3) - vec2(t * 0.2, 0.0)));
	vec2 r = vec2(fbm2(p + 3.0 * q + vec2(1.7, 9.2)),
	              fbm2(p + 3.0 * q + vec2(8.3, 2.8)));
	return fbm2(p + 2.2 * r);
}

// Профиль круга: 1 в центре, 0 у края. Эффект ДОЛЖЕН быть ярче к центру —
// равномерная яркость не имеет фокуса и читается как плоская наклейка.
float core(float d) {
	return pow(max(0.0, 1.0 - d), 1.6);
}



void fragment() {
	vec2 uv = UV;
	float d = length(uv - vec2(0.5)) * 2.0;
	if (d > 1.0) { discard; }
	float cr = ridged(uv * 3.4 + vec2(time * 0.08, 0.0));
	float crack = pow(clamp(cr, 0.0, 1.0), 5.0);
	float dust = warped(uv * 2.6 + 4.4, time * 0.5);
	float body = core(d) * (0.25 + 1.3 * crack + 0.35 * dust);
	vec3 col = mix(color.rgb * 0.4, color.rgb, crack);
	col = mix(col, vec3(1.0, 0.88, 0.7), crack * 0.5);
	COLOR = vec4(col * body * 1.4, 1.0);
}"""


## Astral: a nebula from warped noise + real stars from a hash.
static func _astral_shader() -> String:
	return """shader_type canvas_item;
render_mode blend_add, unshaded;
uniform vec4 color : source_color = vec4(0.7, 0.3, 0.9, 1.0);
uniform float time : hint_range(0.0, 100.0) = 0.0;

float hash21(vec2 p) {
	return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash21(i), hash21(i + vec2(1.0, 0.0)), f.x),
	           mix(hash21(i + vec2(0.0, 1.0)), hash21(i + vec2(1.0, 1.0)), f.x), f.y);
}

float fbm2(vec2 p) {
	float v = 0.0;
	float a = 0.5;
	for (int k = 0; k < 4; k++) {
		v += a * vnoise(p);
		p = p * 2.03 + 11.3;
		a *= 0.5;
	}
	return v;
}

float ridged(vec2 p) {
	float v = 0.0;
	float a = 0.5;
	for (int k = 0; k < 3; k++) {
		v += a * (1.0 - abs(vnoise(p) * 2.0 - 1.0));
		p = p * 2.11 + 5.7;
		a *= 0.5;
	}
	return v;
}

// Domain warping: вложенный fbm применяется к КООРДИНАТЕ, а не к значению.
// Превращает одну гладкую периодичную волну в органическое самоперекрывающееся
// поле. Это главное отличие от прежних шейдеров на голых sin/cos: синус
// идеально периодичен, глаз ловит это за ~200 мс и читает картинку как
// синтетическую (эффект из демосцены, а не «магия»).
float warped(vec2 p, float t) {
	vec2 q = vec2(fbm2(p + vec2(0.0, t * 0.25)),
	              fbm2(p + vec2(5.2, 1.3) - vec2(t * 0.2, 0.0)));
	vec2 r = vec2(fbm2(p + 3.0 * q + vec2(1.7, 9.2)),
	              fbm2(p + 3.0 * q + vec2(8.3, 2.8)));
	return fbm2(p + 2.2 * r);
}

// Профиль круга: 1 в центре, 0 у края. Эффект ДОЛЖЕН быть ярче к центру —
// равномерная яркость не имеет фокуса и читается как плоская наклейка.
float core(float d) {
	return pow(max(0.0, 1.0 - d), 1.6);
}



void fragment() {
	vec2 uv = UV;
	float d = length(uv - vec2(0.5)) * 2.0;
	if (d > 1.0) { discard; }
	float neb = warped(uv * 2.2 + 9.1, time * 0.35);
	// Звёзды: хеш по ячейкам, яркие и редкие.
	vec2 gp = uv * 14.0;
	vec2 gi = floor(gp);
	float h = hash21(gi);
	float star = pow(max(0.0, 1.0 - length(fract(gp) - 0.5) * 2.0), 12.0)
		* step(0.86, h) * (0.6 + 0.4 * sin(time * 3.0 + h * 30.0));
	float body = core(d) * (0.3 + 1.0 * neb) + star * 1.4;
	vec3 col = mix(color.rgb * 0.4, color.rgb, neb);
	col = mix(col, vec3(0.95, 0.85, 1.0), star);
	COLOR = vec4(col * body * 1.5, 1.0);
}"""


## Aura ring: a soft rim with a noise break, brighter towards the ring centre.
static func _ring_shader() -> String:
	return """shader_type canvas_item;
render_mode blend_add, unshaded;
uniform vec4 color : source_color = vec4(1.0, 0.85, 0.4, 1.0);
uniform float time : hint_range(0.0, 100.0) = 0.0;

float hash21(vec2 p) {
	return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash21(i), hash21(i + vec2(1.0, 0.0)), f.x),
	           mix(hash21(i + vec2(0.0, 1.0)), hash21(i + vec2(1.0, 1.0)), f.x), f.y);
}

float fbm2(vec2 p) {
	float v = 0.0;
	float a = 0.5;
	for (int k = 0; k < 4; k++) {
		v += a * vnoise(p);
		p = p * 2.03 + 11.3;
		a *= 0.5;
	}
	return v;
}

float ridged(vec2 p) {
	float v = 0.0;
	float a = 0.5;
	for (int k = 0; k < 3; k++) {
		v += a * (1.0 - abs(vnoise(p) * 2.0 - 1.0));
		p = p * 2.11 + 5.7;
		a *= 0.5;
	}
	return v;
}

// Domain warping: вложенный fbm применяется к КООРДИНАТЕ, а не к значению.
// Превращает одну гладкую периодичную волну в органическое самоперекрывающееся
// поле. Это главное отличие от прежних шейдеров на голых sin/cos: синус
// идеально периодичен, глаз ловит это за ~200 мс и читает картинку как
// синтетическую (эффект из демосцены, а не «магия»).
float warped(vec2 p, float t) {
	vec2 q = vec2(fbm2(p + vec2(0.0, t * 0.25)),
	              fbm2(p + vec2(5.2, 1.3) - vec2(t * 0.2, 0.0)));
	vec2 r = vec2(fbm2(p + 3.0 * q + vec2(1.7, 9.2)),
	              fbm2(p + 3.0 * q + vec2(8.3, 2.8)));
	return fbm2(p + 2.2 * r);
}

// Профиль круга: 1 в центре, 0 у края. Эффект ДОЛЖЕН быть ярче к центру —
// равномерная яркость не имеет фокуса и читается как плоская наклейка.
float core(float d) {
	return pow(max(0.0, 1.0 - d), 1.6);
}



void fragment() {
	vec2 uv = UV;
	float d = length(uv - vec2(0.5)) * 2.0;
	if (d > 1.0) { discard; }
	float wob = (fbm2(uv * 3.0 + time * 0.6) - 0.5) * 0.10;
	float r = d + wob;
	float ring = 1.0 - smoothstep(0.0, 0.20, abs(r - 0.74));
	float halo = core(d) * 0.22;
	float body = (ring + halo) * (0.7 + 0.3 * warped(uv * 2.0, time));
	vec3 col = mix(color.rgb * 0.55, color.rgb, ring);
	col = mix(col, vec3(1.0, 0.95, 0.8), ring * 0.5);
	COLOR = vec4(col * body * 1.6, 1.0);
}"""


## Glow: radial with a bright core and HDR headroom. Without a value above 1.0
## it is just "a bright picture", not a glow — glow needs hdr_2d.
static func _glow_shader() -> String:
	return """shader_type canvas_item;
render_mode blend_add, unshaded;
uniform vec4 color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform float time : hint_range(0.0, 100.0) = 0.0;

float hash21(vec2 p) {
	return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash21(i), hash21(i + vec2(1.0, 0.0)), f.x),
	           mix(hash21(i + vec2(0.0, 1.0)), hash21(i + vec2(1.0, 1.0)), f.x), f.y);
}

float fbm2(vec2 p) {
	float v = 0.0;
	float a = 0.5;
	for (int k = 0; k < 4; k++) {
		v += a * vnoise(p);
		p = p * 2.03 + 11.3;
		a *= 0.5;
	}
	return v;
}

float ridged(vec2 p) {
	float v = 0.0;
	float a = 0.5;
	for (int k = 0; k < 3; k++) {
		v += a * (1.0 - abs(vnoise(p) * 2.0 - 1.0));
		p = p * 2.11 + 5.7;
		a *= 0.5;
	}
	return v;
}

// Domain warping: вложенный fbm применяется к КООРДИНАТЕ, а не к значению.
// Превращает одну гладкую периодичную волну в органическое самоперекрывающееся
// поле. Это главное отличие от прежних шейдеров на голых sin/cos: синус
// идеально периодичен, глаз ловит это за ~200 мс и читает картинку как
// синтетическую (эффект из демосцены, а не «магия»).
float warped(vec2 p, float t) {
	vec2 q = vec2(fbm2(p + vec2(0.0, t * 0.25)),
	              fbm2(p + vec2(5.2, 1.3) - vec2(t * 0.2, 0.0)));
	vec2 r = vec2(fbm2(p + 3.0 * q + vec2(1.7, 9.2)),
	              fbm2(p + 3.0 * q + vec2(8.3, 2.8)));
	return fbm2(p + 2.2 * r);
}

// Профиль круга: 1 в центре, 0 у края. Эффект ДОЛЖЕН быть ярче к центру —
// равномерная яркость не имеет фокуса и читается как плоская наклейка.
float core(float d) {
	return pow(max(0.0, 1.0 - d), 1.6);
}



void fragment() {
	vec2 uv = UV;
	float d = length(uv - vec2(0.5)) * 2.0;
	if (d > 1.0) { discard; }
	float n = warped(uv * 2.4, time * 0.5);
	float body = pow(max(0.0, 1.0 - d), 2.4) * (0.55 + 0.75 * n);
	vec3 col = mix(color.rgb * 0.6, color.rgb, n);
	COLOR = vec4(col * body * 2.2, 1.0);
}"""


static func _wall_shader() -> String:
	return """shader_type canvas_item;
uniform vec4 color : source_color = vec4(1.0, 0.4, 0.1, 1.0);
uniform float time : hint_range(0.0, 100.0) = 0.0;

void fragment() {
	vec2 uv = UV;
	// Языки пламени/камни: вертикальный градиент + шум, края рваные
	float rise = fract(uv.y * 2.0 - time * 1.4);
	float n = sin(uv.x * 14.0 + time * 3.0) * cos(uv.y * 9.0 - time * 2.0);
	float body = smoothstep(0.0, 0.35, uv.y) * smoothstep(1.0, 0.55, uv.y);
	float edge = smoothstep(0.0, 0.12, uv.x) * smoothstep(1.0, 0.88, uv.x);
	float a = body * edge * (0.55 + 0.45 * rise) * (0.75 + 0.25 * n);
	vec3 col = mix(color.rgb, vec3(1.0, 0.95, 0.7), rise * 0.5);
	COLOR = vec4(col, a * 0.85);
}"""


## Spell zone shaders. The style is chosen by a string, because there are three zones and
## their logic is the same (a rectangle + optional cell blocking).
## The shader code with render_mode substituted.
static func _zone_shader_with_mode(style: String) -> String:
	var mode := _zone_render_mode(style)
	var code := _zone_shader(style)
	if mode.is_empty():
		return code
	# render_mode MUST come after shader_type. Before it was substituted
	# as a prefix before "shader_type canvas_item;" — such a shader did not apply
	# at all, and the material drew a raw white 4×4 texture. Hence the "aura dots"
	# of 2–6 px in the previous version and the "white square over the whole figure" after
	# the sprites became normal size.
	#
	# We insert it after the type declaration rather than by line index: the shader texts
	# live in triple quotes, and the line break in the file may be either \n or
	# \r\n — comparing with "\n" broke on CRLF and gave TWO shader_type.
	const DECL := "shader_type canvas_item;"
	var at := code.find(DECL)
	if at >= 0:
		var cut := at + DECL.length()
		return code.substr(0, cut) + "\n" + mode + code.substr(cut).lstrip("\r\n")
	return DECL + "\n" + mode + code

## Render mode by zone style.
## Auras over a unit (shield, resistance, wind, cross) and fire shards
## are drawn as SELF-ILLUMINATION: unshaded + additive. Before they had no
## render_mode at all, that is they counted as lit — and there are almost no light
## sources in the scene, so ambient dimmed them by ~12 %, and on light grass a shield with
## alpha 0.22 disappeared entirely.
## Ground zones (wall/blizzard/cloud) stay blend_mix: they lie on the ground
## and must blend with it rather than burn through.
static func _zone_render_mode(style: String) -> String:
	match style:
		# The protection breeze blends with NORMAL alpha blending: the school colour
		# must stay a colour, while additive rings of four schools
		# added up into a white spot.
		"aura_breeze":
			return "render_mode blend_mix, unshaded;\n"
		"aura_shield", "aura_wind", "aura_bless", "heal_cross", "shard":
			return "render_mode blend_add, unshaded;\n"
		_:
			return ""


static func _zone_shader(style: String) -> String:
	match style:
		"hail":
			return """shader_type canvas_item;
uniform vec4 color : source_color = vec4(0.85, 0.94, 1.0, 1.0);
uniform float time : hint_range(0.0, 100.0) = 0.0;

void fragment() {
	// Метель: снежная крупа, полосы сносит ветром по диагонали.
	vec2 uv = UV;
	float w = uv.x * 6.0 - time * 1.6;
	float h = uv.y * 4.0 + time * 2.2;
	float flakes = sin(w * 6.2831) * sin(h * 6.2831);
	flakes = smoothstep(0.35, 0.95, flakes);
	// Холодное свечение у земли, прозрачное к верху.
	float ground = smoothstep(1.0, 0.35, uv.y);
	float a = flakes * (0.35 + 0.65 * ground);
	COLOR = vec4(color.rgb, a * 0.55);
}"""
		"shard":
			return """shader_type canvas_item;
uniform vec4 color : source_color = vec4(0.85, 0.94, 1.0, 1.0);
uniform float time : hint_range(0.0, 100.0) = 0.0;

void fragment() {
	// Осколок: вытянутый по вертикали кристалл с острыми краями.
	vec2 uv = UV;
	vec2 p = uv * 2.0 - 1.0;
	p.x *= 2.6;
	float body = 1.0 - smoothstep(0.25, 1.0, abs(p.x));
	float tip = 1.0 - smoothstep(0.6, 1.0, abs(p.y));
	float facet = 0.6 + 0.4 * sin(p.x * 8.0 + time * 6.0);
	float a = body * tip * facet;
	COLOR = vec4(color.rgb, a * 0.9);
}"""
		"cloud":
			return """shader_type canvas_item;
uniform vec4 color : source_color = vec4(0.55, 0.85, 0.42, 1.0);
uniform float time : hint_range(0.0, 100.0) = 0.0;

void fragment() {
	// Ядовитое облако: два слоя клубящегося шума, клубы ползут вверх.
	vec2 uv = UV;
	float n1 = sin(uv.x * 7.0 + time * 1.1) * cos(uv.y * 5.0 - time * 0.9);
	float n2 = sin(uv.x * 11.0 - time * 1.7) * cos(uv.y * 9.0 + time * 1.3);
	float f = 0.5 + 0.25 * n1 + 0.25 * n2;
	// Мягкий круглый край, чтобы облако не было прямоугольным баннером.
	vec2 d = uv - 0.5;
	float round = 1.0 - smoothstep(0.32, 0.5, length(d));
	float a = smoothstep(0.35, 0.9, f) * round;
	COLOR = vec4(color.rgb, a * 0.6);
}"""
		"aura_shield":
			return """shader_type canvas_item;
uniform vec4 color : source_color = vec4(0.72, 0.52, 1.0, 1.0);
uniform float time : hint_range(0.0, 100.0) = 0.0;

float hash21(vec2 p) {
	return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash21(i), hash21(i + vec2(1.0, 0.0)), f.x),
	           mix(hash21(i + vec2(0.0, 1.0)), hash21(i + vec2(1.0, 1.0)), f.x), f.y);
}

void fragment() {
	// Щит — ПРЕДМЕТ, а не сетка вокруг тела: геральдический силуэт
	// (прямой верх, сужение к нижнему острию), обод, умбон и пробегающий блик.
	// Сетка читалась как «магический пузырь» и была неотличима от других аур.
	vec2 p = UV - vec2(0.5);         // -0.5..0.5, y вниз
	float top = -0.40;
	float bottom = 0.46;
	float t = clamp((p.y - top) / (bottom - top), 0.0, 1.0);
	float halfw = 0.34 * (1.0 - pow(t, 2.4));
	if (p.y < top || p.y > bottom || abs(p.x) > halfw) {
		discard;
	}
	// Расстояние до кромки: по нему живёт обод.
	float d_edge = min(halfw - abs(p.x), min(p.y - top, bottom - p.y));
	float rim = 1.0 - smoothstep(0.0, 0.055, d_edge);
	// Поле щита: полупрозрачное, с медленно ползущими гранями металла.
	float facet = 0.5 + 0.5 * vnoise(vec2(p.x * 9.0, p.y * 6.0 - time * 0.55));
	// Умбон по центру и вертикальная насечка.
	float boss = 1.0 - smoothstep(0.0, 0.045, length(vec2(p.x, p.y + 0.02)) - 0.065);
	float bar = (1.0 - smoothstep(0.0, 0.022, abs(p.x)))
		* step(-0.28, p.y) * step(p.y, 0.30);
	// Блик, пробегающий по диагонали.
	float glint = smoothstep(0.0, 0.10, abs(fract((p.x - p.y) * 1.3 - time * 0.5) - 0.5) - 0.30);
	float body = 0.34 + 0.22 * facet;
	float m = clamp(body + rim * 0.95 + boss * 0.55 + bar * 0.30 + glint * 0.30, 0.0, 1.6);
	vec3 col = mix(color.rgb * 0.85, vec3(0.95, 0.90, 1.0), clamp(rim + boss * 0.5, 0.0, 1.0));
	COLOR = vec4(col * m * 1.5, 1.0);
}"""
		"aura_breeze":
			# Element protection: a LIGHT BREEZE AS A RING around the body in the school
			# colour. Before it was a 2–4 px icon above the head that also
			# swayed, and all four protections looked like the same dot.
			# The motion of the schools is DIFFERENT — that is the second channel of difference besides colour.
			return """shader_type canvas_item;
uniform vec4 color : source_color = vec4(1.0, 0.18, 0.12, 1.0);
uniform float time : hint_range(0.0, 100.0) = 0.0;
// Школа: 0 огонь, 1 вода, 2 воздух, 3 земля.
uniform int school : hint_range(0, 3) = 0;

void fragment() {
	vec2 p = UV - vec2(0.5);
	float r = length(p) * 2.0;        // эллипс: квад шире, чем выше
	float ang = atan(p.y, p.x);
	// Узкая дорожка обруча. Всё, что вне её, отбрасывается: тело юнита не
	// перекрываем, и в кадре остаются только штрихи ветра.
	float band = smoothstep(0.78, 0.86, r) * (1.0 - smoothstep(0.90, 0.98, r));
	if (band < 0.01) {
		discard;
	}
	// Штрихи, бегущие по кругу. Число штрихов 5–7: больше — и обруч
	// превращается в «ожерелье», глаз не успевает прочитать спокойный ветер.
	float dashes = 5.0;
	if (school == 1) {
		dashes = 6.0;
	} else if (school == 2) {
		dashes = 7.0;
	} else if (school == 3) {
		dashes = 6.0;
	}
	float speed = 0.55 - float(school) * 0.10;
	float u = ang / 6.2831 + 0.5;
	float t = fract(u * dashes - time * speed);
	float head = smoothstep(0.00, 0.18, t) * smoothstep(0.62, 0.42, t);
	float tail = smoothstep(0.18, 0.42, t) * smoothstep(0.72, 0.42, t) * 0.20;
	float m = band * clamp(head + tail, 0.0, 1.0);
	// Огонь поднимается вверх, земля оседает вниз: сдвиг яркости по вертикали.
	if (school == 0) {
		m *= 0.55 + 0.75 * clamp((0.5 - p.y) * 1.6, 0.0, 1.0);
	} else if (school == 3) {
		m *= 0.60 + 0.55 * clamp((p.y + 0.5) * 1.6, 0.0, 1.0);
	}
	if (m < 0.004) {
		discard;
	}
	float pulse = 0.90 + 0.10 * sin(time * 2.0);
	// Альфа-блендинг (blend_mix): струи должны быть ЦВЕТА ШКОЛЫ и не
	// выцветать в белое при наложении нескольких защит.
	vec3 col = mix(color.rgb * 0.85, color.rgb + vec3(0.12), m);
	float a = clamp(m * 1.15, 0.0, 0.86) * pulse;
	COLOR = vec4(col, a);
}"""
		"aura_bless":
			# Blessing: a small warm aura ABOVE THE HEAD. Before, Bless had
			# no permanent visual at all — the spell was applied and
			# the player did not see it (complaint 27.10).
			return """shader_type canvas_item;
uniform vec4 color : source_color = vec4(1.0, 0.86, 0.38, 1.0);
uniform float time : hint_range(0.0, 100.0) = 0.0;

void fragment() {
	vec2 p = UV - vec2(0.5);
	float r = length(p) * 2.0;
	// Ядро + мягкий нимб + шесть коротких лучей: читается как «освящение»,
	// а не как ещё одна точка. Центр не выжигаем до белого (правило VFX).
	float core = pow(max(0.0, 1.0 - r * 1.6), 2.4);
	float halo = 1.0 - smoothstep(0.55, 1.0, r);
	float ang = atan(p.y, p.x);
	float rays = pow(max(0.0, cos(ang * 6.0)), 24.0) * (1.0 - smoothstep(0.30, 1.0, r));
	float pulse = 0.82 + 0.18 * sin(time * 2.2);
	float m = (core * 1.15 + halo * 0.35 + rays * 0.55) * pulse;
	if (m < 0.02) {
		discard;
	}
	vec3 col = mix(color.rgb * 0.95, vec3(1.0, 0.96, 0.74), core);
	COLOR = vec4(col * m * 1.9, 1.0);
}"""
		"aura_wind":
			return """shader_type canvas_item;
uniform vec4 color : source_color = vec4(0.75, 1.0, 0.8, 1.0);
uniform float time : hint_range(0.0, 100.0) = 0.0;

void fragment() {
	// Ускорение: полосы ветра струятся мимо ног слева направо.
	vec2 uv = UV;
	float lane = floor(uv.y * 3.0);
	float speed = 1.6 + lane * 0.35;
	float streak = fract(uv.x * 2.0 - time * speed + lane * 0.37);
	float line = smoothstep(0.0, 0.12, streak) * smoothstep(0.42, 0.16, streak);
	// Гаснем по краям, чтобы полосы не обрезались квадратом.
	float edge = smoothstep(0.0, 0.18, uv.x) * smoothstep(1.0, 0.82, uv.x);
	float a = line * edge * 0.55;
	COLOR = vec4(color.rgb, a);
}"""
		"heal_cross":
			return """shader_type canvas_item;
uniform vec4 color : source_color = vec4(1.0, 0.3, 0.3, 1.0);
uniform float time : hint_range(0.0, 100.0) = 0.0;

void fragment() {
	// Лечение: красный крест, медленно вращается и пульсирует.
	vec2 p = UV - vec2(0.5, 0.5);
	float s = sin(time * 1.4);
	float c = cos(time * 1.4);
	p = vec2(p.x * c - p.y * s, p.x * s + p.y * c);
	float bar_h = step(abs(p.x), 0.10) * step(abs(p.y), 0.34);
	float bar_v = step(abs(p.y), 0.10) * step(abs(p.x), 0.34);
	float cross = clamp(bar_h + bar_v, 0.0, 1.0);
	float pulse = 0.75 + 0.25 * sin(time * 5.0);
	COLOR = vec4(color.rgb, cross * pulse * 0.95);
}"""
		_:
			return _wall_shader()
