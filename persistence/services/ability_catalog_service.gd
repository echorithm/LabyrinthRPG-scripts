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
static var _costs_by_id: Dictionary = {}  # ability_id -> { mp, stam, cooldown, charges }



static func _ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	_by_id.clear()
	_by_gesture.clear()
	_display_name.clear()
	_costs_by_id.clear()

	if not ResourceLoader.exists(CATALOG_PATH):
		push_warning("[AbilityCatalogService] Catalog not found: %s" % CATALOG_PATH)
		return

	var f: FileAccess = FileAccess.open(CATALOG_PATH, FileAccess.READ)
	if f == null:
		push_warning("[AbilityCatalogService] Failed to open: %s" % CATALOG_PATH)
		return

	var txt: String = f.get_as_text()
	var parsed: Variant = JSON.parse_string(txt)
	if typeof(parsed) != TYPE_ARRAY:
		push_warning("[AbilityCatalogService] Catalog is not an array.")
		return

	for e_any: Variant in (parsed as Array):
		# Raw row from JSON
		var row_raw: Dictionary = _S.to_dict(e_any)

		# Normalized baseline (schema may drop unknown keys)
		var row_norm: Dictionary = AbilitySchema.normalize(row_raw)

		# ID
		var aid: String = String(row_norm.get("id",""))
		if aid.is_empty():
			aid = String(row_raw.get("ability_id",""))
		if aid.is_empty():
			continue

		# --- Merge kernel-facing fields from raw JSON so they survive normalization ---
		# Lanes (legacy P0/E0 or canonical): convert to canonical 4+6 keys
		row_norm["lanes"] = _canonicalize_lanes(row_norm, row_raw)

		# Accuracy / crit / variance / penetration
		if row_raw.has("accuracy"):          row_norm["accuracy"] = float(row_raw["accuracy"])
		if row_raw.has("crit_chance"):       row_norm["crit_chance"] = float(row_raw["crit_chance"])
		if row_raw.has("crit_multiplier"):   row_norm["crit_multiplier"] = float(row_raw["crit_multiplier"])
		if row_raw.has("variance_pct"):      row_norm["variance_pct"] = float(row_raw["variance_pct"])
		if row_raw.has("penetration_pct"):   row_norm["penetration_pct"] = float(row_raw["penetration_pct"])

		# Riders array (lightweight status descriptors)
		var riders_any: Variant = row_raw.get("riders")
		if typeof(riders_any) == TYPE_ARRAY:
			var riders_arr: Array = riders_any
			var riders_out: Array[Dictionary] = []
			for r_any: Variant in riders_arr:
				if typeof(r_any) == TYPE_DICTIONARY:
					riders_out.append((r_any as Dictionary).duplicate(true))
			row_norm["riders"] = riders_out

		# Keep these text keys aligned with player JSON (harmless if schema already set)
		if row_raw.has("animation_key"): row_norm["animation_key"] = String(row_raw["animation_key"])
		if row_raw.has("damage_type"):   row_norm["damage_type"] = String(row_raw["damage_type"])
		if row_raw.has("intent_id"):     row_norm["intent_id"]   = String(row_raw["intent_id"])
		if row_raw.has("sound_key"):     row_norm["sound_key"]   = String(row_raw["sound_key"])


		# Store canonical record
		_by_id[aid] = row_norm.duplicate(true)
		_display_name[aid] = String(_S.dget(row_raw, "display_name", aid))

		# Costs (preserve JSON values if present)
		var mp_cost: int   = int(row_raw.get("mp_cost",   row_norm.get("mp_cost",   0)))
		var stam_cost: int = int(row_raw.get("stam_cost", row_norm.get("stam_cost", 0)))
		var cooldown: int  = int(row_raw.get("cooldown",  row_norm.get("cooldown",  0)))
		var charges: int   = int(row_raw.get("charges",   row_norm.get("charges",   0)))
		_costs_by_id[aid] = { "mp": mp_cost, "stam": stam_cost, "cooldown": cooldown, "charges": charges }

		# Gesture mapping (json: gesture.symbol_id)
		var g_any: Variant = row_norm.get("gesture")
		if typeof(g_any) == TYPE_DICTIONARY:
			var g: Dictionary = g_any
			var symbol_id: String = String(g.get("symbol_id",""))
			if not symbol_id.is_empty():
				_by_gesture[symbol_id] = aid

	#print("[AbilityCatalog] Loaded entries=%d" % _by_id.size())


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

	var intent: String = String(row.get("intent_id",""))

	# --- Intent-first guard: these are NOT attacks, regardless of element/scaling ---
	if intent.begins_with("IT_heal") \
	or intent.begins_with("IT_cleanse") \
	or intent == "IT_block" \
	or intent == "IT_block_boost" \
	or intent.begins_with("IT_restore") \
	or intent.begins_with("IT_apply_"):
		return "utility"

	# --- Only genuine attacks fall through here ---
	var elem: String = String(row.get("element","physical"))
	var scaling: String = String(row.get("scaling","support"))
	var to_hit: bool = bool(row.get("to_hit", true))

	if elem in ["light","dark","wind","fire","water","earth"] or scaling in ["arcane","divine"]:
		return "magical"
	if to_hit:
		return "physical"
	return "utility"


static func ctb_cost(ability_id: String) -> int:
	_ensure_loaded()
	var row: Dictionary = _by_id.get(ability_id, {})
	return int(row.get("ctb_cost", 100))

static func costs(ability_id: String) -> Dictionary:
	_ensure_loaded()
	return (_costs_by_id.get(ability_id, {"mp":0, "stam":0, "cooldown":0, "charges":0}) as Dictionary).duplicate(true)

## Allow other systems (e.g., MonsterCatalog) to inject ability defs at runtime.
## Expects monster-style rows (keys like "ability_id", "display_name", "ctb_cost", "lanes", "ai"...).
static func register_external(abilities: Array) -> void:
	_ensure_loaded()
	if abilities.is_empty():
		return

	var added: int = 0
	for a_any: Variant in abilities:
		if typeof(a_any) != TYPE_DICTIONARY:
			continue
		var a: Dictionary = a_any

		var id: String = String(a.get("ability_id", ""))
		if id.is_empty():
			continue

		# Do not overwrite canonical player catalog entries.
		if _by_id.has(id):
			continue

		# Normalize monster ability to kernel/player shape.
		var row: Dictionary = _normalize_monster_ability_row(a)

		# Store normalized row
		_by_id[id] = row.duplicate(true)
		_display_name[id] = String(row.get("display_name", id))

		# Monsters typically don't track costs; ensure defaults exist.
		if not _costs_by_id.has(id):
			_costs_by_id[id] = { "mp": 0, "stam": 0, "cooldown": 0, "charges": 0 }

		# Optional: echo some debug so we can verify normalization quickly.
		#if OS.is_debug_build():
		#	print("[AbilityCatalogService] External ability normalized id=", id,
		#		" lanes=", row.get("lanes"),
		#		" acc=", row.get("accuracy"),
		#		" crit=", row.get("crit_chance"), "x", row.get("crit_multiplier"))

		added += 1

	#if added > 0:
	#	print("[AbilityCatalogService] Registered external abilities: +%d" % added)



# --- Lane normalization helpers ---------------------------------------------

static func _sum_lane_keys(src: Dictionary, keys: PackedStringArray) -> float:
	var s: float = 0.0
	for k in keys:
		if src.has(k):
			s += float(src[k])
	return s

static func _normalize_monster_ability_row(a: Dictionary) -> Dictionary:
	# Source fields (monster JSON)
	var id: String = String(a.get("ability_id", ""))
	var display_name: String = String(a.get("display_name", id))
	var element: String = String(a.get("element", "physical"))
	var scaling: String = String(a.get("scaling", "power"))
	var to_hit: bool = bool(a.get("to_hit", true))
	var crit_allowed: bool = bool(a.get("crit_allowed", true))
	var base_power: int = int(a.get("base_power", 0))
	var ctb_cost: int = int(a.get("ctb_cost", 100))
	var dmg_type: String = String(a.get("damage_type", ""))
	var intent_id: String = String(a.get("intent_id", ""))
	var animation_key: String = String(a.get("animation_key", ""))
	var ai_any: Variant = a.get("ai", {})
	var ai: Dictionary = (ai_any as Dictionary) if typeof(ai_any) == TYPE_DICTIONARY else {}
	var lanes_src_any: Variant = a.get("lanes", {})
	var lanes_src: Dictionary = (lanes_src_any as Dictionary) if typeof(lanes_src_any) == TYPE_DICTIONARY else {}
	var sound_key: String = String(a.get("sound_key", ""))

	# Collapse monster-format lanes to kernel lanes:
	#   Physical keys → "P0"
	#   Elemental keys → "E0"
	# If both present, split proportionally and normalize to 100 total.
	var phys_keys := PackedStringArray(["pierce","slash","blunt","ranged"])
	var elem_keys := PackedStringArray(["fire","water","earth","wind","light","dark"])

	var phys_sum: float = _sum_lane_keys(lanes_src, phys_keys)
	var elem_sum: float = _sum_lane_keys(lanes_src, elem_keys)
	var total_sum: float = phys_sum + elem_sum
	


	var lanes_norm: Dictionary = {}
	if total_sum <= 0.0:
		# Fallback by element/scaling
		if element in ["fire","water","earth","wind","light","dark"] or scaling in ["arcane","divine"]:
			lanes_norm["E0"] = 100
		elif dmg_type != "" and (dmg_type in ["fire","water","earth","wind","light","dark"]):
			lanes_norm["E0"] = 100
		else:
			lanes_norm["P0"] = 100
	else:
		if phys_sum > 0.0:
			lanes_norm["P0"] = int(round((phys_sum / total_sum) * 100.0))
		if elem_sum > 0.0:
			var elem_pct: int = int(round((elem_sum / total_sum) * 100.0))
			# keep total at ~100; adjust if rounding made it 99/101
			if lanes_norm.has("P0"):
				var p0: int = int(lanes_norm["P0"])
				var diff: int = (p0 + elem_pct) - 100
				if diff != 0:
					elem_pct -= diff
			lanes_norm["E0"] = max(0, elem_pct)

	# Safe defaults to drive miss/crit/variance
	var accuracy: float = (1.0 if not to_hit else 0.90)
	var crit_chance: float = (0.0 if not crit_allowed else 0.08)
	var crit_multiplier: float = (1.0 if not crit_allowed else 1.50)
	var variance_pct: float = 0.10
	var penetration_pct: float = 0.0

	# Build normalized row in the same shape our pipelines read for player abilities.
	var row: Dictionary = {
		"id": id,
		"display_name": display_name,
		"element": element,
		"scaling": scaling,
		"to_hit": to_hit,
		"crit_allowed": crit_allowed,
		"base_power": base_power,
		"ctb_cost": ctb_cost,
		"damage_type": (dmg_type if dmg_type != "" else element),
		"intent_id": intent_id,
		"animation_key": animation_key,
		
		

		# Kernel-facing fields
		"lanes": lanes_norm,
		"accuracy": accuracy,
		"crit_chance": crit_chance,
		"crit_multiplier": crit_multiplier,
		"variance_pct": variance_pct,
		"penetration_pct": penetration_pct,

		# Keep AI block for the controller/AI layer
		"ai": ai,
	}
	if sound_key != "":
			row["sound_key"] = sound_key

	return row

# Replace _lane_for_type with this
static func _lane_for_type(dmg_type: String, element: String, intent_id: String) -> String:
	# Normalize hints
	var t := dmg_type.strip_edges().to_lower()
	var e := element.strip_edges().to_lower()
	var i := intent_id.strip_edges().to_lower()

	# If damage_type is a precise canonical lane, trust it.
	if t in ["pierce","slash","blunt","ranged","light","dark","earth","water","fire","wind"]:
		return t

	# Next, use element when it maps 1:1 to a canonical lane.
	if e in ["light","dark","earth","water","fire","wind"]:
		return e

	# Intent fallbacks
	if i.find("_phys_pierce") != -1: return "pierce"
	if i.find("_phys_slash")  != -1: return "slash"
	if i.find("_phys_blunt")  != -1: return "blunt"
	if i.find("_phys_ranged") != -1: return "ranged"
	if i.find("_mag_light")   != -1: return "light"
	if i.find("_mag_dark")    != -1: return "dark"
	if i.find("_mag_earth")   != -1: return "earth"
	if i.find("_mag_water")   != -1: return "water"
	if i.find("_mag_fire")    != -1: return "fire"
	if i.find("_mag_wind")    != -1: return "wind"

	# Final safe default (physical single-target)
	return "pierce"



static func _normalize_pct_map(src: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	var sum: float = 0.0
	for k in src.keys():
		var v: float = max(0.0, float(src[k]))
		if v > 0.0:
			out[String(k)] = v
			sum += v
	if sum <= 0.0:
		out.clear()
		out["pierce"] = 100.0
	else:
		for k2 in out.keys():
			out[k2] = (out[k2] / sum) * 100.0
	return out


static func _canonicalize_lanes(row_norm: Dictionary, row_raw: Dictionary) -> Dictionary:
	# 0) If JSON already used canonical names, keep & normalize them
	var lanes_any: Variant = row_raw.get("lanes")
	if typeof(lanes_any) == TYPE_DICTIONARY:
		var lanes: Dictionary = lanes_any as Dictionary
		var found_canonical: bool = false
		var canonical: Dictionary = {}
		for k_any in lanes.keys():
			var k: String = String(k_any)
			if k in ["pierce","slash","blunt","ranged","light","dark","earth","water","fire","wind"]:
				found_canonical = true
				canonical[k] = lanes[k_any]
		if found_canonical:
			return _normalize_pct_map(canonical)

	# 1) Legacy P/E lanes → pick a single canonical lane using hints
	var dmg_type: String = String(row_norm.get("damage_type", ""))
	var element: String = String(row_norm.get("element", "physical"))
	var intent: String = String(row_norm.get("intent_id", ""))
	var key: String = _lane_for_type(dmg_type, element, intent)
	var out: Dictionary = {}
	out[key] = 100.0
	return out
