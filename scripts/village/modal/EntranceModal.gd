# res://scripts/village/modal/EntranceModal.gd
extends "res://ui/common/BaseModal.gd"
class_name EntranceModal

@export var main_scene: PackedScene
@export var door_texture: Texture2D = preload("res://art/icons/entrance.png")

# Inspector knobs
@export_range(0.60, 1.15, 0.01) var content_scale: float = 0.90
@export_range(0.40, 0.95, 0.01) var image_height_frac: float = 0.85
@export var min_card_width_px: int = 420
@export var default_floor: int = 1

# Use direct preload of SaveManager (no singleton required)
const _SM: GDScript = preload("res://persistence/SaveManager.gd")

const DEBUG_ENTRANCE: bool = true
func _dbg(msg: String) -> void:
	if DEBUG_ENTRANCE:
		print("[ENTRANCE] ", msg)

# Cached (built dynamically under Panel/Margin/V/Content)
var _content: Control
var _row: HBoxContainer
var _art_wrap: AspectRatioContainer
var _icon_rect: TextureRect
var _right_col: VBoxContainer
var _title: Label
var _hint: Label
var _floors: ItemList
var _btn_enter: Button
var _btn_close: Button

func on_opened() -> void:
	_dbg("on_opened()")
	_cache_or_build()
	_populate()
	_sync_typo_and_scale()
	_select_initial_floor()

func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED and visible:
		_sync_typo_and_scale()

# --- Build / cache ---
func _cache_or_build() -> void:
	_content = get_node_or_null(^"Panel/Margin/V/Content") as Control
	_btn_close = get_node_or_null(^"Panel/Margin/V/Bottom/Close") as Button
	if _btn_close != null and not _btn_close.pressed.is_connected(_on_close):
		_btn_close.pressed.connect(_on_close)

	_row = get_node_or_null(^"Panel/Margin/V/Content/EntranceRow") as HBoxContainer
	if _row != null:
		_dbg("reusing existing UI")
		_art_wrap = get_node(^"Panel/Margin/V/Content/EntranceRow/Art") as AspectRatioContainer
		_icon_rect = get_node(^"Panel/Margin/V/Content/EntranceRow/Art/Texture") as TextureRect
		_right_col = get_node(^"Panel/Margin/V/Content/EntranceRow/Right") as VBoxContainer
		_title = get_node(^"Panel/Margin/V/Content/EntranceRow/Right/Title") as Label
		_hint = get_node(^"Panel/Margin/V/Content/EntranceRow/Right/Hint") as Label
		_floors = get_node(^"Panel/Margin/V/Content/EntranceRow/Right/Floors") as ItemList
		_btn_enter = get_node(^"Panel/Margin/V/Content/EntranceRow/Right/Enter") as Button
		return

	_dbg("building UI")
	_row = HBoxContainer.new()
	_row.name = "EntranceRow"
	_row.add_theme_constant_override("separation", 16)
	_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_content.add_child(_row)

	# Art
	_art_wrap = AspectRatioContainer.new()
	_art_wrap.name = "Art"
	_art_wrap.ratio = 1.0
	_art_wrap.stretch_mode = AspectRatioContainer.STRETCH_COVER
	_art_wrap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_art_wrap.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_row.add_child(_art_wrap)

	_icon_rect = TextureRect.new()
	_icon_rect.name = "Texture"
	_icon_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_icon_rect.expand_mode = TextureRect.EXPAND_FIT_WIDTH
	_icon_rect.mouse_filter = Control.MOUSE_FILTER_STOP
	_art_wrap.add_child(_icon_rect)
	if not _icon_rect.gui_input.is_connected(_on_art_gui_input):
		_icon_rect.gui_input.connect(_on_art_gui_input)

	# Right column
	_right_col = VBoxContainer.new()
	_right_col.name = "Right"
	_right_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_right_col.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_right_col.add_theme_constant_override("separation", 10)
	_row.add_child(_right_col)

	_title = Label.new()
	_title.name = "Title"
	_right_col.add_child(_title)

	_hint = Label.new()
	_hint.name = "Hint"
	_right_col.add_child(_hint)

	_floors = ItemList.new()
	_floors.name = "Floors"
	_floors.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_floors.custom_minimum_size = Vector2(0, 140)
	_right_col.add_child(_floors)

	_btn_enter = Button.new()
	_btn_enter.name = "Enter"
	_btn_enter.text = "Enter"
	_right_col.add_child(_btn_enter)
	_btn_enter.pressed.connect(_on_enter_pressed)

func _populate() -> void:
	_dbg("_populate()")
	if _icon_rect != null:
		_icon_rect.texture = door_texture
	if _title != null:
		_title.text = "Enter the Labyrinth"
	if _hint != null:
		_hint.text = "Choose a floor or tap the door."

	# Read meta through preloaded SaveManager
	var meta: Dictionary = _load_meta_safe()
	_dbg("meta=" + str(meta))
	var highest: int = _highest_teleport_floor()
	_dbg("highest_teleport_floor=" + str(highest))

	var floors: Array[int] = _list_entrance_floors()
	_dbg("computed floors=" + str(floors))

	if _floors != null:
		_floors.clear()
		for f: int in floors:
			_floors.add_item("Floor %d" % f)
		if _floors.get_item_count() == 0:
			_dbg("WARNING: no floors added to ItemList")

# --- Layout/scale ---
func _sync_typo_and_scale() -> void:
	var panel: Control = get_node_or_null(^"Panel") as Control
	if panel == null:
		return

	var vp: Vector2 = get_viewport_rect().size
	panel.scale = Vector2.ONE
	var base_size: Vector2 = panel.size
	var s: float = content_scale
	panel.scale = Vector2(s, s)
	panel.position = (vp - (base_size * s)) * 0.5

	var ph: float = base_size.y
	var target_h: float = ph * clamp(image_height_frac, 0.40, 0.95)
	var target_w: float = max(float(min_card_width_px), target_h)

	if _art_wrap != null:
		_art_wrap.custom_minimum_size = Vector2(target_w, target_h)
	if _icon_rect != null:
		_icon_rect.custom_minimum_size = Vector2(target_w, target_h)
		_icon_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		_icon_rect.expand_mode = TextureRect.EXPAND_FIT_WIDTH

	if _right_col != null:
		_right_col.custom_minimum_size = Vector2(420.0, target_h)

func _select_initial_floor() -> void:
	if _floors == null:
		return
	var n: int = _floors.get_item_count()
	_dbg("_select_initial_floor count=" + str(n))
	if n > 0:
		_floors.select(n - 1)  # select highest

func _get_selected_floor() -> int:
	var fallback: int = max(1, default_floor)
	if _floors == null:
		return fallback
	var sel: PackedInt32Array = _floors.get_selected_items()
	if sel.is_empty():
		return fallback
	var idx: int = sel[0]
	var floors: Array[int] = _list_entrance_floors()
	return floors[idx] if idx >= 0 and idx < floors.size() else fallback

# --- Actions ---
func _on_enter_pressed() -> void:
	var floor: int = _get_selected_floor()
	_dbg("_on_enter_pressed floor=" + str(floor))
	EnterLabyrinth.enter(floor, main_scene)

func _on_art_gui_input(ev: InputEvent) -> void:
	var mb: InputEventMouseButton = ev as InputEventMouseButton
	if mb != null and mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
		_dbg("door image clicked (mouse)")
		_on_enter_pressed()
		return
	var st: InputEventScreenTouch = ev as InputEventScreenTouch
	if st != null and st.pressed:
		_dbg("door image tapped (touch)")
		_on_enter_pressed()

func _on_close() -> void:
	_dbg("close() pressed")
	close()

# --- Save/meta helpers (typed; use preloaded SaveManager) ---
func _load_meta_safe() -> Dictionary:
	var d: Dictionary = {}
	if _SM != null and _SM.has_method("load_game"):
		var meta_dict: Dictionary = _SM.load_game()
		d = meta_dict
	else:
		_dbg("SaveManager preload missing or load_game not found")
	return d

func _highest_teleport_floor() -> int:
	var meta: Dictionary = _load_meta_safe()
	var val: int = int(meta.get("highest_teleport_floor", 1))
	return max(1, val)

func _list_entrance_floors() -> Array[int]:
	# Ascending: 1, 4, 7, ... up to highest_teleport_floor
	var out: Array[int] = [] as Array[int]
	var max_t: int = _highest_teleport_floor()
	var f: int = 1
	while f <= max_t:
		out.append(f)
		f += 3
	return out
