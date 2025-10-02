# res://persistence/schemas/village_schema.gd
extends RefCounted
class_name VillageSchema

const _S := preload("res://persistence/util/save_utils.gd")

static func _trainer_ids() -> Array[String]:
	return [
		"trainer_spear","trainer_sword","trainer_mace","trainer_bow",
		"trainer_light","trainer_dark","trainer_wind","trainer_fire",
		"trainer_earth","trainer_water","trainer_defense"
	]

static func defaults() -> Dictionary:
	var services := {
		"inn": 0, "blacksmith": 0, "alchemist": 0,
		"library": 0, "trainer": 0, "temple": 0, "guild": 0
	}
	# Add all trainers at level 0 in services
	for tid in _trainer_ids():
		services[tid] = 0

	var unlocked := {
		"camp": true,
		"entrance": true,
		"farms": false, "trade": false, "housing": false,
		"inn": false, "blacksmith": false, "alchemist": false,
		"library": false, "trainer": false, "temple": false, "guild": false
	}
	# Include trainer keys in unlocked map (all start locked)
	for tid in _trainer_ids():
		unlocked[tid] = false

	return {
		"schema_version": 2,
		"camp_level": 0,          # kept for backward compatibility
		"seed_epoch": 1,
		"buildings": {
			"rts": { "farms": 0, "trade": 0, "housing": 0 },
			"services": services
		},
		"unlocked": unlocked      # string->bool map for O(1) lookups
	}

static func migrate_into(meta_in: Dictionary) -> Dictionary:
	var meta: Dictionary = _S.to_dict(meta_in)
	var v: Dictionary = _S.to_dict(meta.get("village", {}))
	if v.is_empty():
		v = defaults()
		meta["village"] = v
		return meta

	# --- Version/fields ---
	v["schema_version"] = 2

	# Backfill new structure without breaking existing camp_level/seed_epoch
	if not v.has("buildings") or not (v["buildings"] is Dictionary):
		v["buildings"] = defaults()["buildings"]
	else:
		var b: Dictionary = _S.to_dict(v["buildings"])
		if not b.has("rts"): b["rts"] = defaults()["buildings"]["rts"]
		if not b.has("services"): b["services"] = defaults()["buildings"]["services"]
		else:
			# Ensure all trainer service keys exist at 0
			var svc: Dictionary = _S.to_dict(b["services"])
			for tid in _trainer_ids():
				if not svc.has(tid): svc[tid] = 0
			b["services"] = svc
		v["buildings"] = b

	# Unlocked map backfill
	if not v.has("unlocked") or not (v["unlocked"] is Dictionary):
		v["unlocked"] = defaults()["unlocked"]
	else:
		var u: Dictionary = _S.to_dict(v["unlocked"])
		# Ensure camp/entrance stay unlocked by default
		u["camp"] = bool(_S.dget(u, "camp", true))
		u["entrance"] = bool(_S.dget(u, "entrance", true))

		# Ensure keys exist for all known buildings
		for key in [
			"farms","trade","housing",
			"inn","blacksmith","alchemist","library","trainer","temple","guild"
		]:
			if not u.has(key): u[key] = false
		for tid in _trainer_ids():
			if not u.has(tid): u[tid] = false

		v["unlocked"] = u

	# Normalize camp/seed
	v["camp_level"] = max(0, int(_S.dget(v, "camp_level", 0)))
	v["seed_epoch"] = max(1, int(_S.dget(v, "seed_epoch", 1)))

	meta["village"] = v
	return meta
