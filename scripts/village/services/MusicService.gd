# res://scripts/services/MusicService.gd
extends Node
class_name MusicService

@onready var _player: AudioStreamPlayer = $Player

const _MUSIC_DIR := "res://audio/village"
const _LOG_TAG := "[MusicService]"
const _ENABLE_LOG := false

@export var bgm_bus: String = "Master"
@export var editor_playlist: Array[AudioStream] = []  # drag village tracks here if you prefer

var _playlist: Array[AudioStream] = []
var _queue: Array[int] = []
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()
var _fade_tween: Tween

func _ready() -> void:
	_rng.randomize()
	_log("=== READY ===")
	_log("OS=%s  debug=%s" % [OS.get_name(), str(OS.has_feature("debug"))])
	_set_bus_safe()
	_dump_audio_buses()

	if not is_instance_valid(_player):
		_warn("AudioStreamPlayer missing at $Player; music disabled.")
		return

	_log("Dir exists (%s): %s" % [_MUSIC_DIR, str(DirAccess.dir_exists_absolute(_MUSIC_DIR))])
	_load_playlist()

	if _playlist.is_empty():
		_warn("No audio files found in %s" % _MUSIC_DIR)
		return

	if not _player.finished.is_connected(_on_track_finished):
		_player.finished.connect(_on_track_finished)
		_log("Connected 'finished' signal.")

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

	# Option A: explicit references force export inclusion
	if editor_playlist.size() > 0:
		for s in editor_playlist:
			if s != null:
				_playlist.append(s)
		_log("Loaded %d tracks from editor_playlist." % _playlist.size())
		if _playlist.size() > 0:
			return

	# Option B: scan the folder (works in editor; on export we also try .import fallback)
	var files: PackedStringArray = DirAccess.get_files_at(_MUSIC_DIR)
	_log("get_files_at(%s) → %d file(s): %s" % [_MUSIC_DIR, files.size(), files])

	var import_bases: Array[String] = []
	for f in files:
		var ext := f.get_extension().to_lower()
		if ext == "wav" or ext == "ogg" or ext == "mp3":
			_try_add_stream(_MUSIC_DIR.path_join(f))
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
			_try_add_stream(_MUSIC_DIR.path_join(base))

	_log("Playlist size: %d" % _playlist.size())

	if _playlist.is_empty() and import_bases.size() > 0:
		_warn("Only '.import' files found. Add export filters for %s (e.g., *.wav/*.ogg/*.mp3) or populate editor_playlist." % _MUSIC_DIR)

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
	# Fisher–Yates
	for i in range(_queue.size() - 1, 0, -1):
		var j: int = _rng.randi_range(0, i)
		var t: int = _queue[i]
		_queue[i] = _queue[j]
		_queue[j] = t
	_log("Queue reseeded/shuffled: %s" % [_queue])

func _play_next(fade_in: bool = false) -> void:
	if _queue.is_empty():
		_log("Queue empty; reseeding.")
		_reseed_queue()
	var idx: int = _queue.pop_back()
	if idx < 0 or idx >= _playlist.size():
		_warn("Index out of range from queue: %d" % idx)
		return

	var stream: AudioStream = _playlist[idx]
	_player.stream = stream
	_player.play()

	if fade_in:
		_player.volume_db = -60.0
		if is_instance_valid(_fade_tween):
			_fade_tween.kill()
		_fade_tween = create_tween()
		_fade_tween.tween_property(_player, "volume_db", 0.0, 0.4)

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

	_log("▶ Playing idx=%d  name=%s  length≈%.2fs  volume_db=%.2f  bus=%s  playing=%s" %
		[idx, name_hint, length_s, _player.volume_db, _player.bus, str(_player.playing)])

func _on_track_finished() -> void:
	_log("Track finished; advancing.")
	_play_next()

func skip() -> void:
	_log("Skip requested. Stopping current=%s" % str(_player.playing))
	if _player.playing:
		_player.stop()
	_play_next(true)

func set_volume_db(v: float) -> void:
	_player.volume_db = v
	_log("Volume set to %.2f dB" % v)

func stop() -> void:
	if is_instance_valid(_fade_tween):
		_fade_tween.kill()
	_player.stop()

func _dump_audio_buses() -> void:
	for i in range(AudioServer.get_bus_count()):
		var name := AudioServer.get_bus_name(i)
		var vol_db := AudioServer.get_bus_volume_db(i)
		var muted := AudioServer.is_bus_mute(i)
		var solo := AudioServer.is_bus_solo(i)
		_log("Bus[%d] name=%s vol_db=%.2f muted=%s solo=%s" % [i, name, vol_db, str(muted), str(solo)])

func _log(msg: String) -> void:
	if _ENABLE_LOG:
		print("%s %s" % [_LOG_TAG, msg])

func _warn(msg: String) -> void:
	push_warning("%s %s" % [_LOG_TAG, msg])
	if _ENABLE_LOG:
		print("%s [WARN] %s" % [_LOG_TAG, msg])
