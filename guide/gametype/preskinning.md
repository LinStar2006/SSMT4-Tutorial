# GPU 与 CPU 预蒙皮

这是整套教程**最重要的一节**。

如果你只读一页，读这页。绝大多数「模型姿势不对」「没有骨骼权重」「颜色是彩虹噪点」的问题，根都在这里。

## 先说结论

一个带骨骼绑定的模型，在转储里可能有多份顶点缓冲：

| 缓冲 | 内容 | 状态 |
|---|---|---|
| **T-pose VB** | 绑定姿势的坐标 + 骨骼权重 | 静止、可编辑 |
| **Skinned VB** | 已经算完蒙皮的坐标 | 当前帧的动画姿势 |

如果你随手抓了一个 `vb0` 就切，**大概率抓到的是 Skinned VB** —— 于是模型摆着一个踢腿/挥剑的姿势，而且**没有 BLENDINDICES**（骨骼权重）。

于是你会以为「这个模型不支持骨骼」，其实数据一直在，只是在另一个文件里。

## 数据流：为什么有两份

GPU 蒙皮的完整链路（以顶点着色器 stream-out 为例）：

```
        ┌─────────────────────────────────────────────┐
        │                                             │
   [T-pose VB]                                       │
   POSITION / NORMAL / TANGENT                        │
   + BLENDWEIGHTS / BLENDINDICES                     │
        │                                            │
        │  ① pointlist draw                          │
        │     VS 读 [骨骼矩阵] + [T-pose VB]          │
        │     算出蒙皮后的坐标                        │
        │     通过 stream-out 写出                    │
        ▼                                            │
   [Skinned VB]                                      │
   POSITION / NORMAL / TANGENT                        │
   （坐标已经变形了）                                  │
        │                                            │
        │  ② trianglelist draw                       │
        │     用 [Skinned VB] 作为顶点                │
        │     画出屏幕上的形象                        │
        ▼                                            │
     screen                                          │
                                                     │
   vb1（UV / COLOR）──────────────────────────────────┘
        两边都读，内容不变
```

关键点：

1. **① 的 draw 用 `pointlist` topology** —— 因为它不是在画三角形，是在算顶点。每个顶点独立处理，所以拓扑是点列表。
2. **② 的 draw 用 `trianglelist`** —— 真正画三角形。
3. **两次 draw 读的是同一个 IB** —— 顶点顺序完全一致，索引通用。
4. **vb1（UV/COLOR）两边都读，内容相同** —— 所以 UV 从哪一份取都行。

::: tip 为什么 pointlist 也叫「预蒙皮」
「预」= 在真正渲染之前先算好。GPU 先把蒙皮结果写进一块缓冲，后面反复使用（同一个模型可能被多个 draw 用不同材质画多次，蒙皮只算一次）。
:::

## 怎么认出来

### 特征一：转储里有 `topology=pointlist` 的文件

```bash
ls deduped/*topology=pointlist* | wc -l
```

有就是 GPU 预蒙皮。实战案例里这个数字是 **8**（对应 4 个部件 × 2 个槽）。

那 8 个文件长这样：

```
1569d000-vb0-layout=d8e9f34b-topology=pointlist-stride=40-count=24068.txt
47280c51-vb1-layout=d8e9f34b-topology=pointlist-stride=32-count=24068.txt
```

注意两件事：

- `stride=40` 的 vb0 → 是 Position 类（坐标）
- `stride=32` 的 vb1 → 是 **Blend 类**（权重 16 + 索引 16）

## 两份缓冲的对照（真实数据）

拿 IB `7ad7e69e` 举例，同一个模型的两套顶点缓冲：

| | 真名 | stride | 内容 | 顶点数 |
|---|---|---|---|---|
| **T-pose** | `1569d000.buf` | 40 | POSITION@0(12) + NORMAL@12(12) + TANGENT@24(16) | 24068 |
| | `47280c51.buf` | 32 | BLENDWEIGHT@0(16) + BLENDINDICES@16(16) | 24068 |
| **已蒙皮** | `9c2ac78e.buf` | 40 | POSITION@0(12) + NORMAL@12(12) + TANGENT@24(16) | 24068 |
| | `9798ab34.buf` | 28 | COLOR@0(4) + TEXCOORD@4(8) + TEXCOORD1@12(8) + TEXCOORD2@20(8) | 24068 |

几点观察：

### 顶点数完全一致

`1569d000.buf` = 962720 字节 / 40 = **24068**
`9c2ac78e.buf` = 962720 字节 / 40 = **24068**

不是巧合 —— 它们就是同一批顶点，只是坐标值不同。

### 第一份坐标完全不同

```text
T-pose[0]   POSITION = (-0.0857,  1.4883,  0.0631)   # 站立
skinned[0]  POSITION = (-0.5291, -0.0424,  0.0552)   # 踢腿
```

### 顶点顺序一致

这是关键。用**同一个 IB** 的索引分别去索引两份 vb0，渲染出来**都是完整人形** —— 一份站着 T-pose，一份踢腿。

说明：**索引通用，只是坐标不同。**

::: tip 怎么证明这一点
写个对比脚本，用同一批三角形索引分别画两个顶点数组，输出两张图对比。如果两张都是人形（而不是一张人形一张乱麻），就说明顺序一致。

```python
"""用同一套索引分别渲染两份 vb0，对比"""
import numpy as np
from PIL import Image

def read_pos(path, stride, offset=0):
    raw = open(path, 'rb').read()
    a = np.frombuffer(raw, dtype=np.uint8)
    a = a[:(len(a) // stride) * stride].reshape(-1, stride)
    return a[:, offset:offset + 12].copy().view('<f4')

def load_tris(txt_or_buf):
    ...  # 略，见 extract/vertices

tpose = read_pos('1569d000.buf', 40, 0)
skinned = read_pos('9c2ac78e.buf', 40, 0)
tris = load_tris(...)

# 两者的 bbox 对比，先看尺寸
for name, v in [('T-pose', tpose), ('skinned', skinned)]:
    lo, hi = v.min(0), v.max(0)
    print(f'{name:8} bbox {lo} .. {hi}  尺寸 {hi - lo}')
```

实战输出：

```
T-pose   bbox [-0.416 -0.809 -0.559] .. [ 0.416  0.808  0.558]  尺寸 [0.832 1.617 1.117]
skinned  bbox [-0.597 -0.505 -0.300] .. [ 1.005  0.209  0.265]  尺寸 [1.602 0.713 0.565]
```

T-pose 的 Y 跨度 1.617 就是身高（Y 是 up 轴）。skinned 的 X 跨度 1.602 是因为**腿伸向 X 方向**。
:::

## 找到 T-pose 缓冲的 draw

现在的问题是：怎么知道 `1569d000.buf` 对应哪个 draw？

### 原理：从 vb0 哈希反查

pointlist 的 draw 会**读** T-pose 的 vb0，然后**写** Skinned 的缓冲。所以：

1. 找出 trianglelist 的 draw
2. 取它的 vb0 哈希
3. 在 log 里找「**写了这个哈希**」的那个 draw —— 那就是 pointlist draw
4. pointlist draw **读**的 vb0 就是 T-pose

### 日志长什么样

```text
000001 IASetVertexBuffers(StartSlot:0, NumBuffers:2, ppVertexBuffers:...)
       Src: resource=0x... hash=1569d000      ← 读的是 T-pose
000001 SOSetTargets(NumBuffers:1, ...)
       Dst: resource=0x... hash=9c2ac78e      ← 写出的 skinned
000001 Draw(VertexCount:24068, StartVertexLocation:0)

...

000038 IASetVertexBuffers(StartSlot:0, NumBuffers:2, ...)
       Src: resource=0x... hash=9c2ac78e      ← 读的是 skinned
000038 DrawIndexed(IndexCount:10446, StartIndexLocation:59307, BaseVertexLocation:0)
```

`000001` 是 pointlist draw：读 `1569d000`、写 `9c2ac78e`
`000038` 是 trianglelist draw：读 `9c2ac78e`

::: warning 排除 `CopyResource` 的 Dst
日志里 `Dst: ... hash=xxx` 不一定是 GPU 预蒙皮的写出。**`CopyResource` 也会产生 Dst**：

```text
000007 CopyResource(pDstResource:0x..., pSrcResource:0x...)
       Src: resource=... hash=e4d2fec9
       Dst: resource=... hash=e9d29b50
```

这是纯拷贝，没有蒙皮。如果只按「Dst 里有这个哈希」来筛，会把拷贝当预蒙皮，抓到错误的缓冲。

SSMT4 的源码里对这一点有明确注释：`//注意如果是CopyResource之类的操作，这并不是GPU-PreSkinning`。正确的做法是只看 `SOSetTargets` 的 Dst（stream-out 目标）。
:::

### 实现

```python
"""从 trianglelist 的 vb0 哈希，反查负责预蒙皮的 pointlist draw"""
import re

def find_pointlist_draw(log_path, target_vb0_hash):
    """
    返回 (pointlist_draw_index, tpose_vb0_hash) 或 (None, None)

    逻辑：
      1. 扫描 log，收集每个 draw 的 IASetVertexBuffers 读入哈希
      2. 收集每个 draw 的 SOSetTargets 写出哈希（排除 CopyResource）
      3. 找出「写出 target_vb0_hash」的 draw
      4. 它的读入 vb0 就是 T-pose
    """
    read_by_draw = {}      # draw -> [hash, ...]
    write_by_draw = {}     # draw -> [hash, ...]

    cur = None
    mode = None            # 'read' / 'write'
    in_copy = False
    fh = open(log_path, 'r', errors='ignore')

    for line in fh:
        m = re.match(r'^(\d{6})\b', line)
        if m:
            cur = m.group(1)
            mode = None
            in_copy = False

        if 'IASetVertexBuffers' in line:
            mode = 'read'
            continue
        if 'SOSetTargets' in line:
            mode = 'write'
            in_copy = False
            continue
        if 'CopyResource' in line:
            in_copy = True
            mode = None
            continue
        if 'IASetIndexBuffer' in line or 'Draw' in line:
            mode = None
            in_copy = False
            continue

        if 'hash=' not in line or cur is None:
            continue

        h = re.search(r'hash=([0-9a-f]{8})', line)
        if not h:
            continue
        h = h.group(1)

        if mode == 'read' and 'Src:' in line:
            read_by_draw.setdefault(cur, []).append(h)
        elif mode == 'write' and 'Dst:' in line and not in_copy:
            write_by_draw.setdefault(cur, []).append(h)

    fh.close()

    # 找写出目标哈希的 draw
    for draw, writes in sorted(write_by_draw.items()):
        if target_vb0_hash in writes:
            reads = read_by_draw.get(draw, [])
            if reads:
                return draw, reads[0]

    return None, None


# 用法
draw, tpose = find_pointlist_draw(
    r'dump\FrameAnalysis-...\log.txt',
    target_vb0_hash='1844db3b')     # trianglelist 的 vb0
print(f'pointlist draw = {draw}, T-pose vb0 = {tpose}')
```

::: details 更精确的判据（一个 IB 多个部件时必需）
上面这个算法有一个缺陷：**同一个 IB 的多个部件共用同一份 T-pose 缓冲**。

如果你的角色由 body + cloth + accessory 四个部件组成，它们各自有自己的 pointlist draw，但**都读同一份 vb0**。这时候「找最后一个匹配」会抓到别的部件的 draw。

更精确的做法要求候选 draw 同时满足：

1. `IASetVertexBuffers` 里 **vb1（UV）的哈希** 与目标 trianglelist draw 一致
2. 它通过 `SOSetTargets` 写出了**目标 draw 正在读的**缓冲

第一条排除了别的部件，第二条排除了只读不写的渲染 draw。

SSMT4 里这个函数叫 `get_pointlist_index_by_texcoord_hash`，失败时回退到上面那个简单版。
:::

## CPU 预蒙皮是什么样

有些游戏（尤其是用 CPU 算蒙皮的）不搞 GPU 预蒙皮。表现是：

- **转储里没有 `topology=pointlist` 的文件**
- 顶点缓冲里**直接有 BLENDINDICES / BLENDWEIGHTS**
- 顶点坐标已经是当前姿势（因为 CPU 算完才上传）

对比：

| | GPU 预蒙皮 | CPU 预蒙皮 |
|---|---|---|
| pointlist 文件 | 有 | 没有 |
| BLEND 数据在哪 | pointlist 的 vb1 | 和坐标在同一个缓冲 |
| 拿到的坐标是 | T-pose（从 pointlist 取） | 当前动画姿势 |
| 能不能还原成 T-pose | 能（有权重，可反算） | 只能靠权重和骨骼矩阵反算 |
| SSMT4 类型前缀 | `GPU_` | `CPU_` |

::: warning CPU 类型的 JSON 里没有 BLENDINDICES
看 SSMT4 的 GIMI 库里 11 个 CPU 类型，**一个都没有 BLENDINDICES**。

这说明什么？说明这些模型在转储里**真的看不到骨骼绑定** —— 因为游戏在 CPU 侧算完蒙皮才上传，上传的顶点只有坐标/法线/UV。

如果你需要骨骼权重但只有 CPU 数据，得去游戏文件里找原始资源，或者找另一帧里 GPU 路径的版本。教程范围外的内容。
:::

## 实战：怎么判断自己的模型是哪种

```python
"""判断一个 IB 是 GPU 还是 CPU 预蒙皮"""
import os
import re

DUMP = r'C:\path\to\FrameAnalysis-...'
IB = '7ad7e69e'

def classify(dump, ib):
    # 1. 找这个 IB 相关的所有 topology=pointlist 文件
    pointlist = []
    tri = []
    for root, _, files in os.walk(dump):
        for name in files:
            if not name.endswith('.txt'):
                continue
            if f'-ib={ib}' not in name and not re.search(
                    r'-(?:vb|ib)\d*-layout=', name):
                # deduped 里文件名不带 ib=，只带 layout
                pass
            if 'topology=pointlist' in name:
                pointlist.append(name)
            elif 'topology=trianglelist' in name:
                tri.append(name)

    print(f'{ib}: pointlist 文件 {len(pointlist)} 个, '
          f'trianglelist 文件 {len(tri)} 个')

    if pointlist:
        print('→ 有 pointlist：GPU-PreSkinning')
        print('  T-pose 顶点在这些文件里：')
        for n in pointlist[:6]:
            print('   ', n)
    else:
        print('→ 没有 pointlist：要么是 CPU-PreSkinning，'
              '要么这一帧没抓到这个模型的预蒙皮 draw')

classify(DUMP, IB)
```

::: tip pointlist 文件数量对不上怎么办
正常的 GPU 预蒙皮，每个部件有 2 个 pointlist 文件（vb0 = 坐标，vb1 = 权重）。

如果只有 1 个，说明权重可能在别的槽（`cs-t0` 之类），要去看 `ExtractSlot` 分布。

如果一个都没有，但你知道这游戏是 GPU 蒙皮的 —— 可能是**这一帧的模型没走预蒙皮路径**（比如已经缓存过蒙皮结果）。换个姿势/场景再抓一帧。
:::

## 这里的常见错误

::: danger 错误 1：抓了 trianglelist 的 vb0 就切
症状：模型摆着一个动作，顶点组是空的，颜色通道奇怪。

原因：你切的是 Skinned VB，坐标已经是变形后的，且那份缓冲里没有 BLEND 数据。

正确：按[上面的方法](#找到-t-pose-缓冲的-draw)找 pointlist draw 的读入 vb0。
:::

::: danger 错误 2：以为 stride 一样就是同一份数据
`1569d000.buf` 和 `9c2ac78e.buf` **都是 stride 40**，都是 24068 顶点，尺寸都一样。

但坐标完全是两套。

正确：靠**哈希**区分文件，不要靠尺寸/stride 猜。
:::

::: danger 错误 3：UV 从 T-pose 缓冲里找
T-pose 的 vb1 是 **BLEND 数据**（stride 32 = 权重 16 + 索引 16），不是 UV。

正确：UV 从 trianglelist 那份 vb1 取（stride 28 = COLOR 4 + UV × 3）。

这也正是 SSMT4 数据类型里 `ExtractTechnique` 存在的意义：

| Category | ExtractTechnique | 从哪取 |
|---|---|---|
| Position | `pointlist` | T-pose 的 vb0 |
| Blend | `pointlist` | T-pose 的 vb1 |
| Texcoord | `trianglelist` | 已蒙皮的 vb1 |

**同一份数据类型里，不同 Category 走不同 topology 的 draw** —— 这就是为了"既要 T-pose 的形状和权重，又要原始 UV"。
:::

## 快速判断口诀

> **有 pointlist → GPU，坐标取 pointlist 的 vb0，权重取 pointlist 的 vb1，UV 取 trianglelist 的 vb1。**

## 下一步

→ [从转储推导数据类型](/guide/gametype/derive)：对不上任何现成类型时怎么办