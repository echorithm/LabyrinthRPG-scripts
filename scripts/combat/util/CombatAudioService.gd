# res://scripts/combat/util/CombatAudioService.gd
extends Node


const AbilityCatalog := preload("res://persistence/services/ability_catalog_service.gd")

@export var sfx_bus: String = "SFX"
@export_dir var ability_sfx_dir: String = "res://audio/abilities"
@export var initial_pool_size: int = 8
@export var max_pool_size: int = 16
@export var random_pitch_range: Vector2 = Vector2(0.98, 1.02)
@export var debug_logs: bool = false


var _cache: Dictionary = {}                  # sound_key -> AudioStream
var _pool: Array[AudioStreamPlayer] = [] as Array[AudioStreamPlayer]

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	for i: int in range(max(0, initial_pool_size)):
		var p: AudioStreamPlayer = AudioStreamPlayer.new()
		p.bus = sfx_bus
		add_child(p)
		_pool.append(p)

func play_for_ability(ability_id: String, interrupt: bool = false) -> void:
	var row_any: Variant = AbilityCatalog.get_by_id(ability_id)
	if typeof(row_any) != TYPE_DICTIONARY:
		return
	var row: Dictionary = row_any
	var key: String = String(row.get("sound_key", ""))
	if key == "":
		return
	play_key(key, interrupt)

func play_key(sound_key: String, interrupt: bool = false) -> void:
	var stream: AudioStream = _resolve_stream(sound_key)
	if stream == null:
		return
	var p: AudioStreamPlayer = _borrow_player(interrupt)
	# slight pitch variation to avoid "machine-gun" repetition
	var pitch: float = randf_range(random_pitch_range.x, random_pitch_range.y)
	p.pitch_scale = pitch
	p.stream = stream
	p.play()
	if debug_logs:
		print("[SFX] play ", sound_key, " pitch=", "%.2f" % pitch)

func _borrow_player(interrupt: bool) -> AudioStreamPlayer:
	for i: int in range(_pool.size()):
		var p_free: AudioStreamPlayer = _pool[i]
		if not p_free.playing:
			return p_free
	if interrupt and _pool.size() > 0:
		var p_int: AudioStreamPlayer = _pool[0]
		p_int.stop()
		return p_int
	if _pool.size() < max_pool_size:
		var p_new: AudioStreamPlayer = AudioStreamPlayer.new()
		p_new.bus = sfx_bus
		add_child(p_new)
		_pool.append(p_new)
		return p_new
	return _pool[0]

func _resolve_stream(sound_key: String) -> AudioStream:
	var cached: AudioStream = _cache.get(sound_key, null) as AudioStream
	if cached != null:
		return cached

	var base: String = ability_sfx_dir
	if base.length() > 0 and base.ends_with("/"):
		base = base.substr(0, base.length() - 1)

	var path: String = sound_key if sound_key.begins_with("res://") else (base + "/" + sound_key)
	var stream := load(path) as AudioStream
	if stream == null:
		if debug_logs:
			push_warning("SFX resolve failed: " + path)
		return null

	_cache[sound_key] = stream
	return stream
