extends RefCounted
class_name EliteAnchorPlacer

static func _shuffle_in_place(a: Array[Vector2i], rng: RandomNumberGenerator) -> void:
	for i in range(a.size() - 1, 0, -1):
		var j: int = rng.randi_range(0, i)
		var tmp: Vector2i = a[i]
		a[i] = a[j]
		a[j] = tmp

static func _too_close(c: Vector2i, chosen: Array[Vector2i], min_dist_cells_sq: int) -> bool:
	for p in chosen:
		var dx: int = c.x - p.x
		var dz: int = c.y - p.y
		if dx * dx + dz * dz < min_dist_cells_sq:
			return true
	return false

static func place(count: int, candidates: Array[Vector2i], cell_size: float, min_dist_m: float, rng: RandomNumberGenerator, usable_area_cells: int, area_target_m2_per_elite: float) -> Array[Vector2i]:
	var chosen: Array[Vector2i] = []
	if candidates.is_empty() or count <= 0:
		return chosen

	# Soft area cap
	var usable_m2: float = float(usable_area_cells) * cell_size * cell_size
	var max_by_area: int = int(floor(usable_m2 / max(1.0, area_target_m2_per_elite)))
	var target: int = min(count, max_by_area if max_by_area > 0 else count)

	var list: Array[Vector2i] = candidates.duplicate()
	_shuffle_in_place(list, rng)

	var min_cells: int = int(ceil(min_dist_m / cell_size))
	var min_cells_sq: int = min_cells * min_cells

	for c in list:
		if chosen.size() >= target:
			break
		if not _too_close(c, chosen, min_cells_sq):
			chosen.append(c)

	# If we couldn’t fit, allow one relaxed pass
	if chosen.size() < target and min_cells > 1:
		var relaxed_sq: int = (min_cells - 1) * (min_cells - 1)
		for c in list:
			if chosen.size() >= target:
				break
			if not _too_close(c, chosen, relaxed_sq):
				chosen.append(c)

	return chosen
