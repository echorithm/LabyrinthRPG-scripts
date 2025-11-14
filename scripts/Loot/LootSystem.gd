#res://scripts/Loot/LootSystem.gd
extends Node
##
## LootSystem — v3.1
## - Monster-level unlocks only (no floor fallback)
## - Level-diff bias (rarity + amount clamp)
## - Unified chest source
## - Currency amounts scale with POWER LEVEL (+ moderate RARITY multiplier)
##
## Determinism:
##  - RNG seeded only from ctx["rng_seed"] (else randomized).
##  - Given same (source, floor, target_level, player_level, rng_seed) → identical results.

# ---------- Types / constants ----------
enum Rarity { C, U, R, E, A, L, M }

const RARITY_ORDER: Array[String] = ["C","U","R","E","A","L","M"]
const SOURCES: Array[String] = ["trash","elite","boss","chest"]
const JSON_PATH: String = "res://persistence/schemas/loot_source.json"

# Loaded JSON blobs (typed)
var _rules: Dictionary = {}
var _curves: Dictionary = {}
var _norm: Dictionary = {}
var _post_boss: Dictionary = {}
var _shards: Dictionary = {}
var _gold: Dictionary = {}
var _items: Dictionary = {}
var _sel_rules: Dictionary = {}
var _unlock_level: Dictionary = {}   # unlocks by MONSTER LEVEL (authoritative)

# External systems
const SetPL := preload("res://scripts/dungeon/encounters/SetPowerLevel.gd")
const XpTuning := preload("res://scripts/rewards/XpTuning.gd")

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
	_norm = (d.get("normalization", {}) as Dictionary)     # currently informational only
	_post_boss = (d.get("post_boss_shift", {}) as Dictionary)
	_shards = (d.get("shards", {}) as Dictionary)
	_gold = (d.get("gold", {}) as Dictionary)
	_items = (d.get("items", {}) as Dictionary)
	_sel_rules = (d.get("selection_rules", {}) as Dictionary)
	_unlock_level = (d.get("rarity_unlock_level", {}) as Dictionary)

# ctx: {
#   rng_seed:int,
#   player_level:int,            # for level-diff scaling
#   target_level:int,            # MONSTER level (boss/elite/trash) | chest virtual level
#   post_boss_encounters_left:int,
#   boss_charge_factor:float (0..1, optional)
# }
func roll_loot(source: String, floor_i: int, ctx: Dictionary = {}) -> Dictionary:
	# Normalize / map legacy chest sources
	var src: String = _map_source(source)
	var f: int = max(1, floor_i)

	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	if ctx.has("rng_seed"):
		rng.seed = int(ctx["rng_seed"])
	else:
		rng.randomize()

	# Resolve target (monster) level and player level for level-diff scaling
	var player_level: int = int(ctx.get("player_level", 0))
	var target_level: int = int(ctx.get("target_level", 0))

	# For CHESTS, synthesize a virtual monster level from SetPowerLevel band
	if src == "chest":
		var band: Vector2i = SetPL.band_for_floor(f)
		target_level = rng.randi_range(band.x, band.y)

	# If callers didn’t pass a monster level (non-chest), fall back to floor
	if target_level <= 0:
		target_level = f

	# Extract boss charge factor (optional)
	var charge_factor: float = -1.0
	if src == "boss" and ctx.has("boss_charge_factor"):
		match typeof(ctx["boss_charge_factor"]):
			TYPE_FLOAT:
				charge_factor = float(ctx["boss_charge_factor"])
			TYPE_INT:
				charge_factor = float(int(ctx["boss_charge_factor"]))
		charge_factor = clampf(charge_factor, 0.0, 1.0)

	# 1) Shards check — standard per-source chance; Boss path scales by charge factor (if provided)
	var shard_first: bool
	if src == "boss" and charge_factor >= 0.0:
		shard_first = _roll_shards_scaled(src, f, charge_factor, rng)
	else:
		shard_first = _roll_shards(src, f, rng)

	# 2) Build rarity weights (curves → unlocks by MONSTER LEVEL → post-boss tweak → level-diff + boss biases → normalize)
	var shift_left: int = int(ctx.get("post_boss_encounters_left", 0))
	var weights: PackedFloat32Array = weights_for(src, f, shift_left, target_level)

	# Apply boss upward bias (existing behavior) if charge factor present
	if src == "boss" and charge_factor >= 0.0:
		weights = _apply_boss_charge_bias(weights, charge_factor)

	# Apply level-diff scaling (player vs monster) to rarity distribution
	if player_level > 0:
		weights = _apply_level_diff_bias(weights, player_level, target_level)

	var rarity_index: int = _weighted_pick_index(weights, rng)
	var rarity_str: String = RARITY_ORDER[rarity_index]

	# 3) Category (only if not shards)
	var category: String = ""
	if not shard_first:
		category = _pick_category_for_rarity(rarity_str, src, rng)

	# 4) Amounts (gold/shards) — scale with POWER LEVEL (+ rarity for gold), then apply level-diff clamp
	var gold_flat: int = _gold_amount_for(src, target_level, rarity_str)
	var shard_flat: int = 0
	if shard_first:
		shard_flat = _shards_amount_for(src, target_level)

	# Level-diff amount scaling (0.6..1.4 clamp)
	if player_level > 0:
		var dr: float = XpTuning.level_diff_factor(player_level, target_level)
		var amt_scale: float = clampf(dr, 0.6, 1.4)
		gold_flat = int(round(float(gold_flat) * amt_scale))
		if shard_flat > 0:
			shard_flat = int(round(float(shard_flat) * amt_scale))

	return {
		"source": src,
		"floor": f,
		"rarity": rarity_str,
		"category": category,
		"gold": gold_flat,
		"shards": shard_flat,
		"post_boss_shift_applied": shift_left > 0,
		"pity_used": false,  # unified model has no pity
		"chest_level": "chest" if src == "chest" else ""
	}

# ---------- Weights ----------
# NEW signature: includes monster_level for unlocks
func weights_for(source: String, floor_i: int, post_boss_encounters_left: int, monster_level: int) -> PackedFloat32Array:
	var f: int = max(1, floor_i)
	var band: int = int((f - 1) / 3)

	var arr: PackedFloat32Array = PackedFloat32Array()
	arr.resize(7)
	for i in 7:
		arr[i] = 0.0

	var sc: Dictionary = (_curves.get(source, {}) as Dictionary)
	if sc.is_empty():
		push_error("LootSystem: unknown source %s" % source)

	# inherit_from path
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

	# Unlocks — by MONSTER LEVEL only (authoritative)
	arr = _apply_level_unlocks(arr, monster_level)

	# Post-boss temporary shift (legacy simple deltas honored if provided)
	if post_boss_encounters_left > 0:
		arr[Rarity.C] = maxf(0.0, arr[Rarity.C] - 10.0)
		arr[Rarity.U] += 6.0
		arr[Rarity.R] += 3.0
		arr[Rarity.E] += 1.0

	# Normalize to 100
	var total: float = 0.0
	for v in arr:
		total += v
	if total <= 0.0:
		arr = PackedFloat32Array([0.0, 100.0, 0.0, 0.0, 0.0, 0.0, 0.0])
	else:
		for i in arr.size():
			arr[i] = 100.0 * arr[i] / total

	return arr

func _apply_level_unlocks(arr: PackedFloat32Array, monster_level: int) -> PackedFloat32Array:
	if _unlock_level.is_empty():
		return arr
	var lvl: int = max(1, monster_level)
	# Zero tiers whose unlock level is above monster level
	if lvl < int(_unlock_level.get("U", 11)): arr[Rarity.U] = 0.0
	if lvl < int(_unlock_level.get("R", 21)): arr[Rarity.R] = 0.0
	if lvl < int(_unlock_level.get("E", 31)): arr[Rarity.E] = 0.0
	if lvl < int(_unlock_level.get("A", 41)): arr[Rarity.A] = 0.0
	if lvl < int(_unlock_level.get("L", 51)): arr[Rarity.L] = 0.0
	if lvl < int(_unlock_level.get("M", 61)): arr[Rarity.M] = 0.0
	return arr

# ---------- Biases ----------

func _apply_boss_charge_bias(weights: PackedFloat32Array, factor: float) -> PackedFloat32Array:
	# Per-tier bias: negative on C/U, positive and increasing on R→M (existing shape)
	var out := weights.duplicate()
	var bias := PackedFloat32Array([-0.8, -0.5, 0.2, 0.4, 0.6, 0.8, 1.0])
	var sumw: float = 0.0
	for i in out.size():
		var w: float = out[i] * max(0.0, 1.0 + bias[i] * factor)
		out[i] = w
		sumw += w
	if sumw <= 0.0:
		return PackedFloat32Array([0.0, 100.0, 0.0, 0.0, 0.0, 0.0, 0.0])
	for i in out.size():
		out[i] = 100.0 * out[i] / sumw
	return out

func _apply_level_diff_bias(weights: PackedFloat32Array, player_level: int, monster_level: int) -> PackedFloat32Array:
	var dr: float = XpTuning.level_diff_factor(player_level, monster_level) # >1 underleveled, <1 overleveled
	if is_equal_approx(dr, 1.0):
		return weights
	var out := weights.duplicate()
	var bias := PackedFloat32Array([-0.8, -0.5, 0.2, 0.4, 0.6, 0.8, 1.0])
	var k: float = (dr - 1.0) # -ve when overleveled, +ve when underleveled
	var sumw: float = 0.0
	for i in out.size():
		var mult: float = max(0.0, 1.0 + bias[i] * k)
		var w2: float = out[i] * mult
		out[i] = w2
		sumw += w2
	if sumw <= 0.0:
		return PackedFloat32Array([0.0, 100.0, 0.0, 0.0, 0.0, 0.0, 0.0])
	for i in out.size():
		out[i] = 100.0 * out[i] / sumw
	return out

# ---------- Currency amounts (PL-based) ----------
# GOLD: linear in POWER LEVEL; moderate rarity multiplier (reuse XpTuning rarity mults used for XP)
func _gold_amount_for(source: String, target_level: int, rarity_code: String) -> int:
	var base_tbl: Dictionary = (_gold.get("flat_amount_base", {}) as Dictionary)
	var base_per_level: int = int(base_tbl.get(source, 0))
	if base_per_level <= 0:
		return 0
	var pl: int = max(1, target_level)
	var rar_mult: float = XpTuning._rarity_mult(rarity_code)  # C=1.0 … M≈2.6
	var raw: float = float(base_per_level) * float(pl) * rar_mult
	return int(round(raw))

# SHARDS: scale gently with POWER LEVEL (per-10 levels), no rarity multiplier (shards are a separate economy)
func _shards_amount_for(source: String, target_level: int) -> int:
	var base_tbl: Dictionary = (_shards.get("flat_amount_base", {}) as Dictionary)
	var base: int = int(base_tbl.get(source, 0))
	if base <= 0:
		return 0
	var pl: int = max(1, target_level)
	var steps: int = max(1, int(ceil(float(pl) / 10.0))) # 1 at PL1..10, 2 at PL11..20, etc.
	var raw: int = base * steps
	return max(1, raw)

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

# ---------- Shards / Gold (chance models preserved) ----------
func _roll_shards(source: String, f: int, rng: RandomNumberGenerator) -> bool:
	var allowed_by_source: Dictionary = (_shards.get("allowed_by_source", {}) as Dictionary)
	var allowed: bool = bool(allowed_by_source.get(source, false))
	if not allowed:
		return false
	var chance_map: Dictionary = (_shards.get("chance_by_source", {}) as Dictionary)
	var row: Dictionary = (chance_map.get(source, {}) as Dictionary)
	var base_p: float = float(row.get("base_percent", 0.0))
	var per_floor: float = float(row.get("per_floor_percent", 0.0))
	var cap_p: float = float(row.get("cap_percent", 100.0))
	var p: float = minf(cap_p, base_p + per_floor * float(max(1, f)))
	return rng.randf() * 100.0 < p

func _roll_shards_scaled(source: String, f: int, factor: float, rng: RandomNumberGenerator) -> bool:
	var allowed_by_source: Dictionary = (_shards.get("allowed_by_source", {}) as Dictionary)
	var allowed: bool = bool(allowed_by_source.get(source, false))
	if not allowed:
		return false
	var chance_map: Dictionary = (_shards.get("chance_by_source", {}) as Dictionary)
	var row: Dictionary = (chance_map.get(source, {}) as Dictionary)
	var base_p: float = float(row.get("base_percent", 0.0))
	var per_floor: float = float(row.get("per_floor_percent", 0.0))
	var cap_p: float = float(row.get("cap_percent", 100.0))
	var full_p: float = minf(cap_p, base_p + per_floor * float(max(1, f)))
	var eff_p: float = max(0.0, full_p * clampf(factor, 0.0, 1.0))
	return rng.randf() * 100.0 < eff_p

# ---------- Curves ----------
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
		var v: float = float(max(0, f - start_f + 1)) * rate
		return max(0.0, v)
	return 0.0

# ---------- Utils ----------
static func _map_source(s: String) -> String:
	var sl: String = s.strip_edges().to_lower()
	match sl:
		"common_chest", "rare_chest": return "chest"
		_: return sl
