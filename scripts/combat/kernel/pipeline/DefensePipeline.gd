extends RefCounted
class_name DefensePipeline

const DamageModel := preload("res://scripts/combat/util/DamageModel.gd")
const LaneKeys    := preload("res://scripts/combat/data/LaneKeys.gd")

# Applies: shields/wards → block → armor_flat (physical lanes) → resist_pct (all lanes)
# → global DR (guard/row/etc.) → minimum floor. Emits per-step contributions via emit_cb.
#
# Params:
#  - offense_bundle: Dictionary from AttackPipeline.build_offense(...)
#  - attacker_id, target_id: ints
#  - target_snapshot: Dictionary (immutable snapshot; should include armor_flat, resist_pct, helpers)
#  - emit_cb: Callable(kind: String, target_id: int, lane: String, amount: int, meta: Variant)

static func mitigate(
	offense_bundle: Dictionary,
	attacker_id: int,
	target_id: int,
	target_snapshot: Dictionary,
	emit_cb: Callable
) -> Dictionary:
	# ---- 0) Typed inputs & fallbacks ----
	var lanes_pre_any: Variant = offense_bundle.get("lanes_predefense", {})
	var lanes: Dictionary[String, int] = {} as Dictionary[String, int]
	if lanes_pre_any is Dictionary:
		for k_any in (lanes_pre_any as Dictionary).keys():
			var k: String = String(k_any)
			lanes[k] = int((lanes_pre_any as Dictionary).get(k_any, 0))
	else:
		lanes = _zeros_10_int()

	var penetration_pct: float = float(offense_bundle.get("penetration_pct", 0.0))

	var armor_flat: Dictionary[String, int] = {} as Dictionary[String, int]
	var armor_flat_any: Variant = target_snapshot.get("armor_flat", {})
	if armor_flat_any is Dictionary:
		for ak_any in (armor_flat_any as Dictionary).keys():
			var ak: String = String(ak_any)
			armor_flat[ak] = int((armor_flat_any as Dictionary).get(ak_any, 0))

	var resist_pct: Dictionary[String, float] = {} as Dictionary[String, float]
	var resist_pct_any: Variant = target_snapshot.get("resist_pct", {})
	if resist_pct_any is Dictionary:
		for rk_any in (resist_pct_any as Dictionary).keys():
			var rk: String = String(rk_any)
			resist_pct[rk] = float((resist_pct_any as Dictionary).get(rk_any, 0.0))

	var helpers_any: Variant = target_snapshot.get("helpers", {})
	var helpers: Dictionary = (helpers_any if helpers_any is Dictionary else {}) as Dictionary
	var global_dr_pct: float = clamp(float(helpers.get("global_dr_pct", 0.0)), 0.0, 0.90)
	var floor_min: int = int(max(0, helpers.get("dmg_floor_per_hit", 0)))

	# ---- 1) Shields / Wards (hook) ----
	var after_shield: Dictionary[String, int] = {} as Dictionary[String, int]
	for lane in LaneKeys.LANES_10:
		var lane_key: String = String(lane)
		var incoming: int = int(lanes.get(lane_key, 0))
		var absorbed: int = 0
		# TODO: integrate real shields/wards; per-lane or omni consumption here
		# absorbed = ShieldSystem.consume(target_id, lane_key, incoming)
		var remainder: int = incoming - absorbed
		if absorbed > 0:
			emit_cb.call("shield_absorb", target_id, lane_key, absorbed, {"shield_id":"omni"})
		after_shield[lane_key] = max(0, remainder)

	# ---- 2) Block (physical lanes only) ----
	var after_block: Dictionary[String, int] = {} as Dictionary[String, int]
	for lane_b in LaneKeys.LANES_10:
		var lane_key_b: String = String(lane_b)
		var v_in: int = int(after_shield.get(lane_key_b, 0))
		if LaneKeys.is_physical(StringName(lane_key_b)):
			var reduced: int = _maybe_block_reduction(helpers, v_in)
			if reduced > 0:
				emit_cb.call("block", target_id, lane_key_b, reduced, {"tier":1})
			after_block[lane_key_b] = max(0, v_in - reduced)
		else:
			after_block[lane_key_b] = v_in

	# ---- 3) Armor flat (physical), with penetration ----
	var after_armor: Dictionary[String, int] = DamageModel.apply_flat_armor(
		after_block,
		armor_flat,
		penetration_pct
	)

	# ---- 4) Resists % (all lanes), with penetration ----
	var after_resist: Dictionary[String, int] = DamageModel.apply_resists_pct(
		after_armor,
		resist_pct,
		penetration_pct,
		-0.90, # min cap (e.g., vulnerability)
		0.80   # max cap (e.g., resist cap)
	)

	# ---- 5) Global DR → 6) Floor ----
	var after_dr: Dictionary[String, int] = DamageModel.apply_global_dr(after_resist, global_dr_pct)
	var final_map: Dictionary[String, int] = DamageModel.apply_floor_per_hit(after_dr, floor_min)

	# ---- Totals ----
	var total: int = DamageModel.sum_lanes(final_map)

	return {
		"type": "defense_result",
		"lanes_after": final_map.duplicate(), # Dictionary[String,int]
		"total": total
	}

# Hook to your block model via helpers
static func _maybe_block_reduction(helpers: Dictionary, incoming: int) -> int:
	var block_flat: int = int(helpers.get("block_flat", 0))
	return min(max(0, block_flat), max(0, incoming))

# Local zero-map for int lanes using the canonical keys
static func _zeros_10_int() -> Dictionary[String, int]:
	var d: Dictionary[String, int] = {} as Dictionary[String, int]
	for k in LaneKeys.LANES_10:
		d[String(k)] = 0
	return d
