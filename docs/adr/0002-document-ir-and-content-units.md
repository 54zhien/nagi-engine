# Document IR and Logical Content Units

**Status:** accepted（shard 的内存模型部分 provisional）

把「文档」拆成三层，各自承担不同职责：

```
DocumentManifest    轻量、完整、同步、Sendable —— 元数据、单元清单、导航树、版本号
DocumentStore       actor —— 惰性物化，按位置取 fragment
DocumentFragment    已物化的局部 IR —— Layout Engine 的直接输入
```

并在概念上区分两个域：

- **`DocumentUnit` = identity domain**。按 publication reading order 排列的、独立可寻址的内容单元。EPUB 通常对应一个 spine item，TXT 对应整本或合理的解析分块。
- **`ContentShard` = processing domain**。物化 / 解析调度 / 缓存 / 排版调度的实现细节。

**`ShardID` 永远不得进入 NodeID、Bookmark、Annotation 或 Native Position。**

**为什么**

把「稳定身份边界」和「性能切块边界」绑成一个概念，会导致调整 chunk 大小就作废全部用户数据。分开之后，改 shard 大小只影响缓存。

**Consequences**

- `DocumentUnit` **不承诺可流式解析**。TXT 可按字节流式；EPUB 的 XHTML 仍需整份 DOM parse（SwiftSoup 不是可续的 SAX），shard 在 EPUB 上只节省 IR 物化、排版与内存，不节省 DOM 解析。
- 文档访问 API 变为 async/fallible：`DocumentStore.fragment(around:) async throws -> DocumentFragment`。
- `DocumentManifest` 保持 `Sendable` 值语义，因此可以跨线程传递；正文的惰性化不外溢到清单层。
- **强不变量**：所有当前可见 `PageScene` 的交互必须完全同步 —— 命中测试、选区起点、链接点击不得触发文档物化、磁盘 IO 或 async 请求。边界是**页内同步、跨页允许 async**（多页选区、跨页扩展）。见 ADR-0008。
- 命名避免与依赖图中的既有类型撞车：`DocumentManifest` 与 Readium 的 OPF `Manifest` 同义不同物，`DocumentFragment` 与 DOM/SwiftSoup 的 `DocumentFragment` 同名。Swift 无命名空间，同一 target 内会强制到处写限定名。**待定：改名 `DocumentOutline` / `ContentFragment`，或统一加前缀。**
