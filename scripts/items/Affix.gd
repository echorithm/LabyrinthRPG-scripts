# res://scripts/items/Affix.gd
class_name Affix
extends RefCounted

var id: String
var effect_type: String
var value: float
var quality: float = 1.0
var units: String = ""
var params: Dictionary = {}
