Shader "Hidden/PaperBurn/BurnMapDiffusion"
{
    // ================================================================
    //  GPU 扩散 Shader — 用于在 RenderTexture 上传播燃烧状态。
    //
    //  两种模式（由 _IsIgnitePass 控制）：
    //    IgnitePass (=1):  在指定 UV 位置绘制初始着火点圆斑
    //    DiffusePass (=0): 每像素向已燃烧邻居靠近，受噪声扰动
    //
    //  遮罩值含义：
    //    0.0 = 完好未燃烧
    //    0~1 = 正在燃烧中（值越大越接近烧尽）
    //    1.0 = 完全烧尽
    // ================================================================

    Properties
    {
        _BurnMap        ("Burn Map",        2D)    = "black" {}
        _NoiseTex       ("Noise Texture",   2D)    = "white" {}
        _SpreadSpeed    ("Spread Speed",    Float) = 0.03
        _NoiseInfluence ("Noise Influence", Float) = 0.6
        _IgniteUV       ("Ignite UV",       Vector)= (0.5, 0.5, 0, 0)
        _IgniteRadius   ("Ignite Radius",   Float) = 0.03
        _IsIgnitePass   ("Is Ignite Pass",  Float) = 0
    }

    SubShader
    {
        Tags { "RenderType" = "Opaque" }
        LOD 100

        Pass
        {
            CGPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #pragma target 3.0
            #include "UnityCG.cginc"

            struct appdata
            {
                float4 vertex : POSITION;
                float2 uv     : TEXCOORD0;
            };

            struct v2f
            {
                float2 uv     : TEXCOORD0;
                float4 vertex : SV_POSITION;
            };

            sampler2D _BurnMap;
            float4    _BurnMap_TexelSize;   // (1/w, 1/h, w, h)
            sampler2D _NoiseTex;
            float     _SpreadSpeed;
            float     _NoiseInfluence;
            float4    _IgniteUV;            // (u, v, 0, 0)
            float     _IgniteRadius;
            float     _IsIgnitePass;

            v2f vert(appdata v)
            {
                v2f o;
                o.vertex = UnityObjectToClipPos(v.vertex);
                o.uv     = v.uv;
                return o;
            }

            float4 frag(v2f i) : SV_Target
            {
                float center = tex2D(_BurnMap, i.uv).r;

                // ====================================================
                // 模式 1: 着火点绘制（仅 IgniteAtUV 调用时执行一次）
                // ====================================================
                if (_IsIgnitePass > 0.5)
                {
                    float dist   = distance(i.uv, _IgniteUV.xy);
                    float ignite = 1.0 - smoothstep(0, _IgniteRadius, dist);

                    // 取已有值和着火点的最大值（已在燃烧的不清零）
                    return saturate(max(center, ignite));
                }

                // ====================================================
                // 模式 2: 扩散（每帧执行）
                // ====================================================

                // 已烧尽的不再变化
                if (center >= 1.0)
                    return 1.0;

                // 采样 8 邻域，找到燃烧值最大的邻居
                float2 ts = _BurnMap_TexelSize.xy;

                float n[8];
                n[0] = tex2D(_BurnMap, i.uv + float2(-ts.x,  ts.y)).r;
                n[1] = tex2D(_BurnMap, i.uv + float2( 0,     ts.y)).r;
                n[2] = tex2D(_BurnMap, i.uv + float2( ts.x,  ts.y)).r;
                n[3] = tex2D(_BurnMap, i.uv + float2(-ts.x,  0   )).r;
                n[4] = tex2D(_BurnMap, i.uv + float2( ts.x,  0   )).r;
                n[5] = tex2D(_BurnMap, i.uv + float2(-ts.x, -ts.y)).r;
                n[6] = tex2D(_BurnMap, i.uv + float2( 0,    -ts.y)).r;
                n[7] = tex2D(_BurnMap, i.uv + float2( ts.x, -ts.y)).r;

                float maxNeighbor = center;
                for (int j = 0; j < 8; j++)
                    maxNeighbor = max(maxNeighbor, n[j]);

                // 没有邻居在燃烧 → 不变
                if (maxNeighbor <= center)
                    return center;

                // 噪声扰动扩散速度（让边缘不规则）
                float noise      = tex2D(_NoiseTex, i.uv * 2.5).r;
                float noiseBoost = (noise - 0.5) * _NoiseInfluence;
                float spread     = _SpreadSpeed * (1.0 + noiseBoost);

                return saturate(center + spread);
            }
            ENDCG
        }
    }
}
