extends RefCounted
class_name AffixService
## Deterministic affix roller + evaluator.

const _S := preload("res://persistence/util/save_utils.gd")
const Registry := preload("res://scripts/items/AffixRegistry.gd")

# ---------------- RNG helpers ----------------
static func _rng_from_tuple(tuple: Array) -> RandomNumberGenerator:
	# Deterministic seed mixer from tuple of small ints/strings.
	var s := ""
	for v in tuple:
		s += str(v) + "|"
	var h := s.hash() # 32-bit
	var rng := RandomNumberGenerator.new()
	rng.seed = int(h)
	return rng

# ---------------- Public API -----------------
## Rolls affixes for given item slot & rarity using data pools.
## item_type: "weapon" | "armor" | "jewelry" (optional; inferred from slot_name if empty for compatibility)
## Returns: Array[Dictionary] of affix rows:
## { id, effect_type, value: float, quality: float, units?: String, params?: Dictionary }
static func roll_affixes(ilvl: int, rarity_code: String, slot_name: String, base_item_id: String, seed_tuple: Array, item_type: String = "") -> Array[Dictionary]:
	var reg := Registry.new()
	reg.ensure_loaded()

	# Determine item_type (back-compat inference if not provided)
	var itype := item_type.strip_edges().to_lower()
	if itype == "":
		var s := slot_name.to_lower()
		if s == "amulet" or s == "ring":
			itype = "jewelry"
		elif s in ["head", "chest", "legs", "boots"]:
			itype = "armor"
		else:
			itype = "weapon"

	var count: int = reg.rarity_affix_count_for(itype, rarity_code)
	if count <= 0:
		return []

	var pool: Dictionary = reg.pools_for_slot(slot_name)
	var weights: Dictionary = _S.to_dict(pool.get("weights", {}))
	if weights.is_empty():
		return []

	# Build weighted list filtered by rarity gates and disabled flags
	var defs: Dictionary = reg.affix_defs()
	var weighted: Array = []  # Array[[id, weight]]
	for k in weights.keys():
		var affix_id: String = String(k)
		if not defs.has(affix_id):
			continue
		var def: Dictionary = _S.to_dict(defs.get(affix_id, {}))
		if bool(_S.dget(def, "disabled", false)):
			continue
		var gate_min: String = reg.rarity_gate_min_for(affix_id)
		if not _rarity_allows(rarity_code, gate_min, reg.rarity_order()):
			continue
		weighted.append([affix_id, int(weights[k])])

	var result: Array[Dictionary] = []
	if weighted.is_empty():
		return result

	# Quality band and rarity mult (affix power multiplier per spec)
	var qband: Array[float] = reg.rarity_quality_band(rarity_code)
	var qmin: float = (qband[0] if qband.size() >= 1 else 0.60)
	var qmax: float = (qband[1] if qband.size() >= 2 else 1.00)
	var rmult: float = reg.affix_power_multiplier(rarity_code)

	# Deterministic RNG from tuple + affix index
	for i in range(count):
		var rng := _rng_from_tuple(seed_tuple + [slot_name, "affix", i])
		var pick_id: String = _pick_weighted(weighted, rng)
		if pick_id.is_empty():
			continue
		var def2: Dictionary = _S.to_dict(defs.get(pick_id, {}))

		# Draw quality in band
		var q: float = qmin + (qmax - qmin) * rng.randf()
		var value_units: Dictionary = _evaluate_magnitude(def2, ilvl, rmult, q)

		var row: Dictionary = {
			"id": pick_id,
			"effect_type": String(_S.dget(def2, "effect_type", "")),
			"value": float(value_units.value),
			"quality": q
		}
		var units_str: String = String(value_units.units)
		if units_str != "":
			row["units"] = units_str
		var params: Dictionary = _S.to_dict(def2.get("params", {}))
		if not params.is_empty():
			row["params"] = params
		result.append(row)
	return result

## Builds a flavored display name using namebanks + quality tier.
static func build_display_name(base_name: String, affixes: Array, rarity_code: String, seed_tuple: Array) -> String:
	var reg := Registry.new()
	reg.ensure_loaded()

	if affixes.is_empty():
		return base_name

	# Pull a theme based on first affix id mapping (simple v1)
	var a0_any: Variant = affixes[0]
	if typeof(a0_any) != TYPE_DICTIONARY:
		return base_name
	var a0: Dictionary = a0_any
	var aid: String = String(_S.dget(a0, "id", ""))
	var theme_map: Dictionary = reg.affix_theme_map()
	var theme: String = String(_S.dget(theme_map, aid, ""))

	var themes: Dictionary = reg.name_themes()
	var trow: Dictionary = _S.to_dict(themes.get(theme, {}))
	if trow.is_empty():
		return base_name

	var mode: String = String(_S.dget(reg.naming_rules(), "mode", "prefix_or_suffix"))
	var pref: Array = (_S.dget(trow, "prefix", []) as Array)
	var suf: Array = (_S.dget(trow, "suffix", []) as Array)

	# Quality → tier index 0..4
	var qband: Array[float] = reg.rarity_quality_band(rarity_code)
	var qsum: float = 0.0
	var n: int = 0
	for r_any in affixes:
		if r_any is Dictionary:
			qsum += float(_S.dget(r_any as Dictionary, "quality", 1.0))
			n += 1
	var qavg: float = (qsum / float(max(1, n)))
	var qmin: float = (qband[0] if qband.size() > 0 else 0.6)
	var qmax: float = (qband[1] if qband.size() > 1 else 1.0)
	var qnorm: float = clampf((qavg - qmin) / max(0.0001, (qmax - qmin)), 0.0, 1.0)
	var steps: int = 5
	var idx: int = int(floor(qnorm * float(steps)))
	idx = clampi(idx, 0, steps - 1)

	var rng := _rng_from_tuple(seed_tuple + ["name"])
	if mode == "prefix_or_suffix":
		var coin := rng.randi_range(0, 1)
		if coin == 0 and pref.size() > 0:
			var p := String(pref[min(idx, pref.size() - 1)])
			return "%s %s" % [p, base_name]
		elif suf.size() > 0:
			var s := String(suf[min(idx, suf.size() - 1)])
			return "%s %s" % [base_name, s]
	return base_name

# --------------- Internals -------------------
static func _rarity_allows(r_code: String, gate_min: String, order: PackedStringArray) -> bool:
	if gate_min.is_empty():
		return true
	var i_have := order.find(r_code)
	var i_need := order.find(gate_min)
	if i_have < 0 or i_need < 0:
		return false
	return i_have >= i_need

static func _pick_weighted(weighted: Array, rng: RandomNumberGenerator) -> String:
	var total: int = 0
	for e in weighted:
		total += int(e[1])
	if total <= 0:
		return ""
	var roll: int = rng.randi_range(1, total)
	var acc: int = 0
	for e in weighted:
		acc += int(e[1])
		if roll <= acc:
			return String(e[0])
	return ""

static func _evaluate_magnitude(def: Dictionary, ilvl: int, rarity_mult: float, quality: float) -> Dictionary:
	var mag: Dictionary = _S.to_dict(def.get("magnitude", {}))
	var model: String = String(_S.dget(mag, "model", "fixed"))
	var units: String = String(_S.dget(mag, "units", ""))
	var b: int = int(ceil(float(max(1, ilvl)) / 5.0))

	match model:
		"fixed":
			var v_fixed: float = float(_S.dget(mag, "value", 0.0))
			return { "value": v_fixed, "units": units }

		"formula":
			var ctab: Dictionary = _S.to_dict(mag.get("coeff_per_bracket", {}))
			var coeff: float = float(_S.dget(ctab, str(b), _S.dget(ctab, "1", 1.0)))
			var expr: String = String(_S.dget(mag, "formula", "value = coeff * ilvl"))
			var value: float = 0.0
			if expr.find("coeff * ilvl") >= 0:
				value = coeff * float(ilvl)
			elif expr.find("coeff * b") >= 0:
				value = coeff * float(b)
			elif expr.find("1 + floor(b/2)") >= 0:
				value = 1.0 + floor(float(b) / 2.0)
			elif expr.find("1 + floor(ilvl/6)") >= 0:
				value = 1.0 + floor(float(ilvl) / 6.0)
			elif expr.find("1 + floor(ilvl/8)") >= 0:
				value = 1.0 + floor(float(ilvl) / 8.0)
			elif expr.find("1 + floor(ilvl/10)") >= 0:
				value = 1.0 + floor(float(ilvl) / 10.0)
			elif expr.find("2 + floor(ilvl/4)") >= 0:
				value = 2.0 + floor(float(ilvl) / 4.0)
			else:
				value = coeff * float(ilvl)
			value *= rarity_mult * quality
			return { "value": value, "units": units }

		"bands":
			var band: Dictionary = _S.to_dict(mag.get("per_bracket_ranges", {}))
			var pair_any: Variant = band.get(str(b), band.get("1", [1, 1]))
			var pair: Array = (pair_any as Array) if pair_any is Array else [1, 1]
			var lo: float = float(pair[0])
			var hi: float = float(pair[min(1, pair.size() - 1)])
			var v_band: float = lerpf(lo, hi, clampf(quality, 0.0, 1.0))
			var v: float = v_band * rarity_mult
			return { "value": v, "units": units }

		_:
			return { "value": 0.0, "units": units }
