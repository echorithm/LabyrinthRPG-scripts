extends Resource
class_name TriadRules

@export_category("Elite Scaling (Triads)")
@export var slope_A: int = 2          # E_total(k) = A*k + B
@export var offset_B: int = -1
enum SplitMode { EVEN = 0, BACKLOAD_12 = 1, BACKLOAD_2 = 2 }
@export var split_mode: SplitMode = SplitMode.BACKLOAD_12

@export_category("Treasure Scaling")
@export var treasure_ratio: float = 0.6
@export var treasure_base: int = 0
@export var treasure_min: int = 2
@export var treasure_max: int = 8

@export_category("Placement Distances (meters)")
@export var perim_buffer_cells: int = 1
@export var elite_min_dist_m: float = 14.0
@export var treasure_min_dist_m: float = 10.0
@export var elite_treasure_min_dist_m: float = 8.0
@export var door_buffer_m: float = 12.0
@export var start_buffer_m: float = 12.0
@export var area_target_m2_per_elite: float = 140.0

func is_boss_floor(floor: int) -> bool:
	return floor > 0 and (floor % 3 == 0)

func boss_floor_for(floor: int) -> int:
	var seg: int = (max(1, floor) - 1) / 3 + 1
	return seg * 3

func elite_total_for_boss_floor(k: int) -> int:
	return slope_A * k + offset_B

func elite_split_for_triad(k: int) -> Vector3i:
	var total: int = elite_total_for_boss_floor(k)
	var base: int = total / 3
	var r: int = total % 3
	var a: int = base
	var b: int = base
	var c: int = base
	match split_mode:
		SplitMode.EVEN:
			if r >= 1: a += 1
			if r >= 2: b += 1
		SplitMode.BACKLOAD_12:
			if r == 1: c += 1
			elif r == 2: 
				b += 1
				c += 1
		SplitMode.BACKLOAD_2:
			if r == 1: c += 1
			elif r == 2: c += 2
	return Vector3i(a, b, c)

func elite_count_for_floor(floor: int) -> int:
	var k: int = boss_floor_for(floor)
	var share: Vector3i = elite_split_for_triad(k)
	if floor == k - 2:
		return share.x
	elif floor == k - 1:
		return share.y
	else:
		return share.z

func treasure_count_for_floor(floor: int, elites_on_floor: int) -> int:
	var t: int = int(round(float(elites_on_floor) * treasure_ratio)) + treasure_base
	t = clamp(t, treasure_min, treasure_max)
	return t
