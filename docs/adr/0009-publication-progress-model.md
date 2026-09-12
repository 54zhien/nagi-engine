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

**这条判据不是一条，是逐 metric 一条。** 原文把它写成了一句对所有 metric 的承诺，而它其实只有其中一部分能做得到 —— 这句话本身就是一个把不同东西说成同一个东西的例子：

| metric | 打开时的成本 | 靠什么 |
|---|---|---|
| `readiumPositions` | 廉价 | ZIP 中央目录里的 archive entry length，**不需要解压**（`EPUBPositionsService.swift`：默认 `archiveEntryLength(pageLength: 1024)`；`originalLength` 是旧策略，现已 opt-in） |
| `fixedPageOrdinal` | 廉价 | **容器自己声明**页数 —— 不需要读内容 |
| `sourceBytes` | 廉价 | 资源字节数 |
| `canonicalTextIndex` | **需要整本解析** | canonical primary text 的建索引本身就是解析产物 |
| `custom` | 由提供者负责 | 逃生口，不承诺 |

`canonicalTextIndex` 这一行是**依赖关系**问题，不是时序问题：它不在于「解析得慢」，而在于「算它之前必须先有整本的 canonical text」。所以它只能落在后半句 —— 后台计算 + 降级显示态，而这件事要在 Document Store 的物化策略里解决，不是一个可以被 profile 出来的耗时。

**第二条准入判据是布局无关性。** 这与 ADR-0008「publication progress 不经由页码」看似冲突（本 ADR 把 `fixedPageOrdinal` 列给 PDF/CBZ），实为互补：**页码在可重排内容上是排版的输出，在固定版式内容上是出版物的属性**。所以「页序号」这个坐标能不能用，取决于它是谁产生的 —— 准入判据就此变成一条可测量的断言，见文末。

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
（**已于下述第二轮落地。**）

---

## metric 矩阵已落地（2026-09-12）

**实现的是三个轴，不是五个，而且这不是欠账。** `readiumPositions` 需要 archive entry length，而本 spike 没有 archive；`custom` 是逃生口，给它写一个实现等于凭空发明一种 metric。三个轴 —— `CanonicalTextIndexAxis` / `SourceBytesAxis` / `FixedPageOrdinalAxis` —— 各自带来自己的算术，**没有任何一个 metric 的实现是 stub**。没有注册表：哪个轴适用于哪份文档，这一轮由调用方决定，五实现注册表会有四个是空的。

**metric 身份随数值一起走。** `Progression { value, metric }`，`metric` **非可选**。这不是样式：闭合本文档「metric 不写在 UI 能看见的地方」这句话，唯一的机制就是让**想要裸 `Double` 的调用点必须显式丢掉标签**，而那个丢弃点正是出问题的地方 —— 它必须被记进 `discarded`，不得默默发生。`ReadiumLocator.Locations.progression` 保持裸 `Double?`（镜像保真），转换发生在 bridge，丢弃被记录。

**容差由 metric 声明，不由 probe 选择**，且一律以 metric 自己的单位表示（字节 / 页 / UTF-16）。progression 空间不能用来比容差：报告的量化是三位小数（ADR-0011），那里 1e-9 的误差会被写成 `0.0` 并**制造出精确性**。

**三处契约随实测改动：**

1. **`PublicationProgressService` 遇到外来 position 抛错而非夹取。** 夹取会交回一个出版物从未声明过的坐标，且看起来完全真实 —— 与「由分数反算出来的偏移被报成 carried」是同一种缺陷。
2. **`Progression` 的可达范围不是全部 metric 都能覆盖 `0.0...1.0`。** `fixedPageOrdinal` 取页心 `(ordinal + 0.5) / pageCount`（这个约定是为了可证伪而选的：取 `ordinal / pageCount` 时 floor 与 round 同答案，一个把 seek 写成四舍五入的实现会静默通过）。代价是它的可达范围只有 `[0.5 / N, 1 - 0.5 / N]`。**UI 那一层要显示 0 与 1 就必须自己补两端**，而不是假装 metric 给了。
3. **`locations.progression` 是 per-resource，轴的 `progression` 是出版级。** 两者是不同的数，指不同的位置。bridge 写的是前者（`native(from:)` 按 `unit.length` 反算它），而它丢掉的 metric 是 `.canonicalTextIndex` —— 与字段对 EPUB 的 `readiumPositions` 语义**本来就不一致**。这正是本文档早先那条实测（「同一个 `0.5` 在两种 metric 下指不同的位置」）在代码里的样子，现在它被记录了，而不是默默发生。**换成出版级会让每个 offset 都算错，而分划计数仍然全部对得上。**

**准入判据变成了测量，而不是复述。** `progress-layout-independence`：只改容器声明的分页（2 页 → 4 页），同一份字节上问三个 metric —— `sourceBytes` 必须**不动**（锐利臂），`fixedPageOrdinal` 必须**动**（证伪者是一个把页序号实现成字节占比的偷懒写法），`canonicalTextIndex` 必须**不动**（对照臂）。同时测准入侧：容器**没有**声明分页的资源上，页序号必须一律为 `nil` —— metric 拒绝作答，而不是按偶数切一份出来。**一个不可能失败的 probe 没有价值**，所以扫描若一次都没让页序号变化，probe 报 `inconclusive` 而不是 `yes`。

---

## 语义边界（封版，2026-09-12）

本文档此前的措辞把 metric 写成了数值的**附加说明**。实测下来它不是。

```
Position = 数值 + metric + scope + provenance
```

**单独一个 `Double` 没有位置语义。** 以下五条是这份文档的核心，其余章节都是它们的推论。

**一、metric 是 Position 的组成部分，不是附加 metadata。**
`Progression { value, metric }` 里 `metric` **不可选**。这不是防御性编码：它让「取得一个裸 `Double`」变成必须**显式丢标签**的动作，而那个丢弃点正是本文档要盯的地方 —— 丢弃必须被记录，不得默认发生。

**二、不同 metric 的数值空间不可互换，即使底层都是 `Double`。**
`locations.progression` 是 **resource-local**（Readium 的 `EPUBPositionsService` 每条资源一个，`native(from:)` 按 `unit.length` 反算它）；`publication progression` 是 **publication-global**。同一个 `0.5` 在两者下指不同的位置。

> **这类错误不会 crash，也不会落在错误的 outcome bucket 里。**
> 把 publication-global 的数写进那个字段，会让 `native-path-anchored` 的 offset 从 22 反算成 **9**，该行从 `recomputedEquivalent` 掉进 `loses(["utf16Offset"])` —— 而**分划桶的和仍然等于总行数**。桶数的是 outcome，不是真相。比显式失败危险得多，因为它看起来完全合理。

**三、metric round trip 只能证明 navigation fidelity，不能证明 identity preservation.**
本文档性质 1–3 都是导航性质。它们对「这条批注还指着原来那段文字吗」一个字都没说 —— 那是 `AnchorValidator` 的问题，而且要求一条 metric 从未携带过的证据（引文）。**`seek(progress(p))` 落在容差内，不构成 `p` 仍然有意义的任何证据。**

**四、所有 derived position 必须携带 provenance；数值相等不得升级成 carried。**
一个由分数反算回来的偏移可以**恰好**等于原值（`round(o/L × L) == o` 在 IEEE-754 下对这本 fixture 能触及的每个偏移都成立），所以那种相等**从来就不可能失败**，也就不可能是证据。判定必须看来源，不看数值。

**五、metric 的实现必须声明它的容差与吸附策略；单调性与布局无关性必须被验证，不能被声明。**
`ProgressMetricAxis` 上可声明的有两项：`seekTolerance`（以 metric 自己的单位）与 `position(near:)` 的**吸附方向**（否则「落在容差内」是一句无法证伪的话 —— 一个「吸附到最近边界」的实现会把请求 4 答成 5，合法、且在容差内）。单调性与布局无关性是**性质**，由 probe 测量，不由实现自陈：一个把页序号写成字节占比的实现也会「声明」自己单调。

**未闭合的一条**：`readiumPositions` 与 `custom` 两个 metric 没有实现，也**不打算为了矩阵对称去凑**。前者需要真实 archive 才能测（否则只是「我们模拟 Readium，再证明我们的模拟符合我们的预测」），后者没有真实消费者，实现它等于凭空发明语义。等正式接入 ReadiumStreamer 时再补真实 fixture。
