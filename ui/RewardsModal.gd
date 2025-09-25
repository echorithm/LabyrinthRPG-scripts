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
	# skill_xp now comes back as an ARRAY of { id, xp, new_level }
	var sxp_arr: Array = (result.get("skill_xp", []) as Array)

	var lines: Array[String] = []

	# Optional: shards if present in the receipt
	var shards: int = int(result.get("shards", 0))
	if shards > 0:
		lines.append("[b]Shards:[/b] %d" % shards)

	if gold > 0:
		lines.append("[b]Gold:[/b] %d" % gold)
	if xp > 0:
		lines.append("[b]Character XP:[/b] %d" % xp)

	# Render each skill xp entry
	if sxp_arr.size() > 0:
		for entry_any in sxp_arr:
			if entry_any is Dictionary:
				var entry: Dictionary = entry_any
				var sid := String(entry.get("id", ""))
				var amt := int(entry.get("xp", 0))
				var lvl := int(entry.get("new_level", 0))
				var tail := (" (Lv %d)" % lvl) if lvl > 0 else ""
				lines.append("[b]Skill XP – %s:[/b] +%d%s" % [sid, amt, tail])

	# Items
	if items.size() > 0:
		lines.append("[b]Items:[/b]")
		for it_any in items:
			if it_any is Dictionary:
				var it: Dictionary = it_any
				var name: String = ItemNames.display_name(String(it.get("id", "Unknown")))
				var qty: int = int(it.get("count", 1))
				lines.append("  • %s x%d" % [name, qty])

	if lines.is_empty():
		lines.append("No rewards this time.")

	# join lines
	var content := ""
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
