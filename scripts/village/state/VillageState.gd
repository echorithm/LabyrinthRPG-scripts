extends Node

var _map: Dictionary = {}                  # validated snapshot
var _radius: int = 0
var _seed: int = 0
var _path_helper: VillageMapPaths = VillageMapPaths.new()

func _ready() -> void:
	var app: Node = get_node_or_null(^"/root/AppPhase")
	var in_menu: bool = (app != null and app.has_method("in_menu") and bool(app.call("in_menu")))
	# Avoid creating any village files while in the main menu and no save exists yet.
	if in_menu and not SaveManager.meta_exists():
		return
	load_active_or_defaults()

func load_active_or_defaults() -> void:
	var seed_path: String = VillageMapPaths.new().active_seed_path()
	if FileAccess.file_exists(seed_path):
		var f: FileAccess = FileAccess.open(seed_path, FileAccess.READ)
		var txt: String = f.get_as_text()
		_seed = int(txt)
		f.close()
	else:
		_seed = randi()

	var snap_path: String = VillageMapPaths.new().snapshot_path_for_seed(_seed)
	if FileAccess.file_exists(snap_path):
		var f2: FileAccess = FileAccess.open(snap_path, FileAccess.READ)
		var txt2: String = f2.get_as_text()
		f2.close()
		var raw: Variant = JSON.parse_string(txt2)
		if raw is Dictionary:
			_map = VillageMapSchema.validate(raw as Dictionary)
		else:
			_map = VillageMapSchema.defaults()
	else:
		_map = VillageMapSchema.defaults()
	_save_seed_file()

	var grid_any: Variant = _map.get("grid", {})
	var grid: Dictionary = (grid_any if grid_any is Dictionary else {}) as Dictionary
	_radius = int(grid.get("radius", 0))

func save_current() -> void:
	var vpaths: VillageMapPaths = VillageMapPaths.new()
	var snap_path: String = vpaths.snapshot_path_for_seed(_seed)
	var tmp: String = vpaths.tmp_path_for_seed(_seed)
	VillageMapPaths.ensure_user_dir()
	var f: FileAccess = FileAccess.open(tmp, FileAccess.WRITE)
	f.store_string(JSON.stringify(_map, "  "))
	f.flush()
	f.close()
	if FileAccess.file_exists(snap_path):
		DirAccess.remove_absolute(snap_path)
	DirAccess.rename_absolute(tmp, snap_path)

func _save_seed_file() -> void:
	VillageMapPaths.ensure_user_dir()
	var f: FileAccess = FileAccess.open(VillageMapPaths.new().active_seed_path(), FileAccess.WRITE)
	f.store_string(str(_seed))
	f.close()

func get_tile(qr: Vector2i) -> Dictionary:
	var grid_any: Variant = _map.get("grid", {})
	var grid: Dictionary = (grid_any if grid_any is Dictionary else {}) as Dictionary
	var tiles_any: Variant = grid.get("tiles", [])
	var tiles: Array = (tiles_any if tiles_any is Array else []) as Array
	for i in tiles.size():
		var t_any: Variant = tiles[i]
		if t_any is Dictionary:
			var t: Dictionary = t_any as Dictionary
			if int(t.get("q", 0)) == qr.x and int(t.get("r", 0)) == qr.y:
				return t
	return {}

func set_tile_art(qr: Vector2i, art_id: String) -> void:
	var grid_any: Variant = _map.get("grid", {})
	var grid: Dictionary = (grid_any if grid_any is Dictionary else {}) as Dictionary
	var tiles_any: Variant = grid.get("tiles", [])
	var tiles: Array = (tiles_any if tiles_any is Array else []) as Array
	for i in tiles.size():
		var t_any: Variant = tiles[i]
		if t_any is Dictionary:
			var t: Dictionary = t_any as Dictionary
			if int(t.get("q", 0)) == qr.x and int(t.get("r", 0)) == qr.y:
				t["base_art_id"] = art_id
				var validated: Dictionary = VillageMapSchema.validate({
					"grid": {"radius": _radius, "tiles": [t]}
				})
				var vtiles_any: Variant = (validated.get("grid", {}) as Dictionary).get("tiles", [])
				var vt_arr: Array = (vtiles_any if vtiles_any is Array else []) as Array
				var coerced: Dictionary = (vt_arr[0] if vt_arr.size() > 0 and vt_arr[0] is Dictionary else {}) as Dictionary
				tiles[i] = coerced
				_map["grid"] = {"radius": _radius, "tiles": tiles}
				_touch_meta()
				return

func set_tile_kind(qr: Vector2i, kind: String) -> void:
	# No direct reference to VillageMapSchema.TILE_KINDS – we rely on schema.validate().
	var grid_any: Variant = _map.get("grid", {})
	var grid: Dictionary = (grid_any if grid_any is Dictionary else {}) as Dictionary
	var tiles_any: Variant = grid.get("tiles", [])
	var tiles: Array = (tiles_any if tiles_any is Array else []) as Array
	for i in tiles.size():
		var t_any: Variant = tiles[i]
		if t_any is Dictionary:
			var t: Dictionary = t_any as Dictionary
			if int(t.get("q", 0)) == qr.x and int(t.get("r", 0)) == qr.y:
				t["kind"] = kind
				var validated: Dictionary = VillageMapSchema.validate({
					"grid": {"radius": _radius, "tiles": [t]}
				})
				var vt_any: Variant = (validated.get("grid", {}) as Dictionary).get("tiles", [])
				var vt_arr: Array = (vt_any if vt_any is Array else []) as Array
				var coerced: Dictionary = (vt_arr[0] if vt_arr.size() > 0 and vt_arr[0] is Dictionary else {}) as Dictionary
				tiles[i] = coerced
				_map["grid"] = {"radius": _radius, "tiles": tiles}
				_touch_meta()
				return

func _touch_meta() -> void:
	var meta_any: Variant = _map.get("meta", {})
	var meta: Dictionary = (meta_any if meta_any is Dictionary else {}) as Dictionary
	meta["edited_at"] = Time.get_unix_time_from_system()
	_map["meta"] = meta

func radius() -> int: return _radius
func seed() -> int: return _seed
