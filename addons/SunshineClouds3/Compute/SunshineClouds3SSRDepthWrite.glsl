#[vertex]
#version 450

// SunshineClouds3SSRDepth.glsl's mask into the depth buffer (a depth-stencil attachment, which
// compute can't write): one triangle over the view, depth test always, depth written where the
// mask has a depth. restore writes 0 there instead (back to sky, after the opaque pass).

void main() {
	vec2 corner = vec2((gl_VertexIndex << 1) & 2, gl_VertexIndex & 2);
	gl_Position = vec4(corner * 2.0 - 1.0, 0.0, 1.0);
}

#[fragment]
#version 450

layout(set = 0, binding = 0) uniform sampler2D mask_texture;

layout(push_constant, std430) uniform Push {
	int restore;
	int pad_0;
	int pad_1;
	int pad_2;
} push;

void main() {
	float depth = texelFetch(mask_texture, ivec2(gl_FragCoord.xy), 0).r;
	if (depth <= 0.0) {
		discard;
	}
	gl_FragDepth = push.restore != 0 ? 0.0 : depth;
}
