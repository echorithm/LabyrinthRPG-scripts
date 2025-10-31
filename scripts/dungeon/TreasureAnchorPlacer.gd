extends RefCounted
class_name TreasureAnchorPlacer

static func _shuffle_in_place(a: Array[Vector2i], rng: RandomNumberGenerator) -> void:
	for i in range(a.size() - 1, 0, -1):
		var j: int = rng.randi_range(0, i)
		var tmp: Vector2i = a[i]
		a[i] = a[j]
		a[j] = tmp

static func _too_close_any(c: Vector2i, chosen: Array[Vector2i], min_cells_sq: int) -> bool:
	for p in chosen:
		var dx: int = c.x - p.x
		var dz: int = c.y - p.y
		if dx * dx + dz * dz < min_cells_sq:
			return true
	return false

static func _too_close_to_elites(c: Vector2i, elites: Array[Vector2i], min_cells_sq: int) -> bool:
	for p in elites:
		var dx: int = c.x - p.x
		var dz: int = c.y - p.y
		if dx * dx + dz * dz < min_cells_sq:
			return true
	return false

static func place(count: int, candidates: Array[Vector2i], cell_size: float, min_dist_m: float, elites: Array[Vector2i], elite_treasure_min_m: float, rng: RandomNumberGenerator) -> Array[Vector2i]:
	var chosen: Array[Vector2i] = []
	if candidates.is_empty() or count <= 0:
		return chosen

	var list: Array[Vector2i] = candidates.duplicate()
	_shuffle_in_place(list, rng)

	var min_cells: int = int(ceil(min_dist_m / cell_size))
	var min_cells_sq: int = min_cells * min_cells

	var et_cells: int = int(ceil(elite_treasure_min_m / cell_size))
	var et_cells_sq: int = et_cells * et_cells

	for c in list:
		if chosen.size() >= count:
			break
		if _too_close_to_elites(c, elites, et_cells_sq):
			continue
		if _too_close_any(c, chosen, min_cells_sq):
			continue
		chosen.append(c)

	# One relaxed pass against treasure–treasure distance if still short
	if chosen.size() < count and min_cells > 1:
		var relaxed_sq: int = (min_cells - 1) * (min_cells - 1)
		for c in list:
			if chosen.size() >= count:
				break
			if _too_close_to_elites(c, elites, et_cells_sq):
				continue
			if _too_close_any(c, chosen, relaxed_sq):
				continue
			chosen.append(c)

	return chosen
