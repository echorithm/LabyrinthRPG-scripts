# res://scripts/rewards/RewardPipeline.gd
extends RefCounted
class_name RewardPipeline

const RewardService := preload("res://persistence/services/reward_service.gd")
const LootRules := preload("res://scripts/Loot/LootRules.gd")
const XpTuning := preload("res://scripts/rewards/XpTuning.gd")

static func _rng(seed: int) -> RandomNumberGenerator:
	var r := RandomNumberGenerator.new()
	if seed != 0:
		r.seed = int(seed)
	else:
		r.randomize()
	return r

static func _preview_levels_gained_after_add(xp_add: int, cur_level: int, cur_xp: int) -> int:
	var lvl: int = max(1, cur_level)
	var xp: int = max(0, cur_xp) + max(0, xp_add)
	var gained: int = 0
	var need: int = int(round(90.0 * pow(1.13, float(lvl - 1))))
	while xp >= need:
		xp -= need
		lvl += 1
		gained += 1
		need = int(round(90.0 * pow(1.13, float(lvl - 1))))
	return gained

# Back-compatible: monster_level is optional. If provided, XP scales to monster level.
static func encounter_victory(source: String, floor_i: int, rng_seed: int, monster_level: int = 0) -> Dictionary:
	var rules: LootRules = LootRules.instance()
	var rng := _rng(rng_seed)

	var rarity_code: String = rules.pick_rarity(source, floor_i, rng)

	var gs: Dictionary = SaveManager.load_game(SaveManager.DEFAULT_SLOT)
	var pl: Dictionary = (gs.get("player", {}) as Dictionary)
	var sb: Dictionary = (pl.get("stat_block", {}) as Dictionary)
	var p_lvl: int = int(sb.get("level", 1))
	var p_xp: int = int(sb.get("xp_current", 0))

	var gold_amt: int = rules.gold_amount(source, floor_i, rng)
	var shard_amt: int = rules.shards_roll(source, floor_i, rng)

	var target_level: int = (monster_level if monster_level > 0 else floor_i)
	var char_xp: int = XpTuning.char_xp_for_victory(p_lvl, target_level, source, rarity_code, rng)
	var levels_gained: int = _preview_levels_gained_after_add(char_xp, p_lvl, p_xp)

	var rewards: Dictionary = {
		"gold": gold_amt,
		"shards": shard_amt,
		"items": [],
		"skill_xp": [],
		"xp": char_xp  # let RewardService handle Run accumulation
	}
	var _receipt: Dictionary = RewardService.grant(rewards, SaveManager.DEFAULT_SLOT)

	return {
		"source": source,
		"floor": floor_i,
		"rarity": rarity_code,
		"gold": gold_amt,
		"shards": shard_amt,
		"xp": char_xp,
		"levels_gained": levels_gained
	}

static func chest_open(chest_level: String, floor_i: int, rng_seed: int, rare_chest_pity: int) -> Dictionary:
	var rules: LootRules = LootRules.instance()
	var rng := _rng(rng_seed)
	var source: String = "rare_chest" if chest_level == "rare" else "common_chest"

	var rarity_code: String = rules.pick_rarity(source, floor_i, rng)

	var gs: Dictionary = SaveManager.load_game(SaveManager.DEFAULT_SLOT)
	var p_lvl: int = int(((gs.get("player", {}) as Dictionary).get("stat_block", {}) as Dictionary).get("level", 1))
	var p_xp: int = int(((gs.get("player", {}) as Dictionary).get("stat_block", {}) as Dictionary).get("xp_current", 0))

	var gold_amt: int = rules.gold_amount(source, floor_i, rng)
	var shard_amt: int = rules.shards_roll(source, floor_i, rng)

	var char_xp: int = XpTuning.char_xp_for_victory(p_lvl, floor_i, source, rarity_code, rng)
	var levels_gained: int = _preview_levels_gained_after_add(char_xp, p_lvl, p_xp)

	var rewards: Dictionary = {
		"gold": gold_amt,
		"shards": shard_amt,
		"items": [],
		"skill_xp": [],
		"xp": char_xp
	}
	var _receipt: Dictionary = RewardService.grant(rewards, SaveManager.DEFAULT_SLOT)

	return {
		"source": source,
		"floor": floor_i,
		"rarity": rarity_code,
		"gold": gold_amt,
		"shards": shard_amt,
		"xp": char_xp,
		"levels_gained": levels_gained,
		"pity_used": false
	}
