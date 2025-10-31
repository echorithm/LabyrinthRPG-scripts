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

const DEV_DEBUG_PRINTS := false         # legacy switch (still honored)
@export var debug_logs: bool = false    # ← convenient runtime toggle

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

	# Cache enemy header so ANY presentation path (including grant_from_loot) can use it.
	_last_enemy_role  = String(bc_result.get("role", "trash"))
	_last_enemy_name  = String(bc_result.get("monster_display_name", bc_result.get("monster_slug", "")))
	_last_enemy_level = int(bc_result.get("monster_level", 0))

	if outcome == "victory":
		# --- Skill XP (commit pending per-ability entries) ---
		# Pass actual monster level so level_diff_factor uses the enemy level, not the floor.
		var sxp_rows: Array = AbilityXPService.commit_encounter(enc_id, _last_enemy_level, SaveManager.DEFAULT_SLOT)
		_dbg("commit_encounter → sxp_rows", sxp_rows.duplicate())

		# --- Character XP: compute using MONSTER level, then APPLY TO RUN ONLY (not META) ---
		var snap: Dictionary = ProgressionService.get_character_snapshot(SaveManager.DEFAULT_SLOT)
		var player_level: int = int(snap.get("level", 1))
		var target_level: int = (_last_enemy_level if _last_enemy_level > 0 else SaveManager.get_current_floor(SaveManager.DEFAULT_SLOT))

		# Deterministic wiggle: derive from run seed ^ encounter_id
		var rng := RandomNumberGenerator.new()
		var run_seed: int = SaveManager.get_run_seed(SaveManager.DEFAULT_SLOT)
		var seed: int = int(run_seed ^ enc_id)
		if seed == 0:
			rng.randomize()
		else:
			rng.seed = seed

		var cxp_add: int = XpTuning.char_xp_for_victory(player_level, target_level, _last_enemy_role, "C", rng)
		_dbg("char_xp_for_victory", {
			"player_level": player_level, "target_level": target_level,
			"role": _last_enemy_role, "add": cxp_add
		})

		# Apply to RUN
		var rs := SaveManager.load_run(SaveManager.DEFAULT_SLOT)
		var sb: Dictionary = _S.to_dict(rs.get("player_stat_block", {}))
		var lvl: int = int(sb.get("level", 1))
		var cur: int = int(sb.get("xp_current", 0))
		var need: int = int(sb.get("xp_needed", XpTuning.xp_to_next(lvl)))
		var levels_gained: int = 0

		cur += max(0, cxp_add)
		while cur >= need:
			cur -= need
			lvl += 1
			levels_gained += 1
			need = XpTuning.xp_to_next(lvl)

		sb["level"] = lvl
		sb["xp_current"] = cur
		sb["xp_needed"] = need
		rs["player_stat_block"] = sb
		rs["points_unspent"] = int(rs.get("points_unspent", 0)) + (levels_gained * 2)
		SaveManager.save_run(rs, SaveManager.DEFAULT_SLOT)
		_dbg("run saved (post-xp)", {
			"lvl": lvl, "cur": cur, "need": need,
			"levels_gained": levels_gained, "points_unspent": rs.get("points_unspent", 0)
		})

		var before_char := snap
		var after_char := {
			"level": lvl,
			"xp_current": cur,
			"xp_needed": need,
			"points_unspent": int(rs.get("points_unspent", 0))
		}

		_rs_reload(SaveManager.DEFAULT_SLOT)

		var receipt := {
			"gold": 0, "shards": 0, "hp": 0, "mp": 0, "items": [],
			"char_xp_applied": { "add": cxp_add, "before": before_char, "after": after_char },
			"skill_xp_applied": _to_skill_applied_rows(sxp_rows)
		}
		_dbg("receipt(pre-modal)", receipt.duplicate(true))

		# Merge & clear any RUN.skill_xp_delta now that victory is finalized.
		var modal_data := _receipt_to_modal(receipt, true)

		# Enemy/name/level/role for modal
		modal_data["outcome"] = outcome
		modal_data["enemy_display_name"] = (_last_enemy_name if _last_enemy_name != "" else "Enemy")
		modal_data["enemy_level"] = _last_enemy_level
		modal_data["enemy_role"] = _last_enemy_role

		_gl_info("rewards", "Rewards modal prepared (victory).", modal_data.duplicate(true))
		_present_modal(modal_data)

	else:
		# defeat: discard encounter XP, apply penalties, show modal
		AbilityXPService.discard_encounter(enc_id)
		ProgressionService.apply_death_penalties()
		_rs_reload(SaveManager.DEFAULT_SLOT)

		var defeat_data := _receipt_to_modal({
			"gold": 0, "shards": 0, "hp": 0, "mp": 0, "items": [],
			"char_xp_applied": { "add": 0 },
			"skill_xp_applied": []
		}, true)

		# Enemy/name/level/role for modal
		defeat_data["outcome"] = outcome
		defeat_data["enemy_display_name"] = (_last_enemy_name if _last_enemy_name != "" else "Enemy")
		defeat_data["enemy_level"] = _last_enemy_level
		defeat_data["enemy_role"] = _last_enemy_role

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

func _character_xp_for_victory(role: String, monster_level: int) -> int:
	# Player level from META snapshot (read-only).
	var snap: Dictionary = ProgressionService.get_character_snapshot(SaveManager.DEFAULT_SLOT)
	var player_level: int = int(snap.get("level", 1))

	var source: String = _source_from_role(role)
	var rarity_code := "C"

	var rng := RandomNumberGenerator.new()
	rng.randomize()

	var cxp := XpTuning.char_xp_for_victory(player_level, monster_level, source, rarity_code, rng)
	_gl_info("rewards", "Character XP computed.", {
		"player_level": player_level,
		"monster_level": monster_level,
		"source": source,
		"rarity": rarity_code,
		"xp": cxp
	})
	_dbg("_character_xp_for_victory", {"xp": cxp})
	return cxp

# ------------------- Existing loot plumbing (unchanged) ----------------
func grant_from_loot(loot: Dictionary, merge_skill_deltas: bool = false) -> Dictionary:
	var items: Array[Dictionary] = ItemResolver.resolve(loot)
	var rewards: Dictionary = {
		"gold":   int(loot.get("gold", 0)),
		"shards": int(loot.get("shards", 0)),
		"items":  items,
		"xp":     int(loot.get("xp", 0)),
		"skill_xp": (loot.get("skill_xp", []) as Array)
	}

	var receipt: Dictionary = RewardService.grant(rewards, SaveManager.DEFAULT_SLOT)
	_rs_reload(SaveManager.DEFAULT_SLOT)

	var modal_data := _receipt_to_modal(receipt, merge_skill_deltas)

	# --- NEW: pick enemy header straight from loot (preferred path)
	var loot_name: String = String(loot.get("enemy_display_name", ""))
	var loot_level: int = int(loot.get("enemy_level", 0))
	var loot_role: String = String(loot.get("enemy_role", ""))

	if loot_name != "":
		modal_data["enemy_display_name"] = loot_name
	if loot_level > 0:
		modal_data["enemy_level"] = loot_level
	if loot_role != "":
		modal_data["enemy_role"] = loot_role

	# Fallbacks from cached copy (if present)
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

# ------------------- UI helpers ---------------------------------------
func _rs_reload(slot: int = SaveManager.DEFAULT_SLOT) -> void:
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

func _present_modal(data: Dictionary) -> void:
	# Backfill from cached enemy header if caller forgot to include it.
	if _last_enemy_name != "" and not data.has("enemy_display_name"):
		data["enemy_display_name"] = _last_enemy_name
	if _last_enemy_level > 0 and not data.has("enemy_level"):
		data["enemy_level"] = _last_enemy_level
	if _last_enemy_role != "" and not data.has("enemy_role"):
		data["enemy_role"] = _last_enemy_role

	_dbg("_present_modal(data)", data.duplicate(true))
	_ensure_modal()
	if _modal == null:
		push_warning("RewardsOrchestrator: no modal; skipping UI.")
		_gl_warn("rewards", "No modal instance; cannot present.", {"data": data.duplicate(true)})
		return
	if _modal.has_method("present"):
		_modal.call("present", data)
	else:
		push_warning("RewardsOrchestrator: modal has no present(Dictionary).")
		_gl_warn("rewards", "Modal lacks present(data) method.", {"data": data.duplicate(true)})

# Map RewardService.grant(...) receipt → RewardsModal.present(...) data
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
		var sxp_from_deltas := _collect_and_clear_skill_xp_deltas(SaveManager.DEFAULT_SLOT)
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

func _collect_and_clear_skill_xp_deltas(slot: int = SaveManager.DEFAULT_SLOT) -> Array:
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

func _peek_skill_xp_deltas(slot: int = SaveManager.DEFAULT_SLOT) -> Dictionary:
	var rs := SaveManager.load_run(slot)
	var deltas: Dictionary = _S.to_dict(rs.get("skill_xp_delta", {}))
	return deltas.duplicate(true)
