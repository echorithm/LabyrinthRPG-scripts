# res://scripts/combat/status/StatusService.gd
# Godot 4.x
extends RefCounted
class_name StatusService

# ------------------------------------------------------------------------------
# Config / Debug
# ------------------------------------------------------------------------------
const DEBUG := true
static func _d(msg: String) -> void:
	if DEBUG: print("[StatusService] ", msg)

static func _log(cat: String, msg: String, data: Dictionary = {}, level: int = 0) -> void:
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	var gl: Node = tree.root.get_node_or_null(^"/root/GameLog")
	if gl != null:
		gl.call("post", cat, msg, data, level)
	

# ------------------------------------------------------------------------------
# Cache for EffectsPanel (lightweight, panel reads only)
# ------------------------------------------------------------------------------
static var _player_bag_cache: Array[Dictionary] = []
static var _monster_bag_cache: Array[Dictionary] = []

static func _dup_bag(src: Array) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for v in src:
		if v is Dictionary:
			out.append((v as Dictionary).duplicate(true))
	return out

static func set_player_bag(bag: Array) -> void:
	_player_bag_cache = _dup_bag(bag)
	_d("player_bag set -> %d effects" % _player_bag_cache.size())
	_log("status", "Player effects updated", {"count": _player_bag_cache.size()})

static func set_monster_bag(bag: Array) -> void:
	_monster_bag_cache = _dup_bag(bag)
	_d("monster_bag set -> %d effects" % _monster_bag_cache.size())
	_log("status", "Monster effects updated", {"count": _monster_bag_cache.size()})

static func player_bag() -> Array[Dictionary]:
	return _dup_bag(_player_bag_cache)

static func monster_bag() -> Array[Dictionary]:
	return _dup_bag(_monster_bag_cache)

# Convenience: call this if you hold a combat snapshot (optional for your flow)
static func refresh_bags_from_snapshot(snapshot: Dictionary, player_id: String, monster_id: String = "") -> void:
	var actors: Dictionary = snapshot.get("actors", {}) as Dictionary
	var p: Array = []
	var m: Array = []
	if actors.has(player_id) and (actors[player_id] is Dictionary):
		p = (actors[player_id] as Dictionary).get("effects", []) as Array
	if monster_id != "" and actors.has(monster_id) and (actors[monster_id] is Dictionary):
		m = (actors[monster_id] as Dictionary).get("effects", []) as Array
	set_player_bag(p)
	set_monster_bag(m)
	_d("refresh_bags_from_snapshot player=%d monster=%d" % [p.size(), m.size()])

# ------------------------------------------------------------------------------
# Core helpers for snapshot mutation flows (used by action resolvers)
# ------------------------------------------------------------------------------
static func _pct(base: float, pm: float, lvl: int, step_every: int = 0) -> float:
	var bonus: float = 0.0
	if step_every > 0 and lvl > 1:
		bonus = pm * float((lvl - 1) / step_every)
	return max(0.0, base + bonus)

static func _actor(snapshot: Dictionary, id: String) -> Dictionary:
	var actors: Dictionary = snapshot.get("actors", {}) as Dictionary
	return actors.get(id, {}) as Dictionary

static func _ensure_effects(snapshot: Dictionary, id: String) -> Array:
	var a: Dictionary = _actor(snapshot, id)
	if a.is_empty():
		return []
	if not a.has("effects") or not (a["effects"] is Array):
		a["effects"] = []
	return a["effects"] as Array

static func _push_effect(snapshot: Dictionary, id: String, eff: Dictionary) -> void:
	var arr: Array = _ensure_effects(snapshot, id)
	arr.append(eff)
	_d("effect pushed -> target=%s id=%s dur=%d tags=%s"
		% [id, String(eff.get("id","")), int(eff.get("duration_turns",0)), str(eff.get("tags", []))])
	_log("status", "Effect applied", {
		"target": id,
		"id": String(eff.get("id","")),
		"duration": int(eff.get("duration_turns",0)),
		"tags": eff.get("tags", [])
	})

static func _first_mark(effects: Array) -> int:
	for i in range(effects.size()):
		var ed: Dictionary = effects[i] as Dictionary
		if ed.get("mark", null) is Dictionary:
			return i
	return -1

# ------------------------------------------------------------------------------
# Translate rider → status (pure function; does not mutate snapshot)
# ------------------------------------------------------------------------------
static func rider_to_status(ability_row: Dictionary, caster_ctx: Dictionary, target_ctx: Dictionary, last: Dictionary, lvl: int, rng: RandomNumberGenerator) -> Dictionary:
	var A: Dictionary = ability_row
	var P: Dictionary = A.get("progression", {}) as Dictionary
	var R: Dictionary = P.get("rider", {}) as Dictionary
	if R.is_empty():
		return {}

	var t: String = String(R.get("type", ""))
	if t.is_empty():
		return {}

	var status: Dictionary = {
		"id": t.to_lower(),
		"source_ability": String(A.get("ability_id", "")),
		"by_actor": String(caster_ctx.get("id", "")),
		"tags": [],
		"duration_turns": int(R.get("duration_turns", 0)),
		"stacks": 1,
		"mods": {}
	}

	var base_pct: float = float(R.get("base_pct", 0.0))
	var per_ms: float = float(R.get("per_milestone_pct", 0.0))
	var step_ev: int = int(R.get("duration_turns_step_every", 0))
	var pct: float = _pct(base_pct, per_ms, max(1, lvl), step_ev)

	match t:
		"BLEED_FROM_DAMAGE_PCT":
			var last_dmg: int = int(last.get("damage", 0))
			if last_dmg <= 0:
				return {}
			var per_tick: int = max(1, int(round(float(last_dmg) * pct * 0.01)))
			status["tags"] = ["debuff","dot","bleed"]
			status["dot"] = {"elem": "bleed", "amount_per_turn": per_tick}

		"IGNITE_CHANCE_PCT":
			var chance: float = clampf(pct, 0.0, 100.0)
			if rng.randf() * 100.0 > chance:
				return {}
			var last_dmg2: int = int(last.get("damage", 0))
			if last_dmg2 <= 0:
				return {}
			var burn: int = max(1, int(round(float(last_dmg2) * 0.15)))
			status["tags"] = ["debuff","dot","burn"]
			status["duration_turns"] = max(int(status["duration_turns"]), 2)
			status["dot"] = {"elem": "fire", "amount_per_turn": burn}

		"SELF_DEF_UP_PCT":
			status["tags"] = ["buff","defense"]
			(status["mods"] as Dictionary)["defense_bonus_pct"] = pct
			status["target"] = "self"

		"PRECISION_PCT":
			status["tags"] = ["buff","accuracy"]
			(status["mods"] as Dictionary)["hit_bonus_pct"] = pct
			status["target"] = "self"

		"ARMOR_SHRED_PCT":
			status["tags"] = ["debuff","shred"]
			(status["mods"] as Dictionary)["armor_shred_pct"] = pct

		"ARMOR_IGNORE_PCT":
			status["tags"] = ["buff","ignore"]
			(status["mods"] as Dictionary)["armor_ignore_pct"] = pct
			status["target"] = "self"

		"BONUS_VS_ARMORED_PCT":
			status["tags"] = ["buff","conditional"]
			(status["mods"] as Dictionary)["bonus_vs_armored_pct"] = pct
			status["target"] = "self"

		"GUARD_BREAK_STRENGTH_PCT":
			status["tags"] = ["debuff","guard_break"]
			(status["mods"] as Dictionary)["guard_break_pct"] = pct

		"HEADSHOT_BIAS_PCT":
			status["tags"] = ["buff","crit"]
			(status["mods"] as Dictionary)["crit_bias_head_pct"] = pct
			status["target"] = "self"

		"ENEMY_HIT_DOWN_PCT":
			status["tags"] = ["debuff","accuracy"]
			(status["mods"] as Dictionary)["enemy_hit_down_pct"] = pct

		"ENEMY_EVA_DOWN_PCT":
			status["tags"] = ["debuff","evasion"]
			(status["mods"] as Dictionary)["enemy_eva_down_pct"] = pct

		"SLOW_AGI_DOWN_PCT":
			status["tags"] = ["debuff","slow"]
			(status["mods"] as Dictionary)["agi_down_pct"] = pct

		"MARK_AMPLIFY_NEXT_HIT_PCT":
			status["tags"] = ["debuff","mark"]
			status["mark"] = {"amplify_pct": pct, "consume_on_hit": true}

		"OVERHEAL_TO_SHIELD_PCT":
			status["tags"] = ["buff","shield"]
			(status["mods"] as Dictionary)["overheal_to_shield_pct"] = pct
			status["shield"] = {"amount": 0}
			status["target"] = "self"

		"BLOCK_TIER_UP_PCT":
			status["tags"] = ["buff","block"]
			(status["mods"] as Dictionary)["block_tier_up_pct"] = pct
			status["target"] = "self"

		"BLOCK_EFFECT_PCT":
			status["tags"] = ["buff","block"]
			(status["mods"] as Dictionary)["block_effect_pct"] = pct
			status["target"] = "self"

		"HIT_AND_DAMAGE_BONUS":
			var base_hit: float = float(R.get("base_hit_pct", 0.0))
			var pm_hit: float = float(R.get("per_milestone_hit_pct", 0.0))
			var base_dmg: float = float(R.get("base_damage_pct", 0.0))
			var pm_dmg: float = float(R.get("per_milestone_damage_pct", 0.0))
			status["tags"] = ["buff","tempo"]
			var mods: Dictionary = status["mods"] as Dictionary
			mods["hit_bonus_pct"]    = _pct(base_hit, pm_hit, lvl)
			mods["damage_bonus_pct"] = _pct(base_dmg, pm_dmg, lvl)
			status["target"] = "self"

		"MEDITATE_MP_PER_TURN_PCT":
			status["tags"] = ["buff","regen"]
			var mpM: int = int(caster_ctx.get("mp_max", 0))
			var per_turn: int = max(1, int(round(float(mpM) * pct * 0.01)))
			status["regen"] = {"mp_per_turn": per_turn, "stam_per_turn": 0}
			status["target"] = "self"

		"RESTORE_STAM_PCT":
			_d("emit immediate RESTORE_STAM_PCT -> %s%%" % String.num(pct, 1))
			return {"_immediate": true, "type": "RESTORE_STAM_PCT", "pct": pct}

		"CLEANSE_STRENGTH_PCT":
			_d("emit immediate CLEANSE_STRENGTH_PCT -> %s%%" % String.num(pct, 1))
			return {"_immediate": true, "type": "CLEANSE_STRENGTH_PCT", "pct": pct}

		_:
			_d("unknown rider type: " + t)
			return {}

	_d("rider_to_status -> id=%s dur=%d tags=%s mods=%s"
		% [String(status.get("id","")), int(status.get("duration_turns",0)), str(status.get("tags",[])), str(status.get("mods",{}))])
	if not status.has("target"):
		status["target"] = "enemy"
	return status

# ------------------------------------------------------------------------------
# Apply status to target in a snapshot
# ------------------------------------------------------------------------------
static func apply_status(snapshot: Dictionary, target_id: String, status: Dictionary) -> Dictionary:
	if status.is_empty():
		_d("apply_status skipped (empty)")
		return {}
	var eff: Dictionary = status.duplicate(true)
	_push_effect(snapshot, target_id, eff)
	return {
		"type": "StatusApplied",
		"target": target_id,
		"status_id": String(eff.get("id","")),
		"source_ability": String(eff.get("source_ability","")),
		"duration": int(eff.get("duration_turns",0)),
		"tags": eff.get("tags", []) as Array
	}

# ------------------------------------------------------------------------------
# Aggregate attack/defense modifiers from effects on both sides
# ------------------------------------------------------------------------------
static func mods_for_attack(snapshot: Dictionary, attacker_id: String, defender_id: String) -> Dictionary:
	var atk: Dictionary = _actor(snapshot, attacker_id)
	var def: Dictionary = _actor(snapshot, defender_id)

	var out: Dictionary = {
		"hit_bonus_pct": 0.0,
		"damage_bonus_pct": 0.0,
		"armor_ignore_pct": 0.0,
		"bonus_vs_armored_pct": 0.0,
		"crit_bias_head_pct": 0.0,
		"enemy_hit_down_pct": 0.0,
		"enemy_eva_down_pct": 0.0,
		"armor_shred_pct": 0.0,
		"guard_break_pct": 0.0,
		"agi_down_pct": 0.0
	}

	var atk_effs: Array = atk.get("effects", []) as Array
	for e_idx in range(atk_effs.size()):
		var e: Dictionary = atk_effs[e_idx] as Dictionary
		var m: Dictionary = e.get("mods", {}) as Dictionary
		for k in out.keys():
			var kk := String(k)
			out[kk] = float(out.get(kk, 0.0)) + float(m.get(kk, 0.0))

	var def_effs: Array = def.get("effects", []) as Array
	for e2_idx in range(def_effs.size()):
		var e2: Dictionary = def_effs[e2_idx] as Dictionary
		var m2: Dictionary = e2.get("mods", {}) as Dictionary
		out["enemy_hit_down_pct"] += float(m2.get("enemy_hit_down_pct", 0.0))
		out["enemy_eva_down_pct"] += float(m2.get("enemy_eva_down_pct", 0.0))
		out["armor_shred_pct"]    += float(m2.get("armor_shred_pct", 0.0))
		out["guard_break_pct"]    += float(m2.get("guard_break_pct", 0.0))
		out["agi_down_pct"]       += float(m2.get("agi_down_pct", 0.0))

	return out

# ------------------------------------------------------------------------------
# Consume a single "mark" effect (if present) from defender
# ------------------------------------------------------------------------------
static func maybe_consume_mark(snapshot: Dictionary, defender_id: String) -> float:
	var effs: Array = _ensure_effects(snapshot, defender_id)
	var idx: int = _first_mark(effs)
	if idx < 0:
		return 0.0
	var mark_dic: Dictionary = (effs[idx] as Dictionary).get("mark", {}) as Dictionary
	var amp: float = float(mark_dic.get("amplify_pct", 0.0))
	if bool(mark_dic.get("consume_on_hit", false)):
		effs.remove_at(idx)
		_d("mark consumed on %s -> amp=%s%%" % [defender_id, String.num(amp,1)])
		_log("status", "Mark consumed", {"target": defender_id, "amp_pct": amp})
	return amp

# ------------------------------------------------------------------------------
# Turn tick for all statuses (DOT, regen, and expiry)
# ------------------------------------------------------------------------------
static func tick_all(snapshot: Dictionary, rng: RandomNumberGenerator) -> Array:
	var events: Array = []
	var actors: Dictionary = snapshot.get("actors", {}) as Dictionary
	for id_any in actors.keys():
		var id: String = String(id_any)
		var A: Dictionary = actors.get(id, {}) as Dictionary
		var arr: Array = A.get("effects", []) as Array

		var total_dot: int = 0
		var mp_reg: int = 0
		var stam_reg: int = 0
		for e_any in arr:
			var e_dict: Dictionary = e_any as Dictionary

			var d_any: Variant = e_dict.get("dot", null)
			if d_any is Dictionary:
				total_dot += int((d_any as Dictionary).get("amount_per_turn", 0))

			var rg_any: Variant = e_dict.get("regen", null)
			if rg_any is Dictionary:
				var rg: Dictionary = rg_any as Dictionary
				mp_reg += int(rg.get("mp_per_turn", 0))
				stam_reg += int(rg.get("stam_per_turn", 0))

		if total_dot > 0:
			var dot_left: int = total_dot
			for i in range(arr.size()):
				var e2: Dictionary = arr[i] as Dictionary
				var sh_any: Variant = e2.get("shield", null)
				if sh_any is Dictionary:
					var sh: Dictionary = sh_any as Dictionary
					var have: int = int(sh.get("amount", 0))
					var used: int = min(have, dot_left)
					sh["amount"] = max(0, have - used)
					dot_left -= used
					if used > 0:
						events.append({"type":"ShieldDamaged","target": id, "amount": used})
						_d("shield absorbed %d from DOT on %s" % [used, id])
					if dot_left <= 0:
						break
			if dot_left > 0:
				A["hp"] = max(0, int(A.get("hp", 0)) - dot_left)
				events.append({"type":"DamageApplied","target": id, "amount": dot_left, "reason":"dot"})
				_d("DOT applied %d to %s" % [dot_left, id])
				_log("hit", "DOT damage", {"target": id, "amount": dot_left})

		if mp_reg > 0:
			A["mp"] = min(int(A.get("mp_max", 0)), int(A.get("mp", 0)) + mp_reg)
			events.append({"type":"ResourceRestored","target": id, "mp": mp_reg})
			_d("regen MP +%d on %s" % [mp_reg, id])
			_log("resource", "MP regen", {"target": id, "mp": mp_reg})
		if stam_reg > 0:
			A["stam"] = min(int(A.get("stam_max", 0)), int(A.get("stam", 0)) + stam_reg)
			events.append({"type":"ResourceRestored","target": id, "stam": stam_reg})
			_d("regen ST +%d on %s" % [stam_reg, id])
			_log("resource", "Stamina regen", {"target": id, "stam": stam_reg})

		var i2: int = 0
		while i2 < arr.size():
			var e3: Dictionary = arr[i2] as Dictionary
			var dur: int = int(e3.get("duration_turns", 0))
			if dur > 0:
				dur -= 1
				e3["duration_turns"] = dur
				if dur <= 0:
					events.append({"type":"StatusRemoved","target": id, "status_id": String(e3.get("id",""))})
					_d("status expired on %s -> %s" % [id, String(e3.get("id",""))])
					_log("status", "Effect expired", {"target": id, "id": String(e3.get("id",""))})
					arr.remove_at(i2)
					continue
			i2 += 1

	return events
