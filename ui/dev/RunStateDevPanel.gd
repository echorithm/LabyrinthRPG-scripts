extends Control
class_name RunStateDevPanel
## Lightweight debug dock for live-testing RUN state.
## - Shows hp/mp/stam, gold, shards, depth
## - Buttons to heal/damage, add gold/shards, add test items
## - Emits RunState changes so your panels update immediately

const RewardService := preload("res://persistence/services/reward_service.gd")

@export var slot: int = 1
@export var start_open: bool = true

@onready var _lbl: Label = Label.new()
@onready var _btn_toggle: Button = Button.new()

@onready var _btn_refresh: Button = Button.new()
@onready var _btn_heal: Button = Button.new()
@onready var _btn_damage: Button = Button.new()
@onready var _btn_mp: Button = Button.new()
@onready var _btn_gold: Button = Button.new()
@onready var _btn_shards: Button = Button.new()
@onready var _btn_item_stack: Button = Button.new()
@onready var _btn_item_gear: Button = Button.new()
@onready var _btn_reload: Button = Button.new()
@onready var _btn_save: Button = Button.new()
@onready var _btn_depth_up: Button = Button.new()
@onready var _btn_depth_down: Button = Button.new()

func _ready() -> void:
	# Layout (top-left floating panel)
	mouse_filter = MOUSE_FILTER_PASS
	top_level = true
	set_anchors_preset(PRESET_TOP_LEFT)
	offset_left = 16
	offset_top = 16
	custom_minimum_size = Vector2(360, 0)

	var panel := Panel.new()
	panel.name = "Panel"
	panel.mouse_filter = MOUSE_FILTER_PASS
	panel.custom_minimum_size = Vector2(360, 0)
	add_child(panel)

	var vb := VBoxContainer.new()
	vb.name = "VBox"
	vb.anchor_right = 1.0
	vb.offset_left = 10
	vb.offset_top = 10
	vb.offset_right = -10
	vb.offset_bottom = -10
	panel.add_child(vb)

	_btn_toggle.text = "🧪 Run Debug (hide)"
	_btn_toggle.pressed.connect(_on_toggle)
	vb.add_child(_btn_toggle)

	_lbl.add_theme_color_override("font_color", Color(0.9, 0.95, 1.0))
	_lbl.add_theme_font_size_override("font_size", 14)
	vb.add_child(_lbl)

	var row1 := HBoxContainer.new()
	_btn_refresh.text = "Refresh"
	_btn_reload.text = "Reload RunState"
	_btn_save.text = "Save RunState"
	row1.add_child(_btn_refresh)
	row1.add_child(_btn_reload)
	row1.add_child(_btn_save)
	vb.add_child(row1)

	var row2 := HBoxContainer.new()
	_btn_heal.text = "+10 HP"
	_btn_damage.text = "-10 HP"
	_btn_mp.text = "+10 MP"
	row2.add_child(_btn_heal)
	row2.add_child(_btn_damage)
	row2.add_child(_btn_mp)
	vb.add_child(row2)

	var row3 := HBoxContainer.new()
	_btn_gold.text = "+25 Gold"
	_btn_shards.text = "+3 Shards"
	row3.add_child(_btn_gold)
	row3.add_child(_btn_shards)
	vb.add_child(row3)

	var row4 := HBoxContainer.new()
	_btn_item_stack.text = "Add x2 Health Potions"
	_btn_item_gear.text = "Add Test Sword (gear)"
	row4.add_child(_btn_item_stack)
	row4.add_child(_btn_item_gear)
	vb.add_child(row4)

	var row5 := HBoxContainer.new()
	_btn_depth_down.text = "Depth -1"
	_btn_depth_up.text = "Depth +1"
	row5.add_child(_btn_depth_down)
	row5.add_child(_btn_depth_up)
	vb.add_child(row5)

	# Wire actions
	_btn_refresh.pressed.connect(_refresh)
	_btn_reload.pressed.connect(func():
		RunState.reload(slot)
		_refresh()
	)
	_btn_save.pressed.connect(func():
		RunState.save(slot)
		_refresh()
	)

	_btn_heal.pressed.connect(func():
		RunState.heal_hp(10, true, slot)
	)
	_btn_damage.pressed.connect(func():
		RunState.set_hp(RunState.hp - 10, true, slot)
	)
	_btn_mp.pressed.connect(func():
		RunState.set_mp(RunState.mp + 10, true, slot)
	)

	_btn_gold.pressed.connect(func():
		RunState.add_gold(25, true, slot)
	)
	_btn_shards.pressed.connect(func():
		RunState.add_shards(3, true, slot)
	)

	_btn_item_stack.pressed.connect(func():
		var rc := RewardService.grant({
			"items": [
				{"id":"potion_health", "count": 2, "opts": {"rarity":"Common"}}
			]
		}, slot)
		print("[RunDebug] grant stackables receipt=", rc)
		# SaveManager.grant already saves RUN; just refresh mirrors:
		RunState.reload(slot)
	)
	_btn_item_gear.pressed.connect(func():
		var rc := RewardService.grant({
			"items": [
				{"id":"weapon_generic", "count": 1, "opts": {
					"rarity":"Rare", "durability_max": 100, "durability_current": 100,
					"ilvl": max(1, SaveManager.get_current_floor(slot))
				}}
			]
		}, slot)
		print("[RunDebug] grant gear receipt=", rc)
		RunState.reload(slot)
	)

	_btn_depth_up.pressed.connect(func():
		var new_d: int = RunState.depth + 1
		SaveManager.set_run_floor(new_d, slot)         # authoritative
		RunState.set_depth(new_d, false, slot)         # mirror (no extra save)
		if RunState.has_signal("changed"):
			RunState.emit_signal("changed")
		_refresh()
	)

	# Depth -1 (clamped)
	_btn_depth_down.pressed.connect(func():
		var new_d: int = max(1, RunState.depth - 1)
		SaveManager.set_run_floor(new_d, slot)
		RunState.set_depth(new_d, false, slot)
		if RunState.has_signal("changed"):
			RunState.emit_signal("changed")
		_refresh()
	)

	# Update on RunState changes
	if RunState.has_signal("changed"):
		RunState.changed.connect(_refresh)
	if RunState.has_signal("pools_changed"):
		RunState.pools_changed.connect(func(_a: int, _b: int, _c: int, _d: int): _refresh())

	# Start state
	visible = start_open
	_refresh()

func _on_toggle() -> void:
	visible = not visible

func _fmt_line() -> String:
	return "Depth: %d (furthest: %d)\nHP: %d / %d   MP: %d / %d   STAM: %d / %d\nGold: %d   Shards: %d\nLvl: %d  XP: %d / %d  ΔXP(run): %d" % [
		RunState.depth, RunState.furthest_depth_reached,
		RunState.hp, RunState.hp_max, RunState.mp, RunState.mp_max,
		RunState.stam, RunState.stam_max,
		RunState.gold, RunState.shards,
		# Character mirrors (if you added them)
		(RunState.char_level if "char_level" in RunState else 1),
		(RunState.char_xp_current if "char_xp_current" in RunState else 0),
		(RunState.char_xp_needed if "char_xp_needed" in RunState else 90),
		(RunState.char_xp_delta if "char_xp_delta" in RunState else 0),
	]

func _refresh() -> void:
	if _lbl != null:
		_lbl.text = _fmt_line()
