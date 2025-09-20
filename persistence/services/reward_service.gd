extends RefCounted
class_name RewardService
## Grants run rewards & meta-side XP cleanly and returns a receipt for UI.
## Input "rewards" example:
## {
##   "gold": 35,
##   "hp": 10,
##   "mp": 5,
##   "items": [ { "id":"potion_health", "count":2, "opts":{"rarity":"Common"} } ],
##   "skill_xp": [ { "id":"swordsmanship", "xp":15 } ]
## }

const _S      := preload("res://persistence/util/save_utils.gd")
const _Prog   := preload("res://persistence/services/progression_service.gd")
const _Inv    := preload("res://persistence/services/inventory_service.gd")

const DEFAULT_SLOT: int = 1

static func grant(rewards: Dictionary, slot: int = DEFAULT_SLOT) -> Dictionary:
	var receipt: Dictionary = {
		"gold": 0, "hp": 0, "mp": 0,
		"items": [], # Array[Dictionary]: {id, count}
		"skill_xp": [], # Array[Dictionary]: {id, xp, new_level}
	}

	# --- RUN-side: gold / hp / mp ---
	var rs: Dictionary = SaveManager.load_run(slot)
	var gold_add: int = int(_S.dget(rewards, "gold", 0))
	if gold_add != 0:
		var cur_g: int = int(_S.dget(rs, "gold", 0))
		rs["gold"] = max(0, cur_g + gold_add)
		receipt["gold"] = gold_add

	var hp_add: int = int(_S.dget(rewards, "hp", 0))
	if hp_add != 0:
		var hp: int = int(_S.dget(rs, "hp", 0))
		var hp_max: int = int(_S.dget(rs, "hp_max", 30))
		var new_hp: int = min(hp_max, hp + max(0, hp_add))
		rs["hp"] = new_hp
		receipt["hp"] = new_hp - hp

	var mp_add: int = int(_S.dget(rewards, "mp", 0))
	if mp_add != 0:
		var mp: int = int(_S.dget(rs, "mp", 0))
		var mp_max: int = int(_S.dget(rs, "mp_max", 10))
		var new_mp: int = min(mp_max, mp + max(0, mp_add))
		rs["mp"] = new_mp
		receipt["mp"] = new_mp - mp

	SaveManager.save_run(rs, slot)

	# --- Items (META inventory) ---
	var items_any: Variant = _S.dget(rewards, "items", [])
	var items_arr: Array = (items_any as Array) if items_any is Array else []
	for e_any in items_arr:
		if not (e_any is Dictionary):
			continue
		var e: Dictionary = e_any
		var id_str: String = String(_S.dget(e, "id", ""))
		if id_str.is_empty():
			continue
		var cnt: int = max(1, int(_S.dget(e, "count", 1)))
		var opts_any: Variant = _S.dget(e, "opts", {})
		var opts: Dictionary = (opts_any as Dictionary) if opts_any is Dictionary else {}
		_Inv.add(id_str, cnt, opts, slot)
		(receipt["items"] as Array).append({"id": id_str, "count": cnt})

	# --- Skill XP (META) ---
	var skill_any: Variant = _S.dget(rewards, "skill_xp", [])
	var skill_arr: Array = (skill_any as Array) if skill_any is Array else []
	for s_any in skill_arr:
		if not (s_any is Dictionary):
			continue
		var s: Dictionary = s_any
		var sid: String = String(_S.dget(s, "id", ""))
		var xp: int = max(0, int(_S.dget(s, "xp", 0)))
		if sid.is_empty() or xp <= 0:
			continue
		var after: Dictionary = _Prog.award_skill_xp(sid, xp, slot)
		(receipt["skill_xp"] as Array).append({"id": sid, "xp": xp, "new_level": int(_S.dget(after, "level", 1))})

	return receipt
