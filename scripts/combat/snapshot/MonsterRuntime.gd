# Godot 4.4.1
extends Resource
class_name MonsterRuntime

@export var id: int = 0
@export var slug: StringName = &""
@export var display_name: String = ""
@export var scene_path: String = ""
@export var role: String = "trash"

@export var level_baseline: int = 1
@export var final_level: int = 1

@export var base_stats: Dictionary = {}   # 8-key ints
@export var final_stats: Dictionary = {}  # 8-key ints
@export var ability_levels: Dictionary = {}  # { id: int }
@export var abilities: Array = []            # normalized ability dicts (readonly at runtime)

# Derived (computed)
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
