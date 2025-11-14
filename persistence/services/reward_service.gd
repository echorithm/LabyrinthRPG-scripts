# res://persistence/services/reward_service.gd
extends RefCounted
class_name RewardService

const _S := preload("res://persistence/util/save_utils.gd")

const DBG_REWARD := false  # ← flip to true while debugging

static func _get_runstate() -> Node:
	var loop: MainLoop = Engine.get_main_loop()
	var tree: SceneTree = loop as SceneTree
	if tree and tree.root:
		return tree.root.get_node_or_null(^"/root/RunState")
	return null

# ---- Slot resolver ----------------------------------------------------------
static func _slot(s: int) -> int:
	return (s if s > 0 else SaveManager.active_slot())

# --- Helpers -----------------------------------------------------------------

static func _normalize_item(it_in: Dictionary) -> Dictionary:
	var it: Dictionary = it_in.duplicate(true)

	# Top-level numeric fields coerced to int if present.
	if it.has("count"): it["count"] = int(it["count"])
	if it.has("ilvl"): it["ilvl"] = int(it["ilvl"])
	if it.has("durability_max"): it["durability_max"] = int(it["durability_max"])
	if it.has("durability_current"): it["durability_current"] = int(it["durability_current"])
	if it.has("weight"): it["weight"] = float(it["weight"])

	# Normalize equipable flags/slot_hint if present
	if not it.has("equipable"):
		# assume non-gear consumables by default unless explicitly provided by generators
		it["equipable"] = bool(int(_S.dget(it, "durability_max", 0)) > 0)

	if it.has("slot_hint"):
		it["slot_hint"] = String(it["slot_hint"])

	# Common nested options normalization (kept for older callers)
	if it.has("opts") and it["opts"] is Dictionary:
		var o: Dictionary = (it["opts"] as Dictionary)
		if o.has("ilvl"): o["ilvl"] = int(o["ilvl"])
		if o.has("durability_max"): o["durability_max"] = int(o["durability_max"])
		if o.has("durability_current"): o["durability_current"] = int(o["durability_current"])
		if o.has("weight"): o["weight"] = float(o["weight"])
		it["opts"] = o

	return it

static func _is_gear_or_equipable(it: Dictionary) -> bool:
	if bool(_S.dget(it, "equipable", false)):
		return true
	var dmax: int = int(_S.dget(it, "durability_max", 0))
	# legacy gear check
	return dmax > 0

static func _gen_uid() -> String:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var a: int = int(Time.get_ticks_usec()) & 0x7FFFFFFF
	var b: int = int(rng.randi() & 0x7FFFFFFF)
	return "u%08x%08x" % [a, b]

static func _stack_key(it: Dictionary) -> String:
	# Never stack equipable items (armor/weapons/accessories), even if dmax==0
	if _is_gear_or_equipable(it):
		return ""

	# Base identity
	var id_str: String = String(_S.dget(it, "id", ""))
	var rarity: String = String(_S.dget(it, "rarity", ""))

	# Stabilize relevant opts for consumables/materials (legacy)
	var opts_in: Dictionary = {}
	if it.has("opts") and it["opts"] is Dictionary:
		var o: Dictionary = (it["opts"] as Dictionary)
		opts_in = {
			"archetype": String(_S.dget(o, "archetype", "")),
			"ilvl": int(_S.dget(o, "ilvl", 0)),
			"rarity": String(_S.dget(o, "rarity", rarity)),
			"affixes": []
		}
		if o.has("affixes") and (o["affixes"] is Array):
			var arr: Array = (o["affixes"] as Array)
			var aff_out: Array = []
			for a in arr:
				aff_out.append(a)
			opts_in["affixes"] = aff_out

	var key_dict: Dictionary = {"id": id_str, "rarity": rarity, "opts": opts_in}
	return JSON.stringify(key_dict)

static func _stack_inventory(inv_in: Array) -> Array:
	var out: Array = []
	var by_key: Dictionary = {}

	for it_any in inv_in:
		if not (it_any is Dictionary):
			continue
		var it: Dictionary = _normalize_item(it_any as Dictionary)

		# Equipable items (including accessories) pass through—no stacking
		if _is_gear_or_equipable(it):
			out.append(it)
			continue

		var key: String = _stack_key(it)
		if key == "":
			out.append(it)
			continue

		var add_count: int = max(1, int(_S.dget(it, "count", 1)))
		if by_key.has(key):
			var row: Dictionary = by_key[key]
			row["count"] = int(_S.dget(row, "count", 1)) + add_count
		else:
			var first: Dictionary = it.duplicate(true)
			first["count"] = add_count
			by_key[key] = first

	for k in by_key.keys():
		out.append(by_key[k])

	return out

# -----------------------------------------------------------------------------
static func grant(bundle: Dictionary, slot: int = 0) -> Dictionary:
	slot = _slot(slot)

	if DBG_REWARD:
		print("[RewardService] grant() bundle=", bundle)
	var receipt: Dictionary = {}

	# Precompute deltas (don’t touch RUN yet)
	var gold_add: int = int(_S.dget(bundle, "gold", 0))
	var shards_add: int = int(_S.dget(bundle, "shards", 0))
	var hp_add: int = int(_S.dget(bundle, "hp", 0))
	var mp_add: int = int(_S.dget(bundle, "mp", 0))

	# Normalize items; assign uids for equipables; stash to apply after XP
	var pending_items: Array = []
	var granted_items: Array = []
	for it_any in (_S.dget(bundle, "items", []) as Array):
		if it_any is Dictionary:
			var it: Dictionary = _normalize_item(it_any as Dictionary)
			if _is_gear_or_equipable(it):
				var uid: String = String(_S.dget(it, "uid", ""))
				if uid.is_empty():
					it["uid"] = _gen_uid()
				it["count"] = 1
			pending_items.append(it)
			granted_items.append(it)

	# --- CHARACTER XP (saves internally) -----------------------------------
	var char_xp_add: int = int(_S.dget(bundle, "xp", 0))
	if char_xp_add > 0:
		var after_char: Dictionary = SaveManager.run_award_character_xp(char_xp_add, slot)
		var sb_after: Dictionary = {
			"level":      int(_S.dget(after_char, "level", 1)),
			"xp_current": int(_S.dget(after_char, "xp_current", 0)),
			"xp_needed":  int(_S.dget(after_char, "xp_needed", 90)),
		}
		var new_points: int = int(_S.dget(after_char, "points_unspent", 0))
		receipt["char_xp_applied"] = {
			"add": char_xp_add,
			"after": sb_after,
			"points_gained": int(_S.dget(after_char, "points_added", 0)),
			"run_points_unspent": new_points,
		}
	else:
		# Will fill 'after' from fresh RUN snapshot below
		receipt["char_xp_applied"] = {
			"add": 0, "after": {}, "points_gained": 0, "run_points_unspent": 0,
		}

	# --- SKILL XP (saves internally; milestones modify RUN attrs/pools) ----
	var applied_skill: Array = []
	for sxp_any in (_S.dget(bundle, "skill_xp", []) as Array):
		if sxp_any is Dictionary:
			var row: Dictionary = sxp_any as Dictionary
			var aid: String = String(_S.dget(row, "id", ""))
			var xp_add: int = int(_S.dget(row, "xp", 0))
			if not aid.is_empty() and xp_add > 0:
				var after_row: Dictionary = SaveManager.apply_skill_xp_to_run(aid, xp_add, slot)
				if DBG_REWARD:
					print("[RewardService] skill_xp applied: id=", aid, " xp=", xp_add, " after=", after_row)
				applied_skill.append({ "id": aid, "xp": xp_add, "after": after_row })

	# --- RELOAD RUN (to avoid clobbering XP/milestone changes) -------------
	var rs: Dictionary = SaveManager.load_run(slot)

	# If we had no char XP, populate the receipt view from RUN now
	if int(_S.dget(receipt["char_xp_applied"], "add", 0)) == 0:
		receipt["char_xp_applied"]["after"] = _S.to_dict(_S.dget(rs, "player_stat_block", {}))
		receipt["char_xp_applied"]["run_points_unspent"] = int(_S.dget(rs, "points_unspent", 0))

	# currencies
	if gold_add != 0:
		rs["gold"] = int(_S.dget(rs, "gold", 0)) + gold_add
	if shards_add != 0:
		rs["shards"] = int(_S.dget(rs, "shards", 0)) + shards_add

	# inventory (stack only non-equipables)
	var inv: Array = (_S.dget(rs, "inventory", []) as Array)
	for it in pending_items:
		inv.append(it)
	inv = _stack_inventory(inv)
	rs["inventory"] = inv

	# optional pools (use post-milestone maxes from fresh RUN)
	if hp_add != 0:
		rs["hp"] = clampi(int(_S.dget(rs, "hp", 0)) + hp_add, 0, int(_S.dget(rs, "hp_max", 0)))
	if mp_add != 0:
		rs["mp"] = clampi(int(_S.dget(rs, "mp", 0)) + mp_add, 0, int(_S.dget(rs, "mp_max", 0)))

	# Debug: confirm attributes include milestone bonuses before saving
	if DBG_REWARD:
		var dbg_attrs := _S.to_dict(_S.dget(rs, "player_attributes", {}))
		print("[RewardService] post-XP RUN attrs=", dbg_attrs, " hp_max=", _S.dget(rs, "hp_max", -1), " mp_max=", _S.dget(rs, "mp_max", -1))

	SaveManager.save_run(rs, slot)

	# receipt
	receipt["gold"] = gold_add
	receipt["shards"] = shards_add
	receipt["items"] = granted_items
	receipt["hp"] = hp_add
	receipt["mp"] = mp_add
	receipt["skill_xp_applied"] = applied_skill

	if DBG_REWARD:
		print("[RewardService] receipt=", receipt)

	return receipt
