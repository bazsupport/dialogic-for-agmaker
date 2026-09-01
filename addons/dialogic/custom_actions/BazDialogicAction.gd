@tool
extends AGMPluginAction
class_name BazDialogicAction

## ============================================================================
## BazDialogicAction — start, stop, pause or resume a Dialogic timeline
## ============================================================================
##
## HOW TO INSTALL: ships with the Dialogic For AGMaker bundle inside
## `addons/dialogic/custom_actions/`. Single file — no autoload, no plugin.cfg, nothing else
## to wire up. It appears in AGMaker's Add Dialog under CustomAction → "Dialogic". If your
## AGMaker build doesn't list it there, copy this one file into the project-root
## `custom_actions/` folder instead (AGMaker always scans that folder).
##
## WHAT IT DOES: Dialogic Operation picks Start Timeline / End Timeline / Pause / Resume.
## Start Timeline shows a Dialogic Timeline field — a plain typeable dropdown (start typing
## to narrow the list, or pick straight from it) listing every timeline Dialogic knows
## about — plus an optional Start At Label. The other three operations act on whatever
## timeline is currently playing.
##
## REACHING DIALOGIC — NEVER THE BARE IDENTIFIER: the Dialogic autoload only exists when the
## Dialogic plugin is enabled in this project. Writing the bare identifier `Dialogic` anywhere
## in this file would fail to PARSE at all when the plugin is disabled, taking this whole
## script (and its Add Dialog entry) down with it. So Dialogic is looked up at runtime only,
## by walking the tree — `get_tree().root.get_node_or_null(^"Dialogic")` — and every call on
## the result goes through `.call()` / `.set()` (Object-level reflection) instead of typed
## method/property access, since the returned Node is statically typed as plain `Node`, not as
## Dialogic's own (unavailable) class. If Dialogic isn't found, the action pushes one warning
## and quietly no-ops from then on.
##
## THE SIGNAL BRIDGE: `on_state_enter` cannot `await` (see section 7's comment) and Dialogic's
## own completion/choice signals fire independently of any object's state machine. So a small
## self-spawned watcher node (`_DialogicBridge`, one per run, parented to the scene-tree root
## like an autoload) connects to Dialogic's `timeline_ended`, `signal_event`, and — when
## present — the Choices subsystem's `choice_selected`, and forwards them to whichever object
## last started a timeline via this action's `receive_signal(name, value)` method (the same
## method AGMaker's native SignalDetected condition already listens for). Dialogic runs one
## timeline at a time, so "last starter wins" is the correct owner to notify.
##
## Section map: [config / mode enum] → [dynamic inspector: timeline suggestions +
## start-at-label visibility] → [metadata] → [action lifecycle] → [Dialogic autoload
## resolution] → [signal bridge watcher].


# --- Config / mode enum ---------------------------------------------------------

const OP_START_TIMELINE: int = 0
const OP_END_TIMELINE: int = 1
const OP_PAUSE: int = 2
const OP_RESUME: int = 3

## What this action does to Dialogic.[br]• Start Timeline — starts (or restarts) the picked timeline, optionally from a label.[br]• End Timeline — stops whatever timeline is currently playing.[br]• Pause — freezes the current timeline in place.[br]• Resume — un-freezes a paused timeline.
@export_enum("Start Timeline", "End Timeline", "Pause", "Resume") var dialogic_operation: int = OP_START_TIMELINE:
	set(value):
		dialogic_operation = value
		notify_property_list_changed()

## Which timeline to start.[br]Start typing to narrow the list, or pick from the dropdown.[br]This is the timeline's name as shown in the Dialogic editor.
@export var dialogic_timeline: String = ""

## Which label inside the timeline to start from.[br]Blank (default) starts from the top.
@export var start_at_label: String = ""


# --- Dynamic inspector: timeline suggestions + start-at-label visibility --------------
# dialogic_timeline is a plain @export String — no virtual picker, no _get/_set. Its only
# special behavior is a PROPERTY_HINT_ENUM_SUGGESTION hint (a typeable, filterable dropdown)
# built from Dialogic's known timeline identifiers, applied only in Start Timeline mode.

## Dialogic Timeline gets a typeable suggestion dropdown of every timeline Dialogic knows
## about, but only when Start Timeline is picked (the other three operations act on
## whatever timeline is already playing and need no timeline choice). Start At Label is
## hidden for those same three operations.
func _validate_property(property: Dictionary) -> void:
	if property.name == "dialogic_timeline":
		if dialogic_operation != OP_START_TIMELINE:
			property.usage = PROPERTY_USAGE_NO_EDITOR
		else:
			var dtl_dir: Dictionary = ProjectSettings.get_setting("dialogic/directories/dtl_directory", {})
			var names: PackedStringArray = PackedStringArray(_sorted_dtl_identifiers(dtl_dir))
			# Apply the hint only when non-empty — an empty ENUM_SUGGESTION hint renders a
			# blank row (same guard BazGenerateSceneAction's scene_choice uses).
			if not names.is_empty():
				property.hint = PROPERTY_HINT_ENUM_SUGGESTION
				property.hint_string = ",".join(names)
	elif property.name == "start_at_label" and dialogic_operation != OP_START_TIMELINE:
		property.usage = PROPERTY_USAGE_NO_EDITOR


## Every key of the Dialogic timeline directory dict, comma-free, sorted case-insensitively.
static func _sorted_dtl_identifiers(dtl_dir: Dictionary) -> Array[String]:
	var identifiers: Array[String] = []
	for key in dtl_dir.keys():
		var id_str: String = String(key)
		if id_str.find(",") == -1:
			identifiers.append(id_str)
	identifiers.sort_custom(func(a: String, b: String) -> bool: return a.to_lower() < b.to_lower())
	return identifiers


# --- AGMaker plugin metadata ------------------------------------------------------

func get_plugin_tab_name() -> String:
	return "CustomAction"


func get_group_name() -> String:
	return "Dialogic"


func get_description() -> String:
	return "Start, stop, pause or resume a Dialogic timeline."


# --- Action lifecycle --------------------------------------------------------------
# AGM 1.3.0 over-supplies args to action lifecycle methods (on_state_update gets an extra
# delta), so ALL THREE need two trailing optional Variants or they raise "[AGMPluginAction]
# Method call failed. error code = 3" every frame (skill §7 pitfall 11).

## Warn only once per run that Dialogic couldn't be found (plugin disabled, or the autoload
## isn't named "Dialogic"), rather than spamming a push_warning every time this fires.
static var _warned_missing_dialogic: bool = false

## Warn only once per run that Start Timeline was used with no timeline picked.
static var _warned_empty_timeline: bool = false

## Warn only once per run that the picked timeline name isn't in Dialogic's directory
## (renamed or deleted after being picked) — start is still attempted; Dialogic prints its
## own error if the name can't be resolved.
static var _warned_unknown_timeline: bool = false

func on_state_enter(p_owner: Object, _p_extra_a: Variant = null, _p_extra_b: Variant = null) -> void:
	var owner_node: Node = p_owner as Node
	if owner_node == null:
		return
	var dialogic: Node = _resolve_dialogic(owner_node)
	if dialogic == null:
		if not _warned_missing_dialogic:
			_warned_missing_dialogic = true
			push_warning("[BazDialogicAction] Dialogic autoload not found in the scene tree — is the Dialogic plugin enabled? This action will no-op.")
		return

	match dialogic_operation:
		OP_START_TIMELINE:
			_do_start_timeline(dialogic, owner_node)
		OP_END_TIMELINE:
			if dialogic.has_method("end_timeline"):
				dialogic.call("end_timeline")
			else:
				push_warning("[BazDialogicAction] Dialogic autoload has no 'end_timeline' method — is this a supported Dialogic version?")
		OP_PAUSE:
			dialogic.set("paused", true)
		OP_RESUME:
			dialogic.set("paused", false)


func on_state_update(_p_owner: Object, _p_extra_a: Variant = null, _p_extra_b: Variant = null) -> void:
	pass   # required stub — every operation is one-shot in on_state_enter


func on_state_exit(_p_owner: Object, _p_extra_a: Variant = null, _p_extra_b: Variant = null) -> void:
	pass   # required stub — pending_owner is deliberately NOT cleared here; the owner's state
	# may legitimately leave mid-dialogue and still want the eventual timeline_ended signal.


## Start Timeline: ensures the signal bridge is up, latches this owner as the one to notify
## when Dialogic reports back, then starts the picked timeline by NAME. No `await` here
## (skill §7 pitfall 3) — all deferred work lives in the bridge watcher below.
func _do_start_timeline(dialogic: Node, owner_node: Node) -> void:
	if dialogic_timeline.is_empty():
		if not _warned_empty_timeline:
			_warned_empty_timeline = true
			push_warning("[BazDialogicAction] Start Timeline has no timeline picked — no-op.")
		return
	var dtl_dir: Dictionary = ProjectSettings.get_setting("dialogic/directories/dtl_directory", {})
	if not dtl_dir.has(dialogic_timeline) and not _warned_unknown_timeline:
		_warned_unknown_timeline = true
		push_warning("[BazDialogicAction] '%s' isn't a known Dialogic timeline — starting anyway; Dialogic will report its own error if it can't be found." % dialogic_timeline)
	var bridge: Node = _ensure_bridge(owner_node.get_tree())
	if bridge != null:
		bridge.set("pending_owner", weakref(owner_node))
	if dialogic.has_method("start"):
		# Name form: Dialogic resolves a non-"res://" string through its timeline directory,
		# same as picking it by identifier in the Dialogic editor.
		if bridge != null and not bridge.is_inside_tree():
			# First start of the run: the bridge's add_child is still queued, so its _ready
			# (where it connects to Dialogic) hasn't run. Queue the start behind it — deferred
			# calls run in order — or a Signal event as the timeline's FIRST event would be
			# emitted before anyone is listening. Costs one frame, once per run.
			dialogic.call_deferred("start", dialogic_timeline, start_at_label)
		else:
			dialogic.call("start", dialogic_timeline, start_at_label)
	else:
		push_warning("[BazDialogicAction] Dialogic autoload has no 'start' method — is this a supported Dialogic version?")


# --- Dialogic autoload resolution ---------------------------------------------------

## Reaches Dialogic ONLY by walking the tree — never the bare identifier `Dialogic` — so this
## script parses (and stays registered in the Add Dialog) even when the Dialogic plugin is
## disabled. Returns null if the autoload isn't present.
static func _resolve_dialogic(owner_node: Node) -> Node:
	var tree: SceneTree = owner_node.get_tree()
	if tree == null or tree.root == null:
		return null
	return tree.root.get_node_or_null(^"Dialogic")


# --- Signal bridge watcher ----------------------------------------------------------
# Dialogic's timeline_ended / signal_event / choice_selected signals fire independently of
# any object's state machine, and on_state_enter can't `await` to wait for them. A single
# persistent watcher node, parented to the scene-tree ROOT (so it outlives scene changes,
# like an autoload), connects to Dialogic once per run and forwards each event to whichever
# owner started the timeline via that owner's own `receive_signal(name, value)` method — the
# same method AGMaker's native SignalDetected condition already listens for.

## Typed as plain Node (never as the inner class below) everywhere outside that class's own
## body — matching BazInputCondition.gd's _ensure_buffer()/_buffer_instance convention. Custom
## members (pending_owner) are reached through .set()/.get() reflection instead of a forward
## static-type reference to a nested class defined later in this same file.
static var _bridge_instance: Node = null


## Returns the shared bridge node, creating it under the scene-tree root on first runtime
## call. Null in the editor. The static cache + node-name lookup guarantee a single instance
## per run, mirroring BazSaveLoadDetectedCondition's _ensure_watcher().
static func _ensure_bridge(tree: SceneTree) -> Node:
	if _bridge_instance != null and is_instance_valid(_bridge_instance):
		return _bridge_instance
	if Engine.is_editor_hint():
		return null
	if tree == null or tree.root == null:
		return null
	var existing: Node = tree.root.get_node_or_null("BazDialogicBridge")
	if existing != null:
		_bridge_instance = existing
		return existing
	var bridge: Node = _DialogicBridge.new()
	bridge.name = "BazDialogicBridge"
	_bridge_instance = bridge
	# Deferred so it's safe to call mid-frame from on_state_enter; it connects in _ready next frame.
	tree.root.call_deferred("add_child", bridge)
	return bridge


## Listens to Dialogic's timeline_ended / signal_event / Choices.choice_selected signals and
## forwards them to whichever owner last started a timeline (Dialogic runs one timeline at a
## time, so "last starter wins" is the correct target). NOT a @tool node — dormant in the
## editor, connects only in the running game.
class _DialogicBridge extends Node:
	## The GameObject that started the current (or most recent) timeline. A WeakRef so a
	## freed owner can never be kept alive or dereferenced by this watcher.
	var pending_owner: WeakRef = null

	func _ready() -> void:
		var dialogic: Node = get_tree().root.get_node_or_null(^"Dialogic")
		if dialogic == null:
			push_warning("[BazDialogicAction] Dialogic autoload not found — signal bridge inactive.")
			return
		if dialogic.has_signal("timeline_ended") and not dialogic.is_connected("timeline_ended", _on_timeline_ended):
			dialogic.connect("timeline_ended", _on_timeline_ended)
		if dialogic.has_signal("signal_event") and not dialogic.is_connected("signal_event", _on_signal_event):
			dialogic.connect("signal_event", _on_signal_event)
		if dialogic.has_method("has_subsystem") and bool(dialogic.call("has_subsystem", "Choices")):
			var choices: Variant = dialogic.call("get_subsystem", "Choices")
			if choices is Object:
				var choices_obj: Object = choices as Object
				if choices_obj.has_signal("choice_selected") and not choices_obj.is_connected("choice_selected", _on_choice_selected):
					choices_obj.connect("choice_selected", _on_choice_selected)

	## current_timeline is already null by the time timeline_ended fires (end_timeline awaits
	## clear() before emitting — plan Context), so nothing about which timeline ended is read
	## here; the signal itself is the only information. Waits one frame (mirrors the legacy
	## BazDialogicLink node's behavior) before notifying, then releases pending_owner.
	func _on_timeline_ended() -> void:
		var owner_node: Object = _valid_pending_owner()
		if owner_node == null:
			return
		await get_tree().process_frame
		var still_valid: Object = _valid_pending_owner()
		if still_valid != null:
			still_valid.call("receive_signal", "timeline_ended", null)
		pending_owner = null

	## button_index is 1-based (the button the player sees) — passed through unchanged.
	func _on_choice_selected(info: Dictionary) -> void:
		var owner_node: Object = _valid_pending_owner()
		if owner_node == null:
			return
		owner_node.call("receive_signal", "timeline_choice", int(info.get("button_index", 0)))

	## Only String, non-empty Signal events are forwarded — the argument's text IS the signal
	## name, fed straight into receive_signal so native SignalDetected can pick it up.
	func _on_signal_event(arg: Variant) -> void:
		if not (arg is String):
			return
		var text: String = arg as String
		if text.is_empty():
			return
		var owner_node: Object = _valid_pending_owner()
		if owner_node == null:
			return
		owner_node.call("receive_signal", text, null)

	## The latched owner, or null if there is none / it was freed / it can't receive signals.
	func _valid_pending_owner() -> Object:
		if pending_owner == null:
			return null
		var owner_node: Object = pending_owner.get_ref()
		if owner_node == null or not is_instance_valid(owner_node):
			return null
		if not owner_node.has_method("receive_signal"):
			return null
		return owner_node
