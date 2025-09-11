# File: res://scripts/data/EnemyDef.gd
# Enemy defined by IDs + weights (no subresources).
class_name EnemyDef
extends Resource

@export var id: StringName = &"skeleton"
@export var display_name: String = "Skeleton"
@export var base_stats: Stats

@export var intent_ids: Array[StringName] = []             # e.g., ["swipe","guard","chomp","nibble"]
@export var intent_weights: PackedInt32Array = PackedInt32Array()  # e.g., [50,25,20,5]
