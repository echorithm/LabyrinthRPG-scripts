extends RefCounted
class_name HealMath
##
## Deterministic heal math used by both combat and out-of-combat flows.
## - Flat base from catalog + small level scalar + linear WIS term.
## - Optional rider: OVERHEAL_TO_SHIELD_PCT (converts overheal to a short shield).
## All functions are static; no instances or RNG needed.

const AbilityCatalogService := preload("res://persistence/services/ability_catalog_service.gd")

# --- Tuners ---------------------------------------------------------------
const WIS_COEFF: float = 1.0  # how much each point of WIS adds to heal

# --- Public helpers -------------------------------------------------------

static func per_level_heal_pct_from_row(row: Dictionary) -> float:
	var prog_any: Variant = row.get("progression", {})
	if prog_any is Dictionary:
		var per_any: Variant = (prog_any as Dictionary).get("per_level", {})
		if per_any is Dictionary and (per_any as Dictionary).has("heal_pct"):
			return float((per_any as Dictionary).get("heal_pct", 0.0))
	return 0.0

static func rider_from_row(row: Dictionary) -> Dictionary:
	var prog_any: Variant = row.get("progression", {})
	if prog_any is Dictionary:
		var rider_any: Variant = (prog_any as Dictionary).get("rider", {})
		if rider_any is Dictionary:
			return (rider_any as Dictionary).duplicate(true)
	return {}

static func milestones_for(level: int) -> int:
	return int(floor(float(max(1, level)) / 5.0))

static func scalar_for_level(level: int, per_level_pct: float) -> float:
	var L: int = max(1, level)
	return 1.0 + float(L - 1) * (per_level_pct * 0.01)

static func raw_flat(base_power: int, level: int, per_level_pct: float, WIS: int, wis_coeff: float = WIS_COEFF) -> int:
	var flat: float = float(max(0, base_power)) * scalar_for_level(level, per_level_pct)
	var wis_term: float = float(max(0, WIS)) * wis_coeff
	return int(round(flat + wis_term))

## Convenience: compute raw from an ability id via the catalog
static func compute_raw(ability_id: String, level: int, WIS: int, base_power_override: int = -1, per_level_pct_override: float = -1.0, wis_coeff: float = WIS_COEFF) -> int:
	var row: Dictionary = AbilityCatalogService.get_by_id(ability_id)
	var bp: int = (base_power_override if base_power_override >= 0 else int(row.get("base_power", 0)))
	var per: float = (per_level_pct_override if per_level_pct_override >= 0.0 else per_level_heal_pct_from_row(row))
	return raw_flat(bp, level, per, WIS, wis_coeff)

## Apply the raw heal; optionally compute overheal->shield rider.
## Returns: { raw, healed, overheal, shield, shield_duration }
static func apply_to_target(raw: int, target_hp: int, target_hp_max: int, level: int, rider: Dictionary = {}) -> Dictionary:
	var hp: int = max(0, target_hp)
	var hpM: int = max(0, target_hp_max)
	var missing: int = max(0, hpM - hp)

	var healed: int = clampi(raw, 0, missing)
	var overheal: int = max(0, raw - missing)

	var shield: int = 0
	var shield_duration: int = 0

	if not rider.is_empty():
		var rtype: String = String(rider.get("type", ""))
		if rtype == "OVERHEAL_TO_SHIELD_PCT" and overheal > 0:
			var base_pct: float = float(rider.get("base_pct", 0.0))
			var step_pct: float = float(rider.get("per_milestone_pct", 0.0))
			var base_dur: int = int(rider.get("duration_turns", 0))
			var step_every: int = int(rider.get("duration_turns_step_every", 9999))
			var ms: int = milestones_for(level)
			var pct: float = base_pct + step_pct * float(ms)
			shield = int(round(float(overheal) * (pct * 0.01)))
			shield_duration = base_dur
			if step_every > 0 and ms > 0:
				shield_duration += int(ms / step_every)

	return {
		"raw": raw,
		"healed": healed,
		"overheal": overheal,
		"shield": shield,
		"shield_duration": shield_duration
	}

## One-shot helper that does: catalog -> raw -> apply -> rider
## Returns: { raw, healed, overheal, shield, shield_duration, base_power, per_level_pct }
static func compute_full_from_id(ability_id: String, level: int, WIS: int, target_hp: int, target_hp_max: int) -> Dictionary:
	var row: Dictionary = AbilityCatalogService.get_by_id(ability_id)
	var bp: int = int(row.get("base_power", 0))
	var per: float = per_level_heal_pct_from_row(row)
	var raw: int = raw_flat(bp, level, per, WIS, WIS_COEFF)
	var rider: Dictionary = rider_from_row(row)
	var out: Dictionary = apply_to_target(raw, target_hp, target_hp_max, level, rider)
	out["base_power"] = bp
	out["per_level_pct"] = per
	return out

# ---------------------------------------------------------------------------
# Compatibility wrapper for kernels that call HealMath.compute_heal(...)
# Accepts either a row Dictionary or an ability id String and returns HEALED int.
# ---------------------------------------------------------------------------
static func compute_heal(ability_or_row: Variant, ability_level: int, atk_snap: Dictionary, dst_snap: Dictionary, _rng: Variant = null) -> int:
	var row: Dictionary = {}
	if ability_or_row is Dictionary:
		row = ability_or_row
	elif ability_or_row is String:
		row = AbilityCatalogService.get_by_id(String(ability_or_row))
	else:
		row = {}

	var bp: int = int(row.get("base_power", 0))
	var per: float = per_level_heal_pct_from_row(row)
	var WIS: int = _wis_from_snap(atk_snap)
	var hp_pair: Array = _hp_pair_from_snap(dst_snap)
	var hp: int = int(hp_pair[0])
	var hpM: int = int(hp_pair[1])

	var raw: int = raw_flat(bp, ability_level, per, WIS)
	var rider: Dictionary = rider_from_row(row)
	var out: Dictionary = apply_to_target(raw, hp, hpM, ability_level, rider)
	return int(out.get("healed", 0))

# ---- helpers used by compute_heal ---------------------------------------
static func _wis_from_snap(s: Dictionary) -> int:
	# Try common locations/keys for Wisdom
	var direct_keys := ["WIS", "wis", "W", "WISDOM", "wisdom"]
	for k in direct_keys:
		if s.has(k):
			return int(s.get(k, 0))

	var containers := ["stats_total", "derived", "attributes", "attrs", "primary", "primary_attributes"]
	for c in containers:
		if s.has(c) and s[c] is Dictionary:
			var d: Dictionary = s[c]
			for k in direct_keys:
				if d.has(k):
					return int(d.get(k, 0))

	# Player snapshots often carry a "stats_total" and "derived"; WIS tends to be in stats_total.
	if s.has("stats_total") and s["stats_total"] is Dictionary:
		var st := s["stats_total"] as Dictionary
		if st.has("WIS"):
			return int(st["WIS"])

	return 0

static func _hp_pair_from_snap(s: Dictionary) -> Array:
	# Returns [hp, hp_max] from common shapes
	var hp: int = 0
	var hp_max: int = 0

	if s.has("pools") and s["pools"] is Dictionary:
		var p: Dictionary = s["pools"]
		if p.has("hp"): hp = int(p["hp"])
		if p.has("hp_max"): hp_max = int(p["hp_max"])

	if hp_max == 0 and s.has("hp_max"): hp_max = int(s["hp_max"])
	if hp == 0 and s.has("hp"): hp = int(s["hp"])

	return [hp, hp_max]
