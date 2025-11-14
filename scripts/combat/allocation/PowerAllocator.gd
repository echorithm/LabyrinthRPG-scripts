# Godot 4.5
extends RefCounted
class_name PowerAllocator
##
## Allocates monster power given a MonsterCatalog/MonsterSchema entry + power_level.
## Adds player-facing logs (GameLog) and dev-facing prints to help verify stats,
## bundle gains, and per-ability level distribution.

const MonsterSchema := preload("res://persistence/schemas/monster_schema.gd")

# Tunables (promote to JSON later if desired)
const LEVEL_POINTS_PER_LEVEL: int = 2
const BUNDLE_POINTS_PER_5: int = 10
const ABILITY_THRESHOLD: int = 5

# Toggle noisy dev prints (independent of player-facing GameLog)
const DEV_DEBUG_PRINTS: bool = true

# ------------------------------- Public API -----------------------------------

# New: convenience wrapper when you know the absolute floor and role.
# Uses SetPowerLevel.effective_for(floor, role, rng_for_pl) to compute PL, then calls allocate(...).
static func allocate_from_floor(
		monster_entry_raw: Dictionary,
		floor: int,
		role: String,
		rng: RandomNumberGenerator = null,
		rng_for_pl: RandomNumberGenerator = null
	) -> Dictionary:
	var SetPL := preload("res://scripts/dungeon/encounters/SetPowerLevel.gd")
	var pl_eff: int = SetPL.effective_for(max(1, floor), role, rng_for_pl)
	if DEV_DEBUG_PRINTS:
		print_rich("[color=cyan][PA][/color] allocate_from_floor floor=", floor,
			" role='", role, "' → pl_eff=", pl_eff)
	return allocate(monster_entry_raw, pl_eff, rng)

static func allocate(monster_entry_raw: Dictionary, power_level: int, rng: RandomNumberGenerator = null) -> Dictionary:
	var rng_local: RandomNumberGenerator = rng if rng != null else RandomNumberGenerator.new()
	if rng == null:
		rng_local.randomize()

	var pl: int = max(1, power_level)
	var norm: Dictionary = MonsterSchema.normalize(monster_entry_raw)

	# Optional guard: if a deep-floor hint is present but PL is tiny (seed-band),
	# recompute from SetPowerLevel to avoid under-scaling caused by passing a band-local floor.
	var floor_hint: int = _floor_from_entry(monster_entry_raw)
	if pl <= 10 and floor_hint >= 10:
		var role_hint: String = _role_from_entry(monster_entry_raw)
		var SetPL := preload("res://scripts/dungeon/encounters/SetPowerLevel.gd")
		var corrected: int = SetPL.effective_for(floor_hint, role_hint, rng_local)
		if DEV_DEBUG_PRINTS:
			print_rich("[color=yellow][WARN][/color] [PA] Incoming PL=", power_level,
				" looked too low for floor=", floor_hint, " (role='", role_hint,
				"'). Correcting via SetPowerLevel → ", corrected)
		pl = corrected
	elif DEV_DEBUG_PRINTS and pl <= 10:
		print_rich("[color=yellow][WARN][/color] [PA] Very low power_level=", pl,
			". If this encounter is on a deep floor, call allocate_from_floor(...) or compute PL via SetPowerLevel.effective_for(...) first.")

	# Base fields
	var level_baseline: int = 0
	var stats_any: Variant = norm.get("stats", {})
	var base_stats_any: Variant = (stats_any as Dictionary).get("base", {})
	var base_stats: Dictionary = _copy_8(base_stats_any)

	var abilities_any: Variant = norm.get("abilities", [])
	if not (abilities_any is Array) or (abilities_any as Array).is_empty():
		push_error("PowerAllocator: monster has no abilities (invalid data).")
		_game_log_error("power_alloc", "Monster has no abilities", {
			"id": norm.get("id", 0),
			"slug": str(norm.get("slug","")),
			"power_level": pl
		})
		return {}

	var abilities: Array = abilities_any as Array
	var ability_ids: Array[String] = []
	var ability_baselines: Dictionary = {}  # id -> baseline
	var ability_biases: Dictionary = {}     # id -> Dictionary bias
	var ability_levels: Dictionary = {}     # id -> current level
	var ability_weights: Dictionary = {}    # id -> float weight

	for a_any in abilities:
		if not (a_any is Dictionary):
			continue
		var a: Dictionary = a_any as Dictionary
		var aid: String = String(a.get("id", String(a.get("ability_id", ""))))
		if aid == "":
			continue
		ability_ids.append(aid)
		var bl: int = max(1, int(a.get("skill_level_baseline", 1)))
		ability_baselines[aid] = bl
		ability_levels[aid] = bl
		var bias: Dictionary = _copy_8(a.get("stat_bias", {}))
		ability_biases[aid] = bias
		var w: float = max(0.0, float(a.get("weight", 1.0)))
		ability_weights[aid] = w

	# Split 20/80 (remainder to abilities)
	var levels_from_pl: int = int(floor(pl * 0.20))
	var ability_levels_from_pl: int = max(0, pl - levels_from_pl)

	# --- Distribute ability levels (weighted by ability.weight) ---
	if ability_ids.is_empty():
		push_error("PowerAllocator: no valid ability ids after normalization.")
		_game_log_error("power_alloc", "No valid ability ids after normalization", {
			"id": norm.get("id", 0),
			"slug": str(norm.get("slug","")),
			"power_level": pl
		})
		return {}

	var distribution: Dictionary = {}  # aid -> levels_added
	var weight_sum: float = 0.0
	for id_str in ability_ids:
		weight_sum += float(ability_weights.get(id_str, 1.0))

	for i in range(ability_levels_from_pl):
		var pick_id: String = ""
		if weight_sum > 0.0:
			pick_id = _weighted_pick(ability_ids, ability_weights, rng_local)
		else:
			var pick_idx: int = rng_local.randi_range(0, ability_ids.size() - 1)
			pick_id = ability_ids[pick_idx]
		ability_levels[pick_id] = int(ability_levels.get(pick_id, 1)) + 1
		distribution[pick_id] = int(distribution.get(pick_id, 0)) + 1

	# --- Compute ability bundle gains (every 5 levels = +10 points via stat_bias) ---
	var bundle_gain: Dictionary = _zero_8()
	var bundle_steps: Dictionary = {}  # aid -> thresholds hit
	for aid in ability_ids:
		var start_lv: int = int(ability_baselines.get(aid, 1))
		var end_lv: int = int(ability_levels.get(aid, start_lv))
		var thresholds: int = int(floor(float(max(0, end_lv - start_lv)) / float(ABILITY_THRESHOLD)))
		bundle_steps[aid] = thresholds
		if thresholds <= 0:
			continue
		var bias: Dictionary = ability_biases.get(aid, _zero_8())
		var per_threshold: Dictionary = _distribute_points_by_bias(BUNDLE_POINTS_PER_5, bias)
		for _t in range(thresholds):
			_add_into(bundle_gain, per_threshold)

	# --- Level stat points (+2 per level), distributed uniformly across the 8 stats ---
	var level_points: int = levels_from_pl * LEVEL_POINTS_PER_LEVEL
	var level_gain: Dictionary = _zero_8()
	if level_points > 0:
		var keys: PackedStringArray = _stat_keys()
		for _i in range(level_points):
			var idx: int = rng_local.randi_range(0, keys.size() - 1)
			var k: String = keys[idx]
			level_gain[k] = int(level_gain.get(k, 0)) + 1

	# --- Final base stats = base + bundle_gain + level_gain ---
	var final_stats: Dictionary = _copy_8(base_stats)
	_add_into(final_stats, bundle_gain)
	_add_into(final_stats, level_gain)

	# ----------------- Logging (player + dev) -----------------
	var slug_s: String = str(norm.get("slug", ""))
	var display_name_s: String = String(norm.get("display_name", slug_s))

	# Player-facing compact line
	_game_log_info("power_alloc", "Scaled %s (PL %d → L+%d; abilities +%d)" % [
		display_name_s, pl, levels_from_pl, ability_levels_from_pl
	], {
		"monster": display_name_s,
		"slug": slug_s,
		"power_level": pl,
		"levels_to_base": levels_from_pl,
		"points_to_abilities": ability_levels_from_pl,
		"level_gain": level_gain,
		"bundle_gain": bundle_gain
	})

	# Dev-facing breakdown (single print to keep console readable)
	if DEV_DEBUG_PRINTS:
		var dist_str: String = _fmt_kv_counts(distribution)
		var steps_str: String = _fmt_kv_counts(bundle_steps)
		print_rich("[color=cyan][PA][/color] ", display_name_s, " | pl=", pl,
			" | baseline=", level_baseline,
			" | +levels=", levels_from_pl, " (", level_points, " pts)",
			" | final_lv=", max(1, level_baseline + levels_from_pl),
			" | +ability lv=", ability_levels_from_pl,
			" | dist={", dist_str, "}",
			" | bundles={", steps_str, "}\n",
			"    base=", base_stats, "\n",
			"    level_gain=", level_gain, "\n",
			"    bundle_gain=", bundle_gain, "\n",
			"    final=", final_stats
		)

	return {
		"level_baseline": level_baseline,
		"final_level": max(1, level_baseline + levels_from_pl),
		"base_stats": base_stats,                   # pre-allocation
		"final_stats": final_stats,                 # post-allocation (integers)
		"ability_levels": ability_levels,           # { id: level }
		"bundle_gain": bundle_gain,                 # debug
		"level_gain": level_gain,                   # debug
		"abilities": abilities                      # pass-through normalized ability defs
	}

# ------------------------------- Helpers --------------------------------------

static func _stat_keys() -> PackedStringArray:
	return PackedStringArray(["STR","AGI","DEX","END","INT","WIS","CHA","LCK"])

static func _zero_8() -> Dictionary:
	var out: Dictionary = {}
	for k in _stat_keys():
		out[k] = 0
	return out

static func _copy_8(src_any: Variant) -> Dictionary:
	var out: Dictionary = {}
	var keys: PackedStringArray = _stat_keys()
	if src_any is Dictionary:
		var src: Dictionary = src_any as Dictionary
		for k in keys:
			out[k] = int(round(float(src.get(k, 0.0))))
	else:
		for k in keys:
			out[k] = 0
	return out

static func _add_into(dst: Dictionary, add: Dictionary) -> void:
	for k in _stat_keys():
		dst[k] = int(dst.get(k, 0)) + int(add.get(k, 0))

static func _distribute_points_by_bias(points: int, bias_any: Variant) -> Dictionary:
	var keys: PackedStringArray = _stat_keys()
	var bias: Dictionary = {}
	var total: float = 0.0
	for k in keys:
		var w: float = 0.0
		if bias_any is Dictionary:
			w = max(0.0, float((bias_any as Dictionary).get(k, 0.0)))
		bias[k] = w
		total += w

	# If all zeros, fall back to uniform
	if total <= 0.0:
		var uniform: Dictionary = {}
		var base: int = points / keys.size()
		var rem: int = points - base * keys.size()
		for k in keys:
			uniform[k] = base
		# assign remainder in alpha order (stable)
		var i: int = 0
		while rem > 0:
			var kk: String = keys[i % keys.size()]
			uniform[kk] = int(uniform[kk]) + 1
			rem -= 1
			i += 1
		return uniform

	# proportion -> floats -> round and fix remainder by largest fractional
	var alloc_int: Dictionary = {}
	var sum_int: int = 0
	var frac_list: Array[Dictionary] = [] # {k, frac}
	for k in keys:
		var share: float = float(points) * (float(bias[k]) / total)
		var iv: int = int(floor(share))
		alloc_int[k] = iv
		sum_int += iv
		var frac: float = share - float(iv)
		frac_list.append({"k": k, "frac": frac})

	var remp: int = points - sum_int
	frac_list.sort_custom(Callable(PowerAllocator, "_cmp_frac_desc"))
	var idx: int = 0
	while remp > 0 and idx < frac_list.size():
		var item: Dictionary = frac_list[idx]
		var kk: String = String(item["k"])
		alloc_int[kk] = int(alloc_int[kk]) + 1
		remp -= 1
		idx += 1

	# Return ints
	var out: Dictionary = {}
	for k in keys:
		out[k] = int(alloc_int[k])
	return out

static func _cmp_frac_desc(a: Dictionary, b: Dictionary) -> bool:
	var fa: float = float(a.get("frac", 0.0))
	var fb: float = float(b.get("frac", 0.0))
	if is_equal_approx(fa, fb):
		# stable tie-break by key string
		return String(a.get("k","")) < String(b.get("k",""))
	return fa > fb

static func _weighted_pick(ids: Array[String], weights: Dictionary, rng: RandomNumberGenerator) -> String:
	var total: float = 0.0
	for id_str in ids:
		total += float(weights.get(id_str, 1.0))
	if total <= 0.0:
		var i: int = rng.randi_range(0, ids.size() - 1)
		return ids[i]
	var r: float = rng.randf_range(0.0, total)
	var acc: float = 0.0
	for id_str in ids:
		acc += float(weights.get(id_str, 1.0))
		if r <= acc:
			return id_str
	return ids.back()

# ----------------------- Entry hints (optional guard) --------------------------

static func _role_from_entry(entry: Dictionary) -> String:
	var keys := PackedStringArray(["role", "role_hint", "encounter_role"])
	for k in keys:
		if entry.has(k):
			return String(entry[k])
	if entry.has("meta") and entry["meta"] is Dictionary:
		var m: Dictionary = entry["meta"]
		for k in keys:
			if m.has(k):
				return String(m[k])
	return "trash"

static func _floor_from_entry(entry: Dictionary) -> int:
	var keys := PackedStringArray(["floor_abs", "floor", "depth", "encounter_floor", "current_floor"])
	for k in keys:
		if entry.has(k):
			return int(entry[k])
	if entry.has("meta") and entry["meta"] is Dictionary:
		var m: Dictionary = entry["meta"]
		for k in keys:
			if m.has(k):
				return int(m[k])
	return 0

# ------------------------------- Logging --------------------------------------

static func _game_log_node() -> Node:
	var root: Node = Engine.get_main_loop().root
	var n: Node = root.get_node_or_null(^"/root/GameLog")
	return n

static func _game_log_info(cat: String, msg: String, data: Dictionary = {}) -> void:
	var gl: Node = _game_log_node()
	if gl != null:
		gl.call("info", cat, msg, data)

static func _game_log_warn(cat: String, msg: String, data: Dictionary = {}) -> void:
	var gl: Node = _game_log_node()
	if gl != null:
		gl.call("warn", cat, msg, data)

static func _game_log_error(cat: String, msg: String, data: Dictionary = {}) -> void:
	var gl: Node = _game_log_node()
	if gl != null:
		gl.call("error", cat, msg, data)

static func _fmt_kv_counts(m: Dictionary) -> String:
	if m.is_empty():
		return ""
	var parts: Array[String] = []
	for k_any in m.keys():
		var k: String = String(k_any)
		var v: int = int(m[k])
		parts.append("%s:+%d" % [k, v])
	parts.sort()
	return ",".join(parts)
