Shader "Custom/Tesselation"
{
    Properties
    {
        [MainColor] _BaseColor("Base Color", Color) = (1, 1, 1, 1)
        [MainTexture] _BaseMap("Base Map", 2D) = "white" {}
        
        [KeywordEnum(Integer, FractionalOdd, FractionalEven, Pow2)]
        _Partitioning ("Partitioning Mode", Float) = 0
        _TesselationAmount("Tesselation Amount", Range(1.0, 64.0)) = 1.0
        _TesselationMap ("Tessellation Map", 2D) = "black" {} // will be also used to represent depressed snow
        _DisplacementAmount("Displacement Amount", Range(0.0, 0.5)) = 0.25
    }

    SubShader
    {
        Tags {
            "RenderType" = "Opaque"
            "RenderPipeline" = "UniversalPipeline"
        }

        Pass
        {
            Name "TesselationPass"
            
            HLSLPROGRAM

            #pragma vertex vert
            #pragma fragment frag
            #pragma hull hull
            #pragma domain domain
            #pragma shader_feature _PARTITIONING_INTEGER _PARTITIONING_FRACTIONALODD _PARTITIONING_FRACTIONALEVEN _PARTITIONING_POW2

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"

            // This represents data coming from the mesh
            // (CPU → GPU).
            struct Attributes
            {
                float4 positionOS : POSITION;
                float4 normalOS : NORMAL;
                float2 uv : TEXCOORD0;
            };

            // Final interpolated data passed to fragment shader
            // (output of vertex → input to fragment)
            struct Varyings
            {
                float4 positionHCS : SV_POSITION;
                float2 uv : TEXCOORD0;
            };

            // Data passed from vertex shader to hull/domain stages
            struct ControlPoint
            {
                float3 positionWS : INTERNALTESSPOS;
                float3 normalWS : NORMAL;
                float2 uv : TEXCOORD0;
            };

            // Tessellation factors (how much to subdivide)
            struct TesselationFactors
            {
                float edge[3] : SV_TessFactor;      // edge = how many times the edge will subdivide
                float inside : SV_InsideTessFactor; // inside^2 = how many new triangles will be created 
            };

            TEXTURE2D(_BaseMap);
            SAMPLER(sampler_BaseMap);
            sampler2D _TesselationMap;

            CBUFFER_START(UnityPerMaterial)
                half4 _BaseColor;
                float4 _BaseMap_ST;
                float _TesselationAmount;
                float _DisplacementAmount;
            CBUFFER_END

            ControlPoint vert(Attributes IN)
            {
                ControlPoint OUT;
                OUT.positionWS = TransformObjectToWorld(IN.positionOS.xyz);
                OUT.normalWS = TransformObjectToWorldNormal(IN.normalOS);
                OUT.uv = TRANSFORM_TEX(IN.uv, _BaseMap);
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

                // Shift vertices down where tesselated/texture is white
                float3 p0 = tex2Dlod(_TesselationMap, float4(uv, 0, 0));
                float factor = length(p0) / 3.0;
                positionWS.y -= factor * _DisplacementAmount;
                // Possible variation where it also pushes along the normal 
                // positionWS -= normalWS * factor * 0.25;
                
                // Convert to clip space for rasterization
                OUT.positionHCS = TransformWorldToHClip(positionWS);
                OUT.uv = uv;
                
                return OUT;
            }

            half4 frag(Varyings IN) : SV_Target
            {
                half4 color = SAMPLE_TEXTURE2D(_BaseMap, sampler_BaseMap, IN.uv) * _BaseColor;
                return color;
            }
            ENDHLSL
        }
    }
}
