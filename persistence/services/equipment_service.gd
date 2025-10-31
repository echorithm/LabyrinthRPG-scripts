# res://persistence/services/equipment_service.gd
extends RefCounted
class_name EquipmentService
## RUN-only equipment management (A1/B1 policy).
## - Equips by uid from RUN.inventory -> RUN.equipped_bank + writes uid to RUN.equipment[slot].
## - Unequips moves from bank -> inventory.
## - Rebuilds buffs/tags via BuffService after any change.
## - No META writes; Exit/Defeat flows mirror at run end.

const DEFAULT_SLOT: int = 1

# --------------------------------------------------------------------------
# Public API
# --------------------------------------------------------------------------
static func equip(uid: String, slot_hint: String = "", slot: int = DEFAULT_SLOT) -> Dictionary:
	if uid.strip_edges().is_empty():
		return { "ok": false, "reason": "bad_uid" }

	var rs: Dictionary = SaveManager.load_run(slot)
	var inv: Array = _as_array(rs.get("inventory", []))
	var eq: Dictionary = SaveUtils.to_dict(rs.get("equipment", {}))
	var bank: Dictionary = SaveUtils.to_dict(rs.get("equipped_bank", {}))

	# Pop from inventory (if not present but already equipped, treat as success)
	var it: Dictionary = _pop_inventory_by_uid(inv, uid)
	if it.is_empty():
		if bank.has(uid):
			var slot_name: String = _find_slot_holding(eq, uid)
			var buffs_idempotent: Array[String] = _rebuild_buffs(slot)
			return { "ok": true, "equipped_uid": uid, "slot": slot_name, "buffs": buffs_idempotent }
		return { "ok": false, "reason": "not_in_inventory" }

	# Must be gear
	if not _is_gear(it):
		# put back
		inv.append(it)
		rs["inventory"] = inv
		SaveManager.save_run(rs, slot)
		return { "ok": false, "reason": "not_gear" }

	# Resolve target slot
	var resolved_slot: String = _resolve_slot_for_item(it, slot_hint)
	if resolved_slot.is_empty():
		inv.append(it)
		rs["inventory"] = inv
		SaveManager.save_run(rs, slot)
		return { "ok": false, "reason": "no_valid_slot" }

	# Swap: if occupied, return prior to inventory
	var swapped_uid: String = ""
	var prev_any: Variant = eq.get(resolved_slot, null)
	if prev_any != null:
		var prev_uid: String = String(prev_any)
		if not prev_uid.is_empty():
			var prev_row_any: Variant = bank.get(prev_uid, null)
			if typeof(prev_row_any) == TYPE_DICTIONARY:
				var prev_row: Dictionary = prev_row_any as Dictionary
				inv.append(prev_row.duplicate(true))
			swapped_uid = prev_uid
			bank.erase(prev_uid)

	# Move new item into bank and write uid into slot
	var ensured_uid: String = _ensure_uid(it)
	bank[ensured_uid] = it.duplicate(true)
	eq[resolved_slot] = ensured_uid

	# Persist
	rs["inventory"] = inv
	rs["equipped_bank"] = bank
	rs["equipment"] = _normalize_slots(eq)
	SaveManager.save_run(rs, slot)

	# Rebuild buffs + ping RunState
	var buffs: Array[String] = _rebuild_buffs(slot)
	_reload_runstate(slot)

	return {
		"ok": true,
		"equipped_uid": ensured_uid,
		"slot": resolved_slot,
		"swapped_uid": swapped_uid,
		"buffs": buffs
	}


static func unequip(slot_name: String, slot: int = DEFAULT_SLOT) -> Dictionary:
	var s: String = slot_name.strip_edges().to_lower()
	if not _valid_slot_names().has(s):
		return { "ok": false, "reason": "bad_slot" }

	var rs: Dictionary = SaveManager.load_run(slot)
	var inv: Array = _as_array(rs.get("inventory", []))
	var eq: Dictionary = SaveUtils.to_dict(rs.get("equipment", {}))
	var bank: Dictionary = SaveUtils.to_dict(rs.get("equipped_bank", {}))

	var uid_any: Variant = eq.get(s, null)
	if uid_any == null:
		return { "ok": true, "unequipped_uid": "" }

	var uid: String = String(uid_any)
	if uid.is_empty():
		eq[s] = null
		rs["equipment"] = _normalize_slots(eq)
		SaveManager.save_run(rs, slot)
		_reload_runstate(slot)
		return { "ok": true, "unequipped_uid": "" }

	var row_any: Variant = bank.get(uid, null)
	if typeof(row_any) == TYPE_DICTIONARY:
		var row: Dictionary = row_any as Dictionary
		inv.append(row.duplicate(true))

	eq[s] = null
	bank.erase(uid)

	rs["inventory"] = inv
	rs["equipped_bank"] = bank
	rs["equipment"] = _normalize_slots(eq)
	SaveManager.save_run(rs, slot)

	var buffs: Array[String] = _rebuild_buffs(slot)
	_reload_runstate(slot)

	return { "ok": true, "unequipped_uid": uid, "buffs": buffs }


static func equipment_snapshot(slot: int = DEFAULT_SLOT) -> Dictionary:
	var rs: Dictionary = SaveManager.load_run(slot)
	return SaveUtils.to_dict(rs.get("equipment", {})).duplicate(true)

static func equipped_bank_snapshot(slot: int = DEFAULT_SLOT) -> Dictionary:
	var rs: Dictionary = SaveManager.load_run(slot)
	return SaveUtils.to_dict(rs.get("equipped_bank", {})).duplicate(true)

static func inventory_snapshot(slot: int = DEFAULT_SLOT) -> Array:
	var rs: Dictionary = SaveManager.load_run(slot)
	return _as_array(rs.get("inventory", [])).duplicate(true)

static func is_equipped(uid: String, slot: int = DEFAULT_SLOT) -> bool:
	var rs: Dictionary = SaveManager.load_run(slot)
	var eq: Dictionary = SaveUtils.to_dict(rs.get("equipment", {}))
	return not _find_slot_holding(eq, uid).is_empty()

# --------------------------------------------------------------------------
# Internals (typed)
# --------------------------------------------------------------------------
static func _as_array(v: Variant) -> Array:
	return (v as Array) if v is Array else []

static func _valid_slot_names() -> PackedStringArray:
	return PackedStringArray(["head","chest","legs","boots","mainhand","offhand","ring1","ring2","amulet"])

static func _normalize_slots(eq_in: Dictionary) -> Dictionary:
	var out: Dictionary = {
		"head": null, "chest": null, "legs": null, "boots": null,
		"mainhand": null, "offhand": null, "ring1": null, "ring2": null, "amulet": null
	}
	for k in out.keys():
		out[k] = eq_in.get(k, null)
	return out

static func _is_gear(it: Dictionary) -> bool:
	var dmax: int = int(it.get("durability_max", 0))
	if it.has("opts") and it["opts"] is Dictionary:
		var o: Dictionary = it["opts"] as Dictionary
		dmax = max(dmax, int(o.get("durability_max", 0)))
	return dmax > 0

static func _ensure_uid(it_in: Dictionary) -> String:
	var it: Dictionary = it_in
	var uid: String = String(it.get("uid", ""))
	if not uid.is_empty():
		return uid
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.randomize()
	var a: int = int(Time.get_ticks_usec()) & 0x7FFFFFFF
	var b: int = int(rng.randi() & 0x7FFFFFFF)
	uid = "u%08x%08x" % [a, b]
	it["uid"] = uid
	return uid

static func _pop_inventory_by_uid(inv_in: Array, uid: String) -> Dictionary:
	for i: int in range(inv_in.size()):
		var v_any: Variant = inv_in[i]
		if typeof(v_any) == TYPE_DICTIONARY:
			var row: Dictionary = v_any as Dictionary
			if String(row.get("uid", "")) == uid:
				inv_in.remove_at(i)
				return row.duplicate(true)
	return {}

static func _find_slot_holding(eq: Dictionary, uid: String) -> String:
	for k_any: Variant in eq.keys():
		var k: String = String(k_any)
		var v: Variant = eq[k]
		if v != null and String(v) == uid:
			return k
	return ""

static func _resolve_slot_for_item(it: Dictionary, slot_hint: String) -> String:
	var hint := slot_hint.strip_edges().to_lower()

	# --- determine allowed slots for this item ---
	var id_str: String = String(it.get("id", ""))
	var arche: String = String(it.get("archetype", ""))

	var allowed: PackedStringArray = []
	if id_str.begins_with("weapon_") or ["Sword","Spear","Bow","Mace"].has(arche):
		# v1: weapons only in mainhand (offhand later)
		allowed = PackedStringArray(["mainhand"])
	elif id_str.begins_with("armor_") or ["Light","Heavy","Mage"].has(arche):
		# v1: our generator makes generic armor pieces; we map them to chest
		allowed = PackedStringArray(["chest"])
	elif id_str.begins_with("amulet_") or id_str == "amulet_generic":
		allowed = PackedStringArray(["amulet"])
	elif id_str.begins_with("ring_") or id_str == "ring_generic":
		allowed = PackedStringArray(["ring1","ring2"])
	else:
		# Unknown-but-gear fallback (weapons-like)
		if _is_gear(it):
			allowed = PackedStringArray(["mainhand"])

	# If we have a valid hint AND it is allowed, prefer it
	if not hint.is_empty() and allowed.has(hint):
		# special handling for rings: choose first empty between ring1/ring2 if hint is a generic "ring"
		if hint == "ring":
			var rs_now := SaveManager.load_run(DEFAULT_SLOT)
			var eq_now: Dictionary = SaveUtils.to_dict(rs_now.get("equipment", {}))
			if eq_now.get("ring1", null) == null:
				return "ring1"
			if eq_now.get("ring2", null) == null:
				return "ring2"
			return "ring1"
		return hint

	# No (usable) hint → pick a sensible slot from allowed
	if allowed.is_empty():
		return ""

	# rings: choose first empty, else ring1
	if allowed.has("ring1") or allowed.has("ring2"):
		var rs2 := SaveManager.load_run(DEFAULT_SLOT)
		var eq2: Dictionary = SaveUtils.to_dict(rs2.get("equipment", {}))
		if eq2.get("ring1", null) == null:
			return "ring1"
		if eq2.get("ring2", null) == null:
			return "ring2"
		return "ring1"

	# otherwise just the first allowed
	return allowed[0]


static func _rebuild_buffs(slot: int) -> Array[String]:
	return BuffService.rebuild_run_buffs(slot)

static func _reload_runstate(_slot: int) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree and tree.root:
		var rs := tree.root.get_node_or_null(^"/root/RunState")
		if rs:
			# Do NOT call reload() here; just notify panels to refresh from disk snapshot
			if rs.has_signal("changed"):
				rs.call_deferred("emit_signal", "changed")


static func equip_from_run_index(run_index: int, slot_name: String, slot: int = DEFAULT_SLOT) -> Dictionary:
	var rs: Dictionary = SaveManager.load_run(slot)
	var inv: Array = (rs.get("inventory", []) as Array)
	if run_index < 0 or run_index >= inv.size():
		return { "ok": false, "error": "index_oob" }
	var row_any: Variant = inv[run_index]
	if typeof(row_any) != TYPE_DICTIONARY:
		return { "ok": false, "error": "not_item" }
	var row: Dictionary = row_any as Dictionary
	var dmax: int = int(row.get("durability_max", 0))
	if dmax <= 0:
		return { "ok": false, "error": "not_gear" }
	var uid: String = String(row.get("uid", ""))
	if uid.is_empty():
		# give it a uid in-place then persist, so the UI metadata stays valid
		var ensured: String = _ensure_uid(row)
		inv[run_index] = row
		rs["inventory"] = inv
		SaveManager.save_run(rs, slot)
		uid = ensured
	# delegate to the new API
	var rc: Dictionary = equip(uid, slot_name, slot)
	if bool(rc.get("ok", false)):
		return { "ok": true, "slot": String(rc.get("slot","")), "uid": uid, "index": run_index }
	return { "ok": false, "error": String(rc.get("reason","equip_failed")) }

static func unequip_slot(slot_name: String, slot: int = DEFAULT_SLOT) -> bool:
	var s: String = slot_name.strip_edges().to_lower()
	if not _valid_slot_names().has(s):
		return false

	var rs: Dictionary = SaveManager.load_run(slot)
	var eq: Dictionary = SaveUtils.to_dict(rs.get("equipment", {}))
	var bank: Dictionary = SaveUtils.to_dict(rs.get("equipped_bank", {}))
	var inv: Array = _as_array(rs.get("inventory", []))

	# Nothing equipped in this slot → still normalize + rebuild so UI reflects it
	var uid_any: Variant = eq.get(s, null)
	if uid_any == null or String(uid_any).is_empty():
		eq[s] = null
		rs["equipment"] = _normalize_slots(eq)
		SaveManager.save_run(rs, slot)
		_rebuild_buffs(slot)      # ← ensure mods_affix / buffs update
		_reload_runstate(slot)    # ← ping UI listeners
		return true

	var uid: String = String(uid_any)

	# Move banked item back into inventory (if present)
	var row_any: Variant = bank.get(uid, null)
	if typeof(row_any) == TYPE_DICTIONARY:
		inv.append((row_any as Dictionary).duplicate(true))
	bank.erase(uid)

	# Clear slot, persist
	eq[s] = null
	rs["inventory"] = inv
	rs["equipped_bank"] = bank
	rs["equipment"] = _normalize_slots(eq)
	SaveManager.save_run(rs, slot)

	# Recompute run modifiers and notify UI
	_rebuild_buffs(slot)         # ← important: clears mods_affix when no gear
	_reload_runstate(slot)

	return true
