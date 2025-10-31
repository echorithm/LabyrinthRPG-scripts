# res://scripts/combat/ui/ActionFeed.gd
extends Control
class_name ActionFeed

@export var max_lines: int = 5

var _vb: VBoxContainer

# --- Policy ---------------------------------------------------------
# Show only: the player's last action result + all monster actions since then.
# Hide: system noise (battle_begin, guard_expire_turn, stam_regen, etc.).
# Use Dictionaries as sets for allowlists (packeds don't support const expr well).

var _ALLOW_PLAYER: Dictionary = {
	"attack": true,
	"miss": true,
	"ability_used": true,
	"fizzle": true,
	"item_use": true,
	"item_use_fizzle": true,
	"guard_apply": true
}

var _ALLOW_MONSTER: Dictionary = {
	"attack": true,
	"miss": true,
	"guard_consume": true
}

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
	

func append_event(ev: Dictionary) -> void:
	if ev.is_empty():
		return

	var who: String = String(ev.get("who", ""))
	var typ: String = String(ev.get("type", ""))

	# --- Hard filters (remove wasted info) ---
	# Entirely ignore system events and stamina regen.
	if who == "system":
		return
	if typ == "stam_regen":
		return

	# Allowlist per actor
	if who == "player" and not _ALLOW_PLAYER.has(typ):
		return
	if who == "monster" and not _ALLOW_MONSTER.has(typ):
		return

	var line: String = _format_line(ev)
	if line == "":
		return
	_print_line(line)
	

# Build concise, readable lines for allowed events only.
func _format_line(ev: Dictionary) -> String:
	var who: String = String(ev.get("who", ""))
	var typ: String = String(ev.get("type", ""))
	var abil: String = String(ev.get("ability_id", ""))
	var ability_suffix: String = abil if abil != "" else ""
	var actor: String = _name_of(who)

	match typ:
		"attack":
			var dmg: int = int(ev.get("dmg", 0))
			var crit: bool = bool(ev.get("crit", false))
			return "%s hits for %d%s%s" % [
				actor, dmg, (" (CRIT)" if crit else ""), _paren(ability_suffix)
			]

		"miss":
			return "%s misses%s" % [actor, _paren(ability_suffix)]

		"ability_used":
			var kind: String = String(ev.get("kind", ""))
			if kind == "heal":
				var healed: int = int(ev.get("healed", 0))
				return "You restore %d HP%s" % [healed, _paren(ability_suffix)]
			elif kind == "support":
				return "%s uses %s" % [actor, (abil if abil != "" else "an ability")]
			else:
				return "%s uses %s" % [actor, (abil if abil != "" else "an ability")]

		"fizzle":
			return "You try a gesture… it fizzles."

		"item_use":
			var run_index: int = int(ev.get("run_index", -1))
			return "You use an item%s" % _paren(("slot " + str(run_index)) if run_index >= 0 else "")

		"item_use_fizzle":
			return "Item use failed."

		"guard_apply":
			return "You brace yourself (Guard)."

		"guard_consume":
			return "Your Guard absorbs the hit!"

		_:
			return ""

func _paren(s: String) -> String:
	return "" if s == "" else " (%s)" % s

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
