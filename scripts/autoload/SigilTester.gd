extends Node

const ACTION_ELITE: String = "dbg_elite_kill"
const ACTION_BOSS: String = "dbg_boss_kill"

@onready var SaveManagerInst: SaveManager = get_node("/root/SaveManager") as SaveManager

static func dget(d: Dictionary, key: String, def: Variant) -> Variant:
	if d.has(key):
		return d[key]
	return def

func _ready() -> void:
	_ensure_actions()

func _ensure_actions() -> void:
	if not InputMap.has_action(ACTION_ELITE):
		InputMap.add_action(ACTION_ELITE)
		var k1 := InputEventKey.new()
		k1.physical_keycode = KEY_F6
		InputMap.action_add_event(ACTION_ELITE, k1)

	if not InputMap.has_action(ACTION_BOSS):
		InputMap.add_action(ACTION_BOSS)
		var k2 := InputEventKey.new()
		k2.physical_keycode = KEY_F7
		InputMap.action_add_event(ACTION_BOSS, k2)

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(ACTION_ELITE):
		if SaveManagerInst.has_method("notify_elite_killed"):
			SaveManagerInst.notify_elite_killed()
		var rs: Dictionary = SaveManagerInst.load_run()
		var seg: int = int(dget(rs, "sigils_segment_id", 1))
		var killed: int = int(dget(rs, "sigils_elites_killed_in_segment", 0))
		var req: int = int(dget(rs, "sigils_required_elites", 4))
		var charged: bool = bool(dget(rs, "sigils_charged", false))
		print("[SIGIL] elite+1 seg=", seg, " ", killed, "/", req, " charged=", charged)

	if event.is_action_pressed(ACTION_BOSS):
		var charged_before: bool = false
		if SaveManagerInst.has_method("is_sigil_charged"):
			charged_before = bool(SaveManagerInst.is_sigil_charged())
		print("[SIGIL] boss_kill charged=", charged_before, " -> consume")
		if SaveManagerInst.has_method("consume_sigil_charge"):
			SaveManagerInst.consume_sigil_charge()
		var rs2: Dictionary = SaveManagerInst.load_run()
		var seg2: int = int(dget(rs2, "sigils_segment_id", 1))
		var killed2: int = int(dget(rs2, "sigils_elites_killed_in_segment", 0))
		var req2: int = int(dget(rs2, "sigils_required_elites", 4))
		var charged_after: bool = bool(dget(rs2, "sigils_charged", false))
		print("[SIGIL] post-consume seg=", seg2, " ", killed2, "/", req2, " charged=", charged_after)
