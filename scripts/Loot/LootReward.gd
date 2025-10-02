# res://scripts/Loot/LootReward.gd
extends Node
const XpTuning := preload("res://scripts/rewards/XpTuning.gd")

# --- Helpers ----------------------------------------------------
func _current_floor() -> int:
	var lm: Node = get_node_or_null(^"/root/LevelManager")
	if lm == null:
		return 1
	if lm.has_method("get_current_floor"):
		return int(lm.call("get_current_floor"))
	var v: Variant = lm.get("_current_floor")
	return int(v)

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

# --- Public API (kept for compatibility) ------------------------
# Rolls loot and forwards to RewardsOrchestrator.grant_from_loot (if present),
# else falls back to RewardService.grant.

func encounter_victory(source: String, floor_i: int, enemy_name: String, rng_seed: int, post_boss_shift_left: int = 0) -> Dictionary:
	var ctx := {
		"rng_seed": rng_seed,
		"post_boss_encounters_left": post_boss_shift_left
	}
	var loot: Dictionary = LootSystem.roll_loot(source, floor_i, ctx)
	LootLog.print_encounter_victory(source, floor_i, enemy_name, ctx)

	# --- ADD: compute character XP for this victory and include it in loot ---
	var rs := SaveManager.load_run(SaveManager.DEFAULT_SLOT)
	var sb := (rs.get("player_stat_block", {}) as Dictionary)
	var p_lvl: int = int(sb.get("level", 1))
	var rarity_code: String = String(loot.get("rarity", "U"))

	var rng := RandomNumberGenerator.new()
	rng.seed = int(ctx.get("rng_seed", 0))
	if rng.seed == 0:
		rng.randomize()

	var char_xp := XpTuning.char_xp_for_victory(p_lvl, floor_i, source, rarity_code, rng)
	loot["xp"] = int(char_xp)  # <-- now non-zero

	# Grant via orchestrator if present, return both loot + receipt
	var orch := get_node_or_null(^"/root/RewardsOrchestrator")
	if orch != null and orch.has_method("grant_from_loot"):
		var receipt: Dictionary = await orch.call("grant_from_loot", loot) as Dictionary
		return {"loot": loot, "receipt": receipt}

	# Fallback direct grant
	var items: Array = ItemResolver.resolve(loot)
	var rewards := {
		"gold": int(loot.get("gold", 0)),
		"shards": int(loot.get("shards", 0)),
		"items": items,
		"xp": int(loot.get("xp", 0)),
		"skill_xp": (loot.get("skill_xp", []) as Array)
	}
	var receipt: Dictionary = RewardService.grant(rewards, SaveManager.DEFAULT_SLOT)
	return {"loot": loot, "receipt": receipt}



func chest_open(chest_level: String, world_pos: Vector3, rng_seed: int = 0) -> Dictionary:
	var floor_i: int = _current_floor()
	var ctx: Dictionary = {
		"rng_seed": (rng_seed if rng_seed != 0 else int(randi())),
		"chest_level": chest_level
	}
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

	# Grant & show via orchestrator; fallback to direct grant
	var orch: Node = get_node_or_null(^"/root/RewardsOrchestrator")
	if orch != null and orch.has_method("grant_from_loot"):
		orch.call("grant_from_loot", loot)
	else:
		var items_to_grant: Array = ItemResolver.resolve(loot)
		var rewards: Dictionary = { "gold": int(loot.get("gold", 0)), "shards": int(loot.get("shards", 0)), "items": items_to_grant }
		RewardService.grant(rewards, SaveManager.DEFAULT_SLOT)
	return loot
