# File: res://persistence/services/quest_gate_service.gd
# Godot 4.5 — Strict typing; rarity upgrade gating via quest flags

class_name QuestGateService

## Catalog rarity_unlocks example:
## {
##   "UNCOMMON": {"gold": 100},
##   "RARE": {"gold": 200, "shards": 1, "quest": "q_blacksmith_unlocked"},
##   "EPIC": {"gold": 300, "shards": 2, "quest": "q_church_sanctified"}
## }

static func has_flag(flags: Array[String], flag: String) -> bool:
	for f in flags:
		if f == flag:
			return true
	return false


static func quest_id_for_rarity(rarity_unlocks: Dictionary, to_rarity: StringName) -> String:
	var key := String(to_rarity)
	if not rarity_unlocks.has(key):
		return ""
	var step: Variant = rarity_unlocks.get(key)
	if typeof(step) != TYPE_DICTIONARY:
		return ""
	return String(step.get("quest", ""))


static func can_upgrade(flags: Array[String], rarity_unlocks: Dictionary, to_rarity: StringName) -> bool:
	var qid: String = quest_id_for_rarity(rarity_unlocks, to_rarity)
	if qid == "":
		# No quest requirement for this tier
		return true
	return has_flag(flags, qid)
