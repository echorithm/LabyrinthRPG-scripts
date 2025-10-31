extends CanvasLayer
class_name ScreenFX

@onready var flash_rect: ColorRect = %FlashRect

func flash_red(alpha: float = 0.08, dur: float = 0.15) -> void:
	if flash_rect == null:
		return
	flash_rect.modulate = Color(1, 0, 0, alpha)
	flash_rect.visible = true
	var tw := create_tween().set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tw.tween_property(flash_rect, ^"modulate:a", 0.0, dur)
	tw.tween_callback(Callable(self, "_hide_flash"))

func _hide_flash() -> void:
	flash_rect.visible = false
