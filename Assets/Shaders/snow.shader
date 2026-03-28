Shader "Custom/Snow"
{
    Properties
    {
        [MainColor] _BaseColor("Base Color", Color) = (1, 1, 1, 1)

        [Normal] _BumpMap("Normal Map", 2D) = "bump" {}
        _Smoothness("Smoothness", Range(0, 1)) = 0.5
        _SpecularColor("Specular Color", Color) = (1, 1, 1, 1)
        _SSSColor("Subsurface Scattering Color", Color) = (0.8, 0.8, 1, 1)
        _SSSWrap("Subsurface Scattering Wrap", Range(0, 1)) = 0.8
    }

    SubShader
    {
        Tags { "RenderPipeline" = "UniversalPipeline" }

        Pass
        {
            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag

            #pragma multi_compile _ _MAIN_LIGHT_SHADOWS 
            #pragma multi_compile _ _MAIN_LIGHT_SHADOWS_CASCADE
            #pragma multi_compile _ _MAIN_LIGHT_SHADOWS_SCREEN

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/BRDF.hlsl"

            struct Attributes
            {
                float4 positionOS : POSITION; // Object space position
                float2 uv : TEXCOORD0; // UV coordinates
                float4 tangent : TANGENT; // Tangent for normal mapping
                float3 normalOS : NORMAL; // Object space normal
            };

            struct Varyings
            {
                float4 positionHCS : SV_POSITION; // Clip space position
                float2 uv : TEXCOORD0; // UV coordinates
                
                // TBN matrix rows
                float3 tangent0 : TEXCOORD1; 
                float3 tangent1 : TEXCOORD2;
                float3 tangent2 : TEXCOORD3;

                // World position for View dir
                float3 worldPos : TEXCOORD4;
            };

            CBUFFER_START(UnityPerMaterial)
                half4 _BaseColor;
                half4 _BumpMap_ST;
                half _Smoothness;
                half4 _SpecularColor;
                half4 _SSSColor;
                half _SSSWrap;
            CBUFFER_END

            Varyings vert(Attributes IN)
            {
                Varyings OUT;
                OUT.positionHCS = TransformObjectToHClip(IN.positionOS.xyz);
                OUT.worldPos = TransformObjectToWorld(IN.positionOS.xyz);
                OUT.uv = TRANSFORM_TEX(IN.uv, _BumpMap);
                
                // Creates the TBN matrix
                VertexNormalInputs tbn = GetVertexNormalInputs(IN.normalOS, IN.tangent);
                
                OUT.tangent0 = tbn.tangentWS;
                OUT.tangent1 = tbn.bitangentWS;
                OUT.tangent2 = tbn.normalWS;

                return OUT;
            }

            TEXTURE2D(_BumpMap);
            SAMPLER(sampler_BumpMap);


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
