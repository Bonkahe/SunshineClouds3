shader_type texture_blit;
render_mode blend_disabled;

uniform sampler2D source_texture0 : hint_blit_source0;

void blit() {
	// The map's r is what the light is multiplied by; the projector multiplies by rgb * a.
	COLOR0 = vec4(vec3(texture(source_texture0, UV).r), 1.0);
}
