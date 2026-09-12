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
