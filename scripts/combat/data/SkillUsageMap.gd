extends RefCounted
class_name SkillUsageMap
## A typed wrapper around ability_id -> SkillUsageRow.
## Use this to avoid nested-generic Dictionary warnings.

var rows: Dictionary        # Dictionary[String, SkillUsageRow]

func _init() -> void:
	rows = {}

func touch_row(ability_id: String) -> SkillUsageRow:
	var r: SkillUsageRow = rows.get(ability_id)
	if r == null:
		r = SkillUsageRow.new()
		rows[ability_id] = r
	return r

func add_use(ability_id: String) -> void:
	touch_row(ability_id).add_use()

func add_impact(ability_id: String, hit: bool, crit: bool, damage: int) -> void:
	touch_row(ability_id).add_impact(hit, crit, damage)

func merge_from(other: SkillUsageMap) -> void:
	if other == null:
		return
	for aid in other.rows.keys():
		var mine := touch_row(String(aid))
		mine.merge_from(other.rows[aid])

func to_readonly() -> Dictionary:
	# Shallow copy (safe for UI / rewards)
	var out: Dictionary = {}
	for k in rows.keys():
		out[k] = rows[k]
	return out

func to_debug_dict() -> Dictionary:
	var dbg: Dictionary = {}
	for k in rows.keys():
		dbg[String(k)] = rows[k].to_debug_dict()
	return dbg
