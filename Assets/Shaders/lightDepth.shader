Shader "Custom/LightDepth"
{
 SubShader
    {
        Tags
        {
            "RenderPipeline" = "UniversalPipeline"
        }

        Pass
        {
            Name "LightDepth"
            Tags { "LightMode" = "UniversalForward" }

            ZWrite On
            ZTest LEqual

            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"

            struct Attributes
            {
                float4 positionOS : POSITION;
            };

            struct Varyings
            {
                float4 positionHCS : SV_POSITION;
                float linearDepth : TEXCOORD0;
            };


            float4x4 _WorldToLight;
            float4x4 _LightProjection;

            Varyings vert(Attributes IN)
            {
                Varyings OUT;
                float3 worldPos = TransformObjectToWorld(IN.positionOS.xyz);
                float4 lightView = mul(_LightProjection, mul(_WorldToLight, float4(worldPos, 1.0)));
                OUT.positionHCS = lightView;

                half viewDepth = max(1.0/lightView.z, 0.0);
                OUT.linearDepth = viewDepth;
                return OUT;
            }

            half4 frag(Varyings IN) : SV_Target
            {
                return half4(IN.linearDepth, IN.linearDepth, IN.linearDepth, 1.0);
            }
            ENDHLSL
        }
    }
}