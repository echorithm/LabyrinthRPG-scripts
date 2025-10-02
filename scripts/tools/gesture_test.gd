extends Control
class_name GestureTest

const DEBUG: bool = true

const OVERLAY_CLASS := preload("res://scripts/combat/ui/GestureOverlay.gd")
const RECOGNIZER_CLASS := preload("res://scripts/combat/ui/GestureRecognizer.gd")
const DEMO_RESAMPLE_COUNT: int = 48

@export_range(0.0, 1.0, 0.01) var pass_threshold: float = 0.60
@export var show_gate_fail_reasons: bool = true   # NEW: toggle diagnostics

# -------------------------------------------------------------------
# Abilities now ARE gesture ids (no mapping needed)
# -------------------------------------------------------------------
const ABILITY_ORDER: PackedStringArray = [
	"arc_slash","riposte","thrust","skewer",
	"crush","guard_break",
	"aimed_shot","piercing_bolt",
	"heal","purify",
	"shadow_grasp","curse_mark",
	"firebolt","flame_wall",
	"water_jet","tide_surge",
	"stone_spikes","bulwark",
	"gust", "cyclone",
	"block"
]

const ABILITY_DISPLAY: Dictionary = {
	"arc_slash":"Arc Slash",
	"riposte":"Riposte",
	"thrust":"Thrust",
	"skewer":"Skewer",
	"crush":"Crush",
	"guard_break":"Guard Break",
	"aimed_shot":"Aimed Shot",
	"piercing_bolt":"Piercing Bolt",
	"heal":"Heal",
	"purify":"Purify",
	"shadow_grasp":"Shadow Grasp",
	"curse_mark":"Curse Mark",
	"firebolt":"Firebolt",
	"flame_wall":"Flame Wall",
	"water_jet":"Water Jet",
	"tide_surge":"Tide Surge",
	"stone_spikes":"Stone Spikes",
	"bulwark":"Bulwark",
	"gust":"Gust",
	"cyclone": "Cyclone",
	"block":"Block"
}

# ---------------- UI Nodes ---------------------------------------------------
@onready var _root_v: VBoxContainer = VBoxContainer.new()
@onready var _row_top: HBoxContainer = HBoxContainer.new()
@onready var _ability_drop: OptionButton = OptionButton.new()
@onready var _expected_lbl: Label = Label.new()
@onready var _threshold_lbl: Label = Label.new()
@onready var _threshold_spin: SpinBox = SpinBox.new()

@onready var _row_mid: HBoxContainer = HBoxContainer.new()
@onready var _confidence_lbl: Label = Label.new()
@onready var _passes_lbl: Label = Label.new()

@onready var _row_btns: HBoxContainer = HBoxContainer.new()
@onready var _draw_btn: Button = Button.new()
@onready var _clear_btn: Button = Button.new()
@onready var _submit_btn: Button = Button.new()

@onready var _canvas_frame: PanelContainer = PanelContainer.new()
@onready var _canvas: Control = Control.new()
var _overlay: GestureOverlay

func _enter_tree() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT, true)
	size = get_viewport_rect().size
	get_viewport().size_changed.connect(_on_viewport_resized)

func _on_viewport_resized() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT, true)
	size = get_viewport_rect().size

func _ready() -> void:
	_build_ui()
	RECOGNIZER_CLASS.ensure_initialized()
	_create_overlay()
	_populate_dropdown()
	_update_expected_labels()
	_update_threshold_label()

	await get_tree().process_frame
	if DEBUG:
		print("[GestureTest] post-frame sizes:",
			" root=", get_global_rect(),
			" canvas_frame=", _canvas_frame.get_global_rect(),
			" canvas=", _canvas.get_global_rect(),
			" overlay=", _overlay.get_global_rect())

# -------------------------------------------------------------------
# UI build
# -------------------------------------------------------------------
func _build_ui() -> void:
	_root_v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_root_v.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_root_v.mouse_filter = Control.MOUSE_FILTER_PASS
	add_child(_root_v)

	_row_top.add_theme_constant_override("separation", 12)
	_root_v.add_child(_row_top)

	_ability_drop.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_row_top.add_child(_ability_drop)

	_expected_lbl.text = "Expected: —"
	_row_top.add_child(_expected_lbl)

	_threshold_lbl.text = "Threshold: —"
	_row_top.add_child(_threshold_lbl)

	_threshold_spin.min_value = 0.0
	_threshold_spin.max_value = 1.0
	_threshold_spin.step = 0.01
	_threshold_spin.value = pass_threshold
	_threshold_spin.custom_minimum_size = Vector2(90, 0)
	_row_top.add_child(_threshold_spin)

	_row_mid.add_theme_constant_override("separation", 12)
	_root_v.add_child(_row_mid)

	_confidence_lbl.text = "Confidence: 0%"
	_confidence_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_row_mid.add_child(_confidence_lbl)

	_passes_lbl.text = "Result: —"
	_row_mid.add_child(_passes_lbl)

	_row_btns.add_theme_constant_override("separation", 12)
	_root_v.add_child(_row_btns)

	_draw_btn.text = "Draw Template"
	_row_btns.add_child(_draw_btn)

	_submit_btn.text = "Submit Stroke"
	_row_btns.add_child(_submit_btn)

	_clear_btn.text = "Clear"
	_row_btns.add_child(_clear_btn)

	_canvas_frame.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_canvas_frame.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_canvas_frame.custom_minimum_size = Vector2(800, 480)
	_canvas_frame.add_theme_stylebox_override("panel", _panel_style())
	_canvas_frame.mouse_filter = Control.MOUSE_FILTER_PASS
	_root_v.add_child(_canvas_frame)

	_canvas.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_canvas.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_canvas.mouse_filter = Control.MOUSE_FILTER_PASS
	_canvas_frame.add_child(_canvas)

	_ability_drop.item_selected.connect(_on_ability_changed)
	_draw_btn.pressed.connect(_on_draw_template_pressed)
	_clear_btn.pressed.connect(_on_clear_pressed)
	_submit_btn.pressed.connect(_on_submit_pressed)
	_threshold_spin.value_changed.connect(_on_threshold_changed)

func _panel_style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.08, 0.08, 0.10, 1.0)
	sb.border_color = Color(0.22, 0.22, 0.28, 1.0)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(12)
	return sb

func _create_overlay() -> void:
	_overlay = OVERLAY_CLASS.new()
	_overlay.name = "GestureOverlay"
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT, true)
	_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	_overlay.focus_mode = Control.FOCUS_ALL
	_overlay.z_index = 1000
	_canvas.add_child(_overlay)

	_overlay.stroke_updated.connect(_on_stroke_updated)
	_overlay.submitted.connect(_on_submitted)
	_overlay.cleared.connect(_on_cleared)

	if DEBUG:
		print("[GestureTest] overlay ready; rect=", _overlay.get_global_rect(), " z=", _overlay.z_index)

# -------------------------------------------------------------------
# Dropdown / labels
# -------------------------------------------------------------------
func _populate_dropdown() -> void:
	_ability_drop.clear()
	for i in ABILITY_ORDER.size():
		var k: String = ABILITY_ORDER[i]
		var name: String = String(ABILITY_DISPLAY.get(k, k))
		_ability_drop.add_item(name, i)
	_ability_drop.select(0)

func _on_ability_changed(_idx: int) -> void:
	_update_expected_labels()
	_update_controls_state()
	if is_instance_valid(_overlay):
		_overlay.clear_stroke()

func _on_threshold_changed(v: float) -> void:
	pass_threshold = clampf(float(v), 0.0, 1.0)
	_update_threshold_label()
	if is_instance_valid(_overlay):
		_on_stroke_updated(_overlay._points.duplicate())

func _update_expected_labels() -> void:
	var aid := _current_ability_id()
	_expected_lbl.text = "Expected: %s" % aid
	_update_threshold_label()

func _update_threshold_label() -> void:
	_threshold_lbl.text = "Threshold: %d%%" % int(round(pass_threshold * 100.0))

func _update_controls_state() -> void:
	# All abilities have demos; keep the button enabled.
	_draw_btn.disabled = false

func _current_ability_id() -> String:
	var idx: int = _ability_drop.get_selected_id()
	if idx < 0 or idx >= ABILITY_ORDER.size():
		return ABILITY_ORDER[0]
	return ABILITY_ORDER[idx]

# -------------------------------------------------------------------
# Gesture flow
# -------------------------------------------------------------------
func _on_stroke_updated(points: Array[Vector2]) -> void:
	if points.size() < 2:
		_confidence_lbl.text = "Confidence: 0%"
		_passes_lbl.text = "Result: —"
		return
	var res: Dictionary = RECOGNIZER_CLASS.recognize(points)
	var rid: String = String(res.get("id",""))
	var conf: float = float(res.get("confidence", 0.0))

	var expected: String = _current_ability_id()
	var gates_verbose := RECOGNIZER_CLASS.passes_symbol_filters_verbose(StringName(rid), points)
	var gates_ok: bool = bool(gates_verbose["ok"])
	var pass_now: bool = (rid == expected and gates_ok and conf >= pass_threshold)

	_confidence_lbl.text = "Confidence: %d%% (id=%s, gates=%s)" % [int(round(conf * 100.0)), rid, ( "OK" if gates_ok else "NO")]
	if show_gate_fail_reasons and not gates_ok:
		var reasons: PackedStringArray = gates_verbose["failed"]
		if reasons.size() > 0:
			print("[GestureTest] Gates failed for id=", rid, " reasons=", reasons)

	_passes_lbl.text = "Result: %s" % ( "PASS" if pass_now else "…" )

func _on_submitted(points: Array[Vector2]) -> void:
	_finalize_evaluation(points)

func _on_submit_pressed() -> void:
	if not is_instance_valid(_overlay): return
	var pts := _overlay._points.duplicate()
	if pts.size() >= 2:
		_finalize_evaluation(pts)

func _on_cleared() -> void:
	_confidence_lbl.text = "Confidence: 0%"
	_passes_lbl.text = "Result: —"

func _finalize_evaluation(points: Array[Vector2]) -> void:
	var res := RECOGNIZER_CLASS.recognize(points)
	var rid := String(res.get("id",""))
	var conf := float(res.get("confidence", 0.0))
	var expected := _current_ability_id()

	var gates_verbose := RECOGNIZER_CLASS.passes_symbol_filters_verbose(StringName(rid), points)
	var gates_ok: bool = bool(gates_verbose["ok"])
	if show_gate_fail_reasons and not gates_ok:
		var reasons: PackedStringArray = gates_verbose["failed"]
		print("[GestureTest] FINAL gates failed for id=", rid, " reasons=", reasons)

	var pass_bool := (rid == expected and gates_ok and conf >= pass_threshold)

	_confidence_lbl.text = "Confidence: %d%% (id=%s, gates=%s)" % [int(round(conf * 100.0)), rid, ("OK" if gates_ok else "NO")]
	_passes_lbl.text = "Result: %s" % ("PASS" if pass_bool else "FAIL")

# -------------------------------------------------------------------
# Demo strokes (Draw Template)
# -------------------------------------------------------------------
func _evaluate_and_show(points: Array[Vector2], origin: String) -> void:
	var res: Dictionary = RECOGNIZER_CLASS.recognize(points)
	var rid: String = String(res.get("id",""))
	var conf: float = float(res.get("confidence", 0.0))
	var gates_verbose := RECOGNIZER_CLASS.passes_symbol_filters_verbose(StringName(rid), points)
	var gates_ok: bool = bool(gates_verbose["ok"])
	var expected: String = _current_ability_id()
	var pass_now: bool = (rid == expected and gates_ok and conf >= pass_threshold)

	_confidence_lbl.text = "Confidence: %d%% (id=%s, gates=%s)" % [int(round(conf * 100.0)), rid, ("OK" if gates_ok else "NO")]
	_passes_lbl.text = "Result: %s" % ("PASS" if pass_now else "…")

	if show_gate_fail_reasons and not gates_ok:
		var reasons: PackedStringArray = gates_verbose["failed"]
		if reasons.size() > 0:
			print("[GestureTest] %s gates failed for id=%s reasons=%s" % [origin, rid, reasons])


func _on_draw_template_pressed() -> void:
	var aid := _current_ability_id()
	var demo: Array[Vector2] = _demo_points_for(aid)
	if demo.is_empty():
		if DEBUG: print("[GestureTest] demo points empty for id=", aid)
		return
	demo = _resample_polyline(demo, DEMO_RESAMPLE_COUNT)
	_overlay.show_demo(demo, true)
	# NEW: also evaluate + print diagnostics for the demo stroke
	_evaluate_and_show(demo, "DEMO")

func _on_clear_pressed() -> void:
	if is_instance_valid(_overlay):
		_overlay.clear_stroke()

func _demo_points_for(gesture_id: String) -> Array[Vector2]:
	match gesture_id:
		"arc_slash":
			return [Vector2(10,100), Vector2(190,100)]
		"riposte":
			return [Vector2(70,120), Vector2(95,145), Vector2(155,75)]
		"thrust":
			return [Vector2(40,160), Vector2(160,40)]
		"skewer":
			return [Vector2(60, 150), Vector2(132, 72), Vector2(162, 98)]
		"crush":
			return [Vector2(100,40), Vector2(100,170)]
		"guard_break":
			return [Vector2(90,80), Vector2(90,150), Vector2(160,150)]
		"aimed_shot":
			return [Vector2(55,90), Vector2(165,100), Vector2(55,135)]
		"piercing_bolt":
			# Long baseline → short up-left slash at the tip
			return [Vector2(40,110), Vector2(170,110), Vector2(150,90)]
		"heal":
			return [Vector2(40,150), Vector2(100,60), Vector2(160,150)]
		"purify":
			return [Vector2(60,150), Vector2(140,150), Vector2(100,70), Vector2(60,150)]
		"shadow_grasp":
			return [Vector2(110,40), Vector2(110,160), Vector2(145,150)]
		"curse_mark":
			return [Vector2(100,60), Vector2(150,110), Vector2(100,160), Vector2(50,110), Vector2(100,60)]
		"firebolt":
			return [Vector2(40,70), Vector2(100,150), Vector2(160,70)]
		"flame_wall":
			return [
		Vector2(60,140),   # left base
		Vector2(82,110),
		Vector2(98,95),
		Vector2(112,85),
		Vector2(124,80),   # near-flat apex region
		Vector2(136,85),
		Vector2(150,95),
		Vector2(166,110),
		Vector2(188,140)   # right base
	]
		"water_jet":
			return [Vector2(50,110), Vector2(85,95), Vector2(120,110), Vector2(155,95)]
		"tide_surge":
			return [Vector2(200, 80), Vector2(50, 120), Vector2(200, 160)]
		"stone_spikes":
			return [Vector2(60,90), Vector2(140,90), Vector2(60,140), Vector2(140,140)]
		"bulwark":
	# Large, clearly axis-aligned square demo
			return [
				Vector2(120,120), Vector2(260,120),
				Vector2(260,260), Vector2(120,260),
				Vector2(120,120)
			]
		"gust":
			return [Vector2(70,140), Vector2(78,120), Vector2(90,100), Vector2(110,85), Vector2(135,80)]
			
		"cyclone":
			return [
			Vector2(60,80), Vector2(85,115), Vector2(100,135),
			Vector2(115,145), Vector2(130,135), Vector2(145,115),
			Vector2(170,80)
			]

		"block":
			return [Vector2(100,170), Vector2(100,40)]
		_:
			return []

# -------------------------------------------------------------------
# Root input debug: print mouse motion ONLY while LMB is held
# -------------------------------------------------------------------
func _gui_input(event: InputEvent) -> void:
	if not DEBUG:
		return
	if event is InputEventMouseButton:
		print("[GestureTest] ROOT _gui_input: ", event.as_text())
	elif event is InputEventMouseMotion:
		if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
			print("[GestureTest] ROOT _gui_input (drag): pos=", (event as InputEventMouseMotion).position)

func _unhandled_input(event: InputEvent) -> void:
	if not DEBUG:
		return
	if event is InputEventMouseButton:
		print("[GestureTest] ROOT _unhandled_input: ", event.as_text())
	elif event is InputEventMouseMotion:
		if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
			print("[GestureTest] ROOT _unhandled_input (drag): pos=", (event as InputEventMouseMotion).position)

# -------------------------------------------------------------------
# Helpers: resample for demo parity
# -------------------------------------------------------------------
func _path_len(points: Array[Vector2]) -> float:
	var L := 0.0
	for i in range(1, points.size()):
		L += points[i - 1].distance_to(points[i])
	return L

func _resample_polyline(points: Array[Vector2], n: int) -> Array[Vector2]:
	var out: Array[Vector2] = []
	if points.is_empty():
		return out
	if n <= 1:
		out.append(points[0]); return out
	var D := _path_len(points) / float(n - 1)
	var dist_accum := 0.0
	var a := points[0]
	out.append(a)
	var i := 1
	while i < points.size():
		var b := points[i]
		var d := a.distance_to(b)
		if (dist_accum + d) >= D and d > 0.0:
			var t := (D - dist_accum) / d
			var q := a.lerp(b, t)
			out.append(q)
			a = q
			dist_accum = 0.0
		else:
			dist_accum += d
			a = b
			i += 1
	while out.size() < n: out.append(points[points.size() - 1])
	if out.size() > n: out.resize(n)
	return out
