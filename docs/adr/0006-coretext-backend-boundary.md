# CoreText Backend Boundary

**Status:** accepted

CoreText 是 Nagi 的 shaping / typography **backend**；Nagi 拥有 block flow、line policy、fragmentation、column/page geometry 与 pagination decisions。

```
CoreText 可以回答          Nagi 决定
────────────────────      ────────────────────
这些 glyph 怎么 shape      是否就在这里断行
给定宽度下候选断点在哪      这一行属于哪一栏
这一行实际 ascent/descent   这个块能不能拆
                          这一页在哪里结束
                          widow / orphan 怎么处理
```

**为什么不写成「Line/Column/Page 归 Nagi」**

字面太死会误伤 `CTTypesetterSuggestLineBreak` / `CTLine` / `CTRun` —— 以后使用这些 API 看起来像违反本 ADR。**不禁止使用它们；禁止的是让它们成为页面几何的最终决定者。**

**为什么必须这样分**

禁则处理、追い込み/追い出し、标点挤压、hanging punctuation、縦中横、竖排列流 —— **全部在 CoreText 之外**。若 CoreText 的 frame 就是 page，则没有任何缝可以插入它们。

**为什么不采用 TextKit 2**

- TextKit 2 **没有分页 API**，从未有过。`NSTextContainer` 是单数；TextKit 1 的分页机制恰是 `NSLayoutManager.textContainers` 那个数组。Apple 工程师 2021 年在开发者论坛答复「此功能不可用，我们正在调查」，此后两次追问无回复，WWDC26 该 session 逐字稿中 `grep -i "pag"` 仅命中 "propagate" 一词。
- `NSAttributedString.Key.verticalGlyphForm` 在 iOS 上**文档明写 undefined**；`NSTextLayoutManager` 没有指定排版方向的 API。CoreText 是 Apple 平台上唯一有文档的竖排引擎。
- TextKit 2 的主要价值（`NSTextSelectionNavigation`、attachment、无障碍树）恰好是本引擎要用自己的 `LineFragment` + `PageInteractionMap` 替换掉的部分。

**Consequences**

- **竖排需要独立验证**：`CTFramesetterSuggestFrameSizeWithConstraints` 的 `fitRange` 假设水平填充模型，在 `CTFrameProgression.rightToLeft` 下不可信；`CTFrameProgression` 需传**数字 rawValue**，传 Swift enum 会静默失败。竖排度量来自字体的 `vmtx`/`vhea` 表 —— Hiragino / PingFang / Songti 有，SF Pro 没有。
- 选择 UI（手柄 / 放大镜 / 菜单 / 复制）、VoiceOver、词典 Look Up、文本缩放**全部自研**。这些目前由 Readium 提供。
- Pending Spike B：验证 Nagi 能在自己控制 fragmentation 的前提下，把 CoreText 驯成可控 backend。
