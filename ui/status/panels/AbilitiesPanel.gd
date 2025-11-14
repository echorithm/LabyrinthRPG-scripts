extends StatusPanel
class_name AbilitiesPanel

const AbilityCatalogService := preload("res://persistence/services/ability_catalog_service.gd")
const AbilityService        := preload("res://persistence/services/ability_service.gd")
const HealMath              := preload("res://scripts/combat/util/HealMath.gd")

# --- debug toggle for gesture drawing ---
const DEBUG_DRAW := true
func _dbg_draw(msg: String) -> void:
	if DEBUG_DRAW:
		print("[AbilitiesPanel/Draw] ", msg)

@onready var _list: ItemList = get_node_or_null(^"HSplitContainer/ItemList") as ItemList
@onready var _name_lbl: Label = get_node_or_null(^"HSplitContainer/VBoxContainer/DetailsBox/Name") as Label
@onready var _stats_lbl: Control = get_node_or_null(^"HSplitContainer/VBoxContainer/DetailsBox/Stats") as Control
@onready var _gesture_preview: Control = get_node_or_null(^"HSplitContainer/VBoxContainer/GesturePreview") as Control

var _gesture_line: Line2D = null
var _last_preview_id: String = ""
var _last_preview_points: PackedVector2Array = PackedVector2Array() # pre-normalized template
var _stats_scroll: ScrollContainer = null
var _right_vbox: VBoxContainer = null

# UI: Cast button
var _cast_btn: Button = null

# Remember current selection meta to drive the cast button
var _selected_meta: Dictionary = {}

# map ability id -> gesture id (you said everything is arc_slash now)
const ABILITY_TO_GESTURE: Dictionary = {
	"arc_slash": "arc_slash",
	"heal": "heala",
	# add others as needed; for now all point to arc_slash per your note
}

func _ready() -> void:
	if _list:
		if not _list.item_selected.is_connected(_on_item_selected):
			_list.item_selected.connect(_on_item_selected)
		# OOC cast trigger: double-click / Enter
		if not _list.item_activated.is_connected(_on_item_activated):
			_list.item_activated.connect(_on_item_activated)
	_init_gesture_preview()
	_connect_runstate()
	_normalize_right_layout()
	_ensure_cast_button()
	refresh()

func on_enter() -> void:
	_connect_runstate()
	refresh()

func on_exit() -> void:
	var rs := _rs()
	if rs and rs.changed.is_connected(_on_rs_changed):
		rs.changed.disconnect(_on_rs_changed)
	if _gesture_preview and _gesture_preview.resized.is_connected(_on_preview_resized):
		_gesture_preview.resized.disconnect(_on_preview_resized)

# ---------------- RunState plumbing ----------------
func _rs() -> Node: return get_node_or_null(^"/root/RunState")
func _connect_runstate() -> void:
	var rs := _rs()
	if rs and not rs.changed.is_connected(_on_rs_changed):
		rs.changed.connect(_on_rs_changed)

func _on_rs_changed() -> void:
	refresh()

# ---------------- UI / Data ----------------
func refresh() -> void:
	if _list == null:
		push_warning("[AbilitiesPanel] ItemList missing; check scene paths.")
		return

	var slot_i := _effective_slot()

	# Reset left list and right details
	_list.clear()
	if _name_lbl:
		_name_lbl.text = ""

	# Clear stats text safely (Label vs RichTextLabel)
	if _stats_lbl:
		if _stats_lbl is Label:
			(_stats_lbl as Label).text = ""
		elif _stats_lbl is RichTextLabel:
			var r := _stats_lbl as RichTextLabel
			r.text = ""
			r.call_deferred("scroll_to_line", 0)
	if _stats_scroll:
		_stats_scroll.call_deferred("set", "scroll_vertical", 0)

	# Clear gesture preview
	_set_preview_points("", PackedVector2Array())
	_selected_meta = {}
	_refresh_cast_button() # nothing selected yet

	# Populate from run
	var run: Dictionary = SaveManager.load_run(slot_i)
	var st_any: Variant = run.get("skill_tracks")
	if typeof(st_any) != TYPE_DICTIONARY:
		return

	var st: Dictionary = st_any
	var rows: Array = []  # Array[Dictionary]

	for k in st.keys():
		var aid := String(k)
		var row_any: Variant = st[aid]
		if typeof(row_any) != TYPE_DICTIONARY:
			continue
		var row: Dictionary = row_any
		if not bool(row.get("unlocked", false)):
			continue

		var lvl: int  = int(row.get("level", 1))
		var cur: int  = int(row.get("xp_current", 0))
		var need: int = int(row.get("xp_needed", 1))
		var name: String = AbilityCatalogService.display_name(aid)

		rows.append({
			"id": aid,
			"name": name,
			"level": lvl,
			"xp_current": cur,
			"xp_needed": need,
			"cap_band": int(row.get("cap_band", 0)),
			"last_milestone_applied": int(row.get("last_milestone_applied", 0))
		})

	rows.sort_custom(func(a, b): return String(a["name"]).naturalnocasecmp_to(String(b["name"])) < 0)

	for r in rows:
		var line: String = "%s   —   Lv %d   [%d / %d]" % [
			String(r["name"]), int(r["level"]), int(r["xp_current"]), int(r["xp_needed"])
		]
		_list.add_item(line)
		var idx := _list.get_item_count() - 1
		_list.set_item_metadata(idx, r)
		print("[AbilitiesPanel] + listed '%s' -> %s" % [String(r["id"]), line])

	if _list.get_item_count() > 0:
		_list.select(0)
		_on_item_selected(0)
	else:
		print("[AbilitiesPanel] nothing added (no unlocked skills).")

func _effective_slot() -> int:
	var s := _slot
	if s > 0: return s
	var rs := _rs()
	if rs:
		var v: Variant = rs.get("default_slot")
		if v != null and int(v) > 0:
			return int(v)
	return 1

# --- helper: bounds + degenerate check ---------------------------------
func _compute_bounds(points: PackedVector2Array) -> Dictionary:
	var minp := Vector2(INF, INF)
	var maxp := Vector2(-INF, -INF)
	for v in points:
		minp.x = minf(minp.x, v.x); minp.y = minf(minp.y, v.y)
		maxp.x = maxf(maxp.x, v.x); maxp.y = maxf(maxp.y, v.y)
	var size := maxp - minp
	var deg := (size.x <= 0.0 or size.y <= 0.0)
	return {
		"min": minp,
		"max": maxp,
		"size": size,
		"degenerate": deg
	}

func _on_item_selected(idx: int) -> void:
	if _list == null or idx < 0 or idx >= _list.get_item_count():
		return
	var meta_any: Variant = _list.get_item_metadata(idx)
	if typeof(meta_any) != TYPE_DICTIONARY:
		return

	var m: Dictionary = meta_any
	_selected_meta = m.duplicate(true)

	var aid: String   = String(m.get("id",""))
	var name: String  = String(m.get("name", aid))
	var lvl: int      = int(m.get("level", 1))
	var cur: int      = int(m.get("xp_current", 0))
	var need: int     = int(m.get("xp_needed", 1))
	var cap: int      = int(m.get("cap_band", 0))
	var last_ms: int  = int(m.get("last_milestone_applied", 0))

	print("[AbilitiesPanel] select idx=%d id=%s lvl=%d xp=%d/%d cap=%d ms=%d"
		% [idx, aid, lvl, cur, need, cap, last_ms])

	# Title
	if _name_lbl:
		_name_lbl.text = name

	# Pull catalog row and build details
	var row: Dictionary = AbilityCatalogService.get_by_id(aid)
	var elem: String    = String(row.get("element", "physical"))
	var scaling: String = String(row.get("scaling", "support"))
	var base_power: int = int(row.get("base_power", 0))
	var to_hit: bool    = bool(row.get("to_hit", true))
	var crit_ok: bool   = bool(row.get("crit_allowed", true))
	var tags_any        = row.get("tags", [])

	var cost_line: String    = _fmt_costs(aid, row)
	var bias_line: String    = _fmt_stat_bias(row.get("stat_bias", {}))
	var tags_line: String    = _fmt_tags(tags_any)
	var flags_line: String   = "%s%s" % [ ( "Auto-hit" if not to_hit else "Attack roll" ),
										  (", No crits" if not crit_ok else "" ) ]

	var lines := PackedStringArray()
	lines.push_back("Level %d" % lvl)
	lines.push_back("XP: %d / %d" % [cur, need])
	lines.push_back("Cap: %d" % cap)
	lines.push_back("Last Milestone: %d" % last_ms)
	lines.push_back("")  # spacer
	lines.push_back("Element: %s" % elem)
	lines.push_back("Scaling: %s" % scaling)
	lines.push_back("Base Power: %d" % base_power)
	lines.push_back(cost_line)
	lines.push_back(flags_line)
	if not bias_line.is_empty(): lines.push_back(bias_line)
	if not tags_line.is_empty(): lines.push_back(tags_line)

	var detail_text := _lines_to_text(lines)

	# Assign to Label or RichTextLabel
	if _stats_lbl:
		if _stats_lbl is Label:
			(_stats_lbl as Label).text = detail_text
		elif _stats_lbl is RichTextLabel:
			var r := _stats_lbl as RichTextLabel
			r.text = detail_text
			r.call_deferred("scroll_to_line", 0)
	if _stats_scroll:
		_stats_scroll.call_deferred("set", "scroll_vertical", 0)

	# ---- gesture preview ----
	var catalog_pts: PackedVector2Array = _gesture_points_for_ability(aid)
	var demo_pts: PackedVector2Array    = _gesture_points_for_gesture(aid)

	var chosen: PackedVector2Array = catalog_pts
	var b1 := _compute_bounds(chosen)
	var b2 := _compute_bounds(demo_pts)

	# Prefer non-degenerate set if available
	if chosen.size() == 0 or bool(b1["degenerate"]):
		if demo_pts.size() > 0 and not bool(b2["degenerate"]):
			chosen = demo_pts
			b1 = b2

	print("[AbilitiesPanel/Draw] select aid=%s  catalog_pts=%d  demo_pts=%d  using=%d"
		% [aid, catalog_pts.size(), demo_pts.size(), chosen.size()])

	_set_preview_points(aid, chosen)

	# Update Cast button state
	_refresh_cast_button()

# --- OOC cast trigger (double-click / Enter on list) -------------------------
func _on_item_activated(idx: int) -> void:
	if _list == null or idx < 0 or idx >= _list.get_item_count():
		return
	var meta_any: Variant = _list.get_item_metadata(idx)
	if typeof(meta_any) != TYPE_DICTIONARY:
		return
	var m: Dictionary = meta_any
	var aid: String = String(m.get("id",""))
	if aid == "heal":
		_cast_heal_out_of_combat(aid, m)

# --- Out-of-combat Heal casting path -----------------------------------------
func _cast_heal_out_of_combat(aid: String, meta_row: Dictionary) -> void:
	var slot_i := _effective_slot()
	var rs := _rs()
	if rs == null:
		push_warning("[AbilitiesPanel] RunState missing; cannot cast.")
		return

	# 1) Pay costs via RunState (authoritative deduct + save + reload)
	var pay: Dictionary = rs.pay_ability_costs(aid, slot_i)
	if not bool(pay.get("ok", false)):
		var reason := String(pay.get("reason", ""))
		print("[AbilitiesPanel] Heal cast failed: insufficient %s" % (reason if reason != "" else "resources"))
		return

	# 2) Gather inputs for HealMath
	var run: Dictionary = SaveManager.load_run(slot_i)
	var hp: int = int(run.get("hp", 0))
	var hpM: int = int(run.get("hp_max", 0))
	if hpM <= 0:
		print("[AbilitiesPanel] Heal: hp_max <= 0; abort.")
		return
	var attrs: Dictionary = (run.get("player_attributes", {}) as Dictionary) if run.has("player_attributes") else {}
	var WIS: int = int(attrs.get("WIS", 8))

	var lvl: int = AbilityService.level(aid, slot_i)

	# 3) Compute using static HealMath (no instancing)
	var h: Dictionary = HealMath.compute_full_from_id(aid, lvl, WIS, hp, hpM)
	var healed: int = int(h.get("healed", 0))

	# 4) Apply to RUN pools via RunState helper (saves + broadcasts)
	if healed > 0:
		rs.heal_hp(healed, true, slot_i)
		print("[AbilitiesPanel] Heal cast OOC: +%d HP (raw=%d, lvl=%d, WIS=%d)"
			% [healed, int(h.get("raw", 0)), lvl, WIS])
	else:
		print("[AbilitiesPanel] Heal cast OOC: no effect (at or near full HP).")

	# (Optional) If you want OOC shields from overheal:
	# var shield: int = int(h.get("shield", 0)); var dur: int = int(h.get("shield_duration", 0))
	# ...call your Buff/Status service to attach shield here...

	refresh()  # will also update button state

# ---------------- Cast button creation & state ------------------------------
func _ensure_cast_button() -> void:
	# Place the button under the right-side DetailsBox container (bottom)
	var details_box := get_node_or_null(^"HSplitContainer/VBoxContainer/DetailsBox") as Control
	if details_box == null:
		return

	_cast_btn = details_box.get_node_or_null(^"CastButton") as Button
	if _cast_btn == null:
		_cast_btn = Button.new()
		_cast_btn.name = "CastButton"
		_cast_btn.text = "Use"
		_cast_btn.size_flags_horizontal = Control.SIZE_SHRINK_END
		_cast_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		_cast_btn.tooltip_text = "Cast the selected ability out of combat"
		details_box.add_child(_cast_btn)
		# Nudge to the bottom visually
		details_box.move_child(_cast_btn, details_box.get_child_count() - 1)
	if not _cast_btn.pressed.is_connected(_on_cast_pressed):
		_cast_btn.pressed.connect(_on_cast_pressed)
	_refresh_cast_button()

func _on_cast_pressed() -> void:
	if _selected_meta.is_empty():
		return
	var aid: String = String(_selected_meta.get("id",""))
	if aid == "heal":
		_cast_heal_out_of_combat(aid, _selected_meta)

func _refresh_cast_button() -> void:
	if _cast_btn == null:
		return

	# Default disabled
	_cast_btn.disabled = true
	_cast_btn.text = "Use"

	if _selected_meta.is_empty():
		_cast_btn.tooltip_text = "Select an ability"
		return

	var aid: String = String(_selected_meta.get("id",""))
	if aid != "heal":
		_cast_btn.tooltip_text = "Only Heal can be cast out of combat"
		return

	# Check pools and costs
	var slot_i := _effective_slot()
	var run: Dictionary = SaveManager.load_run(slot_i)
	var hp: int = int(run.get("hp", 0))
	var hpM: int = int(run.get("hp_max", 0))
	var costs: Dictionary = AbilityCatalogService.costs(aid)
	var mp_cost: int = int(costs.get("mp", 0))
	var mp: int = int(run.get("mp", 0))

	if hp >= hpM:
		_cast_btn.tooltip_text = "HP is full"
		return
	if mp < mp_cost:
		_cast_btn.tooltip_text = "Not enough MP"
		return

	_cast_btn.disabled = false
	_cast_btn.tooltip_text = "Cast Heal"

# ---------------- Gesture preview ----------------

func _gesture_points_for_ability(aid: String) -> PackedVector2Array:
	var gid: String = String(ABILITY_TO_GESTURE.get(aid, aid))
	return _gesture_points_for_gesture(gid)

func _init_gesture_preview() -> void:
	if _gesture_preview == null:
		return
	# ensure a Line2D child exists
	_gesture_line = _gesture_preview.get_node_or_null(^"Line") as Line2D
	if _gesture_line == null:
		_gesture_line = Line2D.new()
		_gesture_line.name = "Line"
		_gesture_line.width = 4.0
		_gesture_line.default_color = Color(0.90, 0.90, 1.0, 1.0)
		_gesture_line.antialiased = true
		_gesture_line.joint_mode = Line2D.LINE_JOINT_ROUND
		_gesture_line.end_cap_mode = Line2D.LINE_CAP_ROUND
		_gesture_preview.add_child(_gesture_line)
		_dbg_draw("created Line2D under preview; z_index=%d" % _gesture_line.z_index)
	_gesture_preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if not _gesture_preview.resized.is_connected(_on_preview_resized):
		_gesture_preview.resized.connect(_on_preview_resized)

func _on_preview_resized() -> void:
	# Re-fit last points to the new rect
	if _last_preview_id == "" or _last_preview_points.is_empty():
		return
	_dbg_draw("resized -> refit id=%s new_rect=%s"
		% [_last_preview_id, str(_gesture_preview.get_rect())])
	_fit_and_draw(_last_preview_points)

func _set_preview_points(aid: String, points: PackedVector2Array) -> void:
	_last_preview_id = aid
	_last_preview_points = points.duplicate()
	_dbg_draw("set_preview id=%s, count=%d, preview_rect=%s"
		% [aid, points.size(), str(_gesture_preview.get_rect())])
	_fit_and_draw(points)

func _fit_and_draw(points: PackedVector2Array) -> void:
	if _gesture_preview == null or _gesture_line == null:
		return

	_gesture_line.clear_points()
	if points.is_empty():
		print("[AbilitiesPanel/Draw] fit_and_draw: empty points -> nothing to draw")
		return

	var info := _compute_bounds(points)
	var minp: Vector2 = info["min"]
	var size: Vector2 = info["size"]
	var deg: bool = info["degenerate"]

	# Epsilon pad for zero width/height so we don’t bail on flat lines
	if deg:
		if size.x <= 0.0: size.x = 1.0
		if size.y <= 0.0: size.y = 1.0

	var pad: float = 16.0
	var rect_size: Vector2 = _gesture_preview.get_rect().size
	var target: Vector2 = rect_size - Vector2(pad * 2.0, pad * 2.0)
	target.x = maxf(1.0, target.x)
	target.y = maxf(1.0, target.y)

	var sx: float = target.x / size.x
	var sy: float = target.y / size.y
	var s: float = minf(sx, sy)
	var off: Vector2 = (rect_size - (size * s)) * 0.5

	var fitted := PackedVector2Array()
	fitted.resize(points.size())
	for i in points.size():
		var v: Vector2 = points[i]
		fitted[i] = (v - minp) * s + off

	_gesture_line.points = fitted

	# Debug
	if points.size() >= 2:
		print("[AbilitiesPanel/Draw] fitted count=%d scale=%.3f off=%s first=%s last=%s"
			% [fitted.size(), s, str(off), str(fitted[0]), str(fitted[fitted.size()-1])])

# --- helpers (text formatting) -----------------------------------------------
func _lines_to_text(lines: PackedStringArray) -> String:
	var out := ""
	for i in lines.size():
		if i > 0: out += "\n"
		out += lines[i]
	return out

func _fmt_stat_bias(bias_any: Variant) -> String:
	if not (bias_any is Dictionary):
		return ""
	var bias: Dictionary = bias_any
	# stable order so it’s not jumpy
	var order := PackedStringArray(["STR","AGI","DEX","END","INT","WIS","CHA","LCK"])
	var parts := PackedStringArray()
	for k in order:
		if bias.has(k):
			var v := int(bias[k])
			if v != 0:
				parts.push_back("%s+%d" % [k, v])
	# fall back to whatever keys exist (if none matched order)
	if parts.is_empty():
		for k in bias.keys():
			parts.push_back("%s+%d" % [String(k), int(bias[k])])
	return "Stat Bias: %s" % (", ".join(parts) if parts.size() > 0 else "—")

func _fmt_costs(aid: String, row: Dictionary) -> String:
	# CTB from service; MP/STAM/CD straight from row
	var ctb := AbilityCatalogService.ctb_cost(aid)
	var mp  := int(row.get("mp_cost", 0))
	var st  := int(row.get("stam_cost", 0))
	var cd  := int(row.get("cooldown", 0))

	var chunks := PackedStringArray()
	if ctb > 0: chunks.push_back("CTB %d" % ctb)
	if mp  > 0: chunks.push_back("MP %d" % mp)
	if st  > 0: chunks.push_back("STAM %d" % st)
	if cd  > 0: chunks.push_back("CD %d" % cd)

	return "Cost: %s" % (", ".join(chunks) if chunks.size() > 0 else "—")

func _fmt_tags(tags_any: Variant) -> String:
	if tags_any is Array:
		var parts := PackedStringArray()
		for t in (tags_any as Array):
			parts.push_back(String(t))
		if parts.size() > 0:
			return "Tags: %s" % ", ".join(parts)
	return ""

# ---------------- Templates (demo vectors) ----------------
func _gesture_points_for_gesture(gesture_id: String) -> PackedVector2Array:
	match gesture_id:
		"arc_slash":
			return PackedVector2Array([Vector2(10,100), Vector2(190,100)])
		"riposte":
			return PackedVector2Array([Vector2(70,120), Vector2(95,145), Vector2(155,75)])
		"thrust":
			return PackedVector2Array([Vector2(40,160), Vector2(160,40)])
		"skewer":
			return PackedVector2Array([Vector2(60,150), Vector2(132,72), Vector2(162,98)])
		"crush":
			return PackedVector2Array([Vector2(100,40), Vector2(100,170)])
		"guard_break":
			return PackedVector2Array([Vector2(90,80), Vector2(90,150), Vector2(160,150)])
		"aimed_shot":
			return PackedVector2Array([Vector2(55,90), Vector2(165,100), Vector2(55,135)])
		"piercing_bolt":
			return PackedVector2Array([Vector2(40,110), Vector2(170,110), Vector2(150,90)])
		"heal":
			return PackedVector2Array([Vector2(40,150), Vector2(100,60), Vector2(160,150)])
		"purify":
			return PackedVector2Array([Vector2(60,150), Vector2(140,150), Vector2(100,70), Vector2(60,150)])
		"shadow_grasp":
			return PackedVector2Array([Vector2(110,40), Vector2(110,160), Vector2(145,150)])
		"curse_mark":
			return PackedVector2Array([Vector2(100,60), Vector2(150,110), Vector2(100,160), Vector2(50,110), Vector2(100,60)])
		"firebolt":
			return PackedVector2Array([Vector2(40,70), Vector2(100,150), Vector2(160,70)])
		"flame_wall":
			return PackedVector2Array([
				Vector2(60,140), Vector2(82,110), Vector2(98,95), Vector2(112,85),
				Vector2(124,80), Vector2(136,85), Vector2(150,95), Vector2(166,110),
				Vector2(188,140)
			])
		"water_jet":
			return PackedVector2Array([Vector2(50,110), Vector2(85,95), Vector2(120,110), Vector2(155,95)])
		"tide_surge":
			return PackedVector2Array([Vector2(200,80), Vector2(50,120), Vector2(200,160)])
		"stone_spikes":
			return PackedVector2Array([Vector2(60,90), Vector2(140,90), Vector2(60,140), Vector2(140,140)])
		"bulwark":
			return PackedVector2Array([Vector2(120,120), Vector2(260,120), Vector2(260,260), Vector2(120,260), Vector2(120,120)])
		"gust":
			return PackedVector2Array([Vector2(70,140), Vector2(78,120), Vector2(90,100), Vector2(110,85), Vector2(135,80)])
		"cyclone":
			return PackedVector2Array([Vector2(60,80), Vector2(85,115), Vector2(100,135), Vector2(115,145), Vector2(130,135), Vector2(145,115), Vector2(170,80)])
		"block":
			return PackedVector2Array([Vector2(100,170), Vector2(100,40)])
		"punch":
			return PackedVector2Array([Vector2(40,60), Vector2(160,140)])
		"rest":
			return PackedVector2Array([Vector2(120,60), Vector2(105,85), Vector2(120,110), Vector2(135,135), Vector2(120,160)])
		"meditate":
			return PackedVector2Array([Vector2(60,160), Vector2(90,60), Vector2(110,140), Vector2(130,60), Vector2(160,160)])
		_:
			return PackedVector2Array()

func _normalize_right_layout() -> void:
	# Right-side column container
	_right_vbox = get_node_or_null(^"HSplitContainer/VBoxContainer") as VBoxContainer
	if _right_vbox:
		_right_vbox.add_theme_constant_override("separation", 12)

	var details_box := get_node_or_null(^"HSplitContainer/VBoxContainer/DetailsBox") as Control

	# Ensure the stats text lives inside a ScrollContainer
	if details_box and _stats_lbl:
		_stats_scroll = details_box.get_node_or_null(^"StatsScroll") as ScrollContainer
		if _stats_scroll == null:
			_stats_scroll = ScrollContainer.new()
			_stats_scroll.name = "StatsScroll"
			_stats_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			_stats_scroll.size_flags_vertical   = Control.SIZE_EXPAND_FILL
			_stats_scroll.custom_minimum_size   = Vector2(0, 160)

			var parent := _stats_lbl.get_parent()
			var idx := _stats_lbl.get_index()
			parent.remove_child(_stats_lbl)
			parent.add_child(_stats_scroll)
			parent.move_child(_stats_scroll, idx)
			_stats_scroll.add_child(_stats_lbl)

			_stats_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			_stats_lbl.size_flags_vertical   = Control.SIZE_EXPAND_FILL
			if _stats_lbl is Label:
				(_stats_lbl as Label).autowrap_mode = TextServer.AUTOWRAP_WORD_SMART

	# Keep gesture preview visible
	if _gesture_preview:
		_gesture_preview.custom_minimum_size.y = 140.0
		_gesture_preview.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_gesture_preview.size_flags_vertical   = Control.SIZE_EXPAND_FILL
		var details := get_node_or_null(^"HSplitContainer/VBoxContainer/DetailsBox") as Control
		if details:
			details.size_flags_stretch_ratio = 2.0
		_gesture_preview.size_flags_stretch_ratio = 1.0
