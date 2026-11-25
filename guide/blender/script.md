# 脚本路线（完整）

OBJ 路线能看能改，但要**做 mod** 就不够了 —— 顶点组、多层 UV、顶点色、骨骼矩阵这些，OBJ 格式装不下。

这一节讲怎么用 Python 脚本在 Blender 里把这些全部建出来。

## 为什么必须用脚本

| 数据 | OBJ 能装吗 | 脚本能装吗 |
|---|---|---|
| 顶点 / 三角形 | ✓ | ✓ |
| 一套 UV | ✓ | ✓ |
| **3 套 UV** | ✗ | ✓ |
| 顶点法线 | ✓ | ✓ |
| 自定义拆分法线 | ✗ | ✓ |
| **顶点组（骨骼权重）** | ✗（只能靠组顺序猜） | ✓ |
| **顶点色** | 不稳定 | ✓ |
| 材质 + 贴图 | ✓（MTL） | ✓ |
| 对象自定义属性 | ✗ | ✓ |

::: tip 做 mod 的最低要求
至少要有：**顶点位置**、**UV**、**顶点组**。缺顶点组就没法跟着骨架动，改完写回去也蒙不了皮。
:::

## Blender 4.x 的建网格方式

::: danger 千万别手工拼拓扑
下面这段代码**会让 Blender 直接崩溃**（进程消失，无 Python 回溯）：

```python
me = bpy.data.meshes.new('m')
me.vertices.add(n)
me.loops.add(n_tri * 3)
me.loops.foreach_set('vertex_index', idx)
me.polygons.add(n_tri)
me.polygons.foreach_set('loop_start', starts)
me.update(calc_edges=True)      # ← 段错误在这里
```

原因是：4.x 里 `polygons[].loop_total` 变成了**只读的派生属性**，你写不进去。于是 `loop_start` 和实际 loop 数的对应关系无效，`update(calc_edges=True)` 遍历边表时越界。

**必须用 `from_pydata()`。**
:::

### 正确方式

```python
me = bpy.data.meshes.new(name)
me.from_pydata(verts, [], faces)     # verts: [(x,y,z), ...], faces: [(a,b,c), ...]
me.update()
```

`from_pydata` 一次性建对 vertices / edges / loops / polygons 四套数据，索引关系自动正确。

建完之后，用 `foreach_set` 批量填 UV / 颜色 / 自定义法线都是安全的。

## 完整脚本骨架

```python
"""从侧车 JSON + OBJ 在 Blender 里重建模型（骨架版）"""
import json
import os

import bpy
import numpy as np


# ============ 配置 ============
TARGET_DIR = r'C:\path\to\out\blocks'
OBJ_NAME = 'model.obj'
JSON_NAME = 'model_data.json'
SET_CUSTOM_NORMALS = True
SHOW_VERTEX_COLOR_IN_SOLID = True
COLLECTION_NAME = 'extracted'


def log(msg):
    print(f'[import] {msg}')


# ============ 读 OBJ ============
def read_obj(path):
    """
    返回 (verts, normals, uvs, blocks)

    blocks: [{'name', 'v_start', 'v_count', 'faces'}, ...]
    """
    verts, normals, uvs = [], [], []
    blocks = []
    cur = None
    v_base = 0
    n_base = 0
    t_base = 0

    with open(path, 'r', errors='ignore') as fh:
        for line in fh:
            s = line.strip()
            if not s or s.startswith('#'):
                continue

            parts = s.split()
            tag = parts[0]

            if tag == 'v' and len(parts) >= 4:
                verts.append([float(x) for x in parts[1:4]])
            elif tag == 'vn' and len(parts) >= 4:
                normals.append([float(x) for x in parts[1:4]])
            elif tag == 'vt' and len(parts) >= 3:
                uvs.append([float(x) for x in parts[1:3]])
            elif tag == 'g':
                name = ' '.join(parts[1:])
                cur = {
                    'name': name,
                    'v_start': v_base,
                    'v_count': 0,
                    'faces': [],
                }
                blocks.append(cur)
            elif tag == 'f':
                if cur is None:
                    continue
                tri = []
                for tok in parts[1:]:
                    vi = tok.split('/')
                    tri.append(int(vi[0]) - 1 - v_base)   # 转块内 0-based
                cur['faces'].append(tuple(tri))

    # 补齐每块的顶点数（用面索引最大值）
    for blk in blocks:
        if blk['faces']:
            hi = max(max(f) for f in blk['faces'])
            blk['v_count'] = hi + 1
        # 累积偏移（下一个 g 的起点）
    # 用 v_start 顺序推 v_count
    for i, blk in enumerate(blocks):
        if i + 1 < len(blocks):
            blk['v_count'] = blocks[i + 1]['v_start'] - blk['v_start']
        else:
            blk['v_count'] = len(verts) - blk['v_start']

    return (np.asarray(verts, dtype=np.float64),
            np.asarray(normals, dtype=np.float64),
            np.asarray(uvs, dtype=np.float64),
            blocks)
```

::: warning 读 OBJ 时最容易错的两处
1. **`f` 行的索引是 1-based**，减 1 之后还要减去**当前块的顶点偏移**，才得到块内局部索引。
2. **`v_count` 不能只靠面的最大值** —— 有些顶点可能不被任何面引用（孤立顶点）。要用下一个块的 `v_start` 或总顶点数来算。
:::

## 建网格

```python
def make_mesh(name, verts, faces, collection):
    me = bpy.data.meshes.new(name)
    me.from_pydata([tuple(v) for v in verts], [], faces)
    me.update()

    ob = bpy.data.objects.new(name, me)
    collection.objects.link(ob)

    # 校验
    n_face = len(me.polygons)
    if n_face != len(faces):
        log(f'  ⚠ {name}: 面数 {n_face} != 期望 {len(faces)}')

    return ob
```

## 填 UV 层

UV 在 Blender 里是 **CORNER 域**（每个 loop 一个 UV，不是每顶点一个），所以要做索引映射。

```python
def set_uv_layers(ob, me, loops_vi, uv_layers, gidx):
    """
    uv_layers: [(层名, (N,2) 数组), ...]
    gidx:      块内顶点号 -> 全局顶点号
    loops_vi:  每个 loop 对应的块内顶点号
    """
    for name, uv in uv_layers:
        lay = me.uv_layers.new(name=name)
        # uv 是按全局顶点索引的；先取到本块，再按 loop 展开
        block_uv = np.asarray(uv, dtype=np.float32)[np.asarray(gidx, dtype=np.int64)]
        vals = block_uv[loops_vi]                     # (n_loop, 2)
        lay.data.foreach_set('uv', vals.ravel())
        log(f'  UV {name}: {len(vals)} loops')
```

::: tip `loops_vi` 怎么来
用 `foreach_get` 从网格读回来：

```python
def loop_vertex_indices(me, n_verts):
    n = len(me.loops)
    arr = np.empty(n, dtype=np.int32)
    me.loops.foreach_get('vertex_index', arr)
    if arr.min() < 0 or arr.max() >= n_verts:
        raise ValueError(f'loop 顶点索引越界: [{arr.min()}, {arr.max()}]')
    return arr
```

**不要假设**「第 i 个 loop 对应第 i//3 个三角形的某个顶点」—— `from_pydata` 之后顺序是有保证的，但自己算容易错。读回来最稳。
:::

## 填顶点色

这一部分是整套流程里**最容易出错**的地方。

### 核心问题：`foreach_set` 的类型必须匹配

Blender 的 `BYTE_COLOR` 层底层是 **4 个 u8 字节**。如果你传一个 `float32` 数组进去：

```python
# 错！会导致彩虹碎片
lay.data.foreach_set('color_srgb', float32_array.ravel())
```

`float32` 也是 4 字节，于是每个 float 的 4 个字节被当作 4 个 u8 分量读：

```
期望 [255, 128, 128, 77]
实得 [0, 0, 128, 63]
```

**一整个模型变成彩虹噪点。**

### 更阴险的地方：校验也会失效

如果你写完回读校验：

```python
written = float32_array.ravel()
got = np.empty_like(written)
lay.data.foreach_get('color_srgb', got)
assert np.allclose(written, got)     # ← 永远通过！
```

因为 `foreach_get` 和 `foreach_set` 是**对称**的 —— 读的时候也按同样的方式把 4 个 u8 拼回一个 float32，一进一出正好抵消。

::: danger 这个坑我栽了两次
第一次以为修好了，回读误差 0.000000，结果模型里还是彩虹碎片。

**校验必须以原始 uint8 为基准**，不能以 float 为基准。
:::

### 正确实现

```python
# format: '<u1' / '<f4' / '<f2' 等
def fs_to_u8(arr, field, ctype):
    """把读回来的浮点颜色转成 0..255 的整数"""
    a = np.clip(np.asarray(arr, dtype=np.float64), 0.0, 1.0)
    if ctype == 'FLOAT_COLOR' and field == 'color':
        # 'color' 字段是线性空间，显示前要转 sRGB
        a = np.where(a <= 0.0031308,
                     a * 12.92,
                     1.055 * np.power(np.maximum(a, 1e-12), 1 / 2.4) - 0.055)
    return np.rint(np.clip(a, 0, 1) * 255).astype(np.int32)


def set_color_layer(ob, me, loops_vi, colors, gidx):
    """
    colors: (N_total, 4) uint8 原始顶点色
    真值基准 = 原始 uint8，不用 float
    """
    gi = np.asarray(gidx, dtype=np.int64)
    src = np.asarray(colors, dtype=np.uint8)[gi]         # 本块的原始字节
    want = src[loops_vi].astype(np.int32)                # (n_loop, 4) 期望值

    me.update()

    # 候选顺序：FLOAT_COLOR + color 最稳（底层 4×float32，不可能劈裂）
    candidates = [
        ('FLOAT_COLOR', 'color'),
        ('FLOAT_COLOR', 'color_srgb'),
        ('BYTE_COLOR', 'color_srgb'),
        ('BYTE_COLOR', 'color'),
    ]

    for ctype, field in candidates:
        try:
            lay = me.color_attributes.new(name='COLOR_game',
                                          type=ctype, domain='CORNER')
        except Exception as e:
            log(f'  建层失败 {ctype}.{field}: {e}')
            continue

        # 写入值：根据字段语义选 sRGB 还是线性
        wf = want / 255.0
        if ctype == 'FLOAT_COLOR' and field == 'color':
            wf = np.where(wf <= 0.04045,
                          wf / 12.92,
                          ((wf + 0.055) / 1.055) ** 2.4)

        flat = wf.astype(np.float32).ravel()
        try:
            lay.data.foreach_set(field, flat)
        except Exception as e:
            log(f'  写入失败 {ctype}.{field}: {e}')
            me.color_attributes.remove(lay)
            continue

        # 回读校验（以原始 uint8 为基准）
        got = np.empty(len(flat), dtype=np.float32)
        lay.data.foreach_get(field, got)
        got_u8 = fs_to_u8(got.reshape(-1, 4), field, ctype)
        bad = int((np.abs(got_u8 - want) > 1).any(axis=1).sum())

        if bad == 0:
            log(f'  颜色层 {ctype}.{field}（批量写），'
                f'已用原始字节校验通过')
            _activate(me, lay)
            return True

        log(f'  {ctype}.{field} 批量写后 {bad}/{len(want)} 个 loop 不符，'
            f'改逐元素写')

        # 逐元素补救
        for i in range(len(flat) // 4):
            try:
                setattr(lay.data[i], field, tuple(float(x)
                                                  for x in wf[i]))
            except Exception:
                break

        got = np.empty(len(flat), dtype=np.float32)
        lay.data.foreach_get(field, got)
        got_u8 = fs_to_u8(got.reshape(-1, 4), field, ctype)
        bad = int((np.abs(got_u8 - want) > 1).any(axis=1).sum())

        if bad == 0:
            log(f'  颜色层 {ctype}.{field}（逐元素写），校验通过')
            _activate(me, lay)
            return True

        log(f'  {ctype}.{field} 逐元素仍 {bad} 个不符，丢弃该层')
        me.color_attributes.remove(lay)

    log('  ⚠ 顶点色全部候选失败，跳过（不影响 UV / 权重 / 材质）')
    return False


def _activate(me, lay):
    """设为活动颜色层 —— 否则 Solid 模式显示的仍是默认白色"""
    idx = None
    for i, a in enumerate(me.color_attributes):
        if a == lay:
            idx = i
            break
    if idx is not None:
        me.color_attributes.active_color_index = idx
        me.color_attributes.render_color_index = idx
```

::: tip 为什么要设 `active_color_index`
Blender 的 Solid 模式（物体颜色 = 属性）读的是**活动颜色层**。层存在但没有设为活动时，会回退到默认白色。

「模型全白」十有八九就是这个原因。
:::

## 填顶点组

顶点组 = 骨骼 ID → 权重。

```python
def set_vertex_groups(ob, me, loops_vi, weights, bones, gidx):
    """
    weights: (N_total, 4) float32，每顶点 4 个权重
    bones:   (N_total, 4) int32，每顶点 4 个骨骼 ID
    """
    gi = np.asarray(gidx, dtype=np.int64)
    W = np.asarray(weights, dtype=np.float32)[gi]        # (n, 4)
    B = np.asarray(bones, dtype=np.int64)[gi]            # (n, 4)

    n = len(W)

    # 无效骨骼的哨兵值：65535 / -1
    B[B >= 65535] = -1
    B[B < 0] = -1

    # 权重为 0 的槽位也标记无效
    invalid = (B < 0) | (W <= 1e-6)

    # 展开成 (顶点, 骨骼, 权重) 三元组
    vidx = np.repeat(np.arange(n), 4)
    bidx = B.ravel()
    widx = W.ravel()
    keep = ~invalid.ravel()
    vidx, bidx, widx = vidx[keep], bidx[keep], widx[keep]

    if len(vidx) == 0:
        log('  ⚠ 没有有效权重')
        return

    # 同一顶点同一骨骼可能出现在多个槽（=4 个槽都给同一根骨骼）
    # 必须先合并，否则后写覆盖前写，权重和 < 1
    order = np.lexsort((bidx, vidx))
    vidx, bidx, widx = vidx[order], bidx[order], widx[order]

    # 同 (v, b) 的分组求和
    key = vidx.astype(np.int64) * 100000 + bidx
    uniq, start, counts = np.unique(key, return_index=True,
                                    return_counts=True)
    sums = np.add.reduceat(widx, start)
    gv = vidx[start]
    gb = bidx[start]

    # 归一化
    total = np.zeros(n, dtype=np.float64)
    np.add.at(total, gv, sums)
    ok = total[gv] > 1e-9
    sums = sums[ok] / total[gv[ok]]
    gv, gb = gv[ok], gb[ok]

    # 批量建组
    max_bone = int(gb.max()) + 1
    if max_bone > 10000:
        raise ValueError(
            f'骨骼数 {max_bone} 超过 10000，基本不可能是正常情况，'
            f'布局或数据类型选错了')

    groups = {}
    for b in np.unique(gb):
        groups[int(b)] = ob.vertex_groups.new(name=str(int(b)))

    # 按 (骨骼, 权重档) 分桶批量 add
    for b in np.unique(gb):
        m = gb == b
        vs = gv[m]
        ws = sums[m]
        g = groups[int(b)]
        # 权重分桶（减少 add 次数）
        q = np.round(ws * 1000).astype(np.int64)
        for qv in np.unique(q):
            mm = q == qv
            g.add(vs[mm].tolist(), float(ws[mm][0]), 'REPLACE')

    log(f'  顶点组 {len(groups)} 个，{len(gv)} 个有效绑定')
```

::: danger 不合并会丢权重
旧的写法是逐槽 `REPLACE`：

```text
for k in range(4):
    if 该顶点第 k 槽有有效骨骼:
        grp.add([vi], W[vi, k], 'REPLACE')     # ← 后写覆盖前写
```

如果同一顶点在第 0 槽和第 2 槽都有骨骼 90（可能因为权重分配算法留下的），第二次会覆盖第一次，最终权重只有其中一个 → 权重和 < 1 → Blender 里模型变形不足。

**必须按 (顶点, 骨骼) 先聚合再写。**
:::

::: tip 顶点组名用数字字符串
不是骨骼名字，因为转储里**没有骨骼名字**。

只有 `vs-t0` 里的 141 个 4×3 矩阵，ID 从 0 到 140。组名就是 `"0"`、`"1"`、...、`"140"`。

日后拿到对应的骨架文件（`.blend` 或游戏里的骨骼定义），只要 ID 对得上就能直接 `Ctrl+P` → `Armature Deform`。
:::

## 填自定义拆分法线

游戏的法线常常是「每个面角独立、不相连的」，而 Blender 默认按面自动平滑。

```python
def set_custom_normals(ob, me, block_normals):
    """保留游戏原始法线"""
    try:
        me.normals_split_custom_set_from_vertices(
            [tuple(n) for n in block_normals])
        log(f'  自定义法线：{len(block_normals)} 个顶点')
        return True
    except Exception as e:
        log(f'  ⚠ 自定义法线失败（可忽略）: {e}')
        return False
```

::: tip 这个失败了也不影响
如果你的模型是低模、法线基本是面法线，可以不用自定义法线。把它设成 `SET_CUSTOM_NORMALS = False` 就行。

但如果模型看起来「有奇怪的黑色接缝」，通常是法线问题。
:::

## 材质

```python
def set_material(ob, name, png_path):
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    nt = mat.node_tree
    bsdf = nt.nodes.get('Principled BSDF')

    if png_path and os.path.isfile(png_path):
        img = bpy.data.images.load(png_path, check_existing=True)
        img.colorspace_settings.name = 'sRGB'
        tex = nt.nodes.new('ShaderNodeTexImage')
        tex.image = img
        tex.location = (-400, 200)
        nt.links.new(tex.outputs['Color'], bsdf.inputs['Base Color'])
        log(f'  材质 {name}: 贴图 {os.path.basename(png_path)}')

    ob.data.materials.append(mat)
```

## 对象自定义属性

把元信息挂到对象上，方便日后识别：

```python
ob['3DMigoto:GameTypeName'] = game_type_name
ob['SSMT:DrawIB'] = draw_ib
ob['SSMT:PartName'] = block_name
ob['3DMigoto:RecalculateTANGENT'] = False
ob['3DMigoto:RecalculateCOLOR'] = False
```

::: tip 为什么写这些
有些工具（包括 TheHerta4 插件）靠这些属性识别「这个对象是从哪提取的」。

而且自己日后翻旧工程，看到 `SSMT:DrawIB = 7ad7e69e` 就知道对应哪个转储。
:::

## 完整 main

```python
def main():
    out_dir = TARGET_DIR

    # 1. 读数据
    verts, normals, uvs, blocks = read_obj(
        os.path.join(out_dir, OBJ_NAME))
    with open(os.path.join(out_dir, JSON_NAME), 'r',
              encoding='utf-8') as fh:
        meta = json.load(fh)

    log(f'OBJ: {len(verts)} 顶点, {len(normals)} 法线, '
        f'{len(uvs)} UV, {len(blocks)} 块')

    # 2. 建集合
    coll = bpy.data.collections.get(COLLECTION_NAME)
    if coll is None:
        coll = bpy.data.collections.new(COLLECTION_NAME)
        bpy.context.scene.collection.children.link(coll)

    colors = np.asarray(meta['colors'], dtype=np.uint8)
    weights = np.asarray(meta['weights'], dtype=np.float32)
    bones = np.asarray(meta['bone_indices'], dtype=np.int64)

    uv_layers = [
        ('UVMap', np.asarray(meta['uv_layers']['TEXCOORD'])),
        ('TEXCOORD1', np.asarray(meta['uv_layers']['TEXCOORD1'])),
        ('TEXCOORD2', np.asarray(meta['uv_layers']['TEXCOORD2'])),
    ]

    # 3. 逐块处理
    for spec in meta['blocks']:
        name = spec['name']
        log(f'--- {name} ---')

        off = spec['obj_vertex_offset']
        cnt = spec['vertex_count']
        gidx = np.asarray(spec['global_indices'], dtype=np.int64)

        blk = next(b for b in blocks if b['name'] == name)
        block_verts = verts[off:off + cnt]
        block_normals = normals[off:off + cnt]
        block_faces = [tuple(i - off for i in f) for f in blk['faces']]

        # 校验
        for f in block_faces:
            if min(f) < 0 or max(f) >= cnt:
                raise ValueError(
                    f'{name}: 面索引越界 {f} vs cnt={cnt}')

        ob = make_mesh(name, block_verts, block_faces, coll)
        me = ob.data
        loops_vi = loop_vertex_indices(me, cnt)

        # 填数据
        set_uv_layers(ob, me, loops_vi, uv_layers, gidx)
        set_color_layer(ob, me, loops_vi, colors, gidx)
        if SET_CUSTOM_NORMALS:
            set_custom_normals(ob, me, block_normals)
        set_vertex_groups(ob, me, loops_vi, weights, bones, gidx)
        set_material(ob, spec['material'],
                     os.path.join(out_dir, spec['diffuse_png']))

        # 元信息
        ob['3DMigoto:GameTypeName'] = meta.get('game_type', '')
        ob['SSMT:DrawIB'] = meta.get('draw_ib', '')
        ob['SSMT:PartName'] = name

    # 4. 视角
    if SHOW_VERTEX_COLOR_IN_SOLID:
        set_solid_color_attribute()


def set_solid_color_attribute():
    """把视口切到 Solid + 物体颜色=属性，直接看顶点色"""
    for screen in bpy.data.screens:
        for area in screen.areas:
            if area.type != 'VIEW_3D':
                continue
            for space in area.spaces:
                if space.type != 'VIEW_3D':
                    continue
                space.shading.type = 'SOLID'
                for mode in ('ATTRIBUTE', 'VERTEX'):
                    try:
                        space.shading.color_type = mode
                        break
                    except (TypeError, AttributeError):
                        continue
```

## 常见问题

::: danger 一运行 Blender 就闪退
1. 确认用的是 `me.from_pydata()`，不是手工 `loops.add` + `foreach_set`
2. 关掉 `SET_CUSTOM_NORMALS`
3. 移除所有 `bpy.ops` 调用（尤其 `view3d.view_all`）

如果还崩，写个诊断脚本逐步执行，每步前先 flush 日志，崩在哪行一目了然。
:::

::: danger 导入后没有顶点组
最可能的原因：`spec['global_indices']` 从 JSON 读出来是 **Python list**，而你写的是

```python
w = weights[gidx[vidx]]      # numpy 数组用 list 索引 → TypeError
```

报错：

```
TypeError: only integer scalar arrays can be converted to a scalar index
```

**一定要先 `np.asarray(gidx, dtype=np.int64)`。**
:::

::: danger 顶点色是彩虹碎片
见[顶点色与 UV](/guide/blender/vertex-color)。
:::

## 下一步

→ [顶点色与 UV](/guide/blender/vertex-color)：这两块数据的正确姿势