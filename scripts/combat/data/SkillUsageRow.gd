extends RefCounted
class_name SkillUsageRow

var uses: int = 0
var hits: int = 0
var crits: int = 0
var total_damage: int = 0

func add_use() -> void:
	uses += 1

func add_impact(hit: bool, crit: bool, damage: int) -> void:
	if hit:
		hits += 1
		total_damage += maxi(damage, 0)
	if crit:
		crits += 1

func merge_from(other: SkillUsageRow) -> void:
	if other == null:
		return
	uses += other.uses
	hits += other.hits
	crits += other.crits
	total_damage += other.total_damage

func to_debug_dict() -> Dictionary:
	return {"uses": uses, "hits": hits, "crits": crits, "total_damage": total_damage}
