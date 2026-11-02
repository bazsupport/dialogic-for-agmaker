# Deviations from stock Dialogic 2.0 Alpha 16

Re-apply these when upgrading the bundled Dialogic.

1. `BazDialogicLink/` folder — added (node script `baz_dialogic_link.gd`, `icon.png`, this file).
2. `Modules/Variable/subsystem_variables.gd` — `return null` appended to both `_get`
   overrides (the outer subsystem function and the inner `VariableFolder` class).
   Reason: Godot 4.7 "Not all code paths return a value" parse error. Added in v1.1.1.
3. `Modules/Text/node_name_label.gd` — `return false` appended to the `_set` override.
   Same reason (Godot 4.7 "Not all code paths return a value"). Added in v1.1.1.
4. `Modules/Choice/subsystem_choices.gd` — modified in v1.1 so choices take standard
   timeline input for selection (per the v1.1 release notes). Exact hunk: see git
   history, commit 03f0f4d "added choices".
5. `Editor/Common/reference_manager_window.gd` and `Editor/Common/update_install_window.gd`
   — modified between v1.0 and v1.1 (commits 320849b, f133f80). Exact hunks: see git history.
6. `custom_actions/BazDialogicAction.gd` — added v1.2, AGMaker custom action (Start Timeline /
   End Timeline / Pause / Resume). Carry the folder over on upgrade.
7. `custom_conditions/BazDialogicCondition.gd` — added v1.2, AGMaker custom condition (Timeline
   Ended / Choice Picked / Dialogue Active). Carry the folder over on upgrade.
8. `BazDialogicLink/baz_dialogic_link.gd` — v1.2.1: reaches Dialogic through
   `get_tree().root.get_node_or_null(^"Dialogic")` + `connect`/`call` instead of the bare `Dialogic`
   identifier, so the script still loads before the Dialogic plugin is enabled. Same pattern as the action.
9. `Modules/Text/event_text.gd` — v1.2.2: in `_execute`, both `change_style` calls (back to the base style,
   and to the character's style) now store the upcoming speaker in `current_state_info['speaker']` for the
   swap and restore the previous value after the `await`. A rebuilt layout reloads the stored speaker, which
   left the previous speaker's portrait under the new one (upstream issue #2458). Upstream PR #2464 set the
   speaker without restoring it, which skips `change_speaker`'s highlight swap. Alpha 17 replaced that with a
   reorder (PR #2543). Drop this patch when upgrading to Alpha 17 or later.
10. `plugin.gd` — v1.2.3: removed `remove_control_from_bottom_panel(editor_view)` from `_exit_tree`. The editor
   view lives on the main screen, never the bottom panel, so on AGMaker 2.0 (Godot 4.7) that call printed
   `Cannot remove unknown dock "EditorView" from the bottom panel` when closing AGMaker or disabling the plugin.
   Later upstream versions (Alpha 19) already drop the line, so this patch is not needed after upgrading.
11. `Modules/Text/event_text.gd` — v1.2.4: in `_execute`, both `change_style` calls no longer
   `await get_tree().process_frame`. They keep the returned layout and `await layout.ready` only when it is a
   new layout not yet in the tree, and don't wait at all when the layout was reused (`change_style` returns null)
   or the style didn't change. A rebuilt layout is added with `call_deferred` and reloads the current state (the
   previous line) on `ready`. The old one-frame wait let that frame draw, so the previous line showed in the new
   style (e.g. at the new speaker's font size) before the new line replaced it. A reused layout had the same
   frame, with the new overrides applied to the old line. Upstream still has the frame wait as of Alpha 20 /
   main, so re-apply this (adapted to the reordered `_execute`) when upgrading.
