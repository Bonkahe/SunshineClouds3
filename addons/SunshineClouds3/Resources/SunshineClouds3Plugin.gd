@tool
extends EditorPlugin

const ADD_TO_SCENE := "Add Sunshine Clouds to Scene"

var driver_inspector : EditorInspectorPlugin
var clouds_gizmo : EditorNode3DGizmoPlugin


func _enter_tree() -> void:
	driver_inspector = preload("res://addons/SunshineClouds3/Resources/SunshineClouds3DriverInspector.gd").new(get_undo_redo())
	add_inspector_plugin(driver_inspector)
	clouds_gizmo = preload("res://addons/SunshineClouds3/Resources/SunshineCloudsGizmo.gd").new(get_undo_redo())
	add_node_3d_gizmo_plugin(clouds_gizmo)
	add_tool_menu_item(ADD_TO_SCENE, Callable(preload("res://addons/SunshineClouds3/Resources/SunshineClouds3EditorSetup.gd"), &"add_to_scene")) # Editor setup script whose static add_to_scene() builds the clouds stack in the open scene.


func _exit_tree() -> void:
	remove_inspector_plugin(driver_inspector)
	driver_inspector = null
	remove_node_3d_gizmo_plugin(clouds_gizmo)
	clouds_gizmo = null
	remove_tool_menu_item(ADD_TO_SCENE)
