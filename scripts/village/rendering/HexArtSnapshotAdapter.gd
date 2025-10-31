extends RefCounted
class_name HexArtSnapshotAdapter

## Renders a validated snapshot by delegating to HexArtService.
## No randomness; paints exactly what the snapshot specifies.
## Render priority comes EXCLUSIVELY from schema-computed render_key.

var _art: HexArtService
var _grid: HexGridService
var _catalog: BaseTileCatalog

func _init(art: HexArtService, grid: HexGridService, catalog: BaseTileCatalog) -> void:
	_art = art
	_grid = grid
	_catalog = catalog

func render(
	snapshot: Dictionary,
	base_layer: HexArtBaseLayer = null,
	decor_layer: HexArtDecorLayer = null
) -> void:
	if snapshot.is_empty():
		print("[HexArtSnapshotAdapter] empty snapshot; nothing to render")
		return
	if base_layer == null or decor_layer == null:
		print("[HexArtSnapshotAdapter] ERROR: render aborted; layer arguments are null")
		return

	# Use whatever settings the HexArtService node already has.
	_art.attach_runtime(base_layer, decor_layer, _grid, null)
	_art.ensure_tilesets_from_catalog(_catalog, base_layer, decor_layer)
	_art.reanchor_all_sources()  # applies current Inspector values only

	base_layer.y_sort_enabled = true
	decor_layer.y_sort_enabled = true

	# Collect tiles strictly typed (no implicit reordering).
	var grid_d: Dictionary = snapshot.get("grid", {})
	var tiles_any: Variant = grid_d.get("tiles", [])
	var tiles: Array[Dictionary] = []
	if tiles_any is Array:
		for v in (tiles_any as Array):
			if v is Dictionary:
				tiles.append(v as Dictionary)

	# Clear layers before paint
	if base_layer.has_method("clear"):
		base_layer.clear()
	if decor_layer.has_method("clear"):
		decor_layer.clear()

	var painted := 0
	for td in tiles:
		var q: int = int(td.get("q", 0))
		var r: int = int(td.get("r", 0))

		# Source of truth for priority: UNIQUE, schema-computed render_key.
		var render_key: int = int(td.get("render_key", 0))

		# Base layer
		var base_art_id: String = String(td.get("base_art_id", ""))
		if base_art_id != "":
			_art.paint_base_cell(base_layer, q, r, base_art_id, render_key)
			painted += 1

		# Decor layer(s) – painted at same y_origin; decor is above via z-band.
		var decor_any: Variant = td.get("decor_art_ids", [])
		if decor_any is Array:
			for did in (decor_any as Array):
				var decor_id: String = String(did)
				if decor_id == "":
					continue
				_art.paint_decor_cell(decor_layer, q, r, decor_id, render_key)

	# After all base paints, run building-kind overrides (labyrinth, camp_core, per-building kinds)
	var bas: Node = _art.get_tree().get_first_node_in_group("building_art_service")
	if bas != null and bas.has_method("apply_overrides_after_render"):
		bas.call("apply_overrides_after_render", _art, base_layer, snapshot)

	print("[HexArtSnapshotAdapter] render | painted=", painted)
