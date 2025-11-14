# res://scripts/combat/data/ActorSnapshot.gd
extends RefCounted
class_name ActorSnapshot

# Immutable-ish view of a combatant at a point in time, built from a runtime.

var id: int
var team: String

var stats_total: Dictionary
var derived: Dictionary
var resist_pct: Dictionary
var armor_flat: Dictionary
var pools: Dictionary
var caps: Dictionary
var abilities: Dictionary
var statuses: Array[Dictionary]
var tags: PackedStringArray
var cooldowns: Dictionary
var charges: Dictionary
var helpers: Dictionary

# NEW: mods package (offense/defense deltas already combined)
var mods: Dictionary = {}

static func from_runtime(rt_any: Resource) -> ActorSnapshot:
	var snap_dict: Dictionary = {}
	if rt_any != null and rt_any.has_method("to_actor_snapshot"):
		snap_dict = rt_any.call("to_actor_snapshot")

	var a := ActorSnapshot.new()
	a.id = int(snap_dict.get("id", 0))
	a.team = String(snap_dict.get("team", "neutral"))

	a.stats_total = (snap_dict.get("stats_total", {}) as Dictionary).duplicate(true)
	a.derived     = (snap_dict.get("derived", {}) as Dictionary).duplicate(true)
	a.resist_pct  = (snap_dict.get("resist_pct", {}) as Dictionary).duplicate(true)
	a.armor_flat  = (snap_dict.get("armor_flat", {}) as Dictionary).duplicate(true)
	a.pools       = (snap_dict.get("pools", {}) as Dictionary).duplicate(true)
	a.caps        = (snap_dict.get("caps", {}) as Dictionary).duplicate(true)
	a.abilities   = (snap_dict.get("abilities", {}) as Dictionary).duplicate(true)
	a.statuses    = ((snap_dict.get("statuses", []) as Array).duplicate(true)) as Array[Dictionary]
	a.tags        = PackedStringArray(snap_dict.get("tags", PackedStringArray()))
	a.cooldowns   = (snap_dict.get("cooldowns", {}) as Dictionary).duplicate(true)
	a.charges     = (snap_dict.get("charges", {}) as Dictionary).duplicate(true)
	a.helpers     = (snap_dict.get("helpers", {}) as Dictionary).duplicate(true)

	# NEW: carry mods dictionary through to the kernel
	var mods_any: Variant = snap_dict.get("mods", {})
	if mods_any is Dictionary:
		a.mods = (mods_any as Dictionary).duplicate(true)
	else:
		a.mods = {}

	return a

func to_dict() -> Dictionary:
	return {
		"id": id,
		"team": team,
		"stats_total": stats_total,
		"derived": derived,
		"resist_pct": resist_pct,
		"armor_flat": armor_flat,
		"pools": pools,
		"caps": caps,
		"abilities": abilities,
		"statuses": statuses,
		"tags": tags,
		"cooldowns": cooldowns,
		"charges": charges,
		"helpers": helpers,
		"mods": mods            # NEW
	}
