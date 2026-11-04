#[vertex]
#version 450

// With 3D MSAA (SunshineClouds3.gd), the clouds go onto the multisampled colour, which compute
// can't write: the resolve (its msaa version) leaves what it would do to a pixel's colour as
// colour * a + b, once for the pixel's near surface and once for its far one where it has both
// (msaa_far_samples(), Common), and this applies them by blending, a sample at a time (each
// sample takes its own surface's): drawn twice, multiplying by a, then adding b. Godot's
// RenderingDevice has neither dual source blending (both in one draw) nor sample mask outputs
// (shading per pixel, a draw per surface). The transparent pass draws over the result, and Godot
// resolves it with the rest of the scene.

// One triangle over the screen.
void main() {
	vec2 position = vec2(float((gl_VertexIndex << 1) & 2), float(gl_VertexIndex & 2));
	gl_Position = vec4(position * 2.0 - 1.0, 0.0, 1.0);
}

#[fragment]
#version 450

// The resolve's colour * a + b per surface, as halves: x = a.rg, y = (a.b, b.r), z = b.gb. The near
// texture's w holds which samples are on the far surface (a bit each).
layout(set = 0, binding = 0) uniform usampler2D near_texture;
layout(set = 0, binding = 1) uniform usampler2D far_texture;

// The draw adding b; the other multiplies by a.
layout(constant_id = 0) const bool ADD = false;

layout(location = 0) out vec4 frag_color;

void main() {
	ivec2 pixel = ivec2(gl_FragCoord.xy);
	uvec4 packed = texelFetch(near_texture, pixel, 0);
	if (((packed.w >> uint(gl_SampleID)) & 1u) != 0u) {
		packed = texelFetch(far_texture, pixel, 0);
	}
	if (ADD) {
		frag_color = vec4(unpackHalf2x16(packed.y).y, unpackHalf2x16(packed.z), 0.0);
	} else {
		frag_color = vec4(unpackHalf2x16(packed.x), unpackHalf2x16(packed.y).x, 1.0);
	}
}
