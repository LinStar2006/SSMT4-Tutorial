# 切顶点与索引

现在有了布局表，可以真正从 `.buf` 里切出数据了。这一节讲三件事：**怎么切**、**怎么切对**、**怎么验证切对了**。

## 顶点：按 offset 切字节

核心思路：**给 numpy 一个带 offsets 的复合 dtype**，让它按 stride 自动对齐。

```python
import numpy as np

# format -> (numpy 标量类型, 通道数)
NP_OF_FMT = {
    'R32G32B32_FLOAT':    ('<f4', 3),
    'R32G32B32A32_FLOAT': ('<f4', 4),
    'R32G32_FLOAT':       ('<f4', 2),
    'R32_FLOAT':          ('<f4', 1),
    'R8G8B8A8_UNORM':     ('<u1', 4),
    'R8G8B8A8_SNORM':     ('<i1', 4),
    'R8G8B8A8_UINT':      ('<u1', 4),
    'R32G32B32A32_SINT':  ('<i4', 4),
    'R32G32B32A32_UINT':  ('<u4', 4),
    'R32G32_UINT':        ('<u4', 2),
    'R32_UINT':           ('<u4', 1),
    'R16G16_FLOAT':       ('<f2', 2),
    'R16G16B16A16_FLOAT': ('<f2', 4),
    'R16G16B16A16_UNORM': ('<u2', 4),
}


def build_dtype(elements, stride):
    """
    按字段表造一个带 offsets 的 numpy dtype。

    elements: [{'semantic', 'index', 'format', 'offset', 'byte_width'}, ...]
    stride:   每顶点字节数
    """
    names, formats, offsets = [], [], []

    for e in elements:
        name = e['semantic'] if e.get('index', 0) == 0 \
            else f"{e['semantic']}{e['index']}"

        fmt = e['format'].replace('DXGI_FORMAT_', '')
        if fmt not in NP_OF_FMT:
            raise ValueError(f'不认识的格式: {fmt}')
        scalar, count = NP_OF_FMT[fmt]

        names.append(name)
        # 关键：多通道要写成 (类型, (count,))，否则字段变一维
        formats.append(scalar if count == 1 else (scalar, (count,)))
        offsets.append(e['offset'])

    return np.dtype({
        'names': names,
        'formats': formats,
        'offsets': offsets,
        'itemsize': stride,
    })


def read_vertices(buf_path, elements, stride):
    raw = open(buf_path, 'rb').read()
    if len(raw) % stride != 0:
        raise ValueError(
            f'{buf_path} 大小 {len(raw)} 不能整除 stride {stride}')
    dt = build_dtype(elements, stride)
    if dt.itemsize != stride:
        raise ValueError(f'dtype 大小 {dt.itemsize} != stride {stride}')
    return np.frombuffer(raw, dtype=dt)
```

::: danger 踩坑：`formats` 只写标量类型会让字段变一维
错误写法：

```python
formats.append('<f4')          # 字段变成 1 个 float
```

然后 `arr['POSITION']` 拿到的是 `(N,)` 的一维数组，`arr['POSITION'][:, 0]` 会报：

```
IndexError: too many indices for array: array is 1-dimensional, but 2 were indexed
```

正确写法是显式给 count：

```python
formats.append(('<f4', (3,)))  # 字段变成 3 个 float
```

这个坑我在实战里踩了两次，两次症状都一样。
:::

### 用起来

```python
verts = read_vertices(pos_buf, pos_elements, stride=40)

pos = verts['POSITION']        # shape (24068, 3) float32
nrm = verts['NORMAL']          # shape (24068, 3) float32
tan = verts['TANGENT']         # shape (24068, 4) float32

print(pos.shape, pos.dtype)    # (24068, 3) float32
print('bbox:', pos.min(0), pos.max(0))
```

::: tip 不用逐字节切
不用写 `raw[i*40 : i*40+12]` 这种循环。复合 dtype 一次搞定 24068 个顶点的所有字段，快且不容易出错。

而且它天然保留了「空洞」（offset 不连续的情况），因为 `itemsize` 设成了 stride。
:::

## 索引：从 `.buf` 切出三角形

索引比顶点简单 —— 整个文件就是一个连续的整数数组。

```python
def read_indices(buf_path, fmt, first_index=0, index_count=None):
    """
    fmt: 'R16_UINT' 或 'R32_UINT'
    first_index / index_count: 来自 DrawIndexed，单位是**索引个数**
    """
    raw = open(buf_path, 'rb').read()

    dt = {'R16_UINT': '<u2', 'R32_UINT': '<u4'}[fmt]
    all_idx = np.frombuffer(raw, dtype=dt)

    if index_count is None:
        return all_idx
    return all_idx[first_index:first_index + index_count]


def to_triangles(idx):
    """索引数组 -> (T, 3) 三角形数组"""
    if len(idx) % 3 != 0:
        raise ValueError(f'索引数 {len(idx)} 不是 3 的倍数')
    return idx.reshape(-1, 3)
```

::: warning `StartIndexLocation` 的单位是索引个数
不是字节。

比如 `StartIndexLocation: 59307`、格式 `R16_UINT`：

- 正确：从第 **59307** 个 `uint16` 开始 → 字节偏移 `59307 * 2 = 118614`
- 错误：从第 **59307** 个字节开始 → 完全错位

因为 `np.frombuffer` 拿到的就是索引数组，`all_idx[59307:]` 天然是按元素索引，所以只要不用字节偏移就不会错。
:::

## 坑：漏了 BaseVertexLocation

这个坑单独拿出来讲，因为它**极其隐蔽**。

### 症状

- 顶点数校验通过
- 布局校验通过
- 索引不越界
- **但模型炸成一片乱飞的尖刺**

### 原因

`DrawIndexed` 有三个参数：

```text
000081 DrawIndexed(IndexCount:23160, StartIndexLocation:0, BaseVertexLocation:4096)
                                                                    ↑ 这个
```

`BaseVertexLocation` 是**顶点索引的基础偏移**，单位是顶点个数。

很多游戏把大量模型塞进一个巨大的 VB 池，每个模型靠 `BaseVertexLocation` 指向自己那一段。所以索引 `0` 实际指的是池子里的第 `4096` 个顶点。

**忘了加它 → 顶点全部错位 → 模型变成尖刺。**

### 修法

```python
def apply_base_vertex(tris, base_vertex):
    return tris + base_vertex
```

或者在读索引时就加上：

```python
idx = all_idx[first_index:first_index + index_count]
idx = idx + base_vertex          # 关键
tris = idx.reshape(-1, 3)
```

### 为什么难发现

因为**所有自动化校验都会通过**：

- 加了偏移后的索引还是 < 顶点数（只要池子够大）
- 三角形数量完全正确
- 顶点数一致

只有渲染出来看才会发现。而且因为顶点数量对、面数对，你会怀疑是「布局错了」而不是「偏移漏了」，从而在错误的方向上debug很久。

::: tip 检查方法
```python
def check_base_vertex(tris, vertex_count, base_vertex):
    total = tris.max() + 1
    print(f'索引最大值 + 1 = {total}, base_vertex = {base_vertex}, '
          f'顶点数 = {vertex_count}')

    if base_vertex > 0:
        if total <= vertex_count:
            print('  ⚠ base_vertex 非 0 但你似乎没加（索引最大值'
                  ' 在顶点数范围内，加上之后会超）')
        else:
            print(f'  ✓ 看起来加过了（去掉 base 会变成 {total - base_vertex}）')
```

实战案例里 `BaseVertexLocation` 全是 0，所以没踩到这个坑。但**别的游戏经常不是 0**。
:::

## 坑：`BaseVertexLocation` 可能是负数

有些引擎会写成负数（表示从池子末尾往前数）。numpy 加负数没问题，但要注意 dtype：

```python
idx = idx.astype(np.int32) + base_vertex     # 用有符号类型
```

`<u2` 加负数会溢出成天文数字，然后索引越界报错。

## 一个 IB 的多段

同一个 IB 常常被切成几段，各段用不同材质画。

```text
7ad7e69e-ib-format=R16_UINT-topology=trianglelist-count=59307.txt
7ad7e69e-ib-format=R16_UINT-topology=trianglelist-first=59307-count=10446.txt
7ad7e69e-ib-format=R16_UINT-topology=trianglelist-first=69753-count=18045.txt
7ad7e69e-ib-format=R16_UINT-topology=trianglelist-first=87798-count=1020.txt
```

四段的 `first` + `count`：

| 段 | first | count | 三角形 |
|---|---|---|---|
| #0 | 0 | 59307 | 19769 |
| #1 | 59307 | 10446 | 3482 |
| #2 | 69753 | 18045 | 6015 |
| #3 | 87798 | 1020 | 340 |

合计 59307 + 10446 + 18045 + 1020 = **88818** = 整个 `.buf` 的索引数（177636 字节 / 2）。

### 为什么要分段

因为不同部件用不同贴图。body 用人物皮肤贴图，cloth 用布料贴图，一次 `DrawIndexed` 只能绑一套。

### 分段的实际含义

::: tip 段名里 `count-first` 的意义
很多工具（包括 MMT、SSMT4）把段显示成 `59307-0`（count-first），意思是「**从索引 0 开始画 59307 个**」。

这是**最关键的身份标识** —— 它直接来自 `DrawIndexed` 的两个参数，不需要任何推测。

所以在 Blender 里看到 `body_59307-0`、`cloth_a_10446-59307` 这样的对象名，就知道它是从哪一段切出来的。
:::

### 怎么处理多段

三种策略：

| 策略 | 做法 | 适用 |
|---|---|---|
| **合并** | 所有段合成一个 mesh，用多个材质槽 | 想要完整模型 |
| **分段** | 每段一个独立对象 | 想分别挂不同材质/贴图 |
| **只取一段** | 只要 body | 只想看看 |

教程推荐**分段**，原因：

1. 每段配自己的贴图，不需要材质槽管理
2. 想隐藏某个部件（比如去掉武器）直接删对象
3. 和 MMT/SSMT4 的输出对得上，方便对照

分段时要处理一个问题：**段之间可能共用顶点**。

## 跨段共用顶点

拿真实数据：

| 段 | 索引用到的顶点范围 |
|---|---|
| #0 | [0, 16254] → 16255 个 |
| #1 | [16255, 18530] → 2276 个 |
| #2 | [18531, 23865] → 5335 个 |
| #3 | **[16232, 24067]** → 216 个（但横跨了 7836） |

注意 #3：它虽然只用 216 个顶点，但范围横跨 16232..24067。

为什么？因为它是**武器**（长枪），握把部分和手掌接缝共用了 14 个顶点（全局 16232..16253）。

所以：

- 各段顶点数之和 = 16255 + 2276 + 5335 + 216 = **24082**
- 整个池子的顶点数 = **24068**
- 差 **14** = 被两段共用的顶点

### 分段时的两种做法

**做法 A：每段独立顶点（推荐）**

每段只带自己用到的顶点，重复的那 14 个各自存一份。

```python
def split_by_segment(tris, segment_first, segment_count, pos):
    """
    tris: 全量三角形 (T,3)，已按整份 IB 切好
    segment: 用 first/count 定位这一段
    """
    # 1. 先按 first/count 取出这一段的索引
    start_idx = segment_first // 3          # 三角形序号
    n_tri = segment_count // 3
    seg_tris = tris[start_idx:start_idx + n_tri]

    # 2. 找出这段用到的所有顶点
    uniq = np.unique(seg_tris)

    # 3. 建局部坐标映射
    remap = -np.ones(pos.shape[0], dtype=np.int64)
    remap[uniq] = np.arange(len(uniq))

    # 4. 顶点只取这一段用到的
    seg_pos = pos[uniq]

    # 5. 索引重映射到局部
    seg_tris_local = remap[seg_tris]

    return seg_pos, seg_tris_local, uniq
```

`uniq` 就是**全局顶点号列表** —— 后面从别的缓冲（UV、权重、顶点色）取数据时要用它。

**做法 B：所有段共用一份顶点池**

所有段都引用 24068 个顶点，段间共享。

优点：顶点数少一点。
缺点：每个对象带着大量用不到的孤立顶点，Blender 里会出现很多"不在面上的点"，权重/UV 层也要全量拷贝。

::: tip 选 A
A 的代价是 14 个重复顶点（0.06%），换来每个对象干净。Blender 里选对象时不会误选到邻段的东西。
:::

## 跨缓冲顶点数一致性

最重要的一个校验。

```python
def check_consistency(categories):
    """
    categories: {'Position': (buf_path, stride), 'Texcoord': (...), ...}
    """
    counts = {}
    for name, (path, stride) in categories.items():
        size = len(open(path, 'rb').read())
        if size % stride != 0:
            print(f'✗ {name}: {size} % {stride} = {size % stride}，除不尽')
            continue
        counts[name] = size // stride

    print('\n顶点数：')
    for k, v in counts.items():
        print(f'  {k:10} {v}')

    if len(set(counts.values())) == 1:
        print(f'\n✓ 全部一致：{list(counts.values())[0]} 顶点')
        return True

    print('\n✗ 不一致！')
    return False
```

实战输出：

```
顶点数：
  Position   24068
  Texcoord   24068
  Blend      24068

✓ 全部一致：24068 顶点
```

### 不一致说明什么

| 表现 | 可能原因 |
|---|---|
| Position 24068 / Texcoord 24067 | stride 猜错 1 字节（比如把 28 猜成 27） |
| Position 24068 / Texcoord 12034 | 某个 stride 猜成了两倍 |
| 都不一致且乱七八糟 | layout 完全猜错，选错 txt |

::: danger 除不尽时不要「取整凑合」
```python
# 错！掩盖问题
vertex_count = size // stride
```

如果 `size % stride == 0` 不成立，说明**stride 是错的**，应该换一个候选，而不是取整继续。

唯一例外：GPU 的 stream-out 缓冲可能被驱动对齐到 16 字节边界，此时 `size % stride != 0` 是正常的。这时候用 txt 里的 `vertex_count`。
:::

## 完整流程

```python
"""从转储提取一个 IB 的完整数据（骨架）"""
import os
import re
import numpy as np


def extract_model(dump_root, draw_ib, seg_first, seg_count,
                  pos_buf, pos_stride, pos_elems, tex_buf, tex_stride,
                  tex_elems, ib_buf, ib_fmt, base_vertex=0):
    # --- 顶点 ---
    pos_all = read_vertices(pos_buf, pos_elems, pos_stride)
    tex_all = read_vertices(tex_buf, tex_elems, tex_stride)

    # --- 索引 ---
    idx = read_indices(ib_buf, ib_fmt, seg_first, seg_count)
    idx = idx.astype(np.int64) + base_vertex
    tris = idx.reshape(-1, 3)

    # --- 校验 ---
    n_vert = len(pos_all)
    if len(tex_all) != n_vert:
        raise ValueError(
            f'顶点数不一致: pos={n_vert} tex={len(tex_all)}')
    hi = tris.max()
    if hi >= n_vert:
        raise ValueError(f'索引越界: max={hi} >= {n_vert}')

    # --- 切这一段 ---
    uniq = np.unique(tris)
    remap = -np.ones(n_vert, dtype=np.int64)
    remap[uniq] = np.arange(len(uniq))

    return {
        'positions': pos_all['POSITION'][uniq],
        'normals': pos_all['NORMAL'][uniq],
        'uvs': tex_all['TEXCOORD'][uniq],
        'colors': tex_all['COLOR'][uniq],
        'triangles': remap[tris],
        'global_indices': uniq,
        'vertex_count': len(uniq),
        'triangle_count': len(tris),
    }
```

## 通用校验函数

把下面这些检查放进你的提取脚本，任何一项失败就停下来：

```python
def validate(data):
    errs = []

    pos = data['positions']
    tris = data['triangles']
    n = len(pos)

    if n == 0:
        errs.append('顶点数为 0')
    if len(tris) == 0:
        errs.append('三角形数为 0')

    # 索引范围
    if tris.size:
        if tris.min() < 0:
            errs.append(f'索引有负数: {tris.min()}')
        if tris.max() >= n:
            errs.append(f'索引越界: {tris.max()} >= {n}')

    # 退化三角形
    if tris.size:
        a, b, c = tris[:, 0], tris[:, 1], tris[:, 2]
        degen = ((a == b) | (b == c) | (a == c)).sum()
        if degen:
            errs.append(f'退化三角形 {degen} 个（三点共索引）')

    # 坐标合理性
    if n:
        span = pos.max(0) - pos.min(0)
        if span.max() < 1e-6:
            errs.append('所有顶点几乎重合，坐标可能全错')
        if span.max() > 1e6:
            errs.append(f'坐标跨度异常: {span}')
        if not np.isfinite(pos).all():
            errs.append('坐标里有 NaN / Inf')

    # 法线归一化
    nrm = data.get('normals')
    if nrm is not None and len(nrm):
        ln = np.linalg.norm(nrm, axis=1)
        bad = (np.abs(ln - 1.0) > 0.1).sum()
        if bad > len(ln) * 0.05:
            errs.append(
                f'{bad}/{len(ln)} 个法线长度偏离 1，'
                f'可能是布局错位（把别的字段当法线读了）')

    return errs


errs = validate(data)
if errs:
    print('校验失败：')
    for e in errs:
        print('  ✗', e)
else:
    print('✓ 全部通过')
    print(f'  {data["vertex_count"]} 顶点, '
          f'{data["triangle_count"]} 三角形')
```

::: tip 「法线长度偏离 1」这个检查特别好用
因为它能抓住**布局错位**。如果你把 TANGENT 的 xyz 当 NORMAL 读，或者 offset 差了 4 字节，法线长度就会乱七八糟。

正常模型的法线长度应该接近 1.0（单位向量），偏离超过 0.1 的比例不应该超过 5%。
:::

## 这一步的通过标准

- [ ] 跨缓冲顶点数完全一致
- [ ] 索引最大值 < 顶点数
- [ ] 退化三角形 0 个（或极少）
- [ ] 坐标跨度合理（不是 0，也不是天文数字）
- [ ] 法线长度接近 1.0
- [ ] `BaseVertexLocation` 已经加上

## 下一步

→ [提取贴图](/guide/extract/textures)：把 `ps-t*` 那堆 DDS 变成能用的 PNG