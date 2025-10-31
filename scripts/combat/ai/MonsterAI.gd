extends RefCounted
class_name MonsterAI

const AbilityCatalog := preload("res://persistence/services/ability_catalog_service.gd")

## Returns: { "ability_id": String, "targets": Array[int] }
func pick_action(monster_rt: Resource, player_rt: Resource, rng: Object) -> Dictionary:
	# 1) Gather candidates (authored > level map)
	var cands: Array = _candidates_from_authored(monster_rt)
	if cands.is_empty():
		cands = _candidates_from_levels(monster_rt)

	# 2) Filter by runtime (cooldowns/charges)
	cands = _filter_by_runtime(monster_rt, cands)

	# 3) Fallback if nothing left
	if cands.is_empty():
		return {"ability_id": "arc_slash", "targets": [player_rt.id]}

	# 4) Weighted pick
	var aid: String = _weighted_pick_id(cands, rng)

	# 5) Targeting (simple MVP: single -> player)
	var row: Dictionary = AbilityCatalog.get_by_id(aid)
	var ai_block_any: Variant = row.get("ai", {})
	var ai_block: Dictionary = (ai_block_any as Dictionary) if ai_block_any is Dictionary else {}
	var targeting: String = String(ai_block.get("targeting", "single"))
	var targets: Array[int] = []
	if targeting == "single" or targeting == "":
		targets = [player_rt.id]
	else:
		# Future: multi/all; for now same as single
		targets = [player_rt.id]

	return {"ability_id": aid, "targets": targets}

# ---- internals -----------------------------------------------------

func _candidates_from_authored(monster_rt: Resource) -> Array:
	# Returns Array of {id:String, w:float}
	var out: Array = []
	var arr_any: Variant = monster_rt.abilities
	if arr_any is Array:
		for a_any in (arr_any as Array):
			if typeof(a_any) != TYPE_DICTIONARY:
				continue
			var a: Dictionary = a_any
			var aid: String = String(a.get("ability_id",""))
			if aid == "":
				continue
			var w: float = float(a.get("weight", 0.0))
			if w > 0.0:
				out.append({"id": aid, "w": w})
	return out

func _candidates_from_levels(monster_rt: Resource) -> Array:
	# If only a level map exists, give equal weights
	var out: Array = []
	var m_any: Variant = monster_rt.ability_levels
	if m_any is Dictionary:
		for k in (m_any as Dictionary).keys():
			var aid: String = String(k)
			if aid != "":
				out.append({"id": aid, "w": 1.0})
	return out

func _filter_by_runtime(monster_rt: Resource, cands: Array) -> Array:
	var keep: Array = []
	for c_any in cands:
		if typeof(c_any) != TYPE_DICTIONARY:
			continue
		var c: Dictionary = c_any
		var aid: String = String(c.get("id",""))
		if aid == "":
			continue

		# Cooldowns
		var on_cd: bool = false
		if typeof(monster_rt.cooldowns) == TYPE_DICTIONARY:
			on_cd = int(monster_rt.cooldowns.get(aid, 0)) > 0
		if on_cd:
			continue

		# Charges (if defined, require > 0)
		var no_charges: bool = false
		if typeof(monster_rt.charges) == TYPE_DICTIONARY and (monster_rt.charges as Dictionary).has(aid):
			no_charges = int((monster_rt.charges as Dictionary).get(aid, 0)) <= 0
		if no_charges:
			continue

		keep.append(c)
	return keep

func _weighted_pick_id(cands: Array, rng: Object) -> String:
	# Prefer deterministic channel in RNGService if available
	var weights := PackedFloat32Array()
	for c_any in cands:
		weights.append(float((c_any as Dictionary).get("w", 0.0)))

	if rng != null and rng.has_method("pick_ai"):
		var idx: int = int(rng.call("pick_ai", weights))
		idx = clamp(idx, 0, cands.size() - 1)
		return String((cands[idx] as Dictionary).get("id",""))

	# Fallback to ad-hoc roulette
	var total: float = 0.0
	for w in weights:
		total += w
	if total <= 0.0:
		return String((cands.front() as Dictionary).get("id",""))

	var roll: float
	if rng != null and rng.has_method("randf_range"):
		roll = float(rng.call("randf_range", 0.0, total))
	else:
		roll = randf() * total

	var acc: float = 0.0
	for c_any in cands:
		var c: Dictionary = c_any
		acc += float(c.get("w", 0.0))
		if roll <= acc:
			return String(c.get("id",""))
	return String((cands.back() as Dictionary).get("id",""))
