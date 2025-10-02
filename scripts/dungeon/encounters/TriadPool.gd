extends RefCounted
class_name TriadPool
##
## Slug-only triad helper (no Mxx). Uses MonsterCatalog autoload.
##

@export var pool_size: int = 4
@export var trash_roles: Array[String] = ["regular"]  # roles allowed for RNG pool

# ---------------- utils ----------------
func _mc() -> MonsterCatalog:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return null
	var root := tree.get_root() # Viewport (inherits Node)
	if root == null:
		return null
	return root.get_node_or_null("MonsterCatalog") as MonsterCatalog

static func triad_id_for_floor(floor: int) -> int:
	# Floors 1–3 => triad 1, 4–6 => 2, etc.
	return int(((max(1, floor) - 1) / 3) + 1)

func _unique(in_slugs: Array[StringName]) -> Array[StringName]:
	var seen := {}
	for s: StringName in in_slugs:
		seen[s] = true
	var out: Array[StringName] = []
	for k in seen.keys():
		out.append(k as StringName)
	return out

func _weighted_pick(rng: RandomNumberGenerator, candidates: Array[StringName], mc: MonsterCatalog) -> StringName:
	var total := 0.0
	for s: StringName in candidates:
		total += max(0.0001, float(mc.weight_for(s)))
	var t := rng.randf_range(0.0, total)
	for s: StringName in candidates:
		t -= max(0.0001, float(mc.weight_for(s)))
		if t <= 0.0:
			return s
	# Fallback (Godot ternary is Python-style)
	return candidates.back() if not candidates.is_empty() else StringName("")

# ---------------- API ----------------
func pool_for_triad(run_seed: int, triad_id: int) -> Array[StringName]:
	var mc := _mc()
	if mc == null:
		return []

	# Collect candidates from allowed roles
	var candidates: Array[StringName] = []
	for r in trash_roles:
		candidates.append_array(mc.slugs_for_role(r))
	candidates = _unique(candidates)

	# Deterministic RNG from run_seed + triad
	var seed := DetHash.djb2_64([str(run_seed), "TRIAD_POOL", str(triad_id)])
	var rng := RandomNumberGenerator.new()
	rng.seed = seed

	# Pick unique slugs by weight
	var available: Array[StringName] = candidates.duplicate()
	var out: Array[StringName] = []
	while out.size() < pool_size and available.size() > 0:
		var pick: StringName = _weighted_pick(rng, available, mc)
		if String(pick) == "":
			break
		out.append(pick)
		available.erase(pick)
	return out

func boss_for_triad(run_seed: int, triad_id: int, pool: Array[StringName]) -> StringName:
	var mc := _mc()
	if mc == null:
		return StringName("")

	# Prefer a bossable member of the pool
	var from_pool: Array[StringName] = []
	for s: StringName in pool:
		if mc.is_role_allowed(s, "boss"):
			from_pool.append(s)

	var candidates: Array[StringName] = (from_pool if from_pool.size() > 0 else mc.slugs_for_role("boss"))
	if candidates.is_empty():
		# If no dedicated "boss" entries, allow elites to boss up.
		candidates = mc.slugs_for_role("elite")
	if candidates.is_empty():
		return StringName("")

	var seed := DetHash.djb2_64([str(run_seed), "TRIAD_BOSS", str(triad_id)])
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	return _weighted_pick(rng, candidates, mc)

func weighted_pick_for_floor(run_seed: int, floor: int, pool: Array[StringName], nonce: int) -> StringName:
	# Deterministic per encounter attempt (nonce = e.g. eligible_step_index)
	var mc := _mc()
	if mc == null or pool.is_empty():
		return StringName("")
	var seed := DetHash.djb2_64([str(run_seed), "TRASH_PICK", str(floor), str(nonce)])
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	return _weighted_pick(rng, pool, mc)
