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

> **「模糊重锚」里的「模糊」容易被读错，这里说清。** 它**仅指不依赖旧的精确位置**，**不代表近似文本匹配**。实现是**逐 UTF-16 code unit 的字面匹配**：不做编辑距离、不做分词、不做标点宽松、不做 Unicode 归一化，也**不按距离或旧身份选「最近」**。`prefix` / `suffix` 只承担一件事 —— 在多个字面命中之间消歧。契约与实测见 **ADR-0012**。

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
- ADR-0003 的文档序键已定案（2026-09-13）：次序 = **单元在 reading order 中的序号 + 单元内绝对 `utf16Offset`**，两个分量都能从 `NativePosition` 与当前 manifest 联合取得。因此 `NativePosition` **不增加** `documentOrder` 之类的字段，形状不变。

**Spike A 的实测（2026-09-12）**

- **本文件开头那句断言已由论断升级为测量。** 「缺 `AnchorValidator` 的后果比丢失更糟」原本是论证；spike 实测把它拆成了两行，因为**「需要 validator」与「需要 reanchor」不是一个问题的两个答案**：

  ```
  22 条往返
  16 条产出了候选   → 16/16 有待验证的东西：15 条得到一个位置，1 条得到多个候选
   7 条产不出位置   →  7/7  结构上做不出来，只能交给 ReanchorService
  ```

  没有任何一条靠结构自证。这不是实现不足：`NativePosition` 是坐标，坐标里没有地方放「它当初凭什么被确立」。其中唯一看起来精确往返的那条，是靠 ADR-0009 禁止用于此途的 `Double` 算回来的。

  **「产不出位置」这一行的第 7 条是 spike 封版时才补上的（2026-09-13）**，用例名 `native-position-in-a-unit-that-no-longer-exists`：在此之前 `ResolutionShape.notExpressible` —— 「位置根本写不出去」这个形状 —— 零覆盖，因为 **native 方向**每一行的 `unitID` 都取自 fixture 真有的 unit（两行 `unknown-href-*` 确实指着一个不存在的 href，但它们是 locator-first，`locator(from:)` 从没被递过 corpus 自己编的 `unitID`）。补上它之后，「产不出位置」不再只是一句断言，而是一条有行的路径。同日还删掉了 `RoundTripOutcome.requiresValidator` —— 那个 outcome 没有任何路径能产生，它当初正是掩盖这条路径的东西。

  **一条同时在两行里，而且是应当的**：`quotation-repeated` 的引文在文档里出现两次，bridge 找到 **2 个候选** —— 有东西可验证（`AnchorValidator` 要做的正是在候选中挑出仍然指向同一内容的那一个），但没有**单一位置**可确认（`ReanchorService` 是它的兜底）。把「有候选」与「有位置」当成同一件事，会让这一行两边都报错。

- **三层职责里，「没有候选」是一条独立的路径。** `AnchorStrategy` 产出候选 → `AnchorValidator` 验证 → 都失败才进 `ReanchorService`。中间那层的输入是**候选**，所以一条产出不了候选的往返**根本没有东西交给 validator**，它直接进第三层。第一版把「需要 validator」无条件写死成真，于是 20 条里 20 条都声称有 validator 的活要干，而其中 5 条一个候选都没产出。**仪表说它测到了，而它测的是一句构造为真的断言。**

- **Publication Position 的表达能力有边界，且边界在两侧都成立。** 它能**命名一个元素**，不能**命名元素内的偏移**：`fragments` 止于元素，而唯一能承载元素内偏移的一类字段（`domRange` / `partialCfi`）**Readium 自己的生产者也不发**（`dom.js:55-67`）。因此 `native → locator → native` 丢掉元素内偏移**不是 bridge 的缺陷，是坐标系的表达极限**；要补回来只能经由 `progression`，而 ADR-0009 禁止。
  - 连带的更正：曾把「`locator(from:)` 优先发 `fragments`」记为精度上的错误取舍 —— 不成立。该函数**同时**发 `fragments` 与 `progression`；丢 offset 的是解析侧在 fragment 命中后停止下探（`native(from:)`），而那是**正确的**，因为已经没有合法通道可走。

- **兜底是假的兜底。** `totalProgression` **只能定位到资源，定位不到资源内的位置**。实测 `unknown-href-with-fallback`（未知 href + 仅 `totalProgression`）落到 `requiresReanchor`，而非预期的「只丢 href」—— bridge 找到了 unit，却在 unit 内无物可依（该 locator 没有 fragment / cssSelector / progression / position）。把一个只能定位到资源的标量当作位置兜底，不成立。
