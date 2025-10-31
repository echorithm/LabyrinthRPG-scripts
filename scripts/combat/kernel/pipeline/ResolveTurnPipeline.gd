extends RefCounted
class_name ResolveTurnPipeline

const CombatEvents := preload("res://scripts/combat/data/CombatEvents.gd")

## Post-action upkeep (CTB-style) — PURE NARRATION + COOLDOWN DELTAS
## - Reads each runtime's statuses (without mutating) and emits:
##     status_tick(target_id, status_id, turns_left_after_this_upkeep)
##     status_removed(target_id, status_id) when turns_left would hit 0
## - Also returns cooldown decrement deltas for all alive actors.
## - Actual mutations (hp ticks, duration decay, store pruning) are done by
##   BattleController via StatusEngine.tick_all(player_rt, monster_rt).

var debug_upkeep: bool = true

class UpkeepResult:
	var events: Array[Dictionary] = []
	var deltas: Array[Dictionary] = []
	var finished_advisory: bool = false
	var finished_reason: String = ""  # "victory" | "defeat"

func apply_upkeep(
		tick_time: int,
		all_runtimes: Array,   # Array[Object] (PlayerRuntime|MonsterRuntime Resources)
		rng: Object            # RNGService (present for parity; unused here)
	) -> UpkeepResult:
	var result := UpkeepResult.new()
	if debug_upkeep:
		print("[UPKEEP] >>> begin @t=%d; actors=%d" % [tick_time, all_runtimes.size()])

	var all_events: Array[Dictionary] = []
	var all_deltas: Array[Dictionary] = []

	# 1) Narration: build status_tick/status_removed WITHOUT mutating runtimes.
	for rt_untyped in all_runtimes:
		var rt: Object = rt_untyped
		if not _alive(rt):
			continue
		var rt_id: int = _actor_id(rt)

		var statuses_v: Variant = rt.get("statuses")
		if typeof(statuses_v) == TYPE_ARRAY:
			var statuses_any: Array = statuses_v as Array
			for s_any in statuses_any:
				if not (s_any is Dictionary):
					continue
				var s: Dictionary = s_any as Dictionary
				var sid: String = String(s.get("id", ""))
				if sid.is_empty():
					continue
				var dur_v: Variant = s.get("duration", 0)
				var cur_dur: int = int(dur_v)
				var next_dur: int = max(cur_dur - 1, 0)

				var ev_tick: Dictionary = CombatEvents.status_tick(rt_id, sid, next_dur)
				all_events.append(ev_tick)
				if debug_upkeep:
					print("[UPKEEP] status_tick target=%d status=%s turns_left->%d" % [rt_id, sid, next_dur])

				if next_dur <= 0:
					var ev_rm: Dictionary = CombatEvents.status_removed(rt_id, sid)
					all_events.append(ev_rm)
					if debug_upkeep:
						print("[UPKEEP] status_removed target=%d status=%s" % [rt_id, sid])

	# 2) Global cooldown decrement (pure deltas; reducer will apply).
	for rt_untyped2 in all_runtimes:
		var rt2: Object = rt_untyped2
		if not _alive(rt2):
			continue
		var cds_v: Variant = rt2.get("cooldowns")
		if typeof(cds_v) == TYPE_DICTIONARY:
			var cd_dict: Dictionary = cds_v
			for key_any in cd_dict.keys():
				var ability_id: String = String(key_any)
				var prev_v: Variant = cd_dict.get(ability_id, 0)
				var prev: int = int(prev_v)
				if prev > 0:
					var new_v_i: int = max(prev - 1, 0)
					var d: Dictionary = {
						"kind": "cooldown",
						"actor_id": _actor_id(rt2),
						"ability_id": ability_id,
						"new_value": new_v_i,
					}
					all_deltas.append(d)
					if debug_upkeep:
						print("[UPKEEP] cooldown dec actor=%d ability=%s %d->%d"
							% [_actor_id(rt2), ability_id, prev, new_v_i])

	# 3) Advisory finish check (controller decides definitively after reducer+StatusEngine mutations).
	var living_players: int = 0
	var living_enemies: int = 0
	for rt_untyped3 in all_runtimes:
		var rt3: Object = rt_untyped3
		if _alive(rt3):
			if _is_player(rt3):
				living_players += 1
			else:
				living_enemies += 1

	if debug_upkeep:
		print("[UPKEEP] living(pre-apply): players=%d enemies=%d" % [living_players, living_enemies])

	# ---- DEDUPE *before* returning ----
	all_events = _dedupe_events(all_events)

	result.events = all_events
	result.deltas = all_deltas
	if living_players == 0:
		result.finished_advisory = true
		result.finished_reason = "defeat"
	elif living_enemies == 0:
		result.finished_advisory = true
		result.finished_reason = "victory"

	if debug_upkeep:
		print("[UPKEEP] <<< end (events=%d deltas=%d finished_advisory=%s)"
			% [result.events.size(), result.deltas.size(), str(result.finished_advisory)])
	return result

# --- helpers (no Variant inference) ---

func _alive(rt: Object) -> bool:
	if rt.has_method("is_alive"):
		return bool(rt.call("is_alive"))
	var hpv: Variant = rt.get("hp")
	if hpv != null:
		return int(hpv) > 0
	return true

func _actor_id(rt: Object) -> int:
	var idv: Variant = rt.get("id")
	return int(idv) if idv != null else 0

func _is_player(rt: Object) -> bool:
	var isp_v: Variant = rt.get("is_player")
	if isp_v != null and typeof(isp_v) == TYPE_BOOL:
		return bool(isp_v)

	var team_v: Variant = rt.get("team")
	if team_v != null:
		var ts: String = String(team_v).to_lower()
		return ts == "player" or ts == "players" or ts == "party"

	var idv: Variant = rt.get("id")
	if idv != null:
		return int(idv) < 2000

	return true

# ---------------- utils: event de-dupe ----------------
static func _dedupe_events(events: Array) -> Array[Dictionary]:
	var seen: Dictionary = {}
	var out: Array[Dictionary] = []

	for e in events:
		if typeof(e) != TYPE_DICTIONARY:
			continue
		var ev: Dictionary = e as Dictionary

		var typ := str(ev.get("type", ""))

		var src := ""
		if ev.has("src"):
			src = str(ev.get("src"))
		elif ev.has("actor_id"):
			src = str(ev.get("actor_id"))

		var dst := ""
		if ev.has("dst"):
			dst = str(ev.get("dst"))
		elif ev.has("target_id"):
			dst = str(ev.get("target_id"))

		var sid := ""
		if ev.has("id"):
			sid = str(ev.get("id"))
		elif ev.has("status_id"):
			sid = str(ev.get("status_id"))

		var sub := str(ev.get("subtype", ""))
		var left := str(ev.get("turns_left", ""))
		var uid := str(ev.get("id_unique", ""))

		var key := "%s|%s|%s|%s|%s|%s|%s" % [typ, src, dst, sid, sub, left, uid]
		if not seen.has(key):
			seen[key] = true
			out.append(ev)

	return out
