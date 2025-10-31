# File: res://scripts/village/persistence/schemas/buildings_catalog_schema.gd
# Godot 4.5 — Validates buildings_catalog.json (rarity-first model)
# - Accepts either "assets" or legacy "tile"; normalizes to "assets"
# - base_effect now permits: bool/int/float/string, arrays of numbers/strings,
#   and shallow dictionaries composed of the same (no complex objects).

class_name BuildingsCatalogSchema

func _get_string(d: Dictionary, key: String, def: String = "") -> String:
	var v: Variant = d.get(key, def)
	return String(v) if typeof(v) == TYPE_STRING else def

func _get_int(d: Dictionary, key: String, def: int = 0) -> int:
	return int(d.get(key, def))

func _collect_ability_groups(e: Dictionary) -> Array[String]:
	var out: Array[String] = []
	var ag_v: Variant = e.get("ability_groups", [])
	if typeof(ag_v) == TYPE_ARRAY:
		for a in (ag_v as Array):
			if typeof(a) == TYPE_STRING:
				out.append(String(a))
	return out

# Accept either "assets" or legacy "tile"; normalize as "assets"
func _collect_assets(e: Dictionary) -> Dictionary:
	var assets: Dictionary = {}
	var av: Variant = e.get("assets", e.get("tile", {}))
	if typeof(av) == TYPE_DICTIONARY:
		var ad: Dictionary = av
		var prefab: String = _get_string(ad, "prefab", "")
		var path: String = _get_string(ad, "path", "")
		if prefab != "":
			assets["prefab"] = prefab
		# Accept engine paths only; note project uses "res://assests/..." (intentional)
		if path.begins_with("res://"):
			assets["path"] = path
	return assets

# ---- Sanitizers for base_effect ----

func _as_number_array(a: Array) -> Array[float]:
	var out: Array[float] = []
	for e in a:
		var t := typeof(e)
		if t == TYPE_INT or t == TYPE_FLOAT:
			out.append(float(e))
		else:
			# Non-number found → treat as invalid numeric array
			return []
	return out

func _as_string_array(a: Array) -> Array[String]:
	var out: Array[String] = []
	for e in a:
		if typeof(e) == TYPE_STRING:
			out.append(String(e))
		else:
			return []
	return out

# Only allow: bool/int/float/string; arrays of numbers/strings; and
# shallow dicts whose values are recursively sanitized by the same rule.
func _sanitize_value(v: Variant) -> Variant:
	var t := typeof(v)
	if t == TYPE_BOOL or t == TYPE_INT or t == TYPE_FLOAT or t == TYPE_STRING:
		return v
	if t == TYPE_ARRAY:
		var arr: Array = v
		# Prefer numeric arrays when all are numbers, otherwise string arrays when all are strings.
		var nums: Array[float] = _as_number_array(arr)
		if nums.size() == arr.size():
			return nums
		var strs: Array[String] = _as_string_array(arr)
		if strs.size() == arr.size():
			return strs
		# Mixed/unsupported arrays are rejected
		return null
	if t == TYPE_DICTIONARY:
		var d_in: Dictionary = v
		var d_out: Dictionary = {}
		for k in d_in.keys():
			var key_s: String = String(k)
			var sv: Variant = _sanitize_value(d_in[k])
			if sv == null:
				continue
			d_out[key_s] = sv
		return d_out
	# Everything else rejected
	return null

func _collect_base_effect(e: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	var be_v: Variant = e.get("base_effect", {})
	if typeof(be_v) != TYPE_DICTIONARY:
		return out
	var be: Dictionary = be_v
	for rkey in be.keys():
		var tier_v: Variant = be.get(rkey, {})
		if typeof(tier_v) != TYPE_DICTIONARY:
			continue
		var tier_in: Dictionary = tier_v
		var tier_out: Dictionary = {}
		for k in tier_in.keys():
			var sv: Variant = _sanitize_value(tier_in[k])
			if sv == null:
				continue
			tier_out[String(k)] = sv
		out[String(rkey)] = tier_out
	return out

func _collect_rarity_unlocks(e: Dictionary) -> Dictionary:
	var ru: Dictionary = {}
	var ru_v: Variant = e.get("rarity_unlocks", {})
	if typeof(ru_v) == TYPE_DICTIONARY:
		for rkey in (ru_v as Dictionary).keys():
			var step_v: Variant = (ru_v as Dictionary).get(rkey, {})
			if typeof(step_v) == TYPE_DICTIONARY:
				var step: Dictionary = step_v
				var gold: int = _get_int(step, "gold", 0)
				var shards: int = _get_int(step, "shards", 0)
				var quest: String = _get_string(step, "quest", "")
				ru[String(rkey)] = {"gold": gold, "shards": shards, "quest": quest}
	return ru

func validate(input: Dictionary) -> Dictionary:
	var out: Dictionary = {"entries": {}}
	var entries_v: Variant = input.get("entries", {})
	if typeof(entries_v) != TYPE_DICTIONARY:
		return out

	var entries: Dictionary = entries_v
	var clean: Dictionary = {}

	for key in entries.keys():
		var k: String = String(key)
		var e_v: Variant = entries.get(k, {})
		if typeof(e_v) != TYPE_DICTIONARY:
			continue
		var e: Dictionary = e_v

		var id: String = _get_string(e, "id", k)

		var group: StringName = StringName(String(e.get("group", "core")).to_lower())
		if not VillageSchema.BUILDING_GROUPS.has(group):
			group = &"core"

		var name: String = _get_string(e, "name", "")

		var ability_groups: Array[String] = _collect_ability_groups(e)

		var role_req: StringName = StringName(String(e.get("role_required", "")).to_upper())
		if role_req != StringName("") and not StaffingService.has_role(role_req):
			role_req = StringName("")

		var placement_cost: Dictionary = {"gold": 0, "shards": 0}
		var pc_v: Variant = e.get("placement_cost", {})
		if typeof(pc_v) == TYPE_DICTIONARY:
			var pc: Dictionary = pc_v
			placement_cost["gold"] = _get_int(pc, "gold", 0)
			placement_cost["shards"] = _get_int(pc, "shards", 0)

		var rarity_unlocks: Dictionary = _collect_rarity_unlocks(e)
		var assets: Dictionary = _collect_assets(e)
		var base_effect: Dictionary = _collect_base_effect(e)
		var family: String = _get_string(e, "family", "")

		clean[id] = {
			"id": id,
			"group": String(group),
			"name": name,
			"ability_groups": ability_groups,
			"role_required": String(role_req),
			"placement_cost": placement_cost,
			"rarity_unlocks": rarity_unlocks,
			"assets": assets,          # canonical key
			"base_effect": base_effect,
			"family": family
		}

	out["entries"] = clean
	return out
