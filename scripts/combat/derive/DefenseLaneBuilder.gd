# Godot 4.5
extends RefCounted
class_name DefenseLaneBuilder
## Builds normalized, clamped defense lanes (10-lane resist in percent points, 4-lane flat armor)
## from RUN data (mods_village, mods_affix, equipment). Pure functions; no side effects.
##
## Notes:
## - Lane keys are canonicalized as "L0"…"L9" and "A0"…"A3".
## - Global clamp: resist in [-90.0, +95.0] percent points; player soft top +80.0 (doc policy).
## - Armor lanes use integers, no negative clamp (but never below 0 after sum).

# Use array literals so they are valid constant expressions.
const LANES_10 := ["L0","L1","L2","L3","L4","L5","L6","L7","L8","L9"]
const ARMOR_4  := ["A0","A1","A2","A3"]

const RESIST_MIN_PP: float = -90.0
const RESIST_MAX_PP: float = +95.0
const PLAYER_TOP_PP: float = +80.0  # player friendliness soft cap

static func empty_resist() -> Dictionary:
	var d: Dictionary = {}
	for k in LANES_10:
		d[k] = 0.0
	return d

static func empty_armor() -> Dictionary:
	var d: Dictionary = {}
	for k in ARMOR_4:
		d[k] = 0
	return d

static func _clamp_resist_pp_player(v: float) -> float:
	return clampf(v, RESIST_MIN_PP, min(RESIST_MAX_PP, PLAYER_TOP_PP))

static func _clamp_resist_pp_monster(v: float) -> float:
	return clampf(v, RESIST_MIN_PP, RESIST_MAX_PP)

static func _sum_into_float(d: Dictionary, key: String, v: float) -> void:
	d[key] = float(d.get(key, 0.0)) + v

static func _sum_into_int(d: Dictionary, key: String, v: int) -> void:
	d[key] = int(d.get(key, 0)) + v

## Build player defense lanes from a RUN snapshot.
## Inputs:
##   rs: Dictionary = SaveManager.load_run(slot)
## Returns:
##   { "resist_pct": Dictionary(L0..L9 -> float_pp), "armor_flat": Dictionary(A0..A3 -> int), "tags": PackedStringArray }
##
## Mapping policy (version 1):
## - If you only have generic "% element resist" without per-element mapping yet, we distribute as a global pp bonus.
## - When you introduce a concrete lane taxonomy (e.g., Fire->L3), wire it here without touching runtimes/kernel.
static func build_for_player(rs: Dictionary) -> Dictionary:
	var resist: Dictionary = empty_resist()
	var armor: Dictionary = empty_armor()
	var tags: PackedStringArray = PackedStringArray()

	# Aggregated numeric mods written by BuffService
	var mods_village: Dictionary = (rs.get("mods_village", {}) as Dictionary)
	var mods_affix:   Dictionary = (rs.get("mods_affix", {}) as Dictionary)
	var weapon_tags_rs: Array = (rs.get("weapon_tags", []) as Array)

	# Merge tags
	for t_any in weapon_tags_rs:
		tags.append(String(t_any))

	# Global element resist bonus (percent points, not multiplier)
	var generic_elem_pp: float = float(mods_village.get("element_resist_pct", 0.0)) + float(mods_affix.get("element_resist_pct", 0.0))
	if absf(generic_elem_pp) > 0.0001:
		for k in LANES_10:
			_sum_into_float(resist, k, generic_elem_pp)

	# Generic flat armor from mods (temporary policy: spread evenly)
	var def_flat: float = float(mods_village.get("def_flat", 0.0)) + float(mods_affix.get("def_flat", 0.0))
	if absf(def_flat) > 0.0001:
		var per_lane: int = int(round(def_flat / float(ARMOR_4.size())))
		for a in ARMOR_4:
			_sum_into_int(armor, a, per_lane)

	# Clamp
	for k in LANES_10:
		resist[k] = _clamp_resist_pp_player(float(resist[k]))
	for a in ARMOR_4:
		armor[a] = max(0, int(armor[a]))

	return {
		"resist_pct": resist,
		"armor_flat": armor,
		"tags": tags
	}

## Build monster lanes from a MonsterCatalog snapshot (already normalized); simply clamp.
static func build_for_monster(stats_block: Dictionary) -> Dictionary:
	var resist_in: Dictionary = (stats_block.get("resist_pct", {}) as Dictionary)
	var armor_in:  Dictionary = (stats_block.get("armor_flat", {}) as Dictionary)

	var resist: Dictionary = empty_resist()
	var armor: Dictionary = empty_armor()

	for k in LANES_10:
		resist[k] = _clamp_resist_pp_monster(float(resist_in.get(k, 0.0)))
	for a in ARMOR_4:
		armor[a] = max(0, int(armor_in.get(a, 0)))

	return { "resist_pct": resist, "armor_flat": armor }
