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
@export var seed: int = -1                       # -1 = randomize
@export_range(0.0, 1.0, 0.001) var energy_variation: float = 0.25
@export_range(0.0, 1.0, 0.001) var range_variation:  float = 0.15
@export_range(0.0, 0.10, 0.001) var hue_jitter: float      = 0.02
@export_range(0.0, 0.30, 0.001) var sat_jitter: float      = 0.08
@export_range(0.0, 1.0, 0.01)  var start_off_chance: float = 0.0
@export_range(0.0, 1.0, 0.01)  var speed_variation: float  = 0.20  # +/- % of speed

# ---------------- Flicker ----------------
@export_enum("Sine+Jitter", "Noisy", "Sparks", "Flame") var flicker_model: int = 3
@export var flicker_strength: float = 0.16    # overall effect size
@export var flicker_speed: float = 1.0        # base Hz (used by Flame & others)

# Sine+Jitter params (kept for compatibility)
@export var jitter_range: float = 0.15
@export var jitter_interval: Vector2 = Vector2(0.12, 0.34)

# ---------------- Flame extras ----------------
@export var response_rate: float = 3.0        # 1/sec; lower = smoother
@export var color_shift_strength: float = 0.035  # 0..~0.08 good
@export var range_coupling: float = 0.18      # 0..0.3 recommended

# Optional gentle motion
@export var jitter_position: bool = false
@export var position_amplitude: float = 0.02  # meters
@export var position_speed: float = 2.5

# Debug
@export var debug_verbose: bool = false

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
var _noise := FastNoiseLite.new()  # for Flame model

func _ready() -> void:
	_origin = position

	if seed >= 0: _rng.seed = seed
	else:         _rng.randomize()

	# Per-torch variations
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

		# vary speed & strength a bit per torch
		flicker_speed    *= 1.0 + _rng.randf_range(-speed_variation, speed_variation)
		flicker_strength *= 1.0 + _rng.randf_range(-0.25, 0.25)

	# Base light setup
	light_color         = _warm_color_actual
	omni_range          = _base_range_actual
	shadow_enabled      = cast_shadows
	shadow_bias         = shadow_bias_val
	shadow_normal_bias  = shadow_normal_bias_val
	light_cull_mask     = 0x7fffffff

	_phase         = _rng.randf_range(0.0, TAU)   # de-sync
	_target_energy = _base_energy_actual

	# Noise for Flame model
	_noise.seed = (seed if seed >= 0 else int(_rng.randi()))
	_noise.frequency = 0.8 * max(0.05, flicker_speed * 0.25)  # base noise freq

	var start_on := enabled_on_start
	if randomize_on_ready and (_rng.randf() < start_off_chance):
		start_on = false

	set_enabled(start_on)
	set_process(true)

func set_enabled(on: bool) -> void:
	visible      = on
	light_energy = (_base_energy_actual if on else 0.0)

func _process(dt: float) -> void:
	if not visible:
		return

	match flicker_model:
		0: _flicker_sine_jitter(dt)
		1: _flicker_noisy(dt)
		2: _flicker_sparks(dt)
		3: _flicker_flame(dt)

	if jitter_position:
		var wob1 := sin(_phase * position_speed * 0.37 + 1.7)
		var wob2 := sin(_phase * position_speed * 0.71 + 0.3)
		var wob3 := sin(_phase * position_speed * 1.03 + 2.1)
		position = _origin + Vector3(wob1, wob2 * 0.6, wob3 * 0.4) * position_amplitude

# ---------- Helpers ----------
func _smooth_to(current: float, target: float, rate: float, dt: float) -> float:
	# Exponential smoothing, framerate-independent.
	var k := 1.0 - exp(-max(0.0, rate) * dt)
	return current + (target - current) * k

# ---------- Flicker models ----------
func _flicker_sine_jitter(dt: float) -> void:
	_phase += dt * TAU * max(0.01, flicker_speed)
	var base_wobble := 1.0 + sin(_phase) * (flicker_strength * 0.23)

	_time_to_next_jitter -= dt
	if _time_to_next_jitter <= 0.0:
		_target_energy = _base_energy_actual * (1.0 + _rng.randf_range(-jitter_range, jitter_range))
		_time_to_next_jitter = _rng.randf_range(jitter_interval.x, jitter_interval.y)

	var current := _smooth_to(light_energy, _target_energy, response_rate, dt)
	light_energy = current * base_wobble

func _flicker_noisy(dt: float) -> void:
	_phase += dt
	var n1 := sin(_phase * 2.2)
	var n2 := sin(_phase * 3.9 + 1.3)
	var n3 := sin(_phase * 6.7 + 2.2)
	var low := sin(_phase * 0.6) * 0.5 + 0.5
	var noise := (n1 * 0.5 + n2 * 0.3 + n3 * 0.2) * 0.5 + low * 0.5
	var mult := 1.0 + noise * (flicker_strength * 0.4)
	var target := _base_energy_actual * mult
	light_energy = _smooth_to(light_energy, target, response_rate, dt)

func _flicker_sparks(dt: float) -> void:
	_flicker_sine_jitter(dt)
	if _rng.randf() < dt * 0.2:
		light_energy = min(light_energy + _base_energy_actual * 0.35, _base_energy_actual * 1.8)
	if _rng.randf() < dt * 0.1:
		_target_energy = _base_energy_actual * _rng.randf_range(0.65, 0.85)

# ----------- New: Flame model -----------
func _flicker_flame(dt: float) -> void:
	# Smooth, continuous noise (base) + a tiny ripple (fast)
	_t += dt
	var base_n := _noise.get_noise_1d(_t)                       # [-1,1]
	var ripple_n := _noise.get_noise_1d(_t * (6.0 * flicker_speed + 3.0))  # fast small ripple

	# Shape the noise a little (more time near bright)
	base_n = pow((base_n * 0.5 + 0.5), 1.2) * 2.0 - 1.0         # still ~[-1,1]
	var wobble := base_n * 0.65 + ripple_n * 0.12               # mix

	var mult := 1.0 + wobble * flicker_strength                  # energy multiplier
	var target := _base_energy_actual * mult
	light_energy = _smooth_to(light_energy, target, response_rate, dt)

	# Couple range slightly to perceived brightness
	var bright_ratio: float = clampf(light_energy / maxf(0.001, _base_energy_actual), 0.0, 2.0)
	omni_range = _base_range_actual * (1.0 + (bright_ratio - 1.0) * range_coupling)

	# Gentle color temperature shift (hue only)
	if color_shift_strength > 0.0:
		var h := _warm_color_actual.h + wobble * color_shift_strength
		var s := _warm_color_actual.s
		var v := _warm_color_actual.v
		light_color = Color.from_hsv(fposmod(h, 1.0), s, v, _warm_color_actual.a)

	if debug_verbose:
		print("[Flame] E=%.2f targ=%.2f wob=%.2f range=%.2f hue=%.3f" % [
			light_energy, target, wobble, omni_range, light_color.h])
