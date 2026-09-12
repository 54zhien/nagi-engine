# Position and Anchor Model

**Status:** accepted

两套坐标系 + 一个显式桥梁：

```
Publication Position     Readium Locator 承载。跨引擎、跨会话、跨设备同步的身份。
                         Nagi 与 Readium 之间唯一共享的位置语言。
Native Position          unitID + nodeID + UTF-16 offset。Nagi 排版内部的精确坐标。
Location Bridge          二者之间唯一的双向转换点。
Page Index               当前排版的派生输出。
```

**页序号是输出，不是真相来源** —— 任何持久化数据都不得以它为主键。

`utf16Offset` 指向 **canonical primary text**，不是渲染后的文字。**CSS 空白折叠属于 Layout，不得改变文档坐标系。** 选择 UTF-16 是因为 CoreText / CFString / NSAttributedString / NSRange / UIKit selection 全部以 UTF-16 index 工作。

**锚定职责分三层，不得合并**

| 层 | 回答的问题 | 性质 |
|---|---|---|
| `PositionResolver` | 这个 offset 合法吗？该吸附到哪里？ | 结构 / 边界问题。按 `TextBoundaryPolicy` 分策略：`.storage`（不切 surrogate）、`.caret`（EGC）、`.shapingCluster`、`.lineBreak`（UAX #14） |
| `AnchorValidator` | 这个位置现在指的还是原来的内容吗？ | 语义一致性问题。不吻合即 INVALID |
| `ReanchorService` | 原锚失效后能否重新找到它？ | 模糊重锚：`exact` + `prefix` + `suffix` |

**为什么必须分开**

缺 `AnchorValidator` 的后果比丢失更糟：批注会**静默地指到错误的位置上**，用户不会收到任何错误提示。

并且要分清两个不同的问题，不可声称其一解决了其二：

```
NodeID 分层方案        → 解决 re-parse 稳定（同一份文件，解析器升级）
                       ✗ 不解决跨来源匹配
Quote/Context Reanchor → 解决跨版本、跨来源恢复
```

跨来源时（同一本书从不同站点下载），显式 `id=` 也不同 —— 出版社工具生成的 `id="_idTextAnchor042"` 各版本不同。

**Consequences**

- 只有 `.storage` 策略是**文档级不变量**；`.caret` / `.shapingCluster` / `.lineBreak` 是请求时策略。类型上不应混为一谈。
- `AnchorValidator` 与 `ReanchorService` 需要读取文本，因此在 `DocumentStore` 惰性物化之后**它们是 async 的**。
- 若 ADR-0003 的文档序键采用路径 2，`NativePosition` 需增加 `documentOrder` 字段。

**Spike A 的实测（2026-09-12）**

- **本文件开头那句断言已由论断升级为测量。** 「缺 `AnchorValidator` 的后果比丢失更糟」原本是论证；spike 的 18 条往返里 **18 条都需要 validator 才能确认身份**，没有任何一条靠结构自证。这不是实现不足：`NativePosition` 是坐标，坐标里没有地方放「它当初凭什么被确立」。而其中唯一看起来精确往返的那条，是靠 ADR-0009 禁止用于此途的 `Double` 算回来的。

- **Publication Position 的表达能力有边界，且边界在两侧都成立。** 它能**命名一个元素**，不能**命名元素内的偏移**：`fragments` 止于元素，而唯一能承载元素内偏移的一类字段（`domRange` / `partialCfi`）**Readium 自己的生产者也不发**（`dom.js:55-67`）。因此 `native → locator → native` 丢掉元素内偏移**不是 bridge 的缺陷，是坐标系的表达极限**；要补回来只能经由 `progression`，而 ADR-0009 禁止。
  - 连带的更正：曾把「`locator(from:)` 优先发 `fragments`」记为精度上的错误取舍 —— 不成立。该函数**同时**发 `fragments` 与 `progression`；丢 offset 的是解析侧在 fragment 命中后停止下探（`native(from:)`），而那是**正确的**，因为已经没有合法通道可走。

- **兜底是假的兜底。** `totalProgression` **只能定位到资源，定位不到资源内的位置**。实测 `unknown-href-with-fallback`（未知 href + 仅 `totalProgression`）落到 `requiresReanchor`，而非预期的「只丢 href」—— bridge 找到了 unit，却在 unit 内无物可依（该 locator 没有 fragment / cssSelector / progression / position）。把一个只能定位到资源的标量当作位置兜底，不成立。
