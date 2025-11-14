extends Node

const HEARTBEAT_SEC: float = 60.0
var _timer: Timer

func _ready() -> void:
	# 1) Persist any elapsed real time since last session.
	TimeService.realtime_boot_apply()

	# 2) Settle trickle XP using the current META minutes (persisted + live).
	var snap := TimeService.realtime_snapshot()
	var now_min := float(snap.get("combined_min", 0.0))
	if now_min > 0.0:
		NPCXpService.settle_all_assigned(now_min)

	# 3) Start gentle heartbeats.
	_timer = Timer.new()
	_timer.wait_time = HEARTBEAT_SEC
	_timer.one_shot = false
	_timer.autostart = true
	add_child(_timer)
	_timer.timeout.connect(func() -> void:
		# Apply elapsed time to META, then settle XP to the same "now" clock.
		TimeService.realtime_heartbeat()
		var s := TimeService.realtime_snapshot()
		var now_m := float(s.get("combined_min", 0.0))
		if now_m > 0.0:
			NPCXpService.settle_all_assigned(now_m)
	)

func _notification(what: int) -> void:
	# Keep anchor fresh on focus changes; settle XP after applying.
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT or what == NOTIFICATION_WM_CLOSE_REQUEST:
		TimeService.realtime_heartbeat()
		var s := TimeService.realtime_snapshot()
		var now_m := float(s.get("combined_min", 0.0))
		if now_m > 0.0:
			NPCXpService.settle_all_assigned(now_m)
