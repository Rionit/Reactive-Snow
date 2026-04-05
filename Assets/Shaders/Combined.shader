Shader "Custom/Combined"
{
    Properties
    {
        [Header(Main Settings)]
        [Space]
        [MainColor] _BaseColor("Base Color", Color) = (1, 1, 1, 1)

        [Header(Snow Material Settings)]
        [Space]
        [Normal] _BumpMap("Normal Map", 2D) = "bump" {}
        _Smoothness("Smoothness", Range(0, 1)) = 0.5
        _SpecularColor("Specular Color", Color) = (1, 1, 1, 1)
        _SSSColor("Subsurface Scattering Color", Color) = (0.8, 0.8, 1, 1)
        _SSSWrap("Subsurface Scattering Wrap", Range(0, 1)) = 0.8

        [Header(Tesselation Settings)]
        [Space]
        [KeywordEnum(Integer, FractionalOdd, FractionalEven, Pow2)]
        _Partitioning ("Partitioning Mode", Float) = 0
        _TesselationAmount("Tesselation Amount", Range(1.0, 64.0)) = 1.0
        [NoScaleOffset] _DepthMap ("Depth Map", 2D) = "black" {}
        
        [Header(Displacement Settings)]
        [Space]
        _DisplacementAmount("Displacement Amount", Range(0.0, 2.5)) = 0.25
        _NormalCorrectionOffset("Normal Correction Offset", Range(0.0, 0.02)) = 0.01
        _DarkeningAmount("Darkening Amount", Range(0.0, 1.0)) = 0.75
        
        [Header(Filter Settings)]
        [Space]
        _BlurAmount("Blur Amount", Range(0, 3)) = 1
        _TexelSize("Texel Size", Range(0, 1024)) = 1024
        [Toggle(_DEBUG_EDGES)] _DebugEdges("Debug Edges", Float) = 0
    }

    SubShader
    {
        Tags {
            "RenderType" = "Opaque"
            "RenderPipeline" = "UniversalPipeline"
        }

        Pass
        {
            Name "SnowTessellationDisplacementPass"

            HLSLPROGRAM

            #pragma vertex vert
            #pragma fragment frag
            #pragma hull hull
            #pragma domain domain

            #pragma multi_compile _ _MAIN_LIGHT_SHADOWS 
            #pragma multi_compile _ _MAIN_LIGHT_SHADOWS_CASCADE
            #pragma multi_compile _ _MAIN_LIGHT_SHADOWS_SCREEN
            #pragma shader_feature _DEBUG_EDGES

            #pragma shader_feature _PARTITIONING_INTEGER _PARTITIONING_FRACTIONALODD _PARTITIONING_FRACTIONALEVEN _PARTITIONING_POW2

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/BRDF.hlsl"

            // This represents data coming from the mesh
            // (CPU → GPU).
            struct Attributes
            {
                float4 positionOS : POSITION; // Object space position
                float3 normalOS : NORMAL;     // Object space normal
                float4 tangent : TANGENT;     // Tangent for normal mapping
                float2 uv : TEXCOORD0;        // UV coordinates
            };

            // Data passed from vertex shader to hull/domain stages
            struct ControlPoint
            {
                float3 positionWS : INTERNALTESSPOS;
                float3 normalWS : NORMAL;
                float4 tangentWS : TANGENT;
                float2 uv : TEXCOORD0;
            };

            // Final interpolated data passed to fragment shader
            struct Varyings
            {
                float4 positionHCS : SV_POSITION; // Clip space position
                float2 uv : TEXCOORD0;

                // TBN matrix rows
                float3 tangent0 : TEXCOORD1; 
                float3 tangent1 : TEXCOORD2;
                float3 tangent2 : TEXCOORD3;

                // World position for View dir
                float3 worldPos : TEXCOORD4;
            };

            // Tessellation factors (how much to subdivide)
            struct TesselationFactors
            {
                float edge[3] : SV_TessFactor;      // edge = how many times the edge will subdivide
                float inside : SV_InsideTessFactor; // inside^2 = how many new triangles will be created 
            };

            TEXTURE2D(_BumpMap);
            SAMPLER(sampler_BumpMap);

            TEXTURE2D(_DepthMap);
            SAMPLER(sampler_DepthMap);

            CBUFFER_START(UnityPerMaterial)
                half4 _BaseColor;
                float4 _BaseMap_ST;
                float4 _BumpMap_ST;

                half _Smoothness;
                half4 _SpecularColor;

                half4 _SSSColor;
                half _SSSWrap;

                float _TesselationAmount;
                float _DisplacementAmount;
                float _NormalCorrectionOffset;
                float _DarkeningAmount;

                float _TexelSize;
                float _BlurAmount;
            CBUFFER_END

            ControlPoint vert(Attributes IN)
            {
                ControlPoint OUT;
                OUT.positionWS = TransformObjectToWorld(IN.positionOS.xyz);
                OUT.normalWS = TransformObjectToWorldNormal(IN.normalOS);
                OUT.tangentWS = float4(TransformObjectToWorldDir(IN.tangent.xyz), IN.tangent.w);
                OUT.uv = TRANSFORM_TEX(IN.uv, _BumpMap);
                return OUT;
            }

            float SampleDepth(float2 uv)
            {
                return SAMPLE_TEXTURE2D_LOD(_DepthMap, sampler_DepthMap, float4(uv,0,0), 0).r;
            }

            // 3x3 Gaussian blur
            float BlurDepth(float2 uv, float2 texelSize)
            {
                float kernel[9] =
                {
                    1,2,1,
                    2,4,2,
                    1,2,1
                };

                float2 offsets[9] =
                {
                    float2(-1,-1), float2(0,-1), float2(1,-1),
                    float2(-1, 0), float2(0, 0), float2(1, 0),
                    float2(-1, 1), float2(0, 1), float2(1, 1)
                };

                float sum = 0;
                float weight = 0;

                for(int i = 0; i < 9; i++)
                {
                    float2 uvOffset = uv + offsets[i] * texelSize * _BlurAmount;
                    float s = SampleDepth(uvOffset);
                    sum += s * kernel[i];
                    weight += kernel[i];
                }

                return sum / weight;
            }

            // Sobel edge detection (X + Y)
            float EdgeStrength(float2 uv, float2 texelSize)
            {
                float gx[9] =
                {
                    -1,0,1,
                    -2,0,2,
                    -1,0,1
                };

                float gy[9] =
                {
                    -1,-2,-1,
                     0, 0, 0,
                     1, 2, 1
                };

                float2 offsets[9] =
                {
                    float2(-1,-1), float2(0,-1), float2(1,-1),
                    float2(-1, 0), float2(0, 0), float2(1, 0),
                    float2(-1, 1), float2(0, 1), float2(1, 1)
                };

                float sx = 0;
                float sy = 0;

                for(int i = 0; i < 9; i++)
                {
                    float2 uvOffset = uv + offsets[i] * texelSize * _BlurAmount;
                    float s = BlurDepth(uvOffset, texelSize);
                    sx += s * gx[i];
                    sy += s * gy[i];
                }

                return sqrt(sx * sx + sy * sy);
            }

            // Hull shader:
            // Runs once per control point (vertex of the patch)
            // @param patch - Input triangle
            // @param id - Vertex index on the triangle (which vertex in patch to output data for)
            [domain("tri")] // use triangle primitive for each input patch
            [outputcontrolpoints(3)] // how many vertices to ouput to create new patch, sicne we use triangles -> 3
            [outputtopology("triangle_cw")] // type of output patch primitive
            #if defined(_PARTITIONING_INTEGER)
            [partitioning("integer")] // equal spacing with integer, new positions get rounded to integer
            #elif defined(_PARTITIONING_FRACTIONALODD)
            [partitioning("fractional_odd")]
            #elif defined(_PARTITIONING_FRACTIONALEVEN)
            [partitioning("fractional_even")]
            #elif defined(_PARTITIONING_POW2)
            [partitioning("pow2")] // same as integer visually
            #endif
            [patchconstantfunc("patchConstantFunc")] // tells unity to use this function as patch function
            ControlPoint hull(InputPatch<ControlPoint, 3> patch, uint id : SV_OutputControlPointID)
            {
                return patch[id];
            }

            // Patch constant function:
            // Runs once per patch (triangle)
            // Defines how much tessellation to apply
            TesselationFactors patchConstantFunc(InputPatch<ControlPoint, 3> patch)
            {
                TesselationFactors factors;

                float2 texelSize = float2(1.0/_TexelSize, 1.0/_TexelSize);

                // 1.0 - uv.x because ortho camera looking up from bottom
                float2 uv0 = float2(1.0 - patch[0].uv.x, patch[0].uv.y);
                float2 uv1 = float2(1.0 - patch[1].uv.x, patch[1].uv.y);
                float2 uv2 = float2(1.0 - patch[2].uv.x, patch[2].uv.y);

                float2 mid01 = (uv0 + uv1) * 0.5;
                float2 mid12 = (uv1 + uv2) * 0.5;
                float2 mid20 = (uv2 + uv0) * 0.5;

                float2 center = (uv0 + uv1 + uv2) / 3.0;

                float e0 = EdgeStrength(mid12, texelSize);
                float e1 = EdgeStrength(mid20, texelSize);
                float e2 = EdgeStrength(mid01, texelSize);

                float c = EdgeStrength(center, texelSize);

                // Edge tess factors = sampled at edge midpoints
                factors.edge[0] = e0 * _TesselationAmount + 1.0;
                factors.edge[1] = e1 * _TesselationAmount + 1.0;
                factors.edge[2] = e2 * _TesselationAmount + 1.0;

                // Inside factor = sampled at triangle center
                factors.inside = c * _TesselationAmount + 1.0;

                return factors;
            }

            // Domain shader:
            // Runs for each generated vertex after tessellation
            // Uses barycentric coordinates to interpolate data across the triangle
            // because they do not have any data at this point
            [domain("tri")]
            Varyings domain(TesselationFactors factors, OutputPatch<ControlPoint, 3> patch, float3 barycentricCoords : SV_DomainLocation)
            {
                Varyings OUT;

                float3 positionWS =
                patch[0].positionWS * barycentricCoords.x +
                patch[1].positionWS * barycentricCoords.y +
                patch[2].positionWS * barycentricCoords.z;

                float2 uv =
                patch[0].uv * barycentricCoords.x +
                patch[1].uv * barycentricCoords.y +
                patch[2].uv * barycentricCoords.z;

                // These UV coords are used for displacement
                // map, because the ortho camera is looking
                // from the bottom
                float2 duv = float2(1.0 - uv.x, uv.y);

                float3 normalWS =
                patch[0].normalWS * barycentricCoords.x +
                patch[1].normalWS * barycentricCoords.y +
                patch[2].normalWS * barycentricCoords.z;

                float4 tangentWS =
                patch[0].tangentWS * barycentricCoords.x +
                patch[1].tangentWS * barycentricCoords.y +
                patch[2].tangentWS * barycentricCoords.z;
                tangentWS.xyz = normalize(tangentWS.xyz);

                // Shift vertices down where tesselated/texture is white
                float2 texelSize = float2(1.0/_TexelSize, 1.0/_TexelSize);
                float factor = BlurDepth(duv, texelSize);
                positionWS.y -= factor * _DisplacementAmount;
                // ^^^^^
                // Because we displacing the vertices, we need to recalculate
                // the normals.

                // Direction from current vertex uv to
                // control point uv's of the patch
                float2 v0 = patch[0].uv - uv;
                float2 v1 = patch[1].uv - uv;
                float2 v2 = patch[2].uv - uv;

                // Avoids division by zero and precision issues when the vector is very small
                float l0 = max(length(v0), 1e-6);
                float l1 = max(length(v1), 1e-6);
                float l2 = max(length(v2), 1e-6);

                // We have to divide by l, because normalize(e)
                // makes visual errors at poles
                float2 o0 = v0 * (_NormalCorrectionOffset / l0); 
                float2 o1 = v1 * (_NormalCorrectionOffset / l1);
                float2 o2 = v2 * (_NormalCorrectionOffset / l2);

                // Avoid overshooting outside of the current patch
                o0 = (l0 <= _NormalCorrectionOffset) ? v0 : o0;
                o1 = (l1 <= _NormalCorrectionOffset) ? v1 : o1;
                o2 = (l2 <= _NormalCorrectionOffset) ? v2 : o2;

                // Sample displacement values in a triangle around tessellated vertex
                float s0 = SAMPLE_TEXTURE2D_LOD(_DepthMap, sampler_DepthMap, float4(duv + o0, 0, 0), 0).r;
                float s1 = SAMPLE_TEXTURE2D_LOD(_DepthMap, sampler_DepthMap, float4(duv + o1, 0, 0), 0).r;
                float s2 = SAMPLE_TEXTURE2D_LOD(_DepthMap, sampler_DepthMap, float4(duv + o2, 0, 0), 0).r;

                // Take tangent and bi-tangent
                float3 t1 = (patch[1].positionWS - float3(0, s1 * _DisplacementAmount, 0))
                          - (patch[0].positionWS - float3(0, s0 * _DisplacementAmount, 0));
                float3 t2 = (patch[2].positionWS - float3(0, s2 * _DisplacementAmount, 0))
                          - (patch[0].positionWS - float3(0, s0 * _DisplacementAmount, 0));

                // Calculate new normal after displacement
                normalWS = normalize(cross(t1, t2));

                // Creates the TBN matrix
                VertexNormalInputs tbn = GetVertexNormalInputs(TransformWorldToObjectNormal(normalWS), tangentWS);

                OUT.tangent0 = tbn.tangentWS;
                OUT.tangent1 = tbn.bitangentWS;
                OUT.tangent2 = tbn.normalWS;

                OUT.worldPos = positionWS;

                // Convert to clip space for rasterization
                OUT.positionHCS = TransformWorldToHClip(positionWS);
                OUT.uv = TRANSFORM_TEX(uv, _BumpMap);
                // Makes the snow darker where displaced down
                // and looks more "wet"
                // (Delete me if stupid :D but imo looks nice - F.)
                OUT.tangent2.z = saturate(factor) * _DarkeningAmount;

                return OUT;
            }

            float GetDiff(half NDotL)
            {
                half wrap = _SSSWrap;
                return max(0,(NDotL + wrap) / (wrap + 1));
            }

            half4 GetEdgeDebug(float2 uv)
            {
                float2 texelSize = float2(1.0/_TexelSize, 1.0/_TexelSize);
                float2 duv = float2(1.0 - uv.x, uv.y);

                float edge = saturate(EdgeStrength(duv, texelSize) * 5.0);

                return half4(half3(1,0,0) * edge, edge);
            }

            half4 frag(Varyings IN) : SV_Target
            {
                // Applies the bump to the normal
                half3 normalTS = UnpackNormal(SAMPLE_TEXTURE2D(_BumpMap, sampler_BumpMap, IN.uv));
                half3x3 tangentToWorld = half3x3(IN.tangent0, IN.tangent1, IN.tangent2);
                half3 worldNormal = normalize(TransformTangentToWorld(normalTS, tangentToWorld));

                // Sets up the BRDF data from the main directional light
                Light mainLight = GetMainLight();
                BRDFData brdfData;
                InitializeBRDFData(_BaseColor.rgb, 0.3h, _SpecularColor.rgb, _Smoothness, _BaseColor.a, brdfData);

                // Sets up BRDF inputs
                half3 lightDir = normalize(mainLight.direction);
                half3 lightColor = mainLight.color;
                half3 worldViewDir = normalize(GetWorldSpaceViewDir(IN.worldPos));

                half NdotL = dot(worldNormal, lightDir);
                half attenuation = mainLight.distanceAttenuation * mainLight.shadowAttenuation;
                
                // Calculates direct BRDF value
                half3 brdf = DirectBRDF(brdfData, worldNormal, lightDir, worldViewDir);

                // Applies the BRDF color
                half3 directColor = (brdf * max(0,NdotL)) * lightColor * attenuation;

                // Adds SSS(Subsurface cattering) color using wrap (the tint is visible around the edge)
                half3 SSScolor = max(0, abs(GetDiff(NdotL)) - abs(NdotL))* _SSSColor.rgb;

                half3 color = directColor + SSScolor;

                #ifdef _DEBUG_EDGES
                    half4 edgeData = GetEdgeDebug(IN.uv);
                    half3 baseColor = 0.3h * _BaseColor.rgb + 0.7h * color;
                    return half4(lerp(baseColor, edgeData.rgb, edgeData.a), 1);
                #else
                    return half4(0.3h * _BaseColor.rgb + 0.7h * color, 1);
                #endif
                                
                // Adds ambient color (base color * 0.3) and returns the final color
                //return half4(0.3h * _BaseColor.rgb + 0.7h * color, 1);
            }

            ENDHLSL
        }
    }
}