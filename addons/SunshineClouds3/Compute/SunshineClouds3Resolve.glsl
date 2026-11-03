#[compute]
#version 450

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

// Off (SunshineClouds3.gd's atmosphere_enabled), the scene's own sky stays, nothing is fogged and
// the clouds' sky light is a fixed plain sky radiance.
layout(constant_id = 0) const bool ATMOSPHERE_ENABLED = true;

#define CLOUD_SHADOWS
#include "SunshineClouds3Common.glslinc"

#include "atmosphere/AtmosphereHeader.glslinc"
#include "atmosphere/AtmosphereDefinitions.glslinc"
#define ATMOSPHERE_BINDING 9
#include "atmosphere/AtmosphereParameters.glslinc"
#include "atmosphere/AtmosphereFunctions.glslinc"

layout(rgba16f, set = 0, binding = 0) uniform restrict image2D color_image;
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
vec3 aerial_perspective(vec3 ray_origin, vec3 ray_direction, float distance, float glow_scale, out vec3 transmittance) {
	if (!ATMOSPHERE_ENABLED) {
		transmittance = vec3(1.0);
		return vec3(0.0);
	}
	return atmosphere_aerial_perspective(ray_origin, ray_direction, distance, glow_scale, transmittance);
}

// The raymarch texels a group's pixels gather from (those under the group and a one texel border,
// at most 10 x 10 at raymarch_resolution 1), read once per group instead of 9 times per pixel.
#define TILE_TEXELS 100
shared vec4 tile_value[TILE_TEXELS];
shared vec3 tile_value_b[TILE_TEXELS]; // current_b_texture's
shared vec2 tile_pixel[TILE_TEXELS]; // the pixel the texel traced
shared float tile_distance[TILE_TEXELS]; // scene distance at that pixel

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
	float surface = surface_distance(pixel);
	float max_distance = scene_distance(surface);

	// This frame's values (a = absorption and direct light, b = sky ambient, weighted distance and
	// ground ambient), from the 3x3 raymarch texels around the pixel, each weighted by a tent of one block on the
	// distance to the pixel it traced. Only texels at a similar scene distance (or whose opaque cloud
	// hides both, or whose absorption matches the pixel's own: see same_cloud_own) count, so nothing
	// bleeds across silhouettes; they also give the range the history
	// is clamped to. Interlaced,
	// the traced texels (the new ones) are also summed apart.
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
	vec4 result = closest;
	vec3 result_b = closest_b;
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
	imageStore(accumulation_image, pixel, result);
	imageStore(accumulation_b_image, pixel, vec4(max_distance * 0.001, result_b));

	float light_absorption = result.x;

	// Screen space cloud shadows, when the light can't take them as a projector: opaque surfaces
	// are darkened (ambient included) by the sunlight the clouds leave them, fading out towards the
	// edge of the map.
	float sunlight = 1.0;
	if (shadow.screen_space != 0 && shadow.march_length > 0.0 && surface > 0.0 && surface < params.max_distance) {
		float fade = 1.0 - smoothstep(shadow.fade_start, shadow.extent * 0.5, surface);
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

	if (!ATMOSPHERE_ENABLED && light_absorption <= 0.0 && sunlight >= 1.0) {
		return;
	}
	AtmosphereParameters atmosphere = ATMOSPHERE;
	vec4 color = imageLoad(color_image, pixel);
	// How much of what's behind the clouds shows through them (the sky applies its own).
	float background_visibility = 1.0 - light_absorption;
	if (surface > 0.0) {
		vec3 transmittance;
		vec3 in_scatter = aerial_perspective(ray_origin, ray_direction, surface, 1.0, transmittance);
		color.rgb = color.rgb * sunlight * transmittance + in_scatter;
	} else if (ATMOSPHERE_ENABLED) {
		// The sky, and the background behind it (seen across about pixel_angle radians a pixel).
		vec3 transmittance;
		vec3 sky = sky_radiance(ray_origin, ray_direction, 1.0 - light_absorption, transmittance) * params.radiance_scale;
		float pixel_angle = 2.0 * params.inv_projection[1][1] / float(params.screen_size.y);
		sky += background_radiance(ray_direction, pixel_angle, transmittance, sky);
		color.rgb = min(sky * (1.0 - light_absorption), vec3(MAX_RADIANCE));
		background_visibility = 1.0;
	}
	if (light_absorption > 0.0) {
		float distance_to_cloud = cloud_distance(result.x, result_b.y);
		// The direct light (the raymarch's, every light's) and the sky irradiance at the cloud as
		// an average radiance.
		vec3 sky_light = atmosphere.solar_irradiance * params.radiance_scale * vec3(0.04, 0.06, 0.1); // Plain sky radiance: without the atmosphere, the clouds' sky light as a fraction of the sun's irradiance, about a clear midday sky. Each channel 0.02-0.15, blue highest.
		if (ATMOSPHERE_ENABLED) {
			vec3 point = atmosphere_position(ray_origin + ray_direction * distance_to_cloud);
			float r = length(point);
			sky_light = GetIrradiance(atmosphere, irradiance_texture, r, dot(point, params.sun_direction) / r) / PI * params.radiance_scale
					* sky_settings.atmosphere_tint;
		}
		// Tinted after the accumulation, so a change shows at once.
		vec3 cloud_color = (result.yzw + (result_b.x * params.ambient_color + result_b.z * params.ground_color) * sky_light * params.ambient_energy)
				* sky_settings.cloud_tint;
		// The air in front of the cloud is in its shadow looking towards the sun, so its glow is
		// blocked by the cloud's opacity too.
		vec3 transmittance;
		vec3 in_scatter = aerial_perspective(ray_origin, ray_direction, distance_to_cloud, 1.0 - light_absorption, transmittance);
		color.rgb = color.rgb * background_visibility + cloud_color * transmittance + in_scatter * light_absorption;
	}
	imageStore(color_image, pixel, color);
}
