# Deviations from stock Dialogic 2.0 Alpha 16

Re-apply these when upgrading the bundled Dialogic.

1. `BazDialogicLink/` folder — added (node script `baz_dialogic_link.gd`, `icon.png`, this file).
2. `Modules/Variable/subsystem_variables.gd` — `return null` appended to both `_get`
   overrides (the outer subsystem function and the inner `VariableFolder` class).
   Reason: Godot 4.7 "Not all code paths return a value" parse error. Added in v1.1.1.
3. `Modules/Choice/subsystem_choices.gd` — modified in v1.1 so choices take standard
   timeline input for selection (per the v1.1 release notes). Exact hunk: see git
   history, commit 03f0f4d "added choices".
4. `Editor/Common/reference_manager_window.gd` and `Editor/Common/update_install_window.gd`
   — modified between v1.0 and v1.1 (commits 320849b, f133f80). Exact hunks: see git history.
