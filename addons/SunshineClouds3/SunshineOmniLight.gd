@tool
extends OmniLight3D
class_name SunshineOmniLight
## An omni light with its cloud settings on itself: listed among a [SunshineClouds3Driver]'s omni
## lights, these are used in place of the driver's [CloudOmniLightSettings] for it. It lights the
## clouds out to cloud_radius rather than omni_range (with its own colour, energy and attenuation),
## and can leave the world unlit to light only the clouds. The SunshineClouds3 plugin draws its
## cloud radius in the editor.

## Whether it lights the world as any OmniLight3D does. Off, it lights only the clouds (and casts no
## shadows of its own).
@export var light_world : bool = true:
	set(value):
		light_world = value
		_update_world_light()

## How far it reaches on the clouds (m), in place of omni_range, which stays its range on the world.
## Its attenuation falls off over this.
@export_range(0.0, 100000.0, 1.0, "or_greater", "suffix:m") var cloud_radius : float = 1000.0:
	set(value):
		cloud_radius = value
		update_gizmos()

## Scales its energy (light_energy * light_volumetric_fog_energy) on the clouds only.
@export_range(0.0, 64.0, 0.01, "or_greater") var energy_multiplier : float = 1.0

## Samples through the clouds towards it per cloud sample, for the clouds' shadowing of themselves.
## 0 = none (lit through).
@export_range(0, 16) var shadow_samples : int = 4


func _ready() -> void:
	if Engine.is_editor_hint():
		# Basically this is a workaround to ensure this script is never pulled into a actual build as it uses editor interfaces.
		Callable(load("res://addons/SunshineClouds3/Resources/SunshineClouds3EditorSetup.gd"), &"connect_to_driver").call_deferred(self)


func _notification(what : int) -> void:
	# After Light3D's own, which shows it again.
	if what == NOTIFICATION_ENTER_TREE || what == NOTIFICATION_VISIBILITY_CHANGED:
		_update_world_light()


func _update_world_light() -> void:
	if !is_inside_tree():
		return
	if light_world:
		# Light3D's own visibility (visible in tree, editor only) again.
		editor_only = editor_only
	else:
		RenderingServer.instance_set_visible(get_instance(), false)
