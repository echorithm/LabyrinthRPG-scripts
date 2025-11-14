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

	# Snapshots → plain dicts so helpers don’t depend on classes.
	var atk_snap: Dictionary = {}
	if atk != null and atk is Object and atk.has_method("to_dict"):
		atk_snap = atk.to_dict()
	var A_mods: Dictionary = (atk_snap.get("mods", {}) as Dictionary)

	var def_by_id: Dictionary = {}
	for d_any in defs:
		if d_any is Object and d_any.has_method("to_dict"):
			var d: Dictionary = d_any.to_dict()
			def_by_id[int(d.get("id", -1))] = d

	for row_v in rows_for_riders:
		if typeof(row_v) != TYPE_DICTIONARY:
			continue
		var row: Dictionary = row_v as Dictionary
		var aid: String = String(row.get("ability_id",""))
		var target_id: int = int(row.get("target_id", -1))
		var lvl: int = max(1, int(row.get("ability_level", 1)))

		var cat: Dictionary = AbilityCatalog.get_by_id(aid)
		if cat.is_empty():
			if DEBUG_RIDERS:
				print("[Riders] ability not found in catalog id=", aid)
			continue

		# Enrich row with mods so helpers can read bias/resist easily.
		row["__A_mods"] = A_mods
		var D_snap: Dictionary = (def_by_id.get(target_id, {}) as Dictionary)
		var D_mods: Dictionary = (D_snap.get("mods", {}) as Dictionary)
		row["__D_mods"] = D_mods

		if DEBUG_RIDERS:
			print("[Riders] Begin aid=", aid, " lvl=", lvl, " dst=", target_id, " total=", int(row.get("total", 0)))

		var events: Array[Dictionary] = []
		var deltas: Array[Dictionary] = []

		# --- A) Progression rider block (e.g., BLEED_FROM_DAMAGE_PCT) ---
		var prog_any: Variant = cat.get("progression", {})
		var prog: Dictionary = (prog_any as Dictionary) if typeof(prog_any) == TYPE_DICTIONARY else {}
		var rider_prog_any: Variant = prog.get("rider", {})
		var rider_prog: Dictionary = (rider_prog_any as Dictionary) if typeof(rider_prog_any) == TYPE_DICTIONARY else {}
		if not rider_prog.is_empty():
			_apply_progression_rider(row, rider_prog, lvl, rng, events, deltas)

		# --- B) Riders array (DOTs like bleed/ignite) ---
		var riders_any: Variant = cat.get("riders", [])
		if typeof(riders_any) == TYPE_ARRAY:
			for r_any in (riders_any as Array):
				if typeof(r_any) != TYPE_DICTIONARY:
					continue
				_apply_array_rider(row, (r_any as Dictionary), rng, events, deltas)

		# --- C) NEW: on-hit sustain for attacker + thorns reflect for defender ---
		var attacker_id: int = int(row.get("attacker_id", -1))
		var total: int = int(row.get("total", 0))

		# sustain
		var heal_on_hit: int = int(A_mods.get("on_hit_hp_flat", 0))
		var mp_on_hit: int = int(A_mods.get("on_hit_mp_flat", 0))
		if total > 0 and (heal_on_hit > 0 or mp_on_hit > 0):
			if heal_on_hit > 0:
				deltas.append({"actor_id": attacker_id, "hp": heal_on_hit})
				events.append({ "type":"heal_applied", "source_id": attacker_id, "target_id": attacker_id, "amount": heal_on_hit })
			if mp_on_hit > 0:
				deltas.append({"actor_id": attacker_id, "mp": mp_on_hit})
				events.append({ "type":"status_tick", "subtype":"mp", "actor_id": attacker_id, "status_id":"on_hit_mp", "amount": mp_on_hit })

		# thorns
		var thorns_pp: float = float(D_mods.get("thorns_pct", 0.0))
		if total > 0 and thorns_pp > 0.0 and attacker_id >= 0:
			var reflect: int = int(round(float(total) * (thorns_pp * 0.01)))
			if reflect > 0:
				deltas.append({"actor_id": attacker_id, "hp": -reflect})
				events.append({
					"type":"damage_applied", "src": target_id, "dst": attacker_id,
					"lanes": {}, "total": reflect, "tags": ["reflect","thorns"]
				})

		if not events.is_empty() or not deltas.is_empty():
			out.append({"events": events, "deltas": deltas})
			if DEBUG_RIDERS:
				print("[Riders]   -> produced events=", events.size(), " deltas=", deltas.size())
		elif DEBUG_RIDERS:
			print("[Riders]   -> no rider effects produced")

	return out


# ---------------- internal helpers ----------------

func _apply_progression_rider(row: Dictionary, rider: Dictionary, lvl: int, rng: Object, events: Array[Dictionary], deltas: Array[Dictionary]) -> void:
	var r_type: String = String(rider.get("type",""))
	if r_type == "":
		return

	# Special cases (unchanged) …
	if r_type == "BLEED_FROM_DAMAGE_PCT":
		if DEBUG_RIDERS:
			print("[Riders]   progression type=BLEED_FROM_DAMAGE_PCT (damage-derived)")
		if _apply_bleed_from_damage(row, rider, lvl, events):
			return
		return
	if r_type == "HIT_AND_DAMAGE_BONUS" or r_type == "HIT_AND_DAMAGE_BONUS_DAMAGE_BONUS":
		if DEBUG_RIDERS:
			print("[Riders]   progression type=HIT_AND_DAMAGE_BONUS (kernel-handled; no status)")
		return

	# Milestones etc. (unchanged)
	var milestones: int = lvl / 5
	var base_pct: float = float(rider.get("base_pct", 0.0))
	var per_ms_pct: float = float(rider.get("per_milestone_pct", 0.0))
	var pct_final: float = base_pct + per_ms_pct * float(milestones)

	var duration_turns: int = int(rider.get("duration_turns", 1))
	var every_n: int = int(rider.get("duration_turns_step_every", 0))
	if every_n > 0:
		duration_turns += int(lvl / every_n)

	# NEW: bias/resist applied to the application chance
	var apply_prob: float = clamp(float(rider.get("chance_pct", 100.0)) * 0.01, 0.0, 1.0)
	var A_mods: Dictionary = (row.get("__A_mods", {}) as Dictionary)
	var D_mods: Dictionary = (row.get("__D_mods", {}) as Dictionary)
	var status_id: String = _status_id_from_type(r_type)
	var bias: float = clamp(float(A_mods.get("status_on_hit_bias_pct", 0.0)) * 0.01, -1.0, 1.0)
	var resist_map: Dictionary = (D_mods.get("status_resist_pct", {}) as Dictionary)
	var resist: float = clamp(float(resist_map.get(status_id, 0.0)) * 0.01, 0.0, 1.0)
	var apply_prob_final: float = clamp(apply_prob * (1.0 + bias) * (1.0 - resist), 0.0, 1.0)

	var rolled_ok: bool = _roll_status(rng, apply_prob_final)

	if DEBUG_RIDERS:
		print("[Riders]   progression type=", r_type, " -> status=", status_id, " prob(base)=", apply_prob, " bias=", bias, " resist=", resist, " final=", apply_prob_final, " lvl=", lvl, " ms=", milestones)

	if status_id == "":
		if DEBUG_RIDERS:
			print("[Riders]   (skip) unknown rider type=", r_type)
		return
	if not rolled_ok:
		events.append({
			"type": "status_resisted",
			"src": int(row.get("attacker_id", -1)),
			"dst": int(row.get("target_id", -1)),
			"id": status_id
		})
		return

	events.append({
		"type": "status_applied",
		"src": int(row.get("attacker_id", -1)),
		"dst": int(row.get("target_id", -1)),
		"id": status_id,
		"kind": _status_kind_from_type(r_type),
		"stacks": 1,
		"turns": duration_turns
	})

func _apply_array_rider(row: Dictionary, r: Dictionary, rng: Object, events: Array[Dictionary], deltas: Array[Dictionary]) -> void:
	# Expected keys in riders[] entries: { id, chance, stacks, duration, kind, per_stack_tick }
	var rid: String = String(r.get("id",""))
	if rid == "":
		return

	var chance: float = clamp(float(r.get("chance", 1.0)), 0.0, 1.0)

	# Optional: progression-specified ignite bonus (e.g., IGNITE_CHANCE_PCT)
	if rid == _IGNITE_KEY:
		var aid: String = String(row.get("ability_id",""))
		var cat: Dictionary = AbilityCatalog.get_by_id(aid)
		if not cat.is_empty():
			var prog: Dictionary = (cat.get("progression", {}) as Dictionary)
			var rider_prog: Dictionary = (prog.get("rider", {}) as Dictionary)
			if not rider_prog.is_empty() and String(rider_prog.get("type","")) == "IGNITE_CHANCE_PCT":
				var lvl: int = max(1, int(row.get("ability_level", 1)))
				var bonus_pp: float = _compute_ignite_bonus_pct(rider_prog, lvl) # e.g., +10.0 pp
				chance = clamp(chance + (bonus_pp * 0.01), 0.0, 1.0)

	# NEW: attacker bias and defender resist
	var A_mods: Dictionary = (row.get("__A_mods", {}) as Dictionary)
	var D_mods: Dictionary = (row.get("__D_mods", {}) as Dictionary)
	var bias: float = clamp(float(A_mods.get("status_on_hit_bias_pct", 0.0)) * 0.01, -1.0, 1.0)
	var resist_map: Dictionary = (D_mods.get("status_resist_pct", {}) as Dictionary)
	var resist: float = clamp(float(resist_map.get(rid, 0.0)) * 0.01, 0.0, 1.0)
	var final_chance: float = clamp(chance * (1.0 + bias) * (1.0 - resist), 0.0, 1.0)

	var ok: bool = _roll_status(rng, final_chance)

	if DEBUG_RIDERS:
		print("[Riders]   array id=", rid, " chance(base)=", chance, " bias=", bias, " resist=", resist, " -> final=", final_chance, " roll=", ok)

	if not ok:
		events.append({
			"type": "status_resisted",
			"src": int(row.get("attacker_id", -1)),
			"dst": int(row.get("target_id", -1)),
			"id": rid
		})
		return

	var stacks: int = int(r.get("stacks", 1))
	var duration: int = int(r.get("duration", 3))
	var per_tick: int = int(r.get("per_stack_tick", 0))
	var kind: String = String(r.get("kind", "dot"))

	events.append({
		"type": "status_applied",
		"src": int(row.get("attacker_id", -1)),
		"dst": int(row.get("target_id", -1)),
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
