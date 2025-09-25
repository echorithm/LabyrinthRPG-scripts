extends RefCounted
class_name RewardPipeline


const RewardService := preload("res://persistence/services/reward_service.gd")
const LootRules := preload("res://scripts/Loot/LootRules.gd")
const XpTuning := preload("res://scripts/rewards/XpTuning.gd")

# Utility RNG
static func _rng(seed: int) -> RandomNumberGenerator:
	var r := RandomNumberGenerator.new()
	if seed != 0:
		r.seed = int(seed)
	else:
		r.randomize()
	return r

# Minimal character XP award here so we don't depend on non-static ProgressionService.
static func _award_character_xp(amount: int) -> int:
	if amount <= 0:
		return 0
	var gs: Dictionary = SaveManager.load_game(SaveManager.DEFAULT_SLOT)
	var pl: Dictionary = (gs.get("player", {}) as Dictionary)
	var sb: Dictionary = (pl.get("stat_block", {}) as Dictionary)

	var lvl: int = int(sb.get("level", 1))
	var cur: int = int(sb.get("xp_current", 0))
	var need: int = int(sb.get("xp_needed", XpTuning.xp_to_next(lvl)))

	var xp_new: int = cur + max(0, amount)
	var new_levels: int = 0
	while xp_new >= need:
		xp_new -= need
		lvl += 1
		new_levels += 1
		need = XpTuning.xp_to_next(lvl)

	sb["level"] = lvl
	sb["xp_current"] = xp_new
	sb["xp_needed"] = need
	pl["stat_block"] = sb
	gs["player"] = pl
	SaveManager.save_game(gs, SaveManager.DEFAULT_SLOT)
	return new_levels

# -----------------------
# Encounter victory grant
# -----------------------
static func encounter_victory(source: String, floor_i: int, rng_seed: int) -> Dictionary:
	var rules: LootRules = LootRules.instance()
	var rng := _rng(rng_seed)

	# Rarity from rules (post-boss shift is handled inside rules via floor math)
	var rarity_code: String = rules.pick_rarity(source, floor_i, rng)

	# Assume target level ~= floor; if you have precise monster level, pass it in here instead.
	var gs: Dictionary = SaveManager.load_game(SaveManager.DEFAULT_SLOT)
	var pl: Dictionary = (gs.get("player", {}) as Dictionary)
	var sb: Dictionary = (pl.get("stat_block", {}) as Dictionary)
	var p_lvl: int = int(sb.get("level", 1))
	var t_lvl: int = floor_i

	# Currencies
	var gold_amt: int = rules.gold_amount(source, floor_i, rng)
	var shard_amt: int = rules.shards_roll(source, floor_i, rng)

	# Character XP (skill XP is granted per-hit elsewhere)
	var char_xp: int = XpTuning.char_xp_for_victory(p_lvl, t_lvl, source, rarity_code, rng)
	var levels_gained: int = _award_character_xp(char_xp)

	# Grant currencies/items via RewardService (items resolved elsewhere when you add itemization)
	var rewards: Dictionary = {
		"gold": gold_amt,
		"shards": shard_amt,
		"items": [],
		"skill_xp": []
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

# -----------------------
# Chest open grant
# -----------------------
static func chest_open(chest_level: String, floor_i: int, rng_seed: int, rare_chest_pity: int) -> Dictionary:
	var rules: LootRules = LootRules.instance()
	var rng := _rng(rng_seed)
	var source: String = "rare_chest" if chest_level == "rare" else "common_chest"

	var rarity_code: String = rules.pick_rarity(source, floor_i, rng)

	# Basic currencies
	var gold_amt: int = rules.gold_amount(source, floor_i, rng)
	var shard_amt: int = rules.shards_roll(source, floor_i, rng)

	# Character XP (small, chest-based)
	var gs: Dictionary = SaveManager.load_game(SaveManager.DEFAULT_SLOT)
	var p_lvl: int = int(((gs.get("player", {}) as Dictionary).get("stat_block", {}) as Dictionary).get("level", 1))
	var t_lvl: int = floor_i
	var char_xp: int = XpTuning.char_xp_for_victory(p_lvl, t_lvl, source, rarity_code, rng)
	var levels_gained: int = _award_character_xp(char_xp)

	# Grant currencies/items
	var rewards: Dictionary = {
		"gold": gold_amt,
		"shards": shard_amt,
		"items": [],
		"skill_xp": []
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
		"pity_used": false   # hook for future if you wire pity into rules
	}
