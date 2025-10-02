extends RefCounted
class_name BuffService
## Unified buff pipeline:
## - META.permanent_blessings        (Array[String] or Array[Dictionary{id}])
## - META.queued_blessings_next_run  (moved into RUN on start)
## - RUN.buffs                       (Array[String] runtime toggles/boons)
## - Equipment affixes               (derived here → RUN.mods_affix) + RUN.weapon_tags
## - Village benefits                (derived here → RUN.mods_village)

const _S := preload("res://persistence/util/save_utils.gd")
const Registry := preload("res://scripts/items/AffixRegistry.gd")
const VillageService := preload("res://persistence/services/village_service.gd")

const DEFAULT_SLOT: int = 1

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

	# --- Equipment-derived: numeric mods + incidental buff ids + weapon tags
	var eq_calc: Dictionary = _derive_equipment_affix_mods(rs) # {mods, buff_ids, weapon_tags}
	var eq_mods: Dictionary = _S.to_dict(_S.dget(eq_calc, "mods", {}))
	var eq_buff_ids: Array[String] = _S.to_string_array(_S.dget(eq_calc, "buff_ids", []))
	var eq_tags: Array[String]     = _S.to_string_array(_S.dget(eq_calc, "weapon_tags", []))

	# --- Village-derived: numeric mods + cosmetic buff ids
	var v_calc: Dictionary = VillageService.derive_run_benefits(slot)  # {mods, buff_ids}
	var v_mods: Dictionary = _S.to_dict(_S.dget(v_calc, "mods", {}))
	var v_buff_ids: Array[String] = _S.to_string_array(_S.dget(v_calc, "buff_ids", []))

	# Persist summarized mods separately (so UI can inspect both)
	rs["mods_affix"] = eq_mods
	rs["mods_village"] = v_mods

	# Merge weapon tags (unique)
	var existing_tags: Array[String] = _S.to_string_array(_S.dget(rs, "weapon_tags", []))
	for t in eq_tags:
		if not t.is_empty() and not existing_tags.has(t):
			existing_tags.append(t)
	rs["weapon_tags"] = existing_tags

	# Union buff ids (meta permanent + run + equipment + village)
	var union: Array[String] = []
	for id in meta_perm:
		if not union.has(id): union.append(id)
	for id2 in run_ids:
		if not union.has(id2): union.append(id2)
	for id3 in eq_buff_ids:
		if not id3.is_empty() and not union.has(id3):
			union.append(id3)
	for id4 in v_buff_ids:
		if not id4.is_empty() and not union.has(id4):
			union.append(id4)

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
static func _derive_equipment_affix_mods(rs: Dictionary) -> Dictionary:
	var reg := Registry.new()
	reg.ensure_loaded()

	var result: Dictionary = {
		"mods": {},
		"buff_ids": [],
		"weapon_tags": []
	}

	var mods: Dictionary = result["mods"]
	var tags: Array[String] = _S.to_string_array(result.get("weapon_tags", []))
	var ids:  Array[String] = _S.to_string_array(result.get("buff_ids", []))

	# Equipment tables
	var eq: Dictionary = (_S.dget(rs, "equipment", {}) as Dictionary)
	var bank: Dictionary = (_S.dget(rs, "equipped_bank", {}) as Dictionary)

	# Caps
	var caps: Dictionary = reg.global_caps()

	# Iterate all supported slots
	var slot_list: Array[String] = ["head","chest","legs","boots","mainhand","offhand","ring1","ring2","amulet"]
	for slot_name in slot_list:
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
				"added_damage_elem_flat":            _addf_to(mods, "added_damage_elem_flat", val)
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

				# --- Special/tag
				"gain_tag":
					var p: Dictionary = _S.to_dict(_S.dget(a, "params", {}))
					var tag: String = String(_S.dget(p, "tag", ""))
					if not tag.is_empty() and not tags.has(tag):
						tags.append(tag)

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

	# write back the arrays so caller sees the strings
	result["weapon_tags"] = tags
	result["buff_ids"] = ids
	return result
