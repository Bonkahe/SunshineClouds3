#[versions]

copy = "";
msaa = "#define MSAA";

#[compute]
#version 450

VERSION_DEFINES

// Reflection image (SunshineClouds3.gd reflections_enabled) for screen-space reflection materials, written after
// the resolve (and, with 3D MSAA, the composite).
//   rgb: colour with clouds, linear, before transparent objects and post-processing. msaa: samples averaged,
//        as Godot's own resolve does after the transparent pass.
//   a:   distance (m) to the opaque surface as the clouds measure it (SunshineClouds3Common.glslinc
//        surface_distance()/scene_distance()), capped at max_distance, which is also used where nothing was
//        drawn (sky and its clouds). msaa: the nearest sample's, as the clouds do.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

#ifdef MSAA
layout(set = 0, binding = 0) uniform sampler2DMS color_texture;
layout(set = 0, binding = 1) uniform sampler2DMS depth_texture;
#else
layout(set = 0, binding = 0) uniform sampler2D color_texture;
layout(set = 0, binding = 1) uniform sampler2D depth_texture;
#endif
layout(rgba32f, set = 0, binding = 2) uniform restrict writeonly image2D reflection_image;

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
	imageStore(reflection_image, pixel, vec4(color, distance));
}
