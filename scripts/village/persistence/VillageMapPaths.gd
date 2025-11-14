extends RefCounted
class_name VillageMapPaths
##
## Slot-aware paths for village map snapshots and the "active seed".
## - Directory layout:
##     user://villages/slot_<slot>/{seed}.vmap.json
##     user://villages/slot_<slot>/active.seed
## - If slot == 0, falls back to the legacy global: user://villages/…
##

var slot: int = 0

func _init(p_slot: int = 0) -> void:
	var s: int = max(0, p_slot)
	slot = s

func villages_dir() -> String:
	return "user://villages/slot_%d" % slot if slot > 0 else "user://villages"

static func ensure_user_dir(p_slot: int = 0) -> void:
	var dir: String = "user://villages/slot_%d" % p_slot if p_slot > 0 else "user://villages"
	DirAccess.make_dir_recursive_absolute(dir)

func ensure_dir() -> void:
	DirAccess.make_dir_recursive_absolute(villages_dir())

func snapshot_path_for_seed(seed: int) -> String:
	ensure_dir()
	return villages_dir().path_join("%d.vmap.json" % seed)

func tmp_path_for_seed(seed: int) -> String:
	ensure_dir()
	return villages_dir().path_join(".tmp_%d.vmap.json" % seed)

func active_seed_path() -> String:
	ensure_dir()
	return villages_dir().path_join("active.seed")
