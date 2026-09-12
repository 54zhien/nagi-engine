# Identity Scheme

**Status:** accepted；文档序键部分 **provisional**

`NodeID` 必须是 deterministic 的，由稳定 source identity 主导，按优先级解析：

1. 原文显式 ID（`id=` / `xml:id=` / EPUB anchor）
2. Source-local stable anchor（DOM path / XML path / TXT source range）
3. 父节点稳定身份 + node kind + content fingerprint
4. source position
5. `sameFingerprintOrdinal` —— **仅作最后消歧手段**

第 5 条不得被宣传为强稳定性方案。它的正确含义是「**同 fingerprint 的兄弟节点中我是第 N 个**」；若实现成「同级中第 N 个」，那就是被禁止的数组下标换了个位置。即便正确实现，在**内容完全相同**的节点被插入时仍会漂移。

**稳定性承诺（不外扩）**

> 对同一 source artifact，在 identity scheme 不变的情况下必须 deterministic；对发生内容编辑的不同 artifact **不保证** NodeID 持续稳定，由 `ReanchorService` 负责恢复。

**版本号（三个，分开）**

- `identitySchemeVersion` —— 影响 DocumentUnitID / NodeID / Native Position 的锚定语义。
- `documentSchemaVersion` —— 影响 Nagi IR 的序列化格式，用于缓存迁移。
- `layoutAlgorithmVersion` —— 影响 PageMap / PageScene / Layout cache。改了禁则、断行、widow & orphan，只需清 Layout cache，**绝不能让批注失效**。

**bump `identitySchemeVersion` 的判据**

> 当同一 source artifact 在新实现下可能产生不同的 **durable identity**、**canonical primary text**、**source-to-native mapping** 或 **persisted anchor semantics** 时，必须 bump。

禁则算法、分页、glyph geometry 的变化**不** bump identity，只 `layoutAlgorithmVersion++`。

**PROVISIONAL —— 文档序键**

`PageMap` 的二分查找与搜索结果排序需要 O(1) 比较两个 `NativePosition` 的先后。跨 `DocumentUnit` 可由 manifest 中的单元顺序解决；**单元内**若 `NodeID` 是不透明哈希，则比较必须物化 fragment，`pageMap.page(containing:)` 会退化为 async —— 而它每次翻页、恢复位置、搜索都要走。

三条可选路径，尚未选定：

1. `NodeID` 改为路径形状（如 `[UInt32]`），字典序比较 O(depth)，无需物化。
2. `NativePosition` 额外携带 `documentOrder: UInt64`。
3. 接受异步（记作不可接受）。

注意路径 2 **不违反**「禁止下标当身份」：该原则禁止的是**用解析顺序当身份**；文档序由内容决定（同一输入必得同一序），且身份与序是两个不同关注点 —— 身份可继续用哈希，序单独成字段。

此决定影响 ADR-0004 的 `NativePosition` 形状与 ADR-0008 的 PageMap 查找路径，须在实现 DocumentManifest 前定。
