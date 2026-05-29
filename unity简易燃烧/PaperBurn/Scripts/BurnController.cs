using UnityEngine;

/// <summary>
/// 燃烧控制器 — 自动管理动态燃烧遮罩的扩散。
/// 
/// 只需挂到任意带 Collider + Renderer 的 3D 物体上即可工作。
/// 不需要手动指定 Shader 或 Material。
/// 
/// 公开 API:
///   Ignite(RaycastHit)   — 从射线碰撞点点燃（鼠标点击等）
///   IgniteAtUV(Vector2)  — 直接在八面体 UV 空间点燃
///   StopBurning()        — 停止扩散，保留已烧毁区域
///   ResetBurn()          — 完全重置
/// </summary>
[RequireComponent(typeof(Renderer)), RequireComponent(typeof(Collider))]
public class BurnController : MonoBehaviour
{
    // ================================================================
    //  Inspector
    // ================================================================

    [Header("扩散参数")]
    [Tooltip("燃烧传播速度，值越大烧得越快")]
    [Range(0.01f, 0.3f)]
    public float spreadSpeed = 0.05f;

    [Tooltip("噪声对扩散速度的影响权重。0=完美圆形扩散，1+=边缘极不规则")]
    [Range(0f, 2f)]
    public float noiseInfluence = 0.6f;

    [Tooltip("初始着火点的半径大小（UV空间）")]
    [Range(0.005f, 0.1f)]
    public float igniteRadius = 0.03f;

    [Tooltip("每隔多少帧扩散一次。1=每帧，值越大性能越好但燃烧变慢")]
    [Range(1, 10)]
    public int skipFrames = 1;

    [Tooltip("扩散噪声纹理，留空也能用但边缘会比较圆整")]
    public Texture2D noiseTexture;

    [Header("点燃控制")]
    [Tooltip("是否在 Start 时自动从 autoIgniteUV 位置点燃")]
    public bool autoIgnite = false;

    [Tooltip("自动点燃的 UV 坐标，(0.5,0.5) 为物体中心方向")]
    public Vector2 autoIgniteUV = new Vector2(0.5f, 0.5f);

    [Header("限制条件")]
    [Tooltip("最大燃烧时长（秒），0=不限，烧到完为止")]
    [Range(0f, 120f)]
    public float burnMaxDuration = 0f;

    [Tooltip("最大燃烧半径（UV空间 0~1），0=不限。0.3 约烧到1/3范围就停")]
    [Range(0f, 1f)]
    public float burnMaxRadius = 0f;

    // ================================================================
    //  公开状态（只读）
    // ================================================================

    public RenderTexture burnMap { get; private set; }
    public bool          isBurning { get; private set; }
    public bool          isStopped { get; private set; }
    public float         estimatedRadius { get; private set; }

    // ================================================================
    //  内部
    // ================================================================

    private RenderTexture _tempRT;
    private Material      _burnMatInstance;
    private Material      _diffusionMatInstance;
    private Material      _originalSharedMat;
    private int           _frameCounter;
    private float         _burnStartTime;
    private bool          _cleanedUp;
    private bool          _isFlat;       // 平面网格用 XZ 投影，立体用八面体
    private const int     RT_SIZE = 512;

    // Shader property IDs
    private static readonly int ID_BurnMap        = Shader.PropertyToID("_BurnMap");
    private static readonly int ID_NoiseTex       = Shader.PropertyToID("_NoiseTex");
    private static readonly int ID_SpreadSpeed    = Shader.PropertyToID("_SpreadSpeed");
    private static readonly int ID_NoiseInfluence = Shader.PropertyToID("_NoiseInfluence");
    private static readonly int ID_IgniteUV       = Shader.PropertyToID("_IgniteUV");
    private static readonly int ID_IgniteRadius   = Shader.PropertyToID("_IgniteRadius");
    private static readonly int ID_IsIgnitePass   = Shader.PropertyToID("_IsIgnitePass");

    // ================================================================
    //  Lifecycle
    // ================================================================

    private void Start()
    {
        if (!TryInitMaterials()) return;
        InitRenderTextures();

        if (autoIgnite)
            IgniteAtUV(autoIgniteUV);
    }

    private void Update()
    {
        if (!isBurning || isStopped || _diffusionMatInstance == null)
            return;

        if (burnMaxDuration > 0f && Time.time - _burnStartTime >= burnMaxDuration)
            { StopBurning(); return; }
        if (burnMaxRadius > 0f && estimatedRadius >= burnMaxRadius)
            { StopBurning(); return; }

        _frameCounter++;
        if (_frameCounter % skipFrames != 0) return;

        _diffusionMatInstance.SetTexture(ID_BurnMap,        burnMap);
        _diffusionMatInstance.SetTexture(ID_NoiseTex,       noiseTexture);
        _diffusionMatInstance.SetFloat(ID_SpreadSpeed,      spreadSpeed);
        _diffusionMatInstance.SetFloat(ID_NoiseInfluence,   noiseInfluence);
        _diffusionMatInstance.SetFloat(ID_IsIgnitePass,     0f);

        Graphics.Blit(burnMap, _tempRT, _diffusionMatInstance);
        Graphics.Blit(_tempRT,  burnMap);

        estimatedRadius += (spreadSpeed * 0.02f) / skipFrames;
        estimatedRadius  = Mathf.Min(estimatedRadius, 1.0f);
    }

    private void OnDestroy() { Cleanup(); }
    private void OnDisable() { Cleanup(); }

    private void Cleanup()
    {
        if (_cleanedUp) return;
        _cleanedUp = true;
        RestoreMaterial();
        ReleaseRT();
    }

    // ================================================================
    //  初始化
    // ================================================================

    private bool TryInitMaterials()
    {
        // ① 燃烧 Shader
        var burnShader = Shader.Find("PaperBurn/BurnablePaper");
        if (burnShader == null)
        {
            Debug.LogError("BurnController: Shader 'PaperBurn/BurnablePaper' not found.", this);
            return false;
        }

        var renderer = GetComponent<Renderer>();
        _originalSharedMat = renderer.sharedMaterial;
        _burnMatInstance   = new Material(burnShader);

        CopyMainTexture(_originalSharedMat, _burnMatInstance);
        CopyMainColor(_originalSharedMat, _burnMatInstance);

        renderer.material = _burnMatInstance;

        // ② 扩散 Shader — 用 Shader.Find（兼容 Build）
        var diffShader = Shader.Find("Hidden/PaperBurn/BurnMapDiffusion");
        _diffusionMatInstance = diffShader != null ? new Material(diffShader) : null;
        if (_diffusionMatInstance == null)
        {
            Debug.LogError("BurnController: Shader 'Hidden/PaperBurn/BurnMapDiffusion' not found.", this);
            return false;
        }

        // ③ 检测是否为平面网格（Plane / Quad），切换映射模式
        _isFlat = IsFlatMesh();
        if (_isFlat)
            _burnMatInstance.EnableKeyword("_FLAT_MAPPING");
        else
            _burnMatInstance.DisableKeyword("_FLAT_MAPPING");

        return true;
    }

    private bool IsFlatMesh()
    {
        var mf = GetComponent<MeshFilter>();
        if (mf == null || mf.sharedMesh == null) return false;

        // Plane 网格 y 分量范围极小（所有顶点在 XZ 平面）
        var bounds = mf.sharedMesh.bounds;
        float minDim = Mathf.Min(bounds.size.x, bounds.size.y, bounds.size.z);
        float maxDim = Mathf.Max(bounds.size.x, bounds.size.y, bounds.size.z);

        // 如果最小维 < 最大维的 5%，判定为平面
        return maxDim > 0f && (minDim / maxDim) < 0.05f;
    }

    private void InitRenderTextures()
    {
        var wm = _isFlat ? TextureWrapMode.Clamp : TextureWrapMode.Repeat;

        burnMap = new RenderTexture(RT_SIZE, RT_SIZE, 0, RenderTextureFormat.RFloat)
        {
            filterMode = FilterMode.Bilinear,
            wrapMode   = wm
        };
        burnMap.Create();

        _tempRT = new RenderTexture(RT_SIZE, RT_SIZE, 0, RenderTextureFormat.RFloat)
        {
            filterMode = FilterMode.Bilinear,
            wrapMode   = wm
        };
        _tempRT.Create();

        ClearBurnMap();
        _burnMatInstance.SetTexture(ID_BurnMap, burnMap);
    }

    // ================================================================
    //  公开 API
    // ================================================================

    /// <summary>从射线碰撞点点燃，自动选择映射方式。</summary>
    public void Ignite(RaycastHit hit)
    {
        Vector3 local = transform.InverseTransformPoint(hit.point);

        if (_isFlat)
        {
            // 平面：XZ 坐标直接映射到 UV（与 Shader 中 _FLAT_MAPPING 一致）
            float u = local.x * 0.1f + 0.5f;  // Unity Plane mesh 顶点 [-5, 5]
            float v = local.z * 0.1f + 0.5f;
            IgniteAtUV(new Vector2(u, v));
        }
        else
        {
            // 立体：八面体映射
            IgniteAtUV(OctahedralUV(local.normalized));
        }
    }

    /// <summary>八面体映射——与 Shader 一致，将 3D 方向映射到 [0,1]² 无接缝。</summary>
    public static Vector2 OctahedralUV(Vector3 dir)
    {
        dir /= Mathf.Abs(dir.x) + Mathf.Abs(dir.y) + Mathf.Abs(dir.z);
        Vector2 uv;
        if (dir.y >= 0f)
            uv = new Vector2(dir.x, dir.z);
        else
            uv = new Vector2(
                (1f - Mathf.Abs(dir.z)) * Mathf.Sign(dir.x),
                (1f - Mathf.Abs(dir.x)) * Mathf.Sign(dir.z));
        return uv * 0.5f + Vector2.one * 0.5f;
    }

    /// <summary>直接在八面体 UV 空间点燃。</summary>
    public void IgniteAtUV(Vector2 uv)
    {
        if (_diffusionMatInstance == null) return;

        isBurning       = true;
        isStopped       = false;
        _burnStartTime  = Time.time;
        estimatedRadius = igniteRadius;

        _diffusionMatInstance.SetTexture(ID_BurnMap,      burnMap);
        _diffusionMatInstance.SetVector(ID_IgniteUV,      new Vector4(uv.x, uv.y, 0, 0));
        _diffusionMatInstance.SetFloat(ID_IgniteRadius,   igniteRadius);
        _diffusionMatInstance.SetFloat(ID_IsIgnitePass,   1f);

        Graphics.Blit(burnMap, _tempRT, _diffusionMatInstance);
        Graphics.Blit(_tempRT,  burnMap);

        _diffusionMatInstance.SetFloat(ID_IsIgnitePass,   0f);
    }

    public void StopBurning() => isStopped = true;

    public void ResetBurn()
    {
        ClearBurnMap();
        isBurning = isStopped = false;
        estimatedRadius = 0f;
        _frameCounter   = 0;
        _burnMatInstance.SetTexture(ID_BurnMap, burnMap);
    }

    // ================================================================
    //  内部
    // ================================================================

    private void ClearBurnMap()
    {
        var prev = RenderTexture.active;
        RenderTexture.active = burnMap;
        GL.Clear(true, true, Color.black);
        RenderTexture.active = prev;
    }

    private void ReleaseRT()
    {
        if (burnMap != null) { burnMap.Release(); burnMap = null; }
        if (_tempRT != null) { _tempRT.Release(); _tempRT = null; }
    }

    private void RestoreMaterial()
    {
        if (_originalSharedMat == null) return;
        var r = GetComponent<Renderer>();
        if (r != null && r.sharedMaterial != _originalSharedMat)
            r.material = _originalSharedMat;
        _originalSharedMat = null;
    }

    private static void CopyMainTexture(Material src, Material dst)
    {
        Texture tex = null;
        if      (src.HasProperty("_MainTex"))  tex = src.GetTexture("_MainTex");
        else if (src.HasProperty("_BaseMap"))   tex = src.GetTexture("_BaseMap");
        if (tex != null) dst.SetTexture("_MainTex", tex);
    }

    private static void CopyMainColor(Material src, Material dst)
    {
        Color c = Color.white;
        if      (src.HasProperty("_Color"))      c = src.GetColor("_Color");
        else if (src.HasProperty("_BaseColor"))   c = src.GetColor("_BaseColor");
        dst.SetColor("_MainColor", c);
    }
}
