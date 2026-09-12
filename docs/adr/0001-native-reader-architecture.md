# Native Reader Architecture (Option B)

**Status:** accepted

保留 `ReadiumShared` + `ReadiumStreamer` 作为 publication 基础设施 —— OPF/manifest/spine/TOC 解析、资源访问与字体解混淆、Positions、LCP、OPDS —— 并**替换 Navigator 的排版与呈现层**为 Nagi 自研引擎。`ReadiumNavigator` 不进入引擎核心，仅作为 `ReaderPresentationEngine` 的一个实现存在于独立 target。

**为什么**

- fork 相对上游 3.11.0 的改动共 2725 行，其中 2588 行（95%）落在 EPUB 内容渲染层，**解析层只有 7 行**。三年的痛点全部集中在要被替换的那一层，而解析层从未发生冲突。
- 已有同类先例：`CHANG-JUI-LIN/Yuedu-reader` —— ReadiumShared + Streamer + 自研 CoreText 引擎。
- Readium 官方明确其模块设计为可独立使用；`ReadiumNavigator` 可整体移除而不影响其余。
- 替换而非重写，保住了畸形 EPUB 的 href 归一化、字体解混淆、Positions、LCP 这些有多年边界修复的资产。

**Consequences**

- 非 EPUB 格式拿不到 `EPUBPositionsService`（它是 per-parser 的），需要各自的进度 metric。见 ADR-0009。
- `totalProgression` 的**连续插值目前在 Navigator 里**，不在 Streamer。替换 Navigator 后需重新实现，否则进度退化为量化跳变。标记为 Pending Spike A。
- `ReadiumShared.Locator` 保留为 Publication Position 的载体。见 ADR-0004。
- `ViewportObservingNavigator` 由 EPUB 与 PDF navigator 共同实现；原生引擎应同样实现，宿主代码才不必因换引擎而全改。
