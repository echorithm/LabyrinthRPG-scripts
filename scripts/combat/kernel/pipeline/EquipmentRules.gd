# Godot 4.5
extends RefCounted
class_name EquipmentRules
## Pure, testable checks for equipment requirements used by PreUseRules.
## Updated for weapon family slots (sword/spear/mace/bow). No mainhand fallback.

const _S := preload("res://persistence/util/save_utils.gd")

static func meets_weapon_req(run_slot: int, ability_row: Dictionary) -> Dictionary:
	# ability_row is from AbilityCatalogService.get_by_id()
	var wt_raw: String = String(ability_row.get("weapon_type", ""))
	var wt: String = wt_raw.strip_edges().to_lower()
	if wt == "":
		return { "ok": true }

	# Normalize to one of our canonical families; else fail deterministically
	var fam: String = _normalize_family(wt)
	if fam == "":
		return { "ok": false, "reason": "requires_%s" % wt }

	# Read RUN once
	var rs: Dictionary = SaveManager.load_run(run_slot)

	# 1) Fast path: weapon_tags mirror (families populated by BuffService)
	var tags: Array[String] = _S.to_string_array(rs.get("weapon_tags", []))
	for t in tags:
		if t.to_lower() == fam:
			return { "ok": true }

	# 2) Direct family-slot verification (no mainhand fallback)
	var eq_any: Variant = rs.get("equipment", {})
	var eq: Dictionary = (eq_any as Dictionary) if eq_any is Dictionary else {}
	var uid_any: Variant = eq.get(fam)
	if uid_any == null:
		return { "ok": false, "reason": "requires_%s" % fam }

	var bank_any: Variant = rs.get("equipped_bank", {})
	var bank: Dictionary = (bank_any as Dictionary) if bank_any is Dictionary else {}
	var row_any: Variant = bank.get(String(uid_any))
	if row_any is Dictionary:
		var row: Dictionary = row_any as Dictionary
		var arche: String = String(row.get("archetype", "")).to_lower()
		if arche == fam:
			return { "ok": true }

	return { "ok": false, "reason": "requires_%s" % fam }

static func has_equipped_slot(run_slot: int, slot: String) -> bool:
	var rs: Dictionary = SaveManager.load_run(run_slot)
	var eq_any: Variant = rs.get("equipment", {})
	var eq: Dictionary = (eq_any as Dictionary) if eq_any is Dictionary else {}
	var uid_any: Variant = eq.get(slot)
	return uid_any != null

static func get_equipped_item(run_slot: int, slot: String) -> Dictionary:
	var rs: Dictionary = SaveManager.load_run(run_slot)
	var eq: Dictionary = (rs.get("equipment", {}) as Dictionary)
	var bank: Dictionary = (rs.get("equipped_bank", {}) as Dictionary)
	var uid_any: Variant = eq.get(slot)
	if uid_any == null:
		return {}
	var row_any: Variant = bank.get(String(uid_any))
	return (row_any as Dictionary) if row_any is Dictionary else {}

# ---------------- Internals ----------------

static func _normalize_family(wt_lower: String) -> String:
	# Accept common variants and plurals; return canonical slot or "" if unknown
	match wt_lower:
		"sword", "swords":
			return "sword"
		"spear", "spears":
			return "spear"
		"mace", "maces", "hammer", "hammers":
			return "mace"
		"bow", "bows":
			return "bow"
		_:
			return ""
