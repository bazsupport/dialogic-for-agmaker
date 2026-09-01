@tool
extends AGMPluginCondition
class_name BazDialogicCondition

## Baz Dialogic Condition — true when a Dialogic timeline ended, a choice was picked, or a
## dialogue is currently running.
##
## WHAT IT DOES:
##   • Timeline Ended  — true once, latched, after a Dialogic timeline you started finishes.
##   • Choice Picked   — true once, latched, after the player picks a specific choice button
##     (Choice Number is 1-based — 1 is the first button the player sees).
##   • Dialogue Active — true for as long as ANY Dialogic timeline is currently running. Not
##     latched — a live read, no state to leave stale.
##
## LATCHED-SINCE-STATE-ENTRY: Timeline Ended and Choice Picked latch onto TRUE the instant the
## event happens and STAY true until the owner leaves the state this condition is attached to
## (on_condition_exit clears its snapshot) — the same "state re-entry resets it" contract as
## BazSaveLoadDetectedCondition, but keyed by a counter comparison instead of a time window,
## since Dialogic events aren't guaranteed to land inside any fixed wall-clock slot.
##
## WHY A SNAPSHOT PER OWNER: this plugin instance is SHARED by every object that uses it. A bare
## global "did a timeline end" flag would fire for every listener at once and never reset per
## object. Instead on_condition_enter stamps the CURRENT global event counters onto this owner's
## instance id; on_judge_condition just checks whether the counters moved past that stamp.
##
## REACHING DIALOGIC: this file NEVER writes the bare identifier `Dialogic` — only through
## get_tree().root.get_node_or_null(^"Dialogic"). That is what lets this script PARSE and
## register in the Add Dialog even when the Dialogic plugin is disabled in this project; at
## runtime it just degrades to "always false" with a one-time warning.
##
## HOW TO INSTALL: ships with the Dialogic For AGMaker bundle inside
## `addons/dialogic/custom_conditions/`. Single file — no autoload, no plugin.cfg, nothing else
## to wire up. It appears in AGMaker's Add Dialog under CustomCondition → "Dialogic". If your
## AGMaker build doesn't list it there, copy this one file into the project-root
## `custom_conditions/` folder instead (AGMaker always scans that folder).
##
## Section map: [mode] → [timeline + choice fields] → [metadata] → [lifecycle]
##              → [static latch + watcher].


# --- 1. Mode ------------------------------------------------------------------

const CHECK_TIMELINE_ENDED: int = 0
const CHECK_CHOICE_PICKED: int = 1
const CHECK_DIALOGUE_ACTIVE: int = 2

## Which Dialogic event makes this condition true.[br]• Timeline Ended — a dialogue you started has finished.[br]• Choice Picked — the player picked a specific choice button.[br]• Dialogue Active — a Dialogic timeline is currently running (live read, no latch).
@export_enum("Timeline Ended", "Choice Picked", "Dialogue Active") var dialogic_check: int = CHECK_TIMELINE_ENDED:
	set(value):
		dialogic_check = value
		notify_property_list_changed()


# --- 2. Timeline + choice fields -----------------------------------------------
# dialogic_timeline is a plain String field with a PROPERTY_HINT_ENUM_SUGGESTION hint (see
# BazGenerateSceneAction's scene_choice / BazChangeNodePropertyAction's _apply_suggest for the
# established pattern): it stores the typed identifier directly, and the inspector shows it as
# a typeable dropdown that suggests every timeline from dialogic/directories/dtl_directory.
# No virtual picker property, no _get/_set — inspector order comes straight from declaration
# order, so this field sits between Dialogic Check and Choice Number for free.

const ANY_TIMELINE: String = "Any"

## Which timeline this applies to.[br]Leave as Any for every timeline, or start typing a timeline's name to narrow the list.[br]Used by Timeline Ended and Choice Picked.
@export var dialogic_timeline: String = ANY_TIMELINE

## Which choice button this fires for.[br]1 is the first button the player sees.[br]Only used when Dialogic Check is Choice Picked.
@export_range(1, 99, 1) var choice_number: int = 1


func _validate_property(property: Dictionary) -> void:
	if property.name == "dialogic_timeline":
		if dialogic_check == CHECK_DIALOGUE_ACTIVE:
			property.usage = PROPERTY_USAGE_NO_EDITOR
		else:
			property.hint = PROPERTY_HINT_ENUM_SUGGESTION
			property.hint_string = ",".join(_timeline_suggestions())
	elif property.name == "choice_number" and dialogic_check != CHECK_CHOICE_PICKED:
		property.usage = PROPERTY_USAGE_NO_EDITOR


## Suggestion list for Dialogic Timeline: ANY_TIMELINE first, then every identifier from
## dialogic/directories/dtl_directory, sorted case-insensitively. Keys containing a comma are
## skipped — hint_string is comma-delimited and a comma in an entry would corrupt it. Never
## empty (ANY_TIMELINE is always present).
func _timeline_suggestions() -> PackedStringArray:
	var names: PackedStringArray = PackedStringArray([ANY_TIMELINE])
	var directory: Dictionary = ProjectSettings.get_setting("dialogic/directories/dtl_directory", {})
	var identifiers: Array[String] = []
	for key in directory.keys():
		var identifier: String = String(key)
		if not identifier.contains(","):
			identifiers.append(identifier)
	identifiers.sort_custom(func(a: String, b: String) -> bool: return a.nocasecmp_to(b) < 0)
	for identifier in identifiers:
		names.append(identifier)
	return names


# --- 3. AGMaker plugin metadata -------------------------------------------------

func get_plugin_tab_name() -> String:
	return "CustomCondition"


func get_group_name() -> String:
	return "Dialogic"


func get_description() -> String:
	return "True when a Dialogic timeline ended, a choice was picked, or a dialogue is running."


# --- 4. AGMaker condition lifecycle ----------------------------------------------
# The trailing optional Variants are REQUIRED: AGMaker invokes these from C++ via a strict
# Object::callp that passes MORE than just the owner. A single-parameter signature raises
# CALL_ERROR_TOO_MANY_ARGUMENTS (error code 3) every frame. The extra params absorb the surplus.

## Spawn the watcher eagerly (before any judge) and stamp this owner's snapshot of the shared
## event counters, so on_judge_condition only ever has to ask "did the counters move since I
## entered".
func on_condition_enter(p_owner: Object, _p_extra_a: Variant = null, _p_extra_b: Variant = null) -> void:
	var owner_node: Node = p_owner as Node
	if owner_node == null:
		return
	_ensure_watcher(owner_node.get_tree())
	_snapshots[owner_node.get_instance_id()] = {"ended": _ended_count, "choice": _choice_count}


## True if dialogic_timeline is Any (or blank), or the given latched path matches the
## directory entry for the picked identifier. A name not in the directory therefore never
## matches — it never accidentally latches on a mistyped or renamed timeline.
func _timeline_filter_matches(path: String) -> bool:
	if dialogic_timeline == "" or dialogic_timeline == ANY_TIMELINE:
		return true
	var directory: Dictionary = ProjectSettings.get_setting("dialogic/directories/dtl_directory", {})
	if not directory.has(dialogic_timeline):
		return false
	return path == String(directory[dialogic_timeline])


## Pure read — no side effects.
##   Dialogue Active — live: true while Dialogic reports a running timeline. Not latched.
##   Timeline Ended  — true once the global ended-count has moved past this owner's snapshot,
##                      AND (no timeline filter, or the last-ended timeline matches the pick).
##   Choice Picked   — true once the global choice-count has moved past this owner's snapshot,
##                      the last picked button matches Choice Number, AND (no timeline filter,
##                      or the last-choice timeline matches the pick).
## No snapshot for this owner (judged before on_condition_enter ran) → false.
func on_judge_condition(p_owner: Object, _p_extra_a: Variant = null, _p_extra_b: Variant = null) -> bool:
	var owner_node: Node = p_owner as Node
	if owner_node == null:
		return false
	var tree: SceneTree = owner_node.get_tree()
	if tree == null or tree.root == null:
		return false

	if dialogic_check == CHECK_DIALOGUE_ACTIVE:
		var dialogic: Node = tree.root.get_node_or_null(^"Dialogic")
		if dialogic == null:
			return false
		return dialogic.get("current_timeline") != null

	var snap: Variant = _snapshots.get(owner_node.get_instance_id())
	if snap == null:
		return false
	var snap_dict: Dictionary = snap

	if dialogic_check == CHECK_TIMELINE_ENDED:
		if _ended_count <= int(snap_dict.get("ended", 0)):
			return false
		return _timeline_filter_matches(_last_ended_path)

	# CHECK_CHOICE_PICKED
	if _choice_count <= int(snap_dict.get("choice", 0)):
		return false
	if _last_choice_index != choice_number:
		return false
	return _timeline_filter_matches(_last_choice_path)


func on_condition_exit(p_owner: Object, _p_extra_a: Variant = null, _p_extra_b: Variant = null) -> void:
	var owner_node: Node = p_owner as Node
	if owner_node == null:
		return
	_snapshots.erase(owner_node.get_instance_id())


# --- 5. Static latch + self-spawned watcher --------------------------------------
# The Dialogic autoload's timeline_started/timeline_ended/choice_selected signals each fire
# once. A condition's on_judge_condition runs every frame and must be a pure read, so we can't
# react to a one-shot signal directly. Instead a persistent watcher node (spawned under the
# scene-tree ROOT, so it survives scene changes) connects to Dialogic once and latches counters
# + the relevant timeline path into these static vars. Every plugin instance (shared across
# owners) reads the same statics; on_condition_enter/exit turn that into a per-owner "did it
# move since I entered" read via _snapshots.
#
# IMPORTANT: current_timeline is already null by the time timeline_ended fires (Dialogic clears
# it before emitting), so the path has to be captured earlier, on timeline_started, and copied
# into _last_ended_path when the end signal arrives.

## How many timelines have ended since the game started. Compared against a per-owner snapshot.
static var _ended_count: int = 0
## How many choices have been picked since the game started. Compared against a per-owner snapshot.
static var _choice_count: int = 0
## The path of the timeline currently (or most recently) running — stamped on timeline_started.
static var _active_timeline_path: String = ""
## The path of the timeline that produced the most recent timeline_ended.
static var _last_ended_path: String = ""
## The 1-based button index of the most recently picked choice.
static var _last_choice_index: int = 0
## The path of the timeline the most recent choice was picked in.
static var _last_choice_path: String = ""

## owner instance id -> {"ended": int, "choice": int} — the event counters as of this owner's
## on_condition_enter. Per-owner because this plugin instance is shared across every owner.
static var _snapshots: Dictionary = {}

static var _watcher_instance: Node = null
static var _warned_missing_dialogic: bool = false


## Returns the shared watcher node, creating it under the scene-tree root on first runtime call.
## Null in the editor. The static cache + node-name lookup guarantee a single instance per run.
static func _ensure_watcher(tree: SceneTree) -> Node:
	if _watcher_instance != null and is_instance_valid(_watcher_instance):
		return _watcher_instance
	if Engine.is_editor_hint():
		return null
	if tree == null or tree.root == null:
		return null
	# Reuse one created earlier this run (e.g. if statics were reset but the node still lives).
	var existing: Node = tree.root.get_node_or_null("BazDialogicEventLatch")
	if existing != null:
		_watcher_instance = existing
		return existing
	var watcher: Node = _DialogicEventLatch.new()
	watcher.name = "BazDialogicEventLatch"
	_watcher_instance = watcher
	# Deferred so it's safe to call mid-frame from a condition; it connects in _ready next frame.
	tree.root.call_deferred("add_child", watcher)
	return watcher


## Listens to the Dialogic autoload's signals and stamps the static latch above. NOT a @tool
## node — dormant in the editor, connects only in the running game. Reaches Dialogic solely
## through get_tree().root.get_node_or_null(^"Dialogic") and Object.get/call/connect — never the
## bare `Dialogic` identifier — so this whole file parses whether or not the Dialogic plugin is
## enabled in the consuming project.
class _DialogicEventLatch extends Node:
	func _ready() -> void:
		var dialogic: Node = get_tree().root.get_node_or_null(^"Dialogic")
		if dialogic == null:
			if not BazDialogicCondition._warned_missing_dialogic:
				BazDialogicCondition._warned_missing_dialogic = true
				push_warning("BazDialogicCondition: the Dialogic autoload was not found; Dialogic conditions will always read false.")
			return
		if dialogic.has_signal("timeline_started") and not dialogic.is_connected("timeline_started", _on_timeline_started):
			dialogic.connect("timeline_started", _on_timeline_started)
		if dialogic.has_signal("timeline_ended") and not dialogic.is_connected("timeline_ended", _on_timeline_ended):
			dialogic.connect("timeline_ended", _on_timeline_ended)
		if dialogic.has_method("has_subsystem") and bool(dialogic.call("has_subsystem", "Choices")):
			var choices: Object = dialogic.call("get_subsystem", "Choices")
			if choices != null and choices.has_signal("choice_selected") and not choices.is_connected("choice_selected", _on_choice_selected):
				choices.connect("choice_selected", _on_choice_selected)
		# Catch-up: this watcher is added deferred, so a timeline started in the same frame
		# (the usual "Start Timeline action + Timeline Ended link in one state" setup, first
		# time in the run) already emitted timeline_started before we connected. Stamp it now.
		var already_running: String = _current_timeline_path()
		if already_running != "":
			BazDialogicCondition._active_timeline_path = already_running

	## Stamp the active timeline's path while current_timeline is still valid — it's already
	## null by the time timeline_ended fires.
	func _on_timeline_started() -> void:
		BazDialogicCondition._active_timeline_path = _current_timeline_path()

	func _on_timeline_ended() -> void:
		BazDialogicCondition._last_ended_path = BazDialogicCondition._active_timeline_path
		BazDialogicCondition._ended_count += 1

	## info carries at least "button_index" (1-based), "text", "event_index".
	func _on_choice_selected(info: Dictionary) -> void:
		BazDialogicCondition._last_choice_index = int(info.get("button_index", 0))
		BazDialogicCondition._last_choice_path = BazDialogicCondition._active_timeline_path
		BazDialogicCondition._choice_count += 1

	## The live current_timeline's resource path, "" if there is none or it isn't a Resource.
	func _current_timeline_path() -> String:
		var dialogic: Node = get_tree().root.get_node_or_null(^"Dialogic")
		if dialogic == null:
			return ""
		var current: Variant = dialogic.get("current_timeline")
		if current is Resource:
			return (current as Resource).resource_path
		return ""
