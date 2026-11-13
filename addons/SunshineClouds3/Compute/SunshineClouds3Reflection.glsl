#[versions]

copy = "";
msaa = "#define MSAA";

#[compute]
#version 450

VERSION_DEFINES

// The reflection image (SunshineClouds3.gd reflections_enabled), written after the resolve (and,
// with 3D MSAA, the composite): the view's colour with the clouds in it, and the distance to the
// opaque scene at each pixel, for screen-space reflection materials.
//   rgb: the colour, linear, before transparent objects and post-processing. The msaa version
//        averages the samples, as Godot's own resolve does after the transparent pass.
//   a:   the distance (m) from the camera to what the pixel shows: the opaque surface, as the
//        clouds measure it (SunshineClouds3Common.glslinc surface_distance() and
//        scene_distance()), up to max_distance, and max_distance where nothing was drawn (sky);
//        pulled in to the clouds in front of it where they're opaque enough (cloud_depth()). The
//        msaa version takes the nearest sample's surface, as the clouds do.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

#ifdef MSAA
layout(set = 0, binding = 0) uniform sampler2DMS color_texture;
layout(set = 0, binding = 1) uniform sampler2DMS depth_texture;
#else
layout(set = 0, binding = 0) uniform sampler2D color_texture;
layout(set = 0, binding = 1) uniform sampler2D depth_texture;
#endif
layout(rgba32f, set = 0, binding = 2) uniform restrict writeonly image2D reflection_image;
// The resolve's accumulation this frame (SunshineClouds3Resolve.glsl accumulation_image and
// accumulation_b_image), full resolution: x = the clouds' absorption in front of the surface, and
// z = their absorption-weighted distance (km).
layout(set = 0, binding = 3) uniform sampler2D accumulation_texture;
layout(set = 0, binding = 4) uniform sampler2D accumulation_b_texture;

// Where the clouds in front of the surface count as what the pixel shows: from none at
// CLOUD_OPACITY_MIN absorption to fully at CLOUD_OPACITY_FULL. Below it the pixel keeps the surface's
// (or the sky's) distance. The clouds' distance is their absorption-weighted mean, which thin haze
// near the camera pulls in by its share of the absorption: thin pixels (mostly haze) would give
// screen-space reflections false hits close to the camera, which these keep out. 0.2-0.5 /
// 0.5-0.9: lower places thin cloud edges at their depth too, but lets haze in.
const float CLOUD_OPACITY_MIN = 0.3;
const float CLOUD_OPACITY_FULL = 0.7;

// The distance to the pixel's clouds, blended with the surface's (surface m, max_distance for
// sky) by cloud_weight in inverse distance, which is what parallax on screen goes with: the edges
// of a cloud are placed between the cloud and the surface behind it, not doubled.
float cloud_depth(ivec2 pixel, float surface) {
	float absorption = texelFetch(accumulation_texture, pixel, 0).x;
	float weight = smoothstep(CLOUD_OPACITY_MIN, CLOUD_OPACITY_FULL, absorption);
	if (weight <= 0.0) {
		return surface;
	}
	float cloud = clamp(texelFetch(accumulation_b_texture, pixel, 0).z / absorption * 1000.0, 1.0, surface);
	return 1.0 / mix(1.0 / surface, 1.0 / cloud, weight);
}

layout(push_constant, std430) uniform Push {
	mat4 inv_projection; // the view's, as Params' inv_projection
	uvec2 screen_size;
	float max_distance; // m, cloud_scale applied
	float pad;
} push;

void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	if (pixel.x >= int(push.screen_size.x) || pixel.y >= int(push.screen_size.y)) {
		return;
	}
#ifdef MSAA
	vec3 color = vec3(0.0);
	int samples = textureSamples(color_texture);
	for (int i = 0; i < samples; i++) {
		color += texelFetch(color_texture, pixel, i).rgb;
	}
	color /= float(samples);
	// Reverse Z: the nearest sample's is the largest.
	float depth = 0.0;
	for (int i = 0; i < textureSamples(depth_texture); i++) {
		depth = max(depth, texelFetch(depth_texture, pixel, i).r);
	}
#else
	vec3 color = texelFetch(color_texture, pixel, 0).rgb;
	float depth = texelFetch(depth_texture, pixel, 0).r;
#endif
	float distance = push.max_distance;
	if (depth > 0.0) {
		vec2 uv = (vec2(pixel) + 0.5) / vec2(push.screen_size);
		vec4 scene_view = push.inv_projection * vec4(uv * 2.0 - 1.0, depth, 1.0);
		distance = min(length(scene_view.xyz / scene_view.w), push.max_distance);
	}
	imageStore(reflection_image, pixel, vec4(color, cloud_depth(pixel, distance)));
}
