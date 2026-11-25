# 从转储推导数据类型

如果你的游戏不在任何工具的支持列表里，转储里的布局也没人认识，就得自己推。

好消息：**推导所需的信息全都写在 `vb` 的 `.txt` 里**，一行都没少。这一节讲怎么把它读出来、拼成一个合法的数据类型。

## 运行时匹配 vs 离线推导

先说清一个容易混的地方 —— 这两件事的**信息量完全不同**：

| | 运行时匹配（SSMT4 提取时） | 离线推导（本节） |
|---|---|---|
| 目的 | 从**已有**库里选一个能用的 | 造一个**新**的 |
| 手段 | 只看文件大小能不能整除 | 真读 `element[N]` 块 |
| 强度 | **猜** | **读** |

SSMT4 的 GIMI 提取器在匹配类型时，只用 `file_size / category_stride` 判断 —— 它**刻意不读** `InputSlot` 和 `AlignedByteOffset`。真正做完整解析的是另一条路径（SRMI 用 `read_migoto_input_layout_for_slot`）和离线脚本。

所以我们自己推导时，走的是「读」这条路，比运行时匹配更硬。

## 三个信息源

推导一个数据类型，需要三件事：

### 1. `stride` —— 每顶点几字节

VB 的 `.txt` header 里有：

```text
stride: 40
```

::: warning `stride` 也可能不可信
有些 dump 的 `stride` 字段是错的（写的是 InputLayout 的总和而不是这个缓冲的）。如果后面按 offset 算出来的最大值跟它不符，**以 offset 算出来的为准**。
:::

### 2. 每个字段的 `SemanticName` / `Format` / `AlignedByteOffset`

```text
element[0]:
  SemanticName: POSITION
  SemanticIndex: 0
  Format: DXGI_FORMAT_R32G32B32_FLOAT
  AlignedByteOffset: 0
element[1]:
  SemanticName: NORMAL
  SemanticIndex: 0
  Format: DXGI_FORMAT_R32G32B32_FLOAT
  AlignedByteOffset: 12
```

### 3. 这个字段属于哪个 `InputSlot`

```text
  InputSlot: 0
```

## 两个必须处理的坑

### 坑 1：每个 `vbN` 的 txt 都抄了**完整**的 InputLayout

假设模型有两个槽（vb0 放坐标，vb1 放 UV）。你去读 `vb0` 的 txt，会看到 **8 个 element**：

```
element[0] POSITION   InputSlot 0  @0
element[1] NORMAL     InputSlot 0  @12
element[2] COLOR      InputSlot 1  @0
element[3] TEXCOORD   InputSlot 1  @4
element[4] TEXCOORD1  InputSlot 1  @12
element[5] TEXCOORD2  InputSlot 1  @20
element[6] TEXCOORD3  InputSlot 1  @20    ← 与 TEXCOORD2 同 offset
element[7] TANGENT    InputSlot 0  @0     ← 与 POSITION 同 offset
```

注意：
- 里面有 `InputSlot 1` 的元素（它们物理上在 vb1 里，不在这份 vb0 里）
- `TEXCOORD3` 和 `TEXCOORD2` **同 offset** —— 是重复/覆盖的项
- `TANGENT` **@0** 跟 POSITION 撞了 —— 说明这个 layout 里 TANGENT 实际没生效

**正确的做法**：按 `InputSlot` 分组，再按 `AlignedByteOffset` 去重（保留第一个）。

处理后：

| slot | 元素 | stride |
|---|---|---|
| 0 | POSITION@0(12) + NORMAL@12(12) | 24 |
| 1 | COLOR@0(4) + TEXCOORD@4(8) + TEXCOORD1@12(8) + TEXCOORD2@20(8) | 28 |

::: tip 为什么一定会这样
dx11 的 `IASetInputLayout` 是**整条管线一份**的，描述「这帧的顶点数据怎么从各个 slot 组装」。3Dmigoto 把这份完整描述抄进每个 `vbN` 的 txt，方便你看到全貌。

但每个缓冲里**实际只有属于自己 slot 的那些字段**。
:::

### 坑 2：`AlignedByteOffset` 可能有空洞

有些布局不是紧密排列的：

```
POSITION @0   (12 字节)
NORMAL   @12  (12 字节)
--- 空洞 8 字节 ---
TEXCOORD @32  (8 字节)
```

按 offset 切字节时**不能用「累加」算位置，必须用 offset 本身**。

```python
# 错
off = 0
for e in elements:
    e.offset = off
    off += e.byte_width

# 对
for e in elements:
    e.offset = int(e.aligned_byte_offset)
```

## 完整解析代码

```python
"""解析 3DMigoto 的 vb txt，得到按 slot 分组、按 offset 去重的输入布局"""
import re


def byte_width_from_format(fmt):
    """DXGI_FORMAT_R32G32B32_FLOAT -> 12"""
    total = 0
    b = fmt.encode()
    for i in range(len(b) - 2):
        w1, w2 = b[i + 1], b[i + 2]
        if w1 == ord('8'):
            total += 1
        elif w1 == ord('3') and w2 == ord('2'):
            total += 4
        elif w1 == ord('1') and w2 == ord('6'):
            total += 2
    return total


# 3DMigoto 的 format 常量可能带 DXGI_FORMAT_ 前缀，也可能不带
FMT_PREFIX = 'DXGI_FORMAT_'


def norm_format(s):
    s = s.strip()
    if s.upper().startswith(FMT_PREFIX):
        return s[len(FMT_PREFIX):]
    return s


def parse_vb_txt(path):
    """
    返回 (header, elements, preview)

    header:   {'stride': int, 'first_vertex': int, 'vertex_count': int, 'topology': str}
    elements: [{'semantic', 'index', 'format', 'slot', 'offset', 'byte_width'}, ...]
    preview:  {'0': [float, ...], '1': [...]}   # vertex-data 块里的前几个顶点
    """
    header = {}
    elements = []
    preview = {}
    cur = None
    in_vertex_data = False

    with open(path, 'r', errors='ignore') as fh:
        for raw in fh:
            line = raw.rstrip('\n')
            low = line.strip().lower()

            # ---- header ----
            if low.startswith('stride:'):
                header['stride'] = int(re.search(r'(\d+)', line).group(1))
                continue
            if low.startswith('first vertex:'):
                header['first_vertex'] = int(re.search(r'(-?\d+)', line).group(1))
                continue
            if low.startswith('vertex count:'):
                header['vertex_count'] = int(re.search(r'(\d+)', line).group(1))
                continue
            if low.startswith('topology:'):
                header['topology'] = line.split(':', 1)[1].strip()
                continue

            # ---- vertex-data 区（后面都是数据预览）----
            if low.startswith('vertex-data'):
                in_vertex_data = True
                cur = None
                continue
            if in_vertex_data:
                m = re.match(r'\s*vb(\d+)\[(\d+)\]:\s*(.*)$', line)
                if m:
                    slot, vi, vals = m.groups()
                    try:
                        preview[vi] = [float(x) for x in vals.split()]
                    except ValueError:
                        pass
                continue

            # ---- element 块 ----
            if low.startswith('element['):
                if cur:
                    elements.append(cur)
                cur = {}
                continue

            if cur is None:
                continue

            if low.startswith('semanticname:'):
                cur['semantic'] = line.split(':', 1)[1].strip()
            elif low.startswith('semanticindex:'):
                cur['index'] = int(re.search(r'(\d+)', line).group(1))
            elif low.startswith('format:'):
                cur['format'] = norm_format(line.split(':', 1)[1])
            elif low.startswith('inputslot:'):
                cur['slot'] = int(re.search(r'(\d+)', line).group(1))
            elif low.startswith('alignedbyteoffset:'):
                cur['offset'] = int(re.search(r'(\d+)', line).group(1))

    if cur:
        elements.append(cur)

    for e in elements:
        e['byte_width'] = byte_width_from_format(e.get('format', ''))

    return header, elements, preview


def group_by_slot(elements):
    """
    按 InputSlot 分组，每组内按 AlignedByteOffset 去重保留第一个。
    返回 {slot: [element, ...]}，组内按 offset 升序。
    """
    groups = {}
    for e in elements:
        groups.setdefault(e.get('slot', 0), []).append(e)

    out = {}
    for slot, lst in groups.items():
        seen = {}
        for e in sorted(lst, key=lambda x: x.get('offset', -1)):
            off = e.get('offset', -1)
            if off in seen:
                continue          # 同 offset 只保留第一个
            seen[off] = e
        out[slot] = sorted(seen.values(), key=lambda x: x['offset'])
    return out


def slot_stride(slot_elements):
    """一个 slot 的 stride = 最后一个元素的 offset + byte_width"""
    if not slot_elements:
        return 0
    last = slot_elements[-1]
    return last['offset'] + last['byte_width']
```

## 把结果拼成数据类型

```python
"""从解析结果生成 SSMT4 格式的数据类型 JSON"""

# Category 的约定（Unity VS 风格，多数游戏适用）
SLOT_CATEGORY = {
    0: ('Position', 'Position'),
    1: ('Texcoord', 'Texcoord'),
    2: ('Blend', 'Position'),
    3: ('Texcoord', 'Texcoord'),
    4: ('Texcoord', 'Texcoord'),
}


def semantic_segment(semantic, index, byte_width):
    """把元素编码成名字里的段，如 POSITION + 0 + 12 -> 'P12'"""
    s = semantic.upper()
    if s == 'POSITION':
        return f'P{byte_width}'
    if s == 'NORMAL':
        return f'N{byte_width}'
    if s == 'TANGENT':
        return f'TA{byte_width}'
    if s == 'BINORMAL':
        return f'BN{byte_width}'
    if s == 'BITANGENT':
        return f'BT{byte_width}'
    if s == 'COLOR':
        return f'C{byte_width}'
    if s == 'TEXCOORD':
        return f'T{byte_width}' if index == 0 else f'T{index}-{byte_width}'
    if s in ('BLENDWEIGHTS', 'BLENDWEIGHT'):
        return f'BW{byte_width}'
    if s == 'BLENDINDICES':
        return f'BI{byte_width}'
    return f'{s}{index}-{byte_width}'


def build_game_type_json(slot_groups, gpu, name_prefix=''):
    """生成完整的 GameType JSON"""
    is_blend = lambda e: e['semantic'].upper() in (
        'BLENDINDICES', 'BLENDWEIGHTS', 'BLENDWEIGHT')
    has_blend = any(is_blend(e) for lst in slot_groups.values() for e in lst)

    technique = 'pointlist' if has_blend else 'trianglelist'

    elements = []
    segments = []
    for slot in sorted(slot_groups):
        lst = slot_groups[slot]
        if not lst:
            continue
        cat, draw_cat = SLOT_CATEGORY.get(slot, ('Texcoord', 'Texcoord'))
        # 这个 slot 里有 BLEND 元素 -> 归 Blend 类
        if any(is_blend(e) for e in lst):
            cat, draw_cat = 'Blend', 'Blend'

        for e in lst:
            elements.append({
                'SemanticName': e['semantic'],
                'SemanticIndex': e.get('index', 0),
                'Format': 'DXGI_FORMAT_' + e['format'],
                'ExtractSlot': f'vb{slot}',
                'ExtractTechnique': technique if e is lst[0] or True else technique,
                'Category': cat,
                'DrawCategory': draw_cat,
                'ByteWidth': str(e['byte_width']),
            })
            segments.append(semantic_segment(
                e['semantic'], e.get('index', 0), e['byte_width']))

    name = ('GPU_' if has_blend else 'CPU_') + '_'.join(segments) + '_'

    return {
        'GameTypeName': name_prefix + name,
        'D3D11ElementList': elements,
    }
```

::: details 一个重要的局限
上面这段代码把**所有** Category 的 `ExtractTechnique` 设成同一个值（有 BLEND 就全 pointlist）。

但手工维护的 GIMI GPU 类型是**混标**的：

| Category | ExtractTechnique |
|---|---|
| Position | pointlist |
| Blend | pointlist |
| Texcoord | **trianglelist** |

因为 UV 在 pointlist 和 trianglelist 两份缓冲里都有且相同，但 T-pose 那份 vb1 装的是权重，不是 UV。

**所以自动推导只适用于「单个 draw 里就含完整布局」的游戏**（比如 CPU 预蒙皮、或所有数据都塞在一个 VS 缓冲里的）。GPU 预蒙皮的游戏，推导出来的类型需要手工改 `ExtractTechnique`。
:::

## 必须先找 pointlist draw

这是推导过程里最关键的一步。原因：

> GPU 蒙皮的模型，BLEND 数据在 **pointlist draw** 里。如果你只从 trianglelist draw 推导，会得到一个**没有 BLEND 的 CPU 类型** —— 签名是错的。

SSMT4 的检查脚本 docstring 原文：

> GPU-skinned meshes have their BLEND data in the pointlist draw, so deriving from the trianglelist draw alone produces a wrong (post-skinning) signature.

这也解释了为什么不能用「快速路径」：

::: danger 已弃用的快速匹配
有些脚本会「找一个 vb 槽最多的 draw，按它推导」，图快。这个做法对 GPU 预蒙皮**一定会得出错误签名** —— 因为那个 draw 是蒙皮后的，没有 BLEND。

正确的做法是 `check_coverage`：先找 pointlist draw，优先用它。
:::

## 用 SSMT4 的脚本推导

如果不想自己写，SSMT4 自带一套（在安装目录的 `resources\GameType\gametype-analysis\scripts\`）：

```bash
# 先试跑，只读汇总
python gametype_add_missing_types.py ^
  "C:\path\to\FrameAnalysis-..." ^
  --gametype-root "C:\path\to\resources\GameType" ^
  --dry-run

# 输出：checked 42 / covered 38 / unable 0 / new 4
```

`new` 大于 0 才真正生成：

```bash
python gametype_add_missing_types.py ^
  "C:\path\to\FrameAnalysis-..." ^
  --gametype-root "C:\path\to\resources\GameType"
```

会产出 `gametype-additions-<游戏名>-<时间戳>.zip`，可以直接分享给别人。

主要参数：

| 参数 | 作用 |
|---|---|
| `<dump_dir>` | 转储目录 |
| `--settings-file` | SSMT4 的 settings.json |
| `--gametype-root` | `<resources>/GameType` |
| `--drawib-file` | DrawIB 列表文件（默认从 workspace 的 `LOD*/Config.json` 读） |
| `--scan-all` | 扫转储里所有 IB，不只是 DrawIB 列表 |
| `--dry-run` | 只看不写 |
| `--json <out>` | 输出 JSON 结果 |

::: tip 为什么默认只查 DrawIB 列表
一个转储里有几百个 IB，但真正有用的只有你提取的那几个。DrawIB 列表在 `<workspace>\LOD*\Config.json` 里，长这样：

```json
[{"DrawIB": "7ad7e69e", "Alias": ""}]
```

只审这个列表，既快又准，不会为无关的地形/UI 生成一堆类型。
:::

## 手写一个类型

推导不出来的时候，直接写 JSON 也是可以的。模板：

```json
{
  "GameTypeName": "CPU_P12_N12_TA16_C4_T8_T1-8_T2-8_",
  "D3D11ElementList": [
    {
      "SemanticName": "POSITION",
      "SemanticIndex": 0,
      "Format": "DXGI_FORMAT_R32G32B32_FLOAT",
      "ExtractSlot": "vb0",
      "ExtractTechnique": "trianglelist",
      "Category": "Position",
      "DrawCategory": "Position",
      "ByteWidth": "12"
    },
    {
      "SemanticName": "NORMAL",
      "SemanticIndex": 0,
      "Format": "DXGI_FORMAT_R32G32B32_FLOAT",
      "ExtractSlot": "vb0",
      "ExtractTechnique": "trianglelist",
      "Category": "Position",
      "DrawCategory": "Position",
      "ByteWidth": "12"
    },
    {
      "SemanticName": "TANGENT",
      "SemanticIndex": 0,
      "Format": "DXGI_FORMAT_R32G32B32A32_FLOAT",
      "ExtractSlot": "vb0",
      "ExtractTechnique": "trianglelist",
      "Category": "Position",
      "DrawCategory": "Position",
      "ByteWidth": "16"
    },
    {
      "SemanticName": "COLOR",
      "SemanticIndex": 0,
      "Format": "DXGI_FORMAT_R8G8B8A8_UNORM",
      "ExtractSlot": "vb1",
      "ExtractTechnique": "trianglelist",
      "Category": "Texcoord",
      "DrawCategory": "Texcoord",
      "ByteWidth": "4"
    },
    {
      "SemanticName": "TEXCOORD",
      "SemanticIndex": 0,
      "Format": "DXGI_FORMAT_R32G32_FLOAT",
      "ExtractSlot": "vb1",
      "ExtractTechnique": "trianglelist",
      "Category": "Texcoord",
      "DrawCategory": "Texcoord",
      "ByteWidth": "8"
    },
    {
      "SemanticName": "TEXCOORD",
      "SemanticIndex": 1,
      "Format": "DXGI_FORMAT_R32G32_FLOAT",
      "ExtractSlot": "vb1",
      "ExtractTechnique": "trianglelist",
      "Category": "Texcoord",
      "DrawCategory": "Texcoord",
      "ByteWidth": "8"
    },
    {
      "SemanticName": "TEXCOORD",
      "SemanticIndex": 2,
      "Format": "DXGI_FORMAT_R32G32_FLOAT",
      "ExtractSlot": "vb1",
      "ExtractTechnique": "trianglelist",
      "Category": "Texcoord",
      "DrawCategory": "Texcoord",
      "ByteWidth": "8"
    }
  ]
}
```

手写时的几条约定：

1. **元素顺序有讲究**：POSITION, NORMAL, TANGENT, COLOR, TEXCOORD0..N, BLENDWEIGHTS, BLENDINDICES
2. **同名变体加文件后缀**：`..._T8_.json` 和 `..._T8__2.json`
3. **末尾单个下划线**，别多别少
4. **`ByteWidth` 最好写上**，虽然能推算

## 下一步

→ [读输入布局](/guide/extract/layout)：把 `.txt` 变成可用的字段表