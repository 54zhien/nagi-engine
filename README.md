# Nagi Engine

> Nagi 自研阅读引擎的**架构验证仓** —— 在写引擎之前，先用可复现的实证把最危险的假设钉死。

[![CI](https://github.com/54zhien/nagi-engine/actions/workflows/ci.yml/badge.svg)](https://github.com/54zhien/nagi-engine/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

**⚠️ 这个仓库不是引擎本体，也不会长成引擎。** 它只回答两个 ADR 故意留白的经验问题：

| | 问题 |
|---|---|
| **Spike A** | 一个阅读位置的**身份**，能不能跨坐标系往返而不丢？（Readium `Locator` ↔ Native Position） |
| **Spike B** | CoreText 能不能当 Nagi 的**可控排版后端**？（字体特性、字形覆盖、横排/竖排/注音的实际几何） |

答案以**探针（probe）**形式落盘：每个探针带自己的问题、执行状态、结论和数字，跑一次留一份可比对的指纹。结论是"否"也算结论 —— 它是对被测对象的陈述，不是构建失败。

## Spike A 之后：ReanchorService

Spike A 的结论之一是「没有一行能靠结构自证身份」。顺着这条结论往下一步是**重锚**：原锚失效之后，凭内容能不能重新找到它。它已实现、已被测量，契约见 **ADR-0012**。

三条边界值得在这里说明，因为它们都是**容易被想当然**的地方：

- **不做近似匹配。** 匹配是**逐 UTF-16 code unit 的字面相等**：没有编辑距离、没有分词、没有标点宽松、没有 Unicode 归一化。ADR-0004 管这一层叫「模糊重锚」，那里的「模糊」**仅指不依赖旧的精确位置**。
- **绝不选「最近」。** 多个候选分不开时返回 `ambiguous` 并给出全部候选，而不是挑一个最近的 —— 猜中的位置看起来和找到的一样，而用户不会被告知区别。
- **它不是生产件。** 既**不是 `DocumentStore`**，也**不是索引器**：本轮用已物化的文档线性扫描 reading order，只验证**语义与确定性**。`async throws` 的签名是为将来留的生产边界，不是现在的实现。

实测读数：六例全部经公开 API 真实调用，`cases=6 / relocated=3 / ambiguous=1 / notFound=2`，六个判别叶子各被触达一次，`mismatches=0`。

## 适合谁看

- 想了解「位置身份 / 分页 / 排版后端」这类阅读引擎核心问题**怎么被实证、而不是被论证**的人
- 参与 Nagi 的人：`CONTEXT.md` 是词汇表，`docs/adr/` 是设计决定，本仓库是这些决定的实验台
- **如果你在找一个能直接用的 EPUB 渲染库 —— 这里没有**，这是个研究仓

## 环境要求

- macOS 13+
- Swift 5.9+（`swift --version` 自检）

## 快速开始

```bash
git clone https://github.com/54zhien/nagi-engine.git
cd nagi-engine

swift build
swift test          # 单元测试

swift run spike-a   # Spike A：位置身份往返
swift run spike-b   # Spike B：排版后端能力
```

两个可执行文件接受同样的两个参数：

| 参数 | 作用 |
|---|---|
| `--out <dir>` | 产物写到哪。默认 `./.artifacts` |
| `--expect <file>` | 拿上一次的 `.fingerprint` 来比对。**给了它，确定性检查才从"同进程跑两次"变成"跨进程"** |

两个 spike 都会把人类可读的表格打到 stdout（正好落进 CI 日志里），同时把机器可读的报告写进输出目录。

## 产物

| 文件 | 用途 |
|---|---|
| `spike-a.json` / `spike-b.json` | **完整报告** —— 无时间戳、run ID 和输出路径，但除 canonical payload 外还含 `artifacts` 与 `determinism`；**不能直接作为跨进程字节门禁** |
| `spike-*.fingerprint` | **真正的跨进程门禁** —— `canonicalPayload()` 的规范哈希；`canonicalPayload()` 是完整报告的**投影** |
| `canonical-text.txt` | **人审** —— 那些偏移所索引的文本本身（Spike A） |
| `page-0.png` · `vertical-column-0.png` · `ruby.png` | **人审** —— 横排页 / 竖排栏 / 注音行盒（Spike B） |

**`.json` 与 `.fingerprint` 不是同一件东西，这点会咬人。** 跨进程一致性由指纹保证；要拿写盘 JSON 重建 `canonicalPayload()`（例如做「去掉某条 probe 后旧读数是否未动」的投影比较），**必须先排除 `artifacts` 与 `determinism`** —— `determinism.fingerprint` 覆盖整个 payload，新增一条 probe 它就该变，把它算进投影，这条判据在本次这种比较里必然不能通过。ADR-0012 记录了这次实测踩到的原委。

## 一个刻意的设计：探针不构成失败

CI 只有两种失败：**抛出的错误**（真缺陷）和**指纹不一致**（确定性破了）。

探针返回 `no` 不会让 job 变红 —— 内置字体确实没有 `halt` 特性，这件事本身就是字体特性普查的结论。把这种结论写成 `FAIL`，是让 CI 日志变得不可读、进而被所有人忽略的第一步。可执行文件里连 `FAIL` 这个词都没有，只有 `MEASURED` / `INCONCLUSIVE` / `UNSUPPORTED`。

**`UNSUPPORTED` 是输出协议保留的状态，当前没有任何探针产生过它** —— 它表达的是「平台或 API 不支持这件事」，而不是一个当前的测量结论。留着它是因为协议要能表达这种情况，不是因为它正在被用到；写成「这里会出现三种状态」会让人以为第三种随时可能冒出来。

## 项目结构

```
Sources/
  SpikeA/        位置身份 spike 的可执行入口
  SpikeAKit/     Locator 往返、canonical text、身份与进度度量、重锚（Anchor/Validator/ReanchorService）
  SpikeB/        排版后端 spike 的可执行入口
  SpikeKit/      探针与报告原语（Quantize / SHA256 / ProbeOutcome / ReportIO…）
                 + 内置字体 NagiRounded-Regular.ttf
Tests/
  SpikeAKitTests/  ·  SpikeKitTests/
docs/adr/        0001–0012，每个决定一份
CONTEXT.md       词汇表 —— 只定义术语的含义与边界
tasks/           进行中的计划与经验
```

**字体是内置的**（3.4 MB，随 target 一起打包）：系统字体一更新，字形度量就会漂 —— 那样跨时间的指纹比对就失去意义。固定字体、固定 viewport、固定 locale、量化度量，见 ADR-0011。

## 设计文档

设计决定不写进代码注释，写进 ADR：

| ADR | 主题 |
|---|---|
| 0001 | 原生阅读器架构 |
| 0002 | 文档 IR 与内容单元 |
| 0003 | 身份方案 |
| 0004 | 位置与锚点模型 |
| 0005 | Primary Text Stream |
| 0006 | CoreText 后端边界 |
| 0007 | CSS 级联架构 |
| 0008 | 增量分页与 Page Map |
| 0009 | 出版进度模型 |
| 0010 | 兼容渲染器 |
| 0011 | 渲染与黄金验证 |
| 0012 | 重锚服务（Reanchor Service） |

术语的**边界**（什么算、什么不算）以 `CONTEXT.md` 为准 —— 那里每个词都写了 `_Avoid_`，说明它**不是**什么。

## 开发

```bash
swift build          # Gate 1
swift test           # Gate 1
swift run spike-b --out /tmp/run1
swift run spike-b --out /tmp/run2 --expect /tmp/run1/spike-b.fingerprint
cmp /tmp/run1/spike-b.fingerprint /tmp/run2/spike-b.fingerprint
```

CI 分两道门，故意分开（`.github/workflows/ci.yml`）：

- **Gate 1** —— 能不能构建、单元测试是否真的执行了。红了就是实现或 API 假设的问题，不是发现
- **Gate 2** —— 研究那一半：每个 spike 在**三个独立进程**里各跑一次，比对规范指纹。确定性是跨进程属性；在同一进程里比两次布局，看不见 hash 种子、框架冷启动状态、以及环境相关的排序

## 贡献

欢迎 Issue / PR。改动前建议先读 `CONTEXT.md` 和相关的 ADR —— 「这个词在这里指什么」在本仓库是有答案的。

## License

MIT —— 见 [LICENSE](LICENSE)。
