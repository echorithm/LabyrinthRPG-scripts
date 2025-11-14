extends Node
class_name NPCRecruitmentService
## Owns recruitment page math, deterministic seeding, timed/manual restock.

const SaveManager      := preload("res://persistence/SaveManager.gd")
const VillageSaveUtils := preload("res://scripts/village/persistence/village_save_utils.gd")
const NPCGen           := preload("res://scripts/village/persistence/npc_generator.gd")
const NPCSchema        := preload("res://scripts/village/persistence/schemas/npc_instance_schema.gd")
const NPCConfig        := preload("res://scripts/village/services/NPCConfig.gd")

var DEBUG: bool = true
func _dbg(msg: String) -> void:
	if DEBUG:
		print("[NPCRecruit] " + msg)


func _resolve_slot(slot_hint: int) -> int:
	var active: int = SaveManager.active_slot()
	if active <= 0:
		active = 1
	# Only trust the hint if it matches the active slot; otherwise ignore it.
	if slot_hint > 0 and slot_hint == active:
		return slot_hint
	return active


# ---------------- Public API ----------------

func get_page(slot: int = 0) -> Array[Dictionary]:
	var use_slot: int = _resolve_slot(slot)

	var rec: Dictionary = _get_recruitment(use_slot)
	var page_size: int = max(1, int(rec.get("page_size", NPCConfig.DEFAULT_PAGE_SIZE)))
	var cursor: int = max(0, int(rec.get("cursor", 0)))
	var seed_base: int = _seed_for_slot(use_slot)

	var offset: int = cursor % page_size
	var page_index: int = cursor - offset
	var page_seed: int = int(((seed_base ^ 0x9E3779B9) + page_index * 2654435761) & 0x7FFFFFFF)
	var gen_total: int = page_size + (page_size - 1)

	_dbg("get_page size=%d cursor=%d offset=%d page_index=%d seed=%d gen_total=%d slot=%d"
		% [page_size, cursor, offset, page_index, page_seed, gen_total, use_slot])

	var rows_all: Array[Dictionary] = NPCGen.generate_hire_page_from_file(
		NPCConfig.RECRUITMENT_NAMES_PATH,
		gen_total,
		page_seed
	)

	var out: Array[Dictionary] = [] as Array[Dictionary]
	var start_i: int = clampi(offset, 0, max(0, rows_all.size() - page_size))
	var end_i: int = min(rows_all.size(), start_i + page_size)

	for i in range(start_i, end_i):
		var norm: Dictionary = NPCSchema.validate(rows_all[i])
		out.append(norm)

	_dbg("get_page -> rows_all=%d window=[%d..%d) returned=%d slot=%d"
		% [rows_all.size(), start_i, end_i, out.size(), use_slot])

	return out


func apply_timed_restock(slot: int = 0) -> Dictionary:
	var use_slot: int = _resolve_slot(slot)

	var meta: Dictionary = SaveManager.load_game(use_slot)
	var now_min: float = float(meta.get("time_passed_min", 0.0))

	var rec: Dictionary = _get_recruitment(use_slot)
	var cadence: int = int(rec.get("recruit_cadence_min", NPCConfig.DEFAULT_CADENCE_MIN))
	if cadence <= 0:
		cadence = NPCConfig.DEFAULT_CADENCE_MIN

	var ref: float = float(rec.get("recruit_last_min_ref", now_min))
	var delta: float = max(0.0, now_min - ref)
	var ticks: int = int(floor(delta / float(cadence)))

	var page_size: int = int(rec.get("page_size", NPCConfig.DEFAULT_PAGE_SIZE))
	var cursor_before: int = int(rec.get("cursor", 0))

	if ticks > 0:
		rec["cursor"] = cursor_before + (ticks * page_size)
		rec["recruit_last_min_ref"] = ref + float(ticks * cadence)
		_set_recruitment(rec, use_slot)
		_dbg("timed_restock: ticks=%d cursor %d -> %d delta=%.2f ref=%.2f now=%.2f cadence=%d slot=%d"
			% [ticks, cursor_before, int(rec["cursor"]), delta, ref, now_min, cadence, use_slot])
	else:
		if not rec.has("recruit_last_min_ref"):
			rec["recruit_last_min_ref"] = ref
			_set_recruitment(rec, use_slot)
		_dbg("timed_restock: ticks=0 cursor=%d delta=%.2f ref=%.2f now=%.2f cadence=%d slot=%d"
			% [cursor_before, delta, ref, now_min, cadence, use_slot])

	var used: float = float(ticks * cadence)
	var remainder: float = max(0.0, delta - used)
	var remain_min: float = max(0.0, float(cadence) - remainder)

	return {
		"ticks": ticks,
		"remain_min": remain_min,
		"cadence_min": cadence,
		"cursor": int(rec.get("cursor", cursor_before)),
		"page_size": page_size
	}


func refresh(slot: int = 0) -> void:
	var use_slot: int = _resolve_slot(slot)

	var rec: Dictionary = _get_recruitment(use_slot)
	var page_size: int = int(rec.get("page_size", NPCConfig.DEFAULT_PAGE_SIZE))
	var before: int = int(rec.get("cursor", 0))
	rec["cursor"] = before + page_size
	_set_recruitment(rec, use_slot)
	_dbg("refresh: cursor %d -> %d (page_size=%d) slot=%d"
		% [before, int(rec["cursor"]), page_size, use_slot])


func get_config(slot: int = 0) -> Dictionary:
	var use_slot: int = _resolve_slot(slot)
	var rec: Dictionary = _get_recruitment(use_slot)
	return {
		"cursor": int(rec.get("cursor", 0)),
		"page_size": int(rec.get("page_size", NPCConfig.DEFAULT_PAGE_SIZE)),
		"recruit_last_min_ref": float(rec.get("recruit_last_min_ref", 0.0)),
		"recruit_cadence_min": int(rec.get("recruit_cadence_min", NPCConfig.DEFAULT_CADENCE_MIN))
	}


# ---------------- Internals ----------------

func _seed_for_slot(slot: int) -> int:
	var v: Dictionary = VillageSaveUtils.load_village(slot)
	var seed: int = int(v.get("seed", 1))
	return 1 if seed == 0 else seed


func _get_recruitment(slot: int) -> Dictionary:
	var v: Dictionary = VillageSaveUtils.load_village(slot)
	var any: Variant = v.get("recruitment", {})
	var rec: Dictionary = (any as Dictionary) if (any is Dictionary) else {}
	return {
		"cursor": int(rec.get("cursor", 0)),
		"page_size": int(rec.get("page_size", NPCConfig.DEFAULT_PAGE_SIZE)),
		"recruit_last_min_ref": float(rec.get("recruit_last_min_ref", 0.0)),
		"recruit_cadence_min": int(rec.get("recruit_cadence_min", NPCConfig.DEFAULT_CADENCE_MIN))
	}


func _set_recruitment(rec_in: Dictionary, slot: int) -> void:
	var v: Dictionary = VillageSaveUtils.load_village(slot)
	var cur_any: Variant = v.get("recruitment", {})
	var cur: Dictionary = (cur_any as Dictionary) if (cur_any is Dictionary) else {
		"cursor": 0,
		"page_size": NPCConfig.DEFAULT_PAGE_SIZE,
		"recruit_last_min_ref": 0.0,
		"recruit_cadence_min": NPCConfig.DEFAULT_CADENCE_MIN
	}

	var merged: Dictionary = {
		"cursor": int(rec_in.get("cursor", int(cur.get("cursor", 0)))),
		"page_size": int(rec_in.get("page_size", int(cur.get("page_size", NPCConfig.DEFAULT_PAGE_SIZE)))),
		"recruit_last_min_ref": float(rec_in.get("recruit_last_min_ref", float(cur.get("recruit_last_min_ref", 0.0)))),
		"recruit_cadence_min": int(rec_in.get("recruit_cadence_min", int(cur.get("recruit_cadence_min", NPCConfig.DEFAULT_CADENCE_MIN))))
	}

	v["recruitment"] = merged
	VillageSaveUtils.save_village(v, slot)
	_dbg("set_recruitment: cursor=%d size=%d last=%.2f cad=%d slot=%d"
		% [int(merged["cursor"]), int(merged["page_size"]),
		   float(merged["recruit_last_min_ref"]),
		   int(merged["recruit_cadence_min"]), slot])
