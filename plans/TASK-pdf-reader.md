# TASK: PDF 阅读 v1（整包缓存 + PDFKit）

日期：2026-08-24 ｜ 协作模式（主会话规划/Review，另一会话实现）

## 目标复述

浏览器里双击 PDF：整文件经 fileReader 下载进 original 池，`PDFDocument(data:)` 建文档，PDFKit 的 `PDFView` 呈现阅读。再次打开命中缓存秒开。

## 决策记录（已拍板）

- **数据路径 = CBZ 同构**：`originalBytes` 模式（original 池命中则直接用，否则下载后 best-effort 写回），`CacheKey.sourceFile` raw 变体；不做 display 变体、不写临时文件。
- **PDFDocument(data:) 内存建文档**：v1 接受全量入内存（典型文档几十 MB）；超大扫描版的流式化（`PDFDataProvider`）列为后续升级项，接口现在不定型。
- **UI**：新 Feature `PdfReader`（`Features/PdfReader/`：Coordinator + WindowController + 极简 VM）。`PDFView`（AppKit 原生，非 SwiftUI）配置：`displayMode = .singlePageContinuous`、`autoScale = true`、`displaysPageBreaks = true`；窗口黑底、Esc 关闭——与图片/视频阅读器观感一致。
- **加载态**：下载期间显示"加载中…"（VM 状态 loading/ready/failed）；失败（下载失败或 PDFDocument 建不出）经现有 `onError/onMessageError` 链路上报。
- **路由**：`BrowserViewController.handleDoubleClick` 的 `.pdf` 分支从 `onUnsupportedFile` 改为 `onOpenPdf`；`LibraryCoordinator` 新增 `openPdfReader(at:)`，组装走 AppDelegate 既有注入链（cache + makeFileReader）。
- PDFKit 是系统框架，非三方依赖，无需 AGENTS.md 登记。

## Out of Scope

流式按需加载、目录大纲/缩略图侧栏、搜索、批注、打印、多标签。

## 现状摘要

- `ContentItem.FileType.pdf` 分类已存在；`.pdf` 双击当前落入"暂不支持"提示。
- `ReaderContent.originalBytes(...)`（`Cove/Services/Media/ReaderContent.swift`）是整包缓存的现成参照（original 池命中 → fileReader 下载 → 写回）。
- `MainWindowController` 的错误弹窗链路（`onError/onMessageError`）现成。
- 键盘/窗口观感先例：`PagedReaderWindowController`（黑底、Esc、隐藏标题栏）。

## Step 列表与 DoD

单 Step 交付（一个 commit）：

1. `PdfReaderCoordinator`：originalBytes 整包获取 → PDFDocument(data:) → 组装窗口；失败路径上报。
2. `PdfReaderWindowController` + 极简 VM（loading/ready/failed 状态 + 标题）。
3. 浏览器 `.pdf` 路由接入。
4. DoD：
   - VM 测试：loading→ready、下载失败→failed、PDFDocument 建不出→failed；
   - 缓存命中测试：fake fileReader 计数，第二次打开不再下载（参照既有 ReaderContent 测试风格）；
   - `make generate && make build` 零警告、`make test` 全绿；
   - 提审附 Review Package。

## 风险与回滚点

- PDFDocument(data:) 返回 nil 的坏文件：failed 态 + 错误上报，不崩。
- 大文件下载期间无进度显示（v1 接受，只有"加载中…"）。
- 回滚：单 commit revert，`.pdf` 回到"不支持"提示。

## 验证

- 主会话 review + 测试核验。
- 人工检查点（用户）：双击 PDF 打开可滚动/缩放阅读；关掉再开秒开；损坏文件有明确报错。

## Review 交接

按 WORKFLOW.md §5.2 Review Package。
