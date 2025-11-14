# res://scripts/combat/util/CombatMusicService.gd
extends Node


# ---- Configuration ---------------------------------------------------------
@export var bgm_bus: String = "Music"
@export var sfx_bus: String = "SFX"
@export var fade_seconds: float = 0.35

# Play level-up chime before the outcome stinger when both occur
@export var levelup_before_outcome: bool = true

# Debug prints toggle
@export var debug_logs: bool = false

const DIR := "res://audio/combat"

@export_file("*.wav", "*.ogg", "*.mp3") var trash_track_path: String = DIR + "/Combat 1.wav"
@export_file("*.wav", "*.ogg", "*.mp3") var elite_track_path: String = DIR + "/Combat Elite.wav"
@export_file("*.wav", "*.ogg", "*.mp3") var boss_track_path:  String = DIR + "/Combat Boss.wav"

@export_file("*.wav", "*.ogg", "*.mp3") var victory_path:  String = DIR + "/Victory.wav"
@export_file("*.wav", "*.ogg", "*.mp3") var defeat_path:   String = DIR + "/Defeat.wav"
@export_file("*.wav", "*.ogg", "*.mp3") var level_up_path: String = DIR + "/Level_Up.mp3"

# ---- Internals -------------------------------------------------------------
var _current_role: String = ""
var _current_bgm: AudioStream = null
var _outcome_mode: bool = false
var _fade: Tween

var _snapshots: Array[Dictionary] = [] as Array[Dictionary]   # [{ "path": NodePath, "snap": Dictionary }]
var _sfx_queue: Array[AudioStream] = [] as Array[AudioStream] # deterministic SFX ordering

@onready var _bgm: AudioStreamPlayer = _ensure_player("BGM")
@onready var _sfx: AudioStreamPlayer = _ensure_player("SFX")

# ---- Debug helpers ---------------------------------------------------------
func _dbg(msg: String, data: Dictionary = {}) -> void:
	if not debug_logs:
		return
	if data.is_empty():
		print("[CMS] ", msg)
	else:
		print("[CMS] ", msg, "  ", JSON.stringify(data))

func _stream_tag(s: AudioStream) -> String:
	if s == null:
		return "<null>"
	var rp := String(s.resource_path)
	if rp == "":
		return "<mem>"
	if rp == level_up_path:
		return "LEVEL_UP"
	if rp == victory_path:
		return "VICTORY"
	if rp == defeat_path:
		return "DEFEAT"
	if rp == trash_track_path:
		return "BGM:TRASH"
	if rp == elite_track_path:
		return "BGM:ELITE"
	if rp == boss_track_path:
		return "BGM:BOSS"
	return rp.get_file()

# ---- Lifecycle -------------------------------------------------------------
func _ready() -> void:
	add_to_group("bgm_service")            # so we can stop any other bgm service
	_bgm.bus = bgm_bus
	_sfx.bus = sfx_bus
	_bgm.finished.connect(_on_bgm_finished)
	_sfx.finished.connect(_on_sfx_finished)
	process_mode = Node.PROCESS_MODE_ALWAYS
	_dbg("ready", {
		"bgm_bus": bgm_bus, "sfx_bus": sfx_bus,
		"fade_seconds": fade_seconds,
		"levelup_before_outcome": levelup_before_outcome
	})

func _ensure_player(name_in: String) -> AudioStreamPlayer:
	var p := get_node_or_null(NodePath(name_in)) as AudioStreamPlayer
	if p == null:
		p = AudioStreamPlayer.new()
		p.name = name_in
		add_child(p)
	return p

# ---- Public API ------------------------------------------------------------
func start_combat(role: String) -> void:
	# fades down any other BGM services and starts the role track (looping)
	_outcome_mode = false
	_current_role = role.to_lower()
	_dbg("start_combat", {"role": _current_role})
	_stop_other_bgms()

	var stream: AudioStream = _resolve_bgm_for(_current_role)
	if stream == null:
		_dbg("start_combat: no BGM stream resolved", {"role": _current_role})
		return
	_current_bgm = stream
	_bgm.stream = stream
	_bgm.volume_db = 0.0
	_bgm.play()
	_dbg("BGM play", {"tag": _stream_tag(stream)})

func on_battle_outcome(outcome: String) -> void:
	# stop/duck BGM and (eventually) play victory/defeat stinger once
	_outcome_mode = true
	_dbg("on_battle_outcome", {"outcome": outcome})
	_fade_out_bgm()

	var path: String = ""
	match outcome:
		"victory": path = victory_path
		"defeat", "flee": path = defeat_path
		_: path = ""
	if path == "":
		_dbg("on_battle_outcome: unknown outcome; no stinger")
		return

	var s: AudioStream = _load_stream(path)
	if s == null:
		_dbg("on_battle_outcome: load failed", {"path": path})
		return

	if levelup_before_outcome:
		# Queue the outcome stinger so any level-up chime can precede it deterministically.
		_sfx_queue.append(s)
		_dbg("queue outcome stinger", {"tag": _stream_tag(s), "queue_len": _sfx_queue.size()})
		if not _sfx.playing:
			_play_next_from_queue()
	else:
		# Old behavior: allow outcome to interrupt current SFX.
		_play_sfx_stream(s, true)

func play_level_up() -> void:
	var s: AudioStream = _load_stream(level_up_path)
	if s == null:
		_dbg("play_level_up: load failed", {"path": level_up_path})
		return

	if levelup_before_outcome:
		# If outcome is currently playing, interrupt it, play level-up now, then resume outcome.
		if _sfx.playing and _is_outcome_stream(_sfx.stream):
			var interrupted: AudioStream = _sfx.stream
			_dbg("interrupt outcome for level_up", {
				"interrupted": _stream_tag(interrupted)
			})
			_sfx.stop()
			_sfx.stream = s
			_sfx.play()
			_dbg("SFX play", {"tag": _stream_tag(s)})
			_sfx_queue.insert(0, interrupted)
			_dbg("re-queue interrupted outcome", {"tag": _stream_tag(interrupted), "queue_len": _sfx_queue.size()})
			return

		# If outcome is queued (not yet playing), insert level-up before the first outcome item.
		var inserted: bool = false
		for i in range(_sfx_queue.size()):
			if _is_outcome_stream(_sfx_queue[i]):
				_sfx_queue.insert(i, s)
				inserted = true
				_dbg("insert level_up before queued outcome", {"index": i, "queue_len": _sfx_queue.size()})
				break
		if not inserted:
			_sfx_queue.append(s)
			_dbg("append level_up to queue", {"queue_len": _sfx_queue.size()})

		if not _sfx.playing:
			_play_next_from_queue()
	else:
		# Old behavior: play without interrupting; queue if something is already playing.
		_play_sfx_stream(s, false)

func stop_all() -> void:
	_dbg("stop_all")
	_bgm.stop()
	_sfx.stop()
	_sfx_queue.clear()

func stop() -> void:
	stop_all()

# ---- Helpers ---------------------------------------------------------------
func _resolve_bgm_for(role: String) -> AudioStream:
	var path: String = trash_track_path
	if role == "elite":
		path = elite_track_path
	elif role == "boss":
		path = boss_track_path
	_dbg("_resolve_bgm_for", {"role": role, "path": path.get_file()})
	return _load_stream(path)

func _load_stream(path: String) -> AudioStream:
	var s := load(path) as AudioStream
	if s == null:
		_dbg("_load_stream: failed", {"path": path})
	else:
		_dbg("_load_stream: ok", {"tag": _stream_tag(s)})
	return s

func _is_outcome_stream(stream: AudioStream) -> bool:
	if stream == null:
		return false
	var rp: String = String(stream.resource_path)
	return rp == victory_path or rp == defeat_path

func _on_bgm_finished() -> void:
	# Manual loop so WAVs don’t need import looping enabled.
	_dbg("_on_bgm_finished", {"outcome_mode": _outcome_mode})
	if _outcome_mode:
		return
	if _current_bgm != null:
		_bgm.stream = _current_bgm
		_bgm.play()
		_dbg("BGM loop", {"tag": _stream_tag(_current_bgm)})

func _play_sfx_stream(s: AudioStream, can_interrupt: bool) -> void:
	if _sfx.playing:
		if can_interrupt:
			var cur: AudioStream = _sfx.stream
			_dbg("interrupt current SFX", {
				"current": _stream_tag(cur),
				"next": _stream_tag(s)
			})
			if cur != null:
				_sfx_queue.insert(0, cur) # resume what we interrupted next
				_dbg("re-queue interrupted SFX", {"tag": _stream_tag(cur), "queue_len": _sfx_queue.size()})
			_sfx.stop()
		else:
			_sfx_queue.append(s)
			_dbg("queue SFX (no interrupt)", {"tag": _stream_tag(s), "queue_len": _sfx_queue.size()})
			return
	_sfx.stream = s
	_sfx.play()
	_dbg("SFX play", {"tag": _stream_tag(s)})

func _on_sfx_finished() -> void:
	_dbg("_on_sfx_finished", {"queue_len": _sfx_queue.size()})
	_play_next_from_queue()

func _play_next_from_queue() -> void:
	if _sfx_queue.is_empty():
		_dbg("_play_next_from_queue: empty")
		return
	var next: AudioStream = _sfx_queue.pop_front()
	if next != null:
		_sfx.stream = next
		_sfx.play()
		_dbg("SFX play(next)", {"tag": _stream_tag(next), "queue_len": _sfx_queue.size()})

func _fade_out_bgm() -> void:
	if fade_seconds <= 0.0:
		_dbg("_fade_out_bgm: immediate stop")
		_bgm.stop()
		return
	if is_instance_valid(_fade):
		_fade.kill()
	_dbg("_fade_out_bgm: tween", {"seconds": fade_seconds})
	_fade = create_tween()
	_fade.tween_property(_bgm, "volume_db", -60.0, fade_seconds)
	_fade.tween_callback(Callable(_bgm, "stop"))
	_fade.tween_callback(Callable(self, "_reset_bgm_volume"))

func _reset_bgm_volume() -> void:
	_bgm.volume_db = 0.0
	_dbg("_reset_bgm_volume")

func _stop_other_bgms() -> void:
	_snapshots.clear()
	var others: Array = get_tree().get_nodes_in_group("bgm_service")
	_dbg("_stop_other_bgms: found", {"count": others.size()})
	for n_any in others:
		var n: Node = n_any
		if n == self:
			continue

		# 1) Snapshot if the service supports it
		var snap: Dictionary = {}
		if n.has_method("snapshot_bgm"):
			snap = n.call("snapshot_bgm") as Dictionary
		elif n.has_method("bgm_snapshot"):
			snap = n.call("bgm_snapshot") as Dictionary
		else:
			# Fallback snapshot: try child AudioStreamPlayer named "Player"
			var asp := n.get_node_or_null(^"Player") as AudioStreamPlayer
			if asp != null and asp.stream != null:
				var spath: String = String(asp.stream.resource_path)
				var pos: float = 0.0
				if asp.has_method("get_playback_position"):
					pos = asp.get_playback_position()
				snap = {"stream_path": spath, "position": pos}

		_snapshots.append({"path": n.get_path(), "snap": snap})
		_dbg("_stop_other_bgms: snap+stop", {
			"target": str(n.get_path()),
			"has_snap": not snap.is_empty()
		})

		# 2) Stop that BGM service
		if n.has_method("stop"):
			n.call("stop")
		elif n.has_method("stop_all"):
			n.call("stop_all")
		else:
			var asp2 := n.get_node_or_null(^"Player") as AudioStreamPlayer
			if asp2 != null:
				asp2.stop()

func resume_previous_bgms() -> void:
	_dbg("resume_previous_bgms", {"snapshots": _snapshots.size()})
	for row_any in _snapshots:
		if not (row_any is Dictionary):
			continue
		var row: Dictionary = row_any
		var npath: NodePath = row.get("path", NodePath())
		var n: Node = get_node_or_null(npath)
		if n == null:
			continue
		var snap: Dictionary = row.get("snap", {}) as Dictionary
		if n.has_method("resume_bgm"):
			n.call("resume_bgm", snap)
		elif n.has_method("resume_from_snapshot"):
			n.call("resume_from_snapshot", snap)
		elif n.has_method("resume"):
			n.call("resume")
		else:
			# Fallback: try direct AudioStreamPlayer child named "Player"
			var asp := n.get_node_or_null(^"Player") as AudioStreamPlayer
			if asp != null:
				var stream_path: String = String(snap.get("stream_path", ""))
				var pos: float = float(snap.get("position", 0.0))
				if stream_path != "":
					var st := load(stream_path) as AudioStream
					if st != null:
						asp.stream = st
						asp.play(pos)
				elif asp.stream != null:
					asp.play()
	_dbg("resume_previous_bgms: done")
	_snapshots.clear()
