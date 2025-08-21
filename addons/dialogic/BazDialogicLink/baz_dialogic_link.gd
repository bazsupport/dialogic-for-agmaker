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
	Dialogic.timeline_ended.connect(_on_timeline_ended)
	Dialogic.signal_event.connect(_on_dialogic_signal_event)
	Dialogic.start(timeline_name)

func _on_timeline_ended():
	Dialogic.timeline_ended.disconnect(_on_timeline_ended)
	Dialogic.signal_event.disconnect(_on_dialogic_signal_event)
	await get_tree().process_frame
	timeline_ended.emit("timeline_ended",null)

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
func _get_property_list() -> Array:
	var properties = []
	
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
