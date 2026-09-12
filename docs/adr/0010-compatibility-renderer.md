# Compatibility Renderer

**Status:** accepted

长期保留一条 WebKit 兼容渲染路径。由 `NativeCapabilityDetector` 在打开时判定：

```
Profile 之内        → Nagi Native Engine
超出 Profile        → ReadiumCompatibilityEngine（WKWebView）
                      复杂 fixed layout / SVG / MathML / 高度依赖异形 CSS 的内容
```

两者实现同一个 `ReaderPresentationEngine`。

**为什么**

这是**产品目标**决定的：追求 Native 体验上限的同时，不牺牲 EPUB 兼容性下限。不是「别人都这么做」—— 反例存在（Yuedu-reader 明示不使用 WebView），但代价是放弃那部分兼容性。

**依赖方向由构建系统强制，不靠约定**

```
NagiEngineCore            不声明依赖 ReadiumNavigator → 物理上无法 import
NagiReadiumCompatibility  声明依赖，实现 ReaderPresentationEngine
```

SPM 的 target 依赖在编译期保证这一点：删除 adapter target 时，核心零修改。否则会出现「口称 Navigator 已降为 Adapter，实际 Nagi 核心仍绑死在 Navigator 的数据结构上」。

**Consequences**

- 两个引擎必须共用同一套位置系统，否则将永久维护两套选区 / 批注 / 书签系统。这是 `LocationBridge`（ADR-0004）存在的理由，也是 Readium `Locator` 被保留为 Publication Position 载体的理由。
- 迁移期间，`Reduce Motion` / `VoiceOver` / 滚动模式的原生导航仍由 Readium 内置导航承担（见 `Docs/ReaderTransitionEngine.md` 的既有约定）。
- `PageSurface` 必须去 fork 类型化：核心不得暴露 `NavigatorPageSurface` / `NavigatorCurrentPageSurface` / `NavigatorPageSurfaceIdentity`。方向必须是 `Readium Adapter → Nagi interface`，而不是 `Nagi core → Readium fork types everywhere`。相关工作应提前做。
