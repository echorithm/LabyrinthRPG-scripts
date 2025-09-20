extends Resource
class_name GameSave

@export var version: int = 3

# Core floors (persistent “meta” view)
@export var last_floor: int = 1
@export var current_floor: int = 1
@export var previous_floor: int = 0

# Player snapshot resource (your existing)
@export var player: PlayerSave = PlayerSave.new()

# World flags you already had (kept)
@export var world_flags: Dictionary[StringName, bool] = {}

# Deterministic seeds per floor (kept)
@export var floor_seeds: Dictionary[int, int] = {}   # floor -> RNG seed

# --- NEW: progression / anti-double-dip ---
@export var highest_claimed_level: int = 1          # character-level ceiling for rewards

# --- NEW: penalties (configurable) ---
@export var penalties: PenaltyConfig = PenaltyConfig.new()

# --- NEW: anchors & per-segment state (persistent) ---
@export var anchors_unlocked: PackedInt32Array = PackedInt32Array([1])  # floor anchors; 1 by default
@export var world_segments: Array[WorldSegment] = [WorldSegment.new()]  # at least segment 1 present
