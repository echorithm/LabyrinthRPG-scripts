extends Control
class_name DebugRewardsPanel
## Self-constructing rewards tester. Lets you click to grant sample rewards and shows a receipt.

const _Rew := preload("res://persistence/services/reward_service.gd")

@export var slot: int = 1

var _log: RichTextLabel

func _ready() -> void:
	name = "DebugRewardsPanel"
	#set_anchors_preset(Control.LAYOUT_FULL_RECT)

	var root := VBoxContainer.new()
	root.anchor_left = 0; root.anchor_top = 0
	root.anchor_right = 1; root.anchor_bottom = 1
	root.grow_horizontal = Control.GROW_DIRECTION_BOTH
	root.grow_vertical = Control.GROW_DIRECTION_BOTH
	add_child(root)

	var title := Label.new()
	title.text = "Rewards Tester"
	title.add_theme_font_size_override("font_size", 18)
	root.add_child(title)

	var hb := HBoxContainer.new()
	root.add_child(hb)

	var b_gold := Button.new()
	b_gold.text = "+25 Gold"
	b_gold.pressed.connect(func() -> void:
		_emit_receipt(_Rew.grant({"gold": 25}, slot))
	)
	hb.add_child(b_gold)

	var b_hp := Button.new()
	b_hp.text = "+10 HP, +5 MP"
	b_hp.pressed.connect(func() -> void:
		_emit_receipt(_Rew.grant({"hp": 10, "mp": 5}, slot))
	)
	hb.add_child(b_hp)

	var b_items := Button.new()
	b_items.text = "Give 2x Potion"
	b_items.pressed.connect(func() -> void:
		_emit_receipt(_Rew.grant({
			"items": [ { "id":"potion_health", "count":2 } ]
		}, slot))
	)
	hb.add_child(b_items)

	var b_xp := Button.new()
	b_xp.text = "+15 Swordsmanship XP"
	b_xp.pressed.connect(func() -> void:
		_emit_receipt(_Rew.grant({
			"skill_xp": [ { "id":"swordsmanship", "xp":15 } ]
		}, slot))
	)
	hb.add_child(b_xp)

	_log = RichTextLabel.new()
	_log.fit_content = true
	_log.scroll_active = true
	_log.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(_log)

	_log.append_text("[Rewards] Ready.\n")

func _emit_receipt(r: Dictionary) -> void:
	var lines: Array[String] = []
	lines.append("Gold: " + str(int(r.get("gold", 0))))
	lines.append("HP + " + str(int(r.get("hp", 0))) + ", MP + " + str(int(r.get("mp", 0))))
	var items_any: Variant = r.get("items", [])
	if items_any is Array:
		for e in (items_any as Array):
			if e is Dictionary:
				lines.append("Item: %s x%d" % [String((e as Dictionary).get("id","")), int((e as Dictionary).get("count",1))])
	var sxp_any: Variant = r.get("skill_xp", [])
	if sxp_any is Array:
		for s in (sxp_any as Array):
			if s is Dictionary:
				lines.append("Skill XP: %s +%d (new L%d)" % [
					String((s as Dictionary).get("id","")),
					int((s as Dictionary).get("xp",0)),
					int((s as Dictionary).get("new_level",1))
				])
	#_log.append_text(lines.join("\n") + "\n")
