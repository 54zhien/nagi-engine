# Lessons

每次被纠正后立即追加一条，写清「发生了什么 / 规则是什么」，避免重复犯错。
每次会话开始时先复习与当前任务相关的部分。

## 模式

| 场景 | 教训 / 规则 |
|---|---|
| 本机无 Swift 工具链，代码只能靠眼睛审 | **不要让 `try` 与二元运算符混排。** `rubyFrame ?? try requireFrame(...)` 编译不过：`try` 不能出现在非赋值运算符的右侧。凡表达式中含 `try`，展开成 `if let` 或先落一个中间变量，不要塞进 `??` / `&&` / `+` 里。CI 第一次运行就抓到这一处，是全部 26 个文件里唯一的编译错误。 |
| 在无编译器环境里写 Swift | 优先选择**我对语法确信度最高的形式**，而不是最短的形式。这次 `try x ?? y` 我原本认为可行，改成了 `if let` / `else` 语句 —— 代价是 5 行，收益是不必赌。 |
| 上报「已完成」之前 | 不要把「打算做」说成「已经做」。曾对用户说「待办里我记了两项」，实际一行都没写。说之前先 `grep` 一次确认。 |
| 遇到 GitHub 报 `EOF` / `schannel` | 先**原样重试一次**再谈别的。本机到 GitHub 的 HTTP/2 链路间歇性断连，curl（走 HTTP/1.1）同时刻完全正常。不要在没验证的情况下往「被墙」「权限不足」方向查。 |
| 判断「网络问题」还是「工具问题」 | 用第二个工具对**同一个端点**测一次。curl 通、gh 断 → 是工具/协议栈问题，不是网络问题。这一步把三次故障一次性定位清楚。 |
| 上传 CI 产物 | `actions/upload-artifact` **默认跳过隐藏文件**。产物目录若叫 `.artifacts/`（点开头），会**静默传空** —— 而且 `if-no-files-found: warn` 会让这一步显示为 success。用非隐藏目录，并把该选项设成 `error`。这与 `writePNG` 那个「静默丢失产物」是同一类故障，只是发生在不同层。 |
| 让脚本/步骤「不可能静默失败」 | 凡是「找不到东西就跳过」的开关（`warn`、`continue-on-error`、`\|\| true`），都必须先问：**它跳过的时候，我能不能从日志里看出来？** 看不出来就是缺陷，不是宽容。 |
| 写 `XCTAssertEqual` 断言枚举 | **不要写 `XCTAssertEqual(dict["k"], .someCase)`**。字典下标给出 `T?`，前导点成员让泛型参数无法解析，编译器会报 `type 'Equatable' has no member 'someCase'` —— 症状离原因很远。改用 `XCTAssertTrue(dict["k"] == .someCase)`。**这条我在 Spike B 里已经知道并照做，写 Spike A 时又忘了。** |
| 泛型/成员解析失败时 | 先看**是不是推断不出来**，而不是去找那个不存在的成员。`type 'Equatable' has no member X` / `type 'Double' has no member Y` 都是「我把 X 用在了错误的类型上」，不是「X 不存在」。Spike A 的两次红——`Double.nonNegativeInt` 与 `Equatable.notCarriable`——都是这一类。 |
| 断言涉及 fixture 的**绝对** offset / 序号 | **不要凭记忆写常数。** 断言不变量（「offset 等于该元素的起点」）而不是数字。Spike A 里同一个测试因为这条错了**两次**：第一次 fixture 的 `<title>` 被算进了阅读流，第二次我把「第一个标题从 0 开始」断言到了段落身上。两次的报错都是一个看起来合理的数字，没有任何东西提示它错。规则：**凡是能写成关系的地方，不要写成常数。** |
| 新增/修改 fixture 后 | 先用手算（或一段独立脚本）把 canonical text 与关键 offset 算出来，再写断言。Spike A 第三次靠这个才一次通过。 |
| 测试报 `("9") is not equal to ("4")` 这类「两边都合理」的差异 | 这几乎总是**期望值写错**，不是代码错。先去核对被断言的那个对象到底是什么，而不是去改代码迁就断言。 |
| 把「两值判定」改成「三值判定」 | **字段裁定与 outcome 必须并排走一遍。** 把 `utf16Offset` 从「相等 / 丢失」改成「相等 / 重算 / 丢失」时，我只改对了 outcome 分支，字段那行仍是 `(matches && carried) ? .reproduced : .lost`。于是 `.path` 那一行变成一句自相矛盾的话：outcome 刚写下「数字相等，报丢失是另一种误报」，字段却标着 `.lost` —— 而它的含义正是「丢了，本不该丢」。**两个审查代理独立地同时抓到它。** 规则：改判定后逐分支把 `fields` 与 `outcome` 并排读一遍，专找互相矛盾的组合 —— 矛盾会原样进 artifact 的 JSON。 |
| 一轮读数出来，结论不对劲 | **先复核测量仪，再复核被测物。** Spike A 第一轮的头条结论「`locator(from:)` 优先发 `fragments` 是精度上的错误取舍」三处都站不住：它其实**同时**发 `fragments` 与 `progression`；丢 offset 发生在解析侧；而「补回 offset」的唯一通道被 ADR-0009 命令禁止。**看到数字时先问「这个数由谁产生、判定规则本身对不对」，那个「唯一成功的例子」往往最有问题。** |
| 改某一行读数的判定 | **先问这一行有没有测试钉住。** `native-path-anchored` 是唯一走 progression 路径的 native-first 用例，而它**零覆盖** —— 这正是它能长期被判成 `.exact` 而无人察觉的原因。规则：动任何一行的判定前，先确认有断言钉住它；没有就先补，否则改完只有一行没人读的报告作证。 |
| 把验证步骤写进计划 | **先打开那个配置，确认这条路径真的会触发。** 计划里写「推分支跑 CI」，而 `ci.yml` 的 `on:` 只监听 **main 的 push 与 PR**；`gh` 又未登录开不了 PR —— 开分支等于零验证。 |
| 修订一份 ADR | **修订块不要插在 `**Status:**` 与纲领之间。** 我把 Spike A 的修订插进去，把「进度不是持久化坐标」那句纲领挤到了下面。纲领句必须紧贴标题；修订追加到文末或对应章节旁。 |
| probe / 断言报 `yes` 之前 | **先问它有没有可失败的行。** `progress-provenance` 第一次跑报 `yes`，而 `carriedRows = 0` —— 语料里没有一行能触发那个断言，它靠「没有东西可以失败」通过。正式规则：**A probe may conclude `yes` or `no` only if its discriminating arm has non-zero evidence. Zero coverage is `inconclusive`, never success.** 覆盖数必须进 `numbers`，否则 JSON 的读者看不见它。这个病已经撞到**第二次**（第一次是 `native-path-anchored` 零覆盖所以长期判错），所以下一轮应把它做成 probe 声明的 `minimumEvidenceCount`，而不是每个 probe 手写判断。 |
| 一个函数在**部分**分支算出值却没处安放 | `Resolution.discarded` 对 `.ambiguous` / `.unresolvable` 返回 `[]`，而 `native(from:)` 明明已经算好一个列表。于是「解析失败」报告成「什么都没丢」。规则：**改判定或改枚举前，逐个 case 走一遍：这条路径能携带这个值吗？** 携带不了的类型层缺陷，不是「这个 case 本来就没有东西可丢」。 |
| 报告/探针里写死一个会随 fixture 变的数 | `pageCountBefore: 2` 写成了字面量，fixture 改了它还会继续说「2 -> 4」，而 probe 照样 `yes`、测试照样绿。规则：**能从被测对象读出来的数就不要抄。** 与本轮给报告加 `readingOrderUTF16Length` 是同一件事 —— 报告里不许出现没有任何测量在用的数。 |
| 写多行 git commit message | **不要用 `-m "..."` 加反引号。** 双引号里的反引号会被 bash 当命令替换执行，提交后那些词直接消失（本轮 `recomputed from progression…` / `progress-provenance` / `mediaType` / `fragments` 四处丢了，日志里只剩 `command not found`）。规则：多行 message 一律 `git commit -F - <<'EOF'`（引号版 heredoc，不做任何展开）。 |
| 让审查代理「核编译面」 | **它说 `complete` 不等于能编译。** 第二次推送时我让独立代理核编译面，它逐条列了每个改签名的调用点并判为「全部对得上」，其中包括 `table.map(\.provenanceOnly)` —— 而 `provenanceOnly` 是 `FieldResolution` 的成员，`table` 是 `[FieldProvenance]`。CI 一推就红。规则：**「有没有引用已删符号」和「这个成员在这类型上吗」是两个问题**，代理（和人）对前者可靠、对后者不可靠，因为**隔壁类型上真有一个同名成员**时它读起来完全合理。无本地编译器时，把这类改动的判据定成「这个成员定义在哪个类型上」逐条去 `grep` 定义处，而不是读调用点像不像对的。 |
| 用脚本做机械替换之后 | **推之前跑一次全仓库括号平衡。** 一次「把类的闭合括号挪到文末」的 Python 替换少留了一个 `}`，文件 open 31 / close 30，整个测试 target 编译不过 —— Gate 1 停在 Test 而 Build 是绿的，这正是那道工序该有的分辨力。**语法审查代理看不见它**：它读的是 diff，而 EOF 处缺一个右括号在 diff 里不可见。规则：凡是用脚本动过 Swift 源文件，推之前 `{` 与 `}` 计数必须逐文件相等。 |
| 无编译器环境写 Swift，遇到 `any P` 存在类型 | 不要赌「继承 `Sendable` 的协议的存在类型本身是否 `Sendable`」。改成泛型 `Service<Axis: ProgressMetricAxis>` —— 同样零成本，且是静态派发。lessons 里「优先选确信度最高的形式」这条，本轮又用上一次。 |
