# CSS Cascade Architecture

**Status:** accepted

`NagiCSS` 分两层：

```
完整、正确的 Cascade Core      tokenizer → 规则树（at-rule / 简写展开 / !important）
                              → 选择器匹配 → 特异性 → 级联 → 继承
                              → computed value 顺序 → UA 样式表

有边界的 EPUB CSS Profile      受支持的 property / selector 子集
```

**级联核心不得半吊子；覆盖面可以是子集。这是两件事。**

**为什么**

最危险的状态不是支持得少，而是**支持很多属性但 cascade 是错的** —— 那会产生大量无法解释的 EPUB bug。宁可 20–40 个属性 + 正确的 cascade，也不要 100 个属性 + 经常出错的 `!important` / inheritance / specificity。

**易错点（必须在核心中做对，不能留给以后）**

- `!important` 会**同时反转 origin 与 layer 顺序**
- `:is()` / `:not()` / `:has()` 取最具体参数的权重；`:where()` 恒为零
- computed value 有顺序：先算 `font-size`，再算依赖它的 `em` / `rem`
- shorthand 展开、`inherit` / `initial` / `unset` / `currentColor`

**超出 Profile 的处理**

由 `NativeCapabilityDetector` 判定，交给 Compatibility Renderer（见 ADR-0010）。明确不支持的：复杂 SVG、MathML、CSS Grid、复杂 float、复杂伪元素。

**Consequences**

- Swift 生态**没有任何级联 + 特异性实现**。已核查：`SwiftCssParser` 是扁平查表；`swift-css-parser` 是 LGPL（iOS 出局）；`CiderCSSKit` 自述缺组合器与伪元素；`swift-w3c-css` 的 `Sources/W3C CSS Cascade/` 只有两个文件。这是一个自研子工程。
- WebKit 的引擎拿不出来用：WebCore 不公开，`getComputedStyle` 需异步 `evaluateJavaScript`，与同步重排不兼容。
- 可移植参考：**litehtml**（BSD-3，其 `css_priority` 即 importance+layer+specificity，含 `inherited` 参数与正确的 computed-value 顺序）、Servo 的 `style`/`selectors`/`cssparser`。
- `SwiftSoup` 只负责 `HTML → DOM → selector querying`。**它不是级联引擎**，其选择器与浏览器 Selectors Level 4 的等价性需自建 compatibility tests，不得在架构文档中假定「完整」。
