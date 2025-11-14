extends Resource
class_name MonsterVisualEntry

@export var id: StringName                      # visual key (usually your monster_id, e.g., "M12" or "skeleton")
@export var scene: PackedScene                  # enemy .tscn with mesh/anim/etc.
@export var scale: Vector3 = Vector3.ONE        # optional visual scale override
@export var y_offset_m: float = 0.0             # lift/lower the visual
@export var alias_enemy_id: StringName = &""    # optional: when encounter enemy_id differs from visual id
