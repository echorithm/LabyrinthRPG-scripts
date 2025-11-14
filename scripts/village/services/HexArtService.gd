extends Node
class_name HexArtService

# NOTE: Project uses "assests" (intentional). Do not change.
const ENTRANCE_ABS := "res://assests/Hex/Tiles/hexMountainUndergroundGateClosed00.png"
const CAMP_CLEAR_ABS := "res://assests/Hex/Tiles/hexForestBroadleafClearing00.png"

# Only keep simple Z bands (global layering). No per-hex z or row math here.
const _Z_BAND_BASE := 0                 # base tiles live here
const _Z_BAND_DECOR := 100              # decor tiles sit a bit above base
const _Z_BAND_GRID  := 100_000_000      # grid overlay WELL above any tile

const _CANDIDATE_REL: Array[String] = [
	"Tiles/hexPlains00.png",
	"Tiles/hexForestBroadleaf00.png",
	"Tiles/hexWoodlands00.png",
	"Tiles/hexHills00.png",
	"Tiles/hexScrublands00.png",
	"Tiles/hexWetlands00.png",
	"Tiles/hexDirt00.png",
	"Base Tiles/hexPlains00.png",
	"Base Tiles/hexForestBroadleaf00.png",
	"Base Tiles/hexWoodlands00.png",
	"Base Tiles/hexHills00.png",
	"Base Tiles/hexScrublands00.png",
	"Base Tiles/hexWetlands00.png",
	"Base Tiles/hexDirt00.png"
]

# Roots are fixed to "assests"
const _ROOTS: Array[String] = ["res://assests/Hex"]

@export var debug_logging: bool = false
@export var verbose_tile_paint: bool = false
@export var cell_side_px: float = 0.0

@export var global_art_scale: float = 1.0
@export var fit_to_bbox_width: bool = false
@export var min_uniform_scale: float = 0.5
@export var max_uniform_scale: float = 1.2

@export var scale_x_global: float = .94
@export var scale_y_global: float = 1.0
@export var min_scale_x: float = 0.25
@export var max_scale_x: float = 4.0
@export var min_scale_y: float = 0.25
@export var max_scale_y: float = 4.0

@export var base_layer_path: NodePath
@export var decor_layer_path: NodePath
@export var grid_service_path: NodePath
@export var seed_service_path: NodePath

var _sid_by_art_id_base: Dictionary = {}
var _sid_by_art_id_decor: Dictionary = {}

var _base_layer: HexArtBaseLayer
var _decor_layer: HexArtDecorLayer
var _grid: HexGridService
var _seed: HexSeedService

var _base_tileset: TileSet
var _decor_tileset: TileSet

var _sid_entrance: int = -1
var _sid_camp: int = -1
var _random_sids: Array[int] = []

@export var bottom_bias_px: float = 0.0

const SQRT3 := 1.7320508075688772

func _log(tag: String, d: Dictionary = {}) -> void:
	if debug_logging:
		print("[HexArtService] ", tag, " | ", JSON.stringify(d))

func _ready() -> void:
	_bind()
	add_to_group("hex_art_service")

# ----------------------------------------------------------------------------- #
#                                PUBLIC API
# ----------------------------------------------------------------------------- #

func initialize_tilesets() -> void:
	_bind()

	_base_tileset = TileSet.new()
	_decor_tileset = TileSet.new()
	_configure_hex_tileset(_base_tileset)
	_configure_hex_tileset(_decor_tileset)

	_sid_entrance = _add_single_tile_source_bottom_anchor(_base_tileset, ENTRANCE_ABS)
	_sid_camp = _add_single_tile_source_bottom_anchor(_base_tileset, CAMP_CLEAR_ABS)

	_random_sids.clear()
	var added := 0
	for rel: String in _CANDIDATE_REL:
		var abs := _first_existing_under_roots(rel)
		if abs != "":
			_random_sids.append(_add_single_tile_source_bottom_anchor(_base_tileset, abs))
			added += 1

	_log("initialize_tilesets", {
		"entrance_sid": _sid_entrance,
		"camp_sid": _sid_camp,
		"random_sources": added,
		"base_sources": _base_tileset.get_source_count()
	})

	if _random_sids.is_empty():
		_random_sids.append(_ensure_placeholder_bottom_anchor(_base_tileset))
		_log("initialize_tilesets:fallback_placeholder")

	if _base_layer: _base_layer.ensure_tileset(_base_tileset)
	if _decor_layer: _decor_layer.ensure_tileset(_decor_tileset)

	_log("initialize_tilesets:end", {"decor_sources": _decor_tileset.get_source_count()})

# Demo fill: NO render ordering here. Caller/schema must provide y_sort overrides
# in higher-level painting; this method keeps y_origin at 0 for all tiles.
func paint_disk_random_except_special(radius: int) -> void:
	_bind()
	if _base_layer == null or _grid == null:
		_log("paint_disk:missing", {"base_layer": _base_layer != null, "grid": _grid != null})
		return

	_base_layer.clear_all()
	_base_layer.y_sort_enabled = true

	var coords: Array[Vector2i] = _grid.axial_disk(radius)
	var origin := Vector2i(0, 0)
	var camp := _choose_camp_neighbor(origin, coords)
	_log("paint_disk:start", {"radius": radius, "tiles": coords.size(), "camp": str(camp)})

	var painted := 0
	for qr in coords:
		var sid_to_paint := -1
		if qr == origin and _sid_entrance >= 0:
			sid_to_paint = _sid_entrance
		elif qr == camp and _sid_camp >= 0:
			sid_to_paint = _sid_camp
		else:
			var idx := 0
			if _seed != null and _random_sids.size() > 0:
				idx = _seed.roll_index(qr.x, qr.y, _random_sids.size())
			if _random_sids.size() > 0:
				sid_to_paint = _random_sids[idx]
			else:
				sid_to_paint = _ensure_placeholder_bottom_anchor(_base_tileset)

		var offset_cr := _grid.axial_to_offset(qr)
		_base_layer.set_cell(offset_cr, sid_to_paint, Vector2i.ZERO)

		# No schema key here; keep neutral.
		_apply_y_sort_for_cell(_base_layer, offset_cr, null)

		painted += 1
		if verbose_tile_paint:
			_log("paint_disk:tile", {
				"qr": str(qr),
				"offset": str(offset_cr),
				"sid": sid_to_paint,
				"origin": _debug_cell_origin(_base_layer, offset_cr),
				"z": _debug_cell_z(_base_layer, offset_cr)
			})

	_log("paint_disk:end", {"painted": painted})

# ----------------------------------------------------------------------------- #

func _choose_camp_neighbor(origin: Vector2i, coords: Array[Vector2i]) -> Vector2i:
	if _grid == null:
		return origin
	for n in _grid.neighbors(origin):
		if coords.has(n):
			return n
	return origin

func _configure_hex_tileset(ts: TileSet) -> void:
	ts.tile_shape = TileSet.TILE_SHAPE_HEXAGON
	ts.tile_offset_axis = TileSet.TILE_OFFSET_AXIS_HORIZONTAL   # pointy-top
	var bbox := Vector2i(256, 384)
	if _grid != null:
		bbox = _grid.expected_bbox()
	ts.tile_size = bbox
	_log("_configure_hex_tileset", {"tile_size": str(ts.tile_size), "have_grid": _grid != null})

func _compute_side_and_bottom_radius() -> Dictionary:
	var side := cell_side_px
	if side <= 0.0:
		side = (_grid.cell_side_px if _grid != null else 128.0)
	var is_pointy := (_grid.orientation_is_pointy() if _grid != null else true)
	var bottom_radius := (side if is_pointy else (SQRT3 * 0.5) * side)
	return {"side": side, "is_pointy": is_pointy, "bottom_radius": bottom_radius}

func _hex_bbox() -> Vector2:
	var side := (cell_side_px if cell_side_px > 0.0 else (_grid.cell_side_px if _grid != null else 128.0))
	var is_pointy := (_grid == null or _grid.orientation_is_pointy())
	var w := (SQRT3 * side) if is_pointy else (2.0 * side)
	var h := (2.0 * side) if is_pointy else (SQRT3 * side)
	return Vector2(w, h)

# --- anchor/scale helpers -----------------------------------------------------

func _apply_anchor_only(src: TileSetAtlasSource, tid: Vector2i, _path_for_logs: String) -> void:
	# DO NOT rescale here; just recompute anchors from the CURRENT texture size.
	var tex: Texture2D = src.texture
	var tex_w := 0.0
	var tex_h := 0.0
	if tex != null:
		tex_w = float(tex.get_width())
		tex_h = float(tex.get_height())

	var geom := _compute_side_and_bottom_radius()
	var bottom_radius := float(geom.get("bottom_radius", 0.0))

	var td := src.get_tile_data(tid, 0)
	td.texture_origin = Vector2(tex_w * 0.5, tex_h)
	td.texture_offset = Vector2(0.0, bottom_radius + bottom_bias_px)
	td.y_sort_origin = 0

	if debug_logging:
		print("[HexArtService] _apply_anchor_only path=%s size=(%.0f,%.0f) bottom_rad=%.1f"
			% [_path_for_logs, tex_w, tex_h, bottom_radius])

func _apply_anchor_and_scale(src: TileSetAtlasSource, tid: Vector2i, _path_for_logs: String) -> void:
	# ONE-TIME scaling at source creation.
	var geom := _compute_side_and_bottom_radius()
	var bottom_radius := float(geom.get("bottom_radius", 0.0))

	var tex_w := float(src.texture.get_width())
	var tex_h := float(src.texture.get_height())
	var bbox := _hex_bbox()

	var sx := scale_x_global
	var sy := scale_y_global

	# Compress X only to fit hex width if requested.
	if fit_to_bbox_width and tex_w > 0.0:
		var from_width := bbox.x / tex_w
		sx *= from_width

	sx = clamp(sx, min_scale_x, max_scale_x)
	sy = clamp(sy, min_scale_y, max_scale_y)

	if abs(sx - 1.0) > 0.001 or abs(sy - 1.0) > 0.001:
		var img: Image = null
		if src.texture is Texture2D:
			img = (src.texture as Texture2D).get_image()
		if img == null:
			img = Image.create(int(tex_w), int(tex_h), false, Image.FORMAT_RGBA8)
			img.fill(Color(1, 0, 1, 1))

		var new_w := int(round(tex_w * sx))
		var new_h := int(round(tex_h * sy))
		if new_w < 1: new_w = 1
		if new_h < 1: new_h = 1

		img.resize(new_w, new_h, Image.INTERPOLATE_LANCZOS)
		var scaled_tex := ImageTexture.create_from_image(img)

		src.texture = scaled_tex
		src.texture_region_size = scaled_tex.get_size()
		tex_w = float(new_w)
		tex_h = float(new_h)

	var td := src.get_tile_data(tid, 0)
	td.texture_origin = Vector2(tex_w * 0.5, tex_h)
	td.texture_offset = Vector2(0.0, bottom_radius + bottom_bias_px)
	td.y_sort_origin = 0

	if debug_logging:
		print("[HexArtService] _apply_anchor_and_scale path=%s scaled_size=(%.0f,%.0f) bbox=%s sx=%.3f sy=%.3f"
			% [_path_for_logs, tex_w, tex_h, str(bbox), sx, sy])

# --- source creation ----------------------------------------------------------

func _add_single_tile_source_bottom_anchor(ts: TileSet, path: String) -> int:
	var tex := load(path) as Texture2D
	if tex == null:
		_log("add_source:missing", {"path": path})
		tex = _magenta_texture()
	else:
		_log("add_source:ok", {"path": path})

	var src := TileSetAtlasSource.new()
	src.texture = tex
	src.texture_region_size = tex.get_size()
	src.set_meta("orig_path", path)

	var sid := ts.add_source(src)
	var tid := Vector2i(0, 0)
	src.create_tile(tid)

	# ONE-TIME scale + anchor at creation
	_apply_anchor_and_scale(src, tid, path)
	return sid

func _ensure_placeholder_bottom_anchor(ts: TileSet) -> int:
	var tex := _magenta_texture()
	var src := TileSetAtlasSource.new()
	src.texture = tex
	src.texture_region_size = tex.get_size()
	src.set_meta("orig_path", "(placeholder)")

	var sid := ts.add_source(src)
	var tid := Vector2i(0, 0)
	src.create_tile(tid)

	# ONE-TIME scale + anchor at creation
	_apply_anchor_and_scale(src, tid, "(placeholder)")
	return sid

func _first_existing_under_roots(rel: String) -> String:
	for r in _ROOTS:
		var p := r.path_join(rel)
		if ResourceLoader.exists(p):
			return p
	_log("path_not_found_under_assests", {"rel": rel})
	return ""

func _magenta_texture() -> Texture2D:
	var img := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	img.fill(Color(1, 0, 1))
	return ImageTexture.create_from_image(img)

# --- runtime wiring / reanchor ------------------------------------------------

func _bind() -> void:
	_base_layer = (get_node_or_null(base_layer_path) as HexArtBaseLayer)
	_decor_layer = (get_node_or_null(decor_layer_path) as HexArtDecorLayer)
	_grid = (get_node_or_null(grid_service_path) as HexGridService)
	_seed = (get_node_or_null(seed_service_path) as HexSeedService)
	_log("bind", {
		"base_layer": _base_layer != null,
		"decor_layer": _decor_layer != null,
		"grid": _grid != null,
		"seed": _seed != null
	})

func ensure_tilesets_from_catalog(
	catalog: BaseTileCatalog,
	base_layer: HexArtBaseLayer = null,
	decor_layer: HexArtDecorLayer = null
) -> void:
	if base_layer == null or decor_layer == null:
		_bind()
		if base_layer == null: base_layer = _base_layer
		if decor_layer == null: decor_layer = _decor_layer

	if base_layer == null or decor_layer == null:
		_log("ensure_tilesets_from_catalog:missing_layers", {
			"have_base_layer": base_layer != null,
			"have_decor_layer": decor_layer != null,
			"export_base_path": String(base_layer_path),
			"export_decor_path": String(decor_layer_path)
		})
		return

	var created_base := false
	var created_decor := false
	if _base_tileset == null:
		_base_tileset = TileSet.new()
		_configure_hex_tileset(_base_tileset)
		_sid_by_art_id_base.clear()
		created_base = true
	if _decor_tileset == null:
		_decor_tileset = TileSet.new()
		_configure_hex_tileset(_decor_tileset)
		_sid_by_art_id_decor.clear()
		created_decor = true

	base_layer.ensure_tileset(_base_tileset)
	decor_layer.ensure_tileset(_decor_tileset)

	# Y-sort ON – but per-cell origin must come from schema via overrides.
	base_layer.y_sort_enabled = true
	decor_layer.y_sort_enabled = true

	# >>> Debug: show scaling config that will be used on creation <<<
	#print("[HexArtService] tileset build: fit_to_bbox_width=", fit_to_bbox_width,
	#	  " scale_x_global=", scale_x_global, " scale_y_global=", scale_y_global,
	#	  " min_x=", min_scale_x, " max_x=", max_scale_x,
	#	  " min_y=", min_scale_y, " max_y=", max_scale_y)

	var ids := catalog.get_ids()
	var added := 0
	for id in ids:
		var path := catalog.get_file_path(id)
		if path == "":
			continue
		if not _sid_by_art_id_base.has(id):
			var sid_b := _add_single_tile_source_bottom_anchor(_base_tileset, path)
			_sid_by_art_id_base[id] = sid_b
			added += 1
		if not _sid_by_art_id_decor.has(id):
			var sid_d := _add_single_tile_source_bottom_anchor(_decor_tileset, path)
			_sid_by_art_id_decor[id] = sid_d
			added += 1

	_log("ensure_tilesets_from_catalog:end", {
		"created_base": created_base,
		"created_decor": created_decor,
		"sources_added": added,
		"base_source_count": _base_tileset.get_source_count(),
		"decor_source_count": _decor_tileset.get_source_count()
	})

# ---------- Paint API -------------------------------------------------------- #

# NOTE: These two paint_* methods accept an OPTIONAL y_origin override.
# PASS YOUR SCHEMA'S render_key HERE. If null, we do NOT invent one (y_sort_origin=0).

func paint_base_cell(base_layer: HexArtBaseLayer, q: int, r: int, base_art_id: String, y_origin_override: Variant = null) -> void:
	if base_layer == null or _base_tileset == null:
		return

	var sid := -1
	if _sid_by_art_id_base.has(base_art_id):
		sid = int(_sid_by_art_id_base[base_art_id])
	else:
		# Catalog first, then fallback to BuildingArtService
		var path := _resolve_path_for_art_id(base_art_id)
		if path != "":
			sid = _add_single_tile_source_bottom_anchor(_base_tileset, path)
		else:
			sid = _ensure_placeholder_bottom_anchor(_base_tileset)
		_sid_by_art_id_base[base_art_id] = sid

	if _grid == null: _bind()
	var offset_cr := (_grid.axial_to_offset(Vector2i(q, r)) if _grid != null else Vector2i(q, r))

	base_layer.y_sort_enabled = true
	base_layer.set_cell(offset_cr, sid, Vector2i.ZERO)

	_apply_y_sort_for_cell(base_layer, offset_cr, y_origin_override)

	if verbose_tile_paint:
		_log("paint_base_cell", {
			"qr": str(Vector2i(q, r)),
			"offset": str(offset_cr),
			"sid": sid,
			"origin": _debug_cell_origin(base_layer, offset_cr),
			"z": _debug_cell_z(base_layer, offset_cr),
			"override": (y_origin_override != null)
		})

func paint_decor_cell(decor_layer: HexArtDecorLayer, q: int, r: int, decor_art_id: String, y_origin_override: Variant = null) -> void:
	if decor_layer == null or _decor_tileset == null:
		return

	var sid := -1
	if _sid_by_art_id_decor.has(decor_art_id):
		sid = int(_sid_by_art_id_decor[decor_art_id])
	else:
		var path := _resolve_path_for_art_id(decor_art_id)
		if path != "":
			sid = _add_single_tile_source_bottom_anchor(_decor_tileset, path)
		else:
			sid = _ensure_placeholder_bottom_anchor(_decor_tileset)
		_sid_by_art_id_decor[decor_art_id] = sid

	if _grid == null: _bind()
	var offset_cr := (_grid.axial_to_offset(Vector2i(q, r)) if _grid != null else Vector2i(q, r))

	decor_layer.y_sort_enabled = true
	decor_layer.set_cell(offset_cr, sid, Vector2i.ZERO)

	# No artificial bias; schema key should already disambiguate.
	_apply_y_sort_for_cell(decor_layer, offset_cr, y_origin_override)

	if verbose_tile_paint:
		_log("paint_decor_cell", {
			"qr": str(Vector2i(q, r)),
			"offset": str(offset_cr),
			"sid": sid,
			"origin": _debug_cell_origin(decor_layer, offset_cr),
			"z": _debug_cell_z(decor_layer, offset_cr),
			"override": (y_origin_override != null)
		})

# ---------- Runtime wiring & idempotent reanchor ------------------------------ #

func attach_runtime(
	base_layer: HexArtBaseLayer,
	decor_layer: HexArtDecorLayer,
	grid: HexGridService,
	seed_service: HexSeedService = null
) -> void:
	_base_layer = base_layer
	_decor_layer = decor_layer
	_grid = grid
	_seed = seed_service

	if _base_layer:
		_base_layer.y_sort_enabled = true
		_base_layer.z_as_relative = false
		_base_layer.z_index = _Z_BAND_BASE
	if _decor_layer:
		_decor_layer.y_sort_enabled = true
		_decor_layer.z_as_relative = false
		_decor_layer.z_index = _Z_BAND_DECOR

	# If your HexGridService exposes a TileMap/TileMapLayer for the outline, set it HIGH.
	if _grid != null and _grid.has_method("get_outline_layer"):
		var grid_layer := _grid.get_outline_layer() as TileMapLayer
		if grid_layer != null:
			grid_layer.y_sort_enabled = false
			grid_layer.z_as_relative = false
			grid_layer.z_index = _Z_BAND_GRID
			_log("grid_layer_z", {
				"name": grid_layer.name,
				"z_index": grid_layer.z_index,
				"y_sort": grid_layer.y_sort_enabled
			})
		else:
			_log("grid_layer_z:missing_layer")

	_log("attach_runtime", {
		"base_layer": _base_layer != null,
		"decor_layer": _decor_layer != null,
		"grid": _grid != null,
		"seed": _seed != null,
		"base_z": (_base_layer.z_index if _base_layer != null else -1),
		"decor_z": (_decor_layer.z_index if _decor_layer != null else -1)
	})

func reanchor_all_sources() -> void:
	# IMPORTANT: No scaling here. Only recompute anchors/offsets from current texture size.
	if _grid == null:
		_bind()

	var tilesets: Array[TileSet] = []
	if _base_tileset != null: tilesets.append(_base_tileset)
	if _decor_tileset != null: tilesets.append(_decor_tileset)

	for ts in tilesets:
		var sc := ts.get_source_count()
		for i in range(sc):
			var src := ts.get_source(i)
			if src is TileSetAtlasSource:
				var atlas := src as TileSetAtlasSource
				var tid := Vector2i(0, 0)
				if atlas.has_tile(tid):
					var meta_path := (String(atlas.get_meta("orig_path")) if atlas.has_meta("orig_path") else "")
					_apply_anchor_only(atlas, tid, meta_path)

	if debug_logging:
		print("[HexArtService] reanchor_all_sources: anchors refreshed (no rescale)")

# ----------------------------------------------------------------------------- #
#                              PRIVATE HELPERS
# ----------------------------------------------------------------------------- #

# y_origin_override:
#  - if provided (not null), we use it verbatim (expected: schema's render_key).
#  - otherwise we DO NOT invent one: y_sort_origin = 0.
func _apply_y_sort_for_cell(layer: TileMapLayer, offset_cr: Vector2i, y_origin_override: Variant = null) -> void:
	var td := layer.get_cell_tile_data(offset_cr)
	if td == null:
		_log("apply_y_sort:missing_tiledata", {"offset": str(offset_cr)})
		return

	td.z_index = _band_for_layer(layer)
	td.y_sort_origin = (int(y_origin_override) if y_origin_override != null else 0)

	if verbose_tile_paint:
		var axial: Vector2i = (_grid.offset_to_axial(offset_cr) if _grid != null else offset_cr)
		_log("apply_y_sort", {
			"layer": layer.name,
			"offset": str(offset_cr),
			"qr": str(axial),
			"y_origin": td.y_sort_origin,
			"z_band": td.z_index,
			"override": (y_origin_override != null)
		})

func _debug_cell_origin(layer: TileMapLayer, offset_cr: Vector2i) -> int:
	var td := layer.get_cell_tile_data(offset_cr)
	return (td.y_sort_origin if td != null else -1)

func _debug_cell_z(layer: TileMapLayer, offset_cr: Vector2i) -> int:
	var td := layer.get_cell_tile_data(offset_cr)
	return (td.z_index if td != null else -999)

func _band_for_layer(layer: TileMapLayer) -> int:
	if _decor_layer != null and layer == _decor_layer:
		return _Z_BAND_DECOR
	return _Z_BAND_BASE

# --- CLICK / CELL DEBUG (AXIAL) ----------------------------------------------

func debug_info_for_axial(axial: Vector2i) -> String:
	var lines: Array[String] = []
	lines.append("--- HexArt Debug @ axial=%s ---" % str(axial))

	var layers: Array[TileMapLayer] = []
	if _base_layer != null: layers.append(_base_layer)
	if _decor_layer != null: layers.append(_decor_layer)

	var offset: Vector2i = axial
	if _grid != null:
		offset = _grid.axial_to_offset(axial)

	for layer in layers:
		var td := layer.get_cell_tile_data(offset)
		var sid: int = layer.get_cell_source_id(offset)
		var alt: int = layer.get_cell_alternative_tile(offset)

		var src_path := ""
		if sid >= 0 and layer.tile_set != null:
			var src := layer.tile_set.get_source(sid)
			if src is TileSetAtlasSource:
				var atlas := src as TileSetAtlasSource
				if atlas.has_meta("orig_path"):
					src_path = String(atlas.get_meta("orig_path"))

		var local: Vector2 = layer.map_to_local(offset)
		var y_origin := (td.y_sort_origin if td != null else -1)
		var z_index := (td.z_index if td != null else -1)

		lines.append(
			"[Layer=%s] offset=%s local=%s sid=%d alt=%d y_origin=%d z=%d src=%s"
			% [layer.name, str(offset), str(local), sid, alt, y_origin, z_index, src_path]
		)

		if td != null:
			lines.append("  tex_origin=%s tex_offset=%s" % [str(td.texture_origin), str(td.texture_offset)])

	return "\n".join(lines)

func print_debug_for_axial(axial: Vector2i) -> void:
	var report := debug_info_for_axial(axial)
	_log("cell_debug", {"report": report})
	print(report)

# --- extra utilities ----------------------------------------------------------

func ensure_source_for_id_with_path(id: String, path: String, for_decor: bool = false) -> void:
	if id == "" or path == "":
		return
	if for_decor:
		if _decor_tileset == null:
			_decor_tileset = TileSet.new()
			_configure_hex_tileset(_decor_tileset)
		if not _sid_by_art_id_decor.has(id):
			var sid := _add_single_tile_source_bottom_anchor(_decor_tileset, path)
			_sid_by_art_id_decor[id] = sid
		if _decor_layer != null:
			_decor_layer.ensure_tileset(_decor_tileset)
	else:
		if _base_tileset == null:
			_base_tileset = TileSet.new()
			_configure_hex_tileset(_base_tileset)
		if not _sid_by_art_id_base.has(id):
			var sid := _add_single_tile_source_bottom_anchor(_base_tileset, path)
			_sid_by_art_id_base[id] = sid
		if _base_layer != null:
			_base_layer.ensure_tileset(_base_tileset)

func _resolve_path_for_art_id(art_id: String) -> String:
	# 1) Try the base tile catalog
	var catalog := BaseTileCatalog.new()
	var p := catalog.get_file_path(art_id)
	if p != "":
		return p
	# 2) Ask BuildingArtService (by kind id)
	var bas: Node = get_tree().get_first_node_in_group("building_art_service")
	if bas != null and bas.has_method("get_path_for_kind"):
		var pv: Variant = bas.call("get_path_for_kind", art_id)
		if pv is String and String(pv).begins_with("res://"):
			return String(pv)
	return ""
