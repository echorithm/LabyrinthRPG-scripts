## res://scripts/village/ui/TileModalService.gd
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
@export var npc_service_path: NodePath
@export var trade_service_path: NodePath
var _items: ItemsService = null
var _npc: NPCService = null
var _trade: Node = null

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

@export var trainers_service_path: NodePath
var _trainers: TrainersService = null

# Must match TradeService
const SHOP_FACTOR: float = 1.30

var _ui_layer: Node = null
var _active_modal: Control = null
var _suppress_until_frame: int = -1
var _suppress_until_ms: int = -1

var _staffing_ui_cache: Dictionary = {}  # { String(iid): StringName(current_npc_id) }

var _village: VillageService = null
var _slot: int = 1

# ---------- Public API ----------
func load_slot(slot: int) -> void:
	# Never allow 0 – treat 0 as “use export default”, but clamp to 1+ for saves.
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
	if should_block_open():
		return
	if _village != null:
		_village.sync_with_active_vmap()

	var tile: Dictionary = get_tile_at(qr)
	var kind: String = String(tile.get("kind", "wild")).to_lower()
	_log("open_for_tile kind='%s' @ %s" % [kind, str(qr)])

	if kind == "alchemist_lab" and alchemist_modal_scene != null:
		_log("using legacy alchemist modal")
		_open_legacy_alchemist(qr)
		return

	_open_shell_for(qr, StringName(kind))

func open_building_modal(coord: Vector2i, body_kind: String) -> void:
	if should_block_open():
		return
	if _village != null:
		_village.sync_with_active_vmap()
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
	if _village == null:
		_emit_fail("VillageService not available"); return
	var iid: StringName = _village.place_building(qr.x, qr.y, StringName(building_id))
	if String(iid) == "":
		_emit_fail("Failed to place building %s at (%d,%d)" % [building_id, qr.x, qr.y]); return
	_start_suppression()
	emit_signal("action_ok")

func apply_terraform(qr: Vector2i, target_art_id: String) -> void:
	if _village == null:
		_emit_fail("VillageService not available"); return
	_village.terraform_tile(qr.x, qr.y, StringName(target_art_id))
	_start_suppression()
	emit_signal("action_ok")

func assign_staff(instance_id: StringName, npc_id: StringName) -> void:
	if _village == null:
		_emit_fail("VillageService not available"); return
	_log("assign_staff iid=%s npc=%s" % [String(instance_id), String(npc_id)])
	_village.assign_staff(instance_id, npc_id)
	emit_signal("action_ok")

func set_building_rarity(instance_id: StringName, rarity: StringName) -> void:
	if _village == null:
		_emit_fail("VillageService not available"); return
	_village.set_building_rarity(instance_id, rarity)
	emit_signal("action_ok")

func get_snapshot() -> Dictionary:
	if _village == null:
		return {}
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
	if _village != null:
		_village.connect("snapshot_changed", Callable(self, "_on_village_snapshot_changed"))
		if _village.has_signal("activation_changed"):
			_village.connect("activation_changed", Callable(self, "_on_activation_changed"))
		if _village.has_signal("npc_assigned"):
			_village.connect("npc_assigned", Callable(self, "_on_npc_assigned"))
		if _village.has_signal("building_upgraded"):
			_village.connect("building_upgraded", Callable(self, "_on_building_upgraded"))

	# TradeService (may not have signals; guarded)
	if _trade != null:
		if _trade.has_signal("vendor_stock_changed"):
			_trade.connect("vendor_stock_changed", Callable(self, "_on_vendor_stock_changed"))
		if _trade.has_signal("stash_gold_changed"):
			_trade.connect("stash_gold_changed", Callable(self, "_on_stash_gold_changed"))

	if autoload_on_ready:
		load_slot(default_slot)
	_log("USING SCRIPT: %s  NODE PATH: %s" % [(get_script() as Script).resource_path, str(get_path())])

# ---------- Shell path ----------
func _open_shell_for(qr: Vector2i, kind_sname: StringName) -> void:
	var kind: String = String(kind_sname)
	var scene: PackedScene = _scene_for_kind(kind)
	if scene == null:
		_log("no scene resolved; abort")
		return

	var inst_any: Node = scene.instantiate()
	if inst_any == null or not (inst_any is Control):
		_log("resolved scene is not Control; abort")
		return
	var modal: Control = inst_any as Control

	var iid: StringName = StringName("%s@H_%d_%d" % [kind, qr.x, qr.y])
	var slot_i: int = _slot
	_log("iid='%s' slot=%d" % [String(iid), slot_i])

	# Only vendorize vendor-like buildings (avoid bogus vendor blocks for trainers)
	var vendor_like := (kind == "alchemist_lab" or kind == "marketplace" or kind == "blacksmith" or kind == "guild")
	if vendor_like:
		Vendors.ensure_block(iid, String(kind), slot_i)
		

	# Pass theme if supported
	if "modal_theme" in modal and modal_theme != null:
		modal.set("modal_theme", modal_theme)

	var is_shell: bool = modal.has_method("set_body") and modal.has_method("set_context")
	_log("is_shell=%s" % str(is_shell))

	if is_shell:
		modal.call("set_context", qr, iid, slot_i, StringName(kind))

		var body: Control = _instantiate_body_for_kind(kind)
		if body != null:
			_log("mounting body %s" % body.get_class())
			modal.call("set_body", body)
			# Vendor body hooks (trainer body will not emit these)
			if body.has_signal("request_buy"):
				body.connect("request_buy", Callable(self, "_on_vendor_buy").bind(iid))
			if body.has_signal("request_sell"):
				body.connect("request_sell", Callable(self, "_on_vendor_sell").bind(iid))
			# Trainer body hooks
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
		if "tile_coord" in modal:
			modal.set("tile_coord", qr)
		if modal.has_method("set_context"):
			modal.call("set_context", qr)

		modal.visible = true
		modal.mouse_filter = Control.MOUSE_FILTER_STOP
		modal.set_anchors_preset(Control.PRESET_FULL_RECT)
		modal.offset_left = 0.0
		modal.offset_top = 0.0
		modal.offset_right = 0.0
		modal.offset_bottom = 0.0

	var parent: Node = _resolve_or_create_ui_parent()
	parent.add_child(modal)

	_active_modal = modal
	if modal.has_signal("closed"):
		modal.connect("closed", Callable(self, "_on_modal_closed").bind(modal, parent))

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
			if vendor_body_scene != null:
				return vendor_body_scene.instantiate() as Control
		_:
			pass
	# Trainers: match any trainer_* kind
	if kind.begins_with("trainer"):
		if trainer_body_scene != null:
			return trainer_body_scene.instantiate() as Control
	return null

# ---------- Snapshot repaint ----------
func _on_village_snapshot_changed(snap: Dictionary) -> void:
	_repaint_current_scene(snap)
	emit_signal("snapshot_changed", snap)

func _repaint_current_scene(snap: Dictionary) -> void:
	var scene := get_tree().current_scene
	if scene == null:
		return
	if scene.has_method("apply_map_snapshot"):
		scene.call("apply_map_snapshot", snap)
	elif scene.has_method("reload_map_snapshot"):
		scene.call("reload_map_snapshot")

# ---------- Close / lifecycle ----------
func _on_modal_closed(modal: Control, parent: Node) -> void:
	if is_instance_valid(modal):
		modal.queue_free()
	var iid: StringName = modal.get("instance_id") if "instance_id" in modal else StringName("")
	_staffing_ui_cache.erase(String(iid))
	_active_modal = null
	_start_suppression()

	if parent is CanvasLayer and parent.name == AUTO_LAYER_NAME:
		var tree := get_tree()
		if tree != null:
			await tree.process_frame
			if is_instance_valid(parent) and parent.get_child_count() == 0:
				parent.queue_free()
		else:
			if is_instance_valid(parent):
				parent.queue_free()

func _close_active() -> void:
	if is_instance_valid(_active_modal):
		if _active_modal.has_method("close"):
			_active_modal.call_deferred("close")
		else:
			_active_modal.queue_free()
	_active_modal = null
	_start_suppression()

# ---------- Suppression / parent ----------
func _start_suppression() -> void:
	_suppress_until_frame = Engine.get_process_frames() + SUPPRESS_FRAMES
	_suppress_until_ms = Time.get_ticks_msec() + SUPPRESS_MS

func _resolve_or_create_ui_parent() -> Node:
	_ui_layer = get_node_or_null(ui_layer_path)
	if _ui_layer != null:
		return _ui_layer
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
		if n != null and n is VillageService:
			return n as VillageService
	var auto := get_tree().get_root().get_node_or_null("VillageService")
	if auto != null and auto is VillageService:
		return auto as VillageService
	var g: Array = get_tree().get_nodes_in_group("VillageService")
	if g.size() > 0 and g[0] is VillageService:
		return g[0] as VillageService
	return null

func _emit_fail(reason: String) -> void:
	emit_signal("action_failed", reason)

# ---------- Legacy ----------
func _open_legacy_alchemist(qr: Vector2i) -> void:
	var scene: PackedScene = alchemist_modal_scene
	if scene == null:
		return
	var inst_any: Node = scene.instantiate()
	if inst_any == null or not (inst_any is Control):
		return
	var modal := inst_any as Control
	if "tile_coord" in modal:
		modal.set("tile_coord", qr)
	if "modal_theme" in modal and modal_theme != null:
		modal.set("modal_theme", modal_theme)

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
		_emit_fail("VillageService not available"); return
	_log("on_assign_requested iid=%s npc=%s" % [String(instance_id), String(npc_id)])

	# Resolve required role (same as before)
	var role_required := ""
	if _village.has_method("get_building_staffing"):
		var st: Dictionary = _village.call("get_building_staffing", instance_id)
		role_required = String(st.get("role_required",""))
	if role_required == "":
		var kind := String(instance_id).get_slice("@", 0)
		match kind:
			"blacksmith":      role_required = "ARTISAN_BLACKSMITH"
			"alchemist_lab":   role_required = "ARTISAN_ALCHEMIST"
			"marketplace":     role_required = "INNKEEPER"
			_:
				if kind.begins_with("trainer"):
					role_required = "TRAINER_" + kind.replace("trainer_", "").to_upper()
				else:
					role_required = "INNKEEPER"

	var use_slot: int = _slot

	# NEW: ensure dict track (never int) before assigning
	# (Keeps SaveManager. ensure_role_level optional/unused here)
	const NPCXp := preload("res://scripts/village/services/NPCXpService.gd")
	NPCXp.ensure_role_track(npc_id, String(role_required), use_slot)

	_village.assign_staff(instance_id, npc_id)
	emit_signal("action_ok")

func _on_unassign_requested(instance_id: StringName) -> void:
	if _village == null:
		_emit_fail("VillageService not available"); return
	_log("on_unassign_requested iid=%s" % [String(instance_id)])
	_village.assign_staff(instance_id, StringName(""))
	_staffing_ui_cache[String(instance_id)] = StringName("")
	emit_signal("action_ok")
	_emit_refresh(instance_id)

func _on_upgrade_requested(instance_id: StringName) -> void:
	if _village == null:
		_emit_fail("VillageService not available"); return
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
	else:
		handled = false
	if handled: emit_signal("action_ok")
	_emit_refresh(instance_id)

func _on_vendor_sell(item_id: StringName, qty: int, rarity: String, instance_id: StringName) -> void:
	_log("vendor sell iid=%s item=%s qty=%d rarity=%s" % [String(instance_id), String(item_id), qty, rarity])
	var handled := false
	if _trade != null and _trade.has_method("sell"):
		var use_slot := _slot
		_trade.call("sell", String(item_id), qty, use_slot, rarity)
		handled = true
	else:
		handled = false
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
	var h := get_tile_header(instance_id)
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
	return {
		"display_name": "Alchemist Lab",
		"rarity": "COMMON",
		"connected": false,
		"active": false,
		"badges": [] as Array
	}

# ---------- Trainer helpers ----------
static func _is_trainer_kind(instance_id: StringName) -> bool:
	var k := String(instance_id).get_slice("@", 0)
	return k.begins_with("trainer")

# simple fantasy-name pools
const _FNAMES: PackedStringArray = [
	"Aela","Brann","Cael","Dorian","Eira","Fenn","Galen","Hale","Ilya","Jora",
	"Kael","Lyra","Mira","Neric","Orrin","Perrin","Quinn","Rhea","Selene","Tarin",
	"Ulric","Vela","Wren","Xara","Yara","Zev"
]
const _LNAMES: PackedStringArray = [
	"Blackbriar","Stormwatch","Ravensong","Dawnrunner","Ashenvale","Frostborn",
	"Oakenshield","Nightbloom","Silversky","Stonebrook","Ironvale","Mistwalker","Embershard"
]

static func _rand_name() -> String:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var fi: int = rng.randi_range(0, _FNAMES.size() - 1)
	var li: int = rng.randi_range(0, _LNAMES.size() - 1)
	var f: String = _FNAMES[fi]
	var l: String = _LNAMES[li]
	return "%s %s" % [f, l]

static func _gen_uid(n: int = 6) -> String:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var s := ""
	for i in range(n):
		var v := rng.randi_range(0, 15)
		s += "0123456789abcdef".substr(v, 1)
	return s

# ---------- Staffing ----------
func get_staffing(instance_id: StringName) -> Dictionary:
	var role_required: StringName = StringName("")
	var current_npc_id: StringName = _staffing_ui_cache.get(String(instance_id), StringName(""))

	# Preferred: ask VillageService
	if _village != null and _village.has_method("get_building_staffing"):
		var real: Dictionary = _village.call("get_building_staffing", instance_id)

		role_required = real.get("role_required", StringName(""))
		# keep UI's sticky selection, but fall back to service value if none cached
		current_npc_id = _staffing_ui_cache.get(
			String(instance_id),
			real.get("current_npc_id", StringName(""))
		)
		real["current_npc_id"] = current_npc_id

		# Build a UI roster that always includes the current assignee (if any),
		# then all candidates from the service (light rows), deduped by id.
		var r_any: Variant = real.get("roster", [])
		var roster_in: Array = (r_any as Array) if (r_any is Array) else []
		var out: Array[Dictionary] = []
		var seen := {}

		# 0) Ensure current NPC (if any) is first
		if String(current_npc_id) != "":
			var cur_id := String(current_npc_id)
			# Try to load full row from save for nice name/level
			for n_any in _village_npcs():
				if n_any is Dictionary and String((n_any as Dictionary).get("id","")) == cur_id:
					var n: Dictionary = n_any
					out.append({
						"id": StringName(cur_id),
						"name": String(n.get("name", cur_id)),
						"level": int(n.get("level", 1)),
						"role": String(n.get("role",""))
					})
					seen[cur_id] = true
					break
			# If not found, still add a minimal row
			if not seen.has(cur_id):
				out.append({ "id": current_npc_id, "name": String(current_npc_id), "level": 1, "role": "" })
				seen[cur_id] = true

		# 1) Append service-provided roster rows
		for row_any in roster_in:
			if not (row_any is Dictionary): continue
			var row: Dictionary = row_any
			var id_s := ""
			# accept either {id: ...} or {npc_id: ...}
			if row.has("id"): id_s = String(row.get("id",""))
			elif row.has("npc_id"): id_s = String(row.get("npc_id",""))
			if id_s == "" or seen.has(id_s): continue

			# If the row is "full" (has state/assigned_instance_id), apply eligibility filter.
			var has_full_fields := row.has("state") or row.has("assigned_instance_id")
			if has_full_fields:
				if not _npc_is_eligible_for_building(row, String(instance_id)): continue
				if not _npc_matches_role(row, String(role_required)): continue

			# Normalize to the light-row shape expected by the shell
			out.append({
				"id": StringName(id_s),
				"name": String(row.get("name", id_s)),
				"level": int(row.get("level", 1)),
				"role": String(row.get("role",""))
			})
			seen[id_s] = true

		# 2) If the service roster was empty, fall back to our filtered list
		if out.is_empty():
			out = _filtered_roster_for(String(instance_id), String(role_required), _slot)

		real["roster"] = out
		_log("staffing (village) role=%s roster=%d current=%s"
			% [String(role_required), out.size(), String(current_npc_id)])
		return real

	# --- No VillageService path: infer role and build filtered roster ---
	var kind := String(instance_id).get_slice("@", 0)
	if kind == "marketplace":
		role_required = StringName("ARTISAN_MERCHANT")
	elif kind == "blacksmith":
		role_required = StringName("ARTISAN_BLACKSMITH")
	elif kind == "alchemist_lab":
		role_required = StringName("ARTISAN_ALCHEMIST")
	elif kind.begins_with("trainer"):
		role_required = StringName("TRAINER_" + kind.replace("trainer_", "").to_upper())
	else:
		role_required = StringName("INNKEEPER")

	var roster_fb: Array[Dictionary] = _filtered_roster_for(String(instance_id), String(role_required), _slot)

	return {
		"role_required": role_required,
		"current_npc_id": current_npc_id,
		"roster": roster_fb
	}

# Build a neutral roster from all village NPCs and filter it down to:
# - NPCs not staffed anywhere, OR
# - the one currently staffed at this building (sticky).
func _build_unassigned_roster(instance_id: StringName) -> Array[Dictionary]:
	var iid := String(instance_id)

	# Pull full list (village → game fallback kept)
	var all := _village_npcs()

	# Filter using the same predicate as the main path
	var filtered: Array[Dictionary] = []
	for row_any in all:
		if row_any is Dictionary:
			var n: Dictionary = row_any
			if _npc_is_eligible_for_building(n, iid):
				filtered.append(n)

	# Convert to light rows the shell expects
	var out: Array[Dictionary] = []
	for n2 in filtered:
		var id_s := String(n2.get("id",""))
		if id_s == "":
			continue
		out.append({
			"id": StringName(id_s),
			"name": String(n2.get("name","")) if String(n2.get("name","")) != "" else id_s,
			"level": int(n2.get("level", 1)),
			"role": String(n2.get("role",""))
		})

	# Keep current selection sticky (helpful default in the dropdown)
	var cur: String = String(_staffing_ui_cache.get(iid, StringName("")))
	if cur != "":
		out.sort_custom(func(a, b):
			return int(String(a.get("id","")) != cur) - int(String(b.get("id","")) != cur)
		)

	_log("roster fallback -> villagers=%d (returning %d)" % [all.size(), out.size()])
	return out

func _village_npcs() -> Array:
	var use_slot := _slot
	# Primary: village save
	var v := SaveMgr.load_village(use_slot)
	var list_any: Variant = v.get("npcs", [])
	var list: Array = (list_any as Array) if (list_any is Array) else []
	if not list.is_empty():
		return list
	# Secondary: some builds store under game meta.village.npcs – try to be forgiving
	var g := SaveMgr.load_game(use_slot)
	var v_any: Variant = g.get("village", {})
	if v_any is Dictionary:
		var fallback_any: Variant = (v_any as Dictionary).get("npcs", [])
		if fallback_any is Array:
			return fallback_any as Array
	return []

# ---------- Vendor/trainer contexts ----------
func get_vendor_ctx(instance_id: StringName) -> Dictionary:
	if _trade != null:
		var stock: Array = []
		var sellables: Array = []
		var stash_gold: int = 0
		var active: bool = true

		if _trade.has_method("get_stock"):
			stock = _trade.call("get_stock", instance_id)

		if _trade.has_method("get_sellables_for"):
			var use_slot: int = _slot
			sellables = _trade.call("get_sellables_for", instance_id, use_slot)

			if _items != null:
				var fixed: Array[Dictionary] = []
				for v in (sellables if sellables is Array else []):
					if v is Dictionary:
						var d: Dictionary = v
						var id: StringName = StringName(String(d.get("id", "")))
						d["name"] = _display_name(id)
						fixed.append(d)
				sellables = fixed

		if _trade.has_method("get_stash_gold"):
			var use_slot2: int = _slot
			stash_gold = int(_trade.call("get_stash_gold", use_slot2))
		else:
			stash_gold = _meta_stash_gold()

		if _trade.has_method("is_vendor_active"):
			active = bool(_trade.call("is_vendor_active", instance_id))
		else:
			active = Vendors.is_active(instance_id, _slot)

		_log("vendor_ctx (trade) stock=%d sellables=%d gold=%d active=%s"
			% [ (stock as Array).size(), (sellables as Array).size(), stash_gold, str(active) ])

		return {
			"stock": (stock if stock is Array else []),
			"sellables": (sellables if sellables is Array else []),
			"stash_gold": stash_gold,
			"active": active
		}

	# Fallback (no TradeService)
	var use_slot_fb: int = _slot
	var offers: Array[Dictionary] = ShopResolver.build_buy_list(instance_id, use_slot_fb)
	var stock_fb: Array[Dictionary] = []
	for it in offers:
		var id_s: String = String(it.get("id",""))
		if id_s == "":
			continue
		var base: int = Econ.base_price(id_s)
		if base <= 0:
			continue
		stock_fb.append({
			"id": StringName(id_s),
			"name": String(it.get("name", id_s)),
			"rarity": String(it.get("rarity", "Common")),
			"price": int(round(float(base) * SHOP_FACTOR))
		})
	var sellables_fb: Array[Dictionary] = _meta_sellable_potions_list()
	var active_fb: bool = Vendors.is_active(instance_id, use_slot_fb)
	var stash_fb: int = _meta_stash_gold()

	_log("vendor_ctx (fallback) stock=%d sellables=%d gold=%d active=%s"
		% [stock_fb.size(), sellables_fb.size(), stash_fb, str(active_fb)])

	return { "stock": stock_fb, "sellables": sellables_fb, "stash_gold": stash_fb, "active": active_fb }
	
func get_training_ctx(instance_id: StringName) -> Dictionary:
	if _trainers == null:
		return {}

	# Read header to feed rarity + active/connected into TrainersService ctx
	var header := get_tile_header(instance_id)
	var kind   := String(header.get("id", String(instance_id).get_slice("@", 0)))
	var rarity := String(header.get("rarity", "COMMON"))
	var coord  := Vector2i.ZERO
	if _village != null and _village.has_method("get_building_instance"):
		var inst: Dictionary = _village.call("get_building_instance", instance_id)
		coord = Vector2i(int(inst.get("q", 0)), int(inst.get("r", 0)))

	# Inform TrainersService of the current modal rarity (drives cap calc)
	if _trainers.has_method("set_last_modal_rarity"):
		_trainers.call("set_last_modal_rarity", rarity)

	# Build ctx (same entry point used by shell refresh)
	if _trainers.has_method("refresh_for_tile"):
		return _trainers.call("refresh_for_tile", StringName(kind), instance_id, coord, _slot)
	if _trainers.has_method("open_for_tile"):
		return _trainers.call("open_for_tile", StringName(kind), instance_id, coord, _slot)

	return {}


func _display_name(id: StringName) -> String:
	return _items.get_display_name(id) if _items != null else String(id).capitalize().replace("_", " ")

func get_npc_snapshot(npc_id: StringName) -> Dictionary:
	if _npc != null:
		return _npc.get_npc_snapshot(npc_id)
	return { "name": "—", "level": 1, "xp": 0, "xp_next": 1 }

func get_upgrade_info(instance_id: StringName) -> Dictionary:
	if _village != null and _village.has_method("get_upgrade_info"):
		return _village.call("get_upgrade_info", instance_id)

	var header: Dictionary = get_tile_header(instance_id)
	var staffing: Dictionary = get_staffing(instance_id)
	var connected: bool = bool(header.get("connected", false))
	var staffed: bool = String(staffing.get("current_npc_id", "")) != ""

	# Trainers are treated as active when connected (temporary policy)
	var active_tmp: bool = bool(header.get("active", false))
	if _is_trainer_kind(instance_id) and connected:
		active_tmp = true

	var reasons: Array[String] = []
	if not connected: reasons.append("Not connected to camp.")
	if not staffed:   reasons.append("No staff assigned.")

	return {
		"current_rarity": String(header.get("rarity", "COMMON")),
		"upgrade_requirements": { "gold": 100, "shards": 2, "quest_gate": "" },
		"disabled": reasons.size() > 0,
		"reasons": reasons
	}

# ---------- Event bridges ----------
func _on_activation_changed(p_instance_id: StringName, p_active: bool) -> void:
	_log("activation_changed iid=%s active=%s" % [String(p_instance_id), str(p_active)])
	_try_refresh_active_modal(p_instance_id)

func _on_npc_assigned(p_instance_id: StringName, p_npc_id: StringName) -> void:
	_log("npc_assigned iid=%s npc=%s" % [String(p_instance_id), String(p_npc_id)])
	_try_refresh_active_modal(p_instance_id)

func _on_building_upgraded(p_instance_id: StringName, p_rarity: StringName) -> void:
	_log("building_upgraded iid=%s rarity=%s" % [String(p_instance_id), String(p_rarity)])
	_try_refresh_active_modal(p_instance_id)

func _on_vendor_stock_changed(p_instance_id: StringName) -> void:
	_log("vendor_stock_changed iid=%s" % [String(p_instance_id)])
	_try_refresh_active_modal(p_instance_id)

func _on_stash_gold_changed(p_slot: int) -> void:
	_log("stash_gold_changed slot=%d" % p_slot)
	if _active_modal == null:
		return
	var modal_slot: int = int(_active_modal.get("slot") if "slot" in _active_modal else -1)
	if modal_slot == p_slot and _active_modal.has_method("refresh_all"):
		_active_modal.call("refresh_all")

func _try_refresh_active_modal(target_iid: StringName) -> void:
	if _active_modal == null:
		return
	if not _active_modal.has_method("refresh_all"):
		return
	var iid: StringName = _active_modal.get("instance_id") if "instance_id" in _active_modal else StringName("")
	if String(iid) == "" or iid != target_iid:
		return
	_active_modal.call("refresh_all")

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
	if d.has("durability_max"):
		return int(d.get("durability_max", 0))
	if d.has("opts") and d["opts"] is Dictionary:
		return int((d["opts"] as Dictionary).get("durability_max", 0))
	return 0

static func _count_or_1(d: Dictionary) -> int:
	if d.has("count"):
		return int(d.get("count", 1))
	if d.has("opts") and d["opts"] is Dictionary:
		return int((d["opts"] as Dictionary).get("count", 1))
	return 1

func _meta_sellable_potions_list() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var counts: Dictionary = {}  # "id|rarity" -> int

	for v in _meta_inventory():
		if not (v is Dictionary):
			continue
		var d: Dictionary = v
		var id: String = String(d.get("id", ""))
		if id == "" or _dura_max(d) != 0:
			continue
		if not Econ.is_potion_id(id):
			continue

		var rarity_text := "Common"
		var opts_any: Variant = d.get("opts", {})
		if (opts_any is Dictionary):
			var rraw := String((opts_any as Dictionary).get("rarity", ""))
			if rraw != "":
				rarity_text = Econ._rarity_full(rraw)

		var key := id + "|" + rarity_text
		counts[key] = int(counts.get(key, 0)) + _count_or_1(d)

	for key in counts.keys():
		var parts: PackedStringArray = String(key).split("|")
		var id2: String = parts[0]
		var rarity_text: String = parts[1] if parts.size() > 1 else "Common"
		var owned: int = int(counts[key])
		var unit: int = Econ.sell_price_vendor(id2, rarity_text)

		out.append({
			"id": StringName(id2),
			"name": _display_name(StringName(id2)) + " [" + rarity_text + "]",
			"rarity": rarity_text,
			"price": unit,
			"count": owned
		})

	return out

# Returns true if this NPC should be eligible for the assign dropdown at iid
static func _npc_is_eligible_for_building(n: Dictionary, iid: String) -> bool:
	var state := String(n.get("state", "IDLE"))
	var assigned := String(n.get("assigned_instance_id", ""))
	# Eligible if not currently staffed anywhere, OR staffed here.
	return (state != "STAFFED") or (assigned == iid)

# Optional role check: if npc has a role set, it must match the building role
static func _npc_matches_role(n: Dictionary, role: String) -> bool:
	if role == "":
		return true
	var npc_role := String(n.get("role", ""))
	# Allow empty npc_role so you can hire generalists, but if set, it must match
	return (npc_role == "") or (npc_role == role)

# Build the roster (only unstaffed + currently staffed-here)
func _filtered_roster_for(iid: String, role: String, slot: int) -> Array[Dictionary]:
	var vs := SaveMgr.load_village(slot)
	var npcs_any: Variant = vs.get("npcs", [])
	var roster: Array[Dictionary] = []

	if npcs_any is Array:
		for row in (npcs_any as Array):
			if row is Dictionary:
				var n: Dictionary = row
				if _npc_is_eligible_for_building(n, iid) and _npc_matches_role(n, role):
					# convert to the light row shape expected by shells
					var id_s := String(n.get("id",""))
					if id_s == "":
						continue
					roster.append({
						"id": StringName(id_s),
						"name": String(n.get("name","")) if String(n.get("name","")) != "" else id_s,
						"level": int(n.get("level", 1)),
						"role": String(n.get("role",""))
					})

	return roster

func _resolve_trainers() -> TrainersService:
	if trainers_service_path != NodePath():
		var n := get_node_or_null(trainers_service_path)
		if n != null and n is TrainersService:
			return n as TrainersService
	var auto := get_tree().get_root().get_node_or_null("TrainersService")
	if auto != null and auto is TrainersService:
		return auto as TrainersService
	# Fallback: spawn a private service node so editor scenes still work
	var inst := TrainersService.new()
	inst.name = "TrainersService(_local)"
	add_child(inst)
	return inst

func get_assigned_role_snapshot(instance_id: StringName) -> Dictionary:
	var now_min: float = float(SaveMgr.load_game(_slot).get("time_passed_min", 0.0))
	return NPCXp.settle_for_instance(instance_id, now_min, _slot)  # { role, level, xp } or {}
