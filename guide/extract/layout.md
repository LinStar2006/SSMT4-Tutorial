# 读输入布局

这一节把「从 `.txt` 到一张可用的字段表」讲清楚，重点在**怎么确认自己读对了**。

## 一份 txt 的三层结构

打开任何 `vb` 的 `.txt`，都是三段：

```text
stride: 40                          ← ① header
first vertex: 0
vertex count: 18531
topology: trianglelist
element[0]:                         ← ② 输入布局
  SemanticName: POSITION
  ...
element[7]:
  SemanticName: TANGENT
  ...
vertex-data:                        ← ③ 实际数值预览
  vb0[0]: -0.529101 -0.042439 0.055176 ...
  vb0[1]: -0.530645 -0.041132 0.055768 ...
```

第 ① 段和第 ② 段在[从转储推导数据类型](/guide/gametype/derive)里已经写了完整解析代码。这一节重点讲**第 ③ 段怎么用**，以及几个容易错的地方。

## 拿 `vertex-data` 反查 stride

这是**最硬的验证手段**，一定要用。

### 原理

`.txt` 末尾的 `vertex-data` 是 3DMigoto 打印的**实际浮点数值**：

```text
vb0[0]: -0.529101 -0.042439 0.055176 -0.572331 -0.784331 0.239293
vb0[1]: -0.530645 -0.041132 0.055768 -0.553479 -0.792604 0.249178
```

这些数字是从 `.buf` 的**真实字节**里按某个 stride 解出来的。

那么反过来：**拿这些数字去 `.buf` 里搜，能搜到的那个 stride 就是对的。**

### 为什么这招有效

因为浮点数很"脆"。`-0.529100716` 这四个字节 `25 73 07 bf` 是唯一的 —— 除非巧合，否则只会在正确的位置出现。

错误的 stride 会让这些字节落在不对齐的边界上，解出来的浮点值就完全不是这个数。

### 实现

```python
"""用 txt 里的 vertex-data 预览值反查真实 stride"""
import struct
import re


def parse_preview(txt_path, slot=0):
    """只取 vertex-data 块，返回 [{'vi': 0, 'vals': [...]}, ...]"""
    out = []
    in_vd = False
    with open(txt_path, 'r', errors='ignore') as fh:
        for line in fh:
            if line.strip().lower().startswith('vertex-data'):
                in_vd = True
                continue
            if not in_vd:
                continue
            m = re.match(r'\s*vb(\d+)\[(\d+)\]:\s*(.*)$', line)
            if m and int(m.group(1)) == slot:
                vals = []
                for x in m.group(3).split():
                    try:
                        vals.append(float(x))
                    except ValueError:
                        break
                out.append({'vi': int(m.group(2)), 'vals': vals})
    return out


def guess_stride(buf_path, preview, offset=0, tolerance=1e-4):
    """
    搜 stride。

    preview: parse_preview() 的结果
    offset:  起始字节（POSITION 一般是 0）
    返回候选 stride 列表（能同时命中所有预览顶点）
    """
    raw = open(buf_path, 'rb').read()
    n = len(raw)

    # 用第一个预览顶点的前 3 个 float 作为探针
    probe_v = preview[0]['vals'][:3]
    probe_b = struct.pack('<3f', *probe_v)

    hits = []
    start = 0
    while True:
        i = raw.find(probe_b, start)
        if i < 0:
            break
        hits.append(i)
        start = i + 1

    if not hits:
        return []

    # 每个命中位置都是一个候选顶点起点；算它到顶点 0 的距离
    cands = []
    for i in hits:
        # 顶点 0 的起点应该是 i - offset
        base = i - offset
        if base <= 0:
            continue
        cands.append(base)

    # 用顶点 1 的坐标验证：base + stride 处应该等于顶点 1 的坐标
    if len(preview) < 2:
        return sorted(set(cands))

    v1_b = struct.pack('<3f', *preview[1]['vals'][:3])
    ok = []
    for stride in sorted(set(cands)):
        p = stride + offset
        if p + 12 > n:
            continue
        if raw[p:p + 12] == v1_b:
            ok.append(stride)
    return ok


# ---- 用法 ----
txt = r'deduped\9c2ac78e-vb0-layout=5bfd1268-topology=trianglelist-stride=40-count=18531.txt'
buf = r'deduped\9c2ac78e.buf'

preview = parse_preview(txt, slot=0)
print('预览顶点数:', len(preview))
print('顶点 0:', preview[0]['vals'][:6])

for s in guess_stride(buf, preview, offset=0):
    size = len(open(buf, 'rb').read())
    print(f'  stride = {s:4}  顶点数 = {size // s}')
```

### 实战输出

```
预览顶点数: 2
顶点 0: [-0.529101, -0.042439, 0.055176, -0.572331, -0.784331, 0.239293]
  stride =   40  顶点数 = 24068
```

注意 **80 也会命中一个**（因为它正好是 40 的两倍，顶点 1 的位置也对上了两步），但只有 40 能让「顶点 0 和顶点 1 **同时**命中」。

::: tip 唯一解的判定
如果多个候选都通过，就用**更多预览顶点**来排除。txt 通常打印 2 个左右，够用了。

还不够就换个思路：`stride` 必须能整除文件大小。`962720 % 80 == 0` 也成立（40 的倍数），所以整除也不能唯一确定。真正的判据是**预览值全部命中**。
:::

## 一个反直觉的发现：txt 里的 count 可能不是缓冲的顶点数

看这组数据：

| 文件 | header 里的 `vertex count` |
|---|---|
| `9c2ac78e-vb0-layout=5bfd1268-...-count=18531.txt` | 18531 |
| 同类但 count 不同的另一份 | 23866 |
| 再一份 | 16255 |
| 再一份 | 24068 |

而 `.buf` 的实际大小是 962720 字节 / stride 40 = **24068**。

四个 txt 都指向同一个 buf，但 header 里的 count 各不相同。

### 为什么

`vertex count` 记的是**这个 draw 视角用到了多少个顶点**，不是缓冲的总容量。

一个模型可能有一个 24068 顶点的大池子，不同部件（body / cloth / accessory）各用其中一段。3Dmigoto dump 时按 draw 记录，所以每个 draw 的 txt 里 count 不同。

### 导致的问题

如果你的代码是

```python
vertex_count = header['vertex_count']
verts = np.frombuffer(raw, dtype=dtype)[:vertex_count]
```

就会**漏顶点** —— body 那份 txt 说 18531，但 cloth 部段要用的顶点可能在 18531..23865 区间里。

### 正确做法

```python
vertex_count = len(raw) // stride      # 按文件实际大小算
```

::: warning 什么时候可以用 header 里的 count
**只有当这个缓冲是专属的**（不被多个 draw 共享）时才行。判断方法：如果同 stride 同 layout 的 txt 有多份不同 count 的，就说明是共享池，必须按文件大小算。

SSMT4 里这个区分体现在：

- **GPU 类型**：直接用 `.buf` 的文件大小
- **CPU 类型**：用 txt 里的 `stride × vertex_count`（因为 CPU 类型每个 draw 有专属缓冲）
:::

## `first vertex` 一般不用管

```text
first vertex: 0
```

这个字段几乎总是 0。如果非 0，理论上要从第 `first vertex` 个顶点开始读。

但实际上：**真正生效的偏移是 `DrawIndexed` 的 `BaseVertexLocation`**，不是这个 `first vertex`。见[坑：漏了 BaseVertexLocation](/guide/extract/vertices#坑漏了-basevertexlocation)。

## 验证清单

读完 `.txt` 之后，逐项确认：

- [ ] `stride` 与「按 offset 算出来的最大值」一致
- [ ] 每个 `AlignedByteOffset` 都 < `stride`
- [ ] 每个 `(offset + byte_width)` 都 ≤ `stride`
- [ ] 同一 `InputSlot` 内的元素 offset **不重叠**（除了已知的 dup 项）
- [ ] `vertex-data` 预览值能在 `.buf` 里按这个 stride 命中
- [ ] `len(buf) % stride == 0`（至少对 GPU 类型要成立）

::: tip 一个自动化检查
```python
def validate_layout(header, elements, groups, buf_size):
    errs = []

    for slot, lst in groups.items():
        s = slot_stride(lst)
        if s == 0:
            errs.append(f'slot {slot}: 空')
            continue

        # offset 不能重叠
        prev_end = -1
        for e in lst:
            if e['offset'] < prev_end:
                errs.append(
                    f'slot {slot}: {e["semantic"]}@{e["offset"]} '
                    f'与上一个元素重叠（上一结束于 {prev_end}）')
            prev_end = e['offset'] + e['byte_width']

        # 不能超出 stride
        if prev_end > header.get('stride', 0):
            errs.append(
                f'slot {slot}: 结束于 {prev_end}，'
                f'超过 header.stride={header.get("stride")}')

    if buf_size % header.get('stride', 1) != 0:
        errs.append(
            f'文件大小 {buf_size} 不能被 stride '
            f'{header.get("stride")} 整除（CPU 类型可忽略）')

    return errs
```
:::

## 多套 layout 的情况

同一个 IB 在同一次帧里，可能被**不同 layout** 的 draw 使用。实战案例里有 4 套：

| layout | 槽 | slot0 内容 | slot1 内容 | slot2 内容 |
|---|---|---|---|---|
| `5bfd1268` | 2 | POSITION@0 + NORMAL@12（**24**） | COLOR+TEXCOORD×3（28） | — |
| `bac6075e` | 2 | POSITION@0 + NORMAL@12 + TANGENT@24（**40**） | COLOR+TEXCOORD×3（28） | — |
| `7e80b6e1` | 3 | POSITION@0（12） | COLOR+TEXCOORD×3（28） | NORMAL@0（12） |
| `8456ccca` | 3 | POSITION@0 + TANGENT@24（40） | COLOR+TEXCOORD@4（12） | TEXCOORD1..3（40） |

### 怎么选

::: tip 选择标准：**哪个能单独凑满完整的 stride**
`bac6075e` 的 slot0 是 P12 + N12 + TA16 = **40 字节，正好等于文件大小 / 顶点数**。

而 `5bfd1268` 的 slot0 只有 24 字节 —— 但文件大小还是 962720，962720 / 24 = 40113.3，**除不尽**。

所以 `5bfd1268` 的 slot0 解读是错的（它的 TANGENT 虽然写在 txt 里，但 @0 与 POSITION 撞了，说明在这个 layout 里没生效）。

**判据**：对每个 candidate layout，检查每个 slot 的 `len(buf) % slot_stride == 0`，且跨 slot 顶点数一致。能全过的才是对的。
:::

### 多套 layout 意味着什么

意味着**同一个模型被画了多次，每次用不同精度**：

- 一套完整（含 TANGENT）→ 主渲染 pass
- 一套精简（只有 P+N）→ 阴影/描边 pass（不需要切线，不需要精细法线）

::: warning 别选错
阴影 pass 的 layout 也能「凑出」一个 stride（24），也能整除文件大小（如果换个 buf），但解出来的模型会缺 TANGENT，而且 POSITION/NORMAL 的解读可能错位。

选 layout 时优先选 **元素最全** 的那套。
:::

## 下一步

→ [切顶点与索引](/guide/extract/vertices)：真正把字节变成数组