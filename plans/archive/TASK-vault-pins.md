# TASK: Pin vault folders to the sidebar (vault quick-access pins)

- Status: PROMPT ready, pending Owner gate
- Created: 2026-09-12
- Slug: vault-pins
- Depends on: TASK-sidebar-bottom-bar (archived; bottom bar shipped)

## Goal
Pin up to 8 vault subfolders as quick-access rows in the sidebar bottom
bar, between 本地仓库 and 设置. Pins store vault-relative paths (immune
to vault-root moves) plus an optional user alias; they are never
auto-removed (a missing folder greys out until manually unpinned).
Named 固定 (pin) — explicitly not "收藏", reserved for a future content
favorites system (decided 2026-09-12).

## Decisions (2026-09-12 discussion, all Owner-confirmed)
1. 重名/辨认：行 tooltip 显示完整路径（A）；另加**别名**——pin 行右键
   「设置别名…」弹输入框（预填当前名；清空 = 恢复文件夹本名）。显示名
   = alias ?? 文件夹名；tooltip 永远显真实路径。
2. pin 行图标：白色 folder（中性），金色只留仓库根本体。
3. 对称菜单：浏览器里已 pin 的文件夹右键显示「从侧栏移除」；未 pin
   显示「固定到侧栏」。侧栏 pin 行右键：「设置别名…」+「从侧栏移除」。
4. 失效检测时机：启动 / pin 增删 / vault 根变更 / 每次进入本地仓库
   时各 stat 一次（≤8 个本地路径，零成本）。失效置灰不删、不响应
   单击、仍可右键操作。
5. 点 pin = 普通下钻：返回键一级级往 vault 根走，不做"回到进来前"。
6. cap 8：满时点「固定到侧栏」弹 alert「最多固定 8 个文件夹」；
   移除不需确认；红线=任何路径都不删用户文件。
7. 存储 plist 形态：有序 [{path, alias?}]（无已发布版本，无需迁移）。

## Changes（文件面见 PROMPT）
1. `VaultPins` 纯值 + `VaultPinStore` UserDefaults 壳（注入 suite，
   仿 ShareOpenStore）：有序、去重、cap 8、别名设置/清除、plist 往返。
2. Browser vault 模式：`ContextMenuIntent` 对称 pin 分支（纯函数扩参
   传入 pins 状态），动作闭包转发协调器。
3. SidebarBottomBar：pin 行区（setPins API；行=白 folder 图标 +
   显示名 + tooltip 全路径；单击 onOpenPin；右键两菜单项；置灰态）。
4. ServerListViewModel：pins 状态 + 回调（无 AppKit 类型）。
5. LibraryCoordinator：持有 store；增删/别名 → 持久化+推送；
   openVaultFolder 下钻；按第 4 点时机刷存在性；cap alert。
6. VaultService：pin 目标存在性判定（解析根+相对路径 stat）。
7. 测试：纯值（cap/dedupe/order/alias/plist 往返）、壳隔离 suite、
   intent 对称分支、VM pins。

## DoD
1. pin 重启仍在；vault 根迁移不受影响；别名重启仍在、清空即恢复本名。
2. cap 8 强制 + alert 文案如上；移除/别名操作都不碰磁盘文件。
3. 目标被改名/删除 → 置灰保留，仅手动移除。
4. 单击 pin 直达子目录，返回栈与手动下钻一致。
5. build/test 全绿、零新警告；UI 中文、注释英文；无 SwiftUI；
   SnapKit 只在 Views；VM 无 AppKit 类型。

## 真机验收清单（用户，提审时随 Review Package 展开）
- 固定两个文件夹（其中一个改名别名）→ 重启 → 行在、别名在；
  单击直达；返回逐级回根。
- 悬停 pin 行 → tooltip 显完整路径。
- Finder 改名其中一个目标 → 置灰不消失；右键「从侧栏移除」→ 消失；
  磁盘内容全程不动。
- 浏览器里右键已 pin 文件夹 → 「从侧栏移除」可摘；右键未 pin →
  「固定到侧栏」可加；满 8 个再固定 → alert。
- 旧位置/新位置迁移 vault 根（设置页更改）→ pin 仍有效。
