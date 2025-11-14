extends RefCounted
class_name SlotService

const DEBUG: bool = true
const MAX_SLOTS: int = 12
const SAVES_DIR: String = "user://saves"

static func _dbg(msg: String) -> void:
	if DEBUG: print("[SlotService] ", msg)

static func _slot_meta_path(i: int) -> String:
	return "%s/slot_%d_meta.json" % [SAVES_DIR, i]

static func _slot_run_path(i: int) -> String:
	return "%s/slot_%d_run.json" % [SAVES_DIR, i]

static func _meta_exists(i: int) -> bool:
	return FileAccess.file_exists(_slot_meta_path(i))

static func _run_exists(i: int) -> bool:
	return FileAccess.file_exists(_slot_run_path(i))

static func _any_exists(i: int) -> bool:
	return _meta_exists(i) or _run_exists(i)

static func list_used_slots(max_slots: int = MAX_SLOTS) -> Array[int]:
	# Non-creating: only checks for files on disk.
	var out: Array[int] = [] as Array[int]
	if not DirAccess.dir_exists_absolute(SAVES_DIR):
		_dbg("list_used_slots: dir missing → []")
		return out
	for i: int in range(1, max_slots + 1):
		if _any_exists(i):
			out.append(i)
	_dbg("list_used_slots: " + str(out))
	return out

static func slot_exists(slot: int) -> bool:
	var ok: bool = _any_exists(slot)
	_dbg("slot_exists(" + str(slot) + ") → " + str(ok))
	return ok

static func is_slot_empty(slot: int) -> bool:
	var empty: bool = not _any_exists(slot)
	_dbg("is_slot_empty(" + str(slot) + ") → " + str(empty))
	return empty

static func first_empty_slot(max_slots: int = MAX_SLOTS) -> int:
	if not DirAccess.dir_exists_absolute(SAVES_DIR):
		DirAccess.make_dir_recursive_absolute(SAVES_DIR)
	for i: int in range(1, max_slots + 1):
		if not _any_exists(i):
			_dbg("first_empty_slot → " + str(i))
			return i
	_dbg("first_empty_slot: none free, default 1")
	return 1

static func delete_slot(slot: int) -> bool:
	var ok := true
	var mp := _slot_meta_path(slot)
	var rp := _slot_run_path(slot)
	if FileAccess.file_exists(mp):
		ok = ok and (DirAccess.remove_absolute(mp) == OK)
	if FileAccess.file_exists(rp):
		ok = ok and (DirAccess.remove_absolute(rp) == OK)
	_dbg("delete_slot(" + str(slot) + ") → " + str(ok))
	return ok

static func last_played_slot_or_default(default_slot: int = 1) -> int:
	var used: Array[int] = list_used_slots()
	if used.is_empty():
		_dbg("last_played_slot_or_default → default " + str(default_slot))
		return default_slot

	var best_slot: int = used[0]
	var best_mtime: int = -1

	for s: int in used:
		var mt_meta: int = FileAccess.get_modified_time(_slot_meta_path(s)) if _meta_exists(s) else -1
		var mt_run: int = FileAccess.get_modified_time(_slot_run_path(s)) if _run_exists(s) else -1
		var mt: int = mt_meta if mt_meta > mt_run else mt_run
		if mt > best_mtime:
			best_mtime = mt
			best_slot = s

	_dbg("last_played_slot_or_default → " + str(best_slot))
	return best_slot
