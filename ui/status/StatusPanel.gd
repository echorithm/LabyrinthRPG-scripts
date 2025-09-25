extends Control
class_name StatusPanel
## Lightweight interface all panels implement.

signal wants_register_hit_rect(rect: Rect2)   # panels can protect popups from click-outside close
signal wants_unregister_hit_rect(rect: Rect2)

var _slot: int = 0

func set_run_slot(slot: int) -> void:
	_slot = slot

func refresh() -> void:
	# Override in subclass
	pass

func on_enter() -> void:
	# Called when the tab becomes visible (start timers, subscribe signals)
	pass

func on_exit() -> void:
	# Called when tab gets hidden (stop timers, unsubscribe)
	pass
