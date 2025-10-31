# res://scripts/village/modal/bodies/IModalBody.gd
# Minimal, duck-typed contract for bodies mounted by BuildingModalShell.
# This file is intentionally "comments + constants" only; no inheritance needed.

extends Node
class_name IModalBody

## Expected methods (duck typing)
## --------------------------------
# func bind_shell(shell: BuildingModalShell) -> void
# func set_context(kind: StringName, instance_id: StringName, coord: Vector2i, slot: int) -> void
# func enter(ctx: Dictionary) -> void
# func refresh(ctx: Dictionary) -> void
# func get_tabs() -> PackedStringArray
# func on_tab_changed(idx: int) -> void
# Optional:
# func get_footer_actions() -> Array[Dictionary]    # [{ id:String, label:String, enabled:bool }]
# func on_primary_action(action_id: StringName) -> void

## Signals the body may emit (VendorBody already uses these)
signal request_buy(item_id: StringName, qty: int)
signal request_sell(item_id: StringName, qty: int)

## Useful shared keys so Shell/Service/Body agree without magic strings.
const KEY_STOCK := "stock"               # Array[Dictionary]
const KEY_SELLABLES := "sellables"       # Array[Dictionary]
const KEY_STASH_GOLD := "stash_gold"     # int
const KEY_ACTIVE := "active"             # bool
