@tool
extends Resource
class_name CloudEffectorSettings
## How one of a [SunshineClouds3Driver]'s effectors (any Node3D) changes the clouds: a sphere that adds (or removes)
## coverage in every layer it reaches, within the layers' own shapes. A [SunshineEffector] uses its own instead.

## How far it reaches (m), times the effector's largest scale.
@export_range(0.0, 100000.0, 1.0, "or_greater", "suffix:m") var radius : float = 1000.0:
	set(value):
		radius = value
		emit_changed()
## Coverage added at its centre: 1 fills the layers, -1 clears them. Beyond either extends that toward the edge.
@export_range(-1.0, 1.0, 0.01, "or_greater", "or_less") var strength : float = 1.0:
	set(value):
		strength = value
		emit_changed()
## How much of the radius it fades out over, from its edge in: 0 = a hard edge, 1 = from the centre.
@export_range(0.0, 1.0, 0.01) var falloff : float = 0.5:
	set(value):
		falloff = value
		emit_changed()
