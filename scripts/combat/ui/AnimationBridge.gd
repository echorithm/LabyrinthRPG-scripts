# res://scripts/combat/AnimationBridge.gd
extends Node
class_name AnimationBridge

var _root: Node3D = null
var _ap: AnimationPlayer = null

# cached animation names
var _idle_name: String = ""
var _hit_name: String = ""
var _die_name: String = ""

func setup(root: Node3D, ap_in: AnimationPlayer = null) -> void:
	_root = root
	_ap = ap_in if ap_in != null else _find_anim_player_in(root)

	if _ap == null:
		print("[AnimBridge] ERROR: no AnimationPlayer under ", root)
		return

	# Resolve common names (with/without “/Take 001”)
	_idle_name = _pick_name(["IdleBattle", "IdleBattle/Take 001", "Idle", "Idle/Take 001"])
	_hit_name  = _pick_name(["GetHit", "GetHit/Take 001", "HitReact", "HitReact/Take 001"])
	_die_name  = _pick_name(["Die", "Die/Take 001"])

	print("[AnimBridge] ready root=%s ap=%s  idle=%s hit=%s die=%s"
		% [_root.name, str(_ap), _idle_name, _hit_name, _die_name])

	play_idle()

# --- public API --------------------------------------------------------------

func play_idle() -> void:
	if _ap == null:
		return
	_disconnect_finished()
	if _idle_name != "":
		_ensure_loop(_idle_name, true)   # <-- make idle loop
		print("[AnimBridge] play_idle -> ", _idle_name)
		_ap.play(_idle_name)
	else:
		var names: PackedStringArray = _ap.get_animation_list()
		if names.size() > 0:
			print("[AnimBridge] idle missing; fallback -> ", names[0])
			_ap.play(names[0])

func play_player_hit() -> void:
	if _ap == null:
		return
	if _hit_name != "":
		_ensure_loop(_hit_name, false)   # <-- make hit one-shot
		print("[AnimBridge] player hit -> ", _hit_name)
		_ap.play(_hit_name)
		_connect_finished_once()
	else:
		print("[AnimBridge] missing GetHit")


func play_monster_action(anim_key: String) -> void:
	if _ap == null:
		return
	var want := _resolve_action_name(anim_key)
	if want == "":
		print("[AnimBridge] action '%s' not found; no-op" % [anim_key])
		return
	_ensure_loop(want, false)            # <-- make action one-shot
	print("[AnimBridge] monster action -> ", want)
	_ap.play(want)
	_connect_finished_once()


func play_die_and_wait() -> void:
	if _ap == null:
		return
	_disconnect_finished()
	if _die_name != "":
		print("[AnimBridge] play Die -> ", _die_name)
		_ap.play(_die_name)
	else:
		print("[AnimBridge] missing Die; falling back to idle")
		play_idle()

# --- internal helpers --------------------------------------------------------

func _resolve_action_name(base: String) -> String:
	if _ap.has_animation(base):
		return base
	var alt := "%s/Take 001" % base
	if _ap.has_animation(alt):
		return alt
	# last resort: use idle if available
	return _idle_name

func _pick_name(candidates: Array[String]) -> String:
	if _ap == null:
		return ""
	for n in candidates:
		if _ap.has_animation(n):
			return n
	return ""

func _connect_finished_once() -> void:
	# avoid duplicate connections
	_disconnect_finished()
	_ap.connect("animation_finished", Callable(self, "_on_finished_non_idle"))

func _disconnect_finished() -> void:
	if _ap != null and _ap.is_connected("animation_finished", Callable(self, "_on_finished_non_idle")):
		_ap.disconnect("animation_finished", Callable(self, "_on_finished_non_idle"))

func _on_finished_non_idle(_anim_name: StringName) -> void:
	# called after a non-idle clip; go back to idle and stop listening
	_disconnect_finished()
	if _idle_name != "" and _ap != null:
		print("[AnimBridge] finished '%s' -> idle" % [String(_anim_name)])
		_ap.play(_idle_name)

# Breadth-first search for an AnimationPlayer anywhere under the root
func _find_anim_player_in(root: Node) -> AnimationPlayer:
	if root == null:
		return null
	var q: Array[Node] = []
	q.append(root)

	while q.size() > 0:
		var n: Node = q.pop_front()
		var ap: AnimationPlayer = n as AnimationPlayer
		if ap != null:
			print("[AnimBridge][scan] found AnimationPlayer at: ", ap.get_path())
			return ap
		for child in n.get_children():
			var c: Node = child as Node
			if c != null:
				q.append(c)
	return null

func _ensure_loop(anim_name: String, should_loop: bool) -> void:
	if _ap == null or anim_name == "":
		return
	var a: Animation = _ap.get_animation(anim_name)
	if a == null:
		return
	var want := Animation.LOOP_LINEAR if should_loop else Animation.LOOP_NONE
	if a.loop_mode != want:
		a.loop_mode = want
