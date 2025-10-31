# res://scripts/dungeon/encounters/SetPowerLevel.gd
extends RefCounted
class_name SetPowerLevel
##
# Power Level generator.
# - Public API unchanged: base_for_floor, band_for_floor, roll_power_level
# - If (a,b) are overridden, use legacy linear model.
# - Otherwise use triad-stepped exponential by default.

# ---- Legacy defaults (kept for signature + linear mode) ----
const DEFAULT_A: int = 6
const DEFAULT_B: int = 10
const DEFAULT_VOLATILITY: float = 0.15
const MIN_POWER_LEVEL: int = 1

# ---- Tiered-exponential defaults (used when a,b are not overridden) ----
const TIER_SPAN_DEFAULT: int = 3
const START_DEFAULT: int = DEFAULT_A * 1 + DEFAULT_B     # 16 at floor 1 (matches old feel)
const TIER_GROWTH_DEFAULT: float = 1.25                   # +25% per triad
const INTRA_STEPS_DEFAULT: Array[float] = [0.0, 0.45, 1.0]  # 1st, 2nd, boss  (must be Array[float], not Packed*)

# ------------------------- Public API (unchanged) -----------------------------

static func base_for_floor(floor: int, a: int = DEFAULT_A, b: int = DEFAULT_B) -> int:
	var use_linear: bool = (a != DEFAULT_A or b != DEFAULT_B)
	if use_linear:
		var f: int = max(1, floor)
		return max(0, a * f + b)
	return _base_tiered_exp(floor, START_DEFAULT, TIER_GROWTH_DEFAULT, TIER_SPAN_DEFAULT, INTRA_STEPS_DEFAULT)

static func band_for_floor(
		floor: int,
		a: int = DEFAULT_A,
		b: int = DEFAULT_B,
		volatility: float = DEFAULT_VOLATILITY
	) -> Vector2i:
	var base_val: int = base_for_floor(floor, a, b)
	var v: float = max(0.0, volatility)
	var min_f: float = float(base_val) * (1.0 - v)
	var max_f: float = float(base_val) * (1.0 + v)
	var min_i: int = int(round(min_f))
	var max_i: int = int(round(max_f))
	if max_i < min_i:
		var tmp: int = min_i; min_i = max_i; max_i = tmp
	min_i = max(MIN_POWER_LEVEL, min_i)
	max_i = max(MIN_POWER_LEVEL, max_i)
	return Vector2i(min_i, max_i)

static func roll_power_level(
		floor: int,
		a: int = DEFAULT_A,
		b: int = DEFAULT_B,
		volatility: float = DEFAULT_VOLATILITY,
		rng: RandomNumberGenerator = null
	) -> int:
	var band: Vector2i = band_for_floor(floor, a, b, volatility)
	var local_rng: RandomNumberGenerator = rng if rng != null else RandomNumberGenerator.new()
	if rng == null:
		local_rng.randomize()
	var rolled: int = local_rng.randi_range(band.x, band.y)  # inclusive
	return max(MIN_POWER_LEVEL, rolled)

# Optional helper
static func apply_role_mult(pl: int, role: String) -> int:
	var m: float = 1.0
	match role:
		"elite": m = 1.30
		"boss":  m = 1.50
		_:       m = 1.0
	return max(MIN_POWER_LEVEL, int(round(float(pl) * m)))

# ------------------------- Internal: tiered exponential -----------------------

static func _tier_index_for_floor(floor: int, span: int) -> int:
	var f: int = max(1, floor)
	return int((f - 1) / max(1, span))

static func _index_in_tier(floor: int, span: int) -> int:
	var f: int = max(1, floor)
	return int((f - 1) % max(1, span))

static func _base_tiered_exp(
		floor: int,
		start: int,
		tier_growth: float,
		span: int,
		intra_steps: Array[float]
	) -> int:
	var t: int = _tier_index_for_floor(floor, span)
	var i: int = _index_in_tier(floor, span)

	var s: float = 0.0
	if i < intra_steps.size():
		s = clampf(float(intra_steps[i]), 0.0, 1.0)
	else:
		var denom: int = max(1, span - 1)
		s = float(i) / float(denom)

	var g: float = max(1.0, tier_growth)
	var tier_base: float = float(max(MIN_POWER_LEVEL, start)) * pow(g, float(t))
	var base_f: float = tier_base * (1.0 + s * (g - 1.0))  # multiplicative ramp toward next tier
	return max(MIN_POWER_LEVEL, int(round(base_f)))
