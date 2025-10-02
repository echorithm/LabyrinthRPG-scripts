# Godot 4.4.1
extends RefCounted
class_name DerivedCalc
##
## Pure functions to compute derived combat stats from the 8 bases.

static func hp_max(stats: Dictionary, caps: Dictionary = {}) -> int:
	var ENDv: float = float(stats.get("END", 0))
	var STRv: float = float(stats.get("STR", 0))
	return int(round(ENDv * 14.0 + STRv * 2.0))

static func mp_max(stats: Dictionary, caps: Dictionary = {}) -> int:
	var INTv: float = float(stats.get("INT", 0))
	var WISv: float = float(stats.get("WIS", 0))
	return int(round(INTv * 7.0 + WISv * 5.0))

static func p_atk(stats: Dictionary) -> float:
	var STRv: float = float(stats.get("STR", 0))
	var DEXv: float = float(stats.get("DEX", 0))
	var AGIv: float = float(stats.get("AGI", 0))
	return STRv * 2.0 + DEXv * 1.0 + AGIv * 0.5

static func m_atk(stats: Dictionary) -> float:
	var INTv: float = float(stats.get("INT", 0))
	var WISv: float = float(stats.get("WIS", 0))
	var DEXv: float = float(stats.get("DEX", 0))
	return INTv * 2.0 + WISv * 1.0 + DEXv * 0.5

static func defense(stats: Dictionary) -> float:
	var ENDv: float = float(stats.get("END", 0))
	var DEXv: float = float(stats.get("DEX", 0))
	return ENDv * 1.8 + DEXv * 0.7

static func resistance(stats: Dictionary) -> float:
	var WISv: float = float(stats.get("WIS", 0))
	var ENDv: float = float(stats.get("END", 0))
	return WISv * 1.6 + ENDv * 0.6

static func crit_chance(stats: Dictionary, caps: Dictionary = {}) -> float:
	var LCKv: float = float(stats.get("LCK", 0))
	var cap: float = float(caps.get("crit_chance_cap", 0.35))
	var v: float = 0.03 + LCKv * 0.004
	return clampf(v, 0.0, cap)

static func crit_multi(stats: Dictionary, caps: Dictionary = {}) -> float:
	var LCKv: float = float(stats.get("LCK", 0))
	var cap: float = float(caps.get("crit_multi_cap", 2.5))
	var v: float = 1.5 + LCKv * 0.03
	return clampf(v, 1.0, cap)

static func ctb_speed(stats: Dictionary) -> float:
	var AGIv: float = float(stats.get("AGI", 0))
	var DEXv: float = float(stats.get("DEX", 0))
	return 1.0 + AGIv * 0.10 + DEXv * 0.05

# NEW: simple stamina model (easy to retune later)
static func stam_max(stats: Dictionary, caps: Dictionary = {}) -> int:
	var ENDv: float = float(stats.get("END", 0))
	var AGIv: float = float(stats.get("AGI", 0))
	# baseline favors END, with some AGI; tweak as needed
	return int(round(ENDv * 8.0 + AGIv * 4.0))
