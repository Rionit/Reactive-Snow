Shader "Custom/Tesselation"
{
    Properties
    {
        [MainColor] _BaseColor("Base Color", Color) = (1, 1, 1, 1)
        [MainTexture] _BaseMap("Base Map", 2D) = "white" {}
        _TesselationAmount("Tesselation Amount", Range(1.0, 64.0)) = 1.0
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

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"

            // This represents data coming from the mesh
            // (CPU → GPU).
            struct Attributes
            {
                float4 positionOS : POSITION;
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
                float2 uv : TEXCOORD0;
            };

            // Tessellation factors (how much to subdivide)
            struct TessFactors
            {
                float edge[3] : SV_TessFactor;      // edge = how many times the edge will subdivide
                float inside : SV_InsideTessFactor; // inside^2 = how many new triangles will be created 
            };

            TEXTURE2D(_BaseMap);
            SAMPLER(sampler_BaseMap);

            CBUFFER_START(UnityPerMaterial)
                half4 _BaseColor;
                float4 _BaseMap_ST;
                float _TesselationAmount;
            CBUFFER_END

            ControlPoint vert(Attributes IN)
            {
                ControlPoint OUT;
                OUT.positionWS = TransformObjectToWorld(IN.positionOS.xyz);
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
            [partitioning("integer")] // equal spacing with integer, new positions get rounded to integer
            [patchconstantfunc("patchConstantFunc")] // tells unity to use this function as patch function
            ControlPoint hull(InputPatch<ControlPoint, 3> patch, uint id : SV_OutputControlPointID)
            {
                return patch[id];
            }

            // Patch constant function:
            // Runs once per patch (triangle)
            // Defines how much tessellation to apply
            TessFactors patchConstantFunc(InputPatch<ControlPoint, 3> patch)
            {
                TessFactors factors;
                factors.edge[0] = factors.edge[1] = factors.edge[2] = factors.inside = _TesselationAmount;
                return factors;
            }

            // Domain shader:
            // Runs for each generated vertex after tessellation
            // Uses barycentric coordinates to interpolate data across the triangle
            // because they do not have any data at this point
            [domain("tri")]
            Varyings domain(TessFactors factors, OutputPatch<ControlPoint, 3> patch, float3 barycentricCoords : SV_DomainLocation)
            {
                Varyings OUT;
                float3 positionWS = patch[0].positionWS * barycentricCoords.x +
                    patch[1].positionWS * barycentricCoords.y +
                    patch[2].positionWS * barycentricCoords.z;

                float2 uv = patch[0].uv * barycentricCoords.x +
                    patch[1].uv * barycentricCoords.y +
                    patch[2].uv * barycentricCoords.z;

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
