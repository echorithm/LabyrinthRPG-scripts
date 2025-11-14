# res://scripts/dungeon/autoload/AnchorRegistry.gd
extends Node

## Autoload: per-floor anchor cache + spawn-exclusion & step-indexed cooldown helpers.
## Deterministic, no timers, no RNG. Compatible with ADR-001 single ingress/egress, and
## uses the dungeon step index as the stable time unit for grace windows.

@export var debug_logs: bool = false

# Default spawn exclusion dimensions (can be overridden by call sites)
@export var no_spawn_radius_m: float = 1.4
@export var no_spawn_height_m: float = 2.0

# Quantization (meters) used to build stable keys from world positions
@export var cooldown_quantize_m: float = 0.25

# --- Storage: floor -> Array[Transform3D]
var _elite_by_floor: Dictionary = {}          # Dictionary[int, Array[Transform3D]]
var _treasure_by_floor: Dictionary = {}       # Dictionary[int, Array[Transform3D]]

# Elite re-aggro grace tracking: key -> until_step (inclusive bound)
# Key format: "F<floor>@<qx>,<qy>,<qz>"
var _cooldown_until_step: Dictionary = {}     # Dictionary[String, int]

# ------------------------------------------------------------------------------
# Floor registration (API)
# ------------------------------------------------------------------------------

func set_floor_anchors(floor: int, elites: Array[Transform3D], treasures: Array[Transform3D]) -> void:
	# Avoid Array.duplicate() because it erases the generic element type.
	var elites_copy: Array[Transform3D] = []
	elites_copy.append_array(elites)
	var treasures_copy: Array[Transform3D] = []
	treasures_copy.append_array(treasures)

	_elite_by_floor[floor] = elites_copy
	_treasure_by_floor[floor] = treasures_copy

	if debug_logs:
		print("[AnchorRegistry] set_floor_anchors floor=", floor,
			" elites=", elites_copy.size(), " treasures=", treasures_copy.size())

func get_elite_anchors(floor: int) -> Array[Transform3D]:
	return _as_t3_array(_elite_by_floor.get(floor))

func get_treasure_anchors(floor: int) -> Array[Transform3D]:
	return _as_t3_array(_treasure_by_floor.get(floor))

func clear_floor(floor: int) -> void:
	_elite_by_floor.erase(floor)
	_treasure_by_floor.erase(floor)
	# Drop any cooldown keys for this floor
	var prefix := "F%d@" % floor
	var to_erase: Array[String] = []
	for k in _cooldown_until_step.keys():
		var ks: String = String(k)
		if ks.begins_with(prefix):
			to_erase.append(ks)
	for ks2 in to_erase:
		_cooldown_until_step.erase(ks2)
	if debug_logs:
		print("[AnchorRegistry] clear_floor floor=", floor, " cleared_keys=", to_erase.size())

# Optional utility
func clear_all() -> void:
	_elite_by_floor.clear()
	_treasure_by_floor.clear()
	_cooldown_until_step.clear()
	if debug_logs:
		print("[AnchorRegistry] clear_all")

# ------------------------------------------------------------------------------
# Spawn exclusion helpers (no-go zones around elite/treasure anchors)
# ------------------------------------------------------------------------------

## Build zone descriptors for fast UI/debug or custom checks.
## Each zone: { center: Vector3, radius: float, height: float, kind: String }
func no_spawn_zones_for_floor(
		floor: int,
		extra_radius_m: float = 0.0,
		radius_override_m: float = -1.0,
		height_override_m: float = -1.0
	) -> Array[Dictionary]:
	var zones: Array[Dictionary] = []
	var r: float = (radius_override_m if radius_override_m > 0.0 else no_spawn_radius_m) + max(0.0, extra_radius_m)
	var h: float = (height_override_m if height_override_m > 0.0 else no_spawn_height_m)

	for t in get_elite_anchors(floor):
		zones.append({ "center": t.origin, "radius": r, "height": h, "kind": "elite" })
	for t2 in get_treasure_anchors(floor):
		zones.append({ "center": t2.origin, "radius": r, "height": h, "kind": "treasure" })
	return zones

## 2D (XZ) check used by BattleLoader’s candidate placement: true if point p is inside any zone.
func is_point_in_no_spawn(floor: int, p: Vector3, extra_radius_m: float = 0.0) -> bool:
	var zones := no_spawn_zones_for_floor(floor, extra_radius_m)
	for z in zones:
		var c: Vector3 = z["center"]
		var r: float = float(z["radius"])
		if _planar_distance_sq(c, p) <= r * r:
			return true
	return false

# ------------------------------------------------------------------------------
# Cooldown (re-aggro grace) — step-indexed & deterministic
# ------------------------------------------------------------------------------

## Stable key from floor + (quantized) world position
func anchor_key_for_pos(floor: int, pos: Vector3) -> String:
	var q: float = max(0.01, cooldown_quantize_m)
	var qx: float = round(pos.x / q) * q
	var qy: float = round(pos.y / q) * q
	var qz: float = round(pos.z / q) * q
	return "F%d@%.2f,%.2f,%.2f" % [floor, qx, qy, qz]

func anchor_key_for_transform(floor: int, xform: Transform3D) -> String:
	return anchor_key_for_pos(floor, xform.origin)

## Returns nearest anchor key of requested kind within max_m. kind: "", "elite", or "treasure".
func nearest_anchor_key_by_kind(floor: int, pos: Vector3, kind: String = "", max_m: float = 3.0) -> String:
	var best_key := ""
	var best_d2 := INF
	if kind == "" or kind == "elite":
		var k := _nearest_key_scan(pos, get_elite_anchors(floor), floor, max_m, best_d2)
		best_key = k.key
		best_d2 = k.d2
	if kind == "" or kind == "treasure":
		var k2 := _nearest_key_scan(pos, get_treasure_anchors(floor), floor, max_m, best_d2)
		if k2.key != "":
			best_key = k2.key
			best_d2 = k2.d2
	return best_key

## Set absolute 'until_step' for a given key (inclusive bound).
func set_cooldown_until_step(key: String, step_index: int) -> void:
	if key == "":
		return
	_cooldown_until_step[key] = max(0, step_index)
	if debug_logs:
		print("[AnchorRegistry] cooldown set key=", key, " until_step=", step_index)

## Convenience: stamp grace on the nearest anchor to 'pos'. Returns the key ("" if none).
func grant_grace_for_nearest(floor: int, pos: Vector3, current_step: int, grace_steps: int, max_m: float = 3.0) -> String:
	var key := nearest_anchor_key_by_kind(floor, pos, "", max_m)
	if key != "":
		set_cooldown_until_step(key, current_step + max(0, grace_steps))
	return key

func is_under_cooldown(key: String, current_step: int) -> bool:
	var until: int = int(_cooldown_until_step.get(key, -1))
	return current_step < until

func cooldown_left(key: String, current_step: int) -> int:
	var until: int = int(_cooldown_until_step.get(key, -1))
	return max(0, until - current_step)

# ------------------------------------------------------------------------------
# Internal helpers (no nested funcs/lambdas)
# ------------------------------------------------------------------------------

# Variant -> Array[Transform3D] (safe coercion)
static func _as_t3_array(v: Variant) -> Array[Transform3D]:
	var out: Array[Transform3D] = []
	if v is Array:
		var arr: Array = v
		for it in arr:
			if it is Transform3D:
				out.append(it as Transform3D)
	return out

# Returns a small struct-like Dictionary {key:String, d2:float}
func _nearest_key_scan(pos: Vector3, list: Array[Transform3D], floor: int, max_m: float, current_best_d2: float) -> Dictionary:
	var best_key := ""
	var best_d2 := current_best_d2
	var max_d2: float = max_m * max_m
	for t in list:
		var c: Vector3 = t.origin
		var d2: float = _planar_distance_sq(c, pos)
		if d2 < best_d2 and d2 <= max_d2:
			best_d2 = d2
			best_key = anchor_key_for_pos(floor, c)
	return { "key": best_key, "d2": best_d2 }

static func _planar_distance_sq(a: Vector3, b: Vector3) -> float:
	var dx: float = a.x - b.x
	var dz: float = a.z - b.z
	return dx * dx + dz * dz
