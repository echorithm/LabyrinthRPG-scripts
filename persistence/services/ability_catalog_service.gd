extends RefCounted
class_name AbilityCatalogService
## Loads ability_catalog.json once, normalizes, and provides lookups.

const _S := preload("res://persistence/util/save_utils.gd")
const AbilitySchema := preload("res://persistence/schemas/ability_schema.gd")

const CATALOG_PATH: String = "res://data/combat/abilities/ability_catalog.json"

static var _loaded: bool = false
static var _by_id: Dictionary = {}
static var _by_gesture: Dictionary = {}   # symbol_id -> ability_id
static var _display_name: Dictionary = {} # ability_id -> display_name

static func _ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	_by_id.clear()
	_by_gesture.clear()
	_display_name.clear()

	if not ResourceLoader.exists(CATALOG_PATH):
		push_warning("[AbilityCatalogService] Catalog not found: %s" % CATALOG_PATH)
		return

	var f := FileAccess.open(CATALOG_PATH, FileAccess.READ)
	if f == null:
		push_warning("[AbilityCatalogService] Failed to open: %s" % CATALOG_PATH)
		return
	var txt: String = f.get_as_text()
	var parsed: Variant = JSON.parse_string(txt)
	if typeof(parsed) != TYPE_ARRAY:
		push_warning("[AbilityCatalogService] Catalog is not an array.")
		return

	for e_any in (parsed as Array):
		var row_raw: Dictionary = _S.to_dict(e_any)
		var row: Dictionary = AbilitySchema.normalize(row_raw)
		var aid: String = String(row.get("id",""))
		if aid.is_empty():
			continue
		_by_id[aid] = row.duplicate(true)
		_display_name[aid] = String(_S.dget(row_raw, "display_name", aid))

		# gesture mapping (json: gesture.symbol_id)
		var g_any: Variant = row_raw.get("gesture")
		if g_any is Dictionary:
			var g: Dictionary = g_any
			var symbol_id: String = String(g.get("symbol_id",""))
			if not symbol_id.is_empty():
				_by_gesture[symbol_id] = aid

static func get_by_id(ability_id: String) -> Dictionary:
	_ensure_loaded()
	return (_by_id.get(ability_id, {}) as Dictionary).duplicate(true)

static func get_by_gesture(symbol_id: String) -> String:
	_ensure_loaded()
	return String(_by_gesture.get(symbol_id, ""))

static func display_name(ability_id: String) -> String:
	_ensure_loaded()
	return String(_display_name.get(ability_id, ability_id))

static func attack_kind(ability_id: String) -> String:
	# "physical" vs "magical" vs "utility"
	_ensure_loaded()
	var row: Dictionary = _by_id.get(ability_id, {})
	if row.is_empty():
		return "utility"
	var raw: Dictionary = row
	# Decide from element/scaling: light/dark/wind/fire/water/earth => magical
	var elem: String = String(raw.get("element","physical"))
	var scaling: String = String(raw.get("scaling","support"))
	if elem in ["light","dark","wind","fire","water","earth"]:
		return "magical"
	if scaling in ["arcane","divine"]:
		return "magical"
	if bool(raw.get("to_hit", true)):
		return "physical" # default for weapon-like
	return "utility"

static func ctb_cost(ability_id: String) -> int:
	_ensure_loaded()
	var row: Dictionary = _by_id.get(ability_id, {})
	return int(row.get("ctb_cost", 100))

static func costs(ability_id: String) -> Dictionary:
	_ensure_loaded()
	var row: Dictionary = _by_id.get(ability_id, {})
	return {
		"mp": int(row.get("mp_cost", 0)),
		"stam": int(row.get("stam_cost", 0)),
		"cooldown": int(row.get("cooldown", 0))
	}
