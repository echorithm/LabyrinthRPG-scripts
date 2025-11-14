extends RefCounted
class_name VillageMapSnapshotBuilder

##
# Deterministic hex-disc builder with a coherent coarse-biome field.
# Writes per-tile static.biome_hint used by the resolver.
##

enum CoarseBiome { PLAINS, DESERT, JUNGLE, SNOW, MOUNTAINS, WATER }

class BiomeOpts:
	var target: CoarseBiome
	var patch_count: int
	var patch_min: int
	var patch_max: int
	var neighbor_smooth_iters: int
	func _init(t: CoarseBiome, pc: int, pmin: int, pmax: int, smooth: int) -> void:
		target = t
		patch_count = pc
		patch_min = pmin
		patch_max = pmax
		neighbor_smooth_iters = smooth

# Weighted patch palettes (bias “related” biomes around the target)
const PATCH_WEIGHTS := {
	CoarseBiome.PLAINS:    [CoarseBiome.PLAINS, CoarseBiome.PLAINS, CoarseBiome.PLAINS, CoarseBiome.JUNGLE, CoarseBiome.MOUNTAINS, CoarseBiome.WATER],
	CoarseBiome.DESERT:    [CoarseBiome.DESERT, CoarseBiome.DESERT, CoarseBiome.PLAINS, CoarseBiome.MOUNTAINS],
	CoarseBiome.JUNGLE:    [CoarseBiome.JUNGLE, CoarseBiome.JUNGLE, CoarseBiome.PLAINS, CoarseBiome.WATER, CoarseBiome.MOUNTAINS],
	CoarseBiome.SNOW:      [CoarseBiome.SNOW, CoarseBiome.SNOW, CoarseBiome.MOUNTAINS, CoarseBiome.PLAINS],
	CoarseBiome.MOUNTAINS: [CoarseBiome.MOUNTAINS, CoarseBiome.MOUNTAINS, CoarseBiome.PLAINS, CoarseBiome.SNOW],
	CoarseBiome.WATER:     [CoarseBiome.WATER, CoarseBiome.WATER, CoarseBiome.PLAINS, CoarseBiome.JUNGLE]
}

# ---------- Public API ----------
func build(seed: int, radius: int) -> Dictionary:
	var snapshot: Dictionary = _init_snapshot(seed, radius)
	
	# Tune vibe here (counts/sizes/smoothing)
	var opts := BiomeOpts.new(CoarseBiome.PLAINS, 3, 4, 9, 2)
	var field: Dictionary = _build_biome_field(seed, radius, opts)

	var tiles: Array = []
	for q in range(-radius, radius + 1):
		for r in range(-radius, radius + 1):
			if abs(q + r) > radius:
				continue
			var t: Dictionary = {}
			t["q"] = q
			t["r"] = r
			t["tile_id"] = "H_%d_%d" % [q, r]
			t["kind"] = _choose_kind(seed, q, r)
			t["road_mask"] = 0
			t["static"] = {}
			t["visual"] = {}
			var coarse: int = int(field.get(t["tile_id"], CoarseBiome.PLAINS))
			t["static"]["biome_hint"] = _hint_from_coarse(coarse)
			tiles.push_back(t)

	snapshot["grid"]["tiles"] = tiles
	snapshot["tiles"] = tiles  # mirror for legacy consumers
	print("[SnapshotBuilder] build: tiles=", tiles.size())
	return snapshot

# ---------- Internals ----------
static func _neighbors_of(q: int, r: int) -> Array:
	var out: Array = []
	out.push_back(Vector2i(q + 1, r))
	out.push_back(Vector2i(q - 1, r))
	out.push_back(Vector2i(q, r + 1))
	out.push_back(Vector2i(q, r - 1))
	out.push_back(Vector2i(q + 1, r - 1))
	out.push_back(Vector2i(q - 1, r + 1))
	return out

func _init_snapshot(seed: int, radius: int) -> Dictionary:
	var snap: Dictionary = {}
	snap["seed"] = seed
	snap["schema_version"] = 2
	var grid: Dictionary = {}
	grid["radius"] = radius
	grid["tiles"] = []  # Array[Dictionary]
	snap["grid"] = grid
	snap["tiles"] = []  # mirrored
	return snap

func _build_biome_field(seed: int, radius: int, opts: BiomeOpts) -> Dictionary:
	var field: Dictionary = {}  # "H_q_r" -> CoarseBiome(int)

	# 1) fill with target
	for q in range(-radius, radius + 1):
		for r in range(-radius, radius + 1):
			if abs(q + r) <= radius:
				field["H_%d_%d" % [q, r]] = opts.target

	# 2) deterministic RNG
	var rng := RandomNumberGenerator.new()
	rng.seed = seed

	# 3) stamp patches with weighted choices + small nudges
	var bank: Array = PATCH_WEIGHTS.get(opts.target, [opts.target])
	for _i in opts.patch_count:
		var size: int = rng.randi_range(opts.patch_min, opts.patch_max)

		# weighted biome pick
		var choice_biome: int = int(bank[rng.randi_range(0, bank.size() - 1)])

		# choose a center inside the disc
		var q0: int = rng.randi_range(-radius, radius)
		var r0: int = rng.randi_range(-radius, radius)
		while abs(q0 + r0) > radius:
			q0 = rng.randi_range(-radius, radius)
			r0 = rng.randi_range(-radius, radius)

		# --- nudges -----------------------------------------------------
		# Mountains: prefer nearer the rim
		if choice_biome == CoarseBiome.MOUNTAINS:
			var dist_from_center: int = abs(q0) + abs(r0)
			var push: int = max(0, radius - 1)
			if dist_from_center < push and rng.randf() < 0.75:
				# nudge both axes outward
				if q0 == 0:
					q0 = push
				else:
					q0 = sign(q0) * max(abs(q0), push)
				if r0 == 0:
					r0 = push
				else:
					r0 = sign(r0) * max(abs(r0), push)
				# clamp back into hex disc if needed
				q0 = clamp(q0, -radius, radius)
				r0 = clamp(r0, -radius, radius)
				while abs(q0 + r0) > radius:
					if abs(q0) > abs(r0):
						q0 -= sign(q0)
					else:
						r0 -= sign(r0)

		# Water: mostly off interior + smaller patches
		if choice_biome == CoarseBiome.WATER:
			var min_ring: int = int(round(radius * 0.9))
			var tries: int = 0
			while (abs(q0) + abs(r0)) < min_ring and tries < 32:
				q0 = rng.randi_range(-radius, radius)
				r0 = rng.randi_range(-radius, radius)
				while abs(q0 + r0) > radius:
					q0 = rng.randi_range(-radius, radius)
					r0 = rng.randi_range(-radius, radius)
				tries += 1
			size = min(size, max(3, int(size * 6 / 10)))

		# --- flood fill placement --------------------------------------
		var frontier: Array = [Vector2i(q0, r0)]
		var visited: Dictionary = {}
		var placed: int = 0
		while frontier.size() > 0 and placed < size:
			var cur: Vector2i = frontier.pop_back() as Vector2i
			var key: String = "H_%d_%d" % [cur.x, cur.y]
			if visited.has(key):
				continue
			visited[key] = true
			if abs(cur.x + cur.y) <= radius:
				field[key] = choice_biome
				placed += 1
				var nbs: Array = _neighbors_of(cur.x, cur.y)
				for nb_v in nbs:
					var nb: Vector2i = nb_v as Vector2i
					if abs(nb.x + nb.y) <= radius and not visited.has("H_%d_%d" % [nb.x, nb.y]):
						frontier.push_back(nb)

	# 4) smoothing (strip singletons without mush)
	for _s in opts.neighbor_smooth_iters:
		var next: Dictionary = {}
		for q in range(-radius, radius + 1):
			for r in range(-radius, radius + 1):
				if abs(q + r) > radius:
					continue
				var key2: String = "H_%d_%d" % [q, r]
				var counts: Dictionary = {}  # biome(int) -> int
				var cur_biome: int = int(field.get(key2, opts.target))
				var nbs2: Array = _neighbors_of(q, r)
				for nb_v in nbs2:
					var nb2: Vector2i = nb_v as Vector2i
					if abs(nb2.x + nb2.y) <= radius:
						var nk: String = "H_%d_%d" % [nb2.x, nb2.y]
						var b: int = int(field.get(nk, cur_biome))
						counts[b] = int(counts.get(b, 0)) + 1
				var best_b: int = cur_biome
				var best_n: int = -1
				var keys: Array = counts.keys()
				for biome_key_v in keys:
					var biome_key: int = int(biome_key_v)
					var n: int = int(counts[biome_key])
					if n > best_n or (n == best_n and biome_key == cur_biome):
						best_n = n
						best_b = biome_key
				next[key2] = best_b
		field = next

	return field


# Deterministic: exactly one neighbor becomes camp_core
func _choose_kind(seed: int, q: int, r: int) -> String:
	if q == 0 and r == 0:
		return "labyrinth"

	# Hex distance from origin (typed)
	var dist: int = int((abs(q) + abs(q + r) + abs(r)) / 2)
	if dist != 1:
		return "wild"

	# Deterministically pick one ring-1 neighbor for camp_core
	var pick: int = _pick_ring1_index(seed)  # 0..5
	var ring1: Array[Vector2i] = [
		Vector2i( 1,  0), Vector2i( 1, -1), Vector2i( 0, -1),
		Vector2i(-1,  0), Vector2i(-1,  1), Vector2i( 0,  1)
	]
	var chosen: Vector2i = ring1[pick]
	return "camp_core" if (q == chosen.x and r == chosen.y) else "wild"

func _pick_ring1_index(seed: int) -> int:
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = seed
	return rng.randi_range(0, 5)

static func _mix_seed(seed: int, q: int, r: int) -> int:
	var x: int = seed
	x ^= q * 0x9e3779b1
	x ^= r * 0x85ebca6b
	# rotate-left 13
	x = (x << 13) | (x >> (32 - 13))
	return x

func _hint_from_coarse(coarse: int) -> Dictionary:
	match coarse:
		CoarseBiome.DESERT:
			return {"biome":"desert","temperature":"hot","moisture":"dry","elevation":"mid"}
		CoarseBiome.PLAINS:
			return {"biome":"plains","temperature":"temperate","moisture":"medium","elevation":"low"}
		CoarseBiome.JUNGLE:
			return {"biome":"jungle","temperature":"hot","moisture":"wet","elevation":"low"}
		CoarseBiome.SNOW:
			return {"biome":"snow","temperature":"cold","moisture":"medium","elevation":"low"}
		CoarseBiome.MOUNTAINS:
			return {"biome":"mountains","temperature":"temperate","moisture":"medium","elevation":"high"}
		CoarseBiome.WATER:
			return {"biome":"water","temperature":"temperate","moisture":"wet","elevation":"low"}
	return {"biome":"plains","temperature":"temperate","moisture":"medium","elevation":"low"}
