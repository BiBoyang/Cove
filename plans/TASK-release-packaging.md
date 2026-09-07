# TASK: GitHub Release 分发（Developer ID 签名 + 公证 + dmg）

日期：2026-09-08 ｜ 协作模式（用户实现 + 助手规划/Review，协议 WORKFLOW.md）
上游：plans/BACKLOG.md 上架前必须（DEVELOPMENT_TEAM 条目并入本卡）+
「收尾并发布」全局链路（打 tag 触发本卡产物）

## 目标复述

让其他人能从 GitHub Releases 下载到**签名 + 公证过**的 Cove dmg：tag
`v*` 触发 CI 全自动——构建自清洁森林、Release 构建、Developer ID 签名、
notarytool 公证、staple、打 dmg、自动 release notes 发版。

## 决策记录（已拍板 2026-09-08）

- 架构：**B1 CI 全托管**（B2 本地签名兜底否决）。
- 包形态：**dmg**（用户有付费开发者账号）。
- Release notes：git log 自动生成先行（`gh release create
  --generate-notes`），以后嫌糙再换手写模板。
- Team ID 不入仓：CI 侧 `xcodebuild DEVELOPMENT_TEAM=$APPLE_TEAM_ID`
  注入；本地开发构建保持 ad-hoc 不变。
- secrets（用户已配置）：DEVELOPER_ID_CERT_P12_BASE64 /
  DEVELOPER_ID_CERT_PASSWORD / APPLE_TEAM_ID / ASC_KEY_ID /
  ASC_ISSUER_ID / ASC_KEY_P8。

## 关键技术点（实施时逐条落地）

- **森林构建**：CI 先跑 `scripts/build-libmpv.sh`（约 6 分钟；可加
  actions/cache 缓存产物，key=脚本 hash）。CI runner 是标准 macOS，
  不需要 HOMEBREW_FAKE_MACOS。
- **证书导入**：建临时 keychain → 导入 p12 → 设为搜索列表首位 →
  unlock；job 结束删除。
- **签名切换**：postBuild「Embed libmpv dylibs」脚本目前硬编码
  ad-hoc（`codesign --force --sign -`）——需改为跟随构建身份
  （如 `$EXPANDED_CODE_SIGN_IDENTITY`，为 `-` 时保持 ad-hoc 且不加
  runtime 选项；Developer ID 时加 `--options runtime --timestamp`）。
  公证要求 hardened runtime（`ENABLE_HARDENED_RUNTIME=YES`）+ 所有
  二进制同身份签名 + secure timestamp。
- **公证**：`xcrun notarytool submit --wait`（API key 三条 secrets）
  → `xcrun stapler staple`。
- **dmg**：暂存目录放 .app + /Applications 软链，hdiutil 制作。
- **版本号**：tag 注入（`MARKETING_VERSION`/`CURRENT_PROJECT_VERSION`
  从 tag 推导），不手改 project.yml。

## Step 列表与 DoD

### Step 1 release 工作流落地
- 新增 .github/workflows/release.yml + project.yml 必要调整 +
  embed 脚本签名切换。
- DoD：workflow 语法/逻辑静态核验；`make generate` + `make build` +
  `make test` 本地全绿（不破坏开发态构建）；文档（README 下载段 +
  AGENTS.md 发布段）同步。

### Step 2 端到端验证（用户配合）
- 打一个测试 tag（如 v0.6.0-rc1）触发全流程；下载产出的 dmg 到本机
  双击验证（Gatekeeper 放行、公证 staple 生效 `spctl -a -vvv` /
  `stapler validate`）。通过后删测试 release/tag 或转正。
- DoD：真机验收清单全过——下载的 dmg 双击打开无"已损坏"、App 正常
  启动、签名信息为用户身份。

## 风险与回滚点

- 签名/公证是外部服务，失败重试与清晰报错写进 workflow；
  notarytool 排队耗时时长不定（通常几分钟）。
- 测试 tag 触发的 release 是公开可见的——用 prerelease 标记。
- 回滚 = 删 workflow 文件；不改任何 App 代码。

## 验证

- Step 1：本地三件套绿 + workflow 文件静态检查。
- Step 2：真机验收（下载 dmg 全链路），以用户验收通过为闭环。
