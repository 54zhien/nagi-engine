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
