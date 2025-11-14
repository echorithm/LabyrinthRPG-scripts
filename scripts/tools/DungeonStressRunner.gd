extends Node

@export var generator_path: NodePath
@export var iterations: int = 200
@export var pause_frames: int = 1            # yield frames between runs (keeps editor responsive)
@export var randomize_each_run: bool = true  # true = fresh seed every time; false = reuse seed
@export var log_every: int = 25              # progress prints

var _gen: Node = null
var _failures: int = 0
var _total_ms: float = 0.0
var _worst_unreachable: int = 0

func _ready() -> void:
	_gen = get_node_or_null(generator_path)
	if _gen == null:
		push_error("[Stress] generator_path not set or node missing.")
		return
	await _run_stress()


func _run_stress() -> void:
	for i: int in range(iterations):
		var t0: int = Time.get_ticks_usec()

		# Drive the generator
		_gen._apply_seed(randomize_each_run)   # your existing method
		_gen._generate_and_paint()             # your existing method

		var t1: int = Time.get_ticks_usec()
		_total_ms += float(t1 - t0) / 1000.0

		# Check topology/connectivity
		var ok: bool = _check_run(i)
		if not ok:
			_failures += 1

		if log_every > 0 and ((i + 1) % log_every) == 0:
			print("[Stress] ", i + 1, "/", iterations,
				"  avg(ms)=", _avg_ms(),
				"  fails=", _failures,
				"  worst_unreachable=", _worst_unreachable)

		# keep UI responsive / spread load (await the *signal*, no parentheses)
		for _k: int in range(max(0, pause_frames)):
			await get_tree().process_frame

	print("[Stress] DONE: runs=", iterations,
		"  avg(ms)=", _avg_ms(),
		"  failures=", _failures,
		"  worst_unreachable=", _worst_unreachable)


func _avg_ms() -> String:
	if iterations <= 0:
		return "0.00"
	return String.num(_total_ms / float(iterations), 2)


func _check_run(run_index: int) -> bool:
	# Pull state from the generator
	var w: int = _gen.width
	var h: int = _gen.height
	var open: PackedInt32Array = _gen._last_open
	var reserved: PackedByteArray = _gen._last_reserved

	if open.size() != w * h:
		print("[Stress] BAD: open size mismatch on run ", run_index)
		return false

	# Pick a spawn cell (same helper you use)
	var spawn: Vector2i = MazeGen.pick_spawn_cell(open, w, h)

	# Reachability mask (reuse your generator’s helper)
	var vis: PackedByteArray = _gen._reachable_mask(open, w, h, reserved, spawn)

	# Count unreachable but walkable cells (ignores completely walled cells and reserved footprints)
	var unreachable: int = 0
	for z: int in range(h):
		for x: int in range(w):
			var i: int = MazeGen.idx(x, z, w)
			if open[i] == 0:
				continue
			if reserved.size() > 0 and reserved[i] != 0:
				continue
			if vis[i] == 0:
				unreachable += 1

	_worst_unreachable = max(_worst_unreachable, unreachable)

	var ok: bool = (unreachable == 0)

	# If you’re using Anchor_Entry cells, make sure each is reachable from spawn
	if _gen._placed_anchor_cells.size() > 0:
		for ac: Vector2i in _gen._placed_anchor_cells:
			if ac.x < 0 or ac.y < 0:
				continue
			var reach_anchor: bool = MazeGen.has_path_between(open, w, h, reserved, spawn, ac)
			ok = ok and reach_anchor
			if not reach_anchor:
				print("[Stress] Unreachable anchor at ", ac, " on run ", run_index)

	# Optional: ensure prefab-to-prefab links exist (neighbors in placement order)
	for i: int in range(max(0, _gen._placed_anchor_cells.size() - 1)):
		var a: Vector2i = _gen._placed_anchor_cells[i]
		var b: Vector2i = _gen._placed_anchor_cells[i + 1]
		if a.x >= 0 and b.x >= 0:
			var link_ok: bool = MazeGen.has_path_between(open, w, h, reserved, a, b)
			ok = ok and link_ok
			if not link_ok:
				print("[Stress] Unlinked anchors ", a, " -> ", b, " on run ", run_index)

	return ok
