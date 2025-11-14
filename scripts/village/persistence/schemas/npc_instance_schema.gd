# Godot 4.5 — Validates & normalizes an NPC instance for village.json (role_levels dict-ready)
extends RefCounted
class_name NPCInstanceSchema

const ROLES: Array[String] = [
	"INNKEEPER","ARTISAN_BLACKSMITH","ARTISAN_ALCHEMIST","ARTISAN_SCRIBE","CLERGY","ADMIN",
	"TRAINER_SWORD","TRAINER_SPEAR","TRAINER_MACE","TRAINER_RANGE","TRAINER_SUPPORT",
	"TRAINER_FIRE","TRAINER_WATER","TRAINER_WIND","TRAINER_EARTH","TRAINER_LIGHT","TRAINER_DARK"
]

static var DEBUG: bool = false
static func _dbg(msg: String) -> void:
	if DEBUG:
		print("[NPCInst] " + msg)

const XpTuning := preload("res://scripts/rewards/XpTuning.gd")

# ---- safe casts -------------------------------------------------------------

static func _as_int(v: Variant, def: int) -> int:
	if v is int: return v
	if v is float: return int(v)
	if v is String:
		var s: String = v
		if s.is_valid_int(): return s.to_int()
		if s.is_valid_float(): return int(s.to_float())
	return def

static func _get_int(d: Dictionary, key: String, def: int = 0) -> int:
	return _as_int(d.get(key, def), def)

static func _get_string(d: Dictionary, key: String, def: String = "") -> String:
	var v: Variant = d.get(key, def)
	return String(v) if (v is String) else def

# ---- role_levels helpers ----------------------------------------------------

static func _mk_role_track(level_i: int) -> Dictionary:
	var lv: int = max(1, level_i)
	return {
		"level": lv,
		"xp_current": int(0),
		"xp_to_next": int(XpTuning.xp_to_next(lv)),
		"previous_xp": int(0),
		"time_assigned": null, # float|null (minutes anchor from META)
	}

# Accept int OR Dictionary rows; fill defaults; clamp level.
static func _get_role_levels(d: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	var any: Variant = d.get("role_levels", {})
	if typeof(any) != TYPE_DICTIONARY:
		return out

	var src: Dictionary = any
	for k in src.keys():
		var ks := String(k)
		var raw: Variant = src.get(k, 1)

		if raw is int:
			out[ks] = _mk_role_track(_as_int(raw, 1))
			continue

		if raw is Dictionary:
			var rd: Dictionary = raw
			var lv: int = max(1, _as_int(rd.get("level", 1), 1))
			# Preserve existing keys; fill any missing to keep dict stable
			var dst: Dictionary = {
				"level": lv,
				"xp_current": int(rd.get("xp_current", 0)),
				"xp_to_next": int(rd.get("xp_to_next", XpTuning.xp_to_next(lv))),
				"previous_xp": int(rd.get("previous_xp", 0)),
				"time_assigned": rd.get("time_assigned", null)
			}
			out[ks] = dst
			continue

		# Anything else → default track at 1
		out[ks] = _mk_role_track(1)

	return out

static func _rarity_from_level(level: int) -> String:
	var bands: Array[String] = ["COMMON","UNCOMMON","RARE","EPIC","ANCIENT","LEGENDARY","MYTHIC"]
	if level <= 0:
		return "COMMON"
	var idx := int((level - 1) / 10)
	if idx < bands.size():
		return bands[idx]
	var overflow := idx - (bands.size() - 1)
	return "MYTHICx%d" % overflow

# ---- validate ---------------------------------------------------------------

static func validate(npc: Dictionary) -> Dictionary:
	_dbg("validate in id=%s role=%s" % [String(_get_string(npc,"id","<new>")), String(_get_string(npc,"role",""))])

	var out: Dictionary = {}

	# Deterministic-safe defaults
	var id_in: String = _get_string(npc, "id", "")
	if id_in == "":
		id_in = "npc_0000"
	out["id"] = id_in

	# Role is optional for MVP hiring. Do NOT coerce to INNKEEPER.
	var role_in: String = _get_string(npc, "role", "")
	if role_in != "" and not ROLES.has(role_in):
		role_in = ""
	out["role"] = role_in

	out["name"] = _get_string(npc, "name", "Nameless")

	var level: int = _get_int(npc, "level", 1)
	if level < 1: level = 1
	if level > 200: level = 200
	out["level"] = level

	# Legacy (kept for back-compat; runtime now uses role_levels[role].xp_current)
	var legacy_xp: int = _get_int(npc, "xp_current", 0)
	out["xp_current"] = legacy_xp

	# Keep rarity derived from level if not provided
	var rarity_in: String = _get_string(npc, "rarity", "")
	out["rarity"] = rarity_in if rarity_in != "" else _rarity_from_level(level)

	out["fatigue"] = _get_int(npc, "fatigue", 0)
	out["injury_cooldown"] = _get_int(npc, "injury_cooldown", 0)

	var state: String = _get_string(npc, "state", "IDLE")
	if state != "IDLE" and state != "STAFFED" and state != "DEAD":
		state = "IDLE"
	out["state"] = state

	var seed: int = _get_int(npc, "appearance_seed", 0)
	if seed < 0:
		seed = 0
	out["appearance_seed"] = seed

	var wage: int = _get_int(npc, "wage", 0)
	if wage < 0:
		wage = 0
	out["wage"] = wage

	# New fields for MVP:
	out["race"] = _get_string(npc, "race", "")
	out["sex"] = _get_string(npc, "sex", "")

	# Assignment info (optional, persisted). Empty string means "not assigned"
	out["assigned_instance_id"] = _get_string(npc, "assigned_instance_id", "")

	# role_levels block (supports dict rows)
	var role_levels: Dictionary = _get_role_levels(npc)

	# One-time legacy migration: if we have legacy xp and an active role, inject it
	if legacy_xp > 0 and role_in != "":
		var cur_any: Variant = role_levels.get(role_in, null)
		if cur_any is Dictionary:
			var curd: Dictionary = cur_any
			if int(curd.get("xp_current", 0)) == 0:
				curd["xp_current"] = legacy_xp
				# Keep xp_to_next consistent with its level if missing
				if not curd.has("xp_to_next"):
					var lv_i: int = int(curd.get("level", 1))
					curd["xp_to_next"] = int(XpTuning.xp_to_next(lv_i))
				role_levels[role_in] = curd
		elif cur_any is int:
			var lv2: int = max(1, int(cur_any))
			role_levels[role_in] = {
				"level": lv2,
				"xp_current": legacy_xp,
				"xp_to_next": int(XpTuning.xp_to_next(lv2)),
				"previous_xp": 0,
				"time_assigned": null
			}
		elif cur_any == null:
			# Create track and seed xp
			role_levels[role_in] = {
				"level": 1,
				"xp_current": legacy_xp,
				"xp_to_next": int(XpTuning.xp_to_next(1)),
				"previous_xp": 0,
				"time_assigned": null
			}

	out["role_levels"] = role_levels

	_dbg("validate out id=%s role=%s level=%d rarity=%s state=%s wage=%d" %
		[String(out["id"]), String(out["role"]), int(out["level"]), String(out["rarity"]), String(out["state"]), int(out["wage"])])

	return out
