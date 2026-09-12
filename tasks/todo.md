# TODO

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

### 阶段二：metric 矩阵 —— 计划全文见 `C:\Users\Azusa\.claude\plans\immutable-jingling-dragonfly.md`

**先调用**：`/codebase-design`、`/domain-modeling`（已调）；完成前 `/code-review`。

- [ ] `PublicationProgressMetric` / `Progression { value, metric }` —— **metric 非可选**，闭合 ADR-0009:73
- [ ] `ProgressMetricAxis`（构造式捕获，无 `in document:`）+ 泛型 `PublicationProgressService`（**抛错不夹取**）
- [ ] `CanonicalTextIndexAxis` 吸收并删除 `Document.progression(of:)` / `totalProgression(of:)`；清两处过期注释
- [ ] **`locator(from:)` 的 per-unit 算术必须原样保留**（`locations.progression` 是 per-resource 语义，轴的 `progression` 是出版级；换过去会让 `native-path-anchored` 从 22 反算成 9 而**桶和仍是 19**）
- [ ] `locator(from:)` → `LocatorExport?`，在丢标签处记 `"progression.metric"`；`native(from:)` 一行不动
- [ ] `ByteResource`（`Sendable`；字节↔文本映射走**前缀解码**，不写扫描器）+ 三个 `pageRanges` 声明（nil / 2 页 / 4 页，**只用 2 的幂**）
- [ ] fixture：空 unit 插在 chap2 与 chap3 之间
- [ ] `RoundTrip` 加 `discarded` / `derivedFrom`（让 `Resolution.discarded` 第一次进入 artifact）
- [ ] 报告加 `readingOrderUTF16Length`（**4 个写入点**，漏一个就静默不进指纹）
- [ ] 四个 probe，每条点名**能把它翻成 `no` 的变异**；**每个 service 调用必须 `do/catch`**，否则轴行为不端会把 `no` 变成红 Gate 2
- [ ] `layout-independence` 的三臂必须建在**同一份 `ByteResource`** 上（否则是 `nil == nil`）
- [ ] ADR-0009 / 0008、测试、`main.swift`

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
