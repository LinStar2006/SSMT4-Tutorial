# 提取贴图

模型提出来了，但它是白的。这一节讲怎么把 `ps-t*` 那堆 DDS 变成能用的贴图，并且**判断哪张是什么**。

## 贴图槽的约定

每个 draw 的像素着色器绑定了一组纹理：

```
000041-ps-t0=10c4fa9f.dds
000041-ps-t1=9886ea3b.dds
000041-ps-t2=9ce62a7a.dds
000041-ps-t3=b0e08915.dds
000041-ps-t4=bd24efc4.dds
```

| 槽 | 常见用途 | 典型特征 |
|---|---|---|
| `ps-t0` | **基础色（Diffuse / Albedo）** | 有真实颜色、能认出图案 |
| `ps-t1` | **法线贴图（Normal）** | 整体偏紫蓝，RGB 值集中在 (128,128,255) 附近 |
| `ps-t2` | 光照贴图 / 高光遮罩 | 灰度或单色通道 |
| `ps-t3` | 遮罩（Mask / AO / 面 SDF） | 灰度 |
| `ps-t4` | 特殊效果图 | 各种 |

::: warning 槽位约定不是绝对的
`ps-t0` 是基础色**在大多数游戏里成立**，但不是标准。有些游戏把法线放 t0，把基础色放 t2。

**不要靠槽位猜用途，靠内容判断。** 下面讲怎么判断。
:::

## 第 1 步：全部转成 PNG 看一眼

Pillow 直接支持 DDS（含 BC7 压缩）：

```python
"""把转储里所有 ps-t* 贴图转成 PNG，并拼一张总览图"""
import os
import re
from PIL import Image, ImageDraw

DUMP = r'C:\path\to\FrameAnalysis-...'
IB = '7ad7e69e'
OUT_DIR = 'textures'
THUMB = 220
COLS = 5


def find_ps_textures(dump, ib):
    """返回 {槽号: [(draw, tex_hash, 真实路径), ...]}"""
    found = {}
    pat = re.compile(
        rf'^(\d{{6}})-ib={ib}-.*?-ps-t(\d+)=([0-9a-f]+)\.dds$')

    for root, _, files in os.walk(dump):
        for name in files:
            base = name[:-4] if name.endswith('.lnk') else name
            m = pat.match(base)
            if not m:
                continue
            draw, slot, tex = m.groups()
            cand = os.path.join(root, name.replace('.lnk', ''))
            if not os.path.isfile(cand):
                cand = os.path.join(root, base)
            if os.path.isfile(cand):
                found.setdefault(int(slot), []).append((draw, tex, cand))
    return found


os.makedirs(OUT_DIR, exist_ok=True)
textures = find_ps_textures(DUMP, IB)

cells = []
for slot in sorted(textures):
    # 每个槽取第一个 draw 的贴图作为代表
    draw, tex, path = textures[slot][0]
    try:
        im = Image.open(path)
        info = f'{im.width}x{im.height} {im.mode}'
        im = im.convert('RGB')
    except Exception as e:
        print(f'ps-t{slot} {tex} 读不了: {e}')
        continue

    # 存 PNG + 打印统计
    png = os.path.join(OUT_DIR, f'ps-t{slot}_{tex}.png')
    im.save(png)
    arr = __import__('numpy').asarray(im)
    mean = arr.reshape(-1, 3).mean(0)
    print(f'ps-t{slot}  {tex}  {info}  mean RGB = '
          f'[{mean[0]:.1f} {mean[1]:.1f} {mean[2]:.1f}]  -> {png}')

    thumb = im.copy()
    thumb.thumbnail((THUMB, THUMB))
    cells.append((slot, tex, thumb, mean))


# 拼总览图
rows = (len(cells) + COLS - 1) // COLS or 1
canvas = Image.new('RGB', (COLS * THUMB, rows * (THUMB + 24)), (22, 22, 26))
dr = ImageDraw.Draw(canvas)
for i, (slot, tex, im, _) in enumerate(cells):
    x = (i % COLS) * THUMB
    y = (i // COLS) * (THUMB + 24)
    canvas.paste(im, (x, y))
    dr.text((x + 4, y + THUMB + 4), f'ps-t{slot}  {tex}', fill=(230, 230, 230))

canvas.save(os.path.join(OUT_DIR, '_overview.png'))
print('\n总览:', os.path.join(OUT_DIR, '_overview.png'))
```

## 第 2 步：靠内容判断哪张是基础色

打开 `_overview.png`，同时看打印的 mean RGB：

### 判据表

| 特征 | 结论 |
|---|---|
| 有可辨认的图案（人脸、布料、金属） | **基础色** |
| 整体偏紫蓝，mean RGB 接近 (128, 128, 255) | **法线贴图** |
| 纯灰度，mean RGB 三通道相等 | **遮罩 / AO** |
| mean RGB 单通道接近 0（比如 (128, 69, 0)） | 可能是**特殊数据图**（面 SDF、光照方向等） |
| 大面积黑 + 少量彩色 | 可能是**发光贴图 / Emissive** |

### 实战案例的判断过程

转储里 9 张候选贴图，靠 mean RGB 一次分完：

| hash | 尺寸 | mean RGB | 判断 |
|---|---|---|---|
| `10c4fa9f` | 1024² | (211.6, 170.8, 138.0) | **基础色** — 肤色 + 金发 |
| `4437957c` | 256² | (141.5, 122.0, 130.4) | **基础色** — 深色衣料 + 白蕾丝 |
| `82d0c6de` | 1024² | (33.7, 79.4, 24.0) | 法线（偏绿紫） |
| `2ebe89dd` | 1024² | (127.4, 128.0, 254.6) | **法线**（标准紫蓝） |
| `9886ea3b` | 512² | (39.2, 73.6, 45.6) | 法线（暗色版） |
| `9ce62a7a` | 512² | (128.0, 127.8, 43.7) | 特殊数据图 |
| `b0e08915` | 512² | (100.6, 100.6, 100.6) | **灰度遮罩**（三通道相等） |
| `bd24efc4` | 256² | (127.5, 69.3, 0.0) | 特殊数据图 |

::: tip mean RGB 三条判据已经够用
- **三通道完全相等** → 灰度图，一定不是基础色
- **B 通道接近 255 且 R/G 接近 128** → 法线贴图（标准 tangent-space normal 的中性值是 (128,128,255)）
- **有明显偏色且能看到图案** → 基础色
:::

### 一个容易误判的情况

有些游戏的基础色贴图**本身就很暗**（比如黑色皮衣），mean RGB 可能是 (40, 35, 38)。这时看「有没有图案」比看数值可靠。

把图放大看一眼一般就能确定 —— 基础色总能看出布料纹理、缝线、颜色分区。

## 第 3 步：判断哪张贴图属于哪一段

一个 IB 分成多段（body / cloth / accessory），每段用不同贴图。怎么对号？

### 方法：ps hash 被多少个 IB 共用

```python
"""统计每个 ps hash 被多少个不同的 IB 使用"""
import os
import re
from collections import defaultdict


def rank_ps_hashes(dump):
    """返回 {ps_hash: set(ib_hash)}"""
    ps_to_ibs = defaultdict(set)
    pat = re.compile(
        r'^\d{6}-ib=([0-9a-f]{8})-.*?-ps=([0-9a-f]{16})\.')

    for root, _, files in os.walk(dump):
        for name in files:
            base = name[:-4] if name.endswith('.lnk') else name
            m = pat.match(base)
            if m:
                ps_to_ibs[m.group(2)].add(m.group(1))
    return ps_to_ibs


ranks = rank_ps_hashes(DUMP)
print(f'{"ps hash":18} {"共用 IB 数":>10}')
print('-' * 34)
for ps, ibs in sorted(ranks.items(), key=lambda kv: -len(kv[1]))[:20]:
    print(f'{ps:18} {len(ibs):>10}')
```

### 判据

| 共用 IB 数 | 含义 |
|---|---|
| **1** | 这是**某个部件专属的渲染 pass** —— 最可能是主渲染 |
| 2–3 | 可能是同一模型的不同材质变体 |
| **5 以上** | 通用 pass —— 阴影 / 深度 / 描边 / 后处理 |

::: warning 别把阴影 pass 的贴图当材质
阴影 pass 通常用不到颜色贴图（只写深度），但 3Dmigoto 仍然会 dump 它绑定的所有纹理。所以「被 5 个 IB 共用的 ps」往往对应的是通用的阴影/描边着色器，它绑定的贴图可能跟你的模型无关。
:::

### 实战结果

| 段 | draw 列表 | ps 共用 IB 数 | 选哪个当主 pass |
|---|---|---|---|
| #0 (first=0) | `000041` `000052` `000100` `000111` | **2** / 5 / 5 / 5 | `000041` |
| #1 (first=59307) | `000038` `000049` `000104` `000115` | **1** / 2 / 2 / 2 | `000038` |
| #2 (first=69753) | `000039` `000050` `000098` `000109` | 2 / 2 / 2 / 2 | 都行 |
| #3 (first=87798) | `000048` `000059` `000103` `000114` | 1 / 1 / 1 / 1 | 都行 |

然后看选中 draw 的 `ps-t0`：

| 段 | 主 pass | ps-t0 hash | 内容 |
|---|---|---|---|
| #0 body | `000041` | `10c4fa9f` | 肤色 + 金发 |
| #1 cloth_a | `000038` | `4437957c` | 深色衣料 |
| #2 cloth_b | `000039` | `4437957c` | 深色衣料 |
| #3 accessory | `000048` | `10c4fa9f` | 肤色（长枪握把是手的一部分） |

::: tip 同一个模型的不同段可以共用贴图
上面 cloth_a 和 cloth_b 用同一张 `4437957c` —— 它们都是衣服，画在同一张图集的不同的 UV 区域。

**不需要为每段准备独立贴图**，把同一张 PNG 挂到多个材质上就行。
:::

## 第 4 步：sRGB 还是 Linear

DDS 文件名里有时带格式提示：

```
10c4fa9f-BC7_UNORM_SRGB.dds     ← sRGB 编码
4437957c-BC7_UNORM_SRGB.dds     ← sRGB 编码
82d0c6de-BC7_UNORM.dds          ← 线性
```

| 后缀 | 颜色空间 | 谁该用 |
|---|---|---|
| `_SRGB` | sRGB 编码 | **基础色、自发光**（美术给的颜色） |
| 无后缀 / `_UNORM` | 线性 | **法线、粗糙度、遮罩、AO**（数值型数据） |

在 Blender 里：

```python
img = bpy.data.images.load(png_path)
if is_albedo:
    img.colorspace_settings.name = 'sRGB'
else:
    img.colorspace_settings.name = 'Non-Color'
```

::: danger 基础色设成 Non-Color 会发白
反过来，法线贴图设成 sRGB 会让法线方向算错，模型看起来像抹了油。

**基础色永远 sRGB，数据图永远 Non-Color。**
:::

## 第 5 步：贴图与 UV 是否对得上

最后验证一件事：**这张贴图真的配这个 UV 吗？**

### 方法：用 UV 采样贴图，看颜色是否合理

```python
"""用 UV 质心采样贴图给面上色，渲染出来看"""
import numpy as np
from PIL import Image

def sample_by_uv(uv, tris, tex_path, W=900, H=700):
    """
    uv:   (N, 2) 每顶点 UV，已经做过 V 翻转
    tris: (T, 3)
    """
    tex = np.asarray(Image.open(tex_path).convert('RGB'))
    th, tw = tex.shape[:2]

    # 三角形质心的 UV
    tri_uv = uv[tris].mean(axis=1)               # (T, 2)
    px = np.clip((tri_uv[:, 0] * tw).astype(int), 0, tw - 1)
    py = np.clip(((1 - tri_uv[:, 1]) * th).astype(int), 0, th - 1)  # V 翻转
    colors = tex[py, px]

    print('采样到', len(colors), '个颜色，前 5 个：')
    for c in colors[:5]:
        print(' ', c.tolist())
    return colors
```

拿采样结果判断：

| 现象 | 结论 |
|---|---|
| 颜色区域集中（都是肤色 / 都是深色） | ✓ UV 对得上 |
| 颜色随机跳（一片彩噪） | ✗ UV 或 V 轴错了 |
| 大部分是某个单一颜色（比如全黑） | ✗ UV 全部落在贴图外的空白区 |

实战案例采样结果：

```
采样到 29606 个颜色，前 5 个：
  [178, 138, 105]      ← 皮肤色
  [248, 187, 126]      ← 皮肤高光
  [136, 133, 130]      ← 布料
```

这些是**肤色和布料的色调**，说明 UV 和贴图对得上。

::: details V 轴翻转：为什么算法判不出来，只能看
3D 图形里 UV 原点位置有两种约定：

- **DirectX / D3D**: 原点在左上角，V 向下增长
- **OpenGL / Blender**: 原点在左下角，V 向上增长

所以从 dx 转 Blender 通常要做 `v' = 1 - v`。

**但这个翻转不是绝对的** —— 有些游戏用 dx 但美术按 OpenGL 习惯做 UV，有些工具链做了两次翻转。

我试过两种自动判据，都不靠谱：

| 判据 | 结果 |
|---|---|
| 相邻三角形采样色差（同 UV 岛内颜色应相近） | V 原样均值 7.07 / V 翻转 6.35，**差别太小判不出** |
| UV v 与顶点坐标的相关性 | \|corr\| 只有 0.15，**量级不够** |

**只能人眼判定**：把 UV 线框叠到贴图上，看位置对不对。或者用上面采样渲染出来的颜色看是不是"合理的人类配色"。

默认做法：**按 `v' = 1 - v`**（dx → Blender 的标准做法），如果看着不对再关掉。
:::

## 贴图格式对照

| DXGI 格式 | 含义 | Pillow 支持 |
|---|---|---|
| `BC1_UNORM` | DXT1，RGB + 可选 1bit alpha | ✓ |
| `BC3_UNORM` | DXT5，RGB + 8bit alpha | ✓ |
| `BC7_UNORM` | 高质量，现代游戏主流 | ✓（Pillow 8.0+） |
| `BC7_UNORM_SRGB` | 同上，sRGB 编码 | ✓ |
| `R8G8B8A8_UNORM` | 未压缩 32 位 | ✓ |
| `BC5_UNORM` | 双通道法线专用 | ✓ |

::: tip Pillow 读 DDS 的一行代码
```python
from PIL import Image
im = Image.open('10c4fa9f-BC7_UNORM_SRGB.dds').convert('RGB')
im.save('out.png')
```

BC7 在 Pillow 8.0+ 才有支持。如果报错 `cannot identify image file`，升级 Pillow：

```bash
pip install -U pillow
```
:::

## 这一步的通过标准

- [ ] 每段都有一张基础色贴图
- [ ] 能认出贴图内容（能看出是角色/道具，不是噪声）
- [ ] 知道每张图是 sRGB 还是线性
- [ ] 用 UV 采样出来的颜色是合理的（肤色/布料色，不是彩噪）

## 下一步

→ [OBJ 路线](/guide/blender/obj)：最快把模型弄进 Blender