# SSMT4 是怎么做的

前面所有章节都是「如果只有转储，你应该怎么做」。

这一章回答另一个问题：**SSMT4 这个工具内部是怎么做的**，以及它为什么要这么设计。

读源码的收获：它的很多判断比你想的宽松，也有几处文档承诺了但代码没实现。

## 项目形态

```
SSMT4/
├── src-tauri/          Rust 后端
│   ├── src/
│   │   ├── extract_new/    每个游戏一个提取器
│   │   ├── common/         数据结构与算法
│   │   ├── gametype/       数据类型注册表加载
│   │   ├── workspace/      工作区 / SubMeshJson
│   │   ├── commands/       Tauri 命令入口
│   │   └── constants/      字段名常量
│   └── resources/
│       └── GameType/       ★ 数据类型 JSON（单一真源）
│           ├── GIMI/  SRMI/  ZZMI/  ...
│           └── gametype-analysis/   推导工具（Python 脚本）
├── src/                Vue 前端
└── runtime/            3DMigoto（submodule）
```

配套的 Blender 插件是**独立仓库** TheHerta4（Python）。

::: tip 两个关键设计
1. **数据类型是「资源」不是「代码」** —— 全部放在 `resources/GameType/<游戏>/` 下的 JSON 里，加新游戏只要加 JSON 文件，不用改 Rust。
2. **提取器按游戏分文件** —— `gimi.rs`（原神）、`srmi.rs`（星铁）、`zzmi.rs`（绝区零）等，各自实现。因为不同游戏的缓冲组织方式差别很大。
:::

## 数据类型的数据结构

```rust
// common/d3d11_gametype.rs
pub struct D3D11GameType {
    pub game_type_name: String,          // "GPU_P12_N12_TA16_..."
    pub gpu_pre_skinning: bool,          // 派生，JSON 里写的不读
    pub d3d11_element_list: Vec<D3D11Element>,

    // 以下都是 initialize() 算出来的派生字段
    pub category_draw_category_dict: ...,
    pub ordered_category_name_list: ...,
    pub category_slot_dict: ...,         // {Position: "vb0", Texcoord: "vb1", ...}
    pub category_topology_dict: ...,     // {Position: "pointlist", Texcoord: "trianglelist"}
    pub category_stride_dict: ...,       // {Position: 40, Texcoord: 28, Blend: 32}
    pub ordered_full_element_list: ...,
    pub element_name_d3d11_element_dict: ...,
}
```

### `initialize()` 做了什么

```rust
// d3d11_gametype.rs:125-199
pub fn initialize(&mut self) {
    let mut semantic_count: HashMap<String, u64> = HashMap::new();
    self.gpu_pre_skinning = false;

    for element in &mut self.d3d11_element_list {
        // 1. 同名语义递增索引
        let idx = semantic_count.entry(element.semantic_name.clone())
                                .or_insert(0);
        element.semantic_index = *idx;
        element.element_name = if *idx == 0 {
            element.semantic_name.clone()
        } else {
            format!("{}{}", element.semantic_name, idx)
        };
        *idx += 1;

        // 2. GPU 预蒙皮判定
        if element.semantic_name.eq_ignore_ascii_case("BLENDINDICES")
            || element.extract_technique == "pointlist" {
            self.gpu_pre_skinning = true;
        }

        // 3. 累加 stride
        *self.category_stride_dict
             .entry(element.category.clone())
             .or_insert(0) += element.byte_width_int();
    }
}
```

::: danger `GPUPreSkinning` 字段写了也不读
JSON 里可以写 `"GPUPreSkinning": true`，但 `from_json_file` **只反序列化** `GameTypeName` 和 `D3D11ElementList`。

`gpu_pre_skinning` 先硬编码 `false`，然后由 `initialize()` 从元素列表推导覆盖。

所以判断依据只有两条：**有 BLENDINDICES** 或 **有 pointlist 元素**。

第二条是给 APMI 这类「没有 BLENDINDICES 但走预蒙皮」的游戏开的口子，源码注释里明写了。
:::

### `ByteWidth` 可以省略

```rust
// d3d11_gametype.rs:217-235
pub fn get_byte_width_from_format(format: &str) -> u64 {
    format.to_ascii_lowercase()
          .as_bytes()
          .windows(3)
          .fold(0, |acc, w| {
              if w[1] == b'8' { acc + 1 }
              else if w[1] == b'3' && w[2] == b'2' { acc + 4 }
              else if w[1] == b'1' && w[2] == b'6' { acc + 2 }
              else { acc }
          })
}
```

这个算法的巧妙之处：靠滑动 3 字符窗口数「位宽」。

`R32G32B32A32_FLOAT` 里两次出现 `32` → 4 + 4 + 4 + 4 = 16 字节。

`R16G16_FLOAT` → 2 + 2 = 4。

`R8G8B8A8_UNORM` → 1 + 1 + 1 + 1 = 4。

::: tip 这是全项目的 ByteWidth 推算本体
同一个函数出现在三处（`d3d11_gametype.rs`、`vertex_buffer_txt_file.rs`、`gametype_common.py`），逻辑完全一致。

所以 JSON 里 `ByteWidth` 写不写都行 —— 不写就从 `Format` 算。
:::

## 匹配算法（GIMI 版）

这是 SSMT4 最核心的部分。函数在 `extract_new/gimi.rs:401-661`。

```rust
pub fn get_possible_gametype_list_unity_vs(
    &self,
    draw_ib: &str,
    pointlist_index: &str,
    trianglelist_index_list: &[String],
) -> Result<Vec<D3D11GameType>, String>
```

### 逐条拆解

对注册表里每个 GameType（**GPU 类型全部排在 CPU 之前**）：

**① GPU 类型必须有 pointlist index**

```rust
if gpu_pre_skinning && pointlist_index.is_empty() {
    // 日志："未找到PointlistIndex，跳过GPU-PreSkinning数据类型"
    continue;
}
```

**② 一旦匹配到 GPU 类型，跳过后续所有 CPU 类型**

```rust
if found_gpu && !gpu_pre_skinning {
    // 日志："自动优化:已经找到了满足条件的GPU类型，
    //        所以这个CPU类型就不用判断了"
    continue;
}
```

**③ 找满足槽位条件的 trianglelist index**

这套 GameType 里所有 topology 为 `trianglelist` 的 Category，都必须在某个 `<index>-<slot>.buf` 下能找到文件。取第一个全满足的。

**④ 每个 Category 决定用哪个 index 定位**

```rust
// gimi.rs:456-458
let mut extract_index = trianglelist_index.to_string();
if topology == "pointlist" && !pointlist_index.is_empty() {
    extract_index = pointlist_index.to_string();
}
```

→ **Position / Blend 类走 pointlist，Texcoord 类走 trianglelist**。

**⑤ 算文件大小**

```rust
// gimi.rs:511-521
let file_size = if category_buf_txt_file_path.is_empty() {
    get_file_size(&buf_path)           // 没有 txt → 用 buf 实际大小
} else if gpu_pre_skinning {
    get_file_size(&buf_path)           // GPU → 用 buf 实际大小
} else {
    get_file_size_from_migoto_txt(&txt) // CPU → stride × vertex_count
};
```

**⑥ 算顶点数并校验**

```rust
let tmp_number = file_size / category_stride;
if tmp_number == 0 { return skip; }              // 日志："槽位的文件大小不能为0"

if !gpu_pre_skinning {
    let yu_shu = file_size % category_stride;
    if yu_shu != 0 { return skip; }              // 日志："余数不为0: {}"
}
```

::: tip 为什么只有 CPU 要求整除
GPU 的 buffer 是 stream-out 写的，**可能被驱动按 4/8/16 字节对齐补齐**。

CPU 的 buffer 是游戏代码 memcpy 上传的，一定整除。

**所以对 GPU 类型放宽余数检查是必要的。**
:::

**⑦ 所有 Category 的顶点数必须相等**

```rust
if tmp_number != expected_vertex_number {
    // 日志："VertexNumber: {} 当前槽位数量: {}" + "槽位匹配失败"
    return skip;
}
```

**⑧ 全部通过**

```rust
// 日志："MatchGameType: {}"
possible_gametype_list.push(...)
```

空结果时日志：`"无法识别 DrawIB {} 对应的数据类型"`。

### 这个算法到底在检查什么

**等价于：所有 category 的 `文件大小 / stride` 都算出同一个正整数。**

仅此而已。

::: danger 它不检查语义名、格式、slot、offset
GIMI 的匹配**完全不看**：
- SemanticName 对不对
- DXGI Format 对不对
- InputSlot 是不是匹配
- AlignedByteOffset 是不是对

只看「字节总数能不能整除出同一个顶点数」。

这就是为什么会误匹配 —— 后面 [SRMI 的严格校验](#srmi-为什么更复杂) 就是为解决这个问题加的。
:::

### 官方文档 vs 实际代码

`resources/GameType/gametype-analysis/references/PROJECT-CONVENTIONS.md` 第 56-68 行列了 8 条匹配规则。

其中 **3 条在 Rust 里不存在**，只实现在 Python 检查脚本 `gametype_ib_check.py` 里：

| 文档条目 | 在 gimi.rs 里 |
|---|---|
| ⑥ GPU Texcoord 逐 element ByteWidth 交叉比对 | ✗ 没有 |
| ⑦ 单 category CPU 的 txt stride == 类型总 stride | ✗ 没有 |
| ⑧ 全 CPU 命中时只保留 category 最多的 | ✗ 没有 |

::: warning 读文档要留个心
`PROJECT-CONVENTIONS.md` 描述的是「理想算法」，Python 推导工具实现了完整版，Rust 提取器只实现了简化版。

如果照着文档以为自己理解了对，实际提取行为会不一样。
:::

## pointlist index 是怎么找到的

`frameanalysis_log.rs:184-262`：

```rust
pub fn get_last_pointlist_index_by_hash(&self, draw_ib: &str) -> Option<String>
```

函数上面有一句注释：

> 此处逻辑不允许AI修改，只能等待人工后续完善

### 算法

1. 取该 IB hash 的第一个 trianglelist draw index
2. 在这个 draw 的日志行里找 `IASetVertexBuffers`，读 `0: resource=... hash=<vb0hash>`
3. 扫全库日志行，找含 `hash=<vb0hash>` 的行
4. **排除 `Dst:` 行**（CopyResource 的目标不是预蒙皮输入）
5. 只保留 draw index < 第一个 trianglelist index 的
6. 返回**最后一个**

### 已知缺陷（源码注释自己承认）

```
这里返回的是最后一个，所以在部分游戏，例如Naraka手游中无法正确匹配
HSR也出现过这个问题
特殊情况下，第一个匹配到的才是正确的
```

### 更精确的替代

```rust
pub fn get_pointlist_index_by_texcoord_hash(
    &self, trianglelist_index: &str) -> Option<String>
```

追加两个条件：

1. 候选 draw 的 **vb1 hash** 必须和渲染 draw 的 vb1 一致
2. 候选 draw 必须通过 `SOSetTargets` **写出了**本渲染 draw 正在读的那个缓冲

第二条很关键：**渲染 draw 只读不写**，预蒙皮 draw 才写。

::: tip 为什么需要额外条件
同一个 IB 的多个部件**共用同一份 GPU 预蒙皮顶点缓冲**。

只按 vb0 hash 收集再取最后一个，会把别的部件的预蒙皮 draw 挑进来。

失败时回退到 `get_last_pointlist_index_by_hash`。
:::

## 输出：SubMeshJson

`workspace/submesh_json.rs`：

```json
{
  "GamePreset": "GIMI",
  "WorkGameType": { "GameTypeName": "GPU_P12_N12_TA16_...", "D3D11ElementList": [...] },
  "GPU-PreSkinning": true,
  "CategoryHash": { "Position": "1569d000", "Texcoord": "9798ab34", "Blend": "47280c51" },
  "VertexLimitVB": "9c2ac78e",
  "BoneMatrixFileName": "...",
  "IndexBufferList": [{ "DXGI_FORMAT": "R32_UINT", "FileName": "xxx.ib" }],
  "CategoryBufferList": [
    { "FileName": "xxx-Position.buf", "Type": "Normal",
      "D3D11ElementList": [...] }
  ],
  "TextureMarkUpInfoList": [...],
  "DiffuseMap": [...],
  "DrawCallIndexList": ["000041", "000052", ...],
  "VGMap": { "0": 0, "1": 1, ... },
  "SubMeshRole": null
}
```

### 输出目录结构

```rust
// gimi.rs
let unique_str_folder_name = format!("{}-{}-{}",
    draw_ib, ib_txt_file.index_count, ib_txt_file.first_index);
// → <workspace>/7ad7e69e-59307-0/TYPE_GPU_P12_N12_.../xxx.json
```

目录名 `{draw_ib}-{count}-{first}` 就是 MMT 里看到的 `bodyA 7ad7e69e` 下面 `#0 59307-0` 这种编号的来源。

### 一个刻意的留空

GIMI 的 SubMeshJson **不填** `VertexOffset` / `VertexCount` / `IndexOffset` / `IndexCount`。

源码注释（`gimi.rs:307-311`）：

> Do not populate VertexOffset/VertexCount for GIMI. Its submeshes share
> global GPU vertex buffers and their referenced vertices are not guaranteed
> to form a contiguous range. The Blender importer treats non-zero values as
> a slicing instruction, so only the draw-call identity is persisted here.

翻译：GIMI 各 submesh 共享全局 GPU 顶点缓冲，引用的顶点不保证连续。**Blender 导入器把非零值当切片指令**，所以只持久化 draw call 的身份，不写切片范围。

::: tip 这句话解释了一个大坑
如果你自己写导出器，**不要**把 `VertexOffset` 填成「该段的第一个顶点」。

那些字段的语义是「从缓冲里的哪一段切出来」，不是「这段用到了哪些顶点」。

填错了，Blender 插件会去切一段连续区间，结果就是「模型只有一部分」或「顶点错位」。
:::

## TheHerta4 插件侧

主链入口：`ui/ui_func_import_ssmt.py:1088`：

```python
json_file_path = os.path.join(import_folder_path,
                              submesh_folder_name + '.json')
SSMTImportHelper.create_mesh_from_json(json_file_path, import_collection)
```

**主链完全不读 `.fmt` / `.vb`。**

::: danger `.fmt` / `.vb` 是死代码
SSMT4 仓库里有一套 `MigotoModel` + `FmtFile` 的实现（把 category buffer 重新交错成单个 `.vb` 再配 `.fmt`），但：

- `MigotoModel` 全仓只有定义处两个命中，**零调用点**
- `FmtFile::output_fmt_file_by_d3d11_element_list` 只被 `MigotoModel` 调

插件侧 `.fmt` 解析（`sword/fmt_file.py`）只给「剑面板」的旧格式逆向产物用。

**现行提取链路的真实产物是 `.ib` + 每 category 一个 `.buf` + `.json`。**
:::

### 导入流程

```text
create_mesh_from_json(json_path, collection)
  ├─ SubmeshJson(json_path)                      读侧车 JSON
  ├─ parse_category_buffers()                    每个 .buf → numpy 结构化数组
  ├─ parse_index_buffers()                       .ib → 索引数组
  ├─ resolve_draw_call_segments()                DrawCallSegmentList 有效则分段
  └─ MeshCreateHelper.create_mesh_object()
       ├─ set_import_coordinate()                axis_conversion(from_forward='-Z', from_up='Y')
       ├─ initialize_mesh()                      from_pydata 建面
       ├─ 按 element 循环写属性
       ├─ import_uv_layers()                     v' = 1 - v
       ├─ import_vertex_groups()                 65535 → -1 哨兵
       ├─ import_shapekeys()
       ├─ set_import_normals_v2()
       └─ create_bsdf_with_diffuse_linked()
```

### 按 SemanticName 分派

```text
POSITION        → mesh.vertices.co（xyz；4 分量非 0/1 则报错）
COLOR*          → mesh.color_attributes（CORNER 域）
BLENDINDICES    → blend_indices[SemanticIndex]
BLENDWEIGHT(S)  → blend_weights[SemanticIndex]
TEXCOORD*       → texcoords[SemanticIndex]
SHAPEKEY*       → shapekeys[SemanticIndex]
NORMAL*         → use_normals
TANGENT/BINORMAL/BITANGENT → pass（不导入）
```

GIMI 特例：把 TANGENT 原始字节、NORMAL 的 w、COLOR 的 alpha 存到对象的自定义属性里（「Only GIMI preserves game-owned payloads that Blender cannot represent natively」）。

### 预设特化的旋转/缩放

```text
WWMI / NTEMI / SnowBreak  → rotation_euler=(0,0,radians(180)),
                            scale=(0.01, 0.01, 0.01)
CAMI                      → Rz(180) + 0.01
zzmi 家族 / Naraka / EFMI → 全零旋转
```

::: tip 为什么这些游戏要 ×0.01
它们的顶点坐标单位是**厘米**，不是米。

而原神/星铁/绝区零是米制，不需要缩放 —— 这也是为什么实战案例里 1.617 直接就是「1.6 米高」。
:::

## SRMI 为什么更复杂

`srmi.rs` 有 2936 行，比 `gimi.rs`（881 行）复杂得多。

### 严格 InputLayout 校验

```rust
// srmi.rs:429-497
fn category_matches_migoto_input_layout(
    &self,
    d3d11_game_type: &D3D11GameType,
    category_name: &str,
    category_slot: &str,          // "vb0" / "vb1" / ...
    txt_file_path: &str,
) -> Result<bool, String>
```

它读 txt 的 `element[N]` 块，把每个元素的 `(SemanticName, SemanticIndex, Format, AlignedByteOffset)` 和 GameType 声明的逐项比对：

```rust
if !(per_vertex
     && semantic_name.eq_ignore_ascii_case(expected.semantic_name)
     && semantic_index == expected.semantic_index
     && format.eq_ignore_ascii_case(expected.format)
     && aligned_byte_offset == expected_offset)
{
    // 日志："InputLayout mismatch: GameType={}, category={}, slot={},
    //        expected {}{} {} at byte offset {}"
    return Ok(false);
}
```

::: danger 为什么必须加这层
因为 GIMI 那种「只看字节总数」的匹配会**恰好整除但布局完全不同**。

之前出过一个回归：误选了 `CPU_P12_N12_TA16_T4_` 这个类型，stride 恰好能整除，但实际每顶点 960 字节的实例数据被当成顶点数据读 → 越界 `[40..5568)`。

**四元组精确比对能从根上杜绝这种误匹配。**
:::

### 其他 SRMI 特有机制

| 机制 | 作用 |
|---|---|
| `CopyResource` 来源哈希链追踪 | 预蒙皮结果通过 CopyResource 中转时也能找到源头 |
| `validate_precollected_candidate` | 同一 first_index + count 的多条 IB 候选逐一验证 |
| `select_precollected_candidate` | 从多个兼容解释里选一个 |
| `get_cs_output_vertex_limit_vb_from_lines` | 从日志取 compute shader 输出到 UAV 的顶点 limit VB hash |

::: tip 为什么 SRMI 要靠 compute shader
星铁（还有绝区零、鸣潮等）的蒙皮不止用 VS stream-out，还用 **compute shader 写 UAV**。

对应 GameType 里能看到大量 `cs-t0` / `cs-t1` 槽位（全库统计：`cs-t0` 283 处、`cs-t1` 173 处）。
:::

## 数据类型是怎么推导出来的

`resources/GameType/gametype-analysis/` 是一套完整的 Python 工具。

### 三个脚本

| 脚本 | 作用 |
|---|---|
| `gametype_common.py` | 公共库（解析 txt、分组、命名编码） |
| `gametype_ib_check.py` | 检查现有类型能不能覆盖某个 IB |
| `gametype_add_missing_types.py` | 推导缺失类型 + 打包 zip |

### 命名规则的权威实现

```python
# gametype_common.py:502-524
def _semantic_segment(name, idx, bw):
    up = name.upper()
    if up == 'POSITION':     return f'P{bw}'
    if up == 'NORMAL':       return f'N{bw}'
    if up == 'TANGENT':      return f'TA{bw}'
    if up == 'BINORMAL':     return f'BN{bw}'
    if up == 'BITANGENT':    return f'BT{bw}'
    if up == 'COLOR':        return f'C{bw}'
    if up == 'TEXCOORD':
        return f'T{bw}' if idx == 0 else f'T{idx}-{bw}'
    if up == 'BLENDWEIGHTS': return f'BW{bw}'
    if up == 'BLENDINDICES': return f'BI{bw}'
    return f'{up}{idx}-{bw}'


def encode_type_name(gpu, segments):
    prefix = 'GPU' if gpu else 'CPU'
    return prefix + '_' + '_'.join(segments) + '_'
```

::: danger 名字只编码字节总数，不编码通道结构
`P8` 可能是 `R16G16B16A16_FLOAT`（4 × 2 字节），也可能是 `R32G32_FLOAT`（2 × 4 字节）。

`C4` 可能是 `R8G8B8A8_UNORM`，也可能是 `R32_UINT`。

**光看名字猜不出格式，必须打开 JSON 看 `Format` 字段。**
:::

### 推导为什么要先找 pointlist

`gametype_ib_check.py` 的 `check_coverage` docstring：

> GPU-skinned meshes have their BLEND data in the pointlist draw, so
> deriving from the trianglelist draw alone produces a wrong (post-skinning)
> signature.

这就是实战案例里踩的那个坑 —— 只看 trianglelist 会把 GPU 类型误判成 CPU。

### `build_game_type_json` 的局限

```python
technique = 'pointlist' if gpu else 'trianglelist'
# 套给所有 Category
```

而手工维护的 GIMI GPU 类型是**混标**的（Position/Blend = pointlist，Texcoord = trianglelist）。

→ **脚本推导只适用于「单个 draw 含完整布局」的游戏**。对这种「T-pose 和 UV 分在不同 draw」的游戏，推导出来的类型 `ExtractTechnique` 是错的。

## 一句话总结

| 环节 | SSMT4 的做法 | 这套教程的做法 |
|---|---|---|
| 认数据类型 | 运行时靠文件大小整除猜 | 读 txt 的 InputLayout 精确解析 |
| 找 T-pose 缓冲 | 日志 vb0 hash 反查 | 同（这一步没法替代） |
| 抓 UV | 从 trianglelist vb1 | 同 |
| 顶点色 / UV 无损 | 侧车 JSON 存原始字节 | 同 |
| 坐标变换 | 按游戏预设硬编码 | 判 up 轴 + 实测绕序 |
| 输出 | `.ib` + `.buf` + `.json` | `.obj` + `.json` + Blender 脚本 |

→ [术语表](/dev/glossary)：所有名词的准确含义