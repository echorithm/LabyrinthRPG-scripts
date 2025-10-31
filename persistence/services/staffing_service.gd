# File: res://persistence/services/staffing_service.gd
# Godot 4.5 — Strict typing; role-validated staff assignments into VillageSave

class_name StaffingService

signal staff_assigned(building_instance_id: String, role: String, staff_ref: String)
signal staff_unassigned(building_instance_id: String, role: String, staff_ref: String)

# Pure logic; caller provides/receives save Dictionaries (VillageService persists).

static func roles() -> Array[StringName]:
	return VillageSchema.ROLES.duplicate()

static func has_role(role: StringName) -> bool:
	return VillageSchema.ROLES.has(role)

static func list_assignments(save: Dictionary) -> Array[Dictionary]:
	var s: Variant = save.get("staffing", [])
	var out: Array[Dictionary] = []
	if typeof(s) == TYPE_ARRAY:
		for v in s:
			if typeof(v) == TYPE_DICTIONARY:
				out.append(v)
	return out

static func can_assign(save: Dictionary, building_instance_id: String, role: StringName, staff_ref: String) -> bool:
	if not has_role(role):
		return false
	if staff_ref == "":
		return false
	# duplicate prevention
	for a in list_assignments(save):
		if String(a.get("building_instance_id", "")) == building_instance_id and String(a.get("role", "")) == String(role):
			# Already staffed for this role at this building
			return false
	return true

static func assign(save: Dictionary, building_instance_id: String, role: StringName, staff_ref: String) -> Dictionary:
	# Returns updated save
	if not can_assign(save, building_instance_id, role, staff_ref):
		return save
	var arr: Array[Dictionary] = list_assignments(save)
	arr.append({
		"building_instance_id": building_instance_id,
		"role": String(role),
		"staff_ref": staff_ref
	})
	var new_save: Dictionary = save.duplicate(true)
	new_save["staffing"] = arr
	return new_save

static func unassign(save: Dictionary, building_instance_id: String, role: StringName) -> Dictionary:
	var arr: Array[Dictionary] = list_assignments(save)
	var out: Array[Dictionary] = []
	for a in arr:
		var keep: bool = true
		if String(a.get("building_instance_id", "")) == building_instance_id and String(a.get("role", "")) == String(role):
			keep = false
		if keep:
			out.append(a)
	var new_save: Dictionary = save.duplicate(true)
	new_save["staffing"] = out
	return new_save
