shader_type sky;
// The fog makes the entire skybox permanently the fog color otherwise.
render_mode disable_fog;

// SunshineClouds3's skybox panorama, laid out as SKY_COORDS.
uniform sampler2D skybox : filter_linear, repeat_enable, hint_default_black;
// Changed every frame: Godot only filters the sky again when a parameter changes.
uniform float refresh;

void sky() {
	COLOR = texture(skybox, SKY_COORDS).rgb;
}
