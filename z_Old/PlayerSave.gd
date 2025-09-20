# res://save/PlayerSave.gd
extends Resource
class_name PlayerSave

@export var position: Vector3 = Vector3.ZERO
@export var health: int = 100
@export var inventory: Array[ItemStack] = []   # ✅ typed and initialized
