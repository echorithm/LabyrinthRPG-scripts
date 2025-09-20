extends RefCounted
class_name SigilService
## RUN-level “pity” sigil charge per segment.
## Store in RUN:
##   sigils_segment_id:int, sigils_elites_killed_in_segment:int, sigils_required_elites:int, sigils_charged:bool

const _S      := preload("res://persistence/util/save_utils.gd")
const _Meta   := preload("res://persistence/schemas/meta_schema.gd")
const _Run    := preload("res://persistence/schemas/run_schema.gd")
const _ASeg   := preload("res://persistence/services/anchor_segment_service.gd")

const DEFAULT_SLOT: int = 1

static func ensure_segment_for_floor(floor: int, required_elites: int = 4, slot: int = DEFAULT_SLOT) -> void:
	var seg: int = _ASeg.segment_id_for_floor(floor)
	var rs: Dictionary = SaveManager.load_run(slot)
	var cur_seg: int = int(_S.dget(rs, "sigils_segment_id", 0))
	if cur_seg != seg:
		rs["sigils_segment_id"] = seg
		rs["sigils_elites_killed_in_segment"] = 0
		rs["sigils_required_elites"] = max(1, required_elites)
		rs["sigils_charged"] = false
	else:
		# Ensure keys exist
		if not rs.has("sigils_elites_killed_in_segment"): rs["sigils_elites_killed_in_segment"] = 0
		if not rs.has("sigils_required_elites"): rs["sigils_required_elites"] = max(1, required_elites)
		if not rs.has("sigils_charged"): rs["sigils_charged"] = false
	SaveManager.save_run(rs, slot)

static func set_required_elites(count: int, slot: int = DEFAULT_SLOT) -> void:
	var rs: Dictionary = SaveManager.load_run(slot)
	rs["sigils_required_elites"] = max(1, count)
	SaveManager.save_run(rs, slot)

static func notify_elite_killed(slot: int = DEFAULT_SLOT) -> Dictionary:
	var rs: Dictionary = SaveManager.load_run(slot)
	var kills: int = int(_S.dget(rs, "sigils_elites_killed_in_segment", 0)) + 1
	var req: int = max(1, int(_S.dget(rs, "sigils_required_elites", 4)))
	rs["sigils_elites_killed_in_segment"] = kills
	if kills >= req:
		rs["sigils_charged"] = true
	SaveManager.save_run(rs, slot)
	return rs.duplicate(true)

static func is_charged(slot: int = DEFAULT_SLOT) -> bool:
	return bool(_S.dget(SaveManager.load_run(slot), "sigils_charged", false))

static func consume_charge(slot: int = DEFAULT_SLOT) -> void:
	var rs: Dictionary = SaveManager.load_run(slot)
	rs["sigils_charged"] = false
	rs["sigils_elites_killed_in_segment"] = 0
	SaveManager.save_run(rs, slot)

static func get_progress(slot: int = DEFAULT_SLOT) -> Dictionary:
	var rs: Dictionary = SaveManager.load_run(slot)
	return {
		"segment_id": int(_S.dget(rs, "sigils_segment_id", 1)),
		"kills": int(_S.dget(rs, "sigils_elites_killed_in_segment", 0)),
		"required": int(_S.dget(rs, "sigils_required_elites", 4)),
		"charged": bool(_S.dget(rs, "sigils_charged", false)),
	}
