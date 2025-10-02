# Godot 4.4.1
extends RefCounted
class_name PowerAllocator
##
## Takes a MonsterCatalog entry + power_level and produces:
## - final_level
## - per-ability levels (uniform random distribution)
## - final base stats (8) after ability bundles (+10 every 5 levels) and +2 per level (uniform)
##
## Notes:
## - Seedless by design (combat variance). Tests can pass a seeded RNG if needed.

const MonsterSchema := preload("res://persistence/schemas/monster_schema.gd")

# Tunables (promote to JSON later if desired)
const LEVEL_POINTS_PER_LEVEL: int = 2
const BUNDLE_POINTS_PER_5: int = 10
const ABILITY_THRESHOLD: int = 5

static func allocate(monster_entry_raw: Dictionary, power_level: int, rng: RandomNumberGenerator = null) -> Dictionary:
	var rng_local := rng if rng != null else RandomNumberGenerator.new()
	if rng == null:
		rng_local.randomize()

	var pl: int = max(1, power_level)
	var norm: Dictionary = MonsterSchema.normalize(monster_entry_raw)

	# Base fields
	var level_baseline: int = int(norm.get("level_baseline", 1))
	var base_stats_any: Variant = (norm.get("stats", {}) as Dictionary).get("base", {})
	var base_stats: Dictionary = _copy_8(base_stats_any)

	var abilities_any: Variant = norm.get("abilities", [])
	if not (abilities_any is Array) or (abilities_any as Array).is_empty():
		push_error("PowerAllocator: monster has no abilities (invalid data).")
		return {}

	var abilities: Array = (abilities_any as Array)
	var ability_ids: Array[String] = []
	var ability_baselines: Dictionary = {}  # id -> baseline
	var ability_biases: Dictionary = {}     # id -> Dictionary bias
	var ability_levels: Dictionary = {}     # id -> current level
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

	# Split 20/80 (remainder to abilities)
	var levels_from_pl: int = int(floor(pl * 0.20))
	var ability_levels_from_pl: int = pl - levels_from_pl

	# --- Distribute ability levels uniformly at random across abilities ---
	if ability_ids.is_empty():
		push_error("PowerAllocator: no valid ability ids after normalization.")
		return {}

	for i in range(ability_levels_from_pl):
		var pick_idx: int = rng_local.randi_range(0, ability_ids.size() - 1)
		var pick_id: String = ability_ids[pick_idx]
		ability_levels[pick_id] = int(ability_levels.get(pick_id, 1)) + 1

	# --- Compute ability bundle gains (every 5 levels = +10 points via stat_bias) ---
	var bundle_gain: Dictionary = _zero_8()
	for aid in ability_ids:
		var start_lv: int = int(ability_baselines.get(aid, 1))
		var end_lv: int = int(ability_levels.get(aid, start_lv))
		var thresholds: int = int(floor(float(max(0, end_lv - start_lv)) / float(ABILITY_THRESHOLD)))
		if thresholds <= 0:
			continue
		var bias: Dictionary = ability_biases.get(aid, _zero_8())
		var per_threshold: Dictionary = _distribute_points_by_bias(BUNDLE_POINTS_PER_5, bias)
		for _t in range(thresholds):
			_add_into(bundle_gain, per_threshold)

	# --- Level stat points (+2 per level), distributed uniformly at random across the 8 stats ---
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

# ---------------- helpers ----------------

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
		var w: float = max(0.0, float((bias_any as Dictionary).get(k, 0.0)) if bias_any is Dictionary else 0.0)
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
	var alloc_float: Dictionary = {}
	var alloc_int: Dictionary = {}
	var sum_int: int = 0
	var frac_list: Array = [] # Array[Dictionary] of {k, frac}
	for k in keys:
		var share: float = float(points) * (float(bias[k]) / total)
		alloc_float[k] = share
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
	if fa == fb:
		# stable tie-break by key string
		return String(a.get("k","")) < String(b.get("k",""))
	return fa > fb
