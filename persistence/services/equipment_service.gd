extends RefCounted
class_name EquipmentService

const _S := preload("res://persistence/util/save_utils.gd")

const DEFAULT_SLOT: int = 1

# Valid equipment slots in your schema
const SLOTS: PackedStringArray = [
	"head","chest","legs","boots",
	"mainhand","offhand","ring1","ring2","amulet"
]

# -------------------------------------------------------------------
# UI-friendly helper: equip by RUN inventory index
# Returns { ok:bool, slot:String, uid:String?, index:int, error?:String }
# -------------------------------------------------------------------
static func equip_from_run_index(run_index: int, slot_name: String, slot: int = DEFAULT_SLOT) -> Dictionary:
	# Validate slot
	if not SLOTS.has(slot_name):
		return { "ok": false, "index": run_index, "slot": slot_name, "error": "invalid_slot" }

	var rs: Dictionary = SaveManager.load_run(slot)
	var rinv_any: Variant = _S.dget(rs, "inventory", [])
	var rinv: Array = (rinv_any as Array) if rinv_any is Array else []

	# Validate index
	if run_index < 0 or run_index >= rinv.size():
		return { "ok": false, "index": run_index, "slot": slot_name, "error": "index_oob" }

	var row_any: Variant = rinv[run_index]
	if typeof(row_any) != TYPE_DICTIONARY:
		return { "ok": false, "index": run_index, "slot": slot_name, "error": "not_item" }

	var row: Dictionary = row_any as Dictionary
	var dmax: int = int(_S.dget(row, "durability_max", 0))
	if dmax <= 0:
		# Not gear (stackable/consumable)
		return { "ok": false, "index": run_index, "slot": slot_name, "error": "not_gear" }

	var uid: String = String(_S.dget(row, "uid", ""))
	if uid.is_empty():
		# Safety: if a gear row slipped in without uid, refuse (or assign here if you prefer)
		return { "ok": false, "index": run_index, "slot": slot_name, "error": "missing_uid" }

	var ok: bool = equip_uid(slot_name, uid, slot)
	return { "ok": ok, "index": run_index, "slot": slot_name, "uid": uid }

# -------------------------------------------------------------------
# Core equip/unequip by UID
# -------------------------------------------------------------------
static func equip_uid(slot_name: String, uid: String, slot: int = DEFAULT_SLOT) -> bool:
	if not SLOTS.has(slot_name): return false
	if uid.is_empty(): return false

	var rs: Dictionary = SaveManager.load_run(slot)
	var inv_any: Variant = _S.dget(rs, "inventory", [])
	var inv: Array = (inv_any as Array) if inv_any is Array else []
	var eq_any: Variant = _S.dget(rs, "equipment", {})
	var eq: Dictionary = (eq_any as Dictionary) if eq_any is Dictionary else {}

	# Find item by uid in RUN inventory and verify it's gear
	var found: bool = false
	for it_any: Variant in inv:
		if it_any is Dictionary:
			var it: Dictionary = it_any
			if String(_S.dget(it, "uid", "")) == uid and int(_S.dget(it, "durability_max", 0)) > 0:
				found = true
				break
	if not found:
		return false

	eq[slot_name] = uid
	rs["equipment"] = eq
	SaveManager.save_run(rs, slot)

	# Rebuild buffs if available (equipment affixes → buffs)
	if Engine.has_singleton("BuffService") or ClassDB.class_exists("BuffService"):
		BuffService.rebuild_run_buffs(slot)

	return true

static func unequip_slot(slot_name: String, slot: int = DEFAULT_SLOT) -> bool:
	if not SLOTS.has(slot_name): return false
	var rs: Dictionary = SaveManager.load_run(slot)
	var eq_any: Variant = _S.dget(rs, "equipment", {})
	var eq: Dictionary = (eq_any as Dictionary) if eq_any is Dictionary else {}
	if not eq.has(slot_name):
		return false
	eq[slot_name] = null
	rs["equipment"] = eq
	SaveManager.save_run(rs, slot)

	if Engine.has_singleton("BuffService") or ClassDB.class_exists("BuffService"):
		BuffService.rebuild_run_buffs(slot)

	return true

# Convenience
static func get_equipped(slot: int = DEFAULT_SLOT) -> Dictionary:
	var rs: Dictionary = SaveManager.load_run(slot)
	return (_S.dget(rs, "equipment", {}) as Dictionary).duplicate(true)
