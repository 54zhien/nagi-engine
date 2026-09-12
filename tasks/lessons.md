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
