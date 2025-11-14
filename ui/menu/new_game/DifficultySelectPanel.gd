extends Control
class_name DifficultySelectPanel

const DEBUG: bool = true
static func _dbg(msg: String) -> void:
	if DEBUG:
		print("[DiffPanel] ", msg)

# Accent kept as var (not const) to avoid non-const-expression warnings in some setups
var ACCENT: Color = Color(0.368627, 0.631373, 1.0, 1.0)

# Order + node-name mapping
var _order: Array[String] = ["C", "U", "R", "E", "A", "L", "M"]
var _tile_codes: Dictionary = {
	"tile_C": "C", "tile_U": "U", "tile_R": "R",
	"tile_E": "E", "tile_A": "A", "tile_L": "L", "tile_M": "M",
}

# Display names + cosmetic multipliers
var _code_name: Dictionary = {
	"C": "Common", "U": "Uncommon", "R": "Rare",
	"E": "Epic",   "A": "Ancient",  "L": "Legendary",
	"M": "Mythic",
}
var _xp_mult: Dictionary = {
	"C": "×1.00", "U": "×1.65", "R": "×2.62",
	"E": "×3.98", "A": "×5.74", "L": "×7.78", "M": "×9.79",
}

# Shell nodes
var _root: VBoxContainer
var _headline: Label
var _grid: GridContainer
var _help: RichTextLabel

# State
var _selected: String = "U"
var _buttons: Array[Button] = [] as Array[Button]

# Tile styles
var _sb_normal: StyleBoxFlat
var _sb_hover: StyleBoxFlat
var _sb_focus: StyleBoxFlat
var _sb_selected: StyleBoxFlat
var _sb_selected_hover: StyleBoxFlat

# ---------------- lifecycle ----------------
func _ready() -> void:
	_ensure_shell()
	_build_tile_styles()
	_wire_buttons()
	_layout_for_width(get_viewport_rect().size.x)
	_apply_selected_visuals()
	_update_help()

	var vp: Viewport = get_viewport()
	if vp != null and not vp.size_changed.is_connected(_on_viewport_resize):
		vp.size_changed.connect(_on_viewport_resize)

	_snapshot("ready")

# ---------------- shell / layout ----------------
func _ensure_shell() -> void:
	_root = get_node_or_null(^"VBoxContainer") as VBoxContainer
	if _root == null:
		var v: VBoxContainer = VBoxContainer.new()
		v.name = "VBoxContainer"
		v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		v.size_flags_vertical = Control.SIZE_EXPAND_FILL
		_root = v
		add_child(v)
	if not _root.has_theme_constant_override("separation"):
		_root.add_theme_constant_override("separation", 12)

	_headline = _root.get_node_or_null(^"Label") as Label
	if _headline == null:
		_headline = _root.get_node_or_null(^"Headline") as Label
	if _headline == null:
		var l: Label = Label.new()
		l.name = "Headline"
		_headline = l
		_root.add_child(l)
	_headline.text = "Select Difficulty"
	_headline.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT

	_grid = _root.get_node_or_null(^"GridContainer") as GridContainer
	if _grid == null:
		_grid = _root.get_node_or_null(^"Tiles") as GridContainer
	if _grid == null:
		var g: GridContainer = GridContainer.new()
		g.name = "GridContainer"
		_grid = g
		_root.add_child(g)
	_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_grid.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	if not _grid.has_theme_constant_override("h_separation"):
		_grid.add_theme_constant_override("h_separation", 12)
	if not _grid.has_theme_constant_override("v_separation"):
		_grid.add_theme_constant_override("v_separation", 12)

	_help = _root.get_node_or_null(^"Help") as RichTextLabel
	if _help == null:
		var r: RichTextLabel = RichTextLabel.new()
		r.name = "Help"
		_help = r
		_root.add_child(r)
	_help.fit_content = true
	_help.bbcode_enabled = true

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

# ---------------- buttons ----------------
func _wire_buttons() -> void:
	_buttons.clear()

	for code: String in _order:
		var node_name: String = _find_node_name_for_code(code)
		var btn: Button = _grid.get_node_or_null(NodePath(node_name)) as Button
		if btn == null:
			btn = _create_tile_button(node_name, code)
			_grid.add_child(btn)
		_style_tile_button(btn, code)
		_connect_tile_signals(btn, code)
		_buttons.append(btn)

	_buttons.sort_custom(Callable(self, "_cmp_buttons"))
	_setup_grid_navigation()

func _find_node_name_for_code(code: String) -> String:
	for n: String in _tile_codes.keys():
		var mapped: String = String(_tile_codes[n])
		if mapped == code:
			return n
	return "tile_%s" % code

func _create_tile_button(node_name: String, code: String) -> Button:
	var b: Button = Button.new()
	b.name = node_name
	b.text = _display_name(code)
	b.custom_minimum_size = Vector2(120.0, 110.0)
	b.focus_mode = Control.FOCUS_ALL
	b.toggle_mode = false
	b.flat = false
	return b

func _style_tile_button(b: Button, code: String) -> void:
	b.text = _display_name(code)
	b.add_theme_font_size_override("font_size", 20)
	b.add_theme_stylebox_override("normal", _sb_normal)
	b.add_theme_stylebox_override("hover", _sb_hover)
	b.add_theme_stylebox_override("pressed", _sb_selected_hover)
	b.add_theme_stylebox_override("focus", _sb_focus)

	var col: Color = _difficulty_color(code)
	b.add_theme_color_override("font_color", col)
	b.add_theme_color_override("font_hover_color", col)

	b.tooltip_text = "Difficulty: %s (%s)" % [_display_name(code), code]

func _connect_tile_signals(b: Button, code: String) -> void:
	if not b.pressed.is_connected(_on_tile_pressed):
		b.pressed.connect(_on_tile_pressed.bind(code))
	if not b.focus_entered.is_connected(_on_focus_enter):
		b.focus_entered.connect(_on_focus_enter.bind(b))
	if not b.focus_exited.is_connected(_on_focus_exit):
		b.focus_exited.connect(_on_focus_exit.bind(b))
	if not b.mouse_entered.is_connected(_on_hover_enter):
		b.mouse_entered.connect(_on_hover_enter.bind(b))
	if not b.mouse_exited.is_connected(_on_hover_exit):
		b.mouse_exited.connect(_on_hover_exit.bind(b))

func _display_name(code: String) -> String:
	return String(_code_name.get(code, code))

func _cmp_buttons(a: Button, b: Button) -> bool:
	var ca: String = String(_tile_codes.get(a.name, ""))
	var cb: String = String(_tile_codes.get(b.name, ""))
	var ai: int = _order.find(ca)
	var bi: int = _order.find(cb)
	return ai < bi

# ---------------- responsive layout ----------------
func _on_viewport_resize() -> void:
	_layout_for_width(get_viewport_rect().size.x)

func _layout_for_width(vp_w: float) -> void:
	if _grid == null:
		return
	var cols: int = 7 if vp_w >= 1380.0 else 4
	_grid.columns = cols

	var pad_px: float = 24.0
	var avail: float = max(720.0, vp_w - pad_px * 2.0)
	var tile_w: float = clamp(floor((avail - (cols - 1) * 12.0) / float(cols)), 112.0, 196.0)
	var tile_h: float = clamp(tile_w * 0.9, 100.0, 172.0)

	for b: Button in _buttons:
		b.custom_minimum_size = Vector2(tile_w, tile_h)

	_dbg("layout: vp_w=%.1f cols=%d tile=(%.0f,%.0f)" % [vp_w, cols, tile_w, tile_h])
	_setup_grid_navigation()

func _setup_grid_navigation() -> void:
	if _grid == null:
		return
	var cols: int = max(1, _grid.columns)
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

# ---------------- interactions ----------------
func _on_tile_pressed(code: String) -> void:
	_selected = code
	_dbg("pick=" + _selected)
	_apply_selected_visuals()
	_update_help()

func _on_focus_enter(b: Button) -> void:
	var t: Tween = create_tween()
	t.tween_property(b, "scale", Vector2(1.02, 1.02), 0.06)

func _on_focus_exit(b: Button) -> void:
	var t: Tween = create_tween()
	t.tween_property(b, "scale", Vector2.ONE, 0.06)

func _on_hover_enter(b: Button) -> void:
	var t: Tween = create_tween()
	t.tween_property(b, "scale", Vector2(1.03, 1.03), 0.08).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)

func _on_hover_exit(b: Button) -> void:
	var t: Tween = create_tween()
	t.tween_property(b, "scale", Vector2.ONE, 0.08).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)

# ---------------- visuals + help ----------------
func _apply_selected_visuals() -> void:
	for b: Button in _buttons:
		var code: String = String(_tile_codes.get(b.name, ""))
		var sel: bool = (code == _selected)

		b.add_theme_stylebox_override("normal", _sb_selected if sel else _sb_normal)

		var base_col: Color = _difficulty_color(code)
		var text_col: Color = base_col
		if not sel:
			text_col.a = 0.92
		b.add_theme_color_override("font_color", text_col)

		var hover_col: Color = base_col
		hover_col.a = 1.0
		b.add_theme_color_override("font_hover_color", hover_col)

func _update_help() -> void:
	var mult: String = String(_xp_mult.get(_selected, ""))
	_help.text = "[b]Selected[/b]: %s  •  XP to next level %s" % [_display_name(_selected), mult]

# ---------------- external API ----------------
func set_selected(code: String) -> void:
	var c: String = code.strip_edges().to_upper()
	_selected = (c if _order.has(c) else "U")
	_dbg("set_selected=" + _selected)
	_apply_selected_visuals()
	_update_help()

func get_selected() -> String:
	return _selected

# ---------------- difficulty color helper ----------------
func _difficulty_color(key: String) -> Color:
	var k: String = key.strip_edges().to_upper()
	match k:
		"C", "COMMON":
			return Color.hex(0xbfc3c7ff) # gray
		"U", "UNCOMMON":
			return Color.hex(0x67c37bff) # green
		"R", "RARE":
			return Color.hex(0x5aa0ffff) # blue
		"E", "EPIC":
			return Color.hex(0xb277ffff) # purple
		"A", "ANCIENT":
			return Color.hex(0xe7a64bff) # orange
		"L", "LEGENDARY":
			return Color.hex(0xffc342ff) # gold
		"M", "MYTHIC":
			return Color.hex(0xff6bd3ff) # pink
		_:
			return Color.WHITE

# ---------------- debug ----------------
func _snapshot(tag: String) -> void:
	if not DEBUG:
		return
	var vp: Vector2 = get_viewport_rect().size
	print("[DiffPanel] snap=", tag, " vp=", vp, " cols=", (_grid.columns if _grid != null else -1),
		" btns=", _buttons.size(), " sel=", _selected)
