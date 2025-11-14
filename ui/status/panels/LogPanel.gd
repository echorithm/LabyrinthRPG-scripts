extends StatusPanel
class_name LogPanel

@onready var _list: ItemList = get_node(^"HSplitContainer/ItemList") as ItemList
@onready var _name_lbl: Label = get_node(^"HSplitContainer/VBoxContainer/DetailsBox/Name") as Label
@onready var _details_box: Control = get_node(^"HSplitContainer/VBoxContainer/DetailsBox") as Control
@onready var _split: HSplitContainer = get_node(^"HSplitContainer") as HSplitContainer

var _body_ctrl: Control = null                 # points to the "Stats" control (RichTextLabel)
var _body_rich: RichTextLabel = null
var _scroll: ScrollContainer = null

const PREVIEW_MAX := 56
const _PFX := "[LogPanel] "

func _ready() -> void:
	_ensure_details_nodes()

	# Pane sizing / defaults
	if _split:
		_split.split_offset = 300  # default left pane width
	if _list:
		_list.custom_minimum_size = Vector2(280, 0)
		_list.size_flags_horizontal = Control.SIZE_FILL
		_list.size_flags_vertical   = Control.SIZE_EXPAND_FILL

	# Title label: wrap + clip so long titles stay inside
	if _name_lbl:
		_name_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_name_lbl.clip_text = true
		_name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	_connect_log()
	refresh()

func on_enter() -> void:
	_connect_log()
	refresh()

func on_exit() -> void:
	if is_instance_valid(GameLog):
		if GameLog.entry_added.is_connected(_on_log_entry):
			GameLog.entry_added.disconnect(_on_log_entry)
		if GameLog.cleared.is_connected(_on_log_cleared):
			GameLog.cleared.disconnect(_on_log_cleared)

func _connect_log() -> void:
	if is_instance_valid(GameLog):
		if not GameLog.entry_added.is_connected(_on_log_entry):
			GameLog.entry_added.connect(_on_log_entry)
		if not GameLog.cleared.is_connected(_on_log_cleared):
			GameLog.cleared.connect(_on_log_cleared)

# ---------------- Render ----------------

func refresh() -> void:
	if _list == null:
		push_warning(_PFX + "ItemList missing")
		return

	_list.clear()
	_set_details("", "")

	var rows: Array[Dictionary] = []
	if is_instance_valid(GameLog):
		rows = GameLog.entries()

	# newest first
	rows = rows.duplicate()
	rows.reverse()

	for r in rows:
		if not (r is Dictionary):
			continue
		var line := _format_list_line(r as Dictionary)
		_list.add_item(line)
		var idx := _list.get_item_count() - 1
		_list.set_item_metadata(idx, r)

	if not _list.item_selected.is_connected(_on_item_selected):
		_list.item_selected.connect(_on_item_selected)

	if _list.get_item_count() > 0:
		_list.select(0)
		_on_item_selected(0)

func _on_log_entry(row: Dictionary) -> void:
	var line := _format_list_line(row)
	_list.insert_item(0, line)
	_list.set_item_metadata(0, row)

func _on_log_cleared() -> void:
	refresh()

func _on_item_selected(idx: int) -> void:
	if idx < 0 or idx >= _list.get_item_count():
		return
	var meta_any: Variant = _list.get_item_metadata(idx)
	if typeof(meta_any) != TYPE_DICTIONARY:
		return
	var row := meta_any as Dictionary
	_render_details(row)

# ---------------- UI helpers ----------------

func _format_list_line(row: Dictionary) -> String:
	var t := float(row.get("ts", 0.0))
	var lev := int(row.get("level", GameLog.Level.INFO))
	var cat := String(row.get("cat", "sys"))
	var msg := String(row.get("msg", "(empty)"))

	var total_secs := int(t)
	var mm := total_secs / 60
	var ss := total_secs % 60
	var time_s := "%02d:%02d" % [mm, ss]

	var tag := "INF"
	if lev == GameLog.Level.ERROR:
		tag = "ERR"
	elif lev == GameLog.Level.WARN:
		tag = "WRN"

	var preview := _elide(msg, PREVIEW_MAX)
	return "[%s] %s  —  %s" % [tag, _pad(cat, 8), "%s  %s" % [time_s, preview]]

func _render_details(row: Dictionary) -> void:
	var title := "%s — %s" % [String(row.get("cat","")), String(row.get("msg",""))]
	if _name_lbl:
		_name_lbl.text = title

	if _body_rich:
		var lev := int(row.get("level", GameLog.Level.INFO))
		var level_txt := "INFO"
		if lev == GameLog.Level.ERROR:
			level_txt = "ERROR"
		elif lev == GameLog.Level.WARN:
			level_txt = "WARN"

		var t := float(row.get("ts", 0.0))
		var data := (row.get("data", {}) as Dictionary)

		var lines := PackedStringArray()
		lines.push_back("[b]Level:[/b] %s" % level_txt)
		lines.push_back("[b]Time:[/b]  %.3fs since start" % t)
		lines.push_back("")
		lines.push_back("[b]Details:[/b]")
		if data.is_empty():
			lines.push_back("— None —")
		else:
			for k in data.keys():
				lines.push_back("• %s: %s" % [String(k), str(data[k])])

		_body_rich.bbcode_enabled = true
		_body_rich.text = ""
		_body_rich.append_text("\n".join(lines))
		_body_rich.call_deferred("scroll_to_line", 0)

func _set_details(title: String, body: String) -> void:
	if _name_lbl:
		_name_lbl.text = title
	if _body_rich:
		_body_rich.bbcode_enabled = false
		_body_rich.text = body

# ---------------- Node setup (robust) ----------------

func _ensure_details_nodes() -> void:
	if _details_box == null:
		push_warning(_PFX + "Missing DetailsBox; check scene paths.")
		return

	# Try path: DetailsBox/StatsScroll/Stats
	var stats_in_scroll := _details_box.get_node_or_null(^"StatsScroll/Stats") as Control
	# Fallback: DetailsBox/Stats
	var stats_direct := _details_box.get_node_or_null(^"Stats") as Control

	if stats_in_scroll != null:
		_scroll = _details_box.get_node_or_null(^"StatsScroll") as ScrollContainer
		_body_ctrl = stats_in_scroll
	elif stats_direct != null:
		# Create/move into a ScrollContainer
		_scroll = ScrollContainer.new()
		_scroll.name = "StatsScroll"
		_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_scroll.size_flags_vertical   = Control.SIZE_EXPAND_FILL
		_scroll.custom_minimum_size   = Vector2(0, 200)

		var idx: int = stats_direct.get_index()
		_details_box.remove_child(stats_direct)
		_details_box.add_child(_scroll)
		_details_box.move_child(_scroll, idx)
		_scroll.add_child(stats_direct)

		_body_ctrl = stats_direct
	else:
		# Create both nodes
		_scroll = ScrollContainer.new()
		_scroll.name = "StatsScroll"
		_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_scroll.size_flags_vertical   = Control.SIZE_EXPAND_FILL
		_scroll.custom_minimum_size   = Vector2(0, 200)
		_details_box.add_child(_scroll)

		var r := RichTextLabel.new()
		r.name = "Stats"
		r.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		r.size_flags_vertical   = Control.SIZE_EXPAND_FILL
		r.bbcode_enabled = true
		_scroll.add_child(r)

		_body_ctrl = r

	# At this point _body_ctrl must exist.
	if _body_ctrl is RichTextLabel:
		_body_rich = _body_ctrl as RichTextLabel
	else:
		# Replace non-rich label with RichTextLabel for formatting.
		var replacement := RichTextLabel.new()
		replacement.name = "Stats"
		replacement.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		replacement.size_flags_vertical   = Control.SIZE_EXPAND_FILL
		replacement.bbcode_enabled = true

		var p := _body_ctrl.get_parent()
		var i := _body_ctrl.get_index()
		p.remove_child(_body_ctrl)
		p.add_child(replacement)
		p.move_child(replacement, i)
		_body_ctrl.queue_free()

		_body_ctrl = replacement
		_body_rich = replacement

	# Final polish for the right-hand pane
	if _body_rich:
		_body_rich.bbcode_enabled = true
		_body_rich.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART  # or AUTOWRAP_ARBITRARY if you prefer
		_body_rich.fit_content = true
		_body_rich.scroll_active = true
		_body_rich.add_theme_constant_override("line_separation", 2)
		_body_rich.add_theme_constant_override("paragraph_separation", 4)

	if _scroll:
		_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
		_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED

# ---------------- Small string helpers ----------------

static func _pad(s: String, n: int) -> String:
	if s.length() >= n:
		return s
	return s + " ".repeat(n - s.length())

static func _elide(s: String, n: int) -> String:
	if s.length() <= n:
		return s
	var cut: int = max(0, n - 1)
	var sub := s.substr(0, cut)
	# Manually trim trailing whitespace (no rstrip in GDScript)
	while sub.length() > 0 and sub.unicode_at(sub.length() - 1) <= 32:
		sub = sub.substr(0, sub.length() - 1)
	return sub + "…"
