# res://scripts/village/modal/BuildingModalShell.gd
extends "res://ui/common/BaseModal.gd"
class_name BuildingModalShell

signal assign_requested(instance_id: StringName, npc_id: StringName)
signal unassign_requested(instance_id: StringName)
signal upgrade_requested(instance_id: StringName)

const _DBG := "[BuildingModalShell] "
const _BTN_MIN_W := 96.0
const _BTN_DEF_H := 44.0
func _log(msg: String) -> void: print(_DBG + msg)

var coord: Vector2i = Vector2i.ZERO
var instance_id: StringName = &""
var slot: int = 1
var building_kind: StringName = &""
var _lbl_gold: Label = null

var _upgrade_ready: bool = false

const _STAFF_BTN_MIN_W := 96.0
const _STAFF_BTN_MIN_H := 32.0
const _ROSTER_MIN_W := 160.0

# Track who is assigned (for portrait/xp panel)
var _assigned_npc_id: StringName = &""

# --- scene refs ---------------------------------------------------------------
@onready var _title: Label = $"Panel/Margin/V/Header/Title"
@onready var _rarity: Label = $"Panel/Margin/V/Header/Rarity"
@onready var _badge_connected: Label = $"Panel/Margin/V/Header/Badges/Connected"
@onready var _badge_staffed: Label = $"Panel/Margin/V/Header/Badges/Staffed"
@onready var _badge_active: Label = $"Panel/Margin/V/Header/Badges/Active"

@onready var _role_lbl: Label = $"Panel/Margin/V/StaffingRow/RoleLbl"
@onready var _roster: OptionButton = $"Panel/Margin/V/StaffingRow/Roster"
@onready var _btn_assign: Button = $"Panel/Margin/V/StaffingRow/BtnAssign"
@onready var _btn_unassign: Button = $"Panel/Margin/V/StaffingRow/BtnUnassign"

@onready var _tabs: TabBar = $"Panel/Margin/V/Tabs"

# Right-side body host
@onready var _body_host: Control = $"Panel/Margin/V/BodyHost/Body"

# Optional Left column (portrait + XP) nodes; safe if missing
@onready var _left_root: VBoxContainer = $"Panel/Margin/V/BodyHost/Left"
@onready var _portrait: TextureRect = $"Panel/Margin/V/BodyHost/Left/Portrait"
@onready var _npc_name: Label = $"Panel/Margin/V/BodyHost/Left/Name"
@onready var _npc_level: Label = $"Panel/Margin/V/BodyHost/Left/Level"
@onready var _npc_xp: Label = $"Panel/Margin/V/BodyHost/Left/XP"

@onready var _btn_close: Button = $"Panel/Margin/V/Footer/Close"
@onready var _primary_actions: HBoxContainer = $"Panel/Margin/V/Footer/PrimaryActions"
@onready var _btn_upgrade: Button = $"Panel/Margin/V/Footer/BtnUpgrade"

var _body: Control = null

# Upgrade panel (created on demand)
var _upgrade_panel: VBoxContainer = null
var _upgrade_tab_idx: int = -1
var _body_tab_count: int = 0

# ---- lifecycle ---------------------------------------------------------------
func _ready() -> void:
	# IMPORTANT: run BaseModal setup (theme, backdrop, mobile layout, typography)
	super._ready()
	_debug_fix_layout_flags()
	_log("ready()")

func present(animate: bool = true, pause_game: bool = true) -> void:
	_log("present(animate=%s, pause=%s)" % [str(animate), str(pause_game)])
	super.present(animate, pause_game)
	_bind_buttons()
	_setup_staffing_row()
	_setup_footer()
	_init_tabs_from_body()

func close() -> void:
	_log("close()")
	super.close()

# ---- public API --------------------------------------------------------------
func set_context(p_coord: Vector2i, p_instance_id: StringName, p_slot: int = 1, p_kind: StringName = &"") -> void:
	coord = p_coord
	instance_id = p_instance_id
	slot = max(1, p_slot)
	building_kind = p_kind
	_log("set_context -> iid=%s kind=%s @ H_%d_%d (slot %d)"
		% [String(instance_id), String(building_kind), coord.x, coord.y, slot])

func set_body(body: Control) -> void:
	_log("set_body(incoming=%s)" % (body.get_class() if body != null else "null"))

	# Resolve BodyHost even if @onready hasn't run yet
	var host := _resolve_body_host()
	if host == null:
		_log("set_body HARD-FAIL: BodyHost not found at Panel/Margin/V/BodyHost/Body")
		return

	# Clean previous body if present
	if is_instance_valid(_body):
		if _body.get_parent() == host:
			host.remove_child(_body)
		_body.queue_free()
	_body = null

	# Guard input
	if body == null:
		_log("set_body ABORT: body is null")
		return

	# Prepare and parent
	_body = body
	_body.top_level = false
	_body.visible = true
	_body.mouse_filter = Control.MOUSE_FILTER_PASS

	host.add_child(_body)
	_body.set_anchors_preset(Control.PRESET_FULL_RECT)
	_body.offset_left = 0.0
	_body.offset_top  = 0.0
	_body.offset_right = 0.0
	_body.offset_bottom = 0.0

	# Bind + context + enter
	if _body.has_method("bind_shell"):
		_body.call("bind_shell", self)
	if _body.has_method("set_context"):
		_body.call("set_context", building_kind, instance_id, coord, slot)
	if _body.has_method("enter"):
		_body.call("enter", _build_body_ctx())

	_dump_host_children()
	_refresh_footer_actions(_build_body_ctx())

	_log("set_body -> %s (host_children=%d)" % [_body.get_class(), host.get_child_count()])

# ---- wiring ------------------------------------------------------------------
func _bind_buttons() -> void:
	if _btn_close != null and not _btn_close.pressed.is_connected(close):
		_btn_close.pressed.connect(close)
	if _btn_upgrade != null and not _btn_upgrade.pressed.is_connected(_on_upgrade_button):
		_btn_upgrade.pressed.connect(_on_upgrade_button)
	if _btn_assign != null and not _btn_assign.pressed.is_connected(_on_assign_clicked):
		_btn_assign.pressed.connect(_on_assign_clicked)
	if _btn_unassign != null and not _btn_unassign.pressed.is_connected(_on_unassign_clicked):
		_btn_unassign.pressed.connect(_on_unassign_clicked)
	_log("_bind_buttons -> wired close/upgrade/assign/unassign")

func _setup_footer() -> void:
	var target_h := float(min_touch_target_px if _is_mobile_view() else _BTN_DEF_H)
	if _btn_close:
		_btn_close.text = "Close"
		_btn_close.custom_minimum_size = Vector2(_BTN_MIN_W, target_h)
	if _btn_upgrade:
		_btn_upgrade.text = "Upgrade"
		_btn_upgrade.custom_minimum_size = Vector2(_BTN_MIN_W, target_h)
	if _primary_actions:
		_primary_actions.size_flags_horizontal = Control.SIZE_FILL

	# --- gold label ---
	var footer: HBoxContainer = $"Panel/Margin/V/Footer" as HBoxContainer
	if footer != null and _lbl_gold == null:
		_lbl_gold = Label.new()
		_lbl_gold.name = "StashGold"
		_lbl_gold.text = "Gold: —"
		_lbl_gold.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		footer.add_child(_lbl_gold)
		footer.move_child(_lbl_gold, 0)
		_log("_setup_footer -> added stash gold label")

func _on_upgrade_button() -> void:
	if _upgrade_tab_idx >= 0 and is_instance_valid(_tabs) and _tabs.current_tab == _upgrade_tab_idx and _upgrade_ready:
		_log("upgrade button -> emitting upgrade")
		_emit_upgrade()
		return
	if _upgrade_tab_idx >= 0 and is_instance_valid(_tabs):
		_log("upgrade button -> switching to tab %d" % _upgrade_tab_idx)
		_tabs.current_tab = _upgrade_tab_idx
		_on_tab_changed(_upgrade_tab_idx)

func _emit_upgrade() -> void:
	_log("upgrade click (emit)")
	emit_signal("upgrade_requested", instance_id)

func _on_assign_clicked() -> void:
	var sel_id := _selected_npc_id()
	if String(sel_id) == "" or sel_id == _assigned_npc_id:
		_log("assign click -> no-op (empty or already current)")
		return
	_log("assign click -> %s" % String(sel_id))
	emit_signal("assign_requested", instance_id, sel_id)

func _on_unassign_clicked() -> void:
	var sel_id := _selected_npc_id()
	if String(_assigned_npc_id) == "" or sel_id != _assigned_npc_id:
		_log("unassign click -> no-op (no current or selection not current)")
		return
	_log("unassign click")
	emit_signal("unassign_requested", instance_id)

# ---- tabs --------------------------------------------------------------------
func _init_tabs_from_body() -> void:
	if _tabs == null:
		return
	_tabs.clear_tabs()
	var names: PackedStringArray = []

	if _body != null and _body.has_method("get_tabs"):
		var got: Variant = _body.call("get_tabs")
		if typeof(got) == TYPE_PACKED_STRING_ARRAY:
			names = got

	for n in names:
		_tabs.add_tab(n)
	_body_tab_count = max(0, names.size())

	_tabs.add_tab("Upgrades")
	_upgrade_tab_idx = _body_tab_count

	_tabs.current_tab = 0
	if not _tabs.tab_selected.is_connected(_on_tab_changed):
		_tabs.tab_selected.connect(_on_tab_changed)

	_log("tabs init -> body=%d, upgrade_idx=%d, total=%d"
		% [_body_tab_count, _upgrade_tab_idx, _tabs.tab_count])

	if _body != null and _body.has_method("on_tab_changed"):
		_body.call("on_tab_changed", 0)
	_show_upgrade_panel(false)

func _on_tab_changed(idx: int) -> void:
	_log("tab -> %d" % idx)
	if idx == _upgrade_tab_idx:
		_show_upgrade_panel(true)
		_refresh_upgrade_panel()
		return

	_show_upgrade_panel(false)
	if _body != null and _body.has_method("on_tab_changed"):
		_body.call("on_tab_changed", idx)

func _show_upgrade_panel(show: bool) -> void:
	if show:
		if not is_instance_valid(_upgrade_panel):
			_upgrade_panel = _create_upgrade_panel()
			_body_host.get_parent().add_child(_upgrade_panel)
			_upgrade_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
			_log("created upgrade panel")
		if is_instance_valid(_body):
			_body.visible = false
		_upgrade_panel.visible = true
	else:
		if is_instance_valid(_upgrade_panel):
			_upgrade_panel.visible = false
		if is_instance_valid(_body):
			_body.visible = true

func _create_upgrade_panel() -> VBoxContainer:
	var vb := VBoxContainer.new()
	vb.name = "UpgradePanel"
	vb.size_flags_horizontal = Control.SIZE_FILL | Control.SIZE_EXPAND
	vb.size_flags_vertical   = Control.SIZE_FILL | Control.SIZE_EXPAND

	var title := Label.new()
	title.name = "Title"
	title.text = "Upgrade"
	vb.add_child(title)

	var rarity := Label.new()
	rarity.name = "Rarity"
	vb.add_child(rarity)

	var reqs := VBoxContainer.new()
	reqs.name = "Requirements"
	vb.add_child(reqs)

	var reasons := VBoxContainer.new()
	reasons.name = "DisabledReasons"
	vb.add_child(reasons)

	var hint := Label.new()
	hint.name = "Hint"
	hint.text = "(Press the Upgrade button when available.)"
	vb.add_child(hint)

	return vb

func _refresh_upgrade_panel() -> void:
	if not is_instance_valid(_upgrade_panel):
		return
	var svc := _find_modal_service()
	var info: Dictionary = {}
	if svc != null and svc.has_method("get_upgrade_info"):
		info = svc.call("get_upgrade_info", instance_id)

	var rarity_val := String(info.get("current_rarity", ""))
	var reqs: Dictionary = info.get("upgrade_requirements", {})
	var disabled: bool = bool(info.get("disabled", true))
	var reasons: Array = info.get("reasons", [])

	var rarity_lbl := _upgrade_panel.get_node_or_null("Rarity") as Label
	if rarity_lbl:
		rarity_lbl.text = "Current rarity: " + rarity_val

	var reqs_box := _upgrade_panel.get_node_or_null("Requirements") as VBoxContainer
	if reqs_box:
		for c in reqs_box.get_children(): c.queue_free()
		var r_gold := int(reqs.get("gold", 0))
		var r_shards := int(reqs.get("shards", 0))
		var r_qgate := String(reqs.get("quest_gate", ""))
		var l := Label.new()
		l.text = "Requires: %d gold, %d shards%s" % [
			r_gold, r_shards,
			(" + quest: " + r_qgate) if r_qgate != "" else ""
		]
		reqs_box.add_child(l)

	var reasons_box := _upgrade_panel.get_node_or_null("DisabledReasons") as VBoxContainer
	if reasons_box:
		for c in reasons_box.get_children(): c.queue_free()
		if disabled:
			var head := Label.new(); head.text = "Not available:"
			reasons_box.add_child(head)
			for r_any in reasons:
				var r := String(r_any)
				var rl := Label.new(); rl.text = "• " + r
				reasons_box.add_child(rl)
		else:
			var ok := Label.new(); ok.text = "Ready to upgrade."
			reasons_box.add_child(ok)

	_upgrade_ready = not disabled
	_update_upgrade_button_state(disabled)
	_log("_refresh_upgrade_panel -> disabled=%s reasons=%d ready=%s" % [str(disabled), reasons.size(), str(_upgrade_ready)])

	if is_instance_valid(_btn_upgrade):
		_btn_upgrade.text = "Upgrade" if _upgrade_ready else "View Upgrade"

# ---- refresh model -----------------------------------------------------------
func refresh_all() -> void:
	_log("refresh_all() begin")
	var svc := _find_modal_service()

	var header: Dictionary = {}
	var staffing: Dictionary = {}
	var body_ctx: Dictionary = {}

	if svc != null:
		if svc.has_method("get_tile_header"):
			header = svc.call("get_tile_header", instance_id)
		if svc.has_method("get_staffing"):
			staffing = svc.call("get_staffing", instance_id)

	body_ctx = _resolve_ctx_for_body()

	_apply_header(header)
	_apply_staffing(staffing)

	var gold_val: int = int(body_ctx.get("stash_gold", 0))
	if is_instance_valid(_lbl_gold):
		_lbl_gold.text = "Gold: %d" % gold_val
		_log("_footer_gold -> %d" % gold_val)

	if _body != null and _body.has_method("refresh"):
		_body.call("refresh", body_ctx)

	if is_instance_valid(_primary_actions):
		_refresh_footer_actions(body_ctx)

	_log("refresh_all() end")

func _resolve_ctx_for_body() -> Dictionary:
	var svc := _find_modal_service()
	if svc == null:
		return {}
	var key := "vendor"
	if _body != null and _body.has_method("get_ctx_key"):
		var k: Variant = _body.call("get_ctx_key")
		if typeof(k) == TYPE_STRING and String(k) != "":
			key = String(k)
	match key:
		"training":
			if svc.has_method("get_training_ctx"):
				return svc.call("get_training_ctx", instance_id)
		_:
			if svc.has_method("get_vendor_ctx"):
				return svc.call("get_vendor_ctx", instance_id)
	return {}

func _build_body_ctx() -> Dictionary:
	var ctx := _resolve_ctx_for_body()
	if ctx.is_empty():
		return { "stock": [], "sellables": [], "stash_gold": 0, "active": true }
	return ctx

func _apply_header(h: Dictionary) -> void:
	if _title:  _title.text = String(h.get("display_name", ""))
	if _rarity: _rarity.text = String(h.get("rarity", ""))
	if _badge_connected:
		_badge_connected.text = "Connected ✓" if bool(h.get("connected", false)) else "Disconnected"
	if _badge_active:
		_badge_active.text = "Active" if bool(h.get("active", false)) else "Inactive"
	_log("_apply_header -> name=%s rarity=%s" % [_title.text, _rarity.text])

func _apply_staffing(s: Dictionary) -> void:
	if _role_lbl:
		_role_lbl.text = "Staff: " + String(s.get("role_required", "—"))

	_assigned_npc_id = StringName(String(s.get("current_npc_id", "")))

	var select_idx := -1
	if _roster:
		_roster.clear()
		var roster: Array = s.get("roster", [])
		var i := 0
		for row_any in roster:
			if typeof(row_any) != TYPE_DICTIONARY:
				continue
			var row: Dictionary = row_any
			var name := String(row.get("name", "—"))
			var id_sname := StringName(String(row.get("id", "")))

			_roster.add_item(name, i)
			_roster.set_item_metadata(i, id_sname)

			if id_sname == _assigned_npc_id:
				select_idx = i
			i += 1

	var staffed := String(_assigned_npc_id) != ""
	if _badge_staffed:
		_badge_staffed.text = "Staffed ✓" if staffed else "Staffed —"

	if _roster.get_item_count() > 0:
		if select_idx >= 0:
			_roster.select(select_idx)
		elif _roster.get_selected() < 0:
			_roster.select(0)

	_refresh_staff_buttons()

	if staffed:
		_refresh_npc_panel(_assigned_npc_id)
	else:
		_clear_npc_panel()

	_log("_apply_staffing -> roster=%d assigned=%s"
		% [_roster.get_item_count(), String(_assigned_npc_id)])

# ---- footer primary actions --------------------------------------------------
func _refresh_footer_actions(ctx: Dictionary) -> void:
	if not is_instance_valid(_primary_actions):
		return
	for ch in _primary_actions.get_children():
		if ch != _btn_upgrade and ch != _btn_close:
			ch.queue_free()

	var actions: Array = []
	if _body != null and _body.has_method("get_footer_actions"):
		var v: Variant = _body.call("get_footer_actions")
		if typeof(v) == TYPE_ARRAY:
			actions = v as Array

	var added := 0
	for a_any in actions:
		if typeof(a_any) != TYPE_DICTIONARY:
			continue
		var a: Dictionary = a_any
		var id := String(a.get("id", ""))
		var label := String(a.get("label", id))
		var enabled := bool(a.get("enabled", true))

		var b := Button.new()
		var target_h := float(min_touch_target_px if _is_mobile_view() else _BTN_DEF_H)
		b.text = label
		b.custom_minimum_size = Vector2(_BTN_MIN_W, target_h)
		b.disabled = not enabled
		b.pressed.connect(_on_primary_action.bind(StringName(id)))

		var insert_idx := _primary_actions.get_child_count()
		if is_instance_valid(_btn_upgrade):
			insert_idx = max(0, _primary_actions.get_children().find(_btn_upgrade))
		_primary_actions.add_child(b)
		_primary_actions.move_child(b, insert_idx)
		added += 1

	_log("_refresh_footer_actions -> added=%d" % added)

func _on_primary_action(action_id: StringName) -> void:
	_log("primary action -> %s" % String(action_id))
	match String(action_id):
		"open_feature":
			if is_instance_valid(_tabs):
				var buy_idx := 1  # Status=0, Buy=1, Sell=2
				_tabs.current_tab = buy_idx
				_on_tab_changed(buy_idx)
		"start_training":
			if is_instance_valid(_tabs):
				var idx := 1  # Status=0, Training=1
				_tabs.current_tab = idx
				_on_tab_changed(idx)
		_:
			if _body != null and _body.has_method("on_primary_action"):
				_body.call("on_primary_action", action_id)

# ---- left column (portrait + XP) --------------------------------------------
func _refresh_npc_panel(npc_id: StringName) -> void:
	if not is_instance_valid(_left_root):
		return
	var svc := _find_modal_service()
	if svc == null or not svc.has_method("get_npc_snapshot"):
		_clear_npc_panel(); return
	var snap: Dictionary = svc.call("get_npc_snapshot", npc_id)
	_set_label(_npc_name, String(snap.get("name", "—")))
	_set_label(_npc_level, "Lv %d" % int(snap.get("level", 1)))
	var xp: int = int(snap.get("xp", 0))
	var xp_next: int = int(snap.get("xp_next", 1))
	_set_label(_npc_xp, "XP %d / %d" % [xp, xp_next])

	if is_instance_valid(_portrait):
		var tex: Texture2D = null
		var tex_any: Variant = snap.get("portrait_tex", null)
		if tex_any is Texture2D:
			tex = tex_any as Texture2D
		_portrait.texture = tex
	_log("_refresh_npc_panel -> %s lv=%s" % [_npc_name.text, _npc_level.text])

func _clear_npc_panel() -> void:
	_set_label(_npc_name, "—")
	_set_label(_npc_level, "")
	_set_label(_npc_xp, "")
	if is_instance_valid(_portrait):
		_portrait.texture = null

func _set_label(lbl: Label, text: String) -> void:
	if is_instance_valid(lbl):
		lbl.text = text

# ---- upgrade helpers ---------------------------------------------------------
func _recheck_upgrade_state() -> void:
	var svc := _find_modal_service()
	if svc == null or not svc.has_method("get_upgrade_info"):
		return
	var info: Dictionary = svc.call("get_upgrade_info", instance_id)
	_update_upgrade_button_state(bool(info.get("disabled", true)))
	_log("_recheck_upgrade_state -> disabled=%s" % str(bool(info.get("disabled", true))))

func _update_upgrade_button_state(disabled: bool) -> void:
	if is_instance_valid(_btn_upgrade):
		_btn_upgrade.disabled = disabled
		_log("_update_upgrade_button_state -> %s" % ("disabled" if disabled else "enabled"))

# ---- helpers -----------------------------------------------------------------
func _debug_fix_layout_flags() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var panel_ctrl: Control = $"Panel" as Control
	var margin_ctrl: Control = $"Panel/Margin" as Control
	if panel_ctrl: panel_ctrl.set_anchors_preset(Control.PRESET_FULL_RECT)
	if margin_ctrl: margin_ctrl.set_anchors_preset(Control.PRESET_FULL_RECT)

	var vbox: VBoxContainer = $"Panel/Margin/V" as VBoxContainer
	if vbox:
		vbox.size_flags_horizontal = Control.SIZE_FILL | Control.SIZE_EXPAND
		vbox.size_flags_vertical   = Control.SIZE_FILL | Control.SIZE_EXPAND

	var header: HBoxContainer = $"Panel/Margin/V/Header" as HBoxContainer
	var staff:  HBoxContainer = $"Panel/Margin/V/StaffingRow" as HBoxContainer
	if header: header.size_flags_horizontal = Control.SIZE_FILL
	if staff:  staff.size_flags_horizontal  = Control.SIZE_FILL

	var tabs_ctrl: TabBar = $"Panel/Margin/V/Tabs" as TabBar
	if tabs_ctrl:
		tabs_ctrl.size_flags_horizontal = Control.SIZE_FILL
		tabs_ctrl.custom_minimum_size.y = float(min_touch_target_px if _is_mobile_view() else 36)

	var body_host_container: Control = $"Panel/Margin/V/BodyHost" as Control
	if body_host_container:
		body_host_container.size_flags_horizontal = Control.SIZE_FILL
		body_host_container.size_flags_vertical   = Control.SIZE_FILL | Control.SIZE_EXPAND
		var body_ctrl: Control = body_host_container.get_node_or_null("Body") as Control
		if body_ctrl:
			body_ctrl.set_anchors_preset(Control.PRESET_FULL_RECT)
			body_ctrl.offset_left = 0.0
			body_ctrl.offset_top = 0.0
			body_ctrl.offset_right = 0.0
			body_ctrl.offset_bottom = 0.0

	var footer: HBoxContainer = $"Panel/Margin/V/Footer" as HBoxContainer
	if footer:
		footer.size_flags_horizontal = Control.SIZE_FILL
		footer.custom_minimum_size.y = float(min_touch_target_px if _is_mobile_view() else 48.0)

func _find_modal_service() -> Object:
	var tree := get_tree()
	if tree == null:
		return null
	var nodes := tree.get_nodes_in_group("village_modal_service")
	if nodes.size() > 0:
		return nodes[0]
	return tree.get_root().get_node_or_null("TileModalService")

func _setup_staffing_row() -> void:
	if is_instance_valid(_roster):
		var h := float(min_touch_target_px if _is_mobile_view() else _STAFF_BTN_MIN_H)
		_roster.custom_minimum_size = Vector2(_ROSTER_MIN_W, h)
		if not _roster.item_selected.is_connected(_on_roster_changed):
			_roster.item_selected.connect(_on_roster_changed)

	if is_instance_valid(_btn_assign):
		if _btn_assign.text.strip_edges() == "":
			_btn_assign.text = "Assign"
		_btn_assign.custom_minimum_size = Vector2(
			_STAFF_BTN_MIN_W,
			float(min_touch_target_px if _is_mobile_view() else _STAFF_BTN_MIN_H)
		)

	if is_instance_valid(_btn_unassign):
		if _btn_unassign.text.strip_edges() == "":
			_btn_unassign.text = "Unassign"
		_btn_unassign.custom_minimum_size = Vector2(
			_STAFF_BTN_MIN_W,
			float(min_touch_target_px if _is_mobile_view() else _STAFF_BTN_MIN_H)
		)

func _selected_npc_id() -> StringName:
	var idx := _roster.get_selected()
	if idx < 0:
		return StringName("")
	var md: Variant = _roster.get_item_metadata(idx)
	if typeof(md) == TYPE_STRING_NAME:
		return md as StringName
	if typeof(md) == TYPE_STRING:
		return StringName(md as String)
	return StringName("")

func _refresh_staff_buttons() -> void:
	var cur := String(_assigned_npc_id)
	var sel := String(_selected_npc_id())
	var has_sel := sel != ""
	var is_current := has_sel and (sel == cur)

	if is_instance_valid(_btn_assign):
		_btn_assign.disabled = (not has_sel) or is_current

	if is_instance_valid(_btn_unassign):
		_btn_unassign.disabled = (cur == "") or (not is_current)

func _on_roster_changed(_idx: int) -> void:
	_refresh_staff_buttons()

func _dump_host_children() -> void:
	var host := _resolve_body_host()
	if host == null:
		_log("BodyHost dump: host=null")
		return
	var c := host.get_child_count()
	_log("BodyHost children=%d" % c)
	for i in c:
		var n: Node = host.get_child(i)
		_log("  [%d] %s name=%s" % [i, n.get_class(), n.name])

func _resolve_body_host() -> Control:
	if is_instance_valid(_body_host):
		return _body_host
	var n := get_node_or_null("Panel/Margin/V/BodyHost/Body")
	if n is Control:
		_body_host = n as Control
		return _body_host
	return null
