# OBJ 路线（最快）

有了顶点、三角形、UV、贴图，写个 OBJ 就能导进 Blender。这一节讲**怎么把朝向弄对** —— 这是 OBJ 路线唯一的难点。

## OBJ 格式速查

```text
# 注释（必须纯 ASCII）
mtllib model.mtl
o model_name
v  -0.529101 -0.042439 0.055176
v  -0.530645 -0.041132 0.055768
...
vt 0.004423 0.753909
vt 0.005112 0.752034
...
vn -0.572331 -0.784331 0.239293
...
usemtl mat_body
g body_59307-0
f 1/1/1 2/2/2 3/3/3
f 2/2/2 1/1/1 4/4/4
...
```

| 行 | 含义 |
|---|---|
| `v x y z` | 顶点坐标 |
| `vt u v` | 纹理坐标 |
| `vn x y z` | 法线 |
| `f a/b/c a/b/c a/b/c` | 面。a=顶点索引，b=UV 索引，c=法线索引。**1-based** |
| `o name` | 对象名 |
| `g name` | 组名 |
| `usemtl name` | 用哪个材质 |

::: danger OBJ 文件头不能写中文
如果第一行注释里有中文，Python 写文件时会报：

```
UnicodeEncodeError: 'ascii' codec can't encode characters in position 46-48
```

因为很多 OBJ 解析器按 ASCII 读。**注释一律写英文**，或者干脆不写。
:::

## 写 OBJ

```python
"""把提取结果写成 OBJ + MTL"""
import numpy as np


def write_obj(path, blocks, mtl_name='model.mtl'):
    """
    blocks: [{
        'name': 'body_59307-0',
        'material': 'mat_body',
        'positions': (N, 3) float64,    # 已做坐标变换
        'uvs':       (N, 2) float64,    # 已做 V 翻转
        'normals':   (N, 3) float64,
        'triangles': (T, 3) int,        # 局部索引，0-based
    }, ...]
    """
    lines = []
    lines.append('# exported from 3dmigoto frame analysis\n')
    lines.append(f'mtllib {mtl_name}\n')

    v_off = vt_off = vn_off = 0

    for blk in blocks:
        pos = blk['positions']
        uvs = blk['uvs']
        nrm = blk['normals']
        tris = blk['triangles']
        n = len(pos)

        lines.append(f"o {blk['name']}\n")

        # 顶点
        for x, y, z in pos:
            lines.append(f'v {x:.6f} {y:.6f} {z:.6f}\n')

        # UV
        for u, v in uvs:
            lines.append(f'vt {u:.6f} {v:.6f}\n')

        # 法线
        for x, y, z in nrm:
            lines.append(f'vn {x:.6f} {y:.6f} {z:.6f}\n')

        # 面
        lines.append(f"usemtl {blk['material']}\n")
        lines.append(f"g {blk['name']}\n")
        for a, b, c in tris:
            # 1-based + 全局偏移
            i0 = a + v_off + 1
            i1 = b + v_off + 1
            i2 = c + v_off + 1
            # UV 索引与顶点索引一一对应（同数量）
            t0 = a + vt_off + 1
            t1 = b + vt_off + 1
            t2 = c + vt_off + 1
            n0 = a + vn_off + 1
            n1 = b + vn_off + 1
            n2 = c + vn_off + 1
            lines.append(
                f'f {i0}/{t0}/{n0} {i1}/{t1}/{n1} {i2}/{t2}/{n2}\n')

        v_off += n
        vt_off += len(uvs)
        vn_off += len(nrm)

    with open(path, 'w', encoding='ascii', newline='\n') as fh:
        fh.writelines(lines)


def write_mtl(path, materials):
    """
    materials: {'mat_body': {'map_kd': 'T_10c4fa9f.png'}, ...}
    """
    lines = []
    for name, m in materials.items():
        lines.append(f'newmtl {name}\n')
        lines.append('Ka 0.000000 0.000000 0.000000\n')
        lines.append('Kd 1.000000 1.000000 1.000000\n')
        lines.append('Ks 0.000000 0.000000 0.000000\n')
        lines.append('d 1.000000\n')
        lines.append('illum 2\n')
        if m.get('map_kd'):
            lines.append(f"map_Kd {m['map_kd']}\n")
        lines.append('\n')

    with open(path, 'w', encoding='ascii', newline='\n') as fh:
        fh.writelines(lines)
```

::: warning 面索引忘了 +1 的症状
如果写成 `f 0/0/0 1/1/1 2/2/2`，Blender 会报「OBJ 索引越界」或者模型缺面。

因为 OBJ 是 1-based：第一个顶点是 `1`，不是 `0`。

**索引 → OBJ 索引的公式：`i_local + block_vertex_offset + 1`**。
:::

## 三个必须做的变换

从 dx 的坐标系到 Blender 的坐标系，要做三件事：

| 变换 | 做了什么 | 必须吗 |
|---|---|---|
| **坐标系转换** | 把 up 轴转到 Z | 必须 |
| **UV V 翻转** | `v' = 1 - v` | 通常必须 |
| **绕序调整** | 反转三角形顶点顺序 | **视情况** |

### 变换 1：坐标系

D3D 的坐标系：**Y 向上**，-Z 向前（右手系，但 forward 是 -Z）
Blender 的坐标系：**Z 向上**，-Y 向前

标准的转换矩阵（`axis_conversion`）：

```
Blender_X =  dx_X
Blender_Y = -dx_Z
Blender_Z =  dx_Y
```

代码：

```python
def to_blender_yup(v):
    """(x, y, z) -> (x, -z, y)"""
    return np.stack([v[:, 0], -v[:, 2], v[:, 1]], axis=1)
```

::: tip 这个变换的行列式是 +1
意味着它**不改变手性**，所以三角形绕序不需要额外翻转。

这是最常用的变换，SSMT4 的 TheHerta4 插件就是这么做的：

```python
obj.matrix_world = axis_conversion(
    from_forward='-Z', from_up='Y').to_4x4()
```
:::

### 变换 2：UV V 翻转

```python
def flip_v(uv):
    """v' = 1 - v"""
    out = uv.copy()
    out[:, 1] = 1.0 - out[:, 1]
    return out
```

::: danger 别用浮点运算的结果做 mod 回写
`1 - (1 - v)` 在 float32 下**不可逆**。实测 24068 个顶点里有 **302 个**不还原（差 1 ulp，比如 `0.12251025` vs `0.122510254`）。

所以如果你要做 mod，**必须保留原始 UV 的字节**，不要靠翻转后的值反算。

见[做回 Mod](/guide/mod/writeback)。
:::

### 变换 3：绕序

dx11 的默认面朝向规则和 Blender 不同。要不要翻转，**必须实测**，不能猜。

方法见下一节。

## 判定绕序：用几何法线 vs 顶点法线

这是最可靠的自动判据。

### 原理

对于一个三角形 `(p0, p1, p2)`：

- **几何法线**（面的法线）= `(p1 - p0) × (p2 - p0)`
- **顶点法线**（游戏给的）

如果绕序正确（逆时针 = 面朝外），几何法线和顶点法线**同向**（点积 > 0）。

如果绕序反了，点积会是负的。

### 实现

```python
"""用几何法线 vs 顶点法线判定绕序是否正确"""
import numpy as np


def check_winding(pos, tris, normals):
    """
    返回 (同向比例, 面积加权平均点积, 中位数点积)
    """
    p0 = pos[tris[:, 0]]
    p1 = pos[tris[:, 1]]
    p2 = pos[tris[:, 2]]

    # 几何法线（未归一化，长度 = 2 * 面积）
    geo = np.cross(p1 - p0, p2 - p0)

    # 面积（叉积长度的一半）
    area = np.linalg.norm(geo, axis=1) * 0.5
    total_area = area.sum()

    # 退化三角形（面积接近 0）跳过
    valid = area > 1e-12
    if valid.sum() == 0:
        return None

    # 三角形平均顶点法线
    vn = (normals[tris[:, 0]] + normals[tris[:, 1]] +
          normals[tris[:, 2]]) / 3.0

    # 点积
    dot = (geo[valid] * vn[valid]).sum(axis=1)

    same = (dot > 0).sum()
    n = valid.sum()

    # 面积加权平均（归一化后的方向一致性）
    w = area[valid]
    weighted = (dot * w).sum() / w.sum() / \
        (np.linalg.norm(geo[valid], axis=1) *
         np.linalg.norm(vn[valid], axis=1) + 1e-20).mean()

    return same / n, (dot * w).sum() / w.sum(), np.median(
        dot / (np.linalg.norm(geo[valid], axis=1) *
               np.linalg.norm(vn[valid], axis=1) + 1e-20))
```

### 判读

| 同向比例 | 结论 |
|---|---|
| > 95% | ✓ 绕序正确，**不要翻转** |
| < 5% | ✗ 绕序反了，**翻转所有三角形** |
| 40%–60% | 布局错位，法线读的是别的字段 |
| 其他 | 有问题的区域占比较大，需要检查 |

::: details 为什么会有 5% 的例外
因为有些模型的法线本身有误差（美术手工刷的），或者有**内侧面**（比如裙摆内侧、嘴部内腔）。

实战案例：**29596/29606 = 99.97% 同向**，面积加权 +0.9801，中位数 +0.995 —— 结论非常明确。

剩下 4 个不同向的应该是裙摆内侧那种双面材质。
:::

### 翻转

```python
def flip_winding(tris):
    """交换每行的第 2、3 列"""
    out = tris.copy()
    out[:, [1, 2]] = out[:, [2, 1]]
    return out
```

## 判定 up 轴

坐标系变换需要知道**源数据的 up 是哪个轴**。dx 通常是 Y，但不是绝对。

### 判据一：最长轴（不可靠）

「人的身高是最长的跨度」→ 最长轴就是 up。

```python
span = pos.max(0) - pos.min(0)
up_axis = int(np.argmax(span))
```

::: danger 这个判据经常错
如果模型的姿势是**躺着的**或者**腿伸开的**，最长轴可能是别的方向。

实战案例里我一开始用这个判据，得出 up = X（跨度 1.602），结果渲染出来是躺姿 —— 因为那份缓冲是**已蒙皮的**，腿伸向 X 方向。
:::

### 判据二：两端法线朝向（不可靠）

人的头顶和脚底的顶点，法线应该分别朝上和朝下。

```python
# 实战结果：X 判据分 +0.446、Y +0.604、Z +0.620
# 差别太小，判不出
```

不可靠。因为模型法线分布往往三轴接近均匀（实测 abs 均值占比 X 29.3% / Y 38.9% / Z 31.8%）。

### 判据三：截面宽厚比（**这个靠谱**）

沿某个轴切片，看每个切片的横截面轮廓：

- **躯干/腿/手臂的横截面接近圆形**（宽度 ≈ 厚度）
- **沿身高方向切片，横截面的「宽度/厚度」比值会接近 1**
- **沿非身高方向切片，横截面是个细长的椭圆**

```python
"""沿某轴切片，算每片横截面的宽度/厚度比"""
import numpy as np


def axis_profile(pos, axis, bins=24):
    """
    沿 axis 方向切 bins 片，每片算另外两轴的跨度比。
    返回 (均值宽厚比, 每片详情)
    """
    lo, hi = pos[:, axis].min(), pos[:, axis].max()
    edges = np.linspace(lo, hi + 1e-9, bins + 1)
    others = [i for i in range(3) if i != axis]

    ratios = []
    detail = []
    for i in range(bins):
        m = (pos[:, axis] >= edges[i]) & (pos[:, axis] < edges[i + 1])
        if m.sum() < 10:
            continue
        sub = pos[m][:, others]
        span = sub.max(0) - sub.min(0)
        w, t = span[0], span[1]
        ratio = max(w, t) / max(min(w, t), 1e-9)
        ratios.append(ratio)
        detail.append((i, m.sum(), w, t, ratio))

    return float(np.median(ratios)) if ratios else float('inf'), detail


for ax, name in [(0, 'X'), (1, 'Y'), (2, 'Z')]:
    ratio, _ = axis_profile(pos, ax)
    print(f'沿 {name} 轴切片，中位宽厚比 = {ratio:.2f}')
```

### 实战输出

```
沿 X 轴切片，中位宽厚比 = 1.11
沿 Y 轴切片，中位宽厚比 = 2.35
沿 Z 轴切片，中位宽厚比 = 2.08
```

**只有 X 轴的比值接近 1**（1.11）→ 说明沿 X 切出来的横截面接近圆形 → X 是身高方向。

::: tip 这个判据的适用条件
- 模型是**人形或类人形**（有躯干、四肢）
- 模型处于**自然姿势**（T-pose / A-pose / 站姿）

不适用于：球体、车辆、建筑物。

而且**必须用 T-pose 的缓冲**判。用已蒙皮的缓冲，四肢张开会让别的轴看起来最长。
:::

### 判据四：人眼确认（最终裁决）

不管算法给出什么，**渲染一张三视图看一眼**。

```python
"""三视图点云/线框渲染，肉眼确认朝向"""
from PIL import Image, ImageDraw
import numpy as np


def render_views(pos, tris, out_path, W=700, H=860):
    views = [
        ('X-Y', 0, 1),
        ('X-Z', 0, 2),
        ('Y-Z', 1, 2),
    ]

    canvas = Image.new('RGB', (W * 3, H), (18, 18, 22))
    for vi, (label, ax, ay) in enumerate(views):
        img = Image.new('RGB', (W, H), (18, 18, 22))
        dr = ImageDraw.Draw(img)

        a = pos[:, ax]
        b = pos[:, ay]
        lo_a, hi_a = a.min(), a.max()
        lo_b, hi_b = b.min(), b.max()
        span = max(hi_a - lo_a, hi_b - lo_b) or 1
        scale = (min(W, H) * 0.85) / span

        cx = (lo_a + hi_a) / 2
        cy = (lo_b + hi_b) / 2

        def proj(i):
            x = (a[i] - cx) * scale + W / 2
            y = H / 2 - (b[i] - cy) * scale     # 屏幕 y 向下，翻转
            return x, y

        for t in tris[::max(1, len(tris) // 20000)]:
            pts = [proj(i) for i in t]
            dr.polygon(pts, outline=(120, 200, 255))

        dr.text((10, 10), label, fill=(255, 255, 255))
        canvas.paste(img, (vi * W, 0))
        dr2 = ImageDraw.Draw(canvas)
        dr2.text((vi * W + 10, 30),
                 f'{label}: {a.max()-a.min():.3f} x '
                 f'{b.max()-b.min():.3f}', fill=(200, 200, 200))

    canvas.save(out_path)
```

看到清晰的人形剪影 → 判定对了。

::: warning 图像上下颠倒怎么办
PIL 的像素 y 轴向下，模型的 Z 轴向上。如果渲染出来是倒立的，把 `y` 方向翻转（上面代码里的 `H/2 - ...` 已经做了）。

但注意：**以 up 轴为竖轴的那个视图**才需要翻转。俯视图（XY 平面）不需要。
:::

## 完整流程

```python
"""从相位缓冲到 OBJ 的完整流程"""
import numpy as np

# ---- 1. 读数据（前面章节的结果）----
pos = pos_all['POSITION']
nrm = pos_all['NORMAL']
uv = tex_all['TEXCOORD']
col = tex_all['COLOR']
tris = triangles

# ---- 2. 判定 up 轴 ----
up_axis = judge_up_axis(pos)        # 见上面

# ---- 3. 坐标变换 ----
if up_axis == 1:                    # Y up（最常见）
    pos_b = np.stack([pos[:, 0], -pos[:, 2], pos[:, 1]], axis=1)
    nrm_b = np.stack([nrm[:, 0], -nrm[:, 2], nrm[:, 1]], axis=1)
elif up_axis == 2:                  # Z up（已经是 Blender 系）
    pos_b, nrm_b = pos.copy(), nrm.copy()
elif up_axis == 0:                  # X up（罕见，要额外绕过）
    pos_b = np.stack([-pos[:, 2], pos[:, 1], -pos[:, 0]], axis=1)
    nrm_b = np.stack([-nrm[:, 2], nrm[:, 1], -nrm[:, 0]], axis=1)

# ---- 4. UV 翻转 ----
uv_b = uv.copy()
uv_b[:, 1] = 1.0 - uv_b[:, 1]

# ---- 5. 绕序 ----
ratio, wavg, p50 = check_winding(pos_b, tris, nrm_b)
print(f'绕序: {ratio*100:.2f}% 同向, 加权 {wavg:+.4f}, 中位 {p50:+.4f}')
if ratio < 0.05:
    tris = flip_winding(tris)
    print('  -> 已翻转折序')

# ---- 6. 写文件 ----
write_obj('model.obj', blocks, 'model.mtl')
write_mtl('model.mtl', materials)
```

## 渲染验证

写完 OBJ 一定要渲染看一眼。用前面 `render_views` 或者更完整的着色渲染：

```python
"""带贴图和光照的渲染，用于最终确认"""
def render_shaded(pos, tris, uv, normals, tex_path, out_path):
    from PIL import Image
    tex = np.asarray(Image.open(tex_path).convert('RGB')) / 255.0
    th, tw = tex.shape[:2]

    light = np.array([0.45, -0.35, 0.82])
    light /= np.linalg.norm(light)

    # 面法线
    p0, p1, p2 = pos[tris[:, 0]], pos[tris[:, 1]], pos[tris[:, 2]]
    geo = np.cross(p1 - p0, p2 - p0)
    ln = np.linalg.norm(geo, axis=1, keepdims=True)
    geo_n = geo / np.maximum(ln, 1e-12)

    # 光照
    lam = np.abs(geo_n @ light)         # abs: 双面
    shade = 0.35 + 0.65 * lam

    # 采样贴图（三角形质心）
    tri_uv = uv[tris].mean(axis=1)
    px = np.clip((tri_uv[:, 0] * tw).astype(int), 0, tw - 1)
    py = np.clip(((1 - tri_uv[:, 1]) * th).astype(int), 0, th - 1)
    base = tex[py, px]

    col = np.clip(base * shade[:, None] * 255, 0, 255).astype(np.uint8)

    # 深度排序后画
    order = np.argsort(-p0[:, 2] - p1[:, 2] - p2[:, 2])
    # ... 后续用 PIL 画多边形
```

看渲染图：

| 现象 | 结论 |
|---|---|
| 完整人形 + 贴图正确 | ✓ 全部对了 |
| 人形但黑/白一片 | 贴图路径错，或 UV 采样错 |
| 人形但颜色错乱 | V 轴反了 |
| 一片彩色尖刺 | 绕序全反，或索引漏了 base_vertex |
| 只有半个身体 | 只取了一段 |

## OBJ 路线的局限

| 局限 | 影响 | 解决 |
|---|---|---|
| 只支持一套 UV | 多层 UV 只能存一套 | 走[脚本路线](/guide/blender/script) |
| 顶点组只能靠顶点组名 | OBJ 没有顶点组格式 | 走脚本路线 |
| 顶点色支持不稳定 | 不同 Blender 版本行为不同 | 走脚本路线 |
| 多对象要勾选 Split by Object | 容易忘 | 记住就行 |

::: tip 什么时候用 OBJ
- 只想看看模型长什么样
- 只做静态摆件 / 渲染图
- 不打算改回游戏

需要骨骼权重、多层 UV、无损顶点色的，走脚本路线。
:::

## 导入 Blender 的操作

1. `File` → `Import` → `Wavefront (.obj)`
2. 在右侧面板勾选：
   - **Split by Object** — 每段一个独立对象
   - **Split by Group** — 如果用了 `g` 行
   - **Keep Vertex Order** — 保持顶点顺序（做 mod 时重要）
3. **不要勾**：
   - `Forward Axis` / `Up Axis` 保持默认（`-Z` / `Y`）—— 因为文件里已经做好变换了
   - 任何 Scale 相关选项 —— 保持 1.0

::: danger 导入时重新旋转会双重变换
文件里已经做过 `(x,y,z) → (x,-z,y)`，如果导入器再按 `Up=Y` 转一次，模型会躺下或者倒立。

**导入时所有轴选项保持默认。**
:::

## 下一步

→ [脚本路线](/guide/blender/script)：顶点组、多层 UV、顶点色都带上