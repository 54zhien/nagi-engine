# ReanchorService 执行单（R0 – R3）

**方案由 Codex 给出，Claude 只执行。** 疑点写进报告，不自行改道。

基线：`main = origin/main = 87c30ab8abe6fd85b0cd09ec66500c75acd866fc`，分支保护已完成（PR + 两个 Gate + `enforce_admins`）。

## 全程硬约束

- **`tasks/codex-confirm-4.md` 保留**：不删除、不修改。
- **永不用 `git add -A` / `git add .`**：该文件必须始终留在未跟踪状态，不得进入任何提交。
- `main` 已有保护且含管理员 —— 一切改动走 PR，两个 required checks 必须绿。
- 本机**无 Swift 工具链**，CI 是唯一编译器。每段提交前跑：`git diff --check`、全仓库 `{}` 逐文件平衡。
- 多行 git message 一律 `git commit -F - <<'EOF'`（`-m` 双引号里的反引号会被 shell 吃掉）。

---

## R0 — 契约文档（本段）

**产出**（只新增两份，**不改任何 Swift、`Package.swift`、README、CI 或既有 ADR**）：

- `docs/adr/0012-reanchor-service.md`（Status: accepted）
- `tasks/reanchor-service-plan.md`（本文件）

**顺序**：写两份文档 → 自检 → 交 Codex 读 diff。

**判据**：

- `git diff --check` 干净。
- `git status` 只显示这两个新文件 + 未跟踪的 `tasks/codex-confirm-4.md`。
- 文档不得把「模糊」写成近似文本匹配；不得把 `AnchorValidator` 合并进 `ReanchorService`；不得说本轮实现 `DocumentStore`。

**⛔【确认点 R0】：不得先提交。** 未提交的 diff 交 Codex 审；**它放行后，本次提交只含这两份文档**（`docs/adr/0012-reanchor-service.md`、`tasks/reanchor-service-plan.md`），不含任何 Swift 文件。

---

## R1 — 类型 / 算法 / 单测

**拟新增**（不动 `Fixture` / `SpikeACases` / 现有 probe）：

- `Sources/SpikeAKit/Anchor.swift`
- `Sources/SpikeAKit/AnchorValidator.swift`
- `Sources/SpikeAKit/ReanchorService.swift`
- `Tests/SpikeAKitTests/ReanchorServiceTests.swift`

**必须覆盖的矩阵（至少）**：

| # | 情形 | 期望 |
|---|---|---|
| a | 原位置仍有效，且别处有重复 | 必须走 `originalPosition` |
| b | 前文插入导致 offset 整体移动 | `relocated` |
| c | 段落跨 unit 移动 | `relocated` |
| d | 重复 exact，由不同 prefix/suffix 唯一消歧 | `relocated`（`quoteContext`） |
| e | 重复 exact 无法消歧（含 context 全失配） | `ambiguous`，候选**有序**且**不选最近** |
| f | exact 文本本身变化 | `notFound` |
| g | `unitID` / `href` / `id` 全变，仍按 quote 恢复 | `relocated` |
| h | CJK 标点 + XHTML 空白 folding | 按 canonical primary text 判定 |
| i | ruby annotation 不入主文本 | base quote 可恢复，offset 为 UTF-16 |
| j | 非 BMP 前缀之后的 UTF-16 offset | 逐 code unit，不按字符数 |
| k | 空 exact | `notFound`（`emptyQuote`） |
| l | 重叠 exact | 命中包含重叠 |

**顺序**：写类型 → 写算法 → 写测试 → 自检 → 交 Codex 读 diff。

**判据**：

- 静态检查：`git diff --check`；全仓库 `{}` 逐文件平衡。
- 全仓 `rg` 确认**已删符号**无残留引用、**新符号**无悬空引用。
- **不得改** `Fixture.swift` / `SpikeACases.swift` / 任何现有 probe。

**⛔【确认点 R1】：R1 做完保持未提交。Codex 读过 diff 之后才准提交** —— 且那一次提交**只含这 4 个文件**（3 个 `Sources/SpikeAKit/*.swift` + 1 个 `Tests/SpikeAKitTests/ReanchorServiceTests.swift`），不含文档、不含 probe。

---

## ⛔【确认点 R1-CI】—— 在写 R2 之前

**目的**：让「这四个文件能不能编译、20 个测试是否真的执行」成为一个**独立于 R2** 的读数。若 CI 红，归因只有 R1；与 probe 混在一起就分不清是哪一半。

**顺序**：

1. R1 经 Codex 放行后，**单独提交**（只那四个文件）。
2. **随即 push 分支并开 Draft PR** 触发 CI —— **不等 R2**。
3. **Gate 1**：编译成功，且新增的 **20 个 test function 确实执行**。
4. **Gate 2**：现有两个 spike 各自三进程指纹一致。
5. 从**本次 PR run** 与 **main 基线 run `34742073652`** 各下载 `spike-artifacts`，**逐字节**比较：
   - Spike A：`spike-a.json`、`spike-a.fingerprint`、`canonical-text.txt`
   - Spike B：`spike-b.json`、`spike-b.fingerprint`
   - artifact 路径清单不得缺项。
   - **PNG 只核「存在且非空」，不作跨 run 字节门禁**（ADR-0011 把编码排除在 canonical gate 之外）。
6. **该确认点通过之前，不得写 R2。**

**判据来源**：「旧 payload 投影」的确切定义见 ADR-0012（那条定义在此确认点才真正被执行）。

**若任一 Gate 红**：停止并回报错误原文，**不自行修复**。

---

## R2 — 证据（probe 与读数）

**前置**：R0 与 R1 **已各自单独提交**，且**【确认点 R1-CI】已通过** —— 也就是说，**PR 已经存在**（Draft）。R2 不再自己开 PR，而是**把 diff 交给 Codex 获批后，提交并 push 到同一个 Draft PR**。

**再做**（**第三个独立提交**）：追加 `reanchor-policy` probe，**放在 Spike A probes 的尾部**（顺序即报告的一部分），并加最小 corpus / report `numbers`。

> **提交边界（三段各自独立，任何一段都不得与另一段合并提交）**
>
> | 段 | 提交内容 | 提交时机 |
> |---|---|---|
> | R0 | 2 份文档 | Codex 放行 R0 之后 |
> | R1 | 4 个类型/算法/测试文件 | Codex 放行 R1 之后 |
> | R2 | probe + corpus/report numbers | 上述两段已提交之后，作为第三个提交 |
>
> **不得**写成「R0 与 R1 一起、到 R2 才提交」。

**判据**：

- 所有 `relocated` / `ambiguous` / `notFound` **判别臂 `evidenceCount > 0`**。
- 桶和**等于** `cases`。
- **不得改旧用例**（`SpikeACases` 的既有行一个都不许动）。
- **推分支并开 Draft PR 才会触发 CI**（`push` 只在 main 上触发；分支靠 PR）。
- Gate 1 必须全部通过；Gate 2 三进程指纹一致。
- **Spike B 的 artifact 与 main 的基线逐字节一致。**
- **Spike A 的「去掉新 probe 之后的旧 payload 投影」与 main 的基线逐字节一致。** —— 这是「旧读数没被新工作移动」的判据，不是声称。

**⛔【确认点 R2】：提交 / 推送 / 开 Draft PR 之前，先把拟提交的 diff 交 Codex。CI 与 artifact 比对完成后再停等。**

---

## R3 — 收口

**前置**：R2 获批。

**顺序**（**独立提交**）：

1. 更新 ADR-0012 的**实测数字**。
2. 更新 README 的 Spike A 后续说明。
3. 更新 `tasks/todo.md`。
4. 转 ready PR。
5. 确认两个 required checks 绿且 **strict 基线最新**。
6. **Codex 终审后**才 `rebase merge`。
7. 核对 main 的 tree、tags、分支保护。
8. **由 Codex 决定**是否打 `reanchor-service-sealed` tag。

**⛔【确认点 R3】：合并与打 tag 都必须等 Codex 明确确认。**

---

## 停止点汇总

| 确认点 | 停在哪里 | 等 Codex 做什么 |
|---|---|---|
| R0 | 两份文档写完，**未提交** | 读未提交 diff，放行才提交 |
| R1 | 类型/算法/单测写完，**未提交** | 读 diff，放行才提交 |
| R2 | 拟提交 diff 备好；以及 CI/artifact 跑完之后 | 先审 diff，再验 artifact |
| R3 | 收口提交备好；以及合并前后 | 终审、放行合并、决定 tag |
