# Godot 4.5
# Listens to VillageService signals and writes a summarized, deterministic
# village→RUN modifiers snapshot. Also exposes a query API used by item/affix
# assembly and CTB math. Compatible with ADR-014 (decay sums, staff scalar, caps).
extends Node
class_name VillageEffectsService

@export var debug_logging: bool = false
@export var default_slot: int = 0
@export var staff_alpha_per_10_levels: float = 0.08  # ADR-014: ≈ +8% per 10 levels
@export var ctb_stack_group: String = "CTB_ACTION"   # strongest wins; others at 50%

const _Save := preload("res://persistence/SaveManager.gd")
const _VSnap := preload("res://scripts/village/persistence/village_save_utils.gd")

var _village: VillageService = null
var _art: BuildingArtService = null

# Snapshot structure (plain Dictionary/Array to avoid nested typed-collection issues)
var _snapshot: Dictionary = {
	"resonance_map": {},   # Dictionary effect_id -> float
	"ctb_floor": 1.0,      # float
	"additive_globals": {},# Dictionary key -> float
	"sources": {}          # Dictionary inst_id -> breakdown Dictionary
}

func _ready() -> void:
	if not is_in_group("VillageEffectsService"):
		add_to_group("VillageEffectsService")
	_village = _find_village_service()
	_art = _find_building_art_service()

	if _village == null:
		push_error("[VillageEffects] VillageService not found; effects will not apply.")
		return

	_connect_once(_village, "snapshot_changed", Callable(self, "_on_any_changed"))
	_connect_once(_village, "building_placed", Callable(self, "_on_any_changed"))
	_connect_once(_village, "building_changed", Callable(self, "_on_any_changed"))
	_connect_once(_village, "activation_changed", Callable(self, "_on_any_changed"))

	_recompute_and_persist()

# --- Public API ------------------------------------------------------------

func snapshot_from(_village_state: Variant = null) -> Dictionary:
	return _deep_clone(_snapshot) as Dictionary

func get_affix_resonance(effect_id: String) -> float:
	var map: Dictionary = _snapshot.get("resonance_map", {})
	if map.has(effect_id):
		return float(map[effect_id])
	if effect_id.begins_with("element_mod_") and effect_id.ends_with("_pct"):
		if map.has("element_mod_*_pct"):
			return float(map["element_mod_*_pct"])
	return 0.0

func get_ctb_floor() -> float:
	return float(_snapshot.get("ctb_floor", 1.0))

func get_additive_globals() -> Dictionary:
	var d: Dictionary = _snapshot.get("additive_globals", {})
	return d.duplicate(false)

# --- Event hooks -----------------------------------------------------------

func _on_any_changed(_a: Variant = null, _b: Variant = null) -> void:
	_recompute_and_persist()

# --- Core recompute --------------------------------------------------------

func _recompute_and_persist() -> void:
	if _village == null:
		return

	var snap: Dictionary = _village.get_snapshot()
	var buildings_any: Variant = snap.get("buildings", [])
	var buildings: Array = (buildings_any as Array) if (buildings_any is Array) else []

	# Collect rows deterministically
	var rows: Array = []
	for row_any in buildings:
		if row_any is Dictionary:
			rows.append(row_any)
	rows.sort_custom(Callable(self, "_cmp_building_rows"))

	# Accumulators
	var reso_adds: Dictionary = {}     # fam -> Array of float
	var reso_caps: Dictionary = {}     # fam -> float
	var reso_extra_cap: Dictionary = {}# "__global__" -> float

	var ctb_candidates: Array = []     # Array of float
	var global_ward_dr_contribs: Array = []  # Array of float
	var sources: Dictionary = {}

	# Seed known families so lookups are stable (optional)
	reso_adds["on_hit_status_chance_pct"] = []
	reso_adds["element_mod_*_pct"] = []

	for row_any in rows:
		var row: Dictionary = row_any
		if not bool(row.get("active", false)):
			continue

		var b_id: String = String(row.get("id", ""))
		var inst_id: String = String(row.get("instance_id", ""))
		var rarity: String = String(row.get("rarity", "COMMON"))

		# Staff scalar (ADR-014)
		var scalar: float = 1.0
		var staff_any: Variant = row.get("staff", {})
		var staff_d: Dictionary = (staff_any as Dictionary) if (staff_any is Dictionary) else {}
		var npc_id: String = String(staff_d.get("npc_id", ""))
		if npc_id != "":
			var lvl: int = _lookup_npc_level(npc_id)
			var steps: int = int(floor(float(max(1, lvl)) / 10.0))
			scalar = 1.0 + (staff_alpha_per_10_levels * float(steps))

		# Effects from art service
		var base: Dictionary = {}
		var buffs: Array = []
		if _art != null:
			var eff_any: Variant = _art.get_effect_for_rarity(b_id, rarity)
			if eff_any is Dictionary:
				base = eff_any as Dictionary
			if _art.has_method("get_buffs_for_rarity"):
				var buf_any: Variant = _art.call("get_buffs_for_rarity", b_id, rarity)
				if buf_any is Array:
					buffs = buf_any

		if buffs.is_empty():
			buffs = _synthesize_buffs_from_base(b_id, base)

		var decay: float = float(base.get("decay", 0.5))

		for b_any in buffs:
			if not (b_any is Dictionary):
				continue
			var bd: Dictionary = b_any
			var btype: String = String(bd.get("type", ""))
			var bid: String = String(bd.get("id", ""))

			if btype == "resonance":
				var scale: float = float(bd.get("scale", float(base.get("resonance_status_and_element_base_pct", 0.0)) / 100.0))
				var affects_any: Variant = bd.get("affects", [])
				var affects: Array = (affects_any as Array) if (affects_any is Array) else []
				var cap: float = float(base.get("resonance_cap_pct", 0.0)) / 100.0
				if bd.has("extra_cap"):
					var prev: float = float(reso_extra_cap.get("__global__", 0.0))
					reso_extra_cap["__global__"] = prev + float(bd.get("extra_cap", 0.0))

				var contrib: float = scale * scalar
				for fam_any in affects:
					var fam: String = String(fam_any)
					if not reso_adds.has(fam):
						reso_adds[fam] = []
					(reso_adds[fam] as Array).append(contrib)
					if not reso_caps.has(fam):
						reso_caps[fam] = cap
					else:
						reso_caps[fam] = max(float(reso_caps[fam]), cap)

				sources[inst_id] = {
					"id": b_id,
					"rarity": rarity,
					"npc_id": npc_id,
					"scalar": scalar,
					"type": "resonance",
					"contrib": contrib,
					"affects": affects
				}

			elif btype == "multiplicative" and bid == "ALC_CTB_FLOOR":
				var floor_c: float = float(base.get("ctb_floor_c", 0.75))
				var floor_m: float = float(base.get("ctb_floor_m", 0.60))
				var floor_base: float = lerp(floor_c, floor_m, _rarity_t01(rarity))
				var floor_eff: float = pow(floor_base, scalar)
				ctb_candidates.append(clamp(floor_eff, floor_m, 1.0))

				sources[inst_id] = {
					"id": b_id,
					"rarity": rarity,
					"npc_id": npc_id,
					"scalar": scalar,
					"type": "ctb_floor",
					"floor_eff": floor_eff
				}

			elif btype == "additive" and bid == "CH_WARD_DR":
				var base_pct: float = float(bd.get("base", 0.0))
				var eff: float = base_pct * scalar
				global_ward_dr_contribs.append(eff)
				sources[inst_id] = {
					"id": b_id,
					"rarity": rarity,
					"npc_id": npc_id,
					"type": "ward_dr",
					"scalar": scalar,
					"eff": eff
				}

	# Finalize resonance with decay and caps
	var resonance_map: Dictionary = {}
	for fam in reso_adds.keys():
		var arr_any: Variant = reso_adds[fam]
		var arr: Array = (arr_any as Array) if (arr_any is Array) else []
		arr.sort()
		arr.reverse()
		var total: float = 0.0
		var d: float = _family_decay_for(String(fam))
		if d <= 0.0 or d >= 1.0:
			d = 0.5
		for i in range(arr.size()):
			total += float(arr[i]) * pow(d, float(i))
		var cap_base: float = float(reso_caps.get(fam, 0.0))
		var cap_extra: float = float(reso_extra_cap.get("__global__", 0.0))
		var cap: float = cap_base + cap_extra
		if cap > 0.0:
			total = min(total, cap)
		resonance_map[fam] = max(0.0, total)

	# Resolve CTB floor via "strongest wins; others at 50%"
	var ctb_floor: float = 1.0
	if ctb_candidates.size() > 0:
		ctb_candidates.sort() # ascending (lower is stronger)
		var best: float = float(ctb_candidates[0])
		var extra_strength: float = 0.0
		for i in range(ctb_candidates.size()):
			if i == 0:
				continue
			var v: float = float(ctb_candidates[i])
			extra_strength += 0.5 * (1.0 - v)
		var combined_strength: float = (1.0 - best) + extra_strength
		ctb_floor = max(0.0, 1.0 - combined_strength)

	# Ward DR with decay and cap
	var ward_total: float = _decay_sum(global_ward_dr_contribs, 0.6)
	var ward_cap: float = _resolve_ward_cap_from_data()
	if ward_cap > 0.0:
		ward_total = min(ward_total, ward_cap)

	_snapshot = {
		"resonance_map": resonance_map,
		"ctb_floor": ctb_floor,
		"additive_globals": { "ward_dr_pct": ward_total },
		"sources": sources
	}

	var rs: Dictionary = _Save.load_run(default_slot)
	rs["village_buffs"] = _snapshot
	_Save.save_run(rs, default_slot)

	if debug_logging:
		print("[VillageEffects] snapshot=", _snapshot)

# --- Helpers ---------------------------------------------------------------

func _cmp_building_rows(a: Dictionary, b: Dictionary) -> bool:
	var aid: String = String(a.get("id", ""))
	var bid: String = String(b.get("id", ""))
	if aid == bid:
		var ai: String = String(a.get("instance_id", ""))
		var bi: String = String(b.get("instance_id", ""))
		return ai < bi
	return aid < bid

func _lookup_npc_level(npc_id: String) -> int:
	var v: Dictionary = _VSnap.load_village(default_slot)
	var npcs_any: Variant = v.get("npcs", [])
	var npcs: Array = (npcs_any as Array) if (npcs_any is Array) else []
	for r_any in npcs:
		if r_any is Dictionary:
			var r: Dictionary = r_any
			if String(r.get("id", "")) == npc_id:
				return int(r.get("level", 1))
	return 1

func _connect_once(n: Object, sig: StringName, cb: Callable) -> void:
	if n == null:
		return
	if not n.is_connected(sig, cb):
		n.connect(sig, cb)

func _find_village_service() -> VillageService:
	var root: Node = get_tree().get_root()
	var n: Node = root.get_node_or_null("VillageService")
	if n is VillageService:
		return n as VillageService
	var g: Array = get_tree().get_nodes_in_group("VillageService")
	if g.size() > 0 and g[0] is VillageService:
		return g[0] as VillageService
	return null

func _find_building_art_service() -> BuildingArtService:
	var scene: Node = get_tree().get_current_scene()
	if scene == null:
		return null
	var q: Array = [scene]
	while not q.is_empty():
		var it: Node = q.pop_front()
		if it is BuildingArtService:
			return it as BuildingArtService
		var kids: Array = it.get_children()
		for c in kids:
			if c is Node:
				q.append(c)
	return null

func _decay_sum(values: Array, d: float) -> float:
	if values.is_empty():
		return 0.0
	var arr: Array = values.duplicate()
	arr.sort()
	arr.reverse()
	var total: float = 0.0
	for i in range(arr.size()):
		total += float(arr[i]) * pow(d, float(i))
	return total

func _resolve_ward_cap_from_data() -> float:
	if _art == null:
		return 0.0
	var rarities: Array = ["COMMON","UNCOMMON","RARE","EPIC","ANCIENT","LEGENDARY","MYTHIC"]
	var max_cap: float = 0.0
	for r_any in rarities:
		var r: String = String(r_any)
		var eff_any: Variant = _art.get_effect_for_rarity("church", r)
		if eff_any is Dictionary:
			var eff: Dictionary = eff_any
			var c: float = float(eff.get("global_dr_cap_m_pct", eff.get("global_dr_cap_c_pct", 0.0)))
			max_cap = max(max_cap, c / 100.0)
	return max_cap

func _family_decay_for(_fam: String) -> float:
	return 0.5

func _rarity_t01(r: String) -> float:
	match r:
		"COMMON":
			return 0.0
		"UNCOMMON":
			return 0.1666
		"RARE":
			return 0.3333
		"EPIC":
			return 0.5
		"ANCIENT":
			return 0.6666
		"LEGENDARY":
			return 0.8333
		"MYTHIC":
			return 1.0
		_:
			return 0.0

func _synthesize_buffs_from_base(b_id: String, base: Dictionary) -> Array:
	var out: Array = []

	if b_id == "alchemist_lab":
		var base_res: float = float(base.get("resonance_status_and_element_base_pct", 0.0)) / 100.0
		if base_res > 0.0:
			out.append({
				"id": "ALC_RESONANCE",
				"type": "resonance",
				"affects": ["on_hit_status_chance_pct", "element_mod_*_pct"],
				"scale": base_res,
				"extra_cap": float(base.get("resonance_cap_pct", 0.0)) / 100.0
			})
		if base.has("ctb_floor_c") or base.has("ctb_floor_m"):
			out.append({
				"id": "ALC_CTB_FLOOR",
				"type": "multiplicative"
			})

	if b_id == "church":
		var base_dr: float = float(base.get("global_dr_base_pct", 0.0)) / 100.0
		if base_dr > 0.0:
			out.append({
				"id": "CH_WARD_DR",
				"type": "additive",
				"base": base_dr
			})

	return out

func _deep_clone(x: Variant) -> Variant:
	if x is Dictionary:
		var d_in: Dictionary = x
		var d_out: Dictionary = {}
		for k in d_in.keys():
			d_out[k] = _deep_clone(d_in[k])
		return d_out
	elif x is Array:
		var a_in: Array = x
		var a_out: Array = []
		for v in a_in:
			a_out.append(_deep_clone(v))
		return a_out
	else:
		return x
