extends StatusPanel
class_name OverviewPanel

const ATTR_ORDER: PackedStringArray = ["STR","AGI","DEX","END","INT","WIS","CHA","LCK"]

# ---- left column refs ----
var _level_lbl: Label = null
var _xp_bar: ProgressBar = null
var _hp_bar: ProgressBar = null
var _mp_bar: ProgressBar = null
var _stam_bar: ProgressBar = null
var _gold_lbl: Label = null
var _shards_lbl: Label = null
var _floor_lbl: Label = null

# ---- right column (attributes) ----
var _points_lbl: Label = null
var _attr_labels: Dictionary = {}   # String -> Label
var _attr_plus: Dictionary = {}     # String -> Button

# -------------------------------------------------------
func _ready() -> void:
	_resolve_nodes()
	_wire_attr_buttons()
	_connect_runstate()
	_connect_rewards_orchestrator() # refresh on loot grants
	_normalize_stat_rows()
	refresh()

func on_enter() -> void:
	_connect_runstate()
	_connect_rewards_orchestrator()
	refresh()

func on_exit() -> void:
	var rs := _rs()
	if rs:
		if rs.changed.is_connected(_on_rs_changed):
			rs.changed.disconnect(_on_rs_changed)
		if rs.has_signal("pools_changed") and rs.pools_changed.is_connected(_on_rs_pools_changed):
			rs.pools_changed.disconnect(_on_rs_pools_changed)
	var orch := get_node_or_null(^"/root/RewardsOrchestrator")
	if orch and orch.has_signal("rewards_applied") and orch.rewards_applied.is_connected(_on_rewards_applied):
		orch.rewards_applied.disconnect(_on_rewards_applied)

# -------------------------------------------------------
# Safe get for Nodes (returns fallback if property is nil)
static func _g(obj: Object, key: String, fallback: Variant) -> Variant:
	if obj == null:
		return fallback
	var v: Variant = obj.get(key)
	return fallback if v == null else v

# Node resolution
func _n(path: NodePath) -> Node:
	return get_node_or_null(path)

func _resolve_nodes() -> void:
	# Left column
	_level_lbl = _n(^"HBox/VBoxContainer/Level") as Label
	_xp_bar    = _n(^"HBox/VBoxContainer/HBox_XP/XPBar") as ProgressBar
	_hp_bar    = _n(^"HBox/VBoxContainer/HBox_HP/HPBar") as ProgressBar
	_mp_bar    = _n(^"HBox/VBoxContainer/HBox_MP/MPBar") as ProgressBar
	_stam_bar  = _n(^"HBox/VBoxContainer/HBox_Stam/StamBar") as ProgressBar
	_gold_lbl   = _n(^"HBox/VBoxContainer/Currencies/Gold") as Label
	_shards_lbl = _n(^"HBox/VBoxContainer/Currencies/Shards") as Label
	_floor_lbl  = _n(^"HBox/VBoxContainer/Floor") as Label

	# Right column
	_points_lbl = _n(^"HBox/VBoxContainer_Stats/RemainingStats") as Label

	_attr_labels.clear()
	_attr_plus.clear()
	for a in ATTR_ORDER:
		var row_path: NodePath = NodePath("HBox/VBoxContainer_Stats/HBox_%s" % a)
		var row := _n(row_path) as HBoxContainer
		if row == null: continue
		var lbl := row.get_node_or_null(^"Label") as Label
		var btn := row.get_node_or_null(^"Button") as Button
		if lbl: _attr_labels[a] = lbl
		if btn: _attr_plus[a] = btn

func _wire_attr_buttons() -> void:
	for a in ATTR_ORDER:
		var b := _attr_plus.get(a, null) as Button
		if b and not b.pressed.is_connected(_on_attr_plus.bind(a)):
			b.pressed.connect(_on_attr_plus.bind(a))

func _connect_runstate() -> void:
	var rs := _rs()
	if rs:
		if not rs.changed.is_connected(_on_rs_changed):
			rs.changed.connect(_on_rs_changed)
		if rs.has_signal("pools_changed") and not rs.pools_changed.is_connected(_on_rs_pools_changed):
			rs.pools_changed.connect(_on_rs_pools_changed)

func _connect_rewards_orchestrator() -> void:
	var orch := get_node_or_null(^"/root/RewardsOrchestrator")
	if orch and orch.has_signal("rewards_applied") and not orch.rewards_applied.is_connected(_on_rewards_applied):
		orch.rewards_applied.connect(_on_rewards_applied)

# -------------------------------------------------------
# RunState helpers
func _rs() -> Node:
	return get_node_or_null(^"/root/RunState")

func _get_slot() -> int:
	var rs := _rs()
	return int(_g(rs, "default_slot", 1)) if rs else 1

# -------------------------------------------------------
# Signals
func _on_rs_changed() -> void:
	refresh()

func _on_rs_pools_changed(_hp: int, _hpm: int, _mp: int, _mpm: int) -> void:
	refresh()

func _on_rewards_applied(_delta: Dictionary) -> void:
	refresh()

# -------------------------------------------------------
# UI update
func refresh() -> void:
	var rs := _rs()
	if rs == null:
		return
	print("[OverviewPanel] refresh gold=", rs.get("gold"), " shards=", rs.get("shards"), " depth=", rs.get("depth"), " hp=", rs.get("hp"), "/", rs.get("hp_max"), " mp=", rs.get("mp"), "/", rs.get("mp_max"))


	# Level / XP
	if _level_lbl:
		var lvl: int = int(_g(rs, "char_level", _g(rs, "level", 1)))
		_level_lbl.text = "Level %d" % lvl

	if _xp_bar:
		var need: int = max(1, int(_g(rs, "char_xp_needed", 1)))
		var cur: int  = clampi(int(_g(rs, "char_xp_current", 0)), 0, need)
		_xp_bar.max_value = need
		_xp_bar.value = cur
		_xp_bar.tooltip_text = "%d / %d XP" % [cur, need]

	# Pools
	if _hp_bar:
		var hp_max: int = int(_g(rs, "hp_max", 1))
		var hp: int = clampi(int(_g(rs, "hp", 0)), 0, hp_max)
		_hp_bar.max_value = max(1, hp_max)
		_hp_bar.value = hp
		_hp_bar.tooltip_text = "%d / %d HP" % [hp, hp_max]

	if _mp_bar:
		var mp_max: int = int(_g(rs, "mp_max", 1))
		var mp: int = clampi(int(_g(rs, "mp", 0)), 0, mp_max)
		_mp_bar.max_value = max(1, mp_max)
		_mp_bar.value = mp
		_mp_bar.tooltip_text = "%d / %d MP" % [mp, mp_max]

	if _stam_bar:
		var sm_max: int = int(_g(rs, "stam_max", 1))
		var sm: int = clampi(int(_g(rs, "stam", 0)), 0, sm_max)
		_stam_bar.max_value = max(1, sm_max)
		_stam_bar.value = sm
		_stam_bar.tooltip_text = "%d / %d STAM" % [sm, sm_max]

	# Currencies / floor
	if _gold_lbl:
		_gold_lbl.text = str(int(_g(rs, "gold", 0)))
	if _shards_lbl:
		_shards_lbl.text = str(int(_g(rs, "shards", 0)))
	if _floor_lbl:
		_floor_lbl.text = "Floor %d" % int(_g(rs, "depth", _g(rs, "floor", 1)))

	# Attributes pane
	var points_left: int = int(_g(rs, "char_points_unspent", 0))
	if _points_lbl:
		_points_lbl.text = "Points: %d" % points_left

	var attrs: Dictionary = _g(rs, "char_attributes", {})
	for a in ATTR_ORDER:
		var v: int = int(attrs.get(a, 0))
		var lbl := _attr_labels.get(a, null) as Label
		if lbl:
			lbl.text = "%s: %d" % [a, v]
		var btn := _attr_plus.get(a, null) as Button
		if btn:
			btn.disabled = (points_left <= 0)

# -------------------------------------------------------
# Attribute allocation
func _on_attr_plus(attr: String) -> void:
	var rs := _rs()
	if rs == null:
		return
	if rs.has_method("spend_attribute_point"):
		var ok: bool = bool(rs.call("spend_attribute_point", attr, _get_slot()))
		if ok:
			refresh()

# -------------------------------------------------------
# Spacing / alignment for left column rows
func _normalize_stat_rows() -> void:
	var left := get_node_or_null(^"HBox/VBoxContainer") as VBoxContainer
	if left:
		left.add_theme_constant_override("separation", 10)

	var row_names: Array[String] = ["HBox_XP", "HBox_HP", "HBox_MP", "HBox_Stam"]
	for rn in row_names:
		var row_path: NodePath = NodePath("HBox/VBoxContainer/%s" % rn)
		var row := get_node_or_null(row_path) as HBoxContainer
		if row == null:
			continue

		row.custom_minimum_size.y = 28.0
		row.add_theme_constant_override("separation", 8)
		row.alignment = BoxContainer.ALIGNMENT_BEGIN

		# label column
		if row.get_child_count() >= 1 and row.get_child(0) is Label:
			var lab := row.get_child(0) as Label
			lab.custom_minimum_size.x = 80.0
			lab.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
			lab.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			lab.vertical_alignment = VERTICAL_ALIGNMENT_CENTER

		# bar column
		if row.get_child_count() >= 2 and row.get_child(1) is ProgressBar:
			var bar := row.get_child(1) as ProgressBar
			bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			bar.custom_minimum_size.y = 24.0
