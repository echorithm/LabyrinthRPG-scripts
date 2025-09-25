extends RefCounted
class_name XpTuning

# -----------------------
# Character XP curve
# -----------------------
static func xp_to_next(level: int) -> int:
	var lvl: int = max(1, level)
	return int(round(90.0 * pow(1.13, float(lvl - 1))))

# Overlevel diminishing returns (player over target)
static func overlevel_factor(player_level: int, target_level: int) -> float:
	var delta: int = max(0, player_level - target_level)
	var grace: int = 2
	if delta <= grace:
		return 1.0
	var extra: int = delta - grace
	return pow(0.88, float(extra))

# -----------------------
# Skill XP (on-hit only)
# -----------------------
const SKILL_XP_BASE: float = 6.0
const SKILL_XP_VAR: float = 0.25   # ±25%
const SKILL_XP_MIN: int = 1
const SKILL_XP_MAX: int = 40

static func skill_xp_for_hit(player_level: int, target_level: int, s_power: float, rng: RandomNumberGenerator) -> int:
	var dr: float = overlevel_factor(player_level, target_level)
	var wiggle: float = 0.875 + rng.randf() * (SKILL_XP_VAR * 2.0)
	var base: float = SKILL_XP_BASE * wiggle
	var sp: float = max(0.25, pow(max(0.25, s_power), 0.5))
	var out_i: int = int(round(base * dr * sp))
	return clamp(out_i, SKILL_XP_MIN, SKILL_XP_MAX)

# -----------------------
# Character XP (on victory/open)
# -----------------------
static func char_xp_baseline_for(source: String) -> int:
	match source:
		"trash":         return 7
		"elite":         return 28
		"boss":          return 160
		"common_chest":  return 5
		"rare_chest":    return 10
		_:               return 0

static func _rarity_mult(code: String) -> float:
	match code:
		"C": return 1.00
		"U": return 1.10
		"R": return 1.25
		"E": return 1.50
		"A": return 1.80
		"L": return 2.20
		"M": return 2.60
		_:   return 1.00

static func char_xp_for_victory(player_level: int, target_level: int, source: String, rarity_code: String, rng: RandomNumberGenerator) -> int:
	var base: int = char_xp_baseline_for(source)
	if base <= 0:
		return 0
	var dr: float = overlevel_factor(player_level, target_level)  # diminishing when overleveled
	var rar: float = _rarity_mult(rarity_code)
	var wiggle: float = 0.90 + rng.randf() * 0.20  # ±10%
	var out_f: float = float(base) * rar * dr * wiggle
	return int(round(out_f))
