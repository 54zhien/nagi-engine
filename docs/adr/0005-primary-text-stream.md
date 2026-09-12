# Primary Text Stream

**Status:** accepted

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

不得指望 CoreText 自动为 ruby 让出行高。`LineBox` 必须携带：

```
baseAscent / baseDescent
annotationBeforeExtent / annotationAfterExtent
effectiveAscent / effectiveDescent
```

横排时 ruby 向上推高 effective line top，竖排时对应横向的 annotation extent。Ruby 应产出 `RubyFragment`，而不只是 `TextRun(style: ruby)`。

**Consequences**

- 显示 / 隐藏 ruby 不得改变任何 `NativePosition`。
- 若未来加入「隐藏注音」的阅读器设置，**它必须进入 LayoutSignature** —— 因为它改变行度量，进而改变分页。
