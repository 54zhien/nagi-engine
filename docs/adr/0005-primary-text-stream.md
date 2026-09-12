# Primary Text Stream

**Status:** accepted

**Evidence:** ruby 对 line metric 的影响 —— 在限定环境内已验证（fixture / 字体 / runtime 见下「实验证据」）。本文档其余部分（primary stream 归属、`rt`/`rp` 不占主 offset、`RubyFragment` geometry 归属、annotation stream）是**架构决策**，不由此实验支撑。

存在**一条** primary canonical text stream，所有 Native Position 的 UTF-16 偏移都以它为数轴。

**不占主数轴的**：`<rt>` 与 `<rp>`（注音）、被 CSS 折叠的空白、生成内容。

```
<ruby>東京<rp>(</rp><rt>とうきょう</rt><rp>)</rp></ruby>

Primary canonical text : 東京
不是                   : 東京(とうきょう)
```

**为什么**

若注音占据主 offset，则「显示 ruby」与「隐藏 ruby」会改变 `NativePosition` —— 这是绝对不能接受的。空白折叠同理：它改变渲染结果，但不得改变文档坐标系。

**IR 表示**

```
RubyNode
├── base        → Text("東京")
└── annotation  → RubyAnnotation("とうきょう")
```

`<rp>` 是 fallback presentation metadata，Native Ruby Renderer 正常不绘制。注音作为独立的 **annotation stream** 存在，可携带自己的 `RubyAnnotationID` 与文本位置，供**读音搜索、TTS 发音、注音编辑、无障碍**使用，但**不进入**阅读进度、书签、普通选区、主文本 range。

**Ruby 参与 line metric 是 Nagi Layout 的责任**

**实验证据（Spike B，2026-09-12）**

固定 fixture `京都 / きょうと`、bundled font `STYuanti-SC-Regular`、macOS 15 CI runtime，ruby size factor `0.5`：

```
plain line height   22.400pt
ruby line height    33.600pt
增量                11.200pt
```

该增量与 `8pt × 1.4 = 11.200pt` 完全一致（`8pt` = annotation 字号 `16 × 0.5`；`1.4` = 该字体在本实验中的 line-height / font-size 比例）。**这是对观测结果的机制解释，不视为 CoreText API 契约。**

因此可以确认：**在本 fixture、字体与 runtime 下，CoreText 生成的 line metrics 已包含 ruby annotation 带来的额外垂直 extent。**

这推翻了本文档早期的实验假设 ——「不得指望 CoreText 自动为 ruby 让出行高」—— 但不改变架构决策：**Nagi 仍拥有最终 `LineBox` / `RubyFragment` geometry 的决策权。** 竖排、连续 ruby、跨行 ruby、多字号 ruby、碰撞处理与最终 fragment geometry 均不委托给 CoreText。CoreText 提供**测量证据**，不提供**最终几何**。

**测量的前提条件**

同一 probe 在缺字 base（`東京 / とうきょう`，`東` 无字形，CoreText 已替换字体）上得到 `8.000pt`。相对干净值 `11.200pt`：

```
干净值比污染值高    (11.2 − 8.0) / 8.0   = 40%
污染值比干净值低    (11.2 − 8.0) / 11.2  ≈ 28.6%
```

两种说法都对，指向同一件事：**被污染的测量不是「不可信」，而是错的** —— 它在报告里与一次正常测量看不出任何区别。因此凡用于架构判断的 ruby metric probe，必须先证明 base 与 annotation 均由预期字体绘制、且不存在字体替换（实现见 `ruby-line-height` 的 soundness 检查与 `ruby-base-font-fallback`）。

`LineBox` 必须携带：

```
baseAscent / baseDescent
annotationBeforeExtent / annotationAfterExtent
effectiveAscent / effectiveDescent
```

横排时 ruby 向上推高 effective line top，竖排时对应横向的 annotation extent。Ruby 应产出 `RubyFragment`，而不只是 `TextRun(style: ruby)`。

**Consequences**

- 显示 / 隐藏 ruby 不得改变任何 `NativePosition`。
- 若未来加入「隐藏注音」的阅读器设置，**它必须进入 LayoutSignature** —— 因为它改变行度量，进而改变分页。
