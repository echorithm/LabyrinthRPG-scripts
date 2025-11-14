extends "res://ui/common/BaseModal.gd"
class_name NewGameFlow

const DEBUG: bool = true
func _dbg(msg: String) -> void:
	if DEBUG:
		print("[NewGameFlow] ", msg)

# Centered “sheet” size for mobile
const MODAL_W_PCT: float = 0.92
const MODAL_H_PCT: float = 0.78

const PATH_DIFF: String = "res://ui/menu/new_game/DifficultySelectPanel.tscn"
const PATH_WEAP: String = "res://ui/menu/new_game/WeaponSelectPanel.tscn"
const PATH_ELEM: String = "res://ui/menu/new_game/ElementSelectPanel.tscn"
const PATH_SUMM: String = "res://ui/menu/new_game/SummaryConfirmPanel.tscn"
const PATH_LOADING: String = "res://ui/common/LoadingScreen.tscn"

@onready var _title: Label = $MarginContainer/VBoxContainer/Header/Title
@onready var _step_indicator: HBoxContainer = $MarginContainer/VBoxContainer/Header/StepIndicator
@onready var _panel_root: MarginContainer = $MarginContainer
@onready var _content_panel: PanelContainer = $MarginContainer/VBoxContainer/ContentHost
@onready var _step_host: Control = $MarginContainer/VBoxContainer/ContentHost/StepHost
@onready var _btn_back: Button = $MarginContainer/VBoxContainer/Footer/btn_back
@onready var _btn_skip_tutorial: Button = $MarginContainer/VBoxContainer/Footer/btn_skip_tutorial
@onready var _btn_next: Button = $MarginContainer/VBoxContainer/Footer/btn_next

var _svc: NewGameService = NewGameService.new()
var _panels: Array[Control] = [] as Array[Control]
var _step: int = 0
var _skip_tutorial: bool = false

func _ready() -> void:
	modal_theme = preload("res://ui/themes/ModalTheme.tres")
	panel_path = ^"MarginContainer"  # treat MarginContainer as the modal panel
	super._ready()

	_apply_layout()
	_center_modal_panel()

	_build_steps()
	_step_indicator.visible = false  # keep minimal; easy to re-enable later

	if not _btn_back.pressed.is_connected(_on_back):
		_btn_back.pressed.connect(_on_back)
	if not _btn_next.pressed.is_connected(_on_next):
		_btn_next.pressed.connect(_on_next)
	if not _btn_skip_tutorial.pressed.is_connected(_on_toggle_skip):
		_btn_skip_tutorial.pressed.connect(_on_toggle_skip)

	var vp: Viewport = get_viewport()
	if vp != null and not vp.size_changed.is_connected(_on_vp_resized):
		vp.size_changed.connect(_on_vp_resized)

	_refresh_ui()
	_snapshot("ready")

func on_opened() -> void:
	_reset_flow_state()
	_set_phase_menu()
	if is_instance_valid(_btn_next):
		_btn_next.grab_focus()
	_dbg("opened")

func on_closed() -> void:
	_dbg("closed")

# ---------------- reset / init ----------------
func _reset_flow_state() -> void:
	_svc.reset()
	_skip_tutorial = false
	_step = 0

	if _panels.size() >= 4:
		(_panels[0] as DifficultySelectPanel).set_selected(_svc.difficulty_code)
		(_panels[1] as WeaponSelectPanel).set_selected(_svc.weapon_family)
		(_panels[2] as ElementSelectPanel).set_selected(_svc.element_id)
		(_panels[3] as SummaryConfirmPanel).refresh_from_service(_svc)
		(_panels[3] as SummaryConfirmPanel).set_start_tutorial(true)

	_refresh_ui()

# ---------------- layout / cosmetics ----------------
func _apply_layout() -> void:
	if _panel_root != null:
		_panel_root.add_theme_constant_override("margin_left", 24)
		_panel_root.add_theme_constant_override("margin_right", 24)
		_panel_root.add_theme_constant_override("margin_top", 24)
		_panel_root.add_theme_constant_override("margin_bottom", 24)

	var vb: VBoxContainer = $MarginContainer/VBoxContainer
	if vb != null and not vb.has_theme_constant_override("separation"):
		vb.add_theme_constant_override("separation", 16)

	var header: HBoxContainer = $MarginContainer/VBoxContainer/Header
	if header != null and not header.has_theme_constant_override("separation"):
		header.add_theme_constant_override("separation", 14)

	if _content_panel != null:
		var sb: StyleBoxFlat = StyleBoxFlat.new()
		sb.bg_color = Color(0.059, 0.063, 0.078, 0.94)
		sb.border_color = Color(1, 1, 1, 0.12)
		sb.border_width_left = 1
		sb.border_width_top = 1
		sb.border_width_right = 1
		sb.border_width_bottom = 1
		sb.corner_radius_top_left = 12
		sb.corner_radius_top_right = 12
		sb.corner_radius_bottom_left = 12
		sb.corner_radius_bottom_right = 12
		sb.shadow_color = Color(0, 0, 0, 0.55)
		sb.shadow_size = 18
		sb.shadow_offset = Vector2(0, 6)
		_content_panel.add_theme_stylebox_override("panel", sb)
		_content_panel.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		_content_panel.size_flags_vertical = Control.SIZE_SHRINK_CENTER

	var footer: HBoxContainer = $MarginContainer/VBoxContainer/Footer
	if footer != null and not footer.has_theme_constant_override("separation"):
		footer.add_theme_constant_override("separation", 10)

	# Mobile-friendly button heights
	var vp: Vector2 = get_viewport_rect().size
	var min_h: float = clamp(vp.y * 0.07, 48.0, 72.0)
	_btn_back.custom_minimum_size.y = min_h
	_btn_skip_tutorial.custom_minimum_size.y = min_h
	_btn_next.custom_minimum_size.y = min_h
	_btn_back.text = "Back"
	_btn_back.custom_minimum_size.x = 120.0

func _center_modal_panel() -> void:
	if _panel_root == null:
		return
	var vp: Vector2 = get_viewport_rect().size
	var w: float = clamp(vp.x * MODAL_W_PCT, 540.0, vp.x - 24.0)
	var h: float = clamp(vp.y * MODAL_H_PCT, 420.0, vp.y - 24.0)

	_panel_root.anchor_left = 0.5
	_panel_root.anchor_right = 0.5
	_panel_root.anchor_top = 0.5
	_panel_root.anchor_bottom = 0.5
	_panel_root.offset_left = -w * 0.5
	_panel_root.offset_right =  w * 0.5
	_panel_root.offset_top =  -h * 0.5
	_panel_root.offset_bottom = h * 0.5

	# Also constrain the inner content panel to that size (shrink-center)
	_content_panel.custom_minimum_size = Vector2(w - 48.0, h - 140.0)

	if DEBUG:
		_dbg("center modal w=%.0f h=%.0f vp=%s" % [w, h, str(vp)])

func _on_vp_resized() -> void:
	_center_modal_panel()

# ---------------- step construction ----------------
func _build_steps() -> void:
	for c: Node in _step_host.get_children():
		c.queue_free()
	_panels.clear()

	var scenes: Array[String] = [PATH_DIFF, PATH_WEAP, PATH_ELEM, PATH_SUMM]
	for p: String in scenes:
		if not ResourceLoader.exists(p):
			_dbg("MISSING scene: " + p)
			continue
		var sc: PackedScene = load(p) as PackedScene
		if sc == null:
			continue
		var inst: Control = sc.instantiate() as Control
		if inst == null:
			continue
		inst.set_anchors_preset(Control.PRESET_FULL_RECT)
		inst.offset_left = 0.0
		inst.offset_top = 0.0
		inst.offset_right = 0.0
		inst.offset_bottom = 0.0
		inst.visible = false
		inst.modulate.a = 0.0
		_step_host.add_child(inst)
		_panels.append(inst)

	if _panels.size() >= 4:
		(_panels[0] as DifficultySelectPanel).set_selected(_svc.difficulty_code)
		(_panels[1] as WeaponSelectPanel).set_selected(_svc.weapon_family)
		(_panels[2] as ElementSelectPanel).set_selected(_svc.element_id)
		(_panels[3] as SummaryConfirmPanel).refresh_from_service(_svc)

# ---------------- UI refresh / transitions ----------------
func _refresh_ui() -> void:
	for i: int in range(_panels.size()):
		var vis: bool = (i == _step)
		if vis and not _panels[i].visible:
			_panels[i].visible = true
			_panels[i].modulate.a = 0.0
			var tw_in: Tween = create_tween()
			tw_in.tween_property(_panels[i], "modulate:a", 1.0, 0.12)
		elif (not vis) and _panels[i].visible:
			var tw_out: Tween = create_tween()
			tw_out.tween_property(_panels[i], "modulate:a", 0.0, 0.12)
			tw_out.finished.connect(_hide_step.bind(_panels[i]))

	_title.text = _step_title()
	_btn_back.disabled = (_step == 0)
	_btn_next.text = "Start" if _step == (_panels.size() - 1) else "Next"
	_btn_skip_tutorial.text = "Skip Tutorial: ON" if _skip_tutorial else "Skip Tutorial: OFF"

	if DEBUG:
		_dbg("UI: step=%d title=%s skip=%s" % [_step, _title.text, str(_skip_tutorial)])

	if _step == 3 and _panels.size() >= 4:
		var s: SummaryConfirmPanel = _panels[3] as SummaryConfirmPanel
		s.refresh_from_service(_svc)
		s.set_start_tutorial(not _skip_tutorial)

func _hide_step(node: Node) -> void:
	var c: Control = node as Control
	if c != null:
		c.visible = false

func _step_title() -> String:
	match _step:
		0: return "Choose Difficulty"
		1: return "Choose Weapon"
		2: return "Choose Element"
		3: return "Confirm"
		_: return "New Game"

# ---------------- buttons / actions ----------------
func _on_back() -> void:
	if _step > 0:
		_step -= 1
		_dbg("back → step=" + str(_step))
		_refresh_ui()

func _on_next() -> void:
	match _step:
		0:
			var p0: DifficultySelectPanel = _panels[0] as DifficultySelectPanel
			_svc.set_difficulty(p0.get_selected())
			_step += 1
		1:
			var p1: WeaponSelectPanel = _panels[1] as WeaponSelectPanel
			_svc.set_weapon(p1.get_selected())
			_step += 1
		2:
			var p2: ElementSelectPanel = _panels[2] as ElementSelectPanel
			_svc.set_element(p2.get_selected())
			_step += 1
		3:
			var start_tut: bool = not _skip_tutorial
			var slot: int = _first_empty_slot_fallback()
			if "first_empty_slot" in SlotService:
				slot = int(SlotService.first_empty_slot())
			_dbg("commit: slot=%d start_tutorial=%s" % [slot, str(start_tut)])

			var rc: Dictionary = _svc.commit_new_game(slot, start_tut)
			_dbg("commit rc=" + str(rc))

			if bool(rc.get("ok", false)):
				var scene_path: String = String(rc.get("start_scene", ""))
				if not scene_path.is_empty():
					_set_phase_game()
					var tree: SceneTree = get_tree()
					if tree.paused:
						tree.paused = false
					if start_tut:
						tree.change_scene_to_file(scene_path)  # tutorial first
					else:
						_go_via_loading(scene_path)            # direct to village through loader
					close()
					return
			_title.text = "Failed to create save"
	_refresh_ui()

func _on_toggle_skip() -> void:
	_skip_tutorial = not _skip_tutorial
	_dbg("skip_tutorial=" + str(_skip_tutorial))
	_refresh_ui()

# ---------------- helpers ----------------
func _go_via_loading(target_path: String) -> void:
	var tree: SceneTree = get_tree()
	tree.set_meta("loading_target_path", target_path)
	var has_loading: bool = ResourceLoader.exists(PATH_LOADING)
	if has_loading:
		tree.change_scene_to_file(PATH_LOADING)
	else:
		tree.change_scene_to_file(target_path)

func _first_empty_slot_fallback() -> int:
	if "list_present_slots" in SaveManager and "meta_exists" in SaveManager and "run_exists" in SaveManager:
		var max_slots: int = 12
		var present: Array[int] = SaveManager.list_present_slots(max_slots)
		for i: int in range(1, max_slots + 1):
			if not present.has(i):
				return i
	return 1

func _set_phase_menu() -> void:
	var ap: Node = get_node_or_null(^"/root/AppPhase")
	if ap != null and ap.has_method("to_menu"):
		ap.call("to_menu")

func _set_phase_game() -> void:
	var ap: Node = get_node_or_null(^"/root/AppPhase")
	if ap != null and ap.has_method("to_game"):
		ap.call("to_game")

# ---------------- debug ----------------
func _snapshot(stage: String) -> void:
	if not DEBUG:
		return
	var vp: Vector2 = get_viewport_rect().size
	print("[NewGameFlow] snapshot=", stage, " vp=", vp)
	if _content_panel != null:
		print("  ContentHost rect=", _content_panel.get_rect())
	print("  steps=", _panels.size(), " current=", _step)
	for i: int in range(_panels.size()):
		var p: Control = _panels[i]
		print("    step[", i, "] vis=", p.visible, " a=", p.modulate.a)
