@tool
extends OmniLight3D
class_name SunshineOmniLight
## An omni light with its own cloud settings, used in place of the driver's [CloudOmniLightSettings] when listed among
## a [SunshineClouds3Driver]'s omni lights. Lights the clouds out to cloud_radius instead of omni_range (with its own
## colour, energy and attenuation) and can skip lighting the world. The plugin draws cloud_radius in the editor.

## Lights the world as any OmniLight3D does. Off, it lights only the clouds and casts no shadows of its own.
@export var light_world : bool = true:
	set(value):
		light_world = value
		_update_world_light()

## Reach on the clouds (m), in place of omni_range (which still applies to the world). Attenuation falls off over this.
@export_range(0.0, 100000.0, 1.0, "or_greater", "suffix:m") var cloud_radius : float = 1000.0:
	set(value):
		cloud_radius = value
		update_gizmos()

## Scales its energy (light_energy * light_volumetric_fog_energy) on the clouds only.
@export_range(0.0, 64.0, 0.01, "or_greater") var energy_multiplier : float = 1.0

## Samples toward it per cloud sample, for the clouds' self-shadowing. 0 = none (lit through).
@export_range(0, 16) var shadow_samples : int = 4


func _ready() -> void:
	if Engine.is_editor_hint():
		# Loaded by path so the editor-only setup script (it uses editor interfaces) never ends up in an exported build.
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
