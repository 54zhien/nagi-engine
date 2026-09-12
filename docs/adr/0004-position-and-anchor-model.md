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
