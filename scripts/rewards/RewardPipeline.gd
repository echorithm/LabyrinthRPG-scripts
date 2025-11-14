# res://scripts/rewards/RewardPipeline.gd
extends RefCounted
class_name RewardPipeline

const RewardService := preload("res://persistence/services/reward_service.gd")
const XpTuning := preload("res://scripts/rewards/XpTuning.gd")
const SetPowerLevel := preload("res://scripts/dungeon/encounters/SetPowerLevel.gd")

static func _rng(seed: int) -> RandomNumberGenerator:
	var r := RandomNumberGenerator.new()
	r.seed = int(seed)
	return r

static func _cxp_seed(run_seed: int, encounter_id: int, source: String) -> int:
	return int(("%d|%d|%s|cxp" % [run_seed, encounter_id, source]).hash())

# res://scripts/rewards/RewardPipeline.gd
static func _preview_levels_gained_after_add(xp_add: int, cur_level: int, cur_xp: int) -> int:
	var lvl: int = max(1, cur_level)
	var xp: int = max(0, cur_xp) + max(0, xp_add)
	var gained: int = 0
	var need: int = ProgressionService.xp_to_next(lvl)  # difficulty-aware
	while xp >= need:
		xp -= need
		lvl += 1
		gained += 1
		need = ProgressionService.xp_to_next(lvl)       # difficulty-aware
	return gained

static func encounter_victory(source: String, floor_i: int, rng_seed: int, monster_level: int = 0, encounter_id: int = 0) -> Dictionary:
	var rs: Dictionary = SaveManager.load_run()
	var sb: Dictionary = rs.get("player_stat_block", {}) as Dictionary
	var p_lvl: int = int(sb.get("level", 1))
	var p_xp: int = int(sb.get("xp_current", 0))
	var enemy_level: int = (monster_level if monster_level > 0 else floor_i)

	var ctx: Dictionary = {
		"rng_seed": rng_seed,
		"player_level": p_lvl,
		"target_level": enemy_level
	}
	var loot: Dictionary = LootSystem.roll_loot(source, floor_i, ctx)
	var char_xp: int = 0

	if source.to_lower() != "chest":
		var role: int = XpTuning.Role.TRASH
		match source.to_lower():
			"elite": role = XpTuning.Role.ELITE
			"boss":  role = XpTuning.Role.BOSS
		var enemies: Array = [ { "monster_level": max(1, enemy_level), "role": role } ]
		char_xp = XpTuning.char_xp_for_victory_v2(p_lvl, enemies, 1)

	loot["xp"] = char_xp

	var receipt: Dictionary = RewardService.grant({
		"gold":   int(loot.get("gold", 0)),
		"shards": int(loot.get("shards", 0)),
		"items":  ItemResolver.resolve(loot),
		"xp":     char_xp,
		"skill_xp": (loot.get("skill_xp", []) as Array)
	}, SaveManager.active_slot())

	var levels_gained: int = _preview_levels_gained_after_add(char_xp, p_lvl, p_xp)
	return {
		"source": source,
		"floor":  floor_i,
		"rarity": String(loot.get("rarity", "U")),
		"gold":   int(loot.get("gold", 0)),
		"shards": int(loot.get("shards", 0)),
		"xp":     char_xp,
		"levels_gained": levels_gained
	}

# Unified chest path: single "chest" source, no pity; chest "level" derives from SetPowerLevel for this floor.
static func chest_open(_chest_level: String, floor_i: int, rng_seed: int, _rare_chest_pity: int) -> Dictionary:
	var rs: Dictionary = SaveManager.load_run()
	var p_lvl: int = int((rs.get("player_stat_block", {}) as Dictionary).get("level", 1))

	var ctx: Dictionary = {
		"rng_seed": rng_seed,
		"player_level": p_lvl,
		"target_level": max(1, floor_i)
	}
	var loot: Dictionary = LootSystem.roll_loot("chest", floor_i, ctx)
	loot["xp"] = 0

	var receipt: Dictionary = RewardService.grant({
		"gold":   int(loot.get("gold", 0)),
		"shards": int(loot.get("shards", 0)),
		"items":  ItemResolver.resolve(loot),
		"xp":     0,
		"skill_xp": (loot.get("skill_xp", []) as Array)
	}, SaveManager.active_slot())

	return {
		"source": "chest",
		"floor":  floor_i,
		"rarity": String(loot.get("rarity", "U")),
		"gold":   int(loot.get("gold", 0)),
		"shards": int(loot.get("shards", 0)),
		"xp":     0,
		"levels_gained": 0,
		"pity_used": false
	}
