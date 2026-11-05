@tool
extends Resource
class_name CloudDirectionalLightSettings
## How one of a [SunshineClouds3Driver]'s directional lights lights the clouds.

## The colour the clouds and the atmosphere are lit with, in place of the light's own (which the
## driver may drive from the atmosphere).
@export var color : Color = Color.WHITE:
	set(value):
		color = value
		emit_changed()
## Scales this light's energy (light_energy * light_volumetric_fog_energy) on the clouds and the
## atmosphere (its sky, glow and disc); its light on the world is unchanged.
@export_range(0.0, 16.0, 0.01, "or_greater") var energy_multiplier : float = 1.0:
	set(value):
		energy_multiplier = value
		emit_changed()
## Whether this light can cast the cloud shadows (the strongest one that can does).
@export var cast_cloud_shadows : bool = true:
	set(value):
		cast_cloud_shadows = value
		emit_changed()
## Samples through the clouds towards the light per cloud sample, for the clouds' shadowing of
## themselves. 0 = none (lit through).
@export_range(0, 16) var shadow_samples : int = 4:
	set(value):
		shadow_samples = value
		emit_changed()
## Sets the light's own colour to what's left of it after the atmosphere at the camera's height
## (white balanced against it straight overhead) times color, so the scene reddens and dims with
## the clouds towards the horizon. Once that's black (its disc has set) the driver hides the light
## (visible off, which also hides its children), saving its cost in the scene (its shadow maps
## above all), and shows it again when it rises; the clouds and the atmosphere still count it, for
## the twilight. Showing it yourself while it's down keeps it shown until it has risen and set again.
## Be aware, this does not respect a spherical planet, it is recommended you disable this if that setting is being used.
@export var drive_light_color : bool = true:
	set(value):
		drive_light_color = value
		emit_changed()
