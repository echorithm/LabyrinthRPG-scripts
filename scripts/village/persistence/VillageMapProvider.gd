extends RefCounted
class_name VillageMapProvider
##
## Load-or-build with persistence + robust tile mirroring.
## Saves to user://villages/<seed>.vmap.json and tracks user://villages/active.seed
## Ensures both shapes exist: top-level "tiles" and "grid.tiles".
##

const DEBUG: bool = false

var _paths: VillageMapPaths
var _schema: VillageMapSchema
var _builder: VillageMapSnapshotBuilder
var _resolver: TileArtResolver
var _beauty: BiomeBeautyPass = null  # optional; wire later if desired

func _init(
	paths: VillageMapPaths,
	schema: VillageMapSchema,
	builder: VillageMapSnapshotBuilder,
	resolver: TileArtResolver
) -> void:
	_paths = paths
	_schema = schema
	_builder = builder
	_resolver = resolver

static func dbg(msg: String) -> void:
	if DEBUG:
		print("[VillageMapProvider] ", msg)

# --- Public API ---------------------------------------------------------------

## Primary entrypoint. Prefer on-disk JSON; build only if missing.
func get_or_build(seed: int, radius: int) -> Dictionary:
	var use_seed: int = _read_active_seed(seed)
	var path: String = _paths.snapshot_path_for_seed(use_seed)
	if DEBUG:
		print("[VillageMapProvider] get_or_build path=", path)

	# 1) Prefer existing on-disk snapshot
	if FileAccess.file_exists(path):
		var loaded: Dictionary = _read_dict(path)
		if not loaded.is_empty():
			_ensure_tiles_view(loaded)

			# Backfill ONLY missing art ids; do not overwrite user choices.
			var touched: bool = _backfill_art_ids_if_missing(use_seed, loaded)
			var valid_loaded: Dictionary = _schema.validate(loaded)
			_ensure_tiles_view(valid_loaded)

			# Optional beauty pass (visual only)
			if _beauty != null and _beauty.has_method("apply_visual_rules"):
				valid_loaded = _beauty.apply_visual_rules(valid_loaded, use_seed)
				_ensure_tiles_view(valid_loaded)

			# If we backfilled or validation added derived fields, write it back.
			if touched:
				_write_dict_atomic(path, valid_loaded)

			_write_active_seed(use_seed)
			return valid_loaded

	# 2) Build fresh if nothing to load
	if DEBUG:
		if use_seed != seed:
			print("[VillageMapProvider] active seed present: ", use_seed)
		else:
			print("[VillageMapProvider] no snapshot; building… seed=", seed, " radius=", radius)

	var snap: Dictionary = _builder.build(use_seed, radius)
	_ensure_tiles_view(snap)

	# Fill art ids for all tiles on first build
	_fill_art_ids(use_seed, snap)
	_ensure_tiles_view(snap)

	var valid: Dictionary = _schema.validate(snap)
	_ensure_tiles_view(valid)

	# Optional beauty pass
	if _beauty != null and _beauty.has_method("apply_visual_rules"):
		valid = _beauty.apply_visual_rules(valid, use_seed)
		_ensure_tiles_view(valid)

	_write_dict_atomic(path, valid)
	_write_active_seed(use_seed)
	return valid

## Merge-with-prior if exists; otherwise build.
func merge_or_build(seed: int, radius: int) -> Dictionary:
	var path: String = _paths.snapshot_path_for_seed(seed)
	var prior: Dictionary = _read_dict(path)
	if prior.is_empty():
		return get_or_build(seed, radius)

	_ensure_tiles_view(prior)
	var merged: Dictionary = _builder.build_from_merge(seed, radius, prior)
	_ensure_tiles_view(merged)

	_fill_art_ids(seed, merged)  # respects locks; see _fill_art_ids
	_ensure_tiles_view(merged)

	var valid: Dictionary = _schema.validate(merged)
	_ensure_tiles_view(valid)

	if _beauty != null and _beauty.has_method("apply_visual_rules"):
		valid = _beauty.apply_visual_rules(valid, seed)
		_ensure_tiles_view(valid)

	_write_dict_atomic(path, valid)
	return valid

## Explicit helpers for other systems (optional but handy)
func reload_from_disk_or_empty(seed: int) -> Dictionary:
	var path: String = _paths.snapshot_path_for_seed(seed)
	return _read_dict(path)

func save_snapshot(seed: int, snap: Dictionary) -> bool:
	var path: String = _paths.snapshot_path_for_seed(seed)
	_ensure_tiles_view(snap)
	var valid: Dictionary = _schema.validate(snap)
	_ensure_tiles_view(valid)
	return _write_dict_atomic(path, valid)

# --- Tile helpers -------------------------------------------------------------

static func _extract_tiles(snap: Dictionary) -> Array:
	# Prefer top-level when available
	if snap.has("tiles") and snap["tiles"] is Array:
		return snap["tiles"] as Array
	# Fallback to grid.tiles
	if snap.has("grid") and snap["grid"] is Dictionary:
		var g: Dictionary = snap["grid"] as Dictionary
		var arr_any: Variant = g.get("tiles", [])
		if arr_any is Array:
			return arr_any as Array
	return []

static func _set_tiles(snap: Dictionary, tiles: Array) -> void:
	# Write both views to keep parity
	snap["tiles"] = tiles
	var g: Dictionary = {}
	if snap.has("grid") and snap["grid"] is Dictionary:
		g = snap["grid"] as Dictionary
	g["tiles"] = tiles
	snap["grid"] = g

static func _ensure_tiles_view(snap: Dictionary) -> void:
	var tiles: Array = _extract_tiles(snap)
	_set_tiles(snap, tiles)

## Backfill ONLY tiles missing base_art_id; never overwrites existing values.
## Returns true if it modified the snapshot (so caller can write it back).
func _backfill_art_ids_if_missing(seed: int, snap: Dictionary) -> bool:
	var tiles: Array = _extract_tiles(snap)
	if tiles.is_empty():
		return false

	var grid_dict: Dictionary = (snap.get("grid", {}) as Dictionary)
	var radius: int = int(grid_dict.get("radius", 0))

	var changed: bool = false
	for i in tiles.size():
		var t_any: Variant = tiles[i]
		if not (t_any is Dictionary):
			continue
		var t: Dictionary = t_any as Dictionary

		var cur_id: String = String(t.get("base_art_id", ""))
		if cur_id != "":
			continue  # preserve user-picked art

		var st: Dictionary = (t.get("static", {}) as Dictionary)
		var hint: Dictionary = (st.get("biome_hint", {}) as Dictionary)
		var kind_str: String = String(t.get("kind", "wild"))
		var q: int = int(t.get("q", 0))
		var r: int = int(t.get("r", 0))

		var resolved: String = _resolver.resolve_base_art_id(
			seed, q, r, kind_str, hint, radius
		)
		t["base_art_id"] = resolved
		tiles[i] = t
		changed = true

	if changed:
		_set_tiles(snap, tiles)
		dbg("_backfill_art_ids_if_missing: filled some empty art ids")
	return changed

# --- Art population for new builds -------------------------------------------

func _fill_art_ids(seed: int, snap: Dictionary) -> void:
	var tiles: Array = _extract_tiles(snap)
	if tiles.is_empty():
		dbg("_fill_art_ids: no tiles present")
		return

	var grid_dict: Dictionary = (snap.get("grid", {}) as Dictionary)
	var radius: int = int(grid_dict.get("radius", 0))

	var filled: int = 0
	for i in tiles.size():
		var t_any: Variant = tiles[i]
		if not (t_any is Dictionary):
			continue
		var t: Dictionary = t_any as Dictionary

		var st: Dictionary = (t.get("static", {}) as Dictionary)
		var locked: bool = bool(t.get("art_locked", false)) or bool(st.get("art_locked", false))
		if locked and String(t.get("base_art_id", "")) != "":
			continue

		var hint: Dictionary = (st.get("biome_hint", {}) as Dictionary)
		var kind_str: String = String(t.get("kind", "wild"))
		var q: int = int(t.get("q", 0))
		var r: int = int(t.get("r", 0))

		var id: String = _resolver.resolve_base_art_id(seed, q, r, kind_str, hint, radius)
		t["base_art_id"] = id
		tiles[i] = t
		filled += 1

	_set_tiles(snap, tiles)
	dbg("_fill_art_ids: filled=%d" % filled)

# --- Persistence --------------------------------------------------------------

static func _read_dict(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	return (parsed as Dictionary) if (parsed is Dictionary) else {}

static func _write_dict_atomic(final_path: String, data: Dictionary) -> bool:
	var dir: String = final_path.get_base_dir()
	if dir != "":
		DirAccess.make_dir_recursive_absolute(dir)
	var tmp: String = dir.path_join(".tmp_" + final_path.get_file())
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return false
	# Pretty-print to keep diffs readable.
	f.store_string(JSON.stringify(data, "\t"))
	f.flush()
	f = null
	# On some platforms, rename fails if target exists; try remove then rename.
	if FileAccess.file_exists(final_path):
		DirAccess.remove_absolute(final_path)
	return DirAccess.rename_absolute(tmp, final_path) == OK

func _read_active_seed(default_seed: int) -> int:
	var p: String = _paths.active_seed_path()
	if not FileAccess.file_exists(p):
		return default_seed
	var f := FileAccess.open(p, FileAccess.READ)
	if f == null:
		return default_seed
	var txt: String = f.get_as_text().strip_edges()
	if txt.is_valid_int():
		return int(txt)
	return default_seed

func _write_active_seed(seed: int) -> void:
	var p: String = _paths.active_seed_path()
	var dir: String = p.get_base_dir()
	if dir != "":
		DirAccess.make_dir_recursive_absolute(dir)
	var f := FileAccess.open(p, FileAccess.WRITE)
	if f != null:
		f.store_line(str(seed))
		f.close()
		dbg("active.seed written: %s" % p)
