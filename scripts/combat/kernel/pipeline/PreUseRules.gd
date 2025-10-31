extends RefCounted
class_name PreUseRules

const ActorSnapshot := preload("res://scripts/combat/data/ActorSnapshot.gd")
const AbilityUse := preload("res://scripts/combat/data/AbilityUse.gd")
const AbilityCatalog := preload("res://persistence/services/ability_catalog_service.gd")

## Validates ability availability and prepares resource/cooldown/charge deltas.
## Returns:
## { ok:bool, reason?:String, deltas:Array[Dictionary] }
##  deltas example for attacker-id:
##   { "actor_id": <id>, "mp": -N, "stam": -M,
##     "cooldowns": { "<aid>": T },
##     "charges":   { "<aid>": -1 } }
func validate_and_prepare(attacker: ActorSnapshot, use: AbilityUse) -> Dictionary:
	var aid: String = use.ability_id
	if aid == "" or aid == "fizzle":
		return {"ok": true, "deltas": []}

	# NEW: Authoritative unlock gate via snapshot.helpers.skills_unlocked
	var unlocked_map_any: Variant = attacker.helpers.get("skills_unlocked")
	if typeof(unlocked_map_any) == TYPE_DICTIONARY:
		var unlocked_map: Dictionary = unlocked_map_any as Dictionary
		if unlocked_map.has(aid) and not bool(unlocked_map[aid]):
			return {"ok": false, "reason": "locked", "deltas": []}

	# RELAXED known/level check:
	# - If explicitly present with level <= 0 → reject.
	# - If absent from abilities → allow; affordability/cooldowns gate next.
	var known: bool = true
	if typeof(attacker.abilities) == TYPE_DICTIONARY:
		var abs: Dictionary = attacker.abilities as Dictionary
		if abs.has(aid):
			var v: Variant = abs[aid]
			if typeof(v) == TYPE_INT:
				known = int(v) > 0
			elif typeof(v) == TYPE_DICTIONARY and (v as Dictionary).has("level"):
				known = int((v as Dictionary)["level"]) > 0
	if not known:
		return {"ok": false, "reason": "unknown_ability", "deltas": []}

	var costs: Dictionary = AbilityCatalog.costs(aid) # {mp,stam,cooldown,charges}
	var need_mp: int = int(costs.get("mp", 0))
	var need_st: int = int(costs.get("stam", 0))
	var cd_turns: int = int(costs.get("cooldown", 0))
	var max_charges: int = int(costs.get("charges", 0))

	# Cooldown gate
	if attacker.cooldowns.has(aid) and int(attacker.cooldowns[aid]) > 0:
		return {"ok": false, "reason": "cooldown", "deltas": []}

	# Charge gate
	if max_charges > 0:
		var left: int = int(attacker.charges.get(aid, max_charges))
		if left <= 0:
			return {"ok": false, "reason": "no_charges", "deltas": []}

	# MP/ST affordability from snapshot pools
	var pool_mp: int = int(attacker.pools.get("mp", 0))
	var pool_st: int = int(attacker.pools.get("stam", 0))
	if pool_mp < need_mp:
		return {"ok": false, "reason": "mp", "deltas": []}
	if pool_st < need_st:
		return {"ok": false, "reason": "stam", "deltas": []}

	# Prepare deltas to be applied by controller later
	var delta: Dictionary = {"actor_id": attacker.id}
	if need_mp != 0:
		delta["mp"]   = -need_mp
	if need_st != 0:
		delta["stam"] = -need_st
	if cd_turns > 0:
		delta["cooldowns"] = { aid: cd_turns }
	if max_charges > 0:
		delta["charges"] = { aid: -1 } # decrement one

	return {"ok": true, "deltas": [delta]}
