extends Node


@export var bgm_bus: String = "Master"
@export var default_volume_db: float = -6.0
@export var default_fade_seconds: float = 0.4
@export var debug_logs: bool = true

const _LOG_TAG: String = "[MusicManager]"

var _player: AudioStreamPlayer
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()
var _playlist: Array[AudioStream] = [] as Array[AudioStream]
var _queue: Array[int] = [] as Array[int]
var _fade_tween: Tween

var _current_volume_db: float = -6.0
var _current_fade_seconds: float = 0.4
var _current_bus: String = "Master"


func _enter_tree() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS

	_rng.randomize()

	_player = AudioStreamPlayer.new()
	_player.name = "BGM"
	add_child(_player)

	_current_bus = bgm_bus
	_current_volume_db = default_volume_db
	_current_fade_seconds = default_fade_seconds
	_set_bus_safe(_current_bus)
	_player.volume_db = _current_volume_db

	if not _player.finished.is_connected(_on_track_finished):
		_player.finished.connect(_on_track_finished)

	_dbg("ready bus=%s vol=%.2f fade=%.2f" %
		[bgm_bus, default_volume_db, default_fade_seconds])

# -------------------------------------------------------------------
# Public API
# -------------------------------------------------------------------

# dir_path: folder to scan
# editor_playlist: optional explicit streams (forces export inclusion if non-empty)
func play_folder(
	dir_path: String,
	editor_playlist: Array[AudioStream],
	shuffle: bool,
	volume_db: float,
	fade_seconds: float,
	bus: String
) -> void:
	var use_bus: String = (bus if bus != "" else bgm_bus)
	_current_bus = use_bus
	_current_volume_db = volume_db
	_current_fade_seconds = fade_seconds
	_set_bus_safe(_current_bus)

	_playlist.clear()

	# A) explicit playlist first
	for s: AudioStream in editor_playlist:
		if s != null:
			_playlist.append(s)

	# B) folder scan if still empty
	if _playlist.is_empty():
		var scanned: Array[AudioStream] = _scan_dir_for_streams(dir_path)
		for st: AudioStream in scanned:
			_playlist.append(st)

	_dbg("play_folder dir=%s tracks=%d shuffle=%s vol=%.2f fade=%.2f bus=%s" %
		[dir_path, _playlist.size(), str(shuffle),
		_current_volume_db, _current_fade_seconds, _current_bus])

	_start_playlist(shuffle)


# paths: list of res:// audio files
func play_stream_paths(
	paths: Array[String],
	shuffle: bool,
	volume_db: float,
	fade_seconds: float,
	bus: String
) -> void:
	var use_bus: String = (bus if bus != "" else bgm_bus)
	_current_bus = use_bus
	_current_volume_db = volume_db
	_current_fade_seconds = fade_seconds
	_set_bus_safe(_current_bus)

	_playlist.clear()

	for p: String in paths:
		var s: AudioStream = load(p) as AudioStream
		if s != null:
			_playlist.append(s)
		else:
			_dbg("play_stream_paths: failed to load %s" % p)

	_dbg("play_stream_paths count=%d shuffle=%s vol=%.2f fade=%.2f bus=%s" %
		[_playlist.size(), str(shuffle),
		_current_volume_db, _current_fade_seconds, _current_bus])

	_start_playlist(shuffle)


func skip() -> void:
	_dbg("skip()")
	if _player != null and _player.playing:
		_player.stop()
	_play_next(true)


func stop() -> void:
	_dbg("stop()")
	if is_instance_valid(_fade_tween):
		_fade_tween.kill()
	_player.stop()


func set_volume_db(v: float) -> void:
	_current_volume_db = v
	_player.volume_db = v
	_dbg("set_volume_db %.2f" % v)


func snapshot_bgm() -> Dictionary:
	var spath: String = ""
	var idx: int = -1
	var pos: float = 0.0

	if _player != null and _player.stream != null:
		spath = String(_player.stream.resource_path)
		if _player.has_method("get_playback_position"):
			pos = _player.get_playback_position()
		for i: int in range(_playlist.size()):
			if _playlist[i] == _player.stream:
				idx = i
				break

	var snap: Dictionary = {
		"stream_path": spath,
		"index": idx,
		"position": pos,
		"was_playing": _player.playing if _player != null else false,
		"volume_db": _player.volume_db if _player != null else _current_volume_db,
		"bus": _current_bus,
		"fade_seconds": _current_fade_seconds
	}
	_dbg("snapshot_bgm %s" % str(snap))
	return snap


func resume_bgm(snap: Dictionary) -> void:
	if snap.is_empty():
		_dbg("resume_bgm: empty snapshot; ignoring")
		return

	var spath: String = String(snap.get("stream_path", ""))
	var idx: int = int(snap.get("index", -1))
	var pos: float = float(snap.get("position", 0.0))
	var was_playing: bool = bool(snap.get("was_playing", true))
	_current_volume_db = float(snap.get("volume_db", default_volume_db))
	_current_bus = String(snap.get("bus", bgm_bus))
	_current_fade_seconds = float(snap.get("fade_seconds", default_fade_seconds))
	_set_bus_safe(_current_bus)

	var stream: AudioStream = null
	if spath != "":
		stream = load(spath) as AudioStream
	elif idx >= 0 and idx < _playlist.size():
		stream = _playlist[idx]
	elif _player.stream != null:
		stream = _player.stream

	if stream == null:
		_dbg("resume_bgm: stream null; starting next in playlist")
		_play_next(true)
		return

	_player.stream = stream
	_player.volume_db = _current_volume_db
	if was_playing:
		_player.play(pos)

	_dbg("resume_bgm path=%s idx=%d pos=%.2f vol=%.2f bus=%s" %
		[spath, idx, pos, _player.volume_db, _current_bus])

# -------------------------------------------------------------------
# Internals
# -------------------------------------------------------------------

func _start_playlist(shuffle: bool) -> void:
	if _playlist.is_empty():
		_dbg("start_playlist: empty playlist; nothing to play")
		return
	_reseed_queue(shuffle)
	_play_next(true)


func _scan_dir_for_streams(dir_path: String) -> Array[AudioStream]:
	var out: Array[AudioStream] = [] as Array[AudioStream]
	var files: PackedStringArray = DirAccess.get_files_at(dir_path)
	_dbg("_scan_dir_for_streams dir=%s files=%d" % [dir_path, files.size()])

	var import_bases: Array[String] = [] as Array[String]

	for i: int in range(files.size()):
		var f: String = files[i]
		var ext: String = f.get_extension().to_lower()
		if ext == "wav" or ext == "ogg" or ext == "mp3":
			var stream: AudioStream = load(dir_path.path_join(f)) as AudioStream
			if stream != null:
				out.append(stream)
				var length_s: float = 0.0
				if stream.has_method("get_length"):
					length_s = stream.call("get_length")
				_dbg(" loaded %s len≈%.2fs" % [f, length_s])
		elif f.ends_with(".import"):
			var base: String = f.substr(0, f.length() - 7)
			var b_ext: String = base.get_extension().to_lower()
			if b_ext == "wav" or b_ext == "ogg" or b_ext == "mp3":
				import_bases.append(base)

	if out.is_empty() and import_bases.size() > 0:
		_dbg(" no raw audio; resolving via .import bases")
		for base_path: String in import_bases:
			var stream2: AudioStream = load(dir_path.path_join(base_path)) as AudioStream
			if stream2 != null:
				out.append(stream2)

	if out.is_empty() and import_bases.size() > 0:
		_dbg(" WARNING: only .import files in %s; check export filters or pack explicit playlist" % dir_path)

	return out


func _reseed_queue(shuffle: bool) -> void:
	_queue.clear()
	for i: int in range(_playlist.size()):
		_queue.append(i)
	if shuffle:
		for i: int in range(_queue.size() - 1, 0, -1):
			var j: int = _rng.randi_range(0, i)
			var t: int = _queue[i]
			_queue[i] = _queue[j]
			_queue[j] = t
	_dbg("_reseed_queue shuffle=%s queue=%s" % [str(shuffle), str(_queue)])


func _play_next(fade_in: bool) -> void:
	if _playlist.is_empty():
		_dbg("_play_next: playlist empty")
		return
	if _queue.is_empty():
		_reseed_queue(true)

	var idx: int = _queue.pop_back()
	if idx < 0 or idx >= _playlist.size():
		_dbg("_play_next: index OOB %d" % idx)
		return

	var stream: AudioStream = _playlist[idx]
	_player.stream = stream
	_player.play()

	if fade_in and _current_fade_seconds > 0.0:
		_player.volume_db = -60.0
		if is_instance_valid(_fade_tween):
			_fade_tween.kill()
		_fade_tween = create_tween()
		_fade_tween.tween_property(_player, "volume_db", _current_volume_db, _current_fade_seconds)
	else:
		_player.volume_db = _current_volume_db

	var name_hint: String = ""
	if stream.resource_path != "":
		name_hint = stream.resource_path.get_file()
	elif stream.resource_name != "":
		name_hint = stream.resource_name
	else:
		name_hint = "<unnamed>"

	var length_s: float = 0.0
	if stream.has_method("get_length"):
		length_s = stream.call("get_length")

	_dbg("▶ play_next idx=%d name=%s len≈%.2fs vol=%.2f bus=%s" %
		[idx, name_hint, length_s, _player.volume_db, _player.bus])


func _on_track_finished() -> void:
	_dbg("_on_track_finished()")
	_play_next(false)


func _set_bus_safe(bus_name: String) -> void:
	var idx: int = AudioServer.get_bus_index(bus_name)
	if idx < 0:
		_player.bus = "Master"
		_dbg("bus '%s' not found; using Master" % bus_name)
	else:
		_player.bus = bus_name


func _dbg(msg: String) -> void:
	if debug_logs:
		print("%s %s" % [_LOG_TAG, msg])
