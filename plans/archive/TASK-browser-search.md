# TASK: Browser name filter (search, 1.0 batch 1)

- Status: landed 2026-09-12（make test 255 全绿；Review Approved；真机 8 步 Owner 验收通过）
- Created: 2026-09-12
- Roadmap: plans/ROADMAP-1.0.md A3

## Goal
浏览器当前目录按名称过滤，纯本地、零网络成本。share 与 vault 同一条
浏览器管线，一处实现两处生效。

## Decisions（Plan Card 拍板，Executor 照做）
1. **过滤位置：VM 层**。`BrowserViewModel.State` 新增 `filterQuery`
   （默认 ""）；`displayedItems` 为计算属性，= 静态纯函数
   `filterItems(_:query:)` 作用于 `items` 的结果。`state.items`
   保持完整目录清单不变；`setFilter(_:)` 更新 query 并推 state。
2. **导航即清零**：`beginLoading` / `display` 构造 State 时
   filterQuery 一律 ""——下钻、返回上级、回 share 网格、切目的地
   （share↔vault）都经这两个入口，清零不变量在 VM 层可测。
3. **播放列表不受过滤影响**：`imageItems` / `videoItems` /
   `item(atPath:)` 继续基于完整 `state.items`。过滤只是视图层缩小
   范围；打开文件后的翻页/连播范围与现状一致（语义变更留待未来
   单独拍板）。
4. **匹配语义**：大小写不敏感 + 变音符不敏感的「包含」（folding
   case + diacritic insensitive）；query 去首尾空白，纯空白 query
   = 不过滤；只过滤不重排（保持 visibleItems 现有排序）。
5. **工具条形态：常驻搜索框**。trailing 定宽 200 的 NSSearchField，
   位于 downloadLabel 簇与面包屑之间；不用图标折叠方案（窗口
   minSize 900pt 够放，折叠徒增状态机）。download 进度出现时
   downloadLabel（≤320 截断）与搜索框共存，面包屑让位（已有
   中间截断 + 低 hugging）。
6. **⌘F 接线**：手工菜单「编辑」加「查找…」⌘F，target=nil 走
   responder chain；BrowserViewController 实现对应 action 使搜索框
   成为 first responder（浏览器不在屏时菜单项自动置灰不可用）。
7. **焦点规矩**：输入即过滤（sendsSearchStringImmediately）；
   Esc = 清空 query 并把焦点还给表格（query 已空则只还焦点）；
   回车 = 焦点还给表格。VM→field 反向同步只在文本不同时写入
   （防光标跳尾）。
8. **占位优先级**：isLoading > 无匹配（query 非空且 displayed 空
   且原始列表非空）> 空文件夹 > 无。无匹配空态复用
   StatePlaceholderView：symbol "magnifyingglass" + 标题
   「无匹配结果」+ 说明「没有名称包含「<query>」的条目。」
   （设计令牌 §6.1 配方，禁止裸底零提示）。
9. **计数**：query 非空时搜索框左侧显示 caption 级「3/12」
   （匹配数/原始总数），query 为空隐藏。

## Scope
- VM：State.filterQuery + displayedItems + setFilter + 静态
  filterItems + 导航清零。
- VC：工具条搜索框 + 计数标签；表格数据源 / handleDoubleClick /
  revealItem / 右键菜单改用 displayedItems；占位逻辑扩无匹配分支；
  ⌘F action + Esc/回车焦点行为。
- AppDelegate：编辑菜单加「查找…」（⌘F，target=nil responder chain）。
- 测试：filterItems 纯函数用例 + VM 行为用例（入既有
  ViewModelTests.swift，不新建文件）。
- README Features 区补一行——提交阶段由 Planner/Owner 同步，
  不在 Executor 范围。

## Out of scope
递归/全盘/内容搜索与索引；播放列表随过滤变化的语义；图标折叠式
搜索框；share 网格卡片过滤；其它 1.0 卡（空态清扫/检查更新/字幕
等）。

## Steps
1. VM 层：State 扩 filterQuery + displayedItems + setFilter + 静态
   filterItems + beginLoading/display 清零；单测随步落地。
2. VC + 菜单：搜索框、计数标签、displayedItems 全面切换、占位
   优先级、焦点行为、⌘F 接线。
3. 验证：make test 全绿 + 真机验收清单随提审交付。

## DoD
1. filterItems 纯函数测试覆盖：空/纯空白 query 恒等；大小写
   （"MKV" 中 "a.mkv"）；变音符（"cafe" 中 "Café"）；CJK 包含；
   保序；无匹配返回空。
2. VM 测试：setFilter 只动 displayedItems 不动原始 items；
   beginLoading / display 后 query 归零、displayedItems 与原始
   一致；纯空白 query 视为无过滤。
3. `make test` 全绿（八 framework 包 + App target）。
4. 真机（用户验收清单随提审交付）：⌘F 聚焦 → 输入即过滤 →
   计数正确 → 无匹配空态文案 → Esc/清空恢复完整列表 → 进入
   子文件夹后搜索框已清空 → vault 下同样生效 → 下载进行中
   工具条不拥挤错位。
5. 零布局回归：过滤未激活时（搜索框为空）列表与现状一致；
   工具条除新增的常驻搜索框外无位移。

## Risks
- 工具条拥挤（下载中 + 搜索框 + 面包屑）→ 缓解：搜索框定宽 200、
  downloadLabel 已有 ≤320 截断、面包屑让位；真机验收含「下载中
  开过滤」场景。
- ⌘F responder chain 到不了 BrowserViewController（菜单项置灰）
  → 先小步验证 target=nil 链路；若断，回退方案 = MainWindowController
  显式转发（提审时说明理由，不擅自加文件）。
- State 构造点漏传 filterQuery → memberwise 构造编译器强制补参，
  低风险。
- 过滤中同 path 重渲染（下载进度等）→ 列表按同一 query 重算，
  稳定；缩略图 task 随行复用取消，现状机制覆盖。
