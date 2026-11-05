class_name DeathScreen
extends CanvasLayer
## Full-screen black card shown one second after the hero falls, before the
## compact load menu replaces it. Player decision 04.11: 1 s of the fall,
## then the title, then the compact screen with the load list.
##
## The world is NOT paused while this card is visible: the fall animation is
## still playing underneath, and the enemies have already dropped the corpse as
## a target (Game.hero_dead). The actual freeze happens when the load menu is
## created.

func _ready() -> void:
	layer = 19          # above HUD/panels (1/10), below SaveMenu (20) and cursor (100)
	process_mode = Node.PROCESS_MODE_ALWAYS

	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(root)

	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 1)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	root.add_child(bg)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(center)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.add_child(box)

	var title := Label.new()
	title.text = Loc.t("ui.gameover.title")
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 56)
	title.add_theme_color_override("font_color", Color(0.86, 0.72, 0.44))
	title.add_theme_color_override("font_outline_color", Color(0, 0, 0, 1))
	title.add_theme_constant_override("outline_size", 8)
	box.add_child(title)

	var sub := Label.new()
	sub.text = Loc.t("ui.gameover.sub")
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.add_theme_font_size_override("font_size", 18)
	sub.add_theme_color_override("font_color", Color(0.66, 0.63, 0.56))
	box.add_child(sub)
