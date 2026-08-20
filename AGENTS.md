# Cove 架构与分层规矩

## 项目结构

```
Cove/                    # App target（纯 AppKit，禁止 import SwiftUI，不用 storyboard）
├── Application/         # main.swift + AppDelegate，手动接线
├── Services/            # 服务器配置持久化 + SMB 会话生命周期
├── Interface/           # 窗口与视图控制器
└── Resources/           # Info.plist、sandbox entitlements
Frameworks/              # 本地 SPM 包
├── TraceKit/            # os_log 薄封装（零依赖）
├── KeychainKit/         # SecItem 薄封装（零依赖）
└── SourceKit/           # ContentSource 协议 + SMBSource + smb-spike 命令行工具
```

## 依赖方向

`Application → Interface → Services → Frameworks/*`，禁止反向依赖。

## 硬性规矩

1. **AMSMB2 只允许在 `Frameworks/SourceKit` 包内 import**（含其中的 smb-spike
   target）。App target 和其他 Framework 一律不许碰。
2. View Controller 不许直接碰网络层，一律走 `SMBSessionService`。
3. 禁止 `import SwiftUI`，界面全部用 AppKit 手写。
4. 密码只进 Keychain；`UserDefaults` 只存地址 / 共享名 / 用户名。
5. 代码注释与标识符用英文；UI 文案用中文。
6. `project.yml` 是工程的唯一事实来源：改完后跑 `make generate` 重新生成，
   `*.xcodeproj` 不入库（已在 .gitignore）。
7. Frameworks 下的包保持小而专一；新增依赖（尤其是三方库）先在 AGENTS.md
   登记用途再引入。

## 常用命令

```sh
make generate   # xcodegen 生成工程
make build      # Debug 构建
make test       # 三个 Framework 包的单测 + smb-spike 编译检查
make clean
```

## 当前签名状态

开发期：`CODE_SIGN_STYLE=Automatic` + 空 `DEVELOPMENT_TEAM`（即 Sign to Run
Locally）。上架前需要在 `project.yml` 里填自己的 Team ID，并替换占位
bundle id `com.biboyang.cove`。
