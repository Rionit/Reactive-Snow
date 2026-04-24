Shader "Hidden/Custom/LightDepthCapture"
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

            ZWrite On
            ZTest LEqual
            Cull Back

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

            float4x4 _LightDepthWorldToLight;
            float4x4 _LightDepthProjection;
            float _LightDepthNear;
            float _LightDepthFar;

            Varyings vert(Attributes IN)
            {
                Varyings OUT;
                float3 worldPos = TransformObjectToWorld(IN.positionOS.xyz);
                float4 lightView = mul(_LightDepthWorldToLight, float4(worldPos, 1.0));
                OUT.positionHCS = mul(_LightDepthProjection, lightView);
                float viewDepth = max(-lightView.z, 0.0);
                OUT.linearDepth = saturate((viewDepth - _LightDepthNear) / max(_LightDepthFar - _LightDepthNear, 1e-5));
                return OUT;
            }

            half4 frag(Varyings IN) : SV_Target
            {
                float depth01 = IN.linearDepth;
                return half4(depth01, depth01, depth01, 1.0);
            }
            ENDHLSL
        }
    }
}