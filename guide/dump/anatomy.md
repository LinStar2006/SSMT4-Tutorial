# 认识 FrameAnalysis 目录

按 F8 之后，3DMigoto 会在游戏目录（或 `d3dx.ini` 指定的位置）生成一个 `FrameAnalysis-<日期>-<时间>` 目录。打开它，第一眼通常是懵的：几千个文件，名字全是一串哈希。

这一节把它彻底讲明白。

## 两种目录形态

不同版本的 3DMigoto / 不同 `d3dx.ini` 配置会产出两种形态。

### 形态一：平铺

```
FrameAnalysis-2026-11-17-215525\
├── 000001-ib=00000000-vs=653c63ba4a73ca8b-ps=...-vs-cb4=ad3c80a5.buf
├── 000038-ib=7ad7e69e-vs=1844db3b...-ps=f5aa22fa....buf
├── 000038-ib=7ad7e69e-vs=1844db3b...-ps=f5aa22fa....txt
├── 000041-ps-t0=10c4fa9f.dds
└── log.txt
```

所有 `.buf` / `.txt` / `.dds` 都直接躺在根目录。文件本身就是数据。

### 形态二：deduped（去重）

```
FrameAnalysis-2026-11-17-215525\
├── 000038-ib=7ad7e69e-vs=...-ps=....buf.lnk   ← 快捷方式，1.5 KB
├── 000038-ib=7ad7e69e-vs=...-ps=....txt.lnk
├── log.txt                                      ← 4.8 MB
└── deduped\                                     ← 真正的数据
    ├── 9c2ac78e.buf                            ← 名字是内容哈希
    ├── 9c2ac78e-vb0-layout=5bfd1268-topology=trianglelist-stride=40-count=18531.txt
    ├── 7ad7e69e.buf
    └── 10c4fa9f-BC7_UNORM_SRGB.dds
```

根目录全是 `.lnk`（Windows 快捷方式），真实数据在 `deduped\` 里。

::: warning deduped 的核心陷阱
`deduped\` 里 `.buf` 的文件名是**内容哈希**，不是资源哈希。

- 根目录的逻辑名告诉你：`000038` 这个 draw 用了 `ib=7ad7e69e`、`vb0=1844db3b`
- 但 `deduped\` 里可能根本没有 `1844db3b.buf` —— 真实文件叫 `9c2ac78e.buf`

**「资源哈希 → 真实文件」的映射只存在于 `log.txt` 里。** 这就是为什么所有脚本第一件事都是解析 log。
:::

## 文件命名规则

### DrawCall 资源文件

```
000038-ib=7ad7e69e-vs=1844db3b8cd1b6ff-ps=f5aa22fa2bba0707.buf
└──┬──┘ └────┬────┘ └───────┬───────┘ └───────┬───────┘
   │         │              │                  │
   │         │              │                  └─ Pixel Shader 哈希（16 hex）
   │         │              └─ Vertex Shader 哈希（16 hex）
   │         └─ Index Buffer 哈希（8 hex）
   └─ drawcall 序号（6 位十进制，本次帧里的调用顺序）
```

各部分含义：

| 部分 | 长度 | 含义 | 能用来做什么 |
|---|---|---|---|
| `000038` | 6 位十进制 | drawcall 序号 | 去 log 里找这次调用的参数（索引数、起止位置） |
| `ib=7ad7e69e` | 8 hex | 索引缓冲哈希 | **这是「某个模型」的 ID**，同一 IB 的所有 draw 共享它 |
| `vs=...` | 16 hex | 顶点着色器哈希 | 同一套渲染流程的 draw 共享 |
| `ps=...` | 16 hex | 像素着色器哈希 | 同一套材质/效果的 draw 共享 |

**重点**：`ib=` 后面的 8 位哈希是你要找的东西。一个 IB 定义了一组面，它对应的顶点数据在 `vb` 文件里。

### 缓冲槽文件

```
000038-ib=7ad7e69e-vb0-layout=5bfd1268-topology=trianglelist-stride=40-count=18531.buf
000038-ib=7ad7e69e-vs-cb4=ad3c80a5.buf
000041-ps-t0=10c4fa9f.dds
000041-ps-t3=b0e08915.dds
```

| 标记 | 含义 |
|---|---|
| `vb0` `vb1` `vb2` … | 顶点缓冲槽位（InputSlot 0/1/2…） |
| `vs-cb0` … `vs-cb4` | Vertex Shader 常量缓冲槽 |
| `vs-t0` … `vs-t8` | Vertex Shader 纹理/SRV 槽（骨骼矩阵经常在这里） |
| `ps-t0` … `ps-t4` | Pixel Shader 纹理槽（**贴图都在这里**） |
| `cs-t0` … `cs-t4` | Compute Shader 槽（形态键、GPU 蒙皮输出常在这里） |
| `o0` `o1` | 渲染目标（RenderTarget） |

### 配套的 `.txt`

`.buf` 是纯二进制，`.txt` 是 3DMigoto 顺手导出的**人类可读说明**。对于 `vb` 和 `ib`，这个 `.txt` 极其重要 —— 它是唯一告诉你「数据怎么解读」的地方。

VB 的 `.txt` 长这样：

```text
stride: 40
first vertex: 0
vertex count: 18531
topology: trianglelist
element[0]:
  SemanticName: POSITION
  SemanticIndex: 0
  Format: DXGI_FORMAT_R32G32B32_FLOAT
  InputSlot: 0
  AlignedByteOffset: 0
  InputSlotClass: per-vertex
  InstanceDataStepRate: 0
element[1]:
  SemanticName: NORMAL
  SemanticIndex: 0
  Format: DXGI_FORMAT_R32G32B32_FLOAT
  InputSlot: 0
  AlignedByteOffset: 12
  InputSlotClass: per-vertex
  InstanceDataStepRate: 0
...
vertex-data:
  vb0[0]: -0.529101 -0.042439 0.055176 -0.572331 -0.784331 0.239293
  vb0[1]: -0.530645 -0.041132 0.055768 -0.553479 -0.792604 0.249178
```

三个关键区块：

1. **header**（`stride` / `first vertex` / `vertex count` / `topology`）
2. **element 列表**（字段名、格式、槽位、字节偏移）
3. **`vertex-data` 预览**（前几个顶点的**实际数值**）

::: tip 为什么 `vertex-data` 是个宝藏
它是**唯一能反查"我的解读对不对"的锚点**。

你猜 stride=40，那就按 40 切，看第 0 个顶点的前 12 字节是不是 -0.529101 / -0.042439 / 0.055176。对上了，布局就确认了。对不上，换个数再试。

后面[验证 stride](/guide/extract/layout#拿-vertex-data-反查-stride)会详细讲。
:::

IB 的 `.txt` 长这样：

```text
topology: trianglelist
format: DXGI_FORMAT_R16_UINT
first index: 59307
index count: 10446
...
0 1 2
2 1 3
3 1 4
...
```

后面每行三个数字就是一个三角形（三个顶点索引）。

## `log.txt` 是什么

它是这次帧里**所有 dx11 调用的流水账**，几 MB 到几十 MB。对提取来说，它提供三样东西：

### 1. 资源哈希 → 真实文件路径

```text
000007 Dumping Buffer 1844db3b -> 9c2ac78e.buf
```

::: details 为什么需要这一层
因为 `Dumping Buffer` 是 3Dmigoto 决定「要不要保存这个资源」时打的日志。同一个 GPU 缓冲可能被多个 draw 帧内反复改写，内容一样就只存一份（deduped），名字取内容哈希。所以逻辑名和文件名对不上。

平铺形态下也有这层日志（只是文件名恰好保留了资源名），所以**统一都从 log 查最稳**。
:::

### 2. drawcall 的绘制参数

```text
000038 DrawIndexed(IndexCount:10446, StartIndexLocation:59307, BaseVertexLocation:0)
```

这三个数决定「这个 draw 从 IB 的哪一段画多少个三角形」：

| 参数 | 含义 | 单位 |
|---|---|---|
| `IndexCount` | 画多少个索引 | 索引个数（三角形数 = 这个 / 3） |
| `StartIndexLocation` | 从第几个索引开始 | **索引个数**，不是字节 |
| `BaseVertexLocation` | 顶点索引的基础偏移 | **顶点个数** |

::: warning `BaseVertexLocation` 是最容易漏的一项
很多游戏把大量模型塞进一个巨大的 VB 池，靠 `BaseVertexLocation` 指向自己那一段。它非 0 而你忘了加，模型就会炸成一片乱飞的尖刺 —— 而所有"顶点数校验""布局校验"都会通过。

见[坑：漏了 BaseVertexLocation](/guide/extract/vertices#坑漏了-basevertexlocation)。
:::

### 3. 顶点缓冲的绑定关系

```text
000038 IASetVertexBuffers(StartSlot:0, NumBuffers:2, ...)
  Src: resource=0x0000000a1b2c3d4e hash=1844db3b
  Src: resource=0x0000000a1b2c3d5f hash=9798ab34
```

告诉你这次 draw 读了哪些 VB，以及槽位顺序。找 GPU 预蒙皮的「配对 draw」时要用它。

## 一个真实目录的规模

拿实战案例的转储举例：

| 项 | 数量 |
|---|---|
| 根目录条目 | 8078（其中 8076 个 `.lnk`） |
| `deduped\` 真实文件 | 974（446 `.txt` / 285 `.dds` / 243 `.buf`） |
| 总大小 | 1.49 GB |
| `log.txt` 大小 | 4.8 MB |
| `Dumping Buffer` 映射条数 | 6462 |
| 里面包含的 IB 数量 | 235 个 trianglelist + 8 个 pointlist |

一个模型只有几千个三角形，但转储里有 235 个 IB —— 大部分是别的角色、地形、UI。所以[锁定目标 IB](/guide/dump/find-ib)是必要的一步，不能瞎猜。

## 下一步

→ [抓取一次转储](/guide/dump/capture)：怎么让 3DMigoto 把想要的东西都 dump 下来

或者直接跳到 → [锁定目标 IB](/guide/dump/find-ib)：如果你的转储已经在了