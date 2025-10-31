# res://scripts/combat/kernel/pipeline/BuffDebuffPipeline.gd
extends RefCounted
class_name BuffDebuffPipeline

const AbilityCatalog := preload("res://persistence/services/ability_catalog_service.gd")
const _IGNITE_KEY := "ignite"

# Toggle rider debug prints
const DEBUG_RIDERS: bool = true

# Input:
# - atk: ActorSnapshot (attacker)  [may be null in tests, but kernel passes it]
# - defs: Array[ActorSnapshot] (defenders/targets)
# - rows_for_riders: Array[Dictionary] per-target bundles:
#     {
#       "attacker_id": int,
#       "target_id": int,
#       "ability_id": String,
#       "lanes": Dictionary,     # post-mitigation lanes (can be {} for apply-only)
#       "total": int,            # damage dealt (0 ok for apply-only)
#       "did_crit": bool,
#       "ability_level": int     # optional; if missing we treat as 1
#     }
# - rng: RNGService
#
# Output: Array[Dictionary] each with optional "events" and/or "deltas" arrays.
# This pipeline decides rider/status effects; it does not change HP directly (except via DoT/HoT during upkeep).
func run(atk, defs: Array, rows_for_riders: Array, rng: Object) -> Array[Dictionary]:
	var out: Array[Dictionary] = []

	if rows_for_riders.is_empty():
		if DEBUG_RIDERS:
			print("[Riders] rows_for_riders empty -> no work")
		return out

	for row_v in rows_for_riders:
		if typeof(row_v) != TYPE_DICTIONARY:
			continue
		var row: Dictionary = row_v as Dictionary

		var aid: String = String(row.get("ability_id",""))
		var target_id: int = int(row.get("target_id", -1))
		if aid == "" or target_id < 0:
			continue

		var lvl: int = max(1, int(row.get("ability_level", 1)))
		var cat: Dictionary = AbilityCatalog.get_by_id(aid)
		if cat.is_empty():
			if DEBUG_RIDERS:
				print("[Riders] ability not found in catalog id=", aid)
			continue

		if DEBUG_RIDERS:
			print("[Riders] Begin aid=", aid, " lvl=", lvl, " dst=", target_id, " total=", int(row.get("total",0)))

		var events: Array[Dictionary] = []
		var deltas: Array[Dictionary] = []

		# --- A) Single progression rider (if authored) -----------------------
		var prog_any: Variant = cat.get("progression", {})
		var prog: Dictionary = (prog_any as Dictionary) if typeof(prog_any) == TYPE_DICTIONARY else {}
		var rider_prog_any: Variant = prog.get("rider", {})
		var rider_prog: Dictionary = (rider_prog_any as Dictionary) if typeof(rider_prog_any) == TYPE_DICTIONARY else {}
		if not rider_prog.is_empty():
			_apply_progression_rider(row, rider_prog, lvl, rng, events, deltas)

		# --- B) Riders array (DOTs like bleed/ignite) ------------------------
		var riders_any: Variant = cat.get("riders", [])
		if typeof(riders_any) == TYPE_ARRAY:
			for r_any in (riders_any as Array):
				if typeof(r_any) != TYPE_DICTIONARY:
					continue
				_apply_array_rider(row, (r_any as Dictionary), rng, events, deltas)

		if not events.is_empty() or not deltas.is_empty():
			out.append({"events": events, "deltas": deltas})
			if DEBUG_RIDERS:
				print("[Riders]   → produced events=", events.size(), " deltas=", deltas.size())
		elif DEBUG_RIDERS:
			print("[Riders]   → no rider effects produced")

	return out


# ---------------- internal helpers ----------------

func _apply_progression_rider(row: Dictionary, rider: Dictionary, lvl: int, rng: Object, events: Array[Dictionary], deltas: Array[Dictionary]) -> void:
	var r_type: String = String(rider.get("type",""))
	if r_type == "":
		return

	# Special case 1: BLEED_FROM_DAMAGE_PCT derives a DoT from row.total and applies immediately.
	if r_type == "BLEED_FROM_DAMAGE_PCT":
		if DEBUG_RIDERS:
			print("[Riders]   progression type=BLEED_FROM_DAMAGE_PCT (damage-derived)")
		if _apply_bleed_from_damage(row, rider, lvl, events):
			return
		# If no damage, just skip
		return

	# Special case 2: IGNITE_CHANCE_PCT is handled in _apply_array_rider as a chance bonus.
	if r_type == "IGNITE_CHANCE_PCT":
		if DEBUG_RIDERS:
			var bonus: float = _compute_ignite_bonus_pct(rider, lvl)
			print("[Riders]   progression type=IGNITE_CHANCE_PCT (bonus +", bonus, "% to ignite chance)")
		return

	if r_type == "HIT_AND_DAMAGE_BONUS":
		if DEBUG_RIDERS:
			print("[Riders]   progression type=HIT_AND_DAMAGE_BONUS (kernel-handled; no status)")
		return

	# Milestones (every 5 levels; author can also use *_step_every for duration)
	var milestones: int = lvl / 5

	var base_pct: float = float(rider.get("base_pct", 0.0))
	var per_ms_pct: float = float(rider.get("per_milestone_pct", 0.0))
	var pct_final: float = base_pct + per_ms_pct * float(milestones)

	var duration_turns: int = int(rider.get("duration_turns", 1))
	var every_n: int = int(rider.get("duration_turns_step_every", 0))
	if every_n > 0:
		duration_turns += int(lvl / every_n)

	# If author provided explicit chance, use it; otherwise 100%
	var apply_prob: float = clamp(float(rider.get("chance_pct", 100.0)) * 0.01, 0.0, 1.0)
	var rolled_ok: bool = _roll_status(rng, apply_prob)

	var status_id: String = _status_id_from_type(r_type)
	var status_kind: String = _status_kind_from_type(r_type)

	var src_id: int = int(row.get("attacker_id", -1))
	var dst_id: int = _rider_dst_for(r_type, src_id, int(row.get("target_id", -1)))

	if DEBUG_RIDERS:
		print("[Riders]   progression type=", r_type, " map->", status_id, " prob=", apply_prob, " lvl=", lvl, " ms=", milestones)

	if status_id == "":
		if DEBUG_RIDERS:
			print("[Riders]   (skip) unknown rider type=", r_type)
		return

	if rolled_ok:
		events.append({
			"type": "status_applied",
			"src": src_id,
			"dst": dst_id,
			"id": status_id,
			"kind": status_kind,
			"pct": pct_final,
			"turns": duration_turns
		})
		if DEBUG_RIDERS:
			print("[Riders]     APPLIED id=", status_id, " kind=", status_kind, " pct=", pct_final, " turns=", duration_turns)
	else:
		events.append({
			"type": "status_resisted",
			"src": src_id,
			"dst": dst_id,
			"id": status_id,
			"reason": "resist"
		})
		if DEBUG_RIDERS:
			print("[Riders]     RESIST id=", status_id)

func _apply_array_rider(row: Dictionary, r: Dictionary, rng: Object, events: Array[Dictionary], deltas: Array[Dictionary]) -> void:
	# Expected keys in riders[] entries:
	# { id, chance, stacks, duration, kind, per_stack_tick }
	var rid: String = String(r.get("id",""))
	if rid == "":
		return

	var chance: float = clamp(float(r.get("chance", 1.0)), 0.0, 1.0)

	if rid == _IGNITE_KEY:
		# Grab ability progression to see if an IGNITE_CHANCE_PCT rider exists.
		var aid: String = String(row.get("ability_id",""))
		var cat: Dictionary = AbilityCatalog.get_by_id(aid)
		if not cat.is_empty():
			var prog: Dictionary = (cat.get("progression", {}) as Dictionary)
			var rider_prog: Dictionary = (prog.get("rider", {}) as Dictionary)
			if not rider_prog.is_empty() and String(rider_prog.get("type","")) == "IGNITE_CHANCE_PCT":
				var lvl: int = max(1, int(row.get("ability_level", 1)))
				var bonus_pct_points: float = _compute_ignite_bonus_pct(rider_prog, lvl) # e.g., +10.0 (%-points)
				chance = clamp(chance + (bonus_pct_points * 0.01), 0.0, 1.0)
				if DEBUG_RIDERS:
					print("[Riders]   ignite chance bonus applied (+", bonus_pct_points, "%) → chance=", chance)

	var ok: bool = _roll_status(rng, chance)

	if DEBUG_RIDERS:
		print("[Riders]   array id=", rid, " chance=", chance, " → roll=", ok)

	if not ok:
		events.append({
			"type": "status_resisted",
			"src": int(row.get("attacker_id", -1)),
			"dst": int(row.get("target_id", -1)),
			"id": rid,
			"reason": "resist"
		})
		return

	var stacks: int = max(1, int(r.get("stacks", 1)))
	var duration: int = max(1, int(r.get("duration", 1)))
	var kind: String = String(r.get("kind","dot"))
	var per_tick: int = int(r.get("per_stack_tick", 0))

	var src_id: int = int(row.get("attacker_id", -1))
	var dst_id: int = int(row.get("target_id", -1)) # array DoTs/HoTs land on struck/selected target

	events.append({
		"type": "status_applied",
		"src": src_id,
		"dst": dst_id,
		"id": rid,
		"kind": kind,
		"stacks": stacks,
		"turns": duration,
		"per_stack_tick": per_tick
	})

	if DEBUG_RIDERS:
		print("[Riders]     APPLIED id=", rid, " kind=", kind, " stacks=", stacks, " turns=", duration, " per_stack_tick=", per_tick)

func _roll_status(rng: Object, p: float) -> bool:
	if rng != null and rng.has_method("set_bag_prob"):
		rng.call("set_bag_prob", "status", p)
	if rng != null and rng.has_method("roll_status"):
		return bool(rng.call("roll_status"))
	# soft fallback
	if rng != null and rng.has_method("randf"):
		return float(rng.call("randf")) < p
	return p >= 1.0

# Rider type → Status id used in StatusEngine
static func _status_id_from_type(r_type: String) -> String:
	match r_type:
		"ENEMY_HIT_DOWN_PCT":                 return "enemy_hit_down"
		"SLOW_AGI_DOWN_PCT":                  return "agi_down"
		"MARK_AMPLIFY_NEXT_HIT_PCT":          return "mark_amplify_next_hit"
		"DEFENSE_UP_PCT", "SELF_DEF_UP_PCT":  return "def_up"
		"RESISTANCE_UP_PCT":                  return "res_up"
		"PRECISION_PCT":                      return "precision_up"
		"ARMOR_SHRED_PCT":                    return "armor_shred"
		"BONUS_VS_ARMORED_PCT":               return "bonus_vs_armored"
		"GUARD_BREAK_STRENGTH_PCT":           return "guard_break"
		"HEADSHOT_BIAS_PCT":                  return "headshot_bias"
		"ARMOR_IGNORE_PCT":                   return "armor_ignore"
		"OVERHEAL_TO_SHIELD_PCT":             return "overheal_to_shield"
		"CLEANSE_STRENGTH_PCT":               return "cleanse_strength"
		"ENEMY_EVA_DOWN_PCT":                 return "enemy_eva_down"
		"STAGGER_CHANCE_PCT":                 return "stagger_chance"
		"RESTORE_STAM_PCT":                   return "restore_stam"
		"MEDITATE_MP_PER_TURN_PCT":           return "meditate_mp_ot"
		"BLOCK_TIER_UP_PCT":                  return "block_tier_up"
		"BLOCK_EFFECT_PCT":                   return "block_effect_up"
		# handled specially (no direct status id mapping)
		"IGNITE_CHANCE_PCT":                  return ""
		"BLEED_FROM_DAMAGE_PCT":              return ""
		_:                                     return ""

# Rider type → "buff" | "debuff"
static func _status_kind_from_type(r_type: String) -> String:
	var debuffs: Array[String] = [
		"ENEMY_HIT_DOWN_PCT",
		"SLOW_AGI_DOWN_PCT",
		"ARMOR_SHRED_PCT",
		"GUARD_BREAK_STRENGTH_PCT",
		"ENEMY_EVA_DOWN_PCT",
		"MARK_AMPLIFY_NEXT_HIT_PCT"
	]
	return "debuff" if (r_type in debuffs) else "buff"

func _apply_bleed_from_damage(row: Dictionary, rider: Dictionary, lvl: int, events: Array[Dictionary]) -> bool:
	var total: int = int(row.get("total", 0))
	if total <= 0:
		return false
	var base_pct: float = float(rider.get("base_pct", 0.0))
	var per_ms_pct: float = float(rider.get("per_milestone_pct", 0.0))
	var milestones: int = lvl / 5
	var pct_final: float = base_pct + per_ms_pct * float(milestones)
	# How much the bleed ticks per turn (scale by damage dealt)
	var per_stack_tick: int = max(1, int(round(float(total) * (pct_final * 0.01))))
	var duration: int = max(1, int(rider.get("duration_turns", 2)))
	var every_n: int = int(rider.get("duration_turns_step_every", 0))
	if every_n > 0:
		duration += int(lvl / every_n)

	var src_id: int = int(row.get("attacker_id", -1))
	var dst_id: int = int(row.get("target_id", -1))
	events.append({
		"type": "status_applied",
		"src": src_id,
		"dst": dst_id,
		"id": "bleed",
		"kind": "dot",
		"stacks": 1,
		"turns": duration,
		"per_stack_tick": per_stack_tick
	})
	if DEBUG_RIDERS:
		print("[Riders]     APPLIED id=bleed kind=dot stacks=1 turns=", duration, " per_stack_tick=", per_stack_tick)
	return true

# Compute ignite bonus (%-points) from progression rider
func _compute_ignite_bonus_pct(rider: Dictionary, lvl: int) -> float:
	var base_pct: float = float(rider.get("base_pct", 0.0))
	var per_ms_pct: float = float(rider.get("per_milestone_pct", 0.0))
	var milestones: int = lvl / 5
	return base_pct + per_ms_pct * float(milestones)

# Decide who the rider should land on (self vs enemy)
static func _rider_dst_for(r_type: String, src_id: int, default_dst_id: int) -> int:
	# Use dictionaries for O(1) membership (GDScript has no set literal)
	var SELF := {
		"SELF_DEF_UP_PCT": true,
		"PRECISION_PCT": true,
		"HEADSHOT_BIAS_PCT": true,
		"BLOCK_EFFECT_PCT": true,
		"BLOCK_TIER_UP_PCT": true,
		"CLEANSE_STRENGTH_PCT": true,
		"RESTORE_STAM_PCT": true,
		"MEDITATE_MP_PER_TURN_PCT": true,
		"ARMOR_IGNORE_PCT": true
	}
	# This map is here for clarity; logic defaults to enemy anyway.
	var ENEMY := {
		"ENEMY_HIT_DOWN_PCT": true,
		"ENEMY_EVA_DOWN_PCT": true,
		"ARMOR_SHRED_PCT": true,
		"SLOW_AGI_DOWN_PCT": true,
		"GUARD_BREAK_STRENGTH_PCT": true,
		"MARK_AMPLIFY_NEXT_HIT_PCT": true,
		"STAGGER_CHANCE_PCT": true,
		"BONUS_VS_ARMORED_PCT": true
	}
	# Damage-derived types always use the struck target:
	if r_type.ends_with("_FROM_DAMAGE_PCT"):
		return default_dst_id
	if SELF.has(r_type):
		return src_id
	# default to enemy/struck target
	return default_dst_id
