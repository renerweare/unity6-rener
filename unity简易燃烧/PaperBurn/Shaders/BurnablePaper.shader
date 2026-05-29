Shader "PaperBurn/BurnablePaper"
{
    Properties
    {
        [Header(Base Textures)]
        _MainTex ("Front", 2D) = "white" {}
        _MainColor ("Tint", Color) = (1,1,1,1)
        _BackTex ("Back", 2D) = "white" {}

        [Header(Burn)]
        _BurnMap ("Burn Map", 2D) = "black" {}
        _NoiseTex ("Noise (optional)", 2D) = "white" {}
        _BurnSize ("Burn Edge Width", Range(0.01, 0.5)) = 0.1
        _NoiseStrength ("Noise Amount", Range(0, 0.5)) = 0.12

        [Header(Colors)]
        _EdgeColor ("Ember Glow", Color) = (1.0, 0.3, 0.02, 1.0)
        _CharColor ("Char Black", Color) = (0.05, 0.02, 0.01, 1.0)
        _EmberPower ("Ember Intensity", Range(0.5, 10)) = 3.0

        [Header(Curl)]
        _CurlAmount ("Curl Strength", Range(0, 0.5)) = 0.05
    }

    SubShader
    {
        Tags { "RenderType" = "TransparentCutout" "RenderPipeline" = "UniversalPipeline" "Queue" = "AlphaTest" }

        HLSLINCLUDE
        #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
        #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Lighting.hlsl"

        CBUFFER_START(UnityPerMaterial)
            float4 _MainTex_ST;
            float4 _BackTex_ST;
            float4 _MainColor;
            float  _BurnSize;
            float  _NoiseStrength;
            float4 _EdgeColor;
            float4 _CharColor;
            float  _EmberPower;
            float  _CurlAmount;
        CBUFFER_END

        TEXTURE2D(_MainTex);   SAMPLER(sampler_MainTex);
        TEXTURE2D(_BackTex);   SAMPLER(sampler_BackTex);
        TEXTURE2D(_BurnMap);   SAMPLER(sampler_BurnMap);
        TEXTURE2D(_NoiseTex);  SAMPLER(sampler_NoiseTex);

        struct Attributes
        {
            float4 positionOS : POSITION;
            float3 normalOS   : NORMAL;
            float4 tangentOS  : TANGENT;
            float2 uv         : TEXCOORD0;
        };

        struct Varyings
        {
            float4 positionCS : SV_POSITION;
            float2 uv         : TEXCOORD0;  // mesh UV, 用于 _MainTex
            float2 burnUV     : TEXCOORD1;  // 八面体映射 UV, 用于 _BurnMap
            float3 positionWS : TEXCOORD2;
            float3 normalWS   : TEXCOORD3;
        };

        // ============================================================
        //  八面体映射 — 将 3D 方向 连续映射到 [0,1]² 正方形，无接缝
        //  参数 dir: 单位方向向量（物体局部空间，从中心指向表面）
        //  返回:     [0,1]² 连续坐标
        // ============================================================
        float2 OctahedralUV(float3 dir)
        {
            dir /= dot(abs(dir), float3(1, 1, 1));
            float2 uv;
            if (dir.y >= 0)
                uv = dir.xz;
            else
                uv = (1.0 - abs(dir.zx)) * sign(dir.xz);
            return uv * 0.5 + 0.5;
        }

        // ---- 平滑程序噪声 ----
        float Hash21(float2 p)
        {
            p = frac(p * float2(443.897, 441.423));
            p += dot(p, p.yx + 19.19);
            return frac(p.x * p.y);
        }
        float ValueNoise(float2 p)
        {
            float2 i = floor(p);
            float2 f = frac(p);
            f = f * f * (3.0 - 2.0 * f);
            float a = Hash21(i);
            float b = Hash21(i + float2(1, 0));
            float c = Hash21(i + float2(0, 1));
            float d = Hash21(i + float2(1, 1));
            return lerp(lerp(a, b, f.x), lerp(c, d, f.x), f.y);
        }
        float FbmNoise(float2 p, int octaves)
        {
            float v = 0.0;
            float a = 0.5;
            float2 shift = float2(100, 100);
            for (int j = 0; j < 4; j++)
            {
                if (j >= octaves) break;
                v += a * ValueNoise(p + shift);
                p *= 2.0;
                a *= 0.5;
            }
            return v;
        }
        float BurnJitter(float2 uv, float burnValue, out float mask)
        {
            float n = FbmNoise(uv * 14.0 + _Time.y * 0.12, 3);
            float j = (n - 0.44) * 2.0;
            mask    = saturate((burnValue - 0.15) * 30.0);
            return j * mask;
        }

        // ---- 顶点 ----
        Varyings PaperVert(Attributes input, bool isFrontFace)
        {
            Varyings output;

            // 根据 keyword 选择映射方式
            #ifdef _FLAT_MAPPING
                // 平面投影：XZ 坐标直接映射到 UV（适用于 Plane/Quad）
                // Unity Plane mesh 顶点范围 [-5, 5]，除以 10 映射到 [0,1]
                output.burnUV = input.positionOS.xz * 0.1 + 0.5;
            #else
                // 八面体映射：方向 → 无接缝 UV（适用于球体/立方体等立体）
                float3 localDir = normalize(input.positionOS.xyz);
                output.burnUV   = OctahedralUV(localDir);
            #endif

            float burnValue = SAMPLE_TEXTURE2D_LOD(_BurnMap, sampler_BurnMap, output.burnUV, 0).r;
            float curlFactor = burnValue * (1.0 - burnValue) * _CurlAmount;

            input.positionOS.xyz += input.normalOS * curlFactor * (isFrontFace ? 1.0 : -1.0);

            VertexPositionInputs vpi = GetVertexPositionInputs(input.positionOS.xyz);
            VertexNormalInputs   vni = GetVertexNormalInputs(input.normalOS, input.tangentOS);

            output.positionCS = vpi.positionCS;
            output.uv         = input.uv;      // mesh UV for _MainTex
            output.positionWS = vpi.positionWS;
            output.normalWS   = isFrontFace ? vni.normalWS : -vni.normalWS;

            return output;
        }

        // ---- 片段 ----
        float4 PaperFrag(Varyings input, bool isFrontFace) : SV_Target
        {
            // 用八面体 UV 采样燃烧遮罩 —— 彻底无接缝
            float burnValue = SAMPLE_TEXTURE2D(_BurnMap, sampler_BurnMap, input.burnUV).r;

            float jMask;
            float j = BurnJitter(input.burnUV * 8.0, burnValue, jMask) * _NoiseStrength;

            float holeEnd    = 1.0 - _BurnSize * 0.1;
            float charStart  = 1.0 - _BurnSize * 0.9 + j * 0.5;
            float emberStart = 1.0 - _BurnSize * 2.8 + j;
            float heatStart  = 1.0 - _BurnSize * 5.0;

            // 用原始 UV 采样物体自身的贴图，并应用原始颜色 tint
            float4 mainColor = SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, input.uv) * _MainColor;
            float4 result;
            float  emissive = 0.0;

            if (burnValue >= holeEnd)
            {
                discard;
            }
            else if (burnValue >= charStart)
            {
                float  t = (burnValue - charStart) / (holeEnd - charStart);
                float4 col = _CharColor;
                col.a = 1.0 - t;
                result = col;
                emissive = (1.0 - t) * 0.3;
                if (result.a < 0.02) discard;
            }
            else if (burnValue >= emberStart)
            {
                float t = (burnValue - emberStart) / (charStart - emberStart);
                result = lerp(_EdgeColor * _EmberPower, _CharColor, t);
                result = lerp(mainColor * _EmberPower * 0.3, result, saturate(t * 2.0));
                result.a = 1.0;
                emissive = (1.0 - t) * 1.5;
            }
            else if (burnValue >= heatStart)
            {
                float t = (burnValue - heatStart) / (emberStart - heatStart);
                result = lerp(mainColor, _EdgeColor * (_EmberPower * 0.5), t);
                result.a = 1.0;
                emissive = t * 0.6;
            }
            else
            {
                result = mainColor;
            }

            Light light = GetMainLight();
            float NdotL = saturate(dot(normalize(input.normalWS), normalize(light.direction)));
            float lighting = 0.3 + NdotL * 0.7;
            result.rgb *= lighting;
            result.rgb += _EdgeColor.rgb * emissive;

            return result;
        }
        ENDHLSL

        // Pass 1: 正面
        Pass
        {
            Name "FrontFace"
            Tags { "LightMode" = "UniversalForward" }
            Cull Back
            ZWrite On
            HLSLPROGRAM
            #pragma vertex FrontVert
            #pragma fragment FrontFrag
            #pragma target 3.5
            #pragma multi_compile _ _MAIN_LIGHT_SHADOWS
            #pragma multi_compile _ _FLAT_MAPPING
            Varyings FrontVert(Attributes input) { return PaperVert(input, true); }
            float4   FrontFrag(Varyings v) : SV_Target { return PaperFrag(v, true); }
            ENDHLSL
        }

        // Pass 2: 背面
        Pass
        {
            Name "BackFace"
            Tags { "LightMode" = "UniversalForward" }
            Cull Front
            ZWrite On
            HLSLPROGRAM
            #pragma vertex BackVert
            #pragma fragment BackFrag
            #pragma target 3.5
            #pragma multi_compile _ _MAIN_LIGHT_SHADOWS
            #pragma multi_compile _ _FLAT_MAPPING
            Varyings BackVert(Attributes input) { return PaperVert(input, false); }
            float4   BackFrag(Varyings v) : SV_Target { return PaperFrag(v, false); }
            ENDHLSL
        }
    }
    FallBack "Universal Render Pipeline/Unlit"
}
