extends Node


## Toggle at runtime via: CombatTrace.level = 2
## Levels: 0=off, 1=key events, 2=verbose scalars & lanes, 3=very verbose
static var level: int = 2

static func hdr(s: String) -> void:
	if level >= 1:
		print_rich("[color=cyan][CTB][/color] ", s)

static func rng(channel: StringName, p: float, outcome: bool, roll: float) -> void:
	if level >= 2:
		var outcome_str: String = "hit" if outcome else "miss"
		print_rich(
			"[color=teal][RNG][/color] ", str(channel),
			" p=", "%.3f" % p,
			" roll=", "%.3f" % roll,
			" → ", outcome_str
		)

static func atk_scalar(base_power: int, s_school: float, s_level: float, s_bias: float, pre_lanes: float) -> void:
	if level >= 2:
		print(
			"[ATK] base=", base_power,
			" × S_school=", "%.2f" % s_school,
			" × S_level=", "%.2f" % s_level,
			" × S_bias=", "%.2f" % s_bias,
			" => pre-lanes=", "%.1f" % pre_lanes
		)

static func crit_note(multiplier: float) -> void:
	if level >= 1:
		print("[CRIT] multiplier=", "%.2f" % multiplier)

static func defense(kind: StringName, target_id: int, lane: int, amount: int, info: Dictionary) -> void:
	if level >= 1:
		if kind == &"shield_absorb":
			var left_val: int = int(info.get("left", 0))
			print("[DEF] shield_absorb t=", target_id, " lane=", lane, " absorbed=", amount, " left=", left_val)
		elif kind == &"block":
			var tier_val: int = int(info.get("tier", 1))
			print("[DEF] block t=", target_id, " lane=", lane, " reduced=", amount, " tier=", tier_val)

static func lanes_compact(label: String, lanes: Dictionary) -> void:
	if level >= 2:
		print("[LANES] ", label, " ", _lanes_to_str(lanes))

static func turn_summary(actor_id: int, ability_id: int, ctb_cost: int, total_events: int, hp_delta: int) -> void:
	if level >= 1:
		print_rich(
			"[color=lime][SUMMARY][/color] actor=", actor_id,
			" ability=", ability_id,
			" CTB=", ctb_cost,
			" events=", total_events,
			" hpΔ=", hp_delta
		)

static func status_evt(kind: StringName, who: int, id: StringName, stacks: int, dur: int) -> void:
	if level >= 1:
		print("[STATUS] ", str(kind), " target=", who, " id=", str(id), " stacks=", stacks, " dur=", dur)

static func death(target_id: int, killer_id: int) -> void:
	if level >= 1:
		print_rich("[color=orangered][DEATH][/color] target=", target_id, " killer=", killer_id)

static func seed(seed_val: int) -> void:
	if level >= 1:
		print("[RNG] seed=", seed_val)

static func _lanes_to_str(lanes: Dictionary) -> String:
	# Expect keys like P0..P4, E0..E4; sort for stable output.
	var keys_any: Array = lanes.keys()
	var keys: Array[String] = []
	keys.resize(keys_any.size())
	var i: int = 0
	for k in keys_any:
		keys[i] = str(k)
		i += 1
	keys.sort()

	var parts: Array[String] = []
	for key in keys:
		var v: int = int(lanes.get(key, 0))
		parts.append(str(key, ":", v))
	return "{ " + ", ".join(parts) + " }"
