# Rendering and Golden Validation

**Status:** accepted

golden 回归在 iOS Simulator test target 中运行，固定：Xcode 版本、simulator runtime、**捆绑的固定字体**、viewport、locale、`layoutAlgorithmVersion`。输出两个 artifact：

```
PageScene.json     machine gate —— 阻断 CI
page.png           human review artifact —— 不作 pixel gate
```

**JSON 检查**：page ranges、line ranges、line origins、glyph / cluster boundaries、image rects、完成情况下的页数。浮点**量化到约 3 位小数**，防止无意义的浮点差异。

**为什么 PNG 不能当门**

PNG 跨 OS 版本的差异噪声会逼人养成「红了就重录 golden」的习惯 —— 那 golden 就失去了价值。

**为什么必须捆绑固定字体**

固定字体解决 **glyph metric 漂移**（iOS 26.0 → 26.1 系统字体微调会让几百张 golden 全炸）。但它**不解决断行策略漂移**：断行依赖系统的 Unicode 数据，可能随 OS runtime 变化，即使字体完全没动。因此还要钉死 simulator runtime，并把 **golden 更新视为需要人审的事件**。

（不在本 ADR 中断言 Apple 内部的 Unicode/ICU 实现细节 —— Apple 未把该实现作为契约承诺。安全表述是：CoreText / 系统 Unicode 数据 / 断行 / shaping 行为可能随 OS runtime 变化。）

**为什么这对本项目是必需的**

排版引擎是视觉工程。本项目在 Windows 上开发、经 GitHub Actions 构建、需真机验证。CI 直接产出渲染页图与度量 JSON 作为 artifact，是排版能在 Windows 上迭代的**唯一**途径，同时它就是 golden 回归本身。

**Consequences**

- GitHub hosted runner 不保证旧 simulator runtime 长期存在。若 golden 成为关键依赖，长期需 self-hosted macOS CI。
- 这些 artifact 同时是 Spike A / Spike B 的输出载体。
- 提交前验证须包含 CI artifact 的实际结果，不得仅以「本地静态检查通过」作为完成依据。
