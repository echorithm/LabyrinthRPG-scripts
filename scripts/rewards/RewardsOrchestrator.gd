# res://scripts/rewards/RewardsOrchestrator.gd
extends Node

# Try to set in Inspector; falls back to DEFAULT_MODAL_PATH if unset.
@export var rewards_modal_scene: PackedScene
const DEFAULT_MODAL_PATH := "res://scenes/RewardsModal.tscn"

const AbilityXPService := preload("res://persistence/services/ability_xp_service.gd")
const ProgressionService := preload("res://persistence/services/progression_service.gd")

const _S := preload("res://persistence/util/save_utils.gd")
const XpTuning := preload("res://scripts/rewards/XpTuning.gd")

var _ui_layer: CanvasLayer = null
var _modal: Control = null
var _last_enemy_name: String = ""
var _last_enemy_level: int = 0
var _last_enemy_role: String = "trash"

const DEV_DEBUG_PRINTS := true        # legacy switch (still honored)
@export var debug_logs: bool = true   # ← convenient runtime toggle

func _dbg(msg: String, data: Variant = null) -> void:
	if not (DEV_DEBUG_PRINTS or debug_logs):
		return
	if data == null:
		print("[RewardsOrchestrator] ", msg)
	else:
		var payload_str: String
		var t := typeof(data)
		if t == TYPE_DICTIONARY or t == TYPE_ARRAY:
			payload_str = JSON.stringify(data)
		else:
			payload_str = str(data)
		print("[RewardsOrchestrator] ", msg, "  ", payload_str)

# ---------------- GameLog helpers ----------------
static func _get_gamelog() -> Node:
	var root: Node = Engine.get_main_loop().root
	return root.get_node_or_null(^"/root/GameLog")

static func _gl_info(cat: String, msg: String, data: Dictionary = {}) -> void:
	var gl: Node = _get_gamelog()
	if gl != null:
		gl.call("info", cat, msg, data)

static func _gl_warn(cat: String, msg: String, data: Dictionary = {}) -> void:
	var gl: Node = _get_gamelog()
	if gl != null:
		gl.call("warn", cat, msg, data)

# ----------------------------------------------------------------------
func _ready() -> void:
	# Work even while paused (modal pauses the game).
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_process_unhandled_input(true)

	# Listen for battle results.
	var router := get_node_or_null(^"/root/EncounterRouter")
	if router != null and not router.is_connected("battle_finished", Callable(self, "_on_battle_finished")):
		router.connect("battle_finished", Callable(self, "_on_battle_finished"))
		_dbg("connected to EncounterRouter.battle_finished")
	else:
		_gl_warn("rewards", "EncounterRouter not found; rewards listener inactive.")

# ------------------- Battle flow --------------------------------------
func _on_battle_finished(bc_result: Dictionary) -> void:
	_dbg("_on_battle_finished()", bc_result.duplicate(true))

	var outcome: String = String(bc_result.get("outcome", "defeat"))
	var enc_id: int = int(bc_result.get("encounter_id", 0))

	_last_enemy_role  = String(bc_result.get("role", "trash"))
	_last_enemy_name  = String(bc_result.get("monster_display_name", bc_result.get("monster_slug", "")))
	_last_enemy_level = int(bc_result.get("monster_level", 0))

	var slot_i: int = SaveManager.active_slot()

	if outcome == "victory":
		# Build victory ctx for per-enemy skill XP (single-enemy today; multi-enemy later)
		var snap := ProgressionService.get_character_snapshot(slot_i)
		var p_level: int = int(snap.get("level", 1))

		var role_enum: int = XpTuning.Role.TRASH
		match _last_enemy_role.to_lower():
			"elite": role_enum = XpTuning.Role.ELITE
			"boss":  role_enum = XpTuning.Role.BOSS
			_:       role_enum = XpTuning.Role.TRASH

		var enemies: Array = [{ "monster_level": max(1, _last_enemy_level), "role": role_enum }]

		var sxp_rows: Array = AbilityXPService.commit_encounter(enc_id, {
			"player_level": p_level,
			"allies_count": 1,
			"enemies": enemies
		}, slot_i)

		_dbg("commit_encounter → sxp_rows", sxp_rows.duplicate())
		_gl_info("rewards", "Encounter settled (skill XP committed). Loot path will present.", {
			"encounter_id": enc_id, "rows": sxp_rows.size()
		})
		return

	# defeat branch unchanged (slot-safe reload)
	AbilityXPService.discard_encounter(enc_id, slot_i)
	ProgressionService.apply_death_penalties()
	_rs_reload(slot_i)

	var defeat_data := _receipt_to_modal({
		"gold": 0, "shards": 0, "hp": 0, "mp": 0, "items": [],
		"char_xp_applied": { "add": 0 },
		"skill_xp_applied": []
	}, true)

	defeat_data["outcome"] = outcome
	defeat_data["enemy_display_name"] = (_last_enemy_name if _last_enemy_name != "" else "Enemy")
	defeat_data["enemy_level"]        = _last_enemy_level
	defeat_data["enemy_role"]         = _last_enemy_role

	_gl_info("rewards", "Defeat penalties applied; modal prepared.", {
		"encounter_id": enc_id, "modal": defeat_data.duplicate(true)
	})
	_present_modal(defeat_data)

# ------------------- Helpers ------------------------------------------
func _to_skill_applied_rows(sxp_rows: Array) -> Array:
	var out: Array = []
	for r_any in sxp_rows:
		if r_any is Dictionary:
			var r: Dictionary = r_any
			out.append({
				"id": String(r.get("id", "")),
				"xp": int(r.get("xp", 0)),
				"after": { "level": int(r.get("new_level", 0)) }
			})
	_dbg("_to_skill_applied_rows -> out", out.duplicate())
	return out

static func _source_from_role(role: String) -> String:
	match role:
		"elite": return "elite"
		"boss":  return "boss"
		_:       return "trash"

# Deterministic helper retained for any preview callers (no randomize()).
func _character_xp_for_victory(role: String, monster_level: int) -> int:
	var slot_i: int = SaveManager.active_slot()
	var snap: Dictionary = ProgressionService.get_character_snapshot(slot_i)
	var p_level: int = int(snap.get("level", 1))

	var role_enum: int = XpTuning.Role.TRASH
	match role.to_lower():
		"elite": role_enum = XpTuning.Role.ELITE
		"boss":  role_enum = XpTuning.Role.BOSS

	var enemies: Array = [ { "monster_level": max(1, monster_level), "role": role_enum } ]
	var cxp: int = XpTuning.char_xp_for_victory_v2(p_level, enemies, 1)

	_gl_info("rewards", "Character XP preview (v2).", {
		"player_level": p_level, "monster_level": monster_level,
		"role": role, "xp": cxp
	})
	_dbg("_character_xp_for_victory[v2]", {"xp": cxp})
	return cxp

# ------------------- Loot grant path ----------------------------------
func grant_from_loot(loot: Dictionary, merge_skill_deltas: bool = false) -> Dictionary:
	var items: Array[Dictionary] = ItemResolver.resolve(loot)
	var slot_i: int = SaveManager.active_slot()

	# --- BONUS: very-rare Common book drop on ANY boss (deterministic) ---
	var role_str: String = String(loot.get("enemy_role", _last_enemy_role))
	if role_str == "boss":
		_maybe_append_bonus_common_book(loot, items)

	# Snapshot level BEFORE granting (so we can detect level-ups even if receipt lacks 'after')
	var run_before: Dictionary = SaveManager.load_run(slot_i)
	var sb_before: Dictionary = _S.to_dict(run_before.get("player_stat_block", {}))
	var prev_lvl: int = int(sb_before.get("level", 1))

	var rewards: Dictionary = {
		"gold":   int(loot.get("gold", 0)),
		"shards": int(loot.get("shards", 0)),
		"items":  items,
		"xp":     int(loot.get("xp", 0)),
		"skill_xp": (loot.get("skill_xp", []) as Array)
	}

	var receipt: Dictionary = RewardService.grant(rewards, slot_i)
	_rs_reload(slot_i)

	# Determine new level from receipt
	var cxp_dict: Dictionary = receipt.get("char_xp_applied", {}) as Dictionary
	var after_char: Dictionary = cxp_dict.get("after", {}) as Dictionary
	var new_lvl: int = (int(after_char.get("level", 0)) if not after_char.is_empty() else prev_lvl)
	if new_lvl == prev_lvl:
		var run_after: Dictionary = SaveManager.load_run(slot_i)
		var sb_after: Dictionary = _S.to_dict(run_after.get("player_stat_block", {}))
		new_lvl = int(sb_after.get("level", prev_lvl))

	var levels_gained: int = max(0, new_lvl - prev_lvl)
	if levels_gained > 0:
		var svc_node := get_node_or_null(^"/root/CombatMusicService")
		if svc_node != null and svc_node.has_method("play_level_up"):
			_dbg("[audio] level-up SFX (loot path)", {"prev": prev_lvl, "new": new_lvl, "levels_gained": levels_gained})
			svc_node.call("play_level_up")
		else:
			_gl_warn("audio", "CombatMusicService missing or lacks play_level_up().", {})

	var modal_data := _receipt_to_modal(receipt, merge_skill_deltas)

	# Enemy header
	var loot_name: String = String(loot.get("enemy_display_name", ""))
	var loot_level: int = int(loot.get("enemy_level", 0))
	var loot_role: String = String(loot.get("enemy_role", ""))

	if loot_name != "":
		modal_data["enemy_display_name"] = loot_name
	if loot_level > 0:
		modal_data["enemy_level"] = loot_level
	if loot_role != "":
		modal_data["enemy_role"] = loot_role

	# Fallbacks
	if _last_enemy_name != "" and not modal_data.has("enemy_display_name"):
		modal_data["enemy_display_name"] = _last_enemy_name
	if _last_enemy_level > 0 and not modal_data.has("enemy_level"):
		modal_data["enemy_level"] = _last_enemy_level
	if _last_enemy_role != "" and not modal_data.has("enemy_role"):
		modal_data["enemy_role"] = _last_enemy_role

	_dbg("grant_from_loot → modal_data", modal_data.duplicate(true))
	_gl_info("rewards", "Loot granted; modal prepared.", {
		"loot_in": loot.duplicate(true),
		"receipt": receipt.duplicate(true),
		"modal": modal_data.duplicate(true)
	})
	_present_modal(modal_data)
	return receipt

# ------------------- UI helpers --------------------------
func _rs_reload(slot: int = 0) -> void:
	if slot <= 0:
		slot = SaveManager.active_slot()
	var rs := get_node_or_null(^"/root/RunState")
	if rs and rs.has_method("reload"):
		_dbg("_rs_reload() calling RunState.reload", {"slot": slot})
		rs.call("reload", slot)

func _ensure_modal() -> void:
	if rewards_modal_scene == null:
		var ps: Resource = load(DEFAULT_MODAL_PATH)
		if ps is PackedScene:
			rewards_modal_scene = ps
		else:
			push_error("RewardsOrchestrator: cannot load RewardsModal at %s" % DEFAULT_MODAL_PATH)
			_gl_warn("rewards", "Cannot load RewardsModal; path invalid.", {"path": DEFAULT_MODAL_PATH})
			return

	if _ui_layer == null:
		_ui_layer = CanvasLayer.new()
		_ui_layer.layer = 500
		_ui_layer.name = "RewardsUILayer"
		get_tree().root.add_child(_ui_layer)
		_dbg("_ensure_modal() created UI layer", {"layer": _ui_layer.layer})

	if _modal == null:
		var inst := rewards_modal_scene.instantiate()
		if inst == null:
			push_error("RewardsOrchestrator: instantiate() failed.")
			_gl_warn("rewards", "Rewards modal instantiate() failed.")
			return
		_modal = inst as Control
		_modal.top_level = true
		_modal.set_anchors_preset(Control.PRESET_FULL_RECT)
		_ui_layer.add_child(_modal)
		_dbg("_ensure_modal() instantiated modal", {"type": typeof(_modal)})

		# IMPORTANT: close hook → clean battle visuals
		if not _modal.is_connected("closed", Callable(self, "_on_rewards_modal_closed")):
			_modal.connect("closed", Callable(self, "_on_rewards_modal_closed"))

func _on_rewards_modal_closed() -> void:
	# Called when the player clicks Continue on the rewards modal.
	var bl := get_tree().root.get_node_or_null(^"/root/BattleLoader")
	if bl != null:
		if bl.has_method("cleanup_battle_visuals"):
			bl.call("cleanup_battle_visuals")
		elif bl.has_method("_cleanup_after_battle"):
			bl.call("_cleanup_after_battle", "victory")

func _present_modal(data: Dictionary) -> void:
	if _last_enemy_name != "" and not data.has("enemy_display_name"):
		data["enemy_display_name"] = _last_enemy_name
	if _last_enemy_level > 0 and not data.has("enemy_level"):
		data["enemy_level"] = _last_enemy_level
	if _last_enemy_role != "" and not data.has("enemy_role"):
		data["enemy_role"] = _last_enemy_role

	_dbg("_present_modal(data)", data.duplicate(true))
	_ensure_modal()
	if _modal == null:
		_gl_warn("rewards", "No modal instance; cannot present.", {"data": data.duplicate(true)})
		return
	if _modal.has_method("present"):
		_modal.call("present", data)
	else:
		_gl_warn("rewards", "Modal lacks present(data) method.", {"data": data.duplicate(true)})

func _receipt_to_modal(receipt: Dictionary, merge_skill_deltas: bool = true) -> Dictionary:
	_dbg("_receipt_to_modal(receipt, merge=%s)" % str(merge_skill_deltas), receipt.duplicate(true))

	var items_in: Array = (receipt.get("items", []) as Array)
	var items_out: Array = []
	for it_any in items_in:
		if it_any is Dictionary:
			var it: Dictionary = it_any
			var id_str := String(it.get("id", ""))
			it["name"] = ItemNames.display_name(id_str)
			items_out.append(it)

	var cxp: Dictionary = receipt.get("char_xp_applied", {}) as Dictionary
	var xp_value: int = int(cxp.get("add", 0))
	var char_after: Dictionary = cxp.get("after", {}) as Dictionary

	var sxp_applied: Array = (receipt.get("skill_xp_applied", []) as Array)
	var sxp_for_modal: Array = []

	for row_any in sxp_applied:
		if row_any is Dictionary:
			var row: Dictionary = row_any
			var after_row: Dictionary = row.get("after", {}) as Dictionary
			sxp_for_modal.append({
				"id": String(row.get("id", "")),
				"xp": int(row.get("xp", 0)),
				"new_level": int(after_row.get("level", 0))
			})

	# Merge deltas saved in RUN when requested.
	if merge_skill_deltas:
		var sxp_from_deltas := _collect_and_clear_skill_xp_deltas(SaveManager.active_slot())
		for e_any in sxp_from_deltas:
			if e_any is Dictionary:
				sxp_for_modal.append(e_any)

	var modal := {
		"gold": int(receipt.get("gold", 0)),
		"shards": int(receipt.get("shards", 0)),
		"hp": int(receipt.get("hp", 0)),
		"mp": int(receipt.get("mp", 0)),
		"items": items_out,
		"skill_xp": sxp_for_modal,
		"xp": xp_value,
		"char_new_level": int(char_after.get("level", 0)),
		"char_points_gained": int(char_after.get("points_added", 0)),
		"char_points_unspent": int(char_after.get("points_unspent", 0))
	}
	_dbg("_receipt_to_modal -> modal", modal.duplicate(true))
	return modal

func _collect_and_clear_skill_xp_deltas(slot: int = 0) -> Array:
	if slot <= 0:
		slot = SaveManager.active_slot()
	var rs := SaveManager.load_run(slot)
	var deltas: Dictionary = rs.get("skill_xp_delta", {}) as Dictionary

	if DEV_DEBUG_PRINTS or debug_logs:
		print("[RewardsOrchestrator] [deltas] before clear: keys=", deltas.keys(), " values=", deltas)

	if deltas.is_empty():
		return []

	var out: Array = []
	var tracks: Dictionary = rs.get("skill_tracks", {}) as Dictionary
	for aid_any in deltas.keys():
		var aid := String(aid_any)
		var xp_add: int = int(deltas[aid_any])
		if xp_add <= 0:
			continue
		var lvl: int = 0
		if tracks.has(aid) and tracks[aid] is Dictionary:
			lvl = int((tracks[aid] as Dictionary).get("level", 0))
		out.append({ "id": aid, "xp": xp_add, "new_level": lvl })

	_gl_info("rewards", "Collected skill XP deltas.", {"slot": slot, "rows": out.duplicate(true)})

	# Clear after reading so we don’t show them twice.
	rs["skill_xp_delta"] = {}
	SaveManager.save_run(rs, slot)

	if DEV_DEBUG_PRINTS or debug_logs:
		print("[RewardsOrchestrator] [deltas] cleared.")

	return out

func _peek_skill_xp_deltas(slot: int = 0) -> Dictionary:
	if slot <= 0:
		slot = SaveManager.active_slot()
	var rs: Dictionary = SaveManager.load_run(slot)
	var deltas: Dictionary = _S.to_dict(rs.get("skill_xp_delta", {}))
	return deltas.duplicate(true)

# ------------------- BONUS C-Book helper (deterministic) ----------------------
func _maybe_append_bonus_common_book(loot: Dictionary, items: Array[Dictionary]) -> void:
	var slot_i: int = SaveManager.active_slot()
	var run_seed: int = SaveManager.get_run_seed(slot_i)
	var floor_i: int = SaveManager.get_current_floor(slot_i)
	var enemy_id: String = String(loot.get("enemy_id", ""))
	var s := "%d|%d|%s|boss_book_bonus" % [run_seed, floor_i, enemy_id]
	var rng := RandomNumberGenerator.new()
	rng.seed = int(s.hash())

	# 1.5% chance per boss victory
	var p: float = 0.015
	if rng.randf() >= p:
		return

	# Build a Common book that targets a locked skill if possible
	var rs: Dictionary = SaveManager.load_run(slot_i)
	var tracks: Dictionary = _S.to_dict(_S.dget(rs, "skill_tracks", {}))

	var WEAPON_SKILLS: PackedStringArray = [
		"arc_slash","thrust","skewer","riposte","guard_break","crush","aimed_shot","piercing_bolt"
	]
	var ELEMENT_SKILLS: PackedStringArray = [
		"shadow_grasp","curse_mark","heal","purify","firebolt","flame_wall","water_jet","tide_surge","stone_spikes","gust"
	]

	var pick_family_is_weapon: bool = (rng.randi_range(0, 1) == 0)
	var family: PackedStringArray = WEAPON_SKILLS if pick_family_is_weapon else ELEMENT_SKILLS
	var locked: PackedStringArray = []
	var candidates: PackedStringArray = []
	for s_id in family:
		var row: Dictionary = _S.to_dict(_S.dget(tracks, s_id, {}))
		var is_unlocked: bool = bool(_S.dget(row, "unlocked", false))
		if is_unlocked:
			candidates.append(s_id)
		else:
			locked.append(s_id)

	var target: String = ""
	if not locked.is_empty():
		target = locked[rng.randi_range(0, locked.size() - 1)]
	elif not candidates.is_empty():
		target = candidates[rng.randi_range(0, candidates.size() - 1)]
	else:
		return # no skills known? nothing to add

	var item_id: String = "book_weapon_common" if pick_family_is_weapon else "book_element_common"
	var it: Dictionary = {
		"id": item_id,
		"count": 1,
		"rarity": "Common",
		"opts": {
			"ilvl": 1,
			"archetype": "Consumable",
			"rarity": "Common",
			"affixes": [],
			"durability_max": 0,
			"durability_current": 0,
			"weight": 0.0,
			"target_skill": target
		}
	}
	items.append(it)
	_dbg("bonus_common_book_appended", {"item": it, "rng_p": p})
