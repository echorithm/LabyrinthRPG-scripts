extends RefCounted
class_name RoleScaling

const DerivedCalc := preload("res://scripts/combat/derive/DerivedCalc.gd")

static func multiplier_for_role(role: String) -> float:
	var r := role.to_lower()
	if r == "elite":
		return 1.30
	elif r == "boss":
		return 1.50
	return 1.0

## Scales MonsterRuntime.final_stats in-place, then recomputes deriveds.
static func apply(mon: MonsterRuntime, role: String) -> void:
	var m: float = multiplier_for_role(role)
	if m <= 1.001:
		return
	# scale all 8 base stats
	var keys := ["STR","AGI","DEX","END","INT","WIS","CHA","LCK"]
	for k in keys:
		var v := int(mon.final_stats.get(k, 0))
		mon.final_stats[k] = int(round(float(v) * m))
	# recompute deriveds
	mon.hp_max = DerivedCalc.hp_max(mon.final_stats, {})
	mon.mp_max = DerivedCalc.mp_max(mon.final_stats, {})
	mon.hp = clampi(mon.hp, 0, mon.hp_max)
	mon.mp = clampi(mon.mp, 0, mon.mp_max)
	mon.p_atk = DerivedCalc.p_atk(mon.final_stats)
	mon.m_atk = DerivedCalc.m_atk(mon.final_stats)
	mon.defense = DerivedCalc.defense(mon.final_stats)
	mon.resistance = DerivedCalc.resistance(mon.final_stats)
	mon.crit_chance = DerivedCalc.crit_chance(mon.final_stats, {})
	mon.crit_multi  = DerivedCalc.crit_multi(mon.final_stats, {})
	mon.ctb_speed   = DerivedCalc.ctb_speed(mon.final_stats)
