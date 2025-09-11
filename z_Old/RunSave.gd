extends Resource
class_name RunSave

@export var schema_version: int = 1

# Core run meta
@export var run_seed: int = 0
@export var depth: int = 1

# Player snapshot for the run
@export var hp_max: int = 30
@export var hp: int = 30
@export var mp_max: int = 10
@export var mp: int = 10
@export var gold: int = 0
@export var items: Array[StringName] = []

# --- NEW: boss sigil "pity" (per current segment, session-only) ---
@export var sigils_segment_id: int = 1                  # which segment we're currently charging in
@export var sigils_elites_killed_in_segment: int = 0    # session counter
@export var sigils_required_elites: int = 4             # requirement to charge
@export var sigils_charged: bool = false                # true => full loot at boss
