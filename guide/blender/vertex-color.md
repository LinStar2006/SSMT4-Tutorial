# 顶点色与 UV

这两块数据是整套流程里**最容易觉得自己做对了其实没有**的地方。

UV 错一个轴，模型看起来只是「贴图有点乱」；顶点色写错，模型会变成一地彩色碎片。而且这两者的错误都**不会触发任何异常** —— 数据都写进去了，只是不对。

## 顶点色到底是什么

先看一份真实数据。某个角色的 COLOR 通道是一个 `(24068, 4)` 的 `uint8` 数组：

| 通道 | 档位数 | 主要取值 | 含义 |
|---|---|---|---|
| **R** | 9 | `255` 占 93.86% | 大面积「无调整」 |
| **G** | 12 | `128` 占 81.51% | 主体中灰，按材质分区压暗 |
| **B** | **2** | `128` 占 99.96% | **几乎恒定** |
| **A** | 42 | `128` / `102` / `77` / `0` / `51` | 细节最丰富 |

::: danger B 通道恒定说明这不是美术顶点色
美术画的顶点色，四个通道都会随位置连续变化。

这里 B 通道 24068 个顶点里 24058 个都是 `128`，剩下 10 个是 `0`（那 10 个正好是长枪握把接缝处的顶点）。

**`128` 就是 0.5**，是一个「中性、无调整」的编码基准 —— 和法线贴图里 `(128, 128, 255)` 表示「不扰动」是同一个思路。

所以这份数据不是「用来乘到贴图上的颜色」，而是**游戏 shader 逐顶点读取的参数**：不同材质走不同的 shader，各自读不同的通道。
:::

### 把四个通道画出来

数据既然是「每通道独立语义」，那就分通道渲染看图案：

```python
"""把顶点色的四个通道分别当灰度图画出来"""
import numpy as np
from PIL import Image, ImageDraw


def render_channel(pos, tris, chan, ax=0, ay=2, W=520, H=620):
    """把某个通道的值映射成灰度，画到 (ax, ay) 平面上"""
    img = Image.new('L', (W, H), 0)
    dr = ImageDraw.Draw(img)

    a, b = pos[:, ax], pos[:, ay]
    span = max(a.max() - a.min(), b.max() - b.min()) or 1
    scale = (min(W, H) * 0.88) / span
    cx = (a.min() + a.max()) / 2
    cy = (b.min() + b.max()) / 2

    order = np.argsort(pos[tris].mean(axis=1)[:, 2])   # 按深度排序
    for ti in order:
        t = tris[ti]
        pts = [((a[i] - cx) * scale + W / 2,
                H / 2 - (b[i] - cy) * scale) for i in t]
        # 三角形平均的通道值
        g = int(chan[t].mean())
        dr.polygon(pts, fill=g)

    return img
```

渲染结果（左→右 R / G / B / A）：

- **R**：几乎全白，只有眼睛、嘴巴、裙摆内侧有小块暗区
- **G**：按材质分区 —— 裙摆、靴子、衣领被压暗
- **B**：一块纯灰平板（因为值恒定）
- **A**：细节最丰富 —— 五官、布料褶皱、裙摆的渐变

四张图各不相同 → 证明**每个通道都有真实图案**，不是随机噪点。

::: tip 这意味着什么
如果你的模型在 Blender 里显示成「彩虹噪点」，不是数据坏了，是**字节被劈裂了**。看到下一节。
:::

## Blender 里怎么看到顶点色

顶点色在 Blender 里叫**颜色属性**（Color Attribute），存在网格数据上。

### 三种查看方式

| 方式 | 操作 | 能看到什么 |
|---|---|---|
| **A. Solid + 属性** | `Z` → Solid，然后 `Shading` 面板 → `Color` → `Attribute` | 顶点色本身 |
| **B. 材质预览** | `Z` → Material Preview | 贴图（**看不到**顶点色） |
| **C. 着色器节点** | Shader Editor 加 `Attribute` 节点，填 `COLOR_game` | 顶点色参与计算 |

::: warning Solid 模式不显示材质贴图
Solid 模式的「物体颜色 = 属性」读的是**颜色属性层**，完全不采样材质里的图片纹理。

所以：
- 想看**顶点色** → Solid + 属性
- 想看**贴图配色** → 按 `Z` 切 Material Preview（或 Rendered）

这也是**模型全白**最常见的成因 —— 颜色层存在，但没被设为**活动层**，Solid 模式下 Blender 回退显示默认白色。
:::

### 必须设活动颜色层

```python
def activate_color_layer(me, lay):
    """设为活动颜色层，否则 Solid 模式显示的仍是默认白色"""
    for i, a in enumerate(me.color_attributes):
        if a == lay:
            me.color_attributes.active_color_index = i
            me.color_attributes.render_color_index = i     # 渲染也用它
            return True
    return False
```

`active_color_index` 管视口，`render_color_index` 管最终渲染。两个都要设。

## 最大的坑：`foreach_set` 类型不匹配

### 现象

模型上每个三角形颜色都不一样，像彩色噪点拼出来的。

### 原因

Blender 的 `BYTE_COLOR` 层底层是 **4 个 u8 字节**。如果你传 `float32`：

```python
# 错！
lay.data.foreach_set('color_srgb', float32_array.ravel())
```

`float32` 也是 4 字节，于是每个 float 的 4 个字节被当成 4 个 u8 分量读：

```
原始字节  [255, 128, 128, 77]   ← 你说的
被读成    [0,   0,   128, 63]   ← Blender 理解的
```

推导：`float32(1.0)` 的字节是 `00 00 80 3F`，按 u8 读就是 `[0, 0, 128, 63]`。

### 更阴险的地方：连校验都会失效

我第一版写了回读校验：

```python
lay.data.foreach_set('color_srgb', flat)
got = np.empty_like(flat)
lay.data.foreach_get('color_srgb', got)
print(np.abs(got - flat).max())        # 输出 0.000000
```

**误差为 0，校验通过，但模型还是碎。**

因为 `foreach_get` 和 `foreach_set` 是**对称**的：写的时候把 4 个 float 字节按 u8 劈开，读的时候又按同样方式拼回 float32，一进一出正好抵消。

::: danger 这个坑我栽了两次
第一次以为修好了（回读误差 0），模型里看到的还是彩色碎片。
第二次才想到：**校验的基准必须换成原始 uint8，不能用 float**。
:::

### 正确做法

```python
def fs_to_u8(arr, field, ctype):
    """读回的浮点颜色 → 0..255 整数"""
    a = np.clip(np.asarray(arr, dtype=np.float64), 0.0, 1.0)
    if ctype == 'FLOAT_COLOR' and field == 'color':
        # 'color' 字段是线性空间，显示前要转 sRGB
        a = np.where(a <= 0.0031308,
                     a * 12.92,
                     1.055 * np.power(np.maximum(a, 1e-12), 1 / 2.4) - 0.055)
    return np.rint(np.clip(a, 0, 1) * 255).astype(np.int32)


def set_color_layer(ob, me, loops_vi, colors, gidx):
    gi = np.asarray(gidx, dtype=np.int64)
    src = np.asarray(colors, dtype=np.uint8)[gi]
    want = src[loops_vi].astype(np.int32)      # ← 真值 = 原始 uint8

    me.update()

    candidates = [
        ('FLOAT_COLOR', 'color'),        # 最稳：底层 4×float32
        ('FLOAT_COLOR', 'color_srgb'),
        ('BYTE_COLOR', 'color_srgb'),
        ('BYTE_COLOR', 'color'),
    ]

    for ctype, field in candidates:
        lay = me.color_attributes.new(name='COLOR_game',
                                      type=ctype, domain='CORNER')

        wf = want / 255.0
        if ctype == 'FLOAT_COLOR' and field == 'color':
            wf = np.where(wf <= 0.04045,
                          wf / 12.92,
                          ((wf + 0.055) / 1.055) ** 2.4)

        flat = wf.astype(np.float32).ravel()
        lay.data.foreach_set(field, flat)

        got = np.empty(len(flat), dtype=np.float32)
        lay.data.foreach_get(field, got)
        got_u8 = fs_to_u8(got.reshape(-1, 4), field, ctype)
        bad = int((np.abs(got_u8 - want) > 1).any(axis=1).sum())   # 容差 1 档

        if bad == 0:
            print(f'颜色层 {ctype}.{field}（批量写），已用原始字节校验通过')
            activate_color_layer(me, lay)
            return True

        print(f'{ctype}.{field} 批量失败 {bad} 个，改逐元素写')
        for i in range(len(flat) // 4):
            setattr(lay.data[i], field, tuple(float(x) for x in wf[i]))

        got = np.empty(len(flat), dtype=np.float32)
        lay.data.foreach_get(field, got)
        got_u8 = fs_to_u8(got.reshape(-1, 4), field, ctype)
        if int((np.abs(got_u8 - want) > 1).any(axis=1).sum()) == 0:
            print(f'颜色层 {ctype}.{field}（逐元素写），校验通过')
            activate_color_layer(me, lay)
            return True

        me.color_attributes.remove(lay)

    print('⚠ 顶点色全部候选失败，跳过')
    return False
```

### 为什么 FLOAT_COLOR 排第一

| 候选 | 底层存储 | 传 float32 会怎样 |
|---|---|---|
| **FLOAT_COLOR + color** | 4 × `float32` | ✓ 完全匹配，不可能劈裂 |
| FLOAT_COLOR + color_srgb | 4 × `float32` | ✓ 匹配（语义不同） |
| BYTE_COLOR + color_srgb | 4 × `u8` | ✗ 劈裂 |
| BYTE_COLOR + color | 4 × `u8` | ✗ 劈裂 |

`FLOAT_COLOR` 底层就是 4 个 `float32`，你传 `float32` 数组进去，字节布局天然吻合 —— 这才是「类型匹配」。

::: tip 那为什么还要留 BYTE_COLOR 候选
万一你的 Blender 版本对 `FLOAT_COLOR` 支持有问题（或者网格顶点数巨大想省内存），BYTE_COLOR 还能靠**逐元素写**补救。

逐元素写走的是 Python 属性赋值，类型转换由 Blender 自己做，不会劈裂，只是慢（24068 个 loop 大概几秒）。
:::

### 别忘了 A 通道

旧代码里有这么一句：

```python
rgba = np.concatenate([c, np.ones((n_loop, 1))])      # 把 alpha 全设成 1.0
```

看起来无害，但它把真实的 A 通道（42 档细节）全丢了。

**只用 RGB 三列，不要覆盖 alpha。**

## UV

### Blender 里的 UV 是 CORNER 域

UV 不是「每顶点一个」，而是「每 loop 一个」（一个三角形有 3 个 loop，各自有 UV）。

所以从「每顶点 UV」填到 Blender 要经过一次索引展开：

```python
block_uv = np.asarray(uv_global, dtype=np.float32)[gidx]   # 全局 → 本块
vals = block_uv[loops_vi]                                  # 顶点 → loop
lay.data.foreach_set('uv', vals.ravel())
```

`loops_vi` 是「第 i 个 loop 对应哪个顶点」，用 `foreach_get('vertex_index')` 读回来：

```python
def loop_vertex_indices(me, n_verts):
    n = len(me.loops)
    arr = np.empty(n, dtype=np.int32)
    me.loops.foreach_get('vertex_index', arr)
    if arr.min() < 0 or arr.max() >= n_verts:
        raise ValueError(f'loop 顶点索引越界: [{arr.min()}, {arr.max()}]')
    return arr
```

### V 轴翻转

D3D 的 UV 原点在左上，OpenGL / Blender 在左下：

```python
uv[:, 1] = 1.0 - uv[:, 1]
```

::: danger 为什么算法判不出该不该翻转
我试过两种自动判据，都不够可靠：

**判据一：相邻三角形贴图色差**
在同一 UV 岛内，相邻三角形采到的贴图颜色应该相近。翻转后差异变大就是判错了。

实战结果：原样均值 **7.07**，翻转后均值 **6.35** —— 差别只有 10%，噪点级别的信号，判不出。

**判据二：UV v 与模型高度的相关性**
角色贴图通常上半身 UV 靠上，v 应该和高度相关。

实战结果：|corr| X 0.1535 / Y 0.1553 / Z 0.0382 —— 量级太小（可能因为贴图是多个部件拼在一张图上的）。

**结论：只能人眼判。** 把 UV 三角形线框叠到贴图上渲染一张图看一眼最快。
:::

默认按 `v' = 1 - v` 就行 —— 至少 DX11 系游戏（原神、星铁、绝区零、鸣潮等）都是这样。

### UV 层命名

| 层名 | 对应语义 |
|---|---|
| `UVMap` | 主 UV（`TEXCOORD` / SemanticIndex 0） |
| `TEXCOORD1` | 第二套（常用于光照贴图 / 细节遮罩） |
| `TEXCOORD2` | 第三套 |
| `TEXCOORD3`.. | 继续往后 |

::: tip 多于 2 个分量要拆开
如果一个 TEXCOORD 是 4 分量（`R32G32B32A32_FLOAT`），里面其实是**两套 UV** 拼在一起：`xy` 一套，`zw` 一套。

TheHerta4 的做法就是拆成 `TEXCOORD.xy` 和 `TEXCOORD.zw` 两个 UV 图层。
:::

## 关键：做 mod 能不能无损回写

真正要紧的往往不是「在 Blender 里看着像不像」，而是**顶点色不对，做 mod 的时候怎么办**。所以这一节讲清楚哪些数据是无损的、哪些不是。

### 顶点色：完全无损 ✓

因为 COLOR 是纯 `uint8` 搬运，中间没有任何浮点运算：

```python
# 原始 buffer
raw = open('vb1.buf', 'rb').read()
col_bytes = np.frombuffer(raw, dtype=np.uint8).reshape(n, stride)[:, 0:4]

# 侧车 JSON 里的 colors
colors = np.asarray(meta['colors'], dtype=np.uint8)

assert np.array_equal(col_bytes, colors)      # True，逐字节一致
```

验证结果：**24068 个顶点逐字节完全一致**。

所以回写时直接把 `colors` 写回 buffer 的 `@0..@3` 就行，不需要任何转换。

### UV：翻转不是无损的 ✗

如果按 `v' = 1 - v` 翻转后，再从翻转值反算 `1 - v'`，在 float32 下**不还原**。

实测：24068 个顶点里 **302 个**差 1 ulp。例：

```
原始 v = 0.122510254
1 - (1 - 0.122510254) = 0.12251025   ← 差 7.451e-09
```

原因：`1 - v` 是 float32 减法，把低位有效数字舍掉了。

### 解法：侧车 JSON 里存原始字节

```python
import base64

def uv_b64(a):
    return base64.b64encode(
        np.asarray(a, dtype='<f4').tobytes()).decode('ascii')

payload['uv_raw_b64'] = {
    'TEXCOORD': uv_b64(uv0),
    'TEXCOORD1': uv_b64(uv1),
    'TEXCOORD2': uv_b64(uv2),
}
payload['uv_layers'] = {                    # 翻转后的，给 Blender 用
    'TEXCOORD': uv0_flipped.tolist(),
    'TEXCOORD1': uv1_flipped.tolist(),
    'TEXCOORD2': uv2_flipped.tolist(),
}
```

两个都存：
- `uv_layers` → 翻转后，Blender 里直接显示正确
- `uv_raw_b64` → 游戏原始 `float32` 字节，做 mod 时原样写回

### 验证：整条 vb1 重建

用 `colors` + `uv_raw_b64` 重建整个 vb1 buffer：

```
COLOR      ✓ 完全一致
TEXCOORD   ✓ 完全一致
TEXCOORD1  ✓ 完全一致
TEXCOORD2  ✓ 完全一致
─────────────────────
总计 673904 字节  ✓ 完全一致
```

**这就是「能无损回写」的证明。**

### 做 mod 的正确姿势

| 数据 | 用哪个 | 说明 |
|---|---|---|
| **顶点色** | `colors`（uint8） | 纯搬运，无损 |
| **UV** | `uv_raw_b64`（原始字节） | 不要用翻转后的浮点 |
| **展示用 UV** | `uv_layers`（翻转后） | 只给 Blender 看 |
| **权重** | `weights` + `bone_indices` | `float32` / `int32` |
| **顶点位置 / 法线** | 原始 vb0 字节 | 回写时坐标反变换 `(X,Y,Z) → (X,Z,-Y)` |

::: danger 回写坐标要反变换
导入 Blender 时做了 `(x,y,z) → (x,-z,y)`。写回游戏前必须反向：

```
(X, Y, Z) → (X, Z, -Y)
```

漏了这一步，模型会在游戏里躺下或者倒立。
:::

## 自检清单

导入 Blender 后，按顺序检查：

1. **颜色层存在吗** — `Object Data Properties` → `Color Attributes`，应该有 `COLOR_game`
2. **是活动层吗** — 名字左边有高亮（或者代码里设了 `active_color_index`）
3. **Solid + 属性能看到颜色吗** — 能看到「大部分白、局部灰」的图案就对了
4. **看到的是彩色碎片吗** — 是 → 字节劈裂，见上面
5. **UV 有几层** — 按 `N` 面板看 UV Maps，应该有 `UVMap` / `TEXCOORD1` / `TEXCOORD2`
6. **贴图对得上吗** — 切 Material Preview，脸和衣服颜色正常就对了
7. **贴图反了吗** — 如果贴图整体上下颠倒 → V 轴没翻转

任何一步不对，先别改别的，只查这一步。

## 下一步

→ [做回 Mod](/guide/mod/writeback)：把改过的模型写回游戏