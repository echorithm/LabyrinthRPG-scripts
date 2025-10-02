# res://persistence/flows/DefeatFlow.gd
extends RefCounted
class_name DefeatFlow

const _S    := preload("res://persistence/util/save_utils.gd")
const _Meta := preload("res://persistence/schemas/meta_schema.gd")

static func execute(slot: int = 1) -> void:
	var meta: Dictionary = SaveManager.load_game(slot)
	var run:  Dictionary = SaveManager.load_run(slot)

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

	# Currency policy on defeat: keep shards, lose gold (tune as desired)
	meta["stash_gold"]   = int(meta.get("stash_gold", 0))
	meta["stash_shards"] = int(meta.get("stash_shards", 0)) + int(run.get("shards", 0))

	# Merge inventory & equipped so items aren’t lost
	var rinv: Array = (run.get("inventory", []) as Array)
	var rbank: Dictionary = _S.to_dict(run.get("equipped_bank", {}))
	var minv_out: Array = []
	for it_any in rinv:
		if it_any is Dictionary:
			minv_out.append((it_any as Dictionary).duplicate(true))
	for uid_any in rbank.keys():
		var uid: String = String(uid_any)
		var row_any: Variant = rbank[uid_any]
		if row_any is Dictionary:
			var row: Dictionary = (row_any as Dictionary).duplicate(true)
			if not row.has("uid"): row["uid"] = uid
			minv_out.append(row)

	# On defeat we clear equipped slots
	var lo: Dictionary = _S.to_dict(pl.get("loadout", {}))
	lo["equipment"] = {
		"head": null, "chest": null, "legs": null, "boots": null,
		"mainhand": null, "offhand": null, "ring1": null, "ring2": null, "amulet": null
	}
	pl["loadout"]   = lo
	pl["inventory"] = minv_out

	# Floor bookkeeping
	meta["previous_floor"] = int(meta.get("current_floor", 1))
	meta["current_floor"]  = 1  # back to start (tweak to taste)

	meta["player"]     = pl
	meta["updated_at"] = _S.now_ts()
	SaveManager.save_game(meta, slot)
	SaveManager.delete_run(slot)
