extends Node
class_name BaseTileCatalog
##
## Enriched tile catalog with typed indices and backward-compatible API.
## - Keeps: get_ids(), get_file_path(id)
## - Adds: get_by_biome(), get_variants(), get_transitions_for(), filter_ids(), get_def()
## Deterministic & strictly typed for Godot 4.5.
##

const DEBUG: bool = true

## --- Types -------------------------------------------------------------------

class TileDef:
	var id: String
	var display_name: String = ""   
	var file_path: String

	var biome: String = ""
	var temperature: String = ""   # "hot|temperate|cold"
	var moisture: String = ""      # "dry|medium|wet"
	var elevation: String = ""     # "low|mid|high"

	var is_water: bool = false
	var is_transition: bool = false
	var tags: Array[String] = []
	var adjacency_overrides: Dictionary = {}
	var movement_cost: int = 1
	var buildable: bool = true
	var yields: Dictionary = {}

	func _init(d: Dictionary) -> void:
		id = String(d.get("id", ""))
		display_name = String(d.get("display_name", id)) 
		file_path = String(d.get("file_path", ""))

		biome = String(d.get("biome", ""))
		temperature = String(d.get("temperature", ""))
		moisture = String(d.get("moisture", ""))
		elevation = String(d.get("elevation", ""))

		is_water = bool(d.get("is_water", false))
		is_transition = bool(d.get("is_transition", false))

		var raw_tags: Variant = d.get("tags", [])
		if raw_tags is Array:
			var tmp: Array[String] = []
			for t in (raw_tags as Array):
				tmp.append(String(t))
			tags = tmp

		var raw_adj: Variant = d.get("adjacency_overrides", {})
		if raw_adj is Dictionary:
			adjacency_overrides = (raw_adj as Dictionary).duplicate(true)

		movement_cost = int(d.get("movement_cost", 1))
		buildable = bool(d.get("buildable", true))

		var raw_yields: Variant = d.get("yields", {})
		if raw_yields is Dictionary:
			yields = (raw_yields as Dictionary).duplicate(true)

	func to_dict() -> Dictionary:
		var out: Dictionary = {}
		out["id"] = id
		out["display_name"] = display_name
		out["file_path"] = file_path
		out["biome"] = biome
		out["temperature"] = temperature
		out["moisture"] = moisture
		out["elevation"] = elevation
		out["is_water"] = is_water
		out["is_transition"] = is_transition
		out["tags"] = tags.duplicate()
		out["adjacency_overrides"] = adjacency_overrides.duplicate(true)
		out["movement_cost"] = movement_cost
		out["buildable"] = buildable
		out["yields"] = yields.duplicate(true)
		return out

## --- Storage & indices -------------------------------------------------------

var _defs: Dictionary = {}                 # id -> TileDef
var _ids: Array[String] = []               # for backward compatibility
var _file_paths: Dictionary = {}           # id -> path

var _by_biome: Dictionary = {}             # biome -> Array[String]
var _by_key: Dictionary = {}               # "biome|temp|moist|elev" -> Array[String]
var _transitions: Dictionary = {}          # "from->to" -> Array[String]

@export var source_json: String = ""       # e.g., "res://assets/tiles/tiles.json"

## --- Lifecycle ---------------------------------------------------------------

func _ready() -> void:
	if source_json.strip_edges() != "":
		reload()
	add_to_group("BaseTileCatalog")   
	

## --- Logging -----------------------------------------------------------------

static func dbg(msg: String) -> void:
	if DEBUG:
		print("[BaseTileCatalog] ", msg)

## --- Public loading APIs -----------------------------------------------------

func reload() -> void:
	_clear_all()
	if source_json.strip_edges() == "":
		dbg("No source_json set; catalog is empty until register_* is called.")
		return

	var f := FileAccess.open(source_json, FileAccess.READ)
	if f == null:
		push_warning("BaseTileCatalog: cannot open %s" % source_json)
		return

	var text: String = f.get_as_text()
	f.close()
	var parsed_any: Variant = JSON.parse_string(text)
	if not (parsed_any is Dictionary):
		push_warning("BaseTileCatalog: invalid JSON in %s" % source_json)
		return
	var parsed: Dictionary = parsed_any

	var tiles_any: Variant = parsed.get("tiles", null)
	if not (tiles_any is Array):
		push_warning("BaseTileCatalog: no 'tiles' array in %s" % source_json)
		return
	var tiles: Array = tiles_any

	var ok_count: int = 0
	for raw_any in tiles:
		if raw_any is Dictionary:
			_register_one(raw_any as Dictionary)
			ok_count += 1

	_build_indices()
	dbg("Reload complete. tiles=%d" % ok_count)

func register_tile_defs(defs: Array[Dictionary]) -> void:
	for d in defs:
		_register_one(d)
	_build_indices()
	dbg("register_tile_defs: total=%d" % _ids.size())

func register_minimal(id_to_path: Dictionary) -> void:
	for id_key in id_to_path.keys():
		var id: String = String(id_key)
		var path: String = String(id_to_path[id_key])
		_register_one({"id": id, "file_path": path})
	_build_indices()
	dbg("register_minimal: total=%d" % _ids.size())

## --- Backward-compatible API -------------------------------------------------

func get_ids() -> Array[String]:
	return _ids.duplicate()

func get_file_path(id: String) -> String:
	return String(_file_paths.get(id, ""))

## --- New query APIs ----------------------------------------------------------

func get_def(id: String) -> TileDef:
	var td: Variant = _defs.get(id, null)
	if td == null:
		return TileDef.new({"id": id, "file_path": ""})
	return td as TileDef

func get_by_biome(b: String) -> Array[String]:
	var arr_any: Variant = _by_biome.get(b, [])
	var out: Array[String] = []
	if arr_any is Array:
		for x in (arr_any as Array):
			out.append(String(x))
	return out

func get_variants(biome: String, temperature: String, moisture: String, elevation: String) -> Array[String]:
	var key: String = _key4(biome, temperature, moisture, elevation)
	var arr_any: Variant = _by_key.get(key, [])
	var out: Array[String] = []
	if arr_any is Array:
		for x in (arr_any as Array):
			out.append(String(x))
	return out

func get_transitions_for(from_biome: String, to_biome: String) -> Array[String]:
	var key: String = "%s->%s" % [from_biome, to_biome]
	var arr_any: Variant = _transitions.get(key, [])
	var out: Array[String] = []
	if arr_any is Array:
		for x in (arr_any as Array):
			out.append(String(x))
	return out

func filter_ids(predicate: Callable) -> Array[String]:
	var out: Array[String] = []
	for id in _ids:
		var td := _defs[id] as TileDef
		if predicate.call(td):
			out.append(id)
	return out

## --- Internal helpers --------------------------------------------------------

func _clear_all() -> void:
	_defs.clear()
	_ids.clear()
	_file_paths.clear()
	_by_biome.clear()
	_by_key.clear()
	_transitions.clear()

func _register_one(d: Dictionary) -> void:
	var td := TileDef.new(d)
	if td.id == "":
		return
	_defs[td.id] = td
	if not _ids.has(td.id):
		_ids.append(td.id)
	_file_paths[td.id] = td.file_path

func _build_indices() -> void:
	_by_biome.clear()
	_by_key.clear()
	_transitions.clear()

	for id in _ids:
		var td := _defs[id] as TileDef

		# biome index
		if td.biome != "":
			if not _by_biome.has(td.biome):
				_by_biome[td.biome] = []
			var lst1: Array = _by_biome[td.biome]
			lst1.append(id)
			_by_biome[td.biome] = lst1

		# variants index
		var k: String = _key4(td.biome, td.temperature, td.moisture, td.elevation)
		if not _by_key.has(k):
			_by_key[k] = []
		var lst2: Array = _by_key[k]
		lst2.append(id)
		_by_key[k] = lst2

		# transitions (optional authoring)
		var bridges: Array[String] = []
		if td.adjacency_overrides.has("bridges"):
			var b_arr_any: Variant = td.adjacency_overrides["bridges"]
			if b_arr_any is Array:
				for v in (b_arr_any as Array):
					bridges.append(String(v))

		# Also allow a tag syntax like "bridge:desert->plains"
		for t in td.tags:
			if t.begins_with("bridge:"):
				bridges.append(t.replace("bridge:", ""))

		for pair in bridges:
			if not _transitions.has(pair):
				_transitions[pair] = []
			var lst3: Array = _transitions[pair]
			lst3.append(id)
			_transitions[pair] = lst3

func _key4(biome: String, t: String, m: String, e: String) -> String:
	return "%s|%s|%s|%s" % [biome, t, m, e]
