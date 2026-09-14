# Incremental Pagination and PageMap

**Status:** accepted

`PageMap` 是 **disposable derived cache**，允许部分：

```swift
struct PageMapSnapshot: Sendable {
    let generation: LayoutGeneration
    let signature: LayoutSignature
    let pages: [PageDescriptor]
    let frontier: NativeDocumentPosition
    let isComplete: Bool
}
```

打开书时只需物化当前 Anchor 附近的 fragment 与若干页，UI 立即可用；后台由 `PaginationEngine` actor 继续推进 frontier。对外**只发布不可变的 `PageMapSnapshot`** —— 不允许后台 append 一个可变数组而主线程并发读。

PageMap 未就绪时总页数未知。产品上显示「第 47 页 / 共 ? 页」，或暂不显示总页数。**页码是派生输出；publication progress 不经由页码**（见 ADR-0009）。

> **这条禁令与 ADR-0009 把 `fixedPageOrdinal` 列给 PDF/CBZ 看似矛盾，实为互补**（2026-09-12 补记）。
> 页序号在**可重排**内容上是排版的输出，在**固定版式**内容上是出版物的属性。判据不是「能不能用页序号」，
> 而是**布局无关性**：只有内容自身携带页序号的格式才准把它当坐标。
>
> Spike A 阶段二已把它从一句话变成一次测量（`progress-layout-independence`）：容器**声明**了分页的资源上
> 页序号必须存在且随声明变化，容器**没有**声明的资源上必须一律为 `nil` —— 拒绝作答，而不是按偶数切一份出来。

**分页边界**

**v1 的 `DocumentUnit` 是 hard pagination boundary —— 页不跨 unit。** 理由不是「Readium 如此」，而是这样第一版可以隔离一批难题：不同 root style、不同 writing-mode、不同 CSS inheritance root、章节标题、`break-before`、resource 生命周期、页眉归属、unit 加载。

Layout 层从第一天以策略抽象，**不得假定该限制永久存在**：

```swift
enum FlowBoundaryPolicy { case hard, continuous }
```

未来允许多个 DocumentUnit 组成连续 `FlowGroup`。**`ContentShard` 永远不是分页边界。**

**强不变量**

> 所有当前可见 `PageScene` 的交互必须完全同步 —— 命中测试、选区起点、链接点击不得触发文档物化、磁盘 IO 或 async 请求。`PageScene` 必须携带完成这些所需的全部局部映射（`PageInteractionMap` 的 text/link/image hit regions 与 glyph cluster mapping）。

**边界：页内同步，跨页允许 async**（多页选区、跨 unit 扩展）。

**Consequences**

- 持久化缓存键必须包含：`DocumentID` + `identitySchemeVersion` + `documentSchemaVersion` + `LayoutSignature` + `layoutAlgorithmVersion`。
- 任何影响分页的设置必须进入 `LayoutSignature`，**包括字体资源本身的指纹** —— 捆绑字体在 app 更新中换了文件，分页会变，旧 PageMap 即错误。
- PageMap 在每个 LayoutSignature 下都不同，因此持久化对它而言只是「同设备同配置的冷启动加速」，不是通用缓存。
- **查找路径是两层的**：先按单元序号定位单元，再在该单元内按偏移定位页。这个结构是 v1 的 hard pagination boundary（页不跨 unit）的直接推论 —— 页落在一个单元内，所以「哪个单元」与「单元内哪里」可以分两步问。ADR-0003 的文档序键已定案（2026-09-13）：序号 = 单元在 reading order 中的序号 + 单元内绝对 `utf16Offset`；该序键只在同一份不可变 manifest snapshot 内可比较、不持久化。
