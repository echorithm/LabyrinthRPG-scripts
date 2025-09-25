extends Control
class_name BattleHUD

var _player_hp_label: Label
var _monster_hp_label: Label

func _ready() -> void:
	set_anchors_preset(Control.PRESET_TOP_WIDE)
	custom_minimum_size = Vector2(0, 64)

	_player_hp_label = Label.new()
	_player_hp_label.name = "PlayerHP"
	_player_hp_label.text = "Player HP: --/--"
	_player_hp_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	add_child(_player_hp_label)

	_monster_hp_label = Label.new()
	_monster_hp_label.name = "MonsterHP"
	_monster_hp_label.text = "Enemy HP: --/--"
	_monster_hp_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_monster_hp_label.anchor_left = 1.0
	_monster_hp_label.anchor_right = 1.0
	_monster_hp_label.offset_right = -8
	_monster_hp_label.offset_left = -320
	add_child(_monster_hp_label)

func set_snapshot(snapshot: Dictionary) -> void:
	var p_any: Variant = snapshot.get("player", {})
	var m_any: Variant = snapshot.get("monster", {})

	var p: Dictionary = p_any as Dictionary
	var m: Dictionary = m_any as Dictionary

	var php: int = int(p.get("hp", 0) if p != null else 0)
	var phm: int = int(p.get("hp_max", 0) if p != null else 0)
	var mhp: int = int(m.get("hp", 0) if m != null else 0)
	var mhm: int = int(m.get("hp_max", 0) if m != null else 0)

	_player_hp_label.text = "Player HP: %d/%d" % [php, phm]
	_monster_hp_label.text = "Enemy HP: %d/%d" % [mhp, mhm]

	print("[HUD] snapshot P=%d/%d M=%d/%d" % [php, phm, mhp, mhm])
