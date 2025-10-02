extends RefCounted
class_name EquipmentService

const _S := preload("res://persistence/util/save_utils.gd")

const DEFAULT_SLOT: int = 1

const SLOTS: PackedStringArray = [
	"head","chest","legs","boots",
	"mainhand","offhand","ring1","ring2","amulet"
]

# -------------------------------------------------------------------
# Equip by RUN inventory index
# Moves the item from inventory → equipped_bank, and writes its uid into equipment[slot_name].
# Returns: { ok:bool, slot:String, uid:String, index:int } or { ok:false, error:String }
# -------------------------------------------------------------------
static func equip_from_run_index(run_index: int, slot_name: String, slot: int = DEFAULT_SLOT) -> Dictionary:
	if not SLOTS.has(slot_name):
		return { "ok": false, "error": "invalid_slot" }

	var rs: Dictionary = SaveManager.load_run(slot)

	# Inventory
	var inv_any: Variant = _S.dget(rs, "inventory", [])
	var inv: Array = (inv_any as Array) if inv_any is Array else []

	if run_index < 0 or run_index >= inv.size():
		return { "ok": false, "error": "index_oob" }

	var row_any: Variant = inv[run_index]
	if typeof(row_any) != TYPE_DICTIONARY:
		return { "ok": false, "error": "not_item" }
	var row: Dictionary = row_any as Dictionary

	# Must be gear (non-stackable → durability_max > 0)
	var dmax: int = int(_S.dget(row, "durability_max", 0))
	if dmax <= 0:
		return { "ok": false, "error": "not_gear" }

	# Needs a uid
	var uid: String = String(_S.dget(row, "uid", ""))
	if uid.is_empty():
		return { "ok": false, "error": "missing_uid" }

	# Tables
	var bank_any: Variant = _S.dget(rs, "equipped_bank", {})
	var bank: Dictionary = (bank_any as Dictionary) if bank_any is Dictionary else {}

	var eq_any: Variant = _S.dget(rs, "equipment", {})
	var eq: Dictionary = (eq_any as Dictionary) if eq_any is Dictionary else {
		"head": null, "chest": null, "legs": null, "boots": null,
		"mainhand": null, "offhand": null, "ring1": null, "ring2": null, "amulet": null
	}

	# If the same uid is already in any slot, clear it (uniqueness)
	for k_any in eq.keys():
		var k: String = str(k_any)
		if str(_S.dget(eq, k, "")) == uid:
			# if previously equipped, put that banked item back to inventory
			var prev_row_any: Variant = _S.dget(bank, uid, null)
			if prev_row_any is Dictionary:
				inv.append(prev_row_any as Dictionary)
			bank.erase(uid)
			eq[k] = null

	# If something is already in target slot, return it to inventory
	var prior_uid_any: Variant = _S.dget(eq, slot_name, null)
	if prior_uid_any != null:
		var prior_uid: String = String(prior_uid_any)
		if not prior_uid.is_empty():
			var prior_row_any: Variant = _S.dget(bank, prior_uid, null)
			if prior_row_any is Dictionary:
				inv.append(prior_row_any as Dictionary)
			bank.erase(prior_uid)

	# Move selected item from inventory → bank, write uid into slot
	eq[slot_name] = uid
	inv.remove_at(run_index)
	bank[uid] = row

	# Persist
	rs["inventory"] = inv
	rs["equipment"] = eq
	rs["equipped_bank"] = bank
	SaveManager.save_run(rs, slot)

	# Optional: rebuild buffs if you have such a system available
	if Engine.has_singleton("BuffService") or ClassDB.class_exists("BuffService"):
		BuffService.rebuild_run_buffs(slot)

	return { "ok": true, "slot": slot_name, "uid": uid, "index": run_index }


# -------------------------------------------------------------------
# Equip directly by uid (searches the RUN inventory for the uid)
# -------------------------------------------------------------------
static func equip_uid(slot_name: String, uid: String, slot: int = DEFAULT_SLOT) -> bool:
	if not SLOTS.has(slot_name): return false
	if uid.is_empty(): return false

	var rs: Dictionary = SaveManager.load_run(slot)
	var inv: Array = (_S.dget(rs, "inventory", []) as Array)
	var bank: Dictionary = (_S.dget(rs, "equipped_bank", {}) as Dictionary)
	var eq: Dictionary = (_S.dget(rs, "equipment", {}) as Dictionary)

	# Find index of the item in inventory
	var index: int = -1
	for i in range(inv.size()):
		var it_any: Variant = inv[i]
		if it_any is Dictionary:
			var it: Dictionary = it_any as Dictionary
			if str(_S.dget(it, "uid", "")) == uid and int(_S.dget(it, "durability_max", 0)) > 0:
				index = i
				break
	if index < 0:
		return false

	# Clear any other slot using this uid
	for k_any in eq.keys():
		var k: String = str(k_any)
		if str(_S.dget(eq, k, "")) == uid:
			# Return banked copy to inv if present
			var prev_row_any: Variant = _S.dget(bank, uid, null)
			if prev_row_any is Dictionary:
				inv.append(prev_row_any as Dictionary)
			bank.erase(uid)
			eq[k] = null

	# Swap out prior in target slot
	var prior_uid_any: Variant = _S.dget(eq, slot_name, null)
	if prior_uid_any != null:
		var prior_uid: String = String(prior_uid_any)
		if not prior_uid.is_empty():
			var prior_row_any: Variant = _S.dget(bank, prior_uid, null)
			if prior_row_any is Dictionary:
				inv.append(prior_row_any as Dictionary)
			bank.erase(prior_uid)

	# Equip
	var row: Dictionary = inv[index]
	eq[slot_name] = uid
	inv.remove_at(index)
	bank[uid] = row

	rs["inventory"] = inv
	rs["equipment"] = eq
	rs["equipped_bank"] = bank
	SaveManager.save_run(rs, slot)

	if Engine.has_singleton("BuffService") or ClassDB.class_exists("BuffService"):
		BuffService.rebuild_run_buffs(slot)

	return true


# -------------------------------------------------------------------
# Unequip a slot: move banked item back to inventory
# -------------------------------------------------------------------
static func unequip_slot(slot_name: String, slot: int = DEFAULT_SLOT) -> bool:
	if not SLOTS.has(slot_name): return false

	var rs: Dictionary = SaveManager.load_run(slot)
	var eq: Dictionary = (_S.dget(rs, "equipment", {}) as Dictionary)
	var bank: Dictionary = (_S.dget(rs, "equipped_bank", {}) as Dictionary)
	var inv: Array = (_S.dget(rs, "inventory", []) as Array)

	if not eq.has(slot_name):
		return false
	var uid_any: Variant = eq[slot_name]
	if uid_any == null:
		return false

	var uid: String = String(uid_any)
	if uid.is_empty():
		return false

	# Retrieve from bank and return to inventory
	var row_any: Variant = _S.dget(bank, uid, null)
	if row_any is Dictionary:
		inv.append(row_any as Dictionary)
	bank.erase(uid)
	eq[slot_name] = null

	rs["inventory"] = inv
	rs["equipment"] = eq
	rs["equipped_bank"] = bank
	SaveManager.save_run(rs, slot)

	if Engine.has_singleton("BuffService") or ClassDB.class_exists("BuffService"):
		BuffService.rebuild_run_buffs(slot)

	return true


# -------------------------------------------------------------------
# Get a copy of the equipment mapping (slot -> uid or null)
# -------------------------------------------------------------------
static func get_equipped(slot: int = DEFAULT_SLOT) -> Dictionary:
	var rs: Dictionary = SaveManager.load_run(slot)
	return (_S.dget(rs, "equipment", {}) as Dictionary).duplicate(true)
