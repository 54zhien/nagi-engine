# 文档序键执行计划

**方案由 Codex 给出，Claude 执行。** 本文件记录 D0 定案、D1 文档收口，以及正式引擎入口契约。

## D0 的结论（已完成）

序号 = **(单元在 manifest reading order 中的序号, 该单元 canonical primary text 内的绝对 `utf16Offset`)**。

**不加字段。** `documentOrder: UInt64` 会是一份冗余编码 —— 它要表达的量已由上面两项完全导出。

**`NodeID` 不参与排序。** 原前提「单元内排序依赖 `NodeID`」不是从未可能成立（阶梯第 3、5 级本身就是 fingerprint 形态），而是**与排序问题无关** —— `utf16Offset` 已经是单元内的绝对坐标，它**就是**单元内的文档序；`NodeID` 回答「哪一个元素」，不是「在文档的哪里」。

**缺的不是字段，是两样东西：** 一处「unit-index 查询 API」与一个「独立的 order-key 投影」—— 见下面「正式引擎入口契约」。

**连带把 Primary Text Stream 的偏移语义统一了**（ADR-0005 + `CONTEXT.md`）：偏移是 **unit-local 的绝对偏移**，不是全书坐标；那条流由各单元的文本按 reading order 直接拼接、不插入合成分隔符，出版级坐标是由它导出的 metric。两读并存的话，「单元序号 + 单元内偏移」这个键就站不住。

### 提交边界（Codex 裁定）

- `tasks/lessons.md` **独立一次提交**（本仓要求「每次被纠正后立即追加」，不属于 D0 契约扩项）；
- D0 契约提交**不含** lessons；
- D1 文档收口再独立一次。

---

## D1 — 文档收口（已完成；按上述「提交边界」独立提交）

- 更新 ADR-0008 里那句「若 ADR-0003 的文档序键未定，`PageMap` 的二分查找路径无法确定」—— 改为已定，并写明查找路径的两层结构：**先按单元序号定位单元，再在单元内按偏移定位页**（v1 是 hard pagination boundary，页不跨 unit，这个两层结构是它的直接推论）。
- 更新 `tasks/todo.md`：**历史段落保留、不逐处篡改**，只在新段顶部统一说明已被取代 —— 指认走**内容**而不是行号（第一轮那条「`NativePosition` 先不带 `documentOrder`」，加上此后三轮各自那条把文档序键列为未做 / 未触及的收尾项）。行号会随新段插入而整体漂移，写行号等于写一个必然过期的常数。
- **不写 PageMap 实现** —— 那是正式引擎仓的事。

**✅【确认点 D1，已通过】：未提交 diff 已交 Codex 复审并获放行。**

---

## 正式引擎入口契约（**不属于本计划，也不在本仓实现**）

形状已定，两个都归属正式引擎仓：

1. **`DocumentManifest.readingOrderIndex(of unitID: DocumentUnitID) -> Int?`** —— 零基、按 `id` 的**原样相等**建键（`href` 的比较才是归一化的，两条解析路径不得混用）、由构造时预计算的**私有** map 承载、O(1)、不公开 `[ID: Int]`、未知 ID 返回 `nil`；**重复 ID 在 manifest 构造时失败**。
2. **`DocumentOrderKey(unitIndex, utf16Offset)`** —— 一个**瞬态投影**，不是 `NativePosition` 的 `Comparable`（后者 `Equatable` 含 `NodeID`，`<` 忽略它会得到 `a != b` 而双向 `<` 皆 false）。它是 PageMap / manifest snapshot 的**内部值**：`internal`、**非 `Codable`**、不持久化；两个字段只是同一份 snapshot 内的排序 payload。**裸二元组不携带作用域** —— 将来若越过 owner 公开传递，必须给它一个 **manifest scope identity**。

**判据**

- 序号来自**数组下标**，不是从 id 现算的哈希，也不是任何形式的排序。
- 解析失败（`unitID` 不在 manifest 中）是一个**已定义的**结果：**没有序号**，与「排到最后」不同，也与崩溃不同（ADR-0003 已把它写成与 `.notExpressible` 同类的情形）。
- 键只在**同一份不可变 manifest snapshot** 内可比较；不得跨 manifest 比较，不得持久化。
- **排序层不校验 offset 合法性** —— 越界偏移归 `PositionResolver` 与 PageMap containment；否则为构造键，轻量 manifest 得预先掌握每个单元的长度，正是本方案要避免的物化依赖。
- `NodeID` 既不参与键，也不得用于打破并列。
- 不改 `NativePosition`、`NodeID`、`DocumentUnit`。

**本仓不写它们的理由**：spike 里没有**新的**消费者（同一次解析在 `CanonicalTextIndexAxis.coordinate(of:)` 里是就地内联的一行），写出来会是一处没有消费者的零用途 API，违反 README 那句「这个仓库不是引擎本体，也不会长成引擎」。二者是正式引擎仓的**第一个真实纵切**，由 PageMap 消费 —— 带着自己的用例来。

---

## Codex 已裁定的事

1. **`DocumentUnit.id` 的唯一性 —— 已定案。** 在一个 manifest 内必须唯一；重复**在构造时失败**，不得静默 first/last wins；`href` 是路由信息、不等于身份，`id = href` 只是本 spike 夹具的做法；各格式如何生成稳定 ID 留给正式 ingest 设计。强制的落点是**正式 manifest 的构造** —— 本 spike 的 `Document` 是夹具载体，不承担该校验。
2. **重复 href 与重复 ID 是两件事** —— 前者在 ID 不同时不影响文档序，路由怎么处理歧义不由本 ADR 定案。

## 不在本计划内

- `PageMap` / `PageMapSnapshot` / `PaginationEngine` 的实现。
- `PositionResolver`（ADR-0004 的第三层，仍未实现）。
- 正式引擎仓的建立。
- `DocumentStore` 物化策略。
