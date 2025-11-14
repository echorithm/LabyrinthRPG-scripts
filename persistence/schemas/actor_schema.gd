extends RefCounted
class_name ActorSchema
## Unifies player/NPC/enemy data for META (long-term) and RUN (session).
## Shape (META-friendly):
## {
##   "id": String, "kind": String, "name": String,
##   "level": int, "xp": int,
##   "stats": Stats block,
##   "abilities": Array[Ability],
##   "loadout": { slot->inv_index },   # indices into META.player.inventory
## }
## RUN-friendly extension may add live hp/mp/cooldowns snapshot when needed.

const _S := preload("res://persistence/util/save_utils.gd")
const Stats := preload("res://persistence/schemas/stats_schema.gd")
const Ability := preload("res://persistence/schemas/ability_schema.gd")

static func default_block(kind: String = "player") -> Dictionary:
	return {
		"id": "",
		"kind": kind,   # "player","npc","enemy"
		"name": "",
		"level": 1,
		"xp": 0,
		"stats": Stats.default_block(),
		"abilities": [],
		"loadout": _default_loadout(),
	}

static func _default_loadout() -> Dictionary:
	return {
		"weapon_main": -1,
		"weapon_off": -1,
		"head": -1,
		"chest": -1,
		"legs": -1,
		"ring1": -1,
		"ring2": -1,
		"trinket": -1,
	}

static func normalize(d_any: Variant, kind_hint: String = "") -> Dictionary:
	var d: Dictionary = _S.to_dict(d_any)
	if not d.has("id"): d["id"] = ""
	if not d.has("kind"): d["kind"] = kind_hint if not kind_hint.is_empty() else "player"
	if not d.has("name"): d["name"] = ""
	d["level"] = max(1, int(_S.dget(d, "level", 1)))
	d["xp"] = max(0, int(_S.dget(d, "xp", 0)))

	# Stats
	d["stats"] = Stats.normalize(_S.dget(d, "stats", {}))

	# Abilities
	var arr_any: Variant = _S.dget(d, "abilities", [])
	var arr: Array = (arr_any as Array) if arr_any is Array else []
	var out: Array = []
	for a_any in arr:
		out.append(Ability.normalize(a_any))
	d["abilities"] = out

	# Loadout
	var l_any: Variant = _S.dget(d, "loadout", _default_loadout())
	var l: Dictionary = _S.to_dict(l_any)
	var norm: Dictionary = _default_loadout()
	for k in norm.keys():
		norm[k] = int(_S.dget(l, k, -1))
	d["loadout"] = norm

	return d

# --- Optional helpers for manipulating abilities/loadout ---
static func set_loadout_index(d: Dictionary, slot_name: String, inv_index: int) -> Dictionary:
	var n: Dictionary = normalize(d)
	var lo: Dictionary = n["loadout"]
	lo[slot_name] = max(-1, inv_index)
	n["loadout"] = lo
	return n

static func add_or_replace_ability(d: Dictionary, ability: Dictionary) -> Dictionary:
	var n: Dictionary = normalize(d)
	var arr: Array = n["abilities"]
	var id_s: String = String(_S.dget(ability, "id", ""))
	if id_s.is_empty():
		return n
	var found: bool = false
	for i in range(arr.size()):
		if arr[i] is Dictionary and String(_S.dget(arr[i], "id", "")) == id_s:
			arr[i] = Ability.normalize(ability)
			found = true
			break
	if not found:
		arr.append(Ability.normalize(ability))
	n["abilities"] = arr
	return n
