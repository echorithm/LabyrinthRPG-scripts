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
#   "lanes_predefense": Dictionary[String, int], # 10 lanes: pierce,slash,blunt,ranged,light,dark,earth,water,fire,wind
#   "penetration_pct": float
# }

static func build_offense(
	ability_data: Dictionary,
	ability_level: int,
	attacker_id: int,
	attacker_snapshot: Dictionary,
	rng: RNGService
) -> Dictionary:
	# --- Scalars (ADR-011) ---
	var school: String = String(ability_data.get("school", "physical"))
	var s_school: float = _scalar_school(school, attacker_snapshot)
	var s_level: float = _scalar_level(ability_level)
	var s_bias: float = _scalar_bias(school, attacker_snapshot)

	var base_power: float = float(ability_data.get("base_power", 0.0))
	var base_amount: float = base_power * s_school * s_level * s_bias
	CombatTrace.atk_scalar(int(round(base_power)), s_school, s_level, s_bias, base_amount)

	# --- Lanes split (normalize to 10 lanes) ---
	# Ability rows should declare lane weights with keys:
	# pierce, slash, blunt, ranged, light, dark, earth, water, fire, wind
	var lanes_any: Variant = ability_data.get("lanes", {})
	var lanes_input: Dictionary = (lanes_any if lanes_any is Dictionary else {}) as Dictionary
	var lanes_pct_any: Dictionary = LaneKeys.normalize_lanes_pct(lanes_input)
	var lanes_pct: Dictionary[String, float] = _to_string_float_map(lanes_pct_any)

	# Pre-crit distribution (integerized per-lane values)
	var precrit: Dictionary[String, int] = {} as Dictionary[String, int]
	for k: String in lanes_pct.keys():
		precrit[k] = int(round(base_amount * lanes_pct[k]))

	# --- Crit ---
	var crit_mul: float = float(ability_data.get("crit_multiplier", 1.5))
	var did_crit: bool = rng.roll_crit()
	if did_crit:
		CombatTrace.crit_note(crit_mul)

	var after_crit: Dictionary[String, int] = {} as Dictionary[String, int]
	for k2: String in precrit.keys():
		var v: float = float(precrit[k2])
		after_crit[k2] = int(round(v * (crit_mul if did_crit else 1.0)))

	# --- Penetration metadata (applied by DefensePipeline) ---
	var penetration_pct: float = clamp(float(ability_data.get("penetration_pct", 0.0)), 0.0, 1.0)

	# --- Variance jitter (symmetric, multiplicative) ---
	var var_pct: float = clamp(float(ability_data.get("variance_pct", 0.0)), 0.0, 0.50)
	var after_var: Dictionary[String, int] = {} as Dictionary[String, int]
	for k3: String in after_crit.keys():
		var v2: float = float(after_crit[k3])
		after_var[k3] = int(round(rng.jitter_variance(v2, var_pct)))

	return {
		"type": "offense_bundle",
		"attacker_id": attacker_id,
		"school": school,
		"did_crit": did_crit,
		"lanes_predefense": after_var.duplicate(), # Dictionary[String,int] with canonical 10 keys
		"penetration_pct": penetration_pct
	}

# ---------------- helpers ----------------

# Convert any-key dict (possibly StringName keys) to Dictionary[String, float].
static func _to_string_float_map(src_any: Dictionary) -> Dictionary[String, float]:
	var out: Dictionary[String, float] = {} as Dictionary[String, float]
	for k_any in src_any.keys():
		var ks: String = String(k_any)
		out[ks] = float(src_any[k_any])
	return out

static func _scalar_school(_school: String, _snap: Dictionary) -> float:
	# Hook for affinities/stances if needed
	return 1.0

static func _scalar_level(level: int) -> float:
	# Milestones every 5 levels (+20% each)
	var milestones: int = max(0, (level - 1) / 5)
	return 1.0 + float(milestones) * 0.20

static func _scalar_bias(_school: String, snap: Dictionary) -> float:
	# ADR-011 bias term β≈0.15 via snapshot.helpers.stat_bias (-1..+1)
	var helpers: Dictionary = (snap.get("helpers", {}) as Dictionary)
	var stat_bias: float = clamp(float(helpers.get("stat_bias", 0.0)), -1.0, 1.0)
	var beta: float = 0.15
	return 1.0 + (beta * stat_bias)
