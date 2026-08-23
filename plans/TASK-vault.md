# TASK: 本地仓库 v1（整包离线下载 + LocalFileSource 虚拟 share）

日期：2026-08-24 ｜ 协作模式（主会话规划/Review，另一会话实现）

## 目标复述

浏览器右键"下载到本地仓库"：文件夹递归整包（或单文件）下载到本地仓库目录，**永不逐出**。本地仓库以虚拟 share 形式出现在侧栏，浏览/阅读/播放体验与 NAS share 一致。

## 语义边界（已拍板）

- **vault ≠ 预热**：预热是缓存（可逐出、为速度），仓库是拷贝（永久、为所有权）。vault 文件**不进** original 池、不受容量/TTL 策略影响、不参与 LRU；但读取路径（LocalFileSource）与缓存键体系互不干涉。
- **收藏是另一条线**，本期不做。
- 无回传/同步到 NAS，无自动更新检测。

## 决策记录（已拍板）

- **入口**：浏览器右键菜单"下载到本地仓库"（目录行和文件行都有；目录=递归整包 BFS，文件=单个）。
- **位置**：默认 `~/Library/Application Support/Cove/Vault/`，用户可在设置页改（NSOpenPanel 选目录；显示当前路径 + "更改…" + "在 Finder 中打开"）。
- **改位置不迁移**：改动只影响新下载；vault 浏览器始终展示**当前配置位置**的内容，旧位置文件留在磁盘上（设置页可"在 Finder 中打开"自行处理）。任务文档里写明，避免误以为丢文件。
- **目录结构**：`<vault>/<host 摘要>/<share>/<原相对路径>`——不同服务器同名 share/文件天然隔离。
- **LocalFileSource**（SourceKit）：FileManager 实现 `list/metadata/read(range:)`，`sourceID = "vault://"`；作为虚拟 share 注入现有浏览管线。
- **侧栏**：服务器分区下加"本地仓库"分区（或固定行），点击 = 打开虚拟 share（复用 `openShare` 链路，ContentSource 换成 LocalFileSource，无需网络）。
- **下载执行**：递归用 `FolderEnumerator.collectImages` 同款 BFS（但**全类型文件**，不只图片）；逐文件 ranged read 写入本地（写临时文件 + rename，避免半截文件）；进度（N/M 文件名）+ 可取消；同一路径重复下载=覆盖式刷新（按 mtime/size 一致的跳过）。
- **删除**：vault 浏览器里右键"从本地仓库删除"（删本地文件，不碰 NAS——文案必须写清）。

## Out of Scope

收藏/置顶、NAS 回传、同步/更新检测、下载队列的持久化与断点续传、多选批量下载。

## 现状摘要

- `ContentSource` 协议三件套 + `SMBReadRouter` 的注入链路现成——`LibraryCoordinator` 只需支持"非 SMB 的 ContentSource"接入浏览。
- `FolderEnumerator.collectImages`（BFS）在 PreheatKit，其递归枚举模式可参照（本任务要全类型不过滤图片）。
- 设置页（Preferences）已有 SettingsService + 表单先例。
- 右键菜单先例：服务器行的"删除"（NSTableView.menu + validateMenuItem）。

## Step 列表与 DoD

### Step 1：LocalFileSource + 下载服务

- `Frameworks/SourceKit` 新增 `LocalFileSource`（FileManager 三件套 + ContentItem 映射，噪音过滤沿用 `isNoise`）。
- App 层 `VaultService`：vault 根目录解析（设置读取）、递归/单文件下载（temp+rename、进度、取消、跳过未变更）、删除。
- DoD：LocalFileSource 单测（list/metadata/ranged read/噪音过滤）；VaultService 测试（下载→文件落位正确、覆盖刷新、跳过未变更、取消后无半截文件）；`make test` 全绿。

### Step 2：右键入口 + 侧栏虚拟 share + 设置页位置项

- 浏览器右键"下载到本地仓库"；侧栏"本地仓库"入口打开 LocalFileSource 浏览；vault 内右键"从本地仓库删除"。
- 设置页加 vault 位置行（当前路径 + 更改 + 在 Finder 打开）。
- DoD：VM/接线层测试（右键动作触发下载、删除不碰源）；`make generate && make build` 零警告；人工检查点（用户）：下载一个文件夹→断网/退出重开→本地仓库里完整浏览播放。

## 风险与回滚点

- **全类型递归下载**可能比图片预热慢/大：进度可见 + 可取消即可，v1 不做限速。
- 下载中断的半截文件：temp+rename 保证原子性。
- 改 vault 位置后的"旧文件不可见"：在设置页该行的说明文案里写明，不静默。
- 回滚：Step 2 revert 即功能消失，Step 1 能力无害残留。

## Review 交接

按 WORKFLOW.md §5.2 Review Package，每 Step 单独提审。
