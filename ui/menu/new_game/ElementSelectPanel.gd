extends Control
class_name ElementSelectPanel

const DEBUG: bool = true
static func _dbg(msg: String) -> void:
	if DEBUG:
		print("[ElementPanel] ", msg)

var ACCENT: Color = Color(0.368627, 0.631373, 1.0, 1.0)

const H_SEP_PX: int = 12
const V_SEP_PX: int = 12
const PAD_PX: int = 24
const WIDE_COL_THRESHOLD_PX: float = 1280.0
const WIDE_COLS: int = 6
const NARROW_COLS: int = 3
const MIN_TILE_W: float = 120.0
const MAX_TILE_W: float = 200.0
const TILE_ASPECT: float = 0.90
const TILE_FONT_PX: int = 20

@onready var _headline: Label = $VBoxContainer/Headline
@onready var _tiles: GridContainer = $VBoxContainer/Tiles
@onready var _prev_box: VBoxContainer = $VBoxContainer/VBoxContainer
@onready var _p1_host: Control = $VBoxContainer/VBoxContainer/AbilityPreview1
@onready var _p2_host: Control = $VBoxContainer/VBoxContainer/AbilityPreview2

var _selected: String = "fire"
var _order: Array[String] = ["fire","water","light","dark","earth","wind"]
var _tile_map: Dictionary = {
	"tile_fire":  "fire",  "tile_water": "water",
	"tile_light": "light", "tile_dark":  "dark",
	"tile_earth": "earth", "tile_wind":  "wind",
}
var _buttons: Array[Button] = [] as Array[Button]

# styles
var _sb_normal: StyleBoxFlat
var _sb_hover: StyleBoxFlat
var _sb_focus: StyleBoxFlat
var _sb_selected: StyleBoxFlat
var _sb_selected_hover: StyleBoxFlat

func _ready() -> void:
	_headline.text = "Select Element"
	_build_tile_styles()
	_prepare_preview_hosts()
	_wire_buttons()
	_layout_for_width(get_viewport_rect().size.x)
	_apply_selected_visuals()
	_refresh_previews()
	_snapshot("ready")

func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED and _tiles != null:
		_layout_for_width(get_viewport_rect().size.x)

# ---- styles
func _make_card_style(bg: Color, border: Color) -> StyleBoxFlat:
	var sb: StyleBoxFlat = StyleBoxFlat.new()
	sb.bg_color = bg
	sb.corner_radius_top_left = 10
	sb.corner_radius_top_right = 10
	sb.corner_radius_bottom_left = 10
	sb.corner_radius_bottom_right = 10
	sb.border_width_left = 1
	sb.border_width_top = 1
	sb.border_width_right = 1
	sb.border_width_bottom = 1
	sb.border_color = border
	sb.shadow_color = Color(0, 0, 0, 0.55)
	sb.shadow_size = 12
	sb.shadow_offset = Vector2(0, 4)
	return sb

func _build_tile_styles() -> void:
	var base_bg: Color = Color(0.12, 0.13, 0.15, 0.95)
	var hover_bg: Color = base_bg.lerp(ACCENT, 0.08)
	var sel_bg: Color = base_bg.lerp(ACCENT, 0.12)
	var border_dim: Color = Color(1, 1, 1, 0.12)
	var border_acc: Color = ACCENT * Color(1, 1, 1, 0.90)

	_sb_normal = _make_card_style(base_bg, border_dim)
	_sb_hover = _make_card_style(hover_bg, border_dim)
	_sb_focus = _make_card_style(hover_bg, border_acc)
	_sb_selected = _make_card_style(sel_bg, border_acc)
	_sb_selected_hover = _make_card_style(sel_bg.lerp(ACCENT, 0.06), border_acc)

# ---- build / wire
func _wire_buttons() -> void:
	_buttons.clear()

	if not _tiles.has_theme_constant_override("h_separation"):
		_tiles.add_theme_constant_override("h_separation", H_SEP_PX)
	if not _tiles.has_theme_constant_override("v_separation"):
		_tiles.add_theme_constant_override("v_separation", V_SEP_PX)

	for node_name: String in _tile_map.keys():
		var b: Button = _tiles.get_node_or_null(NodePath(node_name)) as Button
		if b == null:
			_dbg("missing button: " + node_name)
			continue

		var elem_id: String = String(_tile_map[node_name])
		var label: String = elem_id.capitalize()

		b.text = label
		b.custom_minimum_size = Vector2(140.0, 126.0)
		b.focus_mode = Control.FOCUS_ALL
		b.toggle_mode = false
		b.flat = false

		b.add_theme_font_size_override("font_size", TILE_FONT_PX)
		b.add_theme_stylebox_override("normal", _sb_normal)
		b.add_theme_stylebox_override("hover", _sb_hover)
		b.add_theme_stylebox_override("pressed", _sb_selected_hover)
		b.add_theme_stylebox_override("focus", _sb_focus)
		b.add_theme_color_override("font_color", Color(1, 1, 1, 0.92))
		b.add_theme_color_override("font_hover_color", Color(1, 1, 1, 1.0))
		b.tooltip_text = "Element: " + label

		if not b.pressed.is_connected(_on_tile_pressed):
			b.pressed.connect(_on_tile_pressed.bind(elem_id, b))
		if not b.focus_entered.is_connected(_on_focus_enter):
			b.focus_entered.connect(_on_focus_enter.bind(b))
		if not b.focus_exited.is_connected(_on_focus_exit):
			b.focus_exited.connect(_on_focus_exit.bind(b))

		_buttons.append(b)

	_buttons.sort_custom(Callable(self, "_cmp_buttons"))
	_setup_grid_navigation()

func _cmp_buttons(a: Button, b: Button) -> bool:
	var ea: String = String(_tile_map.get(a.name, ""))
	var eb: String = String(_tile_map.get(b.name, ""))
	var ai: int = _order.find(ea)
	var bi: int = _order.find(eb)
	return ai < bi

# ---- responsive layout
func _layout_for_width(vp_w: float) -> void:
	if _tiles == null:
		return
	var cols: int = WIDE_COLS if vp_w >= WIDE_COL_THRESHOLD_PX else NARROW_COLS
	_tiles.columns = cols

	var avail: float = max(720.0, vp_w - float(PAD_PX) * 2.0)
	var tile_w: float = clamp(
		floor((avail - float(cols - 1) * float(H_SEP_PX)) / float(cols)),
		MIN_TILE_W, MAX_TILE_W
	)
	var tile_h: float = clamp(tile_w * TILE_ASPECT, 110.0, 170.0)

	for b: Button in _buttons:
		b.custom_minimum_size = Vector2(tile_w, tile_h)

	_dbg("layout: vp_w=%.1f cols=%d tile=(%.0f,%.0f)" % [vp_w, cols, tile_w, tile_h])
	_setup_grid_navigation()

func _setup_grid_navigation() -> void:
	if _tiles == null or _buttons.is_empty():
		return
	var cols: int = max(1, _tiles.columns)
	var n: int = _buttons.size()
	for i: int in range(n):
		var r: int = i / cols
		var c: int = i % cols
		var left_i: int = r * cols + max(0, c - 1)
		var right_i: int = r * cols + min(cols - 1, c + 1)
		var up_i: int = max(0, i - cols)
		var down_i: int = min(n - 1, i + cols)
		var b: Button = _buttons[i]
		b.focus_neighbor_left = _buttons[left_i].get_path()
		b.focus_neighbor_right = _buttons[right_i].get_path()
		b.focus_neighbor_top = _buttons[up_i].get_path()
		b.focus_neighbor_bottom = _buttons[down_i].get_path()

# ---- interactions
func _on_tile_pressed(elem: String, sender: Button) -> void:
	_selected = elem
	_dbg("pick=" + _selected)
	_apply_selected_visuals()
	_refresh_previews()

func _on_focus_enter(b: Button) -> void:
	var t: Tween = create_tween()
	t.tween_property(b, "scale", Vector2(1.02, 1.02), 0.06)

func _on_focus_exit(b: Button) -> void:
	var t: Tween = create_tween()
	t.tween_property(b, "scale", Vector2.ONE, 0.06)

# ---- visuals
func _apply_selected_visuals() -> void:
	for b: Button in _buttons:
		var e: String = String(_tile_map.get(b.name, ""))
		var sel: bool = (e == _selected)
		b.add_theme_stylebox_override("normal", _sb_selected if sel else _sb_normal)
		b.add_theme_color_override("font_color", Color(1, 1, 1, 1.0) if sel else Color(1, 1, 1, 0.92))

# ---- previews
func _prepare_preview_hosts() -> void:
	if _prev_box != null and not _prev_box.has_theme_constant_override("separation"):
		_prev_box.add_theme_constant_override("separation", 6)

	for h: Control in [_p1_host, _p2_host]:
		if h == null:
			continue
		h.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		h.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		h.custom_minimum_size.y = 28.0

	var l1: Label = _ensure_label(_p1_host)
	var l2: Label = _ensure_label(_p2_host)
	l1.add_theme_font_size_override("font_size", 18)
	l2.add_theme_font_size_override("font_size", 18)

func _ensure_label(host: Control) -> Label:
	if host == null:
		var dummy: Label = Label.new()
		return dummy
	var lbl: Label = (host.get_child(0) as Label) if host.get_child_count() > 0 else null
	if lbl == null:
		lbl = Label.new()
		host.add_child(lbl)
	return lbl

func _element_abilities() -> Array[String]:
	match _selected:
		"light": return ["heal","purify"] as Array[String]
		"water": return ["water_jet","tide_surge"] as Array[String]
		"earth": return ["stone_spikes","bulwark"] as Array[String]
		"wind":  return ["gust","cyclone"] as Array[String]
		"dark":  return ["shadow_grasp","curse_mark"] as Array[String]
		_:       return ["firebolt","flame_wall"] as Array[String]

func _refresh_previews() -> void:
	var ab: Array[String] = _element_abilities()
	var n1: String = ab[0].capitalize().replace("_", " ")
	var n2: String = ab[1].capitalize().replace("_", " ")
	(_ensure_label(_p1_host)).text = n1
	(_ensure_label(_p2_host)).text = n2
	_dbg("preview=" + str(ab))

# ---- external
func set_selected(elem: String) -> void:
	var s: String = elem.strip_edges().to_lower()
	_selected = (s if ["fire","water","earth","wind","light","dark"].has(s) else "fire")
	_dbg("set_selected=" + _selected)
	_apply_selected_visuals()
	_refresh_previews()

func get_selected() -> String:
	return _selected

# ---- debug
func _snapshot(tag: String) -> void:
	if not DEBUG:
		return
	var vp: Vector2 = get_viewport_rect().size
	print("[ElementPanel] snap=", tag, " vp=", vp, " btns=", _buttons.size(), " sel=", _selected)
