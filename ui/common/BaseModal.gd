# res://ui/common/BaseModal.gd
extends Control
class_name BaseModal

signal closed

@export var ui_theme: Theme = preload("res://ui/themes/ModalTheme.tres")
@export var modal_theme: Theme
@export var pause_game: bool = true
@export var dim_backdrop: bool = true
@export var animate: bool = true
@export var panel_path: NodePath = ^"Panel"
@export var use_os_mobile_detection: bool = true
@export var desktop_fill_percent: Vector2 = Vector2(0.72, 0.78)
@export var content_padding_px: int = 14

@export var min_panel_size: Vector2 = Vector2(920, 560)
@export var fullscreen_threshold: Vector2i = Vector2i(1024, 700)
@export var mobile_fill_percent: Vector2 = Vector2(0.90, 0.88)
@export var min_touch_target_px: int = 64
@export var backdrop_color: Color = Color(0, 0, 0, 0.55)

@export_group("Typography")
@export var base_font_desktop_px: int = 19   # was 17
@export var base_font_mobile_px: int = 28    # was 24
@export var title_delta_px: int = 7
@export var button_delta_px: int = 4         # was 3
@export var small_text_delta_px: int = -1
@export var tab_delta_px: int = 2

const DEBUG_MODAL: bool = true
func _dbg(msg: String) -> void:
	if DEBUG_MODAL:
		print("[BaseModal] ", msg)

func _rect_str(r: Rect2) -> String:
	return "pos=" + str(r.position) + " size=" + str(r.size)

var _panel: Control
var _backdrop: ColorRect
var _extra_hit_rects: Array[Rect2] = [] as Array[Rect2]
var _close_button: Button = null

func _ready() -> void:
	if ui_theme != null:
		theme = ui_theme

	process_mode = Node.PROCESS_MODE_ALWAYS
	anchors_preset = Control.PRESET_FULL_RECT
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	z_index = 10000
	visible = false

	if modal_theme != null:
		theme = modal_theme

	_panel = get_node_or_null(panel_path) as Control
	_ensure_backdrop()
	_ensure_close_button()
	set_process_input(true)

func _ensure_backdrop() -> void:
	if is_instance_valid(_backdrop):
		return
	_backdrop = ColorRect.new()
	_backdrop.name = "Backdrop"
	_backdrop.color = backdrop_color
	_backdrop.anchors_preset = Control.PRESET_FULL_RECT
	_backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	_backdrop.visible = false
	add_child(_backdrop)
	move_child(_backdrop, 0)
	if not _backdrop.gui_input.is_connected(_on_backdrop_gui_input):
		_backdrop.gui_input.connect(_on_backdrop_gui_input)

func _on_backdrop_gui_input(e: InputEvent) -> void:
	var mouse: InputEventMouseButton = e as InputEventMouseButton
	var touch: InputEventScreenTouch = e as InputEventScreenTouch
	if (mouse != null and mouse.pressed) or (touch != null and touch.pressed):
		close()

func present(animate: bool = true, pause_game: bool = true) -> void:
	_ensure_backdrop()

	if is_instance_valid(_backdrop):
		_backdrop.visible = true
		var c: Color = backdrop_color
		if not dim_backdrop:
			c.a = 0.0
		_backdrop.color = c

	visible = true
	mouse_filter = Control.MOUSE_FILTER_STOP

	await get_tree().process_frame
	_layout_panel_for_viewport(get_viewport_rect().size)
	_apply_content_padding()
	_apply_typography()
	_try_sync_footer_gap()

	if animate:
		_animate_open()

	if pause_game:
		var tree: SceneTree = get_tree()
		if tree != null:
			tree.paused = true

	_grab_initial_focus()
	on_opened()
	_dbg("present name=" + name)

func close() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	if is_instance_valid(_backdrop):
		_backdrop.visible = false
	var tree: SceneTree = get_tree()
	if tree != null:
		tree.paused = false
	on_closed()
	emit_signal("closed")

func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED and visible:
		_layout_panel_for_viewport(get_viewport_rect().size)
		_apply_content_padding()
		_apply_typography()
		_try_sync_footer_gap()

func _layout_panel_for_viewport(vp: Vector2) -> void:
	if _panel == null:
		_panel = get_node_or_null(panel_path) as Control
	if _panel == null:
		return

	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_panel.top_level = false

	var os_name: String = OS.get_name()
	var is_mobile_os: bool = (OS.has_feature("mobile") or os_name == "Android" or os_name == "iOS"
		or OS.has_feature("android") or OS.has_feature("ios")) if use_os_mobile_detection else false

	var is_mobile: bool = is_mobile_os \
		or (vp.x < float(fullscreen_threshold.x)) \
		or (vp.y < float(fullscreen_threshold.y))

	if is_mobile:
		var target_w: float = clamp(vp.x * mobile_fill_percent.x, 0.0, max(16.0, vp.x - 16.0))
		var target_h: float = clamp(vp.y * mobile_fill_percent.y, 0.0, max(16.0, vp.y - 16.0))
		var target: Vector2 = Vector2(target_w, target_h)

		_panel.set_anchors_preset(Control.PRESET_CENTER)
		_panel.custom_minimum_size = target
		_panel.size = target
		_panel.position = (vp - target) * 0.5
	else:
		_panel.set_anchors_preset(Control.PRESET_CENTER)
		var fill_target: Vector2 = Vector2(vp.x * desktop_fill_percent.x, vp.y * desktop_fill_percent.y)
		var target: Vector2 = Vector2(
			clamp(max(min_panel_size.x, fill_target.x), 0.0, vp.x * 0.96),
			clamp(max(min_panel_size.y, fill_target.y), 0.0, vp.y * 0.96)
		)
		_panel.custom_minimum_size = target
		_panel.size = target
		_panel.position = (vp - target) * 0.5

	_dbg("layout vp=%s is_mobile=%s panel pos=%s size=%s" % [
		str(vp), str(is_mobile), str(_panel.position), str(_panel.size)
	])

	_layout_close_button()

func _animate_open() -> void:
	modulate.a = 0.0
	var tw: Tween = create_tween()
	tw.tween_property(self, "modulate:a", 1.0, 0.12)

func _input(e: InputEvent) -> void:
	if not visible:
		return
	if e.is_action_pressed("ui_cancel"):
		close()
		return

	var mb: InputEventMouseButton = e as InputEventMouseButton
	var st: InputEventScreenTouch = e as InputEventScreenTouch
	if mb != null and mb.pressed:
		var inside_panel: bool = _panel != null and _panel.get_global_rect().has_point(mb.position)
		var inside_extra: bool = false
		for r: Rect2 in _extra_hit_rects:
			if r.has_point(mb.position):
				inside_extra = true
				break
		if not inside_panel and not inside_extra:
			close()
	elif st != null and st.pressed:
		var inside_panel2: bool = _panel != null and _panel.get_global_rect().has_point(st.position)
		var inside_extra2: bool = false
		for r2: Rect2 in _extra_hit_rects:
			if r2.has_point(st.position):
				inside_extra2 = true
				break
		if not inside_panel2 and not inside_extra2:
			close()

func _is_mobile_view() -> bool:
	var vp: Vector2 = get_viewport_rect().size
	var is_mobile_os: bool = false
	if use_os_mobile_detection:
		var os_name: String = OS.get_name()
		is_mobile_os = OS.has_feature("mobile") or os_name == "Android" or os_name == "iOS" \
			or OS.has_feature("android") or OS.has_feature("ios")
	return is_mobile_os or vp.x < float(fullscreen_threshold.x) or vp.y < float(fullscreen_threshold.y)

func _apply_typography() -> void:
	if _panel == null:
		return
	var is_mobile: bool = _is_mobile_view()
	var base_px: int = base_font_mobile_px if is_mobile else base_font_desktop_px
	_apply_font_sizes_to_tree(_panel, base_px)

func _apply_font_sizes_to_tree(root: Control, base_px: int) -> void:
	var stack: Array[Control] = [root]
	while not stack.is_empty():
		var c: Control = stack.pop_back()
		if c is Label:
			var lbl: Label = c
			var nm: String = lbl.name.to_lower()
			var size_px: int = base_px
			if nm.find("title") >= 0 or nm.find("header") >= 0:
				size_px = base_px + title_delta_px
			elif nm.find("hint") >= 0 or nm.find("note") >= 0:
				size_px = max(10, base_px + small_text_delta_px)
			lbl.add_theme_font_size_override("font_size", size_px)
		elif c is Button:
			var btn: Button = c
			btn.add_theme_font_size_override("font_size", base_px + button_delta_px)
			btn.custom_minimum_size.y = float(min_touch_target_px)
		elif c is ItemList:
			var il: ItemList = c
			il.add_theme_font_size_override("font_size", base_px)
		elif c is TabContainer:
			var tc: TabContainer = c
			tc.add_theme_font_size_override("font_size", base_px + tab_delta_px)
		elif c is TabBar:
			var tb: TabBar = c
			tb.add_theme_font_size_override("font_size", base_px + tab_delta_px)

		if _is_mobile_view():
			if c is BoxContainer:
				var bc: BoxContainer = c
				if not bc.has_theme_constant_override("separation"):
					bc.add_theme_constant_override("separation", 6)
			elif c is GridContainer:
				var gc: GridContainer = c
				if not gc.has_theme_constant_override("h_separation"):
					gc.add_theme_constant_override("h_separation", 8)
				if not gc.has_theme_constant_override("v_separation"):
					gc.add_theme_constant_override("v_separation", 6)

		for child in c.get_children():
			var cc: Control = child as Control
			if cc != null:
				stack.append(cc)

func on_opened() -> void: pass
func on_closed() -> void: pass
func _grab_initial_focus() -> void: pass

func _apply_content_padding() -> void:
	var margin: MarginContainer = get_node_or_null(^"Panel/Margin") as MarginContainer
	if margin != null:
		margin.add_theme_constant_override("margin_left",   content_padding_px)
		margin.add_theme_constant_override("margin_top",    content_padding_px)
		margin.add_theme_constant_override("margin_right",  content_padding_px)
		margin.add_theme_constant_override("margin_bottom", content_padding_px)

func _try_sync_footer_gap() -> void:
	var vbox: VBoxContainer = get_node_or_null(^"Panel/Margin/V") as VBoxContainer
	var bottom: Control = get_node_or_null(^"Panel/Margin/V/Bottom") as Control
	if vbox == null or bottom == null:
		return
	var sep: int = 8
	if vbox.has_theme_constant_override("separation"):
		sep = vbox.get_theme_constant("separation")
	bottom.custom_minimum_size.y = float(sep)
	_dbg("sync_footer_gap sep=" + str(sep))

# --- Close button helpers ----------------------------------------------------

func _find_close_button_in_panel() -> Button:
	if _panel == null:
		return null
	var stack: Array[Node] = [_panel]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		var btn: Button = n as Button
		if btn != null and btn.name == "CloseX":
			return btn
		for child in n.get_children():
			stack.append(child)
	return null

func _ensure_close_button() -> void:
	if _panel == null:
		_panel = get_node_or_null(panel_path) as Control
	if _panel == null:
		return

	# Already wired?
	if is_instance_valid(_close_button):
		return

	# 1) Prefer an existing CloseX anywhere under the panel (e.g. Header/CloseX in NewGameFlow)
	var btn: Button = _find_close_button_in_panel()

	# 2) If none, auto-create one as a child of the panel (legacy modals)
	if btn == null:
		btn = Button.new()
		btn.name = "CloseX"
		btn.text = "✕"
		btn.focus_mode = Control.FOCUS_NONE
		btn.mouse_filter = Control.MOUSE_FILTER_STOP
		_panel.add_child(btn)

	_close_button = btn

	# If we auto-created as a direct child of the panel, position it now.
	_layout_close_button()

	if not _close_button.pressed.is_connected(_on_close_button_pressed):
		_close_button.pressed.connect(_on_close_button_pressed)

func _on_close_button_pressed() -> void:
	close()

func _layout_close_button() -> void:
	if _panel == null or _close_button == null:
		return

	# Only reposition buttons that are direct children of the panel.
	# If CloseX lives in a header (e.g. Header/CloseX), let that layout handle it.
	if _close_button.get_parent() != _panel:
		return

	var side: float = float(min_touch_target_px)
	var pad: float = 8.0

	_close_button.anchor_left = 0.0
	_close_button.anchor_right = 0.0
	_close_button.anchor_top = 0.0
	_close_button.anchor_bottom = 0.0

	_close_button.custom_minimum_size = Vector2(side, side)
	_close_button.position = Vector2(
		_panel.size.x - pad - side,
		pad
	)
