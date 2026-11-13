#[compute]
#version 450

// Tiling 3D curl noise for SunshineClouds3's curl_noise (build_curl_noise()). Three periodic gradient noise fBm
// potentials (psi) with analytic derivatives give curl(psi), a divergence free flow (Bridson et al. 2007,
// "Curl-Noise for Procedural Fluid Flow"). vorticity blends it with the first potential's gradient (pure sources
// and sinks); turbulence folds each octave (|noise|), creasing the potentials into sharp shear lines. Works in
// texture space (0..1 per axis), so it tiles on every axis at any resolution and ratio.
// Three stages: 0 finds the largest flow component, 1 sums squared components (relative to it) for the RMS, 2 writes
// the flow scaled to an RMS of FLOW_RMS into rgb (0.5 = none; peaks past 1 / FLOW_RMS sigma clip), a = 1. RMS
// normalising keeps the average push the same across settings.

layout(local_size_x = 4, local_size_y = 4, local_size_z = 4) in;

layout(rgba8, set = 0, binding = 0) uniform restrict writeonly image3D curl_image;
layout(set = 0, binding = 1, std430) restrict buffer Range {
	// Bits of the largest absolute flow component (positive floats order like their bits).
	uint max_component;
	// Sum of (component / max)^2 * SUM_SCALE over every voxel, added per workgroup: at most 64 * 3 * SUM_SCALE
	// per group, which fits a uint up to 512^3 voxels.
	uint sum_squares;
} flow_range;

#define FLOW_RMS 0.4
#define SUM_SCALE 8.0

shared float group_squares[64];

layout(push_constant, std430) uniform Settings {
	ivec3 size;
	int frequency; // noise cells per tile of the first octave
	int octaves;
	float roughness; // amplitude kept per octave
	float turbulence;
	float vorticity;
	uint seed;
	uint stage;
	uint pad0;
	uint pad1;
} settings;

// PCG3D hash (Jarzynski and Olano 2020).
uvec3 pcg3d(uvec3 v) {
	v = v * 1664525u + 1013904223u;
	v.x += v.y * v.z;
	v.y += v.z * v.x;
	v.z += v.x * v.y;
	v ^= v >> 16u;
	v.x += v.y * v.z;
	v.y += v.z * v.x;
	v.z += v.x * v.y;
	return v;
}

// Random gradient of a lattice corner, wrapped by the period so the noise tiles.
vec3 lattice_gradient(ivec3 corner, int period, uvec3 key) {
	uvec3 hash = pcg3d(uvec3(corner % period) + key);
	return vec3(hash) * (2.0 / 4294967295.0) - 1.0;
}

// Periodic gradient noise with its derivatives, x = value, yzw = d/dx, d/dy, d/dz (Inigo
// Quilez's noised, quintic interpolation). p is in lattice cells, 0..period.
vec4 gradient_noise(vec3 p, int period, uvec3 key) {
	ivec3 i = ivec3(floor(p));
	vec3 f = fract(p);
	vec3 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
	vec3 du = 30.0 * f * f * (f * (f - 2.0) + 1.0);

	vec3 ga = lattice_gradient(i + ivec3(0, 0, 0), period, key);
	vec3 gb = lattice_gradient(i + ivec3(1, 0, 0), period, key);
	vec3 gc = lattice_gradient(i + ivec3(0, 1, 0), period, key);
	vec3 gd = lattice_gradient(i + ivec3(1, 1, 0), period, key);
	vec3 ge = lattice_gradient(i + ivec3(0, 0, 1), period, key);
	vec3 gf = lattice_gradient(i + ivec3(1, 0, 1), period, key);
	vec3 gg = lattice_gradient(i + ivec3(0, 1, 1), period, key);
	vec3 gh = lattice_gradient(i + ivec3(1, 1, 1), period, key);

	float va = dot(ga, f - vec3(0.0, 0.0, 0.0));
	float vb = dot(gb, f - vec3(1.0, 0.0, 0.0));
	float vc = dot(gc, f - vec3(0.0, 1.0, 0.0));
	float vd = dot(gd, f - vec3(1.0, 1.0, 0.0));
	float ve = dot(ge, f - vec3(0.0, 0.0, 1.0));
	float vf = dot(gf, f - vec3(1.0, 0.0, 1.0));
	float vg = dot(gg, f - vec3(0.0, 1.0, 1.0));
	float vh = dot(gh, f - vec3(1.0, 1.0, 1.0));

	float value = va + u.x * (vb - va) + u.y * (vc - va) + u.z * (ve - va) + u.x * u.y * (va - vb - vc + vd)
			+ u.y * u.z * (va - vc - ve + vg) + u.z * u.x * (va - vb - ve + vf) + (-va + vb + vc - vd + ve - vf - vg + vh) * u.x * u.y * u.z;
	vec3 derivatives = ga + u.x * (gb - ga) + u.y * (gc - ga) + u.z * (ge - ga) + u.x * u.y * (ga - gb - gc + gd)
			+ u.y * u.z * (ga - gc - ge + gg) + u.z * u.x * (ga - gb - ge + gf) + (-ga + gb + gc - gd + ge - gf - gg + gh) * u.x * u.y * u.z
			+ du * (vec3(vb, vc, ve) - va + u.yzx * vec3(va - vb - vc + vd, va - vc - ve + vg, va - vb - ve + vf)
			+ u.zxy * vec3(va - vb - ve + vf, va - vb - vc + vd, va - vc - ve + vg) + u.yzx * u.zxy * (-va + vb + vc - vd + ve - vf - vg + vh));
	return vec4(value, derivatives);
}

// One potential: fBm doubling frequency per octave (whole periods, so it tiles), derivatives in texture space.
vec4 potential(vec3 uv, uint channel) {
	vec4 sum = vec4(0.0);
	float amplitude = 1.0;
	for (int octave = 0; octave < settings.octaves; octave++) {
		int period = settings.frequency << octave;
		uvec3 key = pcg3d(uvec3(settings.seed, channel, uint(octave)));
		vec4 n = gradient_noise(uv * float(period), period, key);
		n.yzw *= float(period);
		vec4 folded = vec4(abs(n.x), sign(n.x) * n.yzw);
		sum += amplitude * mix(n, folded, settings.turbulence);
		amplitude *= settings.roughness;
	}
	return sum;
}

void main() {
	ivec3 voxel = ivec3(gl_GlobalInvocationID);
	// No early out: every invocation has to reach the barrier in stage 1.
	bool inside = all(lessThan(voxel, settings.size));
	vec3 uv = (vec3(voxel) + 0.5) / vec3(settings.size);
	vec4 psi_x = potential(uv, 0u);
	vec4 psi_y = potential(uv, 1u);
	vec4 psi_z = potential(uv, 2u);
	// curl(psi) = (dpsi_z/dy - dpsi_y/dz, dpsi_x/dz - dpsi_z/dx, dpsi_y/dx - dpsi_x/dy).
	vec3 curl = vec3(psi_z.z - psi_y.w, psi_x.w - psi_z.y, psi_y.y - psi_x.z);
	vec3 flow = mix(psi_x.yzw, curl, settings.vorticity);
	float max_component = max(uintBitsToFloat(flow_range.max_component), 1e-6);

	if (settings.stage == 0u) {
		if (inside) {
			atomicMax(flow_range.max_component, floatBitsToUint(max(abs(flow.x), max(abs(flow.y), abs(flow.z)))));
		}
	} else if (settings.stage == 1u) {
		vec3 relative = flow / max_component;
		group_squares[gl_LocalInvocationIndex] = inside ? dot(relative, relative) : 0.0;
		barrier();
		if (gl_LocalInvocationIndex == 0u) {
			float sum = 0.0;
			for (int i = 0; i < 64; i++) {
				sum += group_squares[i];
			}
			atomicAdd(flow_range.sum_squares, uint(sum * SUM_SCALE + 0.5));
		}
	} else if (inside) {
		float voxels = float(settings.size.x) * float(settings.size.y) * float(settings.size.z);
		float rms = max_component * sqrt(float(flow_range.sum_squares) / SUM_SCALE / (voxels * 3.0));
		imageStore(curl_image, voxel, vec4(clamp(flow / max(rms, 1e-6) * FLOW_RMS, -1.0, 1.0) * 0.5 + 0.5, 1.0));
	}
}
