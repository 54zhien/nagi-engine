# Publication Progress Model

**Status:** accepted

> **进度是 navigation metadata，既不是 identity，也不是持久化坐标。**
> **精确的阅读位置恢复不得经由 `Double` progression 往返。**

**两条路径必须分开**

```
精确恢复阅读位置    Anchor → Validator → Resolver / Reanchor
拖动进度条到 35%    Progression → ProgressService → nearby NativePosition
```

把两者合并会让一个有损标量（如 50 万字符书里的 `0.532814`）变成书签。

**协议**

```swift
protocol PublicationProgressService {
    func progression(for position: NativeDocumentPosition) -> Double
    func position(near progression: Double) -> NativeDocumentPosition?
}
```

必须满足三条性质：

1. **Monotonicity** —— `p1 < p2` ⇒ `progress(p1) ≤ progress(p2)`
2. **Layout independence** —— 字号 / viewport / theme 变化，progress 不变
3. **Bounded seek round-trip** —— `seek(progress(p))` 落在 `p` 附近的明确容差内（容差按 metric 定义）

**metric 按格式选择**

```swift
enum PublicationProgressMetric {
    case readiumPositions   // EPUB
    case sourceBytes        // TXT
    case canonicalTextIndex // FB2
    case fixedPageOrdinal   // PDF / CBZ / CBR
    case custom(String)
}
```

UI 只看到 `0.0...1.0`，不知道底层是哪种 metric。

**为什么不能统一用源字节**

FB2 的 `<binary>` 内嵌 base64 图片会把字节进度严重扭曲；MOBI 压缩后的 byte offset 更不能等同于阅读进度。格式各自选择**稳定且成本合理**的坐标。

**metric 的准入判据**

> metric 必须能在打开时廉价求值（不做全量解析），否则必须有后台计算 + 降级显示态。

Readium 的 `readiumPositions` 之所以便宜，关键在于它用 **archive entry length** —— ZIP 中央目录里的字节长度，**不需要解压**。（见 `EPUBPositionsService.swift`：默认 `archiveEntryLength(pageLength: 1024)`，即按资源字节长度切分；`originalLength(pageLength: 1024)` 是旧策略，现已 opt-in。）

**Consequences**

- 非 EPUB 无法复用 `EPUBPositionsService`（positions service 是 per-parser 的：`EPUBPositionsService` / `PDFPositionsService` / `LCPDFPositionsService`）。
- TXT 目前之所以有进度，是因为 app 把 TXT 转成合成 EPUB 3（`TXTReaderAssetBuilder.build()`）。**那是 legacy compatibility path，不是 Nagi Engine 架构**；新路线是 TXT Adapter → NagiDocument。
- Pending Spike A：验证 `Locator ↔ NativePosition` 往返稳定性，并把 round-trip 契约推广到全部 metric。

**Spike A 已落地上面那条待办的「前半」：往返契约本身（2026-09-12）**

实测之后，契约改述为：

```
经 Anchor 路径       精确 —— `.exact` 只允许在这里出现
经 Progression 路径  有界 —— 容差按 metric（本文档性质 3）
```

实测暴露的**表达能力缺口**：`NativePosition → Locator` 目前**没有**任何能把「元素内偏移」写进 locator 的字段 —— `fragments` 只能命名元素，而唯一能承载偏移的一类字段（`domRange` / `partialCfi`）本 spike 不发，**Readium 自己的 JS 生产者也不发**（`dom.js:55-67`）。于是这条往返只剩 `progression` 一条通道，而它正是本文档禁止用于精确恢复的那个。**契约因此只能是「有界」而不是「精确」：不是实现不够好，是坐标系在这里只能表达这么多。**

**metric 不可互换，也已实测**：spike 写入 `locations.progression` 的是**文本长度** metric 的值，而该字段对 EPUB 的语义是 `readiumPositions`（archive entry 字节长度，见上）。同一个 `0.5` 在两种 metric 下指**不同的位置** —— 一个有意义的数必须连同它的 metric 才能识别位置，而 UI 看不到 metric。

**尚未做**：把契约推广到 `sourceBytes` / `canonicalTextIndex` / `fixedPageOrdinal` 等全部 metric。
