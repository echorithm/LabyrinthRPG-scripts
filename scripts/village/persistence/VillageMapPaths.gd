extends RefCounted
class_name VillageMapPaths

## Centralized paths for village map snapshots.

const USER_DIR: String = "user://villages"

static func ensure_user_dir() -> void:
	DirAccess.make_dir_recursive_absolute(USER_DIR)

func snapshot_path_for_seed(seed: int) -> String:
	return villages_dir().path_join("%d.vmap.json" % seed)

static func tmp_path_for_seed(seed: int) -> String:
	ensure_user_dir()
	return "%s/.tmp_%d.vmap.json" % [USER_DIR, seed]
	
func villages_dir() -> String:
	return "user://villages"


func active_seed_path() -> String:
	return villages_dir().path_join("active.seed")
