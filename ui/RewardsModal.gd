extends Control
class_name RewardsModal

signal closed

# NEW: theme hook (inherits your ModalTheme.tres)
@export var ui_theme: Theme = preload("res://ui/themes/ModalTheme.tres")

@export var min_touch_target_px: int = 56
@export var fullscreen_threshold: Vector2i = Vector2i(1024, 700)
@export var mobile_fill_percent: Vector2 = Vector2(0.90, 0.88) # standard mobile size
@export var desktop_fill_percent: Vector2 = Vector2(0.70, 0.75) # how big on desktop/tablet
@export var debug_logs: bool = false   # ← toggle verbose logs here
@export var backdrop_color: Color = Color(0, 0, 0, 0.55) # standardized opacity

@onready var _panel: PanelContainer = PanelContainer.new()
@onready var _pad: MarginContainer = MarginContainer.new()
@onready var _v: VBoxContainer = VBoxContainer.new()
@onready var _title: Label = Label.new()
@onready var _body: RichTextLabel = RichTextLabel.new()
@onready var _btn: Button = Button.new()
@onready var _backdrop: ColorRect = ColorRect.new()

var _last_outcome: String = ""
var _is_chest: bool = false
var _should_pause: bool = true

func _dbg(msg: String, data: Variant = null) -> void:
	if not debug_logs:
		return
	if data == null:
		print("[RewardsModal] ", msg)
	else:
		var payload_str: String
		var t := typeof(data)
		if t == TYPE_DICTIONARY or t == TYPE_ARRAY:
			payload_str = JSON.stringify(data)
		else:
			payload_str = str(data)
		print("[RewardsModal] ", msg, "  ", payload_str)

func _ready() -> void:
	# Apply theme so Label/Button/RichTextLabel pick up your ModalTheme fonts/colors.
	if ui_theme:
		theme = ui_theme

	_body.bbcode_enabled = true
	_dbg("ready()")

	process_mode = Node.PROCESS_MODE_WHEN_PAUSED
	set_process_unhandled_input(true)
	set_anchors_preset(Control.PRESET_FULL_RECT)
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	size_flags_horizontal = Control.SIZE_EXPAND_FILL

	# Backdrop (standardized)
	_backdrop.name = "Backdrop"
	_backdrop.color = backdrop_color
	_backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	_backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	_backdrop.visible = false
	add_child(_backdrop)
	move_child(_backdrop, 0)
	_backdrop.gui_input.connect(func(e: InputEvent) -> void:
		if (e is InputEventMouseButton and (e as InputEventMouseButton).pressed) \
		or (e is InputEventScreenTouch and (e as InputEventScreenTouch).pressed):
			_on_continue()
	)

	# Centerer
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	center.size_flags_vertical = Control.SIZE_EXPAND_FILL
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE  # allow backdrop to receive outside taps
	add_child(center)

	# Panel
	add_child(_panel)
	remove_child(_panel)
	center.add_child(_panel)
	_panel.custom_minimum_size = Vector2(520, 280)
	_panel.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_panel.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_panel.clip_contents = true  # keep children inside background
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP

	# Padding inside the panel
	_panel.add_child(_pad)
	_pad.add_theme_constant_override("margin_left",  16)
	_pad.add_theme_constant_override("margin_right", 16)
	_pad.add_theme_constant_override("margin_top",   16)
	_pad.add_theme_constant_override("margin_bottom",16)

	# Content VBox
	_pad.add_child(_v)
	_v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_v.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_v.add_theme_constant_override("separation", 8)

	# Title (uses theme; we still bump size a bit)
	_v.add_child(_title)
	_title.text = "Rewards"
	_title.add_theme_font_size_override("font_size", 22)
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER

	# Body (theme handles font; keep scrollable)
	_v.add_child(_body)
	_body.autowrap_mode = TextServer.AUTOWRAP_WORD
	_body.scroll_active = true
	_body.fit_content = false
	_body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.custom_minimum_size = Vector2(0, 160)

	# Button
	_v.add_child(_btn)
	_btn.text = "Continue (Enter)"
	_btn.custom_minimum_size = Vector2(0, float(min_touch_target_px))
	_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_btn.pressed.connect(_on_continue)

	# Initial responsive layout + react to resize/rotation
	_apply_responsive_layout()
	connect("resized", Callable(self, "_apply_responsive_layout"))

func _apply_responsive_layout() -> void:
	var vp: Vector2 = get_viewport_rect().size
	var is_mobile: bool = (vp.x < float(fullscreen_threshold.x)) or (vp.y < float(fullscreen_threshold.y))
	_dbg("_apply_responsive_layout", {"vp": vp, "is_mobile": is_mobile})

	if is_mobile:
		var target: Vector2 = Vector2(vp.x * mobile_fill_percent.x, vp.y * mobile_fill_percent.y)
		target = target.clamp(Vector2(360, 280), vp * 0.98)
		_panel.custom_minimum_size = target
		_panel.size = target
		_title.add_theme_font_size_override("font_size", 24)
		_btn.custom_minimum_size.y = float(min_touch_target_px)
	else:
		var target2: Vector2 = Vector2(vp.x * desktop_fill_percent.x, vp.y * desktop_fill_percent.y)
		target2.x = max(target2.x, 520.0)
		target2.y = max(target2.y, 280.0)
		target2 = target2.clamp(Vector2.ZERO, vp * 0.96)
		_panel.custom_minimum_size = target2
		_panel.size = target2
		_title.add_theme_font_size_override("font_size", 22)
		_btn.custom_minimum_size.y = 44.0

func present(result: Dictionary) -> void:
	_dbg("present(data in)", result.duplicate(true))

	var gold: int = int(result.get("gold", 0))
	var xp: int = int(result.get("xp", 0))
	var items: Array = (result.get("items", []) as Array)
	var sxp_arr: Array = (result.get("skill_xp", []) as Array)
	var char_row: Dictionary = (result.get("char", {}) as Dictionary)

	var outcome: String = String(result.get("outcome", "victory"))
	_last_outcome = outcome

	# NEW: source-aware presentation (battle vs chest/quest)
	var source: String = String(result.get("source", "battle"))
	_is_chest = (source == "chest") or bool(result.get("chest_open", false))
	_should_pause = not _is_chest  # pause only during battle result screens

	var lines: Array[String] = []

	# Header (omit for chests)
	if not _is_chest:
		if outcome != "victory":
			lines.append("[center][b]Defeat[/b][/center]")
			lines.append("Progress lost this run; skill/character progress reset to current levels.")
		else:
			lines.append("[center][b]Victory![/b][/center]")
	else:
		_title.text = "Chest Rewards"
		_btn.text = "OK"

	# Enemy header (battle only)
	if not _is_chest:
		var enemy_name: String = String(
			result.get("enemy_display_name",
				result.get("monster_display_name",
					result.get("monster_slug", "")
				)
			)
		)
		var enemy_level: int = int(result.get("enemy_level", result.get("monster_level", 0)))
		var enemy_role: String = String(result.get("enemy_role", result.get("role", "")))

		_dbg("enemy header derived", {"name": enemy_name, "level": enemy_level, "role": enemy_role})

		if enemy_name != "" or enemy_level > 0 or enemy_role != "":
			var line := "[center]vs [b]%s[/b]" % (enemy_name if enemy_name != "" else "Enemy")
			if enemy_level > 0:
				line += "  Lv.%d" % enemy_level
			if enemy_role != "" and enemy_role != "trash":
				line += "  (%s)" % enemy_role.capitalize()
			line += "[/center]"
			lines.append(line)

	# Character row (optional)
	if not char_row.is_empty():
		var lvl: int = int(char_row.get("level", 1))
		var gained_lvls: int = int(char_row.get("levels_gained", 0))
		var gained_pts: int = int(char_row.get("points_gained", 0))
		var char_line: String = "[b]Character:[/b] Lv %d" % lvl
		if gained_lvls > 0:
			char_line += " (+%d level%s)" % [gained_lvls, ("" if gained_lvls == 1 else "s")]
		if gained_pts > 0:
			char_line += " — +%d stat point%s" % [gained_pts, ("" if gained_pts == 1 else "s")]
		lines.append(char_line)

	# Totals
	if xp > 0:
		var clvl: int = int(result.get("char_new_level", 0))
		var tail: String = "" if clvl <= 0 else " (Lv %d)" % clvl
		lines.append("[b]Character XP:[/b] %d%s" % [xp, tail])

	var pts_gained: int = int(result.get("points_gained", 0))
	var pts_total: int = int(result.get("run_points_unspent", -1))
	if pts_gained > 0:
		var suffix: String = ((" (Total: %d)" % pts_total) if pts_total >= 0 else "")
		lines.append("[b]Stat Points:[/b] +%d%s" % [pts_gained, suffix])

	var shards: int = int(result.get("shards", 0))
	if shards > 0:
		lines.append("[b]Shards:[/b] %d" % shards)
	if gold > 0:
		lines.append("[b]Gold:[/b] %d" % gold)

	# Skill XP
	if sxp_arr.size() > 0:
		var sorted: Array = sxp_arr.duplicate()
		sorted.sort_custom(func(a: Variant, b: Variant) -> bool:
			var ax: int = (int((a as Dictionary).get("xp", 0)) if a is Dictionary else 0)
			var bx: int = (int((b as Dictionary).get("xp", 0)) if b is Dictionary else 0)
			return ax > bx
		)
		for entry_any: Variant in sorted:
			if entry_any is Dictionary:
				var entry: Dictionary = entry_any
				var sid: String = String(entry.get("id", ""))
				var amt: int = int(entry.get("xp", 0))
				var lvl2: int = int(entry.get("new_level", 0))
				var tail2: String = ("" if lvl2 <= 0 else " (Lv %d)" % lvl2)
				lines.append("[b]Skill XP – %s:[/b] +%d%s" % [sid, amt, tail2])

	# Items
	if items.size() > 0:
		lines.append("[b]Items:[/b]")
		for it_any: Variant in items:
			if it_any is Dictionary:
				var it: Dictionary = it_any
				var name: String = ItemNames.display_name(String(it.get("id", "Unknown")))
				var qty: int = int(it.get("count", 1))
				lines.append("  • %s x%d" % [name, qty])

	if lines.is_empty():
		lines.append("No rewards this time.")

	_dbg("lines built", {"count": lines.size(), "lines": lines.duplicate()})

	var content: String = ""
	for i in lines.size():
		if i > 0: content += "\n"
		content += lines[i]

	_dbg("bbcode content", content)

	_body.clear()
	_body.parse_bbcode(content)

	if _body.has_method("get_parsed_text"):
		_dbg("parsed preview", _body.call("get_parsed_text"))

	_show_modal()

func _show_modal() -> void:
	_dbg("_show_modal()", {
		"panel_size": _panel.size,
		"panel_min": _panel.custom_minimum_size,
		"visible_before": visible
	})
	visible = true
	if is_instance_valid(_backdrop):
		_backdrop.visible = true
	if _should_pause:
		get_tree().paused = true
	focus_mode = Control.FOCUS_ALL
	_btn.grab_focus()
	_dbg("_show_modal() after", {"visible_after": visible})

func _on_continue() -> void:
	_dbg("_on_continue() closing modal")

	var cms := get_node_or_null(^"/root/CombatMusicService")
	if cms != null:
		# For battle result screens, hand off to CombatMusicService.
		if not _is_chest:
			if cms.has_method("stop_all"):
				cms.call("stop_all")
			if _last_outcome == "victory" and cms.has_method("resume_previous_bgms"):
				cms.call("resume_previous_bgms")
		# For chests / non-combat rewards, leave BGM alone.

	visible = false
	if is_instance_valid(_backdrop):
		_backdrop.visible = false
	get_tree().paused = false
	emit_signal("closed")


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event.is_action_pressed(&"ui_accept") or event.is_action_pressed(&"ui_cancel"):
		_on_continue()
