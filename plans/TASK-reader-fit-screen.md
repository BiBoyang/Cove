# TASK: 阅读器适应屏幕模式 + 图片分类扩展 + 不支持类型提示

日期：2026-08-21 ｜ 协作模式（用户/Codex 实现，助手规划与 Review）

## 目标复述

1. 普通照片（目录模式打开的图片）默认**整图适配屏幕**（适应屏幕），不再被拉伸到满屏宽度只显示局部；CBZ 漫画维持**适应宽度**的竖向长条模式；控制条提供两种模式的切换按钮。
2. RAW 等相机格式纳入图片分类，双击可直接查看。
3. 双击不支持的文件类型时给出明确提示，不再静默无反应。

## Out of Scope

- 左右翻页模式、缩放（pinch/放大镜）、旋转。
- 视频播放、PDF 打开。
- 预热/缓存管线改动（display variant 宽度策略不变）。
- 键盘快捷键切换显示模式（本期不做）。

## 现状摘要

- `ReaderWindowController`（`Cove/Interface/ReaderWindowController.swift`）是全屏条漫阅读器：`showWindow` 强制 `toggleFullScreen`；每个 slot 高 = `内容宽 × 图片宽高比`，图片永远撑满窗口宽度。竖版照片一屏只显示顶部局部 —— 即"全屏放大非填充"症状的根因。
- `ReaderContent`（`Cove/Interface/ReaderContent.swift`）是 struct，含 `directory` / `comic` 两个工厂方法，但**没有保留模式标记**，需要补一个 kind 供阅读器决定默认显示模式。
- 图片分类表在 `Frameworks/SourceKit/Sources/SourceKit/ContentItem.swift` 的 `FileType.init(classifying:)`；`BrowserViewController.handleDoubleClick`（`Cove/Interface/BrowserViewController.swift`）只路由 directory/image/comic，其余类型静默吞掉。
- 实测日志（`/tmp/cove-logstream.txt`）无 `Page N load failed` 记录，排除"解码失败导致看不见"。

## Step 列表与 DoD

### Step 1：扩展图片分类（SourceKit）

- 改动文件：
  - `Frameworks/SourceKit/Sources/SourceKit/ContentItem.swift`
  - `Frameworks/SourceKit/Tests/SourceKitTests/ContentItemTests.swift`
- 内容：image 分支追加 `cr2, cr3, nef, arw, dng, raf, orf, rw2, jfif, jpe`（全部小写比较，现有逻辑已 lowercased）。**不加 `svg`**（ImageIO 无法稳定解码，加进去只会得到"加载失败"占位）。
- DoD：
  1. 新增扩展名分类为 `.image`，大小写不敏感；
  2. video/pdf/comic/text/other 分类无回归；
  3. `swift test --package-path Frameworks/SourceKit` 全绿。

### Step 2：不支持类型的双击提示（Interface）

- 改动文件：
  - `Cove/Interface/BrowserViewController.swift`
  - `Cove/Interface/MainWindowController.swift`
- 内容：
  - `BrowserViewController` 新增闭包 `var onUnsupportedFile: ((_ name: String) -> Void)?`；`handleDoubleClick` 中文件且非 image/comic 时调用它（目录行为不变）。保持 VC 纯声明式、不直接弹窗。
  - `MainWindowController.wireCallbacks` 里接线：弹 `NSAlert` sheet，messageText `暂不支持打开该类型文件`，informativeText 为文件名，style `.informational`。
- DoD：
  1. 双击 `.other` 类型文件出现上述提示；
  2. 目录/图片/CBZ 双击路由无回归；
  3. `make build` 零警告（App target 是 strict concurrency complete）。

### Step 3：阅读器"适应屏幕 / 适应宽度"双模式（方案 B）

- 改动文件：
  - `Cove/Interface/ReaderContent.swift`（补 kind 标记）
  - `Cove/Interface/ReaderWindowController.swift`（显示模式 + 切换 + 布局）
- 设计：
  1. `ReaderContent` 增加 `let kind: Kind`（`enum Kind: Sendable { case directory, comic }`），两个工厂方法各自标注；`ReaderPage` 不动。
  2. `ReaderWindowController` 增加显示模式枚举（如 `DisplayMode { case fitScreen, fitWidth }`）。默认：`.directory` → `.fitScreen`；`.comic` → `.fitWidth`。
  3. slot 高度计算（`estimatedHeight(for:)`）按模式分叉：
     - `fitWidth`：`width × aspect`（现状不变）；
     - `fitScreen`：`min(width × aspect, viewportHeight)`，`viewportHeight` 取 `scrollView.contentView.bounds.height`，布局前回退 `NSScreen.main.frame.height`。
     - slot 内 `NSImageView` 已是 `scaleProportionallyUpOrDown + alignCenter`，整图自动留边居中，无需改 slot view。
  4. 控制条新增一个切换按钮（SF Symbol 自选，如 `arrow.up.left.and.arrow.down.right` / `rectangle.expand.vertical`，accessibilityDescription 中文"切换显示模式"）；切换后调用现有 `relayoutSlotHeights()`（已带视口锚点保持）。
  5. `clipBoundsDidChange` 目前只在宽度变化时重排；`fitScreen` 模式下**高度变化也要触发** `relayoutSlotHeights()`（全屏过渡会改高度）。沿用 `> 0.5` 的 delta 阈值防止布局回环。
  6. 注释用英文，UI 文案中文；布局用 SnapKit DSL；遵守 strict concurrency 零警告。
- DoD：
  1. 竖版照片（如 3024×4032）双击打开后**整图可见**（上下/左右留边，无裁切）；
  2. 横版 3:2 壁纸整图可见，无上下裁切；
  3. CBZ 打开仍是适应宽度长条，行为与现状一致；
  4. 切换按钮即时重排，视口不跳动（锚点保持生效）；
  5. 全屏进入/退出过渡后布局正确；
  6. `make generate && make build` 零警告；`make test` 全绿。

## 风险与回滚点

- **RAW 体积**：单张 20–50MB，缩略图与预热会整文件拉取（NAS 实测 ~21MB/s），首看有等待感；本期接受，后续由预热双池策略兜底。若实测太慢，回滚方式 = 从分类表摘掉 RAW 扩展名（Step 1 独立提交可单独 revert）。
- **布局回环**：fitScreen 下 slot 高度依赖视口高度，重排又改变 document 高度。已用 delta 阈值 + 锚点保持约束；若出现抖动，回滚 = 恢复 `clipBoundsDidChange` 只监听宽度。
- **模式默认值分歧**：若用户实测后想让目录模式也默认 fitWidth，只需改 init 一处默认值。
- 三个 step 相互独立，分别提交，可单独 revert。

## 建议先做的 step

Step 1 → Step 2（同一次提审，两个都是小改动）→ Step 3（单独提审）。

## 验证命令

```sh
swift test --package-path Frameworks/SourceKit   # Step 1
make generate && make build                      # Step 2/3，零警告
make test                                        # 全量回归
```

人工验证点：竖版照片整图可见；横版壁纸无裁切；CBZ 长条不变；双击不支持类型弹提示；RAW 照片可直接打开。
