extends Node
class_name AnimationBridge

var _root: Node3D
var _ap: AnimationPlayer

var _idle_name: StringName
var _hit_name: StringName
var _die_name: StringName
var _victory_name: StringName

var _lock_terminal := false  # set true after death to ignore further plays

func setup(root: Node3D, ap_in: AnimationPlayer = null) -> void:
	_root = root
	_ap = ap_in if ap_in != null else _find_anim_player_in(root)
	if _ap == null:
		push_warning("AnimationBridge: No AnimationPlayer under %s" % str(root))
		return

	_idle_name    = _pick_name([&"IdleBattle", &"IdleBattle/Take 001", &"Idle", &"Idle/Take 001"])
	_hit_name     = _pick_name([&"GetHit", &"GetHit/Take 001", &"HitReact", &"HitReact/Take 001"])
	_die_name     = _pick_name([&"Die", &"Die/Take 001"])
	# Common “win” style names across rigs; add more if you standardize later
	_victory_name = _pick_name([&"Victory", &"Victory/Take 001", &"Win", &"Cheer", &"Roar", &"Roar/Take 001"])

	print("[AnimationBridge] setup idle=", _idle_name, " hit=", _hit_name, " die=", _die_name, " vic=", _victory_name)
	play_idle()

# --- public --------------------------------------------------------

func play_idle() -> void:
	if _ap == null or _lock_terminal:
		return
	_disconnect_finished()
	if _idle_name != StringName():
		_ensure_loop(_idle_name, true)
		_ap.play(_idle_name)
	else:
		var names: PackedStringArray = _ap.get_animation_list()
		if names.size() > 0:
			_ap.play(names[0])

func play_hit() -> void:
	if _ap == null or _lock_terminal:
		return
	if _hit_name != StringName():
		_ensure_loop(_hit_name, false)
		_ap.play(_hit_name)
		_connect_finished_once()

func play_action(anim_key: String) -> void:
	if _ap == null or _lock_terminal:
		return
	var want := _resolve_action_name(anim_key)
	print("[AnimationBridge] play_action key=", anim_key, " -> clip=", want)
	if want == StringName():
		play_idle()
		return
	_ensure_loop(want, false)
	_ap.play(want)
	_connect_finished_once()

func play_victory(loop: bool = true) -> void:
	# Used when the **opponent** is defeated / on player defeat
	if _ap == null or _lock_terminal:
		return
	var clip := _victory_name
	if clip == StringName():
		# if rig has no explicit victory, just idle-loop
		play_idle()
		return
	print("[AnimationBridge] play_victory clip=", clip, " loop=", loop)
	_disconnect_finished()
	_ensure_loop(clip, loop)
	_ap.play(clip)
	# if not looping, return to idle after it finishes
	if not loop:
		_connect_finished_once()

func play_die_and_hold() -> void:
	if _ap == null or _lock_terminal:
		return
	_disconnect_finished()
	_lock_terminal = true
	if _die_name != StringName():
		print("[AnimationBridge] play_die_and_hold clip=", _die_name)
		_ensure_loop(_die_name, false)
		_ap.play(_die_name)

# --- internals -----------------------------------------------------

func _resolve_action_name(base: String) -> StringName:
	if _ap == null:
		return _idle_name
	if base == "":
		return _idle_name
	if _ap.has_animation(base):
		return StringName(base)
	var alt := "%s/Take 001" % base
	if _ap.has_animation(alt):
		return StringName(alt)
	# Strict: return idle so missing clips are obvious in logs
	return _idle_name

func _pick_name(candidates: Array[StringName]) -> StringName:
	if _ap == null:
		return StringName()
	for n in candidates:
		if _ap.has_animation(n):
			return n
	return StringName()

func _connect_finished_once() -> void:
	_disconnect_finished()
	if _ap != null:
		_ap.animation_finished.connect(Callable(self, "_on_finished_non_idle"))

func _disconnect_finished() -> void:
	if _ap != null:
		var cb := Callable(self, "_on_finished_non_idle")
		if _ap.animation_finished.is_connected(cb):
			_ap.animation_finished.disconnect(cb)

func _on_finished_non_idle(_anim_name: StringName) -> void:
	_disconnect_finished()
	if not _lock_terminal:
		play_idle()

func _find_anim_player_in(root: Node) -> AnimationPlayer:
	if root == null:
		return null
	var q: Array[Node] = [root]
	while q.size() > 0:
		var n: Node = q.pop_front()
		var ap: AnimationPlayer = n as AnimationPlayer
		if ap != null:
			return ap
		for child in n.get_children():
			q.append(child as Node)
	return null

func _ensure_loop(anim_name: StringName, should_loop: bool) -> void:
	if _ap == null or anim_name == StringName():
		return
	var a: Animation = _ap.get_animation(anim_name)
	if a == null:
		return
	a.loop_mode = Animation.LOOP_LINEAR if should_loop else Animation.LOOP_NONE

# --- Back-compat aliases -------------------------------------------

func play_player_hit() -> void:
	play_hit()

func play_die_and_wait() -> void:
	play_die_and_hold()

func play_monster_action(anim_key: String) -> void:
	# Back-compat for older callers
	play_action(anim_key)

func play_victory_and_hold() -> void:
	if _ap == null or _lock_terminal:
		return
	_disconnect_finished()
	_lock_terminal = true
	if _victory_name != StringName():
		print("[AnimationBridge] play_victory_and_hold clip=", _victory_name)
		_ensure_loop(_victory_name, false)
		_ap.play(_victory_name)
