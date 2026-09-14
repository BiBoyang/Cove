# TASK-subtitle-clearance：控制条可见时字幕自动抬升

状态：**landed 2026-09-14**（356/55 全绿、构建零警告、Review Approved；
真机验收通过：控制条常亮时字幕抬升不被遮挡、隐藏后回落原位）。

## Amendment 1（2026-09-14，Planner 追认）

白名单第 4 条文件名笔误：PlayerViewModelTests 实际位于
`Tests/CoveTests/PlayerViewModelTests.swift`（`ViewModelTests.swift` 零播放器
内容，rg 实证），Executor 按括注语义执行正确，予以追认，契约以本条文为准。
基线实测：本森林 mpv 默认 `sub-margin-y` = 34（非 0，验证「禁写死」必要性）。

## 背景与定性

2026-09-14 真机复测 GBK 字幕时 Owner 亲历：字幕正常渲染但完全看不见——
悬浮控制胶囊遮挡了画面底部，而字幕默认渲染位置正是画面底部。影响所有
底部字幕（外挂/内嵌通吃）。行业标准解法（IINA/Infuse/QuickTime）：
控制条可见 → 字幕渲染区整体上移让出控制条；隐藏 → 回落。本卡只做
这一条路线；「可拖动控制条」「手动隐藏」经 Plan Card 拍板**不做**
（前者把系统责任推给用户且默认位置仍挡字幕，后者被 2.5s 自动隐藏覆盖）。

## 机制（Planner 已侦察实证）

- mpv `sub-margin-y` 运行时属性可写（libass 下一帧重排，无需重载）。
  代码库当前零使用（rg 实证）。**基线值未知**（mpv 0.41 默认可能非 0），
  实现必须先 `get_property` 读基线，抬升 = 基线 + clearance，回落 = 恢复
  基线，禁止写死 0。
- 引擎通路：`PlayerPlaybackControlling` 协议（PlayerViewModel.swift
  顶部），测试用 recorder 假桩；`captureCurrentFrame` 的 protocol
  extension 默认实现是新增可选能力的先例，照此办理。
- mpv 写入：MPVPlayerCore 已有 `"set"` 命令助手（注释："The command is
  'set', not 'set_property'"），`command(["set", "sub-margin-y", v])`。
- 显隐状态：PlayerViewModel.controlsVisible 单一事实源（338 行亮、
  374 行灭），onChange 渲染。
- 胶囊几何：底锚定，距窗口底 `CoveStyle.space16`，内容 shrink-wrap
  （高度随内容变：codec chips 行/音频壳）。**不许在 VM 里写死高度**——
  由 PlayerWindowController 在布局时量「胶囊顶边到窗口内容底边的距离」，
  以纯 Double 喂给 VM（AppKit 类型不进 VM，Double 可以）。

## 方案（Decisions，Executor 照做）

1. **协议扩展**：`PlayerPlaybackControlling` 增
   `setSubtitleBottomMargin(_ points: Int)`（命名可微调，语义不变），
   protocol extension 默认 no-op（旧 fake 零改动编译）。
2. **VM 逻辑**：新增 `subtitleClearance: Double` 输入属性（controller
   喂）+ 内部 `subtitleMarginBaseline: Int`（会话初从 core 读回）。
   应用规则：controlsVisible=true → margin = baseline + ceil(clearance)
   + 8（gap 常量，注释说明）；false → baseline。应用时机收敛到单一
    choke point（controlsVisible 赋值处与 clearance 更新处），同一值
   不重复下发（记录 lastApplied 去重）。
3. **Core 实现**：MPVPlayerCore.setSubtitleBottomMargin 走既有 "set"
   命令助手；init 后或首个 file-loaded 时 get 一次 sub-margin-y 作基线
   （读失败按 0 处理并记 debug 日志）。
4. **View 测量**：PlayerWindowController 在 viewDidLayout（或既有布局
   回调）计算 capsule 顶边 Y（相对窗口内容区底）+ 8 gap 之外的原始
   距离，变化时喂 VM.subtitleClearance。音频壳/chips 变化自然经
   布局回调覆盖，不单独挂钩。
5. **纯 AppKit/严格并发/英文注释中文文案/零新警告**，AGENTS.md 全规矩
   适用。

## DoD

1. VM 单测（recorder 断言）：① visible→下发 baseline+ceil(clearance)+8；
   ② hidden→下发 baseline；③ clearance 变化且 visible→重新下发；
   ④ 同值不重复下发；⑤ 默认 no-op 协议扩展下旧测试不回归。
2. `make generate && make test` 全绿；`make build` 零警告。
3. 真机验收（Owner）：本地仓库 → 字幕夹具 → E → GbkMovie.mkv：
   ① 鼠标轻晃保持控制条常亮 → 字幕（「外挂字幕第一行…」）显示在
   胶囊**上方**，不被遮挡；② 鼠标静止 2.5s → 控制条消失、字幕回落
   画面底部原位；③ 切内嵌轨（如有）/UTF-8 外挂同样生效。回传：
   一句"抬升/回落正常"+ 异常现象描述。
4. 报告附：改动文件清单、基线实测值（get_property 读到的
   sub-margin-y 默认值）、自测结果。

## 硬停止（命中即停手上报，不许越界）

1. `sub-margin-y` 运行时写入不生效（set 后 get 读不回新值，或真机
   画面不动）→ 停，路线需重议（备选 sub-pos / libass 级），报 Planner。
2. 需要改动胶囊布局结构/ControlsCapsuleView 内部 → 停。
3. 白名单外任何文件（含 project.yml、其他特性）→ 停。

## 白名单（绝对路径）

- /Users/boyang/code/Cove/Cove/Features/Player/ViewModels/PlayerViewModel.swift
- /Users/boyang/code/Cove/Cove/Features/Player/Views/PlayerWindowController.swift
- /Users/boyang/code/Cove/Cove/Services/Media/MPVPlayerCore.swift
- /Users/boyang/code/Cove/Tests/CoveTests/ViewModelTests.swift
  （PlayerViewModelTests 所在文件；如确需新测试文件须报告中说明并
  `make generate`，xcodegen 目录 glob 通常无需动 project.yml）
