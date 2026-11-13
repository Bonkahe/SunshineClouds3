#[versions]

resolve = "";
msaa = "#define MSAA";

#[compute]
#version 450

VERSION_DEFINES

// The msaa version, with 3D MSAA (SunshineClouds3.gd): depth_texture is the multisampled depth
// (Common), and the clouds go into msaa_near_image (and msaa_far_image) as colour * a + b instead
// of onto color_image, for SunshineClouds3MsaaComposite.glsl to apply to the multisampled colour.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

// Off (SunshineClouds3.gd's atmosphere_enabled), the scene's own sky stays, nothing is fogged and
// the clouds' sky light is a fixed plain sky radiance.
layout(constant_id = 0) const bool ATMOSPHERE_ENABLED = true;
// SunshineClouds3.gd's atmosphere_glow_shadows: the air in the opaque scene's shadow (in front of a
// hill hiding the sun) gives none of the glow around the light (glow_shadow_masks()).
layout(constant_id = 1) const bool GLOW_SHADOWS = true;

#define CLOUD_SHADOWS
#include "SunshineClouds3Common.glslinc"

#include "atmosphere/AtmosphereHeader.glslinc"
#include "atmosphere/AtmosphereDefinitions.glslinc"
#define ATMOSPHERE_BINDING 9
#include "atmosphere/AtmosphereParameters.glslinc"
#include "atmosphere/AtmosphereFunctions.glslinc"

#ifdef MSAA
// composite() as a and b (colour * a + b), as halves: x = a.rg, y = (a.b, b.r), z = b.gb; the near
// image's w is the far samples' bits (msaa_far_samples(), Common). The far image only where the
// pixel has samples on a far surface.
layout(rgba32ui, set = 0, binding = 31) uniform restrict writeonly uimage2D msaa_near_image;
layout(rgba32ui, set = 0, binding = 32) uniform restrict writeonly uimage2D msaa_far_image;
#else
layout(rgba16f, set = 0, binding = 0) uniform restrict image2D color_image;
#endif
// The raymarch's values (SunshineClouds3Raymarch.glsl's current_image and current_b_image) and
// their accumulation, last frame's and this frame's. The second accumulation texture also holds
// the scene distance: r = scene distance (km), g = sky ambient intensity, b = weighted cloud
// distance, a = ground ambient intensity.
layout(set = 0, binding = 6) uniform sampler2D history_texture;
layout(set = 0, binding = 17) uniform sampler2D history_b_texture;
layout(rgba16f, set = 0, binding = 7) uniform restrict writeonly image2D accumulation_image;
layout(rgba16f, set = 0, binding = 18) uniform restrict writeonly image2D accumulation_b_image;
layout(set = 0, binding = 8) uniform sampler2D current_texture;
layout(set = 0, binding = 28) uniform sampler2D current_b_texture;
layout(set = 0, binding = 10) uniform sampler2D transmittance_texture;
layout(set = 0, binding = 11) uniform sampler3D scattering_texture;
layout(set = 0, binding = 12) uniform sampler2D irradiance_texture;
layout(set = 0, binding = 20) uniform sampler2D shadow_map;
#include "SunshineClouds3Sky.glslinc"

// atmosphere_aerial_perspective(), none without the atmosphere.
vec3 aerial_perspective(vec3 ray_origin, vec3 ray_direction, float distance, float glow_scale, uvec4 glow_shadow, float glow_extent,
		out vec3 transmittance) {
	if (!ATMOSPHERE_ENABLED) {
		transmittance = vec3(1.0);
		return vec3(0.0);
	}
	return atmosphere_aerial_perspective(ray_origin, ray_direction, distance, glow_scale, glow_shadow, glow_extent, transmittance);
}

const int GLOW_SHADOW_SAMPLES = 10; // Depth samples per light along its line on screen (glow_shadow_masks()). 6-16: fewer leaves some glow in the shadow away from the light, more costs.
const float GLOW_SHADOW_THICKNESS = 2.0; // How far behind a surface on screen the scene is taken to go on, times its distance. 1.5-4: lower lets glow through hills, higher has thin near things (trees, poles) shade long stretches of haze.

// Which air along the pixel's view ray to the opaque scene (surface m away, 0 for none) is in the
// scene's shadow, for each atmosphere light: bit b of its mask for the air from b / 32 to
// (b + 1) / 32 of the way (glow_lit_fraction(), Sky). Its glow is strongly forward, so in front of
// a hill hiding the sun the air is in the hill's shadow and gives none: no halo over the hill.
//
// Every light ray from the view ray lies in the plane of the view and the light, which is a line
// on screen, from the pixel to the light. A light ray from the view ray's point at t passes a
// direction beta from the light (and angle from the view) at t * sin(angle) / sin(beta): where the
// scene there is nearer (and within GLOW_SHADOW_THICKNESS of it), it's behind the scene, in its
// shadow. So each depth sample on that line shades a stretch of the view ray. The samples get
// denser towards the light (beta geometrically from the view to half a pixel from the light),
// where the stretch they shade is nearer the camera; the last stands for the rest of the way, so
// a light hidden behind the scene shades the air from the camera on (the air near the camera has
// the camera's view of it). Off screen counts as lit, so does the sky. A pixel the light is behind
// is all in shadow. The shadow fades out between 60 and 90 degrees from the light, where its glow
// is faint.
uvec4 glow_shadow_masks(ivec2 pixel, float surface) {
	uvec4 masks = uvec4(0u);
	if (!GLOW_SHADOWS || !ATMOSPHERE_ENABLED || surface <= 0.0) {
		return masks;
	}
	mat4 projection = inverse(params.inv_projection);
	if (abs(projection[3][3]) > 0.5) {
		return masks; // Orthographic: no line to the light.
	}
	vec2 uv = (vec2(pixel) + 0.5) / vec2(params.screen_size);
	vec4 far_view = params.inv_projection * vec4(uv * 2.0 - 1.0, 0.0, 1.0);
	vec3 view = normalize(far_view.xyz / far_view.w);
	mat3 world_to_view = transpose(mat3(params.camera_to_world));
	float min_angle = abs(params.inv_projection[1][1]) / float(params.screen_size.y); // Half a pixel (the projection may flip Y).
	for (int i = 0; i < params.atmosphere_light_count; i++) {
		vec3 light = normalize(world_to_view * atmosphere_light_direction(i));
		float cos_angle = dot(view, light);
		float strength = smoothstep(0.0, 0.5, cos_angle);
		float angle = acos(min(cos_angle, 1.0));
		if (strength <= 0.0) {
			continue;
		}
		if (angle <= min_angle) {
			masks[i] = ~0u;
			continue;
		}
		float sin_angle = sin(angle);
		// Fading out, the stretches shaded move out past the surface.
		float scale = 32.0 / (sin_angle * surface * strength);
		float step_ratio = pow(min_angle / angle, 1.0 / float(GLOW_SHADOW_SAMPLES));
		float beta = angle * sqrt(step_ratio);
		uint mask = 0u;
		for (int j = 0; j < GLOW_SHADOW_SAMPLES; j++, beta *= step_ratio) {
			vec3 direction = (sin(beta) * view + sin(angle - beta) * light) / sin_angle;
			vec4 clip = projection * vec4(direction, 1.0);
			if (clip.w <= 0.0) {
				break;
			}
			vec2 sample_uv = clip.xy / clip.w * 0.5 + 0.5;
			// The rest of the line is off screen too.
			if (any(lessThan(sample_uv, vec2(0.0))) || any(greaterThanEqual(sample_uv, vec2(1.0)))) {
				break;
			}
			float depth = texelFetch(depth_texture, ivec2(sample_uv * vec2(params.screen_size)), 0).r;
			if (depth <= 0.0) {
				continue;
			}
			vec4 sample_view = params.inv_projection * vec4(sample_uv * 2.0 - 1.0, depth, 1.0);
			float first = length(sample_view.xyz / sample_view.w) * sin(beta) * scale;
			if (first >= 31.5) {
				continue;
			}
			int first_bin = j == GLOW_SHADOW_SAMPLES - 1 ? 0 : int(round(first));
			int end_bin = int(min(round(first * GLOW_SHADOW_THICKNESS), 32.0));
			if (end_bin > first_bin) {
				mask |= (end_bin - first_bin >= 32 ? ~0u : (1u << uint(end_bin - first_bin)) - 1u) << uint(first_bin);
			}
		}
		masks[i] = mask;
	}
	return masks;
}

// The raymarch texels a group's pixels gather from (those under the group and a one texel border,
// at most 10 x 10 at raymarch_resolution 1), read once per group instead of 9 times per pixel.
#define TILE_TEXELS 100
shared vec4 tile_value[TILE_TEXELS];
shared vec3 tile_value_b[TILE_TEXELS]; // current_b_texture's
shared vec2 tile_pixel[TILE_TEXELS]; // the pixel the texel traced
shared float tile_distance[TILE_TEXELS]; // scene distance at that pixel

// The pixel's clouds for an opaque scene at max_distance (m): result = absorption and direct light,
// result_b = sky ambient, weighted distance and ground ambient. This frame's values come from the
// 3x3 raymarch texels around the pixel, each weighted by a tent of one block on the distance to the
// pixel it traced. Only texels at a similar scene distance (or whose opaque cloud hides both, or
// whose absorption matches the pixel's own: see same_cloud_own) count, so nothing bleeds across
// silhouettes; they also give the range the history is clamped to. Interlaced, the traced texels
// (the new ones) are also summed apart.
void reconstruct(ivec2 pixel, ivec2 tile_origin, int tile_width, vec3 ray_origin, vec3 ray_direction, float max_distance,
		out vec4 result, out vec3 result_b) {
	ivec2 size = ivec2(params.screen_size);
	int divisor = params.raymarch_resolution;
	ivec2 texel = pixel / divisor;
	vec4 weighted_sum = vec4(0.0);
	vec3 weighted_sum_b = vec3(0.0);
	float weight_sum = 0.0;
	vec4 traced_sum = vec4(0.0);
	vec3 traced_sum_b = vec3(0.0);
	float traced_weight = 0.0;
	int traced_count = 0;
	vec4 traced_min = vec4(1e30);
	vec4 traced_max = vec4(-1e30);
	vec3 traced_min_b = vec3(1e30);
	vec3 traced_max_b = vec3(-1e30);
	vec4 neighbourhood_min = vec4(1e30);
	vec4 neighbourhood_max = vec4(-1e30);
	vec3 neighbourhood_min_b = vec3(1e30);
	vec3 neighbourhood_max_b = vec3(-1e30);
	// Fallback when no texel is at a similar distance: the one closest in distance.
	vec4 closest = vec4(0.0);
	vec3 closest_b = vec3(0.0);
	float closest_ratio = -1.0;
	// The pixel's own light absorption, from its texels at its own distance (-1 when there are none):
	// what the texels at other distances are matched by.
	float own_absorption = 0.0;
	float own_count = 0.0;
	for (int y = -1; y <= 1; y++) {
		for (int x = -1; x <= 1; x++) {
			int i = (texel.y + y - tile_origin.y) * tile_width + texel.x + x - tile_origin.x;
			float neighbour_distance = tile_distance[i];
			if (min(neighbour_distance, max_distance) >= 0.5 * max(neighbour_distance, max_distance)) {
				own_absorption += tile_value[i].x >= 0.0 ? tile_value[i].x : -tile_value[i].x - 1.0;
				own_count += 1.0;
			}
		}
	}
	own_absorption = own_count > 0.0 ? own_absorption / own_count : -1.0;
	for (int y = -1; y <= 1; y++) {
		for (int x = -1; x <= 1; x++) {
			int i = (texel.y + y - tile_origin.y) * tile_width + texel.x + x - tile_origin.x;
			vec4 neighbour = tile_value[i];
			vec3 neighbour_b = tile_value_b[i];
			vec2 neighbour_pixel = tile_pixel[i];
			bool traced = neighbour.x >= 0.0;
			neighbour.x = traced ? neighbour.x : -neighbour.x - 1.0;
			float neighbour_distance = tile_distance[i];
			float ratio = min(neighbour_distance, max_distance) / max(neighbour_distance, max_distance);
			if (ratio > closest_ratio) {
				closest_ratio = ratio;
				closest = neighbour;
				closest_b = neighbour_b;
			}
			if (!same_cloud_own(neighbour_distance, max_distance, neighbour.x, cloud_distance(neighbour.x, neighbour_b.y), own_absorption)) {
				continue;
			}
			vec2 offset = abs(neighbour_pixel - vec2(pixel)) / float(divisor);
			float weight = max((1.0 - min(offset.x, 1.0)) * (1.0 - min(offset.y, 1.0)), 1e-4);
			weighted_sum += neighbour * weight;
			weighted_sum_b += neighbour_b * weight;
			weight_sum += weight;
			if (traced) {
				traced_sum += neighbour * weight;
				traced_sum_b += neighbour_b * weight;
				traced_weight += weight;
				traced_count++;
				traced_min = min(traced_min, neighbour);
				traced_max = max(traced_max, neighbour);
				traced_min_b = min(traced_min_b, neighbour_b);
				traced_max_b = max(traced_max_b, neighbour_b);
			}
			neighbourhood_min = min(neighbourhood_min, neighbour);
			neighbourhood_max = max(neighbourhood_max, neighbour);
			neighbourhood_min_b = min(neighbourhood_min_b, neighbour_b);
			neighbourhood_max_b = max(neighbourhood_max_b, neighbour_b);
		}
	}
	result = closest;
	result_b = closest_b;
	// How much of this frame's values go into the history.
	vec4 current = closest;
	vec3 current_b = closest_b;
	float current_weight = params.current_frame_weight;
	if (weight_sum > 0.0) {
		result = weighted_sum / weight_sum;
		result_b = weighted_sum_b / weight_sum;
		current = result;
		current_b = result_b;
		if (params.interlace > 1) {
			// Blend towards the traced texels only, at a weight that takes in new samples at the
			// same rate as with every texel traced every frame.
			if (traced_weight > 0.0) {
				current = traced_sum / traced_weight;
				current_b = traced_sum_b / traced_weight;
			}
			current_weight = min(params.current_frame_weight * float(params.interlace) * traced_weight / weight_sum, 1.0);
			// The reprojected texels hardly clamp the history, being the history itself. The traced
			// ones' range is used when the window holds at least its share of them (9 / interlace,
			// and 3); fewer make it too narrow (flicker).
			if (traced_count >= max((9 + params.interlace - 1) / params.interlace, 3)) {
				neighbourhood_min = traced_min;
				neighbourhood_max = traced_max;
				neighbourhood_min_b = traced_min_b;
				neighbourhood_max_b = traced_max_b;
			}
		}
	} else {
		neighbourhood_min = closest;
		neighbourhood_max = closest;
		neighbourhood_min_b = closest_b;
		neighbourhood_max_b = closest_b;
	}

	// History is dropped off screen and where opaque scene is now in front of the cloud it held;
	// the rest is clamped to the neighbourhood range so content that is gone can't linger.
	// It's reprojected at the cloud's (absorption weighted) distance, and where the camera moved
	// enough for that to differ, also at the scene's: thin air near the camera pulls a pixel's
	// distance in, while the far cloud or sky that shows through it moves with the scene (leaving
	// the edge of a cloud, its history came from inside the far cloud beside it: speckle). The
	// scene's is taken when it's nearer this frame's value by more than the pixel's opacity, so
	// opaque cloud, whose own texture moves with it, keeps the cloud's.
	if (params.history_valid) {
		float distance_to_cloud = cloud_distance(result.x, result_b.y);
		bool history_found = false;
		vec4 history;
		vec4 history_b;
		float history_error = 0.0;
		vec2 cloud_uv = vec2(-1.0);
		for (int candidate = 0; candidate < 2; candidate++) {
			float reprojection_distance = candidate == 0 ? distance_to_cloud : max_distance;
			vec3 cloud_world = ray_origin + ray_direction * reprojection_distance;
			vec4 prev_clip = params.prev_view_projection * vec4(cloud_world - reprojection_wind_delta(cloud_world, reprojection_distance), 1.0);
			vec2 prev_uv = prev_clip.xy / prev_clip.w * 0.5 + 0.5;
			if (candidate == 0) {
				cloud_uv = prev_uv;
			} else if (all(lessThan(abs(prev_uv - cloud_uv) * vec2(size), vec2(0.5)))) {
				break;
			}
			if (prev_clip.w <= 0.0 || any(lessThan(prev_uv, vec2(0.0))) || any(greaterThan(prev_uv, vec2(1.0)))) {
				continue;
			}
			bool found;
			vec4 found_b;
			vec4 found_value = sample_history(history_texture, history_b_texture, prev_uv, max_distance, found_b, found, result.x);
			if (!found || max_distance < cloud_distance(found_value.x, found_b.b) * 0.95) {
				continue;
			}
			// How far it is from this frame's value: absorption, and direct light relative to this frame's.
			float error = abs(found_value.x - result.x) + length(found_value.yzw - result.yzw) / (length(result.yzw) + 1e-3);
			if (!history_found || error < history_error * (1.0 - result.x)) {
				history_found = true;
				history = found_value;
				history_b = found_b;
				history_error = error;
			}
		}
		if (history_found) {
			result = mix(clamp(history, neighbourhood_min, neighbourhood_max), current, current_weight);
			result_b = mix(clamp(history_b.gba, neighbourhood_min_b, neighbourhood_max_b), current_b, current_weight);
		}
	}
}

// Screen space cloud shadows, when the light can't take them as a projector: opaque surfaces
// are darkened (ambient included) by the sunlight the clouds leave them, fading out towards the
// edge of the map, and in from the camera (screen_space_shadow_near_fade).
float surface_sunlight(vec3 ray_origin, vec3 ray_direction, float surface) {
	float sunlight = 1.0;
	if (shadow.screen_space != 0 && shadow.march_length > 0.0 && surface > 0.0 && surface < params.max_distance) {
		float fade = 1.0 - smoothstep(shadow.fade_start, shadow.extent * 0.5, surface);
		if (shadow.near_fade_end > 0.0) {
			fade *= smoothstep(0.0, shadow.near_fade_end, surface);
		}
		if (fade > 0.0) {
			// The optical depth still ahead, interpolated between the map's three levels (zero at
			// the end of the march).
			vec3 world = ray_origin + ray_direction * surface;
			vec2 wrapped = fract((shadow.world_to_light * vec4(world, 1.0)).xy / shadow.extent + 0.5);
			vec4 value = textureLod(shadow_map, vec2(wrapped.x, 1.0 - wrapped.y), 0.0);
			float along = clamp((planet_height(world) - shadow.march_floor)
					/ (shadow.march_length * dot(normalize(shadow.light_to_world[2].xyz), planet_up(world))), 0.0, 1.0) * 3.0;
			vec4 optical_depth = vec4(-log(max(value.gba, vec3(1e-6))), 0.0);
			float level = min(floor(along), 2.0);
			float depth = mix(optical_depth[int(level)], optical_depth[int(level) + 1], along - level);
			float cloud_sunlight = 1.0 - shadow.strength * pow(clamp(1.0 - exp(-depth), 0.0, 1.0), max(shadow.sharpness, 0.01));
			sunlight = mix(1.0, cloud_sunlight, shadow.screen_space_strength * fade);
		}
	}
	return sunlight;
}

// The scene's colour at a pixel (opaque scene at surface m, 0 for none) with its clouds (result,
// result_b) and the atmosphere over it; glow_shadow is glow_shadow_masks()'.
vec3 composite(vec3 color, vec3 ray_origin, vec3 ray_direction, float surface, float sunlight, vec4 result, vec3 result_b, uvec4 glow_shadow) {
	float light_absorption = result.x;
	AtmosphereParameters atmosphere = ATMOSPHERE;
	// How much of what's behind the clouds shows through them (the sky applies its own).
	float background_visibility = 1.0 - light_absorption;
	if (surface > 0.0) {
		vec3 transmittance;
		vec3 in_scatter = aerial_perspective(ray_origin, ray_direction, surface, 1.0, glow_shadow, 1.0, transmittance);
		color = color * sunlight * transmittance + in_scatter;
	} else if (ATMOSPHERE_ENABLED) {
		// The sky, and the background behind it (seen across about pixel_angle radians a pixel).
		vec3 transmittance;
		vec3 disc;
		float through;
		vec3 sky = sky_radiance(ray_origin, ray_direction, 1.0 - light_absorption, transmittance, disc, through);
		float pixel_angle = 2.0 * params.inv_projection[1][1] / float(params.screen_size.y);
		vec3 background = background_radiance(ray_direction, pixel_angle, transmittance, sky * params.radiance_scale, through);
		sky = (sky + disc) * params.radiance_scale + background;
		color = min(sky * (1.0 - light_absorption), vec3(MAX_RADIANCE));
		background_visibility = 1.0;
	}
	if (light_absorption > 0.0) {
		float distance_to_cloud = cloud_distance(result.x, result_b.y);
		// The direct light (the raymarch's, every light's) and the sky irradiance at the cloud as
		// an average radiance.
		vec3 sky_light = atmosphere.solar_irradiance * params.radiance_scale * vec3(0.04, 0.06, 0.1); // Plain sky radiance: without the atmosphere, the clouds' sky light as a fraction of the sun's irradiance, about a clear midday sky. Each channel 0.02-0.15, blue highest.
		if (ATMOSPHERE_ENABLED) {
			vec3 point = atmosphere_position(ray_origin + ray_direction * distance_to_cloud);
			sky_light = atmosphere_sky_irradiance(atmosphere, point) / PI * params.radiance_scale * sky_settings.atmosphere_tint;
		}
		// Tinted after the accumulation, so a change shows at once.
		vec3 cloud_color = (result.yzw + (result_b.x * params.ambient_color + result_b.z * params.ground_color) * sky_light * params.ambient_energy)
				* sky_settings.cloud_tint;
		// The air in front of the cloud is in its shadow looking towards the sun, so its glow is
		// blocked by the cloud's opacity too.
		vec3 transmittance;
		vec3 in_scatter = aerial_perspective(ray_origin, ray_direction, distance_to_cloud, 1.0 - light_absorption, glow_shadow,
				surface > 0.0 ? clamp(distance_to_cloud / surface, 1e-3, 1.0) : 1.0, transmittance);
		color = color * background_visibility + cloud_color * transmittance + in_scatter * light_absorption;
	}
	return color;
}

#ifdef MSAA
// composite() as colour * a + b, packed for SunshineClouds3MsaaComposite.glsl (w left to the caller).
// It's affine in the colour: b is what it makes of black, a what white adds to that.
uvec4 composite_affine(vec3 ray_origin, vec3 ray_direction, float surface, float sunlight, vec4 result, vec3 result_b) {
	uvec4 glow_shadow = glow_shadow_masks(ivec2(gl_GlobalInvocationID.xy), surface);
	vec3 b = composite(vec3(0.0), ray_origin, ray_direction, surface, sunlight, result, result_b, glow_shadow);
	vec3 a = max(composite(vec3(1.0), ray_origin, ray_direction, surface, sunlight, result, result_b, glow_shadow) - b, vec3(0.0));
	b = min(b, vec3(MAX_RADIANCE));
	return uvec4(packHalf2x16(a.rg), packHalf2x16(vec2(a.b, b.r)), packHalf2x16(b.gb), 0u);
}
#endif

void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = ivec2(params.screen_size);
	int divisor = params.raymarch_resolution;
	ivec2 texel_max = raymarch_size() - 1;
	ivec2 group_pixel = ivec2(gl_WorkGroupID.xy) * 8;
	ivec2 tile_origin = group_pixel / divisor - 1;
	int tile_width = (group_pixel.x + 7) / divisor + 2 - tile_origin.x;
	int tile_texels = tile_width * ((group_pixel.y + 7) / divisor + 2 - tile_origin.y);
	for (int i = int(gl_LocalInvocationIndex); i < tile_texels; i += 64) {
		// Edge texels clamp, repeating the border ones.
		ivec2 tile_texel = clamp(tile_origin + ivec2(i % tile_width, i / tile_width), ivec2(0), texel_max);
		ivec2 traced = traced_pixel(tile_texel);
		tile_value[i] = texelFetch(current_texture, tile_texel, 0);
		tile_value_b[i] = texelFetch(current_b_texture, tile_texel, 0).xyz;
		tile_pixel[i] = vec2(traced);
		tile_distance[i] = scene_distance(traced);
	}
	memoryBarrierShared();
	barrier();
	if (pixel.x >= size.x || pixel.y >= size.y) {
		return;
	}
	vec3 ray_origin;
	vec3 ray_direction;
	camera_ray(pixel, ray_origin, ray_direction);
#ifdef MSAA
	// The near surface is the one reconstructed and kept in the history; where the pixel also has
	// samples on a far one, that one's clouds are reconstructed too (below).
	float near_depth;
	float far_depth;
	uint far_samples = msaa_far_samples(pixel, near_depth, far_depth);
	float surface = surface_distance(pixel, near_depth);
#else
	float surface = surface_distance(pixel);
#endif
	float max_distance = scene_distance(surface);

	vec4 result;
	vec3 result_b;
	reconstruct(pixel, tile_origin, tile_width, ray_origin, ray_direction, max_distance, result, result_b);
	imageStore(accumulation_image, pixel, result);
	imageStore(accumulation_b_image, pixel, vec4(max_distance * 0.001, result_b));

	float sunlight = surface_sunlight(ray_origin, ray_direction, surface);
#ifdef MSAA
	uvec4 near_composite = composite_affine(ray_origin, ray_direction, surface, sunlight, result, result_b);
	near_composite.w = far_samples;
	imageStore(msaa_near_image, pixel, near_composite);
	if (far_samples != 0u) {
		float far_surface = surface_distance(pixel, far_depth);
		vec4 far_result;
		vec3 far_result_b;
		reconstruct(pixel, tile_origin, tile_width, ray_origin, ray_direction, scene_distance(far_surface), far_result, far_result_b);
		imageStore(msaa_far_image, pixel, composite_affine(ray_origin, ray_direction, far_surface,
				surface_sunlight(ray_origin, ray_direction, far_surface), far_result, far_result_b));
	}
#else
	if (!ATMOSPHERE_ENABLED && result.x <= 0.0 && sunlight >= 1.0) {
		return;
	}
	vec4 color = imageLoad(color_image, pixel);
	color.rgb = composite(color.rgb, ray_origin, ray_direction, surface, sunlight, result, result_b, glow_shadow_masks(pixel, surface));
	imageStore(color_image, pixel, color);
#endif
}
