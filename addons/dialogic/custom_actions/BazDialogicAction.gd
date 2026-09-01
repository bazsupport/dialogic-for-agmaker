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
## Start Timeline shows a Timeline Picker dropdown (every timeline Dialogic knows about, plus
## a Browse… entry that opens a real OS file dialog) and an optional Start At Label. The other
## three operations act on whatever timeline is currently playing.
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
## Section map: [config / mode enum] → [timeline picker: virtual property] → [start-at-label
## visibility] → [metadata] → [native OS Browse dialog + EditorFileDialog fallback] →
## [action lifecycle] → [Dialogic autoload resolution] → [signal bridge watcher].


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

## The picked timeline's full res:// path — the only value this action actually saves for the
## picker. Hidden from the inspector (edited through Timeline Picker below); surfaced/stored
## via _get_property_list, same split as BazSceneCheckCondition's Scene Picker.
var timeline_path: String = ""

## Which label inside the timeline to start from.[br]Blank (default) starts from the top.
@export var start_at_label: String = ""

## Top entry of the Timeline Picker dropdown — opens the native OS Browse dialog.
const _BROWSE_LABEL: String = "Browse…"


# --- Timeline picker (pretty label shown, full res:// path stored) --------------
# A String PROPERTY_HINT_ENUM stores label == value, so it can't show a friendly identifier
# while storing a path. So we surface a virtual int "timeline_picker" (the dropdown —
# EDITOR-only, never saved) and keep the real value in "timeline_path" (STORAGE-only, hidden).
# The picker's index is derived FRESH from timeline_path on every read, so re-scanning the
# Dialogic timeline directory in a different order can never corrupt the saved choice.
#
# The picker is emitted only for Start Timeline mode (the other three operations act on
# whatever is already playing and need no timeline choice); timeline_path is always emitted
# (STORAGE-only) so switching away from Start Timeline and back never drops the saved pick.

func _get_property_list() -> Array[Dictionary]:
	var props: Array[Dictionary] = []
	if dialogic_operation == OP_START_TIMELINE:
		var lists: Dictionary = _build_picker_lists()
		var labels: PackedStringArray = lists["labels"]
		props.append({
			"name": "timeline_picker",
			"type": TYPE_INT,
			"hint": PROPERTY_HINT_ENUM,
			"hint_string": ",".join(labels),
			"usage": PROPERTY_USAGE_EDITOR,
		})
	props.append({
		"name": "timeline_path",
		"type": TYPE_STRING,
		"usage": PROPERTY_USAGE_STORAGE,
	})
	return props


func _get(property: StringName) -> Variant:
	if property == &"timeline_picker":
		return _current_picker_index()
	return null


func _set(property: StringName, value: Variant) -> bool:
	if property == &"timeline_picker":
		var index: int = int(value)
		if index == 0:
			# Browse… is a COMMAND, not a stored value — open the dialog and snap the
			# dropdown back to whatever is actually saved (deferred so the popup finishes
			# closing before a new window opens, same as BazGenerateSceneAction's scene_choice).
			if Engine.is_editor_hint():
				_open_browse_dialog.call_deferred()
				notify_property_list_changed()
			return true
		var paths: PackedStringArray = _build_picker_lists()["paths"]
		if index >= 0 and index < paths.size():
			timeline_path = paths[index]
			notify_property_list_changed()
		return true
	return false


## Only the hidden store is revertable. The picker itself is NOT: its index 0 is the Browse…
## command, so an inspector revert arrow on it would pop the file dialog instead of clearing.
func _property_can_revert(property: StringName) -> bool:
	return property == &"timeline_path"


func _property_get_revert(property: StringName) -> Variant:
	if property == &"timeline_path":
		return ""
	return null


## Ordered { "labels": dropdown text, "paths": index-aligned res:// paths (or "" for Browse) }.
## Index 0 is always the Browse… command. If the saved timeline_path isn't among Dialogic's
## known timelines (deleted/renamed), a "(missing) …" entry is inserted right after Browse so
## the choice is never silently blanked. Identifiers containing a comma are skipped — the
## enum hint_string is comma-delimited.
func _build_picker_lists() -> Dictionary:
	var labels: PackedStringArray = PackedStringArray()
	var paths: PackedStringArray = PackedStringArray()
	labels.append(_BROWSE_LABEL)
	paths.append("")

	var dtl_dir: Dictionary = ProjectSettings.get_setting("dialogic/directories/dtl_directory", {})
	var identifiers: Array[String] = _sorted_dtl_identifiers(dtl_dir)

	var known_paths: PackedStringArray = PackedStringArray()
	for id_str in identifiers:
		known_paths.append(String(dtl_dir[id_str]))

	if timeline_path != "" and not known_paths.has(timeline_path):
		labels.append("(missing) " + timeline_path.get_file())
		paths.append(timeline_path)

	for id_str in identifiers:
		labels.append(id_str)
		paths.append(String(dtl_dir[id_str]))

	return {"labels": labels, "paths": paths}


## Every key of the Dialogic timeline directory dict, comma-free, sorted case-insensitively.
static func _sorted_dtl_identifiers(dtl_dir: Dictionary) -> Array[String]:
	var identifiers: Array[String] = []
	for key in dtl_dir.keys():
		var id_str: String = String(key)
		if id_str.find(",") == -1:
			identifiers.append(id_str)
	identifiers.sort_custom(func(a: String, b: String) -> bool: return a.to_lower() < b.to_lower())
	return identifiers


## The dropdown index for the currently-stored timeline_path (0 = Browse… / nothing picked
## yet). Recomputed each call — never cached, so a re-scan can't corrupt the saved choice.
func _current_picker_index() -> int:
	var paths: PackedStringArray = _build_picker_lists()["paths"]
	for i in paths.size():
		if paths[i] == timeline_path:
			return i
	return 0


# --- Start-at-label visibility ---------------------------------------------------

## Start At Label only applies to Start Timeline — hide it for the other three operations.
func _validate_property(property: Dictionary) -> void:
	if property.name == "start_at_label" and dialogic_operation != OP_START_TIMELINE:
		property.usage = PROPERTY_USAGE_NO_EDITOR


# --- AGMaker plugin metadata ------------------------------------------------------

func get_plugin_tab_name() -> String:
	return "CustomAction"


func get_group_name() -> String:
	return "Dialogic"


func get_description() -> String:
	return "Start, stop, pause or resume a Dialogic timeline."


# --- Native OS file dialog (Browse) — EditorFileDialog fallback -------------------

const _BROWSE_FILTER: String = "*.dtl ; Dialogic Timeline"
const _BROWSE_TITLE: String = "Pick a Dialogic Timeline"

# Windows whose exclusive flag we released so the EditorFileDialog fallback could claim
# the editor root (normally just AGM's action-settings dialog). Editor-only, never
# serialized. The NATIVE OS dialog lives outside Godot's Window tree entirely, so this
# dance is only ever needed on the fallback path.
var _released_exclusive_windows: Array[Window] = []

# The fallback EditorFileDialog instance — kept only long enough to free it after use.
var _fallback_dialog: EditorFileDialog = null


## Opens a searchable file picker for timeline_path. Prefers the native OS dialog
## (DisplayServer.FEATURE_NATIVE_DIALOG_FILE) — an OS-level window outside Godot's Window
## tree, so it can never collide with AGM's exclusive action-settings dialog. Falls back
## to an EditorFileDialog (which DOES need the exclusivity release/restore dance) when
## the platform has no native file dialog.
func _open_browse_dialog() -> void:
	if not Engine.is_editor_hint():
		return
	if DisplayServer.has_feature(DisplayServer.FEATURE_NATIVE_DIALOG_FILE):
		var err: Error = DisplayServer.file_dialog_show(
			_BROWSE_TITLE,
			ProjectSettings.globalize_path("res://"),
			"",
			false,
			DisplayServer.FILE_DIALOG_MODE_OPEN_FILE,
			PackedStringArray([_BROWSE_FILTER]),
			_on_native_dialog_result
		)
		if err != OK:
			push_warning("[BazDialogicAction] native file dialog failed to open (error %d) — falling back to EditorFileDialog" % err)
			_open_fallback_dialog()
	else:
		_open_fallback_dialog()


## Native dialog callback (status: bool, selected_paths: PackedStringArray,
## selected_filter_index: int) — thread NOT documented-guaranteed to be main, so it does
## no real work itself; it just bounces the payload to a deferred call.
func _on_native_dialog_result(status: bool, selected_paths: PackedStringArray, _filter_idx: int) -> void:
	_handle_picked_path.call_deferred(status, selected_paths)


## EditorFileDialog fallback for platforms without a native file dialog. AGM's
## action-settings dialog is an EXCLUSIVE child window of the editor root, and a window
## may hold only ONE exclusive child — popping another exclusive Window on the same root
## logs a window.cpp:992 refusal. Release the claim while the picker is up; the
## file_selected/canceled handlers restore it.
func _open_fallback_dialog() -> void:
	_release_exclusive_windows()
	_fallback_dialog = EditorFileDialog.new()
	_fallback_dialog.file_mode = EditorFileDialog.FILE_MODE_OPEN_FILE
	_fallback_dialog.access = EditorFileDialog.ACCESS_RESOURCES
	_fallback_dialog.add_filter("*.dtl", "Dialogic Timeline")
	_fallback_dialog.file_selected.connect(_on_fallback_file_selected)
	_fallback_dialog.canceled.connect(_on_fallback_canceled)
	EditorInterface.get_base_control().add_child(_fallback_dialog)
	_fallback_dialog.popup_file_dialog()


func _on_fallback_file_selected(path: String) -> void:
	# Deferred: the dialog may still be closing when this fires — restoring exclusivity
	# now would recreate the same window.cpp:992 conflict in reverse.
	_restore_exclusive_windows.call_deferred()
	_handle_picked_path.call_deferred(true, PackedStringArray([path]))
	_free_fallback_dialog()


func _on_fallback_canceled() -> void:
	_restore_exclusive_windows.call_deferred()
	_free_fallback_dialog()


func _free_fallback_dialog() -> void:
	if is_instance_valid(_fallback_dialog):
		_fallback_dialog.queue_free()
	_fallback_dialog = null


func _release_exclusive_windows() -> void:
	_released_exclusive_windows.clear()
	var editor_root: Node = EditorInterface.get_base_control().get_tree().root
	_collect_exclusive_windows(editor_root, _released_exclusive_windows)
	for w in _released_exclusive_windows:
		w.exclusive = false


## Collects every VISIBLE exclusive Window below n (include_internal — editor dialogs are
## often internal children). One walk per Browse click; not a hot path.
static func _collect_exclusive_windows(n: Node, out: Array[Window]) -> void:
	for child in n.get_children(true):
		var w: Window = child as Window
		if w != null and w.visible and w.exclusive:
			out.append(w)
		_collect_exclusive_windows(child, out)


func _restore_exclusive_windows() -> void:
	for w in _released_exclusive_windows:
		if is_instance_valid(w) and w.visible:
			w.exclusive = true
	_released_exclusive_windows.clear()


## Validates and stores a picked absolute OS path, or leaves timeline_path untouched on
## cancel/invalid pick. Reached only via call_deferred (both the native callback and the
## fallback signal handlers route through here) so it always runs on the main thread.
func _handle_picked_path(status: bool, selected_paths: PackedStringArray) -> void:
	if not Engine.is_editor_hint():
		return
	if not status or selected_paths.is_empty():
		return   # cancelled — keep the old value
	var localized: String = ProjectSettings.localize_path(selected_paths[0])
	if not localized.begins_with("res://"):
		push_warning("[BazDialogicAction] the picked file must be inside this project — ignored: %s" % localized)
		return
	if not localized.ends_with(".dtl"):
		push_warning("[BazDialogicAction] the picked file isn't a .dtl timeline — ignored: %s" % localized)
		return
	timeline_path = localized
	EditorInterface.get_resource_filesystem().scan.call_deferred()
	notify_property_list_changed()


# --- Action lifecycle --------------------------------------------------------------
# AGM 1.3.0 over-supplies args to action lifecycle methods (on_state_update gets an extra
# delta), so ALL THREE need two trailing optional Variants or they raise "[AGMPluginAction]
# Method call failed. error code = 3" every frame (skill §7 pitfall 11).

## Warn only once per run that Dialogic couldn't be found (plugin disabled, or the autoload
## isn't named "Dialogic"), rather than spamming a push_warning every time this fires.
static var _warned_missing_dialogic: bool = false

## Warn only once per run that Start Timeline was used with no timeline picked.
static var _warned_empty_timeline: bool = false

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
## when Dialogic reports back, then starts the picked timeline. No `await` here (skill §7
## pitfall 3) — all deferred work lives in the bridge watcher below.
func _do_start_timeline(dialogic: Node, owner_node: Node) -> void:
	if timeline_path.is_empty():
		if not _warned_empty_timeline:
			_warned_empty_timeline = true
			push_warning("[BazDialogicAction] Start Timeline has no timeline picked — no-op.")
		return
	var bridge: Node = _ensure_bridge(owner_node.get_tree())
	if bridge != null:
		bridge.set("pending_owner", weakref(owner_node))
	if dialogic.has_method("start"):
		# Path form: a String containing "res://" is loaded as a path, so no identifier
		# lookup is needed at runtime (dialogic-action-condition plan, Context).
		if bridge != null and not bridge.is_inside_tree():
			# First start of the run: the bridge's add_child is still queued, so its _ready
			# (where it connects to Dialogic) hasn't run. Queue the start behind it — deferred
			# calls run in order — or a Signal event as the timeline's FIRST event would be
			# emitted before anyone is listening. Costs one frame, once per run.
			dialogic.call_deferred("start", timeline_path, start_at_label)
		else:
			dialogic.call("start", timeline_path, start_at_label)
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
