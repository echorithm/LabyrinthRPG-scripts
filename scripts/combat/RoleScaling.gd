# res://scripts/combat/RoleScaling.gd
extends RefCounted
class_name RoleScaling

const DerivedCalc := preload("res://scripts/combat/derive/DerivedCalc.gd")

static func multiplier_for_role(role: String) -> float:
	var r := role.to_lower()
	match r:
		"elite":
			return 1.30
		"boss":
			return 1.50
		_:
			return 1.0

# Recompute all deriveds from final_stats.
static func _recompute(mon: MonsterRuntime) -> void:
	mon.hp_max      = DerivedCalc.hp_max(mon.final_stats, {})
	mon.mp_max      = DerivedCalc.mp_max(mon.final_stats, {})
	mon.p_atk       = DerivedCalc.p_atk(mon.final_stats)
	mon.m_atk       = DerivedCalc.m_atk(mon.final_stats)
	mon.defense     = DerivedCalc.defense(mon.final_stats)
	mon.resistance  = DerivedCalc.resistance(mon.final_stats)
	mon.crit_chance = DerivedCalc.crit_chance(mon.final_stats, {})
	mon.crit_multi  = DerivedCalc.crit_multi(mon.final_stats, {})
	mon.ctb_speed   = DerivedCalc.ctb_speed(mon.final_stats)

## Scales MonsterRuntime.final_stats in-place, then recomputes deriveds.
## If `fill_to_max` is true (default), HP/MP are filled to the new max (use this at spawn).
## If false, current HP/MP are clamped to the new max (use mid-fight adjustments).
static func apply(mon: MonsterRuntime, role: String) -> void:
	var m: float = multiplier_for_role(role)
	if m <= 1.001:
		return

	# were we full before scaling?
	var was_full := (mon.hp >= mon.hp_max) and (mon.hp_max > 0)

	# scale all 8 base stats
	var keys := ["STR","AGI","DEX","END","INT","WIS","CHA","LCK"]
	for k in keys:
		var v: int = int(mon.final_stats.get(k, 0))
		mon.final_stats[k] = int(round(float(v) * m))

	# recompute deriveds
	mon.hp_max = DerivedCalc.hp_max(mon.final_stats, {})
	mon.mp_max = DerivedCalc.mp_max(mon.final_stats, {})
	mon.p_atk = DerivedCalc.p_atk(mon.final_stats)
	mon.m_atk = DerivedCalc.m_atk(mon.final_stats)
	mon.defense = DerivedCalc.defense(mon.final_stats)
	mon.resistance = DerivedCalc.resistance(mon.final_stats)
	mon.crit_chance = DerivedCalc.crit_chance(mon.final_stats, {})
	mon.crit_multi  = DerivedCalc.crit_multi(mon.final_stats, {})
	mon.ctb_speed   = DerivedCalc.ctb_speed(mon.final_stats)

	# pools
	if was_full:
		mon.hp = mon.hp_max
	else:
		mon.hp = clampi(mon.hp, 0, mon.hp_max)
	mon.mp = clampi(mon.mp, 0, mon.mp_max)
