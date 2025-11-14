extends RefCounted
class_name AttackPipeline

const RNGService  := preload("res://scripts/combat/util/RNGService.gd")
const LaneKeys    := preload("res://scripts/combat/data/LaneKeys.gd")
const CombatTrace := preload("res://scripts/combat/util/CombatTrace.gd")

# Produces an immutable "offense bundle" ready for DefensePipeline.
# {
#   "type": "offense_bundle",
#   "attacker_id": int,
#   "school": String,
#   "did_crit": bool,
#   "lanes_predefense": Dictionary[String, int], # 10 lanes
#   "penetration_pct": float                     # 0..1
# }

static func build_offense(
	ability_data: Dictionary,
	ability_level: int,
	attacker_id: int,
	attacker_snapshot: Dictionary,
	rng: RNGService
) -> Dictionary:
	# --- Scalars ---
	# Accept both "school" and "scaling" (catalog uses "scaling")
	var school: String = String(ability_data.get("school", String(ability_data.get("scaling", "support"))))

	var s_school: float = _scalar_school(school, attacker_snapshot)
	var s_level: float  = _scalar_level(ability_level)
	var s_bias: float   = _scalar_bias(school, attacker_snapshot)

	var base_power: float = float(ability_data.get("base_power", 0.0))
	var base_amount: float = base_power * s_school * s_level * s_bias

	# Mods snapshot (Dictionary)
	var A_mods_any: Variant = attacker_snapshot.get("mods", {})
	var A_mods: Dictionary = (A_mods_any as Dictionary) if A_mods_any is Dictionary else {}

	# Optional school multiplier from mods (e.g., arcane/divine/power/finesse)
	var sch_map: Dictionary = (A_mods.get("school_power_pct", {}) as Dictionary)
	if not sch_map.is_empty():
		var add_pct: float = float(sch_map.get(school, 0.0))
		if add_pct != 0.0:
			base_amount *= (1.0 + add_pct * 0.01)

	CombatTrace.atk_scalar(int(round(base_power)), s_school, s_level, s_bias, base_amount)

	# --- Lanes split (normalize to 10 lanes) ---
	var lanes_any: Variant = ability_data.get("lanes", {})
	var lanes_input: Dictionary = (lanes_any if lanes_any is Dictionary else {}) as Dictionary
	var lanes_pct_any: Dictionary = LaneKeys.normalize_lanes_pct(lanes_input)
	var lanes_pct: Dictionary[String, float] = _to_string_float_map(lanes_pct_any)

	# Pre-crit distribution (integerized per-lane values)
	var precrit: Dictionary[String, int] = {} as Dictionary[String, int]
	for k: String in lanes_pct.keys():
		precrit[k] = int(round(base_amount * lanes_pct[k]))

	# --- Crit: chance (from derived + mods) and multiplier (ability + mods, clamped) ---
	var caps_any: Variant = attacker_snapshot.get("caps", {})
	var caps: Dictionary = (caps_any as Dictionary) if (caps_any is Dictionary) else {}
	var crit_cap: float = float(caps.get("crit_chance_cap", 0.35))
	var crit_mul_cap: float = float(caps.get("crit_multi_cap", 2.5))

	var der_any: Variant = attacker_snapshot.get("derived", {})
	var base_crit_frac: float = 0.0
	if der_any is Dictionary:
		base_crit_frac = float((der_any as Dictionary).get("crit_chance", 0.0))  # 0..1

	# +X% absolute points from equipment/status becomes +0.XX fraction
	var add_pp: float = float(A_mods.get("crit_chance_add", 0.0)) * 0.01
	var crit_chance: float = clamp(base_crit_frac + add_pp, 0.0, crit_cap)

	var crit_mul: float = float(ability_data.get("crit_multiplier", 1.5))
	crit_mul += float(A_mods.get("crit_multi_add", 0.0)) # additive to multiplier (already fractional)
	crit_mul = min(crit_mul, crit_mul_cap)

	# RNGService uses a bag for crit; set the bag prob, then roll.
	rng.set_bag_prob(&"crit", crit_chance)
	var did_crit: bool = rng.roll_crit()
	if did_crit:
		CombatTrace.crit_note(crit_mul)

	var after_crit: Dictionary[String, int] = {} as Dictionary[String, int]
	for k2: String in precrit.keys():
		var v: float = float(precrit[k2])
		after_crit[k2] = int(round(v * (crit_mul if did_crit else 1.0)))

	# --- Variance jitter (symmetric, multiplicative) ---
	var var_pct: float = clamp(float(ability_data.get("variance_pct", 0.0)), 0.0, 0.50)
	var after_var: Dictionary[String, int] = {} as Dictionary[String, int]
	for k3: String in after_crit.keys():
		var v2: float = float(after_crit[k3])
		after_var[k3] = int(round(rng.jitter_variance(v2, var_pct)))

	# --- Offense-side mods (lane multipliers, flat adds, converters) ---
	var lane_mult_map: Dictionary = (A_mods.get("lane_damage_mult_pct", {}) as Dictionary)
	var added_flat_univ: float = float(A_mods.get("added_flat_universal", 0.0))
	var added_by_lane: Dictionary = (A_mods.get("added_flat_by_lane", {}) as Dictionary)

	# distribute universal flat by weights if any
	var w_sum: float = 0.0
	for w_k in lanes_pct.keys():
		w_sum += float(lanes_pct[w_k])

	# apply per-lane
	for lane_any in after_var.keys():
		var lane: String = String(lane_any)
		var v3: float = float(after_var[lane])

		# + flat by lane
		v3 += float(added_by_lane.get(lane, 0.0))

		# + flat universal proportional to lane share
		if w_sum > 0.0 and lanes_pct.has(lane):
			var share: float = float(lanes_pct[lane]) / w_sum
			v3 += added_flat_univ * share

		# * lane multiplier (% points)
		var mult_pct: float = float(lane_mult_map.get(lane, 0.0))
		if mult_pct != 0.0:
			v3 *= (1.0 + mult_pct * 0.01)

		after_var[lane] = int(round(max(0.0, v3)))

	# Optional: convert physical → element before defense
	var conv_any: Variant = A_mods.get("convert_phys_to_element", {})
	if conv_any is Dictionary:
		var conv: Dictionary = conv_any as Dictionary
		var el: String = String(conv.get("element",""))
		var pct: float = float(conv.get("pct", 0.0)) * 0.01
		if pct > 0.0 and el in ["light","dark","fire","water","earth","wind"]:
			var moved: float = 0.0
			for pl in ["pierce","slash","ranged","blunt"]:
				var amt: float = float(after_var.get(pl, 0))
				if amt <= 0.0: continue
				var take: float = amt * pct
				after_var[pl] = int(round(max(0.0, amt - take)))
				moved += take
			if moved > 0.0:
				var cur_el: float = float(after_var.get(el, 0))
				after_var[el] = int(round(cur_el + moved))

	# --- Penetration metadata (ability + mods) ---
	var penetration_base: float = clamp(float(ability_data.get("penetration_pct", 0.0)), 0.0, 1.0)
	var pene_add_pct: float = float(A_mods.get("pene_add_pct", 0.0)) * 0.01
	var penetration_pct: float = clamp(penetration_base + pene_add_pct, 0.0, 1.0)

	return {
		"type": "offefinal_damage_totalnse_bundle",
		"attacker_id": attacker_id,
		"school": school,
		"did_crit": did_crit,
		"lanes_predefense": after_var.duplicate(), # Dictionary[String,int] with canonical 10 keys
		"penetration_pct": penetration_pct
	}


# ---------------- helpers ----------------

static func _to_string_float_map(src_any: Dictionary) -> Dictionary[String, float]:
	var out: Dictionary[String, float] = {} as Dictionary[String, float]
	for k_any in src_any.keys():
		var ks: String = String(k_any)
		out[ks] = float(src_any[k_any])
	return out

static func _scalar_school(_school: String, _snap: Dictionary) -> float:
	return 1.0

static func _scalar_level(level: int) -> float:
	var milestones: int = max(0, (level - 1) / 5)
	return 1.0 + float(milestones) * 0.20

static func _scalar_bias(_school: String, snap: Dictionary) -> float:
	var helpers: Dictionary = (snap.get("helpers", {}) as Dictionary)
	var stat_bias: float = clamp(float(helpers.get("stat_bias", 0.0)), -1.0, 1.0)
	var beta: float = 0.15
	return 1.0 + (beta * stat_bias)
