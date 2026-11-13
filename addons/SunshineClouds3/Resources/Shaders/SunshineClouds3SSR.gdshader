// Basic screen-space reflection material. A rough starting point: throws errors, needs a rewrite.
shader_type spatial;
render_mode depth_draw_always;

global uniform sampler2D sunshine_clouds_reflection : filter_linear, repeat_disable;

group_uniforms surface;
uniform vec3 albedo : source_color = vec3(0.02, 0.03, 0.035);
uniform float roughness : hint_range(0.0, 1.0) = 0.05;
uniform float fresnel_f0 : hint_range(0.0, 1.0) = 0.02;
uniform float reflection_strength : hint_range(0.0, 4.0) = 1.0;

group_uniforms ray_march;
uniform float march_distance : hint_range(1.0, 10000.0, 1.0) = 500.0;
uniform int march_steps : hint_range(4, 256) = 48;
uniform int refine_steps : hint_range(0, 16) = 6;
uniform float thickness : hint_range(0.0, 100.0) = 1.0;
uniform float screen_edge_fade : hint_range(0.0, 0.5) = 0.1;

float image_distance(vec2 uv) {
	ivec2 size = textureSize(sunshine_clouds_reflection, 0);
	ivec2 pixel = clamp(ivec2(uv * vec2(size)), ivec2(0), size - 1);
	return texelFetch(sunshine_clouds_reflection, pixel, 0).a;
}

bool on_screen(vec2 uv) {
	return all(greaterThanEqual(uv, vec2(0.0))) && all(lessThanEqual(uv, vec2(1.0)));
}

float edge_fade(vec2 uv) {
	vec2 to_edge = min(uv, 1.0 - uv);
	return clamp(min(to_edge.x, to_edge.y) / max(screen_edge_fade, 1e-4), 0.0, 1.0);
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
	vec2 aspect = vec2(1.0, float(textureSize(sunshine_clouds_reflection, 0).x) / float(textureSize(sunshine_clouds_reflection, 0).y));
	for (int i = 0; i < 8; i++) {
		float angle = float(i) * 0.785398;
		vec2 offset = vec2(cos(angle), sin(angle)) * radius * aspect * (i % 2 == 0 ? 1.0 : 0.5);
		color += textureLod(sunshine_clouds_reflection, clamp(uv + offset, vec2(0.0), vec2(1.0)), 0.0).rgb;
	}
	return color / 9.0;
}

void fragment() {
	vec3 normal = normalize(NORMAL);
	vec3 to_camera = normalize(-VERTEX);
	vec3 ray = reflect(-to_camera, normal);

	vec3 reflection = vec3(0.0);
	float weight = 0.0;
	float jitter = fract(52.9829189 * fract(dot(FRAGCOORD.xy, vec2(0.06711056, 0.00583715))));
	vec3 origin = VERTEX + normal * (0.002 * length(VERTEX));

	bool hit = false;
	float hit_t = 0.0;
	vec2 hit_uv = vec2(0.0);
	float previous_t = 0.0;
	for (int i = 0; i < march_steps; i++) {
		float f = (float(i) + jitter) / float(march_steps);
		float t = march_distance * f * f;
		vec3 position = origin + ray * t;
		if (position.z > -0.01) {
			break;
		}
		vec2 uv = view_to_uv(position, PROJECTION_MATRIX);
		if (!on_screen(uv)) {
			break;
		}
		float scene = image_distance(uv);
		if (scene <= 0.0) {
			break;
		}
		float ray_distance = length(position);
		if (ray_distance > scene && ray_distance - scene < thickness + (t - previous_t)) {
			// Halve the step until the surface's place is found.
			float low = previous_t;
			float high = t;
			for (int j = 0; j < refine_steps; j++) {
				float middle = (low + high) * 0.5;
				vec3 p = origin + ray * middle;
				if (length(p) > image_distance(view_to_uv(p, PROJECTION_MATRIX))) {
					high = middle;
				} else {
					low = middle;
				}
			}
			hit = true;
			hit_t = high;
			hit_uv = view_to_uv(origin + ray * high, PROJECTION_MATRIX);
			break;
		}
		previous_t = t;
	}

	float blur = roughness * roughness * 0.05;
	if (hit) {
		reflection = image_color(hit_uv, blur * hit_t / (hit_t + length(VERTEX)));
		weight = edge_fade(hit_uv) * (1.0 - smoothstep(0.8, 1.0, hit_t / march_distance));
	} else {
		vec4 clip = PROJECTION_MATRIX * vec4(ray, 0.0);
		if (clip.w > 1e-6) {
			vec2 uv = clip.xy / clip.w * 0.5 + 0.5;
			if (on_screen(uv) && image_distance(uv) >= march_distance) {
				reflection = image_color(uv, blur);
				weight = edge_fade(uv);
			}
		}
	}

	float fresnel = fresnel_f0 + (1.0 - fresnel_f0) * pow(1.0 - clamp(dot(normal, to_camera), 0.0, 1.0), 5.0);

	ALBEDO = albedo;
	ROUGHNESS = roughness;
	METALLIC = 0.0;
	SPECULAR = clamp(sqrt(fresnel_f0 / 0.16), 0.0, 1.0) * (1.0 - weight);
	EMISSION = reflection * fresnel * weight * reflection_strength;
	ALPHA = 1.0;
}
