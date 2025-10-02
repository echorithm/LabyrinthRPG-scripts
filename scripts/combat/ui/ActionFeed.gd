extends Control
class_name ActionFeed

@export var max_lines: int = 5

var _vb: VBoxContainer

func _ready() -> void:
	set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	custom_minimum_size = Vector2(0, 140)
	_vb = VBoxContainer.new()
	_vb.name = "Lines"
	_vb.anchor_left = 0.0
	_vb.anchor_right = 1.0
	_vb.anchor_top = 0.0
	_vb.anchor_bottom = 1.0
	_vb.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(_vb)

func begin_new_window() -> void:
	_clear_lines()
	_print_line("--- Your Turn ---")
	print("[Feed] New window")

func append_event(ev: Dictionary) -> void:
	var who: String = String(ev.get("who",""))
	var typ: String = String(ev.get("type",""))
	var line: String = ""
	var abil: String = String(ev.get("ability_id",""))
	var ability_suffix: String = ""
	if abil != "":
		ability_suffix = " (%s)" % [abil]

	match typ:
		"attack":
			var dmg: int = int(ev.get("dmg",0))
			var crit: bool = bool(ev.get("crit", false))
			line = ("%s hits for %d%s%s"
				% [_name_of(who), dmg, (" (CRIT)" if crit else ""), ability_suffix])
		"miss":
			line = ("%s misses%s" % [_name_of(who), ability_suffix])
		"fizzle":
			line = ("You try a gesture... it fizzles.")
		"guard_apply":
			line = ("You brace yourself (Guard).")
		"guard_consume":
			line = ("Your Guard absorbs the hit!")
		"guard_expire":
			line = ("Your Guard fades.")
		"placeholder":
			line = ("You prepare %s (effect pending)" % [abil if abil != "" else "an ability"])
		_:
			line = ("%s %s" % [_name_of(who), typ])

	_print_line(line)
	print("[Feed] %s" % [line])


func _print_line(text: String) -> void:
	var lab := Label.new()
	lab.text = text
	_vb.add_child(lab)
	_trim_if_needed()

func _trim_if_needed() -> void:
	while _vb.get_child_count() > max_lines:
		var c := _vb.get_child(0)
		_vb.remove_child(c)
		c.queue_free()

func _clear_lines() -> void:
	for c in _vb.get_children():
		_vb.remove_child(c)
		c.queue_free()

func _name_of(who: String) -> String:
	if who == "player":
		return "You"
	elif who == "monster":
		return "Enemy"
	return who
