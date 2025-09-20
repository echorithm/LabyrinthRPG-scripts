extends Resource
class_name PenaltyConfig

@export var level_pct: float = 0.10            # P_L: character level loss on death (10%)
@export var skill_xp_pct: float = 0.15         # P_S: skill XP loss on death (15%)
@export var floor_at_level: int = 1            # clamp min character level
@export var floor_at_skill_level: int = 1      # clamp min skill level
