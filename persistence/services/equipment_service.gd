# res://persistence/services/equipment_service.gd
extends RefCounted
class_name EquipmentService
## RUN-only equipment management (A1/B1 policy).
## - Equips by uid from RUN.inventory -> RUN.equipped_bank + writes uid to RUN.equipment[slot].
## - Unequips moves from bank -> inventory.
## - Rebuilds buffs/tags via BuffService after any change.
## - No META writes; Exit/Defeat flows mirror at run end.
## Changes:
## - Family-aware weapon slots: sword/spear/mace/bow
## - Strict classification (no fallback); unknown weapon family → error
## - Temporary gate: only Common rarity, no affixes
## - Debug API: spawn & equip Common/no-affix item for a slot

const DEFAULT_SLOT: int = 1

const _WEAPON_FAMILIES: PackedStringArray = ["sword","spear","mace","bow"]
const _SLOT_ORDER: PackedStringArray = [
	"head","chest","legs","boots","sword","spear","mace","bow","ring1","ring2","amulet"
]

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
			var slot_name2: String = _find_slot_holding(eq, uid)
			var buffs_idempotent: Array[String] = _rebuild_buffs(slot)
			return { "ok": true, "equipped_uid": uid, "slot": slot_name2, "buffs": buffs_idempotent }
		return { "ok": false, "reason": "not_in_inventory" }

	# Must be gear
	if not _is_gear(it):
		# put back
		inv.append(it)
		rs["inventory"] = inv
		SaveManager.save_run(rs, slot)
		return { "ok": false, "reason": "not_gear" }
	

	# Resolve target slot (family-aware)
	var resolved_slot: String = _resolve_slot_for_item(it, slot_hint)
	if resolved_slot.is_empty():
		var reason: String = "no_valid_slot"
		if _is_weapon(it):
			reason = "unknown_weapon_family"
		inv.append(it)
		rs["inventory"] = inv
		SaveManager.save_run(rs, slot)
		return { "ok": false, "reason": reason }

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
# Debug API (deterministic, no RNG for stats/affixes; uid assigned normally)
# --------------------------------------------------------------------------
static func debug_spawn_and_equip(slot_name: String, slot: int = DEFAULT_SLOT) -> Dictionary:
	var s: String = slot_name.strip_edges().to_lower()
	if not _valid_slot_names().has(s):
		return { "ok": false, "reason": "bad_slot" }

	var rs: Dictionary = SaveManager.load_run(slot)
	var inv: Array = _as_array(rs.get("inventory", []))

	var it: Dictionary = _debug_proto_for_slot(s)
	var uid: String = _ensure_uid(it)
	inv.append(it)

	rs["inventory"] = inv
	SaveManager.save_run(rs, slot)

	# Route through normal equip (so swaps, bank, buffs all apply)
	return equip(uid, s, slot)

# --------------------------------------------------------------------------
# Internals (typed)
# --------------------------------------------------------------------------
static func _as_array(v: Variant) -> Array:
	return (v as Array) if v is Array else []

static func _valid_slot_names() -> PackedStringArray:
	return PackedStringArray([
		"head","chest","legs","boots",
		"sword","spear","mace","bow",
		"ring1","ring2","amulet"
	])

static func _normalize_slots(eq_in: Dictionary) -> Dictionary:
	var out: Dictionary = {
		"head": null, "chest": null, "legs": null, "boots": null,
		"sword": null, "spear": null, "mace": null, "bow": null,
		"ring1": null, "ring2": null, "amulet": null
	}
	for k_any in out.keys():
		var k: String = String(k_any)
		out[k] = eq_in.get(k, null)
	return out

static func _is_gear(it: Dictionary) -> bool:
	var dmax: int = int(it.get("durability_max", 0))
	if it.has("opts") and it["opts"] is Dictionary:
		var o: Dictionary = it["opts"] as Dictionary
		dmax = max(dmax, int(o.get("durability_max", 0)))
	return dmax > 0

static func _is_weapon(it: Dictionary) -> bool:
	var id_str: String = String(it.get("id", "")).to_lower()
	if id_str.begins_with("weapon_"):
		return true
	var arche: String = String(it.get("archetype", ""))
	return ["Sword","Spear","Mace","Bow"].has(arche)

static func _is_common_rarity(r: String) -> bool:
	var s: String = r.strip_edges()
	if s == "":
		return true
	var u: String = s.to_upper()
	return u == "COMMON" or u == "C"

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
	var hint: String = slot_hint.strip_edges().to_lower()
	# Ignore legacy/neutral hints for weapons
	if hint == "mainhand" or hint == "offhand" or hint == "weapon":
		hint = ""

	var id_str_raw: String = String(it.get("id", ""))
	var id_str: String = id_str_raw.to_lower()
	var arche: String = String(it.get("archetype", ""))

	# --- Weapon families (strict; no fallback)
	if _is_weapon(it):
		var fam: String = _classify_weapon_family(id_str, arche)
		return fam if not fam.is_empty() else ""

	# --- Armor: classify by ID prefix ONLY (no archetype catch-all)
	if id_str.begins_with("armor_head_"):
		return "head"
	if id_str.begins_with("armor_chest_"):
		return "chest"
	if id_str.begins_with("armor_legs_"):
		return "legs"
	if id_str.begins_with("armor_boots_"):
		return "boots"
	# If the caller provided an explicit armor hint, honor it.
	if hint == "head" or hint == "chest" or hint == "legs" or hint == "boots":
		return hint

	# --- Accessories
	if id_str.begins_with("amulet_") or id_str == "amulet_generic":
		return "amulet"

	if id_str.begins_with("ring_") or id_str == "ring_generic":
		if hint == "ring1" or hint == "ring2":
			return hint
		var rs_now: Dictionary = SaveManager.load_run(DEFAULT_SLOT)
		var eq_now: Dictionary = SaveUtils.to_dict(rs_now.get("equipment", {}))
		if eq_now.get("ring1", null) == null:
			return "ring1"
		if eq_now.get("ring2", null) == null:
			return "ring2"
		return "ring1"

	# Unknown gear type → no valid slot (caller will error)
	return ""

static func _classify_weapon_family(id_str: String, arche: String) -> String:
	var idl: String = id_str.to_lower()
	if arche == "Sword" or idl.findn("sword") >= 0:
		return "sword"
	if arche == "Spear" or idl.findn("spear") >= 0:
		return "spear"
	if arche == "Mace" or idl.findn("mace") >= 0 or idl.findn("hammer") >= 0:
		return "mace"
	if arche == "Bow" or idl.findn("bow") >= 0:
		return "bow"
	return ""

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
	# delegate to the primary API (slot_name is treated as a hint)
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
		_rebuild_buffs(slot)      # ensure mods_affix / buffs update
		_reload_runstate(slot)    # ping UI listeners
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
	_rebuild_buffs(slot)
	_reload_runstate(slot)

	return true

# --------------------------------------------------------------------------
# Debug item prototypes (Common, no affixes) — now using slot-specific catalog IDs
# --------------------------------------------------------------------------
static func _debug_proto_for_slot(slot_name: String) -> Dictionary:
	match slot_name:
		# Weapons (catalog ids)
		"sword":
			return {
				"id": "weapon_sword",
				"archetype": "Sword",
				"rarity": "Common",
				"ilvl": 1,
				"durability_max": 50,
				"durability_current": 50,
				"weight": 7.0,  # catalog weight
				"affixes": []
			}
		"spear":
			return {
				"id": "weapon_spear",
				"archetype": "Spear",
				"rarity": "Common",
				"ilvl": 1,
				"durability_max": 50,
				"durability_current": 50,
				"weight": 7.0,
				"affixes": []
			}
		"mace":
			return {
				"id": "weapon_mace",
				"archetype": "Mace",
				"rarity": "Common",
				"ilvl": 1,
				"durability_max": 55,
				"durability_current": 55,
				"weight": 8.0,
				"affixes": []
			}
		"bow":
			return {
				"id": "weapon_bow",
				"archetype": "Bow",
				"rarity": "Common",
				"ilvl": 1,
				"durability_max": 40,
				"durability_current": 40,
				"weight": 5.0,
				"affixes": []
			}

		# Armor: use slot-specific catalog ids so base mods apply
		"head":
			return {
				"id": "armor_head_light",
				"archetype": "Light",
				"rarity": "Common",
				"ilvl": 1,
				"durability_max": 30,
				"durability_current": 30,
				"weight": 2.0,
				"affixes": []
			}
		"chest":
			return {
				"id": "armor_chest_light",
				"archetype": "Light",
				"rarity": "Common",
				"ilvl": 1,
				"durability_max": 40,
				"durability_current": 40,
				"weight": 4.0,
				"affixes": []
			}
		"legs":
			return {
				"id": "armor_legs_light",
				"archetype": "Light",
				"rarity": "Common",
				"ilvl": 1,
				"durability_max": 35,
				"durability_current": 35,
				"weight": 3.0,
				"affixes": []
			}
		"boots":
			return {
				"id": "armor_boots_light",
				"archetype": "Light",
				"rarity": "Common",
				"ilvl": 1,
				"durability_max": 25,
				"durability_current": 25,
				"weight": 1.0,
				"affixes": []
			}

		# Accessories (already in catalog)
		"amulet":
			return {
				"id": "amulet_generic",
				"archetype": "Accessory",
				"rarity": "Common",
				"ilvl": 1,
				"durability_max": 20,
				"durability_current": 20,
				"weight": 1.0,
				"affixes": []
			}
		"ring1", "ring2":
			return {
				"id": "ring_generic",
				"archetype": "Accessory",
				"rarity": "Common",
				"ilvl": 1,
				"durability_max": 20,
				"durability_current": 20,
				"weight": 1.0,
				"affixes": []
			}

		_:
			return {
				"id": "armor_head_light",
				"archetype": "Light",
				"rarity": "Common",
				"ilvl": 1,
				"durability_max": 30,
				"durability_current": 30,
				"weight": 2.0,
				"affixes": []
			}
