# res://scripts/combat/ctb/CTBModel.gd
extends RefCounted
class_name CTBModel

var gauge_size: int
var gauge: float
var fill_scale: float
var ctb_speed: float
var ready: bool

# New
var speed_mult: float = 1.0        # haste/slow (0.0..inf)
var queued_tick: bool = false      # edge flag: became-ready this tick

func _init(_gauge_size: int, _fill_scale: float, _ctb_speed: float) -> void:
	gauge_size = max(1, _gauge_size)
	fill_scale = maxf(0.0, _fill_scale)
	ctb_speed = maxf(0.0, _ctb_speed)
	gauge = 0.0
	ready = false
	speed_mult = 1.0
	queued_tick = false

# returns true iff this tick crossed "ready"
func tick(delta: float) -> bool:
	queued_tick = false
	if ready:
		return false
	var d: float = maxf(0.0, delta) * ctb_speed * fill_scale * maxf(0.0, speed_mult)
	if d <= 0.0:
		return false
	var before: float = gauge
	gauge = minf(float(gauge_size), gauge + d)
	if (before < float(gauge_size)) and (gauge >= float(gauge_size)):
		ready = true
		queued_tick = true
	return queued_tick

func consume(cost: int) -> void:
	var c: float = float(max(0, cost))
	gauge = clampf(gauge - c, 0.0, float(gauge_size))
	ready = false
	queued_tick = false

# Helpers
func progress_01() -> float:
	return (gauge / float(max(1, gauge_size)))

func set_speed_mult(m: float) -> void:
	speed_mult = maxf(0.0, m)

func add_delay_raw(units: float) -> void:
	# Positive "units" adds delay (subtracts gauge). Passing negative "units" PREFILLS the gauge.
	if units == 0.0:
		return
	gauge = clampf(gauge - units, 0.0, float(gauge_size))
	if gauge < float(gauge_size):
		ready = false

func reset_ready() -> void:
	ready = false
	queued_tick = false

# -------------------------
# Static helpers (keep BC thin)
# -------------------------

static func scale_cost_for(params: CTBParams, base_cost: int) -> int:
	var base_g: float = float(max(1, params.baseline_gauge))
	var cur_g: float = float(max(1, params.gauge_size))
	var scaled: float = float(max(0, base_cost)) * (cur_g / base_g)
	return max(1, int(round(scaled)))

static func apply_initiative(
	mode: String,
	player_ctb: CTBModel,
	monster_ctb: CTBModel,
	player_speed: float,
	monster_speed: float,
	params: CTBParams
) -> void:
	var G: float = float(max(1, params.gauge_size))
	var ps: float = maxf(0.001, player_speed)
	var ms: float = maxf(0.001, monster_speed)
	var cap: float = clampf(params.initiative_cap_pct, 0.0, 0.95)
	var base_n: float = clampf(params.neutral_base_pct, 0.0, 0.95)
	var span_n: float = clampf(params.neutral_span_pct, 0.0, 0.95 - base_n)

	match mode.to_lower():
		"player":
			# Player full; monster up to cap scaled by (ms/ps)
			player_ctb.add_delay_raw(-G)
			var m_pct: float = clampf((ms / ps) * cap, 0.0, cap)
			monster_ctb.add_delay_raw(-(G * m_pct))
		"monster":
			monster_ctb.add_delay_raw(-G)
			var p_pct: float = clampf((ps / ms) * cap, 0.0, cap)
			player_ctb.add_delay_raw(-(G * p_pct))
		_:
			# Neutral split by speed share within [base .. base+span]
			var total: float = ps + ms
			var p_pct_n: float = base_n + span_n * (ps / total)
			var m_pct_n: float = base_n + span_n * (ms / total)
			player_ctb.add_delay_raw(-(G * p_pct_n))
			monster_ctb.add_delay_raw(-(G * m_pct_n))

func time_to_ready() -> float:
	# Returns seconds to reach ready from current gauge (0 if already ready).
	if ready:
		return 0.0
	var rate: float = ctb_speed * fill_scale * maxf(0.0, speed_mult)
	if rate <= 0.0:
		return INF
	var need: float = float(gauge_size) - gauge
	if need <= 0.0:
		return 0.0
	return need / rate
