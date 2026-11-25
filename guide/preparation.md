# 需要准备什么

## 必要的

### 1. 一个能注入 3DMigoto 的游戏环境

3DMigoto 是一个 dx11 的 dll 代理（`d3d11.dll`），通过替换游戏的 dll 来截取渲染调用。你需要：

- 游戏本体（显然）
- 对应版本的 3DMigoto（32 位 / 64 位要匹配）
- `d3dx.ini` 配置好

大部分游戏的配置方式在 [SSMT4 文档站](https://perxacid-acid.github.io/SSMT4-Documents/) 的「游戏配置」里有现成的。这里不重复，只说跟提取相关的部分。

### 2. Python 3.8+

```bash
python --version
```

需要两个库：

```bash
pip install numpy pillow
```

| 库 | 用途 |
|---|---|
| `numpy` | 读二进制、按 stride 切片、批量算几何 |
| `Pillow` | 读 `.dds` 贴图（含 BC7 压缩格式）转 PNG |

::: tip 不需要 scipy
教程里的所有判断（up 轴、绕序）都只用 numpy 实现，不依赖 scipy。本机装 scipy 也能用，但不是必须。
:::

### 3. Blender

2019 年之后的任意版本都行。教程里的脚本在 **4.5** 上验证过，同时在 3.6 / 4.0 的 API 上做过兼容。

::: warning Blender 4.x 的一个坑
4.x 里 `mesh.polygons[].loop_total` 变成了**只读派生属性**。手工建拓扑时如果只写 `loop_start` 不写 `loop_total`，`mesh.update(calc_edges=True)` 会段错误崩溃（进程直接消失，没有 Python 回溯）。必须用 `mesh.from_pydata()`。
:::

### 4. 一个帧分析转储

如果你手上已经有 `FrameAnalysis-YYYY-MM-DD-HHMMSS` 这样的目录，直接跳到[认识 FrameAnalysis 目录](/guide/dump/anatomy)。

没有的话看[抓取一次转储](/guide/dump/capture)。

## 建议的

### 十六进制编辑器

HxD、010 Editor、或者 VS Code 的 hexdump 扩展。用途：

- 核对某个 offset 的具体字节
- 确认浮点数的实际数值（顺着字节反推猜布局）

推荐 010 Editor，它自带 float/dword 模板，看二进制特别直观。

### 一个能看 DDS 的图片工具

- **Paint.NET** — 免费，装个 DDS 插件就能开
- **Pillow 一行 Python** — 够用，教程里就是这么做的
- **GIMP** — 自带 DDS，但 BC7 支持要看版本

DDS 是「反查这个 IB 是什么」最快的手段，见[找 IB 的三种方式](/guide/dump/find-ib)。

### 一个 diff 工具

改完的数据要不要写回、写回得对不对，靠逐字节 diff 最直观。

```bash
# Git Bash / WSL
cmp -l original.buf rebuilt.buf | head
```

## 目录约定

教程假设你在某个工作目录下操作。建议：

```
my-mod-work\
├── dump\                          # 转储目录（只读，别动）
│   └── FrameAnalysis-2026-11-17-215525\
├── work\                          # 中间产物
│   ├── layout.json                # 推断出的输入布局
│   ├── pos.npy                    # 顶点坐标
│   ├── tris.npy                   # 三角形索引
│   └── meta.json                  # 各种元信息
└── out\                           # 最终交付
    ├── model.obj
    ├── model.mtl
    └── texture.png
```

本教程的脚本都在仓库根目录，用 `python <script>.py` 直接跑。

## 检查清单

开跑之前确认：

- [ ] `python -c "import numpy, PIL; print(numpy.__version__, PIL.__version__)"` 有输出
- [ ] Blender 能打开（版本号记下来，后面有用）
- [ ] 转储目录里有 `log.txt` 和 `deduped\`（或平铺的 `.buf` / `.txt`）
- [ ] 目标 IB 的 8 位哈希你已经知道了（不知道就看[锁定目标 IB](/guide/dump/find-ib)）

都打勾了 → [认识 FrameAnalysis 目录](/guide/dump/anatomy)