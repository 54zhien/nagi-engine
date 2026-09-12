# TODO

## 当前任务：Spike A —— Locator ↔ NativePosition 身份往返

Spike B 已封版于 `763e2c9`（证明了 Nagi 能掌握**排版**）。Spike A 要证明 Nagi 能掌握**身份**。
计划全文见 `C:\Users\Azusa\.claude\plans\bubbly-enchanting-alpaca.md`。

**已拍板**：macOS SwiftPM + Locator 忠实镜像（Readium 是 iOS-only，不能作依赖）；`NativePosition` 先不带 `documentOrder`。

- [x] `Package.swift` 增加 `SpikeAKit` / `SpikeA` / `SpikeAKitTests`
- [x] `JSONValue`（最小 JSON 值，`otherLocations` 与 `domRange` 需要）
- [x] `ReadiumLocator` 镜像 —— 八个编码/解码怪癖逐条带出处
- [x] `Href` 归一化（**局部镜像**：Readium 的 `normalizedPath` 规则未复刻，已在文件里标注）
- [x] `CanonicalText` —— XHTML → canonical primary text（`rt`/`rp` 不占数轴 + 显式折叠规则）
- [x] `NodeIdentity` —— ADR-0003 阶梯前两级（显式 id → DOM path）
- [x] `DocumentModel` —— `DocumentUnit` / `NativePosition`
- [x] `LocationBridge` —— **不设 href 短路**，每条定位都真的走解析
- [x] `RoundTrip` —— 五类分类 + 逐字段判定
- [x] `Fixture` —— 源码内嵌的「解压后 EPUB」，各轴各有对应用例
- [x] `SpikeAReport` + `Sources/SpikeA/main.swift`（沿用 B 的报告纪律与跨进程指纹）
- [x] `Tests/SpikeAKitTests/` —— 镜像保真度 / canonical text / 身份与往返
- [x] `.github/workflows/ci.yml` 的 Gate 2 增加 `spike-a` 三进程比对
- [ ] **在 macOS 上跑 Gate 1** —— 本机无工具链，第一次 CI 前不声称任何结论

### 写作过程中靠阅读（而非编译器）抓到的真 bug

1. `didEndElement` 把保存的 `pendingSeparator` **或**回去 → `<p>foo <b>bar</b> baz</p>` 会多出空格。
2. 悬挂空格在**子元素内部**才结算 → `<p>前</p><p>空白</p>` 里第二个 `<p>` 的范围会以空格开头，它里面每个 offset 都偏 1。
3. `elements(withText:)` 用 `String.index(offsetBy:)` 数**字符**，而范围是 **UTF-16 单元** —— 非 BMP 字符上必错。
4. `DeterminismRecord` 无 public init，**跨模块构造不了**（见下方「偏离计划的一处」）。

### 偏离计划的一处（需知悉）

计划里「不动 Spike B 的任何文件」。实际改了 `Sources/SpikeKit/Report.swift` **一处**：给 `DeterminismRecord` 加了 `public init`。原因是 `SpikeAKit` 是另一个模块，合成 memberwise init 是 internal，不暴露就构造不了。**纯增量**，Spike B 行为不变，其测试仍在跑。

## Review

（完成后记录）
