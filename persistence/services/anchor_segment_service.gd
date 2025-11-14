extends RefCounted
class_name AnchorSegmentService
## World anchors & segments living in META JSON.
## - Anchors: Array[int] of *floor numbers* (e.g., [1, 4, 7] if 3 floors/segment)
## - Segments: Array[{ segment_id:int, drained:bool, boss_sigil:bool }]
## - Floors per segment is configurable here.

const _S    := preload("res://persistence/util/save_utils.gd")
const _Meta := preload("res://persistence/schemas/meta_schema.gd")

const DEFAULT_SLOT: int = 1
const FLOORS_PER_SEGMENT: int = 3

# -------------------------------------------------
# Segment math
# -------------------------------------------------
static func segment_id_for_floor(floor: int) -> int:
	return (max(1, floor) - 1) / FLOORS_PER_SEGMENT + 1

static func segment_start_floor(seg_id: int) -> int:
	return (max(1, seg_id) - 1) * FLOORS_PER_SEGMENT + 1

static func segment_end_floor(seg_id: int) -> int:
	return segment_start_floor(seg_id) + FLOORS_PER_SEGMENT - 1

static func current_segment_id(slot: int = DEFAULT_SLOT) -> int:
	var gs: Dictionary = SaveManager.load_game(slot)
	var floor: int = int(_S.dget(gs, "current_floor", 1))
	return segment_id_for_floor(floor)

# -------------------------------------------------
# Anchors
# -------------------------------------------------
static func list_anchors(slot: int = DEFAULT_SLOT) -> Array:
	var gs: Dictionary = SaveManager.load_game(slot)
	var anchors_any: Variant = _S.dget(gs, "anchors_unlocked", [1])
	var anchors: Array = []
	if anchors_any is PackedInt32Array:
		for v in (anchors_any as PackedInt32Array):
			anchors.append(int(v))
	elif anchors_any is Array:
		for v in (anchors_any as Array):
			anchors.append(int(v))
	else:
		anchors = [1]
	gs["anchors_unlocked"] = anchors
	SaveManager.save_game(gs, slot)
	return anchors.duplicate()

static func is_anchor_unlocked(floor_anchor: int, slot: int = DEFAULT_SLOT) -> bool:
	var a: Array = list_anchors(slot)
	for v in a:
		if int(v) == floor_anchor:
			return true
	return false

static func unlock_anchor(floor_anchor: int, slot: int = DEFAULT_SLOT) -> void:
	var anchor: int = max(1, floor_anchor)
	var gs: Dictionary = SaveManager.load_game(slot)
	var a: Array = list_anchors(slot) # already normalized in META
	var found: bool = false
	for v in a:
		if int(v) == anchor:
			found = true
			break
	if not found:
		a.append(anchor)
		a.sort()
		gs["anchors_unlocked"] = a
		SaveManager.save_game(gs, slot)

static func highest_unlocked_anchor(slot: int = DEFAULT_SLOT) -> int:
	var a: Array = list_anchors(slot)
	if a.is_empty():
		return 1
	var maxv: int = 1
	for v in a:
		maxv = max(maxv, int(v))
	return maxv

static func nearest_anchor_at_or_below(floor: int, slot: int = DEFAULT_SLOT) -> int:
	var a: Array = list_anchors(slot)
	var best: int = 1
	var f: int = max(1, floor)
	for v in a:
		var iv: int = int(v)
		if iv <= f and iv > best:
			best = iv
	return best

# Convenience: unlock the anchor that starts the segment of a floor
static func unlock_anchor_for_floor(floor: int, slot: int = DEFAULT_SLOT) -> int:
	var seg: int = segment_id_for_floor(floor)
	var start_floor: int = segment_start_floor(seg)
	unlock_anchor(start_floor, slot)
	return start_floor

# -------------------------------------------------
# Segments (META.world_segments[])
# -------------------------------------------------
static func list_segments(slot: int = DEFAULT_SLOT) -> Array:
	var gs: Dictionary = SaveManager.load_game(slot)
	var arr_any: Variant = _S.dget(gs, "world_segments", [])
	var arr: Array = (arr_any as Array) if arr_any is Array else []
	# Normalize entries
	var out: Array = []
	for e_any in arr:
		if e_any is Dictionary:
			var e: Dictionary = e_any
			out.append({
				"segment_id": int(_S.dget(e, "segment_id", 1)),
				"drained": bool(_S.dget(e, "drained", false)),
				"boss_sigil": bool(_S.dget(e, "boss_sigil", false)),
			})
	if out.is_empty():
		out = [{"segment_id": 1, "drained": false, "boss_sigil": false}]
	gs["world_segments"] = out
	SaveManager.save_game(gs, slot)
	return out.duplicate(true)

static func get_segment(seg_id: int, slot: int = DEFAULT_SLOT) -> Dictionary:
	var idv: int = max(1, seg_id)
	var segs: Array = list_segments(slot)
	for e_any in segs:
		if e_any is Dictionary:
			var e: Dictionary = e_any
			if int(_S.dget(e, "segment_id", 0)) == idv:
				return e.duplicate(true)
	# not found -> create
	var gs: Dictionary = SaveManager.load_game(slot)
	segs.append({"segment_id": idv, "drained": false, "boss_sigil": false})
	gs["world_segments"] = segs
	SaveManager.save_game(gs, slot)
	return {"segment_id": idv, "drained": false, "boss_sigil": false}

static func set_segment(seg: Dictionary, slot: int = DEFAULT_SLOT) -> void:
	var segs: Array = list_segments(slot)
	var idv: int = int(_S.dget(seg, "segment_id", 1))
	var new_e: Dictionary = {
		"segment_id": idv,
		"drained": bool(_S.dget(seg, "drained", false)),
		"boss_sigil": bool(_S.dget(seg, "boss_sigil", false)),
	}
	var found: bool = false
	for i in range(segs.size()):
		if segs[i] is Dictionary and int(_S.dget(segs[i], "segment_id", -1)) == idv:
			segs[i] = new_e
			found = true
			break
	if not found:
		segs.append(new_e)
	var gs: Dictionary = SaveManager.load_game(slot)
	gs["world_segments"] = segs
	SaveManager.save_game(gs, slot)

static func ensure_segment_for_floor(floor: int, slot: int = DEFAULT_SLOT) -> Dictionary:
	return get_segment(segment_id_for_floor(floor), slot)

static func mark_segment_drained_by_floor(floor: int, slot: int = DEFAULT_SLOT) -> void:
	var idv: int = segment_id_for_floor(floor)
	var e: Dictionary = get_segment(idv, slot)
	e["drained"] = true
	set_segment(e, slot)

static func is_segment_drained_by_floor(floor: int, slot: int = DEFAULT_SLOT) -> bool:
	var idv: int = segment_id_for_floor(floor)
	return bool(_S.dget(get_segment(idv, slot), "drained", false))

static func set_boss_sigil_by_floor(floor: int, value: bool, slot: int = DEFAULT_SLOT) -> void:
	var idv: int = segment_id_for_floor(floor)
	var e: Dictionary = get_segment(idv, slot)
	e["boss_sigil"] = value
	set_segment(e, slot)

static func has_boss_sigil_by_floor(floor: int, slot: int = DEFAULT_SLOT) -> bool:
	var idv: int = segment_id_for_floor(floor)
	return bool(_S.dget(get_segment(idv, slot), "boss_sigil", false))
