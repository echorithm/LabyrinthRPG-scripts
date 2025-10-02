# res://scripts/rewards/RewardsOrchestrator.gd
extends Node


# Try to set in Inspector; falls back to DEFAULT_MODAL_PATH if unset.
@export var rewards_modal_scene: PackedScene
const DEFAULT_MODAL_PATH := "res://scenes/RewardsModal.tscn"

const AbilityXPService := preload("res://persistence/services/ability_xp_service.gd")
const ProgressionService := preload("res://persistence/services/progression_service.gd")

const _S := preload("res://persistence/util/save_utils.gd")
# Optional: if you have tuning helpers for character XP
const XpTuning := preload("res://scripts/rewards/XpTuning.gd")

var _ui_layer: CanvasLayer = null
var _modal: Control = null

func _ready() -> void:
	print("[RewardsOrchestrator] ready scene_set=", rewards_modal_scene != null)
	# Work even while paused (modal pauses the game).
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_process_unhandled_input(true)

	# Listen for battle results (emitted by your battle controller or router).
	var router := get_node_or_null(^"/root/EncounterRouter")
	if router != null and not router.is_connected("battle_finished", Callable(self, "_on_battle_finished")):
		router.connect("battle_finished", Callable(self, "_on_battle_finished"))

# ------------------- Battle flow ----------------------------------------------

func _on_battle_finished(bc_result: Dictionary) -> void:
	var outcome: String = String(bc_result.get("outcome","defeat"))
	var enc_id: int = int(bc_result.get("encounter_id", 0))
	var role: String = String(bc_result.get("role","trash"))

	if outcome == "victory":
		# 1) Apply all pending per-ability skill XP for this encounter.
		#    This performs skill level-ups and 5-level milestone stat grants internally.
		var sxp_rows: Array = AbilityXPService.commit_encounter(enc_id)  # [{id, xp, new_level}]

		# 2) Award character XP (level-ups + +2 points per level are handled internally).
		var cxp_add: int = _character_xp_for_victory(role)
		var before_char := ProgressionService.get_character_snapshot()
		var after_char := ProgressionService.award_character_xp(cxp_add)

		# Build a "receipt-like" structure then map it to the modal payload.
		var receipt := {
			"gold": 0,
			"shards": 0,
			"hp": 0,
			"mp": 0,
			"items": [],
			# shape that _receipt_to_modal expects:
			"char_xp_applied": { "add": cxp_add, "before": before_char, "after": after_char },
			"skill_xp_applied": _to_skill_applied_rows(sxp_rows),
		}
		_rs_reload(SaveManager.DEFAULT_SLOT)
		_present_modal(_receipt_to_modal(receipt))
	else:
		# Defeat: clear pending and apply death penalties (resets progress bars, keeps levels).
		AbilityXPService.discard_encounter(enc_id)
		ProgressionService.apply_death_penalties()
		_rs_reload(SaveManager.DEFAULT_SLOT)
		_present_modal(_receipt_to_modal({
			"gold": 0, "shards": 0, "hp": 0, "mp": 0, "items": [],
			"char_xp_applied": { "add": 0 },
			"skill_xp_applied": []
		}))

func _to_skill_applied_rows(sxp_rows: Array) -> Array:
	var out: Array = []
	for r_any in sxp_rows:
		if r_any is Dictionary:
			var r: Dictionary = r_any
			# Convert to { id, xp, after: {level: <int>} } for _receipt_to_modal()
			out.append({
				"id": String(r.get("id","")),
				"xp": int(r.get("xp", 0)),
				"after": { "level": int(r.get("new_level", 0)) }
			})
	return out

func _character_xp_for_victory(role: String) -> int:
	# Player level from progression snapshot
	var snap: Dictionary = ProgressionService.get_character_snapshot(SaveManager.DEFAULT_SLOT)
	var player_level: int = int(snap.get("level", 1))

	# Use floor as the “target level”
	var target_level: int = SaveManager.get_current_floor(SaveManager.DEFAULT_SLOT)

	# Map role to XpTuning “source”
	var source: String = "trash"
	if role == "elite":
		source = "elite"
	elif role == "boss":
		source = "boss"

	# Rarity code: default to common for encounters; tune later if you like
	var rarity_code := "C"

	var rng := RandomNumberGenerator.new()
	rng.randomize()

	return XpTuning.char_xp_for_victory(player_level, target_level, source, rarity_code, rng)


# ------------------- Existing loot flow (unchanged) ---------------------------

func grant_from_loot(loot: Dictionary) -> Dictionary:
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
	_present_modal(_receipt_to_modal(receipt))
	return receipt

# ------------------- UI helpers ----------------------------------------------

func _rs_reload(slot: int = SaveManager.DEFAULT_SLOT) -> void:
	var rs := get_node_or_null(^"/root/RunState")
	if rs and rs.has_method("reload"):
		rs.call("reload", slot)

func _ensure_modal() -> void:
	if rewards_modal_scene == null:
		var ps: Resource = load(DEFAULT_MODAL_PATH)
		if ps is PackedScene:
			rewards_modal_scene = ps
			print("[RewardsOrchestrator] fallback-loaded modal scene from ", DEFAULT_MODAL_PATH)
		else:
			push_error("RewardsOrchestrator: cannot load RewardsModal at %s" % DEFAULT_MODAL_PATH)
			return

	if _ui_layer == null:
		_ui_layer = CanvasLayer.new()
		_ui_layer.layer = 500
		_ui_layer.name = "RewardsUILayer"
		get_tree().root.add_child(_ui_layer)

	if _modal == null:
		var inst := rewards_modal_scene.instantiate()
		if inst == null:
			push_error("RewardsOrchestrator: instantiate() failed.")
			return
		_modal = inst as Control
		_modal.top_level = true
		_modal.set_anchors_preset(Control.PRESET_FULL_RECT)
		_ui_layer.add_child(_modal)
		print("[RewardsOrchestrator] modal instantiated and added to layer=", _ui_layer.layer)

func _present_modal(data: Dictionary) -> void:
	_ensure_modal()
	if _modal == null:
		push_warning("RewardsOrchestrator: no modal; skipping UI.")
		return
	if _modal.has_method("present"):
		_modal.call("present", data)
	else:
		push_warning("RewardsOrchestrator: modal has no present(Dictionary).")

# Map RewardService.grant(...) receipt → RewardsModal.present(...) data
func _receipt_to_modal(receipt: Dictionary) -> Dictionary:
	var items_in: Array = (receipt.get("items", []) as Array)
	var items_out: Array = []
	for it_any in items_in:
		if it_any is Dictionary:
			var it: Dictionary = it_any
			var id_str := String(it.get("id",""))
			it["name"] = ItemNames.display_name(id_str)
			items_out.append(it)

	# Character XP (from RewardService.grant)
	var cxp: Dictionary = receipt.get("char_xp_applied", {}) as Dictionary
	var xp_value: int = int(cxp.get("add", 0))
	var char_after: Dictionary = cxp.get("after", {}) as Dictionary
	var points_gained: int = int(cxp.get("points_gained", 0))
	var run_points_unspent: int = int(cxp.get("run_points_unspent", 0))

	var new_char_level: int = 0
	if cxp.has("after") and cxp["after"] is Dictionary:
		new_char_level = int((cxp["after"] as Dictionary).get("level", 0))

	# Skill XP: from receipt (if caller merged) + from RUN.skill_xp_delta (our fallback)
	var sxp_applied: Array = (receipt.get("skill_xp_applied", []) as Array)
	var sxp_for_modal: Array = []

	# Normalize anything already in the receipt
	for row_any in sxp_applied:
		if row_any is Dictionary:
			var row: Dictionary = row_any
			var after_row: Dictionary = row.get("after", {}) as Dictionary
			var entry := {
				"id": String(row.get("id","")),
				"xp": int(row.get("xp", 0)),
				"new_level": int(after_row.get("level", 0))
			}
			sxp_for_modal.append(entry)

	# Merge deltas recorded by BattleController (and clear them)
	var sxp_from_deltas := _collect_and_clear_skill_xp_deltas(SaveManager.DEFAULT_SLOT)
	for e_any in sxp_from_deltas:
		if e_any is Dictionary:
			sxp_for_modal.append(e_any)

	return {
		"gold": int(receipt.get("gold", 0)),
		"shards": int(receipt.get("shards", 0)),
		"hp": int(receipt.get("hp", 0)),
		"mp": int(receipt.get("mp", 0)),
		"items": items_out,
		"skill_xp": sxp_for_modal,
		"xp": xp_value,
		# NEW fields for the modal to show level-ups & points
		"char_new_level": int(char_after.get("level", 0)),
		"char_points_gained": int(char_after.get("points_added", 0)),
		"char_points_unspent": int(char_after.get("points_unspent", 0))
	}

func _collect_and_clear_skill_xp_deltas(slot: int = SaveManager.DEFAULT_SLOT) -> Array:
	var rs := SaveManager.load_run(slot)
	var deltas: Dictionary = rs.get("skill_xp_delta", {}) as Dictionary
	if deltas.is_empty():
		return []

	# Build modal-friendly rows: { id, xp, new_level }
	var out: Array = []
	# We can read levels from RUN.skill_tracks (already updated by BattleController)
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

	# Clear after reading so we don’t show them twice.
	rs["skill_xp_delta"] = {}
	SaveManager.save_run(rs, slot)
	return out
