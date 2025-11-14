# res://scripts/rewards/XpTuning.gd
extends RefCounted
class_name XpTuning
##
## XP v2 — Deterministic, per-enemy, victory-only
## - Per enemy: 10 × M
## - Δ-scaler:
##     • Δ = P − M ≥ 0 → max(1 − 0.095×Δ, 0.05)
##     • Δ < 0 → 1 + 0.10×(−Δ)   (uncapped)
## - Role mult: TRASH ×1.00, ELITE ×1.30, BOSS ×1.50
## - Round ONCE per enemy AFTER role multiplier; then sum
## - XP_to_next: 100 × PowerMult(diff) × (level^2)
## - Chests give 0 XP (combat-only policy)

enum Role { TRASH, ELITE, BOSS }

static var DEBUG: bool = false
const _DBG_PREFIX := "[XpTuning] "

static func _log(msg: String) -> void:
	if DEBUG:
		print(_DBG_PREFIX + msg)

const DIFFICULTY_POWER_MULT: Dictionary = {
	"C": 1.00, "U": 1.65, "R": 2.62, "E": 3.98, "A": 5.74, "L": 7.78, "M": 9.79
}

static func role_multiplier(role: int) -> float:
	match role:
		Role.ELITE: return 1.30
		Role.BOSS:  return 1.50
		_:          return 1.00

static func _delta_factor(player_level: int, monster_level: int) -> float:
	var p: int = max(1, player_level)
	var m: int = max(1, monster_level)
	var delta: int = p - m
	if delta >= 0:
		var f: float = 1.0 - 0.095 * float(delta)
		return f if f > 0.05 else 0.05
	else:
		return 1.0 + 0.10 * float(-delta)

## Per-enemy XP (rounded once, post role-mult)
static func xp_for_enemy(player_level: int, monster_level: int, role: int = Role.TRASH) -> int:
	var m: int = max(monster_level, 1)
	var base: int = 10 * m
	var f: float = _delta_factor(player_level, m)
	var out_f: float = float(base) * f * role_multiplier(role)
	var out: int = int(round(out_f))
	# _log("xp_for_enemy: P=" + str(player_level) + " M=" + str(m) + " role=" + str(role) + " → " + str(out))
	return out

## Character XP for an encounter: sum per-enemy rounded values; optional ally split
## enemies: Array[{ "monster_level":int, "role":int }]
static func char_xp_for_victory_v2(player_level: int, enemies: Array, allies_count: int = 1) -> int:
	var total: int = 0
	for e_any in enemies:
		if not (e_any is Dictionary):
			continue
		var e: Dictionary = e_any
		total += xp_for_enemy(player_level, int(e.get("monster_level", 1)), int(e.get("role", Role.TRASH)))
	if allies_count > 1:
		return int(round(float(total) / float(allies_count)))
	return total

## Skill XP: per-ability sum of (uses_on_enemy[i] × per_enemy_xp[i])
## ability_hits_by_enemy: { ability_id:String -> { enemy_index:int -> uses:int } }
static func skill_xp_for_victory_v2(player_level: int, enemies: Array, ability_hits_by_enemy: Dictionary) -> Dictionary:
	var per_enemy: Array[int] = []
	per_enemy.resize(enemies.size())
	for i in enemies.size():
		var e: Dictionary = enemies[i]
		per_enemy[i] = xp_for_enemy(player_level, int(e.get("monster_level", 1)), int(e.get("role", Role.TRASH)))
	var out: Dictionary = {}
	for aid in ability_hits_by_enemy.keys():
		var by_enemy_any: Variant = ability_hits_by_enemy[aid]
		if not (by_enemy_any is Dictionary):
			continue
		var by_enemy: Dictionary = by_enemy_any
		var sum_i: int = 0
		for idx_any in by_enemy.keys():
			var idx: int = int(idx_any)
			if idx >= 0 and idx < per_enemy.size():
				sum_i += int(by_enemy[idx_any]) * per_enemy[idx]
		out[aid] = sum_i
	return out

## Difficulty-scaled threshold (explicit code)
static func xp_to_next_level_v2(level: int, difficulty_code: String = "C") -> int:
	var l: int = max(1, level)
	var mult: float = float(DIFFICULTY_POWER_MULT.get(difficulty_code, 1.0))
	var out: int = int(round(100.0 * mult * float(l * l)))
	# _log("xp_to_next_level_v2: L=" + str(l) + " diff=" + difficulty_code + " → " + str(out))
	return out

# ---------------- Back-compat shims (legacy callers & loot system) -----------

## Legacy name still used by some systems → now difficulty-aware (RUN→META→C)
static func xp_to_next(level: int) -> int:
	var l: int = max(1, level)
	var diff_code: String = "C"

	# Resolve difficulty directly from the SaveManager autoload (RUN → META → "C")
	var c_run: String = String(SaveManager.get_run_difficulty_code())
	if c_run.length() == 1:
		diff_code = c_run
	else:
		var c_meta: String = String(SaveManager.get_difficulty_code())
		if c_meta.length() == 1:
			diff_code = c_meta

	var out: int = xp_to_next_level_v2(l, diff_code)
	# _log("xp_to_next(legacy): L=" + str(l) + " diff=" + diff_code + " → " + str(out))
	return out

## Legacy helpers, unchanged
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

static func level_diff_factor(player_level: int, target_level: int) -> float:
	return _delta_factor(player_level, target_level)

static func char_xp_for_victory(player_level: int, target_level: int, source: String, _rarity_code: String, _rng: RandomNumberGenerator) -> int:
	var s := source.to_lower()
	if s.findn("chest") != -1:
		return 0
	var role: int = Role.TRASH
	if s == "elite":
		role = Role.ELITE
	elif s == "boss":
		role = Role.BOSS
	return xp_for_enemy(player_level, target_level, role)
