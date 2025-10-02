# Godot 4.4.1
extends RefCounted
class_name ActionResolver

# --- Public: generalized single-target attack -------------------------------
# attack_kind: "physical" or "magical"
# Returns a Dictionary event, including hit/miss/crit, dmg, roll, and ability metadata.
static func resolve_attack(
	attacker_stats: Dictionary,
	attacker_nums: Dictionary,
	defender_stats: Dictionary,
	defender_nums: Dictionary,
	defender_guard: bool,
	crit_multi: float,
	rng: RandomNumberGenerator,
	who: String,
	ability_id: StringName,
	attack_kind: String,
	ability_anim_key: String = "",
	opts: Dictionary = {}            # <-- NEW (optional)
) -> Dictionary:
	var roll: int = _roll_d20(rng)
	var atk_bonus: int = (_attack_bonus_physical(attacker_stats) if attack_kind == "physical" else _attack_bonus_magic(attacker_stats))
	var dc: int = (_armor_class(defender_stats) if attack_kind == "physical" else _resist_class(defender_stats))

	var natural: int = roll
	var hit := false
	var crit := false
	var fumble := false

	if natural == 1:
		hit = false; fumble = true
	elif natural == 20:
		hit = true;  crit = true
	else:
		var total: int = roll + atk_bonus
		hit = (total >= dc)
		if hit:
			var lck: float = float(attacker_stats.get("LCK", 0))
			var extra_crit_chance: float = min(0.10, (lck * 0.005 * 0.5))
			if rng.randf() < extra_crit_chance:
				crit = true

	var dmg := 0
	var consumed_guard := false

	if hit:
		var atk_num: float = float(attacker_nums.get("p_atk" if attack_kind == "physical" else "m_atk", 0.0))
		var def_num: float = float(defender_nums.get("defense" if attack_kind == "physical" else "resistance", 0.0))
		var base: float = max(1.0, atk_num - def_num * 0.5)
		var variance: float = 0.90 + rng.randf() * 0.20
		var total: float = base * variance

		if defender_guard:
			total *= 0.5
			consumed_guard = true
		if crit:
			total *= max(1.0, crit_multi)

		# --- NEW: per-skill scaling (defaults to 1.0) ---
		var power_mult: float = 1.0
		if opts.has("power_mult"):
			power_mult = max(0.0, float(opts["power_mult"]))
		total *= power_mult

		dmg = int(round(total))

	var ev: Dictionary = {
		"who": who,
		"type": "attack" if hit else "miss",
		"ability_id": String(ability_id),
		"animation_key": ability_anim_key,
		"roll": natural,
		"atk_bonus": atk_bonus,
		"dc": dc,
		"hit": hit,
		"crit": crit,
		"fumble": fumble,
		"dmg": dmg,
		"consumed_guard": consumed_guard,
		"kind": attack_kind
	}

	# --- NEW: surface rider info (optional; harmless if unused) ---
	if opts.has("rider") and opts["rider"] is Dictionary:
		var r: Dictionary = opts["rider"]
		ev["rider"] = {
			"type": String(r.get("type","")),
			"pct": float(r.get("pct", 0.0)),
			"duration_turns": int(r.get("duration_turns", 0))
		}

	return ev


# Convenience wrapper used by player basic physical
static func resolve_basic_physical(attacker_stats: Dictionary, attacker_nums: Dictionary, defender_stats: Dictionary, defender_nums: Dictionary, defender_guard: bool, crit_multi: float, rng: RandomNumberGenerator, who: String, ability_id: StringName = &"basic_attack") -> Dictionary:
	return resolve_attack(attacker_stats, attacker_nums, defender_stats, defender_nums, defender_guard, crit_multi, rng, who, ability_id, "physical", "")

# --- Helpers ----------------------------------------------------------------
static func _roll_d20(rng: RandomNumberGenerator) -> int:
	return rng.randi_range(1, 20)

static func _attack_bonus_physical(stats: Dictionary) -> int:
	var STRv: float = float(stats.get("STR", 0))
	var DEXv: float = float(stats.get("DEX", 0))
	return int(floor(STRv * 0.5 + DEXv * 0.25))

static func _attack_bonus_magic(stats: Dictionary) -> int:
	var INTv: float = float(stats.get("INT", 0))
	var WISv: float = float(stats.get("WIS", 0))
	return int(floor(INTv * 0.5 + WISv * 0.25))

static func _armor_class(stats: Dictionary) -> int:
	var ENDv: float = float(stats.get("END", 0))
	var DEXv: float = float(stats.get("DEX", 0))
	return 10 + int(floor(ENDv * 0.6 + DEXv * 0.4))

static func _resist_class(stats: Dictionary) -> int:
	var WISv: float = float(stats.get("WIS", 0))
	var ENDv: float = float(stats.get("END", 0))
	return 10 + int(floor(WISv * 0.6 + ENDv * 0.4))
