# File: res://persistence/services/connectivity_service.gd
# Godot 4.5 — Strict typing, hex BFS over axial coords (q,r)

class_name ConnectivityService

## Computes connected_to_camp for all tiles using a BFS over ROAD/BRIDGE/CAMP/ENTRANCE and land tiles with roads.
## Assumes VillageService owns persistence; this service is pure logic with helpers.

static func recompute(tiles: Array[Dictionary]) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	out.resize(tiles.size())
	# Copy tiles to avoid mutating caller arrays directly
	for i in range(tiles.size()):
		out[i] = tiles[i].duplicate(true)

	var camp_indices: Array[int] = _find_camp_like_indices(out)
	if camp_indices.is_empty():
		# If no camp/entrance tiles found, mark none connected.
		for i in range(out.size()):
			out[i]["connected_to_camp"] = false
		return out

	var visited: Array[bool] = []
	visited.resize(out.size())
	for i in range(visited.size()):
		visited[i] = false

	var queue: Array[int] = []
	for ci in camp_indices:
		if ci >= 0 and ci < out.size():
			queue.append(ci)
			visited[ci] = true

	# Build axial index for fast lookup
	var index_by_axial: Dictionary = _build_axial_index(out)

	# BFS
	while not queue.is_empty():
		var idx: int = queue.pop_front()
		var t: Dictionary = out[idx]
		t["connected_to_camp"] = true
		out[idx] = t

		var q: int = int(t.get("q", 0))
		var r: int = int(t.get("r", 0))
		for n in _neighbors_axial(q, r):
			var n_idx: int = index_by_axial.get(_axial_key(n.x, n.y), -1)
			if n_idx == -1:
				continue
			if visited[n_idx]:
				continue
			if _is_traversable(out[idx], out[n_idx]):
				visited[n_idx] = true
				queue.append(n_idx)

	return out


static func _find_camp_like_indices(tiles: Array[Dictionary]) -> Array[int]:
	var indices: Array[int] = []
	for i in range(tiles.size()):
		var kind: String = String(tiles[i].get("kind", "GRASS")).to_upper()
		if kind == "CAMP" or kind == "ENTRANCE":
			indices.append(i)
	return indices


static func _build_axial_index(tiles: Array[Dictionary]) -> Dictionary:
	var map := {}
	for i in range(tiles.size()):
		var q: int = int(tiles[i].get("q", 0))
		var r: int = int(tiles[i].get("r", 0))
		map[_axial_key(q, r)] = i
	return map


static func _axial_key(q: int, r: int) -> String:
	return "%d,%d" % [q, r]


static func _neighbors_axial(q: int, r: int) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	out.append(Vector2i(q + 1, r    ))
	out.append(Vector2i(q + 1, r - 1))
	out.append(Vector2i(q    , r - 1))
	out.append(Vector2i(q - 1, r    ))
	out.append(Vector2i(q - 1, r + 1))
	out.append(Vector2i(q    , r + 1))
	return out


static func _is_traversable(from_tile: Dictionary, to_tile: Dictionary) -> bool:
	# Simple rule: if either tile has ROAD/BRIDGE/CAMP/ENTRANCE kind or has_road/has_bridge, allow traversal.
	var kinds: Array[String] = [
		"CAMP","ENTRANCE","ROAD","BRIDGE","GRASS","FOREST","HILL","MOUNTAIN","WATER"
	]
	var from_kind: String = String(from_tile.get("kind", "GRASS")).to_upper()
	var to_kind: String = String(to_tile.get("kind", "GRASS")).to_upper()
	if not kinds.has(from_kind) or not kinds.has(to_kind):
		return false

	var from_has_path: bool = bool(from_tile.get("has_road", false)) or bool(from_tile.get("has_bridge", false)) or (from_kind == "CAMP") or (from_kind == "ENTRANCE") or (from_kind == "ROAD") or (from_kind == "BRIDGE")
	var to_has_path: bool = bool(to_tile.get("has_road", false)) or bool(to_tile.get("has_bridge", false)) or (to_kind == "CAMP") or (to_kind == "ENTRANCE") or (to_kind == "ROAD") or (to_kind == "BRIDGE")
	return from_has_path and to_has_path
