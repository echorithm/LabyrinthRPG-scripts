extends Control
class_name SummaryConfirmPanel

const DEBUG: bool = true
static func _dbg(msg: String) -> void:
	if DEBUG:
		print("[SummaryPanel] ", msg)

# Accent + layout sizing
var ACCENT: Color = Color(0.368627, 0.631373, 1.0, 1.0)

const H_SEP_PX: int = 12
const PAD_PX: int = 24
const CARD_MIN_W: float = 200.0
const CARD_MAX_W: float = 360.0
const CARD_ASPECT: float = 0.88
const TITLE_PX: int = 16
const VALUE_PX: int = 22
const DETAIL_PX: int = 16

# Nodes (resolved defensively; may be null before _ready)
var _headline: Label
var _row: HBoxContainer
var _box_diff: VBoxContainer
var _box_weap: VBoxContainer
var _box_elem: VBoxContainer
var _chk_tutorial: CheckBox

# Styles
var _sb_card: StyleBoxFlat
var _sb_card_emph: StyleBoxFlat

# Lookups
var _diff_name: Dictionary = {
	"C": "Common", "U": "Uncommon", "R": "Rare", "E": "Epic",
	"A": "Ancient", "L": "Legendary", "M": "Mythic",
}
var _xp_mult: Dictionary = {
	"C": "×1.00", "U": "×1.65", "R": "×2.62",
	"E": "×3.98", "A": "×5.74", "L": "×7.78", "M": "×9.79",
}


# ---------------- lifecycle ----------------
func _ready() -> void:
	_resolve_nodes()
	_ensure_shell()
	_build_card_styles()
	_apply_base_layout()
	_layout_for_width(get_viewport_rect().size.x)

	var vp: Viewport = get_viewport()
	if vp != null and not vp.size_changed.is_connected(_on_viewport_size_changed):
		vp.size_changed.connect(_on_viewport_size_changed)

	if _headline != null:
		_headline.text = "Confirm New Game"

	_dbg("_ready")

func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_resolve_nodes()
		_ensure_shell()
		_layout_for_width(get_viewport_rect().size.x)

# ---------------- external API ----------------
func refresh_from_service(svc: NewGameService) -> void:
	_resolve_nodes()
	_ensure_shell()

	var code: String = svc.difficulty_code.strip_edges().to_upper()
	var name: String = String(_diff_name.get(code, code))
	var mult: String = String(_xp_mult.get(code, ""))
	var diff_value: String = "%s (%s)%s" % [
		name, code, ("  •  %s" % mult) if not mult.is_empty() else ""
		]

	# Difficulty: name/code/multiplier (no details)
	_fill_box(_box_diff, "Difficulty", diff_value)

	# Weapon + Element: include ability previews (two lines)
	var weap_details: Array[String] = _format_abilities(svc.weapon_starting_abilities())
	var elem_details: Array[String] = _format_abilities(svc.element_starting_abilities())
	_fill_box_with_details(_box_weap, "Weapon", svc.weapon_family.capitalize(), weap_details)
	_fill_box_with_details(_box_elem, "Element", svc.element_id.capitalize(), elem_details)

	_dbg("refresh: diff=%s weapon=%s elem=%s" % [svc.difficulty_code, svc.weapon_family, svc.element_id])

func set_start_tutorial(b: bool) -> void:
	_resolve_nodes()
	_ensure_shell()
	if _chk_tutorial != null:
		_chk_tutorial.button_pressed = b
	_dbg("start_tutorial=" + str(b))

func get_start_tutorial() -> bool:
	_resolve_nodes()
	_ensure_shell()
	return (_chk_tutorial.button_pressed if _chk_tutorial != null else true)

# ---------------- node resolution / shell ----------------
func _resolve_nodes() -> void:
	if _headline == null:
		_headline = get_node_or_null(^"VBoxContainer/Headline") as Label
	if _row == null:
		_row = get_node_or_null(^"VBoxContainer/HBoxContainer") as HBoxContainer
	if _box_diff == null:
		_box_diff = get_node_or_null(^"VBoxContainer/HBoxContainer/DifficultyBox") as VBoxContainer
	if _box_weap == null:
		_box_weap = get_node_or_null(^"VBoxContainer/HBoxContainer/WeaponBox") as VBoxContainer
	if _box_elem == null:
		_box_elem = get_node_or_null(^"VBoxContainer/HBoxContainer/ElementBox") as VBoxContainer
	if _chk_tutorial == null:
		_chk_tutorial = get_node_or_null(^"VBoxContainer/chk_start_tutorial") as CheckBox

func _ensure_shell() -> void:
	# Root VBox
	var root: VBoxContainer = get_node_or_null(^"VBoxContainer") as VBoxContainer
	if root == null:
		root = VBoxContainer.new()
		root.name = "VBoxContainer"
		root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		root.size_flags_vertical = Control.SIZE_EXPAND_FILL
		add_child(root)
	if not root.has_theme_constant_override("separation"):
		root.add_theme_constant_override("separation", 12)

	# Headline
	if _headline == null:
		var hl: Label = Label.new()
		hl.name = "Headline"
		root.add_child(hl)
		_headline = hl

	# Row
	if _row == null:
		var hb: HBoxContainer = HBoxContainer.new()
		hb.name = "HBoxContainer"
		hb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		hb.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		root.add_child(hb)
		_row = hb
	if not _row.has_theme_constant_override("separation"):
		_row.add_theme_constant_override("separation", H_SEP_PX)

	# Ensure three logical boxes
	_box_diff = _get_or_create_box("DifficultyBox")
	_box_weap = _get_or_create_box("WeaponBox")
	_box_elem = _get_or_create_box("ElementBox")

	# Checkbox (indicator for start/skip tutorial)
	if _chk_tutorial == null:
		var cb: CheckBox = CheckBox.new()
		cb.name = "chk_start_tutorial"
		cb.text = "Start with Tutorial"
		root.add_child(cb)
		_chk_tutorial = cb

func _get_or_create_box(name_s: String) -> VBoxContainer:
	var vb: VBoxContainer = _row.get_node_or_null(NodePath(name_s)) as VBoxContainer if _row != null else null
	if vb == null:
		vb = VBoxContainer.new()
		vb.name = name_s
		vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		vb.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		if _row != null:
			_row.add_child(vb)
	if not vb.has_theme_constant_override("separation"):
		vb.add_theme_constant_override("separation", 6)
	return vb

func _apply_base_layout() -> void:
	if _headline != null:
		_headline.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		_headline.add_theme_font_size_override("font_size", 20)
	if _chk_tutorial != null:
		# Mirror-only indicator; the footer in NewGameFlow handles the toggle.
		_chk_tutorial.disabled = true
		_chk_tutorial.focus_mode = Control.FOCUS_ALL
		_chk_tutorial.tooltip_text = "Mirrors the footer’s Skip Tutorial toggle."

# ---------------- styles ----------------
func _build_card_styles() -> void:
	var base_bg: Color = Color(0.12, 0.13, 0.15, 0.95)
	var border_dim: Color = Color(1, 1, 1, 0.12)
	var border_acc: Color = ACCENT * Color(1, 1, 1, 0.90)

	_sb_card = _make_card_style(base_bg, border_dim)
	_sb_card_emph = _make_card_style(base_bg.lerp(ACCENT, 0.10), border_acc)

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

# ---------------- card helpers ----------------
func _ensure_card(box: VBoxContainer, emphasized: bool) -> PanelContainer:
	# Guard against null (shouldn't happen after _ensure_shell/_resolve_nodes)
	if box == null:
		var dummy: PanelContainer = PanelContainer.new()
		return dummy

	# One-time cleanup of any legacy contents
	if not box.has_meta("card_built"):
		for c: Node in box.get_children():
			c.queue_free()
		box.set_meta("card_built", true)

	var card: PanelContainer = box.get_node_or_null(^"Card") as PanelContainer
	if card == null:
		card = PanelContainer.new()
		card.name = "Card"
		card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		card.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		card.custom_minimum_size = Vector2(CARD_MIN_W, CARD_MIN_W * CARD_ASPECT)
		box.add_child(card)

		var inner: VBoxContainer = VBoxContainer.new()
		inner.name = "Inner"
		inner.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		inner.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		if not inner.has_theme_constant_override("separation"):
			inner.add_theme_constant_override("separation", 4)
		card.add_child(inner)

		var t: Label = Label.new()
		t.name = "Title"
		t.add_theme_font_size_override("font_size", TITLE_PX)
		t.add_theme_color_override("font_color", Color(1, 1, 1, 0.85))
		inner.add_child(t)

		var v: Label = Label.new()
		v.name = "Value"
		v.add_theme_font_size_override("font_size", VALUE_PX)
		inner.add_child(v)

		# Optional detail lines for ability previews
		var d1: Label = Label.new()
		d1.name = "Detail1"
		d1.add_theme_font_size_override("font_size", DETAIL_PX)
		d1.add_theme_color_override("font_color", Color(1, 1, 1, 0.80))
		inner.add_child(d1)

		var d2: Label = Label.new()
		d2.name = "Detail2"
		d2.add_theme_font_size_override("font_size", DETAIL_PX)
		d2.add_theme_color_override("font_color", Color(1, 1, 1, 0.80))
		inner.add_child(d2)

	card.add_theme_stylebox_override("panel", _sb_card_emph if emphasized else _sb_card)
	return card

func _fill_box(box: VBoxContainer, title: String, value: String) -> void:
	_fill_box_with_details(box, title, value, [] as Array[String])

func _fill_box_with_details(box: VBoxContainer, title: String, value: String, details: Array[String]) -> void:
	var emphasized: bool = (title == "Difficulty")
	var card: PanelContainer = _ensure_card(box, emphasized)
	var inner: VBoxContainer = card.get_node_or_null(^"Inner") as VBoxContainer
	if inner == null:
		return

	var t: Label = inner.get_node_or_null(^"Title") as Label
	var v: Label = inner.get_node_or_null(^"Value") as Label
	var d1: Label = inner.get_node_or_null(^"Detail1") as Label
	var d2: Label = inner.get_node_or_null(^"Detail2") as Label

	if t != null:
		t.text = title
	if v != null:
		v.text = value

	# Show up to 2 lines of details (weapon/element abilities)
	var line1: String = (details[0] if details.size() >= 1 else "")
	var line2: String = (details[1] if details.size() >= 2 else "")
	if d1 != null:
		d1.text = line1
		d1.visible = not line1.is_empty()
	if d2 != null:
		d2.text = line2
		d2.visible = not line2.is_empty()

# ---------------- formatting helpers ----------------
func _format_abilities(ids: Array[String]) -> Array[String]:
	var out: Array[String] = [] as Array[String]
	for id: String in ids:
		out.append(_title_from_snake(id))
	return out

func _title_from_snake(s: String) -> String:
	var parts: PackedStringArray = s.split("_")
	var out_parts: Array[String] = [] as Array[String]
	for p: String in parts:
		var seg: String = p
		if seg.length() >= 1:
			seg = seg.left(1).to_upper() + seg.substr(1)
		out_parts.append(seg)
	return " ".join(out_parts)

# ---------------- responsive layout ----------------
func _on_viewport_size_changed() -> void:
	_resolve_nodes()
	_ensure_shell()
	_layout_for_width(get_viewport_rect().size.x)

func _layout_for_width(vp_w: float) -> void:
	_resolve_nodes()
	_ensure_shell()

	var cols: int = 3
	var avail: float = max(720.0, vp_w - float(PAD_PX) * 2.0)
	var card_w: float = clamp(
		floor((avail - float(cols - 1) * float(H_SEP_PX)) / float(cols)),
		CARD_MIN_W, CARD_MAX_W
	)
	var card_h: float = clamp(card_w * CARD_ASPECT, 110.0, 180.0)

	var diff_box: VBoxContainer = _box_diff if _box_diff != null else _get_or_create_box("DifficultyBox")
	var weap_box: VBoxContainer = _box_weap if _box_weap != null else _get_or_create_box("WeaponBox")
	var elem_box: VBoxContainer = _box_elem if _box_elem != null else _get_or_create_box("ElementBox")

	var cards: Array[PanelContainer] = [] as Array[PanelContainer]
	cards.append(_ensure_card(diff_box, true))
	cards.append(_ensure_card(weap_box, false))
	cards.append(_ensure_card(elem_box, false))

	for c: PanelContainer in cards:
		c.custom_minimum_size = Vector2(card_w, card_h)

	_dbg("layout: vp_w=%.1f card=(%.0f,%.0f)" % [vp_w, card_w, card_h])
