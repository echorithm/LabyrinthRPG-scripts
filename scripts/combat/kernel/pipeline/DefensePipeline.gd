extends RefCounted
class_name DefensePipeline

const DamageModel := preload("res://scripts/combat/util/DamageModel.gd")
const LaneKeys    := preload("res://scripts/combat/data/LaneKeys.gd")

static func mitigate(
	offense_bundle: Dictionary,
	attacker_id: int,
	target_id: int,
	target_snapshot: Dictionary,
	emit_cb: Callable
) -> Dictionary:
	# ---- Inputs ----
	var lanes_pre_any: Variant = offense_bundle.get("lanes_predefense", {})
	var lanes: Dictionary[String, int] = {} as Dictionary[String, int]
	if lanes_pre_any is Dictionary:
		for k_any in (lanes_pre_any as Dictionary).keys():
			var k: String = String(k_any)
			lanes[k] = int((lanes_pre_any as Dictionary).get(k_any, 0))
	else:
		lanes = _zeros_10_int()

	# Penetration is a fraction (0..1)
	var penetration_pct: float = clamp(float(offense_bundle.get("penetration_pct", 0.0)), 0.0, 1.0)

	# Decode snapshot armor/resists to lane maps (armor: ints; resists: FRACTIONS)
	var armor_flat: Dictionary[String, int] = _armor_Ax_to_lanes(target_snapshot.get("armor_flat", {}))
	var resist_frac: Dictionary[String, float] = _resist_Lx_to_lanes(target_snapshot.get("resist_pct", {}))

	# Defender mods (armor/resists are lane-named; resists are percent-points → fractions)
	var D_mods_any: Variant = target_snapshot.get("mods", {})
	var D_mods: Dictionary = (D_mods_any as Dictionary) if D_mods_any is Dictionary else {}
	if not D_mods.is_empty():
		# Armor adds (flat ints)
		var add_arm: Dictionary = (D_mods.get("armor_add_flat", {}) as Dictionary)
		for p_any in add_arm.keys():
			var pl: String = String(p_any)
			armor_flat[pl] = int(armor_flat.get(pl, 0)) + int(add_arm[p_any])
		# Resist adds (percent points → fraction)
		var add_res_pp: Dictionary = (D_mods.get("resist_add_pct", {}) as Dictionary)
		for l_any in add_res_pp.keys():
			var lane: String = String(l_any)
			var add_frac: float = float(add_res_pp[l_any]) * 0.01
			resist_frac[lane] = float(resist_frac.get(lane, 0.0)) + add_frac

	# Global DR (prefer mods; fallback helpers). Both sources are percent-points → fraction
	var helpers_any: Variant = target_snapshot.get("helpers", {})
	var helpers: Dictionary = (helpers_any as Dictionary) if helpers_any is Dictionary else {}
	var dr_mods_pp: float = float(D_mods.get("global_dr_pct", 0.0))
	var dr_help_pp: float = float(helpers.get("global_dr_pct", 0.0))
	var global_dr_pct: float = clamp(max(dr_mods_pp, dr_help_pp) * 0.01, 0.0, 0.95)

	# Per-hit damage floor (int)
	var floor_min: int = int(max(0, helpers.get("dmg_floor_per_hit", 0)))

	# Decide resist cap: players soft-cap at +80%, monsters at +95%
	var is_player: bool = String(target_snapshot.get("team", "")) == "player"
	var max_res_cap: float = 0.80 if is_player else 0.95

	# ---- 1) Shields / Wards (stub) ----
	var after_shield: Dictionary[String, int] = {} as Dictionary[String, int]
	for lane in LaneKeys.LANES_10:
		var lane_key: String = String(lane)
		var incoming: int = int(lanes.get(lane_key, 0))
		var absorbed: int = 0
		# Shield consumption would go here
		var remainder: int = incoming - absorbed
		if absorbed > 0:
			emit_cb.call("shield_absorb", target_id, lane_key, absorbed, {"shield_id":"omni"})
		after_shield[lane_key] = max(0, remainder)

	# ---- 2) Block (physical lanes) ----
	var after_block: Dictionary[String, int] = {} as Dictionary[String, int]
	for lane_b in LaneKeys.LANES_10:
		var lane_key_b: String = String(lane_b)
		var v_in: int = int(after_shield.get(lane_key_b, 0))
		if LaneKeys.is_physical(StringName(lane_key_b)):
			var reduced: int = _maybe_block_reduction(helpers, v_in)
			if reduced > 0:
				emit_cb.call("block", target_id, lane_key_b, reduced, {"tier": 1})
			after_block[lane_key_b] = max(0, v_in - reduced)
		else:
			after_block[lane_key_b] = v_in

	# ---- 3) Armor (flat), with penetration ----
	var after_armor: Dictionary[String, int] = DamageModel.apply_flat_armor(
		after_block, armor_flat, penetration_pct
	)

	# ---- 4) Resists % (all lanes), with penetration ----
	var after_resist: Dictionary[String, int] = DamageModel.apply_resists_pct(
		after_armor,
		resist_frac,          # FRACTIONS per lane
		penetration_pct,
		-0.90,                # min cap (−90%)
		max_res_cap           # player soft-top 0.80 else 0.95
	)

	# ---- 5) Global DR → 6) Floor ----
	var after_dr: Dictionary[String, int] = DamageModel.apply_global_dr(after_resist, global_dr_pct)
	var final_map: Dictionary[String, int] = DamageModel.apply_floor_per_hit(after_dr, floor_min)

	var total: int = DamageModel.sum_lanes(final_map)

	return {
		"type": "defense_result",
		"lanes_after": final_map.duplicate(),
		"total": total
	}


static func _maybe_block_reduction(helpers: Dictionary, incoming: int) -> int:
	var block_flat: int = int(helpers.get("block_flat", 0))
	return min(max(0, block_flat), max(0, incoming))

static func _zeros_10_int() -> Dictionary[String, int]:
	var d: Dictionary[String, int] = {} as Dictionary[String, int]
	for k in LaneKeys.LANES_10:
		d[String(k)] = 0
	return d

static func _armor_Ax_to_lanes(armor_in_any: Variant) -> Dictionary[String, int]:
	var out: Dictionary[String, int] = DamageModel.zeros_10()
	if not (armor_in_any is Dictionary):
		return out
	var armor_in: Dictionary = armor_in_any as Dictionary
	# If already lane-named, pass through
	var lane_keys := ["pierce","slash","blunt","ranged"]
	var has_lane: bool = false
	for k_any in armor_in.keys():
		var k := String(k_any)
		if lane_keys.has(k):
			has_lane = true
			break
	if has_lane:
		for k in lane_keys:
			out[k] = int(armor_in.get(k, 0))
		return out
	# Map A0..A3 -> PHYS_4 by LaneKeys order
	var phys := LaneKeys.PHYS_4
	for i in range(min(4, phys.size())):
		var ax := "A%d" % i
		out[String(phys[i])] = int(armor_in.get(ax, 0))
	return out

static func _resist_Lx_to_lanes(res_in_any: Variant) -> Dictionary[String, float]:
	var out: Dictionary[String, float] = {}
	# default zeros for all lanes
	for k in LaneKeys.LANES_10: out[String(k)] = 0.0
	if not (res_in_any is Dictionary):
		return out
	var res_in: Dictionary = res_in_any as Dictionary

	# If already lane-named (fire/water/etc.), just divide by 100
	var lane_named := false
	for k_any in res_in.keys():
		var k := String(k_any)
		if out.has(k):
			lane_named = true
			break
	if lane_named:
		for k in LaneKeys.LANES_10:
			var s := String(k)
			out[s] = float(res_in.get(s, 0.0)) * 0.01
		return out

	# Else assume L0..L9 follow LaneKeys.LANES_10 order; divide by 100
	for i in range(LaneKeys.LANES_10.size()):
		var lx := "L%d" % i
		var lane := String(LaneKeys.LANES_10[i])
		out[lane] = float(res_in.get(lx, 0.0)) * 0.01
	return out
