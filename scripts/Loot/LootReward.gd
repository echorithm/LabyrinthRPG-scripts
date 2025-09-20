extends Node


# ---- Internal helpers (instance methods) ----
func _current_floor() -> int:
	var lm: Node = get_node_or_null(^"/root/LevelManager")
	if lm == null:
		return 1
	# Try a method first, then a property
	if lm.has_method("get_current_floor"):
		return int(lm.call("get_current_floor"))
	elif lm.has_method("get"):
		var v: Variant = lm.get("_current_floor")
		return int(v)
	return 1

func _get_rare_chest_pity() -> int:
	var sm: Node = get_node_or_null(^"/root/SaveManager")
	if sm == null:
		return 0
	if sm.has_meta("rare_chest_pity"):
		return int(sm.get_meta("rare_chest_pity"))
	return 0

func _set_rare_chest_pity(v: int) -> void:
	var sm: Node = get_node_or_null(^"/root/SaveManager")
	if sm == null:
		return
	sm.set_meta("rare_chest_pity", v)

# ---- Public API (instance methods; call as LootReward.encounter_victory/ chest_open) ----

# Print victory loot for encounters (trash / elite / boss). Returns loot dict.
func encounter_victory(source: String, floor_i: int, enemy_name: String, rng_seed: int, post_boss_shift_left: int = 0) -> Dictionary:
	var ctx: Dictionary = {
		"rng_seed": rng_seed,
		"post_boss_encounters_left": post_boss_shift_left
	}
	var loot: Dictionary = LootSystem.roll_loot(source, floor_i, ctx)
	LootLog.print_encounter_victory(source, floor_i, enemy_name, ctx)
	return loot

# Print loot for treasure chests. chest_level: "common" | "rare". Returns loot dict.
func chest_open(chest_level: String, world_pos: Vector3, rng_seed: int = 0) -> Dictionary:
	var floor_i: int = _current_floor()
	var ctx: Dictionary = {
		"rng_seed": rng_seed,
		"chest_level": chest_level
	}
	if rng_seed == 0:
		ctx["rng_seed"] = randi()

	if chest_level == "rare":
		ctx["rare_chest_pity"] = _get_rare_chest_pity()

	var source: String = "common_chest"
	if chest_level == "rare":
		source = "rare_chest"

	var loot: Dictionary = LootSystem.roll_loot(source, floor_i, ctx)
	LootLog.print_chest_open(chest_level, floor_i, world_pos, ctx)

	# Maintain pity for rare chests
	if source == "rare_chest":
		var r_str: String = String(loot.get("rarity", "U"))
		var pity_used: bool = bool(loot.get("pity_used", false))
		var cur: int = _get_rare_chest_pity()
		var r_index: int = LootSystem.RARITY_ORDER.find(r_str)
		var reset_on_i: int = LootSystem.RARITY_ORDER.find("R")
		if pity_used or (r_index >= reset_on_i):
			_set_rare_chest_pity(0)
		elif r_str == "U":
			_set_rare_chest_pity(cur + 1)

	return loot
