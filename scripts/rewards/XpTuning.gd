extends RefCounted
class_name XpTuning

# -----------------------
# Level difference multiplier (shared by char + skill XP)
# Same level  → 1.00
# Overleveled → grace of LD_GRACE levels, then decay by LD_OVER_FALLOFF^n (never hits 0)
# Underleveled → +LD_UNDER_PER_LVL per level up to LD_UNDER_CAP
# -----------------------
const LD_GRACE: int = 2              # free levels before decay kicks in
const LD_OVER_FALLOFF: float = 0.88  # 12% less per extra level (post-grace)
const LD_UNDER_PER_LVL: float = 0.10 # +10% per level when underleveled
const LD_UNDER_CAP: float = 0.50     # cap underleveled bonus at +50%

# -----------------------
# Character XP curve
# -----------------------
static func xp_to_next(level: int) -> int:
	var lvl: int = max(1, level)
	return int(round(90.0 * pow(1.13, float(lvl - 1))))

# -----------------------
# Level difference multiplier (symmetric)
# -----------------------
# Overleveled: grace of 2 levels, then -12% per extra level (0.88^n)
# Underleveled: +10% per level, capped at +50%
static func level_diff_factor(player_level: int, target_level: int) -> float:
	var p: int = max(1, player_level)
	var t: int = max(1, target_level)
	print("player and monster levels")
	print(p, t)
	var delta: int = p - t
	if delta == 0:
		return 1.0

	# Player above target
	if delta > 0:
		if delta <= LD_GRACE:
			return 1.0
		var extra: int = delta - LD_GRACE
		return pow(LD_OVER_FALLOFF, float(extra)) # asymptotic > 0

	# Player below target
	var under: int = -delta
	return 1.0 + min(LD_UNDER_CAP, LD_UNDER_PER_LVL * float(under))

# Back-compat shim (kept for any older callers)
static func overlevel_factor(player_level: int, target_level: int) -> float:
	return level_diff_factor(player_level, target_level)

# -----------------------
# Skill XP (per-hit baseline)
# -----------------------
const SKILL_XP_BASE: float = 6.0
const SKILL_XP_VAR: float = 0.25   # ±25%
const SKILL_XP_MIN: int = 1
const SKILL_XP_MAX: int = 40

static func skill_xp_for_hit(player_level: int, target_level: int, s_power: float, rng: RandomNumberGenerator) -> int:
	var dr: float = level_diff_factor(player_level, target_level)
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
	var ld: float = level_diff_factor(player_level, target_level)  # symmetric multiplier (over/under)
	var rar: float = _rarity_mult(rarity_code)
	var wiggle: float = 0.90 + rng.randf() * 0.20  # ±10%
	var out_f: float = float(base) * rar * ld * wiggle
	return int(round(out_f))

# -----------------------
# Skill XP (on victory – per ability)
# -----------------------
# Award at encounter end, proportional to uses. Role: elite +30%, boss +50%.
# Level diff still applies; no spam diminishing (simplicity).
static func skill_xp_for_victory(uses: int, player_level: int, target_level: int, role: String, rng: RandomNumberGenerator) -> int:
	var count: int = max(0, uses)
	if count <= 0:
		return 0

	# Per-use baseline: slightly lower than an on-hit average so victory sums feel fair.
	var per_use_base: float = 3.0
	var dr: float = level_diff_factor(player_level, target_level)
	var role_mult: float = 1.0
	match role:
		"elite":
			role_mult = 1.30
		"boss":
			role_mult = 1.50
		_:
			role_mult = 1.00

	# Small ±10% wiggle per encounter
	var wiggle: float = 0.90 + rng.randf() * 0.20

	var total_f: float = float(count) * per_use_base * dr * role_mult * wiggle
	var total: int = int(round(total_f))

	# Clamp per encounter to something sane; we can tune later.
	return clamp(total, 0, 200)
