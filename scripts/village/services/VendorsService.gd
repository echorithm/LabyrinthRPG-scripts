extends RefCounted
class_name VendorsService
## ADR vendors: no per-instance stock. Only instance flags live in village.json.

const _Save := preload("res://scripts/village/persistence/village_save_utils.gd")
const _VendorSchema := preload("res://scripts/village/persistence/schemas/vendor_block_schema.gd")

const DEFAULT_SLOT: int = 1

# --------------------------- IO helpers ---------------------------------------

static func _load(slot: int = DEFAULT_SLOT) -> Dictionary:
	return _Save.load_village(slot)

static func _save(snap: Dictionary, slot: int = DEFAULT_SLOT) -> void:
	_Save.save_village(snap, slot)

static func _vendors_map(snap: Dictionary) -> Dictionary:
	var v_any: Variant = snap.get("vendors", {})
	return (v_any as Dictionary) if (v_any is Dictionary) else {}

static func _buildings_array(snap: Dictionary) -> Array:
	var b_any: Variant = snap.get("buildings", [])
	return (b_any as Array) if (b_any is Array) else []

# --------------------------- Public API ---------------------------------------

static func ensure_block(instance_id: StringName, kind: String, slot: int = DEFAULT_SLOT) -> Dictionary:
	var snap := _load(slot)
	var map := _vendors_map(snap)
	var iid := String(instance_id)
	var cur_any: Variant = map.get(iid, {})
	var cur: Dictionary = (cur_any as Dictionary) if (cur_any is Dictionary) else {}

	if cur.is_empty():
		# Active mirrors building's active flag
		var active := is_active(instance_id, slot)
		cur = _VendorSchema.validate({
			"kind": kind, "active": active, "period_index": 0
		})
		map[iid] = cur
		snap["vendors"] = map
		_save(snap, slot)
	return _VendorSchema.validate(cur)

static func is_active(instance_id: StringName, slot: int = DEFAULT_SLOT) -> bool:
	var snap := _load(slot)
	var arr := _buildings_array(snap)
	var iid := String(instance_id)
	for it in arr:
		if it is Dictionary:
			var d: Dictionary = it
			if String(d.get("instance_id", "")) == iid:
				return bool(d.get("active", false))
	return false

static func set_active(instance_id: StringName, active: bool, slot: int = DEFAULT_SLOT) -> void:
	var snap := _load(slot)
	var map := _vendors_map(snap)
	var iid := String(instance_id)
	var cur := _VendorSchema.validate(map.get(iid, {}))
	cur["active"] = active
	map[iid] = cur
	snap["vendors"] = map
	_save(snap, slot)

static func list_vendors(kind: String = "", slot: int = DEFAULT_SLOT) -> Array[String]:
	var snap := _load(slot)
	var map := _vendors_map(snap)
	var out: Array[String] = []
	for k in map.keys():
		var row_any: Variant = map[k]
		if row_any is Dictionary:
			var row: Dictionary = row_any
			if kind == "" or String(row.get("kind", "")) == kind:
				out.append(String(k))
	return out

static func get_kind(instance_id: StringName, slot: int = DEFAULT_SLOT) -> String:
	var snap := _load(slot)
	var map := _vendors_map(snap)
	var row_any: Variant = map.get(String(instance_id), {})
	if row_any is Dictionary:
		return String((row_any as Dictionary).get("kind", ""))
	return ""
