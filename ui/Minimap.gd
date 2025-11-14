# res://ui/hud/Minimap.gd
extends Control

@export var dungeon_path: NodePath         # optional; leave blank to auto-find "Dungeon"
@export var player_path: NodePath          # optional; leave blank to auto-find "Player"
@export var fit_to_rect: bool = true
@export var cell_px: int = 10
@export var margin_px: int = 6
@export var north_is_negative_z: bool = true   # top of map = -Z

var _dungeon: Node = null
var _player: Node3D = null
var _cells: Array[Vector2i] = []
var _cell_world: float = 4.0

func _ready() -> void:
	_bind_nodes()
	_refresh_cells()
	set_process(true)

func _process(_dt: float) -> void:
	queue_redraw()

func _bind_nodes() -> void:
	# explicit paths (if provided)
	if dungeon_path != NodePath():
		_dungeon = get_node_or_null(dungeon_path)
	if _dungeon == null:
		_dungeon = get_tree().root.find_child("Dungeon", true, false)

	if player_path != NodePath():
		_player = get_node_or_null(player_path) as Node3D
	if _player == null:
		_player = get_tree().root.find_child("Player", true, false) as Node3D

	if _dungeon and _dungeon.has_method("get_cell_size"):
		_cell_world = float(_dungeon.call("get_cell_size"))

	if _dungeon and _dungeon.has_signal("generation_done"):
		_dungeon.connect("generation_done", Callable(self, "_on_generation_done"))

func _on_generation_done() -> void:
	_refresh_cells()
	queue_redraw()

func _refresh_cells() -> void:
	_cells.clear()
	if _dungeon == null:
		return
	if _dungeon.has_method("get_occupied_cells"):
		var arr: Array = _dungeon.call("get_occupied_cells")
		for v in arr:
			if v is Vector2i:
				_cells.append(v as Vector2i)

func _draw() -> void:
	if _cells.is_empty():
		return

	# compute bounds in cell space
	var BIG := 1000000000
	var minc := Vector2i(BIG, BIG)
	var maxc := Vector2i(-BIG, -BIG)
	for c in _cells:
		minc.x = min(minc.x, c.x);  minc.y = min(minc.y, c.y)
		maxc.x = max(maxc.x, c.x);  maxc.y = max(maxc.y, c.y)

	var w_cells := maxc.x - minc.x + 1
	var h_cells := maxc.y - minc.y + 1

	var cell := float(cell_px)
	if fit_to_rect and w_cells > 0 and h_cells > 0:
		var avail := size - Vector2(margin_px * 2, margin_px * 2)
		var sx := avail.x / float(w_cells)
		var sy := avail.y / float(h_cells)
		cell = floor(min(sx, sy))

	# background
	draw_rect(Rect2(Vector2.ZERO, size), Color(0, 0, 0, 0.35), true)

	var origin := Vector2(margin_px, margin_px)
	var fg := Color(1, 1, 1, 1)

	# draw cells
	for c in _cells:
		var sx := (c.x - minc.x) * cell
		var sy := (maxc.y - c.y) * cell if north_is_negative_z else (c.y - minc.y) * cell
		var px := origin + Vector2(sx, sy)
		draw_rect(Rect2(px, Vector2(cell - 1.0, cell - 1.0)), fg, false)

	# player marker
	if _player:
		var p := _player.global_transform.origin
		var cx := int(round(p.x / _cell_world))
		var cz := int(round(p.z / _cell_world))
		var psx := (cx - minc.x + 0.5) * cell
		var psy := (maxc.y - cz + 0.5) * cell if north_is_negative_z else (cz - minc.y + 0.5) * cell
		var pm := origin + Vector2(psx, psy)
		draw_circle(pm, max(2.0, cell * 0.3), Color(1, 0.3, 0.3, 1.0))
