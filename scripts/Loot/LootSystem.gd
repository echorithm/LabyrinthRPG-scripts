extends Node


# ---------- Types / constants ----------
enum Rarity { C, U, R, E, A, L, M }

# NOTE: const arrays must be literal arrays (no constructors).
const RARITY_ORDER: Array[String] = ["C","U","R","E","A","L","M"]
const SOURCES: Array[String] = ["trash","elite","boss","common_chest","rare_chest"]
const JSON_PATH: String = "res://persistence/schemas/loot_source.json"

# Loaded JSON blobs (typed)
var _rules: Dictionary = {}
var _curves: Dictionary = {}
var _norm: Dictionary = {}
var _post_boss: Dictionary = {}
var _pity_rules: Dictionary = {}
var _shards: Dictionary = {}
var _gold: Dictionary = {}
var _items: Dictionary = {}
var _sel_rules: Dictionary = {}
var _unlock_floor: Dictionary = {}

func _ready() -> void:
	load_rules(JSON_PATH)

func load_rules(path: String) -> void:
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("LootSystem: cannot open %s" % path)
		return
	var txt: String = f.get_as_text()
	f.close()
	var parsed: Variant = JSON.parse_string(txt)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("LootSystem: invalid JSON at %s" % path)
		return
	var d: Dictionary = parsed as Dictionary
	_rules = d
	_curves = (d.get("rarity_curves", {}) as Dictionary)
	_norm = (d.get("normalization", {}) as Dictionary)
	_post_boss = (d.get("post_boss_shift", {}) as Dictionary)
	_pity_rules = (d.get("pity_rules", {}) as Dictionary)
	_shards = (d.get("shards", {}) as Dictionary)
	_gold = (d.get("gold", {}) as Dictionary)
	_items = (d.get("items", {}) as Dictionary)
	_sel_rules = (d.get("selection_rules", {}) as Dictionary)
	_unlock_floor = (d.get("rarity_unlock_floor", {}) as Dictionary)

# ctx: { post_boss_encounters_left:int, rare_chest_pity:int, rng_seed:int, chest_level:String }
func roll_loot(source: String, floor_i: int, ctx: Dictionary = {}) -> Dictionary:
	var f: int = max(1, floor_i)

	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	if ctx.has("rng_seed"):
		rng.seed = int(ctx["rng_seed"])  # seed is int in Godot 4
	else:
		rng.randomize()

	# 1) Shards check first
	var shard_first: bool = _roll_shards(source, f, rng)

	# 2) Rarity
	var shift_left: int = int(ctx.get("post_boss_encounters_left", 0))
	var weights: PackedFloat32Array = weights_for(source, f, shift_left)
	var rarity_index: int = _weighted_pick_index(weights, rng)
	var rarity_str: String = RARITY_ORDER[rarity_index]

	# 3) Pity (rare chest)
	var pity_used: bool = false
	if source == "rare_chest":
		var pity: int = int(ctx.get("rare_chest_pity", 0))
		var upgraded: int = _apply_pity_if_needed(pity, rarity_index)
		if upgraded != rarity_index:
			rarity_index = upgraded
			rarity_str = RARITY_ORDER[rarity_index]
			pity_used = true

	# 4) Category (only if not shards)
	var category: String = ""
	if !shard_first:
		category = _pick_category_for_rarity(rarity_str, source, rng)

	# 5) Flat amounts (gold/shards)
	var gold_flat: int = _flat_gold_for(source, f)
	var shard_flat: int = 0
	if shard_first:
		shard_flat = _flat_shards_for(source, f)

	return {
		"source": source,
		"floor": f,
		"rarity": rarity_str,
		"category": category,
		"gold": gold_flat,
		"shards": shard_flat,
		"post_boss_shift_applied": shift_left > 0,
		"pity_used": pity_used,
		"chest_level": String(ctx.get("chest_level",""))
	}

# ---------- Weights ----------
func weights_for(source: String, floor_i: int, post_boss_encounters_left: int) -> PackedFloat32Array:
	var f: int = max(1, floor_i)
	var band: int = int((f - 1) / 3)

	var arr: PackedFloat32Array = PackedFloat32Array()
	arr.resize(7)
	for i in 7:
		arr[i] = 0.0

	var sc: Dictionary = (_curves.get(source, {}) as Dictionary)
	if sc.is_empty():
		push_error("LootSystem: unknown source %s" % source)

	# inherit_from path (e.g., common_chest from trash)
	var base_from: String = source
	var multipliers: Dictionary = {}
	if sc.has("inherit_from"):
		base_from = String(sc["inherit_from"])
		multipliers = (sc.get("multipliers", {}) as Dictionary)

	var base_curve: Dictionary = (_curves.get(base_from, {}) as Dictionary)
	for i in RARITY_ORDER.size():
		var key: String = RARITY_ORDER[i]
		var weight: float = _eval_curve(base_curve.get(key, {}), f, band)
		if multipliers.has(key):
			weight *= float(multipliers[key])
		if weight < 0.0:
			weight = 0.0
		arr[i] = weight

	# rare chest is guaranteed U+
	if source == "rare_chest":
		arr[Rarity.C] = 0.0

	# unlock gates
	arr = _apply_unlocks(arr, f)

	# post-boss temporary shift
	if post_boss_encounters_left > 0:
		arr[Rarity.C] = maxf(0.0, arr[Rarity.C] - 10.0)
		arr[Rarity.U] += 6.0
		arr[Rarity.R] += 3.0
		arr[Rarity.E] += 1.0

	# normalize to 100
	var total: float = 0.0
	for v in arr:
		total += v
	if total <= 0.0:
		arr = PackedFloat32Array([0.0, 100.0, 0.0, 0.0, 0.0, 0.0, 0.0])
	else:
		for i in arr.size():
			arr[i] = 100.0 * arr[i] / total

	return arr

func _apply_unlocks(arr: PackedFloat32Array, floor_i: int) -> PackedFloat32Array:
	var f: int = max(1, floor_i)
	if f < int(_unlock_floor.get("R", 10)):
		arr[Rarity.R] = 0.0
	if f < int(_unlock_floor.get("E", 19)):
		arr[Rarity.E] = 0.0
	if f < int(_unlock_floor.get("A", 28)):
		arr[Rarity.A] = 0.0
	if f < int(_unlock_floor.get("L", 37)):
		arr[Rarity.L] = 0.0
	if f < int(_unlock_floor.get("M", 55)):
		arr[Rarity.M] = 0.0
	return arr

func _eval_curve(desc: Variant, f: int, band: int) -> float:
	if typeof(desc) != TYPE_DICTIONARY:
		if typeof(desc) == TYPE_FLOAT or typeof(desc) == TYPE_INT:
			return float(desc)
		return 0.0
	var d: Dictionary = desc as Dictionary
	var typ: String = String(d.get("type",""))
	if typ == "fixed":
		return float(d.get("value", 0.0))
	elif typ == "linear_by_band":
		var intercept: float = float(d.get("intercept", 0.0))
		var slope: float = float(d.get("slope_per_band", 0.0))
		var val: float = intercept + slope * float(band)
		var mn: float = float(d.get("min", -1.0e30))
		var mx: float = float(d.get("max", 1.0e30))
		return clampf(val, mn, mx)
	elif typ == "ramp_after_floor":
		var start_f: int = int(d.get("start_floor", 1))
		var rate: float = float(d.get("rate_per_floor", 0.0))
		var v: float = float(f - start_f + 1) * rate
		if v < 0.0:
			v = 0.0
		return v
	return 0.0

# ---------- Picks / RNG helpers ----------
func _weighted_pick_index(weights: PackedFloat32Array, rng: RandomNumberGenerator) -> int:
	var total: float = 0.0
	for v in weights:
		total += v
	if total <= 0.0:
		return Rarity.U
	var roll: float = rng.randf() * total
	for i in weights.size():
		roll -= weights[i]
		if roll <= 0.0:
			return i
	return weights.size() - 1

func _pick_category_for_rarity(rarity: String, source: String, rng: RandomNumberGenerator) -> String:
	var items_dict: Dictionary = _items
	var by_source: Dictionary = (items_dict.get("category_weights_by_source", {}) as Dictionary)
	var row: Dictionary = {}
	if by_source.has(source):
		var src_tbl: Dictionary = by_source[source] as Dictionary
		if src_tbl.has(rarity):
			row = (src_tbl[rarity] as Dictionary)
	if row.is_empty():
		var by_r: Dictionary = (items_dict.get("category_weights_by_rarity", {}) as Dictionary)
		row = (by_r.get(rarity, {}) as Dictionary)
	if row.is_empty():
		return ""
	var keys: Array = row.keys()
	var ws := PackedFloat32Array()
	ws.resize(keys.size())
	var total := 0.0
	for i in keys.size():
		var w := float(row.get(keys[i], 0.0))
		ws[i] = w
		total += w
	if total <= 0.0:
		return ""
	var idx := _weighted_pick_index(ws, rng)
	return String(keys[idx])


# ---------- Shards / Gold ----------
func _roll_shards(source: String, f: int, rng: RandomNumberGenerator) -> bool:
	var allowed_by_source: Dictionary = (_shards.get("allowed_by_source", {}) as Dictionary)
	var allowed: bool = bool(allowed_by_source.get(source, false))
	if !allowed:
		return false
	var chance_map: Dictionary = (_shards.get("chance_by_source", {}) as Dictionary)
	var row: Dictionary = (chance_map.get(source, {}) as Dictionary)
	var base_p: float = float(row.get("base_percent", 0.0))
	var per_floor: float = float(row.get("per_floor_percent", 0.0))
	var cap_p: float = float(row.get("cap_percent", 100.0))
	var p: float = minf(cap_p, base_p + per_floor * float(f))
	return rng.randf() * 100.0 < p

func _flat_shards_for(source: String, f: int) -> int:
	var base: Dictionary = (_shards.get("flat_amount_base", {}) as Dictionary)
	var per: float = float(_shards.get("flat_amount_per_band_growth", 0.0))
	var band: int = int((max(1, f) - 1) / 3)
	var b: int = int(base.get(source, 0))
	var amt: float = float(b) * (1.0 + per * float(band))
	return int(round(amt))

func _flat_gold_for(source: String, f: int) -> int:
	var base: Dictionary = (_gold.get("flat_amount_base", {}) as Dictionary)
	var per: float = float(_gold.get("per_band_growth", 0.0))
	var band: int = int((max(1, f) - 1) / 3)
	var b: int = int(base.get(source, 0))
	var amt: float = float(b) * (1.0 + per * float(band))
	return int(round(amt))

# ---------- Pity ----------
func _apply_pity_if_needed(current_pity: int, rarity_index: int) -> int:
	var rc: Dictionary = (_pity_rules.get("rare_chest", {}) as Dictionary)
	if rc.is_empty():
		return rarity_index
	var threshold: int = int(rc.get("threshold", 2))
	var upgrade: int = int(rc.get("upgrade_tiers", 1))
	var reset_on_at_least: String = String(rc.get("reset_on_at_least", "R"))
	var reset_i: int = RARITY_ORDER.find(reset_on_at_least)
	if reset_i == -1:
		reset_i = Rarity.R
	if rarity_index < reset_i and current_pity >= threshold:
		return clampi(rarity_index + upgrade, 0, RARITY_ORDER.size() - 1)
	return rarity_index
