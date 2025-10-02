extends Control
class_name RewardsModal

signal closed

@onready var _panel: PanelContainer = PanelContainer.new()
@onready var _v: VBoxContainer = VBoxContainer.new()
@onready var _title: Label = Label.new()
@onready var _body: RichTextLabel = RichTextLabel.new()
@onready var _btn: Button = Button.new()

func _ready() -> void:
	print("[RewardsModal] ready")
	_body.bbcode_enabled = true

	process_mode = Node.PROCESS_MODE_WHEN_PAUSED
	# The modal only needs to listen for accept/cancel while visible.
	set_process_unhandled_input(true)

	set_anchors_preset(Control.PRESET_FULL_RECT)
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	size_flags_horizontal = Control.SIZE_EXPAND_FILL

	# --- Centering container ---
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	center.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(center)

	# Panel inside the centerer
	add_child(_panel)            # keep for theme; reparent to center
	remove_child(_panel)
	center.add_child(_panel)

	_panel.custom_minimum_size = Vector2(520, 280)
	_panel.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_panel.size_flags_vertical = Control.SIZE_SHRINK_CENTER

	_panel.add_child(_v)
	_v.add_child(_title)
	_title.text = "Rewards"
	_title.add_theme_font_size_override("font_size", 24)
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER

	_v.add_child(_body)
	_body.fit_content = true
	_body.autowrap_mode = TextServer.AUTOWRAP_WORD

	_v.add_child(_btn)
	_btn.text = "Continue (Enter)"
	_btn.pressed.connect(_on_continue)

func present(result: Dictionary) -> void:
	var gold: int = int(result.get("gold", 0))
	var xp: int = int(result.get("xp", 0))
	var items: Array = (result.get("items", []) as Array)
	var sxp_arr: Array = (result.get("skill_xp", []) as Array)
	var char_row: Dictionary = (result.get("char", {}) as Dictionary) # optional “char” bundle
	var outcome: String = String(result.get("outcome", "victory"))

	var lines: Array[String] = []

	# Outcome banner
	if outcome != "victory":
		lines.append("[center][b]Defeat[/b][/center]")
		lines.append("Progress lost this run; skill/character progress reset to current levels.")
	else:
		lines.append("[center][b]Victory![/b][/center]")

	# Character: level / level-ups / points
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

	# Character XP number (compatible with older receipts too)
	if xp > 0:
		var clvl: int = int(result.get("char_new_level", 0))  # optional
		var tail: String = ""
		if clvl > 0:
			tail = " (Lv %d)" % clvl
		lines.append("[b]Character XP:[/b] %d%s" % [xp, tail])

	# Stat points line (also supports older top-level fields)
	var pts_gained: int = int(result.get("points_gained", 0))
	var pts_total: int = int(result.get("run_points_unspent", -1))  # -1 means “unknown”
	if pts_gained > 0:
		var suffix: String = ((" (Total: %d)" % pts_total) if pts_total >= 0 else "")
		lines.append("[b]Stat Points:[/b] +%d%s" % [pts_gained, suffix])

	# Shards / Gold
	var shards: int = int(result.get("shards", 0))
	if shards > 0:
		lines.append("[b]Shards:[/b] %d" % shards)
	if gold > 0:
		lines.append("[b]Gold:[/b] %d" % gold)

	# Skill XP (sorted by largest XP first)
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

	# Fallback if nothing to show
	if lines.is_empty():
		lines.append("No rewards this time.")

	# Render
	var content: String = ""
	for i in lines.size():
		if i > 0:
			content += "\n"
		content += lines[i]

	_body.clear()
	_body.parse_bbcode(content)
	_show_modal()



func _show_modal() -> void:
	visible = true
	get_tree().paused = true
	focus_mode = Control.FOCUS_ALL
	_btn.grab_focus()

func _on_continue() -> void:
	visible = false
	get_tree().paused = false
	emit_signal("closed")

func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event.is_action_pressed(&"ui_accept") or event.is_action_pressed(&"ui_cancel"):
		_on_continue()
