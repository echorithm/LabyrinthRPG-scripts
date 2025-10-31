extends RefCounted
class_name BiomeBeautyPass

##
# Visual-only smoothing between fill-art and save/render.
# - Turns isolated ocean into lake inland.
# - Majority flip for obvious singletons (conservative).
# Respects `art_locked`.
##

func run(snapshot: Dictionary) -> void:
	if not snapshot.has("grid"):
		return
	var g: Dictionary = snapshot["grid"] as Dictionary
	if not g.has("tiles"):
		return
	_smooth_isolated_ocean(snapshot)
	_majority_flip(snapshot, true)

# --- Pass 1: ocean → lake if isolated inland ---
func _smooth_isolated_ocean(snapshot: Dictionary) -> void:
	var grid: Dictionary = snapshot["grid"] as Dictionary
	var tiles: Array = grid.get("tiles", []) as Array
	var radius: int = int(grid.get("radius", 0))

	var by_key: Dictionary = {}
	for t_v in tiles:
		var t: Dictionary = t_v as Dictionary
		by_key[String(t.get("tile_id", ""))] = t

	for t_v in tiles:
		var t: Dictionary = t_v as Dictionary
		var locked: bool = bool(t.get("art_locked", false))
		if locked:
			continue

		var q: int = int(t.get("q", 0))
		var r: int = int(t.get("r", 0))
		if _is_outer_ring(q, r, radius):
			continue

		var base_id: String = String(t.get("base_art_id", ""))
		if not base_id.begins_with("hexOcean"):
			continue

		var w_neighbors: int = 0
		var land_neighbors: int = 0
		var nbs: Array = _neighbors_of(q, r)
		for nb_v in nbs:
			var nb: Vector2i = nb_v as Vector2i
			if abs(nb.x + nb.y) > radius:
				continue
			var nk: String = "H_%d_%d" % [nb.x, nb.y]
			var nt_v: Variant = by_key.get(nk, Dictionary())
			if typeof(nt_v) != TYPE_DICTIONARY:
				continue
			var nid: String = String((nt_v as Dictionary).get("base_art_id", ""))
			if nid.begins_with("hexOcean"):
				w_neighbors += 1
			else:
				land_neighbors += 1

		if w_neighbors <= 1 and land_neighbors >= 3:
			t["base_art_id"] = "hexLake"

# --- Pass 2: generic local-majority smoothing (very conservative) ---
func _majority_flip(snapshot: Dictionary, enable: bool) -> void:
	if not enable:
		return
	var grid: Dictionary = snapshot["grid"] as Dictionary
	var tiles: Array = grid.get("tiles", []) as Array
	var radius: int = int(grid.get("radius", 0))

	var by_key: Dictionary = {}
	for t_v in tiles:
		var t: Dictionary = t_v as Dictionary
		by_key[String(t.get("tile_id", ""))] = t

	var next_ids: Dictionary = {}  # key -> new_id
	for t_v in tiles:
		var t: Dictionary = t_v as Dictionary
		if bool(t.get("art_locked", false)):
			continue

		var q: int = int(t.get("q", 0))
		var r: int = int(t.get("r", 0))
		var id_here: String = String(t.get("base_art_id", ""))

		var counts: Dictionary = {}  # id -> int
		var nbs: Array = _neighbors_of(q, r)
		for nb_v in nbs:
			var nb: Vector2i = nb_v as Vector2i
			if abs(nb.x + nb.y) > radius:
				continue
			var nk: String = "H_%d_%d" % [nb.x, nb.y]
			var nt_v: Variant = by_key.get(nk, Dictionary())
			if typeof(nt_v) != TYPE_DICTIONARY:
				continue
			var nid: String = String((nt_v as Dictionary).get("base_art_id", ""))
			if nid == "":
				continue
			counts[nid] = int(counts.get(nid, 0)) + 1

		var best_id: String = id_here
		var best_n: int = -1
		var keys: Array = counts.keys()
		for k_v in keys:
			var k: String = String(k_v)
			var n: int = int(counts[k])
			if n > best_n:
				best_n = n
				best_id = k

		# flip only on strong majority
		if best_n >= 4 and best_id != id_here:
			var key: String = String(t.get("tile_id", ""))
			next_ids[key] = best_id

	for t_v in tiles:
		var t: Dictionary = t_v as Dictionary
		var key: String = String(t.get("tile_id", ""))
		if next_ids.has(key):
			t["base_art_id"] = next_ids[key]

# --- helpers ---
static func _neighbors_of(q: int, r: int) -> Array:
	var out: Array = []
	out.push_back(Vector2i(q + 1, r))
	out.push_back(Vector2i(q - 1, r))
	out.push_back(Vector2i(q, r + 1))
	out.push_back(Vector2i(q, r - 1))
	out.push_back(Vector2i(q + 1, r - 1))
	out.push_back(Vector2i(q - 1, r + 1))
	return out

static func _is_outer_ring(q: int, r: int, radius: int) -> bool:
	return abs(q) == radius or abs(r) == radius or abs(q + r) == radius
