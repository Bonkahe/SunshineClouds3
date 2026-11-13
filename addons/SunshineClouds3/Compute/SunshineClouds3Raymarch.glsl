#[versions]

raymarch = "#define RAYMARCH";
raymarch_msaa = "#define RAYMARCH\n#define MSAA";
shadow_map = "#define SHADOW_MAP";
shadow_blend = "#define SHADOW_BLEND";
skybox = "#define SKYBOX";
skybox_blend = "#define SKYBOX_BLEND";
sample_points = "#define SAMPLE_POINTS";
raymarch_heightmap = "#define RAYMARCH\n#define HEIGHTMAP";
raymarch_msaa_heightmap = "#define RAYMARCH\n#define MSAA\n#define HEIGHTMAP";
shadow_map_heightmap = "#define SHADOW_MAP\n#define HEIGHTMAP";
skybox_heightmap = "#define SKYBOX\n#define HEIGHTMAP";
sample_points_heightmap = "#define SAMPLE_POINTS\n#define HEIGHTMAP";

#[compute]
#version 450

VERSION_DEFINES

// Everything that samples cloud density: the view raymarch, the sun space shadow map, the skybox (each of those two
// with a blend pass for when not rendered every frame) and queued points (add_sample()). The _heightmap versions,
// used while SunshineClouds3.gd's heightmap is on, lift the layers over the terrain.

#ifdef SHADOW_MAP
#define CLOUD_SHADOWS
#endif
#include "SunshineClouds3Common.glslinc"

layout(constant_id = 0) const uint LAYER_COUNT_U = 1u;
#define LAYER_COUNT int(LAYER_COUNT_U)
layout(set = 0, binding = 2) uniform sampler3D noise_texture;
// A row per layer, over its height: r = vertical profile, g = detail strength, b = curl strength.
layout(set = 0, binding = 4) uniform sampler2D profile_texture;
layout(set = 0, binding = 13) uniform sampler2D coverage_texture;
// rgb = flow vector, 0.5 = none.
layout(set = 0, binding = 14) uniform sampler3D curl_texture;

vec2 profile_size;

// std140, 1296 bytes (SunshineClouds3.gd's lights_buffer), at the offsets noted here. Radiances in scene units.
layout(set = 0, binding = 26, std140) uniform Lights {
	int directional_count; // 0
	int omni_count; // 4
	bool atmosphere_enabled; // 8, the directional lights pass through the atmosphere
	int effector_count; // 12
	// Per light: direction to it (xyz), first shadow step (w); radiance above the atmosphere (rgb), shadow samples (w).
	vec4 directional[MAX_DIRECTIONAL_LIGHTS * 2]; // 16
	// 3 per point, omni lights then effectors. Omni: position (xyz), range (w); radiance (rgb), attenuation exponent
	// (w); shadow samples (x), first shadow step (y). Effector: position (xyz), radius (w); coverage added at centre
	// (x), 1 / fade width (y).
	vec4 points[24 * 3]; // 144. 24 must equal SunshineClouds3.gd's MAX_OMNI_LIGHTS + MAX_EFFECTORS, at most 32 (one bit each).
} lights;

uint point_bits(int first, int count) {
	return ((1u << uint(count)) - 1u) << uint(first);
}

// Bitmask (by index) of points [first, first + count) whose sphere the ray passes through between t0 and t1.
uint points_along(vec3 origin, vec3 direction, float t0, float t1, int first, int count) {
	uint mask = 0u;
	if (t0 < t1) {
		for (int i = first; i < first + count; i++) {
			vec4 sphere = lights.points[i * 3];
			float closest = clamp(dot(sphere.xyz - origin, direction), t0, t1);
			if (distance(origin + direction * closest, sphere.xyz) < sphere.w) {
				mask |= 1u << uint(i);
			}
		}
	}
	return mask;
}

// Effectors sample_density() applies: those along the ray being marched.
uint effector_mask = 0u;

// Coverage effector_mask's effectors add at p: each its strength, fading out to its radius.
float effector_coverage(vec3 p) {
	float total = 0.0;
	for (uint mask = effector_mask; mask != 0u; mask &= mask - 1u) {
		int i = findLSB(mask);
		vec4 sphere = lights.points[i * 3];
		vec2 shape = lights.points[i * 3 + 1].xy;
		float fade = clamp((sphere.w - distance(p, sphere.xyz)) * shape.y, 0.0, 1.0);
		total += shape.x * fade * fade * (3.0 - 2.0 * fade);
	}
	return total;
}

#ifdef HEIGHTMAP
// Terrain heightmap: terrain rising into a layer lifts it. A sample at height h over terrain T reads the layer at
// h - push: push = max(T - layer floor, 0) * a weight that is 1 up to falloff_min above the terrain and smoothsteps to
// 0 at falloff_max. A layer's bottom sits on a mountain, its top bumps up less or not at all. Noise is read at the
// lifted point too, so the cloud is the unlifted cloud moved up.
// std140, 48 bytes (SunshineClouds3.gd's HEIGHTMAP_BYTES), at the offsets noted here.
layout(set = 0, binding = 35, std140) uniform Heightmap {
	vec2 origin; // 0, world XZ of the texture's (0, 0) corner (its outer edge)
	vec2 inv_size; // 8, 1 / world size covered on X and Z
	float base; // 16, height (as planet_height()) of a texel value of 0
	float height_scale; // 20, metres per texel value
	float max_height; // 24, max terrain rise above base; higher values are clamped
	float falloff_min; // 28
	float inv_falloff_range; // 32, 1 / (falloff_max - falloff_min)
	float terrain_top; // 36, base + max_height
	float reach_top; // 40, terrain_top + falloff_max: nothing above it is lifted
	float pad; // 44
} heightmap;
layout(set = 0, binding = 34) uniform sampler2D heightmap_texture;

// Terrain under the last sample_density() point: x = height (-1e30 if none), y = lift weight there.
// cloud_ambient() uses it; light_transmittance() keeps the view's.
vec2 terrain = vec2(-1e30, 0.0);

// Terrain under p (at height = planet_height(p)), as terrain; none above reach_top. Outside the heightmap it's the
// edge's (the sampler clamps, not repeats).
vec2 terrain_at(vec3 p, float height) {
	if (height >= heightmap.reach_top) {
		return vec2(-1e30, 0.0);
	}
	float terrain_height = heightmap.base
			+ min(textureLod(heightmap_texture, (p.xz - heightmap.origin) * heightmap.inv_size, 0.0).r * heightmap.height_scale, heightmap.max_height);
	float fade = clamp((height - terrain_height - heightmap.falloff_min) * heightmap.inv_falloff_range, 0.0, 1.0);
	return vec2(terrain_height, 1.0 - fade * fade * (3.0 - 2.0 * fade));
}

float layer_lift(int index) {
	return max(terrain.x - cloud_layers.layers[index].cloud_floor, 0.0) * terrain.y;
}

// Highest a lifted layer reaches: its ceiling plus the most the terrain rises above its floor, capped at reach_top
// (unless already above it). Used for ray clipping so lifted cloud isn't skipped.
float lifted_ceiling(int index) {
	float ceiling = cloud_layers.layers[index].cloud_ceiling;
	return max(ceiling, min(ceiling + max(heightmap.terrain_top - cloud_layers.layers[index].cloud_floor, 0.0), heightmap.reach_top));
}
#define LAYER_CEILING(index) lifted_ceiling(index)
#else
#define LAYER_CEILING(index) cloud_layers.layers[index].cloud_ceiling
#endif

// Cloud density (0..1) of one layer at p inside it (height = planet_height(p)), with the effectors' added_coverage.
// apply_curl warps p by the curl noise (view samples only, as SunshineClouds2).
float sample_layer_density(vec3 p, float height, int index, bool apply_curl, float added_coverage, out float dimensional_profile, out float height_fraction,
		out float coverage) {
	CloudLayer layer = cloud_layers.layers[index];
	height_fraction = clamp((height - layer.cloud_floor) / (layer.cloud_ceiling - layer.cloud_floor), 0.0, 1.0);
	vec2 profile_uv = vec2((height_fraction * (profile_size.x - 1.0) + 0.5) / profile_size.x, (float(index) + 0.5) / profile_size.y);
	vec4 profile = textureLod(profile_texture, profile_uv, 0.0);
	// cloud_coverage pushes the coverage noise: 1 = full, 0.5 = noise as is, 0 = none. coverage_noise_strength blends
	// towards a uniform cloud_coverage; at 1 the noise isn't sampled.
	coverage = layer.cloud_coverage;
	if (layer.coverage_noise_strength != 1.0) {
		float coverage_noise = textureLod(coverage_texture, (p.xz - layer.coverage_noise_offset) / layer.coverage_noise_scale, 0.0).r;
		coverage = mix(clamp(coverage_noise + 2.0 * layer.cloud_coverage - 1.0, 0.0, 1.0), layer.cloud_coverage, layer.coverage_noise_strength);
	}
	coverage = clamp(coverage + added_coverage, 0.0, 1.0);
	dimensional_profile = profile.r * coverage;
	if (dimensional_profile <= 0.0) {
		return 0.0;
	}
	float curl_amount = layer.curl_strength * profile.b;
	if (apply_curl && curl_amount > 0.0) {
		for (int i = 0; i < params.curl_iterations; i++) {
			vec3 flow = textureLod(curl_texture, (p - layer.curl_noise_offset) / layer.curl_noise_scale, 0.0).rgb * 2.0 - 1.0;
			p += flow * vec3(1.0, 0.2, 1.0) * curl_amount;
		}
	}
	float cloud_noise_composite = textureLod(noise_texture, (p - layer.noise_offset) / layer.noise_scale, 0.0).r;
	float threshold = 1.0 - dimensional_profile;
	// Detail noise: the composite at detail scale, centred on its mean and scaled by its deviation, applied before
	// the cut so it reshapes the surface. detail_power masks it by shape (0 at the base surface, 1 in puff cores):
	// at 1 detail keeps to the soft spans between puffs, at 0 it's everywhere. The mask is <= 1, so detail_reach
	// still bounds it.
	float detail_strength = layer.detail_strength * profile.g;
	float detail_reach = detail_strength * (1.0 - params.noise_mean) / params.noise_deviation * dimensional_profile;
	if (cloud_noise_composite + detail_reach <= threshold) {
		return 0.0;
	}
	float shape = clamp((cloud_noise_composite - threshold) / dimensional_profile, 0.0, 1.0);
	float soft = 1.0 - shape;
	// Skipped where scaled to nothing (no detail strength, or masked out by detail_power).
	float detail_amount = detail_strength / params.noise_deviation * dimensional_profile * mix(1.0, soft * soft, layer.detail_power);
	if (detail_amount != 0.0) {
		cloud_noise_composite += (textureLod(noise_texture, (p - layer.detail_noise_offset) / layer.detail_noise_scale, 0.0).r - params.noise_mean)
				* detail_amount;
	}
	return clamp(cloud_noise_composite - threshold, 0.0, 1.0);
}

// Extinction (per metre) at p summed over its layers; profile, height fraction and coverage are extinction-weighted.
float sample_density(vec3 p, bool apply_curl, out float dimensional_profile, out float height_fraction, out float coverage) {
	float total = 0.0;
	dimensional_profile = 0.0;
	height_fraction = 0.0;
	coverage = 0.0;
	float added_coverage = effector_coverage(p);
	float height = planet_height(p);
#ifdef HEIGHTMAP
	terrain = terrain_at(p, height);
	vec3 up = planet_up(p);
	for (int i = 0; i < LAYER_COUNT; i++) {
		float lift = layer_lift(i);
		float lifted_height = height - lift;
		if (lifted_height < cloud_layers.layers[i].cloud_floor || lifted_height > cloud_layers.layers[i].cloud_ceiling) {
			continue;
		}
		float layer_profile;
		float layer_height;
		float layer_coverage;
		float layer_density = sample_layer_density(p - up * lift, lifted_height, i, apply_curl, added_coverage, layer_profile, layer_height, layer_coverage)
				* cloud_layers.layers[i].density;
		total += layer_density;
		dimensional_profile += layer_profile * layer_density;
		height_fraction += layer_height * layer_density;
		coverage += layer_coverage * layer_density;
	}
#else
	for (int i = 0; i < LAYER_COUNT; i++) {
		if (height < cloud_layers.layers[i].cloud_floor || height > cloud_layers.layers[i].cloud_ceiling) {
			continue;
		}
		float layer_profile;
		float layer_height;
		float layer_coverage;
		float layer_density = sample_layer_density(p, height, i, apply_curl, added_coverage, layer_profile, layer_height, layer_coverage) * cloud_layers.layers[i].density;
		total += layer_density;
		dimensional_profile += layer_profile * layer_density;
		height_fraction += layer_height * layer_density;
		coverage += layer_coverage * layer_density;
	}
#endif
	if (total > 0.0) {
		dimensional_profile /= total;
		height_fraction /= total;
		coverage /= total;
	}
	return total;
}

float henyey_greenstein(float cos_angle, float g) {
	float num = 1.0 - g * g;
	float denom = 1.0 + g * g - 2.0 * g * cos_angle;
	float rsqrt_denom = inversesqrt(denom);
	return num * rsqrt_denom * rsqrt_denom * rsqrt_denom * (1.0 / (4.0 * 3.14159265359)); // 1 / (4 pi): normalises over the sphere.
}

// E2(x): the average of exp(-x / cos) over a hemisphere, within ~5%.
float hemisphere_transmittance(float x) {
	return exp(-x) / (x + 1.0 + x / (x + 1.0));
}

const vec2 NO_SPAN = vec2(1e30, -1.0);

// Clips a ray to the layer between heights floor_h and ceiling_h (as planet_height()) and max_distance: (enter, exit)
// per stretch, NO_SPAN for none. Flat it's a slab (one stretch); spherical it's a shell, which a ray dipping into the
// sphere below crosses twice (second). False when there's none.
bool clip_to_layer(vec3 ray_origin, vec3 ray_direction, float floor_h, float ceiling_h, float max_distance, out vec2 first, out vec2 second) {
	second = NO_SPAN;
	if (!spherical_planet()) {
		if (abs(ray_direction.y) < 1e-6) {
			bool inside = ray_origin.y >= floor_h && ray_origin.y <= ceiling_h;
			first = vec2(0.0, inside ? max_distance : 0.0);
		} else {
			float t_floor = (floor_h - ray_origin.y) / ray_direction.y;
			float t_ceiling = (ceiling_h - ray_origin.y) / ray_direction.y;
			first = vec2(max(min(t_floor, t_ceiling), 0.0), min(max(t_floor, t_ceiling), max_distance));
		}
		if (first.y <= first.x) {
			first = NO_SPAN;
		}
		return first.y > first.x;
	}
	float outer_enter;
	float outer_exit;
	if (!height_crossings(ray_origin, ray_direction, ceiling_h, outer_enter, outer_exit)) {
		first = NO_SPAN;
		return false;
	}
	float inner_enter;
	float inner_exit;
	if (height_crossings(ray_origin, ray_direction, floor_h, inner_enter, inner_exit)) {
		first = vec2(outer_enter, inner_enter);
		second = vec2(inner_exit, outer_exit);
	} else {
		first = vec2(outer_enter, outer_exit);
	}
	first = vec2(max(first.x, 0.0), min(first.y, max_distance));
	second = vec2(max(second.x, 0.0), min(second.y, max_distance));
	if (second.y <= second.x) {
		second = NO_SPAN;
	}
	if (first.y <= first.x) {
		first = second;
		second = NO_SPAN;
	}
	return first.y > first.x;
}

// Distance to a spherical planet's surface (1e30 if missed, flat, or starting below it): scene terrain may not cover
// the curved ground.
float planet_surface_distance(vec3 ray_origin, vec3 ray_direction) {
	float t0;
	float t1;
	if (spherical_planet() && height_crossings(ray_origin, ray_direction, 0.0, t0, t1) && t0 > 0.0) {
		return t0;
	}
	return 1e30;
}

// Transmittance from p towards a light through the layers, up to max_distance: steps samples growing from first_step,
// no curl. Spherical: first stretch only, since a light ray dipping back in has gone below the horizon.
float light_transmittance(vec3 p, vec3 direction, float max_distance, float layers_floor, float layers_ceiling, float jitter, int steps, float first_step) {
	vec2 span;
	vec2 unused_span;
	if (steps <= 0 || !clip_to_layer(p, direction, layers_floor, layers_ceiling, max_distance, span, unused_span)) {
		return 1.0;
	}
	float t = span.x;
	float t_end = span.y;
	uint view_effectors = effector_mask;
#ifdef HEIGHTMAP
	vec2 view_terrain = terrain;
#endif
	effector_mask = points_along(p, direction, t, t_end, lights.omni_count, lights.effector_count);
	float optical_depth = 0.0;
	float step_length = first_step;
	for (int i = 0; i < steps && t < t_end; i++) {
		float dt = min(step_length, t_end - t);
		float unused_profile, unused_height, unused_coverage;
		optical_depth += sample_density(p + direction * (t + dt * jitter), false, unused_profile, unused_height, unused_coverage) * dt;
		t += dt;
		step_length *= params.light_step_growth;
	}
	effector_mask = view_effectors;
#ifdef HEIGHTMAP
	terrain = view_terrain;
#endif
	return exp(-optical_depth);
}

// Ambient at a cloud sample as a fraction of the sky's: x = sky (ambient_color), y = ground (ground_color).
// Density-aware (Hillaire 2016): isotropic sky and ground light through the cloud between the sample and the top or
// bottom of its layers, at the sample's extinction. The profile ambient is all sky.
vec2 cloud_ambient(vec3 p, float extinction, float dimensional_profile) {
	vec2 ambient_scattering = vec2(pow(1.0 - dimensional_profile, 0.5), 0.0);
	if (params.ambient_occlusion > 0.0) {
		float height = planet_height(p);
#ifdef HEIGHTMAP
		// Distances to each containing layer's top and bottom, in lifted heights (terrain is from sample_density(p)).
		float above = 0.0;
		float below = 0.0;
		for (int l = 0; l < LAYER_COUNT; l++) {
			float lifted_height = height - layer_lift(l);
			if (lifted_height >= cloud_layers.layers[l].cloud_floor && lifted_height <= cloud_layers.layers[l].cloud_ceiling) {
				above = max(above, cloud_layers.layers[l].cloud_ceiling - lifted_height);
				below = max(below, lifted_height - cloud_layers.layers[l].cloud_floor);
			}
		}
		float scaled = extinction * params.ambient_extinction_scale;
		vec2 density_ambient = vec2(hemisphere_transmittance(scaled * above),
				params.ambient_ground_strength * hemisphere_transmittance(scaled * below));
#else
		float top = -1e30;
		float bottom = 1e30;
		for (int l = 0; l < LAYER_COUNT; l++) {
			if (height >= cloud_layers.layers[l].cloud_floor && height <= cloud_layers.layers[l].cloud_ceiling) {
				top = max(top, cloud_layers.layers[l].cloud_ceiling);
				bottom = min(bottom, cloud_layers.layers[l].cloud_floor);
			}
		}
		float scaled = extinction * params.ambient_extinction_scale;
		vec2 density_ambient = vec2(hemisphere_transmittance(scaled * max(top - height, 0.0)),
				params.ambient_ground_strength * hemisphere_transmittance(scaled * max(height - bottom, 0.0)));
#endif
		ambient_scattering = mix(ambient_scattering, density_ambient, params.ambient_occlusion);
	}
	return ambient_scattering;
}

#ifdef RAYMARCH
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

// 0 = every texel, 1 = the texels interlacing traces this frame, 2 = the reprojected rest.
layout(constant_id = 1) const uint INTERLACE_PASS_U = 0u;
#define INTERLACE_PASS int(INTERLACE_PASS_U)

// x = light absorption (untraced interlace texels hold reprojected history as -absorption - 1), yzw = direct light.
layout(rgba16f, set = 0, binding = 8) uniform restrict writeonly image2D current_image;
// x = sky ambient intensity, y = absorption-weighted cloud distance (km), z = ground ambient intensity.
layout(rgba16f, set = 0, binding = 27) uniform restrict writeonly image2D current_b_image;
// Previous frame's resolve output: as above; b's r = scene distance (km), g = sky ambient, b = weighted cloud
// distance, a = ground ambient.
layout(set = 0, binding = 16) uniform sampler2D history_texture;
layout(set = 0, binding = 17) uniform sampler2D history_b_texture;

#include "atmosphere/AtmosphereHeader.glslinc"
#include "atmosphere/AtmosphereDefinitions.glslinc"
#define ATMOSPHERE_BINDING 9
#include "atmosphere/AtmosphereParameters.glslinc"
#include "atmosphere/AtmosphereFunctions.glslinc"
layout(set = 0, binding = 10) uniform sampler2D transmittance_texture;

void main() {
	ivec2 id = ivec2(gl_GlobalInvocationID.xy);
	ivec2 texel = id;
	if (INTERLACE_PASS != 0) {
		// Pass 1 runs the k-th traced texel of each 4x4 tile (in Bayer order), pass 2 the k-th untraced.
		bool traced = INTERLACE_PASS == 1;
		int per_tile = 16 / params.interlace;
		int count = traced ? per_tile : 16 - per_tile;
		int block_width = count % 4 == 0 ? 4 : (count % 2 == 0 ? count / 2 : count);
		int block_height = count / block_width;
		int k = (id.y % block_height) * block_width + id.x % block_width;
		int first = int(params.frame % uint(params.interlace)) * per_tile;
		int position = int[16](0, 10, 2, 8, 5, 15, 7, 13, 1, 11, 3, 9, 4, 14, 6, 12)[traced ? first + k : (k < first ? k : k + per_tile)]; // 4x4 Bayer order, so each interlace pass spreads evenly.
		texel = id / ivec2(block_width, block_height) * 4 + ivec2(position & 3, position >> 2);
	}
	if (any(greaterThanEqual(texel, raymarch_size()))) {
		return;
	}
	ivec2 pixel = traced_pixel(texel);
	profile_size = vec2(textureSize(profile_texture, 0));
	vec3 ray_origin;
	vec3 ray_direction;
	float max_distance;
	camera_ray(pixel, ray_origin, ray_direction, max_distance);

	if (INTERLACE_PASS == 2) {
		// History at this pixel's cloud, its distance refined once at the reprojected position. Traced instead if that
		// lands off screen, opaque scene is now in front of the cloud, or the scene was nearer there last frame (unless
		// the cloud hid it).
		vec2 prev_uv = (vec2(pixel) + 0.5) / vec2(params.screen_size);
		vec4 history = textureLod(history_texture, prev_uv, 0.0);
		vec4 history_b = textureLod(history_b_texture, prev_uv, 0.0);
		bool found = true;
		for (int i = 0; i < 2 && found; i++) {
			float distance_to_cloud = cloud_distance(history.x, history_b.b);
			vec3 cloud_world = ray_origin + ray_direction * min(distance_to_cloud, max_distance);
			vec4 prev_clip = params.prev_view_projection * vec4(cloud_world - reprojection_wind_delta(cloud_world, distance_to_cloud), 1.0);
			prev_uv = prev_clip.xy / prev_clip.w * 0.5 + 0.5;
			found = prev_clip.w > 0.0 && !any(lessThan(prev_uv, vec2(0.0))) && !any(greaterThan(prev_uv, vec2(1.0)));
			if (found) {
				history = sample_history(history_texture, history_b_texture, prev_uv, max_distance, history_b, found, -1.0);
			}
		}
		ivec2 prev_pixel = min(ivec2(prev_uv * vec2(params.screen_size)), ivec2(params.screen_size) - 1);
		float prev_distance = texelFetch(history_b_texture, prev_pixel, 0).r * 1000.0;
		if (found && max_distance >= cloud_distance(history.x, history_b.b) * 0.95
				&& (prev_distance >= max_distance * 0.95 || opaque_before(history.x, cloud_distance(history.x, history_b.b), prev_distance))) {
			imageStore(current_image, texel, vec4(-history.x - 1.0, history.yzw));
			imageStore(current_b_image, texel, vec4(history_b.gba, 0.0));
			return;
		}
	}

	vec2 jitter = vec2(pcg3d(uvec3(uvec2(pixel), params.frame)).xy) * (1.0 / 4294967296.0);
	max_distance = min(max_distance, planet_surface_distance(ray_origin, ray_direction));
	// Each layer's ray stretches (two per layer for spherical shells; enter > exit on a miss). LAYER_COUNT is constant,
	// so these loops unroll and the arrays stay in registers.
	float layer_enter[MAX_LAYERS * 2];
	float layer_exit[MAX_LAYERS * 2];
	float layers_floor = 1e30;
	float layers_ceiling = -1e30;
	float t = max_distance;
	float t_end = 0.0;
	for (int l = 0; l < LAYER_COUNT; l++) {
		layers_floor = min(layers_floor, cloud_layers.layers[l].cloud_floor);
		layers_ceiling = max(layers_ceiling, LAYER_CEILING(l));
		vec2 first;
		vec2 second;
		clip_to_layer(ray_origin, ray_direction, cloud_layers.layers[l].cloud_floor, LAYER_CEILING(l), max_distance, first, second);
		layer_enter[l * 2] = first.x;
		layer_exit[l * 2] = first.y;
		layer_enter[l * 2 + 1] = second.x;
		layer_exit[l * 2 + 1] = second.y;
		if (first.y > first.x) {
			t = min(t, first.x);
			t_end = max(t_end, second.y > second.x ? second.y : first.y);
		}
	}

	float primary_phase[MAX_DIRECTIONAL_LIGHTS];
	float secondary_phase[MAX_DIRECTIONAL_LIGHTS];
	for (int i = 0; i < lights.directional_count; i++) {
		float cos_angle = dot(ray_direction, lights.directional[i * 2].xyz);
		primary_phase[i] = henyey_greenstein(cos_angle, params.primary_phase_g);
		secondary_phase[i] = henyey_greenstein(cos_angle, params.secondary_phase_g);
	}
	// Omni lights and effectors (effectors after omni lights) whose range the ray's span through the layers crosses.
	uint omni_bits = point_bits(0, lights.omni_count);
	uint along = points_along(ray_origin, ray_direction, t, t_end, 0, lights.omni_count + lights.effector_count);
	uint omni_mask = along & omni_bits;
	effector_mask = along & ~omni_bits;

	float light_absorption = 0.0;
	vec3 direct_light = vec3(0.0);
	vec2 amb_intensity = vec2(0.0);
	float weighted_distance = 0.0;
	float light_jitter = jitter.y;
	// Marching at cloud_step_size since a sample found cloud, and the empty samples since.
	bool in_cloud = false;
	int empty_samples = 0;
	for (int i = 0; i < params.max_steps && t < t_end; i++) {
		// How far the ray stays inside the layers it's in; outside them all, skip to the next one.
		float span_end = -1.0;
		float next_enter = 1e30;
		for (int l = 0; l < LAYER_COUNT * 2; l++) {
			if (layer_enter[l] <= t && t < layer_exit[l]) {
				span_end = max(span_end, layer_exit[l]);
			} else if (layer_enter[l] > t) {
				next_enter = min(next_enter, layer_enter[l]);
			}
		}
		if (span_end < 0.0) {
			if (next_enter >= t_end) {
				break;
			}
			t = next_enter;
			in_cloud = false;
			continue;
		}
		// Distance based step (Nubis Evolved).
		float coarse_step = clamp(params.near_step_size + params.far_step_size_offset * t / params.step_adjustment_distance, params.near_step_size, params.near_step_size + params.far_step_size_offset);
		float step_size = min(in_cloud ? min(params.cloud_step_size, coarse_step) : coarse_step, span_end - t);
		float sample_t = t + step_size * jitter.x;
		vec3 p = ray_origin + ray_direction * sample_t;

		float dimensional_profile;
		float height_fraction;
		float coverage;
		float extinction = sample_density(p, true, dimensional_profile, height_fraction, coverage);
		if (!in_cloud && extinction > 0.0) {
			in_cloud = true;
			empty_samples = 0;
			if (step_size > params.cloud_step_size) {
				// Found cloud with a coarse step: march this step again at the cloud step size.
				continue;
			}
		}
		t += step_size;
		if (extinction <= 0.0) {
			empty_samples++;
			if (empty_samples >= params.cloud_exit_steps) {
				in_cloud = false;
			}
			continue;
		}
		empty_samples = 0;

		// Direct light per light: transmittance * primary phase + multiple scattering * secondary phase. Atmosphere
		// transmittance is per sample: with a low sun it changes a lot with altitude, and one value per ray can darken
		// whole rays (e.g. taken at a wisp in the planet's shadow).
		vec3 point = atmosphere_position(p);
		float r = length(point);
		float ms_shape = clamp((dimensional_profile * step_size - 0.1) / 0.9, 0.0, 1.0) * pow(coverage, 0.25)
				* pow(height_fraction, params.multiple_scattering_height_power);
		vec3 light_energy = vec3(0.0);
		for (int l = 0; l < lights.directional_count; l++) {
			vec4 light = lights.directional[l * 2];
			float attenuated_light = light_transmittance(p, light.xyz, params.light_march_distance, layers_floor, layers_ceiling, light_jitter,
					int(lights.directional[l * 2 + 1].w), light.w);
			// Golden ratio step so neighbouring light rays along this view ray don't share an offset.
			light_jitter = fract(light_jitter + 0.61803398875);
			float ms_volume = ms_shape * pow(attenuated_light, params.multiple_scattering_depth_power);
			vec3 transmittance = lights.atmosphere_enabled ? GetTransmittanceToSun(ATMOSPHERE, transmittance_texture, r, dot(point, light.xyz) / r) : vec3(1.0);
			light_energy += (attenuated_light * primary_phase[l] + ms_volume * secondary_phase[l]) * lights.directional[l * 2 + 1].rgb * transmittance;
		}
		for (uint mask = omni_mask; mask != 0u; mask &= mask - 1u) {
			int l = findLSB(mask);
			vec4 light = lights.points[l * 3];
			vec4 radiance = lights.points[l * 3 + 1];
			vec2 shadow = lights.points[l * 3 + 2].xy;
			vec3 to_light = light.xyz - p;
			float light_distance = length(to_light);
			if (light_distance >= light.w) {
				continue;
			}
			vec3 direction = to_light / max(light_distance, 1e-3);
			float attenuated_light = light_transmittance(p, direction, min(light_distance, params.light_march_distance), layers_floor, layers_ceiling, light_jitter,
					int(shadow.x), shadow.y);
			light_jitter = fract(light_jitter + 0.61803398875);
			float ms_volume = ms_shape * pow(attenuated_light, params.multiple_scattering_depth_power);
			float cos_angle = dot(ray_direction, direction);
			// Godot's omni falloff: the range window times distance^-attenuation.
			float window = light_distance / light.w;
			window *= window;
			window = max(1.0 - window * window, 0.0);
			float falloff = window * window * pow(max(light_distance, 1e-4), -radiance.w);
			light_energy += (attenuated_light * henyey_greenstein(cos_angle, params.primary_phase_g)
					+ ms_volume * henyey_greenstein(cos_angle, params.secondary_phase_g)) * radiance.rgb * falloff;
		}

		vec2 ambient_scattering = cloud_ambient(p, extinction, dimensional_profile);

		// This step's share of the pixel: its opacity times the transmittance in front of it.
		float step_weight = (1.0 - exp(-extinction * step_size)) * (1.0 - light_absorption);
		weighted_distance += sample_t * step_weight;
		direct_light += light_energy * step_weight;
		amb_intensity += ambient_scattering * step_weight;
		light_absorption += step_weight;
		if (light_absorption > 0.995) {
			light_absorption = 1.0;
			break;
		}
	}
	imageStore(current_image, texel, vec4(light_absorption, direct_light));
	imageStore(current_b_image, texel, vec4(amb_intensity.x, weighted_distance * 0.001, amb_intensity.y, 0.0));
}
#endif

#ifdef SHADOW_MAP
// Each texel is a line along the sun, storing the sunlight through the layers along it. The map repeats every extent
// (as the projector does), so each texel takes its line's copy nearest the camera.
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 21) uniform restrict writeonly image2D shadow_map;

void main() {
	ivec2 texel = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(texel, ivec2(shadow.resolution)))) {
		return;
	}
	profile_size = vec2(textureSize(profile_texture, 0));

	vec2 uv = (vec2(texel) + 0.5) / float(shadow.resolution);
	vec2 light_xy = (vec2(uv.x, 1.0 - uv.y) - 0.5) * shadow.extent;
	light_xy += round((shadow.camera_light.xy - light_xy) / shadow.extent) * shadow.extent;
	// Where the line crosses the plane through the camera facing the sun.
	vec3 line_point = (shadow.light_to_world * vec4(light_xy, shadow.camera_light.z, 1.0)).xyz;
	vec3 sun_direction = normalize(shadow.light_to_world[2].xyz);

	// Optical depth from where the line enters the lowest floor, and from 1/3 and 2/3 along (for points inside or
	// above the layers). Each sample's extinction, relative to the densest layer's, is raised to sharpness and scaled
	// by strength.
	vec3 optical_depth = vec3(0.0);
	float reference_density = 0.0;
	for (int l = 0; l < LAYER_COUNT; l++) {
		reference_density = max(reference_density, cloud_layers.layers[l].density);
	}
	if (shadow.march_length > 0.0 && reference_density > 0.0 && shadow.strength > 0.0) {
		float floor_behind;
		float floor_ahead;
		if (!height_crossings(line_point, sun_direction, shadow.march_floor, floor_behind, floor_ahead)) {
			// Passes over a spherical planet's floor (a low sun): from its lowest point.
			floor_ahead = -dot(planet_offset(line_point), sun_direction);
		}
		vec3 entry = line_point + sun_direction * floor_ahead;
		effector_mask = points_along(entry, sun_direction, 0.0, shadow.march_length, lights.omni_count, lights.effector_count);
		float dt = shadow.march_length / float(shadow.steps);
		for (int i = 0; i < shadow.steps; i++) {
			float t = (float(i) + 0.5) * dt;
			float unused_profile, unused_height, unused_coverage;
			float extinction = sample_density(entry + sun_direction * t, false, unused_profile, unused_height, unused_coverage);
			float depth = shadow.strength * reference_density * pow(extinction / reference_density, max(shadow.sharpness, 0.01)) * dt;
			optical_depth += depth * vec3(1.0, step(shadow.march_length / 3.0, t), step(shadow.march_length * 2.0 / 3.0, t));
		}
	}
	vec3 transmittance = exp(-optical_depth);
	imageStore(shadow_map, texel, vec4(transmittance.x, transmittance));
}
#endif

#ifdef SHADOW_BLEND
// The shadow map between the two last rendered (cloud_shadow_update_interval).
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 21) uniform restrict writeonly image2D shadow_map;
layout(rgba16f, set = 0, binding = 24) uniform restrict readonly image2D shadow_key_0;
layout(rgba16f, set = 0, binding = 25) uniform restrict readonly image2D shadow_key_1;

layout(push_constant, std430) uniform BlendConstants {
	float key_1_weight;
	float pad0;
	float pad1;
	float pad2;
} blend;

void main() {
	ivec2 texel = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(texel, imageSize(shadow_map)))) {
		return;
	}
	imageStore(shadow_map, texel, mix(imageLoad(shadow_key_0, texel), imageLoad(shadow_key_1, texel), blend.key_1_weight));
}
#endif

#ifdef SKYBOX
// Skybox (SunshineClouds3.gd's skybox_enabled): atmosphere, background and a coarse cloud march from the camera, as an
// equirectangular panorama in Godot's SKY_COORDS layout. SunshineClouds3Driver's WorldEnvironment sky draws it.
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

#include "atmosphere/AtmosphereHeader.glslinc"
#include "atmosphere/AtmosphereDefinitions.glslinc"
#define ATMOSPHERE_BINDING 9
#include "atmosphere/AtmosphereParameters.glslinc"
#include "atmosphere/AtmosphereFunctions.glslinc"
layout(set = 0, binding = 10) uniform sampler2D transmittance_texture;
layout(set = 0, binding = 11) uniform sampler3D scattering_texture;
layout(set = 0, binding = 12) uniform sampler2D irradiance_texture;
#include "SunshineClouds3Sky.glslinc"

layout(rgba16f, set = 0, binding = 31) uniform restrict writeonly image2D skybox_image;

// Planet ground below the horizon (sky_settings.skybox_ground_albedo, lit by the atmosphere's lights and sky) seen
// from camera (atmosphere position) along view, with the air in front. Sky light on it and the air's are times
// atmosphere_tint.
vec3 ground_radiance(AtmosphereParameters atmosphere, vec3 camera, vec3 view) {
	float r = length(camera);
	float rmu = dot(camera, view);
	float distance = -rmu - sqrt(max(rmu * rmu - r * r + atmosphere.bottom_radius * atmosphere.bottom_radius, 0.0));
	vec3 point = camera + view * max(distance, 0.1); // Min ground distance (km): nearer, the ground's aerial perspective loses float precision. 0.05-0.5.
	vec3 sky_irradiance = vec3(0.0);
	vec3 sun_irradiance = vec3(0.0);
	for (int i = 0; i < params.atmosphere_light_count; i++) {
		vec3 weight = atmosphere_light_weight(i);
		vec3 light_sky_irradiance;
		sun_irradiance += GetSunAndSkyIrradiance(atmosphere, transmittance_texture, irradiance_texture,
				point, normalize(point), atmosphere_light_direction(i), light_sky_irradiance) * weight;
		sky_irradiance += light_sky_irradiance * weight;
	}
	vec3 transmittance;
	vec3 glow;
	vec3 in_scatter = sky_radiance_to_point_parts(atmosphere, camera, point, transmittance, glow);
	return sky_settings.skybox_ground_albedo / PI * (sun_irradiance + sky_irradiance * sky_settings.atmosphere_tint) * transmittance
			+ (in_scatter + glow) * sky_settings.atmosphere_tint;
}

// Clouds along direction, much coarser than the view raymarch: skybox_cloud_steps even steps up to
// skybox_cloud_distance, skybox_cloud_light_steps per directional light, no curl or omni lights. Returns absorption;
// cloud_light = light sent back (direct + ambient as the resolve adds it); distance_to_cloud: absorption-weighted (m).
float skybox_clouds(vec3 ray_origin, vec3 direction, float jitter, out vec3 cloud_light, out float distance_to_cloud) {
	cloud_light = vec3(0.0);
	distance_to_cloud = 0.0;
	int steps = sky_settings.skybox_cloud_steps;
	float layers_floor = 1e30;
	float layers_ceiling = -1e30;
	for (int l = 0; l < LAYER_COUNT; l++) {
		layers_floor = min(layers_floor, cloud_layers.layers[l].cloud_floor);
		layers_ceiling = max(layers_ceiling, LAYER_CEILING(l));
	}
	// Both of a spherical planet's stretches as one, its even steps crossing the gap between them.
	vec2 first;
	vec2 second;
	float march_distance = min(sky_settings.skybox_cloud_distance, planet_surface_distance(ray_origin, direction));
	if (LAYER_COUNT == 0 || steps <= 0
			|| !clip_to_layer(ray_origin, direction, layers_floor, layers_ceiling, march_distance, first, second)) {
		return 0.0;
	}
	float t = first.x;
	float t_end = second.y > second.x ? second.y : first.y;
	effector_mask = points_along(ray_origin, direction, t, t_end, lights.omni_count, lights.effector_count);
	float step_size = (t_end - t) / float(steps);

	float primary_phase[MAX_DIRECTIONAL_LIGHTS];
	float secondary_phase[MAX_DIRECTIONAL_LIGHTS];
	for (int i = 0; i < lights.directional_count; i++) {
		float cos_angle = dot(direction, lights.directional[i * 2].xyz);
		primary_phase[i] = henyey_greenstein(cos_angle, params.primary_phase_g);
		secondary_phase[i] = henyey_greenstein(cos_angle, params.secondary_phase_g);
	}
	// The light march's first step for its own step count, as SunshineClouds3.gd's _first_light_step().
	int light_steps = sky_settings.skybox_cloud_light_steps;
	float growth = params.light_step_growth;
	float first_light_step = growth > 1.0001 ? params.light_march_distance * (growth - 1.0) / (pow(growth, float(light_steps)) - 1.0)
			: params.light_march_distance / float(max(light_steps, 1));

	float light_absorption = 0.0;
	vec3 direct_light = vec3(0.0);
	vec2 amb_intensity = vec2(0.0);
	float weighted_distance = 0.0;
	for (int i = 0; i < steps; i++) {
		float sample_t = t + (float(i) + jitter) * step_size;
		vec3 p = ray_origin + direction * sample_t;
		float dimensional_profile;
		float height_fraction;
		float coverage;
		float extinction = sample_density(p, false, dimensional_profile, height_fraction, coverage);
		if (extinction <= 0.0) {
			continue;
		}
		// As the view raymarch, its multiple scattering shaped at most at the view's cloud step.
		vec3 point = atmosphere_position(p);
		float r = length(point);
		float ms_shape = clamp((dimensional_profile * min(step_size, params.cloud_step_size) - 0.1) / 0.9, 0.0, 1.0) * pow(coverage, 0.25)
				* pow(height_fraction, params.multiple_scattering_height_power);
		vec3 light_energy = vec3(0.0);
		for (int l = 0; l < lights.directional_count; l++) {
			vec4 light = lights.directional[l * 2];
			float attenuated_light = light_transmittance(p, light.xyz, params.light_march_distance, layers_floor, layers_ceiling, jitter,
					light_steps, first_light_step);
			float ms_volume = ms_shape * pow(attenuated_light, params.multiple_scattering_depth_power);
			vec3 transmittance = lights.atmosphere_enabled ? GetTransmittanceToSun(ATMOSPHERE, transmittance_texture, r, dot(point, light.xyz) / r) : vec3(1.0);
			light_energy += (attenuated_light * primary_phase[l] + ms_volume * secondary_phase[l]) * lights.directional[l * 2 + 1].rgb * transmittance;
		}
		float step_weight = (1.0 - exp(-extinction * step_size)) * (1.0 - light_absorption);
		weighted_distance += sample_t * step_weight;
		direct_light += light_energy * step_weight;
		amb_intensity += cloud_ambient(p, extinction, dimensional_profile) * step_weight;
		light_absorption += step_weight;
		if (light_absorption > 0.995) {
			light_absorption = 1.0;
			break;
		}
	}
	if (light_absorption <= 0.0) {
		return 0.0;
	}
	distance_to_cloud = weighted_distance / light_absorption;
	// The ambient as the resolve adds it: the sky irradiance at the cloud as an average radiance.
	vec3 point = atmosphere_position(ray_origin + direction * distance_to_cloud);
	vec3 sky_light = atmosphere_sky_irradiance(ATMOSPHERE, point) / PI * params.radiance_scale * sky_settings.atmosphere_tint;
	cloud_light = (direct_light + (amb_intensity.x * params.ambient_color + amb_intensity.y * params.ground_color) * sky_light * params.ambient_energy) * sky_settings.cloud_tint;
	return light_absorption;
}

void main() {
	ivec2 texel = ivec2(gl_GlobalInvocationID.xy);
	ivec2 size = imageSize(skybox_image);
	if (any(greaterThanEqual(texel, size))) {
		return;
	}
	profile_size = vec2(textureSize(profile_texture, 0));
	// The direction at the texel, inverting SKY_COORDS (u = atan(x, -z) / 2pi, v = acos(y) / pi).
	vec2 angles = (vec2(texel) + 0.5) / vec2(size) * vec2(2.0 * PI, PI);
	vec3 direction = vec3(sin(angles.x) * sin(angles.y), cos(angles.y), -cos(angles.x) * sin(angles.y));

	AtmosphereParameters atmosphere = ATMOSPHERE;
	vec3 ray_origin = params.camera_to_world[3].xyz;
	vec3 camera = atmosphere_position(ray_origin);
	float r = length(camera);
	float mu_horizon = -sqrt(max(1.0 - (atmosphere.bottom_radius / r) * (atmosphere.bottom_radius / r), 0.0));
	vec3 radiance;
	if (dot(direction, camera) / r < mu_horizon) {
		radiance = ground_radiance(atmosphere, camera, direction) * params.radiance_scale;
	} else {
		// No discs: the lights themselves give the scene their highlights.
		vec3 transmittance;
		vec3 unused_disc;
		float through;
		radiance = sky_radiance(ray_origin, direction, 0.0, transmittance, unused_disc, through) * params.radiance_scale;
		radiance += background_radiance(direction, PI / float(size.y), transmittance, radiance, through) * sky_settings.background_skybox_energy;
	}
	// Clouds over it, composited as the resolve does. Fixed jitter per texel: the skybox isn't accumulated, and
	// filtering it into reflections smooths the noise.
	vec3 cloud_light;
	float distance_to_cloud;
	float jitter = float(pcg3d(uvec3(uvec2(texel), 0u)).x) * (1.0 / 4294967296.0);
	float light_absorption = skybox_clouds(ray_origin, direction, jitter, cloud_light, distance_to_cloud);
	if (light_absorption > 0.0) {
		vec3 transmittance;
		vec3 in_scatter = atmosphere_aerial_perspective(ray_origin, direction, distance_to_cloud, 1.0 - light_absorption, transmittance);
		radiance = radiance * (1.0 - light_absorption) + cloud_light * transmittance + in_scatter * light_absorption;
	}
	imageStore(skybox_image, texel, vec4(min(radiance * sky_settings.skybox_radiance_multiplier, vec3(MAX_RADIANCE)), 1.0));
}
#endif

#ifdef SKYBOX_BLEND
// The skybox between the two last rendered (skybox_update_interval).
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(rgba16f, set = 0, binding = 31) uniform restrict writeonly image2D skybox_image;
layout(rgba16f, set = 0, binding = 32) uniform restrict readonly image2D skybox_key_0;
layout(rgba16f, set = 0, binding = 33) uniform restrict readonly image2D skybox_key_1;

layout(push_constant, std430) uniform BlendConstants {
	float key_1_weight;
	float pad0;
	float pad1;
	float pad2;
} blend;

void main() {
	ivec2 texel = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(texel, imageSize(skybox_image)))) {
		return;
	}
	imageStore(skybox_image, texel, mix(imageLoad(skybox_key_0, texel), imageLoad(skybox_key_1, texel), blend.key_1_weight));
}
#endif

#ifdef SAMPLE_POINTS
// xyz in, w out: cloud density (0..1) summed over the point's layers, before each layer's density scale.
layout(local_size_x = 32, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 22, std430) restrict buffer SamplePointsBuffer {
	vec4 sample_points[32]; // Must match SunshineClouds3.gd's MAX_SAMPLE_POINTS and fit the 32-wide workgroup.
};

layout(push_constant, std430) uniform SampleConstants {
	int count;
	int pad0;
	int pad1;
	int pad2;
} sample_constants;

void main() {
	int index = int(gl_GlobalInvocationID.x);
	if (index >= sample_constants.count) {
		return;
	}
	profile_size = vec2(textureSize(profile_texture, 0));
	vec3 p = sample_points[index].xyz;
	effector_mask = point_bits(lights.omni_count, lights.effector_count);
	float added_coverage = effector_coverage(p);
	float height = planet_height(p);
	float density = 0.0;
#ifdef HEIGHTMAP
	terrain = terrain_at(p, height);
	vec3 up = planet_up(p);
	for (int i = 0; i < LAYER_COUNT; i++) {
		float lift = layer_lift(i);
		float lifted_height = height - lift;
		if (lifted_height < cloud_layers.layers[i].cloud_floor || lifted_height > cloud_layers.layers[i].cloud_ceiling) {
			continue;
		}
		float unused_profile, unused_height, unused_coverage;
		density += sample_layer_density(p - up * lift, lifted_height, i, true, added_coverage, unused_profile, unused_height, unused_coverage);
	}
#else
	for (int i = 0; i < LAYER_COUNT; i++) {
		if (height < cloud_layers.layers[i].cloud_floor || height > cloud_layers.layers[i].cloud_ceiling) {
			continue;
		}
		float unused_profile, unused_height, unused_coverage;
		density += sample_layer_density(p, height, i, true, added_coverage, unused_profile, unused_height, unused_coverage);
	}
#endif
	sample_points[index].w = density;
}
#endif
