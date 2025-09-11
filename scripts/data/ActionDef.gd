# Player action data
class_name ActionDef
extends Resource

@export var id: StringName
@export var display_name: String = ""
@export var kind: StringName = &"attack"      # "attack" | "heal" | "block" | "fizzle"
@export var base_power: int = 0
@export var ctb_cost: int = 100

# New fields for resolver
@export var school: StringName = &"power"     # "power" | "finesse" | "arcane" | "divine" | "support"
@export var to_hit: bool = true
@export var crit_allowed: bool = true
