extends RefCounted
class_name DefeatFlow

const _S            := preload("res://persistence/util/save_utils.gd")
const _Meta         := preload("res://persistence/schemas/meta_schema.gd")
const TimeService   := preload("res://persistence/services/time_service.gd")
const _PS           := preload("res://persistence/services/progression_service.gd") # xp_to_next()

static func execute(slot: int = 1) -> void:
	# 1) Bank current floor time into RUN total, then reset floor accumulator.
	TimeService.commit_and_reset(slot)

	# 2) Load current META and RUN snapshots.
	var meta: Dictionary = SaveManager.load_game(slot)
	var run:  Dictionary = SaveManager.load_run(slot)

	# 3) Roll total run minutes into META (accumulate).
	var run_total_min: float = float(run.get("run_time_total_min", 0.0))
	var meta_time_prev: float = 0.0
	if meta.has("time_passed_min"):
		var tprev: Variant = meta["time_passed_min"]
		if tprev is float:
			meta_time_prev = float(tprev)
		elif tprev is int:
			meta_time_prev = float(tprev)
	meta["time_passed_min"] = meta_time_prev + run_total_min

	# --- Teleport milestone bump on defeat ---
	# If furthest depth is a teleport floor (1,4,7,...) and greater than current META highest, bump it.
	var furthest: int = int(run.get("furthest_depth_reached", int(run.get("depth", 1))))
	var is_teleport: bool = ((furthest - 1) % 3) == 0 and furthest >= 1
	if is_teleport:
		var highest_tp: int = int(meta.get("highest_teleport_floor", 1))
		if furthest > highest_tp:
			meta["highest_teleport_floor"] = furthest

	# 4) Prepare META player mirror.
	var pl: Dictionary      = _S.to_dict(meta.get("player", {}))
	var sb_run: Dictionary  = _S.to_dict(run.get("player_stat_block", {}))
	var sb_meta: Dictionary = _S.to_dict(pl.get("stat_block", {}))

	# --- Character defeat penalties ---
	# Keep level, zero current XP, recompute needed from curve.
	var lvl_after: int = int(sb_run.get("level", 1))
	sb_meta["level"]      = lvl_after
	sb_meta["xp_current"] = 0
	sb_meta["xp_needed"]  = int(_PS.xp_to_next(lvl_after))
	pl["stat_block"] = sb_meta

	# Points + attributes + skills structure mirror (attributes preserved as-is).
	pl["points_unspent"] = int(run.get("points_unspent", int(pl.get("points_unspent", 0))))

	var attrs_any: Variant = run.get("player_attributes", {})
	if attrs_any is Dictionary:
		(_S.to_dict(pl.get("stat_block", {})) as Dictionary)["attributes"] = (attrs_any as Dictionary).duplicate(true)

	# --- Skill defeat penalties ---
	# For each skill: keep level/cap/unlocked/last_ms; set xp_current=0; xp_needed=curve(level).
	var tracks_run: Dictionary = _S.to_dict(run.get("skill_tracks", {}))
	var tracks_meta_out: Dictionary = {}
	for id_any in tracks_run.keys():
		var id: String = String(id_any)
		var row_in: Dictionary = _S.to_dict(tracks_run[id_any])
		var rlvl: int = int(row_in.get("level", 1))
		tracks_meta_out[id] = {
			"level": rlvl,
			"xp_current": 0,
			"xp_needed": int(_PS.xp_to_next(rlvl)),
			"cap_band": int(row_in.get("cap_band", 10)),
			"unlocked": bool(row_in.get("unlocked", false)),
			"last_milestone_applied": int(row_in.get("last_milestone_applied", 0))
		}
	pl["skill_tracks"] = tracks_meta_out

	# 5) Currency policy on defeat: keep shards (stash += run.shards); lose gold (ignore run.gold).
	meta["stash_gold"]   = int(meta.get("stash_gold", 0))
	meta["stash_shards"] = int(meta.get("stash_shards", 0)) + int(run.get("shards", 0))

	# 6) Equipment & inventory:
	#    - Keep ONLY equipped items (as FULL DICTS in META loadout.equipment).
	#    - Lose all non-equipped items (META inventory becomes empty).
	var req: Dictionary       = _S.to_dict(run.get("equipment", {}))         # {slot->uid or null}
	var rbank: Dictionary     = _S.to_dict(run.get("equipped_bank", {}))     # {uid->full item dict}
	var eq_meta_out: Dictionary = {
		"head": null, "chest": null, "legs": null, "boots": null,
		"sword": null, "spear": null, "mace": null, "bow": null,
		"ring1": null, "ring2": null, "amulet": null
	}

	for s_any in eq_meta_out.keys():
		var s: String = String(s_any)
		var uid_any: Variant = req.get(s, null)
		if uid_any == null:
			eq_meta_out[s] = null
			continue
		var uid: String = String(uid_any)
		if uid.is_empty():
			eq_meta_out[s] = null
			continue
		var row_any: Variant = rbank.get(uid, null)
		if row_any is Dictionary:
			var full_row: Dictionary = (row_any as Dictionary).duplicate(true)
			if not full_row.has("uid"):
				full_row["uid"] = uid
			eq_meta_out[s] = full_row
		else:
			# If the UID isn't in the bank for some reason, leave slot empty.
			eq_meta_out[s] = null

	# META: clear inventory entirely (all non-equipped are lost).
	pl["inventory"] = []
	# META: preserve canonical equipment mapping with full dicts.
	var lo: Dictionary = _S.to_dict(pl.get("loadout", {}))
	lo["equipment"] = eq_meta_out
	pl["loadout"]   = lo

	# 7) Floor bookkeeping.
	meta["previous_floor"] = int(meta.get("current_floor", 1))
	meta["current_floor"]  = 1

	meta["player"]     = pl
	meta["updated_at"] = _S.now_ts()

	# 8) Persist META, then clear RUN and seed a fresh RUN from META.
	SaveManager.save_game(meta, slot)
	SaveManager.delete_run(slot)
	RunState.new_run_from_meta(true, slot)
