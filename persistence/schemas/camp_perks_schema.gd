# File: res://persistence/schemas/camp_perks_schema.gd
# Godot 4.5 — Validates camp_perks.json and maps names to rarities

class_name CampPerksSchema

# Expected:
# {
#   "tiers": [
#     {"rarity": "COMMON", "name": "Camp",  "perks": {...}},
#     {"rarity": "UNCOMMON", "name": "Home", "perks": {...}},
#     ...
#   ]
# }

func validate(input: Dictionary) -> Dictionary:
	var tiers_out: Array[Dictionary] = []
	var tiers_v: Variant = input.get("tiers", [])
	if typeof(tiers_v) == TYPE_ARRAY:
		for v in (tiers_v as Array):
			if typeof(v) != TYPE_DICTIONARY:
				continue
			var rarity: StringName = StringName(String((v as Dictionary).get("rarity", "COMMON")).to_upper())
			if not VillageSchema.RARITIES.has(rarity):
				rarity = &"COMMON"
			var name: String = String((v as Dictionary).get("name", ""))
			var perks_v: Variant = (v as Dictionary).get("perks", {})
			var perks: Dictionary = {}
			if typeof(perks_v) == TYPE_DICTIONARY:
				perks = perks_v
			tiers_out.append({
				"rarity": String(rarity),
				"name": name,
				"perks": perks
			})
	return {"tiers": tiers_out}
