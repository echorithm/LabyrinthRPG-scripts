# Centralized combat math: to-hit, damage/heal, CTB.
class_name ActionResolver
extends RefCounted

class HitResult:
	var hit: bool = false
	var crit: bool = false
	var roll: int = 0
	var target: int = 0

static var _rng: RandomNumberGenerator = RandomNumberGenerator.new()
static var _rng_ready: bool = false

static func _rngf() -> float:
	if not _rng_ready:
		_rng.randomize()
		_rng_ready = true
	return _rng.randf()

static func _randi_range(a: int, b: int) -> int:
	if not _rng_ready:
		_rng.randomize()
		_rng_ready = true
	return _rng.randi_range(a, b)

static func roll_to_hit(attacker: Stats, defender: Stats, to_hit: bool, school: StringName, crit_allowed: bool) -> HitResult:
	var hr := HitResult.new()
	var target: int = defender.ac()
	hr.target = target
	if not to_hit:
		# Auto-hit actions (e.g., many spells/heals). Allow crit via crit chance if permitted.
		hr.hit = true
		hr.roll = 0
		if crit_allowed and _rngf() < attacker.crit_chance():
			hr.crit = true
		return hr

	var roll: int = _randi_range(1, 20)
	hr.roll = roll
	if roll == 1:
		hr.hit = false
		return hr
	var bonus: int = attacker.accuracy_bonus(school)
	if roll == 20:
		hr.hit = true
		hr.crit = crit_allowed
		return hr

	hr.hit = (roll + bonus) >= target
	if hr.hit and crit_allowed and _rngf() < attacker.crit_chance():
		hr.crit = true
	return hr

static func compute_damage(attacker: Stats, defender: Stats, base_power: int, school: StringName, crit_allowed: bool, hit: HitResult, skill_lv: int) -> int:
	if not hit.hit:
		return 0
	var scale: float = 1.0
	match school:
		&"power":
			scale += 0.04 * float(attacker.strength)
		&"finesse":
			scale += 0.035 * float(attacker.dexterity)
		&"arcane":
			scale += 0.05 * float(attacker.intelligence)
		&"divine":
			scale += 0.05 * float(attacker.wisdom)
		_:
			scale += 0.02 * float(attacker.level)

	# Skill level bonus
	scale *= (1.0 + 0.02 * float(max(1, skill_lv)))

	var raw: float = float(max(0, base_power)) * scale

	# Mitigation: physical vs magical
	var phys: bool = (school == &"power" or school == &"finesse")
	var mit_stat: int = defender.phys_def() if phys else defender.mag_res()
	var mitig: float = 100.0 / (100.0 + 8.0 * float(max(0, mit_stat)))
	var dmg: float = raw * mitig

	# Crit
	if hit.crit and crit_allowed:
		dmg *= attacker.crit_mult()

	# Small randomization (±5%) to keep numbers lively
	var jitter: float = 0.95 + 0.10 * _rngf()
	dmg *= jitter

	return max(1, int(round(dmg)))

static func compute_heal(attacker: Stats, base_power: int, school: StringName, skill_lv: int) -> int:
	var scale: float = 1.0
	if school == &"divine":
		scale += 0.05 * float(attacker.wisdom)
	else:
		scale += 0.05 * float(attacker.intelligence)
	scale *= (1.0 + 0.02 * float(max(1, skill_lv)))
	var amt: float = float(max(0, base_power)) * scale
	return max(1, int(round(amt)))

static func compute_ctb(attacker_speed: int, base_cost: int, skill_lv: int, haste: float = 1.0) -> int:
	var s: float = float(max(1, attacker_speed))
	var cost: float = float(max(1, base_cost))
	var mult: float = haste * (1.0 - 0.02 * float(max(0, skill_lv - 1)))
	return int(ceil(cost / s * mult))
