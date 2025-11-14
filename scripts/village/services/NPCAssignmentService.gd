# res://scripts/village/services/NPCAssignmentService.gd
extends Node
class_name NPCAssignmentService

signal assigned(instance_id: StringName, npc_id: StringName)
signal unassigned(instance_id: StringName, prev_npc_id: StringName)

@export var village_service_path: NodePath
@export var default_slot: int = 0
@export var debug_logging: bool = true

const NPCXp := preload("res://scripts/village/services/NPCXpService.gd")
const VillageSaveUtils := preload("res://scripts/village/persistence/village_save_utils.gd")

var _village: VillageService = null

func _log(msg: String) -> void:
	if debug_logging: print("[NPCAssign] " + msg)

func _ready() -> void:
	default_slot = max(1, default_slot)
	_village = _resolve_village()
	if _village == null:
		_log("WARN: VillageService not resolved")
	else:
		_log("VillageService resolved -> " + String(_village.get_path()))

# ------------- Public API -------------

func assign(instance_id: StringName, npc_id: StringName, slot: int = 0) -> Dictionary:
	if _village == null: _village = _resolve_village()
	_log("assign(): late resolve -> " + (String(_village.get_path()) if _village != null else "<null>"))
	if _village == null:
		_log("ABORT assign: no VillageService")
		return { "ok": false, "reason": "no_village" }

	var role_required: String = _role_required_for(instance_id)
	if role_required == "":
		_log("ABORT assign: could not resolve role for " + String(instance_id))
		return { "ok": false, "reason": "no_role" }

	var use_slot: int = (slot if slot > 0 else SaveManager.active_slot())

	_log("assign iid=%s npc=%s role=%s slot=%d"
		% [String(instance_id), String(npc_id), role_required, use_slot])

	NPCXp.ensure_role_track(npc_id, role_required, use_slot)
	_village.assign_staff(instance_id, npc_id)
	emit_signal("assigned", instance_id, npc_id)
	return { "ok": true, "role": role_required, "npc_id": String(npc_id) }

func unassign(instance_id: StringName, slot: int = 0) -> Dictionary:
	if _village == null: _village = _resolve_village()
	_log("unassign(): late resolve -> " + (String(_village.get_path()) if _village != null else "<null>"))
	if _village == null:
		_log("ABORT unassign: no VillageService")
		return { "ok": false, "reason": "no_village" }

	var prev: StringName = StringName("")
	var inst: Dictionary = _village.get_building_instance(instance_id)
	if not inst.is_empty():
		var st_any: Variant = inst.get("staff", {})
		if st_any is Dictionary:
			prev = StringName(String((st_any as Dictionary).get("npc_id", "")))

	var use_slot: int = (slot if slot > 0 else SaveManager.active_slot())
	_log("unassign iid=%s prev=%s slot=%d" % [String(instance_id), String(prev), use_slot])

	_village.assign_staff(instance_id, StringName(""))
	emit_signal("unassigned", instance_id, prev)
	return { "ok": true, "prev_npc_id": String(prev) }

## Return { role_required, current_npc_id, roster } with roster = unassigned candidates
func get_staffing(instance_id: StringName, slot: int = 0) -> Dictionary:
	var use_slot: int = (slot if slot > 0 else SaveManager.active_slot())
	var role_required: String = _role_required_for(instance_id)

	var current_id: String = ""
	if _village == null: _village = _resolve_village()
	if _village != null:
		var inst: Dictionary = _village.get_building_instance(instance_id)
		var st_any: Variant = inst.get("staff", {})
		if st_any is Dictionary:
			current_id = String((st_any as Dictionary).get("npc_id", ""))

	var roster: Array[Dictionary] = _eligible_roster_for(String(instance_id), role_required, use_slot)
	return { "role_required": role_required, "current_npc_id": StringName(current_id), "roster": roster }

# ------------- Helpers -------------

func _role_required_for(instance_id: StringName) -> String:
	if _village != null and _village.has_method("get_building_staffing"):
		var s: Dictionary = _village.get_building_staffing(instance_id)
		return String(s.get("role_required", "INNKEEPER"))

	var head: String = String(instance_id).get_slice("@", 0)
	if head == "blacksmith": return "ARTISAN_BLACKSMITH"
	if head == "alchemist_lab": return "ARTISAN_ALCHEMIST"
	if head == "marketplace": return "INNKEEPER"
	if head.begins_with("trainer_sword"): return "TRAINER_SWORD"
	if head.begins_with("trainer_spear"): return "TRAINER_SPEAR"
	if head.begins_with("trainer_mace"): return "TRAINER_MACE"
	if head.begins_with("trainer_range"): return "TRAINER_RANGE"
	if head.begins_with("trainer_support"): return "TRAINER_SUPPORT"
	if head.begins_with("trainer_fire"): return "TRAINER_FIRE"
	if head.begins_with("trainer_water"): return "TRAINER_WATER"
	if head.begins_with("trainer_wind"): return "TRAINER_WIND"
	if head.begins_with("trainer_earth"): return "TRAINER_EARTH"
	if head.begins_with("trainer_light"): return "TRAINER_LIGHT"
	if head.begins_with("trainer_dark"): return "TRAINER_DARK"
	return "INNKEEPER"

func _eligible_roster_for(iid: String, role: String, slot: int) -> Array[Dictionary]:
	var v: Dictionary = VillageSaveUtils.load_village(slot)
	var npcs_any: Variant = v.get("npcs", [])
	var out: Array[Dictionary] = []
	if npcs_any is Array:
		for row_any in (npcs_any as Array):
			if not (row_any is Dictionary): continue
			var n: Dictionary = row_any
			if _npc_is_eligible_for_building(n, iid) and _npc_matches_role(n, role):
				var id_s: String = String(n.get("id",""))
				if id_s == "": continue
				out.append({
					"id": StringName(id_s),
					"name": String(n.get("name", id_s)),
					"level": int(n.get("level", 1)),
					"role": String(n.get("role",""))
				})
	return out

static func _npc_is_eligible_for_building(n: Dictionary, iid: String) -> bool:
	var state: String = String(n.get("state", "IDLE"))
	var assigned: String = String(n.get("assigned_instance_id", ""))
	return (state != "STAFFED") or (assigned == iid)

static func _npc_matches_role(n: Dictionary, role: String) -> bool:
	if role == "": return true
	var npc_role: String = String(n.get("role", ""))
	return (npc_role == "") or (npc_role == role)

func _resolve_village() -> VillageService:
	# 1) Explicit path
	if village_service_path != NodePath():
		var n: Node = get_node_or_null(village_service_path)
		if n is VillageService: return n as VillageService
		if n != null: _log("WARN: node at path is not VillageService -> " + String(n.get_class()))

	# 2) Named node at root
	var root: Node = get_tree().get_root()
	var by_name: Node = root.get_node_or_null("VillageService")
	if by_name is VillageService: return by_name as VillageService

	# 3) Group
	var g: Array = get_tree().get_nodes_in_group("VillageService")
	for x in g:
		if x is VillageService: return x as VillageService

	# 4) Deep scan
	var q: Array[Node] = []
	q.append(root)
	while not q.is_empty():
		var cur: Node = q.pop_front()
		if cur is VillageService: return cur as VillageService
		for c in cur.get_children():
			q.append(c)

	return null
