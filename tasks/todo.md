# TODO

## 当前任务：Spike A —— Locator ↔ NativePosition 身份往返

Spike B 已封版于 `763e2c9`（证明了 Nagi 能掌握**排版**）。Spike A 要证明 Nagi 能掌握**身份**。
计划全文见 `C:\Users\Azusa\.claude\plans\bubbly-enchanting-alpaca.md`。

**已拍板**：macOS SwiftPM + Locator 忠实镜像（Readium 是 iOS-only，不能作依赖）；`NativePosition` 先不带 `documentOrder`。

- [ ] `Package.swift` 增加 `SpikeAKit` / `SpikeA` / `SpikeAKitTests`
- [ ] `JSONValue`（最小 JSON 值，`otherLocations` 与 `domRange` 需要）
- [ ] `ReadiumLocator` 镜像 —— 八个编码/解码怪癖逐条带出处
- [ ] `Href` 归一化（**局部镜像**：Readium 的 `normalizedPath` 规则未复刻，须标注）
- [ ] `CanonicalText` —— XHTML → canonical primary text（`rt`/`rp` 不占数轴 + 显式折叠规则）
- [ ] `NodeIdentity` —— ADR-0003 阶梯前两级（显式 id → DOM path）
- [ ] `DocumentModel` —— `DocumentUnit` / `NativePosition`
- [ ] `LocationBridge` —— **不设 href 短路**，每条定位都真的走解析
- [ ] `RoundTrip` —— 五类分类（exact / semanticEquivalent / lost / requiresValidator / requiresReanchor）
- [ ] `Fixture` —— 源码内嵌的「解压后 EPUB」，七条轴各有对应用例
- [ ] `SpikeAReport` + `Sources/SpikeA/main.swift`（沿用 B 的报告纪律与跨进程指纹）
- [ ] `Tests/SpikeAKitTests/` —— 镜像保真度 / canonical text / NodeID / bridge / 分类
- [ ] `.github/workflows/ci.yml` 的 Gate 2 增加 `spike-a` 三进程比对
- [ ] **在 macOS 上跑 Gate 1** —— 本机无工具链，第一次 CI 前不声称任何结论

## Review

（完成后记录）
