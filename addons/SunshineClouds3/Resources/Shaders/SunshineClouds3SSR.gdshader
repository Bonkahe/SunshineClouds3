// A basic screen-space reflection (SSR) material, a starting point for your own. It marches the
// reflected ray against SunshineClouds3's reflection image (reflections_enabled, the global below):
//   rgb: the opaque scene's colour with the clouds in it, before transparent objects.
//   a:   the distance (m) from the camera to what each pixel shows: the opaque surface, the clouds
//        in front of it where they're dense, the clouds' max_distance for sky. 0 until written.
// Draw it in the transparent pass (it is: ALPHA) so it reads this frame's image.
//
// The march (after McGuire and Mara, "Efficient GPU Screen-Space Ray Tracing", JCGT 2014) steps
// along the ray's line on screen, from the surface to where the ray vanishes (its point at
// infinity, or the near plane for a ray coming back towards the camera), clipped to the screen.
// 1/w and t/w are linear on screen, so each step's distance along the ray is exact. Reaching the
// vanishing point, one march covers near objects, clouds at their depth and the sky.
//   hit:      the ray passes behind what a pixel shows, by no more than its thickness (thickness
//             plus thickness_scale of its distance; anything farther than far_distance, the sky
//             and the clouds in it included, counts as infinitely thick). Placed by bisection.
//   occluded: the ray is behind something nearer than that: what it would see is hidden.
//   valid:    the ray is in front of what the pixel shows.
// Pixels showing something under the mirror plane (the surface below the reflective one, seen
// through it) are passed over: it's not in the reflection.
// A ray that ends occluded (on screen, behind a nearer object) takes the last valid sample's
// colour: the reflection behind the object stretches over the hole it punches, fading out over
// hole_fill_distance on screen past that sample. A ray hidden for longer than that gives up: the
// march stops, and the engine's reflection shows. A ray that leaves
// the screen or comes back towards the camera without a hit reflects nothing: the engine's own
// reflection (SPECULAR) shows there, as it does where the screen edge fades blend it in.
shader_type spatial;
render_mode depth_draw_always;

global uniform sampler2D sunshine_clouds_reflection : filter_linear, repeat_disable;

group_uniforms surface;
uniform vec3 albedo : source_color = vec3(0.02, 0.03, 0.035);
uniform float roughness : hint_range(0.0, 1.0) = 0.05;
uniform float fresnel_f0 : hint_range(0.0, 1.0) = 0.02;
uniform float reflection_strength : hint_range(0.0, 4.0) = 1.0;

group_uniforms ray_march;
// Samples along the ray's line on screen, closer together near the surface.
uniform int march_steps : hint_range(4, 256) = 48;
// Bisection steps placing a hit between the last two samples.
uniform int refine_steps : hint_range(0, 16) = 6;
// How far (m) behind what a pixel shows the ray still counts as hitting it, plus thickness_scale
// of its distance.
uniform float thickness : hint_range(0.0, 100.0) = 1.0;
uniform float thickness_scale : hint_range(0.0, 1.0, 0.001) = 0.1;
// Beyond this (m), everything in the image is taken as infinitely thick: far land, clouds, sky.
uniform float far_distance : hint_range(10.0, 100000.0, 1.0) = 500.0;
// Rays ending behind a nearer object take the last colour they saw, fading out over this far on
// screen (a fraction of its height) past where they saw it: small holes close, large ones fade
// to the engine's reflection. A ray hidden for longer stops there. 0: no filling.
uniform float hole_fill_distance : hint_range(0.0, 1.0, 0.001) = 0.1;
// Fades the reflection out within this fraction of the screen from its edges.
uniform float screen_edge_fade : hint_range(0.0, 0.5) = 0.1;
// Widens the fade at the left and right edges away from the horizon: by this times the
// fragment's distance from the horizon on screen (as a fraction of the screen).
uniform float side_fade_horizon_scale : hint_range(0.0, 10.0, 0.01) = 2.0;

// Rays end this far (m) along when they vanish to infinity: farther than anything in the image.
const float RAY_END = 1e7;

float image_distance(vec2 uv) {
	ivec2 size = textureSize(sunshine_clouds_reflection, 0);
	ivec2 pixel = clamp(ivec2(uv * vec2(size)), ivec2(0), size - 1);
	return texelFetch(sunshine_clouds_reflection, pixel, 0).a;
}

// side: the fade's width at the left and right edges.
float edge_fade(vec2 uv, float side) {
	vec2 to_edge = min(uv, 1.0 - uv);
	return clamp(min(to_edge.x / max(side, 1e-4), to_edge.y / max(screen_edge_fade, 1e-4)), 0.0, 1.0);
}

vec2 view_to_uv(vec3 position, mat4 projection) {
	vec4 clip = projection * vec4(position, 1.0);
	return clip.xy / clip.w * 0.5 + 0.5;
}

vec3 image_color(vec2 uv, float radius) {
	vec3 color = textureLod(sunshine_clouds_reflection, uv, 0.0).rgb;
	if (radius <= 0.0) {
		return color;
	}
	vec2 size = vec2(textureSize(sunshine_clouds_reflection, 0));
	vec2 aspect = vec2(size.y / size.x, 1.0);
	for (int i = 0; i < 8; i++) {
		float angle = float(i) * 0.785398;
		vec2 offset = vec2(cos(angle), sin(angle)) * radius * aspect * (i % 2 == 0 ? 1.0 : 0.5);
		color += textureLod(sunshine_clouds_reflection, clamp(uv + offset, vec2(0.0), vec2(1.0)), 0.0).rgb;
	}
	return color / 9.0;
}

// The fragment's distance on screen from the horizon of the plane with this normal (the line
// where it vanishes), along the direction away from it: 1 where the horizon isn't in front.
float horizon_distance(vec3 vertex, vec3 normal, mat4 projection) {
	vec3 view = normalize(vertex);
	vec4 clip = projection * vec4(view - normal * dot(view, normal), 0.0);
	if (clip.w <= 1e-6) {
		return 1.0;
	}
	return min(length(view_to_uv(vertex, projection) - (clip.xy / clip.w * 0.5 + 0.5)), 1.0);
}

void fragment() {
	vec3 normal = normalize(NORMAL);
	vec3 to_camera = normalize(-VERTEX);
	vec3 ray = reflect(-to_camera, normal);
	vec3 origin = VERTEX + normal * (0.002 * length(VERTEX));
	float jitter = fract(52.9829189 * fract(dot(FRAGCOORD.xy, vec2(0.06711056, 0.00583715))));
	float side_fade = min(screen_edge_fade * (1.0 + side_fade_horizon_scale * horizon_distance(VERTEX, normal, PROJECTION_MATRIX)), 0.5);

	// The ray's line on screen, from the surface (s = 0) to its end (s = 1): where it vanishes,
	// or, coming back towards the camera (or orthographic), a finite point. t(s) from 1/w and t/w,
	// which are linear in s: t = s * end_t / ((1 - s) / w0 + s * end_q).
	vec4 start = PROJECTION_MATRIX * vec4(origin, 1.0);
	vec4 direction = PROJECTION_MATRIX * vec4(ray, 0.0);
	vec4 end;
	float end_t;
	float end_q;
	float s_cap = 1.0;
	if (direction.w > 1e-6 * start.w) {
		end = direction; // The point at infinity.
		end_t = 1.0 / direction.w;
		end_q = 0.0;
		// Stopped at RAY_END: s / (1 - s) = RAY_END * direction.w / start.w.
		float x = RAY_END * direction.w / start.w;
		s_cap = x / (1.0 + x);
	} else {
		// To just short of the camera's plane, or RAY_END away (orthographic).
		float t1 = ray.z > 1e-6 ? -origin.z * 0.99 / ray.z : RAY_END;
		end = start + direction * t1;
		end_t = t1 / end.w;
		end_q = 1.0 / end.w;
	}
	vec2 uv0 = start.xy / start.w * 0.5 + 0.5;
	vec2 uv1 = end.xy / end.w * 0.5 + 0.5;
	vec2 delta = uv1 - uv0;
	// Clipped to the screen.
	float s_screen = 1.0;
	for (int axis = 0; axis < 2; axis++) {
		if (delta[axis] > 1e-9) {
			s_screen = min(s_screen, (1.0 - uv0[axis]) / delta[axis]);
		} else if (delta[axis] < -1e-9) {
			s_screen = min(s_screen, -uv0[axis] / delta[axis]);
		}
	}
	float s_max = max(min(s_cap, s_screen), 0.0);
	float q0 = 1.0 / start.w;

	bool hit = false;
	bool occluded = false;
	bool valid = false;
	vec2 hit_uv = vec2(0.0);
	float hit_t = 0.0;
	vec2 valid_uv = vec2(0.0);
	vec2 last_uv = uv0;
	// Distances on screen in its height.
	vec2 aspect = vec2(float(textureSize(sunshine_clouds_reflection, 0).x) / float(textureSize(sunshine_clouds_reflection, 0).y), 1.0);
	float previous_s = 0.0;
	float previous_distance = length(origin);
	for (int i = 0; i < march_steps; i++) {
		float f = (float(i) + jitter) / (float(march_steps) - 1.0 + jitter);
		float s = s_max * f * f;
		vec2 uv = uv0 + delta * s;
		float t = s * end_t / ((1.0 - s) * q0 + s * end_q);
		float ray_distance = length(origin + ray * t);
		float scene = image_distance(uv);
		if (scene <= 0.0) {
			occluded = false;
			valid = false;
			break; // No image yet.
		}
		last_uv = uv;
		occluded = false;
		// What the pixel shows, if it's under the mirror (the surface below the reflective one,
		// seen through it: not in the reflection), is passed over.
		vec4 scene_view = INV_PROJECTION_MATRIX * vec4(uv * 2.0 - 1.0, 0.0, 1.0);
		vec3 scene_point = normalize(scene_view.xyz / scene_view.w) * scene;
		if (dot(scene_point - VERTEX, normal) <= 0.0) {
			previous_s = s;
			previous_distance = ray_distance;
			continue;
		}
		float near = min(ray_distance, previous_distance);
		float far = max(ray_distance, previous_distance);
		if (scene <= far) {
			float depth = scene >= far_distance ? 1e30 : thickness + thickness_scale * scene;
			if (scene >= near - depth) {
				// Halve the step until the surface's place is found.
				float low = previous_s;
				float high = s;
				for (int j = 0; j < refine_steps; j++) {
					float middle = (low + high) * 0.5;
					vec2 middle_uv = uv0 + delta * middle;
					float middle_t = middle * end_t / ((1.0 - middle) * q0 + middle * end_q);
					if (length(origin + ray * middle_t) > image_distance(middle_uv)) {
						high = middle;
					} else {
						low = middle;
					}
				}
				hit = true;
				hit_uv = uv0 + delta * high;
				hit_t = high * end_t / ((1.0 - high) * q0 + high * end_q);
				break;
			}
			occluded = true;
			// Hidden too far past the last valid sample: nothing to fill with, and the ray gives up.
			if (valid && hole_fill_distance > 0.0 && length((uv - valid_uv) * aspect) >= hole_fill_distance) {
				valid = false;
				break;
			}
		} else {
			// In front of what the pixel shows: a colour to fill holes with.
			valid = true;
			valid_uv = uv;
		}
		previous_s = s;
		previous_distance = ray_distance;
	}

	vec3 reflection = vec3(0.0);
	float weight = 0.0;
	float blur = roughness * roughness * 0.05;
	if (hit) {
		reflection = image_color(hit_uv, blur * hit_t / (hit_t + length(VERTEX)));
		weight = edge_fade(hit_uv, side_fade);
	} else if (hole_fill_distance > 0.0 && occluded && valid) {
		// The last valid sample's own pixel (its centre: not blended with the object's edge),
		// fading out with how far past it the ray ends, and at the screen's edges where either it
		// or the ray's end is.
		vec2 size = vec2(textureSize(sunshine_clouds_reflection, 0));
		vec2 uv = (floor(valid_uv * size) + 0.5) / size;
		reflection = textureLod(sunshine_clouds_reflection, uv, 0.0).rgb;
		weight = edge_fade(uv, side_fade) * edge_fade(last_uv, side_fade)
				* (1.0 - smoothstep(0.0, hole_fill_distance, length((last_uv - valid_uv) * aspect)));
	}

	float fresnel = fresnel_f0 + (1.0 - fresnel_f0) * pow(1.0 - clamp(dot(normal, to_camera), 0.0, 1.0), 5.0);

	ALBEDO = albedo;
	ROUGHNESS = roughness;
	METALLIC = 0.0;
	SPECULAR = clamp(sqrt(fresnel_f0 / 0.16), 0.0, 1.0) * (1.0 - weight);
	EMISSION = reflection * fresnel * weight * reflection_strength;
	ALPHA = 1.0;
}
