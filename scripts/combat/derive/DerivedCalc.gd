# Godot 4.5
extends RefCounted
class_name DerivedCalc
##
## Pure functions to compute derived combat stats from the 8 bases.
## Extras:
##  - recompute_all(): convenience that returns all deriveds and can optionally log a compact line to GameLog.
##  - explain(): dev helper that shows component contributions for p_atk/m_atk/defense/resistance.

# Toggle noisy console prints (independent of GameLog)
const DEV_DEBUG_PRINTS: bool = false

# ---------------------------- Pure derived funcs ------------------------------

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
	var c: Dictionary = _caps_norm(caps)
	var cap: float = float(c.get("crit_chance_cap", 0.35))
	var v: float = 0.03 + LCKv * 0.004
	return clampf(v, 0.0, cap)

static func crit_multi(stats: Dictionary, caps: Dictionary = {}) -> float:
	var LCKv: float = float(stats.get("LCK", 0))
	var c: Dictionary = _caps_norm(caps)
	var cap: float = float(c.get("crit_multi_cap", 2.5))
	var v: float = 1.5 + LCKv * 0.03
	return clampf(v, 1.0, cap)

static func ctb_speed(stats: Dictionary) -> float:
	var AGIv: float = float(stats.get("AGI", 0))
	var DEXv: float = float(stats.get("DEX", 0))
	# Note: no cap here by design; CTB clamps at the gauge/turn system.
	return 1.0 + AGIv * 0.10 + DEXv * 0.05

# Simple stamina model (easy to retune later)
static func stam_max(stats: Dictionary, caps: Dictionary = {}) -> int:
	var ENDv: float = float(stats.get("END", 0))
	var AGIv: float = float(stats.get("AGI", 0))
	return int(round(ENDv * 8.0 + AGIv * 4.0))

# -------------------------- Convenience + Logging -----------------------------

## Returns a Dictionary of all derived values computed once.
## If log_category != "", writes a compact, player-facing line to GameLog.
## Example:
##   var d := DerivedCalc.recompute_all(attrs, {}, "derive", "Forest Wisp")
##   # d = { hp_max, mp_max, p_atk, m_atk, defense, resistance, crit_chance, crit_multi, ctb_speed, stam_max }
static func recompute_all(stats: Dictionary, caps: Dictionary = {}, log_category: String = "", label: String = "") -> Dictionary:
	var c: Dictionary = _caps_norm(caps)

	var hpM: int = hp_max(stats, c)
	var mpM: int = mp_max(stats, c)
	var patk: float = p_atk(stats)
	var matk: float = m_atk(stats)
	var defn: float = defense(stats)
	var resn: float = resistance(stats)
	var cch: float = crit_chance(stats, c)
	var cmu: float = crit_multi(stats, c)
	var ctb: float = ctb_speed(stats)
	var stmM: int = stam_max(stats, c)

	var out: Dictionary = {
		"hp_max": hpM,
		"mp_max": mpM,
		"p_atk": patk,
		"m_atk": matk,
		"defense": defn,
		"resistance": resn,
		"crit_chance": cch,
		"crit_multi": cmu,
		"ctb_speed": ctb,
		"stam_max": stmM
	}

	if log_category != "":
		var msg: String = "Derived for %s  HP:%d  MP:%d  PATK:%.1f  MATK:%.1f  DEF:%.1f  RES:%.1f  Crit:%.0f%% ×%.2f  CTB:%.2f  ST:%d" % [
			(label if label != "" else "actor"),
			hpM, mpM, patk, matk, defn, resn, cch * 100.0, cmu, ctb, stmM
		]
		_game_log_info(log_category, msg, {
			"who": (label if label != "" else "actor"),
			"stats_in": stats.duplicate(true),
			"derived": out.duplicate(true)
		})

	if DEV_DEBUG_PRINTS:
		print_rich("[color=mediumpurple][Derived][/color] ",
			(label if label != "" else "actor"), " → ",
			"HP:", hpM, " MP:", mpM,
			" PATK:", _fmt1(patk), " MATK:", _fmt1(matk),
			" DEF:", _fmt1(defn), " RES:", _fmt1(resn),
			" Crit:", _fmt1(cch * 100.0), "% ×", _fmt2(cmu),
			" CTB:", _fmt2(ctb),
			" ST:", stmM
		)

	return out

## Returns a structured breakdown of how each composite stat was formed.
## Keys:
##   "p_atk","m_atk","defense","resistance"
static func explain(stats: Dictionary) -> Dictionary:
	var STRv: float = float(stats.get("STR", 0))
	var DEXv: float = float(stats.get("DEX", 0))
	var AGIv: float = float(stats.get("AGI", 0))
	var INTv: float = float(stats.get("INT", 0))
	var WISv: float = float(stats.get("WIS", 0))
	var ENDv: float = float(stats.get("END", 0))

	var p1: float = STRv * 2.0
	var p2: float = DEXv * 1.0
	var p3: float = AGIv * 0.5
	var p_sum: float = p1 + p2 + p3

	var m1: float = INTv * 2.0
	var m2: float = WISv * 1.0
	var m3: float = DEXv * 0.5
	var m_sum: float = m1 + m2 + m3

	var d1: float = ENDv * 1.8
	var d2: float = DEXv * 0.7
	var d_sum: float = d1 + d2

	var r1: float = WISv * 1.6
	var r2: float = ENDv * 0.6
	var r_sum: float = r1 + r2

	var out: Dictionary = {
		"p_atk": {"STR*2.0": p1, "DEX*1.0": p2, "AGI*0.5": p3, "total": p_sum},
		"m_atk": {"INT*2.0": m1, "WIS*1.0": m2, "DEX*0.5": m3, "total": m_sum},
		"defense": {"END*1.8": d1, "DEX*0.7": d2, "total": d_sum},
		"resistance": {"WIS*1.6": r1, "END*0.6": r2, "total": r_sum}
	}

	if DEV_DEBUG_PRINTS:
		print_rich("[color=mediumpurple][Derived:Explain][/color] ",
			"PATK(", _fmt1(p1), "+", _fmt1(p2), "+", _fmt1(p3), ")=", _fmt1(p_sum),
			"  MATK(", _fmt1(m1), "+", _fmt1(m2), "+", _fmt1(m3), ")=", _fmt1(m_sum),
			"  DEF(", _fmt1(d1), "+", _fmt1(d2), ")=", _fmt1(d_sum),
			"  RES(", _fmt1(r1), "+", _fmt1(r2), ")=", _fmt1(r_sum)
		)

	return out

# ------------------------------- Utils ----------------------------------------

static func _fmt1(v: float) -> String: return String.num(v, 1)
static func _fmt2(v: float) -> String: return String.num(v, 2)

static func _caps_norm(caps_any: Dictionary) -> Dictionary:
	# Ensure both caps exist with sane defaults, and clamp to non-degenerate ranges.
	var c: Dictionary = caps_any.duplicate(true)
	if not c.has("crit_chance_cap"):
		c["crit_chance_cap"] = 0.35
	else:
		c["crit_chance_cap"] = clampf(float(c["crit_chance_cap"]), 0.0, 0.95)
	if not c.has("crit_multi_cap"):
		c["crit_multi_cap"] = 2.5
	else:
		c["crit_multi_cap"] = max(1.0, float(c["crit_multi_cap"]))
	return c

# ------------------------------ GameLog glue ----------------------------------

static func _game_log_node() -> Node:
	var root: Node = Engine.get_main_loop().root
	var n: Node = root.get_node_or_null(^"/root/GameLog")
	return n

static func _game_log_info(cat: String, msg: String, data: Dictionary = {}) -> void:
	var gl: Node = _game_log_node()
	if gl != null:
		gl.call("info", cat, msg, data)
