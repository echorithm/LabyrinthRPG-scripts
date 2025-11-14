extends RefCounted
class_name StashService
## Village-only deposit/withdraw between RUN (risky) and META stash (safe).

const _S    := preload("res://persistence/util/save_utils.gd")
const _Meta := preload("res://persistence/schemas/meta_schema.gd")

const DEFAULT_SLOT: int = 1

# ------------- Gold/Shards -------------

static func deposit_gold(amount: int, slot: int = DEFAULT_SLOT) -> int:
	var amt: int = max(0, amount)
	if amt == 0: return 0
	var rs: Dictionary = SaveManager.load_run(slot)
	var have: int = max(0, int(_S.dget(rs, "gold", 0)))
	var take: int = min(have, amt)
	if take <= 0: return 0
	rs["gold"] = have - take
	SaveManager.save_run(rs, slot)

	var gs: Dictionary = SaveManager.load_game(slot)
	gs["stash_gold"] = int(_S.dget(gs, "stash_gold", 0)) + take
	SaveManager.save_game(gs, slot)
	return take

static func deposit_shards(amount: int, slot: int = DEFAULT_SLOT) -> int:
	var amt: int = max(0, amount)
	if amt == 0: return 0
	var rs: Dictionary = SaveManager.load_run(slot)
	var have: int = max(0, int(_S.dget(rs, "shards", 0)))
	var take: int = min(have, amt)
	if take <= 0: return 0
	rs["shards"] = have - take
	SaveManager.save_run(rs, slot)

	var gs: Dictionary = SaveManager.load_game(slot)
	gs["stash_shards"] = int(_S.dget(gs, "stash_shards", 0)) + take
	SaveManager.save_game(gs, slot)
	return take

# ------------- Items -------------

static func deposit_item_indices(run_indices: Array[int], slot: int = DEFAULT_SLOT) -> int:
	# Moves selected RUN inventory entries to META stash_items (deep copy).
	var rs: Dictionary = SaveManager.load_run(slot)
	var inv_any: Variant = _S.dget(rs, "inventory", [])
	var rinv: Array = (inv_any as Array) if inv_any is Array else []
	if rinv.is_empty(): return 0

	var moved: int = 0
	var indices: Array[int] = run_indices.duplicate()
	indices.sort()
	indices.reverse() # remove from end to keep indices valid

	var gs: Dictionary = SaveManager.load_game(slot)
	var stash_any: Variant = _S.dget(gs, "stash_items", [])
	var stash: Array = (stash_any as Array) if stash_any is Array else []

	for idx in indices:
		if idx < 0 or idx >= rinv.size(): continue
		var row_any: Variant = rinv[idx]
		if not (row_any is Dictionary):
			rinv.remove_at(idx)
			continue
		var row: Dictionary = (row_any as Dictionary).duplicate(true)
		stash.append(row)
		rinv.remove_at(idx)
		moved += 1

	rs["inventory"] = rinv
	SaveManager.save_run(rs, slot)
	gs["stash_items"] = stash
	SaveManager.save_game(gs, slot)
	return moved

static func withdraw_stash_indices(stash_indices: Array[int], slot: int = DEFAULT_SLOT) -> int:
	# Moves from META stash_items back into RUN inventory (e.g., gearing up in village)
	var gs: Dictionary = SaveManager.load_game(slot)
	var stash_any: Variant = _S.dget(gs, "stash_items", [])
	var stash: Array = (stash_any as Array) if stash_any is Array else []
	if stash.is_empty(): return 0

	var moved: int = 0
	var indices: Array[int] = stash_indices.duplicate()
	indices.sort()
	indices.reverse()

	var rs: Dictionary = SaveManager.load_run(slot)
	var rinv_any: Variant = _S.dget(rs, "inventory", [])
	var rinv: Array = (rinv_any as Array) if rinv_any is Array else []

	for idx in indices:
		if idx < 0 or idx >= stash.size(): continue
		var row_any: Variant = stash[idx]
		if row_any is Dictionary:
			rinv.append((row_any as Dictionary).duplicate(true))
			moved += 1
		stash.remove_at(idx)

	gs["stash_items"] = stash
	SaveManager.save_game(gs, slot)
	rs["inventory"] = rinv
	SaveManager.save_run(rs, slot)
	return moved
