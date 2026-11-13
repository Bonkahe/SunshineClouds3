#[versions]

inject = "";
inject_storage = "#define STORAGE_DEPTH";
restore_storage = "#define STORAGE_DEPTH\n#define RESTORE";

#[compute]
#version 450

VERSION_DEFINES

// Puts the clouds in Godot's own screen-space reflections (SunshineClouds3.gd engine_ssr_clouds).
// Godot's SSR (Forward+) builds its Hi-Z from the depth buffer after the pre opaque compositor
// effects, and traces against the previous frame's colour, which has the clouds in it already. Sky
// pixels have depth 0, which it takes as nothing there: the clouds over the sky are never hit.
// Before it runs (SunshineClouds3SSRDepth.gd at PRE_OPAQUE), this writes the clouds' depth into
// the depth buffer where it shows sky; after the opaque pass (at POST_OPAQUE) the same pixels go
// back to 0, before the sky is drawn.
//   inject:          mask = the depth to write (0: none), for SunshineClouds3SSRDepthWrite.glsl to
//                    write into the depth buffer (a depth-stencil attachment, not storage).
//   inject_storage:  the same, written into the depth buffer directly as well (with 3D MSAA, the
//                    resolved depth is an R32F storage texture).
//   restore_storage: 0 where the mask has a depth.
// The clouds are last frame's (they're drawn later in the frame), their resolve's accumulation read
// where each pixel's direction was last frame: what Godot's SSR reflects is last frame's colour
// too. Only where last frame showed sky as well, and the clouds are opaque enough
// (SunshineClouds3Reflection.glsl cloud_depth(): thin edges are pushed back towards infinity).
//
// Godot's SSR takes a ray that steps into a pixel more than its depth tolerance (Environment
// ssr_depth_tolerance, in metres) behind what the pixel shows as passing behind it. Clouds seen
// from below come nearer going up the screen by far more than that per pixel, so only about
// tolerance / (that step) of the rays reflecting them hit: they're reflected in bands unless the
// tolerance is raised (to tens or hundreds of metres). Keeping their depth from coming nearer
// going up removes the bands but reflects them far too far away; this is inherent to the depth
// buffer and Godot's tolerance, not to the depth written here.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

#ifdef STORAGE_DEPTH
layout(r32f, set = 0, binding = 0) uniform restrict image2D depth_image;
#else
layout(set = 0, binding = 0) uniform sampler2D depth_texture;
#endif
layout(r32f, set = 0, binding = 1) uniform restrict image2D mask_image;
#ifndef RESTORE
// The resolve's accumulation last frame: x = the clouds' absorption, and in b: x = the scene's
// distance (km), z = the clouds' absorption-weighted distance (km).
layout(set = 0, binding = 2) uniform sampler2D accumulation_texture;
layout(set = 0, binding = 3) uniform sampler2D accumulation_b_texture;
#endif

layout(push_constant, std430) uniform Push {
	// Last frame's view projection times this frame's camera transform: a view direction now to
	// last frame's clip space (w = 0, as far away).
	mat4 reprojection;
	// This view's projection (perspective, as Godot's depth buffer has it): x = [0][0],
	// y = [1][1], z = [2][0], w = [2][1].
	vec4 projection_xy;
	// z = [2][2], w = [3][2]: depth = (z * view_z + w) / -view_z.
	vec2 projection_z;
	uvec2 size;
	float max_distance; // m, cloud_scale applied
	float pad_0;
	float pad_1;
	float pad_2;
} push;

// As SunshineClouds3Reflection.glsl's.
const float CLOUD_OPACITY_MIN = 0.3;
const float CLOUD_OPACITY_FULL = 0.7;

#ifndef RESTORE
// The depth buffer value for the clouds at this pixel, 0 for none.
float cloud_depth(ivec2 pixel) {
	vec2 ndc = (vec2(pixel) + 0.5) / vec2(push.size) * 2.0 - 1.0;
	vec3 view = normalize(vec3((ndc + push.projection_xy.zw) / push.projection_xy.xy, -1.0));
	vec4 last_clip = push.reprojection * vec4(view, 0.0);
	if (last_clip.w <= 0.0) {
		return 0.0;
	}
	vec2 last_uv = last_clip.xy / last_clip.w * 0.5 + 0.5;
	if (any(lessThan(last_uv, vec2(0.0))) || any(greaterThanEqual(last_uv, vec2(1.0)))) {
		return 0.0;
	}
	ivec2 last_pixel = ivec2(last_uv * vec2(push.size));
	vec3 accumulation_b = texelFetch(accumulation_b_texture, last_pixel, 0).xyz;
	if (accumulation_b.x * 1000.0 < push.max_distance * 0.99) {
		return 0.0; // A surface there last frame.
	}
	float absorption = texelFetch(accumulation_texture, last_pixel, 0).x;
	float weight = smoothstep(CLOUD_OPACITY_MIN, CLOUD_OPACITY_FULL, absorption);
	if (weight <= 0.0) {
		return 0.0;
	}
	// In inverse distance, from none (the sky, infinitely far) to the clouds' own.
	float distance = clamp(accumulation_b.z / absorption * 1000.0, 1.0, push.max_distance) / weight;
	if (distance >= push.max_distance) {
		return 0.0;
	}
	float view_z = view.z * distance;
	return max((push.projection_z.x * view_z + push.projection_z.y) / -view_z, 0.0);
}
#endif

void main() {
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(pixel, ivec2(push.size)))) {
		return;
	}
#ifdef RESTORE
	if (imageLoad(mask_image, pixel).r > 0.0) {
		imageStore(depth_image, pixel, vec4(0.0));
	}
#else
#ifdef STORAGE_DEPTH
	float depth = imageLoad(depth_image, pixel).r;
#else
	float depth = texelFetch(depth_texture, pixel, 0).r;
#endif
	float inject = depth > 0.0 ? 0.0 : cloud_depth(pixel);
	imageStore(mask_image, pixel, vec4(inject));
#ifdef STORAGE_DEPTH
	if (inject > 0.0) {
		imageStore(depth_image, pixel, vec4(inject));
	}
#endif
#endif
}
