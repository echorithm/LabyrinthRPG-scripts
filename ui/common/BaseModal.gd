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
@export var use_os_mobile_detection: bool = true          # treat Android/iOS as mobile regardless of resolution
@export var desktop_fill_percent: Vector2 = Vector2(0.72, 0.78)  # how big the panel is on desktop/tablet


## Minimum size the panel should use on roomy screens (desktop/tablet).
@export var min_panel_size: Vector2 = Vector2(920, 560)

## If viewport is smaller than this, we switch to a "mobile" layout (near-fullscreen panel).
## Tune per project; these values work well for phones and small landscape.
@export var fullscreen_threshold: Vector2i = Vector2i(1024, 700)

## In "mobile" layout, the panel fills this % of the safe area (leave a small margin).
@export var mobile_fill_percent: Vector2 = Vector2(0.96, 0.96)

## Hard minimum touch target height for primary buttons/tabs we place inside (used by subclasses).
@export var min_touch_target_px: int = 56

## Backdrop color for tap-to-dismiss. Keep semi-transparent.
@export var backdrop_color: Color = Color(0, 0, 0, 0.55)

var _panel: Control
var _backdrop: ColorRect
var _extra_hit_rects: Array[Rect2] = []

func _ready() -> void:
	if ui_theme:
		theme = ui_theme
	# BEFORE: process_mode = Node.PROCESS_MODE_WHEN_PAUSED
	process_mode = Node.PROCESS_MODE_ALWAYS   # <-- works paused or unpaused
	anchors_preset = Control.PRESET_FULL_RECT
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	z_index = 10000
	visible = false

	if modal_theme:
		theme = modal_theme

	_panel = get_node_or_null(panel_path) as Control
	_ensure_backdrop()
	set_process_input(true)

func _ensure_backdrop() -> void:
	_backdrop = ColorRect.new()
	_backdrop.name = "Backdrop"
	_backdrop.color = backdrop_color
	_backdrop.anchors_preset = Control.PRESET_FULL_RECT
	_backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	_backdrop.visible = false
	add_child(_backdrop)
	move_child(_backdrop, 0)
	_backdrop.gui_input.connect(func(e: InputEvent) -> void:
		if e is InputEventMouseButton and (e as InputEventMouseButton).pressed:
			close()
	)


func present(animate: bool = true, pause_game: bool = true) -> void:
	# make sure the backdrop exists before touching it
	_ensure_backdrop()

	if is_instance_valid(_backdrop):
		_backdrop.visible = true

	visible = true
	mouse_filter = Control.MOUSE_FILTER_STOP

	await get_tree().process_frame
	_layout_panel_for_viewport(get_viewport_rect().size)
	if animate:
		_animate_open()

	if pause_game:
		var tree := get_tree()
		if tree != null:
			tree.paused = true

	_grab_initial_focus()
	on_opened()
	print("[BaseModal] present() name=", name)


func close() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	if is_instance_valid(_backdrop):
		_backdrop.visible = false

	var tree := get_tree()
	if tree != null:
		tree.paused = false

	on_closed()
	emit_signal("closed")

func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED and visible:
		_layout_panel_for_viewport(get_viewport_rect().size)

func _layout_panel_for_viewport(vp: Vector2) -> void:
	if _panel == null:
		_panel = get_node_or_null(panel_path) as Control
	if _panel == null:
		return

	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_panel.top_level = false

	var is_mobile_os: bool = false
	if use_os_mobile_detection:
		var name := OS.get_name()
		is_mobile_os = OS.has_feature("mobile") or name == "Android" or name == "iOS" \
			or OS.has_feature("android") or OS.has_feature("ios")

	var is_mobile: bool = is_mobile_os \
		or (vp.x < float(fullscreen_threshold.x)) \
		or (vp.y < float(fullscreen_threshold.y))

	if is_mobile:
		# Fill most of the viewport with a small margin (no safe-area math to avoid scaling issues)
		_panel.set_anchors_preset(Control.PRESET_FULL_RECT)

		var margin := Vector2(
			max((1.0 - mobile_fill_percent.x) * vp.x * 0.5, 8.0),
			max((1.0 - mobile_fill_percent.y) * vp.y * 0.5, 8.0)
		)

		_panel.anchor_left = 0.0
		_panel.anchor_top = 0.0
		_panel.anchor_right = 1.0
		_panel.anchor_bottom = 1.0
		_panel.offset_left =  margin.x
		_panel.offset_top =   margin.y
		_panel.offset_right = -margin.x
		_panel.offset_bottom = -margin.y
		_panel.custom_minimum_size = Vector2.ZERO
	else:
		# Desktop/tablet: scale to a percentage of the viewport, but never smaller than min_panel_size
		_panel.set_anchors_preset(Control.PRESET_CENTER)

		var fill_target := Vector2(vp.x * desktop_fill_percent.x, vp.y * desktop_fill_percent.y)
		var target := Vector2(
			clamp(max(min_panel_size.x, fill_target.x), 0.0, vp.x * 0.96),
			clamp(max(min_panel_size.y, fill_target.y), 0.0, vp.y * 0.96)
		)

		_panel.custom_minimum_size = target
		_panel.size = target
		_panel.position = (vp - target) * 0.5



func _animate_open() -> void:
	modulate.a = 0.0
	if _panel:
		_panel.scale = Vector2(0.98, 0.98)
	var tw: Tween = create_tween()
	tw.tween_property(self, "modulate:a", 1.0, 0.12)
	if _panel:
		tw.parallel().tween_property(_panel, "scale", Vector2.ONE, 0.12).set_ease(Tween.EASE_OUT)

func _input(e: InputEvent) -> void:
	if not visible:
		return

	if e.is_action_pressed("ui_cancel"):
		close()
		return

	# tap/click outside to close
	if e is InputEventMouseButton and (e as InputEventMouseButton).pressed:
		var mb := e as InputEventMouseButton
		var inside_panel: bool = _panel != null and _panel.get_global_rect().has_point(mb.position)
		var inside_extra: bool = false
		for r in _extra_hit_rects:
			if r.has_point(mb.position):
				inside_extra = true
				break
		if not inside_panel and not inside_extra:
			close()

# ----- hooks for subclasses ------------------------------------------------
func on_opened() -> void: pass
func on_closed() -> void: pass
func _grab_initial_focus() -> void: pass
