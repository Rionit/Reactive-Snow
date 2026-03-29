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
        _TesselationMap ("Tessellation Map", 2D) = "black" {} // will be also used to represent depressed snow
        
        [Header(Displacement Settings)]
        [Space]
        _DisplacementAmount("Displacement Amount", Range(0.0, 0.5)) = 0.25
        _NormalCorrectionOffset("Normal Correction Offset", Range(0.0, 0.1)) = 0.01
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
            // #pragma geometry geom

            #pragma multi_compile _ _MAIN_LIGHT_SHADOWS 
            #pragma multi_compile _ _MAIN_LIGHT_SHADOWS_CASCADE
            #pragma multi_compile _ _MAIN_LIGHT_SHADOWS_SCREEN

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

            sampler2D _TesselationMap;

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

                float3 p0 = tex2Dlod(_TesselationMap, float4(patch[0].uv, 0, 0));
                float3 p1 = tex2Dlod(_TesselationMap, float4(patch[1].uv, 0, 0));
                float3 p2 = tex2Dlod(_TesselationMap, float4(patch[2].uv, 0, 0));

                // Edge tess factors = average of the two vertices forming that edge
                // Needed for consistent vertex generation on the shared edge of two neighboring patches
                // Otherwise it creates holes/cracks when displaced downwards
                factors.edge[0] = (length(p1) + length(p2)) * 0.5 * _TesselationAmount + 1.0;
                factors.edge[1] = (length(p2) + length(p0)) * 0.5 * _TesselationAmount + 1.0;
                factors.edge[2] = (length(p0) + length(p1)) * 0.5 * _TesselationAmount + 1.0;

                // Inside factor = average of all
                factors.inside = (length(p0) + length(p1) + length(p2)) / 3.0 * _TesselationAmount + 1.0;

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

                float3 normalWS =
                patch[0].normalWS * barycentricCoords.x +
                patch[1].normalWS * barycentricCoords.y +
                patch[2].normalWS * barycentricCoords.z;
                normalWS = normalize(normalWS);

                float4 tangentWS =
                patch[0].tangentWS * barycentricCoords.x +
                patch[1].tangentWS * barycentricCoords.y +
                patch[2].tangentWS * barycentricCoords.z;
                tangentWS.xyz = normalize(tangentWS.xyz);

                // Shift vertices down where tesselated/texture is white
                float3 f = tex2Dlod(_TesselationMap, float4(uv, 0, 0));
                float factor = length(f) / 3.0;
                positionWS.y -= factor * _DisplacementAmount;
                // ^^^^^
                // Because we displacing the vertices, we need to recalculate
                // the normals. But we only have the control points of the mesh
                // and barycentric coords for this current tesselated vertex
                // so we have to sample around the vertex the displacement
                // values and calculate their new world positions
                // and calculate new normal from that.
                // No clue how else to do this xdd
                
                float e = _NormalCorrectionOffset;
                // Sample displacement values in a triangle around tesselated vertex
                float3 p0 = tex2Dlod(_TesselationMap, float4(uv - float2(e, e), 0, 0));
                float3 p1 = tex2Dlod(_TesselationMap, float4(uv - float2(e, 0), 0, 0));
                float3 p2 = tex2Dlod(_TesselationMap, float4(uv - float2(-e, e), 0, 0));
                float f0 = length(p0) / 3.0; // because rgb divide by three, could probably just take one channel
                float f1 = length(p1) / 3.0;
                float f2 = length(p2) / 3.0;
                // Take tangent and bi-tangent
                float3 dp1 = (patch[1].positionWS - float3(0, f1 * _DisplacementAmount, 0))
                           - (patch[0].positionWS - float3(0, f0 * _DisplacementAmount, 0));
                float3 dp2 = (patch[2].positionWS - float3(0, f2 * _DisplacementAmount, 0))
                           - (patch[0].positionWS - float3(0, f0 * _DisplacementAmount, 0));
                // Calculate new normal after displacement
                normalWS = normalize(cross(dp1, dp2));

                // Creates the TBN matrix
                VertexNormalInputs tbn = GetVertexNormalInputs(normalWS, tangentWS);

                OUT.tangent0 = tbn.tangentWS;
                OUT.tangent1 = tbn.bitangentWS;
                OUT.tangent2 = tbn.normalWS;

                OUT.worldPos = positionWS;

                // Convert to clip space for rasterization
                OUT.positionHCS = TransformWorldToHClip(positionWS);
                OUT.uv = TRANSFORM_TEX(uv, _BumpMap);

                return OUT;
            }

            /*
            // This works too but is not smooth
            // Maybe we really need to do it using geometry shader tho
            // (the normal recalculation)
            [maxvertexcount(3)]
            void geom(triangle Varyings input[3], inout TriangleStream<Varyings> triStream)
            {
                // Compute the true tessellated normal from displaced positions
                float3 edge1 = input[1].worldPos - input[0].worldPos;
                float3 edge2 = input[2].worldPos - input[0].worldPos;
                float3 normalWS = normalize(cross(edge1, edge2));

                // Update the TBN to use this new normal
                for (int i = 0; i < 3; i++)
                {
                    // Keep tangent aligned with displacement (you can keep domain's tangent or recompute)
                    input[i].tangent2 = normalWS;  // Update normal
                    triStream.Append(input[i]);
                }

                triStream.RestartStrip();
            }*/

            float GetDiff(half NDotL)
            {
                half wrap = _SSSWrap;
                return max(0,(NDotL + wrap) / (wrap + 1));
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

                // Adds ambient color (base color * 0.3) and returns the final color
                return half4(0.3h * _BaseColor.rgb + 0.7h * color, 1);
            }

            ENDHLSL
        }
    }
}