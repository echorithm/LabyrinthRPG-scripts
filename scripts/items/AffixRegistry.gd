extends RefCounted
class_name AffixRegistry
## Loads & serves affix data (defs, pools, rarity, caps, UI rules, names).
## Data-only; pure getters so it's easy to mock in tests.

const _S := preload("res://persistence/util/save_utils.gd")

const PATH_DEFS        := "res://data/items/affix_defs.json"
const PATH_POOLS       := "res://data/items/pools_by_slot.json"
const PATH_RARITY      := "res://data/items/rarity_rules.json"
const PATH_CAPS_ORDER  := "res://data/items/caps_and_order.json"
const PATH_UI          := "res://data/items/ui_merge_rules.json"
const PATH_NAMES       := "res://data/items/namebanks.json"

var _defs: Dictionary = {}
var _pools: Dictionary = {}
var _rarity: Dictionary = {}
var _caps_order: Dictionary = {}
var _ui: Dictionary = {}
var _names: Dictionary = {}
var _loaded: bool = false

static func _load_json(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("[AffixRegistry] Could not open: " + path)
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("[AffixRegistry] JSON not object at: " + path)
		return {}
	return parsed as Dictionary

func ensure_loaded() -> void:
	if _loaded: return
	_defs = _S.to_dict(_load_json(PATH_DEFS))
	_pools = _S.to_dict(_load_json(PATH_POOLS))
	_rarity = _S.to_dict(_load_json(PATH_RARITY))
	_caps_order = _S.to_dict(_load_json(PATH_CAPS_ORDER))
	_ui = _S.to_dict(_load_json(PATH_UI))
	_names = _S.to_dict(_load_json(PATH_NAMES))
	_loaded = true

func affix_defs() -> Dictionary:
	ensure_loaded()
	return _S.to_dict(_defs.get("affixes", {}))

func pools_for_slot(slot_name: String) -> Dictionary:
	ensure_loaded()
	var slots: Dictionary = _S.to_dict(_pools.get("slots", {}))
	return _S.to_dict(slots.get(slot_name, {}))

func rarity_order() -> PackedStringArray:
	ensure_loaded()
	var arr: Array = (_rarity.get("rarity_order", []) as Array)
	var out := PackedStringArray()
	for v in arr: out.append(String(v))
	return out

func rarity_affix_count(r_code: String) -> int:
	ensure_loaded()
	return int(_S.dget(_S.to_dict(_rarity.get("affix_count", {})), r_code, 0))

func rarity_multiplier(r_code: String) -> float:
	ensure_loaded()
	return float(_S.dget(_S.to_dict(_rarity.get("rarity_multipliers", {})), r_code, 1.0))

func rarity_quality_band(r_code: String) -> Array[float]:
	ensure_loaded()
	var a: Array = (_S.dget(_S.to_dict(_rarity.get("quality_band_by_rarity", {})), r_code, []) as Array)
	var out: Array[float] = []
	for v in a: out.append(float(v))
	return out

func rarity_gate_min_for(affix_id: String) -> String:
	ensure_loaded()
	var gates: Dictionary = _S.to_dict(_rarity.get("rarity_gates", {}))
	var row: Dictionary = _S.to_dict(gates.get(affix_id, {}))
	return String(_S.dget(row, "min", ""))

func global_caps() -> Dictionary:
	ensure_loaded()
	return _S.to_dict(_caps_order.get("caps", {}))

func converters_rules() -> Dictionary:
	ensure_loaded()
	return _S.to_dict(_caps_order.get("converters", {}))

func ui_rules() -> Dictionary:
	ensure_loaded()
	return _S.to_dict(_ui)

func name_themes() -> Dictionary:
	ensure_loaded()
	return _S.to_dict(_names.get("themes", {}))

func affix_theme_map() -> Dictionary:
	ensure_loaded()
	return _S.to_dict(_names.get("affix_theme_map", {}))

func naming_rules() -> Dictionary:
	ensure_loaded()
	return _S.to_dict(_names.get("naming_rules", {}))
