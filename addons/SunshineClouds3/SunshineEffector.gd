@tool
extends Node3D
class_name SunshineEffector

## A sphere that adds (or removes) cloud coverage in every layer it reaches, within the layers' own shapes. Listed
## among a [SunshineClouds3Driver]'s effectors, its radius, strength and falloff replace the driver's
## [CloudEffectorSettings]. Its largest scale scales its radius. The plugin draws its sphere in the editor.

## How far it reaches (m), before its scale.
@export_range(0.0, 100000.0, 1.0, "or_greater", "suffix:m") var radius : float = 1000.0:
	set(value):
		radius = value
		update_gizmos()

## Coverage added at its centre: 1 fills the layers, -1 clears them. Beyond either extends that toward the edge.
@export_range(-1.0, 1.0, 0.01, "or_greater", "or_less") var strength : float = 1.0:
	set(value):
		strength = value
		update_gizmos()

## How much of the radius it fades out over, from its edge in: 0 = a hard edge, 1 = from the centre.
@export_range(0.0, 1.0, 0.01) var falloff : float = 0.5:
	set(value):
		falloff = value
		update_gizmos()


func _ready() -> void:
	if Engine.is_editor_hint():
		# Loaded by path so the editor-only setup script (it uses editor interfaces) never ends up in an exported build.
		Callable(load("res://addons/SunshineClouds3/Resources/SunshineClouds3EditorSetup.gd"), &"connect_to_driver").call_deferred(self)
