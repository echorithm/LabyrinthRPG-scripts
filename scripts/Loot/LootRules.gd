# Godot 4.4.1
extends RefCounted
class_name LootRules

var _cfg: Dictionary = {}
var _loaded: bool = false
var _path: String = "user://LootSource.cache.json" # optional cache
var _res_path: String = "res://LootSource.json"

static func instance() -> LootRules:
	var lr := LootRules.new()
	lr._ensure_loaded()
	return lr

func _ensure_loaded() -> void:
	if _loaded:
		return
	var d: Dictionary = _load_json(_path)
	if d.is_empty():
		d = _load_json(_res_path)
	if d.is_empty():
		push_error("[LootRules] Could not load LootSource JSON")
		_cfg = {}
	else:
		_cfg = d
	_loaded = true

# -----------------------
# Public API
# -----------------------
func rarity_weights_for(source: String, floor: int) -> Dictionary:
	_ensure_loaded()
	if _cfg.is_empty():
		return {}
	var rar_order: Array = _ord()
	var curves_all: Dictionary = _cfg.get("rarity_curves", {}) as Dictionary
	var floor_band_size: int = int(_cfg.get("floor_band_size", 3))
	var band: int = floor_to_band(floor, floor_band_size)

	var by_src_any: Variant = curves_all.get(source, null)
	if by_src_any == null:
		by_src_any = curves_all.get("trash", {})
	var by_src: Dictionary = by_src_any as Dictionary

	# inherit_from + multipliers
	if by_src.has("inherit_from"):
		var base_src: String = String(by_src["inherit_from"])
		var base: Dictionary = (curves_all.get(base_src, {}) as Dictionary)
		var mul: Dictionary = (by_src.get("multipliers", {}) as Dictionary)
		var merged: Dictionary = base.duplicate(true)
		for k in mul.keys():
			if merged.has(k) and merged[k] is Dictionary:
				var inner: Dictionary = (merged[k] as Dictionary).duplicate(true)
				inner["_multiplier"] = float(mul[k])
				merged[k] = inner
		by_src = merged

	var out: Dictionary = {}
	for r_any in rar_order:
		var r: String = String(r_any)
		var rule_any: Variant = by_src.get(r, null)
		if rule_any == null:
			out[r] = 0.0
			continue
		var rule: Dictionary = rule_any as Dictionary
		var t: String = String(rule.get("type", "fixed"))
		var v: float = 0.0
		match t:
			"fixed":
				v = float(rule.get("value", 0.0))
			"linear_by_band":
				var intercept: float = float(rule.get("intercept", 0.0))
				var slope: float = float(rule.get("slope_per_band", 0.0))
				v = intercept + slope * float(band - 1)
				var vmin: float = float(rule.get("min", -INF))
				var vmax: float = float(rule.get("max", INF))
				v = max(vmin, min(v, vmax))
			"ramp_after_floor":
				var start_floor: int = int(rule.get("start_floor", 1))
				var rate: float = float(rule.get("rate_per_floor", 0.0))
				var delta_floors: int = max(0, floor - start_floor + 1)
				v = max(0.0, rate * float(delta_floors))
			_:
				v = 0.0
		var mul2: float = float(rule.get("_multiplier", 1.0))
		v *= mul2
		out[r] = v

	out = _apply_unlocks(out, floor)
	out = _normalize(out, float((_cfg.get("normalization", {}) as Dictionary).get("normalize_to_percent", 100.0)))
	return out

func pick_rarity(source: String, floor: int, rng: RandomNumberGenerator) -> String:
	var w: Dictionary = rarity_weights_for(source, floor)
	var order: Array = _ord()
	w = _post_boss_adjustment(w, floor)
	return _weighted_pick(w, order, rng)

func category_for(source: String, rarity_code: String, rng: RandomNumberGenerator) -> String:
	_ensure_loaded()
	var items: Dictionary = _cfg.get("items", {}) as Dictionary
	var by_src: Dictionary = (items.get("category_weights_by_source", {}) as Dictionary)
	var by_r: Dictionary = (items.get("category_weights_by_rarity", {}) as Dictionary)

	var w: Dictionary = {}
	if by_src.has(source):
		var src_table_any: Variant = (by_src[source] as Dictionary).get(rarity_code, null)
		if src_table_any is Dictionary:
			w = src_table_any as Dictionary
	if w.is_empty():
		w = (by_r.get(rarity_code, {}) as Dictionary)
	if w.is_empty():
		return "gold"

	var order: Array = w.keys()
	return _weighted_pick(w, order, rng)

func shards_roll(source: String, floor: int, rng: RandomNumberGenerator) -> int:
	_ensure_loaded()
	var sh: Dictionary = _cfg.get("shards", {}) as Dictionary
	var allowed: Dictionary = (sh.get("allowed_by_source", {}) as Dictionary)
	if not bool(allowed.get(source, false)):
		return 0

	var chance: Dictionary = (sh.get("chance_by_source", {}) as Dictionary).get(source, {}) as Dictionary
	var base_p: float = float(chance.get("base_percent", 0.0))
	var per_floor: float = float(chance.get("per_floor_percent", 0.0))
	var cap: float = float(chance.get("cap_percent", 0.0))
	var p: float = min(cap, base_p + per_floor * float(max(0, floor - 1)))
	if rng.randf() * 100.0 > p:
		return 0

	var flat_base: int = int((sh.get("flat_amount_base", {}) as Dictionary).get(source, 1))
	var band_size: int = int(_cfg.get("floor_band_size", 3))
	var band: int = floor_to_band(floor, band_size)
	var growth: float = float(sh.get("flat_amount_per_band_growth", 0.10))
	var amt_f: float = float(flat_base) * pow(1.0 + growth, float(max(0, band - 1)))
	return _rounding(amt_f, String(sh.get("rounding", "nearest_int")))

func gold_amount(source: String, floor: int, rng: RandomNumberGenerator) -> int:
	_ensure_loaded()
	var gold: Dictionary = _cfg.get("gold", {}) as Dictionary
	var base: int = int((gold.get("flat_amount_base", {}) as Dictionary).get(source, 0))
	var per_band: float = float(gold.get("per_band_growth", 0.12))
	var band_size: int = int(_cfg.get("floor_band_size", 3))
	var band: int = floor_to_band(floor, band_size)
	var amount_f: float = float(base) * pow(1.0 + per_band, float(max(0, band - 1)))
	return _rounding(amount_f, String(gold.get("rounding", "nearest_int")))

func books_min_rarity() -> String:
	return String((_cfg.get("items", {}) as Dictionary).get("books_min_rarity", "U"))

func rarity_unlock_floor(code: String) -> int:
	return int((_cfg.get("rarity_unlock_floor", {}) as Dictionary).get(code, 1))

func floor_to_band(floor: int, band_size: int) -> int:
	return ((max(1, floor) - 1) / max(1, band_size)) + 1

func rarity_order() -> Array:
	return _ord()

# -----------------------
# Internals
# -----------------------
func _ord() -> Array:
	return _cfg.get("rarity_order", ["C","U","R","E","A","L","M"])

func _apply_unlocks(w: Dictionary, floor: int) -> Dictionary:
	var unlocks: Dictionary = (_cfg.get("rarity_unlock_floor", {}) as Dictionary)
	var out: Dictionary = w.duplicate()
	for k_any in _ord():
		var k: String = String(k_any)
		var unlock_floor: int = int(unlocks.get(k, 1))
		if floor < unlock_floor:
			out[k] = 0.0
	return out

func _normalize(w: Dictionary, total: float) -> Dictionary:
	var sum_val: float = 0.0
	for k_any in _ord():
		var k: String = String(k_any)
		sum_val += float(w.get(k, 0.0))
	if sum_val <= 0.0:
		var out0: Dictionary = {}
		var n: int = _ord().size()
		for k_any2 in _ord():
			var k2: String = String(k_any2)
			out0[k2] = (total / float(n))
		return out0

	var out: Dictionary = {}
	for k_any3 in _ord():
		var k3: String = String(k_any3)
		out[k3] = float(w.get(k3, 0.0)) * (total / sum_val)
	return out

func _weighted_pick(weights: Dictionary, order: Array, rng: RandomNumberGenerator) -> String:
	var t: float = 0.0
	for k_any in order:
		var k: String = String(k_any)
		t += float(weights.get(k, 0.0))
	if t <= 0.0:
		return String(order.front() if order.size() > 0 else "C")
	var roll: float = rng.randf() * t
	var acc: float = 0.0
	for k_any2 in order:
		var k2: String = String(k_any2)
		acc += float(weights.get(k2, 0.0))
		if roll <= acc:
			return k2
	return String(order.back())

func _post_boss_adjustment(w: Dictionary, floor: int) -> Dictionary:
	var shift: Dictionary = (_cfg.get("post_boss_shift", {}) as Dictionary)
	if not bool(shift.get("apply_after_boss_floors_mod", false)):
		return w
	var modv: int = int(shift.get("apply_after_boss_floors_mod", 3))
	var is_after_boss: bool = ((floor - 1) % modv == 0)
	if not is_after_boss:
		return w

	var respect_unlocks: bool = bool(shift.get("respect_unlocks", true))
	var deltas: Dictionary = (shift.get("deltas", {}) as Dictionary)
	var out: Dictionary = w.duplicate(true)
	for r_any in _ord():
		var r: String = String(r_any)
		if respect_unlocks and (floor < rarity_unlock_floor(r)):
			continue
		var d: float = float(deltas.get(r, 0.0))
		out[r] = max(0.0, float(out.get(r, 0.0)) + d)

	# Renormalize to original total
	var total: float = 0.0
	for r_any2 in _ord():
		var r2: String = String(r_any2)
		total += float(w.get(r2, 0.0))
	return _normalize(out, total)

func _rounding(v: float, mode: String) -> int:
	match mode:
		"floor": return int(floor(v))
		"ceil":  return int(ceil(v))
		_:       return int(round(v))

func _load_json(p: String) -> Dictionary:
	if not FileAccess.file_exists(p):
		return {}
	var f := FileAccess.open(p, FileAccess.READ)
	if f == null:
		return {}
	var txt: String = f.get_as_text()
	var parsed: Variant = JSON.parse_string(txt)
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}
	return parsed as Dictionary
