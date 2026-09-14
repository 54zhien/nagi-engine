# Identity Scheme

**Status:** accepted

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

**文档序键（2026-09-13 定案）**

`PageMap` 的二分查找与搜索结果排序需要 O(1) 比较两个 `NativePosition` 的先后。**结论：不需要给 `NativePosition` 增加任何字段，也不需要改动 `NodeID`。**

序号就是：

```
(单元在 manifest reading order 中的序号, 该单元 canonical primary text 内的绝对 utf16Offset)
```

**两个排序分量都能从 `NativePosition` 与当前 manifest 联合取得，无需物化正文。** 第二半是位置自带的 `utf16Offset`：它在**该单元的 canonical primary text 内是绝对偏移，不是相对于节点的** —— ADR-0005 已把那条流定成「由各单元的 primary text 按 reading order 拼接」，偏移是它在自己那一段内的绝对偏移，**不是全书坐标**。第一半在 manifest 上 —— 它是单元在 `readingOrder` 里的下标，**不在位置类型里**。`unitID` 解析不到时就没有键 —— 见下面「失效 unit」一行。

### 原 provisional 判据的三处失准

这一节此前写成 provisional，是因为三个判断里有两个已不成立、第三个被表述错了：

1. **「若 `NodeID` 是不透明哈希，则比较必须物化 fragment」—— 这个前提不是从未可能成立，而是与排序问题无关。** 本 ADR 的阶梯里本来就有内容 fingerprint 形态的级（第 3 级「父节点稳定身份 + node kind + content fingerprint」、第 5 级 `sameFingerprintOrdinal`），所以 `NodeID` 完全可以是不透明的。它错在排序**不需要读** `NodeID` —— 无论 `NodeID` 是什么形态，物化都不是比较的前提。
2. **「单元内排序依赖 `NodeID`」这个框架本身就是错的。** `utf16Offset` 已经是单元内的绝对坐标，它**就是**单元内的文档序；`NodeID` 回答的是「哪一个元素」，不是「在文档的哪里」。把排序挂在身份上，是这一节最初的病根。
3. **`documentOrder: UInt64`（原路径 2）是一份冗余编码。** 它要表达的量已经可由 `(单元序号, 偏移)` 完全导出。给一个坐标加一个「同一件事的第二份真相」，正是本仓反复在防的那类缺陷。

原路径 1（`NodeID` 改为路径形状）**不必做**：即便 `NodeID` 全是路径，同一个元素内的两个位置仍要靠 `utf16Offset` 分先后，所以路径比较**单独也不充分**。原路径 3（接受异步）**不需要**：物化 fragment 不是这条路径的必要条件。

### 由此产生的要求

- **`NodeID` 不得参与排序**，也不得用作并列时的裁决者。见下。
- **`DocumentUnit.id` 在一个 manifest 内必须唯一，重复必须在构造 manifest 时失败** —— 不得静默 first/last wins。`href` 是路由信息，不等于身份；本 spike 让 `id = href` 只是夹具的做法（它的四个 href 互不相同）。各格式如何生成稳定 ID 属于正式 ingest 的设计。排序的第一半按 `unitID` 解析序号，因此依赖这条；但这条不是排序契约发明的约束，而是身份方案自己的要求 —— 强制的落点是**正式 manifest 的构造**，本 spike 的 `Document` 是夹具载体，不承担该校验。
- **`NativePosition` 不缺字段；正式仓需要的是「unit-index 查询 API」与「独立的 order-key 投影」这两样。** 今天 `unit(withID:)` / `unit(withHref:)` 返回单元本身，不返回它在 `readingOrder` 里的下标。API 的形状已定：

  ```swift
  DocumentManifest.readingOrderIndex(of unitID: DocumentUnitID) -> Int?
  ```

  零基、按 `id` 的**原样相等**建键（`href` 的比较才是归一化的，两条解析路径不得混用）、由构造时预计算的**私有** map 承载、O(1)、不公开 `[ID: Int]`、未知 ID 返回 `nil`。**它是正式引擎仓的入口要求**：本 spike 里没有**新的**消费者 —— 同一次解析在 `CanonicalTextIndexAxis.coordinate(of:)` 里是就地内联的一行，把它抽出来只是重构，今天没有第二处要用它。

### 并列（同单元、同偏移、不同 `NodeID`）

**它们是同一个文本坐标，不是需要稳定次序的两个位置。** 排序是 `(单元序号, 偏移)` 上的**全预序**：两键相同即并列，而 `page(containing:)` 对并列必须返回同一页。用 `NodeID` 去打破并列是错的 —— 那等于用一个**不参与文档序的**身份去冒充次序。

**`NativePosition` 不加 `Comparable`。** 它的 `Equatable` 由合成而来、含 `NodeID`；一旦 `<` 只按 `(单元序号, 偏移)` 判定，两个只差 `NodeID` 的位置会满足 `a != b`，而 `a < b` 与 `b < a` 同时为假 —— 三值互斥的语义被打破。正式实现把排序放在一个**独立的投影** `DocumentOrderKey(unitIndex, utf16Offset)` 上。

那个投影是 **PageMap / manifest snapshot 的内部值**：`internal`、**非 `Codable`**、不持久化；两个字段只是同一份 snapshot 内的排序 payload。**裸二元组本身不携带作用域**，所以一旦将来要越过它的 owner 公开传递，必须给它一个 **manifest scope identity**，而不是继续沿用两数并列的形状。

（相邻问题：这条路径上「存储的 `NodeID` 是否仍与文本一致」由 `AnchorValidator` 回答，它已经**不信任**存储的 `nodeID` 并**从当前文本重建**。见 ADR-0012。）

### 边界语义

| 情形 | 语义 |
|---|---|
| **manifest 重排** | 单元序号改变 ⇒ 跨单元次序随之改变。这是**正确**的：文档被重排了，阅读顺序就该变。次序是**文档的函数**，不是位置自带的常量。 |
| **跨 manifest** | **不可比较。** `unitIndex` 只在生成它的那份不可变 manifest snapshot 内有意义 —— 不同的书、或同一本书重排前后的 `(3, 20)` 不是同一个键。order key 也**不得持久化**。 |
| **失效 unit**（`unitID` 不在 manifest 中） | **不可排序**：没有序号可解析。必须是一个**已定义的**结果，不是崩溃、不是「排到最后」。这与 ADR-0012 里 `.notExpressible` 是同一类情形 —— 位置根本写不出去。 |
| **空 unit**（`utf16Count == 0`） | 次序**良定义**：空单元里只有偏移 `0` 指得向任何东西，它正好落在前后邻元之间。`CanonicalTextIndexAxis` 已按此处理空单元（「空单元在它上面是良定义的」）。 |
| **offset 越界**（负值，或超过该单元当前正文长度） | **是合法性，不是次序。** 归 `PositionResolver` 与 PageMap containment 管；order key 只做投影、不校验 —— 能算出两个数，不代表它是当前文档里的有效位置。让 key 去校验的代价是：**为了构造键，轻量 manifest 就得预先掌握每个单元的长度**，正是本方案要避免的物化依赖。 |
| **重复 href** | 拆成两件事：**重复的 `DocumentUnitID`** ⇒ manifest 构造失败（见上）；**href 相同但 `id` 不同** ⇒ 文档序仍然良定义，键是 `id`，不是 href。`unit(withHref:)` 遇到歧义怎么办是**路由**问题，本 ADR 不替它定案。 |

### 本决定不覆盖什么

- **不新增 `NativePosition` 字段** —— ADR-0004 里它的形状本来就是 `unitID + nodeID + utf16Offset`，不变。
- **不决定 `DocumentUnit.id` 由什么构成** —— 唯一性已定，构成留给正式 ingest。
- **不实现 `PageMap`。** ADR-0008 那句「若 ADR-0003 的文档序键未定，`PageMap` 的二分查找路径无法确定」由此解除 —— 查找路径可以按「先按单元序号定位单元、再在单元内按偏移定位页」来设计。
