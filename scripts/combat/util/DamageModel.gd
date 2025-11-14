# res://scripts/combat/util/DamageModel.gd
extends RefCounted
class_name DamageModel

const LaneKeys := preload("res://scripts/combat/data/LaneKeys.gd")

static func zeros_10() -> Dictionary[String, int]:
	var d: Dictionary[String, int] = {} as Dictionary[String, int]
	for k: String in LaneKeys.LANES_10:
		d[k] = 0
	return d

static func normalize_lanes(pct: Dictionary[String, float]) -> Dictionary[String, float]:
	# Returns a canonical-keys map that sums to 1.0 (or pierce=1.0 if empty/zero).
	var out: Dictionary[String, float] = {} as Dictionary[String, float]
	for k: String in LaneKeys.LANES_10:
		out[k] = 0.0
	var sum: float = 0.0
	for k_any in pct.keys():
		var k: String = String(k_any)
		if out.has(k):
			var v: float = max(0.0, float(pct[k_any]))
			out[k] = v
			sum += v
	if sum <= 0.0:
		out["pierce"] = 1.0
	else:
		for k: String in LaneKeys.LANES_10:
			out[k] = out[k] / sum
	return out

static func distribute_amount(base_amount: float, lane_pct: Dictionary[String, float]) -> Dictionary[String, int]:
	var pct10: Dictionary[String, float] = normalize_lanes(lane_pct)
	var out: Dictionary[String, int] = zeros_10()
	for k: String in LaneKeys.LANES_10:
		out[k] = int(round(base_amount * pct10[k]))
	return out

static func add_lane_maps(a: Dictionary[String, int], b: Dictionary[String, int]) -> Dictionary[String, int]:
	var out: Dictionary[String, int] = zeros_10()
	for k: String in LaneKeys.LANES_10:
		out[k] = int(a.get(k, 0)) + int(b.get(k, 0))
	return out

static func sum_lanes(lanes: Dictionary[String, int]) -> int:
	var total: int = 0
	for k: String in LaneKeys.LANES_10:
		total += int(lanes.get(k, 0))
	return total

# -------------------- Defense helpers (ordered) --------------------

static func apply_flat_armor(
	lanes: Dictionary[String, int],
	armor_flat: Dictionary[String, int],
	penetration_pct: float
) -> Dictionary[String, int]:
	var out: Dictionary[String, int] = zeros_10()
	var pen: float = clamp(penetration_pct, 0.0, 1.0)
	for k: String in LaneKeys.LANES_10:
		var v: int = int(lanes.get(k, 0))
		if LaneKeys.is_physical(StringName(k)):
			var flat: int = int(armor_flat.get(k, 0))
			# Penetration reduces the armor that actually applies
			var reduced_by: int = max(0, flat - int(round(float(flat) * pen)))
			out[k] = max(0, v - reduced_by)
		else:
			out[k] = v
	return out

static func apply_resists_pct(
	lanes: Dictionary[String, int],
	resist_pct: Dictionary[String, float],
	penetration_pct: float,
	min_pct: float = -0.90,
	max_pct: float = 0.80
) -> Dictionary[String, int]:
	var out: Dictionary[String, int] = zeros_10()
	var pen: float = clamp(penetration_pct, 0.0, 1.0)
	for k: String in LaneKeys.LANES_10:
		var v: float = float(lanes.get(k, 0))
		var rpct: float = clamp(float(resist_pct.get(k, 0.0)), min_pct, max_pct)
		# Penetration reduces effective resistance (cannot exceed caps)
		var eff: float = clamp(rpct - pen, min_pct, max_pct)
		out[k] = int(round(v * (1.0 - eff)))
	return out

static func apply_global_dr(
	lanes: Dictionary[String, int],
	global_dr_pct: float
) -> Dictionary[String, int]:
	var out: Dictionary[String, int] = zeros_10()
	var dr: float = clamp(global_dr_pct, 0.0, 0.95)
	for k: String in LaneKeys.LANES_10:
		out[k] = int(round(float(lanes.get(k, 0)) * (1.0 - dr)))
	return out

static func apply_floor_per_hit(
	lanes: Dictionary[String, int],
	min_per_hit: int
) -> Dictionary[String, int]:
	var out: Dictionary[String, int] = zeros_10()
	var floor_min: int = max(0, min_per_hit)
	for k: String in LaneKeys.LANES_10:
		var v: int = int(lanes.get(k, 0))
		out[k] = v if v >= floor_min else floor_min
	return out

static func mitigate_lanes_full(
	predefense_lanes: Dictionary[String, int],
	armor_flat: Dictionary[String, int],
	resist_pct: Dictionary[String, float],
	penetration_pct: float,
	global_dr_pct: float,
	min_floor: int
) -> Dictionary[String, int]:
	var after_armor: Dictionary[String, int] = apply_flat_armor(predefense_lanes, armor_flat, penetration_pct)
	var after_resist: Dictionary[String, int] = apply_resists_pct(after_armor, resist_pct, penetration_pct)
	var after_dr: Dictionary[String, int] = apply_global_dr(after_resist, global_dr_pct)
	var final_map: Dictionary[String, int] = apply_floor_per_hit(after_dr, min_floor)
	return final_map

# -------------------- Legacy helper kept for compatibility --------------------
# (Uses canonical lanes internally; callers that still pass legacy shapes should be updated.)
static func resolve_hit(
	offense: Dictionary,                    # legacy-ish shape
	armor_flat: Dictionary[String, int],
	resist_pct: Dictionary[String, float],
	pen: float
) -> Dictionary:
	var base_power: int = int(offense.get("base_power", 20))
	var p_atk: float = float(offense.get("p_atk", 0.0))
	var was_crit: bool = bool(offense.get("crit", false))

	var raw: float = float(base_power) + p_atk * 0.5
	if was_crit:
		raw *= 1.5

	var lanes: Dictionary[String, int] = zeros_10()
	lanes["pierce"] = int(round(raw))  # default into a physical lane

	var final_map: Dictionary[String, int] = mitigate_lanes_full(
		lanes, armor_flat, resist_pct, clamp(pen, 0.0, 1.0), 0.0, 0
	)
	var total: int = sum_lanes(final_map)
	return {
		"lane": "pierce",
		"dmg": int(final_map.get("pierce", 0)),
		"was_crit": was_crit,
		"lanes": final_map,
		"total": total
	}
