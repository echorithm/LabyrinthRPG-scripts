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

	# --- Player mirrors ---
	var pl: Dictionary     = _S.to_dict(meta.get("player", {}))
	var sb_run: Dictionary = _S.to_dict(run.get("player_stat_block", {}))
	var sb_meta: Dictionary = _S.to_dict(pl.get("stat_block", {}))

	# Bank RUN-scoped XP delta on safe exit, preserving level/xp_needed from RUN.
	var xp_delta: int = int(run.get("char_xp_delta", 0))
	sb_meta["level"]      = int(sb_run.get("level", 1))
	sb_meta["xp_current"] = int(sb_run.get("xp_current", 0)) + xp_delta
	sb_meta["xp_needed"]  = int(sb_run.get("xp_needed", sb_meta.get("xp_needed", 90)))
	pl["stat_block"] = sb_meta

	# Points + attributes + skills back to META (retain current progression)
	pl["points_unspent"] = int(run.get("points_unspent", int(pl.get("points_unspent", 0))))
	var attrs_any: Variant = run.get("player_attributes", {})
	if attrs_any is Dictionary:
		(_S.to_dict(pl.get("stat_block", {})) as Dictionary)["attributes"] = (attrs_any as Dictionary).duplicate(true)
	pl["skill_tracks"] = _S.to_dict(run.get("skill_tracks", {})).duplicate(true)

	# --- Currency policy on safe exit: keep both gold and shards (bank to stash) ---
	meta["stash_gold"]   = int(meta.get("stash_gold", 0)) + int(run.get("gold", 0))
	meta["stash_shards"] = int(meta.get("stash_shards", 0)) + int(run.get("shards", 0))

	# --- Inventory: merge RUN inventory & equipped_bank into META inventory; preserve equipment ---
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
			if not row.has("uid"):
				row["uid"] = uid
			minv_out.append(row)

	# Preserve equipment mapping on safe exit
	var lo: Dictionary = _S.to_dict(pl.get("loadout", {}))
	lo["equipment"] = _S.to_dict(run.get("equipment", {})).duplicate(true)

	pl["loadout"]   = lo
	pl["inventory"] = minv_out

	# --- Floor bookkeeping: return to start (or village hub) ---
	meta["previous_floor"] = int(meta.get("current_floor", 1))
	meta["current_floor"]  = 1

	meta["player"]     = pl
	meta["updated_at"] = _S.now_ts()

	# Persist META and remove the live RUN (fresh shell will be created next).
	SaveManager.save_game(meta, slot)
	SaveManager.delete_run(slot)

	# ---- NEW: clear RunState mirrors and prepare a clean RUN from META defaults ----
	# This re-derives pools consistently and updates all HUD listeners.
	RunState.new_run_from_meta(true, slot)  # internally reloads and emits signals
