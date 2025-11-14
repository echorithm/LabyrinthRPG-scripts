# res://persistence/services/sigil_math.gd
extends RefCounted
class_name SigilMath
## Centralized Sigil math helpers:
##  - triad_id_for_floor(floor)
##  - e_total_for_triad(t, A:=2, B:=-1)   (k = 3*t; falls back to A,B if TriadRules unavailable)
##  - required_for_triad(t, A:=2, B:=-1)  (min((t+1)^2, e_total))
##  - required_for_floor(floor)
##  - charge_factor(kills, required)      ((kills+1)/(required+1), clamped)

const _ASeg := preload("res://persistence/services/anchor_segment_service.gd")
const _TriadRules := preload("res://scripts/dungeon/TriadRules.gd")

# --- Triad id from a 1-based floor (3 floors per triad) ----------------------
static func triad_id_for_floor(floor: int) -> int:
	return _ASeg.segment_id_for_floor(max(1, floor))

# --- Triad total elites (spawn) ----------------------------------------------
# Uses TriadRules if present (respecting its slope/offset); otherwise falls back to A*(3*t)+B.
static func e_total_for_triad(t: int, A: int = 2, B: int = -1) -> int:
	var tid: int = max(1, t)
	var k: int = _ASeg.segment_end_floor(tid)  # boss floor for this triad (3*tid)
	var e_total: int = A * (3 * tid) + B

	if _TriadRules != null:
		var tr := _TriadRules.new()
		var from_rules: int = int(tr.elite_total_for_boss_floor(k))
		if from_rules > 0:
			e_total = from_rules

	return max(1, e_total)

# --- Required elites for full boss charge in triad t -------------------------
# Required(t) = min( (t+1)^2, e_total_for_triad(t) )
static func required_for_triad(t: int, A: int = 2, B: int = -1) -> int:
	var tid: int = max(1, t)
	var quad: int = (tid + 1) * (tid + 1)
	var e_total: int = e_total_for_triad(tid, A, B)
	var req: int = quad if quad < e_total else e_total
	return max(1, req)

# --- Required elites for the triad of a given floor --------------------------
static func required_for_floor(floor: int, A: int = 2, B: int = -1) -> int:
	var t: int = triad_id_for_floor(floor)
	return required_for_triad(t, A, B)

# --- Continuous charge factor for boss loot ----------------------------------
# (kills + 1) / (required + 1), clamped to [0,1]; always grants a non-zero floor share.
static func charge_factor(kills: int, required: int) -> float:
	var req: int = max(1, required)
	var num: float = float(max(0, kills) + 1)
	var den: float = float(req + 1)
	var f: float = num / den
	if f < 0.0:
		f = 0.0
	if f > 1.0:
		f = 1.0
	return f
