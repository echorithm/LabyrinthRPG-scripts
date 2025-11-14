extends Node2D
class_name GestureTutorial

const DEBUG: bool = true
static func _log(s: String) -> void:
	if DEBUG:
		print("[Tutorial] ", s)

# External deps
const OVERLAY_CLASS := preload("res://scripts/combat/ui/GestureOverlay.gd")
const RECOGNIZER: Script = preload("res://scripts/combat/ui/GestureRecognizer.gd")
const SaveManager := preload("res://persistence/SaveManager.gd")

# Scene targets
const PATH_VILLAGE: String = "res://scripts/village/state/VillageHexOverworld2.tscn"
const PATH_LOADING: String = "res://ui/common/LoadingScreen.tscn"

# Tutorial tuning
const PASSES_REQUIRED_PER_ID: int = 3
const DEMO_RESAMPLE_COUNT: int = 48
const PASS_MIN_CONF: float = 0.60  # 60%+ confidence required

# Visual/theming (match Main Menu)
@export var menu_theme: Theme = preload("res://ui/themes/MenuTheme.tres")
@export var accent_color: Color = Color(0.368627, 0.631373, 1.0, 1.0)
const BG_TOP: Color = Color(0.16, 0.17, 0.20, 1.0)
const BG_BOTTOM: Color = Color(0.02, 0.025, 0.03, 1.0)
const SUCCESS_FLASH: Color = Color(0.55, 1.00, 0.65, 1.0)
const LABEL_NORMAL: Color = Color(1, 1, 1, 1)
const FAIL_FLASH: Color = Color(1.00, 0.45, 0.45, 1.0)

# Nodes
@onready var _bg: TextureRect = get_node_or_null(^"Background") as TextureRect
@onready var _ui: CanvasLayer = $UI as CanvasLayer
@onready var _vbox_title: VBoxContainer = $UI/VBoxContainer as VBoxContainer
@onready var _center: Control = $UI/CenterContainer as Control
@onready var _footer: Control = $UI/Footer as Control

@onready var _title: Label = $UI/VBoxContainer/Title as Label
@onready var _inst: Label = $UI/VBoxContainer/Instruction as Label

@onready var _ability_name: Label = $UI/CenterContainer/AbilityName as Label
@onready var _example_canvas: Control = $UI/CenterContainer/GestureExampleCanvas as Control
@onready var _training_label: Label = $UI/CenterContainer/TrainingAmount as Label
@onready var _test_canvas: Control = $UI/CenterContainer/GestureTestCanvas as Control

@onready var _btn_repeat: Button = $UI/Footer/btn_repeat as Button
@onready var _btn_continue: Button = $UI/Footer/btn_continue as Button
@onready var _sfx: AudioStreamPlayer = $SFX as AudioStreamPlayer

# Preview (white template in the example canvas)
var _preview: Control
var _preview_line: Line2D

# Live overlay (player drawing) inside test canvas
var _overlay: GestureOverlay

# Flow state
var _queue: Array[String] = [] as Array[String]
var _idx: int = 0
var _slot: int = 0
var _passes_done: int = 0

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	RECOGNIZER.ensure_initialized()

	_apply_theme()
	_build_background()

	# Middle column layout
	_ensure_center_stack()

	# Sizing + styling
	_apply_canvas_sizes()
	_style_test_canvas()

	# Preview + overlay
	_ensure_preview_layer()
	_ensure_overlay_layer()

	# Signals
	var vp: Viewport = get_viewport()
	if vp != null and not vp.size_changed.is_connected(_on_viewport_resized):
		vp.size_changed.connect(_on_viewport_resized)

	if not _overlay.submitted.is_connected(_on_submitted):
		_overlay.submitted.connect(_on_submitted)
	if not _overlay.stroke_updated.is_connected(_on_stroke_updated):
		_overlay.stroke_updated.connect(_on_stroke_updated)
	if not _overlay.cleared.is_connected(_on_overlay_cleared):
		_overlay.cleared.connect(_on_overlay_cleared)

	_btn_repeat.text = "Repeat"
	if not _btn_repeat.pressed.is_connected(_on_repeat):
		_btn_repeat.pressed.connect(_on_repeat)
	_btn_continue.text = "Skip Tutorial"
	if not _btn_continue.pressed.is_connected(_finish_to_world):
		_btn_continue.pressed.connect(_finish_to_world)

	# Slot + queue
	var tree: SceneTree = get_tree()
	_slot = (int(tree.get_meta("current_slot")) if tree.has_meta("current_slot") else 1)
	_log("slot=" + str(_slot))

	var gs: Dictionary = SaveManager.load_game(_slot)
	var tut: Dictionary = (gs.get("tutorial", {}) as Dictionary)
	var arr: PackedStringArray = tut.get("queue", PackedStringArray())
	for s0: String in arr:
		_queue.append(s0)
	if _queue.is_empty():
		_queue = ["arc_slash", "heal"] as Array[String]

	_idx = 0
	_passes_done = 0

	# Let containers compute sizes first
	await get_tree().process_frame
	await get_tree().process_frame
	_update_step()
	_dump_rects("post-ready")

	# Also update when the example canvas itself resizes
	if _example_canvas != null and not _example_canvas.resized.is_connected(_on_example_resized):
		_example_canvas.resized.connect(_on_example_resized)

	await get_tree().process_frame
	_dump_rects("post-ready")

# ---------- LOOK & LAYOUT ----------
func _apply_theme() -> void:
	if menu_theme == null:
		return
	if is_instance_valid(_vbox_title):
		_vbox_title.theme = menu_theme
	if is_instance_valid(_center):
		_center.theme = menu_theme
	if is_instance_valid(_footer):
		_footer.theme = menu_theme

func _build_background() -> void:
	if _ui == null:
		return

	# Background under UI CanvasLayer (bottom-most)
	_bg = _ui.get_node_or_null(^"Background") as TextureRect
	if _bg == null:
		var tex: TextureRect = TextureRect.new()
		tex.name = "Background"
		tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_ui.add_child(tex)
		_ui.move_child(tex, 0)
		_bg = tex

	var grad: Gradient = Gradient.new()
	grad.colors = PackedColorArray([BG_TOP, BG_BOTTOM])
	grad.offsets = PackedFloat32Array([0.0, 1.0])

	var gt: GradientTexture2D = GradientTexture2D.new()
	gt.gradient = grad
	gt.fill = GradientTexture2D.FILL_LINEAR
	gt.fill_from = Vector2(0.5, 0.0)
	gt.fill_to = Vector2(0.5, 1.0)
	gt.width = 16
	gt.height = 16

	_bg.texture = gt
	_bg.set_anchors_preset(Control.PRESET_FULL_RECT, true)
	_bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_bg.stretch_mode = TextureRect.STRETCH_SCALE
	_bg.modulate = Color(1, 1, 1, 1)

	# Vignette
	var vignette: ColorRect = _ui.get_node_or_null(^"Vignette") as ColorRect
	if vignette == null:
		var cr: ColorRect = ColorRect.new()
		cr.name = "Vignette"
		cr.color = Color(0, 0, 0, 0.22)
		cr.anchors_preset = Control.PRESET_FULL_RECT
		cr.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_ui.add_child(cr)
		_ui.move_child(cr, 1)

func _ensure_center_stack() -> void:
	# Create a VBox inside CenterContainer, move content into it,
	# center instruction above the ability, and put buttons under the box.
	if _center == null:
		return

	var stack: VBoxContainer = _center.get_node_or_null(^"VBox") as VBoxContainer
	if stack == null:
		stack = VBoxContainer.new()
		stack.name = "VBox"
		stack.set_anchors_preset(Control.PRESET_FULL_RECT, true)
		stack.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		stack.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		stack.add_theme_constant_override("separation", 24)
		stack.alignment = BoxContainer.ALIGNMENT_CENTER
		_center.add_child(stack)

	# Instruction into center stack (will be placed above ability)
	if _inst != null and _inst.get_parent() != stack:
		var p_inst: Node = _inst.get_parent()
		if p_inst != null:
			p_inst.remove_child(_inst)
		stack.add_child(_inst)
	if _inst != null:
		_inst.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_inst.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART

	# Move the four core nodes (in order)
	var order: Array[Node] = [] as Array[Node]
	if _ability_name != null: order.append(_ability_name)
	if _example_canvas != null: order.append(_example_canvas)
	if _training_label != null: order.append(_training_label)
	if _test_canvas != null: order.append(_test_canvas)

	for n: Node in order:
		if n != null and n.get_parent() != stack:
			var oldp: Node = n.get_parent()
			if oldp != null:
				oldp.remove_child(n)
			stack.add_child(n)

	# Place instruction directly before ability name
	if _inst != null and _ability_name != null:
		var children: Array[Node] = stack.get_children()
		var idx_ability: int = -1
		for i: int in range(children.size()):
			if children[i] == _ability_name:
				idx_ability = i
				break
		if idx_ability >= 0:
			stack.move_child(_inst, idx_ability)

	# Center the two labels
	if _ability_name != null:
		_ability_name.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	if _training_label != null:
		_training_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER

	# Buttons row under the draw box
	_ensure_buttons_under_box()

func _apply_canvas_sizes() -> void:
	if _example_canvas != null:
		_example_canvas.custom_minimum_size = Vector2(720, 160)
		_example_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_example_canvas.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		_example_canvas.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	if _test_canvas != null:
		_test_canvas.custom_minimum_size = Vector2(720, 360)
		_test_canvas.mouse_filter = Control.MOUSE_FILTER_PASS
		_test_canvas.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		_test_canvas.size_flags_vertical = Control.SIZE_SHRINK_CENTER

func _style_test_canvas() -> void:
	# Dark panel with accent border (draw area)
	if _test_canvas == null:
		return
	var panel: Panel = _test_canvas.get_node_or_null(^"Back") as Panel
	if panel == null:
		panel = Panel.new()
		panel.name = "Back"
		panel.set_anchors_preset(Control.PRESET_FULL_RECT, true)
		panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_test_canvas.add_child(panel)
		_test_canvas.move_child(panel, 0)

	var sb: StyleBoxFlat = StyleBoxFlat.new()
	sb.bg_color = Color(0.10, 0.11, 0.13, 0.95)
	sb.border_color = accent_color
	sb.border_width_left = 2
	sb.border_width_top = 2
	sb.border_width_right = 2
	sb.border_width_bottom = 2
	sb.corner_radius_top_left = 6
	sb.corner_radius_top_right = 6
	sb.corner_radius_bottom_left = 6
	sb.corner_radius_bottom_right = 6
	panel.add_theme_stylebox_override("panel", sb)

func _ensure_buttons_under_box() -> void:
	if _center == null:
		return
	var stack: VBoxContainer = _center.get_node_or_null(^"VBox") as VBoxContainer
	if stack == null:
		return

	# Row for the buttons (centered)
	var row: HBoxContainer = stack.get_node_or_null(^"ButtonsRow") as HBoxContainer
	if row == null:
		row = HBoxContainer.new()
		row.name = "ButtonsRow"
		row.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		row.add_theme_constant_override("separation", 16)
		row.alignment = BoxContainer.ALIGNMENT_CENTER
		stack.add_child(row)  # appended after test canvas

	# Move buttons into the row
	if _btn_repeat != null and _btn_repeat.get_parent() != row:
		var p3: Node = _btn_repeat.get_parent()
		if p3 != null:
			p3.remove_child(_btn_repeat)
		row.add_child(_btn_repeat)
		_btn_repeat.custom_minimum_size = Vector2(200, 44)
		_btn_repeat.size_flags_horizontal = Control.SIZE_SHRINK_CENTER

	if _btn_continue != null and _btn_continue.get_parent() != row:
		var p4: Node = _btn_continue.get_parent()
		if p4 != null:
			p4.remove_child(_btn_continue)
		row.add_child(_btn_continue)
		_btn_continue.custom_minimum_size = Vector2(200, 44)
		_btn_continue.size_flags_horizontal = Control.SIZE_SHRINK_CENTER

	# Arrow-key focus between buttons
	if _btn_repeat != null and _btn_continue != null:
		_btn_repeat.focus_neighbor_right = _btn_continue.get_path()
		_btn_continue.focus_neighbor_left = _btn_repeat.get_path()

func _on_viewport_resized() -> void:
	_draw_template_preview(_want_id())
	_dump_rects("vp-resize")

# ---------- FLOW ----------
func _want_id() -> String:
	return (_queue[_idx] if _idx >= 0 and _idx < _queue.size() else "")

func _update_step() -> void:
	var want: String = _want_id()
	if want == "":
		_finish_to_world()
		return

	if _title != null:
		_title.text = "Gesture Tutorial"
	if _inst != null:
		_inst.text = "Draw the symbol in the box."
	_ability_name.text = want.capitalize().replace("_", " ")
	_training_label.text = "%d out of %d Successes" % [_passes_done, PASSES_REQUIRED_PER_ID]
	_ability_name.modulate = LABEL_NORMAL
	_training_label.modulate = LABEL_NORMAL

	_draw_template_preview(want)
	_log("step idx=%d want=%s passes=%d/%d" % [_idx, want, _passes_done, PASSES_REQUIRED_PER_ID])

func _on_repeat() -> void:
	if is_instance_valid(_overlay):
		_overlay.clear_stroke()

func _on_stroke_updated(points: Array[Vector2]) -> void:
	if points.size() >= 2:
		var res: Dictionary = RECOGNIZER.recognize(points)
		var rid: String = String(res.get("id", ""))
		var conf: float = float(res.get("confidence", 0.0))
		_log("stroke: pts=%d id=%s conf~%d%%" % [points.size(), rid, int(round(conf * 100.0))])

func _on_submitted(points: Array[Vector2]) -> void:
	var res: Dictionary = RECOGNIZER.recognize(points)
	var rid: String = String(res.get("id", ""))
	var conf: float = clamp(float(res.get("confidence", 0.0)), 0.0, 1.0)
	var gates: Dictionary = RECOGNIZER.passes_symbol_filters_verbose(StringName(rid), points)
	var ok: bool = bool(gates.get("ok", false))
	var want: String = _want_id()
	var is_match: bool = (rid == want and ok and conf >= PASS_MIN_CONF)

	_log("submitted: want=%s rid=%s ok=%s conf=%.0f%%" % [want, rid, str(ok), conf * 100.0])

	if is_match:
		if _sfx != null:
			_sfx.play()
		_passes_done += 1
		_flash_success()
		if is_instance_valid(_overlay):
			_overlay.clear_stroke()

		if _passes_done >= PASSES_REQUIRED_PER_ID:
			_idx += 1
			_passes_done = 0
		_update_step()
	else:
		_flash_fail()
		if is_instance_valid(_overlay):
			_overlay.clear_stroke()

func _on_overlay_cleared() -> void:
	_log("overlay: cleared")

# ---------- Finish → Village ----------
func _finish_to_world() -> void:
	_log("finish_to_world")
	var gs: Dictionary = SaveManager.load_game(_slot)
	var settings: Dictionary = (gs.get("settings", {}) as Dictionary)
	settings["tutorial_seen"] = true
	settings["tutorial_pending"] = false
	gs["settings"] = settings
	SaveManager.save_game(gs, _slot)

	var tree: SceneTree = get_tree()
	tree.set_meta("loading_target_path", PATH_VILLAGE)
	tree.change_scene_to_file(PATH_LOADING)

# ---------- PREVIEW (example symbol) ----------
func _ensure_preview_layer() -> void:
	_preview = _example_canvas.get_node_or_null(^"TemplatePreview") as Control
	if _preview == null:
		var p: Control = Control.new()
		p.name = "TemplatePreview"
		p.set_anchors_preset(Control.PRESET_FULL_RECT, true)
		p.mouse_filter = Control.MOUSE_FILTER_IGNORE
		p.z_index = 0
		_example_canvas.add_child(p)
		_preview = p

	_preview_line = _preview.get_node_or_null(^"Line") as Line2D
	if _preview_line == null:
		var ln: Line2D = Line2D.new()
		ln.name = "Line"
		ln.width = 6.0
		ln.default_color = Color(1.0, 1.0, 1.0, 0.94) # white
		ln.antialiased = true
		ln.joint_mode = Line2D.LINE_JOINT_ROUND
		ln.end_cap_mode = Line2D.LINE_CAP_ROUND
		_preview.add_child(ln)
		_preview_line = ln

func _draw_template_preview(gesture_id: String) -> void:
	if gesture_id == "" or _preview_line == null or _preview == null:
		return
	var demo_pts: Array[Vector2] = _demo_points_for(gesture_id)
	if demo_pts.is_empty():
		_preview_line.clear_points()
		return
	var resampled: Array[Vector2] = _resample_polyline(demo_pts, DEMO_RESAMPLE_COUNT)
	var fitted: PackedVector2Array = _fit_points_to_preview(resampled)
	_preview_line.points = fitted

func _fit_points_to_preview(points: Array[Vector2]) -> PackedVector2Array:
	var fitted: PackedVector2Array = PackedVector2Array()
	if points.is_empty() or _preview == null:
		return fitted
	var minp: Vector2 = Vector2(INF, INF)
	var maxp: Vector2 = Vector2(-INF, -INF)
	for v: Vector2 in points:
		minp.x = minf(minp.x, v.x); minp.y = minf(minp.y, v.y)
		maxp.x = maxf(maxp.x, v.x); maxp.y = maxf(maxp.y, v.y)
	var size: Vector2 = maxp - minp
	if size.x <= 0.0: size.x = 1.0
	if size.y <= 0.0: size.y = 1.0
	var pad: float = 16.0
	var rect_size: Vector2 = _preview.get_rect().size
	var target: Vector2 = rect_size - Vector2(pad * 2.0, pad * 2.0)
	target.x = maxf(1.0, target.x); target.y = maxf(1.0, target.y)
	var s: float = minf(target.x / size.x, target.y / size.y)
	var off: Vector2 = (rect_size - (size * s)) * 0.5
	fitted.resize(points.size())
	for i: int in range(points.size()):
		var v: Vector2 = points[i]
		fitted[i] = (v - minp) * s + off
	return fitted

# ---------- OVERLAY (test/draw area) ----------
func _ensure_overlay_layer() -> void:
	_overlay = _test_canvas.get_node_or_null(^"GestureOverlay") as GestureOverlay
	if _overlay == null:
		var ov: GestureOverlay = OVERLAY_CLASS.new()
		ov.name = "GestureOverlay"
		ov.set_anchors_preset(Control.PRESET_FULL_RECT, true)
		ov.mouse_filter = Control.MOUSE_FILTER_STOP
		ov.focus_mode = Control.FOCUS_ALL
		ov.z_index = 10
		_test_canvas.add_child(ov)
		_overlay = ov

# ---------- Success / Fail FX ----------
func _flash_success() -> void:
	_flash_label_green(_ability_name)
	_flash_label_green(_training_label)

func _flash_label_green(lbl: Label) -> void:
	if lbl == null:
		return
	var tw: Tween = create_tween()
	tw.tween_property(lbl, "modulate", SUCCESS_FLASH, 0.10).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_interval(0.05)
	tw.tween_property(lbl, "modulate", LABEL_NORMAL, 0.25).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)

func _flash_fail() -> void:
	_flash_label_color(_ability_name, FAIL_FLASH)
	_flash_label_color(_training_label, FAIL_FLASH)
	_pulse_draw_box_fail()

func _flash_label_color(lbl: Label, col: Color) -> void:
	if lbl == null:
		return
	var tw: Tween = create_tween()
	tw.tween_property(lbl, "modulate", col, 0.08).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_interval(0.04)
	tw.tween_property(lbl, "modulate", LABEL_NORMAL, 0.22).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)

func _pulse_draw_box_fail() -> void:
	var panel: Panel = _test_canvas.get_node_or_null(^"Back") as Panel
	if panel == null:
		return
	var tw: Tween = create_tween()
	tw.tween_property(panel, "modulate", Color(1, 0.5, 0.5, 1), 0.08).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_interval(0.04)
	tw.tween_property(panel, "modulate", Color(1, 1, 1, 1), 0.18).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)

# ---------- Demo points + resampling ----------
func _demo_points_for(gesture_id: String) -> Array[Vector2]:
	match gesture_id:
		"arc_slash":
			return [Vector2(10,100), Vector2(190,100)] as Array[Vector2]
		"riposte":
			return [Vector2(70,120), Vector2(95,145), Vector2(155,75)] as Array[Vector2]
		"thrust":
			return [Vector2(40,160), Vector2(160,40)] as Array[Vector2]
		"skewer":
			return [Vector2(60,150), Vector2(132,72), Vector2(162,98)] as Array[Vector2]
		"crush":
			return [Vector2(100,40), Vector2(100,170)] as Array[Vector2]
		"guard_break":
			return [Vector2(90,80), Vector2(90,150), Vector2(160,150)] as Array[Vector2]
		"aimed_shot":
			return [Vector2(55,90), Vector2(165,100), Vector2(55,135)] as Array[Vector2]
		"piercing_bolt":
			return [Vector2(40,110), Vector2(170,110), Vector2(150,90)] as Array[Vector2]
		"heal":
			return [Vector2(40,150), Vector2(100,60), Vector2(160,150)] as Array[Vector2]
		"purify":
			return [Vector2(60,150), Vector2(140,150), Vector2(100,70), Vector2(60,150)] as Array[Vector2]
		"shadow_grasp":
			return [Vector2(110,40), Vector2(110,160), Vector2(145,150)] as Array[Vector2]
		"curse_mark":
			return [Vector2(100,60), Vector2(150,110), Vector2(100,160), Vector2(50,110), Vector2(100,60)] as Array[Vector2]
		"firebolt":
			return [Vector2(40,70), Vector2(100,150), Vector2(160,70)] as Array[Vector2]
		"flame_wall":
			return [
				Vector2(60,140), Vector2(82,110), Vector2(98,95), Vector2(112,85),
				Vector2(124,80), Vector2(136,85), Vector2(150,95), Vector2(166,110),
				Vector2(188,140)
			] as Array[Vector2]
		"water_jet":
			return [Vector2(50,110), Vector2(85,95), Vector2(120,110), Vector2(155,95)] as Array[Vector2]
		"tide_surge":
			return [Vector2(200,80), Vector2(50,120), Vector2(200,160)] as Array[Vector2]
		"stone_spikes":
			return [Vector2(60,90), Vector2(140,90), Vector2(60,140), Vector2(140,140)] as Array[Vector2]
		"bulwark":
			return [Vector2(120,120), Vector2(260,120), Vector2(260,260), Vector2(120,260), Vector2(120,120)] as Array[Vector2]
		"gust":
			return [Vector2(70,140), Vector2(78,120), Vector2(90,100), Vector2(110,85), Vector2(135,80)] as Array[Vector2]
		"cyclone":
			return [Vector2(60,80), Vector2(85,115), Vector2(100,135), Vector2(115,145), Vector2(130,135), Vector2(145,115), Vector2(170,80)] as Array[Vector2]
		"block":
			return [Vector2(100,170), Vector2(100,40)] as Array[Vector2]
		"punch":
			return [Vector2(40,60), Vector2(160,140)] as Array[Vector2]
		"rest":
			return [Vector2(150,70), Vector2(122,94), Vector2(200,230)] as Array[Vector2]
		"meditate":
			return [Vector2(60,160), Vector2(90,60), Vector2(110,140), Vector2(130,60), Vector2(160,160)] as Array[Vector2]
		_:
			return [] as Array[Vector2]

func _path_len(points: Array[Vector2]) -> float:
	var L: float = 0.0
	for i: int in range(1, points.size()):
		L += points[i - 1].distance_to(points[i])
	return L

func _resample_polyline(points: Array[Vector2], n: int) -> Array[Vector2]:
	var out: Array[Vector2] = [] as Array[Vector2]
	if points.is_empty():
		return out
	if n <= 1:
		out.append(points[0])
		return out

	var D: float = _path_len(points) / float(n - 1)
	var dist_accum: float = 0.0
	var a: Vector2 = points[0]
	out.append(a)
	var i: int = 1
	while i < points.size():
		var b: Vector2 = points[i]
		var d: float = a.distance_to(b)
		if (dist_accum + d) >= D and d > 0.0:
			var t: float = (D - dist_accum) / d
			var q: Vector2 = a.lerp(b, t)
			out.append(q)
			a = q
			dist_accum = 0.0
		else:
			dist_accum += d
			a = b
			i += 1
	while out.size() < n:
		out.append(points[points.size() - 1])
	if out.size() > n:
		out.resize(n)
	return out

# ---------- Debug ----------
func _dump_rects(tag: String) -> void:
	var vp: Vector2 = get_viewport_rect().size
	var ex_r: Rect2 = (_example_canvas.get_global_rect() if is_instance_valid(_example_canvas) else Rect2())
	var ts_r: Rect2 = (_test_canvas.get_global_rect() if is_instance_valid(_test_canvas) else Rect2())
	var ov_r: Rect2 = (_overlay.get_global_rect() if is_instance_valid(_overlay) else Rect2())
	var pr_r: Rect2 = (_preview.get_global_rect() if is_instance_valid(_preview) else Rect2())
	_log("%s: vp=%s example=%s test=%s preview=%s overlay=%s" % [tag, str(vp), _rect_str(ex_r), _rect_str(ts_r), _rect_str(pr_r), _rect_str(ov_r)])

func _rect_str(r: Rect2) -> String:
	return "pos=%s size=%s" % [str(r.position), str(r.size)]

func _on_example_resized() -> void:
	_draw_template_preview(_want_id())
