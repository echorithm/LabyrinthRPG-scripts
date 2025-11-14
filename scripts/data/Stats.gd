# Godot 4.4.1 — Base stats (DnD/LitRPG-ish) with derived helpers.
extends Resource
class_name Stats

@export var level: int = 1

@export var strength: int = 5
@export var agility: int = 5
@export var dexterity: int = 5
@export var endurance: int = 5
@export var intelligence: int = 5
@export var wisdom: int = 5
@export var charisma: int = 5
@export var luck: int = 5

# ---------- Derived attributes (per your plan) ----------
func max_hp() -> int:
	return 20 + 6 * endurance + 2 * level

func speed() -> int:
	# CTB “speed”: 8 + 0.6*AGI + 0.2*DEX + 0.1*LCK
	return int(round(8.0 + 0.6 * float(agility) + 0.2 * float(dexterity) + 0.1 * float(luck)))

func ac() -> int:
	# 10 + floor(DEX*0.5) + floor(AGI*0.3)
	return 10 + int(floor(float(dexterity) * 0.5)) + int(floor(float(agility) * 0.3))

func phys_def() -> int:
	# round(0.6*END + 0.2*STR)
	return int(round(0.6 * float(endurance) + 0.2 * float(strength)))

func mag_res() -> int:
	# round(0.6*WIS + 0.2*INT)
	return int(round(0.6 * float(wisdom) + 0.2 * float(intelligence)))

func accuracy_bonus(school: StringName) -> int:
	# DnD-ish to-hit bonus by school
	match school:
		&"power":
			return int(round(0.5 * float(strength) + 0.5 * float(level) + 0.2 * float(luck)))
		&"finesse":
			return int(round(0.5 * float(dexterity) + 0.5 * float(level) + 0.2 * float(luck)))
		&"arcane":
			return int(round(0.5 * float(intelligence) + 0.5 * float(level) + 0.2 * float(wisdom)))
		&"divine":
			return int(round(0.5 * float(wisdom) + 0.5 * float(level) + 0.2 * float(luck)))
		_:
			return int(round(0.3 * float(level)))

func evasion_chance() -> float:
	# 5% + 0.6%*AGI + 0.2%*LCK (cap later)
	return clampf(0.05 + 0.006 * float(agility) + 0.002 * float(luck), 0.0, 0.50)

func crit_chance() -> float:
	# 5% + 0.4%*DEX + 0.4%*LCK (cap ~35%)
	return clampf(0.05 + 0.004 * float(dexterity) + 0.004 * float(luck), 0.0, 0.35)

func crit_mult() -> float:
	# 1.5 + 0.01*STR + 0.005*LCK (cap ~2.5)
	return min(1.5 + 0.01 * float(strength) + 0.005 * float(luck), 2.5)

func copy() -> Stats:
	var s: Stats = Stats.new()
	s.level = level
	s.strength = strength
	s.agility = agility
	s.dexterity = dexterity
	s.endurance = endurance
	s.intelligence = intelligence
	s.wisdom = wisdom
	s.charisma = charisma
	s.luck = luck
	return s
