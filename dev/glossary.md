# 术语表

这套教程里出现的所有名词，按类别排列。

## 转储与文件

### FrameAnalysis（转储）

3DMigoto 的帧分析功能产出的目录。按 `F8` 触发，会把当前帧所有 draw call 用到的资源 dump 到磁盘。

目录名形如 `FrameAnalysis-2026-11-17-215525`（日期-时间）。

### DrawCall（draw）

一次 GPU 绘制调用。日志里编号 6 位十进制，如 `000038`。

一个 draw 会绑定特定的 IB、VB、shader、贴图，然后画一部分三角形。

### DrawIB

一个 IB 缓冲的 hash，8 位十六进制，如 `7ad7e69e`。

同一个 IB 可被多个 draw 使用（不同渲染 pass）。

### deduped

去重目录。3DMigoto 把所有被多个 draw 共用的资源只存一份，文件名用**内容 hash** 而不是资源 hash。

所以 deduped 里的 `9c2ac78e.buf` 可能是逻辑名里的 `1844db3b`。

::: tip 为什么有 .lnk
主目录里那些 1~1.5 KB 的 `000038-ib=...buf.lnk` 是 Windows 快捷方式，指向 deduped 里的真实文件。

好处是「按逻辑名找文件」的路径还在，坏处是脚本读 `.lnk` 会拿到快捷方式本身而不是内容 —— 必须跟随链接。
:::

### log.txt

转储目录里的完整 API 调用日志。三个关键用途：

1. **`Dumping Buffer <源> -> <目标>`** — 逻辑名到真实文件的映射
2. **`DrawIndexed(IndexCount:..., StartIndexLocation:..., BaseVertexLocation:...)`** — 每个 draw 的索引参数
3. **`IASetVertexBuffers`** — 每个 draw 绑定了哪些 VB 槽

## 缓冲

### VB（Vertex Buffer）

顶点缓冲。存「一顶点一条记录」的数据，每条记录的字节数叫 **stride**。

### IB（Index Buffer）

索引缓冲。存三角形顶点的下标。一个三角形 3 个索引。

### stride

一条顶点记录的字节数。

如 stride 40 的 vb0 里，每条记录 40 字节：POSITION 12 + NORMAL 12 + TANGENT 16。

::: danger stride 是整套流程里最重要的数字
- 读顶点：`buf[i*stride : (i+1)*stride]`
- 顶点数：`len(buf) // stride`
- 校验：`len(buf) % stride == 0`

任何一处用错 stride，读出来的都是垃圾。
:::

### cb（Constant Buffer）

常量缓冲。`vs-cb4` / `ps-cb0` 这类。

骨骼矩阵常见在 `vs-cb4`（每骨骼 48 字节 = 3×float4）。但这个案例里实际的骨骼矩阵在 `vs-t0`（SRV 槽）。

### SRV（Shader Resource View）

着色器资源视图。`vs-t0` / `ps-t0` 这类槽位，可以放 Buffer 或 Texture。

`vs-t0` 里放骨骼矩阵 Bufffer 是常见做法。

### UAV（Unordered Access View）

无序访问视图。compute shader 通过它**写**数据。

GPU 预蒙皮用 CS 实现的游戏，蒙皮结果通过 UAV 写进一个 buffer。

### stream-out / SOSetTargets

VS 的输出可以「流出去」写到一个 buffer 里（`SOSetTargets`）。

这是另一种 GPU 预蒙皮的实现方式：VS 读 T-pose + 骨骼矩阵，算出蒙皮后坐标，直接流到一个新 buffer。

## 数据类型

### GameType / 数据类型

描述「一条顶点记录里有哪些字段、各占多少字节」的清单。

SSMT4 里的正式名字是 `D3D11GameType`，界面叫「数据类型」。

### D3D11Element

GameType 里的一行。7 个字段：

| 字段 | 含义 | 例 |
|---|---|---|
| `SemanticName` | 语义名 | `POSITION` |
| `SemanticIndex` | 同名语义中的序号 | `0` / `1` / `2` |
| `Format` | DXGI 格式 | `R32G32B32_FLOAT` |
| `ByteWidth` | 字节数（可由 Format 推算） | `12` |
| `ExtractSlot` | 从哪个槽取 | `vb0` |
| `ExtractTechnique` | 从哪类 draw 取 | `pointlist` / `trianglelist` |
| `Category` | 分组名 | `Position` / `Texcoord` / `Blend` |
| `DrawCategory` | 数据物理上落在哪路缓冲 | 常与 Category 相同 |

### Category

数据分组。**同一个 Category 的元素共享一个 stride，跨 Category 的顶点数必须相等。**

主流三组：

| Category | 内容 | 常见槽位 |
|---|---|---|
| `Position` | POSITION / NORMAL / TANGENT | vb0 |
| `Texcoord` | COLOR / TEXCOORDn | vb1 |
| `Blend` | BLENDWEIGHTS / BLENDINDICES | vb2 |

### ExtractTechnique

`pointlist` 或 `trianglelist`。

表示「这类数据要去哪种 draw 的缓冲里取」。

### DrawCategory

数据的「物理归属」。通常和 `Category` 一样，但有例外：

统计里 **`Blend → Position` 出现 102 处** —— 意思是「Weight 数据物理上存在 Position 那路缓冲里」，取的时候要按 Position 的 draw 语义定位。

### GPU-PreSkinning / CPU-PreSkinning

蒙皮（把骨骼变换应用到顶点上）在哪做的。

| | GPU-PreSkinning | CPU-PreSkinning |
|---|---|---|
| 蒙皮在哪 | GPU（VS 或 CS） | CPU |
| 转储里有 T-pose 缓冲吗 | **有** | 没有 |
| 转储里有权重数据吗 | **有**（BLENDINDICES / BLENDWEIGHTS） | 没有 |
| 有 pointlist draw 吗 | **有** | 没有 |
| 能提取骨骼权重吗 | 能 | 不能 |

::: tip 快速判断
看转储里有没有 `topology=pointlist` 的 txt。有 → GPU 预蒙皮。

但**如果没有也不能 100% 断定是 CPU** —— 有些游戏用 CS 写 UAV，不走 pointlist 拓扑。
:::

### pointlist / trianglelist

D3D 的两种 topology。

- `trianglelist` — 每 3 个顶点一个三角形（正常的绘制）
- `pointlist` — 每个顶点独立，不组成面（预蒙皮计算用）

### T-pose / 绑定姿势

模型的「出厂姿势」，骨骼还没动过的状态。通常双臂平举（像字母 T）。

游戏在 GPU 预蒙皮时，T-pose 缓冲是输入，蒙皮后的缓冲是输出。

### Skinned VB

已经蒙过皮的顶点缓冲。坐标是「当前帧动画姿势下的位置」。

**如果你直接用这份，导进 Blender 会带着那一帧的动作姿势。**

## 坐标系

### up 轴

「哪个轴指向天空」。

D3D 常见 **Y-up**（Y 向上），Blender 是 **Z-up**。

转换：`(x,y,z) → (x,-z,y)`。

### 绕序（winding order）

三角形的顶点排列方向。

- 逆时针（CCW）→ 面朝外（D3D 默认正面）
- 顺时针（CW）→ 面朝内

Blender 默认也是 CCW 正面，所以通常不用翻。但**必须实测**。

### 手性（handedness）

坐标系的左右手规则。行列式为 +1 的变换不改手性。

`(x,y,z) → (x,-z,y)` 的行列式：

```
| 1  0  0 |
| 0  0 -1 |  = 1
| 0  1  0 |
```

→ +1，不改手性 → 绕序不用跟着翻。

### V 轴翻转

UV 坐标的竖直方向。

- D3D：原点在左上，v 向下增大
- OpenGL / Blender：原点在左下，v 向上增大

转换：`v' = 1 - v`。

::: danger 这个翻转不是无损的
`1 - (1 - v)` 在 float32 下对 302/24068 个顶点不还原（差 1 ulp）。

做 mod 必须保留原始字节。
:::

### BaseVertexLocation

`DrawIndexed` 的第 3 个参数，单位是**顶点个数**。

大量游戏用一个大 VB 池装多个模型，各模型用 `BaseVertexLocation` 指向自己那段。索引都是相对 0 的。

**漏加这个 → 顶点飞到别处 → 模型变成尖刺乱飞。**

## 顶点数据

### SemanticName

D3D 里每个顶点字段的「名字标签」。常见：

`POSITION` / `NORMAL` / `TANGENT` / `COLOR` / `TEXCOORD` / `BLENDINDICES` / `BLENDWEIGHTS`

### SemanticIndex

同名语义的序号。

`TEXCOORD` + index 0 = 主 UV；`TEXCOORD` + index 1 = 第二套。

Blender 里常写成 `UVMap` / `TEXCOORD1` / `TEXCOORD2`。

### AlignedByteOffset

字段在一条顶点记录里的起始偏移（字节）。

比如 stride 40 的 vb0：POSITION @0、NORMAL @12、TANGENT @24。

### InputSlot

这个字段属于哪一路顶点缓冲。

`InputSlot: 0` → vb0，`InputSlot: 1` → vb1。

::: danger 每个 vbN txt 都抄着完整 InputLayout
`9c2ac78e-vb0-...txt` 里不只列 slot 0 的元素，而是**所有 slot 的元素都列出来**。

而且还常有重复项（TEXCOORD3 和 TEXCOORD2 同 offset）和撞车项（TANGENT @0 和 POSITION 撞）。

**必须按 InputSlot 分组 + 按 AlignedByteOffset 去重。**
:::

### DXGI_FORMAT

D3D 的像素/顶点格式枚举。常见：

| 格式 | 字节 | 内容 |
|---|---|---|
| `R32G32B32_FLOAT` | 12 | 3 个 float（位置/法线） |
| `R32G32B32A32_FLOAT` | 16 | 4 个 float（切线 xyz+w） |
| `R32G32_FLOAT` | 8 | 2 个 float（UV） |
| `R16G16_FLOAT` | 4 | 2 个 half（半精度 UV） |
| `R8G8B8A8_UNORM` | 4 | 4 个 u8（颜色） |
| `R32G32B32A32_SINT` | 16 | 4 个 int32（骨骼 ID） |
| `R16_UINT` | 2 | u16 索引 |
| `R32_UINT` | 4 | u32 索引 |

### ByteWidth

格式的字节数。可以从 `Format` 用「3 字符滑窗数位宽」的算法推：

```python
def bw(fmt):
    """DXGI_FORMAT_R32G32B32_FLOAT -> 12"""
    out = 0
    b = fmt.lower().encode()
    for i in range(len(b) - 2):
        w = b[i:i + 3]
        if w[1:2] == b'8':
            out += 1
        elif w[1:3] == b'32':
            out += 4
        elif w[1:3] == b'16':
            out += 2
    return out
```

## 导出产物

### OBJ

Wavefront 的模型文件格式。纯文本。

支持：顶点 / UV / 法线 / 面 / 材质。
不支持：顶点组 / 多层 UV / 顶点色（标准里没有）。

### MTL

OBJ 配套的材质文件。`map_Kd` 指定基础色贴图。

### 侧车 JSON（sidecar JSON）

跟 OBJ 一起输出的补充数据文件。存 OBJ 装不下的东西：顶点组、多层 UV、顶点色、骨骼矩阵。

### Type 目录 / `TYPE_` 前缀

SSMT4 工作区里的命名约定：

```
<workspace>/<draw_ib>-<count>-<first>/TYPE_<GameTypeName>/xxx.json
```

`TYPE_` 后面就是数据类型名。

### Import.json

Blender 插件侧的状态文件，记录「每个 submesh 用了哪个数据类型」。

::: tip Rust 侧不读它
SSMT4 的 Rust 代码明确注释：`This deliberately does not consult Import.json: that file is Blender's`。

它是**纯插件侧**记录，删掉也不影响提取结果，只会让插件不知道上次选了哪个类型。
:::

## Memory / 骨骼

### VGMap

「顶点组映射」。把 submesh 局部的顶点组 ID 映射到全局骨骼 ID。

```json
{ "0": 12, "1": 5, "2": 87 }
```

### bone index / 骨骼 ID

蒙皮权重引用的是骨骼的**编号**，不是名字。

转储里只有编号（0..140），**没有骨骼名字和父子层级** —— 所以没法直接建骨架。

### 骨骼矩阵缓冲

每骨骼一条记录，通常 48 字节 = 3 个 float4（3×4 矩阵）。

前 3 列通常是旋转，第 4 列是平移。但这个案例里两种解读都不在模型 bbox 内 —— 说明矩阵的基准/轴向与模型坐标系不同。

### 65535 哨兵

BLENDINDICES 里 `65535`（u16 最大值）表示「这个槽位没有骨骼」。

导入 Blender 时要转成 `-1`（顶点组 ID 不能是 65535）。

## 工具与项目

### 3DMigoto

游戏画面注入 + 帧分析工具。转储就是它产的。

用 `.ini` 配置文件定义「拦截哪个 hash、替换成什么资源」，所以做 mod 就是写 ini + 提供 buffer 文件。

### SSMT4

Rust + Vue 的桌面工具。自动完成「转储 → 提取 → 组织成 Blender 能读的目录」。

### TheHerta4

SSMT4 配套的 Blender 插件。读 SSMT4 的输出目录，在 Blender 里建网格。

### MMT

另一个同类工具。界面里看到 `#0 59307-0` 这种编号就是它的显示方式。

### hunting 模式

3DMigoto 的功能：在游戏里按快捷键逐个遍历已知的 draw，让你肉眼找出目标模型。

## 数据验证用词

### 退化三角形

面积接近 0 的三角形（三个顶点共线或重合）。

正常模型里应该是 0 个（或者极少）。

### 面积加权

统计时按三角形面积给权重。大三角形的影响更大，避免一堆小碎片干扰结论。

### bbox（bounding box）

轴对齐包围盒。`pos.max(0) - pos.min(0)` 得到三个轴的跨度。

人形模型：Z（或正确的 up 轴）跨度 ≈ 1.6~1.8 米，另两轴 0.5~0.7 米。

### 中位 vs 均值

- **均值**容易被极端值带偏
- **中位**更稳定，适合判读「多数情况是什么」

判绕序时看中位点积（+0.995）比看均值可靠。

## 命名规则速查

数据类型名的段：

| 段 | 含义 | 字节 |
|---|---|---|
| `P12` | POSITION R32G32B32_FLOAT | 12 |
| `P16` | POSITION R32G32B32A32_FLOAT | 16 |
| `P8` | POSITION R16G16B16A16_FLOAT | 8 |
| `N12` | NORMAL 3×f32 | 12 |
| `N4` | NORMAL R8G8B8A8_SNORM | 4 |
| `TA16` | TANGENT 4×f32 | 16 |
| `TA4` | TANGENT R8G8B8A8_SNORM | 4 |
| `C4` | COLOR R8G8B8A8_UNORM | 4 |
| `C16` | COLOR 4×f32 | 16 |
| `T8` | TEXCOORD 2×f32 | 8 |
| `T4` | TEXCOORD R16G16_FLOAT | 4 |
| `T1-8` | TEXCOORD1 8 字节 | 8 |
| `T2-4` | TEXCOORD2 4 字节 | 4 |
| `BW16` | BLENDWEIGHTS 4×f32 | 16 |
| `BW8` | BLENDWEIGHTS 2×f32 | 8 |
| `BI16` | BLENDINDICES 4×u32 | 16 |
| `BI8` | BLENDINDICES 2×u32 | 8 |
| `BI4` | BLENDINDICES 1×u32 | 4 |

::: warning 数字只是字节数
`P8` 可能是 4 个 half 也可能是 2 个 float，名字看不出区别。

必须打开 JSON 看 `Format`。
:::

→ 回到[入门教程](/guide/)重新走一遍流程