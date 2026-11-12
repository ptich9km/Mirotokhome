extends CanvasLayer
class_name GameUI

@onready var spell_grid: GridContainer = $BottomPanel/SpellPanel/SpellGrid
@onready var bottom_panel: Control = $BottomPanel
@onready var spell_panel: Control = $BottomPanel/SpellPanel
@onready var pause_label: Label = $PauseLabel
@onready var coords_label: Label = $CoordsLabel
@onready var minimap_rect: ColorRect = $MinimapPanel/MinimapMargin/MinimapRect
@onready var hud_gold_label: Label = $HudSide/GoldRow/GoldLabel
@onready var hud_cmd_row: HBoxContainer = $HudSide/HudCmdRow

var show_coords := GameConfig.geti("debug", "show_coords") != 0
var cmd_buttons: Array = []

var minimap_camera: Camera2D
var alm_map = null
var player: Player

var minimap_image: Image
var minimap_texture: ImageTexture
var _minimap_base: Image = null   # cache of terrain + buildings (P3): we do not redraw every tick
var _minimap_map_id := 0          # id of the map _minimap_base was built for
var _minimap_size := Vector2.ZERO
var _minimap_timer := 0.0
var _fog_img: Image = null        # fog cache for the minimap (19.10)
var _fog_dirty := true
const MINIMAP_INTERVAL := 0.25
## HUD buttons by the minimap: a 175 px column, five 32 px buttons = 168 px.
## With text the minimum was 248 px and the row went off the right edge of the screen (23.10).
const HUD_CMD_SIZE := 32
const HUD_CMD_ICON_DIR := "res://assets/ui/hud/cmd/"
func setup_ui(p: Player):
	player = p

	_apply_hud_theme()
	_setup_spells()
	refresh_spell_book()

	var gold_icon := get_node_or_null("HudSide/GoldRow/GoldIcon") as TextureRect
	if gold_icon != null:
		var gp := LootIcons.gold_icon()
		if gp != "":
			gold_icon.texture = load(gp)

	alm_map = get_tree().get_first_node_in_group("alm_map")

	_setup_minimap()
	_setup_action_buttons()
	_layout_panels()
	get_tree().root.size_changed.connect(_layout_panels)
	_update_gold(int(player.gold) if player != null else 0)
	_update_bottom_panel_visibility()

## Adaptive layout: the right panel is anchored to the right in main.tscn,
## the bottom panels (magic/inventory) — centred in the game window at any resolution.
func _layout_panels() -> void:
	_update_bottom_panel_visibility()

# Spell panel with icons
const SPELL_CELL := 36              # spell cell = spellback.bmp (36x36)
const SPELL_COLS := 12              # columns in the book (same as the 12 grid in the tscn)
## Icon and cooldown veil inset inside a book cell: the art nearly touches the
## frame, as in the reference skill panels (WoW/Lineage/AION).
const BOOK_ICON_INSET := 2.0
## Sphere ids (Fire/Water/...) are data keys, the visible name lives in ui.json.
const SPHERE_KEY := {"Fire": "ui.sphere.Fire", "Water": "ui.sphere.Water",
	"Air": "ui.sphere.Air", "Earth": "ui.sphere.Earth", "Astral": "ui.sphere.Astral"}


static func _sphere_label(sphere_name: String) -> String:
	if SPHERE_KEY.has(sphere_name):
		return Loc.t(str(SPHERE_KEY[sphere_name]))
	return sphere_name
var spell_buttons: Array = []       # ALL cells (including the empty squares)
var _spell_buttons_filled: Array = []  # only cells with spells (aligned with names)
## "Book is empty" hint: the warrior's book is scrolls from the inventory, the
## mage's is learned spells. Without text the empty panel looked like "B does not
## open the menu" (2026-10-30).
var _book_empty_hint: Label = null
## spell -> last shown WHOLE number of cooldown seconds. The key exists so the
## nodes are not touched every frame: while the integer has not changed, the
## picture stays the same.
var _cd_shown: Dictionary = {}
var spells_visible: bool = true

func _setup_spells():
	if not spell_grid:
		print("WARNING: SpellGrid not found, skipping spell setup")
		return
	spell_grid.columns = SPELL_COLS
	spell_grid.add_theme_constant_override("h_separation", 2)
	spell_grid.add_theme_constant_override("v_separation", 2)

## Rebuild the spell book: always 2 rows of 12 cells = 24 book spells
## (order in docs/rom2-ref/spells.txt). Slot 1 (1st row, left cell) … slot 24
## (2nd row, 12th cell). Each spell icon is the canonical book icon
## (assets/spells/spell_NN.png, cut from spellbook.bmp). Learned — icon +
## a tooltip with the name; not learned — an empty spellback square with a tooltip
## saying which magic is learned here.
func refresh_spell_book() -> void:
	if not is_instance_valid(player):
		return
	for b in spell_buttons:
		if is_instance_valid(b):
			b.queue_free()
	spell_buttons.clear()
	_spell_buttons_filled.clear()
	_spell_button_names.clear()
	_cd_shown.clear()
	_clear_book_empty_hint()

	# WARRIOR: the book = scrolls from the inventory. A mage does NOT take scrolls here — they would
	# overwrite the book magic; for a mage a scroll lives in the inventory and on a hotkey.
	if not player.has_mana:
		_build_scroll_book()
		if spell_buttons.is_empty():
			_show_book_empty_hint(Loc.t("ui.book.empty_warrior"))
		_ensure_auto_status_label()
		_refresh_auto_status()
		return

	# The canonical table of 24 book spells: the order = the icon order
	# assets/spells/spell_NN.png (cut from spellbook.bmp, the book slot = index)
	var slots: Array = []
	for i in range(SpellDB.BOOK_SPELLS.size()):
		slots.append({
			"name": str(SpellDB.BOOK_SPELLS[i]),
			"icon": SpellDB.book_icon_path(i),
		})
	# Other learned spells (given by Sphere Books — e.g. Curse/Slow/Light)
	# go after the canonical 24, with the scroll icon from the database.
	for name in player.known_spells:
		if SpellDB.book_index(str(name)) < 0:
			var ch := player.spell_charges(str(name))
			if (player.has_mana and ch == -1) or (not player.has_mana and ch > 0):
				slots.append({"name": str(name), "icon": SpellDB.icon_of(str(name))})

	for s in slots:
		var name: String = str(s["name"])
		var ch := player.spell_charges(name)
		var known: bool = (player.has_mana and ch == -1) or (not player.has_mana and ch > 0)
		_make_spell_cell(name, str(s["icon"]), known)
	if spell_buttons.is_empty():
		_show_book_empty_hint(Loc.t("ui.book.empty_mage"))
	_ensure_auto_status_label()
	_refresh_auto_status()


## Hint in the middle of the book when there are no cells.
func _show_book_empty_hint(text: String) -> void:
	_clear_book_empty_hint()
	var lab := Label.new()
	lab.name = "BookEmptyHint"
	lab.text = text
	lab.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lab.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lab.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lab.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lab.add_theme_color_override("font_color", UiTheme.TEXT)
	lab.set_anchors_preset(Control.PRESET_FULL_RECT)
	spell_panel.add_child(lab)
	_book_empty_hint = lab


func _clear_book_empty_hint() -> void:
	if _book_empty_hint != null and is_instance_valid(_book_empty_hint):
		_book_empty_hint.queue_free()
	_book_empty_hint = null

## Shared look of a book cell (spell and scroll alike): a translucent dark slot,
## a warm hairline frame and a 2 px stripe of the sphere colour at the bottom —
## the stripe is how the player reads the school of magic.
##
## `flat` must stay FALSE on these buttons: in Godot 4 a flat button does not
## draw its stylebox in the normal state at all, so the icon floated bare above
## the panel while the "not learned" slots (plain PanelContainers) kept their
## background — two looks in one book (player report of 2026-10-30).
func _book_cell_style(accent: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(UiTheme.SLOT_BG.r, UiTheme.SLOT_BG.g, UiTheme.SLOT_BG.b, 0.88)
	style.set_border_width_all(UiTheme.BORDER_HAIRLINE)
	style.set_border_width(SIDE_BOTTOM, 2)
	style.border_color = accent.lerp(UiTheme.PANEL_EDGE.darkened(0.45), 0.4)
	style.set_corner_radius_all(UiTheme.RADIUS_SLOT)
	style.set_content_margin_all(UiTheme.SPACE_1)
	return style


## normal / hover / pressed / focus for a book cell. The focus box is set
## explicitly: without it the theme's generic frame was invisible on these cells,
## so a keyboard/gamepad user could not see where the cursor was.
func _apply_book_cell_styles(b: Button, accent: Color) -> void:
	var style := _book_cell_style(accent)
	b.add_theme_stylebox_override("normal", style)

	var hover := style.duplicate()
	hover.border_color = accent
	hover.bg_color = Color(UiTheme.PANEL_INNER.r, UiTheme.PANEL_INNER.g,
		UiTheme.PANEL_INNER.b, 0.92)
	b.add_theme_stylebox_override("hover", hover)

	var pressed := style.duplicate()
	pressed.bg_color = Color(UiTheme.BG_DEEP.r, UiTheme.BG_DEEP.g,
		UiTheme.BG_DEEP.b, 0.95)
	b.add_theme_stylebox_override("pressed", pressed)

	var focus := style.duplicate()
	focus.border_color = UiTheme.ACCENT
	focus.set_border_width_all(UiTheme.BORDER_FOCUS)
	b.add_theme_stylebox_override("focus", focus)


## Dark veil that recedes upwards as the cooldown runs out (WoW-style sweep).
## Added BEFORE the counters and labels so they stay readable on top of it.
func _add_cooldown_veil(b: Button) -> void:
	var veil := ColorRect.new()
	veil.name = "CooldownVeil"
	veil.color = Color(UiTheme.BG_DEEP.r, UiTheme.BG_DEEP.g, UiTheme.BG_DEEP.b, 0.55)
	veil.mouse_filter = Control.MOUSE_FILTER_IGNORE
	veil.set_anchors_preset(Control.PRESET_FULL_RECT)
	veil.offset_left = BOOK_ICON_INSET
	veil.offset_top = BOOK_ICON_INSET
	veil.offset_right = -BOOK_ICON_INSET
	veil.offset_bottom = -BOOK_ICON_INSET
	veil.visible = false
	b.add_child(veil)


## Seconds counter in the middle of a book cell. Scroll cells had no such label,
## so their cooldown ran silently while spell cells showed the number.
func _add_cooldown_label(b: Button) -> void:
	var cd := Label.new()
	cd.name = "Cooldown"
	cd.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	cd.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	cd.set_anchors_preset(Control.PRESET_FULL_RECT)
	cd.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cd.add_theme_font_size_override("font_size", UiTheme.FONT_SUBHEAD)
	cd.add_theme_color_override("font_color", UiTheme.TEXT_MUTED)
	cd.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	cd.add_theme_constant_override("outline_size", 4)
	cd.visible = false
	b.add_child(cd)


## Icon of a book cell. The texture is inset by 2 px so the art nearly touches
## the frame, as in the reference skill panels (WoW/Lineage/AION). A PNG that
## Godot never imported (a mod asset in user://) is loaded by hand.
func _book_cell_icon(b: Button, icon_path: String) -> TextureRect:
	if icon_path == "":
		return null
	var tex: Texture2D = null
	if ResourceLoader.exists(icon_path):
		tex = load(icon_path) as Texture2D
	elif FileAccess.file_exists(icon_path):
		# A PNG in user:// (a mod asset) is not imported by Godot: it is loaded by
		# hand, the same way the mods panel loads its preview.
		var img := Image.new()
		if img.load(icon_path) == OK:
			tex = ImageTexture.create_from_image(img)
	if tex == null:
		return null
	var ic := TextureRect.new()
	ic.texture = tex
	ic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	ic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	ic.set_anchors_preset(Control.PRESET_FULL_RECT)
	ic.offset_left = BOOK_ICON_INSET
	ic.offset_top = BOOK_ICON_INSET
	ic.offset_right = -BOOK_ICON_INSET
	ic.offset_bottom = -BOOK_ICON_INSET
	ic.mouse_filter = Control.MOUSE_FILTER_IGNORE
	b.add_child(ic)
	return ic


## Spell cell: a stripe of the sphere colour at the bottom; learned — icon,
## not learned — a dimmed frame with a hint of what is taught here.
func _make_spell_cell(name: String, icon: String, known: bool) -> void:
	var spell := SpellDB.get_spell(name)
	# Name through the helper: reading `.ru` directly kept the book Russian in the
	# English mode, and no scanner can see it - the field name "ru" is ASCII.
	var title := SpellDB.display_name(name)
	var sphere_name := SpellDB.sphere_of(name)
	var sphere := _sphere_label(sphere_name)
	var charges := player.spell_charges(name)
	var mana := SpellDB.mana_cost(name)
	var sphere_color: Color = UiKit.SPHERE_COLORS.get(sphere_name, Color(0.5, 0.5, 0.5))

	if not known:
		# Empty book slot: a dimmed border in the element colour
		var cell := PanelContainer.new()
		cell.custom_minimum_size = Vector2(SPELL_CELL, SPELL_CELL)
		var style := StyleBoxFlat.new()
		style.bg_color = Color(UiTheme.BG_DEEP.r, UiTheme.BG_DEEP.g, UiTheme.BG_DEEP.b, 0.88)
		style.border_color = sphere_color.darkened(0.5)
		style.set_border_width_all(1)
		style.set_corner_radius_all(UiTheme.RADIUS_SLOT)
		cell.add_theme_stylebox_override("panel", style)
		cell.tooltip_text = Loc.f("ui.magic.cell_locked", [title, sphere])
		spell_grid.add_child(cell)
		spell_buttons.append(cell)
		return

	var b := Button.new()
	b.custom_minimum_size = Vector2(SPELL_CELL, SPELL_CELL)
	b.focus_mode = Control.FOCUS_ALL
	_apply_book_cell_styles(b, sphere_color)

	# Icon of the spell from assets/spells; the veil goes right above it, all
	# counters are added after the veil and therefore stay legible.
	var ic := _book_cell_icon(b, icon)
	if ic != null:
		# Only the icon is dimmed on cooldown, not the whole button.
		b.set_meta("icon", ic)
	_add_cooldown_veil(b)

	# Tooltip: sphere, cost, damage/heal, radius, effect duration.
	b.tooltip_text = _spell_tooltip(name, title, sphere, charges, mana)

	# Charges left in the cell (readable above the icon).
	if charges > 0:
		var lbl := Label.new()
		lbl.text = str(charges)
		lbl.add_theme_font_size_override("font_size", UiTheme.FONT_MICRO)
		lbl.add_theme_color_override("font_color", UiTheme.ACCENT)
		lbl.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
		lbl.add_theme_constant_override("outline_size", 3)
		lbl.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
		lbl.offset_left = -18.0
		lbl.offset_top = -17.0
		lbl.offset_right = -1.0
		lbl.offset_bottom = -1.0
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		b.add_child(lbl)

	b.pressed.connect(func(sn: String = name): _cast_spell_button(sn))
	# RMB: make the spell "default" for the mage's auto-cast (package C).
	b.gui_input.connect(func(event: InputEvent, sn: String = name):
		if event is InputEventMouseButton and event.pressed \
				and event.button_index == MOUSE_BUTTON_RIGHT:
			if event is InputEventWithModifiers and event.alt_pressed:
				_cycle_auto_buff_tier()
			else:
				_toggle_auto_spell(sn)
			b.accept_event()
	)
	spell_grid.add_child(b)
	spell_buttons.append(b)
	_spell_buttons_filled.append(b)
	_spell_button_names.append(name)
	if Game.auto_spell == name:
		_mark_auto_spell_cell(b, name)
	_add_cooldown_label(b)
	_set_cooldown_visual(b, 0.0, Game.spell_cooldown(player, name))


## Sets the cooldown look of a book cell: `left` seconds, 0 = ready.
## Works for a non-positive `total` too (unknown duration): then the veil is
## shown fully for as long as the cooldown is on, instead of not at all —
## "no feedback" reads as a broken button.
func _set_cooldown_visual(b: Button, left: float, total: float) -> void:
	if not is_instance_valid(b):
		return
	var on := left > 0.0
	var t := 0.0
	if on:
		t = clampf(left / total, 0.0, 1.0) if total > 0.0 else 1.0
	var cd := b.get_node_or_null("Cooldown") as Label
	if cd != null:
		cd.visible = on
		# A whole number of seconds: "3" reads as "3 seconds left", while "2.7"
		# flickers and says nothing. We show ceil so as not to show 0
		# while there is a positive remainder.
		cd.text = str(int(ceil(left))) if on else ""

	# Veil recedes from the top: full height = full cooldown, zero = ready.
	var veil := b.get_node_or_null("CooldownVeil") as ColorRect
	if veil != null:
		veil.visible = on
		if on:
			var cell_h := b.size.y if b.size.y > 0.0 else float(SPELL_CELL)
			var inner := maxf(0.0, cell_h - 2.0 * BOOK_ICON_INSET)
			veil.offset_top = BOOK_ICON_INSET + inner * (1.0 - t)

	var icon_node: CanvasItem = null
	# The "icon" meta exists only on spell cells (scroll cells lacked it): without
	# this check Godot printed a C++ error "no 'meta' with key 'icon'" every frame
	# as soon as a scroll appeared in the warrior's book (2026-10-30).
	if b.has_meta("icon"):
		icon_node = b.get_meta("icon") as CanvasItem
	if icon_node != null:
		# A light fade that follows the veil: a jump from dark to bright once per
		# 3 seconds reads as "broken button" rather than "ready". Kept shallow
		# (0.35) because the veil already darkens the cell.
		icon_node.modulate = Color(1, 1, 1, 1.0 - 0.35 * t)


## Spell tooltip. Before it showed only name/sphere/charges/mana —
## it was impossible to understand what the spell does and how far it reaches.
func _spell_tooltip(spell_name: String, title: String, sphere: String, charges: int, mana: int) -> String:
	var spell := SpellDB.get_spell(spell_name)
	var lines: Array = [title, Loc.f("ui.magic.sphere_line", [sphere])]
	if charges > 0:
		lines.append(Loc.f("ui.magic.charges", [charges]))
	elif player.has_mana:
		lines.append(Loc.f("ui.magic.mana", [mana]))

	# Damage or healing including the hero's spell power
	var base := int(spell.get("damage", 0))
	if base > 0:
		lines.append(Loc.f("ui.magic.damage",
			[Game.spell_damage(player, spell_name, SpellDB.sphere_of(spell_name), base)]))
	elif base < 0:
		lines.append(Loc.f("ui.magic.heal",
			[Game.spell_damage(player, spell_name, SpellDB.sphere_of(spell_name), -base)]))

	var area := float(spell.get("area", 0))
	if area > 0.0:
		lines.append(Loc.f("ui.magic.radius", [area / 32.0]))
	var rng_range := float(spell.get("range", 0))
	if rng_range > 0.0:
		lines.append(Loc.f("ui.magic.range", [rng_range / 32.0]))
	var cd_total := Game.spell_cooldown(player, spell_name)
	if cd_total > 0.0:
		lines.append(Loc.f("ui.magic.cooldown", [cd_total]))
	if SpellDB.cast_time_of(spell_name) > 0.0:
		lines.append(Loc.f("ui.magic.cast_time", [SpellDB.cast_time_of(spell_name)]))

	var eff := SpellDB.effects_of(spell_name)
	if not eff.is_empty():
		lines.append(Loc.f("ui.magic.effects", [", ".join(_effect_labels(eff))]))
	return "\n".join(lines)


## Human-readable effect names for the tooltip.
func _effect_labels(effects: Array) -> Array:
	var out: Array = []
	for e in effects:
		var m := str((e as Dictionary).get("type", ""))
		var dur := float((e as Dictionary).get("duration", 0.0))
		var suffix := Loc.f("ui.magic.seconds", [dur]) if dur > 0.0 else ""
		match m:
			"shield": out.append(Loc.f("ui.effect.shield", [int((e as Dictionary).get("amount", 0)), suffix]))
			"resist": out.append(Loc.f("ui.effect.resist", [
				_sphere_label(str((e as Dictionary).get("sphere", ""))),
				int((e as Dictionary).get("amount", 0)), suffix]))
			"bless": out.append(Loc.f("ui.effect.bless", [suffix]))
			"haste": out.append(Loc.f("ui.effect.haste", [float((e as Dictionary).get("mult", 1.0)), suffix]))
			"slow": out.append(Loc.f("ui.effect.slow", [float((e as Dictionary).get("mult", 1.0)), suffix]))
			"curse": out.append(Loc.f("ui.effect.curse", [suffix]))
			"invisibility": out.append(Loc.f("ui.effect.invisibility", [suffix]))
			"vision": out.append(Loc.f("ui.effect.blind", [suffix]))
			"vampirism": out.append(Loc.f("ui.effect.vampirism",
				[int(float((e as Dictionary).get("ratio", 0.0)) * 100.0)]))
			"dot": out.append(Loc.f("ui.effect.poison", [int((e as Dictionary).get("dps", 0)), suffix]))
			"raise": out.append(Loc.t("ui.effect.raise"))
			_: out.append(m)
	return out

## Click on a spell in the book: as in the original — we enter targeting
## mode (an animated cast/ cursor), the magic flies only on a click
## on the target. Mana/charge are NOT deducted before hitting the target.
func _cast_spell_button(name: String) -> void:
	if Game.is_paused:
		return
	if not is_instance_valid(player):
		return
	_begin_spell_targeting(name)


## RMB on a spell: default auto-cast (usually Heal).
## A repeated RMB on the same one — removes it. The cell is highlighted with an ACCENT frame.
func _toggle_auto_spell(name: String) -> void:
	if Game.auto_spell == name:
		Game.auto_spell = ""
	else:
		Game.auto_spell = name
	# Highlight all book cells
	for i in range(_spell_buttons_filled.size()):
		var b = _spell_buttons_filled[i] as Button
		if b == null or i >= _spell_button_names.size():
			continue
		var sn := str(_spell_button_names[i])
		if Game.auto_spell == sn:
			_mark_auto_spell_cell(b, sn)
		else:
			_clear_auto_spell_mark(b)
	# The healing and buff target is now a single setting (Esc → Settings, "Magic"),
	# so RMB is no longer a cycle: it silently changed the auto-healing behaviour.
	_refresh_auto_status()


func _mark_auto_spell_cell(b: Button, name: String) -> void:
	if not is_instance_valid(b):
		return
	var title := SpellDB.display_name(name)
	var st := StyleBoxFlat.new()
	st.bg_color = UiTheme.SLOT_BG
	st.set_border_width_all(2)
	st.border_color = UiTheme.ACCENT
	st.set_corner_radius_all(UiTheme.RADIUS_SLOT)
	st.set_content_margin_all(UiTheme.SPACE_1)
	b.add_theme_stylebox_override("normal", st)
	b.set_meta("auto_spell", name)
	var badge := b.get_node_or_null("AutoBadge") as Label
	if badge == null:
		badge = Label.new()
		badge.name = "AutoBadge"
		badge.text = Loc.t("ui.magic.auto_badge")
		badge.add_theme_font_size_override("font_size", UiTheme.FONT_MICRO)
		badge.add_theme_color_override("font_color", UiTheme.ACCENT)
		badge.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
		badge.add_theme_constant_override("outline_size", 3)
		badge.set_anchors_preset(Control.PRESET_TOP_LEFT)
		badge.offset_left = 2.0
		badge.offset_top = 1.0
		badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
		b.add_child(badge)
	badge.visible = true
	b.tooltip_text = Loc.f("ui.magic.auto_tip", [title])


func _clear_auto_spell_mark(b: Button) -> void:
	if not is_instance_valid(b):
		return
	if b.has_meta("auto_spell"):
		b.remove_meta("auto_spell")
	var badge := b.get_node_or_null("AutoBadge")
	if badge != null:
		badge.visible = false


## Alt+RMB on the book: a quick cycle of the auto-magic level (without the settings window).
## base → medium → max → base. The target is changed in Esc → Settings, "Magic".
func _cycle_auto_buff_tier() -> void:
	match Game.auto_buff_tier:
		"base":
			Game.auto_buff_tier = "medium"
		"medium":
			Game.auto_buff_tier = "max"
		_:
			Game.auto_buff_tier = "base"
	_refresh_auto_status()


func _ensure_auto_status_label() -> void:
	if spell_panel == null:
		return
	if spell_panel.get_node_or_null("SpellAutoStatus") != null:
		return
	var lab := Label.new()
	lab.name = "SpellAutoStatus"
	lab.theme_type_variation = &"HudLabel"
	lab.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lab.add_theme_font_size_override("font_size", UiTheme.FONT_MICRO)
	lab.add_theme_color_override("font_color", UiTheme.ACCENT_DIM)
	lab.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lab.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	lab.offset_top = -18.0
	lab.offset_bottom = -2.0
	spell_panel.add_child(lab)


## --- Warrior book: scrolls from the inventory -----------------------------------------

## A warrior does not learn magic: their "book" is scrolls in the inventory. One cell per type,
## the inventory stays the owner (the scroll can be sold). A mage does not take scrolls here.
func _build_scroll_book() -> void:
	var seen: Array = []
	for raw in player.inventory:
		var key := str(raw)
		if seen.has(key):
			continue
		var item := ItemDB.find(key)
		if item.is_empty():
			# A scroll of a modded spell may have no item_db record (the shop and
			# loot build it from SpellDB). Dropping it here would make the book
			# silently disagree with the inventory, so it is rebuilt from the key.
			var known := SpellDB.spell_from_scroll(key)
			if known == "":
				continue
			item = {
				"key": key,
				"name_ru": key,
				"quality": "SuperScroll" if key.begins_with("SuperScroll ") else "Scroll",
				"icon": SpellDB.icon_of(known),
			}
		var q := str(item.get("quality", ""))
		if q != "Scroll" and q != "SuperScroll":
			continue
		seen.append(key)
		_make_scroll_cell(key, item, player.inventory.count(key))


## Scroll cell: item icon, remainder, auto-cast mark.
func _make_scroll_cell(item_key: String, item: Dictionary, count: int) -> void:
	var spell := SpellDB.spell_from_scroll(item_key)
	var sphere_name := SpellDB.sphere_of(spell)
	var sphere_color: Color = UiKit.SPHERE_COLORS.get(sphere_name, Color(0.5, 0.5, 0.5))
	var elven := CraftVFX.is_elven(item)

	var b := Button.new()
	b.custom_minimum_size = Vector2(SPELL_CELL, SPELL_CELL)
	b.focus_mode = Control.FOCUS_ALL
	b.set_meta("scroll_item", item_key)
	_apply_book_cell_styles(b, UiTheme.ACCENT if elven else sphere_color)

	var icon_path := str(item.get("icon", ""))
	var ic := _book_cell_icon(b, icon_path)
	if ic != null:
		CraftVFX.apply_elven(ic, item)
	_add_cooldown_veil(b)

	b.tooltip_text = Loc.f("ui.magic.item_tip", [ItemDB.display_name(item), count])

	var cnt := Label.new()
	cnt.text = str(count)
	cnt.add_theme_font_size_override("font_size", UiTheme.FONT_MICRO)
	cnt.add_theme_color_override("font_color", UiTheme.ACCENT)
	cnt.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
	cnt.add_theme_constant_override("outline_size", 3)
	cnt.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	cnt.offset_left = -18.0
	cnt.offset_top = -17.0
	cnt.offset_right = -1.0
	cnt.offset_bottom = -1.0
	cnt.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	cnt.mouse_filter = Control.MOUSE_FILTER_IGNORE
	b.add_child(cnt)

	if Game.auto_scroll_item == item_key:
		var mark := Label.new()
		mark.text = "A"
		mark.add_theme_font_size_override("font_size", UiTheme.FONT_MICRO)
		mark.add_theme_color_override("font_color", UiTheme.SUCCESS)
		mark.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
		mark.add_theme_constant_override("outline_size", 3)
		mark.set_anchors_preset(Control.PRESET_TOP_LEFT)
		mark.offset_left = 2.0
		mark.offset_top = 0.0
		mark.mouse_filter = Control.MOUSE_FILTER_IGNORE
		b.add_child(mark)

	b.pressed.connect(func(k: String = item_key): _begin_scroll_targeting(k))
	b.gui_input.connect(func(event: InputEvent, k: String = item_key):
		if event is InputEventMouseButton and event.pressed \
				and event.button_index == MOUSE_BUTTON_RIGHT:
			b.accept_event()
			_toggle_auto_scroll(k)
			return
		if event is InputEventKey and event.pressed and event.ctrl_pressed:
			# cast_1..3 are rebindable actions; keys 4..9 remain fixed.
			var slot := -1
			for i in range(3):
				if event.is_action_pressed("cast_%d" % (i + 1)):
					slot = i
			if slot < 0 and event.keycode >= KEY_4 and event.keycode <= KEY_9:
				slot = event.keycode - KEY_1
			if slot >= 0:
				Game.hotbar[slot] = {"kind": "item", "key": k}
				_notify_item_assigned(slot, k)
				b.accept_event()
	)
	spell_grid.add_child(b)
	spell_buttons.append(b)
	_spell_buttons_filled.append(b)
	_spell_button_names.append(spell)
	# The scroll's cooldown comes from the power stored inside it (50/100), not
	# from the hero: the same number the cast itself uses.
	_add_cooldown_label(b)
	_set_cooldown_visual(b, 0.0,
		Game.spell_cooldown(player, spell, SpellDB.scroll_power_of(item)))


## RMB on a scroll: the ONLY auto-cast, and self only.
func _toggle_auto_scroll(item_key: String) -> void:
	var spell := SpellDB.spell_from_scroll(item_key)
	if spell == "":
		return
	if Game.auto_scroll_item == item_key:
		Game.auto_scroll_item = ""
		call_deferred("refresh_spell_book")
		_refresh_auto_status()
		return
	var kind := SpellDB.kind_of(spell)
	if kind != "heal" and kind != "buff" and kind != "self":
		_flash_targeting_error(Loc.t("ui.magic.auto_self_only"))
		return
	Game.auto_scroll_item = item_key
	call_deferred("refresh_spell_book")
	_refresh_auto_status()


func _refresh_auto_status() -> void:
	_ensure_auto_status_label()
	var lab := get_node_or_null("BottomPanel/SpellPanel/SpellAutoStatus") as Label
	if lab == null:
		return
	var parts: Array = []
	if Game.auto_spell != "":
		parts.append(Loc.f("ui.auto.cast", [SpellDB.display_name(Game.auto_spell)]))
	if Game.auto_scroll_item != "":
		var it := ItemDB.find(Game.auto_scroll_item)
		parts.append(Loc.f("ui.auto.scroll", [ItemDB.display_name(it)]))
	parts.append(Loc.f("ui.auto.buffs", [_tier_name(Game.auto_buff_tier),
		_target_name(Game.auto_targets)]))
	lab.text = Loc.f("ui.auto.label", [" · ".join(parts)])


## Level and target names for the label and the settings window.
static func _tier_name(tier: String) -> String:
	match tier:
		"medium":
			return Loc.t("ui.auto.tier_medium")
		"max":
			return Loc.t("ui.auto.tier_max")
		_:
			return Loc.t("ui.auto.tier_basic")


static func _target_name(target: String) -> String:
	match target:
		"self":
			return Loc.t("ui.auto.target_self")
		"party_neutral":
			return Loc.t("ui.auto.target_self_all")
		_:
			return Loc.t("ui.auto.target_party")

# --- Targeting (a MAGE's scroll or a book spell) ---
# The targeting cursor is drawn by scripts/cursor_layer.gd (the cast variant) based
# on Game.pending_spell / Game.pending_scroll; it also hides the system cursor.

var _scroll_hint: Label = null
var _error_hint_timer: SceneTreeTimer = null

## A book spell is chosen: we wait for a target. The book closes, the cast cursor follows
## the mouse. The choice is cancelled with RMB/ESC, assigning to a digit — Ctrl+1..9.
func _begin_spell_targeting(name: String) -> void:
	if not is_instance_valid(player) or not player.can_cast(name):
		return
	_cancel_targeting()
	Game.pending_spell = {"name": name}
	Game._spell_targeting_frame = Engine.get_process_frames()
	spells_visible = false              # the book closes, the targeting cursor remains
	_update_bottom_panel_visibility()
	_update_targeting_hint(name, true)
	SoundDB.play("ui.book_open")  # ibook

## The spell was applied to the target (Game does it). Reset the mode + refresh the book.
func _finish_spell_targeting() -> void:
	_cancel_targeting()
	refresh_spell_book()
	_update_bottom_panel_visibility()
	if is_instance_valid(_inventory_panel) and _inventory_panel.has_method("_refresh_stats"):
		_inventory_panel._refresh_stats()

## Hotkey 1..9: enter targeting of the assigned spell.
func _quick_cast(spell: String) -> void:
	if Game.is_paused:
		return
	if not is_instance_valid(player) or not player.can_cast(spell):
		print("quick cast unavailable: " + spell)
		return
	_begin_spell_targeting(spell)

## Ctrl+N: the selected magic is assigned to a digit key (a label in the book +
## a tooltip). The selected spell stays active for targeting.
func _notify_hotbar_assigned(slot: int, spell: String) -> void:
	refresh_spell_book()
	if _scroll_hint != null and is_instance_valid(_scroll_hint):
		_scroll_hint.text = Loc.f("ui.hotbar.bound_scroll",
			[SpellDB.display_name(spell), slot + 1, slot + 1])
		_scroll_hint.visible = true

## Target selection error (the spell stays active): we show it on
## the tooltip, then return the usual tooltip text.
## Ctrl+N: the item under the cursor is assigned to a digit key (potion/scroll).
func _notify_item_assigned(slot: int, item_key: String) -> void:
	if _scroll_hint == null or not is_instance_valid(_scroll_hint):
		return
	var item := ItemDB.find(item_key)
	_scroll_hint.text = Loc.f("ui.hotbar.bound_item",
		[ItemDB.display_name(item), slot + 1, slot + 1])
	_scroll_hint.visible = true


func _flash_targeting_error(msg: String) -> void:
	if _scroll_hint != null and is_instance_valid(_scroll_hint):
		_scroll_hint.text = msg
		_scroll_hint.visible = true
	var timer := get_tree().create_timer(1.8)
	_error_hint_timer = timer
	timer.timeout.connect(_on_error_hint_timeout)

func _on_error_hint_timeout() -> void:
	if not Game.pending_spell.is_empty():
		_update_targeting_hint(str(Game.pending_spell.get("name", "")), true)
	elif not Game.pending_scroll.is_empty():
		_update_targeting_hint(str(Game.pending_scroll.get("spell", "")), true)
	elif _scroll_hint != null and is_instance_valid(_scroll_hint):
		_scroll_hint.visible = false

## The mage double-clicked a scroll in the inventory: we wait for target selection (cast cursor).
func _begin_scroll_targeting(item_key: String) -> void:
	var spell := SpellDB.spell_from_scroll(item_key)
	if spell == "" or not is_instance_valid(player):
		return
	Game.pending_scroll = {"spell": spell, "item_key": item_key}
	_update_targeting_hint(spell, true)
	SoundDB.play("ui.book_open")  # ibook

## The scroll was applied to the target (Game does it). Reset the mode + refresh the book.
func _finish_scroll_targeting() -> void:
	_cancel_targeting()
	refresh_spell_book()
	_update_bottom_panel_visibility()
	if is_instance_valid(_inventory_panel) and _inventory_panel.has_method("_refresh_stats"):
		_inventory_panel._refresh_stats()

## Cancel any targeting (scroll/magic): the charge is NOT spent, the targeting cursor
## is removed, the system cursor returns.
func _cancel_targeting() -> void:
	Game.pending_scroll = {}
	Game.pending_spell = {}
	Game._spell_targeting_frame = -1
	if _scroll_hint != null and is_instance_valid(_scroll_hint):
		_scroll_hint.visible = false

## Hint above the bottom panels: what to apply with the selected scroll/spell
## and how to cancel/assign a hotkey (as in the original).
func _update_targeting_hint(spell: String, on: bool) -> void:
	if _scroll_hint == null:
		_scroll_hint = Label.new()
		_scroll_hint.name = "ScrollHint"
		_scroll_hint.theme_type_variation = &"HudHint"
		_scroll_hint.add_theme_font_size_override("font_size", UiTheme.FONT_SUBHEAD)
		_scroll_hint.add_theme_color_override("font_color", UiTheme.ACCENT)
		_scroll_hint.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
		_scroll_hint.add_theme_constant_override("outline_size", 4)
		_scroll_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_scroll_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(_scroll_hint)
		_scroll_hint.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
		_scroll_hint.offset_top = -66.0
		_scroll_hint.offset_bottom = -42.0
	_scroll_hint.visible = on
	if not on:
		return
	# The target hint is taken from the database target field (enemy/ally/point/self),
	# not from kind — a debuff/raise targets an enemy, wall/self — a point/self.
	var target_kind := SpellDB.target_of(spell)
	var dir_text := ""
	match target_kind:
		"enemy":
			dir_text = Loc.t("ui.target.enemy")
		"point":
			dir_text = Loc.t("ui.target.enemy_or_point")
		"self":
			dir_text = Loc.t("ui.target.self")
		_:
			dir_text = Loc.t("ui.target.self_or_ally")
	_scroll_hint.text = Loc.f("ui.target.apply", [SpellDB.display_name(spell), dir_text])

func _apply_hud_theme() -> void:
	var theme := UiTheme.app_theme()
	theme.set_stylebox("normal", "Button", UiKit.button_style(
		UiTheme.PANEL_INNER, UiTheme.PANEL_EDGE.darkened(0.3),
		UiTheme.BORDER_HAIRLINE, UiTheme.RADIUS_SLOT, UiTheme.SPACE_1))
	theme.set_stylebox("hover", "Button", UiKit.button_style(
		UiTheme.PANEL_INNER.lightened(0.12), UiTheme.ACCENT_DIM,
		UiTheme.BORDER_HAIRLINE, UiTheme.RADIUS_SLOT, UiTheme.SPACE_1))
	theme.set_stylebox("pressed", "Button", UiKit.button_style(
		UiTheme.BG_DEEP, UiTheme.ACCENT_DIM,
		UiTheme.BORDER_HAIRLINE, UiTheme.RADIUS_SLOT, UiTheme.SPACE_1))
	theme.set_stylebox("focus", "Button", UiKit.button_style(
		UiTheme.TRANSPARENT, UiTheme.ACCENT,
		UiTheme.BORDER_FOCUS, UiTheme.RADIUS_SLOT, UiTheme.SPACE_1))
	UiKit.add_button(theme, &"HudCmd",
		UiTheme.PANEL_INNER, UiTheme.PANEL_EDGE.darkened(0.3),
		UiTheme.PANEL_INNER.lightened(0.12), UiTheme.ACCENT_DIM,
		UiTheme.RADIUS_SLOT, UiTheme.SPACE_1)
	UiKit.add_button(theme, &"HudCmdActive",
		UiTheme.PANEL_INNER.lightened(0.16), UiTheme.ACCENT,
		UiTheme.PANEL_INNER.lightened(0.20), UiTheme.ACCENT,
		UiTheme.RADIUS_SLOT, UiTheme.SPACE_1)
	theme.set_color("font_color", &"HudCmd", UiTheme.TEXT)
	theme.set_color("font_hover_color", &"HudCmd", UiTheme.ACCENT)
	theme.set_color("font_pressed_color", &"HudCmd", UiTheme.ACCENT)
	theme.set_color("font_focus_color", &"HudCmd", UiTheme.ACCENT)
	theme.set_color("font_color", &"HudCmdActive", UiTheme.BG_DEEP)
	theme.set_color("font_hover_color", &"HudCmdActive", UiTheme.BG_DEEP)
	theme.set_color("font_pressed_color", &"HudCmdActive", UiTheme.BG_DEEP)
	theme.set_color("font_focus_color", &"HudCmdActive", UiTheme.BG_DEEP)
	theme.set_font_size("font_size", &"HudCmd", UiTheme.FONT_MICRO)
	theme.set_font_size("font_size", &"HudCmdActive", UiTheme.FONT_MICRO)
	UiKit.add_label(theme, &"HudHint", UiTheme.ACCENT, UiTheme.FONT_MICRO)
	if is_instance_valid($HudSide):
		$HudSide.theme = theme
	if is_instance_valid(bottom_panel):
		bottom_panel.theme = theme
	if is_instance_valid(spell_panel):
		spell_panel.theme = theme


func _setup_action_buttons():
	if not is_instance_valid(hud_cmd_row):
		return
	# Compact row by the minimap. Stats are in the inventory now — there is no "Stats" button.
	var inv_btn := Button.new()
	inv_btn.name = "InvBtn"
	inv_btn.theme_type_variation = &"HudCmd"
	inv_btn.custom_minimum_size = Vector2(HUD_CMD_SIZE, HUD_CMD_SIZE)
	inv_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inv_btn.focus_mode = Control.FOCUS_ALL
	inv_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	inv_btn.tooltip_text = Loc.t("ui.hud.inventory_tip")
	_apply_cmd_icon(inv_btn, "inventory", Loc.t("ui.hud.inventory_short"))
	inv_btn.pressed.connect(open_inventory_panel)
	hud_cmd_row.add_child(inv_btn)

	var cmd_tips := [
		Loc.t("ui.order.follow"),
		Loc.t("ui.order.attack"),
		Loc.t("ui.order.guard"),
		Loc.t("ui.order.stop"),
	]
	# Short labels are ONLY a fallback if the PNG is missing: the button is
	# 32 px, a full label does not fit into it. The tooltip keeps the meaning.
	var cmd_short := [Loc.t("ui.order.short_follow"), Loc.t("ui.order.short_attack"),
		Loc.t("ui.order.short_guard"), Loc.t("ui.order.short_stop")]
	var cmd_modes := ["follow", "attack", "guard", "stop"]
	var cmd_icons := ["follow", "attack", "guard", "stop"]
	for i in range(cmd_tips.size()):
		var b := Button.new()
		b.name = "Cmd%d" % i
		b.custom_minimum_size = Vector2(HUD_CMD_SIZE, HUD_CMD_SIZE)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.theme_type_variation = &"HudCmd"
		b.focus_mode = Control.FOCUS_ALL
		b.tooltip_text = cmd_tips[i]
		b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		_apply_cmd_icon(b, cmd_icons[i], cmd_short[i])
		hud_cmd_row.add_child(b)
		cmd_buttons.append(b)
		b.pressed.connect(func(): _set_action_mode(cmd_modes[i]))
	coords_label.visible = false
	_set_action_mode(Game.action_mode if Game.action_mode != "" else "follow")


## HUD button icon. The label stays a fallback: if there is no PNG
## (a new machine/a build without art), the button does not become empty.
func _apply_cmd_icon(button: Button, icon_name: String, fallback_text: String) -> void:
	var path := "%s%s.png" % [HUD_CMD_ICON_DIR, icon_name]
	var tex: Texture2D = null
	if ResourceLoader.exists(path):
		var res = load(path)
		if res is Texture2D:
			tex = res
	if tex == null:
		button.text = fallback_text
		return
	button.text = ""
	button.icon = tex
	button.expand_icon = true
	button.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER

func _set_action_mode(mode: String):
	for i in range(cmd_buttons.size()):
		cmd_buttons[i].theme_type_variation = &"HudCmd"
		cmd_buttons[i].set_pressed_no_signal(false)

	var active := -1
	match mode:
		"follow":
			active = 0
			Game.action_mode = "follow"
		"attack":
			active = 1
			Game.action_mode = "attack"
		"guard":
			active = 2
			Game.action_mode = "guard"
		"stop":
			active = 3
			Game.action_mode = "stop"
	if active >= 0 and active < cmd_buttons.size():
		cmd_buttons[active].theme_type_variation = &"HudCmdActive"
		cmd_buttons[active].set_pressed_no_signal(true)

func _toggle_stats_view():
	# Stats are in the inventory now — no HUD toggle needed.
	pass

# --- Hover cards (styled, via UiKit.make_hover_card) ---------

var _item_card: PanelContainer = null
var _slot_card: PanelContainer = null

func _ensure_card(_kind: String) -> PanelContainer:
	var card := UiKit.make_hover_card(300.0)
	add_child(card)
	var theme := UiKit.base_theme()
	UiKit.add_hover_card_styles(theme)
	card.theme = theme
	return card

## Item card lines live in UiKit: inventory adds the class-restriction line.
func _item_card_lines(item: Dictionary) -> Array:
	return UiKit.item_card_lines(item)

## Item card on an inventory cell (mouse + focus).
func _attach_item_card(cell: Control, item: Dictionary) -> void:
	if not is_instance_valid(cell) or item.is_empty():
		return
	var icon_path := str(item.get("icon", ""))
	var qcolor := UiKit.quality_color(str(item.get("quality", "")))
	var tier := CraftVFX.tier_of_item(item)
	cell.mouse_entered.connect(func():
		if _item_card == null:
			_item_card = _ensure_card("item")
		UiKit.show_hover_card(_item_card, _item_card_lines(item),
			cell.global_position, _world_bounds(), icon_path, qcolor, tier))
	cell.mouse_exited.connect(func():
		if _item_card != null:
			UiKit.hide_hover_card(_item_card))
	cell.focus_entered.connect(func():
		if _item_card == null:
			_item_card = _ensure_card("item")
		UiKit.show_hover_card(_item_card, _item_card_lines(item),
			cell.global_position, _world_bounds(), icon_path, qcolor, tier))
	cell.focus_exited.connect(func():
		if _item_card != null:
			UiKit.hide_hover_card(_item_card))

## Equipment slot card: reads the worn item at the moment of hovering.
func _attach_slot_card(cell: Control, slot: String) -> void:
	if not is_instance_valid(cell):
		return
	cell.mouse_entered.connect(func(): _show_slot_card(cell, slot))
	cell.mouse_exited.connect(func(): _hide_slot_card())
	cell.focus_entered.connect(func(): _show_slot_card(cell, slot))
	cell.focus_exited.connect(func(): _hide_slot_card())

func _show_slot_card(cell: Control, slot: String) -> void:
	if not is_instance_valid(player):
		return
	var key := str(player.equipped.get(slot, ""))
	if key == "":
		_hide_slot_card()
		return
	var it := ItemDB.find(key)
	if it.is_empty():
		_hide_slot_card()
		return
	if _slot_card == null:
		_slot_card = _ensure_card("slot")
	var lines: Array = _item_card_lines(it)
	lines.append(Loc.f("ui.tip.slot_worn", [ItemDB.slot_title(slot)]))
	var icon_path := str(it.get("icon", ""))
	var qcolor := UiKit.quality_color(str(it.get("quality", "")))
	UiKit.show_hover_card(_slot_card, lines, cell.global_position, _world_bounds(),
		icon_path, qcolor, CraftVFX.tier_of_item(it))

func _hide_slot_card() -> void:
	if _slot_card != null:
		UiKit.hide_hover_card(_slot_card)
# --- World tooltips: hover + Alt -----------------------------------------------
## GDD 06.10: hover 0.6 s → the base (name+faction / building / loot);
## Alt → the full unit card (HP/combat/resists). LMB hold is not used.

const WORLD_HOVER_DELAY := 0.6
var _world_card: PanelContainer = null
var _world_hover_key := ""
var _world_hover_time := 0.0
var _world_card_shown := false
var _world_card_alt := false
var _world_hover_unit: Node2D = null


func _world_bounds() -> Vector2:
	var vp := get_viewport()
	if vp == null:
		return Vector2(1280, 800)
	return vp.get_visible_rect().size


func _update_world_tooltip(delta: float) -> void:
	if not is_instance_valid(player):
		return
	if is_editor_open():
		_reset_world_tooltip()
		return

	var target: Array = _world_hover_target()
	var key := str(target[0])
	var alt := Input.is_key_pressed(KEY_ALT)

	if key == "":
		_reset_world_tooltip()
		return

	if key != _world_hover_key:
		_world_hover_key = key
		_world_hover_time = 0.0
		_world_card_shown = false
		_world_card_alt = alt
		if _world_card != null and _world_card.visible:
			UiKit.hide_hover_card(_world_card)
		return

	_world_hover_time += delta
	if _world_hover_time < WORLD_HOVER_DELAY:
		return

	if _world_card_shown and alt == _world_card_alt:
		return
	# Alt switched the mode — rebuild the card
	if _world_card_shown:
		_world_card_shown = false
		if _world_card != null:
			UiKit.hide_hover_card(_world_card)
	if _world_card == null:
		_world_card = _ensure_card("world")

	var lines: Array = target[1]
	var is_unit := key.begins_with("u")
	if is_unit and alt:
		lines = _unit_tooltip_full(target)
	_world_card_alt = alt
	UiKit.show_hover_card(_world_card, lines,
		get_viewport().get_mouse_position(), _world_bounds())
	_world_card_shown = true


func _reset_world_tooltip() -> void:
	_world_hover_time = 0.0
	_world_hover_key = ""
	_world_card_shown = false
	_world_card_alt = false
	if _world_card != null and _world_card.visible:
		UiKit.hide_hover_card(_world_card)


## Full unit card (Alt): HP, damage, armour, resistances.
func _unit_tooltip_full(target: Array) -> Array:
	var lines: Array = target[1].duplicate()
	var e: Node2D = _world_hover_unit
	if e == null or not is_instance_valid(e):
		return lines
	var hp := 0
	if "max_hp" in e:
		hp = int(e.max_hp)
	elif "hp_max" in e:
		hp = int(e.hp_max)
	var cur := int(e.current_hp) if "current_hp" in e else hp
	if hp > 0:
		lines.append(Loc.f("ui.card.health", [cur, hp]))
	if e.has_method("get_attack"):
		lines.append(Loc.f("ui.card.attack", [int(e.call("get_attack"))]))
	if e.has_method("get_defense"):
		lines.append(Loc.f("ui.card.armour", [int(e.call("get_defense"))]))
	if e.has_method("get_absorption"):
		lines.append(Loc.f("ui.card.absorption", [int(e.call("get_absorption"))]))
	var set_name := str(e.anim_set) if "anim_set" in e else ""
	if set_name != "":
		var res: Array[String] = []
		for sphere in ["fire", "water", "air", "earth", "astral"]:
			var r := 0
			if e.has_method("get_protection_" + sphere):
				r = int(e.call("get_protection_" + sphere))
			elif e.has_method("resist_of"):
				r = int(UnitDB.resist_of(set_name, sphere))
			if r != 0:
				res.append("%s %d" % [sphere, r])
		if not res.is_empty():
			lines.append(Loc.f("ui.card.resist", [", ".join(res)]))
	return lines


## The target under the cursor: [key, lines]. "" — no target.
## Unit: the key "u…", the base — name+faction. Building/loot — hover without Alt.
func _world_hover_target() -> Array:
	var world := player.get_global_mouse_position()
	_world_hover_unit = null
	for e in Game.enemies + Game.npcs:
		if is_instance_valid(e) and Game.unit_hover_hit(e, world, 8.0):
			_world_hover_unit = e
			return [_unit_hover_key(e), _unit_tooltip_lines(e)]
	if alm_map and alm_map.map_width > 0:
		var ts: int = 32
		if "tile_size" in alm_map:
			ts = maxi(1, int(alm_map.tile_size))
		var cell := Vector2i(int(world.x) / ts, int(world.y) / ts)
		var h := _structure_at_world(cell, world, ts)
		if not h.is_empty():
			return ["b%d" % int(h.get("type_id", -1)), _building_tooltip_lines(h)]
	for lb in get_tree().get_nodes_in_group("loot"):
		if is_instance_valid(lb) and lb is LootDrop \
				and lb.global_position.distance_to(world) < 28.0:
			return ["l%d" % lb.get_instance_id(), _loot_tooltip_lines(lb)]
	return ["", []]


## Building: structure_at by cell + neighbours (a 3×3 footprint does not always cover
## the click point if the hitbox is wider than one cell).
func _structure_at_world(cell: Vector2i, _world: Vector2, _ts: int) -> Dictionary:
	if alm_map == null or not alm_map.has_method("structure_at"):
		return {}
	var direct: Dictionary = alm_map.structure_at(cell)
	if not direct.is_empty():
		return direct
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			if dx == 0 and dy == 0:
				continue
			var h: Dictionary = alm_map.structure_at(cell + Vector2i(dx, dy))
			if not h.is_empty():
				return h
	return {}


func _unit_hover_key(e: Node2D) -> String:
	return "u%d" % e.get_instance_id()


func _unit_tooltip_lines(e: Node2D) -> Array:
	var lines: Array = []
	var set_name := str(e.anim_set) if "anim_set" in e else ""
	var set_data := UnitDB.get_set(set_name)
	# `name_ru` — the human-readable set name (a Russian display name like "Vicious wolf", "Lord of wolves").
	# Before, only `desc` was taken here, and for Greys that is an English string like
	# "Monster wolf, Gemini Nano Banana strips…", that is the player saw service
	# text in the tooltip. It was not a fatal defect: the label was still
	# non-empty, and `set_name` as a fallback path did not trigger.
	var name := str(set_data.get("name_ru", ""))
	if name == "":
		name = str(set_data.get("desc", ""))
	if name == "":
		name = set_name.get_slice("/", 1) if "/" in set_name else set_name
	lines.append(name if name != "" else Loc.t("ui.card.creature"))
	lines.append(Loc.f("ui.card.faction", [_faction_of_set(set_name)]))
	return lines
func _building_tooltip_lines(h: Dictionary) -> Array:
	var lines: Array = []
	var sid := int(h.get("type_id", -1))
	var name := StructureDB.display_name_by_id(sid) if sid >= 0 else str(h.get("picture", ""))
	lines.append(name if name != "" else Loc.t("ui.card.building"))
	lines.append(Loc.t("ui.card.building"))
	return lines

func _loot_tooltip_lines(lb: LootDrop) -> Array:
	var lines: Array = [Loc.t("ui.card.loot")]
	var gold := 0
	var names: Array[String] = []
	for it in lb.items:
		if it is Dictionary:
			if it.has("gold"):
				gold += int(it.get("gold", 0))
			elif it.has("key"):
				var k := str(it.get("key", ""))
				names.append(str(ItemDB.find(k).get("name_ru", k)))
	if gold > 0:
		lines.append(Loc.f("ui.card.gold", [gold]))
	if not names.is_empty():
		lines.append(Loc.f("ui.card.items", [", ".join(names)]))
	if gold <= 0 and names.is_empty():
		lines.append(Loc.t("ui.card.empty"))
	return lines

## Faction by the unit's animation set (see §8.2 of AGENTS.md).
##
## The `humans/` and `heroes/` families (Allods II art) were removed on 11.10 together with
## the assets, and their branches were deleted: they would point into the void and substitute
## the label of a removed faction. The `rig/` branch is the pilot hero rig.
func _faction_of_set(set_name: String) -> String:
	# City sets city_* — the city race (09.10). The label must come from
	# lore world.json, otherwise the tooltip said "Passer-by".
	var city_race := MapGenerator.race_of_set(set_name)
	if city_race != "":
		var label := str(Lore.faction(city_race).get("label", ""))
		return label if label != "" else city_race
	if set_name.begins_with("ork_mage"):
		return Loc.t("ui.faction_name.ork")
	if set_name.begins_with("rig/"):
		return Loc.t("ui.faction_name.hero")
	for k in ["orc", "goblin", "troll", "ogre"]:
		if k in set_name:
			return Loc.t("ui.faction_name.ork")
	for k in ["skeleton", "zombie", "necromant", "ghost"]:
		if k in set_name:
			return Loc.t("ui.faction_name.necro")
	if "druid" in set_name:
		return Loc.t("ui.faction_name.druid")
	return Loc.t("ui.faction_name.grey")

func _setup_minimap():
	# Guard against a repeated call: before, setup_ui called this twice
	# (directly and via _setup_spells) — a duplicate MinimapTex node was created.
	if minimap_rect.get_node_or_null("MinimapTex") != null:
		return
	minimap_rect.color = Color(0, 0, 0, 0)  # MINIMAP transparent
	# TextureRect for the minimap: the size is set to the frame when drawing
	# (see _draw_minimap), so the picture does not spill out of MinimapRect.
	var tex_rect = TextureRect.new()
	tex_rect.name = "MinimapTex"
	tex_rect.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
	tex_rect.stretch_mode = TextureRect.STRETCH_SCALE
	minimap_rect.add_child(tex_rect)
	minimap_image = null
	_minimap_base = null
	minimap_texture = null
	# Fog (19.10): subscribing to the mask — the minimap fog layer
	# is redrawn only on change, not every tick.
	var fog_node: Node = get_tree().get_first_node_in_group("fog")
	if fog_node != null and not fog_node.updated.is_connected(_on_fog_updated):
		fog_node.updated.connect(_on_fog_updated)
	_fog_dirty = true

## Unit dots move, so the minimap is not fully static, but a full
## traversal of the whole map every frame (65k cells on Beach) is overkill. We update
## at a fixed step.
func _update_minimap(delta: float) -> void:
	_minimap_timer -= delta
	if _minimap_timer <= 0.0:
		_minimap_timer = MINIMAP_INTERVAL
		_draw_minimap()

## Rebind the minimap to the current map. The scene and the UI node live longer
## than one map (`_swap_map` on load slot/portal creates a new Map
## node), so the terrain and fog cache is reset: otherwise after loading
## a slot the minimap kept the map of the previous game.
func rebind_map() -> void:
	alm_map = get_tree().get_first_node_in_group("alm_map")
	_minimap_base = null
	_minimap_map_id = 0
	_fog_img = null
	_fog_dirty = true
	_minimap_timer = 0.0

func _draw_minimap():
	if not alm_map or not is_instance_valid(player):
		return

	var mw: int = alm_map.map_width
	var mh: int = alm_map.map_height
	if mw == 0:
		return

	# The drawing is square, but we fit it into the SMALLER side of the frame: before
	# the side was taken by height, while the frame was already smaller in width, and the picture
	# spilled 4 px out of the panel (23.10).
	var msize: Vector2 = minimap_rect.size
	var h := int(min(msize.x, msize.y))
	var w := h
	if h <= 0:
		return

	# First frame or a frame size change — recreate the image/texture.
	var square_size := Vector2(w, h)
	if minimap_image == null or minimap_texture == null or _minimap_size != square_size:
		_minimap_size = square_size
		minimap_image = Image.create(w, h, false, Image.FORMAT_RGBA8)
		minimap_texture = ImageTexture.create_from_image(minimap_image)
		_minimap_base = null
		var tex_rect := minimap_rect.get_node_or_null("MinimapTex")
		if tex_rect:
			tex_rect.offset_left = (msize.x - w) / 2.0
			tex_rect.offset_top = (msize.y - h) / 2.0
			tex_rect.offset_right = tex_rect.offset_left + w
			tex_rect.offset_bottom = tex_rect.offset_top + h

	var ptx: int = int(player.global_position.x) / alm_map.tile_size
	var pty: int = int(player.global_position.y) / alm_map.tile_size
	var scale_x := float(w) / float(mw)
	var scale_y := float(h) / float(mh)
	var fog_on := Game.fog != null and Game.fog.enabled

	# P3: terrain+buildings are cached; every tick we only copy the base + the dots.
	# The cache is tied to the map id: _swap_map substitutes the Map node, and without this
	# the "same size" check kept the old biome (report 23.10).
	var map_id: int = alm_map.get_instance_id()
	if _minimap_base != null and _minimap_map_id != map_id:
		_minimap_base = null
	if _minimap_base == null or _minimap_base.get_width() != w or _minimap_base.get_height() != h:
		_minimap_map_id = map_id
		_minimap_base = Image.create(w, h, false, Image.FORMAT_RGBA8)
		_minimap_base.fill(MINIMAP_BG)
		for ty in range(mh):
			for tx in range(mw):
				var color := _minimap_color_at(tx, ty)
				if color.a == 0.0:
					continue
				var sx := int(tx * scale_x)
				var sy := int(ty * scale_y)
				var ex := int((tx + 1) * scale_x)
				var ey := int((ty + 1) * scale_y)
				for py in range(sy, mini(ey + 1, h)):
					for px in range(sx, mini(ex + 1, w)):
						_minimap_base.set_pixel(px, py, color)
		# Buildings (grey 2×2 squares) — also into the base
		if alm_map.has_method("structure_at") and alm_map.map_width > 0:
			for ty in range(0, mh, 4):
				for tx in range(0, mw, 4):
					var struct: Dictionary = alm_map.structure_at(Vector2i(tx, ty))
					if not struct.is_empty():
						var sx2 := int(tx * scale_x)
						var sy2 := int(ty * scale_y)
						for dy in range(0, 2):
							for dx in range(0, 2):
								var xx := sx2 + dx; var yy := sy2 + dy
								if xx >= 0 and xx < w and yy >= 0 and yy < h:
									_minimap_base.set_pixel(xx, yy, MINIMAP_BUILDING)

	minimap_image.blit_rect(_minimap_base, Rect2(0, 0, w, h), Vector2.ZERO)

	# Fog layer (19.10): black and dimmed over the terrain.
	if fog_on:
		if _fog_dirty or _fog_img == null or _fog_img.get_width() != w:
			_rebuild_fog_layer(w, h)
		if _fog_img != null:
			minimap_image.blend_rect(_fog_img, Rect2(0, 0, w, h), Vector2.ZERO)

	# The player (a white dot)
	var px := int(ptx * scale_x)
	var py := int(pty * scale_y)
	for dy in range(-1, 2):
		for dx in range(-1, 2):
			var xx := px + dx; var yy := py + dy
			if xx >= 0 and xx < w and yy >= 0 and yy < h:
				minimap_image.set_pixel(xx, yy, MINIMAP_HERO)

	# Enemies (red dots)
	for enemy in Game.enemies:
		if is_instance_valid(enemy):
			var etx: int = int(enemy.global_position.x) / alm_map.tile_size
			var ety: int = int(enemy.global_position.y) / alm_map.tile_size
			var exx := int(etx * scale_x); var eyy := int(ety * scale_y)
			if fog_on and Game.fog.state_at(Vector2i(etx, ety)) < FogOfWar.STATE_VISIBLE:
				continue
			if exx >= 0 and exx < w and eyy >= 0 and eyy < h:
				minimap_image.set_pixel(exx, eyy, MINIMAP_ENEMY)

	# NPCs (yellow = neutral, green = allies/guards)
	for npc in Game.npcs:
		if is_instance_valid(npc):
			var ntx: int = int(npc.global_position.x) / alm_map.tile_size
			var nty: int = int(npc.global_position.y) / alm_map.tile_size
			var nxx := int(ntx * scale_x); var nyy := int(nty * scale_y)
			if fog_on and Game.fog.state_at(Vector2i(ntx, nty)) < FogOfWar.STATE_VISIBLE:
				continue
			if nxx >= 0 and nxx < w and nyy >= 0 and nyy < h:
				var nc: Color = MINIMAP_NPC_CIV
				if "role" in npc and str(npc.role) == "guard":
					nc = MINIMAP_NPC_GUARD
				minimap_image.set_pixel(nxx, nyy, nc)

	# Event/quest markers (19.10): always visible, over the fog.
	if MinimapMarkers.instance != null:
		_draw_minimap_markers(w, h, mw, mh)

	minimap_texture.update(minimap_image)
	var tex_rect2 := minimap_rect.get_node_or_null("MinimapTex")
	if tex_rect2:
		tex_rect2.texture = minimap_texture

## Minimap fog layer: a ready mini-image of the fog (1px/cell) from FogOfWar,
## scaled to the frame; rebuilt only on the updated signal (19.10).
func _rebuild_fog_layer(w: int, h: int) -> void:
	_fog_dirty = false
	if Game.fog == null or Game.fog.mini_img == null:
		_fog_img = null
		return
	_fog_img = Game.fog.mini_img.duplicate()
	_fog_img.resize(w, h, Image.INTERPOLATE_NEAREST)

func _on_fog_updated() -> void:
	_fog_dirty = true

## Event and future quest markers: a 3x3 cross, over the fog
## (player's decision — markers are always visible). Combat pulses,
## and blinks in the last stretch of its life.
func _draw_minimap_markers(w: int, h: int, mw: int, mh: int) -> void:
	var sx := float(w) / float(mw)
	var sy := float(h) / float(mh)
	var blink := (Time.get_ticks_msec() / 400) % 2 == 0
	for m in MinimapMarkers.instance.all_for(Game.map_seed, Game.map_zone, Game.map_sector):
		var cx := int(int(m["cell_x"]) * sx)
		var cy := int(int(m["cell_y"]) * sy)
		var col: Color
		if int(m["kind"]) == MinimapMarkers.Kind.BATTLE:
			if float(m["ttl_left"]) < 20.0 and blink:
				continue
			col = MINIMAP_BATTLE if blink else MINIMAP_BATTLE_FADE
		else:
			col = MINIMAP_QUEST
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				if absi(dx) + absi(dy) > 1:
					continue
				var xx := cx + dx
				var yy := cy + dy
				if xx >= 0 and xx < w and yy >= 0 and yy < h:
					minimap_image.set_pixel(xx, yy, col)
# Minimap colours: game data (biomes/units), not the UI panel palette.
const MINIMAP_NPC_GUARD := Color(0.2, 0.8, 0.2, 1.0)
const MINIMAP_NPC_CIV := Color(1.0, 0.85, 0.2, 1.0)
const MINIMAP_ENEMY := Color(1.0, 0.2, 0.2, 1.0)
const MINIMAP_BUILDING := Color(0.5, 0.45, 0.4, 1.0)
const MINIMAP_HERO := Color(1, 1, 1, 1)
## Quest markers: battle pulse and head "!" dot (game data, not the UI palette).
const MINIMAP_BATTLE := Color(1.0, 0.25, 0.15, 1.0)
const MINIMAP_BATTLE_FADE := Color(0.75, 0.1, 0.1, 1.0)
const MINIMAP_QUEST := Color(1.0, 0.75, 0.1, 1.0)
const MINIMAP_BG := Color(0.03, 0.03, 0.04, 1.0)
const MINIMAP_CUSTOM := {  # MINIMAP biome colors
	1: Color(0.55, 0.35, 0.15, 1.0),    # MINIMAP soil
	2: Color(0.85, 0.80, 0.50, 1.0),    # MINIMAP sand
	3: Color(0.15, 0.35, 0.75, 1.0),    # MINIMAP water
	4: Color(0.45, 0.42, 0.40, 1.0),    # MINIMAP mountains
	5: Color(0.60, 0.50, 0.35, 1.0),    # MINIMAP road
	6: Color(0.30, 0.22, 0.12, 1.0),    # MINIMAP mud
	7: Color(0.45, 0.3, 0.2, 1.0),      # MINIMAP building
	8: Color(1.0, 0.85, 0.2, 1.0),      # MINIMAP spawn
	0: Color(0.25, 0.55, 0.25, 1.0),    # MINIMAP grass
}
const MINIMAP_ALM := {  # MINIMAP biome colors
	2: Color(0.15, 0.35, 0.75, 1.0),    # MINIMAP water
	1: Color(0.52, 0.48, 0.42, 1.0),    # MINIMAP mountains
	3: Color(0.7, 0.65, 0.55, 1.0),     # MINIMAP road
	4: Color(0.50, 0.35, 0.18, 1.0),    # MINIMAP soil
	5: Color(0.85, 0.70, 0.22, 1.0),    # MINIMAP sand
	6: Color(0.22, 0.15, 0.08, 1.0),    # MINIMAP mud
	0: Color(0.25, 0.55, 0.25, 1.0),    # MINIMAP grass
}

# Cell colour for the minimap: CustomMap -> type (0-8), .alm -> terrain_type
func _minimap_color_at(tx: int, ty: int) -> Color:
	if alm_map is CustomMap:
		var t: int = alm_map.tile_id_at(Vector2i(tx, ty))
		if MINIMAP_CUSTOM.has(t):
			return MINIMAP_CUSTOM[t]
		return Color(0, 0, 0, 0)  # MINIMAP empty
	var t2: int = alm_map.cell_type_at(tx, ty)
	if MINIMAP_ALM.has(t2):
		return MINIMAP_ALM[t2]
	return MINIMAP_ALM[0]

func update_ui(p: Player, delta: float = 0.0):
	if not is_instance_valid(p):
		return
	_update_world_tooltip(delta)

	# Debug coordinates: hero position, cursor, cell, tile and walkability.
	if show_coords:
		var lines := "COORDS\n"
		lines += "Hero: %d, %d px\n" % [int(p.global_position.x), int(p.global_position.y)]
		var mouse := get_viewport().get_mouse_position()
		var world := p.get_global_mouse_position() if p.has_method("get_global_mouse_position") else Vector2.ZERO
		lines += "Mouse: %d, %d px\n" % [int(mouse.x), int(mouse.y)]
		if alm_map:
			var ts: int = alm_map.tile_size
			var ts_f := float(ts)
			var tc := Vector2i(floori(p.global_position.x / ts_f), floori(p.global_position.y / ts_f))
			var mc := Vector2i(floori(world.x / ts_f), floori(world.y / ts_f))
			lines += "Hero cell: %d, %d\n" % [tc.x, tc.y]
			lines += "Mouse cell: %d, %d\n" % [mc.x, mc.y]
			var walk_h: bool = alm_map.is_walkable_world(p.global_position)
			lines += "Hero walkable: %s\n" % ("yes" if walk_h else "NO")
			var walk_m: bool = alm_map.is_walkable_world(world)
			lines += "Mouse walkable: %s\n" % ("yes" if walk_m else "NO")
			if mc.x >= 0 and mc.y >= 0 and mc.x < alm_map.map_width and mc.y < alm_map.map_height:
				var t: int = alm_map.cell_type_at(mc.x, mc.y)
				# Mountains and water are IMPASSABLE since 05.10 (WalkTable.walkable), before
				# "passable, slow" stood here — the debug tooltip lied.
				var names := ["Grass (tile1)", "Mountains (tile2 - impassable)",
					"Water (tile3 - impassable)", "Road (tile4)"]
				lines += "Mouse tile: %s\n" % (names[t] if t >= 0 and t < names.size() else str(t))
				if not walk_m and alm_map.has_method("blocked_reason"):
					var reason: String = alm_map.call("blocked_reason", mc)
					if reason != "":
						lines += "Occupied: %s\n" % reason
				if alm_map.has_method("flag_at_world"):
					var fl: int = alm_map.flag_at_world(world)
					lines += "Flag: %d (0 ground/1 hill/2 water/3 heights/4 barrier)\n" % fl
		coords_label.text = lines

	# Highlighting book buttons: available/not enough mana or charges
	for i in range(_spell_buttons_filled.size()):
		var button = _spell_buttons_filled[i] as Button
		if button == null:
			continue
		if i < _spell_button_names.size():
			var sn: String = str(_spell_button_names[i])
			var scroll_key := str(button.get_meta("scroll_item", ""))
			if scroll_key != "":
				# Warrior scroll: available while it is in the inventory and not on cooldown.
				var have := player.has_item(scroll_key)
				var cd_left := float(player.cast_cooldowns.get(sn, 0.0))
				var usable := have and cd_left <= 0.0 and player.state != "casting"
				button.modulate = Color.WHITE if usable else Color(1, 1, 1, 0.45)
				button.disabled = not usable
			elif player.can_cast(sn):
				button.modulate = Color.WHITE
				button.disabled = false
			else:
				button.modulate = Color(1, 1, 1, 0.45)
				button.disabled = true
		else:
			button.modulate = Color(1, 1, 1, 0.3)

	_update_minimap(delta)

var _spell_button_names: Array = []

func _process(_delta):
	if not Game.perf_enabled:
		_process_impl(_delta)
		return
	var t0 := Time.get_ticks_usec()
	_process_impl(_delta)
	Game.perf_end("ui", t0)


func _process_impl(_delta):
	if Game.is_paused:
		pause_label.visible = true
		pause_label.text = Loc.t("ui.hud.pause")
	else:
		pause_label.visible = false

	# Cooldown countdown in the magic book. Before, the cooldown was only in the
	# tooltip, and the player spammed keys without understanding why the spell does not
	# trigger. We update every frame, but only when something changed:
	# 24 cells, looping over them needlessly is extra work in every frame.
	_update_cooldowns()

	# The "Auto-magic" label is updated only when the settings change: they are changed
	# either in Esc → Settings (the "Magic" section) or with Alt+RMB on the book.
	if _auto_shown_tier != Game.auto_buff_tier or _auto_shown_target != Game.auto_targets \
			or _auto_shown_spell != Game.auto_spell:
		_auto_shown_tier = Game.auto_buff_tier
		_auto_shown_target = Game.auto_targets
		_auto_shown_spell = Game.auto_spell
		_refresh_auto_status()


var _auto_shown_tier := ""
var _auto_shown_target := ""
var _auto_shown_spell := ""


func _update_cooldowns() -> void:
	if not is_instance_valid(player):
		return
	for i in range(_spell_buttons_filled.size()):
		var b := _spell_buttons_filled[i] as Button
		if not is_instance_valid(b):
			continue
		var spell_name := str(_spell_button_names[i])
		var left := float(player.cast_cooldowns.get(spell_name, 0.0))
		# Count rounded seconds: showing "0.3 s" is pointless.
		var shown := int(ceil(left))
		# Cache per CELL, not per spell: two scrolls of the same spell (Scroll Heal
		# and SuperScroll Heal) carry different power and therefore different
		# cooldowns — a shared key kept the second cell frozen at the first value.
		var cell_key := str(b.get_instance_id())
		if shown == _cd_shown.get(cell_key, -1):
			continue
		_cd_shown[cell_key] = shown
		# The cooldown ring must match the CALCULATION: for a scroll it is the
		# magic power inside it (50/100), for a spell — the sphere skill and mind.
		var scroll_key := str(b.get_meta("scroll_item", ""))
		var total := Game.spell_cooldown(player, spell_name)
		if scroll_key != "":
			total = Game.spell_cooldown(player, spell_name,
				SpellDB.scroll_power_of(ItemDB.find(scroll_key)))
		_set_cooldown_visual(b, left, total)

func toggle_spells():
	spells_visible = !spells_visible
	# The book is only a view of the inventory (warrior) or of the learned spells
	# (mage), so it is rebuilt on every open: a scroll bought in a shop must show
	# up without a world reload (player report of 2026-10-30: "bought 4 scrolls,
	# the book shows 2").
	if spells_visible:
		refresh_spell_book()
	_update_bottom_panel_visibility()

## Magic (B) — the bottom panel. The inventory is a modal window now.
func _update_bottom_panel_visibility():
	spell_panel.visible = spells_visible
	bottom_panel.visible = spells_visible
	if not spells_visible:
		return

	# BottomPanel is centred by anchors (anchor_left=0.5, anchor_right=0.5),
	# the 720px width is set by offset_left=-360, offset_right=360 in the tscn.
	# Here only the vertical position (bottom-up from the bottom edge).
	var vh := get_viewport().get_visible_rect().size.y

	var n := spell_buttons.size()
	if n <= 0:
		n = 12
	var rows := maxi(1, ceili(float(n) / float(SPELL_COLS)))
	var spell_h := clampf(10.0 + rows * (SPELL_CELL + 2.0), 90.0, 230.0)

	var book_w := 480.0
	spell_panel.offset_left = (720.0 - book_w) / 2.0
	spell_panel.offset_right = spell_panel.offset_left + book_w
	spell_panel.offset_top = 0.0
	spell_panel.offset_bottom = spell_h
	bottom_panel.offset_top = vh - spell_h
	bottom_panel.offset_bottom = vh

# --- Economy (P0): shop / school / tavern panels ---

var _shop: ShopPanel = null
var _alchemy: AlchemyPanel = null
var _school: SchoolPanel = null
var _inn: InnPanel = null
var _archmage: ArchmagePanel = null
var _quests: QuestPanel = null
var _world_map = null
var _workshop: WorkshopPanel = null
var _inventory_panel: InventoryPanel = null
var _interior_pos := Vector2.ZERO   # the hero's position before entering the building
var _in_interior := false
## HUD nodes we hide during an interior. Before they stayed visible:
## "water" and world objects were visible around the modal window, and the "Close"
## button of the interior landed in the inventory strip.
const _HUD_NODES := ["BottomPanel", "MinimapPanel", "HudSide", "CoordsLabel", "PauseLabel"]

## Entering a building: the hero "goes inside" (hidden on the map), comes out on close.
func _enter_interior() -> void:
	if not is_instance_valid(player):
		return
	if not Game.pending_scroll.is_empty() or not Game.pending_spell.is_empty():
		_cancel_targeting()   # no targeting needed inside a building
	_interior_pos = player.global_position
	player.stop_movement()          # does not "gallop off" after the old target while in the menu
	player.visible = false
	_in_interior = true
	for path in _HUD_NODES:
		var node: Control = get_node_or_null(path) as Control
		if node != null:
			node.visible = false

func _exit_interior() -> void:
	if not _in_interior:
		return
	_in_interior = false
	for path in _HUD_NODES:
		var node2: Control = get_node_or_null(path) as Control
		if node2 != null:
			node2.visible = true
	if is_instance_valid(player):
		player.visible = true
		# Exit point: the original position, but on a WALKABLE cell (not "inside a building")
		player.global_position = _clamp_to_walkable(_interior_pos)
		player.reset_physics_interpolation()
	# Autosave after leaving the building: the player could spend minutes in the shop.
	_request_autosave()


func _request_autosave() -> void:
	var scene := get_tree().current_scene
	if scene != null and scene.has_method("autosave_now"):
		scene.call("autosave_now")

## The nearest walkable point next to the requested one (a spiral over the cells).
func _clamp_to_walkable(from: Vector2) -> Vector2:
	var map_node = get_tree().get_first_node_in_group("alm_map")
	if map_node == null or not map_node.has_method("is_walkable_world"):
		return from
	if map_node.is_walkable_world(from):
		return from
	var cell := Vector2i(int(from.x) / 32, int(from.y) / 32)
	for r in range(1, 5):
		for dy in range(-r, r + 1):
			for dx in range(-r, r + 1):
				if abs(dx) != r and abs(dy) != r:
					continue
				var p := Vector2((cell.x + dx) * 32 + 16, (cell.y + dy) * 32 + 16)
				if map_node.is_walkable_world(p):
					return p
	return from

## Shared close handler for any panel: show the hero by the building.
func _on_panel_closed() -> void:
	Game.cursor_context = ""   # the cursor back to normal
	_shop = null
	_alchemy = null
	_school = null
	_inn = null
	_workshop = null
	_inventory_panel = null
	_archmage = null
	_quests = null
	_exit_interior()

## Close all open interior panels (loading a slot of another hero:
## an open paper-doll would show the class/inventory of the previous character).
func close_all_panels() -> void:
	var panels: Array = [_shop, _alchemy, _school, _inn, _workshop,
		_inventory_panel, _archmage, _quests, _world_map]
	for p in panels:
		if not is_instance_valid(p):
			continue
		p.close()
	_on_panel_closed()

## Is any interior panel open (clicks must not move the hero on the map).
func is_editor_open() -> bool:
	return is_instance_valid(_shop) or is_instance_valid(_alchemy) or is_instance_valid(_school) or is_instance_valid(_inn) or is_instance_valid(_workshop) or is_instance_valid(_inventory_panel) or is_instance_valid(_archmage) or is_instance_valid(_quests) or is_instance_valid(_world_map)

## Is the cursor over any interface element (panel/button/book/inventory)?
## A click on the UI must not read as movement/attack on the map.
func is_pointer_over_ui(screen_pos: Vector2) -> bool:
	for child in get_children():
		if child is Control and _control_contains(child, screen_pos):
			return true
	return false

func _control_contains(c: Control, p: Vector2) -> bool:
	# The whole parent chain must be visible (hidden panels do not block)
	var cur: Control = c
	while cur is Control:
		if not cur.visible:
			return false
		cur = cur.get_parent() as Control
	# Nodes with MOUSE_FILTER_IGNORE do not intercept clicks (panel backgrounds),
	# but their child widgets (buttons etc.) are still blocked separately.
	var hit := c.mouse_filter != Control.MOUSE_FILTER_IGNORE \
		and Rect2(c.global_position, c.size).has_point(p)
	for ch in c.get_children():
		if ch is Control and _control_contains(ch, p):
			return true
	return hit

## Shop: buying/selling (click on a Shop building).
func open_shop(city_race: String = "", shop_record: Dictionary = {}) -> void:
	if _shop != null and is_instance_valid(_shop):
		return
	_enter_interior()
	Game.cursor_context = "buy"   # a coin cursor with a purse
	_shop = ShopPanel.new()
	_shop.setup(player, city_race, shop_record)
	_shop.closed.connect(_on_panel_closed)
	# Buying a scroll must reach the warrior's book immediately: the panel emits
	# inventory_changed, and before 2026-10-30 nobody listened to it here (the
	# same signal was already wired for the archmage, workshop and inventory).
	_shop.inventory_changed.connect(_on_inventory_changed)
	add_child(_shop)

func open_alchemy() -> void:
	if _alchemy != null and is_instance_valid(_alchemy):
		return
	_enter_interior()
	_alchemy = AlchemyPanel.new()
	_alchemy.setup(player)
	_alchemy.closed.connect(_on_panel_closed)
	_alchemy.inventory_changed.connect(_on_inventory_changed)
	add_child(_alchemy)

## Training school: skills for gold (click on Training School).
func open_school() -> void:
	if _school != null and is_instance_valid(_school):
		return
	_enter_interior()
	_school = SchoolPanel.new()
	_school.setup(player)
	_school.closed.connect(_on_panel_closed)
	add_child(_school)

## Tavern: hiring mercenaries and conversations (click on Inn).
func open_inn(city_race: String = "") -> void:
	if _inn != null and is_instance_valid(_inn):
		return
	_enter_interior()
	_inn = InnPanel.new()
	_inn.setup(player, city_race)
	_inn.closed.connect(_on_panel_closed)
	add_child(_inn)

## Great mage (captain): military pay (click on the mage in the city centre).
## The city great mage (28.10): the panel opens for a CITY, not for the hero's
## race. city_id/race are passed by game.gd on a click on the captain; without them the panel
## works the old way (the hero's race) — that is how the tests call it.
func open_archmage(city_id: String = "", city_race: String = "") -> void:
	if _archmage != null and is_instance_valid(_archmage):
		if city_id == "" or str(_archmage.get("_city_id")) == city_id:
			return
		_archmage.close()
	_enter_interior()
	_archmage = ArchmagePanel.new()
	_archmage.setup(player, city_id, city_race)
	_archmage.closed.connect(_on_panel_closed)
	_archmage.inventory_changed.connect(_on_inventory_changed)
	add_child(_archmage)

## Workshop: blacksmith / tailor / (the master arrives in the third package).
## Before, a forge stood here, and it did NOT connect inventory_changed, unlike
## the archmage and the inventory. Today the harm is nil - the panels do not open
## at the same time, and smelting does not touch gold, - but as soon as the
## third tab with resource spending appeared, the inventory under the showcase would stay
## stale. One connection, consistent with the rest.
func open_workshop() -> void:
	if _workshop != null and is_instance_valid(_workshop):
		return
	_enter_interior()
	Game.cursor_context = "work"  # a hammer cursor
	_workshop = WorkshopPanel.new()
	_workshop.setup(player)
	_workshop.closed.connect(_on_panel_closed)
	_workshop.inventory_changed.connect(_on_inventory_changed)
	add_child(_workshop)

## Inventory and equipment: a modal window. Pressing I again — closes it.
func open_inventory_panel() -> void:
	if _inventory_panel != null and is_instance_valid(_inventory_panel):
		_inventory_panel.close()
		return
	_enter_interior()
	_inventory_panel = InventoryPanel.new()
	_inventory_panel.setup(player)
	_inventory_panel.closed.connect(_on_panel_closed)
	_inventory_panel.inventory_changed.connect(_on_inventory_changed)
	add_child(_inventory_panel)


## City head quests (22.10): offers, accepted tasks, turn-in, cancel.
## city_id empty — the journal without a city (hotkey W): only accepted ones are visible.
## Pressing W again closes the panel, as I closes the inventory.
func open_quests(city_id: String = "") -> void:
	if _quests != null and is_instance_valid(_quests):
		if city_id == "" or str(_quests.get("city_id")) == city_id:
			_quests.close()
			return
		_quests.close()
	_enter_interior()
	_quests = QuestPanel.new()
	_quests.setup(player, city_id)
	_quests.closed.connect(_on_panel_closed)
	_quests.inventory_changed.connect(_on_inventory_changed)
	add_child(_quests)


## World map 4x3 (23.10). Hotkey M, pressing again closes it.
## Travel only through portals: there is no fast travel here.
func open_world_map() -> void:
	if _world_map != null and is_instance_valid(_world_map):
		_world_map.close()
		return
	if is_editor_open():
		close_all_panels()
	_enter_interior()
	var wm_script: GDScript = load("res://scripts/world_map_panel.gd")
	_world_map = wm_script.new()
	_world_map.setup()
	_world_map.closed.connect(_on_panel_closed)
	add_child(_world_map)

func _update_gold(amount: int) -> void:
	if is_instance_valid(hud_gold_label):
		hud_gold_label.text = str(amount)


func _on_inventory_changed() -> void:
	if is_instance_valid(_inventory_panel) and _inventory_panel.has_method("_refresh_stats"):
		_inventory_panel._refresh_stats()
	_update_gold(int(player.gold) if player != null else 0)
	# The book rebuilds on ANY inventory change: a warrior's bought scroll and a
	# mage's learned spell must appear while the panel is still open. Before
	# 04.11 this branch ran for warriors only, so a learned spell showed up
	# after reopening the panel (player report).
	refresh_spell_book()

func refresh_inventory() -> void:
	if is_instance_valid(_inventory_panel):
		if _inventory_panel.has_method("_refresh_inventory_grid"):
			_inventory_panel._refresh_inventory_grid()
		if _inventory_panel.has_method("_refresh_stats"):
			_inventory_panel._refresh_stats()
	if is_instance_valid(player):
		_update_gold(int(player.get("gold") if "gold" in player else 0))
