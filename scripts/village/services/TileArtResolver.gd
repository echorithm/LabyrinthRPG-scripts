extends RefCounted
class_name TileArtResolver

##
# Deterministic art selection with coherent pools:
# - Inland water (lake/wetlands/marsh) vs rim ocean.
# - Curated, weighted biome groups to avoid “desert bleed” on plains.
##

var catalog: BaseTileCatalog

func _init(c: BaseTileCatalog = null) -> void:
	catalog = c

func resolve_base_art_id(seed: int, q: int, r: int, kind: String, hint: Dictionary, radius: int) -> String:
	var coarse: String = _coarse_from_hint(hint)
	var pool: Array[String] = []

	if coarse == "water":
		if _is_outer_ring(q, r, radius):
			pool = _gather_by_biomes_weighted(["ocean","ocean","water"])
		else:
			pool = _gather_by_biomes_weighted(["lake","freshwater","wetlands","marsh","swamp","water"])
	else:
		# Exact bucket first
		var temp: String = String(hint.get("temperature", ""))
		var moist: String = String(hint.get("moisture", ""))
		var elev: String = String(hint.get("elevation", ""))
		pool = catalog.get_variants(coarse, temp, moist, elev)

		# Weighted coherent groups per coarse biome
		if pool.is_empty():
			match coarse:
				"plains":
					pool = _gather_by_biomes_weighted(["plains","plains","plains","woodlands","hills","highlands","wetlands","scrublands"])
					pool = _exclude_by_id(pool, ["Desert","Ocean","Lava"])
				"desert":
					pool = _gather_by_biomes_weighted(["desert","desert","sand","scrublands"])
				"jungle":
					pool = _gather_by_biomes_weighted(["jungle","jungle","woodlands","swamp","wetlands","marsh"])
					pool = _exclude_by_id(pool, ["Desert","Ocean"])
				"snow":
					pool = _gather_by_biomes_weighted(["snow","snow","highlands","mountains"])
				"mountains":
					pool = _gather_by_biomes_weighted(["mountains","mountains","highlands","hills"])
				_:
					pool = catalog.get_by_biome(coarse)

	# Absolute fallback
	if pool.is_empty():
		pool = catalog.get_by_biome(coarse)
	if pool.is_empty():
		pool = catalog.get_ids()
	if pool.is_empty():
		return ""

	var idx: int = _stable_index(seed, q, r, kind, pool.size())
	return pool[idx]

# --- helpers ---------------------------------------------------------------

func _gather_by_biomes_weighted(labels: Array[String]) -> Array[String]:
	var out: Array[String] = []
	for b in labels:
		var chunk: Array[String] = catalog.get_by_biome(b)
		if not chunk.is_empty():
			for id in chunk:
				out.append(String(id))
	return out

func _exclude_by_id(pool: Array[String], substrings: Array[String]) -> Array[String]:
	if pool.is_empty():
		return pool
	var keep: Array[String] = []
	for id in pool:
		var ok: bool = true
		for s in substrings:
			if id.findn(s) >= 0:
				ok = false
				break
		if ok:
			keep.append(id)
	# Never empty the pool by filtering; fall back to original if all removed
	if keep.size() == 0:
		return pool
	return keep

static func _is_outer_ring(q: int, r: int, radius: int) -> bool:
	return abs(q) == radius or abs(r) == radius or abs(q + r) == radius

static func _stable_index(seed: int, q: int, r: int, kind: String, size: int) -> int:
	var h: int = seed
	h ^= (q << 7)
	h ^= (r << 13)
	h ^= kind.hash()
	if h < 0:
		h = -h
	if size <= 0:
		return 0
	return h % size

static func _coarse_from_hint(hint: Dictionary) -> String:
	if hint.has("biome"):
		return String(hint["biome"])
	var t: String = String(hint.get("temperature", "temperate"))
	var m: String = String(hint.get("moisture", "medium"))
	var e: String = String(hint.get("elevation", "low"))
	if t == "hot" and m == "dry":
		return "desert"
	if e == "high":
		return "mountains"
	if t == "cold":
		return "snow"
	if t == "hot" and m == "wet":
		return "jungle"
	if m == "wet" and e == "low":
		return "water"
	return "plains"
