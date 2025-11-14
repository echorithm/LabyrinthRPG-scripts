# res://scripts/combat/ctb/CTBParams.gd
extends Resource
class_name CTBParams

# Gauge size and fill rate
@export var gauge_size: int = 1000
@export var fill_scale: float = 200.0  # units/sec at ctb_speed=1, speed_mult=1

# --- New: cost scaling & initiative tuning ---
# Abilities in your JSON were authored around ~100 CTB cost; keep that feel even if you change gauge_size.
@export var baseline_gauge: int = 1000        # authoring baseline; cost scales by (gauge_size / baseline_gauge)

# Initiative presets (applied once at battle start)
# - "player": player starts full; monster starts up to initiative_cap_pct scaled by (monster_speed / player_speed)
# - "monster": inverse of above
# - "neutral": both start partially full based on speed share between [neutral_base_pct .. neutral_base_pct+neutral_span_pct]
@export var initiative_cap_pct: float = 0.60   # cap on slower side’s prefill in advantage cases
@export var neutral_base_pct: float = 0.30     # neutral start baseline
@export var neutral_span_pct: float = 0.30     # neutral extra spread allocated by relative speed
