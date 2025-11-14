extends "res://ui/hud/GameMenu.gd"

# Where the village's menu should return.
const TARGET_MENU_SCENE: String = "res://ui/menu/MainMenu.tscn"

@export var edge_padding_px: int = 32
@export var min_button_px: Vector2 = Vector2(120.0, 120.0)

func _ready() -> void:
	# Call base setup (wires text, items, etc.)
	super._ready()
	_apply_mobile_defaults()

func _apply_mobile_defaults() -> void:
	# Bigger tap target on Android
	custom_minimum_size = min_button_px

	# Move away from the absolute edge if not in a Container
	var parent_node: Node = get_parent()
	if not (parent_node is Container):
		anchor_left = 1.0
		anchor_right = 1.0
		anchor_top = 0.0
		anchor_bottom = 0.0

		offset_right = -edge_padding_px
		offset_left = -edge_padding_px - min_button_px.x
		offset_top = edge_padding_px
		offset_bottom = edge_padding_px + min_button_px.y

	# Game is Android-only → just use the mobile font size everywhere
	add_theme_font_size_override("font_size", mobile_font_size)

# Override the base quit handler to skip ExitSafelyFlow entirely.
func _do_quit_to_menu() -> void:
	var tree: SceneTree = get_tree()
	tree.paused = false
	tree.change_scene_to_file(TARGET_MENU_SCENE)

# (Optional safety) If you use the Gesture Test, make its fallback return path the main menu.
func _open_gesture_test() -> void:
	var tree: SceneTree = get_tree()
	var cur: Node = tree.current_scene
	var return_path: String = ""
	if is_instance_valid(cur):
		return_path = cur.scene_file_path
	if return_path.is_empty():
		return_path = TARGET_MENU_SCENE
	tree.set_meta("return_scene_path", return_path)
	tree.paused = false
	tree.change_scene_to_file(GESTURE_TEST_SCENE)
