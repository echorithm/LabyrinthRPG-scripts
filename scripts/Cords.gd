# res://ui/Cords.gd
extends Label

@export var target_path: NodePath     # Player node (Node3D). If empty, tries "player"/"Player" group.
@export var dungeon_path: NodePath    # DungeonGenerator (to read CELL size via get_cell_size()).
@export var update_hz: float = 10.0   # UI update rate
@export var decimals: int = 1         # decimal places for world coords
@export var show_grid_cell: bool = true
@export var prefix: String = ""       # optional text prefix

var _target: Node3D = null
var _cell: float = 4.0
var _accum: float = 0.0

func _ready() -> void:
	# Anchor to top-right with a small margin
	anchor_left = 1.0; anchor_right = 1.0
	anchor_top = 0.0;  anchor_bottom = 0.0
	offset_right = -8.0
	offset_top   = 8.0
	offset_left  = -220.0   # width (negative from the right)
	offset_bottom = 8.0

	horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	vertical_alignment   = VERTICAL_ALIGNMENT_TOP

	_resolve_target()
	_resolve_cell_size()
	_update_now()

func _process(delta: float) -> void:
	_accum += delta
	var hz: float = max(1.0, update_hz)
	var step: float = 1.0 / hz
	if _accum >= step:
		_accum = 0.0
		_update_now()


func _update_now() -> void:
	if _target == null:
		_resolve_target()
	if _target == null:
		text = prefix + "pos=—"
		return

	var p: Vector3 = _target.global_transform.origin
	var x: float = p.x
	var z: float = p.z

	# format world coords
	var snap := pow(10.0, -decimals)
	var pos_str := "x=" + str(snappedf(x, snap)) + "  z=" + str(snappedf(z, snap))

	if show_grid_cell and _cell > 0.0:
		var cx: int = int(floor(x / _cell))
		var cz: int = int(floor(z / _cell))
		text = ("%s%s\ncell=(%d,%d)") % [prefix, pos_str, cx, cz]
	else:
		text = prefix + pos_str

func _resolve_target() -> void:
	if target_path != NodePath():
		_target = get_node_or_null(target_path) as Node3D
		if _target: return
	# fallbacks: groups "player" or "Player"
	var g := get_tree().get_nodes_in_group("player")
	if g.is_empty():
		g = get_tree().get_nodes_in_group("Player")
	if g.size() > 0 and g[0] is Node3D:
		_target = g[0] as Node3D

func _resolve_cell_size() -> void:
	if dungeon_path != NodePath():
		var d := get_node_or_null(dungeon_path)
		if d and d.has_method("get_cell_size"):
			_cell = float(d.call("get_cell_size"))
			return
	# last resort default
	_cell = 4.0
