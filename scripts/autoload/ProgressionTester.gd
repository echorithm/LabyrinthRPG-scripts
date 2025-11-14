extends Node


@onready var SM: SaveManager = get_node("/root/SaveManager") as SaveManager

const ACT_LVL_UP: String = "dbg_claim_level"
const ACT_DEATH: String = "dbg_apply_death"

static func _dget(d: Dictionary, k: String, def: Variant) -> Variant:
	return d[k] if d.has(k) else def

func _ready() -> void:
	if not InputMap.has_action(ACT_LVL_UP):
		InputMap.add_action(ACT_LVL_UP)
		var k1 := InputEventKey.new(); k1.physical_keycode = KEY_F5
		InputMap.action_add_event(ACT_LVL_UP, k1)
	if not InputMap.has_action(ACT_DEATH):
		InputMap.add_action(ACT_DEATH)
		var k2 := InputEventKey.new(); k2.physical_keycode = KEY_F8
		InputMap.action_add_event(ACT_DEATH, k2)

func _unhandled_input(e: InputEvent) -> void:
	if e.is_action_pressed(ACT_LVL_UP):
		var gs: Dictionary = SM.load_game()
		var pl: Dictionary = (_dget(gs, "player", {}) as Dictionary) if _dget(gs, "player", {}) is Dictionary else {}
		var lvl: int = int(_dget(pl, "level", 1)) + 1
		SM.claim_character_level(lvl)
		gs = SM.load_game()
		pl = (_dget(gs, "player", {}) as Dictionary) if _dget(gs, "player", {}) is Dictionary else {}
		print("[CLAIM] level->", int(_dget(pl, "level", 1)),
			" highest_claimed=", int(_dget(pl, "highest_claimed_level", 1)),
			" meta_highest=", int(_dget(gs, "highest_claimed_level", 1)))

	if e.is_action_pressed(ACT_DEATH):
		var before: Dictionary = SM.load_game()
		var bpl: Dictionary = (_dget(before, "player", {}) as Dictionary) if _dget(before, "player", {}) is Dictionary else {}
		print("[DEATH][before] level=", int(_dget(bpl, "level", 1)))
		SM.apply_death_penalties()
		var after: Dictionary = SM.load_game()
		var apl: Dictionary = (_dget(after, "player", {}) as Dictionary) if _dget(after, "player", {}) is Dictionary else {}
		print("[DEATH][after ] level=", int(_dget(apl, "level", 1)),
			" (hc=", int(_dget(apl, "highest_claimed_level", 1)), ")")
