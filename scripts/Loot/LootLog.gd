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
	var parts := PackedStringArray()

	var src: String = String(loot.get("source",""))
	if src == "common_chest" or src == "rare_chest":
		var default_chest: String = "common"
		if src == "rare_chest":
			default_chest = "rare"
		var chest: String = String(loot.get("chest_level", default_chest))
		parts.append("Chest=" + chest.capitalize())
	else:
		parts.append("Source=" + src)

	var r: String = String(loot.get("rarity","U"))
	var cat: String = String(loot.get("category",""))
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

static func print_encounter_victory(source: String, floor_i: int, enemy_name: String, ctx: Dictionary) -> void:
	var loot: Dictionary = LootSystem.roll_loot(source, floor_i, ctx)
	var line: String = "[VictoryLoot][" + source.capitalize() + "] F" + str(floor_i) + " vs " + enemy_name + " ⇒ " + _loot_summary(loot)
	print(line)

static func print_chest_open(chest_level: String, floor_i: int, world_pos: Vector3, ctx: Dictionary) -> void:
	var source: String = "common_chest"
	if chest_level == "rare":
		source = "rare_chest"
	ctx["chest_level"] = chest_level
	var loot: Dictionary = LootSystem.roll_loot(source, floor_i, ctx)
	var line: String = "[Loot][ChestOpen] F" + str(floor_i) + " @" + str(world_pos) + " ⇒ " + _loot_summary(loot)
	print(line)
