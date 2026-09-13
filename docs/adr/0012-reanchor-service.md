# Reanchor Service

**Status:** accepted

Spike A 证明了位置身份**能**跨坐标系往返到什么程度，也证明了它不够：语料里没有任何一行能靠结构自证身份。本 ADR 定义结构失效之后的下一步 —— **原锚失效后，凭内容能否重新找到它** —— 并把它限制在一个**可验证的参考实现**里。

## 范围（先写死，防止这一轮膨胀）

- 这是 Spike A 之后的**可验证参考实现**，**不是**生产 `DocumentStore`，**不是**索引器。
- **不新建第三个 spike**；也不把本验证仓扩成生产引擎。
- API 把**生产边界预留为 `async throws`** —— 生产上 `AnchorValidator` 与 `ReanchorService` 都要读文本，因而必须在 `DocumentStore` 惰性物化之后（ADR-0004 的 Consequences 已写明这一点）。**本轮用的是已物化的 `Document`**，只验证**语义与确定性**，不实现物化调度、缓存或索引。
- `PositionResolver`（「这个偏移合法吗、该吸附到哪里」）**不并入本轮**。ADR-0004 的三层职责分工不变。

## 模型

```
Anchor                 NativePosition?  +  AnchorQuote(exact / prefix / suffix)
AnchorValidator        原位置现在还指着同一段内容吗
ReanchorService        原锚失效后，凭内容重新找到它
```

**`Anchor` 不复用 `ReadiumLocator.Text`。** 后者是 Publication Position 的一个字段，其形状由 Readium 决定；`AnchorQuote` 是 Nagi 自己的类型，因为「引文与上下文」在本模型里是**内容**，不是某个 wire format 的成员。两者长相相近是巧合，不是同一个东西。

**`Location Bridge` 仍是唯一同时认识 Publication Position 与 Native Position 的组件。** `ReanchorService` 不认识 `ReadiumLocator`，也不产生它。

## 流程（固定，不按距离或权重改写）

```
Anchor
  → AnchorValidator：原位置验证
  → 全 reading order 的 literal UTF-16 exact quote 搜索
  → prefix / suffix 只用于重复候选消歧
  → relocated / ambiguous / notFound
```

### 1. 原位置验证（`AnchorValidator`）

要求 **`exact` 与所有非空 context 在当前 canonical primary text 中相邻匹配** —— 即 `prefix + exact + suffix` 要在文本里连续出现，缺一不可。

成功时返回一个**按当前 canonical element 重新构造的 `NativePosition`**：**不得盲信旧的 `nodeID`**。旧的 `nodeID` 可能仍然存在却已指向别处（这正是 ADR-0003 的稳定性承诺之外的情形），也可能仍然指向同一处 —— 但无论哪种，结论都必须由**当前文本**得出，不能由旧身份继承。

### 2. 全局搜索

- 顺序**只能**是 **reading order + unit 内 UTF-16 offset**。
- **不得**按旧 `unitID` / `href` / `nodeID` 加权，**不得**按距离加权，**不得**「选最近」。
- **v1 不跨 `DocumentUnit` 匹配**：`exact` 必须落在同一个 unit 之内。

### 3. 匹配语义

`exact` 是**逐 UTF-16 code unit 的字面匹配**，**包含重叠命中**。

明确**不做**：Levenshtein / 编辑距离、分词、标点宽松化、Unicode 归一化或任何猜测。

- **CJK 标点按原字符匹配**，不因它是标点而放宽。
- **空白与 ruby 的语义来自 canonical primary text**：`rt` / `rp` **不上主轴**，现有的 folding 规则**先发生**。也就是说 `ReanchorService` 看到的是既成的 canonical 文本，它自己不做空白折叠，也不解析 XHTML。

### 4. 判定

| 情形 | 结果 |
|---|---|
| `exact` 为空 | **`notFound`**（原因可类型化） |
| 0 个 exact 命中 | **`notFound`** |
| 恰 1 个 exact 命中 | **`relocated`** —— **即使 context 已经陈旧** |
| 多个 exact 命中，用**全部非空** prefix/suffix 过滤后恰剩 1 个 | **`relocated`** |
| 多个 exact 命中，过滤后**仍多个** | **`ambiguous`** |
| 多个 exact 命中，过滤后**成 0 个** | **`ambiguous`**，返回**原始 exact 候选** |

最后一行是刻意的：过滤成 0 说明**上下文已经不可信**，而不是「文本不存在」—— exact 明明命中了。此时假装 `notFound` 是错的；**猜最近更是错的**。

### 5. 结果形状

- 成功（`relocated`）必须能说明**凭哪一条**做到的：`method` ∈ `originalPosition` / `uniqueExactQuote` / `quoteContext`。
- `ambiguous` 返回**按确定顺序**排列的候选（reading order + unit 内 offset，见上）。
- `notFound` 区分原因：`emptyQuote` / `exactTextMissing`。

## 为什么 `AnchorValidator` 与 `ReanchorService` 不合并

它们回答的是两个问题（ADR-0004）：**「这个位置现在指的还是原来的内容吗」**（语义一致性）与**「原锚失效后能否重新找到它」**（跨版本、跨来源恢复）。ADR-0004 已经写死了职责分层与「PositionResolver / AnchorValidator / ReanchorService 三层不得合并」；本 ADR 只是把**第三层的语义**落实成可实现、可证伪的规则，没有改动分层本身。

另一个原因来自实际读数：Spike A 封版实测中「有候选」与「有位置」是**两件事** —— **22 条往返，16 条产出候选，7 条产不出位置**（`quotation-repeated` 同时属于两类：它有 2 个候选，却没有单一位置可确认）。合并两层会把这条已经测量到的事实重新糊起来。

## 术语：这里的「模糊重锚」不是近似匹配

ADR-0004 把本层的性质写作「模糊重锚：`exact` + `prefix` + `suffix`」。**该说法指的是「不以精确位置为唯一依据」，不是「做近似文本匹配」。** 本 ADR 的匹配是**字面**的：逐 UTF-16 code unit 相等。上下文（prefix / suffix）只承担一件事 —— **在多个字面命中之间消歧**；它不参与打分，也不容忍差异。

## 对既有报告的影响

- **Spike A 与 Spike B 的报告必须保持旧字段、旧 probe、旧顺序、旧数值不变。**
- 后续若增加 `reanchor-policy` probe，**只允许追加在 Spike A 的 probes 尾部**（顺序即报告的一部分）。
- 新 probe 落地后，**「去掉新 probe 之后的旧 payload 投影」必须与 main 上的基线逐字节一致** —— 这是「旧读数没有被新工作移动」的判据，而不是一句声称。

**「旧 payload 投影」的确切定义**（不定义就无法执行，定义不精确就会变成一句安慰）：

1. 取**新**报告与 **main 基线**报告各自的 `SpikeAReport.canonicalPayload()` JSON。
2. 在**新**报告那份的 `probes` 数组里，删除**末尾唯一**那条 `name == "reanchor-policy"` 的项。
3. 两份随后**都用 sorted keys 重新编码**，再**逐字节比较**。
4. 删除前必须**断言**该条目存在、唯一、且确实在末尾。**不能在该条目不存在时静默跳过** —— 一个「什么都没删所以相等」的比较，与一个「删对了所以相等」的比较，必须能区分开。

这条之所以可执行：**现有报告没有顶层的 probe 总数**，每个 probe 自己的 `numbers` 留在各自条目里。所以删掉末尾一项之后，其余字节不会因为任何聚合而变动。

> ⚠️ **一个实测踩到的坑，写在这里防下一次误用。** 上面说的是 `SpikeAReport.canonicalPayload()` 的编码，**不是 `SpikeAReport.write(to:)` 写出的 `spike-a.json`** —— 后者**额外包含 `artifacts` 与 `determinism`** 两个顶层字段。若从写盘 JSON 重建 canonical payload，**必须先排除这两个字段**，再执行 probe 删除与 sorted-keys 重编码。
>
> 漏掉这一步的后果不是「比较麻烦」，而是**在本次新增 probe 的新旧投影比较中，该判据必然不能通过**：`determinism.fingerprint` 覆盖整个 canonical payload，新增一条 probe 它就该变；把它算进投影，就等于要求一个必然为假的相等。第一次执行这条判据时正是这样失败的（差在第 415 字符处的那个字段），而问题不在判据、在取错了来源。

## 实测（2026-09-13）

契约、实现、测量分三次独立提交；**R0 为纯文档**，R1 与 R2 分别经过独立 CI 验证 —— 分开是为了让**实现变化与测量变化的验证结果更容易归因**。

| 段 | commit | 内容 |
|---|---|---|
| R0 | `fef22ca` | 本 ADR 与执行单（纯文档） |
| R1 | `3a0c82a` | `Anchor` / `AnchorValidator` / `ReanchorService` + 20 条契约测试 |
| R2 | `961cd2c` | `reanchor-policy` probe（六例）+ 报告接线 |

R1 的 CI（run `34753766411`）与 R2 的 CI（run `34755702082`）都是两个 Gate 全绿、**163 tests / 0 failures**（R1 之后即为 163，R2 未新增测试）。

**`reanchor-policy` 的读数**

```
cases=6   relocated=3   ambiguous=1   notFound=2
methodOriginalPosition=1   methodUniqueExactQuote=1   methodQuoteContext=1
reasonEmptyQuote=1         reasonExactTextMissing=1
evidenceCount=1            mismatches=0            →  measured / yes
```

六例各自走到一个判别叶子，所以 `evidenceCount = 1` —— 它取的是**最稀缺的那个叶子**，不是用例数。将来语料若不再触达某一支，读数会变成 `inconclusive`，而不是一个「没什么可失败的 `yes`」。

**三进程指纹**（同一 run 内 a-run1/2/3 一致）

```
Spike A   096450057cea34d63dcbc01e1245e14a989af90d6f004b32ccb08cfe94d84b05
```

**它不要求等于封版基线的 `291c830c…`** —— 新增一条 probe 就改变了 canonical payload，指纹理应随之改变。要求它相等反而是错的判据。要相等的是下面这条投影。

**旧 payload 投影**（按上文定义执行，两侧同一 sorted-keys 编码）

```
trimmed   622a3e38b0282ff7a3df62f0133f9a59a398c4ba3ea1756f2c36845be1b50450
baseline  622a3e38b0282ff7a3df62f0133f9a59a398c4ba3ea1756f2c36845be1b50450
```

逐字节相同。**去掉新 probe 之后，旧 payload 一个字都没动。**

**同时逐字节未变的**：`canonical-text.txt`（新旧相同）、`run1/spike-b.json`、`run1/spike-b.fingerprint`（Spike B 完全未受影响）。

## Consequences

- 跨来源恢复（同一本书来自不同站点、`id` 全部不同）由本层负责，**不是** `NodeID` 分层方案的职责 —— ADR-0003 的稳定性承诺不覆盖内容编辑过的 artifact。
- 本轮不实现真实 `DocumentStore`，因此 async 边界只体现在签名上；一旦接入真实物化策略，`AnchorValidator` 与 `ReanchorService` 的调用点必须已经是 async。
- 不实现索引：全 reading order 线性扫描是本轮**有意**的选择。它同时是「顺序只能是 reading order」这条规则的直接后果 —— 先造索引再谈顺序，容易把索引的迭代顺序当成语义。
- `ambiguous` 是一个**正常结果**，不是失败。把它折叠成 `notFound`，或按「最近位置」静默挑选，都会让批注指到错误的地方而用户收不到任何提示 —— 那正是 ADR-0004 开头那句「缺 `AnchorValidator` 的后果比丢失更糟」的同族错误。
