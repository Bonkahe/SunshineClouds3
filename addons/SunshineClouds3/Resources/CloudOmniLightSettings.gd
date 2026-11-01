@tool
extends Resource
class_name CloudOmniLightSettings
## How one of a [SunshineClouds3Driver]'s omni lights lights the clouds: with its own colour and
## light_energy * light_volumetric_fog_energy, falling off as Godot's omni lights do. A
## [SunshineOmniLight] has these on itself, used in place of these.

## Scales this light's energy (light_energy * light_volumetric_fog_energy) on the clouds only; its
## light on the world is unchanged.
@export_range(0.0, 16.0, 0.01, "or_greater") var energy_multiplier : float = 1.0:
	set(value):
		energy_multiplier = value
		emit_changed()
## Samples through the clouds towards the light per cloud sample, for the clouds' shadowing of
## themselves. 0 = none (lit through).
@export_range(0, 16) var shadow_samples : int = 4:
	set(value):
		shadow_samples = value
		emit_changed()
