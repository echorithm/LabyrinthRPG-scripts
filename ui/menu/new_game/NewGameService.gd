# res://ui/menu/new_game/NewGameService.gd
extends RefCounted
class_name NewGameService

const DEBUG: bool = true
static func _dbg(msg: String) -> void:
	if DEBUG:
		print("[NewGameService] ", msg)

const DEFAULT_DIFFICULTY: String = "U"
const DEFAULT_WEAPON: String = "bow"
const DEFAULT_ELEMENT: String = "fire"

var difficulty_code: String = DEFAULT_DIFFICULTY
var weapon_family: String = DEFAULT_WEAPON
var element_id: String = DEFAULT_ELEMENT

func reset() -> void:
	_dbg("reset()")
	difficulty_code = DEFAULT_DIFFICULTY
	weapon_family = DEFAULT_WEAPON
	element_id = DEFAULT_ELEMENT

func set_difficulty(code: String) -> void:
	var c: String = code.strip_edges().to_upper()
	var allowed: PackedStringArray = PackedStringArray(["C","U","R","E","A","L","M"])
	difficulty_code = (c if allowed.has(c) else DEFAULT_DIFFICULTY)
	_dbg("set_difficulty → " + difficulty_code)

func set_weapon(family: String) -> void:
	var s: String = family.strip_edges().to_lower()
	var allowed: PackedStringArray = PackedStringArray(["sword","spear","mace","bow"])
	weapon_family = (s if allowed.has(s) else DEFAULT_WEAPON)
	_dbg("set_weapon → " + weapon_family)

func set_element(elem: String) -> void:
	var s: String = elem.strip_edges().to_lower()
	var allowed: PackedStringArray = PackedStringArray(["fire","water","earth","wind","light","dark"])
	element_id = (s if allowed.has(s) else DEFAULT_ELEMENT)
	_dbg("set_element → " + element_id)

func weapon_starting_abilities() -> Array[String]:
	match weapon_family:
		"sword": return ["arc_slash","riposte"]
		"spear": return ["thrust","skewer"]
		"mace":  return ["crush","guard_break"]
		"bow":   return ["aimed_shot","piercing_bolt"]
		_:       return ["aimed_shot","piercing_bolt"]

func element_starting_abilities() -> Array[String]:
	match element_id:
		"light": return ["heal","purify"]
		"fire":  return ["firebolt","flame_wall"]
		"water": return ["water_jet","tide_surge"]
		"earth": return ["stone_spikes","bulwark"]
		"wind":  return ["gust","cyclone"]
		"dark":  return ["shadow_grasp","curse_mark"]
		_:       return ["firebolt","flame_wall"]

func starting_abilities() -> Array[String]:
	var out: Array[String] = []
	for a: String in weapon_starting_abilities():
		out.append(a)
	for b: String in element_starting_abilities():
		out.append(b)
	return out

# Returns: { ok:bool, slot:int, start_scene:String }
func commit_new_game(preferred_slot: int, start_tutorial: bool) -> Dictionary:
	_dbg("commit_new_game start: slot_hint=%d diff=%s weapon=%s elem=%s start_tutorial=%s"
		% [preferred_slot, difficulty_code, weapon_family, element_id, str(start_tutorial)])

	var slot: int = (preferred_slot if preferred_slot > 0 else 1)

	# --- 1) META in-memory: difficulty/tutorial flags + tutorial queue ---
	var gs: Dictionary = SaveManager.load_game(slot)
	var settings: Dictionary = (gs.get("settings", {}) as Dictionary)
	settings["difficulty"] = difficulty_code
	settings["tutorial_seen"] = false
	settings["tutorial_pending"] = not start_tutorial
	gs["settings"] = settings

	gs["tutorial"] = { "queue": PackedStringArray(starting_abilities()) }

	# --- 2) META in-memory: ensure equipment families + seed starter weapon ---
	var player: Dictionary = (gs.get("player", {}) as Dictionary)
	var loadout: Dictionary = (player.get("loadout", {}) as Dictionary)
	var eq_meta: Dictionary = (loadout.get("equipment", {}) as Dictionary)

	# Fill canonical family keys if missing
	var canonical: Dictionary = {
		"head": null, "chest": null, "legs": null, "boots": null,
		"sword": null, "spear": null, "mace": null, "bow": null,
		"ring1": null, "ring2": null, "amulet": null
	}
	var canonical_keys: PackedStringArray = PackedStringArray([
		"head","chest","legs","boots","sword","spear","mace","bow","ring1","ring2","amulet"
	])
	for k: String in canonical_keys:
		if not eq_meta.has(k):
			eq_meta[k] = canonical[k]

	var fam: String = weapon_family
	if not PackedStringArray(["sword","spear","mace","bow"]).has(fam):
		fam = "bow"  # safety default

	var starter_item: Dictionary = EquipmentService._debug_proto_for_slot(fam)
	eq_meta[fam] = starter_item.duplicate(true)

	loadout["equipment"] = eq_meta
	player["loadout"] = loadout
	gs["player"] = player

	# --- 3) PERSIST FIRST (allow-create in MENU) -----------------------------
	# Create the file before calling any progression service that uses save_game().
	SaveManager.save_game_allow_create(gs, slot)
	_dbg("META saved (pre-unlock): difficulty=%s weapon=%s starters=%s"
		% [difficulty_code, fam, str(starting_abilities())])

	# --- 4) Unlock starting abilities now that the file exists ----------------
	for aid: String in starting_abilities():
		ProgressionService.set_unlocked(aid, true, slot)

	# Make this slot active (and update recency)
	SaveManager.activate_and_touch(slot)

	# --- 5) Mirror META → RUN once, then lock run difficulty ------------------
	SaveManager.start_or_refresh_run_from_meta(slot)            # allow-create inside
	SaveManager.ensure_run_difficulty_locked_on_run_start(slot) # freeze difficulty in RUN.

	# Optional: tiny verification log (non-fatal)
	var rs_snap: Dictionary = SaveManager.load_run(slot)
	var eq_run: Dictionary = (rs_snap.get("equipment", {}) as Dictionary)
	_dbg("RUN equip summary: sword=%s spear=%s mace=%s bow=%s"
		% [str(eq_run.get("sword", null)), str(eq_run.get("spear", null)),
		   str(eq_run.get("mace", null)),  str(eq_run.get("bow", null))])

	var start_scene: String = (
		"res://ui/menu/new_game/GestureTutorial.tscn" if start_tutorial
		else "res://scripts/village/state/VillageHexOverworld2.tscn"
	)
	_dbg("commit_new_game done: slot=%d scene=%s" % [slot, start_scene])
	return { "ok": true, "slot": slot, "start_scene": start_scene }

# (Optional) If you want to reuse the family name elsewhere.
func _weapon_slot_name() -> String:
	return weapon_family if PackedStringArray(["sword","spear","mace","bow"]).has(weapon_family) else "bow"
