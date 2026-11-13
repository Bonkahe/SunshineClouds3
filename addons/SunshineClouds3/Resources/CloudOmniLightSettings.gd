@tool
extends Resource
class_name CloudOmniLightSettings
## How one of a [SunshineClouds3Driver]'s omni lights lights the clouds (its own colour and energy, Godot's omni
## falloff). A [SunshineOmniLight] uses its own instead.

## Scales light_energy * light_volumetric_fog_energy on the clouds only.
@export_range(0.0, 16.0, 0.01, "or_greater") var energy_multiplier : float = 1.0:
	set(value):
		energy_multiplier = value
		emit_changed()
## Samples toward the light per cloud sample, for the clouds' self-shadowing. 0 = none (lit through).
@export_range(0, 16) var shadow_samples : int = 4:
	set(value):
		shadow_samples = value
		emit_changed()
