extends Label
class_name SigilHUD

@export var prefix: String = "Sigil"
@onready var SaveManagerInst: SaveManager = get_node("/root/SaveManager") as SaveManager

func _process(_dt: float) -> void:
	var rs: RunSave = SaveManagerInst.load_run()
	var status: String = "—"
	if rs.sigils_charged:
		status = "CHARGED"
	text = "%s  seg:%d  %d/%d  %s" % [
		prefix, rs.sigils_segment_id,
		rs.sigils_elites_killed_in_segment, rs.sigils_required_elites,
		status
	]
