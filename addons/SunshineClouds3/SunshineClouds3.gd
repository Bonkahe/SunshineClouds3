@tool
extends CompositorEffect
class_name SunshineClouds3

##	References used:
##	https://www.schneidervfx.com/andrew-schneider-real-time-volumetrics-and-vfx (The man the myth the legend)
##	https://ebruneton.github.io/precomputed_atmospheric_scattering/ (provided the atmospheric calculation pretty much 1-1, super cool stuff)
##


const SHADER_PATH := "res://addons/SunshineClouds3/Compute/SunshineClouds3Raymarch.glsl"
const RESOLVE_SHADER_PATH := "res://addons/SunshineClouds3/Compute/SunshineClouds3Resolve.glsl"
const ATMOSPHERE_PRECOMPUTE_PATH := "res://addons/SunshineClouds3/Compute/atmosphere/AtmospherePrecompute.glsl"
const MSAA_COMPOSITE_SHADER_PATH := "res://addons/SunshineClouds3/Compute/SunshineClouds3MsaaComposite.glsl"
const REFLECTION_SHADER_PATH := "res://addons/SunshineClouds3/Compute/SunshineClouds3Reflection.glsl"
const DRAW_SHADER_PATHS := [SHADER_PATH, RESOLVE_SHADER_PATH, ATMOSPHERE_PRECOMPUTE_PATH, MSAA_COMPOSITE_SHADER_PATH, REFLECTION_SHADER_PATH]

## I wouldn't change this, as 32 sample points per frame should be enough, and it buffers so if you go over that one frame and under it the other the ones missed will roll over.
const MAX_SAMPLE_POINTS := 32
const SAMPLE_BUFFER_BYTES := MAX_SAMPLE_POINTS * 16
const SHADOW_BYTES := 208
const PARAMS_BYTES := 384
const ATMOSPHERE_BYTES := 304
const SKY_BYTES := 144

## Can be changed but you will have to acocunt for it in the SunshineClouds3Common.glslinc
const MAX_LAYERS := 8 
const LAYER_BYTES := 112


## Can be changed but update raymarch.glsl
const MAX_DIRECTIONAL_LIGHTS := 4
const MAX_OMNI_LIGHTS := 8
## We can change this, but you have to change the raymarch.glsl (Lights->points) size.
const MAX_EFFECTORS := 16 
const SHADOW_MODE_PROJECTOR := 0
## Precomputed atmosphere texture sizes, as in AtmosphereHeader.glslinc.
const TRANSMITTANCE_SIZE := Vector3i(256, 64, 1)
const SCATTERING_SIZE := Vector3i(8 * 32, 128, 32)
const IRRADIANCE_SIZE := Vector3i(64, 16, 1)
const PRECOMPUTE_VERSIONS := ["transmittance", "direct_irradiance", "single_scattering", "scattering_density", "indirect_irradiance", "multiple_scattering"]
## Wavelengths (nm) the atmosphere is computed for, as in Bruneton's model.h.
const ATMOSPHERE_LAMBDAS := [680.0, 550.0, 440.0]
## From Bruneton's demo.cc, in 10 nm bins from 360 nm: ozone absorption cross section (m^2).
const OZONE_CROSS_SECTION := [1.18e-27, 2.182e-28, 2.818e-28, 6.636e-28, 1.527e-27, 2.763e-27,
	5.52e-27, 8.451e-27, 1.582e-26, 2.316e-26, 3.669e-26, 4.924e-26, 7.752e-26, 9.016e-26, 1.48e-25,
	1.602e-25, 2.139e-25, 2.755e-25, 3.091e-25, 3.5e-25, 4.266e-25, 4.672e-25, 4.398e-25, 4.701e-25,
	5.019e-25, 4.305e-25, 3.74e-25, 3.215e-25, 2.662e-25, 2.238e-25, 1.852e-25, 1.473e-25, 1.209e-25,
	9.423e-26, 7.455e-26, 6.566e-26, 5.105e-26, 4.15e-26, 4.228e-26, 3.237e-26, 2.451e-26, 2.801e-26,
	2.534e-26, 1.624e-26, 1.465e-26, 2.078e-26, 1.383e-26, 7.105e-27]
const RAYLEIGH := 1.24062e-6
## 300 Dobson units of ozone spread over the 15 km integral of the ozone profile.
const MAX_OZONE_NUMBER_DENSITY := 300.0 * 2.687e20 / 15000.0

## We can store the textures for each viewport in the RenderSceneBuffersRD for that viewport, which lets us use multiple camera's, this is the key for those buffers.
const BUFFERS_CONTEXT := &"SunshineClouds3"
const VIEW_TEXTURE_NAMES : Array[StringName] = [&"history_0", &"history_1", &"raymarch", &"raymarch_b", &"history_b_0", &"history_b_1"]
const VIEW_TEXTURES := 6
const SET_INPUT_COUNT := 8 + VIEW_TEXTURES


@export_group("Layers")
@export var layers : Array[CloudLayer] = [CloudLayer.new()]:
	set(value):
		layers = value
		_sync_layers()
@export_subgroup("Advanced")
## Used for the resolution of the profile definition, as those curves for each layer are baked into a gradient texture, this is the resolution of that texture.
@export_range(2, 1024, 1) var profile_resolution : int = 64:
	set(value):
		profile_resolution = value
		_bake_profile()

@export_group("Base Settings")
## The overall amount of clouds in the scene, multiplies the individual layers coverage.
@export_range(0.0, 1.0) var coverage: float = 0.611
## The overall amount of density of the clouds, multiplies the individual layers coverage.
@export_range(0.0, 1.0) var density: float = 0.611
## Scales the clouds and the atmosphere as a whole: the layers' heights, the noise sizes and wind,
## the planet and atmosphere sizes, the march and shadow distances, with the extinctions scaled
## back so they look the same, just bigger or smaller. Effectors and omni lights keep their own
## world sizes.
@export_range(0.001, 10.0, 0.001, "or_greater") var cloud_scale : float = 1.0:
	set(value):
		cloud_scale = value
		atmosphere_changed = true

@export_group("Direct Scattering")
## Multiplies the clouds' light, every light's direct light and the ambient, on screen and in the
## skybox. White leaves them as lit.
@export_color_no_alpha var cloud_tint : Color = Color.WHITE
## Scales every directional light's energy on the clouds.
@export_range(0.0, 10.0, 0.01, "or_greater") var directional_energy_multiplier : float = 5.74
## Scales every omni light's energy on the clouds.
@export_range(0.0, 10.0, 0.01, "or_greater") var omni_energy_multiplier : float = 10.0

## Henyey-Greenstein g of the direct light (light that reached the sample through the cloud).
## Higher concentrates it forward: bright silver linings looking towards the light, darker looking
## away. 0.3-0.8 suits clouds.
@export_range(0.01, 0.99, 0.01) var primary_phase_g : float = 0.08

## Henyey-Greenstein g of the multiple scattering term (the ms_volume glow inside the cloud).
## Bounced light has lost its direction, so keep it low: 0.0-0.3, near even in every direction,
## lights the side facing away from the light.
@export_range(0.01, 0.99, 0.01) var secondary_phase_g : float = 0.36

## ms_volume *= pow(attenuated_light, multiple_scattering_depth_power).
@export_range(0.01, 4.0, 0.001, "or_greater") var multiple_scattering_depth_power : float = 0.07
## ms_volume *= pow(height_fraction, multiple_scattering_height_power).
@export_range(0.01, 4.0, 0.001, "or_greater") var multiple_scattering_height_power : float = 0.43
@export_subgroup("Fallback Light")
## Fallback is just what's used when no lights are assigned to the driver.
@export_range(-90.0, 90.0, 0.1, "degrees") var fallback_light_elevation : float = 50.0
@export_range(-180.0, 180.0, 0.1, "degrees") var fallback_light_azimuth : float = 30.0
@export var fallback_light_color : Color = Color.WHITE
@export_range(0.0, 16.0, 0.01, "or_greater") var fallback_light_energy : float = 1.0
## Forgets the last directional lights a driver gave, so the fallback light is used until one gives
## some again.
@export_tool_button("Forget Last Lights", "Clear") var forget_last_lights_action = forget_last_lights

@export_group("Ambient Scattering")

@export var ambient_color : Color = Color(1.0, 0.3889187, 0.2613985)
## Colour of the ground bounce, the density-aware ambient's light from below (ambient_color is the
## sky's from above).
@export var ground_color : Color = Color(1.0, 0.3889187, 0.2613985)
@export_range(0.0, 10.0, 0.01, "or_greater") var ambient_energy : float = 1.0
## 0: the ambient light follows the layer's profile only, so dark sides come out flat. 1:
## density-aware, sky light from above and ground light from below dimmed through the cloud, so
## dense cores darken and wisps stay lit.
@export_range(0.0, 1.0, 0.01) var ambient_occlusion : float = 0.99
## Light from below as a fraction of the sky light from above, for the density-aware ambient.
@export_range(0.0, 2.0, 0.01, "or_greater") var ambient_ground_strength : float = 0.92
## Scales the extinction the density-aware ambient is occluded by: lower lets it reach further
## into the cloud.
@export_range(0.0, 1.0, 0.0001, "or_greater") var ambient_extinction_scale : float = 0.1861


@export_group("Atmosphere")

@export var atmosphere_enabled : bool = true

## Multiplies the atmosphere's own light: the sky (not the sun's disc), the haze over the scene and
## in front of the clouds, and the sky light on the clouds and the skybox's ground.
@export_color_no_alpha var atmosphere_tint : Color = Color.WHITE

@export_range(0.0, 100.0, 0.01, "or_greater") var radiance_scale : float = 1.0
## World Y of the planet surface.
@export var ground_height : float = 0.0

@export_range(0.01, 10.0, 0.01, "or_greater") var atmospheric_density : float = 3.0:
	set(value):
		atmospheric_density = value
		atmosphere_changed = true

@export_subgroup("Advanced")
@export_range(1.0, 100000.0, 1.0, "or_greater", "suffix:km") var planet_radius : float = 6360.0:
	set(value):
		planet_radius = value
		atmosphere_changed = true
@export_range(1.0, 1000.0, 0.1, "or_greater", "suffix:km") var atmosphere_height : float = 60.0:
	set(value):
		atmosphere_height = value
		atmosphere_changed = true
@export_range(100.0, 100000.0, 1.0, "or_greater", "suffix:m") var rayleigh_scale_height : float = 8000.0:
	set(value):
		rayleigh_scale_height = value
		atmosphere_changed = true
@export_range(10.0, 100000.0, 1.0, "or_greater", "suffix:m") var mie_scale_height : float = 1200.0:
	set(value):
		mie_scale_height = value
		atmosphere_changed = true
## Aerosol amount (Angstrom turbidity beta); higher is hazier.
@export_range(0.0, 0.1, 0.0001, "or_greater") var mie_angstrom_beta : float = 5.328e-3:
	set(value):
		mie_angstrom_beta = value
		atmosphere_changed = true
@export_range(0.0, 1.0, 0.01) var mie_single_scattering_albedo : float = 0.9:
	set(value):
		mie_single_scattering_albedo = value
		atmosphere_changed = true
## Cornette-Shanks g of the aerosols.
@export_range(-0.99, 0.99, 0.01) var mie_phase_g : float = 0.93:
	set(value):
		mie_phase_g = value
		atmosphere_changed = true
## Albedo of the planet ground in the precomputed scattering (the ground itself isn't drawn).
@export_range(0.0, 2.0, 0.01) var ground_albedo : float = 1.0:
	set(value):
		ground_albedo = value
		atmosphere_changed = true
@export var ozone : bool = true:
	set(value):
		ozone = value
		atmosphere_changed = true
@export_range(0.0001, 0.1, 0.0001, "suffix:rad") var sun_angular_radius : float = 0.0156:
	set(value):
		sun_angular_radius = value
		atmosphere_changed = true
@export_range(1, 8) var scattering_orders : int = 8:
	set(value):
		scattering_orders = value
		atmosphere_changed = true

@export_group("Spherical Planet Settings")
## Curves the cloud layers, the atmosphere and the cloud shadows around a sphere of planet_radius
## at planet_center: their heights become altitudes above its surface (ground_height is unused).
## Off, they're flat along world Y, as around a planet at (0, -planet_radius, 0).
## There are incompatablities with this feature, this stops coverage noise from working, as that is still in world space xy, recommended you disable that if you enable this feature.
## It also stops the driving of the directional light color from being accurate as well, as when the sun is on the other side of the planet from you, it will be red when it should still be white (Or whatever you have it set to).
@export var spherical_planet : bool = false
## World position of the planet's centre, with spherical_planet.
@export var planet_center : Vector3 = Vector3(0.0, -6360000.0, 0.0)

@export_group("Quality")
## Step size at the camera: near_step_size + far_step_size_offset * distance / step_adjustment_distance.
@export_range(0.1, 100.0, 0.1, "or_greater") var near_step_size : float = 3.0
## Step size added to the near step size at the maximum distance.
@export_range(0.0, 1000.0, 0.1, "or_greater") var far_step_size_offset : float = 100.0
## Used to modulate the point at which far_step_size_offset is fully used.
@export_range(1.0, 100000.0, 1.0, "or_greater") var step_adjustment_distance : float = 6000.0
## View step size once a ray has found cloud. Lower values get better visuals overall (less noise specifically), but it does have some performance cost and also sometimes introduces a bit of banding on the clouds.
@export_range(1.0, 1000.0, 0.1, "or_greater") var cloud_step_size : float = 10.0
## Samples in a row that find no cloud before the view ray goes back to coarse steps.
@export_range(1, 64) var cloud_exit_steps : int = 10
## In short, it renders a small subset of pixels based on this setting, the rest just reproject during interem frames.
@export_enum("Off:1", "Half:2", "Quarter:4", "Eighth:8") var interlace : int = 2
## Maximum number of raymarch steps used, the base for performance is usually controlled by this.
@export_range(1, 4096) var max_steps : int = 600
## Total distance used to sample the lighting in.
@export_range(1.0, 100000.0, 1.0, "or_greater") var light_march_distance : float = 2000.0
## Each light step is this much longer than the previous one. 1 = even steps.
@export_range(1.0, 3.0, 0.01) var light_step_growth : float = 2.15
## Maximum distance used for the clouds.
@export_range(100.0, 200000.0, 1.0, "or_greater") var max_distance : float = 150000.0
## The raymarch traces one random pixel per N x N block each frame; the resolve reconstructs and
## accumulates at full resolution.
@export_enum("Full:1", "Half:2", "Quarter:4") var raymarch_resolution : int = 2

@export_group("Accumulation")
## Weight of the new frame when blending with the history. 1 = no accumulation.
@export_range(0.001, 1.0, 0.001) var current_frame_weight : float = 0.1
## Nearer than this, the history isn't moved with the wind (fading in linearly from the camera):
## there a frame's wind is a large screen jump that ghosts across silhouettes.
@export_range(0.0, 10000.0, 1.0, "or_greater", "suffix:m") var wind_reprojection_distance : float = 500.0

@export_group("Cloud Shadows")
## Generates cloud shadow textures and applies them to the directional light strongest in the scene, if the projectors are available.
## There is a PR open currently to implement this support, available here: https://github.com/godotengine/godot/pull/106294 you will have to build a version yourself.
@export var cloud_shadows : bool = true
## Light Projector: SunshineClouds3Driver puts the map on its directional light as a projector
## (needs an engine build with directional light projectors and the light casting shadows). Screen
## Space: the resolve darkens opaque surfaces instead, ambient light included. Light Projector
## falls back to Screen Space when the projector isn't available.
@export_enum("Light Projector:0", "Screen Space:1") var cloud_shadow_mode : int = SHADOW_MODE_PROJECTOR
@export_enum("512:512", "1024:1024", "2048:2048") var cloud_shadow_resolution : int = 512
@export_range(1000.0, 512000.0, 100.0, "or_greater", "suffix:m") var cloud_shadow_extent : float = 80000.0
@export_range(1, 64) var cloud_shadow_steps : int = 32
@export_range(0.0, 1.0, 0.001, "or_greater") var cloud_shadow_strength : float = 0.549
@export_range(0.05, 4.0, 0.01) var cloud_shadow_sharpness : float = 0.97
@export_range(0.0, 45.0, 0.1, "suffix:°") var cloud_shadow_horizon_fade : float = 45.0
## Frames between shadow map renders, blended from one to the next in between (1 = every frame).
## Higher saves GPU time; the shadows then trail the clouds by about this many frames.
@export_range(1, 128) var cloud_shadow_update_interval : int = 12
@export_subgroup("Screen Space")
@export_range(0.0, 1.0, 0.01) var screen_space_shadow_strength : float = 0.6
@export_range(0.0, 1.0, 0.01) var screen_space_shadow_fade : float = 0.7

@export_group("Background")
## An equirectangular panorama behind the atmosphere (laid out as PanoramaSkyMaterial's): stars and
## the like. It's seen through the air to space and behind the clouds, and fades out where the sky
## in front of it is bright. Its colours are light in scene units, times background_color and
## background_energy. Needs atmosphere_enabled.
@export var background_texture : Texture2D
@export var background_color : Color = Color.WHITE
@export_range(0.0, 16.0, 0.001, "or_greater") var background_energy : float = 1.0
## Sky brightness (luminance, scene units) that dims the background to about a third: it fades in
## as the sky darkens, first on the side away from the sun. At a radiance_scale of 1 a clear midday
## zenith is about 0.06, and the sky away from a sun 3 degrees below the horizon about 0.0005.
## 0 = never fades.
@export_range(0.0, 0.1, 0.0001, "or_greater") var background_fade_brightness : float = 0.002
## Rotates the background (Euler angles in degrees, as Environment.sky_rotation): turn it to move
## the stars through the night.
@export var background_rotation : Vector3 = Vector3.ZERO
## Scales the background in the skybox (reflections and ambient light) on top of
## background_energy; the clouds' own sky on screen is unaffected.
@export_range(0.0, 16.0, 0.001, "or_greater") var background_skybox_energy : float = 1.0

@export_group("Skybox")
## Renders the atmosphere, the background and a coarse march of the clouds into a low resolution
## panorama, the skybox, which a SunshineClouds3Driver with a world_environment draws that
## environment's sky with (in the editor too): the scene's reflections and ambient light then follow
## the atmosphere. Needs atmosphere_enabled.
@export var skybox_enabled : bool = true
## Width of the panorama (its height is half of it).
@export_enum("64:64", "128:128", "256:256", "512:512", "1024:1024") var skybox_resolution : int = 64
## The Sky's radiance_size: the resolution Godot filters the reflections and ambient light at.
@export_enum("32:0", "64:1", "128:2", "256:3", "512:4") var skybox_radiance_size : int = Sky.RADIANCE_SIZE_32
## Frames between panorama renders, blended from one to the next in between (1 = every frame), as
## cloud_shadow_update_interval. It renders again at once when the sun, the camera height or the
## settings jump.
@export_range(1, 128) var skybox_update_interval : int = 32
## Albedo of the ground below the horizon in the panorama, lit by the sun and the sky.
@export var skybox_ground_color : Color = Color(0.1875, 0.17620538, 0.13044626)
## Scales the whole skybox's brightness, and so the reflections and ambient light it gives (the
## clouds' own sky on screen is unaffected).
@export_range(0.0, 4.0, 0.01, "or_greater") var skybox_energy : float = 1.0
## How much the clouds' coverage and density darken the whole skybox (and so the reflections and
## ambient light): its radiance is scaled by 1 - this * (coverage + density) / 2, from Base
## Settings. 0 = not at all.
@export_range(0.0, 1.0, 0.01) var skybox_cloud_dimming : float = 0.0
@export_subgroup("Clouds")
## Marches the clouds into the skybox too, far coarser than on screen: even steps, no curl noise and
## no omni lights. Off leaves the clear sky.
@export var skybox_clouds : bool = true
## Steps along each skybox ray through the layers, evenly spaced up to skybox_cloud_distance.
@export_range(1, 128) var skybox_cloud_steps : int = 4
## Steps towards each directional light from every cloud sample (0 = lit through), over
## light_march_distance growing by light_step_growth.
@export_range(0, 8) var skybox_cloud_light_steps : int = 2
## How far along a skybox ray the clouds are marched.
@export_range(1000.0, 200000.0, 100.0, "or_greater", "suffix:m") var skybox_cloud_distance : float = 10000.0

@export_group("Reflections")
## Writes the frame's colour with the clouds in it, and how far away each pixel is, into one image
## every frame, for screen-space reflection materials (Resources/Shaders/SunshineClouds3SSR.gdshader
## is a basic one).
@export var reflections_enabled : bool = false:
	set(value):
		reflections_enabled = value
		_queue_reflection_update()
## The global shader parameter (sampler2D) the image is set as.
@export var reflection_parameter : StringName = &"sunshine_clouds_reflection":
	set(value):
		reflection_parameter = value
		_queue_reflection_update()
## Adds reflection_parameter to Project Settings > Globals > Shader Globals (sampler2D), so
## materials that read it compile whenever they load.
@export_tool_button("Add To Project Shader Globals", "Add") var add_reflection_global_action = add_reflection_parameter_to_project

@export_group("Noise Textures")
@export_subgroup("Noise Composite")
@export var noise_texture : Texture3D = preload("res://addons/SunshineClouds3/Compute/NoiseTextures/NoiseComposite.res")

@export var composite_perlin : Texture3D = preload("res://addons/SunshineClouds3/Compute/NoiseTextures/CompositePerlin.tres")
@export var composite_perlin_worley : Texture3D = preload("res://addons/SunshineClouds3/Compute/NoiseTextures/CompositePerlinWorley.tres")

@export var composite_worley_g : Texture3D = preload("res://addons/SunshineClouds3/Compute/NoiseTextures/CompositeWorleyG.tres")
@export_range(0.0, 1.0, 0.001) var composite_weight_g : float = 0.625
@export var composite_worley_b : Texture3D = preload("res://addons/SunshineClouds3/Compute/NoiseTextures/CompositeWorleyB.tres")
@export_range(0.0, 1.0, 0.001) var composite_weight_b : float = 0.25
@export var composite_worley_a : Texture3D = preload("res://addons/SunshineClouds3/Compute/NoiseTextures/CompositeWorleyA.tres")
@export_range(0.0, 1.0, 0.001) var composite_weight_a : float = 0.125
@export_file("*.res") var composite_path : String = "res://addons/SunshineClouds3/Compute/NoiseTextures/NoiseComposite.res"
@export_tool_button("Build Noise Composite", "Texture3D") var build_composite_action = build_noise_composite

@export_subgroup("Coverage Noise")
@export var coverage_noise : Texture2D = preload("res://addons/SunshineClouds3/Compute/NoiseTextures/CoverageNoise.tres")

@export_subgroup("Curl Noise")
## 3D curl noise (rgb = flow vector) that warps the view samples near the cloud base, as
## SunshineClouds2 does: turbulent, wind-torn bottoms.
@export var curl_noise : Texture3D = preload("res://addons/SunshineClouds3/Compute/NoiseTextures/curl_noise_packed.png")
## Curl steps per sample (SunshineClouds2 uses 3). Each is a 3D texture read. Seriously decreases performance if your not careful.
@export_range(1, 4) var curl_iterations : int = 4

@export_subgroup("Curl Noise Generator")
@export var curl_generator_size : Vector3i = Vector3i(128, 64, 128)

@export_range(1, 32) var curl_generator_frequency : int = 12
@export_range(1, 6) var curl_generator_octaves : int = 6

@export_range(0.0, 1.0, 0.01) var curl_generator_roughness : float = 0.09

@export_range(0.0, 1.0, 0.01) var curl_generator_turbulence : float = 0.0

@export_range(0.0, 1.0, 0.01) var curl_generator_vorticity : float = 1.0
@export var curl_generator_seed : int = 0
@export_file("*.res") var curl_generator_path : String = "res://addons/SunshineClouds3/Compute/NoiseTextures/CurlNoise.res"
## Not very good, the one that's a custom texture in here is honestly better.
@export_tool_button("Build Curl Noise", "Texture3D") var build_curl_action = build_curl_noise

@export_group("Shaders")
## In the editor, reload the shaders when one of the addon's .glsl or .glslinc files changes.
@export var auto_reload_shaders : bool = true
## Reimports and recompiles the shaders (the editor doesn't reimport the shaders including an
## edited .glslinc, and the clouds keep the shaders they compiled either way).
@export_tool_button("Reload Shaders", "Reload") var reload_shaders_action = reload_shaders

var rd : RenderingDevice
var shader : RID
var resolve_shader : RID
## The versions used with 3D MSAA.
var raymarch_msaa_shader : RID
var resolve_msaa_shader : RID
var msaa_composite_shader : RID
## The MSAA composite's render pipelines (multiply, add) by framebuffer format.
var msaa_composite_pipelines := {}
var shadow_shader : RID
var shadow_blend_shader : RID
var shadow_blend_pipeline : RID
var skybox_shader : RID
var skybox_blend_shader : RID
var skybox_blend_pipeline : RID
var sample_shader : RID
var precompute_shaders : Array[RID] = []
# Pipelines are created the first time they're needed (_pipeline()) and freed with their shader.
var raymarch_pipelines : Array[RID] = []
var resolve_pipelines : Array[RID] = []
var shadow_pipelines : Array[RID] = []
var skybox_pipelines : Array[RID] = []
var sample_pipelines : Array[RID] = []
var precompute_pipelines : Array[RID] = []

var nearest_sampler : RID
var noise_sampler : RID
var lut_sampler : RID
# Linear with mipmaps, repeating around: the background panorama.
var background_sampler : RID
# Bound in place of a missing background.
var black_texture : RID
var params_buffer : RID
var layers_buffer : RID
var shadow_buffer : RID
var sky_buffer : RID
var atmosphere_buffer : RID
var point_sample_data_buffer : RID
var lights_buffer : RID
var transmittance_texture : RID
var scattering_texture : RID
var irradiance_texture : RID
var shadow_texture : RID
var shadow_texture_resolution := 0
# Replaced textures and the engine frame from which they're freed.
var retired_textures : Array[RID] = []
var retired_frames := PackedInt64Array()

# ViewportStates by their RenderSceneBuffersRD's instance id.
var viewport_states := {}
# The current view's VIEW_TEXTURES.
var view_textures : Array[RID] = [RID(), RID(), RID(), RID(), RID(), RID()]
# Work done once per engine frame, whichever viewport draws first, and the shadow map's camera.
var last_engine_frame := -1
var shadow_camera := Vector3.ZERO
# With cloud_shadow_update_interval above 1 the map is rendered into the two keys in turn, and
# shadow_texture is blended between them every frame.
var shadow_keys : Array[RID] = [RID(), RID()]
# The key rendered last, how many keys hold a map (0 to 2), frames since the last one, and the
# camera and sun it was rendered for.
var shadow_key := 0
var shadow_keys_ready := 0
var shadow_age := 0
var shadow_key_camera := Vector3.ZERO
var shadow_key_sun := Vector3.ZERO
# The shadow map writing shadow_texture, key 0 and key 1.
var shadow_sets : Array[RID] = [RID(), RID(), RID()]
var shadow_blend_set : RID
var sample_set : RID
var density_set_inputs := PackedInt64Array()
# The skybox panorama, and the keys it's blended between, as the shadow map's (sizes 0
# while it's off). The key rendered last, how many hold a panorama, frames since the last render, and
# the camera height and up, sun and settings it was rendered for.
var skybox_texture : RID
var skybox_texture_size := Vector2i.ZERO
var skybox_keys : Array[RID] = [RID(), RID()]
var skybox_key := 0
var skybox_keys_ready := 0
var skybox_age := 0
var skybox_key_camera_height := 0.0
var skybox_key_up := Vector3.UP
var skybox_key_sun := Vector3.ZERO
var skybox_key_clouds := PackedByteArray()
var skybox_key_lights := 0
# The skybox render writing skybox_texture, key 0 and key 1, the blend, and the RIDs they were built with.
var skybox_sets : Array[RID] = [RID(), RID(), RID()]
var skybox_blend_set : RID
var skybox_set_inputs := PackedInt64Array()
# What SkySettings was last written from.
var sky_settings_key := []
# Whether the blend has reached the latest key, and a count of the skybox's changes
# (SunshineClouds3Driver refreshes its Sky's reflections when it moves).
var skybox_blended := false
var skybox_version := 0
# When a driver last asked for the skybox (request_skybox()); -1 = never.
var skybox_requested_msec := -1

var reflection_texture : Texture2DRD
var reflection_global := &""
var reflection_global_added := false
var reflection_update_queued := false
var reflection_rd : RID
var reflection_size := Vector2i.ZERO
var reflection_owner := 0
var reflection_shaders : Array[RID] = [RID(), RID()]
var reflection_pipelines : Array[RID] = [RID(), RID()]
var reflection_push := PackedByteArray()

# Upload staging, sized in _initialize().
var params_bytes := PackedByteArray()
var layers_bytes := PackedByteArray()
var shadow_bytes := PackedByteArray()
var sky_bytes := PackedByteArray()
var atmosphere_bytes := PackedByteArray()
var sample_bytes := PackedByteArray()
var push_bytes := PackedByteArray()

var atmosphere_changed : bool = true
var atmosphere_precompute_pending : bool = true
var noise_stats := Vector2(0.5, 0.25)
var noise_stats_texture : Texture3D
var profile_texture : ImageTexture
var profile_image : Image
var active_layers : Array[CloudLayer] = []
var synced_layers : Array[CloudLayer] = []

# The light projector the driver hands over (set_shadow_projector()).
var shadow_projector : RID
var shadow_projector_size := Vector2i.ZERO
var shadow_blit_material : RID
var shadow_light_transform : Transform3D
var shadow_projector_light_id := 0

# The lights and effectors for the clouds: encoded on the main thread by set_lights() and
# set_effectors() when what they depend on (their keys) changes, none without a recent call;
# uploaded on the render thread when dirty. With each directional light's instance id and direction,
# and the one that should cast the shadows.
var lights_mutex := Mutex.new()
var lights_bytes := PackedByteArray()
var effector_bytes := PackedByteArray()
var omni_count := 0
var effector_count := 0
var lights_key := []
var effectors_key := []
var lights_dirty := true
# Counts the lights' uploads.
var lights_version := 0
var uploaded_atmosphere_enabled := false
var lights_set_msec := -100000
var light_ids := PackedInt64Array([0, 0, 0, 0])
var light_directions := PackedVector3Array([Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO])
var light_id_count := 0
var wanted_caster_id := 0
var wanted_caster_direction := Vector3.ZERO
var point_scores := PackedFloat32Array()
var default_directional_settings := CloudDirectionalLightSettings.new()
var default_omni_settings := CloudOmniLightSettings.new()
var default_effector_settings := CloudEffectorSettings.new()
# The first listed directional light's direction, which the atmosphere follows as its sun.
var atmosphere_sun_direction := Vector3.UP
# The last directional lights a driver gave (each one's direction, colour * energy before the
# radiance scale and multiplier, and shadow samples) and the atmosphere's sun then, kept with the
# effect for the fallback.
@export_storage var has_last_directional := false
@export_storage var last_directional_directions := PackedVector3Array()
@export_storage var last_directional_radiance := PackedVector3Array()
@export_storage var last_directional_samples := PackedInt32Array()
@export_storage var last_sun_direction := Vector3.UP
# Whether a driver is giving the lights (calls in the last half second), whether the directional
# lights are the fallback ones, and what those were encoded from.
var lights_driven := false
var using_fallback := true
var fallback_key := []
# The light the shadow map is rendered for (instance id, 0 = none; the driver puts the projector on
# it) and its direction, and whether its shadows are fading out for the next one.
var shadow_caster_id := 0
var shadow_caster_direction := Vector3.ZERO
var shadow_fading := false
var shadow_source : Texture2DRD

# Cloud density samples, as SunshineClouds2 (same names): add_sample() queues a position and a
# callable, a frame with no batch in flight samples up to MAX_SAMPLE_POINTS of them, and the
# readback calls each callable in the order they were added. positionQueriesEncoded is how many
# the batch in flight answers.
var positionQueries : Array[Vector3] = []
var positionQueryCallables : Array[Callable] = []
var positionQuerying : bool = false
var positionResetting : bool = false
var positionQueriesEncoded : int = 0
var position_query_mutex := Mutex.new()

# The shader sources' md5s when auto_reload_shaders last looked, and when it looks next.
var shader_sources_hash := ""
var next_shader_check := 0


## What the clouds keep per viewport (its textures are in its render buffers).
class ViewportState:
	var frame := 0
	var prev_view_projections : Array[Projection] = []
	# Uniform sets per view and parity, rebuilt when an RID in set_inputs changes or the rendering
	# device drops them.
	var raymarch_sets : Array[RID] = []
	var resolve_sets : Array[RID] = []
	var set_inputs := PackedInt64Array()
	# While reflections are on: its internal size in pixels and the engine frame it last drew, which
	# pick the viewport writing the reflection image.
	var reflection_pixels := 0
	var reflection_frame := -1


## Queues a cloud density sample at position (world space): callable is called with
## (position : Vector3, density : float) a frame or two later, as SunshineClouds2's add_sample().
## density is the cloud density in 0..1 summed over the layers containing position, before each
## layer's density scales it.
func add_sample(callable : Callable, position : Vector3):
	position_query_mutex.lock()
	positionQueries.append(position)
	positionQueryCallables.append(callable)
	position_query_mutex.unlock()


## Called every frame by a SunshineClouds3Driver that puts the skybox (skybox_texture) on its
## WorldEnvironment: it's rendered only while asked for.
func request_skybox() -> void:
	skybox_requested_msec = Time.get_ticks_msec()


## The reflection image (see reflections_enabled) as a texture: also the global shader
## parameter's value. It can be given to a material's own uniform instead of using the global. Null
## while reflections are off; the same texture while they stay on (its size follows the viewport).
func get_reflection_texture() -> Texture2DRD:
	return reflection_texture


## Adds reflection_parameter to the project's shader globals (a sampler2D without a texture; the
## effect sets the texture at run time), and saves the project settings. In the editor.
func add_reflection_parameter_to_project() -> void:
	if reflection_parameter == &"":
		push_warning("SunshineClouds3: reflection_parameter is empty.")
		return
	var setting := "shader_globals/" + String(reflection_parameter)
	if ProjectSettings.has_setting(setting):
		print("SunshineClouds3: %s is already a project shader global." % reflection_parameter)
		return
	ProjectSettings.set_setting(setting, {"type": "sampler2D", "value": ""})
	ProjectSettings.save()
	# The editor's RenderingServer gets it as the shader globals editor would add it.
	if !RenderingServer.global_shader_parameter_get_list().has(reflection_parameter):
		RenderingServer.global_shader_parameter_add(reflection_parameter, RenderingServer.GLOBAL_VAR_TYPE_SAMPLER2D, RID())
	reflection_global = &""
	_update_reflection_global()
	print("SunshineClouds3: added %s to the project's shader globals." % reflection_parameter)


func _queue_reflection_update() -> void:
	if !reflection_update_queued:
		reflection_update_queued = true
		_update_reflection_global.call_deferred()



func _update_reflection_global() -> void:
	reflection_update_queued = false
	if RenderingServer.get_rendering_device() == null:
		return
	var wanted := reflection_parameter if reflections_enabled else &""
	if wanted != reflection_global:
		_release_reflection_global()
	if !reflections_enabled:
		if reflection_texture:
			reflection_texture = null
			RenderingServer.call_on_render_thread(_free_reflection_image)
		return
	if reflection_texture == null:
		reflection_texture = Texture2DRD.new()
		# A cleared image (distance 0: no image yet) until a viewport writes the real one.
		RenderingServer.call_on_render_thread(_create_reflection_image.bind(Vector2i(4, 4)))
	if wanted == &"" || wanted == reflection_global:
		return
	var existing := _existing_global_type(wanted)
	if existing == "":
		RenderingServer.global_shader_parameter_add(wanted, RenderingServer.GLOBAL_VAR_TYPE_SAMPLER2D, reflection_texture.get_rid())
		reflection_global_added = true
	elif existing == "sampler2D":
		RenderingServer.global_shader_parameter_set(wanted, reflection_texture.get_rid())
		reflection_global_added = false
	else:
		push_warning("SunshineClouds3: the shader global %s is a %s, not a sampler2D; the reflection image isn't set as it." % [wanted, existing])
		return
	reflection_global = wanted


func _existing_global_type(global_name : StringName) -> String:
	var setting := "shader_globals/" + String(global_name)
	if ProjectSettings.has_setting(setting):
		var value : Variant = ProjectSettings.get_setting(setting)
		return String(value.get("type", "")) if value is Dictionary else "?"
	if Engine.is_editor_hint() && RenderingServer.global_shader_parameter_get_list().has(global_name):
		return "sampler2D" if RenderingServer.global_shader_parameter_get_type(global_name) == RenderingServer.GLOBAL_VAR_TYPE_SAMPLER2D else "?"
	return ""


func _release_reflection_global() -> void:
	if reflection_global == &"":
		return
	if reflection_global_added:
		RenderingServer.global_shader_parameter_remove(reflection_global)
	elif _existing_global_type(reflection_global) == "sampler2D":
		RenderingServer.global_shader_parameter_set(reflection_global, RID())
	reflection_global = &""
	reflection_global_added = false


func _create_reflection_image(size : Vector2i) -> void:
	if rd == null || reflection_texture == null:
		return
	if reflection_rd.is_valid():
		_retire(reflection_rd)
	var format := RDTextureFormat.new()
	format.width = size.x
	format.height = size.y
	format.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT \
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT
	reflection_rd = rd.texture_create(format, RDTextureView.new())
	rd.texture_clear(reflection_rd, Color(0.0, 0.0, 0.0, 0.0), 0, 1, 0, 1)
	reflection_size = size
	reflection_texture.texture_rd_rid = reflection_rd


func _free_reflection_image() -> void:
	if reflection_rd.is_valid():
		_retire(reflection_rd)
	reflection_rd = RID()
	reflection_size = Vector2i.ZERO
	reflection_owner = 0


func _is_reflection_owner(buffers : RenderSceneBuffersRD, state : ViewportState, size : Vector2i, engine_frame : int) -> bool:
	state.reflection_pixels = size.x * size.y
	state.reflection_frame = engine_frame
	var id := buffers.get_instance_id()
	if id != reflection_owner:
		var owner : ViewportState = viewport_states.get(reflection_owner)
		if owner == null || owner.reflection_frame < engine_frame - 1 || state.reflection_pixels > owner.reflection_pixels:
			reflection_owner = id
	return id == reflection_owner


func _write_reflection(color_layer : RID, depth_layer : RID, msaa : bool, size : Vector2i, inv_projection : Projection) -> void:
	if !reflection_shaders[0].is_valid():
		var copy_shader := _load_shader(REFLECTION_SHADER_PATH, &"copy")
		var msaa_shader := _load_shader(REFLECTION_SHADER_PATH, &"msaa")
		if !copy_shader.is_valid() || !msaa_shader.is_valid():
			for s : RID in [copy_shader, msaa_shader]:
				if s.is_valid():
					rd.free_rid(s)
			return
		reflection_shaders = [copy_shader, msaa_shader]
		reflection_pipelines = [rd.compute_pipeline_create(copy_shader), rd.compute_pipeline_create(msaa_shader)]
		reflection_push.resize(80)
	if reflection_size != size || !rd.texture_is_valid(reflection_rd):
		_create_reflection_image(size)
	var version := int(msaa)
	_encode_mat4(reflection_push, 0, inv_projection)
	reflection_push.encode_u32(64, size.x)
	reflection_push.encode_u32(68, size.y)
	reflection_push.encode_float(72, max_distance * cloud_scale)
	var uniform_set := UniformSetCacheRD.get_cache(reflection_shaders[version], 0, [
		_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 0, [nearest_sampler, color_layer]),
		_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 1, [nearest_sampler, depth_layer]),
		_uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 2, [reflection_rd]),
	])
	var list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, reflection_pipelines[version])
	rd.compute_list_bind_uniform_set(list, uniform_set, 0)
	rd.compute_list_set_push_constant(list, reflection_push, reflection_push.size())
	rd.compute_list_dispatch(list, ceili(size.x / 8.0), ceili(size.y / 8.0), 1)
	rd.compute_list_end()


func _init() -> void:
	effect_callback_type = CompositorEffect.EFFECT_CALLBACK_TYPE_PRE_TRANSPARENT
	lights_bytes.resize(144 + MAX_OMNI_LIGHTS * 48) # Lights block head: 144 byte header + directional lights, then 48 bytes per omni light; effectors follow. Must match the Lights block layout in SunshineClouds3Raymarch.glsl.
	effector_bytes.resize(MAX_EFFECTORS * 48)
	# Initial values don't go through the setters.
	_sync_layers()
	RenderingServer.call_on_render_thread(_initialize)
	if Engine.is_editor_hint() && Engine.get_main_loop() is SceneTree:
		shader_sources_hash = _shader_sources_hash()
		(Engine.get_main_loop() as SceneTree).process_frame.connect(_check_shader_sources)


func _notification(what : int) -> void:
	if what != NOTIFICATION_PREDELETE || rd == null:
		return
	# Pipelines and uniform sets go with the shaders and resources they use.
	var rids : Array[RID] = [shader, resolve_shader, shadow_shader, shadow_blend_shader, skybox_shader, skybox_blend_shader, sample_shader,
		raymarch_msaa_shader, resolve_msaa_shader, msaa_composite_shader,
		nearest_sampler, noise_sampler, lut_sampler, background_sampler,
		params_buffer, layers_buffer, shadow_buffer, sky_buffer, atmosphere_buffer, point_sample_data_buffer, lights_buffer,
		transmittance_texture, scattering_texture, irradiance_texture, shadow_texture, shadow_keys[0], shadow_keys[1],
		skybox_texture, skybox_keys[0], skybox_keys[1], black_texture, reflection_shaders[0], reflection_shaders[1]]
	# A global this effect added goes with it (written out: its own functions can't be called here).
	if reflection_global != &"" && reflection_global_added:
		RenderingServer.global_shader_parameter_remove(reflection_global)
	if rd.texture_is_valid(reflection_rd):
		rids.append(reflection_rd)
	rids.append_array(precompute_shaders)
	for texture in retired_textures:
		if rd.texture_is_valid(texture):
			rids.append(texture)
	for rid in rids:
		if rid.is_valid():
			rd.free_rid(rid)
	for id : int in viewport_states:
		var buffers := instance_from_id(id) as RenderSceneBuffersRD
		if buffers:
			buffers.clear_context(BUFFERS_CONTEXT)


## Reimports (in the editor) and recompiles the shaders, then swaps them in on the render thread.
## If one doesn't compile, the clouds keep the shaders they had.
func reload_shaders() -> void:
	# EditorInterface only exists in editor builds; naming it directly fails to parse in exports.
	if Engine.is_editor_hint() && Engine.has_singleton(&"EditorInterface"):
		Engine.get_singleton(&"EditorInterface").get_resource_filesystem().reimport_files(PackedStringArray(DRAW_SHADER_PATHS))
	for path : String in DRAW_SHADER_PATHS:
		ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_REPLACE)
	RenderingServer.call_on_render_thread(_reload_shaders)


func _reload_shaders() -> void:
	if rd == null:
		return
	if !params_buffer.is_valid():
		_initialize()
	elif !_create_shaders():
		push_error("SunshineClouds3: kept the previous shaders, see the compile errors above.")
		return
	atmosphere_precompute_pending = true
	shadow_keys_ready = 0
	skybox_keys_ready = 0
	for state : ViewportState in viewport_states.values():
		state.prev_view_projections.clear()
	print("SunshineClouds3: shaders reloaded.")


## auto_reload_shaders' check, every frame in the editor.
func _check_shader_sources() -> void:
	if !auto_reload_shaders || Time.get_ticks_msec() < next_shader_check:
		return
	next_shader_check = Time.get_ticks_msec() + 1000 # Shader source poll interval (ms) for auto_reload_shaders. 500-2000: lower reacts faster to saves but hashes every shader file more often.
	if !Engine.has_singleton(&"EditorInterface") || Engine.get_singleton(&"EditorInterface").get_resource_filesystem().is_scanning():
		return
	var sources_hash := _shader_sources_hash()
	if sources_hash != shader_sources_hash:
		shader_sources_hash = sources_hash
		reload_shaders()


func _shader_sources_hash() -> String:
	var hashes := PackedStringArray()
	for directory : String in ["res://addons/SunshineClouds3/Compute/", "res://addons/SunshineClouds3/Compute/atmosphere/"]: # Folders whose .glsl and .glslinc files auto_reload_shaders watches; add any new shader folder here.
		for file in DirAccess.get_files_at(directory):
			if file.get_extension() == "glsl" || file.get_extension() == "glslinc":
				hashes.append(FileAccess.get_md5(directory + file))
	return "".join(hashes)


## Rebuilds active_layers from the enabled layers, and again whenever a layer changes (toggled or
## its curves edited), rebaking the profiles.
func _sync_layers() -> void:
	var active : Array[CloudLayer] = []
	var enabled_count := 0
	for layer in layers:
		if layer && layer.enabled:
			enabled_count += 1
			if active.size() < MAX_LAYERS:
				active.append(layer)
	if enabled_count > active.size() && active != active_layers:
		push_warning("SunshineClouds3: only the first %d enabled layers are drawn." % MAX_LAYERS)
	for layer in synced_layers:
		if layer && !layers.has(layer) && layer.changed.is_connected(_sync_layers):
			layer.changed.disconnect(_sync_layers)
	for layer in layers:
		if layer && !layer.changed.is_connected(_sync_layers):
			layer.changed.connect(_sync_layers)
	active_layers = active
	synced_layers = layers.duplicate()
	_bake_profile()


func _bake_profile() -> void:
	var width := maxi(profile_resolution, 2)
	var rows := maxi(active_layers.size(), 1)
	if profile_image == null || profile_image.get_width() != width || profile_image.get_height() != rows:
		profile_image = Image.create_empty(width, rows, false, Image.FORMAT_RGBAH)
	for row in active_layers.size():
		for x in width:
			profile_image.set_pixel(x, row, active_layers[row].sample_profile(x / float(width - 1)))
	if profile_texture && profile_texture.get_width() == width && profile_texture.get_height() == rows:
		profile_texture.update(profile_image)
	else:
		profile_texture = ImageTexture.create_from_image(profile_image)


func build_noise_composite() -> void:
	var inputs : Array[Texture3D] = [composite_perlin, composite_worley_g, composite_worley_b, composite_worley_a]
	if composite_perlin_worley:
		inputs.append(composite_perlin_worley)
	var slices : Array = []
	for texture in inputs:
		if texture == null:
			push_error("SunshineClouds3: a noise composite input is missing.")
			return
		var data := texture.get_data()
		if data.is_empty():
			push_error("SunshineClouds3: %s has no data yet (still generating?)." % texture.resource_path)
			return
		if Vector3i(texture.get_width(), texture.get_height(), texture.get_depth()) != Vector3i(inputs[0].get_width(), inputs[0].get_height(), inputs[0].get_depth()):
			push_error("SunshineClouds3: noise composite inputs must all be the same size.")
			return
		var bytes : Array[PackedByteArray] = []
		for image in data:
			if image.get_format() != Image.FORMAT_L8:
				image = image.duplicate()
				image.convert(Image.FORMAT_L8)
			bytes.append(image.get_data())
		slices.append(bytes)

	var width := inputs[0].get_width()
	var height := inputs[0].get_height()
	var no_worley := PackedByteArray()
	no_worley.resize(width * height)
	var weight_g := composite_weight_g / 255.0
	var weight_b := composite_weight_b / 255.0
	var weight_a := composite_weight_a / 255.0
	var images : Array[Image] = []
	for z in inputs[0].get_depth():
		var perlin : PackedByteArray = slices[0][z]
		var worley : PackedByteArray = slices[4][z] if composite_perlin_worley else no_worley
		var g : PackedByteArray = slices[1][z]
		var b : PackedByteArray = slices[2][z]
		var a : PackedByteArray = slices[3][z]
		var out := PackedByteArray()
		out.resize(width * height)
		for i in width * height:
			# Perlin-Worley: remap(perlin, 0, 1, worley, 1).
			var perlin_worley := (worley[i] + perlin[i] * (255 - worley[i]) / 255.0) / 255.0
			var worley_fbm := g[i] * weight_g + b[i] * weight_b + a[i] * weight_a
			# remap(perlin_worley, worley_fbm - 1, 1, 0, 1)
			var value := (perlin_worley - (worley_fbm - 1.0)) / maxf(2.0 - worley_fbm, 1e-4)
			out[i] = clampi(roundi(value * 255.0), 0, 255)
		images.append(Image.create_from_data(width, height, false, Image.FORMAT_R8, out))

	var composite := _save_texture_3d(composite_path, Image.FORMAT_R8, Vector3i(width, height, images.size()), images)
	if composite:
		noise_texture = composite

## genuinely sucks, I need to work on this.
func build_curl_noise() -> void:
	var size := curl_generator_size.clamp(Vector3i.ONE * 4, Vector3i.ONE * 512)
	var finest_cell := float(mini(size.x, mini(size.y, size.z))) / (curl_generator_frequency << (curl_generator_octaves - 1))
	if finest_cell < 2.0:
		push_warning("SunshineClouds3: the finest curl octave is %.1f voxels per cell on the smallest axis and will alias; lower the frequency or octaves." % finest_cell)
	var local_rd := RenderingServer.create_local_rendering_device()
	if local_rd == null:
		push_error("SunshineClouds3: building curl noise needs a RenderingDevice (Forward+ or Mobile).")
		return
	var spirv := (load("res://addons/SunshineClouds3/Compute/SunshineClouds3CurlNoise.glsl") as RDShaderFile).get_spirv() # Curl noise bake compute shader, run once when the curl texture is (re)built.
	var curl_shader := local_rd.shader_create_from_spirv(spirv) if spirv.compile_error_compute.is_empty() else RID()
	if !curl_shader.is_valid():
		push_error("SunshineClouds3CurlNoise.glsl: %s" % spirv.compile_error_compute)
		local_rd.free()
		return
	var curl_pipeline := local_rd.compute_pipeline_create(curl_shader)
	var texture_format := RDTextureFormat.new()
	texture_format.texture_type = RenderingDevice.TEXTURE_TYPE_3D
	texture_format.width = size.x
	texture_format.height = size.y
	texture_format.depth = size.z
	texture_format.format = RenderingDevice.DATA_FORMAT_R8G8B8A8_UNORM
	texture_format.usage_bits = RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	var texture := local_rd.texture_create(texture_format, RDTextureView.new())
	var range_bytes := PackedByteArray()
	range_bytes.resize(16)
	var range_buffer := local_rd.storage_buffer_create(range_bytes.size(), range_bytes)
	var uniform_set := local_rd.uniform_set_create([
		_uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 0, [texture]),
		_uniform(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 1, [range_buffer]),
	], curl_shader, 0)
	var push := PackedByteArray()
	push.resize(48)
	push.encode_s32(0, size.x)
	push.encode_s32(4, size.y)
	push.encode_s32(8, size.z)
	push.encode_s32(12, curl_generator_frequency)
	push.encode_s32(16, curl_generator_octaves)
	push.encode_float(20, curl_generator_roughness)
	push.encode_float(24, curl_generator_turbulence)
	push.encode_float(28, curl_generator_vorticity)
	push.encode_u32(32, curl_generator_seed & 0xFFFFFFFF)
	# Stage 0 finds the largest flow component, stage 1 the RMS, stage 2 writes the normalised flow.
	for stage in 3:
		push.encode_u32(36, stage)
		var list := local_rd.compute_list_begin()
		local_rd.compute_list_bind_compute_pipeline(list, curl_pipeline)
		local_rd.compute_list_bind_uniform_set(list, uniform_set, 0)
		local_rd.compute_list_set_push_constant(list, push, push.size())
		local_rd.compute_list_dispatch(list, ceili(size.x / 4.0), ceili(size.y / 4.0), ceili(size.z / 4.0))
		local_rd.compute_list_end()
		local_rd.submit()
		local_rd.sync()
	# A 3D texture's data is all its slices, one after another.
	var data := local_rd.texture_get_data(texture, 0)
	for rid in [uniform_set, texture, range_buffer, curl_shader]:
		local_rd.free_rid(rid)
	local_rd.free()

	var slice_bytes := size.x * size.y * 4
	var images : Array[Image] = []
	for z in size.z:
		images.append(Image.create_from_data(size.x, size.y, false, Image.FORMAT_RGBA8, data.slice(z * slice_bytes, (z + 1) * slice_bytes)))
	var curl := _save_texture_3d(curl_generator_path, Image.FORMAT_RGBA8, size, images)
	if curl:
		curl_noise = curl


## Saves images as an ImageTexture3D at path, rebuilding the loaded texture in place so everything
## using it updates. Returns null if it couldn't be saved.
func _save_texture_3d(path : String, format : Image.Format, size : Vector3i, images : Array[Image]) -> ImageTexture3D:
	var texture : ImageTexture3D
	if ResourceLoader.has_cached(path):
		texture = ResourceLoader.get_cached_ref(path) as ImageTexture3D
	if texture == null:
		texture = ImageTexture3D.new()
	texture.create(format, size.x, size.y, size.z, false, images)
	var error := ResourceSaver.save(texture, path, ResourceSaver.FLAG_COMPRESS)
	if error != OK:
		push_error("SunshineClouds3: could not save %s (%s)." % [path, error_string(error)])
		return null
	texture.take_over_path(path)
	if Engine.is_editor_hint() && Engine.has_singleton(&"EditorInterface"):
		Engine.get_singleton(&"EditorInterface").get_resource_filesystem().update_file(path)
	return texture


func _initialize() -> void:
	rd = RenderingServer.get_rendering_device()
	if rd == null || !_create_shaders():
		return

	atmosphere_buffer = rd.uniform_buffer_create(ATMOSPHERE_BYTES)
	transmittance_texture = _create_atmosphere_texture(TRANSMITTANCE_SIZE, RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT)
	scattering_texture = _create_atmosphere_texture(SCATTERING_SIZE, RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT)
	irradiance_texture = _create_atmosphere_texture(IRRADIANCE_SIZE, RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT)

	var sampler_state := RDSamplerState.new()
	nearest_sampler = rd.sampler_create(sampler_state)
	sampler_state.min_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.mag_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	lut_sampler = rd.sampler_create(sampler_state)
	sampler_state.repeat_u = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	sampler_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	sampler_state.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_REPEAT
	noise_sampler = rd.sampler_create(sampler_state)
	sampler_state.mip_filter = RenderingDevice.SAMPLER_FILTER_LINEAR
	sampler_state.repeat_v = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	sampler_state.repeat_w = RenderingDevice.SAMPLER_REPEAT_MODE_CLAMP_TO_EDGE
	background_sampler = rd.sampler_create(sampler_state)
	var black_format := RDTextureFormat.new()
	black_format.width = 4
	black_format.height = 4
	black_format.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
	black_format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT
	black_texture = rd.texture_create(black_format, RDTextureView.new())
	rd.texture_clear(black_texture, Color(0.0, 0.0, 0.0, 0.0), 0, 1, 0, 1)
	params_buffer = rd.uniform_buffer_create(PARAMS_BYTES)
	layers_buffer = rd.uniform_buffer_create(MAX_LAYERS * LAYER_BYTES)
	shadow_buffer = rd.uniform_buffer_create(SHADOW_BYTES)
	sky_buffer = rd.uniform_buffer_create(SKY_BYTES)
	point_sample_data_buffer = rd.storage_buffer_create(SAMPLE_BUFFER_BYTES)
	lights_buffer = rd.uniform_buffer_create(144 + (MAX_OMNI_LIGHTS + MAX_EFFECTORS) * 48) # Full Lights block: 144 byte header + directional lights, then 48 bytes per point (omni lights then effectors). Must match the points array size in SunshineClouds3Raymarch.glsl.

	params_bytes.resize(PARAMS_BYTES)
	layers_bytes.resize(MAX_LAYERS * LAYER_BYTES)
	shadow_bytes.resize(SHADOW_BYTES)
	sky_bytes.resize(SKY_BYTES)
	atmosphere_bytes.resize(ATMOSPHERE_BYTES)
	sample_bytes.resize(SAMPLE_BUFFER_BYTES)
	push_bytes.resize(16)
	density_set_inputs.resize(7)
	skybox_set_inputs.resize(7)


## Compiles the shaders, freeing the ones they replace (their pipelines and uniform sets go with
## them). Returns false, keeping the old shaders, if one that draws doesn't compile; without the
## sample shader samples just stay queued.
func _create_shaders() -> bool:
	var new_shaders : Array[RID] = [_load_shader(SHADER_PATH, &"raymarch"), _load_shader(RESOLVE_SHADER_PATH, &"resolve"),
		_load_shader(SHADER_PATH, &"shadow_map"), _load_shader(SHADER_PATH, &"shadow_blend"),
		_load_shader(SHADER_PATH, &"skybox"), _load_shader(SHADER_PATH, &"skybox_blend"),
		_load_shader(SHADER_PATH, &"raymarch_msaa"), _load_shader(RESOLVE_SHADER_PATH, &"msaa"), _load_shader(MSAA_COMPOSITE_SHADER_PATH)]
	for version : String in PRECOMPUTE_VERSIONS:
		new_shaders.append(_load_shader(ATMOSPHERE_PRECOMPUTE_PATH, version))
	if new_shaders.has(RID()):
		for s in new_shaders:
			if s.is_valid():
				rd.free_rid(s)
		return false
	var new_sample_shader := _load_shader(SHADER_PATH, &"sample_points")
	for s : RID in [shader, resolve_shader, shadow_shader, shadow_blend_shader, skybox_shader, skybox_blend_shader, sample_shader,
			raymarch_msaa_shader, resolve_msaa_shader, msaa_composite_shader] + precompute_shaders:
		if s.is_valid():
			rd.free_rid(s)
	shader = new_shaders[0]
	resolve_shader = new_shaders[1]
	shadow_shader = new_shaders[2]
	shadow_blend_shader = new_shaders[3]
	shadow_blend_pipeline = rd.compute_pipeline_create(shadow_blend_shader)
	skybox_shader = new_shaders[4]
	skybox_blend_shader = new_shaders[5]
	skybox_blend_pipeline = rd.compute_pipeline_create(skybox_blend_shader)
	raymarch_msaa_shader = new_shaders[6]
	resolve_msaa_shader = new_shaders[7]
	msaa_composite_shader = new_shaders[8]
	msaa_composite_pipelines.clear()
	# The reflection shaders load again the next time they're used.
	for s : RID in reflection_shaders:
		if s.is_valid():
			rd.free_rid(s)
	reflection_shaders = [RID(), RID()]
	reflection_pipelines = [RID(), RID()]
	precompute_shaders = new_shaders.slice(9)
	sample_shader = new_sample_shader

	for pipelines : Array[RID] in [raymarch_pipelines, resolve_pipelines, shadow_pipelines, skybox_pipelines, sample_pipelines, precompute_pipelines]:
		pipelines.clear()
	raymarch_pipelines.resize((MAX_LAYERS + 1) * 3 * 2) # Per layer count and interlace pass, without and with MSAA.
	resolve_pipelines.resize(4) # Atmosphere off/on, without and with MSAA.
	shadow_pipelines.resize(MAX_LAYERS + 1)
	skybox_pipelines.resize(MAX_LAYERS + 1)
	sample_pipelines.resize(MAX_LAYERS + 1)
	precompute_pipelines.resize(PRECOMPUTE_VERSIONS.size())
	return true


func _load_shader(path : String, version : StringName = &"") -> RID:
	var shader_file : RDShaderFile = load(path)
	if shader_file == null:
		push_error("Could not load %s." % path)
		return RID()
	var spirv := shader_file.get_spirv(version)
	var compile_error := spirv.compile_error_compute + spirv.compile_error_vertex + spirv.compile_error_fragment
	if !compile_error.is_empty():
		push_error("%s %s: %s" % [path.get_file(), version, compile_error])
		return RID()
	return rd.shader_create_from_spirv(spirv)


## pipelines[index], created the first time with constant 0 (and 1) set to the given values.
func _pipeline(pipelines : Array[RID], index : int, pipeline_shader : RID, constant_0 : Variant = null, constant_1 : Variant = null) -> RID:
	if !pipelines[index].is_valid():
		var constants : Array[RDPipelineSpecializationConstant] = []
		for value : Variant in [constant_0, constant_1]:
			if value != null:
				var constant := RDPipelineSpecializationConstant.new()
				constant.constant_id = constants.size()
				constant.value = value
				constants.append(constant)
		pipelines[index] = rd.compute_pipeline_create(pipeline_shader, constants)
	return pipelines[index]


## 2D when size.z is 1, 3D otherwise; sampled and written by the atmosphere passes.
func _create_atmosphere_texture(size : Vector3i, format : RenderingDevice.DataFormat) -> RID:
	var texture_format := RDTextureFormat.new()
	texture_format.texture_type = RenderingDevice.TEXTURE_TYPE_2D if size.z == 1 else RenderingDevice.TEXTURE_TYPE_3D
	texture_format.width = size.x
	texture_format.height = size.y
	texture_format.depth = size.z
	texture_format.format = format
	texture_format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT
	return rd.texture_create(texture_format, RDTextureView.new())


## Frees a texture a few frames from now.
func _retire(texture : RID) -> void:
	retired_textures.append(texture)
	retired_frames.append(Engine.get_frames_drawn() + 3) # Frames a replaced texture waits before it's freed: freeing mid frame breaks materials drawn later that frame. 2-4: needs to cover the frames in flight; higher only holds VRAM longer.


func _precompute_dispatch(version : int, uniforms : Array[RDUniform], size : Vector3i, scattering_order : int = 0) -> void:
	var all_uniforms : Array[RDUniform] = [_uniform(RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER, 0, [atmosphere_buffer])]
	all_uniforms.append_array(uniforms)
	push_bytes.encode_s32(0, scattering_order)
	var list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(list, _pipeline(precompute_pipelines, version, precompute_shaders[version]))
	rd.compute_list_bind_uniform_set(list, UniformSetCacheRD.get_cache(precompute_shaders[version], 0, all_uniforms), 0)
	rd.compute_list_set_push_constant(list, push_bytes, push_bytes.size())
	rd.compute_list_dispatch(list, ceili(size.x / 8.0), ceili(size.y / 8.0), size.z)
	rd.compute_list_end()


## Records rid at inputs[index], returning true if it differs from what was there.
func _set_input(inputs : PackedInt64Array, index : int, rid : RID) -> bool:
	var id := rid.get_id()
	if inputs[index] == id:
		return false
	inputs[index] = id
	return true


func _uniform(type : RenderingDevice.UniformType, binding : int, ids : Array[RID]) -> RDUniform:
	var uniform := RDUniform.new()
	uniform.uniform_type = type
	uniform.binding = binding
	for id in ids:
		uniform.add_id(id)
	return uniform


## Called by SunshineClouds3Driver on the render thread: the light projector (a DrawableTexture2D
## of target_size) the shadow map is blitted into each frame through blit_material, and the
## transform and instance id of the light it's on (shadow_caster_id). An invalid target means none:
## the shadows fall back to screen space.
func set_shadow_projector(target : RID, target_size : Vector2i, blit_material : RID, light_transform : Transform3D, light_id : int) -> void:
	shadow_projector = target
	shadow_projector_size = target_size
	shadow_blit_material = blit_material
	shadow_light_transform = light_transform
	shadow_projector_light_id = light_id


## Called by SunshineClouds3Driver every frame (main thread), with set_effectors(): the lights on the
## clouds, each with its settings at the same index (defaults where there are none). A light's
## energy on the clouds is light_energy * light_volumetric_fog_energy * its settings'
## energy_multiplier * the effect's directional or omni energy multiplier. The first directional
## light is the atmosphere's sun. The strongest directional light that may cast cloud shadows
## (energy faded towards the horizon as its shadows are) casts them. A SunshineOmniLight uses its
## own settings, and its cloud_radius as its range. Omni lights count only where their range reaches the layers, the nearest MAX_OMNI_LIGHTS to camera_position when more do. They
## are encoded again only when what they depend on changes. Without a call for half a second there
## are none, and the directional lights fall back (see fallback_light_elevation), as they do while
## none of the directional lights given exist.
func set_lights(directional_lights : Array[DirectionalLight3D], directional_settings : Array[CloudDirectionalLightSettings],
		omni_lights : Array[OmniLight3D], omni_settings : Array[CloudOmniLightSettings], camera_position : Vector3) -> void:
	var layers_span := _layers_span()
	var key := [radiance_scale, directional_energy_multiplier, omni_energy_multiplier, cloud_shadow_horizon_fade, light_step_growth,
		light_march_distance, layers_span, cloud_scale]
	if omni_lights.size() > MAX_OMNI_LIGHTS:
		# Which are the nearest moves with the camera.
		key.append(camera_position)
	for i in directional_lights.size():
		if !is_instance_valid(directional_lights[i]):
			key.append(null)
			continue
		var light : DirectionalLight3D = directional_lights[i]
		var settings := directional_settings[i] if i < directional_settings.size() && directional_settings[i] else default_directional_settings
		key.append_array([light, light.global_transform.basis, light.light_energy, light.light_volumetric_fog_energy, light.is_visible_in_tree(),
			settings.color, settings.energy_multiplier, settings.cast_cloud_shadows, settings.shadow_samples])
	for i in omni_lights.size():
		if !is_instance_valid(omni_lights[i]):
			key.append(null)
			continue
		var light : OmniLight3D = omni_lights[i]
		key.append_array([light, light.global_position, light.omni_attenuation, light.light_color, light.light_energy,
			light.light_volumetric_fog_energy, light.is_visible_in_tree(), _omni_shape(light, omni_settings, i)])
	lights_mutex.lock()
	lights_set_msec = Time.get_ticks_msec()
	lights_driven = true
	if key != lights_key:
		lights_key = key
		_encode_directional_lights(directional_lights, directional_settings)
		omni_count = _encode_omni_lights(omni_lights, omni_settings, camera_position, layers_span)
		lights_dirty = true
	lights_mutex.unlock()


## Called by SunshineClouds3Driver every frame (main thread), with set_lights(): the effectors on the
## clouds, each with its settings at the same index (defaults where there are none; a SunshineEffector
## uses its own). Each one's radius is scaled by its largest scale. They count only where their radius
## reaches the layers, the nearest MAX_EFFECTORS to camera_position when more do, and follow the omni
## lights in the Lights buffer. They are encoded again only when what they depend on changes.
func set_effectors(effectors : Array[Node3D], effector_settings : Array[CloudEffectorSettings], camera_position : Vector3) -> void:
	var key := [_layers_span()]
	if effectors.size() > MAX_EFFECTORS:
		key.append(camera_position)
	for i in effectors.size():
		if !is_instance_valid(effectors[i]):
			key.append(null)
			continue
		var effector : Node3D = effectors[i]
		key.append_array([effector, effector.global_position, effector.is_visible_in_tree(), _effector_shape(effector, effector_settings, i)])
	lights_mutex.lock()
	lights_set_msec = Time.get_ticks_msec()
	lights_driven = true
	if key != effectors_key:
		effectors_key = key
		effector_count = _encode_effectors(effectors, effector_settings, camera_position, key[0])
		lights_dirty = true
	lights_mutex.unlock()


# The lowest floor and highest ceiling of the layers, times cloud_scale.
func _layers_span() -> Vector2:
	var span := Vector2(INF, -INF)
	for layer in active_layers:
		span = Vector2(minf(span.x, layer.cloud_floor), maxf(span.y, layer.cloud_ceiling))
	return span * cloud_scale


func _reaches_layers(position : Vector3, radius : float, layers_span : Vector2) -> bool:
	var height := get_cloud_height(position)
	return radius > 0.0 && height - radius <= layers_span.y && height + radius >= layers_span.x


## The planet's centre: planet_center with spherical_planet, else (0, -planet_radius, 0). Its radius
## is scaled by cloud_scale with the top of the planet staying put.
func get_planet_center() -> Vector3:
	var center := planet_center if spherical_planet else Vector3(0.0, -planet_radius * 1000.0, 0.0)
	return center + Vector3.UP * planet_radius * 1000.0 * (1.0 - cloud_scale)


## The height the cloud layers are placed by at position: world Y, or with spherical_planet the
## altitude above the planet's surface.
func get_cloud_height(position : Vector3) -> float:
	return position.distance_to(get_planet_center()) - planet_radius * 1000.0 * cloud_scale if spherical_planet else position.y


## Up at position: away from the planet's centre with spherical_planet, else +Y.
func get_planet_up(position : Vector3) -> Vector3:
	return (position - get_planet_center()).normalized() if spherical_planet else Vector3.UP


# Encodes the directional lights (at most MAX_DIRECTIONAL_LIGHTS) and picks the shadow caster, and
# keeps them for the fallback. With none of them existing, the fallback lights instead.
func _encode_directional_lights(lights : Array[DirectionalLight3D], settings : Array[CloudDirectionalLightSettings]) -> void:
	var directional_radiance := _solar_irradiance() * radiance_scale * directional_energy_multiplier
	var horizon := sin(deg_to_rad(cloud_shadow_horizon_fade))
	light_id_count = 0
	wanted_caster_id = 0
	wanted_caster_direction = Vector3.ZERO
	if !lights.is_empty() && is_instance_valid(lights[0]):
		atmosphere_sun_direction = lights[0].global_transform.basis.z.normalized()
	var any_exist := false
	var directions := PackedVector3Array()
	var radiances := PackedVector3Array()
	var samples := PackedInt32Array()
	var caster_strength := 0.0
	for i in lights.size():
		if !is_instance_valid(lights[i]):
			continue
		# Hidden or unlit ones count: they're the lights given, just dark.
		any_exist = true
		if light_id_count == MAX_DIRECTIONAL_LIGHTS:
			continue
		var light := lights[i]
		var energy := light.light_energy * light.light_volumetric_fog_energy
		if !light.is_visible_in_tree() || energy <= 0.0:
			continue
		var light_settings := settings[i] if i < settings.size() && settings[i] else default_directional_settings
		var direction := light.global_transform.basis.z.normalized()
		var color := light_settings.color
		var radiance := Vector3(color.r, color.g, color.b) * energy * light_settings.energy_multiplier
		_encode_vec4(lights_bytes, 16 + light_id_count * 32, direction, _first_light_step(light_settings.shadow_samples))
		_encode_vec4(lights_bytes, 32 + light_id_count * 32, directional_radiance * radiance, light_settings.shadow_samples)
		directions.append(direction)
		radiances.append(radiance)
		samples.append(light_settings.shadow_samples)
		light_ids[light_id_count] = light.get_instance_id()
		light_directions[light_id_count] = direction
		light_id_count += 1
		var strength := energy * (smoothstep(0.0, horizon, direction.y) if horizon > 0.0 else (1.0 if direction.y > 0.0 else 0.0))
		if light_settings.cast_cloud_shadows && strength > caster_strength:
			caster_strength = strength
			wanted_caster_id = light.get_instance_id()
			wanted_caster_direction = direction
	if !any_exist:
		_encode_fallback_lights()
		return
	using_fallback = false
	has_last_directional = true
	last_directional_directions = directions
	last_directional_radiance = radiances
	last_directional_samples = samples
	last_sun_direction = atmosphere_sun_direction
	lights_bytes.encode_s32(0, light_id_count)


# Encodes the directional lights without a driver's: the last ones a driver gave, else the fallback
# light. Neither casts the shadow map (there's no light to project it from).
func _encode_fallback_lights() -> void:
	using_fallback = true
	fallback_key = _fallback_key()
	light_id_count = 0
	wanted_caster_id = 0
	wanted_caster_direction = Vector3.ZERO
	var directional_radiance := _solar_irradiance() * radiance_scale * directional_energy_multiplier
	var count := 0
	if has_last_directional:
		count = mini(mini(last_directional_directions.size(), last_directional_radiance.size()), mini(last_directional_samples.size(), MAX_DIRECTIONAL_LIGHTS))
		for n in count:
			_encode_vec4(lights_bytes, 16 + n * 32, last_directional_directions[n], _first_light_step(last_directional_samples[n]))
			_encode_vec4(lights_bytes, 32 + n * 32, directional_radiance * last_directional_radiance[n], last_directional_samples[n])
		atmosphere_sun_direction = last_sun_direction
	else:
		var elevation := deg_to_rad(fallback_light_elevation)
		var azimuth := deg_to_rad(fallback_light_azimuth)
		var direction := Vector3(cos(elevation) * sin(azimuth), sin(elevation), cos(elevation) * cos(azimuth))
		var color := fallback_light_color
		var shadow_samples := default_directional_settings.shadow_samples
		_encode_vec4(lights_bytes, 16, direction, _first_light_step(shadow_samples))
		_encode_vec4(lights_bytes, 32, directional_radiance * Vector3(color.r, color.g, color.b) * fallback_light_energy, shadow_samples)
		count = 1
		atmosphere_sun_direction = direction
	lights_bytes.encode_s32(0, count)


# What the fallback lights are encoded from (checked on the render thread while they're in use).
func _fallback_key() -> Array:
	return [radiance_scale, directional_energy_multiplier, light_step_growth, light_march_distance, cloud_scale, has_last_directional,
		last_directional_directions, last_directional_radiance, last_directional_samples, last_sun_direction,
		fallback_light_elevation, fallback_light_azimuth, fallback_light_color, fallback_light_energy]


## Forgets the last directional lights a driver gave, so the fallback light lights the clouds until
## one gives some again.
func forget_last_lights() -> void:
	lights_mutex.lock()
	has_last_directional = false
	last_directional_directions = PackedVector3Array()
	last_directional_radiance = PackedVector3Array()
	last_directional_samples = PackedInt32Array()
	last_sun_direction = Vector3.UP
	lights_mutex.unlock()


# Encodes the omni lights reaching the layers as the first points. Returns how many.
func _encode_omni_lights(lights : Array[OmniLight3D], settings : Array[CloudOmniLightSettings], camera_position : Vector3, layers_span : Vector2) -> int:
	var reaching := 0
	_size_point_scores(lights.size())
	for i in lights.size():
		if !is_instance_valid(lights[i]):
			continue
		var light := lights[i]
		var shape := _omni_shape(light, settings, i)
		if light.is_visible_in_tree() && light.light_energy * light.light_volumetric_fog_energy > 0.0 \
				&& _reaches_layers(light.global_position, shape.x, layers_span):
			point_scores[i] = camera_position.distance_to(light.global_position) - shape.x
			reaching += 1
	var count := mini(reaching, MAX_OMNI_LIGHTS)
	for n in count:
		var i := _next_point(lights.size(), reaching > count)
		var light := lights[i]
		var shape := _omni_shape(light, settings, i)
		var radiance := Vector3(light.light_color.r, light.light_color.g, light.light_color.b) * light.light_energy * light.light_volumetric_fog_energy \
			* shape.y * omni_energy_multiplier
		_encode_vec4(lights_bytes, 144 + n * 48, light.global_position, shape.x)
		_encode_vec4(lights_bytes, 160 + n * 48, radiance, light.omni_attenuation)
		_encode_vec4(lights_bytes, 176 + n * 48, Vector3(shape.z, _first_light_step(int(shape.z)), 0.0), 0.0)
	lights_bytes.encode_s32(4, count)
	return count


# An omni light's range on the clouds, energy multiplier and shadow samples: a SunshineOmniLight's
# own (its cloud_radius), else its settings' with its omni_range.
func _omni_shape(light : OmniLight3D, settings : Array[CloudOmniLightSettings], index : int) -> Vector3:
	var sunshine_light := light as SunshineOmniLight
	if sunshine_light != null:
		return Vector3(sunshine_light.cloud_radius, sunshine_light.energy_multiplier, sunshine_light.shadow_samples)
	var light_settings := settings[index] if index < settings.size() && settings[index] else default_omni_settings
	return Vector3(light.omni_range, light_settings.energy_multiplier, light_settings.shadow_samples)


# Encodes the effectors reaching the layers into effector_bytes. Returns how many.
func _encode_effectors(effectors : Array[Node3D], settings : Array[CloudEffectorSettings], camera_position : Vector3, layers_span : Vector2) -> int:
	var reaching := 0
	_size_point_scores(effectors.size())
	for i in effectors.size():
		if !is_instance_valid(effectors[i]):
			continue
		var effector := effectors[i]
		var shape := _effector_shape(effector, settings, i)
		if effector.is_visible_in_tree() && shape.y != 0.0 && _reaches_layers(effector.global_position, shape.x, layers_span):
			point_scores[i] = camera_position.distance_to(effector.global_position) - shape.x
			reaching += 1
	var count := mini(reaching, MAX_EFFECTORS)
	for n in count:
		var i := _next_point(effectors.size(), reaching > count)
		var shape := _effector_shape(effectors[i], settings, i)
		_encode_vec4(effector_bytes, n * 48, effectors[i].global_position, shape.x)
		_encode_vec4(effector_bytes, 16 + n * 48, Vector3(shape.y, 1.0 / maxf(shape.x * shape.z, 0.001), 0.0), 0.0)
	return count


# An effector's radius (times its largest scale), strength and falloff: a SunshineEffector's own,
# otherwise its settings' at index (the defaults where there are none).
func _effector_shape(effector : Node3D, settings : Array[CloudEffectorSettings], index : int) -> Vector3:
	var scale := effector.global_transform.basis.get_scale().abs()
	var largest := maxf(scale.x, maxf(scale.y, scale.z))
	var sunshine_effector := effector as SunshineEffector
	if sunshine_effector != null:
		return Vector3(sunshine_effector.radius * largest, sunshine_effector.strength, sunshine_effector.falloff)
	var effector_settings := settings[index] if index < settings.size() && settings[index] else default_effector_settings
	return Vector3(effector_settings.radius * largest, effector_settings.strength, effector_settings.falloff)


# point_scores for size nodes, all left out (INF) until scored: distance to the camera less radius.
func _size_point_scores(size : int) -> void:
	if point_scores.size() < size:
		point_scores.resize(size)
	point_scores.fill(INF)


# The next of size scored nodes to encode, taken out of point_scores: the first in list order when
# they all fit, otherwise the nearest.
func _next_point(size : int, nearest : bool) -> int:
	var next := -1
	for i in size:
		if point_scores[i] < INF && (next < 0 || point_scores[i] < point_scores[next]):
			next = i
			if !nearest:
				break
	point_scores[next] = INF
	return next


## The first of steps light march steps, growing by light_step_growth to span light_march_distance
## (times cloud_scale): first * (growth^n - 1) / (growth - 1) = that distance.
func _first_light_step(steps : int) -> float:
	if steps <= 0:
		return 0.0
	var distance := light_march_distance * cloud_scale
	if light_step_growth > 1.0001:
		return distance * (light_step_growth - 1.0) / (pow(light_step_growth, steps) - 1.0)
	return distance / steps


## Bruneton's solar irradiance at ATMOSPHERE_LAMBDAS (they fall on demo.cc's 10 nm bins).
func _solar_irradiance() -> Vector3:
	var solar := Vector3.ZERO
	for i in 3:
		solar[i] = [1.11776, 1.14259, 1.01249, 1.14716, 1.72765, 1.73054, 1.6887, 1.61253,
			1.91198, 2.03474, 2.02042, 2.02212, 1.93377, 1.95809, 1.91686, 1.8298, 1.8685, 1.8931, 1.85149,
			1.8504, 1.8341, 1.8345, 1.8147, 1.78158, 1.7533, 1.6965, 1.68194, 1.64654, 1.6048, 1.52143,
			1.55622, 1.5113, 1.474, 1.4482, 1.41018, 1.36775, 1.34188, 1.31429, 1.28303, 1.26758, 1.2367,
			1.2082, 1.18737, 1.14683, 1.12362, 1.1058, 1.07124, 1.04992][int(ATMOSPHERE_LAMBDAS[i] - 360.0) / 10] # Solar irradiance (W.m^-2.nm^-1) from Bruneton's demo.cc, 10 nm bins from 360 to 830 nm. Measured data, don't tune: values sit around 1.0-2.0.
	return solar


## Colour of a light towards direction at position after the atmosphere (as
## GetTransmittanceToSun at ATMOSPHERE_LAMBDAS for r, g, b, integrated on the CPU), white balanced
## against it straight overhead; 0 once its disc has set.
func get_light_color(direction : Vector3, position : Vector3) -> Color:
	var bottom := planet_radius * 1000.0
	# Unscaled, as the atmosphere is the same one scaled by cloud_scale.
	var altitude := (get_cloud_height(position) if spherical_planet else position.y - ground_height) / cloud_scale
	var r := clampf(bottom + altitude, bottom, bottom + atmosphere_height * 1000.0)
	var mu := direction.normalized().dot(get_planet_up(position))
	var transmittance := _transmittance_to_top(r, mu)
	var overhead := _transmittance_to_top(r, 1.0)
	# Fraction of the disc above the horizon, as GetTransmittanceToSun.
	var sin_horizon := bottom / r
	var cos_horizon := -sqrt(maxf(1.0 - sin_horizon * sin_horizon, 0.0))
	var disc := smoothstep(-sin_horizon * sun_angular_radius, sin_horizon * sun_angular_radius, mu - cos_horizon)
	return Color(transmittance.x / overhead.x * disc, transmittance.y / overhead.y * disc, transmittance.z / overhead.z * disc)


## Transmittance from radius r (m) to the top of the atmosphere along a ray with cosine mu to the
## vertical (through the planet below the horizon, as Bruneton's transmittance texture).
func _transmittance_to_top(r : float, mu : float) -> Vector3:
	var bottom := planet_radius * 1000.0
	var top := bottom + atmosphere_height * 1000.0
	var distance := -r * mu + sqrt(maxf(r * r * (mu * mu - 1.0) + top * top, 0.0))
	var rayleigh := Vector3.ZERO
	var ozone_extinction := Vector3.ZERO
	for i in 3:
		var lambda : float = ATMOSPHERE_LAMBDAS[i]
		rayleigh[i] = RAYLEIGH * pow(lambda * 1e-3, -4.0)
		ozone_extinction[i] = MAX_OZONE_NUMBER_DENSITY * OZONE_CROSS_SECTION[int(lambda - 360.0) / 10] if ozone else 0.0
	var mie := mie_angstrom_beta / mie_scale_height
	const SAMPLES := 64
	var optical_depth := Vector3.ZERO
	for i in SAMPLES + 1:
		var t := distance * i / SAMPLES
		var altitude := sqrt(t * t + 2.0 * r * mu * t + r * r) - bottom
		var ozone_density := clampf(altitude / 15000.0 - 2.0 / 3.0 if altitude < 25000.0 else 8.0 / 3.0 - altitude / 15000.0, 0.0, 1.0)
		var weight := 0.5 if i == 0 || i == SAMPLES else 1.0
		optical_depth += weight * (rayleigh * exp(-altitude / rayleigh_scale_height) + Vector3.ONE * mie * exp(-altitude / mie_scale_height) + ozone_extinction * ozone_density)
	optical_depth *= distance / SAMPLES * atmospheric_density
	return Vector3(exp(-optical_depth.x), exp(-optical_depth.y), exp(-optical_depth.z))


func _render_callback(_callback_type : int, render_data : RenderData) -> void:
	if !shader.is_valid() || noise_texture == null || profile_texture == null:
		return
	# Invalid while a NoiseTexture3D is still generating.
	var noise_rid := RenderingServer.texture_get_rd_texture(noise_texture.get_rid())
	var profile_rid := RenderingServer.texture_get_rd_texture(profile_texture.get_rid())
	var coverage_rid := RenderingServer.texture_get_rd_texture(coverage_noise.get_rid()) if coverage_noise else RID()
	var curl_rid := RenderingServer.texture_get_rd_texture(curl_noise.get_rid()) if curl_noise else RID()
	# The sRGB view where the texture has one, as a source_color sampler reads it.
	var background_rid := RenderingServer.texture_get_rd_texture(background_texture.get_rid(), true) if background_texture else RID()
	var has_background := background_rid.is_valid()
	if !has_background:
		background_rid = black_texture
	if !noise_rid.is_valid() || !profile_rid.is_valid() || !coverage_rid.is_valid() || !curl_rid.is_valid():
		return
	# Changes to layers that skipped its setter (e.g. layers.append()) are picked up on the main
	# thread, which owns the profile texture.
	if layers != synced_layers:
		_sync_layers.call_deferred()
	var frame_layers := active_layers
	var layer_count := frame_layers.size()

	var buffers := render_data.get_render_scene_buffers() as RenderSceneBuffersRD
	var scene_data := render_data.get_render_scene_data()
	if buffers == null || scene_data == null:
		return
	var size := buffers.get_internal_size()
	if size.x == 0 || size.y == 0:
		return

	var engine_frame := Engine.get_frames_drawn()
	var first_viewport := engine_frame != last_engine_frame
	last_engine_frame = engine_frame
	if first_viewport:
		for i in range(retired_textures.size() - 1, -1, -1):
			if engine_frame >= retired_frames[i]:
				# A reflection image may have gone with its Texture2DRD's RenderingServer texture.
				if rd.texture_is_valid(retired_textures[i]):
					rd.free_rid(retired_textures[i])
				retired_textures.remove_at(i)
				retired_frames.remove_at(i)
		# Forget viewports that are gone (their buffers freed our textures with them).
		if engine_frame % 60 == 0:
			for id : int in viewport_states.keys():
				if !is_instance_id_valid(id):
					viewport_states.erase(id)

	var state : ViewportState = viewport_states.get(buffers.get_instance_id())
	if state == null:
		state = ViewportState.new()
		viewport_states[buffers.get_instance_id()] = state
	state.frame += 1
	# Whether this viewport writes the reflection image (its first view's) this frame.
	var reflect := reflections_enabled && reflection_texture != null && _is_reflection_owner(buffers, state, size, engine_frame)
	var view_count := buffers.get_view_count()
	var raymarch_size := Vector2i(ceili(float(size.x) / raymarch_resolution), ceili(float(size.y) / raymarch_resolution))
	# With 3D MSAA the scene is in multisampled textures until the end of the transparent pass, when
	# Godot resolves the colour over anything written to the resolved one before (and its depth
	# resolve averages the samples). The raymarch and resolve then run their msaa versions, which
	# read the multisampled depth, and the resolve leaves its changes to the colour per surface
	# (msaa_near, msaa_far) for SunshineClouds3MsaaComposite.glsl to blend into the multisampled
	# colour a sample at a time.
	var msaa := buffers.get_msaa_3d() != RenderingServer.VIEWPORT_MSAA_DISABLED
	if buffers.has_texture(BUFFERS_CONTEXT, &"raymarch") && buffers.get_texture_slice_size(BUFFERS_CONTEXT, &"raymarch", 0) != raymarch_size:
		buffers.clear_context(BUFFERS_CONTEXT)
	# Turning MSAA on or off reconfigures the buffers, which frees these textures.
	if !buffers.has_texture(BUFFERS_CONTEXT, &"raymarch"):
		for i in VIEW_TEXTURES:
			buffers.create_texture(BUFFERS_CONTEXT, VIEW_TEXTURE_NAMES[i],
				RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT,
				RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT,
				RenderingDevice.TEXTURE_SAMPLES_1, raymarch_size if i == 2 || i == 3 else size, view_count, 1, true, false)
		if msaa:
			for texture_name : StringName in [&"msaa_near", &"msaa_far"]:
				buffers.create_texture(BUFFERS_CONTEXT, texture_name, RenderingDevice.DATA_FORMAT_R32G32B32A32_UINT,
					RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT,
					RenderingDevice.TEXTURE_SAMPLES_1, size, view_count, 1, true, false)
		state.prev_view_projections.clear()

	# Visual profiler: ">" opens a folder and "<" closes it; each timestamp is an entry lasting
	# until the next one.
	rd.capture_timestamp(">Sunshine Clouds")
	if atmosphere_changed:
		atmosphere_changed = false
		atmosphere_precompute_pending = true
		# Bruneton's AtmosphereParameters for ATMOSPHERE_LAMBDAS, in kilometres, as model.cc builds
		# them from demo.cc's spectra (the lambdas fall on the 10 nm bins). Lengths are times
		# cloud_scale and extinctions over it, so the scaled atmosphere looks the same.
		var solar := _solar_irradiance()
		var rayleigh := Vector3.ZERO
		var absorption := Vector3.ZERO
		var per_km := 1000.0 * atmospheric_density / cloud_scale
		for i in 3:
			var lambda : float = ATMOSPHERE_LAMBDAS[i]
			var bin := int(lambda - 360.0) / 10
			rayleigh[i] = RAYLEIGH * pow(lambda * 1e-3, -4.0) * per_km
			absorption[i] = (MAX_OZONE_NUMBER_DENSITY * OZONE_CROSS_SECTION[bin] if ozone else 0.0) * per_km
		# Angstrom alpha is 0, so aerosols are the same at every wavelength.
		var mie := mie_angstrom_beta / mie_scale_height * per_km
		atmosphere_bytes.fill(0)
		_encode_vec4(atmosphere_bytes, 0, solar, sun_angular_radius)
		# mu_s_min: 102 degrees, as the demo uses with half float scattering textures.
		_encode_vec4(atmosphere_bytes, 16, Vector3(planet_radius, planet_radius + atmosphere_height, 0.0) * cloud_scale + Vector3(0.0, 0.0, mie_phase_g),
			cos(deg_to_rad(102.0)))
		# Density profiles at 32 (Rayleigh), 96 (Mie) and 160 (ozone), two layers of
		# (width, exp_term, exp_scale, linear_term), (constant_term); single layer profiles get an
		# empty first layer, as in model.cc.
		_encode_vec4(atmosphere_bytes, 64, Vector3(0.0, 1.0, -1000.0 / (rayleigh_scale_height * cloud_scale)), 0.0)
		_encode_vec4(atmosphere_bytes, 128, Vector3(0.0, 1.0, -1000.0 / (mie_scale_height * cloud_scale)), 0.0)
		# Ozone: rises linearly from 0 at 10 km to 1 at 25 km, falls back to 0 at 40 km.
		_encode_vec4(atmosphere_bytes, 160, Vector3(25.0 * cloud_scale, 0.0, 0.0), 1000.0 / (15000.0 * cloud_scale))
		_encode_vec4(atmosphere_bytes, 176, Vector3(-2.0 / 3.0, 0.0, 0.0), 0.0)
		_encode_vec4(atmosphere_bytes, 192, Vector3(0.0, 0.0, 0.0), -1000.0 / (15000.0 * cloud_scale))
		_encode_vec4(atmosphere_bytes, 208, Vector3(8.0 / 3.0, 0.0, 0.0), 0.0)
		_encode_vec4(atmosphere_bytes, 224, rayleigh, 0.0)
		_encode_vec4(atmosphere_bytes, 240, Vector3.ONE * mie * mie_single_scattering_albedo, 0.0)
		_encode_vec4(atmosphere_bytes, 256, Vector3.ONE * mie, 0.0)
		_encode_vec4(atmosphere_bytes, 272, absorption, 0.0)
		_encode_vec4(atmosphere_bytes, 288, Vector3.ONE * ground_albedo, 0.0)
		rd.buffer_update(atmosphere_buffer, 0, ATMOSPHERE_BYTES, atmosphere_bytes)
	# Without the atmosphere nothing reads the precomputed textures; they're redone once it's back.
	if atmosphere_precompute_pending && atmosphere_enabled:
		atmosphere_precompute_pending = false
		rd.capture_timestamp("Recalculate Sunshine Clouds Atmosphere")
		skybox_keys_ready = 0
		# Bruneton's Model::Precompute (radiance mode, combined scattering textures): transmittance,
		# direct irradiance, single scattering, then per extra scattering order the scattering
		# density, indirect irradiance and multiple scattering.
		var float32 := RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
		var float16 := RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
		var delta_irradiance := _create_atmosphere_texture(IRRADIANCE_SIZE, float32)
		var delta_rayleigh := _create_atmosphere_texture(SCATTERING_SIZE, float16)
		var delta_mie := _create_atmosphere_texture(SCATTERING_SIZE, float16)
		var delta_scattering_density := _create_atmosphere_texture(SCATTERING_SIZE, float16)
		# Multiple scattering is only needed from order 3, single Rayleigh only for order 2: they share.
		var delta_multiple := delta_rayleigh
		var image := RenderingDevice.UNIFORM_TYPE_IMAGE
		var sampler := RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE
		_precompute_dispatch(0, [_uniform(image, 1, [transmittance_texture])], TRANSMITTANCE_SIZE)
		_precompute_dispatch(1, [
			_uniform(sampler, 1, [lut_sampler, transmittance_texture]),
			_uniform(image, 2, [delta_irradiance]),
			_uniform(image, 3, [irradiance_texture]),
		], IRRADIANCE_SIZE)
		_precompute_dispatch(2, [
			_uniform(sampler, 1, [lut_sampler, transmittance_texture]),
			_uniform(image, 2, [delta_rayleigh]),
			_uniform(image, 3, [delta_mie]),
			_uniform(image, 4, [scattering_texture]),
		], SCATTERING_SIZE)
		for scattering_order in range(2, scattering_orders + 1):
			_precompute_dispatch(3, [
				_uniform(sampler, 1, [lut_sampler, transmittance_texture]),
				_uniform(sampler, 2, [lut_sampler, delta_rayleigh]),
				_uniform(sampler, 3, [lut_sampler, delta_mie]),
				_uniform(sampler, 4, [lut_sampler, delta_multiple]),
				_uniform(sampler, 5, [lut_sampler, delta_irradiance]),
				_uniform(image, 6, [delta_scattering_density]),
			], SCATTERING_SIZE, scattering_order)
			_precompute_dispatch(4, [
				_uniform(sampler, 2, [lut_sampler, delta_rayleigh]),
				_uniform(sampler, 3, [lut_sampler, delta_mie]),
				_uniform(sampler, 4, [lut_sampler, delta_multiple]),
				_uniform(image, 5, [delta_irradiance]),
				_uniform(image, 6, [irradiance_texture]),
			], IRRADIANCE_SIZE, scattering_order - 1)
			_precompute_dispatch(5, [
				_uniform(sampler, 1, [lut_sampler, transmittance_texture]),
				_uniform(sampler, 2, [lut_sampler, delta_scattering_density]),
				_uniform(image, 3, [delta_multiple]),
				_uniform(image, 4, [scattering_texture]),
			], SCATTERING_SIZE)
		_retire(delta_irradiance)
		_retire(delta_rayleigh)
		_retire(delta_mie)
		_retire(delta_scattering_density)

	# The layers once a frame: their wind delta is since the last frame. Their sizes are times
	# cloud_scale and their extinction over it; the noise offsets are world positions already (the
	# driver scales the wind).
	if first_viewport:
		for i in layer_count:
			var layer := frame_layers[i]
			var offset := i * LAYER_BYTES
			var half_tile := layer.noise_scale * cloud_scale * 0.5
			var wind_delta := layer.noise_offset - layer.prev_noise_offset
			wind_delta = Vector3(wrapf(wind_delta.x, -half_tile, half_tile), wrapf(wind_delta.y, -half_tile, half_tile),
				wrapf(wind_delta.z, -half_tile, half_tile))
			layer.prev_noise_offset = layer.noise_offset
			_encode_vec4(layers_bytes, offset, layer.noise_offset, layer.noise_scale * cloud_scale)
			_encode_vec4(layers_bytes, offset + 16, layer.detail_noise_offset, layer.detail_noise_scale * cloud_scale)
			_encode_vec4(layers_bytes, offset + 32, layer.curl_noise_offset, layer.curl_noise_scale * cloud_scale)
			_encode_vec4(layers_bytes, offset + 48, wind_delta, layer.cloud_floor * cloud_scale)
			layers_bytes.encode_float(offset + 64, layer.coverage_noise_offset.x)
			layers_bytes.encode_float(offset + 68, layer.coverage_noise_offset.z)
			layers_bytes.encode_float(offset + 72, layer.coverage_noise_scale * cloud_scale)
			layers_bytes.encode_float(offset + 76, layer.coverage_noise_strength)
			layers_bytes.encode_float(offset + 80, layer.cloud_ceiling * cloud_scale)
			layers_bytes.encode_float(offset + 84, layer.cloud_coverage * coverage)
			layers_bytes.encode_float(offset + 88, layer.detail_strength)
			layers_bytes.encode_float(offset + 92, layer.detail_power)
			layers_bytes.encode_float(offset + 96, layer.curl_strength * cloud_scale)
			layers_bytes.encode_float(offset + 100, layer.density * density / cloud_scale)
		if layer_count > 0:
			rd.buffer_update(layers_buffer, 0, layer_count * LAYER_BYTES, layers_bytes)
		var background_basis := Basis.from_euler(background_rotation * (PI / 180.0)).inverse()
		var sky_key_now := [has_background, background_color, background_energy, background_fade_brightness, background_basis,
			background_skybox_energy, skybox_ground_color, background_rid, radiance_scale, ground_height, skybox_energy, skybox_cloud_dimming, coverage,
			density, skybox_clouds, skybox_cloud_steps, skybox_cloud_light_steps, skybox_cloud_distance, atmosphere_tint, cloud_tint, cloud_scale]
		if sky_key_now != sky_settings_key:
			sky_settings_key = sky_key_now
			# The skybox shows the new settings at once.
			skybox_keys_ready = 0
			_encode_mat4(sky_bytes, 0, Projection(Transform3D(background_basis, Vector3.ZERO)))
			var tint := background_color.srgb_to_linear() * background_energy if has_background else Color.BLACK
			_encode_vec4(sky_bytes, 64, Vector3(tint.r, tint.g, tint.b), background_fade_brightness)
			var ground := skybox_ground_color.srgb_to_linear()
			_encode_vec4(sky_bytes, 80, Vector3(ground.r, ground.g, ground.b), background_skybox_energy)
			sky_bytes.encode_float(96, skybox_energy * maxf(1.0 - skybox_cloud_dimming * (coverage + density) * 0.5, 0.0))
			sky_bytes.encode_float(100, skybox_cloud_distance * cloud_scale)
			sky_bytes.encode_s32(104, skybox_cloud_steps if skybox_clouds else 0)
			sky_bytes.encode_s32(108, skybox_cloud_light_steps)
			var atmosphere_linear := atmosphere_tint.srgb_to_linear()
			_encode_vec4(sky_bytes, 112, Vector3(atmosphere_linear.r, atmosphere_linear.g, atmosphere_linear.b), 0.0)
			var cloud_linear := cloud_tint.srgb_to_linear()
			_encode_vec4(sky_bytes, 128, Vector3(cloud_linear.r, cloud_linear.g, cloud_linear.b), 0.0)
			rd.buffer_update(sky_buffer, 0, SKY_BYTES, sky_bytes)

	if noise_stats_texture != noise_texture:
		# Mean and standard deviation of the noise's red channel, from every 8th voxel on each axis.
		noise_stats_texture = noise_texture
		var data := noise_texture.get_data()
		var total := 0.0
		var total_squared := 0.0
		var count := 0
		for z in range(0, data.size(), 8):
			var image : Image = data[z]
			for y in range(0, image.get_height(), 8):
				for x in range(0, image.get_width(), 8):
					var value := image.get_pixel(x, y).r
					total += value
					total_squared += value * value
					count += 1
		var mean := total / maxi(count, 1)
		noise_stats = Vector2(mean, sqrt(maxf(total_squared / maxi(count, 1) - mean * mean, 1e-6))) if count > 0 else Vector2(0.5, 0.25)

	# A tiny shadow map while shadows are off, which the resolve still binds; keys only while it's
	# not rendered every frame.
	var shadow_resolution := cloud_shadow_resolution if cloud_shadows else 4
	var use_keys := cloud_shadows && cloud_shadow_update_interval > 1
	if shadow_resolution != shadow_texture_resolution || use_keys != shadow_keys[0].is_valid():
		for texture : RID in [shadow_texture, shadow_keys[0], shadow_keys[1]]:
			if texture.is_valid():
				_retire(texture)
		var texture_format := RDTextureFormat.new()
		texture_format.width = shadow_resolution
		texture_format.height = shadow_resolution
		texture_format.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
		texture_format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT
		# Cleared maps are unshadowed (a key that's blended out still has to be a number).
		shadow_texture = rd.texture_create(texture_format, RDTextureView.new())
		rd.texture_clear(shadow_texture, Color(1.0, 1.0, 1.0, 1.0), 0, 1, 0, 1)
		for i in 2:
			shadow_keys[i] = rd.texture_create(texture_format, RDTextureView.new()) if use_keys else RID()
			if use_keys:
				rd.texture_clear(shadow_keys[i], Color(1.0, 1.0, 1.0, 1.0), 0, 1, 0, 1)
		shadow_keys_ready = 0
		shadow_texture_resolution = shadow_resolution

	# The lights, and the caster the shadows should move to.
	var wanted_id := shadow_caster_id
	var wanted_direction := shadow_caster_direction
	var sun_direction := atmosphere_sun_direction
	if first_viewport:
		lights_mutex.lock()
		if lights_driven && Time.get_ticks_msec() - lights_set_msec > 500:
			# No driver updating them: the fallback directional lights, no omni lights or effectors.
			# Encoded again from scratch once calls resume.
			lights_driven = false
			lights_key = []
			effectors_key = []
			omni_count = 0
			effector_count = 0
			lights_bytes.encode_s32(4, 0)
			_encode_fallback_lights()
			lights_dirty = true
		elif using_fallback && _fallback_key() != fallback_key:
			_encode_fallback_lights()
			lights_dirty = true
		sun_direction = atmosphere_sun_direction
		if lights_dirty || atmosphere_enabled != uploaded_atmosphere_enabled:
			lights_dirty = false
			lights_version += 1
			uploaded_atmosphere_enabled = atmosphere_enabled
			lights_bytes.encode_u32(8, 1 if atmosphere_enabled else 0)
			lights_bytes.encode_s32(12, effector_count)
			# The effectors straight after the omni lights.
			var effectors_offset := 144 + omni_count * 48
			rd.buffer_update(lights_buffer, 0, effectors_offset, lights_bytes)
			if effector_count > 0:
				rd.buffer_update(lights_buffer, effectors_offset, effector_count * 48, effector_bytes)
		wanted_id = wanted_caster_id
		wanted_direction = wanted_caster_direction
		for i in light_id_count:
			if light_ids[i] == shadow_caster_id:
				shadow_caster_direction = light_directions[i]
		lights_mutex.unlock()

	rd.capture_timestamp("Render Sunshine Clouds")
	var cam_transform := scene_data.get_cam_transform()
	var world_to_camera := Projection(cam_transform.affine_inverse())
	if state.set_inputs.size() != view_count * SET_INPUT_COUNT:
		state.set_inputs.resize(view_count * SET_INPUT_COUNT)
		state.set_inputs.fill(0)
		state.raymarch_sets.resize(view_count * 2)
		state.resolve_sets.resize(view_count * 2)
	var parity := state.frame % 2
	for view in view_count:
		var projection := scene_data.get_view_projection(view)
		var view_projection := projection * world_to_camera
		var history_valid := view < state.prev_view_projections.size()

		_encode_mat4(params_bytes, 0, projection.inverse())
		_encode_mat4(params_bytes, 64, Projection(cam_transform))
		_encode_mat4(params_bytes, 128, state.prev_view_projections[view] if history_valid else view_projection)
		_encode_vec4(params_bytes, 192, sun_direction, 0.0)
		params_bytes.encode_u32(204, state.frame & 0x7FFFFFFF)
		_encode_vec4(params_bytes, 208, cam_transform.origin - get_planet_center(), 1.0 if spherical_planet else 0.0)
		params_bytes.encode_u32(224, size.x)
		params_bytes.encode_u32(228, size.y)
		params_bytes.encode_s32(232, layer_count)
		params_bytes.encode_u32(236, 1 if history_valid else 0)
		_encode_vec4(params_bytes, 240, Vector3(ambient_color.r, ambient_color.g, ambient_color.b), ambient_energy)
		params_bytes.encode_float(256, primary_phase_g)
		params_bytes.encode_float(260, current_frame_weight)
		params_bytes.encode_s32(264, raymarch_resolution)
		params_bytes.encode_float(268, cloud_step_size * cloud_scale)
		params_bytes.encode_float(272, secondary_phase_g)
		params_bytes.encode_float(276, multiple_scattering_depth_power)
		params_bytes.encode_float(280, multiple_scattering_height_power)
		params_bytes.encode_float(284, near_step_size * cloud_scale)
		params_bytes.encode_float(288, far_step_size_offset * cloud_scale)
		params_bytes.encode_float(292, step_adjustment_distance * cloud_scale)
		params_bytes.encode_s32(296, max_steps)
		params_bytes.encode_float(304, light_march_distance * cloud_scale)
		params_bytes.encode_float(308, light_step_growth)
		params_bytes.encode_float(316, max_distance * cloud_scale)
		params_bytes.encode_float(320, radiance_scale)
		params_bytes.encode_float(324, ground_height)
		params_bytes.encode_float(328, planet_radius * cloud_scale)
		params_bytes.encode_float(332, noise_stats.x)
		params_bytes.encode_float(336, noise_stats.y)
		params_bytes.encode_s32(340, curl_iterations)
		params_bytes.encode_s32(344, cloud_exit_steps)
		params_bytes.encode_s32(348, interlace)
		params_bytes.encode_float(352, wind_reprojection_distance * cloud_scale)
		params_bytes.encode_float(356, ambient_occlusion)
		params_bytes.encode_float(360, ambient_ground_strength)
		params_bytes.encode_float(364, ambient_extinction_scale)
		_encode_vec4(params_bytes, 368, Vector3(ground_color.r, ground_color.g, ground_color.b), 0.0)
		rd.buffer_update(params_buffer, 0, PARAMS_BYTES, params_bytes)

		var color_layer := buffers.get_color_layer(view, msaa)
		var depth_layer := buffers.get_depth_layer(view, msaa)
		var msaa_near := buffers.get_texture_slice(BUFFERS_CONTEXT, &"msaa_near", view, 0, 1, 1) if msaa else RID()
		var msaa_far := buffers.get_texture_slice(BUFFERS_CONTEXT, &"msaa_far", view, 0, 1, 1) if msaa else RID()
		if view == 0: #TODO: Add timing offsets to make this only render every other frame or every 3rd etc, for performance modulation.
			# The shadow map passes and point samples bind the same textures; their sets are rebuilt
			# together. None reads the depth, so binding 1 gets a texture of ours instead of a
			# viewport's. Bindings a shader doesn't declare are ignored.
			var density_inputs_changed := _set_input(density_set_inputs, 0, noise_rid)
			density_inputs_changed = _set_input(density_set_inputs, 1, profile_rid) || density_inputs_changed
			density_inputs_changed = _set_input(density_set_inputs, 2, coverage_rid) || density_inputs_changed
			density_inputs_changed = _set_input(density_set_inputs, 3, curl_rid) || density_inputs_changed
			density_inputs_changed = _set_input(density_set_inputs, 4, shadow_texture) || density_inputs_changed
			density_inputs_changed = _set_input(density_set_inputs, 5, shadow_keys[0]) || density_inputs_changed
			density_inputs_changed = _set_input(density_set_inputs, 6, shadow_keys[1]) || density_inputs_changed
			if density_inputs_changed || !rd.uniform_set_is_valid(shadow_sets[0]) \
					|| (shadow_keys[0].is_valid() && !rd.uniform_set_is_valid(shadow_blend_set)) \
					|| (sample_shader.is_valid() && !rd.uniform_set_is_valid(sample_set)):
				var density_uniforms : Array[RDUniform] = [
					_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 1, [nearest_sampler, transmittance_texture]),
					_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 2, [noise_sampler, noise_rid]),
					_uniform(RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER, 3, [params_buffer]),
					_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 4, [lut_sampler, profile_rid]),
					_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 13, [noise_sampler, coverage_rid]),
					_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 14, [noise_sampler, curl_rid]),
					_uniform(RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER, 15, [layers_buffer]),
					_uniform(RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER, 19, [shadow_buffer]),
					_uniform(RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER, 26, [lights_buffer]),
				]
				for i in 3:
					var target := shadow_texture if i == 0 else shadow_keys[i - 1]
					shadow_sets[i] = UniformSetCacheRD.get_cache(shadow_shader, 0, density_uniforms + [
						_uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 21, [target]),
					]) if target.is_valid() else RID()
				if shadow_keys[0].is_valid():
					shadow_blend_set = UniformSetCacheRD.get_cache(shadow_blend_shader, 0, density_uniforms + [
						_uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 21, [shadow_texture]),
						_uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 24, [shadow_keys[0]]),
						_uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 25, [shadow_keys[1]]),
					])
				if sample_shader.is_valid():
					sample_set = UniformSetCacheRD.get_cache(sample_shader, 0, density_uniforms + [
						_uniform(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 22, [point_sample_data_buffer]),
					])

			# The shadow map, and the Shadow buffer the resolve's screen space shadows read: once a
			# frame, and again, straight into shadow_texture, for a viewport whose camera is away
			# from the one it's centred on.
			var shadow_extent := maxf(cloud_shadow_extent * cloud_scale, 1.0)
			var far_camera := !first_viewport && cam_transform.origin.distance_to(shadow_camera) > shadow_extent * 0.01
			if first_viewport || far_camera:
				shadow_camera = cam_transform.origin
				var keyed := shadow_keys[0].is_valid() && !far_camera
				if keyed:
					shadow_age += 1
				# A new caster: with keys, the current one's shadows first fade out to a lit key over
				# the interval and the next one's then fade in from it (two maps in different light
				# spaces can't be blended); without, it switches at once.
				if far_camera || wanted_id == shadow_caster_id:
					shadow_fading = false
				elif keyed && shadow_keys_ready > 0 && !shadow_fading:
					shadow_fading = true
					shadow_key = 1 - shadow_key
					rd.texture_clear(shadow_keys[shadow_key], Color(1.0, 1.0, 1.0, 1.0), 0, 1, 0, 1)
					shadow_keys_ready = 2
					shadow_age = 0
				elif !keyed || shadow_keys_ready == 0 || shadow_age + 1 >= cloud_shadow_update_interval:
					shadow_caster_id = wanted_id
					shadow_caster_direction = wanted_direction
					shadow_fading = false
					# Rendered as soon as the light space is ready, blended in from the lit key.
					shadow_key_sun = shadow_caster_direction
					shadow_age = cloud_shadow_update_interval

				# The projector has to be on the caster: the driver moves it a frame after a switch,
				# and until then nothing is drawn.
				var projector_mode := cloud_shadow_mode == SHADOW_MODE_PROJECTOR && shadow_projector.is_valid() && shadow_blit_material.is_valid()
				var projector := projector_mode && shadow_projector_light_id == shadow_caster_id
				if !projector_mode || projector:
					var light_to_world := shadow_light_transform
					if !projector && shadow_caster_direction != Vector3.ZERO:
						light_to_world = Transform3D(Basis.looking_at(-shadow_caster_direction,
							Vector3.FORWARD if absf(shadow_caster_direction.y) > 0.99 else Vector3.UP), Vector3.ZERO)
					var world_to_light := light_to_world.affine_inverse()
					var to_sun := light_to_world.basis.z.normalized()
					var sun_height := to_sun.dot(get_planet_up(cam_transform.origin))
					# The horizon fade scales the strength. Faded out, screen space skips the map; the
					# projector still gets it (all lit), so the light doesn't keep the last shadows.
					var fade := 1.0 if sun_height > 0.0 else 0.0
					if cloud_shadow_horizon_fade > 0.0:
						fade = smoothstep(0.0, sin(deg_to_rad(cloud_shadow_horizon_fade)), sun_height)
					var shadows_active := cloud_shadows && layer_count > 0 && shadow_caster_direction != Vector3.ZERO && (fade > 0.0 || projector)

					# With keys, the map is rendered every interval frames into them in turn, and again
					# right away after the camera or sun jumps (the keys would show the wrong place).
					var render := shadows_active
					if keyed:
						var reset := shadow_keys_ready == 0 \
							|| cam_transform.origin.distance_to(shadow_key_camera) > shadow_extent * 0.25 \
							|| to_sun.dot(shadow_key_sun) < 0.9998
						render = shadows_active && !shadow_fading && (reset || shadow_age >= cloud_shadow_update_interval)
						if render:
							shadow_key = 1 - shadow_key
							shadow_keys_ready = 1 if reset else 2
							shadow_age = 0
							shadow_key_camera = cam_transform.origin
							shadow_key_sun = to_sun
						elif !shadows_active:
							shadow_keys_ready = 0

					if render || !shadows_active:
						var march_floor := INF
						var march_ceiling := -INF
						for layer in frame_layers:
							march_floor = minf(march_floor, layer.cloud_floor * cloud_scale)
							march_ceiling = maxf(march_ceiling, layer.cloud_ceiling * cloud_scale)
						var thickness := maxf(march_ceiling - march_floor, 1.0) if shadows_active else 1.0
						var extent := shadow_extent
						_encode_mat4(shadow_bytes, 0, Projection(light_to_world))
						_encode_mat4(shadow_bytes, 64, Projection(world_to_light))
						shadow_bytes.encode_float(128, extent)
						shadow_bytes.encode_s32(132, shadow_texture_resolution)
						shadow_bytes.encode_float(136, cloud_shadow_strength * fade)
						shadow_bytes.encode_float(140, cloud_shadow_sharpness)
						_encode_vec4(shadow_bytes, 144, world_to_light * cam_transform.origin, 0.0)
						shadow_bytes.encode_s32(156, cloud_shadow_steps)
						shadow_bytes.encode_float(160, march_floor if shadows_active else 0.0)
						shadow_bytes.encode_float(164, minf(thickness / sun_height, thickness * 8.0) if shadows_active && sun_height > 0.001 else 0.0) # Max shadow march length as a multiple of layer thickness: with a low sun the march would otherwise run for hundreds of km. 4-16: lower is cheaper but clips long low-sun shadows.
						shadow_bytes.encode_s32(168, 1 if shadows_active && !projector else 0)
						shadow_bytes.encode_float(172, screen_space_shadow_strength)
						shadow_bytes.encode_float(176, screen_space_shadow_fade * extent * 0.5)
						rd.buffer_update(shadow_buffer, 0, SHADOW_BYTES, shadow_bytes)
					var groups := ceili(shadow_texture_resolution / 8.0)
					if render:
						var list := rd.compute_list_begin()
						rd.compute_list_bind_compute_pipeline(list, _pipeline(shadow_pipelines, layer_count, shadow_shader, layer_count))
						rd.compute_list_bind_uniform_set(list, shadow_sets[1 + shadow_key if keyed else 0], 0)
						rd.compute_list_dispatch(list, groups, groups, 1)
						rd.compute_list_end()
					if keyed && shadows_active:
						# The latest key's weight goes from 1 / interval after it's rendered to 1 when the
						# next one is due; with only one key so far it's that one.
						var latest_weight := minf(float(shadow_age + 1) / cloud_shadow_update_interval, 1.0) if shadow_keys_ready == 2 else 1.0
						push_bytes.encode_float(0, latest_weight if shadow_key == 1 else 1.0 - latest_weight)
						var list := rd.compute_list_begin()
						rd.compute_list_bind_compute_pipeline(list, shadow_blend_pipeline)
						rd.compute_list_bind_uniform_set(list, shadow_blend_set, 0)
						rd.compute_list_set_push_constant(list, push_bytes, push_bytes.size())
						rd.compute_list_dispatch(list, groups, groups, 1)
						rd.compute_list_end()
					if shadows_active && projector:
						# Blitting into the DrawableTexture2D is what makes Godot copy it into the decal
						# atlas (where projectors are sampled from) again; a texture written by compute
						# never is. Called by name: older engines have no drawable blit.
						if shadow_source == null:
							shadow_source = Texture2DRD.new()
						if shadow_source.texture_rd_rid != shadow_texture:
							shadow_source.texture_rd_rid = shadow_texture
						RenderingServer.call(&"texture_drawable_blit_rect", [shadow_projector], Rect2i(Vector2i.ZERO, shadow_projector_size),
							shadow_blit_material, Color.WHITE, [shadow_source.get_rid()], 0)

			if first_viewport:
				_update_skybox(cam_transform.origin, sun_direction, background_rid, [noise_rid, profile_rid, coverage_rid, curl_rid], layer_count)
				rd.capture_timestamp("Render Sunshine Clouds Views")

			# Up to MAX_SAMPLE_POINTS queued points (w = 0, the shader writes the density there).
			if !positionQuerying && !positionResetting && !positionQueries.is_empty() && sample_shader.is_valid():
				positionQuerying = true
				position_query_mutex.lock()
				positionQueriesEncoded = mini(positionQueries.size(), MAX_SAMPLE_POINTS)
				for i in positionQueriesEncoded:
					_encode_vec4(sample_bytes, i * 16, positionQueries[i], 0.0)
				positionQueries = positionQueries.slice(positionQueriesEncoded)
				position_query_mutex.unlock()
				rd.buffer_update(point_sample_data_buffer, 0, SAMPLE_BUFFER_BYTES, sample_bytes)
				push_bytes.encode_s32(0, positionQueriesEncoded)
				var list := rd.compute_list_begin()
				rd.compute_list_bind_compute_pipeline(list, _pipeline(sample_pipelines, layer_count, sample_shader, layer_count))
				rd.compute_list_bind_uniform_set(list, sample_set, 0)
				rd.compute_list_set_push_constant(list, push_bytes, push_bytes.size())
				rd.compute_list_dispatch(list, 1, 1, 1)
				rd.compute_list_end()

		# Rebuild the view's uniform sets only when something they bind changed or the rendering
		# device dropped them (a bound resource was freed).
		var base := view * SET_INPUT_COUNT
		var inputs_changed := _set_input(state.set_inputs, base, color_layer)
		inputs_changed = _set_input(state.set_inputs, base + 1, depth_layer) || inputs_changed
		inputs_changed = _set_input(state.set_inputs, base + 2, noise_rid) || inputs_changed
		inputs_changed = _set_input(state.set_inputs, base + 3, profile_rid) || inputs_changed
		inputs_changed = _set_input(state.set_inputs, base + 4, coverage_rid) || inputs_changed
		inputs_changed = _set_input(state.set_inputs, base + 5, curl_rid) || inputs_changed
		inputs_changed = _set_input(state.set_inputs, base + 6, shadow_texture) || inputs_changed
		inputs_changed = _set_input(state.set_inputs, base + 7, background_rid) || inputs_changed
		for i in VIEW_TEXTURES:
			view_textures[i] = buffers.get_texture_slice(BUFFERS_CONTEXT, VIEW_TEXTURE_NAMES[i], view, 0, 1, 1)
			inputs_changed = _set_input(state.set_inputs, base + 8 + i, view_textures[i]) || inputs_changed
		if inputs_changed \
				|| !rd.uniform_set_is_valid(state.raymarch_sets[view * 2]) || !rd.uniform_set_is_valid(state.raymarch_sets[view * 2 + 1]) \
				|| !rd.uniform_set_is_valid(state.resolve_sets[view * 2]) || !rd.uniform_set_is_valid(state.resolve_sets[view * 2 + 1]):
			var depth := _uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 1, [nearest_sampler, depth_layer])
			var params_uniform := _uniform(RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER, 3, [params_buffer])
			var layers_uniform := _uniform(RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER, 15, [layers_buffer])
			var raymarch_texture := view_textures[2]
			var raymarch_b_texture := view_textures[3]
			var atmosphere_uniform := _uniform(RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER, 9, [atmosphere_buffer])
			var transmittance_uniform := _uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 10, [lut_sampler, transmittance_texture])
			# The resolve writes the histories of the frame's parity and reads the other's, as does
			# the raymarch for the texels interlacing reprojects.
			for set_parity in 2:
				var history := view_textures[1 - set_parity]
				var history_b := view_textures[5 - set_parity]
				state.raymarch_sets[view * 2 + set_parity] = UniformSetCacheRD.get_cache(raymarch_msaa_shader if msaa else shader, 0, [
					depth,
					_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 2, [noise_sampler, noise_rid]),
					params_uniform,
					_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 4, [lut_sampler, profile_rid]),
					_uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 8, [raymarch_texture]),
					atmosphere_uniform,
					transmittance_uniform,
					_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 13, [noise_sampler, coverage_rid]),
					_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 14, [noise_sampler, curl_rid]),
					layers_uniform,
					_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 16, [lut_sampler, history]),
					_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 17, [nearest_sampler, history_b]),
					_uniform(RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER, 26, [lights_buffer]),
					_uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 27, [raymarch_b_texture]),
				])
				var resolve_uniforms : Array[RDUniform] = [
					depth,
					params_uniform,
					_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 6, [lut_sampler, history]),
					_uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 7, [view_textures[set_parity]]),
					_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 8, [nearest_sampler, raymarch_texture]),
					atmosphere_uniform,
					transmittance_uniform,
					_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 11, [lut_sampler, scattering_texture]),
					_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 12, [lut_sampler, irradiance_texture]),
					layers_uniform,
					_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 17, [nearest_sampler, history_b]),
					_uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 18, [view_textures[4 + set_parity]]),
					_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 28, [nearest_sampler, raymarch_b_texture]),
					_uniform(RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER, 19, [shadow_buffer]),
					_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 20, [noise_sampler, shadow_texture]),
					_uniform(RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER, 29, [sky_buffer]),
					_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 30, [background_sampler, background_rid]),
				]
				if msaa:
					resolve_uniforms.append(_uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 31, [msaa_near]))
					resolve_uniforms.append(_uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 32, [msaa_far]))
				else:
					resolve_uniforms.append(_uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 0, [color_layer]))
				state.resolve_sets[view * 2 + set_parity] = UniformSetCacheRD.get_cache(resolve_msaa_shader if msaa else resolve_shader, 0, resolve_uniforms)

		rd.capture_timestamp("Sunshine Clouds Raymarch")
		var list := rd.compute_list_begin()
		var raymarch_set := state.raymarch_sets[view * 2 + parity]
		var raymarch_shader := raymarch_msaa_shader if msaa else shader
		var raymarch_base := (MAX_LAYERS + 1) * 3 * int(msaa) + layer_count * 3
		if interlace > 1 && history_valid:
			# The texels traced this frame, then the reprojected rest (INTERLACE_PASS 1 and 2), each
			# 4x4 tile's as a block of threads.
			var tiles := Vector2i(ceili(size.x / (4.0 * raymarch_resolution)), ceili(size.y / (4.0 * raymarch_resolution)))
			var per_tile := 16 / interlace
			for interlace_pass in 2:
				var count := per_tile if interlace_pass == 0 else 16 - per_tile
				var block_width := 4 if count % 4 == 0 else (count / 2 if count % 2 == 0 else count)
				rd.compute_list_bind_compute_pipeline(list, _pipeline(raymarch_pipelines, raymarch_base + interlace_pass + 1, raymarch_shader, layer_count, interlace_pass + 1))
				rd.compute_list_bind_uniform_set(list, raymarch_set, 0)
				rd.compute_list_dispatch(list, ceili(tiles.x * block_width / 8.0), ceili(tiles.y * (count / block_width) / 8.0), 1)
		else:
			rd.compute_list_bind_compute_pipeline(list, _pipeline(raymarch_pipelines, raymarch_base, raymarch_shader, layer_count, 0))
			rd.compute_list_bind_uniform_set(list, raymarch_set, 0)
			rd.compute_list_dispatch(list, ceili(size.x / (8.0 * raymarch_resolution)), ceili(size.y / (8.0 * raymarch_resolution)), 1)
		rd.compute_list_end()

		rd.capture_timestamp("Sunshine Clouds Resolve")
		list = rd.compute_list_begin()
		rd.compute_list_bind_compute_pipeline(list, _pipeline(resolve_pipelines, int(atmosphere_enabled) + 2 * int(msaa),
			resolve_msaa_shader if msaa else resolve_shader, atmosphere_enabled))
		rd.compute_list_bind_uniform_set(list, state.resolve_sets[view * 2 + parity], 0)
		rd.compute_list_dispatch(list, ceili(size.x / 8.0), ceili(size.y / 8.0), 1)
		rd.compute_list_end()

		if msaa:
			rd.capture_timestamp("Sunshine Clouds MSAA Composite")
			_msaa_composite(color_layer, msaa_near, msaa_far)

		if reflect && view == 0:
			rd.capture_timestamp("Sunshine Clouds Reflection")
			_write_reflection(color_layer, depth_layer, msaa, size, projection.inverse())

		if history_valid:
			state.prev_view_projections[view] = view_projection
		else:
			state.prev_view_projections.append(view_projection)
	if !positionResetting && positionQuerying:
		positionResetting = true
		rd.buffer_get_data_async(point_sample_data_buffer, retrieve_position_queries)
	rd.capture_timestamp("<Sunshine Clouds")


## Blends the resolve's changes (msaa_near, msaa_far: colour * a + b per surface) into the
## multisampled colour color_msaa through SunshineClouds3MsaaComposite.glsl, a sample at a time:
## times a, then plus b, of the sample's surface (msaa_near's w).
func _msaa_composite(color_msaa : RID, msaa_near : RID, msaa_far : RID) -> void:
	var framebuffer := FramebufferCacheRD.get_cache_multipass([color_msaa], [], 1)
	var samples := rd.texture_get_format(color_msaa).samples
	var format := rd.framebuffer_get_format(framebuffer)
	var pipelines : Array = msaa_composite_pipelines.get(format, [RID(), RID()])
	for add in 2:
		if pipelines[add].is_valid() && rd.render_pipeline_is_valid(pipelines[add]):
			continue
		var add_constant := RDPipelineSpecializationConstant.new()
		add_constant.constant_id = 0
		add_constant.value = add == 1
		var multisample := RDPipelineMultisampleState.new()
		# The shader reads gl_SampleID, which shades it per sample (the D3D12 driver rejects
		# enable_sample_shading).
		multisample.sample_count = samples
		# Colour times the source, or plus it; the scene's alpha stays.
		var attachment := RDPipelineColorBlendStateAttachment.new()
		attachment.enable_blend = true
		attachment.src_color_blend_factor = RenderingDevice.BLEND_FACTOR_ONE if add else RenderingDevice.BLEND_FACTOR_ZERO
		attachment.dst_color_blend_factor = RenderingDevice.BLEND_FACTOR_ONE if add else RenderingDevice.BLEND_FACTOR_SRC_COLOR
		attachment.color_blend_op = RenderingDevice.BLEND_OP_ADD
		attachment.src_alpha_blend_factor = RenderingDevice.BLEND_FACTOR_ZERO
		attachment.dst_alpha_blend_factor = RenderingDevice.BLEND_FACTOR_ONE
		attachment.alpha_blend_op = RenderingDevice.BLEND_OP_ADD
		var blend := RDPipelineColorBlendState.new()
		blend.attachments = [attachment]
		pipelines[add] = rd.render_pipeline_create(msaa_composite_shader, format, RenderingDevice.INVALID_FORMAT_ID,
			RenderingDevice.RENDER_PRIMITIVE_TRIANGLES, RDPipelineRasterizationState.new(), multisample,
			RDPipelineDepthStencilState.new(), blend, 0, 0, [add_constant])
	msaa_composite_pipelines[format] = pipelines
	var uniform_set := UniformSetCacheRD.get_cache(msaa_composite_shader, 0, [
		_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 0, [nearest_sampler, msaa_near]),
		_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 1, [nearest_sampler, msaa_far]),
	])
	var draw_list := rd.draw_list_begin(framebuffer, RenderingDevice.DRAW_DEFAULT_ALL)
	for add in 2:
		rd.draw_list_bind_render_pipeline(draw_list, pipelines[add])
		rd.draw_list_bind_uniform_set(draw_list, uniform_set, 0)
		rd.draw_list_draw(draw_list, false, 1, 3)
	rd.draw_list_end()


## The skybox panorama, as the shadow map: rendered every skybox_update_interval frames into its
## two keys in turn and blended into skybox_texture every frame (straight into it at an interval of
## 1), and again at once when the sun, the camera height or the settings jump. While the sun, the
## camera height, the clouds (wind, shapes) and the lights stay put it isn't rendered or blended at
## all.
## Rendered only while a driver asks for it (request_skybox()); its textures are kept when
## the driver stops asking (a paused game), as its environment may still be showing them.
func _update_skybox(camera_position : Vector3, sun_direction : Vector3, background_rid : RID, density_rids : Array[RID], layer_count : int) -> void:
	var enabled := skybox_enabled && atmosphere_enabled && skybox_requested_msec >= 0
	# Once asked for, the textures stay while it's off too: a driver's Sky samples them until it lets
	# go (a frame later, or once a paused game resumes), and a freed one breaks its material. Replaced
	# ones are retired, which leaves the driver frames to move to the new one.
	var size := Vector2i(skybox_resolution, skybox_resolution / 2) if skybox_requested_msec >= 0 else Vector2i.ZERO
	var use_keys := size != Vector2i.ZERO && skybox_update_interval > 1
	if size != skybox_texture_size || use_keys != skybox_keys[0].is_valid():
		for texture : RID in [skybox_texture, skybox_keys[0], skybox_keys[1]]:
			if texture.is_valid():
				_retire(texture)
		skybox_texture = RID()
		skybox_keys[0] = RID()
		skybox_keys[1] = RID()
		if size != Vector2i.ZERO:
			var texture_format := RDTextureFormat.new()
			texture_format.width = size.x
			texture_format.height = size.y
			texture_format.format = RenderingDevice.DATA_FORMAT_R16G16B16A16_SFLOAT
			# Can be read back (rd.texture_get_data()) to look at.
			texture_format.usage_bits = RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT | RenderingDevice.TEXTURE_USAGE_STORAGE_BIT \
				| RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
			# Cleared, so a key that's blended out is still a number.
			skybox_texture = rd.texture_create(texture_format, RDTextureView.new())
			rd.texture_clear(skybox_texture, Color(0.0, 0.0, 0.0, 1.0), 0, 1, 0, 1)
			for i in 2:
				if use_keys:
					skybox_keys[i] = rd.texture_create(texture_format, RDTextureView.new())
					rd.texture_clear(skybox_keys[i], Color(0.0, 0.0, 0.0, 1.0), 0, 1, 0, 1)
		skybox_keys_ready = 0
		skybox_texture_size = size
	if !enabled:
		# Rendered afresh when it's back on.
		skybox_keys_ready = 0
		return
	if Time.get_ticks_msec() - skybox_requested_msec >= 500: # How long a request_skybox() keeps the skybox updating (ms). 250-1000: long enough to cover a few update intervals.
		return

	var inputs_changed := _set_input(skybox_set_inputs, 0, skybox_texture)
	inputs_changed = _set_input(skybox_set_inputs, 1, skybox_keys[0]) || inputs_changed
	inputs_changed = _set_input(skybox_set_inputs, 2, background_rid) || inputs_changed
	for i in density_rids.size():
		inputs_changed = _set_input(skybox_set_inputs, 3 + i, density_rids[i]) || inputs_changed
	if inputs_changed || !rd.uniform_set_is_valid(skybox_sets[0]) || (use_keys && !rd.uniform_set_is_valid(skybox_blend_set)):
		# Binding 1 is SunshineClouds3Common.glslinc's depth, which the skybox render doesn't read.
		var uniforms : Array[RDUniform] = [
			_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 1, [nearest_sampler, transmittance_texture]),
			_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 2, [noise_sampler, density_rids[0]]),
			_uniform(RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER, 3, [params_buffer]),
			_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 4, [lut_sampler, density_rids[1]]),
			_uniform(RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER, 9, [atmosphere_buffer]),
			_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 10, [lut_sampler, transmittance_texture]),
			_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 11, [lut_sampler, scattering_texture]),
			_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 12, [lut_sampler, irradiance_texture]),
			_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 13, [noise_sampler, density_rids[2]]),
			_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 14, [noise_sampler, density_rids[3]]),
			_uniform(RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER, 15, [layers_buffer]),
			_uniform(RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER, 26, [lights_buffer]),
			_uniform(RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER, 29, [sky_buffer]),
			_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 30, [background_sampler, background_rid]),
		]
		for i in 3:
			var target := skybox_texture if i == 0 else skybox_keys[i - 1]
			skybox_sets[i] = UniformSetCacheRD.get_cache(skybox_shader, 0, uniforms + [
				_uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 31, [target]),
			]) if target.is_valid() else RID()
		if use_keys:
			skybox_blend_set = UniformSetCacheRD.get_cache(skybox_blend_shader, 0, uniforms + [
				_uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 31, [skybox_texture]),
				_uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 32, [skybox_keys[0]]),
				_uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 33, [skybox_keys[1]]),
			])

	rd.capture_timestamp("Sunshine Clouds Skybox")
	skybox_age += 1
	# With spherical_planet, the horizon also tilts as the camera moves around the planet.
	var camera_height := get_cloud_height(camera_position)
	var camera_up := get_planet_up(camera_position)
	var reset := skybox_keys_ready == 0 || absf(camera_height - skybox_key_camera_height) > 200.0 * cloud_scale \
		|| sun_direction.dot(skybox_key_sun) < 0.9998 || camera_up.dot(skybox_key_up) < 0.9998 # 200.0: camera height change (m, times cloud_scale) since the last render that re-renders the skybox at once. 100-500: lower snaps sooner on big climbs, higher leans on the interval updates.
	# Nothing it depends on changed since the last render: it stays as it is (so the editor, which
	# only redraws on changes, can go idle).
	var clouds_state := layers_bytes.slice(0, layer_count * LAYER_BYTES) if skybox_clouds else PackedByteArray()
	var changed := absf(camera_height - skybox_key_camera_height) > 1.0 * cloud_scale || !sun_direction.is_equal_approx(skybox_key_sun) \
		|| !camera_up.is_equal_approx(skybox_key_up) \
		|| clouds_state != skybox_key_clouds || lights_version != skybox_key_lights # 1.0: camera height change (m, times cloud_scale) below which an otherwise unchanged skybox idles. 0.5-5: lower re-renders on tiny bobs, higher lets the horizon drift.
	var groups := Vector2i(ceili(size.x / 8.0), ceili(size.y / 8.0))
	if reset || (changed && (!use_keys || skybox_age >= skybox_update_interval)):
		if use_keys:
			skybox_key = 1 - skybox_key
		skybox_keys_ready = 1 if reset || !use_keys else 2
		skybox_age = 0
		skybox_key_camera_height = camera_height
		skybox_key_up = camera_up
		skybox_key_sun = sun_direction
		skybox_key_clouds = clouds_state
		skybox_key_lights = lights_version
		skybox_blended = false
		skybox_version += 1
		var list := rd.compute_list_begin()
		rd.compute_list_bind_compute_pipeline(list, _pipeline(skybox_pipelines, layer_count, skybox_shader, layer_count))
		rd.compute_list_bind_uniform_set(list, skybox_sets[1 + skybox_key if use_keys else 0], 0)
		rd.compute_list_dispatch(list, groups.x, groups.y, 1)
		rd.compute_list_end()
	if use_keys && !skybox_blended:
		# As the shadow map's: the latest key's weight goes from 1 / interval after it's rendered to 1
		# when the next one is due; with only one key so far it's that one. Done once it's at 1.
		var latest_weight := minf(float(skybox_age + 1) / skybox_update_interval, 1.0) if skybox_keys_ready == 2 else 1.0
		skybox_blended = latest_weight >= 1.0
		skybox_version += 1
		push_bytes.encode_float(0, latest_weight if skybox_key == 1 else 1.0 - latest_weight)
		var list := rd.compute_list_begin()
		rd.compute_list_bind_compute_pipeline(list, skybox_blend_pipeline)
		rd.compute_list_bind_uniform_set(list, skybox_blend_set, 0)
		rd.compute_list_set_push_constant(list, push_bytes, push_bytes.size())
		rd.compute_list_dispatch(list, groups.x, groups.y, 1)
		rd.compute_list_end()


## Calls the batch's callables with (position, density), in the order they were added. As
## SunshineClouds2's retrieve_position_queries().
func retrieve_position_queries(data : PackedByteArray):
	position_query_mutex.lock()
	var callables := positionQueryCallables.slice(0, positionQueriesEncoded)
	positionQueryCallables = positionQueryCallables.slice(positionQueriesEncoded)
	position_query_mutex.unlock()

	for i in callables.size():
		var offset := i * 16
		callables[i].call(Vector3(data.decode_float(offset), data.decode_float(offset + 4), data.decode_float(offset + 8)), data.decode_float(offset + 12))

	positionQueriesEncoded = 0
	positionQuerying = false
	positionResetting = false


func _encode_mat4(bytes : PackedByteArray, offset : int, value : Projection) -> void:
	for column in 4:
		var c : Vector4 = value[column]
		for row in 4:
			bytes.encode_float(offset + (column * 4 + row) * 4, c[row])


func _encode_vec4(bytes : PackedByteArray, offset : int, v : Vector3, w : float) -> void:
	bytes.encode_float(offset, v.x)
	bytes.encode_float(offset + 4, v.y)
	bytes.encode_float(offset + 8, v.z)
	bytes.encode_float(offset + 12, w)
