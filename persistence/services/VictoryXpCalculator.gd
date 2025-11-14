# res://persistence/services/VictoryXpCalculator.gd
extends RefCounted
class_name VictoryXpCalculator

## Enemy row: { monster_level:int, role:int } where role is XpTuning.Role
## ability_hits_by_enemy: { ability_id:String -> { enemy_index:int -> uses:int } }
## allies_count: number of allied actors sharing CHARACTER XP (skills are per-actor and not split)

static func compute_character_xp(player_level: int, enemies: Array, allies_count: int = 1) -> int:
	return XpTuning.char_xp_for_victory_v2(player_level, enemies, allies_count)

static func compute_skill_xp(player_level: int, enemies: Array, ability_hits_by_enemy: Dictionary) -> Dictionary:
	return XpTuning.skill_xp_for_victory_v2(player_level, enemies, ability_hits_by_enemy)
