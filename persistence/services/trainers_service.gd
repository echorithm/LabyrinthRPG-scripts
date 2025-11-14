extends Node
class_name TrainersService

# ── Logging config ───────────────────────────────────────────────────────────
# LOG_LEVEL: 0=OFF, 1=INFO, 2=DEBUG (default INFO)
const LOG: bool = false
const LOG_LEVEL := 0
const _DBG := "[TrainersService] "

# Fine-grained toggles for very chatty spots
const LOG_SKILL_ROWS := false     # per-skill detail lines
const LOG_JSON_PREVIEW := 140       # max characters when previewing JSON payloads
const LOG_ARRAY_PREVIEW := 5        # how many array items to preview

# --- logger helpers ----------------------------------------------------------
static func _log_any(level: int, msg: String) -> void:
	if not LOG: return
	if level > LOG_LEVEL: return
	print(_DBG + msg)

static func _logi(msg: String) -> void:
	_log_any(1, msg)

static func _logd(msg: String) -> void:
	_log_any(2, msg)

static func _truncate(s: String, max_len: int) -> String:
	if s.length() <= max_len:
		return s
	return s.substr(0, max_len - 1) + "…"

static func _preview_array(a: Array, max_items: int, max_json: int) -> String:
	var shown: Array[String] = []
	var n: int = min(a.size(), max_items)
	for i in n:
		var it: Variant = a[i]
		if typeof(it) == TYPE_DICTIONARY or typeof(it) == TYPE_ARRAY:
			shown.append(_truncate(JSON.stringify(it), max_json))
		else:
			shown.append(str(it))
	var suffix: String = "" if a.size() <= max_items else (", … +" + str(a.size() - max_items))
	return "[len=" + str(a.size()) + "] [" + ", ".join(shown) + suffix + "]"

static func _preview_dict(d: Dictionary, max_json: int) -> String:
	# Show keys and a tiny sample; avoids megadumps
	var keys: PackedStringArray = PackedStringArray()
	for k in d.keys():
		keys.append(String(k))
	keys.sort()

	var sample: Dictionary = {}
	var take: int = min(3, keys.size())
	for i in take:
		var k: String = keys[i]
		sample[k] = d.get(k)

	return "{keys=" + str(keys.size()) + ", sample=" + _truncate(JSON.stringify(sample), max_json) + "}"


static func _s(v: Variant) -> String:
	match typeof(v):
		TYPE_ARRAY:
			return _preview_array(v, LOG_ARRAY_PREVIEW, LOG_JSON_PREVIEW)
		TYPE_DICTIONARY:
			return _preview_dict(v, LOG_JSON_PREVIEW)
		TYPE_PACKED_STRING_ARRAY:
			var a: Array[String] = []
			for s in (v as PackedStringArray):
				a.append(String(s))
			return _preview_array(a, LOG_ARRAY_PREVIEW, LOG_JSON_PREVIEW)
		TYPE_STRING:
			return _truncate(v, LOG_JSON_PREVIEW)
		_:
			return str(v)

static func _psa_to_str(psa: PackedStringArray) -> String:
	var arr: Array[String] = []
	var n := 0
	for s in psa:
		if n < LOG_ARRAY_PREVIEW:
			arr.append(s)
		n += 1
	var suffix := "" if psa.size() <= LOG_ARRAY_PREVIEW else (", … +" + str(psa.size() - LOG_ARRAY_PREVIEW))
	return "[" + ", ".join(arr) + suffix + "]"

# Maintain backward-compat: existing code calls _log(); now routes to INFO.
static func _log(msg: String) -> void:
	_logi(msg)

# --- External singletons (kept as Node/Object to avoid hard deps)
var _village: Node = null
var _persistence: Node = null
var _abilities_db: Node = null
var _buildings_db: Node = null

# Save fallback + slot memory
const SaveMgr := preload("res://persistence/SaveManager.gd")
var _last_slot: int = 1

# rarity → target cap mapping
const _RARITY_TO_CAP := {
	"COMMON": 10, "UNCOMMON": 20, "RARE": 30, "EPIC": 40,
	"ANCIENT": 50, "LEGENDARY": 60, "MYTHIC": 70
}

# Cached “open modal” info
var _last_modal_rarity: String = "COMMON"
var _last_modal_kind: String = ""
var _last_modal_header: Dictionary = {}

func get_ctx_key() -> String:
	return "training"

func _ready() -> void:
	var root := get_tree().get_root()
	_logi("ready(): scene_root=%s children=%d" % [root.name, root.get_child_count()])

	var scene := get_tree().get_current_scene()
	if scene != null:
		_village = scene.get_node_or_null("Services/VillageService")
		_logd("resolve VillageService @Services/VillageService -> %s" % str(is_instance_valid(_village)))

	if _village == null:
		_village = get_node_or_null("/root/VillageService")
		_logd("resolve VillageService @/root -> %s" % str(is_instance_valid(_village)))
	if _village == null:
		_village = root.get_node_or_null("VillageService")
		_logd("resolve VillageService @root child -> %s" % str(is_instance_valid(_village)))
	if _village == null:
		var g_vs := get_tree().get_nodes_in_group("VillageService")
		_logd("resolve VillageService @group size=%d" % g_vs.size())
		if g_vs.size() > 0:
			_village = g_vs[0]

	_persistence = get_node_or_null("/root/PersistenceService")
	_logd("resolve PersistenceService @/root -> %s" % str(is_instance_valid(_persistence)))
	if _persistence == null:
		_persistence = root.get_node_or_null("PersistenceService")
		_logd("resolve PersistenceService @root child -> %s" % str(is_instance_valid(_persistence)))
	if _persistence == null:
		var g_ps := get_tree().get_nodes_in_group("PersistenceService")
		_logd("resolve PersistenceService @group size=%d" % g_ps.size())
		if g_ps.size() > 0:
			_persistence = g_ps[0]

	_abilities_db = root.get_node_or_null("AbilitiesDb")
	_buildings_db = root.get_node_or_null("BuildingsDb")

	_logi("resolved -> village=%s(has header=%s staffing=%s) persistence=%s(has snap=%s player=%s stash_gold=%s) abilities_db=%s buildings_db=%s"
		% [
			str(is_instance_valid(_village)), str(is_instance_valid(_village) and _village.has_method("get_tile_header")), str(is_instance_valid(_village) and _village.has_method("get_building_staffing")),
			str(is_instance_valid(_persistence)), str(is_instance_valid(_persistence) and _persistence.has_method("get_snapshot")), str(is_instance_valid(_persistence) and _persistence.has_method("get_player")), str(is_instance_valid(_persistence) and _persistence.has_method("get_stash_gold")),
			str(is_instance_valid(_abilities_db)), str(is_instance_valid(_buildings_db))
		])

# ------------------------------------------------------------------------------------
# Entry points used by modal shell
# ------------------------------------------------------------------------------------
func open_for_tile(kind: StringName, iid: StringName, coord: Vector2i, slot: int) -> Dictionary:
	_last_slot = max(1, slot)
	_logi("open_for_tile kind=%s iid=%s coord=%s slot=%d" % [String(kind), String(iid), str(coord), slot])
	var ctx := _build_ctx(kind, iid, coord, slot)
	_logd("open_for_tile -> ctx=%s" % _s(ctx))
	return ctx

func refresh_for_tile(kind: StringName, iid: StringName, coord: Vector2i, slot: int) -> Dictionary:
	_last_slot = max(1, slot)
	_logi("refresh_for_tile kind=%s iid=%s coord=%s slot=%d" % [String(kind), String(iid), str(coord), slot])
	var ctx := _build_ctx(kind, iid, coord, slot)
	_logi("refresh_for_tile -> gold=%d shards=%d skills=%d staffed=%s connected=%s active=%s"
		% [int(ctx.get("stash_gold", 0)), int(ctx.get("stash_shards", 0)), (ctx.get("skills", []) as Array).size(),
		   str(_last_modal_header.get("staffed", false)), str(_last_modal_header.get("connected", false)), str(_last_modal_header.get("active", false))])
	return ctx

# ------------------------------------------------------------------------------------
# Context builder
# ------------------------------------------------------------------------------------
func _build_ctx(kind: StringName, iid: StringName, coord: Vector2i, slot: int) -> Dictionary:
	var header := _get_header(kind, iid, coord, slot)
	_last_modal_header = header.duplicate(true)
	_last_modal_kind = String(kind)

	var rarity_text := String(header.get("rarity", "COMMON"))
	var target_cap := int(_RARITY_TO_CAP.get(rarity_text, 10))
	_last_modal_rarity = rarity_text

	var building_entry := _get_building_entry(kind)
	_logd("building_entry(kind=%s) -> %s" % [String(kind), _s(building_entry)])

	var unlock_at_rarity := String(_training_unlock_at_rarity(building_entry))
	var per_rarity_costs := _training_costs_map(building_entry)
	_logd("training data: unlock_at=%s costs=%s" % [unlock_at_rarity, _s(per_rarity_costs)])

	var gold := _get_stash_gold()
	var shards := _get_stash_shards()

	var skills := _collect_skills(kind, rarity_text, header, gold, shards, unlock_at_rarity, per_rarity_costs)
	if skills.is_empty():
		_logi("NO SKILLS: (allowed_ids empty? abilities_db missing? player skill_tracks empty?)")

	var ctx := {
		"connected": bool(header.get("connected", false)),
		"active": bool(header.get("active", false)),
		"staffed": bool(header.get("staffed", false)),
		"trainer_rarity": rarity_text,
		"target_cap": target_cap,
		"stash_gold": gold,
		"stash_shards": shards,
		"skills": skills
	}

	_logi("ctx summary -> rarity=%s target_cap=%d gold=%d shards=%d staffed=%s"
		% [rarity_text, target_cap, gold, shards, str(bool(header.get("staffed", false)))])
	return ctx

# ------------------------------------------------------------------------------------
# Header helpers
# ------------------------------------------------------------------------------------
func _get_header(kind: StringName, iid: StringName, coord: Vector2i, slot: int) -> Dictionary:
	var header: Dictionary = {
		"id": String(kind),
		"iid": String(iid),
		"rarity": "COMMON",
		"connected": false,
		"active": false,
		"staffed": false,
		"slot": max(1, slot)
	}
	_logd("_get_header: get_tile_header(iid=%s)" % String(iid))

	if not is_instance_valid(_village):
		_logi("_get_header: VillageService missing; using defaults")
		return header

	if _village.has_method("get_tile_header"):
		var h_any: Variant = _village.call("get_tile_header", String(iid))
		_logd("  header <- %s" % _s(h_any))
		if h_any is Dictionary:
			var h: Dictionary = h_any
			if h.has("id"):        header["id"]        = h["id"]
			if h.has("rarity"):    header["rarity"]    = h["rarity"]
			if h.has("connected"): header["connected"] = h["connected"]
			if h.has("active"):    header["active"]    = h["active"]

	if _village.has_method("get_building_staffing"):
		var st_any: Variant = _village.call("get_building_staffing", String(iid))
		_logd("  staffing <- %s" % _s(st_any))
		if st_any is Dictionary:
			var st: Dictionary = st_any
			var cur := String(st.get("current_npc_id", StringName("")))
			header["staffed"] = (cur != "")
	else:
		# fallback if you add staffed into header later
		header["staffed"] = bool(header.get("staffed", false))

	return header

# ------------------------------------------------------------------------------------
# Buildings DB helpers (optional)
# ------------------------------------------------------------------------------------
func _get_building_entry(kind: StringName) -> Dictionary:
	if is_instance_valid(_buildings_db):
		_logd("_get_building_entry: buildings_db present; has(get_entry)=%s" % str(_buildings_db.has_method("get_entry")))
	if is_instance_valid(_buildings_db) and _buildings_db.has_method("get_entry"):
		var e: Variant = _buildings_db.call("get_entry", String(kind))
		_logd("  buildings_db.get_entry(%s) -> %s" % [String(kind), _s(e)])
		if e is Dictionary:
			return e
	_logd("  buildings_db missing or entry not a dict; using {}")
	return {}

func _training_unlock_at_rarity(entry: Dictionary) -> String:
	if entry.has("training") and entry["training"] is Dictionary:
		var tr: Dictionary = entry["training"]
		if tr.has("unlock_at_rarity"):
			return String(tr.get("unlock_at_rarity", "COMMON")).to_upper()
	return "COMMON"

func _training_costs_map(entry: Dictionary) -> Dictionary:
	if entry.has("training") and entry["training"] is Dictionary:
		var tr: Dictionary = entry["training"]
		if tr.has("costs") and tr["costs"] is Dictionary:
			var src: Dictionary = tr["costs"]
			var out: Dictionary = {}
			for k in src.keys():
				var v_any: Variant = src[k]
				if v_any is Dictionary:
					var v: Dictionary = v_any
					out[String(k).to_upper()] = { "gold": int(v.get("gold", 0)), "shards": int(v.get("shards", 0)) }
			return out
	return {}

func _training_cost_for_rarity(rarity: String, costs_map: Dictionary) -> Dictionary:
	var key := rarity.to_upper()
	if costs_map.has(key):
		var row: Dictionary = costs_map[key]
		return { "gold": int(row.get("gold", 0)), "shards": int(row.get("shards", 0)) }
	return { "gold": 0, "shards": 0 }

# ------------------------------------------------------------------------------------
# Skills collection (+ affordance/costs)
# ------------------------------------------------------------------------------------
func _collect_skills(
		kind: StringName,
		rarity: String,
		header: Dictionary,
		stash_gold: int,
		stash_shards: int,
		unlock_at_rarity: String,
		costs_map: Dictionary
	) -> Array[Dictionary]:
	var out: Array[Dictionary] = []

	var player: Dictionary = _get_player_snapshot()
	var tracks_any: Variant = player.get("skill_tracks", {})
	_logd("player snapshot -> %s" % _s(player))
	var tracks: Dictionary = tracks_any if (tracks_any is Dictionary) else {}
	_logi("skill_tracks: %d keys" % tracks.size())

	var allowed_ids: PackedStringArray = _ability_ids_for_building(kind)
	_logi("build_kind=%s allowed_ids=%s" % [String(kind), _psa_to_str(allowed_ids)])

	var usable := bool(header.get("connected", false)) and bool(header.get("active", false)) and bool(header.get("staffed", false))
	var target_cap: int = int(_RARITY_TO_CAP.get(rarity, 10))
	var raise_cost: Dictionary = _training_cost_for_rarity(rarity, costs_map)
	var can_unlock_at_rarity: bool = (_rarity_rank(rarity) >= _rarity_rank(unlock_at_rarity))

	_logi("gates: usable=%s rarity=%s unlock_at=%s can_unlock_at_rarity=%s target_cap=%d stash=(%dg,%ds)"
		% [str(usable), rarity, unlock_at_rarity, str(can_unlock_at_rarity), target_cap, stash_gold, stash_shards])

	for k in tracks.keys():
		var skill_id: String = String(k)
		if not allowed_ids.is_empty() and not allowed_ids.has(skill_id):
			_logd("  skip %s (not allowed)" % skill_id)
			continue

		var st_any: Variant = tracks.get(k)
		if not (st_any is Dictionary):
			_logd("  skip %s (track not dict)" % skill_id)
			continue
		var st: Dictionary = st_any

		var level: int = int(st.get("level", 1))
		var cap_band: int = int(st.get("cap_band", 10))
		var unlocked: bool = bool(st.get("unlocked", false))

		var unlock_cost: Dictionary = { "gold": 0, "shards": 0 }
		if _rarity_rank(unlock_at_rarity) > _rarity_rank("COMMON"):
			unlock_cost = _training_cost_for_rarity(unlock_at_rarity, costs_map)

		var can_afford_unlock := (stash_gold >= int(unlock_cost.get("gold", 0))) and (stash_shards >= int(unlock_cost.get("shards", 0)))
		var can_afford_raise := (stash_gold >= int(raise_cost.get("gold", 0))) and (stash_shards >= int(raise_cost.get("shards", 0)))

		var can_unlock := (not unlocked) and _can_do_common_unlock() and can_unlock_at_rarity and usable and can_afford_unlock
		var cant_unlock_reason := ""
		if not usable: cant_unlock_reason = "TRAINER_INACTIVE"
		elif unlocked: cant_unlock_reason = "ALREADY_UNLOCKED"
		elif not can_unlock_at_rarity: cant_unlock_reason = "RARITY_TOO_LOW"
		elif not can_afford_unlock: cant_unlock_reason = "INSUFFICIENT_FUNDS"

		var can_raise_cap := unlocked and (cap_band < target_cap) and usable and can_afford_raise
		var cant_raise_reason := ""
		if not usable: cant_raise_reason = "TRAINER_INACTIVE"
		elif not unlocked: cant_raise_reason = "LOCKED"
		elif cap_band >= target_cap: cant_raise_reason = "AT_CAP_FOR_RARITY"
		elif not can_afford_raise: cant_raise_reason = "INSUFFICIENT_FUNDS"

		out.append({
			"id": skill_id,
			"level": level,
			"cap_band": cap_band,
			"unlocked": unlocked,
			"can_unlock": can_unlock,
			"can_raise_cap": can_raise_cap,
			"unlock_cost": unlock_cost,
			"raise_cost": raise_cost,
			"cant_unlock_reason": cant_unlock_reason,
			"cant_raise_reason": cant_raise_reason
		})

		if LOG_SKILL_ROWS:
			_logd("  skill[%s] lv=%d cap=%d unlocked=%s unlock_cost=%s raise_cost=%s can_unlock=%s(%s) can_raise=%s(%s)"
				% [skill_id, level, cap_band, str(unlocked), _s(unlock_cost), _s(raise_cost), str(can_unlock), cant_unlock_reason, str(can_raise_cap), cant_raise_reason])

	return out

# Ability IDs for a given trainer building
func _ability_ids_for_building(kind: StringName) -> PackedStringArray:
	var group_ids: PackedStringArray = PackedStringArray()
	var trainer_entry: Dictionary = {}

	if is_instance_valid(_buildings_db):
		_logd("_ability_ids_for_building: buildings_db present=%s has(get_entry)=%s" % [str(true), str(_buildings_db.has_method("get_entry"))])

	if is_instance_valid(_buildings_db) and _buildings_db.has_method("get_entry"):
		var e: Variant = _buildings_db.call("get_entry", String(kind))
		_logd("  buildings_db.get_entry(%s) -> %s" % [String(kind), _s(e)])
		if e is Dictionary:
			trainer_entry = e
	else:
		_logd("  buildings_db missing; infer groups from kind")

	if trainer_entry.has("ability_groups"):
		var ag_any: Variant = trainer_entry.get("ability_groups")
		_logd("  ability_groups raw -> %s" % _s(ag_any))
		if ag_any is Array:
			for a in (ag_any as Array):
				group_ids.append(String(a))

	if group_ids.is_empty():
		group_ids = _infer_groups_from_kind(kind)
		_logd("  inferred groups from kind=%s -> %s" % [String(kind), _psa_to_str(group_ids)])

	var ids: PackedStringArray = PackedStringArray()
	if not group_ids.is_empty() and is_instance_valid(_abilities_db) and _abilities_db.has_method("get_abilities_for_groups"):
		var res: Variant = _abilities_db.call("get_abilities_for_groups", group_ids)
		_logd("  abilities_db.get_abilities_for_groups(%s) -> %s" % [_psa_to_str(group_ids), _s(res)])
		if res is Array:
			for r in (res as Array):
				ids.append(String(r))
		_logi("  resolved ids via abilities_db -> %s" % _psa_to_str(ids))
	elif not group_ids.is_empty():
		var fallback := {
			"sword": PackedStringArray(["arc_slash", "riposte"]),
			"spear": PackedStringArray(["thrust", "skewer"]),
			"mace": PackedStringArray(["crush", "guard_break"]),
			"range": PackedStringArray(["aimed_shot", "piercing_bolt"]),
			"support": PackedStringArray(["block", "rest", "meditate", "heal", "purify"]),
			"fire": PackedStringArray(["firebolt", "flame_wall"]),
			"water": PackedStringArray(["water_jet", "tide_surge"]),
			"earth": PackedStringArray(["stone_spikes", "bulwark"]),
			"wind": PackedStringArray(["gust", "cyclone"]),
			"light": PackedStringArray(["heal", "purify"]),
			"dark": PackedStringArray(["shadow_grasp", "curse_mark"])
		}
		for g in group_ids:
			if fallback.has(g):
				for id in (fallback[g] as PackedStringArray):
					ids.append(id)
		_logi("  resolved ids via fallback -> %s" % _psa_to_str(ids))
	else:
		_logi("  no groups for kind=%s (returning empty)" % String(kind))

	return ids

static func _infer_groups_from_kind(kind: StringName) -> PackedStringArray:
	var groups := PackedStringArray()
	var k := String(kind)
	if k.begins_with("trainer_") and k.length() > 8:
		groups.append(k.substr(8))
	return groups

# ------------------------------------------------------------------------------------
# Unlock & raise-cap actions
# ------------------------------------------------------------------------------------
func request_unlock(skill_id: StringName) -> bool:
	_logi("request_unlock -> %s (slot=%d rarity=%s kind=%s)" % [String(skill_id), _last_slot, _last_modal_rarity, _last_modal_kind])

	var allowed := _ability_ids_for_building(StringName(_last_modal_kind))
	if not allowed.is_empty() and not allowed.has(String(skill_id)):
		_logi("  fail: not allowed (allowed=%s)" % _psa_to_str(allowed))
		return false

	var header := _last_modal_header
	var usable := bool(header.get("connected", false)) and bool(header.get("active", false)) and bool(header.get("staffed", false))
	_logi("  usable=%s (connected=%s active=%s staffed=%s)" % [str(usable), str(header.get("connected", false)), str(header.get("active", false)), str(header.get("staffed", false))])
	if not usable:
		return false

	var entry: Dictionary = _get_building_entry(StringName(_last_modal_kind))
	var unlock_at := _training_unlock_at_rarity(entry)
	if _rarity_rank(_last_modal_rarity) < _rarity_rank(unlock_at):
		_logi("  fail: rarity too low (need %s, have %s)" % [unlock_at, _last_modal_rarity])
		return false

	var costs_map := _training_costs_map(entry)
	var unlock_cost := { "gold": 0, "shards": 0 }
	if _rarity_rank(unlock_at) > _rarity_rank("COMMON"):
		unlock_cost = _training_cost_for_rarity(unlock_at, costs_map)
	_logd("  unlock_cost=%s -> try_spend" % _s(unlock_cost))
	if not _try_spend(unlock_cost):
		_logi("  fail: insufficient funds")
		return false

	var gs: Dictionary = SaveMgr.load_game(_last_slot)
	var pl_any: Variant = gs.get("player", {})
	if not (pl_any is Dictionary):
		_logi("  fail: META.player missing")
		return false
	var pl: Dictionary = pl_any

	var tracks_any: Variant = pl.get("skill_tracks", {})
	if not (tracks_any is Dictionary):
		_logi("  fail: META.player.skill_tracks missing")
		return false
	var tracks: Dictionary = tracks_any

	if not tracks.has(String(skill_id)):
		_logi("  fail: track missing (%s)" % String(skill_id))
		return false

	var row_any: Variant = tracks.get(String(skill_id))
	if not (row_any is Dictionary):
		_logi("  fail: META track not dict")
		return false
	var row: Dictionary = row_any

	if bool(row.get("unlocked", false)):
		_logi("  already unlocked (no-op)")
		return true

	row["unlocked"] = true
	tracks[String(skill_id)] = row
	pl["skill_tracks"] = tracks
	gs["player"] = pl
	SaveMgr.save_game(gs, _last_slot)
	_logi("  unlocked OK (META)")

	_sync_run_skill_row(String(skill_id), { "unlocked": true })
	return true

func request_raise_cap(skill_id: StringName, rarity: String = "COMMON") -> bool:
	_log("request_raise_cap -> %s rarity=%s (slot=%d kind=%s)" % [String(skill_id), rarity, _last_slot, _last_modal_kind])

	# Allowed check (building-kind gate)
	var allowed := _ability_ids_for_building(StringName(_last_modal_kind))
	if not allowed.is_empty() and not allowed.has(String(skill_id)):
		_log("  fail: skill not allowed for this trainer, allowed=%s" % _psa_to_str(allowed))
		return false

	# Usability gate (connected+active+staffed)
	var header := _last_modal_header
	var usable := bool(header.get("connected", false)) and bool(header.get("active", false)) and bool(header.get("staffed", false))
	_log("  usable=%s header=%s" % [str(usable), _s(header)])
	if not usable:
		return false

	# Costs for the rarity we’re targeting (default to the current modal rarity if blank)
	var entry: Dictionary = _get_building_entry(StringName(_last_modal_kind))
	var costs_map := _training_costs_map(entry)
	var use_rarity := (rarity if rarity != "" else _last_modal_rarity)
	var raise_cost := _training_cost_for_rarity(use_rarity, costs_map)
	_log("  raise_cost=%s -> try_spend" % _s(raise_cost))
	if not _try_spend(raise_cost):
		_log("  fail: insufficient funds")
		return false

	# Target cap for the chosen rarity
	var cap_target: int = int(_RARITY_TO_CAP.get(use_rarity, 10))

	# ---- META write via SaveManager (no PersistenceService required) ----
	var gs: Dictionary = SaveMgr.load_game(_last_slot)
	var pl_any: Variant = gs.get("player", {})
	if not (pl_any is Dictionary):
		_log("  fail: META.player missing")
		return false
	var pl: Dictionary = pl_any

	var tracks_any: Variant = pl.get("skill_tracks", {})
	if not (tracks_any is Dictionary):
		_log("  fail: META.player.skill_tracks missing")
		return false
	var tracks: Dictionary = tracks_any

	if not tracks.has(String(skill_id)):
		_log("  fail: track id missing in META -> %s" % String(skill_id))
		return false

	var row_any: Variant = tracks.get(String(skill_id))
	if not (row_any is Dictionary):
		_log("  fail: META track row not a dict")
		return false
	var row: Dictionary = row_any

	var current_cap: int = int(row.get("cap_band", 10))
	_log("  cap: current=%d target=%d" % [current_cap, cap_target])
	if current_cap >= cap_target:
		_log("  no-op (already at/above target)")
		return true

	row["cap_band"] = cap_target
	tracks[String(skill_id)] = row
	pl["skill_tracks"] = tracks
	gs["player"] = pl
	SaveMgr.save_game(gs, _last_slot)
	_log("  wrote META.player.skill_tracks[%s].cap_band=%d" % [String(skill_id), cap_target])

	# Mirror to RUN snapshot so in-run state stays consistent
	_sync_run_skill_row(String(skill_id), { "cap_band": cap_target })

	return true

# ------------------------------------------------------------------------------------
# Stash helpers
# ------------------------------------------------------------------------------------
func _get_stash_gold() -> int:
	_logd("_get_stash_gold(slot=%d)" % _last_slot)
	if is_instance_valid(_village):
		if _village.has_method("get_stash_gold"):
			var g_vs: int = int(_village.call("get_stash_gold"))
			_logd("  via VillageService -> %d" % g_vs)
			return g_vs

	if is_instance_valid(_persistence):
		if _persistence.has_method("get_stash_gold"):
			var g_ps: int = int(_persistence.call("get_stash_gold"))
			_logd("  via PersistenceService -> %d" % g_ps)
			return g_ps
		if _persistence.has_method("get_snapshot"):
			var snap_any: Variant = _persistence.call("get_snapshot")
			_logd("  snapshot -> %s" % _s(snap_any))
			if snap_any is Dictionary and (snap_any as Dictionary).has("stash_gold"):
				return int((snap_any as Dictionary)["stash_gold"])

	var player_snap: Dictionary = _get_player_snapshot()
	if player_snap.has("stash_gold"):
		return int(player_snap["stash_gold"])

	var gs: Dictionary = SaveMgr.load_game(_last_slot)
	return int(gs.get("stash_gold", 0))

func _get_stash_shards() -> int:
	_logd("_get_stash_shards(slot=%d)" % _last_slot)
	if is_instance_valid(_village) and _village.has_method("get_stash_shards"):
		var s_vs: int = int(_village.call("get_stash_shards"))
		_logd("  via VillageService -> %d" % s_vs)
		return s_vs
	if is_instance_valid(_persistence) and _persistence.has_method("get_stash_shards"):
		var s_ps: int = int(_persistence.call("get_stash_shards"))
		_logd("  via PersistenceService -> %d" % s_ps)
		return s_ps
	if is_instance_valid(_persistence) and _persistence.has_method("get_snapshot"):
		var snap_any: Variant = _persistence.call("get_snapshot")
		_logd("  snapshot -> %s" % _s(snap_any))
		if snap_any is Dictionary and (snap_any as Dictionary).has("stash_shards"):
			return int((snap_any as Dictionary)["stash_shards"])

	var player_snap: Dictionary = _get_player_snapshot()
	if player_snap.has("stash_shards"):
		return int(player_snap.get("stash_shards", 0))

	var gs: Dictionary = SaveMgr.load_game(_last_slot)
	return int(gs.get("stash_shards", 0))

func _try_spend(cost: Dictionary) -> bool:
	var need_g: int = int(cost.get("gold", 0))
	var need_s: int = int(cost.get("shards", 0))
	_logd("_try_spend cost=%s" % _s(cost))
	if need_g <= 0 and need_s <= 0:
		_logd("  free -> ok")
		return true
	var gs: Dictionary = SaveMgr.load_game(_last_slot)
	var have_g: int = int(gs.get("stash_gold", 0))
	var have_s: int = int(gs.get("stash_shards", 0))
	if have_g < need_g or have_s < need_s:
		_logi("  spend insufficient (have %d/%d, need %d/%d)" % [have_g, have_s, need_g, need_s])
		return false
	gs["stash_gold"] = max(0, have_g - need_g)
	gs["stash_shards"] = max(0, have_s - need_s)
	SaveMgr.save_game(gs, _last_slot)
	_logi("  spent -> gold=%d shards=%d" % [int(gs["stash_gold"]), int(gs["stash_shards"])])
	return true

# ------------------------------------------------------------------------------------
# Player access
# ------------------------------------------------------------------------------------
func _get_player_proxy() -> Object:
	if is_instance_valid(_persistence):
		_logd("_get_player_proxy: persistence.has(get_player)=%s" % str(_persistence.has_method("get_player")))
		if _persistence.has_method("get_player"):
			var p: Variant = _persistence.call("get_player")
			_logd("  get_player -> %s" % _s(p))
			if p != null:
				return p
	_logd("  player proxy not available")
	return null

func _get_player_snapshot() -> Dictionary:
	var p: Object = _get_player_proxy()
	if p != null:
		_logd("_get_player_snapshot: player.has(get_data)=%s" % str(p.has_method("get_data")))
		if p.has_method("get_data"):
			var v_any: Variant = p.get_data()
			_logd("  player.get_data -> %s" % _s(v_any))
			if v_any is Dictionary:
				var v: Dictionary = (v_any as Dictionary)
				if v.has("player") and (v["player"] is Dictionary):
					return v["player"]
				return v

	_logd("  snapshot via SaveMgr")
	var gs: Dictionary = SaveMgr.load_game(_last_slot)
	var pl_any: Variant = gs.get("player", {})
	if pl_any is Dictionary:
		return (pl_any as Dictionary)
	return {}

# ------------------------------------------------------------------------------------
# RUN mirror
# ------------------------------------------------------------------------------------
func _sync_run_skill_row(skill_id: String, fields: Dictionary) -> void:
	_logd("_sync_run_skill_row id=%s fields=%s" % [skill_id, _s(fields)])
	if not SaveMgr.run_exists(_last_slot):
		_logd("  run not present for slot=%d (skip)" % _last_slot)
		return
	var rs: Dictionary = SaveMgr.load_run(_last_slot)
	var st_all_any: Variant = rs.get("skill_tracks", {})
	var st_all: Dictionary = (st_all_any as Dictionary) if (st_all_any is Dictionary) else {}
	var row_any: Variant = st_all.get(String(skill_id), {})
	var row: Dictionary = (row_any as Dictionary) if (row_any is Dictionary) else {}

	for k in fields.keys():
		row[k] = fields[k]

	st_all[String(skill_id)] = row
	rs["skill_tracks"] = st_all
	SaveMgr.save_run(rs, _last_slot)
	_logd("  run row synced")

# ------------------------------------------------------------------------------------
# UI rule helpers
# ------------------------------------------------------------------------------------
func set_last_modal_rarity(r: String) -> void:
	_last_modal_rarity = r
	_logd("set_last_modal_rarity -> %s" % r)

func _current_target_cap_for_open_modal() -> int:
	return int(_RARITY_TO_CAP.get(_last_modal_rarity, 10))

func _can_do_common_unlock() -> bool:
	return true

# ------------------------------------------------------------------------------------
# Rarity rank helper
# ------------------------------------------------------------------------------------
static func _rarity_rank(r: String) -> int:
	match r.to_upper():
		"COMMON": return 0
		"UNCOMMON": return 1
		"RARE": return 2
		"EPIC": return 3
		"ANCIENT": return 4
		"LEGENDARY": return 5
		"MYTHIC": return 6
		_: return -1
