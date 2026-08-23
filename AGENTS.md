# Cove 架构与分层规矩

## 项目结构

```
Cove/                    # App target（纯 AppKit，禁止 import SwiftUI，不用 storyboard）
├── Application/         # main.swift + AppDelegate，手动接线
├── Features/            # 按功能组织的 AppKit View + @MainActor ViewModel
├── Services/            # App 服务适配层，按 Infrastructure/Media/Preheat/Settings 分组
│   ├── Infrastructure/  # SMB 会话 + 服务器配置持久化
│   ├── Media/           # 缓存、缩略图、Reader 内容与图片加载适配
│   ├── Vault/           # 本地仓库：根目录解析、递归/单文件下载（temp+rename）、本地删除
│   ├── Preheat/         # 用户配置的后台预热生命周期
│   └── Settings/        # UserDefaults 设置
├── SharedUI/            # 跨 Feature 复用的 AppKit 组件
└── Resources/           # Info.plist、sandbox entitlements
Frameworks/              # 本地 SPM 包
├── TraceKit/            # os_log 薄封装（零依赖）
├── KeychainKit/         # SecItem 薄封装（零依赖）
├── SourceKit/           # ContentSource 协议（list/metadata/ranged read）+ SMBSource（share 级会话，actor）+ LocalFileSource（本地目录 ContentSource，vault 虚拟 share 用）+ SMBServer（共享枚举）+ NaturalSort（共享自然排序）+ smb-spike 命令行工具
├── ImagePipeline/       # 图片解码 + 按需降采样（ImageIO/CGImageSource 薄封装，零三方依赖）
├── CacheKit/            # 磁盘双池缓存（original/display）+ LRU + TTL，容量/TTL 可运行时调整（仅依赖本地 TraceKit 与系统框架 CryptoKit，零三方依赖）
├── PreheatKit/          # 预热调度器：优先级队列 + 令牌桶限速 + 文件夹 BFS 枚举（依赖 SourceKit/CacheKit/ImagePipeline/TraceKit）
├── ComicKit/            # CBZ 漫画包：内存 ZIP 解析 + 图片 entry 过滤/自然排序 + 线程安全抽取（依赖 SourceKit + ZIPFoundation）
└── ReaderKit/            # Reader 领域核心：有序页面模型 + 原始页数据源协议（仅依赖 Foundation）
```

## 依赖方向

`Application → Features → Services → Frameworks/*`，禁止反向依赖。

ReaderKit 是 Frameworks 下的领域核心包，不依赖 AppKit、SnapKit、SMB、ZIP 或缓存实现；目录/CBZ/缓存适配器由 App target 的 Services 层提供。

## 硬性规矩

1. **AMSMB2 只允许在 `Frameworks/SourceKit` 包内 import**（含其中的 smb-spike
   target）。App target 和其他 Framework 一律不许碰。
2. **ZIPFoundation 只允许在 `Frameworks/ComicKit` 包内 import**（CBZ/ZIP 解析；
   ComicKitTests 可用它构建测试包）。App target 和其他 Framework 一律不许碰。
3. View Controller 不许直接碰网络层，一律走 `SMBSessionService`。
4. 禁止 `import SwiftUI`，界面全部用 AppKit 手写。
5. 密码只进 Keychain；`UserDefaults` 只存地址 / 用户名 / 显示名 / 设置项。
   密码、Token、真实 NAS 凭据不得写入源码、测试数据、日志、截图或 Git
   提交记录；smb-spike 的命令行密码参数仅用于开发期连通性探针，不是
   安全存储方案。
6. 代码注释与标识符用英文；UI 文案用中文。
7. `project.yml` 是工程的唯一事实来源：改完后跑 `make generate` 重新生成，
   `*.xcodeproj` 不入库（已在 .gitignore）。
8. Frameworks 下的包保持小而专一；新增依赖（尤其是三方库）先在 AGENTS.md
   登记用途再引入。已登记三方库：SnapKit（App target 布局 DSL）、AMSMB2
   （SourceKit SMB 客户端）、ZIPFoundation（ComicKit CBZ 解析）、libmpv
   （视频播放引擎，Vendor/libmpv dylib 随包嵌入 App target；Vendor/libmpv
   不入库，由 `scripts/assemble-libmpv.sh` 从本机 IINA.app 装配，获取方式
   与选型理由见 `plans/SPIKE-video-playback.md`）。
9. 日志隐私：TraceKit 插值默认 `.auto`（持久化日志里打码）；host/share/path
   等用户数据显式传 `.private`；`.public` 只给确定安全的内容。任何 API 都
   不许记密码。
10. App target 开 `SWIFT_STRICT_CONCURRENCY: complete`：新增代码必须零警告，
    不许用 `nonisolated(unsafe)` 糊并发问题。
11. 布局约束统一用 SnapKit DSL（`snp.makeConstraints`），仅限 App target 的
    Features View / SharedUI 层；ViewModel、Services 和 Frameworks
    不引入 SnapKit。
12. MVVM 边界：View / WindowController 只负责 AppKit 渲染、SnapKit 布局和输入转发；
    `@MainActor` ViewModel 负责 UI 会话状态与任务生命周期；缓存、解码、SMB、ZIP
    等具体能力由 Services/Frameworks 注入，不得重新塞回 View。
    例外：cell 复用驱动的加载/取消（如缩略图 task 随行复用创建与取消）属于
    View 生命周期职责，可留在 View。
13. Feature Coordinator 负责跨层组装与窗口生命周期。`MainWindowController` 只调用
    Feature Coordinator 的意图接口，不直接构造该 Feature 的 Content/Loader/ViewModel/View。
14. `SharedUI` 只收纳至少被两个 Feature 使用的 AppKit 组件；Feature 私有 View 留在
    自己的 `Features/<Name>/Views`，禁止把不确定归属的 UI 默认塞进 SharedUI。
15. App target 的行为测试统一放在 `Tests/CoveTests`，优先使用 Swift Testing；
    仅 UI automation / XCTest-only 场景保留 XCTest。每次跨 actor 状态重构至少覆盖
    边界状态、取消或陈旧结果中的一个真实可观察行为。

## 常用命令

```sh
make generate   # xcodegen 生成工程
make build      # Debug 构建
make test       # 七个 Framework 包的单测 + smb-spike 编译检查
make clean
```

## 文档分工与协作纪律

- `README.md`：项目定位、功能范围、环境要求、构建与使用说明。
- `AGENTS.md`（本文件）：实现者与 AI agent 必须遵守的架构边界与操作规约。
- `plans/`：任务拆解（TASK-*.md）、设计/选型报告（SPIKE-*、审计）与
  全量待办索引（`BACKLOG.md`）——入库，对贡献者可见。
- `sessions/`：AI 协作过程日志，**本地专用、不入库**（已 gitignore）。

协作纪律：**任何会话开工前先跑 `pwd && git rev-parse --show-toplevel &&
git log --oneline -1`，确认自己在正确的工作树上**——本机曾经存在一份
过期克隆并导致过基于旧代码的错误修改。

## 当前签名状态

开发期：`CODE_SIGN_STYLE=Automatic` + 空 `DEVELOPMENT_TEAM`（即 Sign to Run
Locally）。上架前需要在 `project.yml` 里填自己的 Team ID，并替换占位
bundle id `com.biboyang.cove`。
