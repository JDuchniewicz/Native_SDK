#version 460
#extension GL_EXT_ray_tracing : require
#extension GL_EXT_nonuniform_qualifier : enable
#extension GL_EXT_scalar_block_layout : enable

#define NUM_REFLECTION_RAYS 2
#define MAX_REFLECTION_DEPTH (NUM_REFLECTION_RAYS - 1)
#define MAX_REFLECTION_SHADOW_RAY_DEPTH 0
#define PI 3.1415926535897932384626433832795
#define ONE_OVER_PI (1.0 / PI)
#define REFLECTIONS_HIT_OFFSET 0
#define REFLECTIONS_MISS_INDEX 0
#define SHADOW_HIT_OFFSET 1
#define SHADOW_MISS_INDEX 1

struct ReflectionRayPayload
{
	vec3 Li;
	uint depth;
};

struct Vertex
{
  vec3 pos;
  vec3 nrm;
  vec2 texCoord;
  vec3 tangent;
};

struct Material
{
	ivec4 textureIndices;
	vec4 baseColor;
	vec4 metallicRoughness;
};

layout(location = 0) rayPayloadInEXT ReflectionRayPayload reflectionRayPayload;

layout(location = 1) rayPayloadEXT ReflectionRayPayload indirectReflectionRayPayload;
layout(location = 2) rayPayloadEXT bool visiblityRayPayload;

hitAttributeEXT vec2 attribs;

struct LightData
{
	highp vec4 vLightColor;
	highp vec4 vLightPosition;
	highp vec4 vAmbientColor;
};

layout(set = 2, binding = 1) uniform LightDataUBO
{
	LightData lightData;
};

layout(set = 2, binding = 2) buffer MateralDataBufferBuffer { Material materials[]; } ;
layout(set = 2, binding = 3) buffer MatIndexColorBuffer { int i[]; } matIndex[1];
layout(set = 2, binding = 4) uniform sampler2D textureSamplers[4];
layout(set = 2, binding = 5) uniform accelerationStructureEXT topLevelAS;
layout(set = 2, binding = 6, scalar) buffer Vertices { Vertex v[]; } vertices[1];
layout(set = 2, binding = 7) buffer Indices { uint i[]; } indices[1];

layout(set = 3, binding = 0) uniform samplerCube skyboxImage;
layout(set = 3, binding = 1) uniform samplerCube prefilteredImage;
layout(set = 3, binding = 2) uniform samplerCube irradianceImage;
layout(set = 3, binding = 3) uniform sampler2D brdfLUT;

// Normal Distribution function
// http://blog.selfshadow.com/publications/s2013-shading-course/karis/s2013_pbs_epic_notes_v2.pdf
mediump float d_GGX(mediump float dotNH, mediump float roughness)
{
	mediump float alpha = roughness * roughness;
	mediump float alpha2 = alpha * alpha;
	mediump float x = dotNH * dotNH * (alpha2 - 1.0) + 1.0;
	return alpha2 / max(PI * x * x, 0.0001);
}

mediump float g1(mediump float dotAB, mediump float k)
{
	return dotAB / max(dotAB * (1.0 - k) + k, 0.0001);
}

// Geometric Shadowing function
// http://blog.selfshadow.com/publications/s2013-shading-course/karis/s2013_pbs_epic_notes_v2.pdf
mediump float g_schlicksmithGGX(mediump float dotNL, mediump float dotNV, mediump float roughness)
{
	mediump float k = (roughness + 1.0);
	k = (k * k) / 8.;
	return g1(dotNL, k) * g1(dotNV, k);
}

// Fresnel function (Shlicks)
// http://blog.selfshadow.com/publications/s2013-shading-course/karis/s2013_pbs_epic_notes_v2.pdf
mediump vec3 f_schlick(mediump float cosTheta, mediump vec3 F0)
{
	return F0 + (vec3(1.0) - F0) * pow(2.0, (-5.55473 * cosTheta - 6.98316) * cosTheta);
}

mediump vec3 f_schlickR(mediump float cosTheta, mediump vec3 F0, mediump float roughness)
{
	return F0 + (max(vec3(1.0 - roughness), F0) - F0) * pow(1.0 - cosTheta, 5.0);
}

mediump vec3 directLighting(mediump vec3 P, mediump vec3 V, mediump vec3 N, mediump vec3 L, mediump vec3 F0, mediump vec3 albedo, mediump float metallic, mediump float roughness)
{
	// half vector
	mediump vec3 H = normalize(V + L);

	mediump float dotNL = clamp(dot(N, L), 0.0, 1.0);

	mediump vec3 color = vec3(0.0);

	// light contributed only if the angle between the normal and light direction is less than equal to 90 degree.
	if (dotNL > 0.0)
	{
		mediump float dotLH = clamp(dot(L, H), 0.0, 1.0);
		mediump float dotNH = clamp(dot(N, H), 0.0, 1.0);
		mediump float dotNV = clamp(dot(N, V), 0.0, 1.0);
		
		///-------- Specular BRDF: COOK-TORRANCE ---------
		// D = Microfacet Normal distribution.
		mediump float D = d_GGX(dotNH, roughness);

		// G = Geometric Occlusion
		mediump float G = g_schlicksmithGGX(dotNL, dotNV, roughness);

		// F = Surface Reflection
		mediump vec3 F = f_schlick(dotLH, F0);

		mediump vec3 spec = F * ((D * G) / (4.0 * dotNL * dotNV + 0.001/* avoid divide by 0 */));

		///-------- DIFFUSE BRDF ----------
		// kD factor out the lambertian diffuse based on the material's metallicity and fresenal.
		// e.g If the material is fully metallic than it wouldn't have diffuse.
		mediump vec3 kD =  (vec3(1.0) - F) * (1.0 - metallic);
		mediump vec3 diff = kD * albedo * ONE_OVER_PI;

		visiblityRayPayload = false;
		mediump float visibility = 1.0f;

		if (reflectionRayPayload.depth <= MAX_REFLECTION_SHADOW_RAY_DEPTH)
		{
			// Trace a shadow ray for this pixel
			visiblityRayPayload = false;

			uint  rayFlags = gl_RayFlagsOpaqueEXT | gl_RayFlagsTerminateOnFirstHitEXT;
			float tMin     = 0.001;
			float tMax     = 10000.0;
			
			vec3 origin = P + N * 0.1f;

			// Start the raytrace
			traceRayEXT(topLevelAS,		   // acceleration structure
						rayFlags,		   // rayFlags
						0xFF,			   // cullMask
						SHADOW_HIT_OFFSET, // sbtRecordOffset
						0,				   // sbtRecordStride
						SHADOW_MISS_INDEX, // missIndex
						origin.xyz,		   // ray origin
						tMin,			   // ray min range
						L.xyz,			   // ray direction
						tMax,			   // ray max range
						2				   // payload (location = 2)
				);

			visibility = float(visiblityRayPayload);
		}

		///-------- DIFFUSE + SPEC ------
		color += visibility * (diff + spec) * lightData.vLightColor.rgb * dotNL;// scale the final colour based on the angle between the light and the surface normal.
	}

	return color;
}

mediump vec3 prefilteredReflection(mediump float roughness, mediump vec3 R)
{
	// We need to detect where we need to sample from.
	const mediump float maxmip = float(3);

	mediump float cutoff = 1. / maxmip;

	if(roughness <= cutoff)
	{
		mediump float lod = roughness * maxmip;
		return mix(texture(skyboxImage, R).rgb, textureLod(prefilteredImage, R, 0.).rgb, lod);
	}
	else
	{
		mediump float lod = (roughness - cutoff) * maxmip / (1. - cutoff); // Remap to 0..1 on rest of mimpmaps
		return textureLod(prefilteredImage, R, lod).rgb;
	}
}

mediump vec3 indirectLightingIBL(mediump vec3 N, mediump vec3 V, mediump vec3 R, mediump vec3 albedo, mediump vec3 F0, mediump float metallic, mediump float roughness)
{
	mediump vec3 specularIR = prefilteredReflection(roughness, R);
	mediump vec2 brdf = texture(brdfLUT, vec2(clamp(dot(N, V), 0.0, 1.0), roughness)).rg;

	mediump vec3 F = f_schlickR(max(dot(N, V), 0.0), F0, roughness);

	mediump vec3 diffIR = texture(irradianceImage, N).rgb;
	mediump vec3 kD  = (vec3(1.0) - F) * (1.0 - metallic);// Diffuse factor   

	return albedo * kD  * diffIR + specularIR * (F * brdf.x + brdf.y);
}

mediump vec3 indirectLighting(mediump vec3 P, mediump vec3 N, mediump vec3 V, mediump vec3 R, mediump vec3 albedo, mediump vec3 F0, mediump float metallic, mediump float roughness)
{
	// Indirect Specular
	indirectReflectionRayPayload.Li = vec3(0.0f);
	indirectReflectionRayPayload.depth = reflectionRayPayload.depth + 1;
	
	uint  rayFlags = gl_RayFlagsOpaqueEXT;
	float tMin     = 0.001;
	float tMax     = 10000.0;

	vec3 origin = P + N * 0.1f;

	// Start the raytrace
	traceRayEXT(topLevelAS,				// acceleration structure
				rayFlags,				// rayFlags
				0xFF,					// cullMask
				REFLECTIONS_HIT_OFFSET, // sbtRecordOffset
				0,						// sbtRecordStride
				REFLECTIONS_MISS_INDEX, // missIndex
				origin.xyz,				// ray origin
				tMin,					// ray min range
				R.xyz,					// ray direction
				tMax,					// ray max range
				1						// payload (location = 1)
		);

	mediump vec3 specularIR = indirectReflectionRayPayload.Li;
	mediump vec2 brdf = texture(brdfLUT, vec2(clamp(dot(N, V), 0.0, 1.0), roughness)).rg;

	mediump vec3 F = f_schlickR(max(dot(N, V), 0.0), F0, roughness);

	// Indirect Diffuse
	mediump vec3 diffIR = texture(irradianceImage, N).rgb;
	mediump vec3 kD  = (vec3(1.0) - F) * (1.0 - metallic);

	return albedo * kD  * diffIR + specularIR * (F * brdf.x + brdf.y);
}

// If the ray hits anything we will fetch the material properties and shade this point as usual. 
// Image Based Lighting is used here so we can get some reflections within reflections without having to fire more rays.
void main()
{
	// Indices of the triangle
	ivec3 ind = ivec3(indices[nonuniformEXT(gl_InstanceID)].i[3 * gl_PrimitiveID + 0],   //
	                  indices[nonuniformEXT(gl_InstanceID)].i[3 * gl_PrimitiveID + 1],   //
	                  indices[nonuniformEXT(gl_InstanceID)].i[3 * gl_PrimitiveID + 2]);  //

	// Vertex of the triangle
	Vertex v0 = vertices[nonuniformEXT(gl_InstanceID)].v[ind.x];
	Vertex v1 = vertices[nonuniformEXT(gl_InstanceID)].v[ind.y];
	Vertex v2 = vertices[nonuniformEXT(gl_InstanceID)].v[ind.z];

	// Material of the object
    int matID = matIndex[nonuniformEXT(gl_InstanceID)].i[gl_PrimitiveID];
	
	const vec3 barycentrics = vec3(1.0 - attribs.x - attribs.y, attribs.x, attribs.y);
	
	// Computing the normal at hit position
	vec3 normal = v0.nrm * barycentrics.x + v1.nrm * barycentrics.y + v2.nrm * barycentrics.z;

	// Computing the coordinates of the hit position
    vec3 worldPos = v0.pos * barycentrics.x + v1.pos * barycentrics.y + v2.pos * barycentrics.z;

	// Computing the coordinates of the hit position
    vec2 texCoord = v0.texCoord * barycentrics.x + v1.texCoord * barycentrics.y + v2.texCoord * barycentrics.z;

	const Material mat = materials[nonuniformEXT(matID)];

	vec3 N = normalize(normal);	
	vec3 V = normalize(-gl_WorldRayDirectionEXT);
	vec3 R = normalize(reflect(-V, N));
	vec3 L = normalize(lightData.vLightPosition.xyz - worldPos);

	vec3 albedo;
	float roughness = max(mat.metallicRoughness.g, 0.01);
	float metallic = mat.metallicRoughness.r;

	// If a valid texture index does not exist, use the albedo color stored in the Material structure
	if (mat.textureIndices.x == -1)
		albedo = mat.baseColor.rgb;
	else  // If a valid texture index exists, use it to index into the image sampler array and sample the texture
		albedo = textureLod(textureSamplers[nonuniformEXT(mat.textureIndices.x)], texCoord, 0.0f).rgb;

	vec3 F0 = mix(vec3(0.04), albedo.rgb, metallic);

	vec3 Li = vec3(0.0f);

	// Direct Lighting
	Li += directLighting(worldPos, V, N, L, F0, albedo, metallic, roughness);

	// Indirect Lighting
	if (reflectionRayPayload.depth == MAX_REFLECTION_DEPTH)
		Li += indirectLightingIBL(N, V, R, albedo, F0 , metallic, roughness);
	else
		Li += indirectLighting(worldPos, N, V, R, albedo, F0 , metallic, roughness);

	reflectionRayPayload.Li = Li;
}
