class_name CraftMasterTab
extends CraftSmithTab

## Master tab: +1..+7 on a crafted item.
##
## Quality is decided at the anvil (Crafted/Fine/Master); the master only adds
## plus levels. Every plus rolls one bonus from the item's class pool and stores
## the roll as a seed inside the key. +1..+5 are guaranteed, +6 is 40% and +7 is
## 25%; a failure consumes the materials but never the item.

func _decor_path() -> String:
	return "res://assets/professions/workshop/furnace.png"


func _items() -> Array:
	var out: Array = []
	for raw in _inventory_items():
		var item: Dictionary = raw["item"]
		if not ItemDB.is_equippable(item):
			continue
		if not ForgeDB.is_forgeable(item):
			continue
		var key := str(raw["key"])
		if ItemDB.plus_of(key) >= ForgeDB.MAX_PLUS:
			continue
		out.append({
			"mode": "forge",
			"key": key,
			"item": item,
			"count": int(raw["count"]),
			"target": ItemDB.plus_of(key) + 1,
		})
	return out


func _item_label(entry: Dictionary) -> String:
	var item: Dictionary = entry["item"]
	var target := int(entry.get("target", 0))
	return "  %s  [→ +%d]" % [ItemDB.display_name(item), target]


func _action_label(entry: Dictionary) -> String:
	if str(entry.get("mode", "")) == "forge":
		return Loc.t("ui.craft.master.improve")
	return super._action_label(entry)


func _action_block_reason(entry: Dictionary) -> String:
	if str(entry.get("mode", "")) != "forge":
		return super._action_block_reason(entry)
	if not is_instance_valid(player):
		return Loc.t("ui.craft.no_hero")
	var item: Dictionary = entry["item"]
	var block := ForgeDB.can_upgrade(item, player)
	if block != "":
		return block
	var c := ForgeDB.cost(item, int(entry.get("target", 0)))
	for pair in [["resource", "resource_count"], ["essence", "essence"],
			["boss_core", "boss_core"]]:
		var key := str(c.get(pair[0], ""))
		var need := int(c.get(pair[1], 0))
		if key == "" or need <= 0:
			continue
		if _item_count(key) < need:
			return Loc.f("ui.craft.missing", [ItemDB.display_name(ItemDB.find(key))])
	return ""


func _perform(entry: Dictionary) -> String:
	if str(entry.get("mode", "")) != "forge":
		return super._perform(entry)
	var res := ForgeDB.upgrade(player, str(entry.get("key", "")))
	return str(res.get("message", ""))


func _build_detail(entry: Dictionary) -> void:
	if str(entry.get("mode", "")) != "forge":
		super._build_detail(entry)
		return
	var item: Dictionary = entry["item"]
	var target := int(entry.get("target", 0))
	var plus := ItemDB.plus_of(str(entry["key"]))
	var cost := ForgeDB.cost(item, target)
	_detail.add_child(_heading(ItemDB.display_name(item)))
	_detail.add_child(_note(Loc.t("ui.craft.master.only_own")))

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", UiTheme.SPACE_3)
	_detail.add_child(row)
	row.add_child(_make_icon(item, Vector2(72, 72)))
	var arrow := Label.new()
	arrow.text = "→ +%d" % target
	arrow.theme_type_variation = &"CraftTitle"
	arrow.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(arrow)

	_detail.add_child(_section(Loc.t("ui.craft.master.cost")))
	if int(cost.get("resource_count", 0)) > 0:
		_detail.add_child(_make_cost_row(str(cost.get("resource", "")),
			int(cost.get("resource_count", 0))))
	if int(cost.get("essence", 0)) > 0:
		_detail.add_child(_make_cost_row(ForgeDB.ESSENCE_KEY, int(cost.get("essence", 0))))
	if int(cost.get("boss_core", 0)) > 0:
		_detail.add_child(_make_cost_row(ForgeDB.BOSS_CORE, int(cost.get("boss_core", 0))))

	var chance := ForgeDB.success_chance(target)
	if chance < 100:
		_detail.add_child(_note(Loc.f("ui.craft.master.chance", [chance])))
	else:
		_detail.add_child(_note(Loc.t("ui.craft.master.guaranteed")))
	var cap := ForgeDB.cap_for(item, player)
	_detail.add_child(_note(Loc.f("ui.craft.master.cap", [cap, plus])))


func _make_cost_row(item_key: String, required: int) -> Control:
	var current := _item_count(item_key)
	var item := ItemDB.find(item_key)
	var panel := PanelContainer.new()
	if item.is_empty():
		item = {"name_ru": item_key}
	panel.name = "CostRow_%s" % item_key.replace(" ", "_")
	panel.theme_type_variation = &"CraftIngredient"
	var m := MarginContainer.new()
	_set_margins(m, UiTheme.SPACE_2, UiTheme.SPACE_1, UiTheme.SPACE_2, UiTheme.SPACE_1)
	panel.add_child(m)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", UiTheme.SPACE_2)
	m.add_child(row)
	row.add_child(_make_icon(item, Vector2(40, 40)))
	var name_label := Label.new()
	name_label.text = ItemDB.display_name(item)
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(name_label)
	var count_label := Label.new()
	count_label.theme_type_variation = &"CraftIngredientOk" \
		if current >= required else &"CraftIngredientMissing"
	count_label.text = Loc.f("ui.craft.have_need", [current, required])
	count_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(count_label)
	return panel


func _variation_prefix() -> String:
	return "CraftMaster"


func _build_recipe_detail(entry: Dictionary) -> void:
	_detail.add_child(_make_hint(Loc.t("ui.craft.master.hint")))
