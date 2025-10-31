# res://scripts/combat/ui/BattleHUD.gd
extends Control
class_name BattleHUD

const GameMenuScript := preload("res://ui/hud/GameMenu.gd")

@export var right_menu_safe_margin_px: int = 180

var _p_hp: Label
var _p_mp: Label
var _p_st: Label
var _m_hp: Label
var _menu: MenuButton
var _m_name: Label

# CTB UI
var _p_ctb_bar: ProgressBar
var _m_ctb_bar: ProgressBar
var _p_ctb_label: Label
var _m_ctb_label: Label

func _ready() -> void:
	# Allow BattleController FCT lookups to find this HUD
	if not is_in_group("battle_hud"):
		add_to_group("battle_hud")

	# Let children (like GameMenu) handle input while HUD itself doesn't block
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)

	# ---------------- Top bar ----------------
	var top := HBoxContainer.new()
	top.name = "TopBar"
	top.anchor_left = 0
	top.anchor_top = 0
	top.anchor_right = 1
	top.anchor_bottom = 0
	top.offset_left = 12
	top.offset_top = 10
	top.offset_right = -12
	add_child(top)

	# Player column (left)
	var pcol := VBoxContainer.new()
	pcol.name = "PlayerCol"
	pcol.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(pcol)

	_p_hp = _mk_label(18, Color8(230,230,230)) # HP white
	_p_mp = _mk_label(18, Color.hex(0x4aa3ff)) # MP blue
	_p_st = _mk_label(18, Color.hex(0x2ecc71)) # ST green-ish

	pcol.add_child(_p_hp)
	pcol.add_child(_p_mp)
	pcol.add_child(_p_st)

	# --- Player CTB row ---
	var p_ctb_row := HBoxContainer.new()
	p_ctb_row.custom_minimum_size = Vector2(220, 0)
	pcol.add_child(p_ctb_row)

	_p_ctb_label = _mk_label(14, Color8(200,200,200))
	_p_ctb_label.text = "CTB"
	_p_ctb_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	p_ctb_row.add_child(_p_ctb_label)

	_p_ctb_bar = _mk_ctb_bar(Color.hex(0x4aa3ff), Color.hex(0x2ecc71))
	_p_ctb_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	p_ctb_row.add_child(_p_ctb_bar)

	# Spacer
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(spacer)

	# Monster column (right)
	var mcol := VBoxContainer.new()
	mcol.name = "MonsterCol"
	mcol.alignment = BoxContainer.ALIGNMENT_END
	top.add_child(mcol)

	_m_name = _mk_label(20, Color8(240, 240, 240))
	_m_name.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_m_name.text = "Enemy"
	mcol.add_child(_m_name)

	_m_hp = _mk_label(18, Color8(230,230,230))
	_m_hp.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	mcol.add_child(_m_hp)

	# --- Monster CTB row ---
	var m_ctb_row := HBoxContainer.new()
	m_ctb_row.custom_minimum_size = Vector2(220, 0)
	mcol.add_child(m_ctb_row)

	_m_ctb_label = _mk_label(14, Color8(200,200,200))
	_m_ctb_label.text = "CTB"
	_m_ctb_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	m_ctb_row.add_child(_m_ctb_label)

	_m_ctb_bar = _mk_ctb_bar(Color.hex(0xff7f50), Color.hex(0xffd166)) # coral → ready amber
	_m_ctb_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	m_ctb_row.add_child(_m_ctb_bar)

	# Defaults
	_p_hp.text = "HP  — / —"
	_p_mp.text = "MP  — / —"
	_p_st.text = "ST  — / —"
	_m_hp.text = "Enemy HP  — / —"
	_set_ctb(_p_ctb_bar, _p_ctb_label, 0.0, false, 1000.0)
	_set_ctb(_m_ctb_bar, _m_ctb_label, 0.0, false, 1000.0)

	# ---------------- Game Menu (top-right) ----------------
	_menu = GameMenuScript.new()
	_menu.name = "GameMenu_Battle"
	add_child(_menu)
	var is_small_screen: bool = get_viewport_rect().size.x <= 900.0
	var edge_margin: int = 30 if is_small_screen else 24
	_menu.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT, Control.PRESET_MODE_MINSIZE, edge_margin)

	# Reserve right margin on the top bar so labels don't sit under the menu.
	await get_tree().process_frame  # let _menu size settle
	_reserve_right_margin_for_menu(top)

func _mk_label(size: int, col: Color) -> Label:
	var L := Label.new()
	L.add_theme_font_size_override("font_size", size)
	L.add_theme_color_override("font_color", col)
	L.autowrap_mode = TextServer.AUTOWRAP_OFF
	return L

func _mk_ctb_bar(col_normal: Color, col_ready: Color) -> ProgressBar:
	var pb := ProgressBar.new()
	pb.name = "CTBBar"
	pb.min_value = 0.0
	pb.max_value = 100.0
	pb.value = 0.0
	pb.rounded = true
	pb.show_percentage = false
	pb.self_modulate = col_normal
	pb.set_meta("ready_color", col_ready)
	pb.set_meta("normal_color", col_normal)
	pb.custom_minimum_size = Vector2(140, 10)
	return pb

func set_snapshot(snapshot: Dictionary) -> void:
	if snapshot.is_empty():
		return

	var p := snapshot.get("player", {}) as Dictionary
	var m := snapshot.get("monster", {}) as Dictionary

	# Player pools
	if not p.is_empty():
		var php := int(p.get("hp", 0))
		var phpM := int(p.get("hp_max", 0))
		var pmp := int(p.get("mp", 0))
		var pmpM := int(p.get("mp_max", 0))
		var pst := int(p.get("stam", p.get("st", 0)))
		var pstM := int(p.get("stam_max", p.get("st_max", 0)))

		_p_hp.text = "HP  %d / %d" % [php, phpM]
		_p_mp.text = "MP  %d / %d" % [pmp, pmpM]
		_p_st.text = "ST  %d / %d" % [pst, pstM]

	# Monster pools + header
	if not m.is_empty():
		var mhp := int(m.get("hp", 0))
		var mhpM := int(m.get("hp_max", 0))

		# New: name + level header
		var name := String(m.get("name", "Enemy"))
		var level := int(m.get("level", 0))
		_m_name.text = ("%s  Lv.%d" % [name, level]) if level > 0 else name

		_m_hp.text = "Enemy HP  %d / %d" % [mhp, mhpM]

	# CTB
	var ctb := snapshot.get("ctb", {}) as Dictionary
	if not ctb.is_empty():
		var p_ctb := ctb.get("p", {}) as Dictionary
		var m_ctb := ctb.get("m", {}) as Dictionary

		if not p_ctb.is_empty():
			var g_p := float(p_ctb.get("gauge", 0.0))
			var size_p := float(p_ctb.get("size", 1.0))
			var ready_p := bool(p_ctb.get("ready", false))
			_set_ctb(_p_ctb_bar, _p_ctb_label, (g_p / max(1.0, size_p)) * 100.0, ready_p, size_p)

		if not m_ctb.is_empty():
			var g_m := float(m_ctb.get("gauge", 0.0))
			var size_m := float(m_ctb.get("size", 1.0))
			var ready_m := bool(m_ctb.get("ready", false))
			_set_ctb(_m_ctb_bar, _m_ctb_label, (g_m / max(1.0, size_m)) * 100.0, ready_m, size_m)

func _set_ctb(bar: ProgressBar, lab: Label, pct_value: float, is_ready: bool, size_units: float) -> void:
	if bar == null or lab == null:
		return
	bar.value = clampf(pct_value, 0.0, 100.0)
	var normal_col: Color = bar.get_meta("normal_color", Color(1,1,1)) as Color
	var ready_col: Color = bar.get_meta("ready_color", Color(1,1,1)) as Color
	bar.self_modulate = (ready_col if is_ready else normal_col)
	lab.text = "CTB%s" % (" READY" if is_ready else "")
	bar.tooltip_text = "CTB: %.0f%%  (size: %.0f)" % [bar.value, size_units]

func _reserve_right_margin_for_menu(top: Control) -> void:
	if top == null:
		return
	var edge_margin: int = 30 if get_viewport_rect().size.x <= 900.0 else 24
	var menu_w: float = 0.0
	if _menu != null:
		menu_w = max(_menu.size.x, _menu.get_combined_minimum_size().x)
	var reserve: int = max(right_menu_safe_margin_px, int(ceil(menu_w + edge_margin + 8.0)))
	top.offset_right = -reserve

func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		var top := get_node_or_null(^"TopBar") as Control
		_reserve_right_margin_for_menu(top)
