# res://scripts/autoload/AppPhase.gd
extends Node

enum Phase { BOOT, MENU, GAME }
var phase: Phase = Phase.MENU

func _set_flag() -> void:
	var t: SceneTree = get_tree()
	if t != null:
		t.set_meta("in_menu", phase == Phase.MENU)
		print("[AppPhase: in_menu]")

func in_menu() -> bool: return phase == Phase.MENU
func in_game() -> bool: return phase == Phase.GAME

func to_menu() -> void:
	print("[AppPhase: to_menu]")
	phase = Phase.MENU
	_set_flag()

func to_game() -> void:
	print("[AppPhase: to_game]")
	phase = Phase.GAME
	_set_flag()
