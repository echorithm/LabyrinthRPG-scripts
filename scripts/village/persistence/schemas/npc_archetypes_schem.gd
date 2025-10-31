# Godot 4.5 — Validates & normalizes npc_archetypes.json
# Input shape:
# {
#   "schema_version": 1,
#   "roles": { "<ROLE>": { "spawn_weight": int>=0, "name_pool": String, "wage_base": int>=0 }, ... },
#   "name_pools": { "<POOL_KEY>": [ "Name", ... ], ... }
#   # Optional/misc fields (ignored by this schema): "portrait_path", comments, etc.
# }
extends RefCounted
class_name NPCArchetypesSchema

static func _get_int(d: Dictionary, key: String, def: int = 0) -> int:
	return int(d.get(key, def))

static func _get_string(d: Dictionary, key: String, def: String = "") -> String:
	var v: Variant = d.get(key, def)
	if typeof(v) == TYPE_STRING:
		return String(v)
	return def

static func _collect_name_pool(arr_v: Variant) -> Array[String]:
	var out: Array[String] = []
	if typeof(arr_v) != TYPE_ARRAY:
		return out
	for n in (arr_v as Array):
		if typeof(n) == TYPE_STRING:
			var s := String(n)
			if s.length() > 0 and not out.has(s):
				out.append(s)
	return out

static func collect_errors(input: Dictionary) -> PackedStringArray:
	var errs: PackedStringArray = []

	# root fields
	if input.get("schema_version", 0) != 1:
		errs.append("schema_version must be 1")

	var roles_v: Variant = input.get("roles", {})
	if typeof(roles_v) != TYPE_DICTIONARY or (roles_v as Dictionary).is_empty():
		errs.append("'roles' must be a non-empty object")

	var pools_v: Variant = input.get("name_pools", {})
	if typeof(pools_v) != TYPE_DICTIONARY or (pools_v as Dictionary).is_empty():
		errs.append("'name_pools' must be a non-empty object")

	# pool contents
	if typeof(pools_v) == TYPE_DICTIONARY:
		var pools: Dictionary = pools_v
		for pk in pools.keys():
			var list_str: Array[String] = _collect_name_pool(pools[pk])
			if list_str.is_empty():
				errs.append("name_pools.%s must be a non-empty array of strings" % String(pk))

	# roles + cross-ref to pools
	if typeof(roles_v) == TYPE_DICTIONARY and typeof(pools_v) == TYPE_DICTIONARY:
		var roles: Dictionary = roles_v
		var pools: Dictionary = pools_v
		for r in roles.keys():
			var cfg_v: Variant = roles.get(r, {})
			if typeof(cfg_v) != TYPE_DICTIONARY:
				errs.append("roles.%s must be an object" % String(r))
				continue
			var cfg: Dictionary = cfg_v
			var sw: int = _get_int(cfg, "spawn_weight", -1)
			if sw < 0:
				errs.append("roles.%s.spawn_weight must be >= 0" % String(r))
			var wb: int = _get_int(cfg, "wage_base", -1)
			if wb < 0:
				errs.append("roles.%s.wage_base must be >= 0" % String(r))
			var pool_key: String = _get_string(cfg, "name_pool", "")
			if pool_key == "":
				errs.append("roles.%s.name_pool must be a non-empty string" % String(r))
			elif not pools.has(pool_key):
				errs.append("roles.%s.name_pool '%s' not found in name_pools" % [String(r), pool_key])

	return errs

# Returns a cleaned dictionary with normalized types and de-duplicated name lists.
static func validate(input: Dictionary) -> Dictionary:
	var clean: Dictionary = {
		"schema_version": 1,
		"roles": {},
		"name_pools": {}
	}

	# name_pools first (so roles can be cross-checked)
	var pools_out: Dictionary = {}
	var pools_v: Variant = input.get("name_pools", {})
	if typeof(pools_v) == TYPE_DICTIONARY:
		for pk in (pools_v as Dictionary).keys():
			var key_str := String(pk)
			var names: Array[String] = _collect_name_pool((pools_v as Dictionary).get(pk, []))
			if not names.is_empty():
				pools_out[key_str] = names
	clean["name_pools"] = pools_out

	# roles
	var roles_out: Dictionary = {}
	var roles_v: Variant = input.get("roles", {})
	if typeof(roles_v) == TYPE_DICTIONARY:
		for rk in (roles_v as Dictionary).keys():
			var rkey := String(rk)
			var cfg_v: Variant = (roles_v as Dictionary).get(rk, {})
			if typeof(cfg_v) != TYPE_DICTIONARY:
				continue
			var cfg: Dictionary = cfg_v
			var role_clean: Dictionary = {}
			var spawn_weight := _get_int(cfg, "spawn_weight", 0)
			if spawn_weight < 0:
				spawn_weight = 0
			var wage_base := _get_int(cfg, "wage_base", 0)
			if wage_base < 0:
				wage_base = 0
			var pool_key := _get_string(cfg, "name_pool", "")
			role_clean["spawn_weight"] = spawn_weight
			role_clean["wage_base"] = wage_base
			role_clean["name_pool"] = pool_key
			roles_out[rkey] = role_clean
	clean["roles"] = roles_out

	return clean
