extends Node2D
class_name VillageHexOverworld2

@export var ring_radius: int = 4
@export var button_side_px: float = 128.0
@export var center_on_viewport: bool = true
@export var debug_logging: bool = false

@onready var _base_layer: HexArtBaseLayer            = $Grid/BaseLayer as HexArtBaseLayer
@onready var _decor_layer: HexArtDecorLayer          = $Grid/DecorLayer as HexArtDecorLayer
@onready var _spawner: HexButtonSpawner              = $Buttons as HexButtonSpawner
@onready var _grid: HexGridService                   = $Services/HexGridService as HexGridService
@onready var _art: HexArtService                     = $Services/HexArtService as HexArtService
@onready var _seed: HexSeedService                   = $Services/HexSeedService as HexSeedService
@onready var _catalog: BaseTileCatalog               = $Services/BaseTileCatalog as BaseTileCatalog
@onready var _building_art: BuildingArtService       = $Services/BuildingArtService as BuildingArtService

const SaveManager := preload("res://persistence/SaveManager.gd")

func _ready() -> void:
	if debug_logging: print("[VHexOverworld2] _ready begin")

	var art: HexArtService = _find_hex_art_service()
	if art == null:
		art = get_node_or_null("Services/HexArtService") as HexArtService
	if art == null:
		art = HexArtService.new()
		add_child(art)
		if debug_logging: print("[VHexOverworld2] WARN: HexArtService node not found; using a temporary instance")

	var grid: HexGridService = get_node_or_null("Services/HexGridService") as HexGridService
	if grid == null:
		grid = HexGridService.new()
		add_child(grid)
		if debug_logging: print("[VHexOverworld2] WARN: HexGridService node not found; using a temporary instance")

	var seed_service: HexSeedService = _find_hex_seed_service()
	var seed: int = 0
	if seed_service != null:
		seed = seed_service.get_seed()
	else:
		var rng := RandomNumberGenerator.new()
		rng.randomize()
		seed = int((int(Time.get_ticks_usec()) << 1) ^ int(rng.randi()))
		if seed == 0:
			seed = 1
		if debug_logging:
			print("[VHexOverworld2] WARN: HexSeedService missing; using fallback seed=", seed)

	var catalog: BaseTileCatalog = _catalog
	if catalog == null:
		push_error("[VHexOverworld2] ERROR: Services/BaseTileCatalog node missing")
		return
	if debug_logging:
		var id_list: Array[String] = catalog.get_ids()
		print("[VHexOverworld2] catalog ids=", id_list.size())

	# -- Resolver (RefCounted) --
	var resolver: TileArtResolver = TileArtResolver.new()
	resolver.catalog = catalog

	# -- Builder (RefCounted) --
	var builder: VillageMapSnapshotBuilder = VillageMapSnapshotBuilder.new()

	# Slot-aware paths
	var active_slot: int = SaveManager.active_slot()
	var paths: VillageMapPaths = VillageMapPaths.new(active_slot)
	var schema: VillageMapSchema = VillageMapSchema.new()

	# Provider (RefCounted)
	var provider: VillageMapProvider = VillageMapProvider.new(paths, schema, builder, resolver)

	var adapter := HexArtSnapshotAdapter.new(art, grid, catalog)

	var radius: int = max(1, ring_radius)

	# ── Prefer authoritative VillageService snapshot, fall back to provider ──
	var vs := _find_village_service()
	var snapshot: Dictionary
	if vs != null:
		snapshot = vs.get_snapshot()
		# Live repaint on any VillageService changes
		if not vs.is_connected("snapshot_changed", Callable(self, "apply_map_snapshot")):
			vs.connect("snapshot_changed", Callable(self, "apply_map_snapshot"))
	else:
		snapshot = provider.get_or_build(seed, radius)

	# Ensure grid.tiles present
	if not snapshot.has("grid"):
		var grid_dict: Dictionary = {}
		grid_dict["tiles"] = snapshot.get("tiles", [])
		snapshot["grid"] = grid_dict
	elif snapshot.has("tiles"):
		var g: Dictionary = snapshot["grid"] as Dictionary
		if not g.has("tiles"):
			g["tiles"] = snapshot["tiles"]
			snapshot["grid"] = g

	var tiles_any: Variant = (snapshot.get("grid", {}) as Dictionary).get("tiles", [])
	var tile_count: int = (tiles_any as Array).size() if (tiles_any is Array) else 0
	if debug_logging:
		print("[VHexOverworld2] snapshot ready seed=", snapshot.get("seed", seed),
			" radius=", radius, " tiles=", tile_count, " slot=", active_slot)

	var base_layer: HexArtBaseLayer = _find_hex_base_layer()
	var decor_layer: HexArtDecorLayer = _find_hex_decor_layer()

	if debug_logging:
		print("[VHexOverworld2] layers base=", base_layer != null, " decor=", decor_layer != null)
	if base_layer == null or decor_layer == null:
		print("[VHexOverworld2] WARN: layers not found; snapshot loaded but rendering skipped")
		return

	# Always render locally to avoid 'early return' blank maps.
	adapter.render(snapshot, base_layer, decor_layer)
	if _building_art != null:
		_building_art.paint_postpass_for_snapshot(snapshot, _art, base_layer, decor_layer)

	var spawner := _find_hex_button_spawner()
	if spawner != null:
		if spawner.base_layer_path == NodePath(""):
			spawner.base_layer_path = base_layer.get_path()
		if spawner.has_method("spawn_buttons_for_radius_with_grid"):
			spawner.spawn_buttons_for_radius_with_grid(radius, grid)
		elif spawner.has_method("spawn_for_hex_disc"):
			spawner.spawn_for_hex_disc(radius)
	else:
		if debug_logging:
			print("[VHexOverworld2] WARN: HexButtonSpawner not found; no buttons spawned")
			
	var village_dir: String = "res://audio/village"
	var empty_playlist: Array[AudioStream] = [] as Array[AudioStream]
	var shuffle_tracks: bool = true
	var vol_db: float = 0.0
	var fade_s: float = 0.4
	var bus_name: String = "Master"

	# play_folder(dir_path, editor_playlist, shuffle, volume_db, fade_seconds, bus)
	MusicManager.play_folder(
		village_dir,
		empty_playlist,
		shuffle_tracks,
		vol_db,
		fade_s,
		bus_name
	)

	if debug_logging: print("[VHexOverworld2] _ready end")
	_center_view_on_origin(base_layer)

# --- helpers ----------------------------------------------------------------

func _find_village_service() -> VillageService:
	# Autoload first
	var n := get_tree().get_root().get_node_or_null("VillageService")
	if n is VillageService:
		return n
	# Then any node in group
	var g := get_tree().get_nodes_in_group("VillageService")
	if g.size() > 0 and g[0] is VillageService:
		return g[0] as VillageService
	return null

func _find_hex_base_layer() -> HexArtBaseLayer:
	var root := get_tree().get_current_scene()
	if root == null:
		return null
	var q: Array[Node] = []
	q.append(root)
	while not q.is_empty():
		var n: Node = q.pop_front()
		if n is HexArtBaseLayer:
			return n as HexArtBaseLayer
		for c in (n.get_children() as Array[Node]):
			q.append(c)
	return null

func _find_hex_decor_layer() -> HexArtDecorLayer:
	var root := get_tree().get_current_scene()
	if root == null:
		return null
	var q: Array[Node] = []
	q.append(root)
	while not q.is_empty():
		var n: Node = q.pop_front()
		if n is HexArtDecorLayer:
			return n as HexArtDecorLayer
		for c in (n.get_children() as Array[Node]):
			q.append(c)
	return null

func _find_hex_button_spawner() -> HexButtonSpawner:
	var root := get_tree().get_current_scene()
	if root == null:
		return null
	var q: Array[Node] = []
	q.append(root)
	while not q.is_empty():
		var n: Node = q.pop_front()
		if n is HexButtonSpawner:
			return n as HexButtonSpawner
		for c in (n.get_children() as Array[Node]):
			q.append(c)
	return null

func _find_hex_art_service() -> HexArtService:
	var root := get_tree().get_current_scene()
	if root == null:
		return null
	var q: Array[Node] = []
	q.append(root)
	while not q.is_empty():
		var n: Node = q.pop_front()
		if n is HexArtService:
			return n as HexArtService
		for c in (n.get_children() as Array[Node]):
			q.append(c)
	return null

func _find_hex_seed_service() -> HexSeedService:
	var root := get_tree().get_current_scene()
	if root == null:
		return null
	var q: Array[Node] = []
	q.append(root)
	while not q.is_empty():
		var n: Node = q.pop_front()
		if n is HexSeedService:
			return n as HexSeedService
		for c in (n.get_children() as Array[Node]):
			q.append(c)
	return null

func _read_active_seed_or_fallback() -> int:
	var paths := VillageMapPaths.new(SaveManager.active_slot())
	var p := paths.active_seed_path()
	if FileAccess.file_exists(p):
		var f := FileAccess.open(p, FileAccess.READ)
		if f != null:
			var txt: String = f.get_as_text().strip_edges()
			if txt.is_valid_int():
				return int(txt)
	return 0

# --- repaint API used by TileModalService ----------------------------------

func apply_map_snapshot(snap: Dictionary) -> void:
	if debug_logging:
		var tiles_a: Array = (snap.get("tiles", []) as Array)
		var tiles_b: Array = ((snap.get("grid", {}) as Dictionary).get("tiles", []) as Array)
		print("[VHexOverworld2] apply_map_snapshot tilesA=", tiles_a.size(), " tilesB=", tiles_b.size())

	# Ensure grid.tiles exists for the adapter (robust to legacy saves).
	if not snap.has("grid"):
		var grid_dict: Dictionary = {}
		grid_dict["tiles"] = snap.get("tiles", [])
		snap["grid"] = grid_dict
	elif snap.has("tiles"):
		var g: Dictionary = (snap["grid"] as Dictionary)
		if not g.has("tiles"):
			g["tiles"] = snap["tiles"]
			snap["grid"] = g

	var base_layer: HexArtBaseLayer = _base_layer
	var decor_layer: HexArtDecorLayer = _decor_layer
	if base_layer == null or decor_layer == null:
		if debug_logging:
			print("[VHexOverworld2] WARN: layers missing; skipping render")
		return

	var adapter := HexArtSnapshotAdapter.new(_art, _grid, _catalog)

	adapter.render(snap, base_layer, decor_layer)
	if _building_art != null:
		_building_art.paint_postpass_for_snapshot(snap, _art, base_layer, decor_layer)

func reload_map_snapshot() -> void:
	var paths := VillageMapPaths.new(SaveManager.active_slot())
	var seed: int = _read_active_seed_or_fallback()
	var snap_path: String = paths.snapshot_path_for_seed(seed)

	var snap: Dictionary = {}
	if FileAccess.file_exists(snap_path):
		var f := FileAccess.open(snap_path, FileAccess.READ)
		if f != null:
			var raw: Variant = JSON.parse_string(f.get_as_text())
			if raw is Dictionary:
				snap = raw as Dictionary
			f.close()

	apply_map_snapshot(snap)

func _center_view_on_origin(base_layer: HexArtBaseLayer) -> void:
	if not center_on_viewport or base_layer == null or _grid == null:
		return

	# World-space center of hex (0,0)
	var origin_world: Vector2 = _grid.cell_center_world(Vector2i(0, 0), base_layer)

	# If there’s an active Camera2D, move it to the origin.
	var cam := get_viewport().get_camera_2d()
	if cam != null:
		cam.global_position = origin_world
		if debug_logging:
			print("[VHexOverworld2] centered via Camera2D at ", origin_world)
		return

	# Otherwise, shift this Node2D so the origin lands in the viewport center.
	var vp_center := get_viewport_rect().size * 0.5
	var delta := vp_center - origin_world
	global_position += delta
	if debug_logging:
		print("[VHexOverworld2] centered node by delta=", delta, " origin_world=", origin_world, " vp_center=", vp_center)
