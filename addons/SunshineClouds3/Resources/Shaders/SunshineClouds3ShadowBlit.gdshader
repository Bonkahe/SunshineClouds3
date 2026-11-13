shader_type texture_blit;
render_mode blend_disabled;

uniform sampler2D source_texture0 : hint_blit_source0;

// MODULATE (SunshineClouds3.gd's blit_params): rg = the shift into the map (which repeats) in texels
// over its resolution, b = where the edge fade starts (fraction of the way out to the edge), a = 1
// when the light has repeat off and its window is centred over the camera (else the map as it is).
void blit() {
	ivec2 resolution = textureSize(source_texture0, 0);
	ivec2 texel = ivec2(UV * vec2(resolution));
	float sunlight;
	if (MODULATE.a > 0.5) {
		ivec2 shift = ivec2(round(MODULATE.rg * vec2(resolution)));
		sunlight = texelFetch(source_texture0, (texel + shift) % resolution, 0).r;
		// Round, so the window's corners don't stick out: lit at the edge's midpoints and beyond.
		float edge = length(UV - 0.5) * 2.0;
		sunlight = mix(sunlight, 1.0, smoothstep(min(MODULATE.b, 0.999), 1.0, edge));
	} else {
		sunlight = texelFetch(source_texture0, texel, 0).r;
	}
	// The map's r is what the light is multiplied by; the projector multiplies by rgb * a.
	COLOR0 = vec4(vec3(sunlight), 1.0);
}
