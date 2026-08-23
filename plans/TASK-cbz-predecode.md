# TASK: CBZ 页预解码（翻页前把后续 2 页解码进 display 池）

日期：2026-08-23 ｜ 协作模式（本会话规划/Review，另一会话实现）

## 目标复述

CBZ 阅读时，打开阅读器和每次翻页后，把当前页之后最多 2 页提前解码（ImageIO 全尺寸解码 + JPEG 编码）进 display 池，翻页时 `ReaderImageLoader.load` 走 display 命中路径，消除全尺寸解码等待。

## 决策记录（已拍板）

- **机制 = 复用 `load` 本身**：load 的完整路径（display 检查 → 取原始字节 → 解码 → 编码进 display 池）就是预热的全部工作；预解码是"提前调它、丢弃返回"。
- **warm 必须在解码前跳过已暖页**：`load` 的 display 命中路径仍会解码 payload（交给上层显示用），warm 场景这是浪费——所以 `warm` 先查 display 池变体存在性，已暖直接返回。
- **错误吞掉**：预解码是 best-effort，`try? load`；真实错误由用户翻到该页时的正式加载路径暴露。
- **数量与触发点**：与相邻页预取一致——向前 2 张，打开 + 翻页两个触发点（复用上个任务建好的 `onPageChanged` 缝和 open 触发点）。
- **并发**：decode 是 CPU 密集同步调用，warm 必须 `Task.detached`，不上主 actor。
- **不做取消**：单页解码百毫秒级；翻页过快留下的陈旧 warm 结果是有效缓存，LRU 兜底。
- **仅 CBZ 模式**：目录模式的网络等待已被相邻页预取覆盖；目录模式的 decode-ahead 是未来优化，本期不做。

## Out of Scope

- 目录模式预解码、向后预取、预热数量设置项。
- Reader 渲染结构、`load` 主路径行为改动。

## 现状摘要

- `ReaderImageLoader`（`Cove/Services/Media/ReaderImageLoader.swift`）：Sendable struct，`load(pageAt:)` 路径为 display 池（variant `w<targetWidth>`）→ 原始字节（CBZ 模式 = `ComicArchive.extractImage`，本地）→ `ImagePipeline.decode` → `encodeJPEG` 存 display 池。
- CBZ 整包在打开时已进 original 池（`ReaderContent.comic`），页字节本地抽取，预解码消除的是 CPU 解码段。
- 触发缝已存在：`ReaderViewModel.onPageChanged`（页码落地回调）+ `ReaderCoordinator` 的 open 触发点；注入缝先例：`presentContent` / `submitPrefetch`（lazy closure，生产默认 + 测试替换）。
- 缓存键构造走 `CacheKey.sourceFile` + `CacheKey.displayWidthVariant(targetWidth)`（CacheKit 工厂）。

## Step 列表与 DoD

### Step 1：能力层——`ReaderImageLoader.warm(pageAt:)`

- 改动文件：
  - `Cove/Services/Media/ReaderImageLoader.swift`
  - `Tests/CoveTests/`（新增或并入现有测试文件，按 xcodeproj 显式清单约束选择；新文件需 `make generate`）
- 内容：
  1. `warm(pageAt:)`：display 池已有该页 `displayWidthVariant` 变体则直接返回（判定用 `cache.data(forKey:)` 或 CacheStore 现有的存在性 API——若没有只读存在性检查，用 data(forKey:) 即可，注意它的 LRU 刷新副作用可接受）；否则 `try? load(pageAt:)`。越界 index 安全返回。
  2. 不改 `load` 的任何行为。
- DoD：
  1. 测试：warm 后 display 池出现对应变体（用生产 CacheKey 工厂探测）；已暖页重复 warm 不重复解码（可用注入点或计数手段观察，选最小侵入的）；坏页 warm 不抛错。
  2. `make test` 全绿、`make build` 零警告。

### Step 2：接线——漫画模式的两个触发点

- 改动文件：
  - `Cove/Features/Reader/Coordination/ReaderCoordinator.swift`
  - `Tests/CoveTests/ViewModelTests.swift`（或对应测试文件）
- 内容：
  1. `ReaderCoordinator` 加 `warmPages` 注入缝（lazy closure，默认实现持有当前 loader 并 `Task.detached` warm）。loader 在 `present()` 构造，缝的默认实现需要在 present 后拿到它——注意 `presentContent` 缝被测试替换时 loader 不存在，测试替换 `warmPages` 即可。
  2. 漫画模式：`openComic` present 后 warm startIndex+1/+2；`onPageChanged` 回调里目录模式走 `prefetchFollowing`、漫画模式走 warm（两个触发点、两条路径，在 coordinator 一处分叉）。
  3. 目录模式不得触发 warm（display 池变体的构建依赖网络原始字节已被预取覆盖，warm 会重复下载——这是行为约束，测试要钉住）。
- DoD：
  1. 测试：CBZ 打开后 warm 记录了 +1/+2 页；翻页回调触发 warm；目录模式不触发 warm；末尾不足 2 页只 warm 存在的。
  2. `make generate && make build` 零警告、`make test` 全绿。
  3. 人工检查点（用户）：打开一个**未读过**的 CBZ，快速连翻数页，翻页无明显解码停顿；日志可见 warm 发生。

## 风险与回滚点

- warm 与正式 load 并发同一页：两条路径都会算同一个 displayKey，CacheStore 的 Mutex 保证写安全，最坏结果是重复解码一次——可接受。
- 陈旧 warm（翻页快于解码）写进缓存无害。
- 回滚：Step 2 单独 revert 即功能消失，Step 1 的 API 无害残留。

## 验证命令

```sh
make test                    # 全量回归
make generate && make build  # 零警告
```

## Review 交接

提审按 WORKFLOW.md §5.2 Review Package：Step 编号、改动文件列表、关键 diff 摘要、自测命令与结果、已知风险。每个 Step 单独提审。
