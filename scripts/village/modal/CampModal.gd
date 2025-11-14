# res://scripts/village/modal/CampModal.gd
extends "res://ui/common/BaseModal.gd"
class_name CampModalPanel

const SaveMgr := preload("res://persistence/SaveManager.gd")
const NPCRecruitmentService := preload("res://scripts/village/services/NPCRecruitmentService.gd")
const NPCHiringService := preload("res://scripts/village/services/NPCHiringService.gd")
const NPCConfig := preload("res://scripts/village/services/NPCConfig.gd")
const TimeService := preload("res://persistence/services/time_service.gd")
const NPCXpService := preload("res://scripts/village/services/NPCXpService.gd")

var _coord: Vector2i
func set_context(coord: Vector2i) -> void:
	_coord = coord

@export var slot: int = 1
@export var recruitment_service_path: NodePath
@export var hiring_service_path: NodePath

var _content: Control
var _btn_close: Button
var _candidates_v: VBoxContainer
var _gold_label: Label
var _restock_label: Label

# NEW: roster section
var _roster_header: Label
var _btn_roster_refresh: Button
var _roster_v: VBoxContainer

var _recruit: NPCRecruitmentService = null
var _hire: NPCHiringService = null

# Maps rendered row -> original page index (from recruitment page)
var _render_index_map: Array[int] = []

func _ready() -> void:
	super._ready()
	_content = $"Panel/Margin/V/Content"
	_btn_close = $"Panel/Margin/V/Bottom/Close"
	if _btn_close and not _btn_close.pressed.is_connected(_on_close_pressed):
		_btn_close.pressed.connect(_on_close_pressed)

	_recruit = get_node_or_null(recruitment_service_path) as NPCRecruitmentService
	_hire    = get_node_or_null(hiring_service_path) as NPCHiringService
	assert(_recruit != null, "NPCRecruitmentService missing (wire recruitment_service_path)")
	assert(_hire != null, "NPCHiringService missing (wire hiring_service_path)")

	_build_ui()
	_apply_mobile_styles()
	connect("resized", Callable(self, "_apply_mobile_styles"))

func _build_ui() -> void:
	_clear_children(_content)

	var root: VBoxContainer = VBoxContainer.new()
	root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_theme_constant_override("separation", 10)
	_content.add_child(root)

	var title: Label = Label.new()
	title.text = "Camp"
	title.autowrap_mode = TextServer.AUTOWRAP_WORD
	title.add_theme_font_size_override("font_size", 22)
	root.add_child(title)

	_gold_label = Label.new()
	_gold_label.add_theme_font_size_override("font_size", 16)
	root.add_child(_gold_label)
	_update_gold_label()

	var sub: Label = Label.new()
	sub.text = "Hire Staff (%dg)" % NPCConfig.HIRE_COST_GOLD
	sub.add_theme_font_size_override("font_size", 16)
	root.add_child(sub)

	var top_row: HBoxContainer = HBoxContainer.new()
	top_row.add_theme_constant_override("separation", 8)
	root.add_child(top_row)

	var btn_refresh: Button = Button.new()
	btn_refresh.name = "BtnRefreshCandidates"
	btn_refresh.text = "Refresh Candidates"
	btn_refresh.pressed.connect(_on_refresh_candidates_pressed)
	top_row.add_child(btn_refresh)

	_candidates_v = VBoxContainer.new()
	_candidates_v.add_theme_constant_override("separation", 6)
	_candidates_v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_candidates_v.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(_candidates_v)

	# Apply timed restock (advances cursor if enough minutes elapsed)
	var restock: Dictionary = _recruit.apply_timed_restock(slot)

	_restock_label = Label.new()
	_restock_label.add_theme_font_size_override("font_size", 14)
	_restock_label.modulate = Color(1.0, 1.0, 1.0, 0.9)
	root.add_child(_restock_label)
	_update_restock_label(restock)

	# Divider
	var sep := HSeparator.new()
	root.add_child(sep)

	# --- Current NPCs section ---
	var roster_row: HBoxContainer = HBoxContainer.new()
	roster_row.add_theme_constant_override("separation", 8)
	root.add_child(roster_row)

	_roster_header = Label.new()
	_roster_header.text = "Current NPCs"
	_roster_header.add_theme_font_size_override("font_size", 16)
	_roster_header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	roster_row.add_child(_roster_header)

	_btn_roster_refresh = Button.new()
	_btn_roster_refresh.name = "BtnRefreshRoster"
	_btn_roster_refresh.text = "Refresh NPC List"
	_btn_roster_refresh.pressed.connect(_on_refresh_roster_pressed)
	roster_row.add_child(_btn_roster_refresh)

	_roster_v = VBoxContainer.new()
	_roster_v.add_theme_constant_override("separation", 6)
	_roster_v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_roster_v.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(_roster_v)

	# Initial paints
	_render_candidates()
	_render_roster()

func _target_btn_height() -> float:
	return float(min_touch_target_px if _is_mobile_view() else 44)

func _apply_mobile_styles() -> void:
	# Close button
	if is_instance_valid(_btn_close):
		_btn_close.custom_minimum_size.y = _target_btn_height()

	# Top refresh buttons
	var btn_refresh := _content.get_node_or_null(^"../V/Content/BtnRefreshCandidates") as Button
	if btn_refresh == null:
		# fallback to manual search in the container we created
		btn_refresh = _content.get_node_or_null(^"BtnRefreshCandidates") as Button
	if btn_refresh:
		btn_refresh.custom_minimum_size.y = _target_btn_height()

	if is_instance_valid(_btn_roster_refresh):
		_btn_roster_refresh.custom_minimum_size.y = _target_btn_height()

	# Each hire button in candidates list
	if is_instance_valid(_candidates_v):
		for i in _candidates_v.get_child_count():
			var row := _candidates_v.get_child(i)
			if row is HBoxContainer:
				for c in row.get_children():
					if c is Button:
						(c as Button).custom_minimum_size.y = _target_btn_height()

# ---------- Candidates ----------
func _render_candidates() -> void:
	_clear_children(_candidates_v)
	_render_index_map.clear()

	var page: Array[Dictionary] = _recruit.get_page(slot) as Array[Dictionary]

	# Debug: show raw page before filtering out already-hired NPCs
	for i in page.size():
		var r: Dictionary = page[i]
		print("[CampModal] prefilter i=", i, " key=", _candidate_key(r))

	# Filter out already hired + build source-index map
	var pair: Array = _filter_out_hired_with_index_map(page)
	var filtered: Array[Dictionary] = pair[0] as Array[Dictionary]
	var index_map: Array[int] = pair[1] as Array[int]
	_render_index_map = index_map

	# Debug: visible list + mapping back to source indices
	for j in filtered.size():
		var r2: Dictionary = filtered[j]
		print("[CampModal] postfilter j=", j, " key=", _candidate_key(r2), " source_idx=", index_map[j])

	var gs: Dictionary = SaveMgr.load_game(slot)
	var gold: int = int(gs.get("stash_gold", 0))
	var cost: int = NPCConfig.HIRE_COST_GOLD

	if filtered.is_empty():
		var empty: Label = Label.new()
		empty.text = "No candidates right now."
		_candidates_v.add_child(empty)
		return

	for i in filtered.size():
		var row: Dictionary = filtered[i]

		var hb: HBoxContainer = HBoxContainer.new()
		hb.add_theme_constant_override("separation", 6)
		_candidates_v.add_child(hb)

		var name: Label = Label.new()
		var race: String = String(row.get("race", "")).capitalize()
		var sex: String = String(row.get("sex", "")).capitalize()
		name.text = "%s  — %s / %s  (Lv 1, %s)" % [
			String(row.get("name", "Nameless")),
			race, sex,
			String(row.get("rarity", "COMMON"))
		]
		name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		hb.add_child(name)

		var btn: Button = Button.new()
		btn.text = "Hire (%dg)" % cost
		btn.disabled = gold < cost
		btn.custom_minimum_size.y = _target_btn_height()
		btn.pressed.connect(_on_hire_pressed.bind(i))
		hb.add_child(btn)

# ---------- Roster rendering ----------
func _render_roster() -> void:
	_clear_children(_roster_v)

	var v: Dictionary = SaveMgr.load_village(slot)
	var npcs_any: Variant = v.get("npcs", [])
	var npcs: Array = (npcs_any as Array) if (npcs_any is Array) else []

	if npcs.is_empty():
		var empty: Label = Label.new()
		empty.text = "No NPCs hired yet."
		_roster_v.add_child(empty)
		return

	# Use live minutes for assigned NPCs
	var rt: Dictionary = TimeService.realtime_snapshot(slot)
	var now_min: float = float(rt.get("combined_min", float(rt.get("meta_total_min", 0.0))))

	for n_any in npcs:
		if not (n_any is Dictionary):
			continue
		var n: Dictionary = n_any

		var block: VBoxContainer = VBoxContainer.new()
		block.add_theme_constant_override("separation", 2)
		block.add_theme_stylebox_override("panel", null)
		_roster_v.add_child(block)

		# Top line: Name — State / Role (Assigned @ iid)
		var top: Label = Label.new()
		var nm: String = String(n.get("name", "Nameless"))
		var state_s: String = String(n.get("state", "IDLE"))
		var role_s: String = String(n.get("role", ""))
		var iid_s: String = String(n.get("assigned_instance_id", ""))
		var role_disp: String = (role_s if role_s != "" else "—")
		var assign_note: String = ((" @ " + iid_s) if iid_s != "" else "")
		top.text = "%s  —  %s / %s%s" % [nm, state_s, role_disp, assign_note]
		top.add_theme_font_size_override("font_size", 14)
		block.add_child(top)

		# Details: live role snapshot if assigned, otherwise show stored role_levels summary
		if iid_s != "":
			var live: Dictionary = NPCXpService.settle_for_instance(StringName(iid_s), now_min, slot)
			if not live.is_empty():
				var lv: int = int(live.get("level", 1))
				var xp: int = int(live.get("xp", 0))
				var nxt: int = int(live.get("xp_next", 1))
				var role_live: String = String(live.get("role", role_disp))
				var det: Label = Label.new()
				det.text = "• %s  L%d   %d / %d" % [role_live, lv, xp, nxt]
				det.add_theme_font_size_override("font_size", 12)
				block.add_child(det)
			else:
				# Fallback to stored roles
				_add_rolelevels_summary(n, block)
		else:
			_add_rolelevels_summary(n, block)

# Helper: add a compact per-role summary for an NPC (stored tracks)
func _add_rolelevels_summary(npc: Dictionary, parent: VBoxContainer) -> void:
	var rl_any: Variant = npc.get("role_levels", {})
	if not (rl_any is Dictionary):
		var det0: Label = Label.new()
		det0.text = "• No role progress"
		det0.add_theme_font_size_override("font_size", 12)
		parent.add_child(det0)
		return

	var rl: Dictionary = rl_any as Dictionary
	# Show up to 3 roles to keep it compact
	var shown: int = 0
	for k_any in rl.keys():
		if shown >= 3:
			break
		var key: String = String(k_any)
		var t_any: Variant = rl.get(key, {})
		if not (t_any is Dictionary):
			continue
		var t: Dictionary = t_any as Dictionary
		var lv_i: int = int(t.get("level", 1))
		var cur_i: int = int(t.get("xp_current", int(t.get("previous_xp", 0))))
		var nxt_i: int = int(t.get("xp_to_next", 1))
		var det: Label = Label.new()
		det.text = "• %s  L%d   %d / %d" % [key, lv_i, cur_i, nxt_i]
		det.add_theme_font_size_override("font_size", 12)
		parent.add_child(det)
		shown += 1

# ---------- Buttons ----------
func _on_refresh_candidates_pressed() -> void:
	print("[CampModal] refresh button pressed")
	_recruit.refresh(slot)
	var restock: Dictionary = _recruit.apply_timed_restock(slot)
	_update_restock_label(restock)
	_render_candidates()
	_apply_mobile_styles()  # ensure newly created Hire buttons get correct height

func _on_refresh_roster_pressed() -> void:
	print("[CampModal] roster refresh pressed")
	_render_roster()

func _on_hire_pressed(rendered_index: int) -> void:
	print("[CampModal] hire pressed rendered_index=", rendered_index)
	var source_index: int = rendered_index
	if rendered_index >= 0 and rendered_index < _render_index_map.size():
		source_index = _render_index_map[rendered_index]
	print("[CampModal] hire source_index (page index)=", source_index, " map=", _render_index_map)

	var hired: Dictionary = _hire.hire(source_index, slot)
	_update_gold_label()
	_render_candidates()
	_apply_mobile_styles()  # re-apply heights after list rebuild
	_render_roster()

func _on_close_pressed() -> void:
	close()

# ---------- Small helpers ----------
func _update_gold_label() -> void:
	var gs: Dictionary = SaveMgr.load_game(slot)
	var gold: int = int(gs.get("stash_gold", 0))
	_gold_label.text = "Stash Gold: %d" % gold

func _clear_children(n: Node) -> void:
	for c in n.get_children():
		c.queue_free()

# ---------- Candidate filtering ----------
static func _candidate_key(d: Dictionary) -> String:
	var id_s: String = String(d.get("id", ""))
	if id_s != "":
		return id_s
	var seed: String = String(d.get("appearance_seed", ""))
	var name: String = String(d.get("name", ""))
	var race: String = String(d.get("race", ""))
	var sex: String  = String(d.get("sex", ""))
	return "%s|%s|%s|%s" % [seed, name, race, sex]

# Returns [filtered_list, index_map] where index_map[i] = original_index_in_page
func _filter_out_hired_with_index_map(page: Array[Dictionary]) -> Array:
	var village: Dictionary = SaveMgr.load_village(slot)
	var owned_keys: Dictionary = {}
	var npcs_any: Variant = village.get("npcs", [])
	if npcs_any is Array:
		for v in (npcs_any as Array):
			if v is Dictionary:
				owned_keys[_candidate_key(v as Dictionary)] = true

	var filtered: Array[Dictionary] = []
	var index_map: Array[int] = []
	for i in page.size():
		var row_any: Variant = page[i]
		if not (row_any is Dictionary):
			continue
		var row: Dictionary = row_any as Dictionary
		var key: String = _candidate_key(row)
		if not owned_keys.has(key):
			filtered.append(row)
			index_map.append(i)

	return [filtered, index_map]

func _update_restock_label(restock_info: Dictionary) -> void:
	if _restock_label == null:
		return
	var remain_min: float = float(restock_info.get("remain_min", 0.0))
	var cadence: int = int(restock_info.get("cadence_min", 720))

	var total_min: int = int(ceil(remain_min))
	var days: int = total_min / (60 * 24)
	var rem_after_days: int = total_min - days * 60 * 24
	var hours: int = rem_after_days / 60
	var mins: int = rem_after_days - hours * 60

	_restock_label.text = "Next timed restock in %dd:%02dh:%02dm (every %dh)" % [
		days, hours, mins, int(cadence / 60)
	]
