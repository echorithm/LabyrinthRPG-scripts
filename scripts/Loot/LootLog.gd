extends Node
class_name LootLog

const RARE_CHAR: String = "★"

static func _rarity_mark(r: String) -> String:
	match r:
		"C": return "C"
		"U": return "U"
		"R": return "R" + RARE_CHAR
		"E": return "E" + RARE_CHAR
		"A": return "A" + RARE_CHAR
		"L": return "L" + RARE_CHAR
		"M": return "M" + RARE_CHAR
		_:   return r

static func _loot_summary(loot: Dictionary) -> String:
	var parts: PackedStringArray = PackedStringArray()

	var src: String = String(loot.get("source", ""))
	if src == "chest":
		parts.append("Chest=Chest")
	else:
		parts.append("Source=" + src)

	var r: String = String(loot.get("rarity", "U"))
	var cat: String = String(loot.get("category", ""))
	if cat != "":
		parts.append("Drop=" + _rarity_mark(r) + " " + cat)
	else:
		parts.append("Drop=" + _rarity_mark(r))

	var g: int = int(loot.get("gold", 0))
	var s: int = int(loot.get("shards", 0))
	if g > 0:
		parts.append(str(g) + "g")
	if s > 0:
		parts.append(str(s) + " shards")

	if bool(loot.get("pity_used", false)):
		parts.append("pity↑")
	if bool(loot.get("post_boss_shift_applied", false)):
		parts.append("shift↑")

	return String(", ").join(parts)

# Print using what was actually granted (receipt).
static func print_encounter_victory_from_grant(
	source: String,
	floor_i: int,
	enemy_name: String,
	loot_ctx: Dictionary,   # rarity/category/flags decided by generator
	receipt: Dictionary     # returned by RewardService.grant() or Orchestrator.grant_from_loot()
) -> void:
	var merged: Dictionary = {
		"source": source,
		"floor": floor_i,
		"rarity": String(loot_ctx.get("rarity", "U")),
		"category": String(loot_ctx.get("category", "")),
		"gold": int(receipt.get("gold", 0)),
		"shards": int(receipt.get("shards", 0)),
		"pity_used": bool(loot_ctx.get("pity_used", false)),
		"post_boss_shift_applied": bool(loot_ctx.get("post_boss_shift_applied", false)),
	}
	var line: String = "[VictoryLoot][" + source.capitalize() + "] F" + str(floor_i) + " vs " + enemy_name + " ⇒ " + _loot_summary(merged)
	print(line)

# Deprecated logger (kept for compatibility)
static func print_encounter_victory(source: String, floor_i: int, enemy_name: String, _ctx: Dictionary) -> void:
	var src_cap: String = String(source).capitalize()
	var line: String = "[VictoryLoot][" + src_cap + "] F" + str(floor_i) + " vs " + enemy_name
	print(line)

static func print_chest_open(_chest_level: String, _floor_i: int, _world_pos: Vector3, _ctx: Dictionary) -> void:
	pass
