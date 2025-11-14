extends Node

const ACTION_ELITE: String = "dbg_elite_kill"
const ACTION_BOSS: String = "dbg_boss_kill"

const Sigils := preload("res://persistence/services/sigils_service.gd")

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
		# +1 elite kill toward current triad
		Sigils.notify_elite_killed()
		_print_progress("elite+1")

	if event.is_action_pressed(ACTION_BOSS):
		var charged_before: bool = Sigils.is_charged()
		print("[SIGIL] boss_kill charged=", charged_before, " -> consume")
		Sigils.consume_charge()
		_print_progress("post-consume")

func _print_progress(tag: String) -> void:
	var p: Dictionary = Sigils.get_progress()
	var seg: int = int(p.get("segment_id", 1))
	var kills: int = int(p.get("kills", 0))
	var req: int = max(1, int(p.get("required", 4)))
	var charged: bool = bool(p.get("charged", false))
	var factor: float = clampf(float(kills + 1) / float(req + 1), 0.0, 1.0)
	print("[SIGIL][", tag, "] seg=", seg, " ", kills, "/", req, " charged=", charged, " factor=", "%.2f" % factor)
