extends OmniLight3D

# ---------------- Base ----------------
@export var enabled_on_start: bool = true
@export var base_energy: float = 2.2
@export var base_range: float = 7.0
@export var warm_color: Color = Color(1.0, 0.85, 0.55)

@export var cast_shadows: bool = true
@export var shadow_bias_val: float = 0.03
@export var shadow_normal_bias_val: float = 0.6

# ---------------- Per-torch randomization ----------------
@export var randomize_on_ready: bool = true
@export var seed: int = -1
@export_range(0.0, 1.0, 0.001) var energy_variation: float = 0.25
@export_range(0.0, 1.0, 0.001) var range_variation:  float = 0.15
@export_range(0.0, 0.10, 0.001) var hue_jitter: float      = 0.02
@export_range(0.0, 0.30, 0.001) var sat_jitter: float      = 0.08
@export_range(0.0, 1.0, 0.01)  var start_off_chance: float = 0.0
@export_range(0.0, 1.0, 0.01)  var speed_variation: float  = 0.20

# ---------------- Flicker ----------------
@export_enum("Sine+Jitter", "Noisy", "Sparks", "Flame") var flicker_model: int = 3
@export var flicker_strength: float = 0.16
@export var flicker_speed: float = 1.0
@export var jitter_range: float = 0.15
@export var jitter_interval: Vector2 = Vector2(0.12, 0.34)

# ---------------- Flame extras ----------------
@export var response_rate: float = 3.0
@export var color_shift_strength: float = 0.035
@export var range_coupling: float = 0.18

# Optional gentle motion
@export var jitter_position: bool = false
@export var position_amplitude: float = 0.02
@export var position_speed: float = 2.5

# ---------------- Sound (positional) ----------------
@export_file("*.wav","*.ogg","*.mp3") var flame_loop_path: String = "res://audio/ui/torch.mp3"
@export var sfx_bus: String = "SFX"

# Audible defaults
@export var sound_volume_db: float = 0.0
@export var sound_max_distance: float = 60.0
@export var sound_unit_size: float = 1.0
@export var sound_pitch_jitter: float = 0.03
@export var sound_enabled: bool = true
@export_enum("InverseSquare","Inverse","Log") var attenuation_model_pick: int = 2  # Log default

# Close-up punch (hard boost inside small radius)
@export var near_boost_db: float = 8
@export var near_boost_radius_m: float = 4.2
@export var near_boost_smooth: float = 20.0  # 1/sec

# NEW: smooth "pass-by" presence from ~1m out to ~6m
@export var passby_boost_db: float = 12
@export var passby_near_m: float = 0.8
@export var passby_far_m: float = 30.0
@export var passby_smooth: float = 12.0  # 1/sec

# Cap overall loudness close-up
@export var max_close_gain_db: float = 15.0

# Fallback routing if SFX bus does not exist
@export var bus_fallback_to_master: bool = true

# ---------------- Debug ----------------
@export var debug_verbose: bool = false
@export var debug_sound: bool = false
@export var debug_tick_s: float = 1.0

# ---------------- Internals ----------------
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()
var _phase: float = 0.0
var _time_to_next_jitter: float = 0.1

var _base_energy_actual: float = 0.0
var _base_range_actual: float = 0.0
var _warm_color_actual: Color = Color(1,1,1)

var _target_energy: float = 0.0
var _origin: Vector3 = Vector3.ZERO

var _t: float = 0.0
var _noise: FastNoiseLite = FastNoiseLite.new()

var _snd: AudioStreamPlayer3D = null
var _dbg_accum: float = 0.0
var _base_vol_db_applied: float = 0.0
var _current_vol_db: float = 0.0

# ---------------- Lifecycle ----------------
func _ready() -> void:
	_origin = position
	if seed >= 0:
		_rng.seed = seed
	else:
		_rng.randomize()

	# light params
	_base_energy_actual = base_energy
	_base_range_actual  = base_range
	_warm_color_actual  = warm_color
	if randomize_on_ready:
		_base_energy_actual *= 1.0 + _rng.randf_range(-energy_variation, energy_variation)
		_base_range_actual  *= 1.0 + _rng.randf_range(-range_variation,  range_variation)
		var h: float = warm_color.h
		var s: float = warm_color.s
		var v: float = warm_color.v
		h = fposmod(h + _rng.randf_range(-hue_jitter, hue_jitter), 1.0)
		s = clamp(s + _rng.randf_range(-sat_jitter, sat_jitter), 0.0, 1.0)
		_warm_color_actual = Color.from_hsv(h, s, v, warm_color.a)
		flicker_speed    *= 1.0 + _rng.randf_range(-speed_variation, speed_variation)
		flicker_strength *= 1.0 + _rng.randf_range(-0.25, 0.25)

	light_color         = _warm_color_actual
	omni_range          = _base_range_actual
	shadow_enabled      = cast_shadows
	shadow_bias         = shadow_bias_val
	shadow_normal_bias  = shadow_normal_bias_val
	light_cull_mask     = 0x7fffffff

	_phase         = _rng.randf_range(0.0, TAU)
	_target_energy = _base_energy_actual

	_noise.seed = (seed if seed >= 0 else int(_rng.randi()))
	_noise.frequency = 0.8 * max(0.05, flicker_speed * 0.25)

	if sound_enabled:
		_snd = AudioStreamPlayer3D.new()
		_snd.name = "TorchSound"
		_snd.stream = load(flame_loop_path) as AudioStream
		_snd.max_polyphony = 1
		_snd.unit_size = sound_unit_size
		_snd.pitch_scale = 1.0 + _rng.randf_range(-sound_pitch_jitter, sound_pitch_jitter)
		add_child(_snd, true)

		var idx: int = AudioServer.get_bus_index(sfx_bus)
		if idx >= 0: _snd.bus = sfx_bus
		elif bus_fallback_to_master:
			_snd.bus = "Master"
			if debug_sound: print("[TorchSound][WARN] bus '", sfx_bus, "' missing; using Master")

		_apply_atten_model(attenuation_model_pick)
		_snd.max_distance = sound_max_distance
		_snd.max_db = _safe_cap_db()
		_base_vol_db_applied = sound_volume_db
		_current_vol_db = _base_vol_db_applied
		_snd.volume_db = _current_vol_db

		_force_stream_loop(_snd.stream)
		if debug_sound:
			if _snd.stream == null: print("[TorchSound][WARN] stream failed to load from: ", flame_loop_path)
			else:
				print("[TorchSound] ready-created: stream ok from: ", flame_loop_path)
				_dbg_sound_state("ready")

	var start_on: bool = enabled_on_start
	if randomize_on_ready and (_rng.randf() < start_off_chance): start_on = false
	set_enabled(start_on)
	set_process(true)

# ---------------- Public API ----------------
func set_enabled(on: bool) -> void:
	visible      = on
	light_energy = (_base_energy_actual if on else 0.0)
	if _snd != null:
		if on and _snd.stream != null and not _snd.playing: _start_sound_with_random_offset()
		elif (not on) and _snd.playing: _snd.stop()
	_dbg_sound_state("set_enabled(" + str(on) + ")")

# ---------------- Process ----------------
func _process(dt: float) -> void:
	if not visible: return

	# debug tick
	if debug_sound and _snd != null:
		_dbg_accum += dt
		if _dbg_accum >= max(0.1, debug_tick_s):
			_dbg_accum = 0.0
			var d: float = _dbg_cam_distance()
			if d >= 0.0 and d > _snd.max_distance:
				print("[TorchSound] tick: listener > max_distance (", str(d), " > ", str(_snd.max_distance), ")")
			_dbg_sound_state("tick")

	# --- Pass-by presence boost (smooth) + near punch (hard) ---
	if _snd != null:
		var d2: float = _dbg_cam_distance()
		var target_db: float = _base_vol_db_applied

		# near punch
		if near_boost_db > 0.0 and near_boost_radius_m > 0.0 and d2 >= 0.0 and d2 <= near_boost_radius_m:
			target_db = _cap_db(_base_vol_db_applied + near_boost_db)

		# pass-by presence (smoothstep from near->far)
		if passby_boost_db > 0.0 and d2 >= 0.0 and d2 <= max(passby_near_m, passby_far_m):
			var n: float = min(passby_near_m, passby_far_m)
			var f: float = max(passby_near_m, passby_far_m + 0.001)
			var t: float = clamp((d2 - n) / max(0.001, f - n), 0.0, 1.0)
			var s: float = t * t * (3.0 - 2.0 * t)  # smoothstep
			var boost: float = passby_boost_db * (1.0 - s)
			target_db = maxf(target_db, _cap_db(_base_vol_db_applied + boost))

		_current_vol_db = _smooth_to(_current_vol_db, target_db, (passby_smooth if target_db > _current_vol_db else near_boost_smooth), dt)
		_snd.volume_db = _current_vol_db

	match flicker_model:
		0: _flicker_sine_jitter(dt)
		1: _flicker_noisy(dt)
		2: _flicker_sparks(dt)
		3: _flicker_flame(dt)

	if jitter_position:
		var wob1: float = sin(_phase * position_speed * 0.37 + 1.7)
		var wob2: float = sin(_phase * position_speed * 0.71 + 0.3)
		var wob3: float = sin(_phase * position_speed * 1.03 + 2.1)
		position = _origin + Vector3(wob1, wob2 * 0.6, wob3 * 0.4) * position_amplitude

# ---------------- Helpers ----------------
func _apply_atten_model(pick: int) -> void:
	if _snd == null: return
	match pick:
		1: _snd.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
		2: _snd.attenuation_model = AudioStreamPlayer3D.ATTENUATION_LOGARITHMIC
		_: _snd.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_SQUARE_DISTANCE

func _smooth_to(current: float, target: float, rate: float, dt: float) -> float:
	var k: float = 1.0 - exp(-max(0.0, rate) * dt)
	return current + (target - current) * k

func _safe_cap_db() -> float:
	if typeof(max_close_gain_db) == TYPE_NIL: return 18.0
	if typeof(max_close_gain_db) == TYPE_INT or typeof(max_close_gain_db) == TYPE_FLOAT:
		return float(max_close_gain_db)
	return 18.0

func _cap_db(v: float) -> float:
	return minf(v, _safe_cap_db())

func _start_sound_with_random_offset() -> void:
	if _snd == null or _snd.stream == null: return
	var length_s: float = 0.0
	if _snd.stream.has_method("get_length"): length_s = float(_snd.stream.get_length())
	var ofs: float = 0.0
	if length_s > 0.1:
		var max_ofs: float = max(0.0, length_s - 0.05)
		ofs = _rng.randf_range(0.0, max_ofs)
	_snd.play(ofs)

func _force_stream_loop(st: AudioStream) -> void:
	if st == null: return
	if st is AudioStreamOggVorbis:
		var ogg: AudioStreamOggVorbis = st; ogg.loop = true
	elif st is AudioStreamMP3:
		var mp3: AudioStreamMP3 = st; mp3.loop = true
	elif st is AudioStreamWAV:
		var wav: AudioStreamWAV = st; wav.loop_mode = AudioStreamWAV.LOOP_FORWARD

# ---------------- Flicker models ----------------
func _flicker_sine_jitter(dt: float) -> void:
	_phase += dt * TAU * max(0.01, flicker_speed)
	var base_wobble: float = 1.0 + sin(_phase) * (flicker_strength * 0.23)
	_time_to_next_jitter -= dt
	if _time_to_next_jitter <= 0.0:
		_target_energy = _base_energy_actual * (1.0 + _rng.randf_range(-jitter_range, jitter_range))
		_time_to_next_jitter = _rng.randf_range(jitter_interval.x, jitter_interval.y)
	var current: float = _smooth_to(light_energy, _target_energy, response_rate, dt)
	light_energy = current * base_wobble

func _flicker_noisy(dt: float) -> void:
	_phase += dt
	var n1: float = sin(_phase * 2.2)
	var n2: float = sin(_phase * 3.9 + 1.3)
	var n3: float = sin(_phase * 6.7 + 2.2)
	var low: float = sin(_phase * 0.6) * 0.5 + 0.5
	var noise: float = (n1 * 0.5 + n2 * 0.3 + n3 * 0.2) * 0.5 + low * 0.5
	var mult: float = 1.0 + noise * (flicker_strength * 0.4)
	var target: float = _base_energy_actual * mult
	light_energy = _smooth_to(light_energy, target, response_rate, dt)

func _flicker_sparks(dt: float) -> void:
	_flicker_sine_jitter(dt)
	if _rng.randf() < dt * 0.2:
		light_energy = min(light_energy + _base_energy_actual * 0.35, _base_energy_actual * 1.8)
	if _rng.randf() < dt * 0.1:
		_target_energy = _base_energy_actual * _rng.randf_range(0.65, 0.85)

func _flicker_flame(dt: float) -> void:
	_t += dt
	var base_n: float = _noise.get_noise_1d(_t)
	var ripple_n: float = _noise.get_noise_1d(_t * (6.0 * flicker_speed + 3.0))
	base_n = pow((base_n * 0.5 + 0.5), 1.2) * 2.0 - 1.0
	var wobble: float = base_n * 0.65 + ripple_n * 0.12
	var mult: float = 1.0 + wobble * flicker_strength
	var target: float = _base_energy_actual * mult
	light_energy = _smooth_to(light_energy, target, response_rate, dt)

	var bright_ratio: float = clampf(light_energy / maxf(0.001, _base_energy_actual), 0.0, 2.0)
	omni_range = _base_range_actual * (1.0 + (bright_ratio - 1.0) * range_coupling)

	if color_shift_strength > 0.0:
		var h: float = _warm_color_actual.h + wobble * color_shift_strength
		var s: float = _warm_color_actual.s
		var v: float = _warm_color_actual.v
		light_color = Color.from_hsv(fposmod(h, 1.0), s, v, _warm_color_actual.a)

	if debug_verbose:
		print("[Flame] E=%.2f targ=%.2f wob=%.2f range=%.2f hue=%.3f" % [
			light_energy, target, wobble, omni_range, light_color.h])

# ---------------- Debug helpers ----------------
func _dbg_bus_line(bus_name: String) -> String:
	var idx: int = AudioServer.get_bus_index(bus_name)
	if idx < 0: return "bus='%s' idx=<missing>" % bus_name
	var vol_db: float = AudioServer.get_bus_volume_db(idx)
	var muted: bool = AudioServer.is_bus_mute(idx)
	return "bus='%s' idx=%d vol_db=%.1f muted=%s" % [bus_name, idx, vol_db, str(muted)]

func _dbg_cam_distance() -> float:
	var cam: Camera3D = get_viewport().get_camera_3d()
	if cam == null: return -1.0
	return (global_transform.origin - cam.global_transform.origin).length()

func _dbg_sound_state(tag: String) -> void:
	if not debug_sound: return
	var has_stream: bool = (_snd != null and _snd.stream != null)
	var playing: bool = (_snd != null and _snd.playing)
	var pos_s: float = 0.0
	if _snd != null: pos_s = _snd.get_playback_position()
	var dist: float = _dbg_cam_distance()
	var dist_s: String = "<no Camera3D>" if dist < 0.0 else ("%.2f m" % dist)
	var stream_len: float = 0.0
	if has_stream and _snd.stream.has_method("get_length"): stream_len = float(_snd.stream.get_length())
	var atn_name: String = "?"
	if _snd != null:
		match _snd.attenuation_model:
			AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE: atn_name = "INV_DIST"
			AudioStreamPlayer3D.ATTENUATION_INVERSE_SQUARE_DISTANCE: atn_name = "INV_SQ"
			AudioStreamPlayer3D.ATTENUATION_LOGARITHMIC: atn_name = "LOG"
			_: atn_name = "?"
	var master_line: String = _dbg_bus_line("Master")
	var sfx_line: String = _dbg_bus_line(sfx_bus)
	print("[TorchSound] ", tag, " | on=", visible, " playing=", playing, " stream=", has_stream,
		" pos=", "%.2fs" % pos_s, " len=", "%.2fs" % stream_len, " pitch=", "%.3f" % (_snd.pitch_scale if _snd != null else 0.0))
	if _snd != null:
		print("              dist=", dist_s, " vol_db=", "%.1f" % _snd.volume_db,
			" max_dist=", "%.1f" % _snd.max_distance, " unit=", "%.2f" % _snd.unit_size, " atten=", atn_name)
	print("              ", master_line, " | ", sfx_line)
