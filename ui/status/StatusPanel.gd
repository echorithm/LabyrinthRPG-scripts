extends Control
class_name StatusPanel
## Lightweight interface all panels implement.

signal wants_register_hit_rect(rect: Rect2)   # panels can protect popups from click-outside close
signal wants_unregister_hit_rect(rect: Rect2)

var _slot: int = -1

func set_run_slot(s: int) -> void:
	# Prefer explicit slot; else ask RunState; else default to 1.
	if s > 0:
		_slot = s
		return

	var rs := get_node_or_null(^"/root/RunState")
	if rs:
		# Use RunState.default_slot if present and > 0
		var v: Variant = rs.get("default_slot")
		if v != null and int(v) > 0:
			_slot = int(v)
			return

	# Final fallback
	_slot = 1

func refresh() -> void:
	# Override in subclass
	pass

func on_enter() -> void:
	# Called when the tab becomes visible (start timers, subscribe signals)
	pass

func on_exit() -> void:
	# Called when tab gets hidden (stop timers, unsubscribe)
	pass
