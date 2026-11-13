#[versions]

transmittance = "#define COMPUTE_TRANSMITTANCE";
direct_irradiance = "#define COMPUTE_DIRECT_IRRADIANCE";
single_scattering = "#define COMPUTE_SINGLE_SCATTERING";
scattering_density = "#define COMPUTE_SCATTERING_DENSITY";
indirect_irradiance = "#define COMPUTE_INDIRECT_IRRADIANCE";
multiple_scattering = "#define COMPUTE_MULTIPLE_SCATTERING";

#[compute]
#version 450

VERSION_DEFINES

// Bruneton's model.cc Model::Precompute passes (radiance mode, combined scattering textures), one compute
// kernel per version, one texel per invocation. model.cc's "blend" render targets are read, added to and written back.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

#include "AtmosphereHeader.glslinc"
#include "AtmosphereDefinitions.glslinc"
#define ATMOSPHERE_BINDING 0
#include "AtmosphereParameters.glslinc"
#include "AtmosphereFunctions.glslinc"

// x = scattering order.
layout(push_constant, std430) uniform PushConstants {
	ivec4 data;
} push;

#ifdef COMPUTE_TRANSMITTANCE
layout(rgba32f, set = 0, binding = 1) uniform restrict writeonly image2D transmittance_image;

void main() {
	ivec2 texel = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(texel, ivec2(TRANSMITTANCE_TEXTURE_WIDTH, TRANSMITTANCE_TEXTURE_HEIGHT)))) {
		return;
	}
	imageStore(transmittance_image, texel, vec4(ComputeTransmittanceToTopAtmosphereBoundaryTexture(ATMOSPHERE, vec2(texel) + 0.5), 1.0));
}
#endif

#ifdef COMPUTE_DIRECT_IRRADIANCE
layout(set = 0, binding = 1) uniform sampler2D transmittance_texture;
layout(rgba32f, set = 0, binding = 2) uniform restrict writeonly image2D delta_irradiance_image;
layout(rgba32f, set = 0, binding = 3) uniform restrict writeonly image2D irradiance_image;

void main() {
	ivec2 texel = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(texel, ivec2(IRRADIANCE_TEXTURE_WIDTH, IRRADIANCE_TEXTURE_HEIGHT)))) {
		return;
	}
	imageStore(delta_irradiance_image, texel, vec4(ComputeDirectIrradianceTexture(ATMOSPHERE, transmittance_texture, vec2(texel) + 0.5), 1.0));
	// The irradiance texture only holds the sky (indirect) irradiance.
	imageStore(irradiance_image, texel, vec4(0.0));
}
#endif

#ifdef COMPUTE_SINGLE_SCATTERING
layout(set = 0, binding = 1) uniform sampler2D transmittance_texture;
layout(rgba16f, set = 0, binding = 2) uniform restrict writeonly image3D delta_rayleigh_image;
layout(rgba16f, set = 0, binding = 3) uniform restrict writeonly image3D delta_mie_image;
layout(rgba16f, set = 0, binding = 4) uniform restrict writeonly image3D scattering_image;

void main() {
	ivec3 texel = ivec3(gl_GlobalInvocationID);
	vec3 delta_rayleigh;
	vec3 delta_mie;
	ComputeSingleScatteringTexture(ATMOSPHERE, transmittance_texture, vec3(texel) + 0.5, delta_rayleigh, delta_mie);
	imageStore(delta_rayleigh_image, texel, vec4(delta_rayleigh, 0.0));
	imageStore(delta_mie_image, texel, vec4(delta_mie, 0.0));
	imageStore(scattering_image, texel, vec4(delta_rayleigh, delta_mie.r));
}
#endif

#ifdef COMPUTE_SCATTERING_DENSITY
layout(set = 0, binding = 1) uniform sampler2D transmittance_texture;
layout(set = 0, binding = 2) uniform sampler3D single_rayleigh_scattering_texture;
layout(set = 0, binding = 3) uniform sampler3D single_mie_scattering_texture;
layout(set = 0, binding = 4) uniform sampler3D multiple_scattering_texture;
layout(set = 0, binding = 5) uniform sampler2D irradiance_texture;
layout(rgba16f, set = 0, binding = 6) uniform restrict writeonly image3D scattering_density_image;

void main() {
	ivec3 texel = ivec3(gl_GlobalInvocationID);
	vec3 scattering_density = ComputeScatteringDensityTexture(ATMOSPHERE, transmittance_texture,
			single_rayleigh_scattering_texture, single_mie_scattering_texture, multiple_scattering_texture,
			irradiance_texture, vec3(texel) + 0.5, push.data.x);
	imageStore(scattering_density_image, texel, vec4(scattering_density, 0.0));
}
#endif

#ifdef COMPUTE_INDIRECT_IRRADIANCE
layout(set = 0, binding = 2) uniform sampler3D single_rayleigh_scattering_texture;
layout(set = 0, binding = 3) uniform sampler3D single_mie_scattering_texture;
layout(set = 0, binding = 4) uniform sampler3D multiple_scattering_texture;
layout(rgba32f, set = 0, binding = 5) uniform restrict writeonly image2D delta_irradiance_image;
layout(rgba32f, set = 0, binding = 6) uniform restrict image2D irradiance_image;

void main() {
	ivec2 texel = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(texel, ivec2(IRRADIANCE_TEXTURE_WIDTH, IRRADIANCE_TEXTURE_HEIGHT)))) {
		return;
	}
	vec3 delta_irradiance = ComputeIndirectIrradianceTexture(ATMOSPHERE, single_rayleigh_scattering_texture,
			single_mie_scattering_texture, multiple_scattering_texture, vec2(texel) + 0.5, push.data.x);
	imageStore(delta_irradiance_image, texel, vec4(delta_irradiance, 1.0));
	imageStore(irradiance_image, texel, imageLoad(irradiance_image, texel) + vec4(delta_irradiance, 0.0));
}
#endif

#ifdef COMPUTE_MULTIPLE_SCATTERING
layout(set = 0, binding = 1) uniform sampler2D transmittance_texture;
layout(set = 0, binding = 2) uniform sampler3D scattering_density_texture;
layout(rgba16f, set = 0, binding = 3) uniform restrict writeonly image3D delta_multiple_scattering_image;
layout(rgba16f, set = 0, binding = 4) uniform restrict image3D scattering_image;

void main() {
	ivec3 texel = ivec3(gl_GlobalInvocationID);
	float nu;
	vec3 delta_multiple_scattering = ComputeMultipleScatteringTexture(ATMOSPHERE, transmittance_texture,
			scattering_density_texture, vec3(texel) + 0.5, nu);
	imageStore(delta_multiple_scattering_image, texel, vec4(delta_multiple_scattering, 0.0));
	imageStore(scattering_image, texel, imageLoad(scattering_image, texel) + vec4(delta_multiple_scattering / RayleighPhaseFunction(nu), 0.0));
}
#endif
