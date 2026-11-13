@tool
extends Resource
class_name CloudDirectionalLightSettings
## How one of a [SunshineClouds3Driver]'s directional lights lights the clouds.

## The colour the clouds and atmosphere are lit with, in place of the light's own (which the driver may drive).
@export var color : Color = Color.WHITE:
	set(value):
		color = value
		emit_changed()
## Scales light_energy * light_volumetric_fog_energy on the clouds and atmosphere (sky, glow, disc) only.
@export_range(0.0, 16.0, 0.01, "or_greater") var energy_multiplier : float = 1.0:
	set(value):
		energy_multiplier = value
		emit_changed()
## Whether this light can cast the cloud shadows (the strongest one that can does).
@export var cast_cloud_shadows : bool = true:
	set(value):
		cast_cloud_shadows = value
		emit_changed()
## Samples toward the light per cloud sample, for the clouds' self-shadowing. 0 = none (lit through).
@export_range(0, 16) var shadow_samples : int = 4:
	set(value):
		shadow_samples = value
		emit_changed()
## Sets the light's colour to color times what's left after the atmosphere at camera height (white balanced at
## zenith), so the scene reddens and dims with the clouds toward the horizon. Once black (set below the horizon) the
## driver hides the light and its children to save its cost (shadow maps above all) until it rises; the clouds and
## atmosphere still count it, for twilight. Shown by hand while down, it stays shown until it rises and sets again.
## Doesn't account for a spherical planet; disable it when that setting is used.
@export var drive_light_color : bool = true:
	set(value):
		drive_light_color = value
		emit_changed()
