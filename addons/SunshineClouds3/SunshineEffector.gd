@tool
extends Node3D
class_name SunshineEffector

## A cloud effector with its settings on itself: listed among a [SunshineClouds3Driver]'s effectors,
## its radius, strength and falloff are used in place of the driver's [CloudEffectorSettings] for it.
## A sphere around it that adds coverage to every layer it reaches (or takes it away), so clouds
## grow or clear there within the layers' own shapes. Its largest scale scales its radius, as any
## effector's does. The SunshineClouds3 plugin draws its sphere in the editor.

## How far it reaches (m), before its scale.
@export_range(0.0, 100000.0, 1.0, "or_greater", "suffix:m") var radius : float = 1000.0:
	set(value):
		radius = value
		update_gizmos()

## Coverage added at its centre: 1 fills the layers, -1 clears them. Beyond either holds that out
## further towards the edge.
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
		# Basically this is a workaround to ensure this script is never pulled into a actual build as it uses editor interfaces.
		Callable(load("res://addons/SunshineClouds3/Resources/SunshineClouds3EditorSetup.gd"), &"connect_to_driver").call_deferred(self)
