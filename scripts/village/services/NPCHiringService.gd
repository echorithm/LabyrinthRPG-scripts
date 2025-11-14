extends Node
class_name NPCHiringService

const SaveManager      := preload("res://persistence/SaveManager.gd")
const NPCSchema        := preload("res://scripts/village/persistence/schemas/npc_instance_schema.gd")
const NPCRecruitment   := preload("res://scripts/village/services/NPCRecruitmentService.gd")
const NPCConfig        := preload("res://scripts/village/services/NPCConfig.gd")

@export var recruitment_service_path: NodePath
@export var debug_logging: bool = true
@export var default_slot: int = 1  # only used as a fallback if active_slot is 0

var _recruit: NPCRecruitmentService = null


func _dbg(msg: String) -> void:
	if debug_logging:
		print("[NPCHire] " + msg)


func _ready() -> void:
	default_slot = max(1, default_slot)
	_recruit = _resolve_recruit()
	if _recruit == null:
		_dbg("WARN: NPCRecruitmentService not resolved at _ready(); will try again on hire()")


func _resolve_recruit() -> NPCRecruitmentService:
	# 1) Explicit export path
	if recruitment_service_path != NodePath(""):
		var n: Node = get_node_or_null(recruitment_service_path)
		if n is NPCRecruitmentService:
			return n as NPCRecruitmentService
		if n != null:
			_dbg("WARN: node at recruitment_service_path is not NPCRecruitmentService -> " + n.get_class())

	# 2) Named node at root
	var root: Node = get_tree().get_root()
	if root != null:
		var by_name: Node = root.get_node_or_null("NPCRecruitmentService")
		if by_name is NPCRecruitmentService:
			return by_name as NPCRecruitmentService

		# 3) Group
		var group_nodes: Array = get_tree().get_nodes_in_group("NPCRecruitmentService")
		for g_any in group_nodes:
			if g_any is NPCRecruitmentService:
				return g_any as NPCRecruitmentService

		# 4) Deep scan BFS
		var q: Array[Node] = []
		q.append(root)
		while not q.is_empty():
			var cur: Node = q.pop_front()
			if cur is NPCRecruitmentService:
				return cur as NPCRecruitmentService
			for c in (cur.get_children() as Array[Node]):
				q.append(c)

	return null


func _active_slot_or_fallback() -> int:
	var s: int = SaveManager.active_slot()
	if s <= 0:
		s = max(1, default_slot)
	return s


func cost() -> int:
	return NPCConfig.HIRE_COST_GOLD


## Hire from the current recruitment page.
## NOTE: 'slot' is treated as a *hint* only; we always prefer SaveManager.active_slot().
func hire(source_index: int, slot: int = 0) -> Dictionary:
	var active_slot: int = _active_slot_or_fallback()
	var use_slot: int = active_slot

	# Only trust the explicit slot if it matches the active slot
	if slot > 0 and slot == active_slot:
		use_slot = slot

	_dbg("hire: source_index=%d slot_arg=%d active_slot=%d use_slot=%d"
		% [source_index, slot, active_slot, use_slot])

	if _recruit == null:
		_recruit = _resolve_recruit()
		_dbg("late resolve recruit -> " + (String(_recruit.get_path()) if _recruit != null else "<null>"))

	if _recruit == null:
		_dbg("ABORT: recruitment service missing (cannot fetch page)")
		return {}

	# --- Fetch page for this slot -----------------------------------------
	# get_page() is also slot-aware and will resolve against active_slot.
	var page_raw: Array = _recruit.get_page(use_slot)
	var page: Array[Dictionary] = [] as Array[Dictionary]
	for row_any in page_raw:
		if row_any is Dictionary:
			page.append(row_any as Dictionary)

	if page.is_empty():
		_dbg("ABORT: empty page (no candidates) slot=%d" % use_slot)
		return {}

	if source_index < 0 or source_index >= page.size():
		_dbg("ABORT: index out of range i=%d size=%d slot=%d" % [source_index, page.size(), use_slot])
		return {}

	# --- META gold gate (per-slot stash) ----------------------------------
	var meta: Dictionary = SaveManager.load_game(use_slot)
	var stash_gold: int = int(meta.get("stash_gold", 0))
	var cost_gold: int = NPCConfig.HIRE_COST_GOLD

	if stash_gold < cost_gold:
		_dbg("hire BLOCKED: need %d gold, have %d (slot=%d)" % [cost_gold, stash_gold, use_slot])
		return {}

	meta["stash_gold"] = max(0, stash_gold - cost_gold)
	SaveManager.save_game(meta, use_slot)

	# --- Append NPC into that slot's village save -------------------------
	var hire_norm: Dictionary = NPCSchema.validate(page[source_index])

	# IMPORTANT: go through SaveManager.load_village/save_village so slot
	# semantics match META (in_menu vs in_game + active_slot).
	var village: Dictionary = SaveManager.load_village(use_slot)
	var npcs_any: Variant = village.get("npcs", [])
	var npcs: Array[Dictionary] = [] as Array[Dictionary]
	if npcs_any is Array:
		for r_any in (npcs_any as Array):
			if r_any is Dictionary:
				npcs.append(r_any as Dictionary)

	npcs.append(hire_norm)
	village["npcs"] = npcs
	SaveManager.save_village(village, use_slot)

	_touch_recruitment_unchanged(use_slot)

	_dbg("OK hired '%s' (id=%s) -> npcs now=%d (-%d gold) slot=%d"
		% [String(hire_norm.get("name","")), String(hire_norm.get("id","")),
		   npcs.size(), cost_gold, use_slot])

	return hire_norm


func _touch_recruitment_unchanged(slot: int) -> void:
	# Just ensure the recruitment block exists and stays in the same slot.
	var v: Dictionary = SaveManager.load_village(slot)
	var rec_any: Variant = v.get("recruitment", {})
	var rec: Dictionary = {} as Dictionary
	if rec_any is Dictionary:
		rec = rec_any as Dictionary
	v["recruitment"] = rec
	SaveManager.save_village(v, slot)
