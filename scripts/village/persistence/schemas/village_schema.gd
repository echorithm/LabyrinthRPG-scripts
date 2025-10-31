# File: res://persistence/schemas/village_schema.gd
extends RefCounted
class_name VillageSchema

## Godot 4.5 strict typing. Validates village.json against ADR-014.

const SCHEMA_VERSION: int = 1

# --- Enums / constants -----------------------------------------------------
const TILE_KINDS: PackedStringArray = [
	"wild", "camp_core", "labyrinth"
]

const BUILDING_GROUPS: PackedStringArray = [
	"core", "rts", "service", "trainer"
]

const ROLES: PackedStringArray = [
	"INNKEEPER", "ARTISAN_BLACKSMITH", "ARTISAN_ALCHEMIST", "ARTISAN_SCRIBE",
	"CLERGY", "ADMIN",
	"TRAINER_SWORD", "TRAINER_SPEAR", "TRAINER_MACE", "TRAINER_RANGE",
	"TRAINER_SUPPORT", "TRAINER_FIRE", "TRAINER_WATER", "TRAINER_WIND",
	"TRAINER_EARTH", "TRAINER_LIGHT", "TRAINER_DARK"
]

const RARITIES: PackedStringArray = [
	"COMMON","UNCOMMON","RARE","EPIC","ANCIENT","LEGENDARY","MYTHIC"
]

const NPC_STATES: PackedStringArray = ["IDLE","STAFFED","DEAD"]

# --- Public API ------------------------------------------------------------
func validate_village(d: Dictionary) -> PackedStringArray:
	var errors: PackedStringArray = PackedStringArray()

	_require_keys(
		d,
		PackedStringArray(["schema_version","seed","grid","buildings","staffing","quests","guild","economy"]),
		errors,
		"."
	)

	if d.has("schema_version") and int(d["schema_version"]) != SCHEMA_VERSION:
		errors.append("schema_version unsupported: %s (expected %s)" % [str(d["schema_version"]), str(SCHEMA_VERSION)])

	if d.has("seed") and typeof(d["seed"]) != TYPE_INT:
		errors.append("seed must be int")

	if d.has("grid"):
		_validate_grid(d["grid"] as Dictionary, errors, ".grid")

	if d.has("buildings"):
		if typeof(d["buildings"]) != TYPE_ARRAY:
			errors.append(".buildings must be Array")
		else:
			var arr: Array = d["buildings"] as Array
			for i in range(arr.size()):
				var b_v: Variant = arr[i]
				if typeof(b_v) != TYPE_DICTIONARY:
					errors.append(".buildings[%d] must be Dictionary" % i)
				else:
					_validate_building_instance(b_v as Dictionary, errors, ".buildings[%d]" % i)

	if d.has("staffing"):
		_validate_staffing(d["staffing"] as Dictionary, errors, ".staffing")

	if d.has("quests"):
		_validate_quests(d["quests"] as Dictionary, errors, ".quests")

	if d.has("guild"):
		_validate_guild(d["guild"] as Dictionary, errors, ".guild")

	if d.has("economy"):
		_validate_economy(d["economy"] as Dictionary, errors, ".economy")

	return errors

# --- Section validators ----------------------------------------------------
func _validate_grid(g: Dictionary, errors: PackedStringArray, path: String) -> void:
	_require_keys(g, PackedStringArray(["radius","tiles"]), errors, path)
	if g.has("radius") and (typeof(g["radius"]) != TYPE_INT or int(g["radius"]) <= 0):
		errors.append("%s.radius must be positive int" % path)
	if g.has("tiles"):
		if typeof(g["tiles"]) != TYPE_ARRAY:
			errors.append("%s.tiles must be Array" % path)
		else:
			var tiles: Array = g["tiles"] as Array
			for i in range(tiles.size()):
				var t_v: Variant = tiles[i]
				var tpath: String = "%s.tiles[%d]" % [path, i]
				if typeof(t_v) != TYPE_DICTIONARY:
					errors.append("%s must be Dictionary" % tpath)
				else:
					var t: Dictionary = t_v
					_require_keys(t, PackedStringArray(["q","r","kind"]), errors, tpath)
					if t.has("q") and typeof(t["q"]) != TYPE_INT:
						errors.append("%s.q must be int" % tpath)
					if t.has("r") and typeof(t["r"]) != TYPE_INT:
						errors.append("%s.r must be int" % tpath)
					if t.has("kind") and not TILE_KINDS.has(String(t["kind"])):
						errors.append("%s.kind invalid: %s" % [tpath, String(t["kind"])])
					var k: String = String(t.get("kind",""))
					if k == "building" or k == "camp" or k == "entrance":
						if not t.has("instance_id"):
							errors.append("%s.instance_id required for kind=%s" % [tpath, k])

func _validate_building_instance(b: Dictionary, errors: PackedStringArray, path: String) -> void:
	_require_keys(b, PackedStringArray(["instance_id","id","rarity","active","connected_to_camp","staff"]), errors, path)
	if b.has("rarity") and not RARITIES.has(String(b["rarity"])):
		errors.append("%s.rarity invalid: %s" % [path, String(b["rarity"])])
	if b.has("active") and typeof(b["active"]) != TYPE_BOOL:
		errors.append("%s.active must be bool" % path)
	if b.has("connected_to_camp") and typeof(b["connected_to_camp"]) != TYPE_BOOL:
		errors.append("%s.connected_to_camp must be bool" % path)
	if b.has("staff"):
		var s_v: Variant = b["staff"]
		if typeof(s_v) != TYPE_DICTIONARY:
			errors.append("%s.staff must be Dictionary" % path)
		else:
			var s: Dictionary = s_v
			var has_id: bool = s.has("npc_id")
			if has_id:
				var id_v: Variant = s["npc_id"]
				var id_type: int = typeof(id_v)
				if id_type != TYPE_STRING and id_type != TYPE_NIL:
					errors.append("%s.staff.npc_id must be String or null" % path)
			if s.has("since_ts") and typeof(s["since_ts"]) != TYPE_INT:
				errors.append("%s.staff.since_ts must be int unix ts" % path)

func _validate_staffing(s: Dictionary, errors: PackedStringArray, path: String) -> void:
	_require_keys(s, PackedStringArray(["npcs","population_cap"]), errors, path)
	if s.has("population_cap") and (typeof(s["population_cap"]) != TYPE_INT or int(s["population_cap"]) < 0):
		errors.append("%s.population_cap must be >= 0" % path)
	if s.has("npcs"):
		if typeof(s["npcs"]) != TYPE_ARRAY:
			errors.append("%s.npcs must be Array" % path)
		else:
			var npcs: Array = s["npcs"] as Array
			for i in range(npcs.size()):
				var n_v: Variant = npcs[i]
				var npath: String = "%s.npcs[%d]" % [path, i]
				if typeof(n_v) != TYPE_DICTIONARY:
					errors.append("%s must be Dictionary" % npath)
				else:
					var n: Dictionary = n_v
					_require_keys(n, PackedStringArray(["id","name","role","level","rarity","fatigue","injury_cooldown","state"]), errors, npath)
					var role_val: String = String(n.get("role",""))
					if role_val != "" and not ROLES.has(role_val):
						errors.append("%s.role invalid: %s" % [npath, role_val])
					if not RARITIES.has(String(n.get("rarity",""))):
						errors.append("%s.rarity invalid" % npath)
					if not NPC_STATES.has(String(n.get("state",""))):
						errors.append("%s.state invalid" % npath)

func _validate_quests(q: Dictionary, errors: PackedStringArray, path: String) -> void:
	if q.has("active") and typeof(q["active"]) != TYPE_ARRAY:
		errors.append("%s.active must be Array" % path)
	if q.has("completed") and typeof(q["completed"]) != TYPE_ARRAY:
		errors.append("%s.completed must be Array" % path)

func _validate_guild(g: Dictionary, errors: PackedStringArray, path: String) -> void:
	_require_keys(g, PackedStringArray(["contracts","weekly_slivers","last_reset_ts"]), errors, path)
	if g.has("weekly_slivers") and (typeof(g["weekly_slivers"]) != TYPE_INT or int(g["weekly_slivers"]) < 0):
		errors.append("%s.weekly_slivers must be >= 0" % path)
	if g.has("last_reset_ts") and typeof(g["last_reset_ts"]) != TYPE_INT:
		errors.append("%s.last_reset_ts must be int" % path)

func _validate_economy(e: Dictionary, errors: PackedStringArray, path: String) -> void:
	_require_keys(e, PackedStringArray(["roads_built","bridges_built","gold_spent","shards_spent"]), errors, path)
	for k in ["roads_built","bridges_built","gold_spent","shards_spent"]:
		if e.has(k) and (typeof(e[k]) != TYPE_INT or int(e[k]) < 0):
			errors.append("%s.%s must be >= 0" % [path, k])

# --- Helpers ---------------------------------------------------------------
func _require_keys(obj: Dictionary, keys: PackedStringArray, errors: PackedStringArray, path: String) -> void:
	for k in keys:
		if not obj.has(k):
			errors.append("%s missing key: %s" % [path, k])
