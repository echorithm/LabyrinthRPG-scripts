# res://scripts/dungeon/encounters/SetPowerLevel.gd
extends RefCounted
class_name SetPowerLevel
##
# Linear base + symmetric band power generator (no role/rarity).
# - Base(floor) = a * floor + b
# - Band = Base ± (volatility * Base)
# - Result = uniform int within [min_band..max_band], clamped >= 1
#
# Defaults (Balanced): a=6, b=10, volatility=0.15
# You can override per-call.
##

# ---- Defaults (tweak here if you want project-wide changes) ----
const DEFAULT_A: int = 1
const DEFAULT_B: int = 5
const DEFAULT_VOLATILITY: float = 0.15
const MIN_POWER_LEVEL: int = 1

static func base_for_floor(floor: int, a: int = DEFAULT_A, b: int = DEFAULT_B) -> int:
	# Guard floor to 1+ and compute linear base.
	var f: int = max(1, floor)
	return max(0, a * f + b)

static func band_for_floor(
		floor: int,
		a: int = DEFAULT_A,
		b: int = DEFAULT_B,
		volatility: float = DEFAULT_VOLATILITY
	) -> Vector2i:
	# Returns inclusive [min, max] as Vector2i
	var base_val: int = base_for_floor(floor, a, b)
	var v: float = max(0.0, volatility)
	var min_f: float = float(base_val) * (1.0 - v)
	var max_f: float = float(base_val) * (1.0 + v)
	var min_i: int = int(round(min_f))
	var max_i: int = int(round(max_f))
	if max_i < min_i:
		var tmp: int = min_i
		min_i = max_i
		max_i = tmp
	# Ensure at least MIN_POWER_LEVEL on the lower bound.
	min_i = max(MIN_POWER_LEVEL, min_i)
	return Vector2i(min_i, max_i)

static func roll_power_level(
		floor: int,
		a: int = DEFAULT_A,
		b: int = DEFAULT_B,
		volatility: float = DEFAULT_VOLATILITY,
		rng: RandomNumberGenerator = null
	) -> int:
	# Draws a random integer within the band. If no RNG is provided, uses a fresh randomized RNG.
	var band: Vector2i = band_for_floor(floor, a, b, volatility)
	var local_rng: RandomNumberGenerator = rng if rng != null else RandomNumberGenerator.new()
	if rng == null:
		local_rng.randomize()
	var rolled: int = local_rng.randi_range(band.x, band.y)  # inclusive
	return max(MIN_POWER_LEVEL, rolled)
