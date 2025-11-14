extends Node
class_name NPCService

const _DBG := "[NPCService] "
func _log(msg: String) -> void: print(_DBG + msg)

@export var village_service_path: NodePath

var _village: Node = null

func _ready() -> void:
	_village = get_node_or_null(village_service_path)

# Legacy roster by required role (UI can still call this).
func get_roster(role_required: StringName) -> Array[Dictionary]:
	# Preferred: dedicated API
	if _village != null and _village.has_method("get_roster_for_role"):
		var a: Variant = _village.call("get_roster_for_role", role_required)
		var typed: Array[Dictionary] = []
		if a is Array:
			for v in (a as Array):
				if v is Dictionary:
					typed.append(v as Dictionary)
		return typed

	# Fallback: scan snapshot (kept simple and deterministic)
	if _village != null and _village.has_method("get_snapshot"):
		var snap: Dictionary = _village.call("get_snapshot")
		var npcs_any: Variant = snap.get("npcs", [])
		var npcs: Array = (npcs_any as Array) if (npcs_any is Array) else []
		var out: Array[Dictionary] = []
		for n_any in npcs:
			if not (n_any is Dictionary):
				continue
			var n: Dictionary = n_any
			# MVP: any NPC can be assigned anywhere; do not filter by baked-in 'role'
			out.append({
				"id": StringName(String(n.get("id",""))),
				"name": String(n.get("name",""))
			})
		return out

	# Default: empty typed array
	return [] as Array[Dictionary]

# Building-oriented roster (MVP convenience). Delegates to Village if present.
func get_roster_for_building(instance_id: StringName) -> Array[Dictionary]:
	if _village != null and _village.has_method("get_roster_for_building"):
		var a: Variant = _village.call("get_roster_for_building", instance_id)
		var typed: Array[Dictionary] = []
		if a is Array:
			for v in (a as Array):
				if v is Dictionary:
					typed.append(v as Dictionary)
		return typed
	# Fallback to generic roster if no per-building method is available.
	return get_roster(StringName(""))

func get_npc_snapshot(id: StringName) -> Dictionary:
	if _village != null and _village.has_method("get_npc_ui_snapshot"):
		return _village.call("get_npc_ui_snapshot", id)
	if _village != null and _village.has_method("get_npc_snapshot"):
		return _village.call("get_npc_snapshot", id)
	# Minimal default; note xp/xp_next for UI fallbacks
	return { "name": "", "level": 1, "xp": 0, "xp_next": 1 }

func assign_staff(instance_id: StringName, npc_id: StringName) -> void:
	if _village != null and _village.has_method("assign_staff"):
		_village.call("assign_staff", instance_id, npc_id)
