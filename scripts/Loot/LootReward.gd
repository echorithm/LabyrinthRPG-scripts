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

static func _cxp_seed(run_seed: int, encounter_id: int, source: String) -> int:
	var s := "%d|%d|%s|cxp" % [run_seed, encounter_id, source]
	return int(s.hash())

# --- Public API (updated) ---------------------------------------
# Rolls loot and forwards to RewardsOrchestrator.grant_from_loot (if present),
# else falls back to RewardService.grant.
func encounter_victory(
	source: String,
	floor_i: int,
	enemy_id: String,
	rng_seed: int,
	post_boss_shift_left: int = 0,
	extra_skill_xp: Array[Dictionary] = [],
	enemy_display_name: String = "",
	enemy_level: int = 0,
	role_hint: String = "",
	boss_charge_factor: float = -1.0,
	ctx_overrides: Dictionary = {}
) -> Dictionary:
	var ctx := { "rng_seed": rng_seed, "post_boss_encounters_left": post_boss_shift_left }

	var rs := SaveManager.load_run()
	var sb := (rs.get("player_stat_block", {}) as Dictionary)
	var p_lvl: int = int(sb.get("level", 1))
	var target_level: int = (enemy_level if enemy_level > 0 else floor_i)
	ctx["player_level"] = p_lvl
	ctx["target_level"] = target_level

	if ctx_overrides is Dictionary:
		for k_any in ctx_overrides.keys():
			var k: String = String(k_any)
			ctx[k] = ctx_overrides[k_any]

	# Boss charge passthrough
	var charge_factor: float = boss_charge_factor
	if charge_factor < 0.0 and has_meta("boss_charge_factor"):
		var mv: Variant = get_meta("boss_charge_factor")
		if mv is float: charge_factor = float(mv)
		elif mv is int: charge_factor = float(int(mv))
	if role_hint == "boss" and charge_factor >= 0.0:
		ctx["boss_charge_factor"] = clampf(charge_factor, 0.0, 1.0)

	var loot: Dictionary = LootSystem.roll_loot(source, floor_i, ctx)

	# Character XP (v2 per enemy). This path is single-enemy today.
	var role_enum: int = XpTuning.Role.TRASH
	match (role_hint if role_hint != "" else source).to_lower():
		"elite": role_enum = XpTuning.Role.ELITE
		"boss":  role_enum = XpTuning.Role.BOSS
		_:       role_enum = XpTuning.Role.TRASH

	var cxp: int = 0
	if source.to_lower() != "chest":
		cxp = XpTuning.xp_for_enemy(p_lvl, target_level, role_enum)
	loot["xp"] = cxp

	# Merge skill XP rows (from loot tables and/or external tallies)
	var merged_sxp: Array = []
	if loot.has("skill_xp") and (loot["skill_xp"] is Array):
		for r_any in (loot["skill_xp"] as Array):
			if r_any is Dictionary: merged_sxp.append(r_any)
	for r2_any in extra_skill_xp:
		if r2_any is Dictionary: merged_sxp.append(r2_any)
	if merged_sxp.size() > 0:
		loot["skill_xp"] = merged_sxp

	# Enemy header for the modal
	if enemy_display_name == "":
		enemy_display_name = enemy_id
	loot["enemy_display_name"] = enemy_display_name
	loot["enemy_level"] = enemy_level
	loot["enemy_role"] = (role_hint if role_hint != "" else source)
	loot["enemy_id"] = enemy_id

	# Grant via orchestrator (preferred), else fallback to RewardService
	var orch := get_node_or_null(^"/root/RewardsOrchestrator")
	if orch != null and orch.has_method("grant_from_loot"):
		var receipt: Dictionary = await orch.call("grant_from_loot", loot, true) as Dictionary
		LootLog.print_encounter_victory_from_grant(source, floor_i, enemy_id, {
			"rarity": String(loot.get("rarity","U")),
			"category": String(loot.get("category","")),
			"pity_used": false,
			"post_boss_shift_applied": bool(loot.get("post_boss_shift_applied", false))
		}, receipt)
		return {"loot": loot, "receipt": receipt}

	var items: Array = ItemResolver.resolve(loot)
	var rewards := {
		"gold": int(loot.get("gold", 0)),
		"shards": int(loot.get("shards", 0)),
		"items": items,
		"xp": int(loot.get("xp", 0)),
		"skill_xp": (loot.get("skill_xp", []) as Array)
	}
	var receipt2: Dictionary = RewardService.grant(rewards, SaveManager.active_slot())
	LootLog.print_encounter_victory_from_grant(source, floor_i, enemy_id, {
		"rarity": String(loot.get("rarity","U")),
		"category": String(loot.get("category","")),
		"pity_used": false,
		"post_boss_shift_applied": bool(loot.get("post_boss_shift_applied", false))
	}, receipt2)
	return {"loot": loot, "receipt": receipt2}

func chest_open(_chest_level: String, world_pos: Vector3, rng_seed: int = 0) -> Dictionary:
	var floor_i: int = _current_floor()
	var rs := SaveManager.load_run()
	var p_lvl: int = int((rs.get("player_stat_block", {}) as Dictionary).get("level", 1))

	var run_seed: int = SaveManager.get_run_seed()
	var seed_src := "%d|%d|(%0.2f,%0.2f,%0.2f)|chest" % [run_seed, floor_i, world_pos.x, world_pos.y, world_pos.z]
	var ctx: Dictionary = {
		"rng_seed": (rng_seed if rng_seed != 0 else int(seed_src.hash())),
		"player_level": p_lvl
	}
	var loot: Dictionary = LootSystem.roll_loot("chest", floor_i, ctx)

	# Policy: chests do not grant XP
	loot["xp"] = 0

	var orch: Node = get_node_or_null(^"/root/RewardsOrchestrator")
	if orch != null and orch.has_method("grant_from_loot"):
		orch.call("grant_from_loot", loot, false)
	else:
		var items_to_grant: Array = ItemResolver.resolve(loot)
		var rewards: Dictionary = { "gold": int(loot.get("gold", 0)), "shards": int(loot.get("shards", 0)), "items": items_to_grant }
		RewardService.grant(rewards, SaveManager.active_slot())
	return loot
