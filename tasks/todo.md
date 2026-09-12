# TODO

## 下一阶段：Phase 2.5 —— compare / Resolution / outcome reducer 收口

**顺序已由用户拍板（2026-09-12）：先修测量仪器，再写恢复算法。**

```
Phase 2.5  compare / Resolution semantics 收口
           ↓  冻结 transport fidelity 模型
Phase 3    ReanchorService
```

理由：`Anchor → Resolution → Reanchor` 是把恢复算法建立在分类器之上。而本轮已经查明分类器**不完全诚实** —— `discarded` 此前不进入最终判断，一次「解析失败」可以报告成「什么都没丢」。在已知有缺陷的仪器上盖恢复算法，之后所有重锚读数都要重新解释。

**计划全文**：`C:\Users\Azusa\.claude\plans\immutable-jingling-dragonfly.md`（已批准）。**分两次推送，各自读数。**

### 第一次：comparator 重写，outcome 集合保持 6 个不动

- [x] `LocatorField` / `Provenance` / `Bound` / `DiscardReason` / `FieldProvenance` / `FieldResolution` / `ResolutionShape`
- [x] `OutcomeReducer.reduce(_:shape:refusalReason:row:)` —— **空投影抛错，不得 `exact`**
- [x] `Resolution` 四个 case 携带 provenance；成功路径上的 append **不再是 discard**
- [x] **偏移归宿移进 `locator(from:)`** —— `.structural` ≠ carried
- [x] `RoundTrip.resolutions` 取代 `fields` / `discarded` / `derivedFrom`
- [x] `mediaType` 删除（不可能变化的字段）；`otherLocations` 排除 `cssSelector`（重复计数）
- [x] 有序数组 + `sortedFields`，**字典不进 Codable 类型**
- [x] `ProbeEvidence`（`monotonicity` / `provenanceHonesty` 已接；另两个的判定不是单一 observed/violations 对，硬套会改读数，留到下一轮）
- [x] 推 CI（run 34681113858，两 gate 全绿，commit `d207df5`）—— **20 行桶一个都不许动**（`exact` **5** / `recomputed` 5 / `semantic` 1 / `loses` 3 / `reanchor` 6 / `validator` 0 —— 上一版记的 4 是 19 行时代的数，`4+5+1+3+6+0 = 19 ≠ 20`）

#### 第一次的读数（run 34681113858，两 gate 全绿，commit `d207df5`）

```
Gate 1   136 tests / 0 failures   （+1：ProbeEvidence 那条）
Gate 2   fingerprint 3c897327… 三进程一致

identity-round-trip  20 cases: 5 exact, 5 recomputed-equivalent, 1 semantic-equivalent,
                     3 losing fields, 0 blocked, 6 needing a reanchor
                     —— **与重写前逐字相同**
progress-provenance  discardedFields=19  distinctRefusals=5  carriedOffsetRows=1  unbackedCarriedRows=0
                     writtenProgression=0.289（per-resource）vs publicationProgression=0.118（出版级）
四个 metric probe     全 MEASURED / yes，数一个没动
```

**桶位不变是这一轮的目的，不是巧合。** 按 §二 的规则（字段「当且仅当输入声明了它」+ 出站只陈述偏移归宿），任何一行搬家都说明「谁陈述什么」写错了。审查代理推之前把 20 行逐条手推了一遍，读数与它一致。

设计上**预期会变**的两处，均非回归：`progress-provenance` 的 (c) 改读 `trip.resolutions`（旧的扁平列表 27 个名字 → 19 个字段、5 种拒绝）；字段表不再有 `mediaType`，`fragments` 有了真正的 provenance。

旗舰行现在在 artifact 里说清了它一直该说的话：

```
utf16Offset   22   22   recomputed from progression, bounded by 0.5 canonicalTextIndex
```

数字相等，而 provenance 写着它**没有被带过去** —— 这正是前两轮假阳性的病根。

#### 踩到的坑

**Python 机械替换少留了一个 `}`**，`ProgressMetricTests.swift` open 31 / close 30，测试 target 编译不过。编译面审查代理**看不见它**（它读 diff，EOF 缺右括号在 diff 里不可见）。已写进 `lessons.md`：用脚本动过 Swift 源文件，推之前逐文件数括号。

### 第二次：修测量仪器（六项）—— **已改完，待推 CI**

计划全文：`C:\Users\Azusa\.claude\plans\immutable-jingling-dragonfly.md`；本次会话的计划与**四处修正**（下面「修正」段）见 `C:\Users\Azusa\.claude\plans\inherited-imagining-shore.md`。

- [x] **1** `RoundTrip.transportResolutions`（输入声明过的字段）与 `observations`（桥自身的事实）分开，**reducer 只吃前者** —— 现在 `exact` 与它自己的定义矛盾：`id-anchored` 报 `exact`，而它表里一行写着 `refused: …`
- [x] **2** `Progression` 加 `scope`（`.publication` / `.resource(String)`）—— ADR-0009 封版写了「数值 + metric + scope + provenance」，而类型里只有前两个；上一轮抓到的那个替换，类型至今拦不住
- [x] **3** 无 candidate 的六行 `needsValidator` 应为 **false**（现在写死 true，20/20；那六行没有东西可 validate）
- [x] **4** `RecomputeBasis` 类型化 —— renderer 现在把每个 `bound == nil` 都解释成「请求越界被 clamp」，而 `js-shaped-selector` 的 artifact 里就印着这句**假话**
- [x] **5** `mixed-evidence-locator` fixture + 不变量「输入声明的字段不得静默消失」（`native(from:)` 命中 fragment 就提前 return，`progression` / `cssSelector` 会缺席）；「声明了它」只定义一次（`LocatorField.isStated(by:)`）
- [x] **6** `refused()` 的两列值渲染不出来（`js-shaped-complex-selector  href  —  —  carried`）
- [x] ADR-0004 / 0009 同步（用户拍板：两份都改）
- [x] 推之前必跑 ① 全仓库 `{` / `}` 逐文件平衡 → **33 文件 / 0 问题**（脚本见 `%TEMP%\bracecheck.py`）
- [x] 推之前必跑 ② 独立代理核编译面与桶位 → **跑过了，报 11 处发现**（9 处已修），但**它把一处编译错误判成「complete」**：`table.map(\.provenanceOnly)`，而 `provenanceOnly` 定义在 `FieldResolution` 上、`table` 是 `[FieldProvenance]`。见 `lessons.md` 新增那条。
- [x] 推 CI run 34702448668 → **Gate 1 红**（上面那处编译错误，`RoundTrip.swift:290` / `:335`），Gate 2 因 `needs: gate-1` 被 skip。已修，重推。
- [ ] 修完重推，读实际读数

#### 执行前拍板 / 修正（计划文件内部有四处自相矛盾，以此为准）

1. **用户拍板**：`needsValidator` 按「产生过 **candidate**」判 —— `.ambiguous` 的 `quotation-repeated` 计入（它产出 2 个候选，且 locator 带着 `text.highlight`，validator 有东西可用）。
2. **用户拍板**：`Resolution.approximate` 一起类型化（携带 `RecomputeBasis`，删 `Resolution.bound`），避免 String 与 enum 两份真相并存。
3. **用户拍板**：ADR-0004 与 0009 本轮一并更新。
4. **修正一（真 bug，原计划未发现）**：`OutcomeReducer` 的四步 `lost → derived → uncarriable → exact` **对 `.discarded` 没有分支**，所以 `exact` 能从「表里写着 `refused`」的行上得出。今天没有一行暴露它，因为带 `.discarded` 的行全是 `requiresReanchor`（按 shape 判，不进字段规则）。`mixed-evidence-locator` 是第一行既有位置、又有 refused 字段的用例。修法：加一步 `.discarded` 落进 `semanticEquivalent`（拒绝是**有意**的差异，不是 `loses`）。**对既有一行影响为零**（已逐行走过 14 个 `finish()` 行）。
5. **修正二**：原计划 §二「三个轴一律返回 `.publication`」是错的 —— `SourceBytesAxis` 除的是**该资源**的字节数、`FixedPageOrdinalAxis` 除的是**该资源声明的**页数，本来就是 resource-scoped。照写会让类型说假话。
6. **修正三**：`RecomputeBasis.progression` 的 `bound` **不可选**。`.clampedProgression` 独立成 case 后，未 clamp 的路径永远有 bound（`seekTolerance` 在协议里非可选），可选就是零覆盖词汇。
7. **修正四**：桶位判据重述为「**20 个旧行逐个不动** + 新增第 21 行单独预测」。新行落 **`semanticEquivalent`**（原计划预测 `recomputedEquivalent` 也不对：它没有任何字段被重算，fragment 命中即 structural）。

#### 本次新增的两处覆盖

- `RecomputeBasis.utf16Offset` 在语料里原本**零覆盖**（`native-path-anchored` 落在匿名段落里，不发 fragment）。已用一个**单元测试**钉住，不新增语料行 —— 加行会动 census，而本轮的判据就是 census 不动。
- `ObservationKind.scopeDroppedToFitTheMirror` 若无 probe 断言就是零覆盖词汇；`provenanceHonesty` 的 (a) 现在两条 observation 都查。

**判据**：**20 个旧行的桶逐个不动**（5/5/1/3/6/0）；第 21 行预测 `semanticEquivalent` → `semantic` 1→2。
**预期会变的**：`needsValidator` 20/20 → **16/21**；`needsReanchor` 6/20 → 6/21；`progress-provenance` 的 (c) `discardedFields` 19 → **7**、`distinctRefusals` 5 → 5。

### 第三次：两个零覆盖词汇定案

- [ ] `requiresValidator` 并入 `requiresReanchor`；词汇 6 → 5。**第二次推送已让这个 case 变成可证明的不可达**（reducer 对一切产不出位置的 shape 都返回 `requiresReanchor`，`refused()` 的 `needsReanchor` 也去掉了 `.notExpressible` 例外），所以 `numbers["requiresValidator"]` 是一个**没有任何测量能推动的数** —— 留着它就是本仓库点名过的「报告里出现没有测量在用的数」。删。
- [ ] 补 `native-position-in-a-unit-that-no-longer-exists`。**前提已随第二次推送反转**：原文写「`needsReanchor` 写死成 `false`，它不可能落进 `requiresReanchor`」，而现在 `.notExpressible` **就是**落 `requiresReanchor` 且 `needsReanchor == true`。所以这一条不再是「给 `requiresValidator` 覆盖」，而是给 `.notExpressible` 这条路径**第一次**一个可观测的行 —— 它今天仍然零覆盖。
- [ ] **零覆盖词汇清点**（第二次推送的审查代理列出，均非本轮引入）：`DiscardReason.nothingResolvable` **全仓库从不构造**（末尾那个 `unresolvable` 不为它写行，也没有对应的 `LocatorField`），而 `ProgressProbes.explain` 为它手写了文案；`selectorNamesNothing` / `unitCarriesNoText` / `unitHasNoAddressableElements` 由 bridge 构造但语料不可达（枚举 9 个 case，census 只走到 5 个）；`ObservationKind: CaseIterable` 从未被枚举；`ProgressScope.publication.described`（「publication-wide」）只被一个**否定**断言用到，不进任何 artifact 路径。arm (c) 按设计看不见这些（「名字的计数不能分划行」）。
- [x] `docs/adr/0004:49` 的「18 条」计数更新 —— **第二次推送已做**（改成实测两行式：21 条 / 16 条产出候选 / 6 条产不出位置）。

**已在本轮代码里写明的两处「已知且接受」**（不是欠账，是不改）：
- `uncarriableProvenance` 先占下的字段（`.position` / `.totalProgression`）保持 `.documentLevel`，扫尾不覆盖它 —— 那个裁定说的是**字段本身**，扫尾的理由只说**这一次解析的路线**，前者更强。语料里没有同时声明 fragment 与 position 的行。
- `ProgressScope.resource(String)` 有**两个生产者**（bridge 传 `DocumentUnit.id`，两个资源轴传 `ByteResource.href`），它们相同是因为夹具让它们相同，不是类型保证的。

**三处与草案的冲突已定**（见对话记录与计划 §三）：① 两个名字都留（阶段一实测证明 `recomputed` 与 `semantic` 必须分开）；② `requiresValidator` 的零覆盖要正面处理；③ reducer 用**类型**收不到数值，而不是靠规则禁止。

---

## 当前任务：Spike A 第三轮 —— 先冻结测量规则，再扩张测量面

计划全文见 `C:\Users\Azusa\.claude\plans\curious-scribbling-forest.md`。
**分两次推送、各自读数** —— 合起来推就分不清是哪一半改变了读数。

### 阶段一：harness 修整 —— **已推 `5984b84`，CI run 34677720492 两 gate 全绿**

- [x] 先加 `#p1` 形态的 locator 用例（`id-anchored-with-fragment-in-href`）+ 一条穿过 bridge 的测试
- [x] href：**那个方向改为一律不报 href 字段**（见下方 Review 的偏离说明）
- [x] `FieldVerdict`：`reproduced` → `carried`；新增 `approximated`；六项按 provenance 定义
- [x] **`exact` ⟺ 每个字段 `.carried`**
- [x] outcome 拆两个：`recomputedEquivalent` / `semanticEquivalent`
- [x] **两个方向共用一个 `classify`**（`RoundTrip.swift:288` 定义，`:258` / `:346` 调用）
- [x] `main.swift` `outcomeLabel` 加 case（编译期绊线）
- [x] `identityRoundTripProbe` 加桶 + **分划断言**（`RoundTripCensusError`）
- [x] 测试同步（`carried` 改名 + 新增两处断言）
- [ ] **未做**：`compare` 的判定输入改为 `Resolution.discarded`（今天仍无人读取）；ADR 更新

### 阶段二：metric 矩阵 ✅ 已完成（`e2c23ec` + `d430736`，CI run 34679508081 两 gate 全绿）

**先调用**：`/codebase-design`、`/domain-modeling`（已调）；完成后两个独立审查代理（一个攻设计、一个攻无编译器下的语法与算术）。

- [x] `PublicationProgressMetric` / `Progression { value, metric }` —— **metric 非可选**，闭合 ADR-0009:73
- [x] `ProgressMetricAxis`（构造式捕获，无 `in document:`）+ **泛型** `PublicationProgressService`（**抛错不夹取**）
- [x] `CanonicalTextIndexAxis` 吸收并删除 `Document.progression(of:)` / `totalProgression(of:)`；清两处过期注释
- [x] **`locator(from:)` 的 per-unit 算术原样保留** —— 这是审查代理抓到的会**静默毁掉旗舰行**的陷阱
- [x] `locator(from:)` → `LocatorExport?`，在丢标签处记 `"progression.metric"`；`native(from:)` 一行不动
- [x] `ByteResource`（`Sendable`；字节↔文本映射走**前缀解码**）+ 三个 `pageRanges` 声明（nil / 2 页 / 4 页）
- [x] fixture：空 unit 插在 chap2 与 chap3 之间
- [x] `RoundTrip` 加 `discarded` / `derivedFrom`；**`Resolution.discarded` 第一次进入 artifact**
- [x] 报告加 `readingOrderUTF16Length`（5 个写入点）
- [x] 四个 probe；**每个 service 调用都 `do/catch`**
- [x] `layout-independence` 三臂建在**同一份 `ByteResource`** 上
- [x] ADR-0009 / 0008、测试、`main.swift`

## 已完成：Spike A 第二轮 —— 让往返契约回到它真正成立的样子

计划全文见 `C:\Users\Azusa\.claude\plans\curious-scribbling-forest.md`。
第一轮读数已出（`945ad92`），但**复核代码后发现第一轮的头条结论引错了地方**。

**根因**：`locator(from:)` 已经同时发 `fragments` 和 `progression`；丢 offset 发生在**解析侧** —— `native(from:)` 一命中 fragment 就返回元素起点，不再看 progression。而「改用 progression 补回 offset」被 **ADR-0009** 明令禁止：

> 精确的阅读位置恢复**不得**经由 `Double` progression 往返。

所以 **bridge 是对的，错的是测量仪**：`RoundTrip.nativeToLocatorToNative` 把一个由 progression **算回来**的 offset 判成 `.reproduced`，进而报 `.exact`。
`compare`（反方向）对同一个道理**已经写对了规则**（`RoundTrip.swift:181-186`），只是没施加到「由 progression 推出的那个 offset」上。

- [x] `RoundTrip.nativeToLocatorToNative`：`.approximate` 解析下 `utf16Offset` 判 `.recomputed`，**数字相等也不判 `.reproduced`**
- [x] 同一条规则施加到 `nodeID` —— `.approximate` 下 `nodeIDMatches` 由 `offsetMatches` **蕴含**，判 `.reproduced` 是把恒真式报成「幸存的事实」
- [x] outcome → `.semanticEquivalent` 并附 provenance 说明（**不是 `.loses`**：数字相等，bounded-seek 的成功不是失败）
- [x] 重写硬编码的说明文字，改为组装 notes
- [x] 根因注释：`fields` 的「survived」→「was carried」；`FieldVerdict.recomputed` 的「different value」措辞
- [x] **新增测试**：`.path` 形态的 native-first 断言（此前**零覆盖**），offset 从 fixture 推导不写常数
- [x] `SpikeACases.swift` 注释补：这一行现在是「path 级身份无法写入 locator」的唯一证据
- [x] `docs/adr/0009` 记录 Pending Spike A 前半落地；`docs/adr/0004` 记表达能力边界与「假的兜底」
- [x] 推 CI，**读 artifact 的实际数字**（run 34677202575）

**过程中的一处真 bug（靠审查抓到，不是靠 CI）**：`utf16Offset` 有**三种**结果而非两种 —— 我第一版写成
`(offsetMatches && carried) ? .reproduced : .lost`，`.path` 情形落到 `.lost`，于是 outcome 刚写下「数字相等，报丢失是另一种误报」，
字段却标着 `.lost`（其含义正是「丢了，本不该丢」）。**同一个 struct 自相矛盾，且会原样进 artifact JSON。**
两个独立审查代理同时抓到它。修法是显式三分支。

**判据用 `.approximate` 本身，不用 basis 字符串** —— `"progression (clamped)"` 同样可达。
**不动 `LocationBridge` 任何行为**；不给 bridge 加 `domRange`/`partialCfi`（那会测量一个现实生产者不产出的形状）。

## 已完成：Spike A 第一轮 —— Locator ↔ NativePosition 身份往返

Spike B 已封版于 `763e2c9`（证明了 Nagi 能掌握**排版**）。Spike A 要证明 Nagi 能掌握**身份**。
计划全文见 `C:\Users\Azusa\.claude\plans\bubbly-enchanting-alpaca.md`。

**已拍板**：macOS SwiftPM + Locator 忠实镜像（Readium 是 iOS-only，不能作依赖）；`NativePosition` 先不带 `documentOrder`。

- [x] `Package.swift` 增加 `SpikeAKit` / `SpikeA` / `SpikeAKitTests`
- [x] `JSONValue`（最小 JSON 值，`otherLocations` 与 `domRange` 需要）
- [x] `ReadiumLocator` 镜像 —— 八个编码/解码怪癖逐条带出处
- [x] `Href` 归一化（**局部镜像**：Readium 的 `normalizedPath` 规则未复刻，已在文件里标注）
- [x] `CanonicalText` —— XHTML → canonical primary text（`rt`/`rp` 不占数轴 + 显式折叠规则）
- [x] `NodeIdentity` —— ADR-0003 阶梯前两级（显式 id → DOM path）
- [x] `DocumentModel` —— `DocumentUnit` / `NativePosition`
- [x] `LocationBridge` —— **不设 href 短路**，每条定位都真的走解析
- [x] `RoundTrip` —— 五类分类 + 逐字段判定
- [x] `Fixture` —— 源码内嵌的「解压后 EPUB」，各轴各有对应用例
- [x] `SpikeAReport` + `Sources/SpikeA/main.swift`（沿用 B 的报告纪律与跨进程指纹）
- [x] `Tests/SpikeAKitTests/` —— 镜像保真度 / canonical text / 身份与往返
- [x] `.github/workflows/ci.yml` 的 Gate 2 增加 `spike-a` 三进程比对
- [x] **在 macOS 上跑 Gate 1** —— 本机无工具链，已由 CI（`macos-15`）在 run 34676261279 实跑，与 Gate 2 同绿

### 写作过程中靠阅读（而非编译器）抓到的真 bug

1. `didEndElement` 把保存的 `pendingSeparator` **或**回去 → `<p>foo <b>bar</b> baz</p>` 会多出空格。
2. 悬挂空格在**子元素内部**才结算 → `<p>前</p><p>空白</p>` 里第二个 `<p>` 的范围会以空格开头，它里面每个 offset 都偏 1。
3. `elements(withText:)` 用 `String.index(offsetBy:)` 数**字符**，而范围是 **UTF-16 单元** —— 非 BMP 字符上必错。
4. `DeterminismRecord` 无 public init，**跨模块构造不了**（见下方「偏离计划的一处」）。

### 偏离计划的一处（需知悉）

计划里「不动 Spike B 的任何文件」。实际改了 `Sources/SpikeKit/Report.swift` **一处**：给 `DeterminismRecord` 加了 `public init`。原因是 `SpikeAKit` 是另一个模块，合成 memberwise init 是 internal，不暴露就构造不了。**纯增量**，Spike B 行为不变，其测试仍在跑。

## Review

### 第三轮阶段二：metric 矩阵（run 34679508081，两 gate 全绿，commit `d430736`）

```
Gate 1   135 tests, 0 failures        （阶段一后是 116，本轮 +19）
Gate 2   Spike A 跨进程指纹 b3b3a413… 在 a-run1/2/3 均一致 → MEASURED / yes

progress-monotonicity        MEASURED yes  16 位置 / 0 递减 / 0 前缀和错位 / 空 unit 首尾相等 1-of-1 / 全空文档 nil
progress-layout-independence MEASURED yes  sourceBytes 动 0、fixedPageOrdinal 动 5、canonicalTextIndex 动 0、可重排资源给页序号 0
progress-bounded-seek        MEASURED yes  13 请求 0 错位、max snap 2 vs 声明 3、危险命中 4/2/1、9 次翻页往返 0 失败
progress-provenance          MEASURED yes  写进字段 0.289474（per-resource）≠ 0.117647（出版级）；carried 1-of-5 有载体；27 个丢弃名全部可解释

identity-round-trip  20 cases: 5 exact, 5 recomputed-equivalent, 1 semantic-equivalent,
                     3 losing fields, 0 blocked, 6 needing a reanchor
```

#### 本轮真正立住的四条

1. **metric 身份随数值一起走。** `Progression.metric` 非可选，所以想拿裸 `Double` 必须显式丢标签 —— 而那个丢弃点被记进 `discarded`，artifact 里看得见（`progression.metric`）。
2. **`locations.progression` 是 per-resource，轴的 `progression` 是出版级。** 这不是学究式区分：`native(from:)` 按 `unit.length` 反算它。换过去会让 `native-path-anchored` 的 22 反算成 9、该行从 `recomputedEquivalent` 掉进 `loses(["utf16Offset"])`，而**分划桶和仍然等于 20**。审查代理在推 CI 前抓到，现在有测试（`testTheProgressionWrittenIntoTheLocatorIsPerResource`）钉住，且 probe 把两个候选数都报出来。
3. **准入判据从一句话变成一次测量。** 容器声明了分页 → 页序号存在且随声明变化；没声明 → 一律 `nil`。可重排资源给出页序号 0 次。
4. **`Resolution.discarded` 第一次被读。** 此前不只是没人读，是在唯一调用点被裸 `_` 丢掉。它还暴露出 `.ambiguous` / `.unresolvable` 两个 case **拿着算好的列表却无处安放** —— 一次「解析失败」于是报告「什么都没丢」。修完日志里能直接看到：`quotation-repeated` 丢 `text`、`unknown-href-with-fallback` 丢 `href`、`fragment-names-nothing` 丢 `fragments`、`global-position-only` 丢 `position`。

#### 第一次 CI 读数抓到的空转（`d430736` 修）

`progress-provenance` 报了 `yes`，而 `carriedRows = 0` —— 语料里**没有一行**能把 offset 报成 `.carried`（四个 native-first 用例不是丢 offset 就是重算），于是「`.carried` 必须有载体」这一臂无物可查，靠「没有东西可以失败」通过。

修法是两条一起：语料补 `native-id-anchored-at-element-start`（偏移正好是元素起点，因此可 `.carried`），probe 在覆盖计数为 0 时报 `inconclusive` 而非 `yes`。**读数随之变化且可见**：cases 19→20、exact 4→5，其余桶不动。

这与 `native-path-anchored` 当年「零覆盖所以长期判错」是同一个病，只是这次是断言侧而非判定侧。

#### 偏离计划的两处（评审时先拍板）

1. `progression(of:)` 返回 `Progression?` 而非裸 `Double?` —— 草图会在唯一需要标签的那一层把标签丢掉。
2. document / resource 改为**构造时捕获**，去掉每个方法的 `in document:` —— 三个 conformer 里两个根本不看 document。

#### 靠审查（而非 CI）抓到的其它四处

- `ByteResource` 漏 `Sendable`（显式 `Sendable` 类型里放非 `Sendable` 存储属性是硬错误）。
- `ProgressProbes` 的 `pageCountBefore/After` 写成了字面量 —— fixture 改了它还会说「2 -> 4」，正是本轮加 `readingOrderUTF16Length` 要消灭的那类数。
- `monotonicity` 的注释宣称有「无空 unit 就 inconclusive」的保护，代码里没有。
- `ProgressMetricTests` 里那条 `Progression` 不等断言是合成 `==` 上的恒真式，改成「同一位置两个 metric 给出不同的数」。

`"fragments"` 是我这轮新加进 `discarded` 的词，而可解释名单里没有它 —— **provenance 的 tripwire 当场会报 `no` 并点出这个词**，修在推之前。

#### 未做（各自独立）

- `compare` 的逐行重写（判定输入改为 `discarded`）。
- `ReanchorService` 的模糊匹配（仍只判定「需要它」，本轮 6 例）。
- `readiumPositions` / `custom` 两个 metric：没有 archive 可测，且 `custom` 是实现一种不存在的 metric。**不是欠账，是范围。**
- ADR-0003 的文档序键。

### 第三轮阶段一：把测量规则冻结成结构（run 34677720492，两 gate 全绿，commit `5984b84`）

```
Gate 1   全部测试通过（含新增的 href 用例与改写后的 .path 断言）
Gate 2   Spike A 跨进程指纹一致 → MEASURED / yes

identity-round-trip  19 cases: 4 exact, 5 recomputed-equivalent, 1 semantic-equivalent,
                     3 losing fields, 0 blocked, 6 needing a reanchor.
                     19 of them cannot confirm identity without a validator.
N  cases=19  exact=4  recomputedEquivalent=5  semanticEquivalent=1  losesFields=3  requiresReanchor=6
```

**分离的价值由实测证明，而不是由论证。** 分离前 6 行全叫 `semanticEquivalent`；现在是 **5 个 `recomputed` + 1 个 `semantic`**。
那唯一的 `semantic` 是 `id-anchored-with-quotation` —— 它丢的是引文（`notCarriable`），**没有任何东西被重算**。
这恰好是我当初反对「整体改名为 `recomputedEquivalent`」的理由，现在第一次有了测量支撑：那一行会被误名。

`id-anchored-with-fragment-in-href` → `exact`，cases 18→19、exact 3→4。**新增用例确实是可观测的** —— 语义 href 比较第一次被真正走过。
四个原本 `semantic` 的 locator-first 行（`positions-service-shaped` / `js-shaped-selector` / `progression-out-of-range` / `quotation-unique`）现为 `recomputed`：它们**都有**一个由 offset 导出的 `progression` 字段。桶和 4+5+1+3+0+6 = 19 ✓（分划断言首次生效）。

#### 偏离计划的一处

计划写的是「href 在那个方向判 `.recomputed`」，落地时发现那会让 **`exact` 在 native-first 方向永远不可达**（该方向 locator 的每个字段都是合成的），于是 `exact` 在那里失去意义。
改为**根本不报这个字段**。理由是同一条原则的推论：**一个不可能变化的字段不携带信息，报告它本身就是缺陷，而不是给它选哪个裁定。**
该方向「是否落回正确 unit」由 `unitID` 回答。测试里加了 `XCTAssertNil(trip.fields["href"])` 钉住。

#### 尚未做

- `compare` 的判定输入改为 `Resolution.discarded`（**今天全仓库无人读取它**）—— 这是计划里的「逐行重写」，本轮未动。
- ADR-0004 / 0009 的对应更新。
- `SpikeARunner.swift:14-17` 的 `"\n"` join 与 `Document.totalLength` 差 2 —— 未标注。
- **阶段二（metric 矩阵）整体未开始。**


### 第二轮：契约改述为「Anchor 精确 / Progression 有界」（run 34677202575，两 gate 全绿，commit `83c693a`）

```
Gate 1   116 tests, 0 failures
Gate 2   Spike A 跨进程指纹 bfbed91025d3… 在 a-run2 / a-run3 均匹配 → MEASURED / yes

identity-round-trip  18 cases: 3 exact, 6 semantic-equivalent, 3 losing fields,
                     0 blocked for another reason, 6 needing a reanchor.
                     18 of them cannot confirm identity without a validator.
```

与预测**逐字吻合**：`native-path-anchored` 由 `exact` 转 `semantic`，另三个 native-first 用例分类不变。读数 **4/5/3/6 → 3/6/3/6**。

#### 实测确认的三件事

1. **`native-path-anchored` 的三条 note 全部进了 artifact**：数字相等但**是算回来的**；`progression` 的 metric 未被 locator 声明，而 ADR-0009 给这条路径的是**有界容差**；且 resolution **自己把它列为 discarded**。这是报告里第一条把「值相等 ≠ 信息被带过去」写成行的话。
2. **没有任何一例把精确 offset 带了过去。** 唯一看似成功的那个，靠的正是 ADR-0009 禁止的 `Double`。ADR-0004 那句「缺 `AnchorValidator` 的后果比丢失更糟」由此从论断变成 **18/18 的测量**。
3. **`totalProgression` 的兜底确实是假的**：`unknown-href-with-fallback` 仍落 `needs reanchor`，理由行是「the locator carries nothing this bridge can resolve」—— bridge 找到了 unit，unit 内无物可依。

#### 一处预测失误（记录，不掩饰）

我按手算估 chap1 的 canonical 长度是 74–77，**实测 76**，匿名的那个 `<p>` 是 `21..<29`。对抗审查代理手算的 76 才是对的。**不影响任何判定**（只依赖 offset 落在区间内、且分数反算回同一整数），但手算仍然错了一次。

#### 未做（各自独立一轮）

- **ADR-0009 那条待办的后半**：把往返契约推广到 `sourceBytes` / `canonicalTextIndex` / `fixedPageOrdinal` 等全部 metric —— 需要先有 metric 抽象与容差定义。
- **`ReanchorService` 的模糊匹配**：本轮仍只判定「需要它」（6 例 `needs reanchor`）。
- 样本仍是一个 fixture、一套合成 XHTML；ADR-0003 的文档序键问题未触及。
- 同族测量缺陷（`RoundTrip.swift` 用原始字符串比 href 而 `compare` 用 `Href.isEquivalent`；`.exact` 在两个方向含义不同）。


### Spike A 第一次真实读数（run 34676261279，两个 gate 全绿，commit `945ad92`）

```
canonical-text-shape      measured  yes  annotation excluded ✓ 折叠符合模型 ✓ 非 BMP 在 UTF-16 上更宽（31 字符 / 35 单元）
href-routing              measured  yes  同一个 id 在两个内容相同的 unit 里解析到不同 unit —— href 在起作用
duplicate-text-ambiguity  measured  yes  引文出现 2 次，bridge 返回 2 个候选
offset-boundaries         measured  yes  offset 4 落在非 BMP 字符内部，bridge **原样带过**（不吸附）
identity-round-trip       measured  yes  18 例：4 exact / 5 semantic / 3 loses / 6 requiresReanchor

18 例中 **18 例都无法在没有 validator 的情况下确认身份**
determinism: measured / yes（跨进程指纹一致）
```

#### 最锋利的一条：`fragments` 与 `progression` 不可互换

> ⚠️ **本节结论已在第二轮更正中推翻一半，保留原文仅为留痕。** 两处不成立：(1) `locator(from:)` **同时**发 `fragments` 与 `progression`，不存在「优先发谁」的取舍；(2) 表里那个「**保留**」是**假阳性** —— offset 是拿 ADR-0009 禁止用于精确恢复的 `Double` 算回来的，不是被带过去的。正确的表述见上方第二轮的实测。


`native→locator→native` 的三例**全部**丢掉了 `utf16Offset`，而 `native-path-anchored` **保住了**。相关性是完美的：

| nodeID | 回程走哪条路 | offset |
|---|---|---|
| `.explicitID`（有 id） | `fragments` → 解析到**元素起点** | **丢失** |
| `.path`（无 id） | `progression` → 按长度换算 | **保留** |

即：**`fragments` 命名一个元素，`progression` 命名一个位置。** 当前 `locator(from:)` 优先发 `fragments`，恰好是精度上的错误取舍 —— 而两者单独都不完整。这是 Spike A 直接给出的架构结论。

#### 没预测到的一条

`unknown-href-with-fallback`（未知 href + `totalProgression`）落到 **`requiresReanchor`**，不是我预判的 `.loses(["href"])`。原因：Readium 唯一的兜底（`totalProgression`）**只能定位到资源，定位不到资源里的位置** —— bridge 找到了 unit，却在 unit 内无物可依（该 locator 没有 fragment/cssSelector/progression/position），于是最终仍是不可解。**兜底是假的兜底。**

#### 与预测的对照

命中的：结构锚点 exact ✓、引文丢 text/title ✓、positions-service 形状丢全局编号 ✓、纯全局 position 不可解 ✓、重复引文进 Reanchor ✓、复杂选择器被拒绝而非猜测 ✓。
未命中的：上面那条 fallback；以及 `native-id-anchored` 的 offset 丢失（我原以为元素起点能往返，实际 `+3` 就丢了 —— 测试里用的是起点，恰好是唯一能保住的 offset）。

#### 仍未验证

`ReanchorService` 的模糊匹配**没有实现**，本轮只判定「需要它」。样本仍是一个 fixture、一套合成 XHTML。ADR-0003 的文档序键问题本轮未触及。
