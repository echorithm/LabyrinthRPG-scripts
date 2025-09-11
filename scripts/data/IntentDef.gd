# Enemy move data
extends Resource
class_name IntentDef

# Minimal typed schema used by BattleController and ActionResolver.

@export var id: StringName = &""
@export var display_name: StringName = &""

# Kinds you currently use: "attack", "guard", "heal", "delay"
@export var kind: StringName = &"attack"

# Power and turn cost
@export var power: int = 5                 # <-- this is what your code reads
@export var ctb_cost: int = 100

# Resolver hints
# Schools you’ve referenced: "power", "finesse", "arcane", "divine"
@export var school: StringName = &"power"
@export var to_hit: bool = false
@export var crit_allowed: bool = true
