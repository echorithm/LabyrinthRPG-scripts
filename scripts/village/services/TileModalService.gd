# res://scripts/village/services/TileModalService.gd
## Modal orchestrator. Delegates to VillageService and repaints scene on changes.
extends Node
class_name TileModalService

signal action_ok()
signal action_failed(reason: String)
signal snapshot_changed(snap: Dictionary)

@export var wild_modal_scene: PackedScene
@export var camp_modal_scene: PackedScene
@export var entrance_modal_scene: PackedScene

# Shell + body scenes
@export var building_modal_shell_scene: PackedScene
@export var vendor_body_scene: PackedScene
@export var trainer_body_scene: PackedScene    # body for any trainer_* kind

@export var modal_theme: Theme
@export var ui_layer_path: NodePath

@export var village_service_path: NodePath
@export var autoload_on_ready: bool = true
@export var default_slot: int = 0

# Optional: services
@export var items_service_path: NodePath
@export var npc_service_path: NodePath    # (kept for get_npc_snapshot fallback)
@export var trade_service_path: NodePath
@export var trainers_service_path: NodePath
@export var npc_assignment_service_path: NodePath   # NEW

var _items: ItemsService = null
var _npc: NPCService = null
var _trade: Node = null
var _trainers: TrainersService = null
var _npc_assign: NPCAssignmentService = null   # NEW

# Legacy (kept but not used for stock)
@export var alchemist_modal_scene: PackedScene

const NPCXp := preload("res://scripts/village/services/NPCXpService.gd")

const AUTO_LAYER_NAME := "TileUILayer"
const SUPPRESS_FRAMES := 6
const SUPPRESS_MS := 160
const _DBG := "[TMS] "
func _log(msg: String) -> void: print(_DBG + msg)

# ADR helpers
const Vendors := preload("res://scripts/village/services/VendorsService.gd")
const SaveMgr := preload("res://persistence/SaveManager.gd")
const Econ    := preload("res://scripts/village/util/EconomyUtils.gd")
const ShopResolver := preload("res://scripts/village/services/ShopResolver.gd")

const SHOP_FACTOR: float = 1.30

var _ui_layer: Node = null
var _active_modal: Control = null
var _suppress_until_frame: int = -1
var _suppress_until_ms: int = -1

var _staffing_ui_cache: Dictionary = {}  # { String(iid): StringName(current_npc_id) }

var _village: VillageService = null
var _slot: int = 1

# Keep open-modal metadata so we can rebuild training ctx
var _by_iid: Dictionary = {}   # { iid: { kind:StringName, coord:Vector2i, slot:int } }

# ---------- Public API ----------
func load_slot(slot: int) -> void:
	_slot = (slot if slot != 0 else default_slot)
	_slot = max(1, _slot)
	if _village == null:
		_village = _resolve_village()
	if _village != null:
		_village.load_slot(_slot)
	else:
		_emit_fail("VillageService not available")

func should_block_open() -> bool:
	var frames: int = Engine.get_process_frames()
	var now_ms: int = Time.get_ticks_msec()
	var active: bool = is_instance_valid(_active_modal)
	var by_frame: bool = frames <= _suppress_until_frame
	var by_time: bool = now_ms <= _suppress_until_ms
	return active or by_frame or by_time

func open_for_tile(qr: Vector2i) -> void:
	if should_block_open(): return
	if _village != null: _village.sync_with_active_vmap()
	var tile: Dictionary = get_tile_at(qr)
	var kind: String = String(tile.get("kind", "wild")).to_lower()
	_log("open_for_tile kind='%s' @ %s" % [kind, str(qr)])
	if kind == "alchemist_lab" and alchemist_modal_scene != null:
		_log("using legacy alchemist modal")
		_open_legacy_alchemist(qr)
		return
	_open_shell_for(qr, StringName(kind))

func open_building_modal(coord: Vector2i, body_kind: String) -> void:
	if should_block_open(): return
	if _village != null: _village.sync_with_active_vmap()
	_open_shell_for(coord, StringName(body_kind.to_lower()))

func close_current() -> void:
	_close_active()

func get_tile_at(qr: Vector2i) -> Dictionary:
	var snap: Dictionary = get_snapshot()
	var tiles_any: Variant = (snap.get("grid", {}) as Dictionary).get("tiles", [])
	var tiles: Array = (tiles_any as Array) if (tiles_any is Array) else []
	for t_any in tiles:
		if t_any is Dictionary:
			var t: Dictionary = t_any
			if int(t.get("q", 0)) == qr.x and int(t.get("r", 0)) == qr.y:
				return t
	return {}

func apply_build(qr: Vector2i, building_id: String) -> void:
	if _village == null: _emit_fail("VillageService not available"); return
	var iid: StringName = _village.place_building(qr.x, qr.y, StringName(building_id))
	if String(iid) == "": _emit_fail("Failed to place building %s at (%d,%d)" % [building_id, qr.x, qr.y]); return
	_start_suppression()
	emit_signal("action_ok")

func apply_terraform(qr: Vector2i, target_art_id: String) -> void:
	if _village == null: _emit_fail("VillageService not available"); return
	_village.terraform_tile(qr.x, qr.y, StringName(target_art_id))
	_start_suppression()
	emit_signal("action_ok")

func assign_staff(instance_id: StringName, npc_id: StringName) -> void:
	if _village == null: _emit_fail("VillageService not available"); return
	_log("assign_staff iid=%s npc=%s" % [String(instance_id), String(npc_id)])
	_village.assign_staff(instance_id, npc_id)
	emit_signal("action_ok")

func set_building_rarity(instance_id: StringName, rarity: StringName) -> void:
	if _village == null: _emit_fail("VillageService not available"); return
	_village.set_building_rarity(instance_id, rarity)
	emit_signal("action_ok")

func get_snapshot() -> Dictionary:
	if _village == null: return {}
	return _village.get_snapshot()

# ---------- Scene resolution ----------
func _scene_for_kind(kind_in: String) -> PackedScene:
	var k: String = kind_in.to_lower()
	match k:
		"wild", "road", "bridge":
			return wild_modal_scene
		"camp_core":
			return camp_modal_scene
		"labyrinth":
			return entrance_modal_scene
		"alchemist_lab":
			return alchemist_modal_scene if alchemist_modal_scene != null else (building_modal_shell_scene if building_modal_shell_scene != null else wild_modal_scene)
		_:
			return building_modal_shell_scene if building_modal_shell_scene != null else wild_modal_scene

# ---------- Lifecycle ----------
func _ready() -> void:
	if not is_in_group("village_modal_service"):
		add_to_group("village_modal_service")

	_ui_layer = get_node_or_null(ui_layer_path)
	_items = get_node_or_null(items_service_path)
	_npc   = get_node_or_null(npc_service_path)
	_trade = get_node_or_null(trade_service_path)

	_trainers = _resolve_trainers()
	_village = _resolve_village()
	_npc_assign = get_node_or_null(npc_assignment_service_path) as NPCAssignmentService

	if _village != null:
		_village.connect("snapshot_changed", Callable(self, "_on_village_snapshot_changed"))
		if _village.has_signal("activation_changed"):
			_village.connect("activation_changed", Callable(self, "_on_activation_changed"))
		if _village.has_signal("npc_assigned"):
			_village.connect("npc_assigned", Callable(self, "_on_npc_assigned"))
		if _village.has_signal("building_upgraded"):
			_village.connect("building_upgraded", Callable(self, "_on_building_upgraded"))

	if _trade != null:
		if _trade.has_signal("vendor_stock_changed"):
			_trade.connect("vendor_stock_changed", Callable(self, "_on_vendor_stock_changed"))
		if _trade.has_signal("stash_gold_changed"):
			_trade.connect("stash_gold_changed", Callable(self, "_on_stash_gold_changed"))

	if autoload_on_ready:
		var slot_i: int = SaveMgr.active_slot()
		load_slot(slot_i)
	_log("USING SCRIPT: %s  NODE PATH: %s" % [(get_script() as Script).resource_path, str(get_path())])

# ---------- Shell path ----------
func _open_shell_for(qr: Vector2i, kind_sname: StringName) -> void:
	var kind: String = String(kind_sname)
	var scene: PackedScene = _scene_for_kind(kind)
	if scene == null: _log("no scene resolved; abort"); return

	var inst_any: Node = scene.instantiate()
	if inst_any == null or not (inst_any is Control): _log("resolved scene is not Control; abort"); return
	var modal: Control = inst_any as Control

	var iid: StringName = StringName("%s@H_%d_%d" % [kind, qr.x, qr.y])
	var slot_i: int = _slot
	_log("iid='%s' slot=%d" % [String(iid), slot_i])

	var vendor_like: bool = (kind == "alchemist_lab" or kind == "marketplace" or kind == "blacksmith" or kind == "guild")
	if vendor_like:
		Vendors.ensure_block(iid, String(kind), slot_i)

	if "modal_theme" in modal and modal_theme != null:
		modal.set("modal_theme", modal_theme)

	var is_shell: bool = modal.has_method("set_body") and modal.has_method("set_context")
	_log("is_shell=%s" % str(is_shell))

	# Remember open modal metadata for training ctx rebuilds
	_by_iid[String(iid)] = { "kind": StringName(kind), "coord": qr, "slot": slot_i }

	if is_shell:
		modal.call("set_context", qr, iid, slot_i, StringName(kind))

		var body: Control = _instantiate_body_for_kind(kind)
		if body != null:
			_log("mounting body %s" % body.get_class())
			modal.call("set_body", body)
			if body.has_signal("request_buy"):
				body.connect("request_buy", Callable(self, "_on_vendor_buy").bind(iid))
			if body.has_signal("request_sell"):
				body.connect("request_sell", Callable(self, "_on_vendor_sell").bind(iid))
			if body.has_signal("request_unlock"):
				body.connect("request_unlock", Callable(self, "_on_trainer_unlock").bind(iid))
			if body.has_signal("request_raise_cap"):
				body.connect("request_raise_cap", Callable(self, "_on_trainer_raise_cap").bind(iid))

		if modal.has_signal("assign_requested"):
			modal.connect("assign_requested", Callable(self, "_on_assign_requested"))
		if modal.has_signal("unassign_requested"):
			modal.connect("unassign_requested", Callable(self, "_on_unassign_requested"))
		if modal.has_signal("upgrade_requested"):
			modal.connect("upgrade_requested", Callable(self, "_on_upgrade_requested"))
	else:
		if "tile_coord" in modal: modal.set("tile_coord", qr)
		if modal.has_method("set_context"): modal.call("set_context", qr)
		modal.visible = true
		modal.mouse_filter = Control.MOUSE_FILTER_STOP
		modal.set_anchors_preset(Control.PRESET_FULL_RECT)
		modal.offset_left = 0.0; modal.offset_top = 0.0; modal.offset_right = 0.0; modal.offset_bottom = 0.0

	var parent: Node = _resolve_or_create_ui_parent()
	parent.add_child(modal)

	_active_modal = modal
	if modal.has_signal("closed"):
		modal.connect("closed", Callable(self, "_on_modal_closed").bind(modal, parent))

	# Prime trainers service with the open context so actions have header/rarity cached.
	if _trainers != null:
		_trainers.open_for_tile(StringName(kind), iid, qr, slot_i)

	if modal.has_method("present"):
		_log("calling present() NOW")
		modal.call("present", true, false)
		_log("returned from present()")
	if modal.has_method("refresh_all"):
		modal.call("refresh_all")

	var tree: SceneTree = get_tree()
	if tree != null:
		await tree.process_frame
		await tree.process_frame

	if modal.mouse_filter != Control.MOUSE_FILTER_STOP:
		modal.mouse_filter = Control.MOUSE_FILTER_STOP
		_log("modal mouse_filter -> STOP (post-present)")

	var backdrop := modal.get_node_or_null(^"Backdrop") as ColorRect
	if backdrop != null:
		if backdrop.mouse_filter != Control.MOUSE_FILTER_STOP:
			backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
			_log("Backdrop mouse_filter -> STOP")
		backdrop.visible = true

	var p := modal.get_node_or_null(^"Panel") as Control
	if p != null:
		if p.mouse_filter != Control.MOUSE_FILTER_STOP:
			p.mouse_filter = Control.MOUSE_FILTER_STOP
			_log("Panel mouse_filter -> STOP")
		p.set_anchors_preset(Control.PRESET_FULL_RECT)

	var rect: Rect2 = modal.get_global_rect()
	_log("modal mounted -> vis=%s mouse=%d rect=%s parent=%s children=%d" %
		[str(modal.visible), int(modal.mouse_filter), str(rect), parent.name, int(modal.get_child_count())])
	if p != null:
		_log("modal Panel rect=%s" % str(p.get_global_rect()))
	else:
		_log("modal has no 'Panel' node (ok for legacy panels)")

	if tree != null and tree.paused and not is_shell:
		tree.paused = false
		_log("unpaused game for non-shell modal")

func _instantiate_body_for_kind(kind: String) -> Control:
	match kind:
		"alchemist_lab", "marketplace", "blacksmith", "guild":
			if vendor_body_scene != null: return vendor_body_scene.instantiate() as Control
		_:
			pass
	if kind.begins_with("trainer") and trainer_body_scene != null:
		return trainer_body_scene.instantiate() as Control
	return null

# ---------- Snapshot repaint ----------
func _on_village_snapshot_changed(snap: Dictionary) -> void:
	_repaint_current_scene(snap)
	emit_signal("snapshot_changed", snap)

func _repaint_current_scene(snap: Dictionary) -> void:
	var scene := get_tree().current_scene
	if scene == null: return
	if scene.has_method("apply_map_snapshot"):
		scene.call("apply_map_snapshot", snap)
	elif scene.has_method("reload_map_snapshot"):
		scene.call("reload_map_snapshot")

# ---------- Close / lifecycle ----------
func _on_modal_closed(modal: Control, parent: Node) -> void:
	if is_instance_valid(modal): modal.queue_free()
	var iid: StringName = modal.get("instance_id") if "instance_id" in modal else StringName("")
	_staffing_ui_cache.erase(String(iid))
	_by_iid.erase(String(iid))
	_active_modal = null
	_start_suppression()
	if parent is CanvasLayer and parent.name == AUTO_LAYER_NAME:
		var tree := get_tree()
		if tree != null:
			await tree.process_frame
			if is_instance_valid(parent) and parent.get_child_count() == 0:
				parent.queue_free()
		elif is_instance_valid(parent):
			parent.queue_free()

func _close_active() -> void:
	if is_instance_valid(_active_modal):
		if _active_modal.has_method("close"): _active_modal.call_deferred("close")
		else: _active_modal.queue_free()
	_active_modal = null
	_start_suppression()

# ---------- Suppression / parent ----------
func _start_suppression() -> void:
	_suppress_until_frame = Engine.get_process_frames() + SUPPRESS_FRAMES
	_suppress_until_ms = Time.get_ticks_msec() + SUPPRESS_MS

func _resolve_or_create_ui_parent() -> Node:
	_ui_layer = get_node_or_null(ui_layer_path)
	if _ui_layer != null: return _ui_layer
	var layer := CanvasLayer.new()
	layer.name = AUTO_LAYER_NAME
	layer.layer = 10000
	layer.follow_viewport_enabled = true
	var parent: Node = get_tree().current_scene if get_tree().current_scene != null else get_tree().root
	parent.add_child(layer)
	_ui_layer = layer
	return _ui_layer

# ---------- Service resolution ----------
func _resolve_village() -> VillageService:
	if village_service_path != NodePath():
		var n := get_node_or_null(village_service_path)
		if n != null and n is VillageService: return n as VillageService
	var auto := get_tree().get_root().get_node_or_null("VillageService")
	if auto != null and auto is VillageService: return auto as VillageService
	var g: Array = get_tree().get_nodes_in_group("VillageService")
	if g.size() > 0 and g[0] is VillageService: return g[0] as VillageService
	return null

func _emit_fail(reason: String) -> void:
	emit_signal("action_failed", reason)

# ---------- Legacy ----------
func _open_legacy_alchemist(qr: Vector2i) -> void:
	var scene: PackedScene = alchemist_modal_scene
	if scene == null: return
	var inst_any: Node = scene.instantiate()
	if inst_any == null or not (inst_any is Control): return
	var modal := inst_any as Control
	if "tile_coord" in modal: modal.set("tile_coord", qr)
	if "modal_theme" in modal and modal_theme != null: modal.set("modal_theme", modal_theme)
	var parent := _resolve_or_create_ui_parent()
	parent.add_child(modal)
	_active_modal = modal
	if modal.has_signal("closed"):
		modal.connect("closed", Callable(self, "_on_modal_closed").bind(modal, parent))
	if modal.has_method("present"):
		modal.call_deferred("present", true, false)

# ---------- Intents from Shell / Body ----------
func _on_assign_requested(instance_id: StringName, npc_id: StringName) -> void:
	if _village == null:
		_emit_fail("VillageService not available")
		return
	_log("on_assign_requested iid=%s npc=%s" % [String(instance_id), String(npc_id)])

	if _npc_assign == null:
		_emit_fail("NPCAssignmentService missing")
		return

	var res: Dictionary = _npc_assign.assign(instance_id, npc_id, _slot)
	if bool(res.get("ok", true)):
		emit_signal("action_ok")
	else:
		_emit_fail(String(res.get("reason", "assign_failed")))
	_emit_refresh(instance_id)

func _on_unassign_requested(instance_id: StringName) -> void:
	if _village == null:
		_emit_fail("VillageService not available")
		return
	_log("on_unassign_requested iid=%s" % [String(instance_id)])

	if _npc_assign == null:
		_emit_fail("NPCAssignmentService missing")
		return

	var res2: Dictionary = _npc_assign.unassign(instance_id, _slot)
	if bool(res2.get("ok", true)):
		emit_signal("action_ok")
	else:
		_emit_fail(String(res2.get("reason", "unassign_failed")))
	_staffing_ui_cache[String(instance_id)] = StringName("")
	_emit_refresh(instance_id)

func _on_upgrade_requested(instance_id: StringName) -> void:
	if _village == null: _emit_fail("VillageService not available"); return
	var inst: Dictionary = _village.get_building_instance(instance_id)
	var cur: String = String(inst.get("rarity", "COMMON"))
	var next: StringName = _next_rarity(StringName(cur))
	_log("on_upgrade_requested iid=%s rarity %s -> %s" % [String(instance_id), cur, String(next)])
	_village.set_building_rarity(instance_id, next)
	emit_signal("action_ok")
	_emit_refresh(instance_id)

static func _next_rarity(r: StringName) -> StringName:
	match String(r).to_upper():
		"COMMON", "C":    return StringName("UNCOMMON")
		"UNCOMMON", "U":  return StringName("RARE")
		"RARE", "R":      return StringName("EPIC")
		"EPIC", "E":      return StringName("ANCIENT")
		"ANCIENT", "A":   return StringName("LEGENDARY")
		"LEGENDARY", "L": return StringName("MYTHIC")
		_:                return StringName("MYTHIC")

func _on_vendor_buy(item_id: StringName, qty: int, rarity: String, instance_id: StringName) -> void:
	_log("vendor buy iid=%s item=%s qty=%d rarity=%s" % [String(instance_id), String(item_id), qty, rarity])
	var handled := false
	if _trade != null and _trade.has_method("buy"):
		var use_slot := _slot
		_trade.call("buy", instance_id, String(item_id), qty, use_slot, rarity)
		handled = true
	if handled: emit_signal("action_ok")
	_emit_refresh(instance_id)

func _on_vendor_sell(item_id: StringName, qty: int, rarity: String, instance_id: StringName) -> void:
	_log("vendor sell iid=%s item=%s qty=%d rarity=%s" % [String(instance_id), String(item_id), qty, rarity])
	var handled := false
	if _trade != null and _trade.has_method("sell"):
		var use_slot := _slot
		_trade.call("sell", String(item_id), qty, use_slot, rarity)
		handled = true
	if handled: emit_signal("action_ok")
	_emit_refresh(instance_id)

func _on_trainer_unlock(skill_id: StringName, instance_id: StringName) -> void:
	_log("trainer unlock iid=%s skill=%s" % [String(instance_id), String(skill_id)])
	var ok: bool = false
	if _trainers != null and _trainers.has_method("request_unlock"):
		ok = bool(_trainers.call("request_unlock", skill_id))
	if ok:
		emit_signal("action_ok")
	else:
		_emit_fail("Unlock failed")
	_emit_refresh(instance_id)

func _on_trainer_raise_cap(skill_id: StringName, instance_id: StringName) -> void:
	var rarity: String = "COMMON"
	var h: Dictionary = get_tile_header(instance_id)
	if not h.is_empty():
		rarity = String(h.get("rarity", "COMMON"))
	_log("trainer raise_cap iid=%s skill=%s rarity=%s" % [String(instance_id), String(skill_id), rarity])

	var ok: bool = false
	if _trainers != null and _trainers.has_method("request_raise_cap"):
		ok = bool(_trainers.call("request_raise_cap", skill_id, rarity))
	if ok:
		emit_signal("action_ok")
	else:
		_emit_fail("Raise cap failed")
	_emit_refresh(instance_id)

func _emit_refresh(instance_id: StringName) -> void:
	if _active_modal != null and _active_modal.has_method("refresh_all"):
		_active_modal.call("refresh_all")

func get_tile_header(instance_id: StringName) -> Dictionary:
	if _village != null and _village.has_method("get_tile_header"):
		return _village.call("get_tile_header", instance_id)
	return { "display_name": "Alchemist Lab", "rarity": "COMMON", "connected": false, "active": false, "badges": [] as Array }

# ---------- Training ctx bridge ----------
func get_training_ctx(iid: StringName) -> Dictionary:
	if _trainers == null:
		return {}
	var row: Dictionary = _by_iid.get(String(iid), {})
	var kind: StringName = row.get("kind", StringName(""))
	var coord: Vector2i = row.get("coord", Vector2i.ZERO)
	var slot_i: int = int(row.get("slot", _slot))
	# Fallback: parse kind from iid if we missed the map
	if String(kind) == "":
		var parts: PackedStringArray = String(iid).split("@")
		if parts.size() > 0:
			kind = StringName(parts[0])
	return _trainers.refresh_for_tile(kind, iid, coord, slot_i)

# ---------- Staffing (delegated) ----------
func get_staffing(instance_id: StringName) -> Dictionary:
	# Preferred: NPCAssignmentService provides role_required/current/roster
	if _npc_assign != null:
		var s: Dictionary = _npc_assign.get_staffing(instance_id, _slot)
		# Keep “current first” behavior for UI
		var current_id: String = String(s.get("current_npc_id", ""))
		if current_id != "":
			var v: Dictionary = SaveMgr.load_village(_slot)
			var list_any: Variant = v.get("npcs", [])
			var list: Array = (list_any as Array) if (list_any is Array) else []
			var out: Array[Dictionary] = []
			var seen: Dictionary = {}
			# Current first (full row if found)
			for row_any in list:
				if not (row_any is Dictionary): continue
				var n: Dictionary = row_any
				if String(n.get("id","")) == current_id:
					out.append({ "id": StringName(current_id), "name": String(n.get("name", current_id)),
								 "level": int(n.get("level", 1)), "role": String(n.get("role","")) })
					seen[current_id] = true
					break
			if not seen.has(current_id):
				out.append({ "id": StringName(current_id), "name": current_id, "level": 1, "role": "" })
			# Append service roster (unassigned candidates)
			var roster_in: Array = (s.get("roster", []) as Array) if (s.get("roster", []) is Array) else []
			for r_any in roster_in:
				if not (r_any is Dictionary): continue
				var r: Dictionary = r_any
				var id_s: String = String(r.get("id",""))
				if id_s == "": continue
				if seen.has(id_s): continue
				out.append({ "id": StringName(id_s), "name": String(r.get("name", id_s)),
							 "level": int(r.get("level", 1)), "role": String(r.get("role","")) })
			return { "role_required": StringName(String(s.get("role_required",""))),
					 "current_npc_id": StringName(current_id),
					 "roster": out }
		return s
	# Fallback: minimal empty
	return { "role_required": StringName("INNKEEPER"), "current_npc_id": StringName(""), "roster": [] as Array[Dictionary] }

# ---------- META helpers ----------
func _meta_stash_gold() -> int:
	var slot_i: int = _slot
	var gs: Dictionary = SaveMgr.load_game(slot_i)
	return int(gs.get("stash_gold", 0))

func _meta_inventory() -> Array:
	var slot_i: int = _slot
	var gs: Dictionary = SaveMgr.load_game(slot_i)
	var pl_any: Variant = gs.get("player", {})
	var pl: Dictionary = (pl_any as Dictionary) if pl_any is Dictionary else {}
	var inv_any: Variant = pl.get("inventory", [])
	return (inv_any as Array) if (inv_any is Array) else []

static func _dura_max(d: Dictionary) -> int:
	if d.has("durability_max"): return int(d.get("durability_max", 0))
	if d.has("opts") and d["opts"] is Dictionary: return int((d["opts"] as Dictionary).get("durability_max", 0))
	return 0

static func _count_or_1(d: Dictionary) -> int:
	if d.has("count"): return int(d.get("count", 1))
	if d.has("opts") and d["opts"] is Dictionary: return int((d["opts"] as Dictionary).get("count", 1))
	return 1

func _meta_sellable_potions_list() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var counts: Dictionary = {}
	for v in _meta_inventory():
		if not (v is Dictionary): continue
		var d: Dictionary = v
		var id: String = String(d.get("id", ""))
		if id == "" or _dura_max(d) != 0: continue
		if not Econ.is_potion_id(id): continue
		var rarity_text := "Common"
		var opts_any: Variant = d.get("opts", {})
		if (opts_any is Dictionary):
			var rraw := String((opts_any as Dictionary).get("rarity", ""))
			if rraw != "": rarity_text = Econ._rarity_full(rraw)
		var key := id + "|" + rarity_text
		counts[key] = int(counts.get(key, 0)) + _count_or_1(d)
	for key in counts.keys():
		var parts: PackedStringArray = String(key).split("|")
		var id2: String = parts[0]
		var rarity_text2: String = parts[1] if parts.size() > 1 else "Common"
		var owned: int = int(counts[key])
		var unit: int = Econ.sell_price_vendor(id2, rarity_text2)
		out.append({ "id": StringName(id2), "name": _display_name(StringName(id2)) + " [" + rarity_text2 + "]",
					 "rarity": rarity_text2, "price": unit, "count": owned })
	return out

func _resolve_trainers() -> TrainersService:
	if trainers_service_path != NodePath():
		var n := get_node_or_null(trainers_service_path)
		if n != null and n is TrainersService: return n as TrainersService
	var auto := get_tree().get_root().get_node_or_null("TrainersService")
	if auto != null and auto is TrainersService: return auto as TrainersService
	var inst := TrainersService.new()
	inst.name = "TrainersService(_local)"
	add_child(inst)
	return inst

func _display_name(id: StringName) -> String:
	return _items.get_display_name(id) if _items != null else String(id).capitalize().replace("_", " ")

func get_npc_snapshot(npc_id: StringName) -> Dictionary:
	if _npc != null: return _npc.get_npc_snapshot(npc_id)
	return { "name": "—", "level": 1, "xp": 0, "xp_next": 1 }

func get_assigned_role_snapshot(instance_id: StringName) -> Dictionary:
	var now_min: float = float(SaveMgr.load_game(_slot).get("time_passed_min", 0.0))
	return NPCXp.settle_for_instance(instance_id, now_min, _slot)

func is_modal_open() -> bool:
	return is_instance_valid(_active_modal)
