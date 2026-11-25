# 数据类型到底是什么

「数据类型」是这类工具里最让人困惑的概念。SSMT4 界面上叫这个名字，代码里叫 `D3D11GameType`，本质上它就是：

> **一张「每顶点 stride 里的字节，怎么切成一个个字段」的说明书。**

这一节把它讲透。

## 问题的起源

一个 VB 缓冲是纯粹的字节流：

```
25 73 07 bf  49 d4 2d bd  a8 00 62 3d  48 84 12 bf  e9 c9 48 bf  25 09 75 3e ...
```

没有任何自描述信息。你不知道：

- 每顶点是 12 字节？28 字节？40 字节？
- 前 12 字节是三个 float32（坐标）？还是 12 个 uint8（某种打包数据）？
- 第 13 字节开始是什么？

**唯一的线索是 `vb` 的 `.txt` 文件** —— 3Dmigoto 从 dx11 的 `IASetInputLayout` 里读出来，抄成人类可读的格式。

## 一份真实的数据类型

看这个 IB 的 vb0 `.txt`：

```text
stride: 40
element[0]:
  SemanticName: POSITION
  SemanticIndex: 0
  Format: DXGI_FORMAT_R32G32B32_FLOAT
  InputSlot: 0
  AlignedByteOffset: 0
element[1]:
  SemanticName: NORMAL
  SemanticIndex: 0
  Format: DXGI_FORMAT_R32G32B32_FLOAT
  InputSlot: 0
  AlignedByteOffset: 12
element[2]:
  SemanticName: TANGENT
  SemanticIndex: 0
  Format: DXGI_FORMAT_R32G32B32A32_FLOAT
  InputSlot: 0
  AlignedByteOffset: 24
```

翻译成人话：

| 字段名 | 语义名 | 格式 | 槽 | 偏移 | 占几字节 |
|---|---|---|---|---|---|
| POSITION | 坐标 | R32G32B32_FLOAT | vb0 | 0 | 12 |
| NORMAL | 法线 | R32G32B32_FLOAT | vb0 | 12 | 12 |
| TANGENT | 切线 | R32G32B32A32_FLOAT | vb0 | 24 | 16 |

加起来 12 + 12 + 16 = 40 = stride。**这就是一个数据类型。**

如果给它起个名字，按业内约定叫 `P12_N12_TA16`（P=Position 12 字节，N=Normal 12 字节，TA=Tangent 16 字节）。

## SSMT4 里「数据类型」的完整结构

SSMT4 把上面这张表存成 JSON。每个元素七个字段：

```json
{
  "GameTypeName": "CPU_P12_N12_TA16_C4_T8_T1-8_T2-8_",
  "D3D11ElementList": [
    {
      "SemanticName": "POSITION",
      "Format": "DXGI_FORMAT_R32G32B32_FLOAT",
      "ExtractSlot": "vb0",
      "ExtractTechnique": "trianglelist",
      "Category": "Position",
      "DrawCategory": "Position",
      "ByteWidth": "12"
    },
    {
      "SemanticName": "NORMAL",
      "Format": "DXGI_FORMAT_R32G32B32_FLOAT",
      "ExtractSlot": "vb0",
      "ExtractTechnique": "trianglelist",
      "Category": "Position",
      "DrawCategory": "Position",
      "ByteWidth": "12"
    },
    ...
  ]
}
```

七个字段的含义：

| 字段 | 作用 | 举例 |
|---|---|---|
| `SemanticName` | 语义名。Blender 里靠它决定数据往哪塞 | POSITION / NORMAL / TEXCOORD / COLOR / BLENDINDICES |
| `SemanticIndex` | 同名语义的序号。TEXCOORD0/1/2 就是靠它区分 | 0 / 1 / 2 / 3 |
| `Format` | dxgi 格式。决定字节怎么解释成数字 | R32G32B32_FLOAT / R8G8B8A8_UNORM |
| `ExtractSlot` | 从哪个缓冲槽取 | vb0 / vb1 / vb2 / cs-t0 / vs-t0 |
| `ExtractTechnique` | 从哪类 draw 取 | pointlist / trianglelist |
| `Category` | 逻辑分类。**同一 Category 的元素共享一个 stride** | Position / Texcoord / Blend |
| `ByteWidth` | 该元素占几字节 | 12 / 4 / 16 |

::: warning `ByteWidth` 可以省略
JSON 里 `ByteWidth` 不写也能工作 —— 从 `Format` 推算就行。

推算规则（SSMT4 和 3Dmigoto 用同一个算法）：对 format 字符串做 3 字符滑窗，看每个通道的位宽求和。

```python
def byte_width_from_format(fmt: str) -> int:
    """DXGI_FORMAT_R32G32B32_FLOAT -> 12"""
    total = 0
    b = fmt.encode()
    for i in range(len(b) - 2):
        w1, w2 = b[i + 1], b[i + 2]
        if w1 == ord('8'):
            total += 1          # 8 位 = 1 字节
        elif w1 == ord('3') and w2 == ord('2'):
            total += 4          # 32 位 = 4 字节
        elif w1 == ord('1') and w2 == ord('6'):
            total += 2          # 16 位 = 2 字节
    return total
```

验证：

```text
>>> byte_width_from_format('DXGI_FORMAT_R32G32B32_FLOAT')
12
>>> byte_width_from_format('DXGI_FORMAT_R32G32B32A32_FLOAT')
16
>>> byte_width_from_format('DXGI_FORMAT_R8G8B8A8_UNORM')
4
>>> byte_width_from_format('DXGI_FORMAT_R16G16_FLOAT')
4
```

::: details 这个算法为什么能对上
`R32G32B32_FLOAT` 里有三个 `32`，每个贡献 4 字节 → 12。`R8G8B8A8_UNORM` 里有四个 `8`，每个 1 字节 → 4。

滑窗起点是 `i+1`，因为 format 里 `R` 后面紧跟第一个数字，所以 `w1` 总落在数字的第一个字符上。
:::

## `Category` 这个字段为什么重要

`Category` 是**最容易忽略但最关键**的一维。

规则：**同一 Category 的所有元素，物理上必须在同一个缓冲里，首尾相接。**

所以：

```
Category = Position  →  POSITION(12) + NORMAL(12) + TANGENT(16) = stride 40，在 vb0
Category = Texcoord  →  COLOR(4) + TEXCOORD(8) + TEXCOORD1(8) = stride 20，在 vb1
Category = Blend     →  BLENDWEIGHTS(16) + BLENDINDICES(16) = stride 32，在 vb1（有时）
```

这就是为什么 SSMT4 提取时是「**按 Category 逐块处理**」的 —— 每个 Category 是一份独立的缓冲，有独立的 stride、独立的顶点数。

::: tip 顶点数必须一致
同一个模型的所有 Category，算出来的顶点数**必须相等**。

如果 Position 算出 24068 顶点、Texcoord 算出 24067 —— 说明布局猜错了，或者索引对不上。这是最重要的一个校验点，见[跨缓冲顶点数一致性](/guide/extract/vertices#跨缓冲顶点数一致性)。
:::

## 四维正交的四个字段

SSMT4 的数据类型里，有四组字段是**互相独立**的，各管一件事：

| 字段 | 管什么 | 取值例子 |
|---|---|---|
| `Category` | 逻辑分组 | Position / Texcoord / Blend / Color |
| `ExtractSlot` | 从哪个 GPU 槽取 | vb0 / vb1 / vb2 / cs-t0 / vs-t0 |
| `ExtractTechnique` | 从哪类 draw 取 | pointlist / trianglelist |
| `DrawCategory` | 在哪类 draw 的语境下取 | Position / Texcoord / Blend |

它们可以任意组合。全库统计里出现过的组合：

| Category → DrawCategory | 出现次数 | 含义 |
|---|---|---|
| Position → Position | 1063 | 标准：坐标从 Position 类缓冲取 |
| Texcoord → Texcoord | 785 | 标准：UV 从 Texcoord 类缓冲取 |
| Blend → Blend | 289 | 标准：权重从 Blend 类缓冲取 |
| **Blend → Position** | **102** | **权重物理上落在 Position 那路缓冲** |
| Vector → Vector | 30 | 方向类数据 |
| Normal → Normal | 18 | 法线单独一类 |
| trianglelist → Position | 3 | 少见组合 |

`Blend → Position` 那 102 处是什么意思？意思是：这个模型把骨骼权重存在了「本来该放坐标」的路上。取数据时必须按 Position 的 draw 语义去定位，而不是按 Blend 的。

::: details `ExtractSlot` 的取值分布说明了什么
全库统计：`vb1` 784、`vb0` 771、**`cs-t0` 283**、`vb2` 202、`cs-t1` 173、`vb4` 36、`vb3` 21、`vs-t5` 8……

`cs-t0` 出现 283 次说明：**大量游戏的 GPU 蒙皮是靠 compute shader 把结果写进 UAV 的**，不只是 vertex shader 的 stream-out。

这直接影响你怎么找 T-pose 顶点缓冲 —— 见[GPU 与 CPU 预蒙皮](/guide/gametype/preskinning)。
:::

## 命名规则

数据类型名是**纯 ASCII 的压缩编码**，规则来自 SSMT4 的 `gametype_common.py`：

```
[GPU|CPU]_<段1>_<段2>_..._<尾下划线>
```

| 段 | 含义 | 字节数 |
|---|---|---|
| `P12` | POSITION，R32G32B32_FLOAT | 12 |
| `P16` | POSITION，R32G32B32A32_FLOAT | 16 |
| `P8` | POSITION，R16G16B16A16_FLOAT（也可能 R32G32_FLOAT） | 8 |
| `N12` | NORMAL | 12 |
| `N4` | NORMAL，R8G8B8A8_SNORM | 4 |
| `TA16` | TANGENT | 16 |
| `TA4` | TANGENT，R8G8B8A8_SNORM | 4 |
| `C4` | COLOR，R8G8B8A8_UNORM | 4 |
| `C16` | COLOR，R32G32B32A32_FLOAT | 16 |
| `T8` | TEXCOORD，R32G32_FLOAT | 8 |
| `T4` | TEXCOORD，R16G16_FLOAT | 4 |
| `T1-8` | TEXCOORD1，R32G32_FLOAT | 8 |
| `T2-4` | TEXCOORD2，R16G16_FLOAT | 4 |
| `BW16` | BLENDWEIGHTS | 16 |
| `BW8` | BLENDWEIGHTS，R32G32_FLOAT | 8 |
| `BI16` | BLENDINDICES | 16 |
| `BI8` | BLENDINDICES，R32G32_UINT | 8 |
| `BI4` | BLENDINDICES，R32_UINT | 4 |

前缀 `GPU` / `CPU` 表示预蒙皮类型。实例：

```
CPU_P12_N12_TA16_C4_T8_T1-8_T2-8_
GPU_P12_N12_TA16_C4_T8_T1-8_T2-8_BW16_BI16_
```

::: warning 名字只编码字节数，不编码通道结构
`P8` 可能是 `R16G16B16A16_FLOAT`（4 通道 × 2 字节）也可能是 `R32G32_FLOAT`（2 通道 × 4 字节）。两者都是 8 字节，名字里区分不出来。

同理 `C4` 可能是 `R8G8B8A8_UNORM` 也可能是 `R32_UINT`。

**所以名字只能当索引用，真要看清结构必须打开 JSON。**
:::

## 完整格式的实际分布

SSMT4 内置库里，BLENDINDICES 出现过 8 种格式：

| 格式 | 出现次数 |
|---|---|
| R32G32B32A32_SINT | 65 |
| R32G32B32A32_UINT | 47 |
| R8G8B8A8_UINT | 44 |
| R32_UINT | 37 |
| R32G32_UINT | 23 |
| R8_UINT | 4 |
| R32G32_SINT | 3 |
| R16G16B16A16_UINT | 3 |

BLENDWEIGHTS 出现过 7 种：

| 格式 | 出现次数 |
|---|---|
| R32G32B32A32_FLOAT | 114 |
| R32G32_FLOAT | 26 |
| R8G8B8A8_UNORM | 8 |
| R16G16B16A16_FLOAT | 8 |
| R16G16B16A16_UNORM | 5 |
| R8_UNORM | 2 |
| R16G16_FLOAT | 1 |

::: tip SINT / UINT 混用不是错误
有人会问「骨骼索引是整数，为什么还有 SINT 和 UINT 两种？」—— 这是**游戏之间的差异**，不是预蒙皮类型的差异。读取时用 numpy 的 `np.int32` 还是 `np.uint32` 都能拿到正确的 ID（只要数值没超范围）。
:::

## 数据类型从哪来

三个来源，按使用比重排：

### 1. 自带库（99% 的情况）

SSMT4 安装目录下：

```
<安装目录>\resources\GameType\<游戏名>\*.json
```

每个 JSON 一个数据类型。目前覆盖 24 个游戏目录，多的一个游戏有 37 个数据类型（ZZMI、NarakaM），少的一个。

::: tip 只读，不要改
这份库随程序发布，是只读的。要加自己的类型，用下一个来源生成的 zip 导入，不要直接改安装目录。
:::

### 2. 从转储推导

`gametype-analysis` 脚本可以扫转储、发现不认识的布局、自动生成 JSON。见[从转储推导数据类型](/guide/gametype/derive)。

### 3. 手写

实在没有的时候自己写一个 JSON。规则就是上面那张字段表。

## 为什么「选错数据类型」会出事

因为数据类型本质上是一个**猜测**：

- 你看到 stride 40，猜是 `P12 + N12 + TA16`
- 但真相可能是 `P12 + N12 + 16 字节的什么东西`

两种解读都能「凑满 40 字节」，都能「顶点数整除」，但解出来的模型完全不对。

**这也是为什么 SSMT4 的匹配算法只看文件大小** —— 它没法知道语义，只能验证「大小对不对得上」。要真正校验布局，需要更硬的证据，见[拿 vertex-data 反查 stride](/guide/extract/layout#拿-vertex-data-反查-stride)。

## 下一步

→ [GPU 与 CPU 预蒙皮](/guide/gametype/preskinning)：同一个模型为什么有两份顶点