@tool
@icon("res://addons/SunshineClouds3/CloudsDriverIcon.svg")
extends Node
class_name SunshineClouds3Driver

## Updates the effect every frame; off leaves it as it is.
@export var update_continuously : bool = true
@export var clouds_resource : SunshineClouds3
## Basically just checked to see if a sky is present in the environment before overwriting it.
@export var world_environment : WorldEnvironment

@export_group("Wind Controls")
## Whether the wind will iterate within the editor (moving the clouds over time)
@export var iterate_wind_in_editor : bool = false
## Whether the wind will iterate within the player (moving the clouds over time)
@export var iterate_wind_in_game : bool = false
## Added to every layer's noise positions (for shifting world origins).
@export var origin_offset : Vector3 = Vector3.ZERO
## How fast the applied wind direction and scale follow wind_direction and wind_scale.
@export var transition_speed : float = 0.25
@export var wind_scale : float = 1.0
@export var wind_direction : Vector3 = Vector3(1.0, 0.0, 1.0)

var wind_direction_cur : Vector3 = Vector3(1.0, 0.0, 1.0)
var wind_scale_cur : float = 1.0
## origin_offset as the layer positions were last written with.
var prev_origin_offset : Vector3 = Vector3.ZERO

const PROJECTOR_META := &"_sunshine_clouds3_projector"

# The lights on the clouds (paths from this node), each with its settings at the same index. Empty
# paths (added in the inspector, no light picked yet) and missing lights are skipped.
@export_storage var directional_lights : Array[NodePath] = []:
	set(value):
		directional_lights = value
		_lights_resolved = false
		notify_property_list_changed()
@export_storage var directional_light_settings : Array[CloudDirectionalLightSettings] = []:
	set(value):
		directional_light_settings = value
		notify_property_list_changed()
@export_storage var omni_lights : Array[NodePath] = []:
	set(value):
		omni_lights = value
		_lights_resolved = false
		notify_property_list_changed()
@export_storage var omni_light_settings : Array[CloudOmniLightSettings] = []:
	set(value):
		omni_light_settings = value
		notify_property_list_changed()
# The effectors, as the lights.
@export_storage var effectors : Array[NodePath] = []:
	set(value):
		effectors = value
		_lights_resolved = false
		notify_property_list_changed()
@export_storage var effector_settings : Array[CloudEffectorSettings] = []:
	set(value):
		effector_settings = value
		notify_property_list_changed()

# Each list's paths and settings properties, by the name its inspector fields use.
const LISTS := {
	"directional": [&"directional_lights", &"directional_light_settings"],
	"omni": [&"omni_lights", &"omni_light_settings"],
	"effector": [&"effectors", &"effector_settings"],
}

# The lights and effectors as nodes (null where missing), resolved when the paths change and every
# so many frames (nodes freed or added since).
var _directional_nodes : Array[DirectionalLight3D] = []
var _omni_nodes : Array[OmniLight3D] = []
var _effector_nodes : Array[Node3D] = []
var _lights_resolved := false
var _resolve_countdown := 0

var _shadow_projector : Texture2D
var _shadow_blit_material : ShaderMaterial
var _shadow_light : DirectionalLight3D
# Warnings already given, as WARN_ flags per light instance id (0 for the engine).
var _shadow_warned := {}
# What the effect was last handed (set_shadow_projector()), so it's only sent when it changes.
var _sent_clouds := 0
var _sent_projector := RID()
var _sent_resolution := 0
var _sent_light_transform := Transform3D()
# The projector window centre last handed to the effect (set_shadow_projector_center()); the
# light's offset follows it a frame later, when the atlas has the map blitted around it.
var _sent_center := Vector2.ZERO
var _sent_windowed := false

# The Sky drawing the skybox (made the first time), and the Environment it's set on.
var _skybox : Sky
var _skybox_material : ShaderMaterial
var _skybox_texture : Texture2DRD
var _skybox_environment : Environment
# What was last set on the rendering server for it (the Environment's own sky settings and the
# skybox's Sky), and the effect's skybox_version last refreshed for.
var _skybox_applied := []
var _skybox_version := -1

# The directional lights this driver hid below the horizon (drive_light_color: see
# _hide_below_horizon()). Each also carries SunshineClouds3.BELOW_HORIZON_META, which the clouds read
# and which tells a driver after a reload that it was hidden here, not by hand.
var _hidden_lights : Array = []
# Lights shown by hand while hidden below the horizon (instance ids): left shown until they've risen.
var _shown_by_hand := {}


func _exit_tree() -> void:
	_release_shadow_projector()
	_release_skybox()
	_show_hidden_lights()


func _notification(what : int) -> void:
	if what == NOTIFICATION_EDITOR_PRE_SAVE:
		_release_shadow_projector()
		# Saved as the user left them; they're hidden again on the next frame.
		_show_hidden_lights()
	elif what == NOTIFICATION_EDITOR_POST_SAVE:
		_update_shadow_projector()


func _ready() -> void:
	wind_direction_cur = wind_direction
	# Starts where _process eases it to.
	wind_scale_cur = clampf(wind_scale * 0.05, 0.0, 1.0)
	prev_origin_offset = origin_offset
	# Every light has settings.
	while directional_light_settings.size() < directional_lights.size():
		directional_light_settings.append(CloudDirectionalLightSettings.new())
	while omni_light_settings.size() < omni_lights.size():
		omni_light_settings.append(CloudOmniLightSettings.new())
	while effector_settings.size() < effectors.size():
		effector_settings.append(CloudEffectorSettings.new())


# The Cloud Lights and Cloud Effectors sections of the inspector: placeholders
# SunshineClouds3DriverInspector replaces with the lists.
func _get_property_list() -> Array[Dictionary]:
	return [
		{"name": "Cloud Lights", "type": TYPE_NIL, "usage": PROPERTY_USAGE_GROUP},
		{"name": "cloud_lights", "type": TYPE_NIL, "usage": PROPERTY_USAGE_EDITOR},
		{"name": "Cloud Effectors", "type": TYPE_NIL, "usage": PROPERTY_USAGE_GROUP},
		{"name": "cloud_effectors", "type": TYPE_NIL, "usage": PROPERTY_USAGE_EDITOR},
	]


# Each light's and effector's fields for the inspector's property editors, not listed:
# cloud_lists/<directional, omni or effector>/<index>/<node, or one of its settings' properties>.
func _get(property : StringName) -> Variant:
	var field := _list_field(property)
	if field.is_empty():
		return null
	var paths : Array = get(LISTS[field[0]][0])
	var settings : Array = get(LISTS[field[0]][1])
	var index : int = field[1]
	if field[2] == "node":
		return get_node_or_null(paths[index]) if index < paths.size() && !paths[index].is_empty() else null
	return settings[index].get(field[2]) if index < settings.size() && settings[index] else null


func _set(property : StringName, value : Variant) -> bool:
	var field := _list_field(property)
	if field.is_empty():
		return false
	var index : int = field[1]
	if field[2] == "node":
		var paths : Array = get(LISTS[field[0]][0]).duplicate()
		if index < paths.size():
			paths[index] = get_path_to(value) if value is Node else NodePath()
			set(LISTS[field[0]][0], paths)
	else:
		var settings : Array = get(LISTS[field[0]][1])
		if index < settings.size() && settings[index]:
			settings[index].set(field[2], value)
	return true


# [list, index, field] of a cloud_lists/ property, or empty.
func _list_field(property : StringName) -> Array:
	var parts := String(property).split("/")
	if parts.size() != 4 || parts[0] != "cloud_lists" || !LISTS.has(parts[1]) || !parts[2].is_valid_int():
		return []
	return [parts[1], parts[2].to_int(), parts[3]]


## Adds light (in the same tree as this node) to the lights on the clouds with settings (a new
## default one if null), or gives it settings if it's there already. Returns its settings resource.
func add_directional_light(light : DirectionalLight3D, settings : CloudDirectionalLightSettings = null) -> CloudDirectionalLightSettings:
	if settings == null:
		settings = CloudDirectionalLightSettings.new()
	var path := get_path_to(light)
	var index := directional_lights.find(path)
	if index < 0:
		directional_lights.append(path)
		directional_light_settings.append(settings)
	else:
		directional_light_settings[index] = settings
	_lights_resolved = false
	notify_property_list_changed()
	return settings


func remove_directional_light(light : DirectionalLight3D) -> void:
	var index := directional_lights.find(get_path_to(light))
	if index >= 0:
		directional_lights.remove_at(index)
		directional_light_settings.remove_at(index)
		_lights_resolved = false
		notify_property_list_changed()


## As add_directional_light().
func add_omni_light(light : OmniLight3D, settings : CloudOmniLightSettings = null) -> CloudOmniLightSettings:
	if settings == null:
		settings = CloudOmniLightSettings.new()
	var path := get_path_to(light)
	var index := omni_lights.find(path)
	if index < 0:
		omni_lights.append(path)
		omni_light_settings.append(settings)
	else:
		omni_light_settings[index] = settings
	_lights_resolved = false
	notify_property_list_changed()
	return settings


func remove_omni_light(light : OmniLight3D) -> void:
	var index := omni_lights.find(get_path_to(light))
	if index >= 0:
		omni_lights.remove_at(index)
		omni_light_settings.remove_at(index)
		_lights_resolved = false
		notify_property_list_changed()


## As add_directional_light(), for an effector: any Node3D, the centre of its settings' sphere (a
## SunshineEffector uses its own settings instead, and settings are kept only for if it's swapped).
func add_effector(effector : Node3D, settings : CloudEffectorSettings = null) -> CloudEffectorSettings:
	if settings == null:
		settings = CloudEffectorSettings.new()
	var path := get_path_to(effector)
	var index := effectors.find(path)
	if index < 0:
		effectors.append(path)
		effector_settings.append(settings)
	else:
		effector_settings[index] = settings
	_lights_resolved = false
	notify_property_list_changed()
	return settings


func remove_effector(effector : Node3D) -> void:
	var index := effectors.find(get_path_to(effector))
	if index >= 0:
		effectors.remove_at(index)
		effector_settings.remove_at(index)
		_lights_resolved = false
		notify_property_list_changed()


## Queues a cloud density sample at position (world space): passes through to the clouds'
## [method SunshineClouds3.add_sample], so callable is called with (position : Vector3,
## density : float) a frame or two later. Does nothing without a clouds_resource.
func add_sample(callable : Callable, position : Vector3) -> void:
	if clouds_resource != null:
		clouds_resource.add_sample(callable, position)


## Connected to WanderTerrain.test_launch: the "test" run (--role=test) turns the clouds off.
func test_launched() -> void:
	if "--role=test" in OS.get_cmdline_args():
		update_continuously = false
		if clouds_resource != null:
			clouds_resource.enabled = false


func _process(delta : float) -> void:
	_update_shadow_projector()
	_update_skybox()
	_update_ssr_depth_effects()
	if !update_continuously || clouds_resource == null:
		_show_hidden_lights()
		return

	_resolve_countdown -= 1
	if !_lights_resolved || _resolve_countdown <= 0:
		_lights_resolved = true
		_resolve_countdown = 60 # Frames between re-resolving light/effector paths to nodes. 30-120: lower picks up added/freed nodes sooner at a small per-frame cost.
		_directional_nodes.resize(directional_lights.size())
		for i in directional_lights.size():
			_directional_nodes[i] = get_node_or_null(directional_lights[i]) as DirectionalLight3D
		_omni_nodes.resize(omni_lights.size())
		for i in omni_lights.size():
			_omni_nodes[i] = get_node_or_null(omni_lights[i]) as OmniLight3D
		_effector_nodes.resize(effectors.size())
		for i in effectors.size():
			_effector_nodes[i] = get_node_or_null(effectors[i]) as Node3D
	var camera := get_viewport().get_camera_3d() if get_viewport() else null
	var camera_position := camera.global_position if camera else Vector3.ZERO
	clouds_resource.set_lights(_directional_nodes, directional_light_settings, _omni_nodes, omni_light_settings, camera_position)
	clouds_resource.set_effectors(_effector_nodes, effector_settings, camera_position)

	# Only changes are assigned, so the lights aren't touched every frame.
	var light_position := camera_position if camera else Vector3(0.0, clouds_resource.ground_height, 0.0)
	var driven : Array[DirectionalLight3D] = []
	for i in mini(_directional_nodes.size(), directional_light_settings.size()):
		var light := _directional_nodes[i]
		var settings := directional_light_settings[i]
		if settings && settings.drive_light_color && is_instance_valid(light):
			var light_color := clouds_resource.get_light_color(light.global_transform.basis.z, light_position) * settings.color
			light_color.a = 1.0
			if !light.light_color.is_equal_approx(light_color):
				light.light_color = light_color
			_hide_below_horizon(light, light_color.r <= 0.0 && light_color.g <= 0.0 && light_color.b <= 0.0)
			driven.append(light)
	# Hidden lights no longer driven (taken off the list, or drive_light_color turned off) come back.
	for light in _hidden_lights.duplicate():
		if !driven.has(light):
			_show_hidden_light(light)

	# Wind, as SunshineClouds2's driver: direction and scale ease towards their targets, and every
	# layer moves each of its noises at its own speed (the detail also rises), kept within a tile
	# of their noise relative to the origin offset. Speeds and tiles are times the clouds' cloud_scale.
	wind_direction_cur = wind_direction_cur.move_toward(wind_direction, delta * transition_speed)
	wind_scale_cur = move_toward(wind_scale_cur, clampf(wind_scale * 0.05, 0.0, 1.0), delta * transition_speed)
	var wind_speed := 0.0 if (!iterate_wind_in_editor && Engine.is_editor_hint()) || (!iterate_wind_in_game && !Engine.is_editor_hint()) else wind_scale_cur
	var scale := clouds_resource.cloud_scale
	var wind := wind_direction_cur * delta * wind_speed * scale
	for layer in clouds_resource.layers:
		if layer == null:
			continue
		layer.coverage_noise_offset = origin_offset + _wrap(layer.coverage_noise_offset - prev_origin_offset + wind * layer.coverage_wind_speed,
			layer.coverage_noise_scale * scale)
		layer.noise_offset = origin_offset + _wrap(layer.noise_offset - prev_origin_offset + wind * layer.base_wind_speed, layer.noise_scale * scale)
		layer.detail_noise_offset = origin_offset + _wrap(layer.detail_noise_offset - prev_origin_offset
			+ (wind * layer.detail_wind_speed + Vector3.UP * absf(layer.detail_wind_speed) * delta * wind_speed * scale), layer.detail_noise_scale * scale)
		layer.curl_noise_offset = origin_offset + _wrap(layer.curl_noise_offset - prev_origin_offset + wind * layer.curl_wind_speed,
			layer.curl_noise_scale * scale)
	prev_origin_offset = origin_offset


## Keeps the pair of SunshineClouds3SSRDepth effects in world_environment's compositor (next to the
## clouds) while the clouds' engine_ssr_clouds is on, and takes them out when it's off.
func _update_ssr_depth_effects() -> void:
	if clouds_resource == null || !is_instance_valid(world_environment) || world_environment.compositor == null:
		return
	var compositor := world_environment.compositor
	var effects := compositor.compositor_effects
	if !effects.has(clouds_resource):
		return
	var present := 0
	for effect in effects:
		if effect is SunshineClouds3SSRDepth && effect.clouds == clouds_resource:
			present += 1
	var wanted := clouds_resource.engine_ssr_clouds
	if (present == 2) == wanted && (present == 0) != wanted:
		return
	var kept : Array[CompositorEffect] = []
	for effect in effects:
		if !(effect is SunshineClouds3SSRDepth && effect.clouds == clouds_resource):
			kept.append(effect)
	if wanted:
		kept.append_array(clouds_resource.get_ssr_depth_effects())
	compositor.compositor_effects = kept


## Hides a driven light whose colour has gone black (dark: its disc has set below the horizon), so
## the scene doesn't pay for a light that gives none (its shadow maps above all), and shows it again
## once it's lit. Only visible is changed, and only on lights this driver hid: one hidden by hand
## stays hidden, and one shown by hand while down stays shown until it has risen (and is hidden at
## its next setting). The clouds and the atmosphere count a light hidden here as shown
## (SunshineClouds3.light_shown()), so their lights, the shadow caster and the last lights kept for
## the fallback stay as they were.
func _hide_below_horizon(light : DirectionalLight3D, dark : bool) -> void:
	var id := light.get_instance_id()
	if light.has_meta(SunshineClouds3.BELOW_HORIZON_META):
		if light.visible:
			# Shown by hand: the user's from here on.
			light.remove_meta(SunshineClouds3.BELOW_HORIZON_META)
			_hidden_lights.erase(light)
			_shown_by_hand[id] = true
		elif !dark:
			_show_hidden_light(light)
		elif !_hidden_lights.has(light):
			# Hidden here before a reload.
			_hidden_lights.append(light)
	elif !dark:
		_shown_by_hand.erase(id)
	elif light.visible && !_shown_by_hand.has(id):
		light.set_meta(SunshineClouds3.BELOW_HORIZON_META, true)
		light.visible = false
		_hidden_lights.append(light)


func _show_hidden_light(light) -> void:
	_hidden_lights.erase(light)
	if is_instance_valid(light) && light.has_meta(SunshineClouds3.BELOW_HORIZON_META):
		light.remove_meta(SunshineClouds3.BELOW_HORIZON_META)
		light.visible = true


func _show_hidden_lights() -> void:
	for light in _hidden_lights.duplicate():
		_show_hidden_light(light)


## True the first time it's asked for flag on object (null for the engine).
func _first_warning(object : Object, flag : int) -> bool:
	var id := object.get_instance_id() if object else 0
	var warned : int = _shadow_warned.get(id, 0)
	if warned & flag:
		return false
	_shadow_warned[id] = warned | flag
	return true


## Hands the effect a projector to blit its shadow map into (and puts it on the light casting the
## shadows, the effect's shadow_caster_id) when the effect wants projector shadows and the engine
## and light can take them; otherwise takes it off, and the effect falls back to screen space
## shadows.
func _update_shadow_projector() -> void:
	var light := instance_from_id(clouds_resource.shadow_caster_id) as DirectionalLight3D if clouds_resource else null
	if !update_continuously || clouds_resource == null || !clouds_resource.cloud_shadows \
			|| clouds_resource.cloud_shadow_mode != SunshineClouds3.SHADOW_MODE_PROJECTOR \
			|| light == null || !light.is_visible_in_tree() || !is_inside_tree():
		light = null
	# Directional projectors (light_projector_size) aren't in stock Godot, nor drawable blits.
	if light != null && !("light_projector" in light && "light_projector_size" in light
			&& ClassDB.class_exists(&"DrawableTexture2D") && RenderingServer.has_method(&"texture_drawable_blit_rect")):
		if _first_warning(null, 1): # Warning flag: engine lacks directional projectors. Each warning needs its own power of two (1, 2, 4, ...).
			push_warning("SunshineClouds3Driver: this Godot build has no directional light projectors, cloud shadows are screen space.")
		light = null
	if light != null && _shadow_projector == null && _is_cloud_projector(light.get(&"light_projector")):
		_take_projector_off(light)
	if light != null && light.get(&"light_projector") != null && light.get(&"light_projector") != _shadow_projector:
		if _first_warning(light, 2): # Warning flag: light already has a projector texture. Each warning needs its own power of two (1, 2, 4, ...).
			push_warning("SunshineClouds3Driver: %s already has a projector texture, cloud shadows are screen space." % light.name)
		light = null
	if light != _shadow_light:
		_release_shadow_projector()
	if light == null:
		return
	if !light.shadow_enabled && _first_warning(light, 4): # Warning flag: light has shadows off. Each warning needs its own power of two (1, 2, 4, ...).
		push_warning("SunshineClouds3Driver: %s needs shadow_enabled; Godot only applies a directional projector to lights casting shadows." % light.name)

	var resolution := clouds_resource.cloud_shadow_resolution
	if _shadow_projector == null:
		_shadow_projector = ClassDB.instantiate(&"DrawableTexture2D")
		_shadow_projector.set_meta(PROJECTOR_META, true)
	if _shadow_projector.get_width() != resolution || _shadow_projector.get_height() != resolution:
		_shadow_projector.call(&"setup", resolution, resolution,
			ClassDB.class_get_integer_constant(&"DrawableTexture2D", &"DRAWABLE_FORMAT_RGBA8_SRGB"), Color.WHITE, false)
	if _shadow_blit_material == null:
		_shadow_blit_material = ShaderMaterial.new()
		# Loaded here, not preloaded: texture_blit shaders only compile on engines with drawable textures.
		_shadow_blit_material.shader = load("res://addons/SunshineClouds3/Resources/Shaders/SunshineClouds3ShadowBlit.gdshader")

	var extent := Vector2.ONE * maxf(clouds_resource.cloud_shadow_extent * clouds_resource.cloud_scale, 1.0)
	if light.get(&"light_projector") != _shadow_projector:
		light.set(&"light_projector", _shadow_projector)
	if light.get(&"light_projector_size") != extent:
		light.set(&"light_projector_size", extent)
	# With repeat off (engines that have it) the projector only covers extent around its offset: the
	# effect blits the map centred over the camera and faded out to the edge, and the offset moves
	# the window there. The projector shows the map blitted last frame (the decal atlas copies it at
	# the start of the next frame's draw), so the offset is the centre handed over then.
	var windowed := "light_projector_repeat" in light && "light_projector_offset" in light
	if windowed:
		if light.get(&"light_projector_repeat") != false:
			light.set(&"light_projector_repeat", false)
		var offset := -_sent_center if _sent_windowed else Vector2.ZERO
		if light.get(&"light_projector_offset") != offset:
			light.set(&"light_projector_offset", offset)
	elif "light_projector_offset" in light && light.get(&"light_projector_offset") != Vector2.ZERO:
		light.set(&"light_projector_offset", Vector2.ZERO)
	_shadow_light = light
	var projector := _shadow_projector.get_rid()
	if clouds_resource.get_instance_id() != _sent_clouds || projector != _sent_projector || resolution != _sent_resolution || light.global_transform != _sent_light_transform:
		_sent_clouds = clouds_resource.get_instance_id()
		_sent_projector = projector
		_sent_resolution = resolution
		_sent_light_transform = light.global_transform
		RenderingServer.call_on_render_thread(clouds_resource.set_shadow_projector.bind(projector,
			Vector2i(resolution, resolution), _shadow_blit_material.get_rid(), _sent_light_transform, light.get_instance_id()))
	var center := clouds_resource.get_shadow_projector_center_request() if windowed else Vector2.ZERO
	if center != _sent_center || windowed != _sent_windowed:
		_sent_center = center
		_sent_windowed = windowed
		RenderingServer.call_on_render_thread(clouds_resource.set_shadow_projector_center.bind(center, windowed))


## Asks the effect for its skybox every frame and sets it as world_environment's sky on the
## rendering server (again whenever the Environment's own sky settings change, as it pushes them
## then); otherwise sets the Environment's own sky back. Only changes reach the rendering server,
## so the editor can go idle.
func _update_skybox() -> void:
	var environment := world_environment.environment if is_instance_valid(world_environment) else null
	var wanted := environment != null && clouds_resource != null && clouds_resource.skybox_enabled \
		&& clouds_resource.atmosphere_enabled && is_inside_tree()
	if !wanted || environment != _skybox_environment:
		_release_skybox()
	if !wanted:
		return
	clouds_resource.request_skybox()
	# Created on the render thread from the next frame.
	var texture := clouds_resource.skybox_texture
	if !texture.is_valid():
		return
	if _skybox == null:
		_skybox_material = ShaderMaterial.new()
		_skybox_material.shader = preload("res://addons/SunshineClouds3/Resources/Shaders/SunshineClouds3Skybox.gdshader")
		_skybox = Sky.new()
		_skybox.sky_material = _skybox_material
		# Filtered over a few frames rather than all at once.
		_skybox.process_mode = Sky.PROCESS_MODE_INCREMENTAL
	if _skybox_texture == null:
		_skybox_texture = Texture2DRD.new()
		_skybox_material.set_shader_parameter(&"skybox", _skybox_texture)
	if _skybox_texture.texture_rd_rid != texture:
		_skybox_texture.texture_rd_rid = texture
	if _skybox.radiance_size != clouds_resource.skybox_radiance_size:
		_skybox.radiance_size = clouds_resource.skybox_radiance_size as Sky.RadianceSize
	_skybox_environment = environment
	var applied := [environment.sky, environment.background_mode, environment.sky_rotation, _skybox.get_rid()]
	if applied != _skybox_applied:
		_skybox_applied = applied
		var environment_rid := environment.get_rid()
		RenderingServer.environment_set_sky(environment_rid, _skybox.get_rid())
		RenderingServer.environment_set_background(environment_rid, RenderingServer.ENV_BG_SKY)
		# The panorama is in world directions.
		RenderingServer.environment_set_sky_orientation(environment_rid, Basis.IDENTITY)
	# Godot only filters a sky's reflections again when one of its material's parameters changes.
	if clouds_resource.skybox_version != _skybox_version:
		_skybox_version = clouds_resource.skybox_version
		_skybox_material.set_shader_parameter(&"refresh", float(_skybox_version % 4096))


## Sets the Environment's own sky, background mode and sky rotation back on the rendering server,
## as Environment's setters do, and lets go of the effect's texture (replaced or freed while the
## skybox is off, it would break the Sky's material).
func _release_skybox() -> void:
	if _skybox_texture != null:
		_skybox_material.set_shader_parameter(&"skybox", null)
		_skybox_texture = null
	if _skybox_environment != null:
		var environment_rid := _skybox_environment.get_rid()
		RenderingServer.environment_set_sky(environment_rid, _skybox_environment.sky.get_rid() if _skybox_environment.sky else RID())
		RenderingServer.environment_set_background(environment_rid, _skybox_environment.background_mode as RenderingServer.EnvironmentBG)
		RenderingServer.environment_set_sky_orientation(environment_rid, Basis.from_euler(_skybox_environment.sky_rotation))
	_skybox_environment = null
	_skybox_applied = []


func _release_shadow_projector() -> void:
	if is_instance_valid(_shadow_light) && _is_cloud_projector(_shadow_light.get(&"light_projector")):
		_take_projector_off(_shadow_light)
	for light in _directional_nodes:
		if is_instance_valid(light) && "light_projector" in light && _is_cloud_projector(light.get(&"light_projector")):
			_take_projector_off(light)
	_shadow_light = null
	_sent_clouds = 0
	_sent_center = Vector2.ZERO
	_sent_windowed = false
	if clouds_resource != null:
		RenderingServer.call_on_render_thread(clouds_resource.set_shadow_projector.bind(RID(), Vector2i.ZERO, RID(), Transform3D.IDENTITY, 0))
		RenderingServer.call_on_render_thread(clouds_resource.set_shadow_projector_center.bind(Vector2.ZERO, false))


# Takes the cloud projector off light and puts its repeat and offset back to the defaults, so the
# camera-following offset is never saved into the scene.
func _take_projector_off(light : DirectionalLight3D) -> void:
	light.set(&"light_projector", null)
	if "light_projector_repeat" in light:
		light.set(&"light_projector_repeat", true)
	if "light_projector_offset" in light:
		light.set(&"light_projector_offset", Vector2.ZERO)


func _is_cloud_projector(texture : Texture2D) -> bool:
	return texture != null && (texture == _shadow_projector || texture.has_meta(PROJECTOR_META))


func _wrap(position : Vector3, tile_size : float) -> Vector3:
	return Vector3(fposmod(position.x, tile_size), fposmod(position.y, tile_size), fposmod(position.z, tile_size))
