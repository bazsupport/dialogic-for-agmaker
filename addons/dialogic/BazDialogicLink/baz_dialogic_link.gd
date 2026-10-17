@tool
@icon("res://addons/dialogic/BazDialogicLink/icon.png")
extends Node
class_name BazDialogicLink

var game_object_is_owner:bool = true : set = _set_game_object_is_owner
var game_object:GameObject : set = _set_game_object
var timeline_is_node_name:bool = true : set = _set_timeline_is_node_name
var timeline_name:String = ""

signal timeline_ended
signal timeline_choice

func _ready() -> void:
	var target_object = null
	var actual_timeline = timeline_name
	
	# Use node name as timeline if timeline_is_node_name is true
	if timeline_is_node_name:
		actual_timeline = name
	
	# Determine which object to use based on obj_is_owner flag
	if game_object_is_owner:
		target_object = get_owner()
	else:
		target_object = game_object
	
	# Check if we have a valid target object
	if target_object == null:
		return
	
	# Connect signals if the target object has the required signal
	if target_object.has_signal(actual_timeline):
		target_object.connect(actual_timeline, Callable(self, "_on_start_dialogue"))
		timeline_ended.connect(Callable(target_object, "receive_signal"))
		timeline_choice.connect(Callable(target_object, "receive_signal"))

func _on_start_dialogue(timeline_name:String,_value) -> void:
	var dialogic: Node = _get_dialogic()
	if dialogic == null:
		push_warning("[BazDialogicLink] Dialogic not found. Enable it in Project > Project Settings > Plugins, then reload the project.")
		return
	dialogic.connect("timeline_ended", _on_timeline_ended)
	dialogic.connect("signal_event", _on_dialogic_signal_event)
	dialogic.call("start", timeline_name)

func _on_timeline_ended():
	var dialogic: Node = _get_dialogic()
	if dialogic != null:
		dialogic.disconnect("timeline_ended", _on_timeline_ended)
		dialogic.disconnect("signal_event", _on_dialogic_signal_event)
	await get_tree().process_frame
	timeline_ended.emit("timeline_ended",null)

# Looks the Dialogic autoload up at runtime instead of naming it directly, so this script
# still loads when the Dialogic plugin isn't enabled yet. Returns null if it isn't there.
func _get_dialogic() -> Node:
	if not is_inside_tree():
		return null
	return get_tree().root.get_node_or_null(^"Dialogic")

func _on_dialogic_signal_event(choice_number:String) -> void:
	timeline_choice.emit("timeline_choice", int(choice_number))

# Setter for game_object_is_owner that controls game_object visibility
func _set_game_object_is_owner(value: bool) -> void:
	game_object_is_owner = value
	_update_obj_visibility()

# Setter for game_object to ensure visibility is updated when game_object changes
func _set_game_object(value: GameObject) -> void:
	game_object = value
	_update_obj_visibility()

# Setter for timeline_is_node_name that controls timeline_name visibility
func _set_timeline_is_node_name(value: bool) -> void:
	timeline_is_node_name = value
	_update_obj_visibility()

# Updates the visibility of the game_object property in the inspector
func _update_obj_visibility() -> void:
	# This will hide/show the game_object property based on game_object_is_owner
	notify_property_list_changed()

# Override _get_property_list to control which properties are visible
func _get_property_list() -> Array[Dictionary]:
	var properties: Array[Dictionary] = []
	
	# Always show game_object_is_owner
	properties.append({
		"name": "game_object_is_owner",
		"type": TYPE_BOOL
	})
	
	# Only show game_object if game_object_is_owner is false
	if not game_object_is_owner:
		properties.append({
			"name": "game_object",
			"type": TYPE_OBJECT,
			"hint": PROPERTY_HINT_NODE_TYPE,
			"hint_string": "GameObject"
		})
	
	# Always show timeline_is_node_name
	properties.append({
		"name": "timeline_is_node_name",
		"type": TYPE_BOOL
	})
	
	# Only show timeline_name if timeline_is_node_name is false
	if not timeline_is_node_name:
		properties.append({
			"name": "timeline_name",
			"type": TYPE_STRING
		})
	
	
	return properties
