extends Node
class_name EnterLabyrinth

## Minimal, side-effect-aware entry point.
static func enter(floor: int, main_scene: PackedScene) -> void:
	assert(main_scene != null)
	SaveManager.start_or_refresh_run_from_meta()
	SaveManager.set_run_floor(floor)

	var BS: GDScript = preload("res://persistence/services/buff_service.gd")
	BS.on_run_start()

	if Engine.get_main_loop() is SceneTree:
		var tree: SceneTree = Engine.get_main_loop() as SceneTree
		if tree.paused:
			tree.paused = false
		tree.change_scene_to_packed(main_scene)
