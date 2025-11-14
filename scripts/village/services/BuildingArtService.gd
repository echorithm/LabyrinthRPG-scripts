# File: res://scripts/village/services/BuildingArtService.gd
extends Node
class_name BuildingArtService

@export var debug_logging: bool = false

const CATALOG_PATH: String = "res://data/village/buildings_catalog.json"

# Special kinds mapped to building IDs in the catalog
const KIND_TO_BUILDING_ID: Dictionary = {
	"labyrinth": "labyrinth",
	"camp_core": "camp_core",
}

var _path_by_id: Dictionary[String, String] = {}
var _prefab_by_id: Dictionary[String, String] = {}
var _name_by_id: Dictionary[String, String] = {}
var _all_ids: Array[String] = []
var _entry_by_id: Dictionary[String, Dictionary] = {}

func _ready() -> void:
	if not is_in_group("building_art_service"):
		add_to_group("building_art_service")
	reload()

# -----------------------------------------------------------------------------
# Catalog
# -----------------------------------------------------------------------------
func reload() -> void:
	_path_by_id.clear()
	_prefab_by_id.clear()
	_name_by_id.clear()
	_entry_by_id.clear()
	_all_ids.clear()

	var entries: Dictionary = _load_catalog_entries()
	for id_v in entries.keys():
		var id: String = String(id_v)
		var e: Dictionary = entries[id] as Dictionary
		_entry_by_id[id] = e  # keep the raw entry for effects/role

		# Accept either { tile: { path } } or { assets: { path, prefab } }
		var tile_d: Dictionary = (e.get("tile", {}) as Dictionary)
		var assets_d: Dictionary = (e.get("assets", {}) as Dictionary)

		var path: String = ""
		if tile_d.has("path"):
			path = String(tile_d.get("path", ""))
		elif assets_d.has("path"):
			path = String(assets_d.get("path", ""))

		var prefab: String = ""
		if assets_d.has("prefab"):
			prefab = String(assets_d.get("prefab", ""))

		var name: String = String(e.get("name", id))

		if path != "": _path_by_id[id] = path
		if prefab != "": _prefab_by_id[id] = prefab
		_name_by_id[id] = name
		_all_ids.append(id)

	if debug_logging:
		var preview := ", ".join(_all_ids.slice(0, min(5, _all_ids.size())))
		print("[BuildingArt] reload | entries=", _all_ids.size(),
			" sample=[", preview, "]")

func _load_catalog_entries() -> Dictionary:
	var f := FileAccess.open(CATALOG_PATH, FileAccess.READ)
	if f == null:
		if debug_logging:
			print("[BuildingArt] WARN: catalog not found @ ", CATALOG_PATH)
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		if debug_logging:
			print("[BuildingArt] WARN: catalog JSON not a Dictionary @ ", CATALOG_PATH)
		return {}

	var d := parsed as Dictionary
	# If your catalog is wrapped as { "entries": { ... } }, unwrap it.
	if d.has("entries") and typeof(d["entries"]) == TYPE_DICTIONARY:
		return d["entries"] as Dictionary
	return d

# -----------------------------------------------------------------------------
# UI helpers
# -----------------------------------------------------------------------------
func get_building_ids() -> Array[String]:
	return _all_ids.duplicate()

func get_display_name(building_id: String) -> String:
	return _name_by_id.get(String(building_id), String(building_id))

func get_art_path(building_id: String) -> String:
	return _path_by_id.get(String(building_id), "")

func get_prefab(building_id: String) -> String:
	return _prefab_by_id.get(String(building_id), "")

# Convenience: resolve by kind (maps special kinds first)
func get_path_for_kind(kind_or_id: String) -> String:
	var key := String(kind_or_id)
	if KIND_TO_BUILDING_ID.has(key):
		key = String(KIND_TO_BUILDING_ID[key])
	return get_art_path(key)

# -----------------------------------------------------------------------------
# Post-render pass (with logging)
# -----------------------------------------------------------------------------
func paint_postpass_for_snapshot(
	snapshot: Dictionary,
	art: HexArtService,
	base_layer: HexArtBaseLayer,
	decor_layer: HexArtDecorLayer
) -> void:
	if snapshot.is_empty() or art == null or base_layer == null:
		if debug_logging:
			print("[BuildingArt] postpass: skipped (snapshot empty or missing layers/art)")
		return

	var grid_d: Dictionary = snapshot.get("grid", {})
	var tiles_any: Variant = grid_d.get("tiles", [])
	if typeof(tiles_any) != TYPE_ARRAY:
		if debug_logging:
			print("[BuildingArt] postpass: grid.tiles not an Array; abort.")
		return

	var total := 0
	var painted := 0
	var mapped := 0
	var generic := 0
	var direct := 0

	for v in (tiles_any as Array):
		if not (v is Dictionary):
			continue
		total += 1
		var t: Dictionary = v
		var q: int = int(t.get("q", 0))
		var r: int = int(t.get("r", 0))
		var render_key: int = int(t.get("render_key", 0))
		var kind: String = String(t.get("kind", ""))

		# 1) special kinds mapped to catalog ids
		if KIND_TO_BUILDING_ID.has(kind):
			var mapped_id: String = String(KIND_TO_BUILDING_ID[kind])
			if _ensure_and_paint(art, base_layer, q, r, render_key, mapped_id):
				painted += 1
			mapped += 1
			if debug_logging:
				print("[BuildingArt] paint special kind=", kind, " -> id=", mapped_id, " @(", q, ",", r, ")")
			continue

		# 2) generic building with base_art_id
		if kind == "building":
			var bid: String = String(t.get("base_art_id", ""))
			if bid != "":
				if _ensure_and_paint(art, base_layer, q, r, render_key, bid):
					painted += 1
				generic += 1
				if debug_logging:
					print("[BuildingArt] paint generic building id=", bid, " @(", q, ",", r, ")")
			else:
				if debug_logging:
					print("[BuildingArt] WARN: generic building missing base_art_id @(", q, ",", r, ")")
			continue

		# 3) direct building kind equals a catalog id (e.g., "alchemist_lab")
		if _path_by_id.has(kind):
			if _ensure_and_paint(art, base_layer, q, r, render_key, kind):
				painted += 1
			direct += 1
			if debug_logging:
				print("[BuildingArt] paint direct building kind=id=", kind, " @(", q, ",", r, ")")
			continue

	# Summary
	if debug_logging:
		print("[BuildingArt] postpass summary | tiles=", total, " painted=", painted,
			" mapped=", mapped, " generic=", generic, " direct=", direct)

# Ensure tileset exists and paint. Returns true if we issued a paint.
func _ensure_and_paint(
	art: HexArtService,
	base_layer: HexArtBaseLayer,
	q: int, r: int, render_key: int,
	building_id: String
) -> bool:
	if building_id == "":
		return false

	var path: String = get_art_path(building_id)
	if path == "":
		if debug_logging:
			print("[BuildingArt] WARN: no path for building_id='", building_id, "' (placeholder will be used)")
	else:
		art.ensure_source_for_id_with_path(building_id, path, false)
		if debug_logging:
			print("[BuildingArt] ensured source id='", building_id, "' path='", path, "'")

	art.paint_base_cell(base_layer, q, r, building_id, render_key)
	return true

func get_entry(building_id: String) -> Dictionary:
	return _entry_by_id.get(String(building_id), {})

func get_effect_for_rarity(building_id: String, rarity: String) -> Dictionary:
	var e: Dictionary = _entry_by_id.get(String(building_id), {}) as Dictionary
	if e.is_empty():
		return {}

	var base_any: Variant = e.get("base_effect", {})
	if typeof(base_any) != TYPE_DICTIONARY:
		return {}

	var base: Dictionary = base_any as Dictionary
	var eff_any: Variant = base.get(String(rarity), {})
	return eff_any as Dictionary if (eff_any is Dictionary) else {}
