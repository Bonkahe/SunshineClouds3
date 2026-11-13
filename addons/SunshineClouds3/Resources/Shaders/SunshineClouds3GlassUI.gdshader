// Frosted / refracting glass for UI (a canvas_item material), uses reflections from the sunshine clouds, though it honestly just needs the screen_texture

shader_type canvas_item;

#define USE_SCREEN_COLOR

#ifdef USE_SCREEN_COLOR
uniform sampler2D screen_texture : hint_screen_texture, filter_linear, repeat_disable;
#else
global uniform sampler2D sunshine_clouds_reflection : filter_linear, repeat_disable;
#endif

group_uniforms blur;
uniform float blur_power : hint_range(0.0, 64.0, 0.1) = 12.0;
uniform float near_blur : hint_range(0.0, 1.0) = 0.1;
uniform float blur_near_distance : hint_range(0.0, 10000.0, 0.1) = 5.0;
uniform float blur_far_distance : hint_range(0.0, 100000.0, 1.0) = 1000.0;
uniform float blur_distance_curve : hint_range(0.1, 4.0) = 1.0;
uniform int blur_samples : hint_range(1, 64) = 24;

group_uniforms distortion;
uniform sampler2D distortion_map : hint_normal, filter_linear_mipmap, repeat_enable;
uniform vec2 distortion_scale = vec2(1.0);
uniform float distortion_pixels : hint_range(0.0, 64.0, 0.1) = 0.0;
uniform float edge_refraction : hint_range(0.0, 64.0, 0.1) = 0.0;
uniform float edge_width : hint_range(1.0, 256.0, 0.1) = 24.0;

group_uniforms look;
uniform vec4 tint : source_color = vec4(1.0, 1.0, 1.0, 0.1);
uniform float brightness : hint_range(0.0, 4.0) = 1.0;
uniform float corner_radius : hint_range(0.0, 256.0, 0.1) = 0.0;
uniform float exposure : hint_range(0.0, 16.0) = 1.0;
uniform int tonemap : hint_enum("Linear", "Reinhard") = 0;
uniform float tonemap_white : hint_range(0.1, 16.0) = 1.0;
uniform bool hdr_2d = false;

vec3 linear_to_srgb(vec3 color) {
	color = clamp(color, vec3(0.0), vec3(1.0));
	return mix(1.055 * pow(color, vec3(1.0 / 2.4)) - 0.055, color * 12.92, lessThan(color, vec3(0.0031308)));
}

vec3 view_color(vec2 uv) {
#ifdef USE_SCREEN_COLOR
	return textureLod(screen_texture, uv, 0.0).rgb;
#else
	vec3 color = max(textureLod(sunshine_clouds_reflection, uv, 0.0).rgb * exposure, vec3(0.0));
	if (tonemap == 1) {
		color = color * (1.0 + color / (tonemap_white * tonemap_white)) / (1.0 + color);
	}
	return hdr_2d ? color : linear_to_srgb(color);
#endif
}

void fragment() {
	vec2 rect_size = 1.0 / max(abs(vec2(dFdx(UV.x), dFdy(UV.y))), vec2(1e-6));
	vec2 position = UV * rect_size;
	vec2 half_size = rect_size * 0.5;
	float radius = min(corner_radius, min(half_size.x, half_size.y));
	vec2 q = abs(position - half_size) - (half_size - radius);
	float outline = length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0) - radius;
	float coverage = clamp(0.5 - outline, 0.0, 1.0);

	vec2 offset = (texture(distortion_map, UV * distortion_scale).xy * 2.0 - 1.0) * distortion_pixels;
	float rim = clamp(1.0 + outline / edge_width, 0.0, 1.0);
	vec2 to_center = half_size - position;
	offset += (length(to_center) > 1e-3 ? normalize(to_center) : vec2(0.0)) * edge_refraction * rim * rim;
	vec2 uv = SCREEN_UV + offset * SCREEN_PIXEL_SIZE;

#ifndef USE_SCREEN_COLOR
	ivec2 image_size = textureSize(sunshine_clouds_reflection, 0);
	float distance = texelFetch(sunshine_clouds_reflection, clamp(ivec2(uv * vec2(image_size)), ivec2(0), image_size - 1), 0).a;
	float ramp = distance > 0.0 ? clamp((distance - blur_near_distance) / max(blur_far_distance - blur_near_distance, 1e-3), 0.0, 1.0) : 1.0;
	float blur_radius = blur_power * mix(near_blur, 1.0, pow(ramp, blur_distance_curve));
#else
	float blur_radius = blur_power;
#endif

	vec3 color = view_color(uv);
	if (blur_radius > 0.5 && blur_samples > 1) {
		float turn = 6.2831853 * fract(52.9829189 * fract(dot(FRAGCOORD.xy, vec2(0.06711056, 0.00583715))));
		color = vec3(0.0);
		float weights = 0.0;
		for (int i = 0; i < blur_samples; i++) {
			float r = sqrt((float(i) + 0.5) / float(blur_samples));
			float angle = float(i) * 2.3999632 + turn;
			float weight = 1.0 - 0.6 * r * r;
			vec2 tap = uv + vec2(cos(angle), sin(angle)) * r * blur_radius * SCREEN_PIXEL_SIZE;
			color += view_color(clamp(tap, vec2(0.0), vec2(1.0))) * weight;
			weights += weight;
		}
		color /= weights;
	}

	COLOR *= vec4(mix(color * brightness, tint.rgb, tint.a), coverage);
}
