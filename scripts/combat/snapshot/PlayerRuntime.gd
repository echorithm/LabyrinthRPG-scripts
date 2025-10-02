# Godot 4.4.1
extends Resource
class_name PlayerRuntime

@export var base_stats: Dictionary = {}   # 8-key ints
@export var final_stats: Dictionary = {}  # after buffs (MVP: same as base)
@export var hp_max: int = 1
@export var mp_max: int = 0
@export var hp: int = 1
@export var mp: int = 0

@export var p_atk: float = 0.0
@export var m_atk: float = 0.0
@export var defense: float = 0.0
@export var resistance: float = 0.0
@export var crit_chance: float = 0.0
@export var crit_multi: float = 1.0
@export var ctb_speed: float = 1.0

# --- transient battle-only state ---
@export var guard_active: bool = false
@export var guard_pending_clear_on_next_turn: bool = false
