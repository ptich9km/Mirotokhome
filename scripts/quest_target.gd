extends Area2D
class_name QuestTarget
## Search spot of a quest item (FIND_ITEM): a glowing item on the map.
##
## The hero walks up - the item goes into the bag and counts towards the
## quest (QuestSystem.notify_item_picked). The icon is the quest art from
## assets/ui/quest/items/ (QuestIcons.target_icon by the quest's "pick",
## otherwise the item's own icon), so the quest works without the art too.

signal picked(node: Node2D, item_key: String)

const PICK_DIST := 28.0
const BOB_SPEED := 2.2
const BOB_AMP := 3.0

@export var item_key: String = ""
@export var quest_id: String = ""
@export var icon: String = ""
var _sprite: Sprite2D = null
var _base_y := 0.0
var _t := 0.0

func _ready() -> void:
	add_to_group("quest_target")
	collision_layer = 0
	collision_mask = 0
	monitorable = false
	monitoring = false
	_base_y = position.y
	_sprite = Sprite2D.new()
	_sprite.name = "Icon"
	_sprite.texture = _icon_texture()
	_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	add_child(_sprite)

func _icon_texture() -> Texture2D:
	return QuestIcons.target_icon(str(_pick()), item_key)


func _pick() -> String:
	var qs := QuestSystem.instance
	if qs == null:
		return ""
	var q := qs.quest_by_id(quest_id)
	return str(q.get("pick", ""))

func _process(delta: float) -> void:
	_t += delta
	position.y = _base_y + sin(_t * BOB_SPEED) * BOB_AMP
	if Game.hero == null or not is_instance_valid(Game.hero):
		return
	if Game.hero.global_position.distance_to(global_position) > PICK_DIST:
		return
	_collect()

func _collect() -> void:
	if item_key != "" and Game.hero != null and is_instance_valid(Game.hero):
		Game.hero.add_item(item_key)
	SoundDB.play("ui.click")
	picked.emit(self, item_key)
	queue_free()

## Mouse hover: the point under the cursor (a click does not pick up - walking does).
func contains_point(world: Vector2) -> bool:
	return world.distance_to(global_position) <= PICK_DIST

func label() -> String:
	var named := ItemDB.display_name(ItemDB.find(item_key))
	if named != "" and named != item_key:
		return named
	var quest_name := QuestDB.quest_item_name(ItemDB.quest_base(item_key))
	return quest_name if quest_name != "" else item_key
