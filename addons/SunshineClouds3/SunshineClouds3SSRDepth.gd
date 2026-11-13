@tool
class_name SunshineClouds3SSRDepth
extends CompositorEffect
## Puts the clouds into Godot's own screen-space reflections (Environment SSR) for a SunshineClouds3
## effect with engine_ssr_clouds on: the pair of these (SunshineClouds3.get_ssr_depth_effects())
## goes in the same Compositor. Before Godot's SSR runs (PRE_OPAQUE) the clouds' depth is written
## into the depth buffer where it shows sky; after the opaque pass (POST_OPAQUE, restore) those
## pixels go back to sky. A SunshineClouds3Driver adds and removes the pair as engine_ssr_clouds is
## turned on and off.

## The effect whose clouds go in.
@export var clouds : SunshineClouds3
## false: writes the clouds' depth (PRE_OPAQUE). true: puts the sky back (POST_OPAQUE).
@export var restore : bool = false:
	set(value):
		restore = value
		effect_callback_type = EFFECT_CALLBACK_TYPE_POST_OPAQUE if value else EFFECT_CALLBACK_TYPE_PRE_OPAQUE


func _init() -> void:
	effect_callback_type = EFFECT_CALLBACK_TYPE_PRE_OPAQUE
	# With 3D MSAA, Godot's SSR reads the resolved depth: resolved before the pre opaque effects.
	access_resolved_depth = true


func _render_callback(_callback_type : int, render_data : RenderData) -> void:
	if clouds != null && clouds.engine_ssr_clouds:
		clouds._ssr_depth_callback(restore, render_data)
