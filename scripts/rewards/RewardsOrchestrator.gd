# res://scripts/rewards/RewardsOrchestrator.gd
extends Node

# Try to set in Inspector, but we also hard-fallback to DEFAULT_MODAL_PATH.
@export var rewards_modal_scene: PackedScene
const DEFAULT_MODAL_PATH := "res://scenes/RewardsModal.tscn"

var _ui_layer: CanvasLayer = null
var _modal: Control = null

func _ready() -> void:
	print("[RewardsOrchestrator] ready scene_set=", rewards_modal_scene != null)
	# Allow this autoload to receive input even when nothing else handles it.
	set_process_unhandled_input(true)
	process_mode = Node.PROCESS_MODE_ALWAYS

func _rs_reload(slot: int = SaveManager.DEFAULT_SLOT) -> void:
	var rs := get_node_or_null(^"/root/RunState")
	if rs and rs.has_method("reload"):
		rs.call("reload", slot)

func grant_from_loot(loot: Dictionary) -> void:
	var items: Array[Dictionary] = ItemResolver.resolve(loot)
	var gold: int = int(loot.get("gold", 0))
	var shards: int = int(loot.get("shards", 0))

	var rewards: Dictionary = {
		"gold": gold,
		"shards": shards,
		"items": items
	}

	var receipt: Dictionary = RewardService.grant(rewards, SaveManager.DEFAULT_SLOT)
	# ⇣ Run JSON just changed (gold/shards) → refresh mirrors
	_rs_reload(SaveManager.DEFAULT_SLOT)

	print("[RewardsOrchestrator] grant_from_loot source=%s gold=%d shards=%d rarity=%s cat=%s"
		% [String(loot.get("source","")), gold, shards, String(loot.get("rarity","")), String(loot.get("category",""))])

	_mirror_items_to_run(items, SaveManager.DEFAULT_SLOT) # will also _rs_reload() at the end
	_present_modal(_receipt_to_modal(receipt))

func _ensure_modal() -> void:
	if rewards_modal_scene == null:
		var ps := load(DEFAULT_MODAL_PATH)
		if ps is PackedScene:
			rewards_modal_scene = ps
			print("[RewardsOrchestrator] fallback-loaded modal scene from ", DEFAULT_MODAL_PATH)
		else:
			push_error("RewardsOrchestrator: cannot load RewardsModal at %s" % DEFAULT_MODAL_PATH)
			return

	if _ui_layer == null:
		_ui_layer = CanvasLayer.new()
		_ui_layer.layer = 500
		_ui_layer.name = "RewardsUILayer"
		get_tree().root.add_child(_ui_layer)

	if _modal == null:
		_modal = rewards_modal_scene.instantiate()
		if _modal == null:
			push_error("RewardsOrchestrator: instantiate() failed.")
			return
		_modal.top_level = true
		if _modal is Control:
			(_modal as Control).set_anchors_preset(Control.PRESET_FULL_RECT)
		_ui_layer.add_child(_modal)
		print("[RewardsOrchestrator] modal instantiated and added to layer=", _ui_layer.layer)

func _present_modal(data: Dictionary) -> void:
	_ensure_modal()
	if _modal == null:
		push_warning("RewardsOrchestrator: no modal; skipping UI.")
		return
	if _modal.has_method("present"):
		_modal.call("present", data)
	else:
		push_warning("RewardsOrchestrator: modal has no present(Dictionary).")

func _receipt_to_modal(receipt: Dictionary) -> Dictionary:
	var items_in: Array = (receipt.get("items", []) as Array)
	var items_out: Array = []
	for it_any in items_in:
		if it_any is Dictionary:
			var it: Dictionary = it_any
			var id_str := String(it.get("id",""))
			it["name"] = ItemNames.display_name(id_str)
			items_out.append(it)

	return {
		"gold": int(receipt.get("gold", 0)),
		"shards": int(receipt.get("shards", 0)),
		"hp": int(receipt.get("hp", 0)),
		"mp": int(receipt.get("mp", 0)),
		"items": items_out,
		"skill_xp": (receipt.get("skill_xp", []) as Array)
	}

func _mirror_items_to_run(items: Array[Dictionary], slot: int) -> void:
	if items.is_empty():
		return

	var rs: Dictionary = SaveManager.load_run(slot)
	var inv_any: Variant = rs.get("inventory", [])
	var inv: Array = (inv_any as Array) if inv_any is Array else []
	var added_total: int = 0

	for it_any: Variant in items:
		if typeof(it_any) != TYPE_DICTIONARY:
			continue
		var it: Dictionary = it_any as Dictionary
		var id_str: String = String(it.get("id",""))
		if id_str.is_empty():
			continue

		var dmax: int = int(it.get("durability_max", 0))
		if dmax > 0:
			var row_gear: Dictionary = {
				"id": id_str,
				"count": 1,
				"ilvl": int(it.get("ilvl", 1)),
				"archetype": String(it.get("archetype", "")),
				"rarity": String(it.get("rarity", "Common")),
				"affixes": (it.get("affixes", []) as Array),
				"durability_max": dmax,
				"durability_current": int(it.get("durability_current", dmax)),
				"weight": float(it.get("weight", 0.0)),
				"uid": String(it.get("uid",""))
			}
			inv.append(row_gear)
			added_total += 1
			print("[RewardsOrchestrator] mirrored GEAR %s (uid=%s ilvl=%d rarity=%s)"
				% [id_str, String(row_gear.get("uid","")), int(row_gear.get("ilvl",1)), String(row_gear.get("rarity",""))])
			continue

		var cnt: int = max(1, int(it.get("count", 1)))
		var opts_any: Variant = it.get("opts", {})
		var opts: Dictionary = (opts_any as Dictionary) if opts_any is Dictionary else {}
		var ilvl: int = int(opts.get("ilvl", 1))
		var arche: String = String(opts.get("archetype", "Consumable"))
		var rarity: String = String(opts.get("rarity", "Common"))
		var affixes_any: Variant = opts.get("affixes", [])
		var affixes: Array = (affixes_any as Array) if affixes_any is Array else []
		var weight: float = float(opts.get("weight", 0.0))

		var merged: bool = false
		for i in inv.size():
			var e_any: Variant = inv[i]
			if typeof(e_any) != TYPE_DICTIONARY:
				continue
			var e: Dictionary = e_any as Dictionary
			if int(e.get("durability_max", 0)) != 0:
				continue
			if String(e.get("id","")) != id_str: continue
			if int(e.get("ilvl", 1)) != ilvl: continue
			if String(e.get("archetype","")) != arche: continue
			if String(e.get("rarity","")) != rarity: continue

			var ea_any: Variant = e.get("affixes", [])
			var ea: Array = (ea_any as Array) if ea_any is Array else []
			if ea.size() != affixes.size():
				continue
			var all_match: bool = true
			for j in affixes.size():
				if String(ea[j]) != String(affixes[j]):
					all_match = false
					break
			if not all_match:
				continue

			var new_e: Dictionary = e.duplicate()
			new_e["count"] = int(e.get("count", 1)) + cnt
			inv[i] = new_e
			merged = true
			break

		if not merged:
			var row_stack: Dictionary = {
				"id": id_str,
				"count": cnt,
				"ilvl": ilvl,
				"archetype": arche,
				"rarity": rarity,
				"affixes": affixes,
				"durability_max": 0,
				"durability_current": 0,
				"weight": weight
			}
			inv.append(row_stack)

		added_total += cnt

	rs["inventory"] = inv
	SaveManager.save_run(rs, slot)
	print("[RewardsOrchestrator] mirrored %d item(s) into RUN (inv.size=%d)" % [added_total, inv.size()])

	# ⇣ inventory changed → refresh mirrors
	_rs_reload(slot)

func _gen_uid() -> String:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var a := int(Time.get_ticks_usec()) & 0x7FFFFFFF
	var b := int(rng.randi() & 0x7FFFFFFF)
	return "ru%08x%08x" % [a, b]

# Debug: force a gear grant (one weapon) to verify persistence & UI
func debug_grant_gear(kind: String = "weapon", rarity_letter: String = "U") -> void:
	var ilvl: int = SaveManager.get_current_floor(SaveManager.DEFAULT_SLOT)
	var rarity_name := ItemResolver._rarity_name_for_letter(rarity_letter)
	var gear_row: Dictionary
	match kind:
		"weapon":
			gear_row = GearGen.make_weapon(ilvl, rarity_name, ItemResolver._pick_weapon_family(ilvl))
		"armor":
			gear_row = GearGen.make_armor(ilvl, rarity_name, ItemResolver._pick_armor_archetype(ilvl))
		"accessory":
			gear_row = GearGen.make_accessory(ilvl, rarity_name, "ring")
		_:
			return
	var receipt := RewardService.grant({"gold":0, "items":[gear_row]}, SaveManager.DEFAULT_SLOT)
	_mirror_items_to_run([gear_row], SaveManager.DEFAULT_SLOT)
	_present_modal(_receipt_to_modal(receipt))
	print("[RewardsOrchestrator][DEBUG] forced %s -> %s" % [kind, str(gear_row)])

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("debug_spawn_gear"):
		debug_grant_gear("weapon", "U")
		
