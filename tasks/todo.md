# TODO

## 当前任务：收掉第一轮审计留下的 5 项语义修正

三项硬编译错误已修（见下方 Review）。本轮按用户拍板的语义收掉剩余 5 项，然后进第一次真实编译。

- [x] **1. Kinsoku 假 PASS** —— `LineRecord` 拆成 consumedRange / contentRange；只去掉强制断行控制符（LF/CR/CRLF/NEL/U+2028/U+2029），**不 trim 普通空白**；游标仍按 consumed 推进；补极小回归测试
- [x] **2. Quantize** —— 非有限值与溢出一律 `throw`，不再饱和；`Quantize` 改 throwing 并传导到 `LineRecord` / `ProbeOutcome` / `Size` / `LayoutReport` 的 init；六个浮点字段走同一个 helper
- [x] **3. writePNG** —— 改 throwing contract，返回字节数；保证「编码成功 + 写入成功 + 文件存在 + size > 0」；report 增加 `artifacts` 清单供 CI 三方核验
- [x] **4. determinism probe** —— 改为跨进程：report 输出 `determinism.fingerprint`（覆盖 canonical payload，不含运行元数据），支持 `--expect <上一次的指纹文件>` 比对
- [x] **5. parseFeatureList** —— 引入 `ByteSlice`，每层 offset 都落在 owning table 切片内；补「offset 逃出本表但仍落在文件内」的回归测试
- [x] 连带项：金则扫描的 `pageHeight` 换成有限哨兵（否则第 2 项会让扫描直接抛错）
- [x] 连带项：ruby probe 自证 —— `requestedRubySizeFactor` 从 `LayoutInput` 传入并写进 report，避免「API 用错了但测试仍绿」
- [x] 更新既有测试以适配 throwing init 与新字段；补上述各项的新测试（49 → 62 个）
- [x] 复核轮：FINDING/EXECUTION 双轴拆分（消除 CI 日志里的 FAIL 二义）
- [x] 复核轮：`measurementCanvasHeight` 命名 + canvas 自证（0.9 余量）
- [x] 复核轮：ruby probe 单行自证（同类画布假象）
- [ ] **在 macOS 上跑 `swift build` 与 `swift test`** —— 本机无工具链，这是唯一真正的验证

## Review

### Gate 2 第一次真实结果（2026-09-12，run 34672568307）

两个 gate 全绿：`swift build` ✓、66 个测试全部执行并通过 ✓、三次进程指纹 `cmp` 一致 ✓。
评审图已取回并**逐张看过**（此前一直被静默丢弃）。

#### 第三类 —— CoreText 实际行为（Spike 的真正产出）

| # | 结果 | 与假设的关系 |
|---|---|---|
| F1 | **CoreText 确实为 ruby 让出行高**：`plainLineHeight 22.400 → rubyLineHeight 30.400`，`delta = 8.000pt`，恰为 `fontSize 16 × sizeFactor 0.5` | **与 ADR-0005 冲突**。ADR 写「不得指望 CoreText 自动为 ruby 让出行高」。**但见 P3 —— 这次测量不干净，不足以据此改 ADR。** |
| F2 | **CoreText 默认断行已实现禁则**，与 `kCTLanguageAttributeName` 无关：29 个宽度下 tagged 与 untagged 的违规数**都是 0**，2152 个行末被检查 | 修正了 probe 的原始假设。UAX #14 LB13 本身就禁止在收尾标点前断行。 |
| F3 | 字体缺 `halt` `palt` `vrt2` `kern` `locl` 等 10 项，只有 `aalt` `vert` | 预判命中。**标点压缩只能由 Nagi 自己做。** |
| F4 | 竖排串接不卡死（但见 P2，这个 yes 的含义要打折） | — |

#### 第一类 —— 实现错误（我的代码）

| # | 问题 | 状态 |
|---|---|---|
| I1 | **`ruby.png` 是一张纯白空图**。布局框是 10000×10000（为了不折行），渲染位图只有 400×120，而 `CTFrameDraw` 把首行放在 path 顶部 → 文字落在画布外。**从第一次运行起就是空的。** | 待修 |
| I2 | **`writePNG` 的校验（文件存在 + size > 0）必要但不充分**：空白 PNG 完全满足它。真实的告警信号是三张图的字节数 —— `ruby.png 1244` vs `page-0.png 80992` / `vertical-column-0.png 82696`，两个数量级的差距一直印在日志里。 | 待修（建议加「frame 的 path 必须放得下位图」的守卫） |
| I3 | 评审图被 `actions/upload-artifact` 静默丢弃（隐藏目录 + `if-no-files-found: warn`） | **已修** `decf225` |

#### 待用户裁决 —— 实验有效性（第二类的一半）

| # | 问题 |
|---|---|
| P1 | `kinsoku-language-tag` 报 `yes`，但**对照组同样是 0 违规** —— 没有任何可测之差。按既定原则（只有确实测到目标行为才允许产出 yes/no）应为 `INCONCLUSIVE`。判定式 `taggedViolations == 0 ? .yes : .no` 忽略了对照组。 |
| P2 | `vertical-column-flow` 的框是 **480 宽**，实际每屏容纳约 17 条竖列；`columns = 2` 数的是**屏数不是列数**（340 字/屏 × 2 ≈ 407 ✓ 数学吻合）。它声称的「单列串行」这个风险点从未被测到。名字与度量不符。 |
| P3 | `ruby-line-height` 的 base `東京` 中 **`東` 无字形**（已用独立 cmap 解析复核）。F1 的 8.000pt 是在部分 `.notdef` 的 base 上测出来的，**不干净**。 |

#### 本轮修复（按「先 I1+I2，再 P1/P2」）

| # | 修法 |
|---|---|
| I1 | ruby 评审图改用**自己的一帧**渲染，其 box 就是画布（400×120）；测量仍用 10000pt 的 box。doc 注释写明「CoreText 把首行放在 path 顶部」这一机制。 |
| I2 | `writePNG` 增加守卫：读 `CTFrameGetPath(frame)` 的 `boundingBoxOfPath`，与位图尺寸比较，放不下即 throw。空白 PNG 从此不再可能悄悄产出。 |
| P1 | 判定规则抽成**纯函数** `Kinsoku.decide(tagged:untagged:contentHeight:canvasHeight:)`，因为它正是出错的那一环。**对照组现在参与判定**：两臂都干净 → `inconclusive`（无可测之差）；tagged 干净而对照组有违规 → `yes`；tagged 有违规 → `no`。实验有效性（行末检查被绕过、画布被顶到）优先于比较。 |
| P2 | `chainColumns` 的 box 改为**一列宽**（`lineExtent` = 单字排版高度），因为 `rightToLeft` 下「框宽就是列距」——框和页面一样宽会让每帧塞下一整页竖列，`columns` 就变成数页数。`measureWidth` 仍是一列的长度。竖排评审图保持整页视野不变（两者回答不同问题，已在注释里说明）。 |
| P3 | ruby probe 增加**字形覆盖自证**：base 含字体未覆盖字符（本轮即 `東`）→ `inconclusive`，detail 说明「有 fallback 时行度量可能来自替代字体，不能归因于被测字体」。**不动语料** —— 改语料该是一次有意识的动作，不是为了让测量变干净。 |

新增 7 个测试（其中 `testCleanControlMeansNothingWasMeasured` 就是 P1 那个缺陷的回归），删除 1 个已失效的 canvas 测试，共 **72 个**。

#### 已独立复核为正确的

- `glyph-coverage` 报缺 `U+6771 東`、`U+30FC ー` —— 我用直接 cmap 解析复核，二者确实 glyph 0，探针无误。
- 跨进程确定性：3 个进程的 PNG **逐字节相同**、fingerprint 相同；完整 `spike-b.json` **不同**，差异恰为 `determinism.expectedFingerprint`（run1 为 null）—— 正是「指纹只覆盖 canonical payload」要保住的性质。
- 禁则的假 PASS 修复生效：`inspectedLineEnds = 2152 > 0`，464 个硬断行未使任何行末检查被绕过。

#### 附带查明的字体身份

`NagiRounded-Regular.ttf` 的真实 face 是 **`STYuanti-SC-Regular` / 华文圆体 / Yuanti SC**（SinoType 商业字体），文件名与内容不符。仓库私有故无暴露问题；`Seidoku` 将系统字体打入 app bundle 属产品/法务问题，此处仅记录。

### 早前 Review

### Gate 1 —— 第一次真实编译（2026-09-12）

仓库 `54zhien/nagi-engine`（private）已建，`main` 已推，CI 已跑。

**第一次：Build 红，一个错误。**

```
Sources/SpikeKit/Probes.swift:291:33: error: 'try' cannot appear to the
right of a non-assignment operator
291 |   frame: rubyFrame ?? try requireFrame(rubyInput),
```

按用户定的三类分流，这属于**实现错误**（我的 Swift 写错），不是测试期望错、不是实验装置问题。已改成 `if let` / `else` 语句（`ca8ca06`）并重推。

**这次运行的价值（比错误本身更重要）：**

| 事实 | 含义 |
|---|---|
| workflow 本身跑通（checkout ✓ / toolchain ✓ / job 结构 ✓） | 唯一未经校验的 YAML 也没问题 |
| `Fixture.swift`、`FontTables.swift` 编译通过 | **`ByteSlice` 的 owning-table 边界类型检查通过** |
| `Report.swift` 已开始编译 | throwing 契约在 `Quantize` / `LineRecord` / `ProbeOutcome` / `LayoutReport` / `SpikeReport` 上的传导类型检查通过 |
| `Typography.swift`、`main.swift` 尚未被编译 | 仍完全未验证 —— 含两处 CoreText 硬修复（`kCTFontAttributeName`、`RubyAnnotation` 5 参） |
| Gate 2 | 被 Gate 1 依赖挡住，从未运行 |

**仍未验证的**：66 个测试从未执行过；`swift test` 一次都没跑。

### 做了什么

五项语义 + 两项连带项 + 用户复核后的三点，全部收掉。测试 **49 → 66 个**。

**用户复核轮的追加三项：**

| 点 | 落点 | 结论 |
|---|---|---|
| 1. FAIL 语义二义 | `ProbeOutcome.Verdict` 拆成 `execution`（measured / inconclusive / unsupported）× `finding`（yes / no / nil） | 词汇表里**不再有 "FAIL"**。finding 以并排小写打印（`yes` / `no` / `—`）。init 强制不变量：`(execution == .measured) == (finding != nil)`，违反则抛 `SpikeError.inconsistentProbeOutcome`。代码失败本就不会走到这里——它抛错、进程非零退出、不产出报告，所以报告里的每条结论都是关于被测对象的 |
| 2. `--b.fingerprint` | 无改动 | **那不是我写的命令。** 我给的是 `--expect .artifacts/run1/spike-b.fingerprint`，run2/run3 都以 run1 为基线；`--b.fingerprint` 从未出现过。已再次确认 `main.swift` 的 `--expect <path>` 按读文件取指纹工作 |
| 3. canvas 自证 | `unboundedPageHeight` → **`measurementCanvasHeight`**（名字更诚实）；新增 `canvasIsUnconstraining` + 0.9 余量 | 金则扫描累积 `contentHeight`，逼近画布 90% 即转 `.inconclusive`，而不是把「测量画布不够高」误读成 CoreText 断行结果。`contentHeight` / `canvasHeight` 已进 report |
| 4. ByteSlice 溢出 | 无改动 | **已经是用户提议的形式**：`relativeOffset <= count, length <= count - relativeOffset`（避免加法溢出），且带注释说明理由 |

**我自己追加的一处同类自证**（与第 3 点同一原则，用户未要求，可否决）：ruby probe 现在检查两次排版各自恰好 1 行，否则 `.inconclusive`。行被折断时测的是「断在哪」而不是「行框多高」，那是同一类会被误读成排版行为的画布假象。

### 前五项（本轮主体）

五项语义 + 两项连带项全部收掉。

| 项 | 落点 | 关键决定 |
|---|---|---|
| 1. Kinsoku 假 PASS | `LineRecord` 拆 `utf16*`（consumed）/ `content*`；新增 `MandatoryBreak.contentRange` | 只去强制断行控制符（LF/CR/CRLF/NEL/U+2028/U+2029），**普通空白一律不动**；游标仍按 consumed 推进；`Kinsoku.Violations` 增加 `hardBreakLines` / `inspectedLineEnds` 与 `lineEndChecksWereBypassed`，探测到「有硬断行却无一行检查过行末」时 verdict 转 `.inconclusive` 而非 PASS |
| 2. Quantize | `Quantize.value` 改 `throws`，新增 `QuantizeError` | 非有限值与溢出**都是错误**，不饱和；传导到 `LineRecord`/`ProbeOutcome`/`Size`/`LayoutReport` 的 init；`LayoutReport` 六个浮点字段补上量化 |
| 3. writePNG | 改 `throws -> Int`（字节数），非 `@discardableResult` | 校验链路「建 context → 快照 → 建 destination → 编码 → 文件存在且 size > 0」；report 增加 `artifacts` 清单（`written` / `byteCount`） |
| 4. determinism | 提升为顶层 `determinism` 记录 + `ReportIO.writeFingerprint` 边车文件 | `canonicalFingerprint()` 只覆盖 `CanonicalPayload`；**关键设计**：determinism 不进 `probes`，否则「指纹覆盖 probe 结果」与「probe 结果是比对结论」自指矛盾 |
| 5. FeatureList 边界 | 新增 internal `ByteSlice`，每层 offset 相对 owning table | 外部接口仍是 `FontTables.parse(Data) -> FontTableReport?`，范围检查从散落 guard 收进一个 seam |
| 连带 A：金则扫描哨兵 | `SpikeB.unboundedPageHeight = 1_000_000` 取代 `.greatestFiniteMagnitude` | 否则第 2 项一落地，扫描立即 `metricOverflow` 抛出 |
| 连带 B：ruby 自证 | `LayoutInput.rubySizeFactor` + report 里 `requestedRubySizeFactor` | 报告声称的 0.5 就是实验实际用的 0.5 |

### 验证结果（本机可做的部分）

- **`FontTableTests` 全部期望值**：用独立 Python 复刻**新版有界解析器**逐条核对，18 项全 OK。
- **新回归测试的区分力已证明**：那条「offset 逃出本表」的 fixture，以文件为界会读出 padding 表**伪造的** `vert`，以 owning table 为界返回 `[]`。**过程中发现并修掉了自己的错误**：fixture 原本用 3 字节的 `"pad"` 当 tag，sfnt tag 必须恰好 4 字节，导致后续 offset 整体错位——那条测试当时是「因为错误的原因通过」的。已在 helper 里加 `precondition` 把这个错误永久挡住。
- 全部 9 个文件词法括号/引号配平；62 个 test 方法逐条核对。
- 检查脚本报的 4 处「用了 `try` 未标 `throws`」经核实**是误报**：`XCTAssertThrowsError` 的首参是 `@autoclosure () throws -> T`，该写法是标准习语，调用点无需 `throws`。未改。

### 遗留问题

1. **`swift build` / `swift test` 仍未跑过**。本机无工具链。这是唯一真正的验证，现在该走了。
2. `Size` 是死代码（全仓只有它自己的声明与我的测试引用它）。未删——超出本轮范围，但 `testSizeQuantizesOnConstruction` 因此是全套里最弱的一个测试。
3. `GlyphCoverage.missingScalars` 的注释仍与代码不符（注释说 deduplicated，代码只排序）。未改，未钉。
4. `SpikeReport` 缺 `layoutAlgorithmVersion`（ADR-0011 要求 golden 门钉死它）。
5. `parseFeatureList` 现在以 owning table 为界，但 `ByteSlice` 尚未被 vhea/vmtx 等后续解析复用——那是它们落地时的事。
6. `artifacts.byteCount` 在 report 里但不在 `CanonicalPayload` 里。这是有意的：ADR-0011 说 PNG 不作 pixel gate，若 byteCount 进了比对负载，PNG 编码变化就会间接卡住度量门。
7. **`environment` 节点不存在**（未实现，不是「已隔离」）。`SpikeReport` 只有 `probes` / `artifacts` / `determinism` 三个节点，没有任何运行元数据。所以 fingerprint 不含环境信息这一点，当前是**空集意义上的成立**，不是设计意义上的隔离。Gate 2 若要收 `environment.json`，需新做。放在 Gate 1 之后——Gate 1 之前每加一行都是可能让首次编译变红、且与待学内容无关的一行。
8. **`.unsupported` 无生产者**：全仓只有 `Report.swift` 的枚举定义与 `main.swift` 的打印标签，没有任何 probe 会产出它。原因是当前没有 probe 触碰版本门控 API（`CTRubyAnnotationCreateWithAttributes` 10.12+、`UTType` 11+，而 package 下限是 macOS 13）。保留该 case 作为协议状态空间的一部分，不为「覆盖 enum case」人为制造 probe。
