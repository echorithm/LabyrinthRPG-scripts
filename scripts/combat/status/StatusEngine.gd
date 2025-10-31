# FILE: res://scripts/combat/status/StatusEngine.gd
extends RefCounted
class_name StatusEngine
##
## Unified Status Engine (typed)
## - Part A: Bag-style helpers used by UI/panels & simple buffs/debuffs
## - Part B: Runtime-attached statuses for DOT/HoT ticking + resource OT (MP/ST)
## All functions are static so you can call without instancing.
##

# ============================================================================
# Part A — Bag-style helpers (used by EffectsPanel, etc.)
# Bag row shape (UI expects):
#   { id:String, kind:"buff"|"debuff", pct:float, turns:int, meta:Dictionary }
# ============================================================================

static func make(id: String, kind: String, pct: float, turns: int, meta: Dictionary = {}) -> Dictionary:
	var out: Dictionary = {}
	out["id"] = id
	out["kind"] = kind
	out["pct"] = pct
	out["turns"] = max(0, turns)
	out["meta"] = meta
	return out

static func tick_start_of_turn(bag: Array[Dictionary]) -> void:
	# decrement
	for s_i: int in range(bag.size()):
		var s: Dictionary = bag[s_i]
		var t: int = max(0, int(s.get("turns", 0)) - 1)
		s["turns"] = t
		bag[s_i] = s
	# purge expired
	for i: int in range(bag.size() - 1, -1, -1):
		if int(bag[i].get("turns", 0)) <= 0:
			bag.remove_at(i)

static func apply(bag: Array[Dictionary], s: Dictionary) -> void:
	# replace if stronger or longer
	var id_s: String = String(s.get("id",""))
	var replaced: bool = false
	for i: int in range(bag.size()):
		var cur: Dictionary = bag[i]
		if String(cur.get("id","")) == id_s:
			var s_pct: float = float(s.get("pct", 0.0))
			var c_pct: float = float(cur.get("pct", 0.0))
			var s_turns: int = int(s.get("turns", 0))
			var c_turns: int = int(cur.get("turns", 0))
			if s_pct >= c_pct or s_turns > c_turns:
				bag[i] = s
			replaced = true
			break
	if not replaced:
		bag.append(s)

# Returns compact summary used by other systems:
# { def_up_pct, res_up_pct, enemy_hit_down_pct, agi_down_pct, mark_amp_pct }
static func summarize(bag: Array[Dictionary]) -> Dictionary:
	var out: Dictionary = {
		"def_up_pct": 0.0,
		"res_up_pct": 0.0,
		"enemy_hit_down_pct": 0.0,
		"agi_down_pct": 0.0,
		"mark_amp_pct": 0.0
	}
	for s: Dictionary in bag:
		var id_s: String = String(s.get("id",""))
		var pct: float = float(s.get("pct", 0.0))
		match id_s:
			"def_up":
				out["def_up_pct"] = max(float(out["def_up_pct"]), pct)
			"res_up":
				out["res_up_pct"] = max(float(out["res_up_pct"]), pct)
			"enemy_hit_down":
				out["enemy_hit_down_pct"] = max(float(out["enemy_hit_down_pct"]), pct)
			"agi_down":
				out["agi_down_pct"] = max(float(out["agi_down_pct"]), pct)
			"mark_amplify_next_hit":
				out["mark_amp_pct"] = max(float(out["mark_amp_pct"]), pct)
			_:
				pass
	return out

static func purify_debuffs(bag: Array[Dictionary]) -> int:
	var removed: int = 0
	for i: int in range(bag.size() - 1, -1, -1):
		if String(bag[i].get("kind","")) == "debuff":
			bag.remove_at(i)
			removed += 1
	return removed

static func consume_mark_if_present(bag: Array[Dictionary]) -> float:
	for i: int in range(bag.size()):
		if String(bag[i].get("id","")) == "mark_amplify_next_hit":
			var pct: float = float(bag[i].get("pct", 0.0))
			bag.remove_at(i)
			return pct
	return 0.0

# ============================================================================
# Part B — Runtime-attached statuses for DOT/HoT ticking + MP/ST regen
# Runtime is expected to have `id:int` and `statuses:Array[Dictionary]`.
# DOT/HoT row shape:
#   { id, kind:"dot"|"hot"|..., stacks:int, duration:int, per_stack_tick:int, [pct:float] }
# ============================================================================

static func _ensure_store(rt: Object) -> Array[Dictionary]:
	if rt == null:
		return []
	# Create or coerce `statuses` field
	if not ("statuses" in rt):
		rt.statuses = []
	elif rt.statuses == null:
		rt.statuses = []
	var s_arr_any: Variant = rt.statuses
	var out: Array[Dictionary] = []
	if s_arr_any is Array:
		for e in (s_arr_any as Array):
			if e is Dictionary:
				out.append(e as Dictionary)
	rt.statuses = out
	return rt.statuses as Array[Dictionary]

static func attach(rt: Object, status_in: Dictionary) -> void:
	var store: Array[Dictionary] = _ensure_store(rt)
	var sid: String = String(status_in.get("id",""))
	if sid.is_empty():
		return
	var merged: bool = false
	for i: int in range(store.size()):
		var s: Dictionary = store[i]
		if String(s.get("id","")) == sid:
			if status_in.has("stacks"):
				var new_stacks: int = int(status_in.get("stacks", 0))
				s["stacks"] = max(0, int(s.get("stacks", 0)) + new_stacks)
			if status_in.has("duration"):
				s["duration"] = max(0, int(status_in.get("duration", 0)))
			if status_in.has("per_stack_tick"):
				s["per_stack_tick"] = int(status_in.get("per_stack_tick", int(s.get("per_stack_tick", 0))))
			if status_in.has("kind"):
				s["kind"] = String(status_in.get("kind", String(s.get("kind","dot"))))
			if status_in.has("pct"):  # NEW: keep percent payload if provided
				s["pct"] = float(status_in.get("pct", float(s.get("pct", 0.0))))
			store[i] = s
			merged = true
			break
	if not merged:
		var snew: Dictionary = status_in.duplicate(true)
		snew["kind"] = String(snew.get("kind", "dot"))
		snew["stacks"] = int(snew.get("stacks", 1))
		snew["duration"] = int(snew.get("duration", 2))
		snew["per_stack_tick"] = int(snew.get("per_stack_tick", 1))
		if not snew.has("pct"):
			snew["pct"] = 0.0
		store.append(snew)

# Persist status when we see a status event (legacy or new rider-style).
# Supports:
#  - {"type":"status_apply", "actor_id": <dst>, "status": {...}}
#  - {"type":"status_applied","src":...,"dst":...,"id":...,"kind":...,"pct":..., "turns":..., ["per_stack_tick":...,"stacks":...]}
static func apply_event_if_status(e: Dictionary, player_rt: Object, monster_rt: Object) -> void:
	var t: String = String(e.get("type",""))
	if t != "status_applied":
		return

	var dst_id: int = int(e.get("dst", -1))
	if dst_id < 0:
		return

	var rt: Object = _pick_rt_by_id(player_rt, monster_rt, dst_id)
	if rt == null:
		return

	# Build a runtime status row from the event.
	var s: Dictionary = {}
	s["id"] = String(e.get("id",""))
	s["kind"] = String(e.get("kind","dot"))
	if e.has("stacks"):
		s["stacks"] = int(e.get("stacks", 1))
	if e.has("turns"):
		s["duration"] = int(e.get("turns", 1))
	if e.has("per_stack_tick"):
		s["per_stack_tick"] = int(e.get("per_stack_tick", 0))
	if e.has("pct"):  # NEW: keep percent to compute per-turn MP/ST
		s["pct"] = float(e.get("pct", 0.0))

	attach(rt, s)

	if OS.is_debug_build():
		print("[StatusEngine] attached status on dst=", dst_id, " -> ", s)

static func _pick_rt_by_id(p: Object, m: Object, idv: int) -> Object:
	if p != null and int(p.id) == idv:
		return p
	if m != null and int(m.id) == idv:
		return m
	return null

# --- pool helpers (support [cur,max] arrays or scalar+*_max) ---
static func _pool_cur_max(rt: Object, field: String, alt_field: String) -> Dictionary:
	# return {cur:int, max:int}
	var cur: int = 0
	var mx: int = 0

	# Prefer explicit <field> / <field>_max
	if rt.has_method("get"):
		var v: Variant = rt.get(field)
		if v is int:
			cur = int(v)
		elif v is Array and (v as Array).size() >= 2:
			var arr: Array = v as Array
			cur = int(arr[0])
			mx = int(arr[1])

		# explicit max if present
		var mvn: String = field + "_max"
		var mv: Variant = rt.get(mvn)
		if mv != null:
			mx = int(mv)

	# Alt field (e.g., "st")
	if mx <= 0 and rt.has_method("get"):
		var v2: Variant = rt.get(alt_field)
		if v2 is Array and (v2 as Array).size() >= 2:
			var arr2: Array = v2 as Array
			cur = int(arr2[0])
			mx = int(arr2[1])
		elif v2 is int and rt.has_method("get"):
			var mv2: Variant = rt.get(alt_field + "_max")
			if mv2 != null:
				mx = int(mv2)

	# Last resort: if no max found but we have cur, treat mx=cur
	if mx <= 0:
		mx = cur
	return {"cur": cur, "max": mx}

# Returns { deltas:Array[Dictionary], events:Array[Dictionary] }
static func tick_all(player_rt: Object, monster_rt: Object) -> Dictionary:
	var deltas: Array[Dictionary] = []
	var events: Array[Dictionary] = []
	var rts: Array[Object] = []
	if player_rt != null:
		rts.append(player_rt)
	if monster_rt != null:
		rts.append(monster_rt)

	for rt: Object in rts:
		var store: Array[Dictionary] = _ensure_store(rt)
		if store.is_empty():
			continue

		var new_store: Array[Dictionary] = []
		for s: Dictionary in store:
			var dur: int = int(s.get("duration", 0))
			var stacks: int = int(s.get("stacks", 0))
			var kind: String = String(s.get("kind","dot"))
			var per: int = int(s.get("per_stack_tick", 0))
			var sid: String = String(s.get("id",""))
			var pct: float = float(s.get("pct", 0.0))

			# Tick effect (numeric)
			if stacks > 0:
				if kind == "dot" and per != 0:
					var dmg: int = -abs(stacks * per)
					if dmg != 0:
						deltas.append({"actor_id": rt.id, "hp": dmg})
						events.append({
							"type":"status_tick", "subtype":"dot", "actor_id": rt.id,
							"status_id": sid, "amount": dmg
						})
				elif kind == "hot" and per != 0:
					var heal: int = abs(stacks * per)
					if heal != 0:
						deltas.append({"actor_id": rt.id, "hp": heal})
						events.append({
							"type":"status_tick", "subtype":"hot", "actor_id": rt.id,
							"status_id": sid, "amount": heal
						})
				else:
					# Resource-over-time statuses keyed by id (percent-based)
					if sid == "restore_stam" and pct > 0.0:
						var st := _pool_cur_max(rt, "stam", "st")
						var missing: int = max(0, int(st.max) - int(st.cur))
						if missing > 0:
							var amt: int = max(1, int(round(float(st.max) * (pct * 0.01))))
							amt = min(amt, missing)
							deltas.append({"actor_id": rt.id, "stam": amt})
							events.append({
								"type":"status_tick", "subtype":"stam", "actor_id": rt.id,
								"status_id": sid, "amount": amt
							})
					elif sid == "meditate_mp_ot" and pct > 0.0:
						var mp := _pool_cur_max(rt, "mp", "mp")
						var missing_mp: int = max(0, int(mp.max) - int(mp.cur))
						if missing_mp > 0:
							var amt_mp: int = max(1, int(round(float(mp.max) * (pct * 0.01))))
							amt_mp = min(amt_mp, missing_mp)
							deltas.append({"actor_id": rt.id, "mp": amt_mp})
							events.append({
								"type":"status_tick", "subtype":"mp", "actor_id": rt.id,
								"status_id": sid, "amount": amt_mp
							})

			# Decay duration
			dur -= 1
			if dur > 0:
				var keep: Dictionary = s.duplicate(true)
				keep["duration"] = dur
				new_store.append(keep)
			else:
				events.append({"type":"status_expired", "actor_id": rt.id, "status_id": sid})

		# Commit pruned list
		rt.statuses = new_store

	return {"deltas": deltas, "events": events}
