# res://persistence/services/buff_service.gd
extends RefCounted
class_name BuffService
## Unified buff pipeline:
## - META.permanent_blessings        (Array[String] or Array[Dictionary{id}])
## - META.queued_blessings_next_run  (moved into RUN on start)
## - RUN.buffs                       (Array[String] runtime toggles/boons)
## - Equipment affixes               (derived here → RUN.mods_affix)
## - Weapon families                 (derived here → RUN.weapon_tags := ["sword","bow",...])
## - Village benefits                (derived elsewhere → RUN.mods_village)

const _S := preload("res://persistence/util/save_utils.gd")
const Registry := preload("res://scripts/items/AffixRegistry.gd")
const PATH_CATALOG := "res://data/items/catalog.json"

const DEFAULT_SLOT: int = 1

# Canonical, deterministic slot order (affects aggregation order)
const _SLOT_ORDER: PackedStringArray = [
	"head","chest","legs","boots",
	"sword","spear","mace","bow",
	"ring1","ring2","amulet"
]

# ---------------------- catalog loader (once) ----------------------
static var _catalog_items_cache: Dictionary = {}
static var _catalog_loaded: bool = false

static func _catalog_items() -> Dictionary:
	if _catalog_loaded:
		return _catalog_items_cache
	var fa := FileAccess.open(PATH_CATALOG, FileAccess.READ)
	if fa == null:
		push_error("[BuffService] Missing catalog at " + PATH_CATALOG)
		_catalog_items_cache = {}
		_catalog_loaded = true
		return _catalog_items_cache
	var parsed: Variant = JSON.parse_string(fa.get_as_text())
	fa.close()
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("[BuffService] catalog.json invalid")
		_catalog_items_cache = {}
		_catalog_loaded = true
		return _catalog_items_cache
	var d: Dictionary = parsed as Dictionary
	var items_any: Variant = d.get("items", {})
	_catalog_items_cache = (items_any as Dictionary) if items_any is Dictionary else {}
	_catalog_loaded = true
	return _catalog_items_cache

static func _catalog_mods_for(id_str: String) -> Dictionary:
	var items: Dictionary = _catalog_items()
	var row_any: Variant = items.get(id_str, {})
	if typeof(row_any) != TYPE_DICTIONARY:
		return {}
	var row: Dictionary = row_any as Dictionary
	var mods_any: Variant = row.get("mods", {})
	return (mods_any as Dictionary) if mods_any is Dictionary else {}

# ------------------------------------------------------------
# Entry points
# ------------------------------------------------------------
static func on_run_start(slot: int = DEFAULT_SLOT) -> void:
	var gs: Dictionary = SaveManager.load_game(slot)
	var rs: Dictionary = SaveManager.load_run(slot)

	# Move queued blessings (next-run) from META → RUN.buffs
	var queued_ids: Array[String] = _extract_buff_ids(_S.dget(gs, "queued_blessings_next_run", []))
	var run_buffs: Array[String] = _extract_buff_ids(_S.dget(rs, "buffs", []))
	for id in queued_ids:
		if not run_buffs.has(id):
			run_buffs.append(id)
	gs["queued_blessings_next_run"] = []
	rs["buffs"] = run_buffs
	
	SaveManager.save_game(gs, slot)
	SaveManager.save_run(rs, slot)

	# Rebuild immediately so equipment/village affixes are reflected
	rebuild_run_buffs(slot)

static func rebuild_run_buffs(slot: int = DEFAULT_SLOT) -> Array[String]:
	var gs: Dictionary = SaveManager.load_game(slot)
	var rs: Dictionary = SaveManager.load_run(slot)

	var meta_perm: Array[String] = _S.to_string_array(_S.dget(gs, "permanent_blessings", []))
	var run_ids:   Array[String] = _S.to_string_array(_S.dget(rs, "buffs", []))

	# --- Equipment-derived: numeric mods + incidental buff ids + weapon families
	var eq_calc: Dictionary = _derive_equipment_affix_mods(rs) # {mods, buff_ids, weapon_tags}
	var eq_mods: Dictionary = _S.to_dict(_S.dget(eq_calc, "mods", {}))
	var eq_buff_ids: Array[String] = _S.to_string_array(_S.dget(eq_calc, "buff_ids", []))
	var eq_families: Array[String] = _S.to_string_array(_S.dget(eq_calc, "weapon_tags", [])) # now families only

	# Write mirrors back to RUN (deterministic shape)
	rs["mods_affix"] = eq_mods
	rs["weapon_tags"] = eq_families

	# Union buff ids (meta permanent + run + equipment)
	var union: Array[String] = []
	for id in meta_perm:
		if not union.has(id):
			union.append(id)
	for id2 in run_ids:
		if not union.has(id2):
			union.append(id2)
	for id3 in eq_buff_ids:
		if not id3.is_empty() and not union.has(id3):
			union.append(id3)

	rs["buffs"] = union

	SaveManager.save_run(rs, slot)
	return union

# ------------------------------------------------------------
# Helpers
# ------------------------------------------------------------
static func _extract_buff_ids(src_any: Variant) -> Array[String]:
	# Accept either Array[String] or Array[Dictionary]{ id = String }
	var out: Array[String] = []
	if src_any is Array:
		for v in (src_any as Array):
			match typeof(v):
				TYPE_STRING:
					var s := String(v)
					if not s.is_empty() and not out.has(s):
						out.append(s)
				TYPE_DICTIONARY:
					var d: Dictionary = v
					var id: String = String(_S.dget(d, "id", ""))
					if not id.is_empty() and not out.has(id):
						out.append(id)
				_:
					pass
	return out

# Class-level small helper: sum float into a dictionary key.
static func _addf_to(mods: Dictionary, key: String, v: float) -> void:
	var cur: float = float(_S.dget(mods, key, 0.0))
	mods[key] = cur + v

# Walk equipped_bank and aggregate affix effects.
# Returns: { "mods": Dictionary, "buff_ids": Array[String], "weapon_tags": Array[String] }
# NOTE: weapon_tags in this context are the EQUIPPED WEAPON FAMILIES (sword/spear/mace/bow), not affix tags.
static func _derive_equipment_affix_mods(rs: Dictionary) -> Dictionary:
	var reg := Registry.new()
	reg.ensure_loaded()

	var result: Dictionary = {
		"mods": {},
		"buff_ids": [],
		"weapon_tags": []
	}

	var mods: Dictionary = result["mods"]
	var families: Array[String] = []
	var ids:  Array[String] = []

	# Equipment tables
	var eq: Dictionary = (_S.dget(rs, "equipment", {}) as Dictionary)
	var bank: Dictionary = (_S.dget(rs, "equipped_bank", {}) as Dictionary)

	# Caps
	var caps: Dictionary = reg.global_caps()

	# Iterate deterministic slot order (includes weapon families)
	for slot_name in _SLOT_ORDER:
		var uid_any: Variant = eq.get(slot_name, null)
		if uid_any == null:
			continue
		var uid: String = String(uid_any)
		if uid.is_empty():
			continue
		if not (bank.has(uid) and bank[uid] is Dictionary):
			continue

		var row: Dictionary = bank[uid] as Dictionary
		if int(_S.dget(row, "durability_max", 0)) <= 0:
			continue # only gear contributes

		# If a weapon-family slot is populated, record the family tag
		if slot_name in ["sword","spear","mace","bow"]:
			if not families.has(slot_name):
				families.append(slot_name)

		# ---- (A) Include base item mods from catalog.json ----
		var id_str: String = String(_S.dget(row, "id", ""))
		if not id_str.is_empty():
			var base: Dictionary = _catalog_mods_for(id_str)
			if not base.is_empty():
				# Cost multiplier -> reduction percent for UI/summary
				if base.has("ctb_cost_mult"):
					var mult: float = float(base["ctb_cost_mult"])
					var pct: float = (1.0 - mult) * 100.0
					if pct != 0.0:
						_addf_to(mods, "ctb_cost_reduction_pct", pct)
				# Speed add
				if base.has("ctb_speed_add"):
					_addf_to(mods, "ctb_speed_add", float(base["ctb_speed_add"]))
				# Accuracy: prefer add_pct; also mirror to accuracy_flat for panel pretty-name
				if base.has("accuracy_add_pct"):
					var acc: float = float(base["accuracy_add_pct"])
					_addf_to(mods, "accuracy_add_pct", acc)
					_addf_to(mods, "accuracy_flat", acc)
				# Crit chance as absolute points (panel mapping expects *_pct)
				if base.has("crit_chance_add"):
					_addf_to(mods, "crit_chance_pct", float(base["crit_chance_add"]))
				# Crit multi additive (+0.05 style)
				if base.has("crit_multi_add"):
					_addf_to(mods, "crit_multi_add", float(base["crit_multi_add"]))
				# Penetration
				if base.has("pene_add_pct"):
					_addf_to(mods, "pene_add_pct", float(base["pene_add_pct"]))
				# Armor: sum lanes into a simple Defense preview
				if base.has("armor_add_flat") and base["armor_add_flat"] is Dictionary:
					var arow: Dictionary = base["armor_add_flat"] as Dictionary
					var asum: float = 0.0
					for k_any in arow.keys():
						asum += float(_S.dget(arow, String(k_any), 0.0))
					if asum != 0.0:
						_addf_to(mods, "def_flat", asum)

		# ---- (B) Aggregate affixes; do NOT add 'gain_tag' into weapon_tags here.
		var aff_any: Variant = _S.dget(row, "affixes", [])
		if not (aff_any is Array):
			continue
		var aff: Array = aff_any as Array

		for a_any in aff:
			if not (a_any is Dictionary):
				# Legacy string affixes could be considered buff IDs:
				if typeof(a_any) == TYPE_STRING:
					var s: String = String(a_any)
					if not s.is_empty() and not ids.has(s):
						ids.append(s)
				continue

			var a: Dictionary = a_any
			var et: String = String(_S.dget(a, "effect_type", ""))
			if et.is_empty():
				continue
			var val: float = float(_S.dget(a, "value", 0.0))

			match et:
				# --- Offense / weapon
				"flat_power":                        _addf_to(mods, "flat_power", val)
				"school_power_pct":                  _addf_to(mods, "school_power_pct", val)
				"accuracy_flat":                     _addf_to(mods, "accuracy_flat", val)
				"crit_chance_pct":                   _addf_to(mods, "crit_chance_pct", val)
				"crit_damage_pct":                   _addf_to(mods, "crit_damage_pct", val)
				"added_damage_elem_flat":
					_addf_to(mods, "added_damage_elem_flat", val)  # keep legacy total
					var p_el: Dictionary = _S.to_dict(_S.dget(a, "params", {}))
					var elem: String = String(_S.dget(p_el, "element", "")).to_lower()
					if not elem.is_empty():
						_addf_to(mods, "added_damage_%s_flat" % elem, val)  # e.g. added_damage_fire_flat
				"added_damage_phys_flat":            _addf_to(mods, "added_damage_phys_flat", val)
				"element_mod_pct":                   _addf_to(mods, "element_mod_pct", val)
				"on_hit_status_chance_pct":          _addf_to(mods, "on_hit_status_chance_pct", val)
				"life_on_hit_flat":                  _addf_to(mods, "life_on_hit_flat", val)
				"mana_on_hit_flat":                  _addf_to(mods, "mana_on_hit_flat", val)
				"ctb_on_kill_pct":                   _addf_to(mods, "ctb_on_kill_pct", val)
				"convert_physical_to_element_pct":   _addf_to(mods, "convert_physical_to_element_pct", val)

				# --- Defense / armor
				"def_flat":                          _addf_to(mods, "def_flat", val)
				"res_flat":                          _addf_to(mods, "res_flat", val)
				"speed_delta_flat":                  _addf_to(mods, "speed_delta_flat", val)
				"dodge_chance_pct":                  _addf_to(mods, "dodge_chance_pct", val)
				"ctb_cost_reduction_pct":            _addf_to(mods, "ctb_cost_reduction_pct", val)
				"status_resist_pct":                 _addf_to(mods, "status_resist_pct", val)
				"element_resist_pct":                _addf_to(mods, "element_resist_pct", val)
				"thorns_pct":                        _addf_to(mods, "thorns_pct", val)
				"carry_capacity_flat":               _addf_to(mods, "carry_capacity_flat", val)

				# --- Accessories / economy
				"primary_stat_flat":                 _addf_to(mods, "primary_stat_flat", val)
				"skill_xp_gain_pct":                 _addf_to(mods, "skill_xp_gain_pct", val)
				"gold_find_pct":                     _addf_to(mods, "gold_find_pct", val)
				"hp_on_kill_flat":                   _addf_to(mods, "hp_on_kill_flat", val)
				"mp_on_kill_flat":                   _addf_to(mods, "mp_on_kill_flat", val)

				# --- QoL
				"durability_loss_reduction_pct":     _addf_to(mods, "durability_loss_reduction_pct", val)

				_:
					# If any affix provides a literal buff id in params (rare)
					var p2: Dictionary = _S.to_dict(_S.dget(a, "params", {}))
					var maybe_buff: String = String(_S.dget(p2, "buff_id", ""))
					if not maybe_buff.is_empty() and not ids.has(maybe_buff):
						ids.append(maybe_buff)

	# Apply simple global caps (clamps)
	if mods.has("crit_chance_pct"):
		mods["crit_chance_pct"] = min(float(mods["crit_chance_pct"]), float(_S.dget(caps, "crit_chance_pct", 9e9)))
	if mods.has("dodge_chance_pct"):
		mods["dodge_chance_pct"] = min(float(mods["dodge_chance_pct"]), float(_S.dget(caps, "dodge_chance_pct", 9e9)))
	if mods.has("ctb_cost_reduction_pct"):
		mods["ctb_cost_reduction_pct"] = min(float(mods["ctb_cost_reduction_pct"]), float(_S.dget(caps, "ctb_cost_reduction_pct", 9e9)))
	if mods.has("durability_loss_reduction_pct"):
		var floor_v: float = float(_S.dget(caps, "durability_loss_reduction_pct_floor", -80.0))
		mods["durability_loss_reduction_pct"] = max(float(mods["durability_loss_reduction_pct"]), floor_v)

	# write back arrays
	result["weapon_tags"] = families
	result["buff_ids"] = ids
	return result
