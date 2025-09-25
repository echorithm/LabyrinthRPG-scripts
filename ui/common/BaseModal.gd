# res://ui/common/BaseModal.gd
extends Control
class_name BaseModal

signal closed

@export var ui_theme: Theme = preload("res://ui/themes/ModalTheme.tres")
@export var modal_theme: Theme
@export var pause_game := true
@export var dim_backdrop := true
@export var animate := true
@export var panel_path: NodePath = ^"Panel"
@export var min_panel_size := Vector2(920, 560)
@export var backdrop_color := Color(0, 0, 0, 0.55)

var _panel: Control
var _backdrop: ColorRect
var _extra_hit_rects: Array[Rect2] = []   # subclasses can push rects here (e.g., popups)

func _ready() -> void:
	if ui_theme:
		theme = ui_theme   # applies to this Control and all of its children
	process_mode = Node.PROCESS_MODE_WHEN_PAUSED
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
	_backdrop.gui_input.connect(func(e: InputEvent):
		if e is InputEventMouseButton and e.pressed:
			close())

func present() -> void:
	if modal_theme:
		theme = modal_theme

	mouse_filter = Control.MOUSE_FILTER_STOP
	if dim_backdrop:
		_backdrop.visible = true
	visible = true

	await get_tree().process_frame
	_center_panel()
	if animate:
		_animate_open()

	if pause_game:
		get_tree().paused = true

	_grab_initial_focus()
	on_opened()

func close() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	if dim_backdrop:
		_backdrop.visible = false
	if pause_game:
		get_tree().paused = false
	on_closed()
	emit_signal("closed")

func _center_panel() -> void:
	if _panel == null:
		_panel = get_node_or_null(panel_path) as Control
	if _panel == null:
		return
	_panel.set_anchors_preset(Control.PRESET_CENTER)
	if _panel.custom_minimum_size == Vector2.ZERO:
		_panel.custom_minimum_size = min_panel_size
	_panel.size = _panel.custom_minimum_size
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP

func _animate_open() -> void:
	modulate.a = 0.0
	if _panel:
		_panel.scale = Vector2(0.98, 0.98)
	var tw := create_tween()
	tw.tween_property(self, "modulate:a", 1.0, 0.12)
	if _panel:
		tw.parallel().tween_property(_panel, "scale", Vector2.ONE, 0.12).set_ease(Tween.EASE_OUT)

func _input(e: InputEvent) -> void:
	if not visible:
		return

	if e.is_action_pressed("ui_cancel"):
		close()
		return

	# click-outside to close
	if e is InputEventMouseButton and e.pressed:
		var mb := e as InputEventMouseButton
		var inside_panel := _panel != null and _panel.get_global_rect().has_point(mb.position)
		var inside_extra := false
		for r in _extra_hit_rects:
			if r.has_point(mb.position):
				inside_extra = true
				break
		if not inside_panel and not inside_extra:
			close()

# ----- hooks for subclasses ----------------------------------------------------
func on_opened() -> void: pass
func on_closed() -> void: pass
func _grab_initial_focus() -> void: pass
