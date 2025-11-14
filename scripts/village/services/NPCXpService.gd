# Godot 4.5 — Deterministic, assignment-anchored trickle XP (same rate for all roles)
extends RefCounted
class_name NPCXpService

const _DBG := "[NPCXp] "
static var DEBUG := false
static func _log(msg: String) -> void:
	if DEBUG: print(_DBG + msg)

# --- deps --------------------------------------------------------------------
const SaveManager := preload("res://persistence/SaveManager.gd")
const XpTuning    := preload("res://scripts/rewards/XpTuning.gd")
const ProgressionService := preload("res://persistence/services/progression_service.gd")

# --- config ------------------------------------------------------------------
## Global trickle rate, identical for all roles/buildings (XP per minute).
static var XP_PER_MINUTE: float = 1.0

## Optional external curve provider; VillageService sets this on _ready().
static var _xp_curve: Callable = Callable()

static func set_xp_curve_provider(p: Callable) -> void:
	_xp_curve = p
	_log("set_xp_curve_provider: valid=%s" % str(p.is_valid()))

static func _xp_to_next(level: int) -> int:
	if _xp_curve.is_valid():
		return int(_xp_curve.call(level))
	# Difficulty-aware fallback:
	return int(ProgressionService.xp_to_next(level))

# --- public API --------------------------------------------------------------

## Ensure a role track exists and is a Dictionary (not an int). Safe for legacy saves.
static func ensure_role_track(npc_id: StringName, role: String, slot: int = 0) -> void:
	slot = (slot if slot > 0 else SaveManager.active_slot())
	var snap: Dictionary = SaveManager.load_village(slot)
	var npcs_any: Variant = snap.get("npcs", [])
	var npcs: Array = (npcs_any as Array) if (npcs_any is Array) else []
	var changed := false

	for i in npcs.size():
		var n_any: Variant = npcs[i]
		if not (n_any is Dictionary):
			continue
		var n: Dictionary = n_any
		if String(n.get("id","")) != String(npc_id):
			continue

		var rl_any: Variant = n.get("role_levels", {})
		var rl: Dictionary = (rl_any as Dictionary) if (rl_any is Dictionary) else {}
		var track_any: Variant = rl.get(role, null)

		if track_any == null:
			rl[role] = {
				"level": 1,
				"previous_xp": 0,
				"time_assigned": null,
				"xp_current": 0,
				"xp_to_next": 90,
			}
			n["role_levels"] = rl
			npcs[i] = n
			changed = true
			_log("ensure_role_track: npc=%s role=%s <- created L1" % [String(npc_id), role])

		elif track_any is int:
			var lvl := int(track_any)
			rl[role] = {
				"level": lvl,
				"previous_xp": 0,
				"time_assigned": null,
				"xp_current": 0,
				"xp_to_next": 90,
			}
			n["role_levels"] = rl
			npcs[i] = n
			changed = true
			_log("ensure_role_track: npc=%s role=%s <- upgraded legacy int to dict (L%d)" % [String(npc_id), role, lvl])

		else:
			var tr: Dictionary = track_any
			var patched := false
			if not tr.has("level"): tr["level"] = 1; patched = true
			if not tr.has("previous_xp"): tr["previous_xp"] = 0; patched = true
			if not tr.has("time_assigned"): tr["time_assigned"] = null; patched = true
			if not tr.has("xp_current"): tr["xp_current"] = 0; patched = true
			if not tr.has("xp_to_next"): tr["xp_to_next"] = 90; patched = true
			if patched:
				rl[role] = tr
				n["role_levels"] = rl
				npcs[i] = n
				changed = true
				_log("ensure_role_track: npc=%s role=%s <- patched missing keys" % [String(npc_id), role])

	if changed:
		snap["npcs"] = npcs
		SaveManager.save_village(snap, slot) # (snapshot, slot)
		_log("ensure_role_track: saved slot=%d" % slot)

# Called by Village/TileModalService on (re)assign).
# Also fixes the top-level NPC state/role/instance so UI doesn't stick on IDLE.
static func on_reassign(role: StringName, prev_staff_id: StringName, new_staff_id: StringName, now_min: float, slot: int = 0) -> void:
	slot = (slot if slot > 0 else SaveManager.active_slot())
	if String(prev_staff_id) != "":
		_log("on_reassign: freeze prev npc=%s role=%s now=%.2f" % [String(prev_staff_id), String(role), now_min])
		settle_role(prev_staff_id, role, now_min, slot, true)
	if String(new_staff_id) != "":
		_log("on_reassign: anchor new npc=%s role=%s now=%.2f" % [String(new_staff_id), String(role), now_min])
		anchor_role(new_staff_id, role, now_min, slot)

	_sync_staff_state(String(role), String(prev_staff_id), String(new_staff_id), slot)

## Heartbeat/boot: settle all *assigned* NPCs for level-ups (no write if no level-up).
static func settle_all_assigned(now_min: float, slot: int = 0) -> void:
	slot = (slot if slot > 0 else SaveManager.active_slot())
	var v: Dictionary = SaveManager.load_village(slot)
	var b_any: Variant = v.get("buildings", [])
	var buildings: Array = (b_any as Array) if (b_any is Array) else []
	_log("settle_all_assigned now=%.2f slot=%d buildings=%d" % [now_min, slot, buildings.size()])

	var seen := {}
	for b_any2 in buildings:
		if not (b_any2 is Dictionary):
			continue
		var b: Dictionary = b_any2
		var staff_any: Variant = b.get("staff", {})
		if not (staff_any is Dictionary):
			continue
		var npc_id := String((staff_any as Dictionary).get("npc_id",""))
		if npc_id == "":
			continue
		if seen.has(npc_id):
			continue
		seen[npc_id] = true

		var kind := String(b.get("id", ""))
		var role := _role_for_kind(kind)
		settle_role(StringName(npc_id), StringName(role), now_min, slot, false)

## Snapshot for a single instance (for UI). Derives XP; writes nothing unless asked elsewhere.
static func settle_for_instance(instance_id: StringName, now_min: float, slot: int = 0) -> Dictionary:
	slot = (slot if slot > 0 else SaveManager.active_slot())
	var v: Dictionary = SaveManager.load_village(slot)
	var b_any: Variant = v.get("buildings", [])
	var buildings: Array = (b_any as Array) if (b_any is Array) else []

	for b_any2 in buildings:
		if not (b_any2 is Dictionary):
			continue
		var row: Dictionary = b_any2
		if String(row.get("instance_id","")) != String(instance_id):
			continue
		var staff_any: Variant = row.get("staff", {})
		var npc_id := String((staff_any as Dictionary).get("npc_id","")) if (staff_any is Dictionary) else ""
		if npc_id == "":
			return {}
		var role := _role_for_kind(String(row.get("id","")))
		var snap := _derive_snapshot(StringName(npc_id), StringName(role), now_min, slot)
		snap["role"] = String(role)
		return snap

	return {}

# --- core mechanics ----------------------------------------------------------

## Derive (level, xp, xp_next) for a specific role at 'now_min' without saving.
static func _derive_snapshot(npc_id: StringName, role: StringName, now_min: float, slot: int) -> Dictionary:
	var v: Dictionary = SaveManager.load_village(slot)
	var npcs_any: Variant = v.get("npcs", [])
	var npcs: Array = (npcs_any as Array) if (npcs_any is Array) else []

	for n_any in npcs:
		if not (n_any is Dictionary):
			continue
		var n: Dictionary = n_any
		if String(n.get("id","")) != String(npc_id):
			continue

		var rl_any: Variant = n.get("role_levels", {})
		var rl: Dictionary = (rl_any as Dictionary) if (rl_any is Dictionary) else {}
		var tr_any: Variant = rl.get(String(role), null)
		if not (tr_any is Dictionary):
			return { "level": 1, "xp": 0, "xp_next": _xp_to_next(1) }

		var tr: Dictionary = tr_any
		var level := int(tr.get("level", 1))
		var prev := int(tr.get("previous_xp", int(tr.get("xp_current", 0))))
		var to_next := int(tr.get("xp_to_next", _xp_to_next(level)))
		var t_anchor_any: Variant = tr.get("time_assigned", null)

		var xp_now := prev
		if t_anchor_any is float:
			var anchor := float(t_anchor_any)
			var delta_min: float = max(0.0, now_min - anchor)
			var gained := int(XP_PER_MINUTE * delta_min)  # truncate
			xp_now = prev + gained

		return { "level": level, "xp": xp_now, "xp_next": to_next }

	return {}

## Settle one role at 'now_min'. If 'freeze_after' is true, unassigns (time_assigned = null).
static func settle_role(npc_id: StringName, role: StringName, now_min: float, slot: int, freeze_after: bool) -> void:
	var v: Dictionary = SaveManager.load_village(slot)
	var npcs_any: Variant = v.get("npcs", [])
	var npcs: Array = (npcs_any as Array) if (npcs_any is Array) else []
	var changed := false

	for i in npcs.size():
		var n_any: Variant = npcs[i]
		if not (n_any is Dictionary):
			continue
		var n: Dictionary = n_any
		if String(n.get("id","")) != String(npc_id):
			continue

		var rl_any: Variant = n.get("role_levels", {})
		var rl: Dictionary = (rl_any as Dictionary) if (rl_any is Dictionary) else {}
		var key := String(role)
		var tr_any: Variant = rl.get(key, null)
		if not (tr_any is Dictionary):
			_log("settle_role: missing track npc=%s role=%s (no-op)" % [String(npc_id), key])
			break

		var tr: Dictionary = tr_any
		var level := int(tr.get("level", 1))
		var prev := int(tr.get("previous_xp", int(tr.get("xp_current", 0))))
		var to_next := int(tr.get("xp_to_next", _xp_to_next(level)))
		var t_anchor_any: Variant = tr.get("time_assigned", null)

		if not (t_anchor_any is float):
			if freeze_after:
				_log("settle_role: already frozen npc=%s role=%s" % [String(npc_id), key])
			break

		var anchor := float(t_anchor_any)
		var delta_min: float = max(0.0, now_min - anchor)
		var gained := int(XP_PER_MINUTE * delta_min)
		var accum := prev + gained

		var levels := 0
		while accum >= to_next:
			accum -= to_next
			level += 1
			to_next = _xp_to_next(level)
			levels += 1

		if levels > 0:
			tr["level"] = level
			tr["xp_to_next"] = to_next
			tr["previous_xp"] = accum
			tr["xp_current"] = accum
			tr["time_assigned"] = now_min
			rl[key] = tr
			n["role_levels"] = rl
			npcs[i] = n
			changed = true
			_log("settle_role: npc=%s role=%s +%d lvl -> L%d xp=%d/%d (anchor %.2f→%.2f)"
				% [String(npc_id), key, levels, level, accum, to_next, anchor, now_min])
		elif freeze_after:
			tr["previous_xp"] = accum
			tr["xp_current"] = accum
			tr["time_assigned"] = null
			rl[key] = tr
			n["role_levels"] = rl
			npcs[i] = n
			changed = true
			_log("settle_role: freeze npc=%s role=%s xp=%d (delta=%.2fmin)" % [String(npc_id), key, accum, delta_min])

		break

	if changed:
		v["npcs"] = npcs
		SaveManager.save_village(v, slot)
		_log("settle_role: saved slot=%d" % slot)

# --- helpers -----------------------------------------------------------------

## Anchor the role at 'now_min' (used on assignment). Does not change previous_xp.
static func anchor_role(npc_id: StringName, role: String, time_now_min: float, slot: int = 0) -> void:
	slot = (slot if slot > 0 else SaveManager.active_slot())
	var snap: Dictionary = SaveManager.load_village(slot)
	var npcs_any: Variant = snap.get("npcs", [])
	var npcs: Array = (npcs_any as Array) if (npcs_any is Array) else []
	var anchored := false

	for i in npcs.size():
		var n_any: Variant = npcs[i]
		if not (n_any is Dictionary):
			continue
		var n: Dictionary = n_any
		if String(n.get("id","")) != String(npc_id):
			continue

		var rl_any: Variant = n.get("role_levels", {})
		var rl: Dictionary = (rl_any as Dictionary) if (rl_any is Dictionary) else {}
		var track_any: Variant = rl.get(role, null)

		if track_any is int or track_any == null:
			var lvl := 1 if (track_any == null) else int(track_any)
			track_any = {
				"level": lvl,
				"previous_xp": 0,
				"time_assigned": null,
				"xp_current": 0,
				"xp_to_next": 90,
			}

		var track: Dictionary = track_any
		track["time_assigned"] = time_now_min
		rl[role] = track
		n["role_levels"] = rl
		npcs[i] = n
		anchored = true
		_log("anchor_role: npc=%s role=%s time_assigned=%.2f" % [String(npc_id), role, time_now_min])

	if anchored:
		snap["npcs"] = npcs
		SaveManager.save_village(snap, slot)
		_log("anchor_role: saved slot=%d" % slot)
	else:
		_log("anchor_role: npc not found -> %s (no-op)" % String(npc_id))

## Map building kind -> role (kept local to avoid circular preloads)
static func _role_for_kind(kind: String) -> String:
	match kind:
		"blacksmith":     return "ARTISAN_BLACKSMITH"
		"alchemist_lab":  return "ARTISAN_ALCHEMIST"
		"marketplace":    return "INNKEEPER"
		_:
			if kind.begins_with("trainer_sword"):   return "TRAINER_SWORD"
			if kind.begins_with("trainer_spear"):   return "TRAINER_SPEAR"
			if kind.begins_with("trainer_mace"):    return "TRAINER_MACE"
			if kind.begins_with("trainer_range"):   return "TRAINER_RANGE"
			if kind.begins_with("trainer_support"): return "TRAINER_SUPPORT"
			if kind.begins_with("trainer_fire"):    return "TRAINER_FIRE"
			if kind.begins_with("trainer_water"):   return "TRAINER_WATER"
			if kind.begins_with("trainer_wind"):    return "TRAINER_WIND"
			if kind.begins_with("trainer_earth"):   return "TRAINER_EARTH"
			if kind.begins_with("trainer_light"):   return "TRAINER_LIGHT"
			if kind.begins_with("trainer_dark"):    return "TRAINER_DARK"
			return "INNKEEPER"

# Keep save's NPC rows in sync with assignment/unassignment so UI is consistent.
static func _sync_staff_state(role: String, prev_id: String, new_id: String, slot: int) -> void:
	var v: Dictionary = SaveManager.load_village(slot)
	var b_any: Variant = v.get("buildings", [])
	var buildings: Array = (b_any as Array) if (b_any is Array) else []

	var instance_for_new := ""
	if new_id != "":
		for b_any2 in buildings:
			if not (b_any2 is Dictionary):
				continue
			var b: Dictionary = b_any2
			var staff_any: Variant = b.get("staff", {})
			if staff_any is Dictionary and String((staff_any as Dictionary).get("npc_id","")) == new_id:
				instance_for_new = String(b.get("instance_id",""))
				break

	var changed := false
	if prev_id != "":
		changed = _apply_npc_state(v, prev_id, "IDLE", "", "") or changed
	if new_id != "":
		if instance_for_new == "":
			_log("WARN _sync_staff_state: could not find instance for new npc=%s role=%s" % [new_id, role])
		changed = _apply_npc_state(v, new_id, "STAFFED", role, instance_for_new) or changed

	if changed:
		SaveManager.save_village(v, slot)
		_log("_sync_staff_state: saved slot=%d (prev=%s→IDLE, new=%s→STAFFED @ %s role=%s)"
			% [slot, prev_id, new_id, instance_for_new, role])
	else:
		_log("_sync_staff_state: no-op (prev=%s, new=%s)" % [prev_id, new_id])

static func _apply_npc_state(v: Dictionary, npc_id: String, state: String, role: String, iid: String) -> bool:
	var npcs_any: Variant = v.get("npcs", [])
	var npcs: Array = (npcs_any as Array) if (npcs_any is Array) else []
	var touched := false

	for i in npcs.size():
		var row_any: Variant = npcs[i]
		if not (row_any is Dictionary):
			continue
		var n: Dictionary = row_any
		if String(n.get("id","")) != npc_id:
			continue

		var before_state := String(n.get("state",""))
		var before_role  := String(n.get("role",""))
		var before_iid   := String(n.get("assigned_instance_id",""))

		var did := false
		if before_state != state:
			n["state"] = state; did = true
		if before_role != role:
			n["role"] = role; did = true
		if before_iid != iid:
			n["assigned_instance_id"] = iid; did = true

		if did:
			npcs[i] = n
			touched = true
			_log("_apply_npc_state: npc=%s  (%s/%s/%s) -> (%s/%s/%s)"
				% [npc_id, before_state, before_role, before_iid, state, role, iid])
		break

	if touched:
		v["npcs"] = npcs
	return touched
