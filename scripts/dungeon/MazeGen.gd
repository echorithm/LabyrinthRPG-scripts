extends Object
class_name MazeGen

# Cardinal directions
const N: int = 0
const E: int = 1
const S: int = 2
const W: int = 3
const DX: Array[int]   = [0, 1, 0, -1]
const DZ: Array[int]   = [-1, 0, 1, 0]
const OPP: Array[int]  = [2, 3, 0, 1]
const MASK: Array[int] = [1, 2, 4, 8] # bit for each dir

static func idx(x: int, z: int, cols: int) -> int:
	return z * cols + x

# ───────────────────────────
# Base maze + options
# ───────────────────────────
static func carve_maze(cols: int, rows: int, rng: RandomNumberGenerator) -> PackedInt32Array:
	var open: PackedInt32Array = PackedInt32Array()
	open.resize(cols * rows)

	var visited: PackedByteArray = PackedByteArray()
	visited.resize(cols * rows)

	var stack: Array[Vector2i] = []

	var sx: int = rng.randi_range(0, cols - 1)
	var sz: int = rng.randi_range(0, rows - 1)
	stack.push_back(Vector2i(sx, sz))
	visited[idx(sx, sz, cols)] = 1

	while stack.size() > 0:
		var c: Vector2i = stack.back()
		var dirs: Array[int] = [N, E, S, W]
		_shuffle_int(dirs, rng)

		var carved: bool = false
		for d: int in dirs:
			var nx: int = c.x + DX[d]
			var nz: int = c.y + DZ[d]
			if nx < 0 or nx >= cols or nz < 0 or nz >= rows:
				continue
			var i: int = idx(nx, nz, cols)
			if visited[i] == 1:
				continue
			open[idx(c.x, c.y, cols)] |= MASK[d]
			open[i] |= MASK[OPP[d]]
			visited[i] = 1
			stack.push_back(Vector2i(nx, nz))
			carved = true
			break
		if not carved:
			stack.pop_back()

	return open

static func add_loops(open: PackedInt32Array, pct: float, cols: int, rows: int, rng: RandomNumberGenerator) -> int:
	var candidates: Array[Vector3i] = []
	for z: int in range(rows):
		for x: int in range(cols):
			var m: int = open[idx(x, z, cols)]
			if x + 1 < cols and (m & MASK[E]) == 0:
				candidates.append(Vector3i(x, E, z))
			if z + 1 < rows and (m & MASK[S]) == 0:
				candidates.append(Vector3i(x, S, z))

	var add: int = int(floor(float(candidates.size()) * pct / 100.0))
	_shuffle_v3i(candidates, rng)
	for k: int in range(add):
		var c: Vector3i = candidates[k]
		var x: int = c.x
		var z: int = c.z
		var d: int = c.y
		var nx: int = x + DX[d]
		var nz: int = z + DZ[d]
		open[idx(x, z, cols)] |= MASK[d]
		open[idx(nx, nz, cols)] |= MASK[OPP[d]]
	return add

static func inject_rooms(open: PackedInt32Array, attempts: int, rmax: int, cols: int, rows: int, rng: RandomNumberGenerator) -> int:
	var injected: int = 0
	for _i: int in range(attempts):
		var rx: int = rng.randi_range(1, cols - 2)
		var rz: int = rng.randi_range(1, rows - 2)
		var rw: int = rng.randi_range(2, rmax)
		var rh: int = rng.randi_range(2, rmax)
		if rx + rw > cols - 1 or rz + rh > rows - 1:
			continue

		for z: int in range(rz, rz + rh):
			for x: int in range(rx, rx + rw):
				if x + 1 < rx + rw:
					open[idx(x, z, cols)]     |= MASK[E]
					open[idx(x + 1, z, cols)] |= MASK[W]
				if z + 1 < rz + rh:
					open[idx(x, z, cols)]     |= MASK[S]
					open[idx(x, z + 1, cols)] |= MASK[N]

		# one connection to the maze
		var side: int = rng.randi_range(0, 3)
		if side == 0 and rz - 1 >= 0:
			var x0: int = rng.randi_range(rx, rx + rw - 1)
			open[idx(x0, rz - 1, cols)] |= MASK[S]
			open[idx(x0, rz,     cols)] |= MASK[N]
		elif side == 1 and rx + rw < cols:
			var z1: int = rng.randi_range(rz, rz + rh - 1)
			open[idx(rx + rw - 1, z1, cols)] |= MASK[E]
			open[idx(rx + rw,     z1, cols)] |= MASK[W]
		elif side == 2 and rz + rh < rows:
			var x2: int = rng.randi_range(rx, rx + rw - 1)
			open[idx(x2, rz + rh - 1, cols)] |= MASK[S]
			open[idx(x2, rz + rh,     cols)] |= MASK[N]
		elif side == 3 and rx - 1 >= 0:
			var z2: int = rng.randi_range(rz, rz + rh - 1)
			open[idx(rx - 1, z2, cols)] |= MASK[E]
			open[idx(rx,     z2, cols)] |= MASK[W]

		injected += 1
	return injected

static func block_out_of_bounds_sides(open: PackedInt32Array, cols: int, rows: int) -> void:
	for z: int in range(rows):
		for x: int in range(cols):
			var i: int = idx(x, z, cols)
			var m: int = open[i]
			if m == 0:
				continue
			if z == rows - 1: m &= ~MASK[S]
			if x == cols - 1: m &= ~MASK[E]
			if z == 0:        m &= ~MASK[N]
			if x == 0:        m &= ~MASK[W]
			open[i] = m

static func pick_spawn_cell(open: PackedInt32Array, cols: int, rows: int) -> Vector2i:
	var cx: int = cols / 2
	var cz: int = rows / 2
	if open[idx(cx, cz, cols)] != 0:
		return Vector2i(cx, cz)
	var max_r: int = max(cols, rows)
	for r: int in range(1, max_r + 1):
		var x0: int = max(0, cx - r)
		var x1: int = min(cols - 1, cx + r)
		var z0: int = max(0, cz - r)
		var z1: int = min(rows - 1, cz + r)
		for z: int in range(z0, z1 + 1):
			for x: int in range(x0, x1 + 1):
				if open[idx(x, z, cols)] != 0:
					return Vector2i(x, z)
	return Vector2i(0, 0)

# Open portals at the side of a rectangle so a given door cell connects inside it.
static func open_portal_into_rect(
	open: PackedInt32Array, cols: int, rows: int, r: Rect2i, door: Vector2i
) -> void:
	# West of rect
	if door.x == r.position.x - 1 and door.y >= r.position.y and door.y < r.position.y + r.size.y:
		if door.x >= 0:
			open[idx(door.x, door.y, cols)] |= MASK[E]
		if door.x + 1 < cols:
			open[idx(door.x + 1, door.y, cols)] |= MASK[W]
		return

	# East of rect
	if door.x == r.position.x + r.size.x and door.y >= r.position.y and door.y < r.position.y + r.size.y:
		if door.x - 1 >= 0:
			open[idx(door.x - 1, door.y, cols)] |= MASK[E]
		if door.x < cols:
			open[idx(door.x, door.y, cols)] |= MASK[W]
		return

	# North of rect
	if door.y == r.position.y - 1 and door.x >= r.position.x and door.x < r.position.x + r.size.x:
		if door.y >= 0:
			open[idx(door.x, door.y, cols)] |= MASK[S]
		if door.y + 1 < rows:
			open[idx(door.x, door.y + 1, cols)] |= MASK[N]
		return

	# South of rect
	if door.y == r.position.y + r.size.y and door.x >= r.position.x and door.x < r.position.x + r.size.x:
		if door.y - 1 >= 0:
			open[idx(door.x, door.y - 1, cols)] |= MASK[S]
		if door.y < rows:
			open[idx(door.x, door.y, cols)] |= MASK[N]
		return

# Midpoint cells just OUTSIDE the rectangle on each side (clamped)
static func door_cells_for_rect(cols: int, rows: int, r: Rect2i) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	var cx: int = r.position.x + r.size.x / 2
	var cz: int = r.position.y + r.size.y / 2
	if r.position.y > 0:
		result.append(Vector2i(cx, r.position.y - 1))                # N
	if r.position.y + r.size.y < rows:
		result.append(Vector2i(cx, r.position.y + r.size.y))          # S
	if r.position.x > 0:
		result.append(Vector2i(r.position.x - 1, cz))                 # W
	if r.position.x + r.size.x < cols:
		result.append(Vector2i(r.position.x + r.size.x, cz))          # E
	return result

# Manhattan BFS ignoring current openings; avoids 'reserved' > 0
static func shortest_cell_path(cols: int, rows: int, reserved: PackedByteArray, start: Vector2i, goal: Vector2i) -> Array[Vector2i]:
	if start == goal:
		return [start]

	if start.x < 0 or start.x >= cols or start.y < 0 or start.y >= rows: return []
	if goal.x  < 0 or goal.x  >= cols or goal.y  < 0 or goal.y  >= rows: return []

	var q: Array[Vector2i] = []
	q.push_back(start)
	var came_from: Dictionary = {}
	came_from[start] = start

	while q.size() > 0:
		var cur: Vector2i = q.pop_front()
		if cur == goal:
			break

		for d: int in [N, E, S, W]:
			var nx: int = cur.x + DX[d]
			var nz: int = cur.y + DZ[d]
			if nx < 0 or nx >= cols or nz < 0 or nz >= rows:
				continue
			var np: Vector2i = Vector2i(nx, nz)
			if not came_from.has(np):
				var blocked := false
				if reserved.size() > 0:
					blocked = reserved[idx(np.x, np.y, cols)] != 0
				if blocked and np != goal:
					continue
				came_from[np] = cur
				q.push_back(np)

	if not came_from.has(goal):
		return []

	var path: Array[Vector2i] = []
	var p: Vector2i = goal
	while true:
		path.append(p)
		if p == start:
			break
		p = came_from[p]
	path.reverse()
	return path

# Carve walls along a path
static func carve_path(open: PackedInt32Array, cols: int, rows: int, path: Array[Vector2i]) -> void:
	if path.size() < 2:
		return
	for i: int in range(path.size() - 1):
		var a: Vector2i = path[i]
		var b: Vector2i = path[i + 1]
		var dx: int = b.x - a.x
		var dz: int = b.y - a.y
		var d: int = -1
		if dx == 1 and dz == 0: d = E
		elif dx == -1 and dz == 0: d = W
		elif dx == 0 and dz == 1: d = S
		elif dx == 0 and dz == -1: d = N
		if d != -1:
			open[idx(a.x, a.y, cols)] |= MASK[d]
			open[idx(b.x, b.y, cols)] |= MASK[OPP[d]]

# Shuffle helpers
static func _shuffle_int(a: Array[int], rng: RandomNumberGenerator) -> void:
	var n: int = a.size()
	for i: int in range(n - 1, 0, -1):
		var j: int = rng.randi_range(0, i)
		var tmp: int = a[i]
		a[i] = a[j]
		a[j] = tmp

static func _shuffle_v3i(a: Array[Vector3i], rng: RandomNumberGenerator) -> void:
	var n: int = a.size()
	for i: int in range(n - 1, 0, -1):
		var j: int = rng.randi_range(0, i)
		var tmp: Vector3i = a[i]
		a[i] = a[j]
		a[j] = tmp

# Mark a rect as reserved
static func reserve_rect(reserved: PackedByteArray, cols: int, rows: int, r: Rect2i) -> bool:
	if r.position.x < 0 or r.position.y < 0: return false
	if r.position.x + r.size.x > cols: return false
	if r.position.y + r.size.y > rows: return false
	for z: int in range(r.position.y, r.position.y + r.size.y):
		for x: int in range(r.position.x, r.position.x + r.size.x):
			reserved[idx(x, z, cols)] = 1
	return true

# Open mid sockets around a prefab rect
static func open_room_sockets(open: PackedInt32Array, cols: int, rows: int, r: Rect2i) -> void:
	var cx: int = r.position.x + r.size.x / 2
	var cz: int = r.position.y + r.size.y / 2

	if r.position.y > 0:
		var zi: int = r.position.y - 1
		open[idx(cx, zi, cols)]     |= MASK[S]
		open[idx(cx, zi + 1, cols)] |= MASK[N]

	if r.position.y + r.size.y < rows:
		var zs: int = r.position.y + r.size.y
		open[idx(cx, zs - 1, cols)] |= MASK[S]
		open[idx(cx, zs, cols)]     |= MASK[N]

	if r.position.x > 0:
		var xw: int = r.position.x - 1
		open[idx(xw, cz, cols)]     |= MASK[E]
		open[idx(xw + 1, cz, cols)] |= MASK[W]

	if r.position.x + r.size.x < cols:
		var xe: int = r.position.x + r.size.x
		open[idx(xe - 1, cz, cols)] |= MASK[E]
		open[idx(xe, cz, cols)]     |= MASK[W]

# BFS respecting current openings (reserved treated as blocked except for goal)
static func has_path_between(
	open: PackedInt32Array,
	cols: int, rows: int,
	reserved: PackedByteArray,
	start: Vector2i, goal: Vector2i
) -> bool:
	if start == goal:
		return true
	if start.x < 0 or start.x >= cols or start.y < 0 or start.y >= rows:
		return false
	if goal.x < 0 or goal.x >= cols or goal.y < 0 or goal.y >= rows:
		return false

	var q: Array[Vector2i] = []
	q.push_back(start)

	var seen := PackedByteArray()
	seen.resize(cols * rows)
	seen[idx(start.x, start.y, cols)] = 1

	while q.size() > 0:
		var cur: Vector2i = q.pop_front()
		if cur == goal:
			return true

		var i: int = idx(cur.x, cur.y, cols)
		var m: int = open[i]
		if m == 0:
			continue

		for d: int in [N, E, S, W]:
			if (m & MASK[d]) == 0:
				continue
			var nx: int = cur.x + DX[d]
			var nz: int = cur.y + DZ[d]
			if nx < 0 or nx >= cols or nz < 0 or nz >= rows:
				continue
			var ni: int = idx(nx, nz, cols)
			if reserved.size() > 0 and reserved[ni] != 0 and Vector2i(nx, nz) != goal:
				continue
			if seen[ni] == 1:
				continue
			seen[ni] = 1
			q.push_back(Vector2i(nx, nz))

	return false

static func ensure_path_between(
	open: PackedInt32Array,
	cols: int, rows: int,
	reserved: PackedByteArray,
	a: Vector2i, b: Vector2i
) -> bool:
	if has_path_between(open, cols, rows, reserved, a, b):
		return true

	var path: Array[Vector2i] = shortest_cell_path(cols, rows, reserved, a, b)
	if path.size() > 1:
		carve_path(open, cols, rows, path)
		return has_path_between(open, cols, rows, reserved, a, b)

	return false
