# res://scripts/village/persistence/VillageMapProvider.gd
extends RefCounted
class_name VillageMapProvider
##
## Load-or-build with persistence + robust tile mirroring.
## Saves to user://villages/slot_<slot>/{seed}.vmap.json and tracks slot‑scoped active.seed.
## Ensures both shapes exist: top-level "tiles" and "grid.tiles".
##

const DEBUG: bool = false

var _paths: VillageMapPaths
var _schema: VillageMapSchema
var _builder: VillageMapSnapshotBuilder
var _resolver: TileArtResolver
var _beauty: BiomeBeautyPass = null  # optional; may be null

func _init(
	paths: VillageMapPaths,
	schema: VillageMapSchema,
	builder: VillageMapSnapshotBuilder,
	resolver: TileArtResolver,
	beauty: BiomeBeautyPass = null
) -> void:
	_paths = paths
	_schema = schema
	_builder = builder
	_resolver = resolver
	_beauty = beauty

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
			var r_eff: int = _radius_in(loaded, radius)
			var touched: bool = _backfill_art_ids_if_missing(use_seed, r_eff, loaded)

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

	var snap: Dictionary = _builder.build(use_seed, max(1, radius))
	_ensure_tiles_view(snap)

	# Fill art ids for all tiles on first build
	var r_build: int = _radius_in(snap, radius)
	_fill_art_ids(use_seed, r_build, snap)
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
	var merged: Dictionary = _builder.build_from_merge(seed, max(1, radius), prior)
	_ensure_tiles_view(merged)

	var r_eff: int = _radius_in(merged, radius)
	_fill_art_ids(seed, r_eff, merged)  # respects locks; see _fill_art_ids
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

static func _extract_tiles(snap: Dictionary) -> Array[Dictionary]:
	var out: Array[Dictionary] = []

	# Prefer top-level when available
	if snap.has("tiles") and (snap["tiles"] is Array):
		for v in (snap["tiles"] as Array):
			if v is Dictionary:
				out.append(v as Dictionary)
		if out.size() > 0:
			return out

	# Fallback to grid.tiles
	if snap.has("grid") and (snap["grid"] is Dictionary):
		var g: Dictionary = snap["grid"] as Dictionary
		if g.has("tiles") and (g["tiles"] is Array):
			for v2 in (g["tiles"] as Array):
				if v2 is Dictionary:
					out.append(v2 as Dictionary)

	return out

static func _set_tiles(snap: Dictionary, tiles: Array[Dictionary]) -> void:
	# Write both views to keep parity
	snap["tiles"] = tiles
	var g: Dictionary = {}
	if snap.has("grid") and (snap["grid"] is Dictionary):
		g = snap["grid"] as Dictionary
	g["tiles"] = tiles
	snap["grid"] = g

static func _ensure_tiles_view(snap: Dictionary) -> void:
	var tiles: Array[Dictionary] = _extract_tiles(snap)
	_set_tiles(snap, tiles)

static func _radius_in(snap: Dictionary, fallback: int) -> int:
	# Prefer explicit grid.radius
	if snap.has("grid") and (snap["grid"] is Dictionary):
		var g: Dictionary = snap["grid"] as Dictionary
		var r_any: Variant = g.get("radius", 0)
		if typeof(r_any) == TYPE_INT:
			var r_val: int = int(r_any)
			if r_val > 0:
				return r_val

	# Derive from tiles if needed
	var tiles: Array[Dictionary] = _extract_tiles(snap)
	var r_derived: int = 0
	for t in tiles:
		var q: int = int(t.get("q", 0))
		var r: int = int(t.get("r", 0))
		r_derived = max(r_derived, abs(q))
		r_derived = max(r_derived, abs(r))
		r_derived = max(r_derived, abs(q + r))
	if r_derived > 0:
		return r_derived

	return max(1, fallback)

func _fill_art_ids(seed: int, radius: int, snap: Dictionary) -> void:
	if _resolver == null:
		return
	var tiles: Array[Dictionary] = _extract_tiles(snap)
	if tiles.is_empty():
		return
	var changed: bool = false
	for i: int in range(tiles.size()):
		var t: Dictionary = tiles[i]
		var cur: String = String(t.get("base_art_id", ""))
		if cur.strip_edges().is_empty():
			var q: int = int(t.get("q", 0))
			var r: int = int(t.get("r", 0))
			var kind: String = String(t.get("kind", ""))
			var art_id: String = _resolver.resolve_base_art_id(seed, q, r, kind, t, radius)
			if art_id != "":
				t["base_art_id"] = art_id
				tiles[i] = t
				changed = true
	if changed:
		_set_tiles(snap, tiles)

func _backfill_art_ids_if_missing(seed: int, radius: int, snap: Dictionary) -> bool:
	if _resolver == null:
		return false
	var tiles: Array[Dictionary] = _extract_tiles(snap)
	if tiles.is_empty():
		return false
	var changed: bool = false
	for i: int in range(tiles.size()):
		var t: Dictionary = tiles[i]
		var cur: String = String(t.get("base_art_id", ""))
		if cur.strip_edges().is_empty():
			var q: int = int(t.get("q", 0))
			var r: int = int(t.get("r", 0))
			var kind: String = String(t.get("kind", ""))
			var art_id: String = _resolver.resolve_base_art_id(seed, q, r, kind, t, radius)
			if art_id != "":
				t["base_art_id"] = art_id
				tiles[i] = t
				changed = true
	if changed:
		_set_tiles(snap, tiles)
	return changed

# --- IO helpers ---------------------------------------------------------------

func _write_dict_atomic(path: String, d: Dictionary) -> bool:
	# Write to tmp then move into place atomically.
	var tmp: String = _paths.tmp_path_for_seed(int(d.get("seed", 0)))
	var f_tmp: FileAccess = FileAccess.open(tmp, FileAccess.WRITE)
	if f_tmp == null:
		return false
	var txt: String = JSON.stringify(d, "\t")
	f_tmp.store_string(txt)
	f_tmp.flush()
	f_tmp.close()

	# Replace: remove existing then rename tmp -> final (absolute paths to avoid cwd issues)
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	var rc: int = DirAccess.rename_absolute(tmp, path)
	return rc == OK

func _write_active_seed(seed: int) -> void:
	var p: String = _paths.active_seed_path()
	var f: FileAccess = FileAccess.open(p, FileAccess.WRITE)
	if f != null:
		f.store_string(str(seed))
		f.flush()
		f.close()

func _read_active_seed(fallback: int) -> int:
	var p: String = _paths.active_seed_path()
	if not FileAccess.file_exists(p):
		return int(fallback)
	var f: FileAccess = FileAccess.open(p, FileAccess.READ)
	if f == null:
		return int(fallback)
	var s: String = f.get_as_text().strip_edges()
	f.close()
	return int(s) if s.is_valid_int() else int(fallback)

func _read_dict(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	var out: Dictionary = {}
	if typeof(parsed) == TYPE_DICTIONARY:
		out = parsed as Dictionary
	return out
