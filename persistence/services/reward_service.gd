extends RefCounted
class_name RewardService

const _S := preload("res://persistence/util/save_utils.gd")

const DEFAULT_SLOT: int = 1

static func _get_runstate() -> Node:
	var loop := Engine.get_main_loop()
	var tree := loop as SceneTree
	if tree and tree.root:
		return tree.root.get_node_or_null(^"/root/RunState")
	return null

# --- Helpers -----------------------------------------------------------------

static func _normalize_item(it_in: Dictionary) -> Dictionary:
	var it: Dictionary = it_in.duplicate(true)

	# Top-level numeric fields coerced to int if present.
	if it.has("count"): it["count"] = int(it["count"])
	if it.has("ilvl"): it["ilvl"] = int(it["ilvl"])
	if it.has("durability_max"): it["durability_max"] = int(it["durability_max"])
	if it.has("durability_current"): it["durability_current"] = int(it["durability_current"])

	# Common nested options normalization.
	if it.has("opts") and it["opts"] is Dictionary:
		var o: Dictionary = (it["opts"] as Dictionary)
		if o.has("ilvl"): o["ilvl"] = int(o["ilvl"])
		if o.has("durability_max"): o["durability_max"] = int(o["durability_max"])
		if o.has("durability_current"): o["durability_current"] = int(o["durability_current"])
		# Keep weights as float if you track fractional weights.
		if o.has("weight"): o["weight"] = float(o["weight"])
		it["opts"] = o

	return it

# -----------------------------------------------------------------------------
static func grant(bundle: Dictionary, slot: int = SaveManager.DEFAULT_SLOT) -> Dictionary:
	var rs: Dictionary = SaveManager.load_run(slot) # fresh snapshot
	var receipt: Dictionary = {}

	# --- currencies ---
	var gold_add: int = int(bundle.get("gold", 0))
	var shards_add: int = int(bundle.get("shards", 0))
	if gold_add != 0:
		rs["gold"] = int(rs.get("gold", 0)) + gold_add
	if shards_add != 0:
		rs["shards"] = int(rs.get("shards", 0)) + shards_add

	# --- items (normalize + ensure uid for gear) ---
	var inv: Array = (rs.get("inventory", []) as Array)
	var granted_items: Array = []
	for it_any in (bundle.get("items", []) as Array):
		if it_any is Dictionary:
			var it: Dictionary = _normalize_item(it_any as Dictionary)
			var dmax: int = int(it.get("durability_max", 0))
			if dmax > 0:
				var uid: String = String(it.get("uid", ""))
				if uid.is_empty():
					it["uid"] = _gen_uid()
				it["count"] = 1  # gear is non-stackable
			inv.append(it)
			granted_items.append(it)
	rs["inventory"] = inv

	# --- pools (optional) ---
	var hp_add: int = int(bundle.get("hp", 0))
	var mp_add: int = int(bundle.get("mp", 0))
	if hp_add != 0:
		rs["hp"] = clampi(int(rs.get("hp", 0)) + hp_add, 0, int(rs.get("hp_max", 0)))
	if mp_add != 0:
		rs["mp"] = clampi(int(rs.get("mp", 0)) + mp_add, 0, int(rs.get("mp_max", 0)))

	# --- character XP ---
	var char_xp_add: int = int(bundle.get("xp", 0))
	if char_xp_add > 0:
		var after_char: Dictionary = SaveManager.run_award_character_xp(char_xp_add, slot)
		var sb_after := {
			"level":      int(after_char.get("level", 1)),
			"xp_current": int(after_char.get("xp_current", 0)),
			"xp_needed":  int(after_char.get("xp_needed", 90)),
		}
		rs["player_stat_block"] = sb_after
		var new_points := int(after_char.get("points_unspent", int(_S.dget(rs, "points_unspent", 0))))
		rs["points_unspent"] = new_points
		receipt["char_xp_applied"] = {
			"add": char_xp_add,
			"after": sb_after,
			"points_gained": int(after_char.get("points_added", 0)),
			"run_points_unspent": new_points,
		}
	else:
		receipt["char_xp_applied"] = {
			"add": 0,
			"after": _S.to_dict(rs.get("player_stat_block", {})),
			"points_gained": 0,
			"run_points_unspent": int(_S.dget(rs, "points_unspent", 0)),
		}

	# --- skill XP ---
	var applied_skill: Array = []
	var st_all: Dictionary = (rs.get("skill_tracks", {}) as Dictionary)
	for sxp_any in (bundle.get("skill_xp", []) as Array):
		if sxp_any is Dictionary:
			var row: Dictionary = sxp_any as Dictionary
			var aid: String = String(row.get("id", ""))
			var xp_add: int = int(row.get("xp", 0))
			if aid != "" and xp_add > 0:
				var after_row: Dictionary = SaveManager.apply_skill_xp_to_run(aid, xp_add, slot)
				applied_skill.append({ "id": aid, "xp": xp_add, "after": after_row })
				st_all[aid] = after_row.duplicate(true)
	if not st_all.is_empty():
		rs["skill_tracks"] = st_all

	# --- single authoritative save ---
	SaveManager.save_run(rs, slot)

	# Build receipt
	receipt["gold"] = gold_add
	receipt["shards"] = shards_add
	receipt["items"] = granted_items
	receipt["hp"] = hp_add
	receipt["mp"] = mp_add
	receipt["skill_xp_applied"] = applied_skill

	print("[RewardService] grant() returning: ", JSON.stringify(receipt, "\t"))
	return receipt

static func _gen_uid() -> String:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var a: int = int(Time.get_ticks_usec()) & 0x7FFFFFFF
	var b: int = int(rng.randi() & 0x7FFFFFFF)
	return "u%08x%08x" % [a, b]
