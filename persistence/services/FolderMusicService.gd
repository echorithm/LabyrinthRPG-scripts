# res://persistence/services/FolderMusicService.gd
extends Node
class_name FolderMusicService

@export_dir var music_dir: String = "res://audio/labyrinth"
@export var editor_playlist: Array[AudioStream] = []   # optional: drag tracks here to force export inclusion
@export var shuffle: bool = true
@export var volume_db: float = -6.0
@export var fade_seconds: float = 0.4
@export var bgm_bus: String = "Master"


@onready var _player: AudioStreamPlayer = $Player

const _LOG_TAG := "[FolderMusicService]"
const _ENABLE_LOG := false

var _playlist: Array[AudioStream] = []
var _queue: Array[int] = []
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()
var _fade_tween: Tween

func _ready() -> void:
	_rng.randomize() # UI-only randomness; safe for determinism
	add_to_group("bgm_service")
	_set_bus_safe()

	_log("OS=%s  debug=%s  dir=%s  exists=%s" %
		[OS.get_name(), str(OS.has_feature("debug")), music_dir, str(DirAccess.dir_exists_absolute(music_dir))])

	_load_playlist()
	if _playlist.is_empty():
		_warn("No audio files found in %s" % music_dir)
		return

	_player.volume_db = volume_db
	if not _player.finished.is_connected(_on_track_finished):
		_player.finished.connect(_on_track_finished)

	_reseed_queue()
	_play_next(true)

func _set_bus_safe() -> void:
	var idx := AudioServer.get_bus_index(bgm_bus)
	if idx < 0:
		_log("Bus '%s' not found; using 'Master'." % bgm_bus)
		_player.bus = "Master"
	else:
		_player.bus = bgm_bus

func _load_playlist() -> void:
	_playlist.clear()

	# A) Explicit references force export inclusion
	if editor_playlist.size() > 0:
		for s in editor_playlist:
			if s != null:
				_playlist.append(s)
		_log("Loaded %d tracks from editor_playlist." % _playlist.size())
		if _playlist.size() > 0:
			return

	# B) Folder scan (plus .import fallback for exports)
	var files: PackedStringArray = DirAccess.get_files_at(music_dir)
	_log("get_files_at(%s) → %d file(s): %s" % [music_dir, files.size(), files])

	var import_bases: Array[String] = []
	for f in files:
		var ext := f.get_extension().to_lower()
		if ext == "wav" or ext == "ogg" or ext == "mp3":
			_try_add_stream(music_dir.path_join(f))
		elif f.ends_with(".import"):
			var base := f.substr(0, f.length() - 7) # strip ".import"
			var b_ext := base.get_extension().to_lower()
			if b_ext == "wav" or b_ext == "ogg" or b_ext == "mp3":
				import_bases.append(base)
			else:
				_log("Skipping non-audio .import: %s" % f)
		else:
			_log("Skipping non-audio file: %s" % f)

	if _playlist.is_empty() and import_bases.size() > 0:
		_log("No raw audio visible; resolving via .import bases...")
		for base in import_bases:
			_try_add_stream(music_dir.path_join(base))

	_log("Playlist size: %d" % _playlist.size())

	if _playlist.is_empty() and import_bases.size() > 0:
		_warn("Only '.import' files found in %s. Add export filters (e.g., %s/*.wav, *.ogg, *.mp3) or populate editor_playlist." %
			[music_dir, music_dir])

func _try_add_stream(path: String) -> void:
	var stream := load(path) as AudioStream
	if stream != null:
		_playlist.append(stream)
		var length_s := 0.0
		if stream.has_method("get_length"):
			length_s = stream.call("get_length")
		_log("Loaded: %s  (len≈%.2fs)" % [path, length_s])
	else:
		_warn("Failed to load stream: %s" % path)

func _reseed_queue() -> void:
	_queue.clear()
	for i in range(_playlist.size()):
		_queue.append(i)
	# optional shuffle
	if shuffle:
		for i in range(_queue.size() - 1, 0, -1):
			var j: int = _rng.randi_range(0, i)
			var t: int = _queue[i]
			_queue[i] = _queue[j]
			_queue[j] = t
	_log("Queue reseeded%s: %s" % [(" (shuffled)" if shuffle else ""), _queue])


func _play_next(fade_in: bool = false) -> void:
	if _queue.is_empty():
		_reseed_queue()
	var idx: int = _queue.pop_back()
	if idx < 0 or idx >= _playlist.size():
		_warn("Index out of range from queue: %d" % idx)
		return

	var stream: AudioStream = _playlist[idx]
	_player.stream = stream
	_player.play()

	if fade_in and fade_seconds > 0.0:
		_player.volume_db = -60.0
		if is_instance_valid(_fade_tween):
			_fade_tween.kill()
		_fade_tween = create_tween()
		_fade_tween.tween_property(_player, "volume_db", volume_db, fade_seconds)

	var name_hint := ""
	if stream.resource_path != "":
		name_hint = stream.resource_path.get_file()
	elif stream.resource_name != "":
		name_hint = stream.resource_name
	else:
		name_hint = "<unnamed>"

	var length_s := 0.0
	if stream.has_method("get_length"):
		length_s = stream.call("get_length")

	_log("▶ Playing idx=%d  name=%s  length≈%.2fs  vol_db=%.2f  bus=%s  playing=%s" %
		[idx, name_hint, length_s, _player.volume_db, _player.bus, str(_player.playing)])

func _on_track_finished() -> void:
	_play_next()

# Optional helpers
func skip() -> void:
	_log("Skip requested. Stopping current=%s" % str(_player.playing))
	if _player.playing:
		_player.stop()
	_play_next(true)

func set_volume_db(v: float) -> void:
	volume_db = v
	_player.volume_db = v
	_log("Volume set to %.2f dB" % v)

func stop() -> void:
	if is_instance_valid(_fade_tween):
		_fade_tween.kill()
	_player.stop()

func snapshot_bgm() -> Dictionary:
	var spath := ""
	var idx := -1
	var pos := 0.0
	if _player != null and _player.stream != null:
		spath = String(_player.stream.resource_path)
		if _player.has_method("get_playback_position"):
			pos = _player.get_playback_position()
		for i in range(_playlist.size()):
			if _playlist[i] == _player.stream:
				idx = i
				break
	return {
		"stream_path": spath,
		"index": idx,
		"position": pos,
		"was_playing": _player.playing,
		"volume_db": _player.volume_db
	}

func resume_bgm(snap: Dictionary) -> void:
	if _player == null:
		return
	var spath: String = String(snap.get("stream_path", ""))
	var idx: int = int(snap.get("index", -1))
	var pos: float = float(snap.get("position", 0.0))
	var was_playing: bool = bool(snap.get("was_playing", true))
	var vol: float = float(snap.get("volume_db", volume_db))

	var stream: AudioStream = null
	if spath != "":
		stream = load(spath) as AudioStream
	elif idx >= 0 and idx < _playlist.size():
		stream = _playlist[idx]
	elif _player.stream != null:
		stream = _player.stream

	if stream == null:
		_play_next(true)
		return

	_player.stream = stream
	_player.volume_db = vol
	if was_playing:
		_player.play(pos)

func resume() -> void:
	# generic "just continue" fallback
	if _player == null:
		return
	if _player.stream == null:
		_play_next(true)
	else:
		if not _player.playing:
			_player.play()

# --- Logging ---
func _log(msg: String) -> void:
	if _ENABLE_LOG:
		print("%s %s" % [_LOG_TAG, msg])

func _warn(msg: String) -> void:
	push_warning("%s %s" % [_LOG_TAG, msg])
	if _ENABLE_LOG:
		print("%s [WARN] %s" % [_LOG_TAG, msg])
