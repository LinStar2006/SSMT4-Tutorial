# 转储到模型 · 教程文档站

从 3DMigoto 的 FrameAnalysis 转储文件出发，一步步提取出能导入 Blender 的模型。

**不假设你装了 SSMT4 或任何提取工具** —— 全部用 Python 手搓，每一步都能验证。

## 本地运行

```powershell
# 依赖（首次）
pnpm install

# 开发模式（热更新）
pnpm run dev

# 构建 + 预览
pnpm run build
pnpm run preview
```

如果 `pnpm` 不在 PATH 里（本机 dsh 运行时的情况）：

```powershell
$node = "C:\Users\North\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\node\bin"
$pnpm = "C:\Users\North\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\pnpm\bin\pnpm.cjs"
$env:PATH = "$node;$env:PATH"
node $pnpm run build
node $pnpm exec vitepress preview --port 4173
```

## 目录结构

```
index.md                          首页
guide/                             入门教程（主线）
├── index.md                       这套教程讲什么
├── preparation.md                 需要准备什么
├── dump/                          第一步：拿到转储
│   ├── anatomy.md                 认识 FrameAnalysis 目录
│   ├── capture.md                 抓取一次转储
│   └── find-ib.md                 锁定目标 IB
├── gametype/                      第二步：搞懂数据类型
│   ├── what-is-gametype.md        数据类型到底是什么
│   ├── preskinning.md             GPU 与 CPU 预蒙皮 ★ 最重要
│   └── derive.md                  从转储推导数据类型
├── extract/                       第三步：提取数据
│   ├── layout.md                  读输入布局
│   ├── vertices.md                切顶点与索引
│   └── textures.md                提取贴图
├── blender/                       第四步：导入 Blender
│   ├── obj.md                     OBJ 路线（最快）
│   ├── script.md                  脚本路线（完整）
│   └── vertex-color.md            顶点色与 UV
└── mod/
    └── writeback.md               第五步：做回 Mod
case/7ad7e69e.md                   实战案例：真实转储全流程复盘
dev/
├── ssmt4-internals.md             原理：SSMT4 内部是怎么做的
└── glossary.md                    术语表
```

## 内容来源

所有技术细节来自对两个仓库的实际源码阅读 + 一次真实转储的完整提取实验：

- [SSMT4](https://github.com/Perxenic-Acid/SSMT4) — Rust 后端，`src-tauri/src/extract_new/` 各游戏提取器、`common/` 数据结构、`resources/GameType/` 数据类型库
- [TheHerta4](https://github.com/Perxenic-Acid/TheHerta4) — Blender 插件，`common/ssmt_import_helper.py`、`common/mesh_create_helper.py`
- 实战案例：`FrameAnalysis-2026-11-17-215525` / IB `7ad7e69e`（GPU 预蒙皮，4 段 IB，24068 顶点，29606 三角形，141 骨骼）

## 部署（GitHub Pages）

```powershell
# 构建
pnpm run build

# .vitepress/dist 就是静态站点根目录
# 推到 gh-pages 分支即可
```

如果用 GitHub Actions，`base` 需要设成仓库名：

```ts
// .vitepress/config.mts
export default defineConfig({
  base: '/<repo-name>/',
  // ...
})
```

## 写作约定

- 代码块一律可运行（` ```python ` 围栏里的都通过 `compile()` 检查）
- 非 Python 内容（调用树、箭头表、REPL 输出）用 ` ```text `
- 关键坑用 `::: danger`，经验用 `::: tip`，展开细节用 `::: details`
- 每章末尾有「通过标准」或「自检清单」，能自己判断做对没有