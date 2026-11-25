# 做回 Mod

前面所有步骤都是为了这一步：把改过的模型写回游戏。

这一章讲清楚**数据要怎么反变换回去**，以及一份最小可用的 3DMigoto 替换配置长什么样。

## 数据流反向

提取时的每一步变换，写回时都要反过来：

| 提取时的操作 | 写回时的逆操作 |
|---|---|
| 坐标 `(x,y,z) → (x,-z,y)` | `(X,Y,Z) → (X,Z,-Y)` |
| UV `v' = 1 - v` | 用 `uv_raw_b64` 原样写回，**不要**再算 `1 - v'` |
| 顶点色 uint8 直读 | 原样写回（无损） |
| 索引 `first_index` 切片 | 拼回完整 IB |
| 按段拆分 | 拼回完整 IB（或整段替换） |

::: danger 坐标反变换方向别搞反
导入 Blender 是：

```python
blender_x = dx_x
blender_y = -dx_z
blender_z = dx_y
```

所以写回是解这个方程：

```python
dx_x = blender_x
dx_y = blender_z          # 因为 blender_z = dx_y
dx_z = -blender_y         # 因为 blender_y = -dx_z
```

代码：

```python
def from_blender(v):
    """(X, Y, Z) -> (x, y, z) 即 (X, Z, -Y)"""
    return np.stack([v[:, 0], v[:, 2], -v[:, 1]], axis=1)
```

验证：设原始 `(0.1, 0.2, 0.3)`，导入后是 `(0.1, -0.3, 0.2)`，再写回算 `(0.1, 0.2, -(-0.3)) = (0.1, 0.2, 0.3)` ✓。
:::

## 重建 VB 缓冲

一个 category 的 buffer 是「按 stride 交错的多字段」结构。写回时要按 offset 塞回去。

```python
"""重建 VB buffer"""
import numpy as np


def rebuild_vb(template: bytes, stride: int, fields: list):
    """
    template: 原始 buffer 字节（作为模板，保留未修改的字段）
    fields: [(offset, ByteWidth, dtype, (N,) 或 (N,k) 数组), ...]

    返回新的 bytes
    """
    n = len(template) // stride
    out = np.frombuffer(template, dtype=np.uint8).reshape(n, stride).copy()

    for offset, width, dtype, values in fields:
        arr = np.asarray(values).astype(dtype)
        if arr.ndim == 1:
            arr = arr[:, None]
        raw = arr.astype(dtype).view(np.uint8).reshape(n, width)
        out[:, offset:offset + width] = raw

    return out.tobytes()
```

### 实战：只改顶点位置

```python
template = open('deduped/1569d000.buf', 'rb').read()   # T-pose vb0
stride = 40

# 从 Blender 导出（世界坐标，已应用变换）
pos = np.array(blender_positions)           # (24068, 3) float32
pos = from_blender(pos)                     # 回到 dx 坐标系

new_bytes = rebuild_vb(template, stride, [
    (0, 12, '<f4', pos.astype(np.float32)),   # POSITION @0，3 个 float32
])
open('new_vb0.buf', 'wb').write(new_bytes)
```

::: tip 只改要改的字段
`rebuild_vb` 用原始 buffer 做模板，只覆盖你指定的 offset 范围 —— 法线、TANGENT、其它字段都保持原样。

这样最安全，也不会因为某个字段格式没读对而把整个缓冲写坏。
:::

### 多字段一起改

如果模型整体变形了（法线也要重算）：

```python
# 法线在 @12，3 个 float32
# TANGENT 在 @24，4 个 float32（w 保留原值）
tangent_w = np.frombuffer(
    template, dtype='<f4').reshape(-1, stride // 4)[:, 6:7]   # @24..@27 是 xyz，w 在 @36

new_bytes = rebuild_vb(template, stride, [
    (0, 12, '<f4', pos_dx),
    (12, 12, '<f4', nrm_dx),
    (24, 12, '<f4', tan_dx),          # 只写 xyz，w 保留
])
```

::: warning TANGENT.w 不要乱动
实战案例里 TANGENT 的 w 分量**恒定是 -1.0**（24068 个顶点里只有一个取值）。

这个 -1 是「手性标记」，告诉 shader 要不要反解切线空间。改成别的值会让光照错乱。

**只改 xyz 三个分量，w 留给原始数据。**
:::

## 重建 IB 缓冲

IB 简单得多 —— 就是一串索引。

```python
def rebuild_ib(indices, fmt='R16_UINT'):
    """把索引数组打包回 buffer"""
    if fmt == 'R16_UINT':
        return np.asarray(indices, dtype='<u2').tobytes()
    elif fmt == 'R32_UINT':
        return np.asarray(indices, dtype='<u4').tobytes()
    raise ValueError(fmt)


# 原始 IB 是 R16_UINT，4 段拼起来
new_ib = rebuild_ib(all_indices, 'R16_UINT')
open('new_ib.buf', 'wb').write(new_ib)
```

### 分段 vs 整段

原来的 IB 有 4 段（`first=0/count=59307` 等），每段被不同的 draw 用。

两种替换策略：

| 策略 | 做法 | 优点 | 缺点 |
|---|---|---|---|
| **整段替换** | 拼成一个完整 IB，改所有段 | 简单 | 所有 draw 都被影响 |
| **只替换一段** | 保留原 IB，只改一段 | 精准 | 要保证长度不变 |

如果只是改一个部件，**只替换那一段**最好 —— 用 `match_first_index` 精确匹配。

```python
# 只替换 seg2（first=59307, count=10446）
seg_start = 59307
seg_count = 10446
new_seg = modify_my_part(old_indices[seg_start:seg_start + seg_count])

full = old_indices.copy()
full[seg_start:seg_start + seg_count] = new_seg
```

::: danger 改长度会让后续段错位
如果新段的索引数变了，后面所有段的 `first_index` 都要跟着平移。

而且 `match_first_index` 是写在 ini 里的常量，平移了就得改 ini。

**尽量不要改总索引数。**
:::

## 最小 3DMigoto 替换配置

一份能跑的最小 mod 目录：

```
MyMod\
├── mod.ini
├── new_vb0.buf
├── new_ib.buf
└── diffuse.dds
```

`mod.ini`：

```ini
[TextureOverrideMyMod]
hash = 7ad7e69e
match_first_index = 0
vb0 = ResourceMyVB0
ib = ResourceMyIB
ps-t0 = ResourceMyDiffuse

[ResourceMyVB0]
type = Buffer
filename = new_vb0.buf

[ResourceMyIB]
type = Buffer
filename = new_ib.buf

[ResourceMyDiffuse]
type = Texture2D
filename = diffuse.dds
```

字段解释：

| 字段 | 含义 |
|---|---|
| `hash` | 要拦截的 IB hash（就是你的 draw_ib） |
| `match_first_index` | 只拦这一段（`0` = 第一段） |
| `vb0` / `vb1` / `vb2` | 替换对应槽位的顶点缓冲 |
| `ib` | 替换索引缓冲 |
| `ps-t0` | 替换像素着色器第 0 号纹理（基础色） |

::: warning 这是最小框架，不是万能模板
真实的 mod 还要考虑：

- **哪些 shader 会读这个 IB** —— 阴影 pass 和描边 pass 也用同一个 IB，只换主渲染的 vb0 会让阴影错位
- **VS 常量**（骨骼矩阵）要不要一起换
- **`ResourceXxx` 的 buffer 尺寸** 必须和原始一致（shader 按 stride 读，多一个字节都会错位）
- **多个 `[TextureOverride]`** 分别对应 `match_first_index` 才能覆盖所有段

完整做法看 3DMigoto 官方文档和现成的 mod 作者作品。
:::

### VB 的尺寸必须精确匹配

```python
stride = 40
n = 24068
expected = stride * n

new = rebuild_vb(template, stride, [(0, 12, '<f4', pos)])
assert len(new) == expected, f'{len(new)} != {expected}'
```

::: danger 尺寸不对就等于没替换
如果新 buffer 比原 buffer 短，shader 读越界 → 要么黑屏要么花屏。
如果比原 buffer 长，多出的部分被忽略（但可能触发别的 draw 的越界）。

**严格按 `stride × vertex_count` 生成。**
:::

## 整条链路的验证

改完不要直接扔进游戏试。按这个顺序验证：

### 1. 字节级检查

```python
# 尺寸
assert len(new_vb0) == len(old_vb0)

# 未删改的区域应完全一致
diff = np.frombuffer(new_vb0, np.uint8) != np.frombuffer(old_vb0, np.uint8)
changed = diff.reshape(-1, stride)
print('被改动的字段分布:')
for off in range(stride):
    if changed[:, off].any():
        print(f'  @{off} 有 {changed[:, off].sum()} 个字节不同')

# 期望：只有 @0..@11 有变化
```

### 2. 反解回模型检查

把新 buffer 当原始数据再走一遍提取流程，渲染出来看是不是你想要的形状：

```python
# 用新 buffer 重跑提取
pos_new = np.frombuffer(new_vb0, dtype='<f4').reshape(-1, 10)[:, 0:3]
pos_b = to_blender_yup(pos_new)
render_views(pos_b, tris, 'check_written.png')
```

### 3. 尺寸与朝向核对

```python
span = pos_b.max(0) - pos_b.min(0)
print(f'尺寸: {span[0]:.3f} x {span[1]:.3f} x {span[2]:.3f}')
print(f'高度 = {span[2]:.3f} 米')      # 应该和原模型接近
```

如果高度从 1.617 变成 1617 —— 坐标反变换漏了乘/除。
如果高度对但模型躺下了 —— 反变换方向错了。

### 4. 进游戏看

前三步都过了再进游戏。第一次进建议：

- 只改一个部件（比如只换一条裙子的材质）
- 保留原始的 `vb0` 不动，只换 `ps-t0`
- 确认这一步生效后，再加 `vb0`

分步验证能把问题定位到具体环节。

## 常见翻车

::: danger 模型在游戏里躺下 / 倒立
坐标反变换错了。

**别猜，用数字验**：取一个已知顶点，走完「提取 → Blender → 写回」整条链，看是否回到原值。
:::

::: danger 模型在游戏里是尖刺乱飞
三个可能：

1. 漏了 `BaseVertexLocation`（提取时没加，写回时也不该加）
2. IB 和 VB 的顶点数对不上
3. `stride` 不匹配 —— 新 buffer 的 stride 和 shader 期望的不一样
:::

::: danger 模型正常但贴图错乱
- UV 用了翻转值而不是 `uv_raw_b64`
- 或者 UV 层顺序错了（主 UV 必须是第一层）
:::

::: danger 只有一半身体 / 某些部件消失
只替换了一段，其它段没换。检查 `match_first_index` 覆盖了几个段。
:::

::: danger 游戏崩溃 / 卡死
最可能是 buffer 尺寸不对。

先只换 `ps-t0` 纹理确认 mod 被加载了，再逐步加 buffer 替换。
:::

## 做完之后

一个可靠的 mod 工作流：

1. **保存原始转储** —— 别只留提取结果，原始 buffer 是你唯一的真值来源
2. **保留侧车 JSON** —— `colors` / `uv_raw_b64` / `weights` 这些无损数据全靠它
3. **记录数据类型** —— `GPU_P12_N12_TA16_C4_T8_T1-8_T2-8_BW16_BI16_` 这种名字写进 mod 目录的 README，下次改就知道该用哪套布局
4. **版本控制** —— buffer 是二进制，用 `git lfs` 或者按版本号打目录

## 下一步

→ [实战案例：7ad7e69e](/case/7ad7e69e)：把这套流程在一个真实转储上完整走一遍