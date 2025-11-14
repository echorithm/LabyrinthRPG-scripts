extends RefCounted
class_name SigilService
## RUN-level “pity” sigil charge per segment.
## Store in RUN:
##   sigils_segment_id:int, sigils_elites_killed_in_segment:int, sigils_required_elites:int, sigils_charged:bool

const _S      := preload("res://persistence/util/save_utils.gd")
const _Meta   := preload("res://persistence/schemas/meta_schema.gd")
const _Run    := preload("res://persistence/schemas/run_schema.gd")
const _ASeg   := preload("res://persistence/services/anchor_segment_service.gd")
const _TriadRules := preload("res://scripts/dungeon/TriadRules.gd")

const DEFAULT_SLOT: int = 1

# --------------------------------------------------------------
# Helper: compute Required for this floor's triad (quadratic)
# Required(t) = min( (t+1)^2, E_total(t) ), where
#   t = AnchorSegmentService.segment_id_for_floor(floor)
#   E_total(k) = A*k + B from TriadRules (defaults A=2, B=-1),
#   k = boss floor for triad t = segment_end_floor(t)
# --------------------------------------------------------------
static func required_for_floor(floor: int) -> int:
	var SigilMath := preload("res://persistence/services/sigil_math.gd")
	return SigilMath.required_for_floor(floor)

# Ensure RUN has a row for the current triad. If `required_elites` is <= 0,
# compute it via required_for_floor(floor). Reset kills/charged when triad changes.
static func ensure_segment_for_floor(floor: int, required_elites: int = 4, slot: int = DEFAULT_SLOT) -> void:
	var seg: int = _ASeg.segment_id_for_floor(floor)
	var rs: Dictionary = SaveManager.load_run(slot)

	var current_seg: int = int(_S.dget(rs, "sigils_segment_id", 0))
	var req_in: int = int(required_elites)
	var req_final: int = req_in if req_in > 0 else required_for_floor(floor)

	if current_seg != seg:
		# New triad → reset counters and set fresh required
		rs["sigils_segment_id"] = seg
		rs["sigils_elites_killed_in_segment"] = 0
		rs["sigils_required_elites"] = max(1, req_final)
		rs["sigils_charged"] = false
	else:
		# Same triad → ensure keys exist; do not overwrite existing required unless missing
		if not rs.has("sigils_elites_killed_in_segment"):
			rs["sigils_elites_killed_in_segment"] = 0
		if not rs.has("sigils_required_elites"):
			rs["sigils_required_elites"] = max(1, req_final)
		if not rs.has("sigils_charged"):
			rs["sigils_charged"] = false

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
