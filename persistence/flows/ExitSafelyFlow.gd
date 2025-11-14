extends RefCounted
class_name ExitSafelyFlow

const _S            := preload("res://persistence/util/save_utils.gd")
const _Meta         := preload("res://persistence/schemas/meta_schema.gd")
const TimeService   := preload("res://persistence/services/time_service.gd")

static func execute(slot: int = 1) -> void:
	# Commit current floor time into RUN total, then reset floor accumulator.
	TimeService.commit_and_reset(slot)

	var meta: Dictionary = SaveManager.load_game(slot)
	var run:  Dictionary = SaveManager.load_run(slot)

	# --- Roll total run minutes into META (accumulate) ---
	var run_total_min: float = float(run.get("run_time_total_min", 0.0))
	var meta_time_prev: float = 0.0
	if meta.has("time_passed_min"):
		var tprev: Variant = meta["time_passed_min"]
		if tprev is float:
			meta_time_prev = float(tprev)
		elif tprev is int:
			meta_time_prev = float(tprev)
	meta["time_passed_min"] = meta_time_prev + run_total_min

	# --- Teleport milestone bump on safe exit ---
	# Use furthest_depth_reached from RUN. If it's a teleport floor and exceeds META's highest, bump it.
	var furthest: int = int(run.get("furthest_depth_reached", int(run.get("depth", 1))))
	var is_teleport: bool = ((furthest - 1) % 3) == 0 and furthest >= 1
	if is_teleport:
		var highest_tp: int = int(meta.get("highest_teleport_floor", 1))
		if furthest > highest_tp:
			meta["highest_teleport_floor"] = furthest

	# --- Player mirrors ---
	var pl: Dictionary      = _S.to_dict(meta.get("player", {}))
	var sb_run: Dictionary  = _S.to_dict(run.get("player_stat_block", {}))
	var sb_meta: Dictionary = _S.to_dict(pl.get("stat_block", {}))

	# Bank RUN-scoped XP delta on safe exit, preserving level/xp_needed from RUN.
	var xp_delta: int = int(run.get("char_xp_delta", 0))
	sb_meta["level"]      = int(sb_run.get("level", 1))
	sb_meta["xp_current"] = int(sb_run.get("xp_current", 0)) + xp_delta
	sb_meta["xp_needed"]  = int(sb_run.get("xp_needed", sb_meta.get("xp_needed", 90)))
	pl["stat_block"] = sb_meta

	# Points + attributes + skills back to META
	pl["points_unspent"] = int(run.get("points_unspent", int(pl.get("points_unspent", 0))))
	var attrs_any: Variant = run.get("player_attributes", {})
	if attrs_any is Dictionary:
		(_S.to_dict(pl.get("stat_block", {})) as Dictionary)["attributes"] = (attrs_any as Dictionary).duplicate(true)
	pl["skill_tracks"] = _S.to_dict(run.get("skill_tracks", {})).duplicate(true)

	# --- Currency on safe exit: bank both gold and shards to stash ---
	meta["stash_gold"]   = int(meta.get("stash_gold", 0)) + int(run.get("gold", 0))
	meta["stash_shards"] = int(meta.get("stash_shards", 0)) + int(run.get("shards", 0))

	# --- Inventory & equipment fold-back ---
	var rinv: Array       = (run.get("inventory", []) as Array)
	var rbank: Dictionary = _S.to_dict(run.get("equipped_bank", {}))
	var req: Dictionary   = _S.to_dict(run.get("equipment", {}))

	# Build a set of currently equipped UIDs (by canonical slot list).
	var equip_uids := {}
	for s in ["head","chest","legs","boots","sword","spear","mace","bow","ring1","ring2","amulet"]:
		var u_any: Variant = req.get(s, null)
		if u_any != null:
			var u: String = String(u_any)
			if not u.is_empty():
				equip_uids[u] = true

	# META inventory = RUN inventory + any banked items that are NOT currently equipped
	var minv_out: Array = []
	for it_any in rinv:
		if it_any is Dictionary:
			minv_out.append((it_any as Dictionary).duplicate(true))
	for uid_any in rbank.keys():
		var uid: String = String(uid_any)
		if equip_uids.has(uid):
			continue # equipped -> will be placed into META equipment, not inventory
		var row_any: Variant = rbank[uid_any]
		if row_any is Dictionary:
			var row: Dictionary = (row_any as Dictionary).duplicate(true)
			if not row.has("uid"):
				row["uid"] = uid
			minv_out.append(row)

	# META equipment must store FULL ITEM DICTS (not uids)
	var eq_meta_out: Dictionary = {
		"head": null, "chest": null, "legs": null, "boots": null,
		"sword": null, "spear": null, "mace": null, "bow": null,
		"ring1": null, "ring2": null, "amulet": null
	}
	for s2 in eq_meta_out.keys():
		var u2_any: Variant = req.get(String(s2), null)
		if u2_any == null:
			continue
		var u2: String = String(u2_any)
		if u2.is_empty():
			continue
		var row2_any: Variant = rbank.get(u2, null)
		if row2_any is Dictionary:
			var row2: Dictionary = (row2_any as Dictionary).duplicate(true)
			if not row2.has("uid"):
				row2["uid"] = u2
			eq_meta_out[String(s2)] = row2

	# Preserve equipment mapping on safe exit (as full dicts)
	var lo: Dictionary = _S.to_dict(pl.get("loadout", {}))
	lo["equipment"] = eq_meta_out
	pl["loadout"]   = lo
	pl["inventory"] = minv_out

	# --- Floor bookkeeping ---
	meta["previous_floor"] = int(meta.get("current_floor", 1))
	meta["current_floor"]  = 1

	meta["player"]     = pl
	meta["updated_at"] = _S.now_ts()

	# Persist META and remove RUN
	SaveManager.save_game(meta, slot)
	SaveManager.delete_run(slot)

	# Seed a fresh RUN from META defaults
	RunState.new_run_from_meta(true, slot)
