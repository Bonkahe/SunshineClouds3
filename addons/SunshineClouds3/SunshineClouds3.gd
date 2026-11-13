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
const PARAMS_BYTES := 512
## Cosine to the vertical below which a light is left out of the atmosphere: Bruneton's mu_s_min
## (102 degrees, end of twilight) less 0.03 for points up to ~200 km away, where the vertical has tilted.
const ATMOSPHERE_LIGHT_MIN_MU := -0.238
## Meta a SunshineClouds3Driver sets on a directional light it hid below the horizon (see
## CloudDirectionalLightSettings.drive_light_color): the clouds and the atmosphere keep it as shown.
const BELOW_HORIZON_META := &"_sunshine_clouds3_below_horizon"
const ATMOSPHERE_BYTES := 304
const SKY_BYTES := 144
## The Heightmap block in SunshineClouds3Raymarch.glsl.
const HEIGHTMAP_BYTES := 48
## The raymarch shader's versions with the terrain heightmap, loaded the first time it's on.
const HEIGHTMAP_VERSIONS : Array[StringName] = [&"raymarch_heightmap", &"raymarch_msaa_heightmap", &"shadow_map_heightmap", &"skybox_heightmap", &"sample_points_heightmap"]

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
const SET_INPUT_COUNT := 9 + VIEW_TEXTURES


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

## Henyey-Greenstein g of the direct light. Higher concentrates it forward: brighter silver linings
## towards the light, darker away. 0.3-0.8 suits clouds.
@export_range(0.01, 0.99, 0.01) var primary_phase_g : float = 0.08

## Henyey-Greenstein g of the multiple scattering glow (ms_volume). Bounced light has lost its
## direction, so keep it low (0.0-0.3); this lights the side facing away from the light.
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
## Forgets the last directional lights a driver gave; the fallback light is used until a driver gives more.
@export_tool_button("Forget Last Lights", "Clear") var forget_last_lights_action = forget_last_lights

@export_group("Ambient Scattering")

@export var ambient_color : Color = Color(1.0, 0.3889187, 0.2613985)
## Ground bounce colour: the density-aware ambient's light from below (ambient_color is from above).
@export var ground_color : Color = Color(1.0, 0.3889187, 0.2613985)
@export_range(0.0, 10.0, 0.01, "or_greater") var ambient_energy : float = 1.0
## 0: ambient follows the layer profile only (flat dark sides). 1: density-aware, sky and ground
## light dimmed through the cloud, so dense cores darken and wisps stay lit.
@export_range(0.0, 1.0, 0.01) var ambient_occlusion : float = 0.99
## Light from below as a fraction of the sky light from above, for the density-aware ambient.
@export_range(0.0, 2.0, 0.01, "or_greater") var ambient_ground_strength : float = 0.92
## Scales the density-aware ambient's occluding extinction: lower reaches further into the cloud.
@export_range(0.0, 1.0, 0.0001, "or_greater") var ambient_extinction_scale : float = 0.1861


@export_group("Atmosphere")

@export var atmosphere_enabled : bool = true

## Air in the scene's shadow gives no glow around a light (no halo over a hill hiding the sun).
## Uses the screen depth buffer, so only on-screen geometry shadows. Costs a few depth reads per
## pixel per light.
@export var atmosphere_glow_shadows : bool = true

## Multiplies the atmosphere's own light: sky (not the sun disc), haze, and sky light on the clouds
## and skybox ground.
@export_color_no_alpha var atmosphere_tint : Color = Color.WHITE

## Scene units per unit of precomputed atmosphere light; scales the sky, discs, haze and the
## directional lights on the clouds alike. Each directional light also scales the atmosphere by its
## colour * energy (see set_lights()): energy 1 is the atmosphere's sun, 0.1 a tenth of it.
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
## Angular radius of every directional light's sky disc. Below energy 1 a disc only partly covers
## the background, so a dim moon's disc lets a moon on background_texture show through.
@export_range(0.0001, 0.1, 0.0001, "suffix:rad") var sun_angular_radius : float = 0.0156:
	set(value):
		sun_angular_radius = value
		atmosphere_changed = true
@export_range(1, 8) var scattering_orders : int = 8:
	set(value):
		scattering_orders = value
		atmosphere_changed = true

@export_group("Spherical Planet Settings")
## Curves the cloud layers, atmosphere and cloud shadows around a sphere of planet_radius at
## planet_center; heights become altitudes (ground_height is unused). Off: flat along world Y.
## Breaks coverage noise (still in flat world space), so disable that with this on. Driven light colour is
## also wrong when the sun is on the far side of the planet (red instead of its set colour).
@export var spherical_planet : bool = false
## World position of the planet's centre, with spherical_planet.
@export var planet_center : Vector3 = Vector3(0.0, -6360000.0, 0.0)

@export_group("Quality")
## Step size at the camera: near_step_size + far_step_size_offset * distance / step_adjustment_distance.
@export_range(0.1, 100.0, 0.1, "or_greater") var near_step_size : float = 3.0
## Step size added to near_step_size at step_adjustment_distance.
@export_range(0.0, 1000.0, 0.1, "or_greater") var far_step_size_offset : float = 100.0
## Distance at which far_step_size_offset is fully applied.
@export_range(1.0, 100000.0, 1.0, "or_greater") var step_adjustment_distance : float = 6000.0
## View step size once a ray has found cloud. Lower is less noisy but costs performance and can band.
@export_range(1.0, 1000.0, 0.1, "or_greater") var cloud_step_size : float = 10.0
## Samples in a row that find no cloud before the view ray goes back to coarse steps.
@export_range(1, 64) var cloud_exit_steps : int = 10
## Renders a subset of pixels each frame; the rest reproject in between.
@export_enum("Off:1", "Half:2", "Quarter:4", "Eighth:8") var interlace : int = 2
## Maximum raymarch steps; usually the main performance control.
@export_range(1, 4096) var max_steps : int = 600
## Total distance the lighting is sampled over.
@export_range(1.0, 100000.0, 1.0, "or_greater") var light_march_distance : float = 2000.0
## Each light step is this much longer than the previous one. 1 = even steps.
@export_range(1.0, 3.0, 0.01) var light_step_growth : float = 2.15
## Maximum distance used for the clouds.
@export_range(100.0, 200000.0, 1.0, "or_greater") var max_distance : float = 150000.0
## Traces one random pixel per N x N block each frame; the resolve reconstructs at full resolution.
@export_enum("Full:1", "Half:2", "Quarter:4") var raymarch_resolution : int = 2

@export_group("Accumulation")
## Weight of the new frame when blending with the history. 1 = no accumulation.
@export_range(0.001, 1.0, 0.001) var current_frame_weight : float = 0.1
## Within this distance the history isn't moved with the wind (fading in linearly): up close the
## wind's screen jump ghosts across silhouettes.
@export_range(0.0, 10000.0, 1.0, "or_greater", "suffix:m") var wind_reprojection_distance : float = 500.0

@export_group("Cloud Shadows")
## Renders cloud shadows onto the strongest directional light.
@export var cloud_shadows : bool = true
## Light Projector: the driver puts the map on its directional light as a projector (needs the light
## casting shadows and an engine build with https://github.com/godotengine/godot/pull/106294).
## Screen Space: the resolve darkens opaque surfaces, ambient included; also the projector fallback.
@export_enum("Light Projector:0", "Screen Space:1") var cloud_shadow_mode : int = SHADOW_MODE_PROJECTOR
@export_enum("512:512", "1024:1024", "2048:2048") var cloud_shadow_resolution : int = 512
## Width of the shadowed area, centred on the camera (times cloud_scale).
@export_range(1000.0, 512000.0, 100.0, "or_greater", "suffix:m") var cloud_shadow_extent : float = 80000.0
@export_range(1, 64) var cloud_shadow_steps : int = 32
@export_range(0.0, 1.0, 0.001, "or_greater") var cloud_shadow_strength : float = 0.549
@export_range(0.05, 4.0, 0.01) var cloud_shadow_sharpness : float = 0.97
@export_range(0.0, 45.0, 0.1, "suffix:°") var cloud_shadow_horizon_fade : float = 45.0
## Frames between shadow map renders, blended from one to the next in between (1 = every frame).
## Higher saves GPU time; the shadows then trail the clouds by about this many frames.
@export_range(1, 128) var cloud_shadow_update_interval : int = 12
## Fraction of the way to the edge of cloud_shadow_extent where shadows start fading. 1 = no fade.
@export_range(0.0, 1.0, 0.01) var cloud_shadow_edge_fade : float = 0.7
@export_subgroup("Screen Space")
@export_range(0.0, 1.0, 0.01) var screen_space_shadow_strength : float = 0.6

@export_group("Background")
## Equirectangular panorama (as PanoramaSkyMaterial) behind the atmosphere and clouds, e.g. stars.
## Fades where the sky in front is bright. Colours are scene-unit light times background_color and
## background_energy. Needs atmosphere_enabled.
@export var background_texture : Texture2D
@export var background_color : Color = Color.WHITE
@export_range(0.0, 16.0, 0.001, "or_greater") var background_energy : float = 1.0
## Sky luminance (scene units) that dims the background to about a third. At radiance_scale 1 a
## clear midday zenith is ~0.06, the sky away from a sun 3 degrees below the horizon ~0.0005.
## 0 = never fades.
@export_range(0.0, 0.1, 0.0001, "or_greater") var background_fade_brightness : float = 0.002
## Background rotation (Euler degrees, as Environment.sky_rotation); animate to move the stars.
@export var background_rotation : Vector3 = Vector3.ZERO
## Scales the background in the skybox only (reflections and ambient), on top of background_energy.
@export_range(0.0, 16.0, 0.001, "or_greater") var background_skybox_energy : float = 1.0

@export_group("Skybox")
## Renders the atmosphere, background and a coarse cloud march into a low resolution panorama that a
## SunshineClouds3Driver with a world_environment uses as its sky (editor too), so reflections and
## ambient light follow the atmosphere. Needs atmosphere_enabled.
@export var skybox_enabled : bool = true
## Panorama width (height is half).
@export_enum("64:64", "128:128", "256:256", "512:512", "1024:1024") var skybox_resolution : int = 64
## The Sky's radiance_size: the resolution Godot filters reflections and ambient light at.
@export_enum("32:0", "64:1", "128:2", "256:3", "512:4") var skybox_radiance_size : int = Sky.RADIANCE_SIZE_32
## Frames between panorama renders, blended in between (1 = every frame). Re-renders at once when
## the sun, camera height or settings jump.
@export_range(1, 128) var skybox_update_interval : int = 32
## Albedo of the panorama's ground below the horizon.
@export var skybox_ground_color : Color = Color(0.1875, 0.17620538, 0.13044626)
## Scales the skybox's brightness, and so its reflections and ambient (not the on-screen sky).
@export_range(0.0, 4.0, 0.01, "or_greater") var skybox_energy : float = 1.0
## How much coverage and density darken the skybox: radiance *= 1 - this * (coverage + density) / 2.
## 0 = not at all.
@export_range(0.0, 1.0, 0.01) var skybox_cloud_dimming : float = 0.0
## Renders the skybox from world Y skybox_height (at the camera's X and Z) instead of from the camera.
@export var skybox_fixed_height : bool = false
## World Y the skybox is rendered from with skybox_fixed_height.
@export var skybox_height : float = 0.0
@export_subgroup("Clouds")
## Marches the clouds into the skybox, far coarser than on screen: even steps, no curl noise or omni
## lights. Off leaves a clear sky.
@export var skybox_clouds : bool = true
## Even steps along each skybox ray up to skybox_cloud_distance.
@export_range(1, 128) var skybox_cloud_steps : int = 4
## Light steps per cloud sample (0 = fully lit), over light_march_distance growing by light_step_growth.
@export_range(0, 8) var skybox_cloud_light_steps : int = 2
## How far along a skybox ray the clouds are marched.
@export_range(1000.0, 200000.0, 100.0, "or_greater", "suffix:m") var skybox_cloud_distance : float = 10000.0

@export_group("Reflections")
## Writes the frame's colour (with clouds) and per-pixel distance into one image each frame, for
## screen-space reflection materials (see Resources/Shaders/SunshineClouds3SSR.gdshader).
@export var reflections_enabled : bool = false:
	set(value):
		reflections_enabled = value
		_queue_reflection_update()
## Global shader parameter (sampler2D) the image is set as.
@export var reflection_parameter : StringName = &"sunshine_clouds_reflection":
	set(value):
		reflection_parameter = value
		_queue_reflection_update()
## Adds reflection_parameter to Project Settings > Globals > Shader Globals, so materials reading it compile.
@export_tool_button("Add To Project Shader Globals", "Add") var add_reflection_global_action = add_reflection_parameter_to_project

@export_group("Terrain Heightmap")
## Lifts the cloud layers over terrain
@export var heightmap_enabled : bool = false:
	set(value):
		heightmap_enabled = value
		heightmap_version += 1

@export var heightmap : Texture2D:
	set(value):
		if heightmap && heightmap.changed.is_connected(_heightmap_changed):
			heightmap.changed.disconnect(_heightmap_changed)
		heightmap = value
		if heightmap:
			heightmap.changed.connect(_heightmap_changed)
		heightmap_version += 1
## X and Z: world position of the texture's (0, 0) outer corner (not the first texel's centre);
## u runs along +X, v along +Z.
@export var heightmap_position : Vector3 = Vector3.ZERO
## The world size (m) the whole texture covers along X and Z.
@export var heightmap_size : Vector2 = Vector2(10000.0, 10000.0)
## Metres of terrain height per texel value (1 for a texture holding metres).
@export_range(0.0, 10000.0, 0.01, "or_greater", "suffix:m") var heightmap_height_scale : float = 1000.0
## Max terrain rise above heightmap_position.y (m); higher is clamped. Widens the march bounds, so
## keep it close to the real maximum. 0: heightmap_height_scale (a texture holding 0..1).
@export_range(0.0, 10000.0, 1.0, "or_greater", "suffix:m") var heightmap_max_height : float = 0.0
## Up to this height above the terrain, layers are lifted one for one with it.
@export_range(0.0, 10000.0, 1.0, "or_greater", "suffix:m") var heightmap_falloff_min : float = 500.0
## From this height above the terrain there's no lift; between the two it fades out smoothly.
@export_range(0.0, 20000.0, 1.0, "or_greater", "suffix:m") var heightmap_falloff_max : float = 2000.0

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
## Off by default: the check hashes every shader file once a second (~4.6 ms on the main thread, can lag out the editor, only leave it on when changing compute things).
@export var auto_reload_shaders : bool = false
## Reimports and recompiles the shaders (the editor doesn't reimport the shaders including an
## edited .glslinc, and the clouds keep the shaders they compiled either way).
@export_tool_button("Reload Shaders", "Reload") var reload_shaders_action = reload_shaders

# Rendering device: every GPU resource below is created on it.
var rd : RenderingDevice

# Shaders: compute shaders for each pass, including the 3D MSAA variants.
var shader : RID
var resolve_shader : RID
var raymarch_msaa_shader : RID
var resolve_msaa_shader : RID
var msaa_composite_shader : RID
var shadow_shader : RID
var shadow_blend_shader : RID
var skybox_shader : RID
var skybox_blend_shader : RID
var sample_shader : RID
var precompute_shaders : Array[RID] = []

# Pipelines: created on first use by _pipeline(); MSAA composite pipelines keyed by framebuffer format.
var raymarch_pipelines : Array[RID] = []
var resolve_pipelines : Array[RID] = []
var shadow_pipelines : Array[RID] = []
var skybox_pipelines : Array[RID] = []
var sample_pipelines : Array[RID] = []
var precompute_pipelines : Array[RID] = []
var shadow_blend_pipeline : RID
var skybox_blend_pipeline : RID
var msaa_composite_pipelines := {}

# Samplers and fallbacks: shared samplers and a black texture bound when there's no background.
var nearest_sampler : RID
var noise_sampler : RID
var lut_sampler : RID
var background_sampler : RID
var black_texture : RID

# GPU buffers: uniform and storage buffers the staging bytes are uploaded into.
var params_buffer : RID
var layers_buffer : RID
var shadow_buffer : RID
var sky_buffer : RID
var atmosphere_buffer : RID
var point_sample_data_buffer : RID
var lights_buffer : RID

# Upload staging: CPU-side bytes for the GPU buffers and push constants, sized in _initialize().
var params_bytes := PackedByteArray()
var layers_bytes := PackedByteArray()
var shadow_bytes := PackedByteArray()
var sky_bytes := PackedByteArray()
var atmosphere_bytes := PackedByteArray()
var sample_bytes := PackedByteArray()
var push_bytes := PackedByteArray()

# Texture retirement: replaced textures and the engine frame each is safe to free from.
var retired_textures : Array[RID] = []
var retired_frames := PackedInt64Array()

# Per-viewport state: ViewportStates by render buffers id, the current view's textures, and the last once-per-frame run.
var viewport_states := {}
var view_textures : Array[RID] = [RID(), RID(), RID(), RID(), RID(), RID()]
var last_engine_frame := -1

# Atmosphere: precomputed scattering LUTs, recompute flags, and the last sky settings written.
var transmittance_texture : RID
var scattering_texture : RID
var irradiance_texture : RID
var atmosphere_changed : bool = true
var atmosphere_precompute_pending : bool = true
var sky_settings_key := []

# Cloud layers: enabled and last-synced layers, the profile texture, and the base noise's mean and deviation.
var active_layers : Array[CloudLayer] = []
var synced_layers : Array[CloudLayer] = []
var profile_texture : ImageTexture
var profile_image : Image
var noise_stats := Vector2(0.5, 0.25)
var noise_stats_texture : Texture3D

# Shadow map: the blended texture, two keys rendered in turn (latest, ready count, age, camera and sun), and uniform sets.
var shadow_texture : RID
var shadow_texture_resolution := 0
var shadow_camera := Vector3.ZERO
var shadow_keys : Array[RID] = [RID(), RID()]
var shadow_key := 0
var shadow_keys_ready := 0
var shadow_age := 0
var shadow_key_camera := Vector3.ZERO
var shadow_key_sun := Vector3.ZERO
var shadow_sets : Array[RID] = [RID(), RID(), RID()]
var shadow_blend_set : RID

# Shadow caster: the shadow light (instance id, 0 = none), its direction, and whether it's fading out for the next one.
var shadow_caster_id := 0
var shadow_caster_direction := Vector3.ZERO
var shadow_fading := false

# Shadow projector: the driver's projector, blit material, light and window centre (requests cross threads under the mutex).
var shadow_projector : RID
var shadow_projector_size := Vector2i.ZERO
var shadow_blit_material : RID
var shadow_light_transform : Transform3D
var shadow_projector_light_id := 0
var shadow_projector_center := Vector2.ZERO
var shadow_projector_windowed := false
var shadow_source : Texture2DRD
var _shadow_projector_center_request := Vector2.ZERO
var _shadow_projector_center_mutex := Mutex.new()

# Density sample sets: the point-sample uniform set and the RIDs it was last built with.
var sample_set : RID
var density_set_inputs := PackedInt64Array()

# Density sample queries: queued by add_sample(), answered up to MAX_SAMPLE_POINTS per batch (as SunshineClouds2).
var positionQueries : Array[Vector3] = []
var positionQueryCallables : Array[Callable] = []
var positionQuerying : bool = false
var positionResetting : bool = false
var positionQueriesEncoded : int = 0
var position_query_mutex := Mutex.new()

# Skybox: panorama blended between two keys like the shadow map, its uniform sets, and request/version tracking.
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
var skybox_sets : Array[RID] = [RID(), RID(), RID()]
var skybox_blend_set : RID
var skybox_set_inputs := PackedInt64Array()
var skybox_blended := false
var skybox_version := 0
var skybox_requested_msec := -1

# Reflections: the image and its texture, global shader parameter, owning viewport, shaders and pipelines.
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

# Terrain heightmap: shaders (loaded on first use), buffer, last uploaded bytes, and a version bumped on change.
var heightmap_shaders : Array[RID] = []
var heightmap_buffer : RID
var heightmap_bytes := PackedByteArray()
var heightmap_version := 0
var heightmap_failed := false

# Light and effector encoding: encoded on the main thread, uploaded on the render thread when dirty (lights_mutex).
var lights_mutex := Mutex.new()
var lights_bytes := PackedByteArray()
var effector_bytes := PackedByteArray()
var omni_count := 0
var effector_count := 0
var lights_key := []
var effectors_key := []
var lights_dirty := true
var lights_version := 0
var uploaded_atmosphere_enabled := false
var lights_set_msec := -100000
var point_scores := PackedFloat32Array()

# Directional light tracking: instance ids and directions, and the light that should cast shadows.
var light_ids := PackedInt64Array([0, 0, 0, 0])
var light_directions := PackedVector3Array([Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO])
var light_id_count := 0
var wanted_caster_id := 0
var wanted_caster_direction := Vector3.ZERO

# Light driving and fallback: whether a driver gave lights in the last 0.5 s, and fallback state.
var lights_driven := false
var using_fallback := true
var fallback_key := []

# Default settings: for lights and effectors without their own.
var default_directional_settings := CloudDirectionalLightSettings.new()
var default_omni_settings := CloudOmniLightSettings.new()
var default_effector_settings := CloudEffectorSettings.new()

# Atmosphere lights: direction and colour * energy of each, plus the render thread's per-frame copies.
var atmosphere_light_directions := PackedVector3Array()
var atmosphere_light_weights := PackedVector3Array()
var frame_light_directions := PackedVector3Array()
var frame_light_weights := PackedVector3Array()

# Shader hot reload: the sources' last md5s and the next check time.
var shader_sources_hash := ""
var next_shader_check := 0

# The last directional lights a driver gave (direction, colour * energy before radiance scale and
# multiplier, shadow samples), saved with the effect for the fallback.
@export_storage var has_last_directional := false
@export_storage var last_directional_directions := PackedVector3Array()
@export_storage var last_directional_radiance := PackedVector3Array()
@export_storage var last_directional_samples := PackedInt32Array()


## Per-viewport state (its textures live in its render buffers).
class ViewportState:
	# History: frame count and last view projections, for reprojection.
	var frame := 0
	var prev_view_projections : Array[Projection] = []

	# Uniform sets: per view and parity, rebuilt when set_inputs changes or the device drops them.
	var raymarch_sets : Array[RID] = []
	var resolve_sets : Array[RID] = []
	var set_inputs := PackedInt64Array()

	# Reflections: pixel count and last drawn frame, used to pick the viewport writing the reflection image.
	var reflection_pixels := 0
	var reflection_frame := -1


## Queues a cloud density sample at position (world space)
func add_sample(callable : Callable, position : Vector3):
	position_query_mutex.lock()
	positionQueries.append(position)
	positionQueryCallables.append(callable)
	position_query_mutex.unlock()

func request_skybox() -> void:
	skybox_requested_msec = Time.get_ticks_msec()

func get_reflection_texture() -> Texture2DRD:
	return reflection_texture

func set_heightmap(texture : Texture2D, position : Vector3, size : Vector2, height_scale : float = 1.0, max_height : float = 0.0) -> void:
	heightmap = texture
	heightmap_position = position
	heightmap_size = size
	heightmap_height_scale = height_scale
	heightmap_max_height = max_height
	heightmap_enabled = true
	heightmap_version += 1

func clear_heightmap() -> void:
	heightmap_enabled = false
	heightmap = null

func _heightmap_changed() -> void:
	heightmap_version += 1


func _heightmap_on() -> bool:
	return heightmap_enabled && heightmap != null && heightmap_size.x > 0.0 && heightmap_size.y > 0.0


## The most the terrain rises above heightmap_position.y.
func _heightmap_max_height() -> float:
	return heightmap_max_height if heightmap_max_height > 0.0 else maxf(heightmap_height_scale, 0.0)


## Highest a layer from floor_height to ceiling (world heights, cloud_scale applied) reaches when
## lifted; matches lifted_ceiling() in SunshineClouds3Raymarch.glsl.
func _lifted_ceiling(floor_height : float, ceiling : float) -> float:
	var terrain_top := heightmap_position.y + _heightmap_max_height()
	return maxf(ceiling, minf(ceiling + maxf(terrain_top - floor_height, 0.0), terrain_top + maxf(heightmap_falloff_max, heightmap_falloff_min)))


## Bindings for the _heightmap shader versions: the texture (bilinear, clamped) and Heightmap buffer.
func _heightmap_uniforms(heightmap_rid : RID) -> Array[RDUniform]:
	return [
		_uniform(RenderingDevice.UNIFORM_TYPE_SAMPLER_WITH_TEXTURE, 34, [lut_sampler, heightmap_rid]),
		_uniform(RenderingDevice.UNIFORM_TYPE_UNIFORM_BUFFER, 35, [heightmap_buffer]),
	]


## The Heightmap block's bytes (HEIGHTMAP_BYTES).
func _encode_heightmap(bytes : PackedByteArray) -> void:
	var max_height := _heightmap_max_height()
	var falloff_max := maxf(heightmap_falloff_max, heightmap_falloff_min)
	bytes.encode_float(0, heightmap_position.x)
	bytes.encode_float(4, heightmap_position.z)
	bytes.encode_float(8, 1.0 / heightmap_size.x)
	bytes.encode_float(12, 1.0 / heightmap_size.y)
	bytes.encode_float(16, heightmap_position.y)
	bytes.encode_float(20, heightmap_height_scale)
	bytes.encode_float(24, max_height)
	bytes.encode_float(28, heightmap_falloff_min)
	bytes.encode_float(32, 1.0 / maxf(falloff_max - heightmap_falloff_min, 1e-3))
	bytes.encode_float(36, heightmap_position.y + max_height)
	bytes.encode_float(40, heightmap_position.y + max_height + falloff_max)
	bytes.encode_float(44, 0.0)


## Creates the heightmap shaders and buffer on first use (render thread). False on failure; the
## clouds then draw without it.
func _ensure_heightmap_resources() -> bool:
	if !heightmap_shaders.is_empty():
		return true
	if heightmap_failed:
		return false
	var shaders : Array[RID] = []
	for version in HEIGHTMAP_VERSIONS:
		shaders.append(_load_shader(SHADER_PATH, version))
	if shaders.has(RID()):
		for s in shaders:
			if s.is_valid():
				rd.free_rid(s)
		heightmap_failed = true
		return false
	heightmap_shaders = shaders
	if !heightmap_buffer.is_valid():
		heightmap_buffer = rd.uniform_buffer_create(HEIGHTMAP_BYTES)
		# Uploaded on first use.
		heightmap_bytes = PackedByteArray()
	return true


## Adds reflection_parameter to the project's shader globals as an empty sampler2D (set at run
## time) and saves the project settings. Editor only.
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
	# Register it with the editor's RenderingServer, as the shader globals editor would.
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


## mid_frame: called from the render callback; the Texture2DRD is repointed next frame (_point_reflection_texture).
func _create_reflection_image(size : Vector2i, mid_frame := false) -> void:
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
	if mid_frame:
		_point_reflection_texture.call_deferred(reflection_rd)
	else:
		reflection_texture.texture_rd_rid = reflection_rd


func _point_reflection_texture(texture : RID) -> void:
	if reflection_texture == null || texture != reflection_rd || !rd.texture_is_valid(texture):
		return # Superseded by a newer image, or reflections were turned off.
	reflection_texture.texture_rd_rid = texture

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
		_create_reflection_image(size, true)
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
	lights_bytes.resize(144 + MAX_OMNI_LIGHTS * 48) # 144 byte header + directional lights, then 48 bytes per omni light (effectors follow). Must match the Lights block in SunshineClouds3Raymarch.glsl.
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
		skybox_texture, skybox_keys[0], skybox_keys[1], black_texture, reflection_shaders[0], reflection_shaders[1], heightmap_buffer]
	rids.append_array(heightmap_shaders)
	# Remove a global this effect added (inlined: its own functions can't be called here).
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


## Reimports (in the editor) and recompiles the shaders on the render thread; if one fails, the old
## ones are kept.
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
	next_shader_check = Time.get_ticks_msec() + 1000 # Poll interval (ms). 500-2000: lower reacts faster but hashes every shader file more often.
	if !Engine.has_singleton(&"EditorInterface") || Engine.get_singleton(&"EditorInterface").get_resource_filesystem().is_scanning():
		return
	var sources_hash := _shader_sources_hash()
	if sources_hash != shader_sources_hash:
		shader_sources_hash = sources_hash
		reload_shaders()


func _shader_sources_hash() -> String:
	var hashes := PackedStringArray()
	for directory : String in ["res://addons/SunshineClouds3/Compute/", "res://addons/SunshineClouds3/Compute/atmosphere/"]: # Watched shader folders; add new ones here.
		for file in DirAccess.get_files_at(directory):
			if file.get_extension() == "glsl" || file.get_extension() == "glslinc":
				hashes.append(FileAccess.get_md5(directory + file))
	return "".join(hashes)


## Rebuilds active_layers from the enabled layers and rebakes the profiles; reruns whenever a layer changes.
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
	var spirv := (load("res://addons/SunshineClouds3/Compute/SunshineClouds3CurlNoise.glsl") as RDShaderFile).get_spirv()
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


## Saves images as an ImageTexture3D at path, rebuilding any loaded copy in place so users update.
## Returns null on failure.
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
	lights_buffer = rd.uniform_buffer_create(144 + (MAX_OMNI_LIGHTS + MAX_EFFECTORS) * 48) # Lights block: 144 byte header + directional lights, then 48 bytes per point (omni lights, then effectors). Must match SunshineClouds3Raymarch.glsl.

	params_bytes.resize(PARAMS_BYTES)
	layers_bytes.resize(MAX_LAYERS * LAYER_BYTES)
	shadow_bytes.resize(SHADOW_BYTES)
	sky_bytes.resize(SKY_BYTES)
	atmosphere_bytes.resize(ATMOSPHERE_BYTES)
	sample_bytes.resize(SAMPLE_BUFFER_BYTES)
	push_bytes.resize(16)
	density_set_inputs.resize(8)
	skybox_set_inputs.resize(8)


## Compiles the shaders, freeing those replaced (and with them their pipelines and uniform sets).
## Returns false, keeping the old ones, if a draw shader fails; without the sample shader, samples stay queued.
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
	# The reflection shaders reload on next use.
	for s : RID in reflection_shaders:
		if s.is_valid():
			rd.free_rid(s)
	reflection_shaders = [RID(), RID()]
	reflection_pipelines = [RID(), RID()]
	# The heightmap shaders too.
	for s : RID in heightmap_shaders:
		if s.is_valid():
			rd.free_rid(s)
	heightmap_shaders = []
	heightmap_failed = false
	precompute_shaders = new_shaders.slice(9)
	sample_shader = new_sample_shader

	for pipelines : Array[RID] in [raymarch_pipelines, resolve_pipelines, shadow_pipelines, skybox_pipelines, sample_pipelines, precompute_pipelines]:
		pipelines.clear()
	raymarch_pipelines.resize((MAX_LAYERS + 1) * 3 * 2 * 2) # Layer count x interlace pass x MSAA off/on x heightmap off/on.
	resolve_pipelines.resize(8) # Atmosphere x MSAA x glow shadows, each off/on.
	# Layer count x heightmap off/on.
	shadow_pipelines.resize((MAX_LAYERS + 1) * 2)
	skybox_pipelines.resize((MAX_LAYERS + 1) * 2)
	sample_pipelines.resize((MAX_LAYERS + 1) * 2)
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
	retired_frames.append(Engine.get_frames_drawn() + 3) # Freeing mid frame breaks materials drawn later that frame. 2-4: must cover frames in flight; higher only holds VRAM longer.


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


## Called by SunshineClouds3Driver (render thread): the projector (a DrawableTexture2D of target_size)
## the shadow map is blitted into each frame via blit_material, and its light's transform and instance
## id. An invalid target falls back to screen-space shadows.
func set_shadow_projector(target : RID, target_size : Vector2i, blit_material : RID, light_transform : Transform3D, light_id : int) -> void:
	shadow_projector = target
	shadow_projector_size = target_size
	shadow_blit_material = blit_material
	shadow_light_transform = light_transform
	shadow_projector_light_id = light_id


## Called by SunshineClouds3Driver (render thread): the light-space point (light local XY) the projector
## window is centred on from the next blit (its offset is minus it), and whether the light has repeat
## off (windowed); otherwise the map is blitted as is.
func set_shadow_projector_center(center : Vector2, windowed : bool) -> void:
	shadow_projector_center = center
	shadow_projector_windowed = windowed


## Called by SunshineClouds3Driver (main thread): where the projector window should move, i.e. the
## first viewport's camera in light space snapped to map texels.
func get_shadow_projector_center_request() -> Vector2:
	_shadow_projector_center_mutex.lock()
	var center := _shadow_projector_center_request
	_shadow_projector_center_mutex.unlock()
	return center


func set_lights(directional_lights : Array[DirectionalLight3D], directional_settings : Array[CloudDirectionalLightSettings],
		omni_lights : Array[OmniLight3D], omni_settings : Array[CloudOmniLightSettings], camera_position : Vector3) -> void:
	var layers_span := _layers_span()
	var key := [radiance_scale, directional_energy_multiplier, omni_energy_multiplier, cloud_shadow_horizon_fade, light_step_growth,
		light_march_distance, layers_span, cloud_scale]
	if omni_lights.size() > MAX_OMNI_LIGHTS:
		# The nearest set changes as the camera moves.
		key.append(camera_position)
	for i in directional_lights.size():
		if !is_instance_valid(directional_lights[i]):
			key.append(null)
			continue
		var light : DirectionalLight3D = directional_lights[i]
		var settings := directional_settings[i] if i < directional_settings.size() && directional_settings[i] else default_directional_settings
		key.append_array([light, light.global_transform.basis, light.light_energy, light.light_volumetric_fog_energy, light_shown(light),
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


# Lowest floor and highest ceiling of the layers, times cloud_scale (ceilings at max heightmap lift while on).
func _layers_span() -> Vector2:
	var span := Vector2(INF, -INF)
	var lifted := _heightmap_on()
	for layer in active_layers:
		var ceiling := layer.cloud_ceiling * cloud_scale
		if lifted:
			ceiling = _lifted_ceiling(layer.cloud_floor * cloud_scale, ceiling)
		span = Vector2(minf(span.x, layer.cloud_floor * cloud_scale), maxf(span.y, ceiling))
	return span


func _reaches_layers(position : Vector3, radius : float, layers_span : Vector2) -> bool:
	var height := get_cloud_height(position)
	return radius > 0.0 && height - radius <= layers_span.y && height + radius >= layers_span.x


## planet_center with spherical_planet, else (0, -planet_radius, 0); shifted so the planet's top
## stays put as cloud_scale scales its radius.
func get_planet_center() -> Vector3:
	var center := planet_center if spherical_planet else Vector3(0.0, -planet_radius * 1000.0, 0.0)
	return center + Vector3.UP * planet_radius * 1000.0 * (1.0 - cloud_scale)


## Height the cloud layers are placed by: world Y, or with spherical_planet the altitude above the surface.
func get_cloud_height(position : Vector3) -> float:
	return position.distance_to(get_planet_center()) - planet_radius * 1000.0 * cloud_scale if spherical_planet else position.y


## Up at position: away from the planet's centre with spherical_planet, else +Y.
func get_planet_up(position : Vector3) -> Vector3:
	return (position - get_planet_center()).normalized() if spherical_planet else Vector3.UP



func _encode_directional_lights(lights : Array[DirectionalLight3D], settings : Array[CloudDirectionalLightSettings]) -> void:
	var directional_radiance := _solar_irradiance() * radiance_scale * directional_energy_multiplier
	var horizon := sin(deg_to_rad(cloud_shadow_horizon_fade))
	light_id_count = 0
	wanted_caster_id = 0
	wanted_caster_direction = Vector3.ZERO
	var any_exist := false
	var directions := PackedVector3Array()
	var radiances := PackedVector3Array()
	var samples := PackedInt32Array()
	var caster_strength := 0.0
	for i in lights.size():
		if !is_instance_valid(lights[i]):
			continue
		# Hidden or unlit lights still count as given, just dark.
		any_exist = true
		if light_id_count == MAX_DIRECTIONAL_LIGHTS:
			continue
		var light := lights[i]
		var energy := light.light_energy * light.light_volumetric_fog_energy
		if !light_shown(light) || energy <= 0.0:
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
	atmosphere_light_directions = directions
	atmosphere_light_weights = radiances
	lights_bytes.encode_s32(0, light_id_count)


## is_visible_in_tree(), or would be but for a driver hiding it below the horizon (BELOW_HORIZON_META);
## such a light still lights the clouds and atmosphere (twilight).
static func light_shown(light : DirectionalLight3D) -> bool:
	if light.is_visible_in_tree():
		return true
	if !light.has_meta(BELOW_HORIZON_META):
		return false
	var parent := light.get_parent() as Node3D
	return parent == null || parent.is_visible_in_tree()


func _encode_fallback_lights() -> void:
	using_fallback = true
	fallback_key = _fallback_key()
	light_id_count = 0
	wanted_caster_id = 0
	wanted_caster_direction = Vector3.ZERO
	var directional_radiance := _solar_irradiance() * radiance_scale * directional_energy_multiplier
	var count := 0
	atmosphere_light_directions = PackedVector3Array()
	atmosphere_light_weights = PackedVector3Array()
	if has_last_directional:
		count = mini(mini(last_directional_directions.size(), last_directional_radiance.size()), mini(last_directional_samples.size(), MAX_DIRECTIONAL_LIGHTS))
		for n in count:
			_encode_vec4(lights_bytes, 16 + n * 32, last_directional_directions[n], _first_light_step(last_directional_samples[n]))
			_encode_vec4(lights_bytes, 32 + n * 32, directional_radiance * last_directional_radiance[n], last_directional_samples[n])
			atmosphere_light_directions.append(last_directional_directions[n])
			atmosphere_light_weights.append(last_directional_radiance[n])
	else:
		var elevation := deg_to_rad(fallback_light_elevation)
		var azimuth := deg_to_rad(fallback_light_azimuth)
		var direction := Vector3(cos(elevation) * sin(azimuth), sin(elevation), cos(elevation) * cos(azimuth))
		var color := fallback_light_color
		var shadow_samples := default_directional_settings.shadow_samples
		_encode_vec4(lights_bytes, 16, direction, _first_light_step(shadow_samples))
		var weight := Vector3(color.r, color.g, color.b) * fallback_light_energy
		_encode_vec4(lights_bytes, 32, directional_radiance * weight, shadow_samples)
		count = 1
		atmosphere_light_directions.append(direction)
		atmosphere_light_weights.append(weight)
	lights_bytes.encode_s32(0, count)


# What the fallback lights are encoded from (checked on the render thread while they're in use).
func _fallback_key() -> Array:
	return [radiance_scale, directional_energy_multiplier, light_step_growth, light_march_distance, cloud_scale, has_last_directional,
		last_directional_directions, last_directional_radiance, last_directional_samples,
		fallback_light_elevation, fallback_light_azimuth, fallback_light_color, fallback_light_energy]


func _encode_atmosphere_lights(directions : PackedVector3Array, weights : PackedVector3Array, up : Vector3) -> Vector3:
	var count := 0
	var first := up
	for i in mini(mini(directions.size(), weights.size()), MAX_DIRECTIONAL_LIGHTS):
		var weight := weights[i]
		if maxf(weight.x, maxf(weight.y, weight.z)) <= 0.0 || directions[i].dot(up) < ATMOSPHERE_LIGHT_MIN_MU:
			continue
		if count == 0:
			first = directions[i]
		var cover := clampf(Color(weight.x, weight.y, weight.z).get_luminance(), 0.0, 1.0)
		_encode_vec4(params_bytes, 384 + count * 32, directions[i], cover)
		_encode_vec4(params_bytes, 400 + count * 32, weight, 0.0)
		count += 1
	params_bytes.encode_s32(380, count)
	return first


## Forgets the last directional lights a driver gave; the fallback light is used until a driver gives more.
func forget_last_lights() -> void:
	lights_mutex.lock()
	has_last_directional = false
	last_directional_directions = PackedVector3Array()
	last_directional_radiance = PackedVector3Array()
	last_directional_samples = PackedInt32Array()
	lights_mutex.unlock()


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


func _omni_shape(light : OmniLight3D, settings : Array[CloudOmniLightSettings], index : int) -> Vector3:
	var sunshine_light := light as SunshineOmniLight
	if sunshine_light != null:
		return Vector3(sunshine_light.cloud_radius, sunshine_light.energy_multiplier, sunshine_light.shadow_samples)
	var light_settings := settings[index] if index < settings.size() && settings[index] else default_omni_settings
	return Vector3(light.omni_range, light_settings.energy_multiplier, light_settings.shadow_samples)


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


func _effector_shape(effector : Node3D, settings : Array[CloudEffectorSettings], index : int) -> Vector3:
	var scale := effector.global_transform.basis.get_scale().abs()
	var largest := maxf(scale.x, maxf(scale.y, scale.z))
	var sunshine_effector := effector as SunshineEffector
	if sunshine_effector != null:
		return Vector3(sunshine_effector.radius * largest, sunshine_effector.strength, sunshine_effector.falloff)
	var effector_settings := settings[index] if index < settings.size() && settings[index] else default_effector_settings
	return Vector3(effector_settings.radius * largest, effector_settings.strength, effector_settings.falloff)


# Resets point_scores for size nodes to INF (unscored); a score is distance to the camera less radius.
func _size_point_scores(size : int) -> void:
	if point_scores.size() < size:
		point_scores.resize(size)
	point_scores.fill(INF)


# Takes the next scored node out of point_scores: the first in list order when all fit, else the nearest.
func _next_point(size : int, nearest : bool) -> int:
	var next := -1
	for i in size:
		if point_scores[i] < INF && (next < 0 || point_scores[i] < point_scores[next]):
			next = i
			if !nearest:
				break
	point_scores[next] = INF
	return next


## First of steps light march steps growing by light_step_growth to span light_march_distance (times
## cloud_scale): first * (growth^n - 1) / (growth - 1) = distance.
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
			1.2082, 1.18737, 1.14683, 1.12362, 1.1058, 1.07124, 1.04992][int(ATMOSPHERE_LAMBDAS[i] - 360.0) / 10] # W.m^-2.nm^-1 from Bruneton's demo.cc, 10 nm bins from 360 to 830 nm. Measured data, don't tune.
	return solar


## Colour of a light towards direction at position after the atmosphere (GetTransmittanceToSun at
## ATMOSPHERE_LAMBDAS, on the CPU), white balanced against overhead; 0 once its disc has set.
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
	# Heightmap: while on, every cloud-sampling pass runs its _heightmap version with the texture and
	# Heightmap buffer bound. Off, none of it is touched.
	var heightmap_rid := RID()
	if _heightmap_on() && _ensure_heightmap_resources():
		heightmap_rid = RenderingServer.texture_get_rd_texture(heightmap.get_rid())
	var lifted := heightmap_rid.is_valid()
	# Layer changes that skipped the setter (e.g. layers.append()) sync on the main thread (owns the profile).
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
	# With 3D MSAA the scene stays multisampled until the end of the transparent pass, when Godot resolves
	# the colour over anything written to the resolved texture (and averages depth). So the raymarch and
	# resolve run msaa versions reading multisampled depth, and the resolve stores its colour changes per
	# surface (msaa_near, msaa_far) for SunshineClouds3MsaaComposite.glsl to blend in per sample.
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

	# Visual profiler: ">" opens a folder, "<" closes it; each timestamp lasts until the next.
	rd.capture_timestamp(">Sunshine Clouds")
	if atmosphere_changed:
		atmosphere_changed = false
		atmosphere_precompute_pending = true
		# Bruneton's AtmosphereParameters for ATMOSPHERE_LAMBDAS in km, as model.cc builds them from
		# demo.cc's spectra. Lengths are times cloud_scale and extinctions over it, so scaling looks the same.
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

	# Layers, once a frame (wind delta is since the last frame). Sizes are times cloud_scale and extinction
	# over it; noise offsets are already world positions (the driver scales the wind).
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
		if lifted:
			var bytes := PackedByteArray()
			bytes.resize(HEIGHTMAP_BYTES)
			_encode_heightmap(bytes)
			if bytes != heightmap_bytes:
				heightmap_bytes = bytes
				rd.buffer_update(heightmap_buffer, 0, HEIGHTMAP_BYTES, heightmap_bytes)
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

	# A tiny shadow map while shadows are off (the resolve still binds it); keys only if not rendered every frame.
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
	if first_viewport:
		lights_mutex.lock()
		if lights_driven && Time.get_ticks_msec() - lights_set_msec > 500:
			# No driver: fallback directional lights, no omni lights or effectors; fully re-encoded once calls resume.
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
		frame_light_directions = atmosphere_light_directions
		frame_light_weights = atmosphere_light_weights
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
	# The same for every view: they share the camera's position.
	var sun_direction := _encode_atmosphere_lights(frame_light_directions, frame_light_weights, get_planet_up(cam_transform.origin))
	for view in view_count:
		var projection := scene_data.get_view_projection(view)
		var view_projection := projection * world_to_camera
		var history_valid := view < state.prev_view_projections.size()

		_encode_mat4(params_bytes, 0, projection.inverse())
		_encode_mat4(params_bytes, 64, Projection(cam_transform))
		_encode_mat4(params_bytes, 128, state.prev_view_projections[view] if history_valid else view_projection)
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
		# Three floats: 380 is atmosphere_light_count (_encode_atmosphere_lights()).
		params_bytes.encode_float(368, ground_color.r)
		params_bytes.encode_float(372, ground_color.g)
		params_bytes.encode_float(376, ground_color.b)
		rd.buffer_update(params_buffer, 0, PARAMS_BYTES, params_bytes)

		var color_layer := buffers.get_color_layer(view, msaa)
		var depth_layer := buffers.get_depth_layer(view, msaa)
		var msaa_near := buffers.get_texture_slice(BUFFERS_CONTEXT, &"msaa_near", view, 0, 1, 1) if msaa else RID()
		var msaa_far := buffers.get_texture_slice(BUFFERS_CONTEXT, &"msaa_far", view, 0, 1, 1) if msaa else RID()
		if view == 0: #TODO: Add timing offsets to render this only every Nth frame, for performance.
			# The shadow map passes and point samples bind the same textures, so their sets are rebuilt together.
			# None reads depth, so binding 1 gets one of our textures; undeclared bindings are ignored.
			var density_inputs_changed := _set_input(density_set_inputs, 0, noise_rid)
			density_inputs_changed = _set_input(density_set_inputs, 1, profile_rid) || density_inputs_changed
			density_inputs_changed = _set_input(density_set_inputs, 2, coverage_rid) || density_inputs_changed
			density_inputs_changed = _set_input(density_set_inputs, 3, curl_rid) || density_inputs_changed
			density_inputs_changed = _set_input(density_set_inputs, 4, shadow_texture) || density_inputs_changed
			density_inputs_changed = _set_input(density_set_inputs, 5, shadow_keys[0]) || density_inputs_changed
			density_inputs_changed = _set_input(density_set_inputs, 6, shadow_keys[1]) || density_inputs_changed
			density_inputs_changed = _set_input(density_set_inputs, 7, heightmap_rid) || density_inputs_changed
			var density_shader := heightmap_shaders[2] if lifted else shadow_shader
			var points_shader := heightmap_shaders[4] if lifted else sample_shader
			if density_inputs_changed || !rd.uniform_set_is_valid(shadow_sets[0]) \
					|| (shadow_keys[0].is_valid() && !rd.uniform_set_is_valid(shadow_blend_set)) \
					|| (points_shader.is_valid() && !rd.uniform_set_is_valid(sample_set)):
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
				if lifted:
					density_uniforms.append_array(_heightmap_uniforms(heightmap_rid))
				for i in 3:
					var target := shadow_texture if i == 0 else shadow_keys[i - 1]
					shadow_sets[i] = UniformSetCacheRD.get_cache(density_shader, 0, density_uniforms + [
						_uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 21, [target]),
					]) if target.is_valid() else RID()
				if shadow_keys[0].is_valid():
					shadow_blend_set = UniformSetCacheRD.get_cache(shadow_blend_shader, 0, density_uniforms + [
						_uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 21, [shadow_texture]),
						_uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 24, [shadow_keys[0]]),
						_uniform(RenderingDevice.UNIFORM_TYPE_IMAGE, 25, [shadow_keys[1]]),
					])
				if points_shader.is_valid():
					sample_set = UniformSetCacheRD.get_cache(points_shader, 0, density_uniforms + [
						_uniform(RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER, 22, [point_sample_data_buffer]),
					])

			# The shadow map and Shadow buffer (read by screen-space shadows): once a frame, and again straight
			# into shadow_texture for a viewport whose camera is far from the map's centre.
			var shadow_extent := maxf(cloud_shadow_extent * cloud_scale, 1.0)
			var far_camera := !first_viewport && cam_transform.origin.distance_to(shadow_camera) > shadow_extent * 0.01
			if first_viewport || far_camera:
				shadow_camera = cam_transform.origin
				var keyed := shadow_keys[0].is_valid() && !far_camera
				if keyed:
					shadow_age += 1
				# New caster: with keys, the current shadows fade out to a lit key over the interval, then the
				# new ones fade in (maps in different light spaces can't blend); without keys, switch at once.
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

				# The projector must be on the caster; the driver moves it a frame after a switch.
				var projector_mode := cloud_shadow_mode == SHADOW_MODE_PROJECTOR && shadow_projector.is_valid() && shadow_blit_material.is_valid()
				var projector := projector_mode && shadow_projector_light_id == shadow_caster_id
				if !projector_mode || projector:
					var light_to_world := shadow_light_transform
					if !projector && shadow_caster_direction != Vector3.ZERO:
						light_to_world = Transform3D(Basis.looking_at(-shadow_caster_direction,
							Vector3.FORWARD if absf(shadow_caster_direction.y) > 0.99 else Vector3.UP), Vector3.ZERO)
					var world_to_light := light_to_world.affine_inverse()
					if projector && first_viewport && shadow_projector_size.x > 0:
						# Next window centre: camera in light space, snapped to whole texels (no swimming).
						var texel := shadow_extent / shadow_projector_size.x
						var camera_light := world_to_light * cam_transform.origin
						_shadow_projector_center_mutex.lock()
						_shadow_projector_center_request = (Vector2(camera_light.x, camera_light.y) / texel).round() * texel
						_shadow_projector_center_mutex.unlock()
					var to_sun := light_to_world.basis.z.normalized()
					var sun_height := to_sun.dot(get_planet_up(cam_transform.origin))
					# The horizon fade scales strength. Faded out, screen space skips the map; the projector
					# still gets it (all lit) so the light doesn't keep stale shadows.
					var fade := 1.0 if sun_height > 0.0 else 0.0
					if cloud_shadow_horizon_fade > 0.0:
						fade = smoothstep(0.0, sin(deg_to_rad(cloud_shadow_horizon_fade)), sun_height)
					var shadows_active := cloud_shadows && layer_count > 0 && shadow_caster_direction != Vector3.ZERO && (fade > 0.0 || projector)

					# With keys, render into them in turn every interval frames, and at once after a camera or sun jump.
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
							if lifted:
								march_ceiling = maxf(march_ceiling, _lifted_ceiling(layer.cloud_floor * cloud_scale, layer.cloud_ceiling * cloud_scale))
							else:
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
						shadow_bytes.encode_float(164, minf(thickness / sun_height, thickness * 8.0) if shadows_active && sun_height > 0.001 else 0.0) # Caps the march at 8x layer thickness: a low sun would otherwise march hundreds of km. 4-16: lower is cheaper but clips low-sun shadows.
						shadow_bytes.encode_s32(168, 1 if shadows_active && !projector else 0)
						shadow_bytes.encode_float(172, screen_space_shadow_strength)
						shadow_bytes.encode_float(176, cloud_shadow_edge_fade * extent * 0.5)
						rd.buffer_update(shadow_buffer, 0, SHADOW_BYTES, shadow_bytes)
					var groups := ceili(shadow_texture_resolution / 8.0)
					if render:
						var list := rd.compute_list_begin()
						rd.compute_list_bind_compute_pipeline(list, _pipeline(shadow_pipelines, layer_count + (MAX_LAYERS + 1) * int(lifted), density_shader, layer_count))
						rd.compute_list_bind_uniform_set(list, shadow_sets[1 + shadow_key if keyed else 0], 0)
						rd.compute_list_dispatch(list, groups, groups, 1)
						rd.compute_list_end()
					if keyed && shadows_active:
						# Latest key's weight ramps from 1 / interval to 1 when the next is due (1 with one key).
						var latest_weight := minf(float(shadow_age + 1) / cloud_shadow_update_interval, 1.0) if shadow_keys_ready == 2 else 1.0
						push_bytes.encode_float(0, latest_weight if shadow_key == 1 else 1.0 - latest_weight)
						var list := rd.compute_list_begin()
						rd.compute_list_bind_compute_pipeline(list, shadow_blend_pipeline)
						rd.compute_list_bind_uniform_set(list, shadow_blend_set, 0)
						rd.compute_list_set_push_constant(list, push_bytes, push_bytes.size())
						rd.compute_list_dispatch(list, groups, groups, 1)
						rd.compute_list_end()
					if shadows_active && projector:
						# Only a blit into the DrawableTexture2D makes Godot re-copy it into the decal atlas
						# (where projectors sample); compute writes never do. Called by name: older engines lack it.
						if shadow_source == null:
							shadow_source = Texture2DRD.new()
						if shadow_source.texture_rd_rid != shadow_texture:
							shadow_source.texture_rd_rid = shadow_texture
						# The map repeats every extent; the blit takes the window around shadow_projector_center
						# (r, g: shift in texels / resolution, b: edge fade start, a: 1 = windowed).
						var blit_params := Color(0.0, 0.0, 1.0, 0.0)
						if shadow_projector_windowed:
							var resolution := shadow_projector_size.x
							var shift := Vector2i((shadow_projector_center * resolution / shadow_extent).round())
							blit_params = Color(float(posmod(shift.x, resolution)) / resolution, float(posmod(-shift.y, resolution)) / resolution,
								cloud_shadow_edge_fade, 1.0)
						RenderingServer.call(&"texture_drawable_blit_rect", [shadow_projector], Rect2i(Vector2i.ZERO, shadow_projector_size),
							shadow_blit_material, blit_params, [shadow_source.get_rid()], 0)

			if first_viewport:
				var skybox_origin := Vector3(cam_transform.origin.x, skybox_height, cam_transform.origin.z) if skybox_fixed_height else cam_transform.origin
				_update_skybox(skybox_origin, sun_direction, background_rid, [noise_rid, profile_rid, coverage_rid, curl_rid], layer_count, heightmap_rid)
				rd.capture_timestamp("Render Sunshine Clouds Views")

			# Up to MAX_SAMPLE_POINTS queued points (w = 0, the shader writes the density there).
			if !positionQuerying && !positionResetting && !positionQueries.is_empty() && points_shader.is_valid():
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
				rd.compute_list_bind_compute_pipeline(list, _pipeline(sample_pipelines, layer_count + (MAX_LAYERS + 1) * int(lifted), points_shader, layer_count))
				rd.compute_list_bind_uniform_set(list, sample_set, 0)
				rd.compute_list_set_push_constant(list, push_bytes, push_bytes.size())
				rd.compute_list_dispatch(list, 1, 1, 1)
				rd.compute_list_end()

		# Rebuild the view's uniform sets only when a binding changed or the device dropped them (resource freed).
		var base := view * SET_INPUT_COUNT
		var inputs_changed := _set_input(state.set_inputs, base, color_layer)
		inputs_changed = _set_input(state.set_inputs, base + 1, depth_layer) || inputs_changed
		inputs_changed = _set_input(state.set_inputs, base + 2, noise_rid) || inputs_changed
		inputs_changed = _set_input(state.set_inputs, base + 3, profile_rid) || inputs_changed
		inputs_changed = _set_input(state.set_inputs, base + 4, coverage_rid) || inputs_changed
		inputs_changed = _set_input(state.set_inputs, base + 5, curl_rid) || inputs_changed
		inputs_changed = _set_input(state.set_inputs, base + 6, shadow_texture) || inputs_changed
		inputs_changed = _set_input(state.set_inputs, base + 7, background_rid) || inputs_changed
		inputs_changed = _set_input(state.set_inputs, base + 8, heightmap_rid) || inputs_changed
		for i in VIEW_TEXTURES:
			view_textures[i] = buffers.get_texture_slice(BUFFERS_CONTEXT, VIEW_TEXTURE_NAMES[i], view, 0, 1, 1)
			inputs_changed = _set_input(state.set_inputs, base + 9 + i, view_textures[i]) || inputs_changed
		var raymarch_shader := (heightmap_shaders[int(msaa)] if lifted else (raymarch_msaa_shader if msaa else shader))
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
			# The resolve writes this parity's histories and reads the other's, as does the raymarch for
			# interlace-reprojected texels.
			for set_parity in 2:
				var history := view_textures[1 - set_parity]
				var history_b := view_textures[5 - set_parity]
				var raymarch_uniforms : Array[RDUniform] = [
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
				]
				if lifted:
					raymarch_uniforms.append_array(_heightmap_uniforms(heightmap_rid))
				state.raymarch_sets[view * 2 + set_parity] = UniformSetCacheRD.get_cache(raymarch_shader, 0, raymarch_uniforms)
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
		var raymarch_base := (MAX_LAYERS + 1) * 3 * (int(msaa) + 2 * int(lifted)) + layer_count * 3
		if interlace > 1 && history_valid:
			# Traced texels, then the reprojected rest (INTERLACE_PASS 1 and 2), each 4x4 tile as a thread block.
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
		rd.compute_list_bind_compute_pipeline(list, _pipeline(resolve_pipelines, int(atmosphere_enabled) + 2 * int(msaa) + 4 * int(atmosphere_glow_shadows),
			resolve_msaa_shader if msaa else resolve_shader, atmosphere_enabled, atmosphere_glow_shadows))
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


## Blends the resolve's per-surface changes (msaa_near, msaa_far: colour * a + b) into color_msaa
## via SunshineClouds3MsaaComposite.glsl per sample, using the sample's surface (msaa_near's w).
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
		# The shader reads gl_SampleID to force per-sample shading (D3D12 rejects enable_sample_shading).
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


## Skybox panorama, keyed like the shadow map: rendered every skybox_update_interval frames into two
## keys in turn and blended into skybox_texture (directly at interval 1), and at once when the sun,
## camera height or settings jump. Idle while sun, camera height, clouds and lights stay put.
## Only rendered while a driver calls request_skybox(); textures are kept when it stops (a paused
## game), as its environment may still show them.
func _update_skybox(camera_position : Vector3, sun_direction : Vector3, background_rid : RID, density_rids : Array[RID], layer_count : int,
		heightmap_rid : RID) -> void:
	var lifted := heightmap_rid.is_valid()
	var sky_shader := heightmap_shaders[3] if lifted else skybox_shader
	var enabled := skybox_enabled && atmosphere_enabled && skybox_requested_msec >= 0
	# Once requested, the textures persist while off: a driver's Sky samples them until it lets go (a frame
	# later, or when a paused game resumes), and freeing one breaks its material. Replaced ones are retired.
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
	if Time.get_ticks_msec() - skybox_requested_msec >= 500: # How long a request_skybox() keeps it updating (ms). 250-1000: enough to cover a few update intervals.
		return

	var inputs_changed := _set_input(skybox_set_inputs, 0, skybox_texture)
	inputs_changed = _set_input(skybox_set_inputs, 1, skybox_keys[0]) || inputs_changed
	inputs_changed = _set_input(skybox_set_inputs, 2, background_rid) || inputs_changed
	for i in density_rids.size():
		inputs_changed = _set_input(skybox_set_inputs, 3 + i, density_rids[i]) || inputs_changed
	inputs_changed = _set_input(skybox_set_inputs, 7, heightmap_rid) || inputs_changed
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
		if lifted:
			uniforms.append_array(_heightmap_uniforms(heightmap_rid))
		for i in 3:
			var target := skybox_texture if i == 0 else skybox_keys[i - 1]
			skybox_sets[i] = UniformSetCacheRD.get_cache(sky_shader, 0, uniforms + [
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
		|| sun_direction.dot(skybox_key_sun) < 0.9998 || camera_up.dot(skybox_key_up) < 0.9998 # 200.0: height change (m, times cloud_scale) that re-renders at once. 100-500: lower snaps sooner on big climbs.
	# Unchanged since the last render: leave it, so the editor (which redraws only on changes) can idle.
	var clouds_state := layers_bytes.slice(0, layer_count * LAYER_BYTES) if skybox_clouds else PackedByteArray()
	if lifted && skybox_clouds:
		# The heightmap's settings, texture and changes too.
		clouds_state.append_array(heightmap_bytes)
		clouds_state.append_array(var_to_bytes([heightmap_rid.get_id(), heightmap_version]))
	var changed := absf(camera_height - skybox_key_camera_height) > 1.0 * cloud_scale || !sun_direction.is_equal_approx(skybox_key_sun) \
		|| !camera_up.is_equal_approx(skybox_key_up) \
		|| clouds_state != skybox_key_clouds || lights_version != skybox_key_lights # 1.0: height change (m, times cloud_scale) below which an unchanged skybox idles. 0.5-5: lower re-renders on tiny bobs, higher lets the horizon drift.
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
		if skybox_fixed_height:
			# For this dispatch only: Params with the camera at camera_position (height and planet-centre offset).
			var moved_params := params_bytes.duplicate()
			moved_params.encode_float(64 + 52, camera_position.y)
			_encode_vec4(moved_params, 208, camera_position - get_planet_center(), 1.0 if spherical_planet else 0.0)
			rd.buffer_update(params_buffer, 0, PARAMS_BYTES, moved_params)
		var list := rd.compute_list_begin()
		rd.compute_list_bind_compute_pipeline(list, _pipeline(skybox_pipelines, layer_count + (MAX_LAYERS + 1) * int(lifted), sky_shader, layer_count))
		rd.compute_list_bind_uniform_set(list, skybox_sets[1 + skybox_key if use_keys else 0], 0)
		rd.compute_list_dispatch(list, groups.x, groups.y, 1)
		rd.compute_list_end()
		if skybox_fixed_height:
			rd.buffer_update(params_buffer, 0, PARAMS_BYTES, params_bytes)
	if use_keys && !skybox_blended:
		# Weighted as the shadow map's keys; done once the latest key's weight reaches 1.
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


## Calls the batch's callables with (position, density) in order, as SunshineClouds2's retrieve_position_queries().
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
