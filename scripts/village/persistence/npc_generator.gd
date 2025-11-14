# Godot 4.5 — NPC generator
# • Roleful generation (legacy) still supported using npc_archetypes.json
# • MVP recruitment is role-agnostic and uses res://data/village/recruitment_names.json
extends RefCounted
class_name NPCGenerator

const _S := preload("res://persistence/util/save_utils.gd")
const _InstSchema := preload("res://scripts/village/persistence/schemas/npc_instance_schema.gd")

# Keep in sync with StaffingService roles (used for roleful generation only).
const ROLES: Array[String] = [
	"INNKEEPER","ARTISAN_BLACKSMITH","ARTISAN_ALCHEMIST","ARTISAN_SCRIBE","CLERGY","ADMIN",
	"TRAINER_SWORD","TRAINER_SPEAR","TRAINER_MACE","TRAINER_RANGE","TRAINER_SUPPORT",
	"TRAINER_FIRE","TRAINER_WATER","TRAINER_WIND","TRAINER_EARTH","TRAINER_LIGHT","TRAINER_DARK"
]

# Recruitment names file (version "1.0")
const RECRUITMENT_NAMES_PATH := "res://data/village/recruitment_names.json"

# --- debug toggle ------------------------------------------------------------
static var DEBUG: bool = true
static func _dbg(msg: String) -> void:
	if DEBUG:
		print("[NPCGen] " + msg)

# ----------------------- shared helpers --------------------------------------
static func rarity_from_level(level: int) -> String:
	var bands: Array[String] = ["COMMON","UNCOMMON","RARE","EPIC","ANCIENT","LEGENDARY","MYTHIC"]
	if level <= 0:
		return "COMMON"
	var idx := int((level - 1) / 10)
	if idx < bands.size():
		return bands[idx]
	var overflow := idx - (bands.size() - 1)
	return "MYTHICx%d" % overflow

static func _choose_name(pool: Array[String], rng: RandomNumberGenerator) -> String:
	if pool.is_empty():
		return "Nameless"
	var i := rng.randi_range(0, max(0, pool.size() - 1))
	return pool[i]

static func _wage_for(level: int, wage_base: int) -> int:
	var bump := int(level / 10)
	return max(0, wage_base + bump)

static func _typed_string_array(a: Array) -> Array[String]:
	var out: Array[String] = []
	for v in a:
		if typeof(v) == TYPE_STRING:
			var s := String(v)
			if s.length() > 0:
				out.append(s)
	return out

# --------------------- archetypes (legacy roleful) ---------------------------
static func _read_archetypes(path: String) -> Dictionary:
	_dbg("read_archetypes path=" + path)
	var text := FileAccess.get_file_as_string(path)
	var parsed: Variant = JSON.parse_string(text)
	var d: Dictionary = _S.to_dict(parsed)
	var roles_v: Variant = d.get("roles", {})
	var pools_v: Variant = d.get("name_pools", {})
	_dbg("archetypes: roles=%d pools=%d" %
		[int((roles_v as Dictionary).size()) if roles_v is Dictionary else 0,
		 int((pools_v as Dictionary).size()) if pools_v is Dictionary else 0])
	return d

static func _names_for_pool(archetypes: Dictionary, key: String) -> Array[String]:
	var pools_v: Variant = archetypes.get("name_pools", {})
	if typeof(pools_v) != TYPE_DICTIONARY:
		return []
	var pools: Dictionary = pools_v
	if not pools.has(key):
		return []
	var arr_v: Variant = pools.get(key, [])
	var arr: Array = (arr_v as Array) if arr_v is Array else []
	return _typed_string_array(arr)

static func _role_cfg(archetypes: Dictionary, role: String) -> Dictionary:
	var roles_v: Variant = archetypes.get("roles", {})
	if typeof(roles_v) != TYPE_DICTIONARY:
		return {}
	var roles: Dictionary = roles_v
	if roles.has(role) and roles.get(role) is Dictionary:
		return (roles.get(role, {}) as Dictionary)
	return {}

# --------------------- roleful generation (legacy) ---------------------------
static func generate_one_from(archetypes: Dictionary, role: String, level: int, rng: RandomNumberGenerator) -> Dictionary:
	assert(ROLES.has(role))
	_dbg("generate_one role=%s level=%d" % [role, level])

	var cfg: Dictionary = _role_cfg(archetypes, role)
	var pool_key: String = String(cfg.get("name_pool", ""))
	var pool: Array[String] = _names_for_pool(archetypes, pool_key)
	var name: String = _choose_name(pool, rng)

	var wage_base := int(cfg.get("wage_base", 10))
	if wage_base < 0:
		wage_base = 0

	# Legacy roleful ID; preserved for systems that still expect it.
	var npc_id := "%s_%04X" % [role, int(rng.randi() & 0xFFFF)]
	_dbg("  picked name=%s pool=%s wage_base=%d id=%s" % [name, pool_key, wage_base, npc_id])

	var out: Dictionary = {
		"id": npc_id,
		"name": name,
		"role": role,
		"level": max(1, level),
		"xp_current": 0,
		"rarity": rarity_from_level(level),
		"fatigue": 0,
		"injury_cooldown": 0,
		"state": "IDLE",
		"appearance_seed": int(rng.randi()),
		"wage": _wage_for(level, wage_base),
		"race": "",
		"sex": "",
		"role_levels": {}
	}
	var norm := _InstSchema.validate(out)
	_dbg("  normalized rarity=%s wage=%d state=%s" %
		[String(norm.get("rarity","")), int(norm.get("wage",0)), String(norm.get("state",""))])
	return norm

static func generate_many_from(archetypes: Dictionary, role: String, levels: Array[int], seed: int) -> Array[Dictionary]:
	_dbg("generate_many role=%s count=%d seed=%d" % [role, levels.size(), seed])
	var rng := RandomNumberGenerator.new()
	rng.seed = int(seed)
	var out: Array[Dictionary] = []
	for lvl in levels:
		out.append(generate_one_from(archetypes, role, int(lvl), rng))
	_dbg("generate_many done -> %d" % out.size())
	return out

static func generate_weighted_pool(archetypes: Dictionary, total: int, seed: int) -> Array[Dictionary]:
	# Pulls by roles.*.spawn_weight, distributes until 'total'.
	_dbg("generate_weighted_pool total=%d seed=%d" % [total, seed])
	var roles_v: Variant = archetypes.get("roles", {})
	var out: Array[Dictionary] = []
	if typeof(roles_v) != TYPE_DICTIONARY or total <= 0:
		return out

	var rng := RandomNumberGenerator.new()
	rng.seed = int(seed)

	# Build weights
	var tickets: Array[String] = []
	for r in (roles_v as Dictionary).keys():
		var rkey := String(r)
		var cfg: Dictionary = (roles_v as Dictionary).get(rkey, {})
		var w := int(cfg.get("spawn_weight", 0))
		if w > 0 and ROLES.has(rkey):
			for i in w:
				tickets.append(rkey)
	_dbg("  tickets=%d" % tickets.size())

	if tickets.is_empty():
		return out

	for i in total:
		var role_idx := rng.randi_range(0, max(0, tickets.size() - 1))
		var role := tickets[role_idx]
		var lvl := 1 + int(rng.randi() % 20)  # legacy seed band; callers can post-edit
		out.append(generate_one_from(archetypes, role, lvl, rng))

	_dbg("generate_weighted_pool done -> %d" % out.size())
	return out

# --------------------- recruitment_names (MVP) -------------------------------
static func _dedupe_strings(arr: Array) -> Array[String]:
	var out: Array[String] = []
	for v in arr:
		if typeof(v) == TYPE_STRING:
			var s := String(v).strip_edges()
			if s.length() > 0 and not out.has(s):
				out.append(s)
	return out

static func _upper(s: String) -> String:
	if s == "":
		return s
	return s.to_upper()

static func _read_recruitment_names(path: String) -> Dictionary:
	# Expected shape (version "1.0"):
	# { "version":"1.0", "names": { "<race_lower>": { "male":[...], "female":[...] }, ... } }
	_dbg("read_recruitment_names path=" + path)
	var text := FileAccess.get_file_as_string(path)
	var parsed: Variant = JSON.parse_string(text)
	var raw: Dictionary = _S.to_dict(parsed)

	var out: Dictionary = {}           # { "version": String, "names": Dictionary }
	out["version"] = String(raw.get("version",""))
	var names_out: Dictionary = {}     # { RACE(upper): { "MALE":Array[String], "FEMALE":Array[String] } }

	var names_v: Variant = raw.get("names", {})
	if typeof(names_v) == TYPE_DICTIONARY:
		var names: Dictionary = names_v
		for race_k in names.keys():
			var race_key_upper := _upper(String(race_k))
			var genders_any: Variant = names.get(race_k, {})
			if typeof(genders_any) != TYPE_DICTIONARY:
				continue
			var genders: Dictionary = genders_any
			var male_any: Variant = genders.get("male", [])
			var female_any: Variant = genders.get("female", [])
			var male_arr: Array = (male_any as Array) if male_any is Array else []
			var female_arr: Array = (female_any as Array) if female_any is Array else []
			var male_names: Array[String] = _dedupe_strings(male_arr)
			var female_names: Array[String] = _dedupe_strings(female_arr)

			var per_race: Dictionary = {}
			per_race["MALE"] = male_names
			per_race["FEMALE"] = female_names
			names_out[race_key_upper] = per_race
	out["names"] = names_out

	# Quick stats
	_dbg("recruitment: races=%d" % int(names_out.size()))
	return out

# Deterministically pick a race from the normalized names map.
static func _pick_race_key(names_map: Dictionary, rng: RandomNumberGenerator) -> String:
	var keys: Array[String] = []
	for k in names_map.keys():
		keys.append(String(k))
	if keys.is_empty():
		return ""
	var i := rng.randi_range(0, max(0, keys.size() - 1))
	return keys[i]

static func _pick_sex(rng: RandomNumberGenerator) -> String:
	# Simple binary for MVP while enum is open.
	# 0 => "FEMALE", 1 => "MALE"
	var v := int(rng.randi() & 1)
	if v == 0:
		return "FEMALE"
	return "MALE"

static func _choose_name_from_bucket(names_map: Dictionary, race_key: String, sex_key: String, rng: RandomNumberGenerator) -> String:
	if not names_map.has(race_key):
		return "Nameless"
	var per_race_any: Variant = names_map.get(race_key, {})
	if typeof(per_race_any) != TYPE_DICTIONARY:
		return "Nameless"
	var per_race: Dictionary = per_race_any
	var pool_any: Variant = per_race.get(sex_key, [])
	var pool_arr: Array = (pool_any as Array) if pool_any is Array else []
	var pool: Array[String] = _typed_string_array(pool_arr)
	return _choose_name(pool, rng)

# --------------------- MVP recruitment (role-agnostic) -----------------------
# Create ONE candidate for Camp hiring using recruitment_names.json:
# - role-agnostic
# - id format: "npc_<hex>"
# - level = 1, wage = 0
# - rarity from level (COMMON)
# - race/sex from file
static func generate_hire_candidate_from_file(recruitment_file_path: String, rng: RandomNumberGenerator) -> Dictionary:
	var rec := _read_recruitment_names(recruitment_file_path)
	var names_map_any: Variant = rec.get("names", {})
	if typeof(names_map_any) != TYPE_DICTIONARY:
		# Fallback nameless candidate
		var fallback: Dictionary = {
			"id": "npc_%04X" % int(rng.randi() & 0xFFFF),
			"name": "Nameless",
			"role": "",
			"level": 1,
			"xp_current": 0,
			"rarity": rarity_from_level(1),
			"fatigue": 0,
			"injury_cooldown": 0,
			"state": "IDLE",
			"appearance_seed": int(rng.randi()),
			"wage": 0,
			"race": "",
			"sex": "FEMALE",
			"role_levels": {}
		}
		return _InstSchema.validate(fallback)

	var names_map: Dictionary = names_map_any
	var race := _pick_race_key(names_map, rng)
	var sex := _pick_sex(rng)
	var name := _choose_name_from_bucket(names_map, race, sex, rng)

	var npc_id := "npc_%04X" % int(rng.randi() & 0xFFFF)
	var out: Dictionary = {
		"id": npc_id,
		"name": name,
		"role": "",
		"level": 1,
		"xp_current": 0,
		"rarity": rarity_from_level(1),
		"fatigue": 0,
		"injury_cooldown": 0,
		"state": "IDLE",
		"appearance_seed": int(rng.randi()),
		"wage": 0,
		"race": race,
		"sex": sex,
		"role_levels": {}
	}
	return _InstSchema.validate(out)

# Deterministic hire page using recruitment_names.json.
# page_seed should be derived by the caller from (village_seed, recruitment.cursor).
static func generate_hire_page_from_file(recruitment_file_path: String, total: int, page_seed: int) -> Array[Dictionary]:
	_dbg("generate_hire_page_from_file total=%d seed=%d" % [total, page_seed])
	var out: Array[Dictionary] = []
	if total <= 0:
		return out
	var rng := RandomNumberGenerator.new()
	rng.seed = int(page_seed)

	# Ensure unique names within the page (player-facing nicety).
	var used_names: Array[String] = []

	for i in total:
		var attempt: int = 0
		var candidate: Dictionary = generate_hire_candidate_from_file(recruitment_file_path, rng)
		var candidate_name := String(candidate.get("name","Nameless"))

		# Simple re-pick loop to avoid duplicates within page.
		while used_names.has(candidate_name) and attempt < 8:
			attempt += 1
			candidate = generate_hire_candidate_from_file(recruitment_file_path, rng)
			candidate_name = String(candidate.get("name","Nameless"))

		used_names.append(candidate_name)
		out.append(candidate)
	

	_dbg("generate_hire_page_from_file done -> %d" % out.size())
	return out

# Convenience wrappers using the default path constant.
static func generate_hire_candidate(rng: RandomNumberGenerator) -> Dictionary:
	return generate_hire_candidate_from_file(RECRUITMENT_NAMES_PATH, rng)

static func generate_hire_page(total: int, page_seed: int) -> Array[Dictionary]:
	return generate_hire_page_from_file(RECRUITMENT_NAMES_PATH, total, page_seed)
