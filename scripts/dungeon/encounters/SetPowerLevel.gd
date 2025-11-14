# res://scripts/dungeon/encounters/SetPowerLevel.gd
extends RefCounted
class_name SetPowerLevel
##
# Power Level generator (linear envelopes).
# - Trash MIN:  y = 3.67x + 4
# - Trash MAX:  z = 5.56x
# - Elite  = 1.30 × trash
# - Boss   = 1.50 × trash
# - Deterministic midpoint if rng == null.
# - Public API kept compatible: base_for_floor, band_for_floor, roll_power_level, effective_for.

const MIN_POWER_LEVEL: int = 1

# Role multipliers
const ELITE_MULT: float = 1.30
const BOSS_MULT: float = 1.50

# Debug toggle
const DEBUG_PL: bool = true

# ------------------------- Public API (compat) -------------------------

static func base_for_floor(floor: int, a: int = 0, b: int = 0) -> int:
	# Midpoint of the trash band under the linear envelopes.
	var band: Vector2i = band_for_floor(floor, 0, 0, 0.0)
	return int((band.x + band.y) / 2)

static func band_for_floor(
		floor: int,
		a: int = 0,
		b: int = 0,
		volatility: float = 0.0
	) -> Vector2i:
	var f: int = max(1, floor)

	var min_pl: int = _min_for_floor(f)
	var max_pl: int = _max_for_floor(f)

	# Safety clamps
	if max_pl < min_pl:
		max_pl = min_pl
	min_pl = max(MIN_POWER_LEVEL, min_pl)
	max_pl = max(MIN_POWER_LEVEL, max_pl)

	if DEBUG_PL:
		_print_debug_band(f, min_pl, max_pl)

	return Vector2i(min_pl, max_pl)

static func roll_power_level(
		floor: int,
		a: int = 0,
		b: int = 0,
		volatility: float = 0.0,
		rng: RandomNumberGenerator = null
	) -> int:
	var band: Vector2i = band_for_floor(floor, 0, 0, 0.0)

	var rolled: int
	if rng == null:
		# Deterministic midpoint
		rolled = int((band.x + band.y) / 2)
		if DEBUG_PL:
			print_rich("[color=cyan][SetPL.roll][/color] floor=", floor,
				" band=[", band.x, ",", band.y, "] midpoint=", rolled, " (rng=null)")
	else:
		rolled = rng.randi_range(band.x, band.y)
		if DEBUG_PL:
			print_rich("[color=cyan][SetPL.roll][/color] floor=", floor,
				" band=[", band.x, ",", band.y, "] -> rolled=", rolled)

	return max(MIN_POWER_LEVEL, rolled)

static func apply_role_mult(pl: int, role: String) -> int:
	var m: float = 1.0
	match role:
		"elite": m = ELITE_MULT
		"boss":  m = BOSS_MULT
		_:       m = 1.0
	return max(MIN_POWER_LEVEL, int(round(float(pl) * m)))

# One-liner for effective PL for (floor, role) with determinism.
static func effective_for(floor: int, role: String = "trash", rng: RandomNumberGenerator = null) -> int:
	var pl_raw: int = roll_power_level(floor, 0, 0, 0.0, rng)
	var eff: int = apply_role_mult(pl_raw, role)
	if DEBUG_PL:
		print_rich("[color=cyan][SetPL.eff][/color] floor=", floor, " role='", role,
			"' raw=", pl_raw, " -> eff=", eff)
	return eff

# ------------------------------- Internal -------------------------------------

# Trash MIN: y = 3.67x + 4  (rounded to hit anchors: 9→37, 18→70, 27→104, 36→137)
static func _min_for_floor(floor: int) -> int:
	var f: int = max(1, floor)
	var k: int = int((f - 1) / 9)  # 0 for 1–9, 1 for 10–18, 2 for 19–27, ...
	var y: int = 4 * f + 1 - 3 * k
	return y

static func _max_for_floor(floor: int) -> int:
	var f: int = max(1, floor)
	var k: int = int((f - 1) / 9)
	var z: int = 5 * f + 5 * (1 + k)
	return z

static func _print_debug_band(floor: int, min_pl: int, max_pl: int) -> void:
	print_rich(
		"[color=cyan][SetPL.band][/color] floor=", floor,
		" min=", min_pl,
		" max=", max_pl
	)
