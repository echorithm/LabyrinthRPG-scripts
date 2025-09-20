# TorchDirector.gd
extends Node

@export var groups_total: int = 4
@export var enabled_groups: PackedInt32Array = [0]   # e.g. show only group 0 by default
@export var torch_group_count: int = 4

const ROOT_GROUP := "torch_all"      # every controllable torch holder joins this
const GROUP_FMT  := "torch_group_%d" # each holder also joins exactly one of these

func _ready() -> void:
	_apply()

func set_enabled_group(g: int) -> void:
	enabled_groups = [g]
	_apply()

func set_enabled_groups(gs: PackedInt32Array) -> void:
	enabled_groups = gs.duplicate()
	_apply()

func _apply() -> void:
	# 1) turn **everything** off
	for n in get_tree().get_nodes_in_group(ROOT_GROUP):
		_toggle_holder(n, false)

	# 2) turn the chosen groups on
	for g in enabled_groups:
		for n in get_tree().get_nodes_in_group(GROUP_FMT % g):
			_toggle_holder(n, true)

func _toggle_holder(holder: Node, on: bool) -> void:
	# Show/hide the torch holder (mesh)
	if holder is VisualInstance3D:
		(holder as VisualInstance3D).visible = on
	elif holder.has_method("set_visible"):
		holder.call("set_visible", on)

	# Find ALL OmniLight3D descendants and toggle them safely.
	var lights := holder.find_children("*", "OmniLight3D", true, true)
	for ln in lights:
		var l := ln as OmniLight3D
		if l == null: continue

		# If a flicker script exposes set_enabled(), prefer that.
		if l.has_method("set_enabled"):
			l.call_deferred("set_enabled", on)
		else:
			# Fallback: stash/restore energy via metadata.
			if on:
				var base: float = l.light_energy
				if l.has_meta("base_energy"):
					base = float(l.get_meta("base_energy"))
				l.light_energy = base
			else:
				if not l.has_meta("base_energy"):
					l.set_meta("base_energy", l.light_energy)
				l.light_energy = 0.0

		l.visible = on
		l.set_process(on) # silences any _process() (e.g., flicker scripts) when off
		
func use_group(group_id: int) -> void:
	print("[TorchDirector] enabling torch_group_", group_id, " and disabling others")
	for i in range(torch_group_count):
		var name := "torch_group_%d" % i
		var enable := (i == group_id)
		var list := get_tree().get_nodes_in_group(name)
		print("  group ", name, " count=", list.size(), " -> ", enable)
		for n in list:
			var root := n as Node3D
			var l := root.get_node_or_null("OmniLight3D") as OmniLight3D
			if l and l.has_method("set_enabled"):
				l.call("set_enabled", enable)
			root.visible = enable
