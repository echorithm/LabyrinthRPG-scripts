extends RefCounted
class_name TeleportService

const _S    := preload("res://persistence/util/save_utils.gd")
const _Meta := preload("res://persistence/schemas/meta_schema.gd")

const DEFAULT_SLOT: int = 1

static func list_unlocked(slot: int = DEFAULT_SLOT) -> Array[int]:
	# Returns the floors you can teleport TO: 1 and every 4,7,10,... up to highest_teleport_floor.
	var gs: Dictionary = SaveManager.load_game(slot)
	var max_t: int = max(1, int(_S.dget(gs, "highest_teleport_floor", 1)))
	var out: Array[int] = [1]
	var f: int = 4
	while f <= max_t:
		out.append(f)
		f += 3
	return out

static func can_teleport_to(target_floor: int, slot: int = DEFAULT_SLOT) -> bool:
	var options: Array[int] = list_unlocked(slot)
	return options.has(max(1, target_floor))

static func teleport_to(target_floor: int, slot: int = DEFAULT_SLOT) -> bool:
	# Jump to a teleport floor; floors below become drained (handled via furthest_depth_reached).
	if not can_teleport_to(target_floor, slot):
		return false

	# Ensure furthest_depth_reached >= target so lower floors are drained
	var rs: Dictionary = SaveManager.load_run(slot)
	var cur_depth: int = int(_S.dget(rs, "depth", 1))
	var cur_furthest: int = int(_S.dget(rs, "furthest_depth_reached", cur_depth))
	if target_floor > cur_furthest:
		rs["furthest_depth_reached"] = target_floor
		SaveManager.save_run(rs, slot)

	# Move the run to the target floor (also maintains furthest if needed)
	SaveManager.set_run_floor(target_floor, slot)

	# Keep Sigil segment counters consistent for triad/sigils:
	var SigilMath := preload("res://persistence/services/sigil_math.gd")
	var required: int = SigilMath.required_for_floor(target_floor)
	SigilService.ensure_segment_for_floor(target_floor, required, slot)

	# (Optional, but useful) Mark all earlier triads drained in META for visibility/telemetry.
	# This does not affect behavior if you rely on furthest_depth_reached, but matches your intent.
	var target_seg: int = AnchorSegmentService.segment_id_for_floor(target_floor)
	for seg_id in range(1, target_seg):
		var seg_start_floor: int = AnchorSegmentService.segment_start_floor(seg_id)
		AnchorSegmentService.mark_segment_drained_by_floor(seg_start_floor, slot)

	return true
