# 锁定目标 IB

转储里可能有几百个 IB。这一节讲怎么快速找出「你要的那一个」。

## 三种定位方式

按可靠性从高到低：

| 方式 | 原理 | 可靠度 |
|---|---|---|
| **贴图反查** | 看 `ps-t0` 的贴图长什么样 | ★★★★★ |
| **索引数量排序** | 角色模型的面数通常最大 | ★★★☆☆ |
| **hunting 模式** | 3Dmigoto 界面直接显示当前 draw 的哈希 | ★★★★★（但需要能进游戏看） |

## 方式一：贴图反查（最推荐）

这是最直观的方式。`ps-t0` 槽通常是**基础色贴图（Diffuse）**，直接看一眼就知道这个 IB 是什么。

### 原理

每个 draw 的 `ps-t0` 文件就是它用的第一张像素着色器纹理：

```
000041-ps-t0=10c4fa9f.dds     ← 这个 draw 的基础色
000041-ps-t1=9886ea3b.dds     ← 法线贴图
000041-ps-t3=b0e08915.dds     ← 遮罩
```

而 `000041-ib=7ad7e69e-...` 说明 `000041` 这个 draw 画的是 IB `7ad7e69e`。

所以：**打开贴图 → 看到金发少女 → 这个 IB 就是那个角色。**

### 步骤

1. 列出所有 `ps-t0` 贴图
2. 逐个转成 PNG 看一眼（或者拼成一张大图一起看）

```python
"""把转储里所有 ps-t0 贴图拼成一张总览图"""
import os
import re
from PIL import Image, ImageDraw

DUMP = r'C:\path\to\FrameAnalysis-...'
OUT = 'all_ps_t0.png'
THUMB = 200          # 每张缩略图边长
COLS = 6

def find_ps_t0(root):
    """找出所有 ps-t0 贴图，返回 {ib_hash: png_path}"""
    result = {}
    pat = re.compile(r'^(\d{6})-ib=([0-9a-f]{8})-.*-ps-t0=([0-9a-f]+)\.dds$')
    for name in os.listdir(root):
        base = name[:-4] if name.endswith('.lnk') else name
        m = pat.match(base)
        if not m:
            continue
        draw, ib, tex = m.groups()
        path = os.path.join(root, 'deduped', name.replace('.lnk', ''))
        if not os.path.isfile(path):
            path = os.path.join(root, base)
        if os.path.isfile(path):
            result.setdefault(ib, []).append((draw, tex, path))
    return result

items = find_ps_t0(DUMP)
print(f'找到 {len(items)} 个 IB 带基础色贴图')

cells = []
for ib, lst in sorted(items.items()):
    draw, tex, path = lst[0]
    try:
        im = Image.open(path).convert('RGB')
    except Exception as e:
        print(f'  {ib} 读不了: {e}')
        continue
    im.thumbnail((THUMB, THUMB))
    cells.append((ib, draw, tex, im))

# 拼图
rows = (len(cells) + COLS - 1) // COLS
canvas = Image.new('RGB', (COLS * THUMB, rows * (THUMB + 18)), (24, 24, 28))
dr = ImageDraw.Draw(canvas)
for i, (ib, draw, tex, im) in enumerate(cells):
    x = (i % COLS) * THUMB
    y = (i // COLS) * (THUMB + 18)
    canvas.paste(im, (x, y))
    dr.text((x + 3, y + THUMB + 2), f'{ib} {draw}', fill=(220, 220, 220))

canvas.save(OUT)
print('写出', OUT)
```

打开 `all_ps_t0.png`，找到你的目标，记下它上面标的 8 位哈希。

::: tip 为什么这招好用
索引数量会骗人 —— 地形、天空盒的索引数动辄几十万，比角色大得多。但贴图不会骗人：你一眼就能认出「这是我的角色」。

而且顺手就拿到了材质贴图，后面导入 Blender 要用。
:::

## 方式二：索引数量排序

如果你没法看图（比如贴图全是灰色噪点），可以按面数排。

```python
"""按索引数量排序，列出最大的 30 个 IB"""
import os, re

DUMP = r'C:\path\to\FrameAnalysis-...'

def list_ibs_by_size(root):
    """返回 [(ib_hash, index_count, first_index, topology, txt_path)]"""
    out = []
    pat = re.compile(
        r'^(\d{6})-ib=([0-9a-f]{8})-.*?'
        r'(?:topology=(trianglelist|pointlist))?'
        r'(?:.*?count=(\d+))?\.txt$')
    for name in os.listdir(root):
        if not name.endswith('.txt'):
            continue
        base = name
        m = re.search(r'-ib=([0-9a-f]{8})-', base)
        if not m:
            continue
        ib = m.group(1)
        # deduped 形态：真实名字在 deduped 里
        cand = os.path.join(root, 'deduped', base)
        path = cand if os.path.isfile(cand) else os.path.join(root, base)
        if not os.path.isfile(path):
            continue
        head = open(path, 'r', errors='ignore').read(2000)
        topo = re.search(r'topology:\s*(\w+)', head)
        cnt = re.search(r'index count:\s*(\d+)', head)
        first = re.search(r'first index:\s*(\d+)', head)
        out.append((
            ib,
            int(cnt.group(1)) if cnt else 0,
            int(first.group(1)) if first else 0,
            topo.group(1) if topo else '?',
            path,
        ))
    return out

rows = list_ibs_by_size(DUMP)
rows.sort(key=lambda r: -r[1])
print(f'{"IB":10} {"索引数":>9} {"三角形":>9} {"first":>8}  topology')
print('-' * 60)
for ib, cnt, first, topo, _ in rows[:30]:
    print(f'{ib:10} {cnt:>9} {cnt//3:>9} {first:>8}  {topo}')
```

典型输出（就是这个案例的真实结果）：

```
IB              索引数      三角形    first  topology
------------------------------------------------------------
7ad7e69e       59307     19769        0  trianglelist     ← 最大的一段
7ad7e69e       18045      6015    69753  trianglelist     ← 同一个 IB 的另一段
7ad7e69e       10446      3482    59307  trianglelist     ← 又一段
1c4d8f3a       10235      3411        0  trianglelist     ← 别的模型
7ad7e69e        1020       340    87798  trianglelist     ← 最后一段
...
```

::: warning 注意同一 IB 有多段
上面 `7ad7e69e` 出现了 4 次，`first index` 各不相同。这不是 4 个模型，是**一个 IB 被切成 4 段，各段用不同材质/贴图分别画**。

这就是为什么一个角色在有些工具里显示成 4 个部件（body / cloth_a / cloth_b / accessory）。见[一个 IB 的多段](/guide/extract/vertices#一个-ib-的多段)。
:::

## 方式三：hunting 模式

如果游戏能正常跑、3Dmigoto 的 hunting 界面能用，这是最准的方式：

1. 打开 `d3dx.ini`，设 `hunting=1`
2. 进游戏，按小键盘 `0`（默认）开启 hunting
3. 屏幕上会显示当前 draw 的信息，包括 `ib=` 和 `vb=` 哈希
4. 用 `[` `]` 或 `+` `-` 切换 draw，直到屏幕上高亮的正是你的目标
5. 记下 `ib=` 后面的 8 位哈希

::: details hunting 模式下看不到哈希怎么办
确认 `d3dx.ini` 的 `[Hunting]` 段里 `hunting=1`，并且 `show_original=0`（否则显示的是原始数值而不是哈希）。

有些游戏需要按小键盘 `+` 而不是 `[`。具体键位看 `d3dx.ini` 里的注释。
:::

## 拿到哈希之后

假设你确定了目标 IB 是 `7ad7e69e`，接下来要搞清楚：

1. **它被哪些 draw 用了** —— 这决定了有哪些数据可用
2. **每个 draw 的输入布局是什么** —— 这决定了每顶点怎么拆

```python
"""列出引用某个 IB 的所有 draw，以及它们的绘制参数"""
import os
import re

DUMP = r'C:\path\to\FrameAnalysis-...'
IB = '7ad7e69e'

# 1. 从文件名收集 draw
draws = {}
for name in os.listdir(DUMP):
    base = name[:-4] if name.endswith('.lnk') else name
    m = re.match(r'^(\d{6})-ib=([0-9a-f]{8})-', base)
    if m and m.group(2) == IB.lower():
        draws.setdefault(m.group(1), []).append(base)

# 2. 从 log 里取 DrawIndexed 参数
DRAW_RE = re.compile(
    r'DrawIndexed(Instanced)?\(\s*IndexCount:\s*(\d+)\s*,'
    r'(?:\s*InstanceCount:\s*(\d+)\s*,)?'
    r'\s*StartIndexLocation:\s*(-?\d+)\s*,'
    r'\s*BaseVertexLocation:\s*(-?\d+)')

log = open(os.path.join(DUMP, 'log.txt'), 'r', errors='ignore')
calls = {}
cur = None
for line in log:
    m = re.match(r'^(\d{6})\b', line)
    if m:
        cur = m.group(1)
    m = DRAW_RE.search(line)
    if m and cur:
        calls[cur] = dict(
            index_count=int(m.group(2)),
            instance_count=int(m.group(3)) if m.group(3) else 1,
            start=int(m.group(4)),
            base=int(m.group(5)),
        )

print(f'{"draw":8} {"索引数":>8} {"first":>8} {"base":>6}  topology')
print('-' * 50)
for d in sorted(draws):
    c = calls.get(d, {})
    topo = '?'
    for f in draws[d]:
        if '-vb0-' in f and 'topology=' in f:
            topo = re.search(r'topology=(\w+)', f)
            topo = topo.group(1) if topo else '?'
            break
    print(f'{d:8} {c.get("index_count", 0):>8} '
          f'{c.get("start", 0):>8} {c.get("base", 0):>6}  {topo}')
```

## 这一步的通过标准

- [ ] 有一个明确的 8 位 IB 哈希
- [ ] 知道它被哪些 draw 引用（数量 + 序号）
- [ ] 每个 draw 的 `IndexCount` / `StartIndexLocation` / `BaseVertexLocation` 都对上了
- [ ] 顺手存下了 `ps-t0` 的基础色贴图

::: tip 提前看一眼 topology
如果这个 IB 的 draw 里有 `topology=pointlist` 的，**先别删** —— 那是 GPU 预蒙皮的宝藏。看[GPU 与 CPU 预蒙皮](/guide/gametype/preskinning)。
:::

## 下一步

→ [数据类型到底是什么](/guide/gametype/what-is-gametype)：搞清每顶点的字节怎么拆