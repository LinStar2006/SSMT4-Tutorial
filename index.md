---
layout: home

hero:
  name: 转储到模型
  text: 3DMigoto 数据提取全流程教程
  tagline: 从一个 FrameAnalysis 转储目录，走到一个能在 Blender 里编辑、能改回游戏里的模型
  actions:
    - theme: brand
      text: 开始阅读
      link: /guide/
    - theme: alt
      text: 直接看案例
      link: /case/7ad7e69e

features:
  - title: 讲清原理，不只给脚本
    details: 为什么同一个模型有两份顶点？为什么 GPU 蒙皮要从 pointlist draw 取数据？每一个"为什么"都追到 dx11 调用和日志原话。
  - title: 每一步都能验证
    details: 顶点数对不对、布局猜得准不准、绕序朝向有没有反、UV 要不要翻转 —— 每个环节都给出可执行的校验手段，不靠"看起来差不多"。
  - title: 最终能改回游戏
    details: 不满足于"导进 Blender 看看"。顶点色按 uint8 逐字节保留、UV 存原始字节，保证改完能无损写回去。
---

## 这套教程解决什么问题

你想改一个游戏的模型。游戏用 **3DMigoto** 注入，能抓 **FrameAnalysis** 转储。但转储目录里是一堆 `000081-ib=1a2b3c4d-vs=...-ps=....buf` 这样的文件，名字里只有哈希，没有任何说明告诉你：

- 哪个 `.buf` 是这个模型的顶点？
- 数据是 12 字节一顶点还是 40 字节一顶点？前 12 字节是坐标，那后 28 字节是什么？
- 为什么顶点数和我数的差一点？
- 为什么导出来的人形是躺着的，或者摆着一个踢腿姿势？
- 为什么进 Blender 之后颜色是彩虹噪点？

这套教程把这些逐个拆开。不假设你有 SSMT 这类工具，只用 Python + numpy + 一本 dx11 手册，从转储一路走到 Blender 里能编辑的网格。

## 路线图

```
FrameAnalysis 转储目录
       │
       ├─ log.txt ──────────────► 谁画了谁（draw → 资源哈希 → 真实文件）
       ├─ 000081-ib=….txt ──────► 索引缓冲区长什么样
       ├─ 000081-vb0.txt ───────► 输入布局：每顶点有哪些字段、各占几字节
       └─ deduped\*.buf ────────► 真正的二进制数据
                │
                ▼
        ① 锁定目标 IB        找到 8 位 IB 哈希，认清它的 draw
                │
        ② 搞懂数据类型        每顶点 stride 怎么拆成字段（GameType）
                │
        ③ 切片提取            按 offset 切字节 → 顶点 / 索引 / 贴图
                │
        ④ 坐标与朝向          定 up 轴、定绕序、UV 是否翻转
                │
        ⑤ 导入 Blender        OBJ 或脚本，顶点组 / 顶点色 / 多套 UV
                │
        ⑥ 做回 Mod            反变换写回，坐标 / UV / 顶点色都要能还原
```

## 三条阅读路径

::: tip 只想赶紧把模型导出来
跳到[锁定目标 IB](/guide/dump/find-ib) → [读输入布局](/guide/extract/layout) → [OBJ 路线](/guide/blender/obj)。半小时能出结果。
:::

::: tip 想知道为什么会踩坑
从[认识 FrameAnalysis 目录](/guide/dump/anatomy)读起。重点看[GPU 与 CPU 预蒙皮](/guide/gametype/preskinning)那一节 —— 大部分"模型姿势不对"的问题都出在这里。
:::

::: tip 想做 Mod，改完还要能写回去
[第五步：做回 Mod](/guide/mod/writeback) 是必读的。前面每一步都要按"能还原"的标准来做，事后补救来不及。
:::

## 关于术语

教程里会出现几个高频词，先统一一下：

| 词 | 意思 |
|---|---|
| **转储 / Dump** | 3DMigoto 按 F8 生成的 FrameAnalysis 目录 |
| **IB** | Index Buffer，索引缓冲区。一个"模型"通常由一个 IB 定义它的面 |
| **VB** | Vertex Buffer，顶点缓冲区。位置、法线、UV 都在里面 |
| **draw / drawcall** | 一次绘制调用。同一个 IB 可能被多个 draw 用不同顶点范围画 |
| **数据类型 / GameType** | 一套"每顶点字节怎么拆成字段"的说明书 |
| **预蒙皮 / PreSkinning** | 骨骼绑定是在 GPU 还是 CPU 上算的，决定了数据藏在哪个缓冲里 |

完整定义见[术语表](/dev/glossary)。