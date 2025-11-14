class_name DungeonLight
extends Node

# ---------------------------- Config ----------------------------
@export_group("Torch placement")
@export var torch_group_count: int = 4
@export var torch_group_active: int = 0          # -1 = show all groups
@export var torch_min_segment_gap: int = 4
@export var torch_spawn_chance: float = 0.45
@export var torch_cross_gap_cells: int = 1
@export var torch_min_world_dist_m: float = 3.0
@export var torch_debug_verbose: bool = false
@export var hide_off_torch_mesh: bool = true

@export_group("Light params (fallback when no TorchDirector)")
@export var torch_light_energy: float = 2.2
@export var torch_light_color: Color = Color(1.0, 0.85, 0.55)
@export var torch_light_range: float = 7.0
@export var torch_light_shadows: bool = true
@export var torch_shadow_bias: float = 0.03
@export var torch_shadow_normal_bias: float = 0.6
@export var torch_light_cull_mask: int = 0xFFFFF   # affect all 20 visual layers

# ----------------------- Constants / internals -------------------
const SIDE_N := 0
const SIDE_E := 1
const SIDE_S := 2
const SIDE_W := 3

const TORCH_NAME := "Torch"
const GROUP_ALL := "torch_all"
const GROUP_PREFAB := "torch_prefab"
const META_SPACE_OFF := "torch_space_off"

var _rng: RandomNumberGenerator = RandomNumberGenerator.new()

var _torch_positions: Array[Vector3] = []
var _last_torch_by_line := {}          # "E:<z>" or "S:<x>" -> last index
var _torch_cross_block := {}           # "E,x,z" / "S,x,z" -> true

# ---------------------------- Lifecycle --------------------------
func new_context(seed: int) -> void:
	_rng.seed = seed
	reset_state()

func reset_state() -> void:
	_torch_positions.clear()
	_last_torch_by_line.clear()
	_torch_cross_block.clear()

# ------------------- Wall-piece torch handling -------------------
func process_wallpiece(inst: Node3D, side: int, x: int, z: int, center_world: Vector3) -> void:
	var holder: Node = _find_holder(inst)
	if holder == null:
		_dbg("[Torch] piece (%d,%d) side=%d -> no holder under %s" % [x, z, side, str(inst.get_path())])
		return

	# Ensure groups
	if holder is Node3D:
		var h3: Node3D = holder as Node3D
		if not h3.is_in_group(GROUP_ALL): h3.add_to_group(GROUP_ALL)
		var gtotal: int = max(1, torch_group_count)
		var gpick: int = int(_rng.randi() % gtotal)
		if not h3.is_in_group("torch_group_%d" % gpick):
			h3.add_to_group("torch_group_%d" % gpick)

	var allow: bool = _torch_allowed(side, x, z, center_world)
	if holder is Node:
		(holder as Node).set_meta(META_SPACE_OFF, not allow)

	_dbg("[Torch] piece (%d,%d) side=%d allow=%s holder=%s" %
		[x, z, side, str(allow), str(holder.get_path())])

	_set_torch_enabled(holder, allow)

# ------------------------- Final group gate ----------------------
func apply_group_gate() -> void:
	var all: Array = get_tree().get_nodes_in_group(GROUP_ALL)
	for n in all:
		var torch_root: Node3D = n as Node3D
		if torch_root == null:
			continue

		var disallowed: bool = torch_root.has_meta(META_SPACE_OFF) and bool(torch_root.get_meta(META_SPACE_OFF))
		var in_active: bool = (torch_group_active < 0) or torch_root.is_in_group("torch_group_%d" % torch_group_active)
		var is_prefab: bool = torch_root.is_in_group(GROUP_PREFAB)
		var should: bool = (not disallowed) and (in_active )
		_set_torch_enabled(torch_root, should)

		_dbg("[Gate] %s  active=%s prefab=%s disallowed=%s -> %s" %
			[str(torch_root.get_path()), str(in_active), str(is_prefab), str(disallowed), ("ON" if should else "OFF")])

# --------------------- Find holders / lights ---------------------
func _find_holder(inst: Node3D) -> Node:
	var n: Node = inst.get_node_or_null("wall/" + TORCH_NAME)
	if n == null: n = inst.get_node_or_null(TORCH_NAME)
	if n == null: n = inst.find_child(TORCH_NAME, true, false)
	if n == null:
		var l: OmniLight3D = _get_first_omni(inst)
		if l != null:
			return l.get_parent()
	return n

func _find_all_holders(root: Node3D) -> Array[Node]:
	var out: Array[Node] = []
	for n in root.find_children(TORCH_NAME, "", true, false):
		out.append(n)
	for lnode in root.find_children("*", "OmniLight3D", true, true):
		var l: OmniLight3D = lnode as OmniLight3D
		if l == null: continue
		var p: Node = l.get_parent()
		if p != null and not out.has(p):
			out.append(p)
	return out

func _get_first_omni(root: Node) -> OmniLight3D:
	var q: Array[Node] = [root]
	while q.size() > 0:
		var cur: Node = q.pop_back()
		for c: Node in cur.get_children():
			if c is OmniLight3D:
				return c as OmniLight3D
			q.push_back(c)
	return null

# --------------------- Spacing / RNG helpers ---------------------
func _line_key(side: int, x: int, z: int) -> String:
	return ("E:%d" % z) if side == SIDE_E else ("S:%d" % x)

func _seg_index(side: int, x: int, z: int) -> int:
	return (x if side == SIDE_E else z)

func _torch_cross_ok(side: int, x: int, z: int) -> bool:
	var key: String = ("E,%d,%d" % [x, z]) if side == SIDE_E else ("S,%d,%d" % [x, z])
	return not _torch_cross_block.has(key)

func _mark_cross_block(side: int, x: int, z: int) -> void:
	if side == SIDE_E:
		for dz in range(0, torch_cross_gap_cells + 1):
			_torch_cross_block["S,%d,%d" % [x, z + dz]] = true
	else:
		for dx in range(0, torch_cross_gap_cells + 1):
			_torch_cross_block["E,%d,%d" % [x + dx, z]] = true

func _want_torch(side: int, x: int, z: int) -> bool:
	var key: String = _line_key(side, x, z)
	var idx: int = _seg_index(side, x, z)
	var last: int = int(_last_torch_by_line.get(key, -999999))
	if idx - last < torch_min_segment_gap:
		return false
	if not _torch_cross_ok(side, x, z):
		return false
	if _rng.randf() < torch_spawn_chance:
		_last_torch_by_line[key] = idx
		_mark_cross_block(side, x, z)
		return true
	return false

func _torch_far_enough(p_world: Vector3) -> bool:
	var min_d2: float = torch_min_world_dist_m * torch_min_world_dist_m
	for q: Vector3 in _torch_positions:
		if p_world.distance_squared_to(q) < min_d2:
			return false
	return true

func _torch_allowed(side: int, x: int, z: int, center_world: Vector3) -> bool:
	if not _want_torch(side, x, z):
		return false
	if not _torch_far_enough(center_world):
		return false
	_torch_positions.append(center_world)
	return true

# ----------------------- Toggle / configure ----------------------
func _set_visuals_visible_except_lights(n: Node, v: bool) -> int:
	var changed: int = 0
	if n is VisualInstance3D and not (n is OmniLight3D):
		(n as VisualInstance3D).visible = v
		changed += 1
	elif n is Node3D and not (n is OmniLight3D):
		(n as Node3D).visible = v
		changed += 1
	for c: Node in n.get_children():
		changed += _set_visuals_visible_except_lights(c, v)
	return changed

func _set_torch_enabled(torch_root: Node, enable: bool) -> void:
	if torch_root == null:
		return

	var vis_changed: int = 0
	if hide_off_torch_mesh:
		vis_changed = _set_visuals_visible_except_lights(torch_root, enable)

	# Collect all omnis under this holder
	var omnis: Array[OmniLight3D] = _omnis_under(torch_root)

	# If enabling and none exist, create one WITH the TorchFlicker script
	if enable and omnis.is_empty():
		var TorchFlicker := preload("res://rooms/pieces/TorchFlicker.gd")
		var nl: OmniLight3D = TorchFlicker.new()
		nl.name = "TorchLight"
		if torch_root is Node3D:
			(torch_root as Node3D).add_child(nl)
			omnis.append(nl)
			_dbg("[Torch] created TorchFlicker on %s" % str((torch_root as Node3D).get_path()))

	for l: OmniLight3D in omnis:
		# Prefer the torch script API so audio follows the state.
		if l.has_method("set_enabled"):
			l.call_deferred("set_enabled", enable)
			continue

		# Fallback for plain Omni lights (no script)
		l.visible = enable
		l.shadow_enabled = enable and torch_light_shadows
		if enable:
			l.light_energy        = torch_light_energy
			l.light_color         = torch_light_color
			l.omni_range          = torch_light_range
			l.shadow_bias         = torch_shadow_bias
			l.shadow_normal_bias  = torch_shadow_normal_bias
			l.light_cull_mask     = torch_light_cull_mask
			l.light_bake_mode     = Light3D.BAKE_DYNAMIC
		else:
			l.light_energy = 0.0

	_dbg("[Torch] %s -> %s  (nodes_toggled=%d, omnis=%d, E=%.2f R=%.2f mask=0x%X)" %
		[str((torch_root as Node3D).get_path() if torch_root is Node3D else "<node>"),
		 ("ON" if enable else "OFF"), vis_changed, omnis.size(), torch_light_energy, torch_light_range, torch_light_cull_mask])

func apply_config(cfg: Dictionary) -> void:
	if cfg.has("torch_light_energy"):        torch_light_energy = float(cfg["torch_light_energy"])
	if cfg.has("torch_light_color"):         torch_light_color  = cfg["torch_light_color"]
	if cfg.has("torch_light_range"):         torch_light_range  = float(cfg["torch_light_range"])
	if cfg.has("torch_light_shadows"):       torch_light_shadows = bool(cfg["torch_light_shadows"])
	if cfg.has("torch_shadow_bias"):         torch_shadow_bias = float(cfg["torch_shadow_bias"])
	if cfg.has("torch_shadow_normal_bias"):  torch_shadow_normal_bias = float(cfg["torch_shadow_normal_bias"])
	if cfg.has("torch_light_cull_mask"):     torch_light_cull_mask = int(cfg["torch_light_cull_mask"])

	if cfg.has("torch_group_count"):       torch_group_count = int(cfg["torch_group_count"])
	if cfg.has("torch_group_active"):      torch_group_active = int(cfg["torch_group_active"])
	if cfg.has("torch_min_segment_gap"):   torch_min_segment_gap = int(cfg["torch_min_segment_gap"])
	if cfg.has("torch_spawn_chance"):      torch_spawn_chance = float(cfg["torch_spawn_chance"])
	if cfg.has("torch_cross_gap_cells"):   torch_cross_gap_cells = int(cfg["torch_cross_gap_cells"])
	if cfg.has("torch_min_world_dist_m"):  torch_min_world_dist_m = float(cfg["torch_min_world_dist_m"])
	if cfg.has("torch_debug_verbose"):     torch_debug_verbose = bool(cfg["torch_debug_verbose"])
	if cfg.has("hide_off_torch_mesh"):     hide_off_torch_mesh = bool(cfg["hide_off_torch_mesh"])


func _is_torch_on(torch_root: Node) -> bool:
	var l: OmniLight3D = _get_first_omni(torch_root)
	if l != null:
		return l.visible
	if torch_root is Node3D:
		return (torch_root as Node3D).visible
	return true

func _dbg(s: String) -> void:
	if torch_debug_verbose:
		print(s)

func _omnis_under(root: Node) -> Array[OmniLight3D]:
	var out: Array[OmniLight3D] = []
	var stack: Array[Node] = [root]
	while stack.size() > 0:
		var cur: Node = stack.pop_back()
		for c: Node in cur.get_children():
			if c is OmniLight3D:
				out.append(c as OmniLight3D)
			stack.push_back(c)
	return out
