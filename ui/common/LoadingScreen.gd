extends Control
class_name LoadingScreen

@export var message: String = "Loading"
@export var dot_frames: int = 3
@export var dot_interval_sec: float = 0.25
@export var font_size: int = 32
@export var min_show_time_sec: float = 0.45

var _label: Label
var _timer: Timer
var _frame: int = 0
var _target_path: String = ""
var _started: bool = false
var _elapsed: float = 0.0

func _ready() -> void:
	# Ensure this screen animates even if tree gets paused elsewhere.
	process_mode = Node.PROCESS_MODE_ALWAYS

	_build_ui()
	_read_target_path()

	if _target_path != "":
		var rc: int = ResourceLoader.load_threaded_request(_target_path)
		_started = (rc == OK)
	else:
		_started = false

	_timer.wait_time = dot_interval_sec
	_timer.start()

func _process(delta: float) -> void:
	_elapsed += delta
	if not _started or _target_path == "":
		return

	var dummy_progress: PackedFloat32Array = PackedFloat32Array()
	var status: int = ResourceLoader.load_threaded_get_status(_target_path, dummy_progress)

	if status == ResourceLoader.THREAD_LOAD_LOADED and _elapsed >= min_show_time_sec:
		var res: Resource = ResourceLoader.load_threaded_get(_target_path)
		if res is PackedScene:
			get_tree().change_scene_to_packed(res as PackedScene)
	elif status == ResourceLoader.THREAD_LOAD_FAILED and _elapsed >= 0.2:
		# Fallback if threaded load failed (very rare).
		get_tree().change_scene_to_file(_target_path)

# --- internal helpers --------------------------------------------------------

func _build_ui() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	size = get_viewport_rect().size

	var bg: ColorRect = ColorRect.new()
	bg.name = "BG"
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.color = Color.BLACK
	add_child(bg)

	var center: CenterContainer = CenterContainer.new()
	center.name = "Center"
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	_label = Label.new()
	_label.text = message
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_label.add_theme_font_size_override("font_size", font_size)
	center.add_child(_label)

	_timer = Timer.new()
	_timer.name = "Ticker"
	_timer.one_shot = false
	add_child(_timer)
	_timer.timeout.connect(_on_tick)

func _read_target_path() -> void:
	var tree: SceneTree = get_tree()
	if tree.has_meta("loading_target_path"):
		var v: Variant = tree.get_meta("loading_target_path")
		if typeof(v) == TYPE_STRING:
			_target_path = String(v)

func _on_tick() -> void:
	_frame = (_frame + 1) % (dot_frames + 1)
	var dots: String = ".".repeat(_frame)
	_label.text = "%s%s" % [message, dots]
