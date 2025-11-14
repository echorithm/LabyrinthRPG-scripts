# res://scripts/combat/kernel/CombatKernel.gd
extends RefCounted
class_name CombatKernel

const PreUseRules         := preload("res://scripts/combat/kernel/pipeline/PreUseRules.gd")
const TargetingRules      := preload("res://scripts/combat/kernel/pipeline/TargetingRules.gd")
const AttackPipeline      := preload("res://scripts/combat/kernel/pipeline/AttackPipeline.gd")
const DefensePipeline     := preload("res://scripts/combat/kernel/pipeline/DefensePipeline.gd")
const BuffDebuffPipeline  := preload("res://scripts/combat/kernel/pipeline/BuffDebuffPipeline.gd")
# ResolveTurnPipeline handles BETWEEN-TURNS upkeep; controller calls it, not this resolver.

const ActionResult   := preload("res://scripts/combat/data/ActionResult.gd")
const ActorSnapshot  := preload("res://scripts/combat/data/ActorSnapshot.gd")
const TurnContext    := preload("res://scripts/combat/data/TurnContext.gd")
const AbilityUse     := preload("res://scripts/combat/data/AbilityUse.gd")
const RNGService     := preload("res://scripts/combat/util/RNGService.gd")
const CTBParams      := preload("res://scripts/combat/ctb/CTBParams.gd")
const Events         := preload("res://scripts/combat/data/CombatEvents.gd")
const CombatTrace    := preload("res://scripts/combat/util/CombatTrace.gd")

# Use the service, not the autoload script
const AbilityCatalogService := preload("res://persistence/services/ability_catalog_service.gd")
const HealMath := preload("res://scripts/combat/util/HealMath.gd")


# ---------- typed helpers ----------
static func _to_dict_array(v: Variant) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if v is Array:
		for e in (v as Array):
			if e is Dictionary:
				out.append((e as Dictionary).duplicate(true))
	return out

static func _to_int_array(v: Variant) -> Array[int]:
	var out: Array[int] = []
	if v is Array:
		for e in (v as Array):
			out.append(int(e))
	return out

static func _snap_by_id(actors: Array[ActorSnapshot], idv: int) -> ActorSnapshot:
	for a: ActorSnapshot in actors:
		if a.id == idv:
			return a
	return null

static func _snaps_by_ids(actors: Array[ActorSnapshot], ids: Array[int]) -> Array[ActorSnapshot]:
	var out: Array[ActorSnapshot] = []
	var set: Dictionary = {}
	for i: int in ids:
		set[i] = true
	for a: ActorSnapshot in actors:
		if set.has(a.id):
			out.append(a)
	return out

static func _safe_targets(arr: Variant) -> Array[int]:
	var out: Array[int] = []
	if arr is Array:
		for v in (arr as Array):
			out.append(int(v))
	return out

static func _extract_ability_level(atk: ActorSnapshot, ability_id: String) -> int:
	var lvl: int = 1
	var snap: Dictionary = atk.to_dict()
	if snap.has("abilities") and snap["abilities"] is Dictionary:
		var ab: Dictionary = snap["abilities"] as Dictionary
		if ab.has(ability_id):
			var v: Variant = ab[ability_id]
			if v is int:
				lvl = int(v)
			elif v is Dictionary and (v as Dictionary).has("level"):
				lvl = int((v as Dictionary)["level"])
	return max(1, lvl)

# Read per-level scalar from the ability row (works for both power/heal)
static func _power_or_heal_scalar_from_row(row: Dictionary, level: int) -> float:
	var lvl: int = max(1, level)
	var prog_any: Variant = row.get("progression", {})
	if typeof(prog_any) != TYPE_DICTIONARY:
		return 1.0
	var prog: Dictionary = prog_any as Dictionary
	var per_any: Variant = prog.get("per_level", {})
	if typeof(per_any) != TYPE_DICTIONARY:
		return 1.0
	var per: Dictionary = per_any as Dictionary
	var step: float = 0.0
	if per.has("power_pct"):
		step = float(per["power_pct"])
	elif per.has("heal_pct"):
		step = float(per["heal_pct"])
	return 1.0 + (float(lvl - 1) * step) * 0.01
# -----------------------------------

func resolve(
	turn_ctx: TurnContext,
	actors: Array[ActorSnapshot],
	use: AbilityUse,
	rng: RNGService,
	_params: CTBParams
) -> ActionResult:
	# Attacker
	var atk: ActorSnapshot = _snap_by_id(actors, use.actor_id)
	if atk == null:
		return ActionResult.invalid("no_attacker")

	var who: String = ("player" if atk.team == "player" else "monster")

	var events: Array[Dictionary] = []
	CombatTrace.hdr("turn_began actor=" + str(atk.id) + " ability=" + use.ability_id)
	events.append(Events.turn_began(turn_ctx.round, atk.id, who))
	events.append(Events.ability_used(atk.id, use.ability_id, _safe_targets(use.targets), int(round(use.time_ctb_cost))))

	# Step 0: pre-use validation & cost deltas (controller applies these)
	var pre: Dictionary = PreUseRules.new().validate_and_prepare(atk, use)
	if not bool(pre.get("ok", false)):
		events.append({"type": "fizzle", "who": who, "reason": String(pre.get("reason",""))})
		return ActionResult.ok_result("invalid", [], events)
	var deltas: Array[Dictionary] = _to_dict_array(pre.get("deltas", []))

	# Narrate costs if provided
	var paid_mp: int = int(pre.get("mp", 0))
	var paid_stam: int = int(pre.get("stam", 0))
	var paid_charges: int = int(pre.get("charges", 0))
	var paid_cooldown: int = int(pre.get("cooldown", 0))
	if paid_mp != 0 or paid_stam != 0 or paid_charges != 0 or paid_cooldown != 0:
		events.append(Events.costs_paid(atk.id, paid_mp, paid_stam, paid_charges, paid_cooldown))

	# Step 1: targeting
	var t_res: Dictionary = TargetingRules.new().validate(actors, use, turn_ctx)
	if not bool(t_res.get("ok", false)):
		return ActionResult.invalid(String(t_res.get("reason", "bad_targets")))
	var target_ids: Array[int] = _to_int_array(t_res.get("targets", []))
	var defs: Array[ActorSnapshot] = _snaps_by_ids(actors, target_ids)

	# Ability meta
	var ability_row: Dictionary = AbilityCatalogService.get_by_id(use.ability_id)
	var ability_level: int = _extract_ability_level(atk, use.ability_id)
	var intent_id: String = String(ability_row.get("intent_id",""))
	var kind: String = AbilityCatalogService.attack_kind(use.ability_id)
	print("[Kernel] resolve aid=%s intent=%s kind=%s" % [use.ability_id, intent_id, kind])

	# ---------- HEAL branch ----------
	if intent_id.begins_with("IT_heal"):
		# Allies only (keeps your original fallback-to-self behavior)
		var ally_defs: Array[ActorSnapshot] = []
		for d in defs:
			if d != null and d.team == atk.team:
				ally_defs.append(d)
		if ally_defs.is_empty():
			ally_defs = [atk]

		var atk_snap: Dictionary = atk.to_dict()

		for d in ally_defs:
			var dst_snap: Dictionary = d.to_dict()
			# Adjust name/signature to your HealMath API:
			# Example returns an int; a struct {hp:int, shield:int} also works.
			var heal_amt: int = HealMath.compute_heal(ability_row, ability_level, atk_snap, dst_snap, rng)

			if heal_amt <= 0:
				continue

			deltas.append({"actor_id": d.id, "hp": heal_amt})
			events.append(Events.heal_applied(atk.id, d.id, heal_amt))
		return ActionResult.ok_result("normal", deltas, events)

	# ---------- APPLY-ONLY branch (utility intents) ----------
	if intent_id.begins_with("IT_apply_") or intent_id in [
		"IT_block", "IT_block_boost", "IT_restore_stamina", "IT_restore_mana_over_time",
		"IT_cleanse_single"
	]:
		# Accuracy if to_hit==true; otherwise auto-apply
		var base_acc_apply: float = clamp(float(ability_row.get("accuracy", 1.0)), 0.0, 1.0)

		var rows_for_riders_apply: Array[Dictionary] = []
		for d_apply in defs:
			var hit_apply: bool = true
			if bool(ability_row.get("to_hit", false)):
				rng.set_bag_prob("acc", base_acc_apply)
				hit_apply = rng.roll_acc()
			if not hit_apply:
				events.append(Events.miss(atk.id, d_apply.id, "evasion"))
				continue

			rows_for_riders_apply.append({
				"attacker_id": atk.id,
				"target_id": d_apply.id,
				"ability_id": use.ability_id,
				"lanes": {},      # no damage lanes for apply-only
				"total": 0,
				"did_crit": false,
				"ability_level": ability_level
			})

		var post_rows_apply: Array[Dictionary] = BuffDebuffPipeline.new().run(atk, defs, rows_for_riders_apply, rng)
		for r1 in post_rows_apply:
			if r1.has("events") and (r1["events"] is Array):
				for ev1 in (r1["events"] as Array):
					if ev1 is Dictionary:
						events.append((ev1 as Dictionary).duplicate(true))
			if r1.has("deltas") and (r1["deltas"] is Array):
				for dd1 in (r1["deltas"] as Array):
					if dd1 is Dictionary:
						deltas.append((dd1 as Dictionary).duplicate(true))

		return ActionResult.ok_result("normal", deltas, events)

	# ---------- ATTACK branch ----------
	# Accuracy & Crit channels
	var base_acc: float = clamp(float(ability_row.get("accuracy", 0.85)), 0.0, 1.0)
	var base_crit: float = clamp(float(ability_row.get("crit_chance", 0.10)), 0.0, 1.0)
	rng.set_bag_prob("crit", base_crit)

	# --- HIT_AND_DAMAGE_BONUS perk (read once per resolve) ---
	var hit_bonus_pct: float = 0.0
	var dmg_bonus_pct: float = 0.0
	var prog_any2: Variant = ability_row.get("progression", {})
	if typeof(prog_any2) == TYPE_DICTIONARY:
		var prog2: Dictionary = prog_any2 as Dictionary
		var rider_any2: Variant = prog2.get("rider", {})
		if typeof(rider_any2) == TYPE_DICTIONARY:
			var rp: Dictionary = rider_any2 as Dictionary
			if String(rp.get("type","")) == "HIT_AND_DAMAGE_BONUS":
				hit_bonus_pct = float(rp.get("hit_bonus_pct", 0.0))
				dmg_bonus_pct = float(rp.get("damage_bonus_pct", 0.0))
				# Optional milestone scaling
				var ms2: int = ability_level / 5
				hit_bonus_pct += float(rp.get("per_milestone_hit_pct", 0.0)) * float(ms2)
				dmg_bonus_pct += float(rp.get("per_milestone_damage_pct", 0.0)) * float(ms2)

	# Apply the hit bonus to base accuracy (cap slightly below 1.0)
	if hit_bonus_pct != 0.0:
		base_acc = clamp(base_acc + hit_bonus_pct * 0.01, 0.0, 0.999)

	# Surface the rider as an applied buff (one-shot, purely informational)
	if hit_bonus_pct != 0.0 or dmg_bonus_pct != 0.0:
		# Use the status RNG channel for determinism (p=1, but still routed)
		if rng != null and rng.has_method("set_bag_prob"):
			rng.call("set_bag_prob", "status", 1.0)
		var ev := {
			"type": "status_applied",
			"src": atk.id, "dst": atk.id,
			"id": "hit_and_damage_bonus",
			"kind": "buff",
			"pct_hit": hit_bonus_pct,
			"pct_damage": dmg_bonus_pct,
			"turns": 1
		}
		events.append(ev)

	# Build offense bundle (crit & variance included)
	var atk_dict: Dictionary = atk.to_dict()
	var offense: Dictionary = AttackPipeline.build_offense(ability_row, ability_level, atk.id, atk_dict, rng)
	var did_crit: bool = bool(offense.get("did_crit", false))

	# Per-target
	var rows_for_riders: Array[Dictionary] = []
	for d: ActorSnapshot in defs:
		rng.set_bag_prob("acc", base_acc)
		var hit: bool = rng.roll_acc()
		if not hit:
			events.append(Events.miss(atk.id, d.id, "evasion"))
			continue

		var sub_events: Array[Dictionary] = []
		var emit_cb := func(kind2: String, a, b, c, d4):
			match kind2:
				"shield_absorb":
					sub_events.append(Events.shield_absorb(int(a), String(b), int(c), String(d4)))
				"block":
					sub_events.append(Events.block(int(a), String(b), int(c), String(d4)))
				_:
					pass

		var def_res: Dictionary = DefensePipeline.mitigate(
			offense, atk.id, d.id, d.to_dict(), emit_cb
		)

		var lanes_after: Dictionary = def_res.get("lanes_after", {}) as Dictionary
		var total: int = int(def_res.get("total", 0))

		# Apply post-mitigation damage bonus from perk
		if dmg_bonus_pct != 0.0 and total > 0:
			total = int(round(float(total) * (1.0 + dmg_bonus_pct * 0.01)))

		# Trace the final lanes for UI/telemetry visibility
		CombatTrace.lanes_compact("post-mitigation", lanes_after)

		events.append_array(sub_events)
		if did_crit:
			events.append(Events.crit(atk.id, d.id, float(ability_row.get("crit_multiplier", 1.5))))
		events.append(Events.damage_applied(atk.id, d.id, lanes_after, total))

		if total > 0:
			deltas.append({"actor_id": d.id, "hp": -total})

		# Emit a death event if this hit is lethal relative to the defender snapshot
		var d_snap: Dictionary = d.to_dict()
		var pools_any: Variant = d_snap.get("pools", {})
		var hp_before: int = 0
		if pools_any is Dictionary and (pools_any as Dictionary).has("hp"):
			hp_before = int((pools_any as Dictionary).get("hp", 0))
		if hp_before > 0 and total >= hp_before:
			events.append(Events.death(d.id, atk.id))
			CombatTrace.death(d.id, atk.id)

		rows_for_riders.append({
			"attacker_id": atk.id,
			"target_id": d.id,
			"ability_id": use.ability_id,
			"lanes": lanes_after.duplicate(),
			"total": total,
			"did_crit": did_crit,
			"ability_level": ability_level
		})

	# Riders/status
	var post_rows: Array[Dictionary] = BuffDebuffPipeline.new().run(atk, defs, rows_for_riders, rng)
	for r in post_rows:
		if r.has("events") and (r["events"] is Array):
			for ev in (r["events"] as Array):
				if ev is Dictionary:
					events.append((ev as Dictionary).duplicate(true))
		if r.has("deltas") and (r["deltas"] is Array):
			for dd in (r["deltas"] as Array):
				if dd is Dictionary:
					deltas.append((dd as Dictionary).duplicate(true))

	return ActionResult.ok_result("normal", deltas, events)
