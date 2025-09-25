extends RefCounted
class_name RewardService

const _S    := preload("res://persistence/util/save_utils.gd")
const _Prog := preload("res://persistence/services/progression_service.gd")
const _Meta := preload("res://persistence/schemas/meta_schema.gd") # for _gen_uid()

const DEFAULT_SLOT: int = 1

static func _get_runstate() -> Node:
	var loop := Engine.get_main_loop()
	var tree: SceneTree = loop as SceneTree
	if tree and tree.root:
		return tree.root.get_node_or_null(^"/root/RunState")
	return null

static func grant(rewards: Dictionary, slot: int = DEFAULT_SLOT) -> Dictionary:
	var receipt: Dictionary = {
		"gold": 0, "shards": 0, "hp": 0, "mp": 0,
		"items": [],      # Array[Dictionary]: {id, count, opts?}
		"skill_xp": []    # Array[Dictionary]: {id, xp, new_level}
	}

	# -----------------------------
	# RUN: gold / shards / hp / mp
	# -----------------------------
	var rs: Dictionary = SaveManager.load_run(slot)

	var gold_add: int = int(_S.dget(rewards, "gold", 0))
	if gold_add != 0:
		rs["gold"] = max(0, int(_S.dget(rs, "gold", 0)) + gold_add)
		receipt["gold"] = gold_add

	var shard_add: int = int(_S.dget(rewards, "shards", 0))
	if shard_add != 0:
		rs["shards"] = max(0, int(_S.dget(rs, "shards", 0)) + shard_add)
		receipt["shards"] = shard_add

	# Character XP (permanent)
	var char_xp_add: int = int(_S.dget(rewards, "xp", 0))
	if char_xp_add > 0:
		var after_char: Dictionary = _Prog.award_character_xp(char_xp_add, slot)
		receipt["xp"] = char_xp_add

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

	# -----------------------------
	# RUN: items (stackables vs gear)
	# -----------------------------
	var items_any: Variant = _S.dget(rewards, "items", [])
	var items_arr: Array = (items_any as Array) if items_any is Array else []

	var rinv_any: Variant = _S.dget(rs, "inventory", [])
	var rinv: Array = (rinv_any as Array) if rinv_any is Array else []

	for e_any: Variant in items_arr:
		if typeof(e_any) != TYPE_DICTIONARY:
			continue
		var e: Dictionary = e_any as Dictionary

		var id_str: String = String(_S.dget(e, "id", ""))
		if id_str.is_empty():
			continue

		var cnt: int = max(1, int(_S.dget(e, "count", 1)))
		var dmax: int = int(_S.dget(e, "durability_max", 0))

		if dmax > 0:
			# Gear (non-stackable)
			var gear: Dictionary = {
				"id": id_str, "count": 1,
				"ilvl": int(_S.dget(e, "ilvl", 1)),
				"archetype": String(_S.dget(e, "archetype", "Light")),
				"rarity": String(_S.dget(e, "rarity", "Common")),
				"affixes": _S.to_string_array(_S.dget(e, "affixes", [])),
				"durability_max": dmax,
				"durability_current": int(_S.dget(e, "durability_current", dmax)),
				"weight": float(_S.dget(e, "weight", 1.0)),
				"uid": String(_S.dget(e, "uid", "")),
			}
			if String(gear["uid"]).is_empty():
				gear["uid"] = _Meta._gen_uid()
			rinv.append(gear.duplicate(true))
			(receipt["items"] as Array).append({
				"id": id_str, "count": 1, "opts": {"rarity": String(gear["rarity"])}
			})
		else:
			# Stackables (try to merge by id/ilvl/archetype/rarity/affixes)
			var ilvl: int = int(_S.dget(e, "ilvl", 1))
			var arche: String = String(_S.dget(e, "archetype", "Light"))
			var rarity: String = String(_S.dget(e, "rarity", "Common"))
			var aff_norm: Array[String] = _S.to_string_array(_S.dget(e, "affixes", []))
			var stacked: bool = false

			for i in range(rinv.size()):
				var it_any: Variant = rinv[i]
				if not (it_any is Dictionary):
					continue
				var it: Dictionary = it_any
				if String(_S.dget(it, "id", "")) == id_str \
				and int(_S.dget(it, "ilvl", ilvl)) == ilvl \
				and String(_S.dget(it, "archetype", "")) == arche \
				and String(_S.dget(it, "rarity", "")) == rarity:
					var aff_it: Array[String] = _S.to_string_array(_S.dget(it, "affixes", []))
					if aff_it.size() == aff_norm.size():
						var same: bool = true
						for j in range(aff_it.size()):
							if aff_it[j] != aff_norm[j]:
								same = false
								break
						if same:
							it["count"] = int(_S.dget(it, "count", 1)) + cnt
							rinv[i] = it
							stacked = true
							break
			if not stacked:
				rinv.append({
					"id": id_str, "count": cnt,
					"ilvl": ilvl, "archetype": arche, "rarity": rarity,
					"affixes": aff_norm,
					"durability_max": 0, "durability_current": 0,
					"weight": float(_S.dget(e, "weight", 1.0))
				})
			(receipt["items"] as Array).append({"id": id_str, "count": cnt, "opts": {}})

	rs["inventory"] = rinv
	SaveManager.save_run(rs, slot)

	# ----- Mirror to /root/RunState so UI updates immediately -----
	var rs_node: Node = _get_runstate()
	if rs_node != null:
		print("[RewardService] Mirror to RunState start")

		# gold
		if gold_add != 0:
			var g_before: Variant = rs_node.get("gold")
			var g_now: int = int(rs.get("gold", 0))
			rs_node.set("gold", g_now)
			print("[RewardService] gold: UI ", g_before, " -> ", rs_node.get("gold"))

		# shards
		if shard_add != 0:
			var s_before: Variant = rs_node.get("shards")
			var s_now: int = int(rs.get("shards", 0))
			rs_node.set("shards", s_now)
			print("[RewardService] shards: UI ", s_before, " -> ", rs_node.get("shards"))

		# hp / mp (only if actually changed)
		var hp_delta: int = int(receipt.get("hp", 0))
		var mp_delta: int = int(receipt.get("mp", 0))
		if hp_delta != 0:
			var hp_b: Variant = rs_node.get("hp")
			var hpm_b: Variant = rs_node.get("hp_max")
			rs_node.set("hp", int(rs.get("hp", 0)))
			rs_node.set("hp_max", int(rs.get("hp_max", 0)))
			print("[RewardService] hp: UI ", hp_b, "/", hpm_b, " -> ",
				  rs_node.get("hp"), "/", rs_node.get("hp_max"))

		if mp_delta != 0:
			var mp_b: Variant = rs_node.get("mp")
			var mpm_b: Variant = rs_node.get("mp_max")
			rs_node.set("mp", int(rs.get("mp", 0)))
			rs_node.set("mp_max", int(rs.get("mp_max", 0)))
			print("[RewardService] mp: UI ", mp_b, "/", mpm_b, " -> ",
				  rs_node.get("mp"), "/", rs_node.get("mp_max"))

		# inventory mirror (size only)
		var inv_b: int = 0
		var inv_prop: Variant = rs_node.get("inventory")
		if inv_prop is Array:
			inv_b = (inv_prop as Array).size()
		rs_node.set("inventory", rinv)
		print("[RewardService] inventory: UI size ", inv_b, " -> ", rinv.size())

		# notify UIs
		var emitted: bool = false
		if rs_node.has_signal("pools_changed") and (hp_delta != 0 or mp_delta != 0):
			rs_node.emit_signal(
				"pools_changed",
				int(rs.get("hp", 0)), int(rs.get("hp_max", 0)),
				int(rs.get("mp", 0)), int(rs.get("mp_max", 0))
			)
			print("[RewardService] emitted pools_changed")
			emitted = true

		if rs_node.has_signal("changed"):
			rs_node.emit_signal("changed")
			print("[RewardService] emitted changed")
			emitted = true

		if not emitted:
			var ctrl := rs_node as Control
			if ctrl:
				ctrl.notification(Control.NOTIFICATION_THEME_CHANGED)
				print("[RewardService] nudged UI via Control.NOTIFICATION_THEME_CHANGED")
	else:
		print("[RewardService] /root/RunState NOT FOUND (UI won’t update until next sync)")

	# -----------------------------
	# META: skill xp (permanent)
	# -----------------------------
	var skill_any: Variant = _S.dget(rewards, "skill_xp", [])
	var skill_arr: Array = (skill_any as Array) if skill_any is Array else []
	for s_any: Variant in skill_arr:
		if typeof(s_any) != TYPE_DICTIONARY:
			continue
		var s: Dictionary = s_any as Dictionary
		var sid: String = String(_S.dget(s, "id", ""))
		var xp: int = max(0, int(_S.dget(s, "xp", 0)))
		if sid.is_empty() or xp <= 0:
			continue
		var after: Dictionary = _Prog.award_skill_xp(sid, xp, slot)
		(receipt["skill_xp"] as Array).append({
			"id": sid, "xp": xp, "new_level": int(_S.dget(after, "level", 1))
		})

	return receipt
