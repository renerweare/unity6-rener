# PaperBurn — 通用 3D 物体燃烧系统 (URP)

只需挂一个脚本，任意 3D 物体就能燃烧。

---

## 快速开始

1. 场景中放一个带 `Collider` 的 3D 物体（Cube、Sphere、Plane 等）
2. 挂 `BurnController` 组件
3. Camera 挂 `MouseClickIgniter` 组件
4. **Play → 鼠标点击物体 → 燃烧**

不需要手动设置 Shader 或 Material。

---

## 原理概述

```
着火点 → GPU 扩散 (RenderTexture) → Shader 四层着色 → 画面
                 ↑                          ↑
           每帧 8 邻域扩散            burnMap=0 完好
           + 噪声扰动不规则           burnMap≈0.5~0.7 余烬发光
                                     burnMap≈0.7~0.9 炭化黑边
                                     burnMap>0.9  透明孔洞 (discard)
```

燃烧状态是一张 **512×512 浮点 RenderTexture**，每个像素 ∈ [0, 1]：
- 0 = 完好
- 0→1 = 逐渐烧尽
- 1 = 完全烧尽，Fragment Shader 直接 `discard` 产生孔洞

映射方式按物体形状自动选择：

| 物体类型 | 映射 | 原理 |
|:---:|------|------|
| 立体 (Sphere/Cube) | 八面体映射 | `normalize(localPos)` → 连续 UV，无接缝 |
| 平面 (Plane/Quad) | XZ 平面投影 | `pos.xz * 0.1 + 0.5`，直接映射 |

---

## 文件结构

```
Assets/PaperBurn/
├── BurnController.cs         核心：RT 管理 + 扩散驱动 + 材质替换
├── MouseClickIgniter.cs      辅助：鼠标点击点燃
├── BurnFlameParticles.cs     可选：火焰粒子跟随
├── README.md
├── Shaders/
│   ├── BurnablePaper.shader   渲染：八面体/平面映射 + 四层着色 + 卷曲
│   └── BurnMapDiffusion.shader GPU：扩散方程 + 噪声加速
├── Materials/                 (材质由脚本自动创建，目录保留备用)
└── VFX/                       (预留)
```

---

## BurnController 参数

在 Inspector 中鼠标悬停每个参数可看 Tooltip。

| 类别 | 参数 | 默认 | 说明 |
|------|------|:---:|------|
| 扩散 | `spreadSpeed` | 0.05 | 传播速度，越大越快 |
| | `noiseInfluence` | 0.6 | 噪声强度，0=圆形，1+=极不规则 |
| | `igniteRadius` | 0.03 | 初始着火点大小 |
| | `skipFrames` | 1 | 隔 N 帧扩散一次，省性能 |
| | `noiseTexture` | 空 | 扩散噪声图，留空也能用 |
| 点燃 | `autoIgnite` | false | 是否 Start 时自动点燃 |
| | `autoIgniteUV` | (0.5,0.5) | 自动点燃的 UV 位置 |
| 限制 | `burnMaxDuration` | 0 | 最大燃烧秒数，0=不限 |
| | `burnMaxRadius` | 0 | 最大燃烧半径(UV)，0=不限 |

---

## 公开 API

```csharp
// 从射线碰撞点点燃（鼠标点击用）
burnController.Ignite(RaycastHit hit);

// 直接在 UV 空间点燃
burnController.IgniteAtUV(Vector2 uv);

// 停止扩散，保留已烧毁区域
burnController.StopBurning();

// 完全重置
burnController.ResetBurn();

// 八面体映射（静态工具方法）
Vector2 uv = BurnController.OctahedralUV(direction);
```

### 使用示例：火柴触碰点燃

```csharp
// 在另一个脚本中，持续检测火柴是否碰到物体
void OnTriggerStay(Collider other)
{
    _contactTime += Time.deltaTime;
    if (_contactTime >= 1.5f)  // 触碰 1.5 秒后点燃
    {
        var burnCtrl = other.GetComponent<BurnController>();
        if (burnCtrl != null)
        {
            // 用火柴头的位置作为点燃点
            var hit = new RaycastHit { point = matchHead.position };
            burnCtrl.Ignite(hit);
        }
    }
}
```

---

## Shader 属性（可调，可在 Material 面板中修改）

| 属性 | 默认 | 说明 |
|------|:---:|------|
| `_BurnSize` | 0.1 | 燃烧过渡带总宽度 |
| `_NoiseStrength` | 0.12 | 边缘噪声扰动幅度 |
| `_EdgeColor` | (1, 0.3, 0.02) | 余烬发光颜色 |
| `_CharColor` | (0.05, 0.02, 0.01) | 炭化黑边颜色 |
| `_EmberPower` | 3.0 | 余烬发光强度(影响 Bloom) |
| `_CurlAmount` | 0.05 | 顶点卷曲强度 |

---

## 依赖

- **Unity 2022+ / Unity 6**
- **URP (Universal Render Pipeline)**
- 无第三方插件
- 可选：Vefects Free Fire VFX URP（火焰粒子）

---

## 已知限制

1. **非凸物体**：八面体映射假设物体近似凸。深度凹陷的网格会产生轻微映射重叠。
2. **顶点密度**：卷曲变形需要足够顶点。默认 Cube/Sphere 可用，极低 poly 模型卷曲不明显。
3. **Build 环境**：`noiseTexture` 需手动拖入或在 Resources 下，否则留空不影响核心效果。
