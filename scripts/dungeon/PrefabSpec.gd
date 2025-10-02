extends Resource
class_name PrefabSpec

@export var scene: PackedScene
@export var size_cells: Vector2i = Vector2i(2, 2)
@export var margin_cells: int = 1

@export_enum("Center","Random","Fixed") var placement_mode: int = 0
@export var fixed_cell: Vector2i = Vector2i(-1, -1)

@export var count: int = 1
@export var open_sockets: bool = true
@export var extra_offset_m: Vector2 = Vector2.ZERO

# Spawn semantics (use for the “Up/Stairs” room)
@export var is_spawn_room: bool = false
@export var spawn_node_path: NodePath      # e.g. "PlayerSpawn"

# Finish semantics (use for the “Down/Stairs” room)
@export var is_finish_room: bool = false
@export var finish_node_path: NodePath     # Area3D for finish trigger
@export var finish_door_path: NodePath     # OPTIONAL: Door node you want locked until key
