# res://persistence/flows/ExitSafelyFlow.gd
extends RefCounted
class_name ExitSafelyFlow

const _S    := preload("res://persistence/util/save_utils.gd")
const _Meta := preload("res://persistence/schemas/meta_schema.gd")

static func execute(slot: int = 1) -> void:
	# Load latest snapshots
	var meta: Dictionary = SaveManager.load_game(slot)   # migrated
	var run:  Dictionary = SaveManager.load_run(slot)    # migrated

	# --- Character mirrors (RUN is truth during run)
	var pl: Dictionary = _S.to_dict(meta.get("player", {}))
	var sb_run: Dictionary = _S.to_dict(run.get("player_stat_block", {}))
	var sb_meta: Dictionary = _S.to_dict(pl.get("stat_block", {}))
	sb_meta["level"]      = int(sb_run.get("level", 1))
	sb_meta["xp_current"] = int(sb_run.get("xp_current", 0))
	sb_meta["xp_needed"]  = int(sb_run.get("xp_needed", sb_meta.get("xp_needed", 90)))
	pl["stat_block"] = sb_meta

	pl["points_unspent"] = int(run.get("points_unspent", int(pl.get("points_unspent", 0))))

	var attrs_any: Variant = run.get("player_attributes", {})
	if attrs_any is Dictionary:
		(_S.to_dict(pl.get("stat_block", {})) as Dictionary)["attributes"] = (attrs_any as Dictionary).duplicate(true)

	pl["skill_tracks"] = _S.to_dict(run.get("skill_tracks", {})).duplicate(true)

	# --- Currencies (example: add on-hand to stash)
	meta["stash_gold"]   = int(meta.get("stash_gold", 0))   + int(run.get("gold", 0))
	meta["stash_shards"] = int(meta.get("stash_shards", 0)) + int(run.get("shards", 0))

	# --- Inventory + equipment mirror
	var rinv: Array = (run.get("inventory", []) as Array)
	var req:  Dictionary = _S.to_dict(run.get("equipment", {}))
	var rbank: Dictionary = _S.to_dict(run.get("equipped_bank", {}))

	var lo: Dictionary  = _S.to_dict(pl.get("loadout", {}))
	var meq: Dictionary = _S.to_dict(lo.get("equipment", {}))

	# META inventory: leftover run inv + all equipped items (from bank)
	var minv_out: Array = []
	for it_any in rinv:
		if it_any is Dictionary:
			minv_out.append((it_any as Dictionary).duplicate(true))
	for uid_any in rbank.keys():
		var uid: String = String(uid_any)
		var row_any: Variant = rbank[uid_any]
		if row_any is Dictionary:
			var row: Dictionary = (row_any as Dictionary).duplicate(true)
			if not row.has("uid"):
				row["uid"] = uid
			minv_out.append(row)

	# Copy slot -> uid map
	var meq_out: Dictionary = {
		"head": null, "chest": null, "legs": null, "boots": null,
		"mainhand": null, "offhand": null, "ring1": null, "ring2": null, "amulet": null
	}
	for k in meq_out.keys():
		meq_out[k] = req.get(k, null)

	lo["equipment"]   = meq_out
	lo["weapon_tags"] = _S.to_string_array(run.get("weapon_tags", []))
	pl["loadout"]     = lo
	pl["inventory"]   = minv_out

	# --- Floor mirrors
	meta["previous_floor"]         = int(meta.get("current_floor", 1))
	meta["current_floor"]          = int(run.get("depth", meta.get("current_floor", 1)))
	meta["highest_teleport_floor"] = max(int(meta.get("highest_teleport_floor", 1)), int(run.get("furthest_depth_reached", 1)))

	# --- Save META, then clear RUN
	meta["player"]     = pl
	meta["updated_at"] = _S.now_ts()
	SaveManager.save_game(meta, slot)
	SaveManager.delete_run(slot)
