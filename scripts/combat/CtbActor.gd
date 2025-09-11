# File: res://scripts/combat/CtbActor.gd
# Godot 4.4.1 — Typed CTB actor

class_name CtbActor
extends RefCounted

var id: StringName
var name: String
var speed: int
var next_turn_at: int

var hp: int
var hp_max: int
var guard: bool = false

func _init(id_in: StringName, name_in: String, speed_in: int, hp_max_in: int, next_turn_at_in: int = 0) -> void:
	id = id_in
	name = name_in
	speed = speed_in
	hp_max = hp_max_in
	hp = hp_max_in
	next_turn_at = next_turn_at_in
