# CompileErrorTerminal (CETerm) 设计文档

> 版本:v2 —— **已实现部分逐条核对过 `src/`**;尚未实现的能力在标题上标注 **【规划】**
> 定位:CETerm 是一个**拓展性的终端应用管理器(exterminal)**

**文档地图**

| 文档 | 内容 | 与本文的关系 |
|---|---|---|
| `DESIGN.md`(本文) | 架构 / 数据结构 / 接口分层 | — |
| `SCRIPT.md` | 命令与配置脚本语言 | **命令全集的唯一文档真相源**(由 `COMMAND_SPECS` 导出) |
| `OSC.md` | 已实现的全部 OSC 号码 | 扩展序列总览 |
| `OSC999.md` | 子进程命令信道协议 | OSC 999 的协议规范 |
| `CODING_STYLE.md` | 编码规范全文(DOD) | 本文 §7 指向它 |
| `DEBUG_SUMMARY.md` | 性能测量与结论 | — |
| `DIRTY_TRACKING_REVIEW.md` | 脏标记复盘 | 每帧常数开销 / 字段级写者清单 |

---

## 1. 定位与愿景

- CETerm 不是"终端模拟器",而是**终端应用管理器**:每个窗口承载一个终端应用,并为其提供管理工具与应用间协作能力。
- 终端应用 = **ConPTY 子进程**(shell / neovim / agent 工具等),通过 ConPTY 管道与 CETerm 交流——不引入其他通信抽象。
- 超文本内容(数学公式 / GIF / 视频 / UI 控件)是未来能力,通过**扩展 ANSI 转义序列**实现;当前只做文本渲染。

## 2. 概念模型

```
Window(leaf 节点)= 一个 App = 一个 ConPTY 子进程
  ├─ console:渲染子进程输出(conpty pipeline 是唯一交流通道)
  └─ iterm[]:CETerm 内置管理工具(浮层 UI,不是 app,不走 conpty)   ← 【规划】,见 4.2
       └─ 工具通过 CETerm 指令通道控制 app
```

- **window ↔ app 一一对应**:一个 window 一个 conpty 一个 console。
- **iterm = 管理工具【规划】**:控制台、侧边文件树、预览面板、状态栏——CETerm 自己渲染,复用 Console/TermBuffer(conpty_handle = 0 的内部 console)。**当前代码中没有任何 iterm 类型或接口**,详见 4.2 / 5.3。
- **应用间交互 = 指令通道**:文件树 app 通过扩展 ANSI 序列向 CETerm 发送 canvas 接口调用指令(如 focus、send-input),CETerm 解析执行——指令接口面向**需要控制 CETerm 的使用方**(子进程 / 外部工具)。

## 3. 分层架构

```
┌─ 使用方层:悬浮控制台指令(F2 呼出,已实现)/ ConPTY 子进程 OSC 指令(已实现)/ DLL 插件(规划)
├─ 用户接口层:指令语义(5.0,文档见 SCRIPT.md)+ 用户函数族(5.0b)
├─ 适配器层:command parser(指令字符串 → 用户函数;id 世代解析)
├─ 模块接口层:canvas / conpty / font / render 公开函数(操作级,见 5.1)
├─ 数据层:窗口树 / Console / TermBuffer / 会话 / 字体
└─ 渲染层:DrawFrame(终端内容)+ nanovg UI 层(悬浮控制台)
```

- 指令入口与 DLL 插件**并存**:DLL 给编译代码的用户,指令给交互/子进程;两者都落在用户接口(5.0 / 5.0b)上,经适配器翻译到模块接口。
- **模块间通过数据交互,避免回调交叉**;回调只允许出现在"框架 → 使用方"边界(插件契约)。
- 模块依赖是 **DAG**(见 `CODING_STYLE.md` 2.1):`main` 只做编排;`canvas` 不反向依赖 `command`,两者靠 `commandpipe.odin` 的 poll 池单向通信。

### 3.1 canvas 模块文件划分(一类数据 + 其操作 = 一个文件)

`src/canvas/` 共 16 个文件:

| 文件 | 数据类型 | 职责 |
|---|---|---|
| `canvas.odin` | —(模块入口) | 每帧主入口 `Update`:① 树遍历(布局 + 消费各会话输出,Resize 联动 ConPTY)② 会话轮询 ③ 命令信道回读 ④ 选区自愈 ⑤ 鼠标路由 ⑥ 未消费文本路由 |
| `tree.odin` | `WindowTreeNode` / `Transform` / `SplitType` / `FocusDirection` | 树结构操作(分裂/摘除/挂载/重算/焦点/命中)+ `ConsoleUpdateTree` 编排;leaf 节点**直接持 `console_id`**(无 Window 中间层)。**焦点是树状态**;`FocusNeighbor` 方向导航;`nodeAtPoint` / `SplitFrameHit` 命中 |
| `buffer.odin` | `Cell` / `CellStyle` / `Line` / `TermBuffer` / **`ScreenRow`(屏幕行表)** | 内容层生命周期 + **全部写路径**(落格/折行/滚动/擦除/插入/裁剪)+ `review_line` 真值 + **屏幕坐标↔缓冲坐标换算**(表与唯一重算入口 `screenEnsure`) |
| `console.odin` | `Console`(持有 `Parser` / `VtState`) | 窗格内容实体:视口生命周期 + 布局(居中 / `viewportTop` / review 锚定)+ **字体集**(主/粗/斜/粗斜 + 输入名,引用计数持有者)+ 会话(conpty / 缓冲)+ `ensureConsole` / `ConsoleFontVariant` |
| `vtparse.odin` | `Parser` | 移植的 DEC 兼容状态机(Paul Williams / Joshua Haberman,public domain)+ 两处补充(UTF-8 直通;OSC 也接受 BEL 终止)。**纯草稿纸**:不存句柄、无回调、无上下文;`Parse` 是唯一入口 |
| `vt.odin` | `VtState` | VT 语法语义分派(ESC/CSI/SGR/DEC 模式)+ 应答(DSR/DA/DECRQM 写回) |
| `selection.odin` | `Selection` | 文本选区:**buffer 物理 (line, col) 坐标系** + 区间判定/平移/提取/剪贴板动作;内容结构变化经 buffer 写路径通报平移 |
| `mouse.odin` | `SplitDrag` | 鼠标交互状态:分割条拖拽(**独占路由**:active 期间任何鼠标事件归它)+ 系统光标反馈 |
| `keybindings.odin` | —(**鼠标路由**) | ⚠ 文件名叫 keybindings,内容是**鼠标路由**:滚轮 → review、点击 → 聚焦、应用鼠标模式(1000/1002/1003)→ SGR 编码写回。键绑定在 `command/keybindings.odin` |
| `commandbar.odin` | `CommandBar` | 悬浮命令栏(全局单例,输入框画在底部页签条右侧):输入缓冲 + 光标编辑状态 + esc 序列状态机 + 帧尾 `CommandBarReap` 结果回显 |
| `commandpipe.odin` | `CommandPoll` / `CommandEvent` | canvas → command 的**唯一通路**:全局 poll 池;持有者只拿一个 `mem.Handle`,**持有 poll 即"已授权"**(`Console.poll_h`,OSC 信道靠它开关);`CommandPipePending()` 供阻塞主循环判定 |
| `page.odin` | `Page` / `PageMode` | 页数据:每页一棵窗口树(页持根句柄 + 页内焦点 + 显示模式);页签几何/命中(`PageTabRect` / `NewTabRect` / `TabBarHit`);`PageCreate` / `New` / `Destroy` / `Switch` / `Next` / `Prev` + `SetSingleMode` / `ToggleSingleMode` |
| `theme.odin` | `Theme` / `NamedTheme` / `ThemeField` | 命名主题注册表(外部数据 `resource/themes.ceterm`)+ `boot_theme` 启动兜底;颜色引用编码归属(`DEFAULT_COLOR` / `colorRgb` / `colorIndex` / `ResolveColor` / `ansi256ToRgb`);`THEME_FIELDS` 字段名表 + `DefineTheme` / `SetThemeField` / `SetThemeByName` / `GetTheme` / `GetThemeSlot` |
| `ui.odin` | —(UI 定制状态) | UI 字体定制(页签/状态栏/命令栏/FPS 共用),**单例引用计数持有者**;`SetUIFont` / `GetUIFont` / `ResetUIFont`;默认 consola 18 |
| `userapi.odin` | —(用户接口状态) | 窗格/会话/字体/焦点/页/主题域用户接口函数族(id 省略 = 焦点)+ 默认启动配置(`DefaultLaunch`)+ 查询(`ConsoleCount` / `GetSplitFactor` / `GetConsoleInfo`)+ 会话轮询 `PollSessions` |
| `colors.odin` | — | **空占位**(仅 package 声明;颜色引用编码实际在 `theme.odin`) |

### 3.2 command 模块文件划分(动作层)

`src/command/` 共 5 个文件:

| 文件 | 数据类型 | 职责 |
|---|---|---|
| `command/spec.odin` | `CommandSpec` / `ArgKind` | 命令规格表(`COMMAND_SPECS`):名字/别名/参数形态/用法/帮助 —— 解析、校验、错误文本、格式化、help 全部表驱动 |
| `command/command.odin` | `ParsedCommand` / `CommandStringKind` / `ToggleMode` | 解析(`ParseCommandStringEx`,带失败原因)+ 逆变换(`FormatCommand`)+ 唯一解释器(`ExecuteCommand` / `executeString`)+ 子命令槽表 |
| `command/config.odin` | `ConfigStats` | 配置文件 = 命令脚本:入口(用户配置 → 保底配置)+ `load` 就地展开(相对路径按当前文件目录)+ 逐行顺序执行 |
| `command/keybindings.odin` | `Binding` / `KeyMods` / `KeyBindings` | 快捷键绑定表(mods + key → 数据化命令)+ 每帧键消费(`ProcessKeys`)+ 表操作 userapi |
| `command/execute.odin` | `CommandEvent`(canvas) | 命令信道消费(帧内路由):遍历 poll 池 → `executeString` → 结果/失败原因写回事件槽 |

### 3.3 资源根解析(`src/paths/`)

配置文件、主题库、shader 全部相对**资源根**定位(`paths.ResourceRoot()` / `paths.Resource(sub)`),解析顺序:

| 顺序 | 来源 | 场景 |
|---|---|---|
| ① | 环境变量 `CETERM_RESOURCE_DIR` | 显式覆盖(便携布局 / 回归探针) |
| ② | `<exe 目录>/resource` | **发行版**(双击 / 快捷方式 / PATH / Win+R 启动都对) |
| ③ | `<cwd>/resource` | 开发与探针(`odin run` 产出的 exe 在临时目录,只能靠这条回落读到出厂数据) |
| ④ | 兜底 = ② | 不存在也用它:报错信息给出用户看得懂的路径 |

- 解析**只做一次**(首次访问自动解析,幂等;`paths.Init` 在 main 启动时显式调一次让问题尽早暴露)。
- 路径串**零分配**:`ResourceRoot()` 借用定长缓冲,`Resource(sub)` 借用一个共享拼接缓冲(**直到下一次 `Resource` 调用失效**)。
- 依赖只有 `core:os` + `core:sys/windows`,**不挂 SDL**,任何初始化之前都能用。

**随包第三方载荷**(都在资源根下,exe 旁边不留散文件):`conpty/x64/`(新版 OpenConsole,见 `conpty` 命令)、
`freetype/x64/`(`freetype.dll` + `zlib1.dll`,字形 hinting,见 `hinting` 命令)。两者都是**可选载荷**:
缺失时各自退回系统实现 / stb 光栅化,只打一行 stderr。FreeType 的两个文件必须同目录,且加载方式有坑
(`LoadLibraryExW` 的 ALTERED / `LOAD_LIBRARY_SEARCH_*` 标志在本机被代码完整性策略拒掉,报 15700 / 577),
详见 `resource/freetype/README.md` 与 `playground/ftdll/`。

`conpty/x64/` 同理必须**两个文件一起分发**:`conpty.dll` 只是壳,真正的宿主进程是它**自己所在目录**里的
`OpenConsole.exe`(找不到就依次退回 `<同目录>/<arch>/OpenConsole.exe` → `%SystemRoot%\System32\conhost.exe`,
见 WT `src/winconpty/winconpty.cpp:_ConsoleHostPath`)。缺宿主 exe 时 dll **静默**用回装箱 conhost ——
"dll 加载成功"≠"新实现生效",Win10 上曾因此长时间误判(日志说 OpenConsole、实际跑 conhost)。
所以 `initConptyApi` 现在**先查宿主 exe**:不在位就当这份 dll 不可用(回系统实现)并打一行 `⚠`。

## 4. 程序状态(数据结构设计)

### 4.0 主题(配色)数据

参考落地:alacritty(269 索引表 + normal/bright/dim 结构字段)、WT(扁平 20 字段 JSON 配色方案)、kitty(color0-255 展开 + 边框色独立)。CETerm 取三方共识与最小集:

```odin
// src/canvas/theme.odin — 主题数据(唯一写者 = canvas;render 只读)
// 决策:① CellStyle.fg/bg 用引用编码(主题热切换零缓冲污染)
//      ② 256 色固定算法(主题只管 0-15 + 默认)
//      ③ frame_color 从树节点删除,分割条读主题(节点回到纯结构)
//      ④ 主题归 canvas:命名注册表 + theme/theme-set 指令,切换即下一帧生效
Theme :: struct {
    fg, bg         : u32,      // 默认前景/背景(SGR 39/49/0 解析目标)
    cursor         : u32,      // 光标
    ansi           : [16]u32,  // SGR 索引 0..15:0-7 普通,8-15 亮(顺序 = WT/alacritty/kitty)
    frame          : u32,      // 分割条(原树节点 frame_color,主题化后节点回纯结构)
    focus_border   : u32,      // 焦点窗口边框(kitty active_border 对应物)
    fps_bg, fps_fg : u32,      // 右上角 FPS tag(渲染层观测数据)
    tab_bar_bg     : u32,      // 底部页签条背景(非激活区)
    tab_fg         : u32,      // 非激活页签文字
    tab_active_bg  : u32,      // 激活页签底(默认 = 主题 bg:WT 式"背景延伸进激活页签")
    tab_active_fg  : u32,      // 激活页签文字(默认 = 主题 fg)
    tab_hover_bg   : u32,      // 页签悬停底
    selection_bg, selection_fg : u32, // 文本选区底色 / 字形色
}

// CellStyle.fg/bg 颜色引用编码(u32,一键 switch 解码,渲染期 resolve):
//   0x00RRGGBB           直接 RGB(SGR 38;2;r;g;b)
//   0x01xxxxxx(低24 = n) 索引色 n:0-15 → theme.ansi[n];16-255 → 固定 cube/灰度算法
//   0xFFFFFFFF           默认 → theme.fg / theme.bg
// 解析器(SGR)只做语法 → 编码,零主题依赖;ansi256ToRgb 固定公式随编码一起驻 theme.odin。
```

**命名主题注册表(外部数据段)**:`NamedTheme{name, theme}` 槽位数组(`MAX_THEME_SLOTS = 32`)+
`current_theme_h`(当前激活槽,0 = 未激活)+ `boot_theme`(代码内唯一保留的启动兜底色,非可发布主题)。
内置 **24 套配色**是**外部数据** `resource/themes.ceterm`(每主题 30 行 `theme-set "name" <字段> <#RRGGBB>`),
由入口配置首行 `load "themes.ceterm"` 引入 —— 代码里不再有主题常量。
字段名表 `THEME_FIELDS`(`ThemeFieldSpec{name, field, index}`)把字符串字段名映到 `ThemeField` 判别 +
ansi 下标;**零映射**:表里的 `name` 就是 `Theme` 结构体字段名(改字段名 = 改表)。
写者:`SetThemeField(name, field, index, color)`(逐项,名字不存在即建槽,初值 = `boot_theme`)/ `SetThemeByName(name)`(激活)/
`GetTheme()^` 直接改字段(程序化整表改)。**单一真相 = 注册表槽**,改活动主题的字段下一帧即生效。

### 4.1 窗口树节点

```odin
// leaf 节点 = 一个窗格:直接持 console(字体集/会话/视口都在 console 里,无 Window 中间层)
// 内部节点 = 纯分割容器(console_id = 0)
WindowTreeNode :: struct {
    console_id : mem.Handle,     // 仅 leaf:窗格 console;0 = 空窗格
    using transform : Transform, // position_x/y, height/width(像素)
    frame_width : u32,           // 分割条像素宽(颜色读主题 frame)
    parent_id : mem.Handle,      // 0 = 无父(仅根)
    left_son_id : mem.Handle,    // left or up
    right_son_id : mem.Handle,   // right or down
    split_factor : f32,          // 左子树所占空间
    split_type : SplitType,      // UpDown / LeftRight
    is_leaf : bool,
}
```

- 容量 `MAX_TREE_NODE_SLOTS = 2000`(满二叉树下等于窗口上限);`window_tree_nodes` 为全局 GenArray。
- 窗格"存在"判定 = **有 console**(`NodeConsole != nil`):`CreateWindowTreeRoot` / `SplitNewWindow` 建窗格时即建 console(内容容器,字体/会话可选)。
- 关窗 = `DestroyConsole`(字体引用 + 会话 + 缓冲)+ `TreeNodeRemove`;**无 auto_close 开关**(会话结束即关窗,要保留窗格用 `clearc`)。

### 4.2 工具 iterm(锚定定位)【规划,代码中不存在】

> **本类型当前未实现**:`src/` 中没有 `Iterm` / `ToolType` / `TreeNodeAddIterm` 等任何符号。
> 以下是设计记录,不是现状描述。

```odin
ToolType :: enum u8 { Console, FileTree, Preview, StatusBar, Terminal }

// 锚定规则:iterm 系数坐标转化的绝对坐标,永远等于 window 系数坐标转化的绝对坐标
//   window_pos + window_size*window_coord == iterm_pos + iterm_size*iterm_coord
Iterm :: struct {
    tool_type : ToolType,
    console_id : mem.Handle,     // 工具渲染目标(内部 console,conpty_handle = 0)
    layer : u16,                 // 绘制层(小 = 先画)
    width, height : f32,         // 绝对大小(px)
    iterm_ax, iterm_ay : f32,    // iterm 系数坐标(锚点,0..1)
    window_ax, window_ay : f32,  // window 系数坐标(锚点,0..1)
}
```

- 锚定式的意义:**窗口 resize 后工具自动跟随**(系数不变 → 绝对位置按比例重算),不需要额外的"重排工具"趟。
- 工具渲染目标复用 Console(`conpty_handle = 0`),所以渲染层不需要知道"这是工具还是应用"。

### 4.3 Console(内容与渲染目标)

```odin
Console :: struct {
    rows, cols : u16,             // 目标网格尺寸(布局趟真源,每帧由窗口几何重算)
    pty_rows, pty_cols : u16,     // ConPTY 已应用尺寸(尺寸应用趟比较)
    origin_x, origin_y : f32,     // 居中后网格左上角(内容区坐标空间)
    cursor_row, cursor_col : u16, // 指向 active buffer 的物理行

    parser : Parser,              // 输入识别态(草稿纸,见 vtparse.odin)
    vt : VtState,                 // 终端语义态(见 vt.odin)

    poll_h : mem.Handle,          // OSC 命令信道(见 commandpipe.odin);持有 = 已授权
    term_buffer_ids : [MAX_BUFFERS_PER_CONSOLE]mem.Handle, // ids[0] = 主屏
    term_buffer_count : u32,
    active_term_buffer_id : mem.Handle,

    conpty_handle : mem.Handle,   // 0 = 无会话(空窗格 / 工具 console)
    font_id : mem.Handle,         // 字体集(引用计数持有者 = 本结构)
    font_bold, font_italic, font_bold_italic : mem.Handle, // 变体(0 = 合成兜底)
    font_input : string,          // 原始输入名(字号重载 / 继承)
    input_activity_ms : u64,      // 最近输入活动(FeedConsole 唯一写点;render 判"输入期间光标不闪")

    app_title : string,           // 应用侧标题(OSC 0/1/2 唯一写点;OS 窗口标题显示它)
    cwd : string,                 // 该会话最后报告的工作目录(OSC 7;新会话继承)
}
```

- `parser` 与 `vt` 是**两个平级组件**:前者是字节 → 事件的草稿纸(无终端语义),后者是终端状态机;`Parse()` 是 cell 状态的**唯一写者**。
- 字体唯一真相 = **Console.font_id**(渲染/布局/鼠标换算都经 console 取;树节点不存字体副本)。
- 容量:`MAX_CONSOLE_SLOTS = 64`(一个 leaf 窗格恰持一个 console),`MAX_BUFFERS_PER_CONSOLE = 8`,`MAX_TERM_BUFFER_SLOTS = 128`(全局 buffer 槽;每 console 主屏 + 交替屏)。
- `app_title` 与 `Page.title` **互不覆盖**:前者经 OSC 由子进程设置(显示在 OS 窗口标题),后者是页签文字(用户/配置设置)。
- Cell 当前为文本单元(`cp: rune + style + wide`);rich content 未来经扩展 ANSI 序列进入,Cell 届时扩展为内容判别。

### 4.4 焦点状态

```odin
// 每页一份,存在 Page 里(不是全局):
focused : mem.Handle        // 该页聚焦的 leaf 节点;0 = 无
```

- 焦点**属于页**:切页即恢复该页记忆的焦点(`PageSwitch` 无同步动作)。
- 没有"焦点在工具"的概念(`focused_iterm` 从未落地):当前焦点目标恒为窗格。

### 4.5 会话与字体(现状保留)

- `ConptyContext`:hpc / 管道 / 进程信息 / Job Object(进程树跟踪 + KILL_ON_JOB_CLOSE 清理)。
- **会话结束判定 = 双信号取或**:主进程退出(`IsChildAlive`,GetExitCodeProcess)+ 读线程 dead(管道断开)。只信读线程会漏 `cmd exit`(conhost 保活管道写端,ReadFile 永不 EOF);只信 Job 会误杀脱离 Job 的 msys2(`JobActiveProcesses` 恒 0,**该函数已不存在**)。
- `Font`:faces / GSUB / 图集 / shape 缓存;引用计数持有者 = 各窗格 `Console`(`RetainFont` / `ReleaseFont`,归零的槽留待 `Alloc` 复用)。
- **字形采样链路(唯一路径)**:字体文件 → `Face`(每 Font 至多 2 面:主字体 + 中文 fallback)→ **光栅化** → `GlyphSlot`(哈希缓存)→ 图集字节 → GL 纹理 → quad(1:1)→ 混合上屏。分层原则:
  - **度量与位图分离**:`cell_width/cell_height/ascent/advance/underline` 一律取自 stb(与 WT 公式同源、与 FontSet 的 em 对齐一致);FreeType **只负责"这张位图长什么样"**。换后端不会移动布局。
  - **两个光栅化后端**,运行时由 `hinting` 决定:`Hinting.Stb`(stb_truetype,无 hinting)/ `.Off` / `.Light` / `.Normal`(FreeType,默认)。FreeType 载荷缺失 → 自动退回 stb,只打一行 stderr。
  - **stb 现在不是"光栅化后端",而是度量/字形身份层**(别把它当历史包袱删掉):cell 高与基线公式、em 对齐、advance、下划线/删除线、家族名解析、cmap→gid(`FindGlyphIndex`,连体/shape 缓存/gid 槽的键空间)、sfnt/TTC 目录定位(`GetFontOffsetForIndex`,gsub.odin 也借它)全部来自 stb;光栅化只剩 `glyphPending` 里的一个分支。**FreeType 替代不了 GSUB**(它没有 OpenType 布局引擎,连体是我们自己解析原始字节),而且 stb 是零依赖兜底:载荷缺失/架构不符/被杀软隔离时仍能显示文字。
  - **先出位图、再分配图集**:`glyphPending`(后端 → `Font.raster_scratch` 紧凑位图)→ `atlasAlloc`(按**实际**位图尺寸 + 2px pad)→ `atlasWrite`(逐行拷入 + 裁到 cell + 算 UV)。尺寸必须来自后端:hinting 会改变位图盒,按 outline 盒预分配会越界。
  - **图集**:单通道 R8,行式分配(`cur_x/cur_y/row_height`),满则 `atlasGrow` 尺寸翻倍并**重新光栅化**全部缓存字形(因此重放必须走 `glyphPending`,不能拿裁剪后的 `slot.w/h` 当盒——否则框线类竖高字形错位);`ATLAS_PAD = 1` 防线性采样串色。
  - **上屏是 1:1 的**:`writeQuad` 把顶点四舍五入到整数像素,quad 尺寸 = 位图尺寸,UV 对准图集内容区 ⇒ LINEAR 采样正好落在纹素中心,**GPU 不做重采样**。所以屏幕质量 = CPU 位图质量,调 GPU 侧(MSAA/滤波)无效。窗口尺寸取 `GetWindowSizeInPixels`(物理像素,不受 DPI 缩放)。
  - **混合**:`main.frag` 用 DirectWrite 同源的 gamma 校正 + 对比度增强(`ENHANCED_CONTRAST = 0.5`,与 WT 的 `DWrite_GrayscaleBlend` 对齐);对 alpha=1 的矩形是恒等,只作用于字形覆盖率。
  - 光栅化参数变化(切 `hinting`)后 `InvalidateGlyphCaches()` 清缓存 + 复位图集分配游标,下一帧按新参数重新光栅化。
- `Theme`:canvas 数据(唯一写者;见 4.0),渲染层每帧 `GetTheme` 只读消费。
- `session_cwd`:配置默认工作目录(命令 `cwd` 写);真正的目录记忆在**各** `Console.cwd`——全局单值会被 shell 每次提示符的 OSC 7 上报打回原形。

### 4.6 页(Page,每页一棵窗口树)

```odin
// src/canvas/page.odin — 页数据(分页后根槽不再固定:根 = 普通 Alloc,页持有句柄)
// 一棵树 = 一个标签页;树节点/console/font/window 表全局,页只是组织层
// (根引用 + 页内焦点 + 显示模式);句柄体系不变(id+世代),页切换无迁移。
MAX_PAGE_SLOTS :: 16
TAB_BAR_HEIGHT :: f32(32)     // 底部页签条(状态栏雏形);树区高 = 物理高 - BAR

Page :: struct {
    title : [32]u8,           // 页标题(定长,截断;默认 = 页序号)
    title_len : u8,
    tree_root : mem.Handle,   // 本页树根(空叶;页销毁时整树释放)
    focused : mem.Handle,     // 页内焦点(每页记忆,切换即恢复)
    view_mode : PageMode,     // Tiled / Single;写者 = SetSingleMode + DestroyWindow(自愈回 Tiled)
}
pages : mem.GenArray(MAX_PAGE_SLOTS, Page)
current_page : mem.Handle     // 当前页;0 = 无页(程序空态)
```

- **根语义变化**:`ROOT_WINDOW_TREE_NODE_ID=1 / AllocAt(1)` 废除;`WindowTreeRoot()` = 当前页根(页字段);`TreeNodeSplit` 根分支同步页根(根 id 迁移到新父);根壳常驻/吸收逻辑不变(用 `parent_id == 0` 判根)。
- **页签几何/命中**:`PageTabRect` / `NewTabRect`(渲染与命中共用公式,标题宽经 UI 字体度量)、`TabBarHit`(点击页签切页 / "+" 建页);`ProcessMouse` 页签区优先于窗口树命中。
- **后台页休眠**:布局只算当前页;`WindowTreeSetRootSize` 更新**所有页**根几何 + 重排,后台页布局延后到切回帧。
- **会话全量**:`PollSessions` 遍历**所有页**的叶子(`PageTreeRoot` + `collectLeaves`),任意页有窗格 → 程序继续;后台页持续消费输出。`ConsoleUpdateTree` 对**所有** console 调用 `UpdateConsole`(含无会话的),因为 OSC 命令信道的回收必须在无会话时也发生(否则 `CommandPipePending` 恒真,阻塞主循环永不入睡)。

### 4.7 状态栏(页签条)

- 底部 `TAB_BAR_HEIGHT = 32` px 条:`[页签...][+] │ 工具区(命令栏输入框 + FPS 标签)`;激活页签背景 = 主题 `tab_active_bg`(默认 = 主题 bg),与内容区**无缝延伸**(WT 式)。
- 主题字段:`tab_bar_bg` / `tab_fg` / `tab_active_bg` / `tab_active_fg` / `tab_hover_bg`。
- 条内尺寸常量(渲染与命中共用):`TAB_PAD_X=12` / `TAB_MIN_W=80` / `TAB_MAX_W=240` / `TAB_GAP=3` / `NEW_TAB_W=26` / `CMD_VIEW_W=320` / `FPS_TAG_W=64` / `TOOL_GAP=6`。
- 一期交互:点击页签切页、点 + 建页、`Ctrl+Tab` / `Ctrl+Shift+Tab` 环绕切换;`×` 关闭右侧期。

## 5. 接口分层:模块接口与用户接口

**两类接口必须分开设计**——调用方掌握的上下文不同:

| | 模块接口(内部) | 用户接口(外部) |
|---|---|---|
| 调用方 | 其他模块(canvas ↔ conpty ↔ font) | 子进程 / 控制台指令 / DLL 插件 / 脚本 |
| 上下文 | 已知:Handle 世代、布局、模块边界、调用顺序 | 极少:只知道窗口 id 与意图 |
| 参数 | `mem.Handle`、内部结构指针 | 简单整数 id、cstring、自包含参数 |
| 操作粒度 | 单一操作(分裂 / 挂载 / 改比例) | 意图(open-file = 聚焦 + 输入序列的组合) |
| 返回 | `(值, bool)` | 统一状态码 / 回执 |

- 模块接口在"已知上下文"下设计:传 Handle、直写字段。
- 用户接口在"低上下文"下设计:只认窗口 id(世代解析在内部)、命令自包含、操作是意图。
- **用户接口适配器**:命令字符串 → 调用模块接口(parser 层),不直接暴露模块接口。

### 5.0 用户接口(控制台指令集 / 配置文件)

**入口**:① 悬浮命令栏(F2 呼出)输入指令回车执行;② 配置文件 `config.ceterm`(逐行 = 一条指令,见 6.3);③ 子进程 OSC 999 信道(见 6.1)。
三处共用**同一套语法、同一个解析器与同一个解释器**;指令无前缀,命令名与键名大小写不敏感。

> **完整命令表(53 条)见 `SCRIPT.md` §4** —— 那份表由 `src/command/spec.odin` 的 `COMMAND_SPECS`
> 逐条导出,是命令全集的**唯一文档真相源**;本文不再复述,避免双份维护。

设计上不可省的几条硬规则(细节与反例见 `SCRIPT.md` §2):

- **`@id` 放末尾**指定目标窗口(缺省 = 当前焦点);仅窗口类命令接受;**id 不在当前页树内 = 目标空**(执行失败)。
- **方向词**是每组命令的固定枚举:水平 `right|leftright|h`,垂直 `down|updown|v`;`left/up` = 新窗在首侧。
- **三态参数** `[on|off]` 缺省 = **翻转**(不是"设为 on");布尔参数另收 `true|false|1|0`。
- 参数形态由 `ArgKind` 判别,解析器**逐位取用**(token 位置 = 语法位置),命令名特判不写在解析器里。

**实现:** `src/command/` —— `spec.odin`(`COMMAND_SPECS` 表:名字/别名/参数形态/用法/帮助)、
`command.odin`(`ParseCommandStringEx` 解析 + `FormatCommand` 逆变换 + `ExecuteCommand` 唯一解释器)、
`config.odin`(配置加载)、`keybindings.odin`(绑定表)、`execute.odin`(命令信道消费)。
**新命令 = 规格表加一行 + 解释器加一个分支**(解析/校验/错误文本/格式化/help 自动跟随)。

### 5.0b 用户接口(函数族)

控制台指令最终映射到这些函数(用户代码 / 未来 DLL 也可直接调用)。**调用方负责失败处理**:失败 = `false` / 空句柄,不抛错;`id` 缺省 = 当前焦点窗格。

| 函数 | 签名 | 说明 |
|---|---|---|
| `CreateWindowTreeRoot` | `() -> mem.Handle` | 建根节点 + 根窗口,幂等 |
| `SplitNewWindow` | `(dir : SplitType, id = {}, new_on_first := false, factor : f32 = 0.5) -> mem.Handle` | 分裂新窗,焦点移到新窗;factor = 原窗占比(<= 0 = 0.5) |
| `DestroyWindow` | `(id = {}) -> bool` | 关应用+会话+树摘除;唯一剩余窗口清空整树 |
| `SetSplitFactor` | `(factor : f32, id = {}) -> bool` | 设父节点比例 |
| `SetSplitFactorLeaf` | `(n : int, factor : f32) -> bool` | 设先序叶子序号 n(1-based)认领的 split 比例 |
| `GetSplitFactor` | `(id = {}) -> (f32, bool)` | 查询父节点比例(根窗 = false) |
| `ExchangeWindow` | `(dir : FocusDirection, id = {}) -> bool` | 与方向邻居交换 console_id |
| `SetConsoleFont` | `(path : string, size : f32, id = {}) -> bool` | 设窗格字体(空窗格自动建 console) |
| `SetConsoleFontSize` | `(size : f32, id = {}) -> bool` | 改字号(保留字体文件;失败保留旧字体) |
| `AdjustConsoleFontSize` | `(delta : f32, id = {}) -> bool` | 字号增量(绑定目标;命令层用 ±2) |
| `SetDefaultLaunch` | `(cmd, font : string, size : f32)` | 默认启动配置:之后新建窗格自动先设字体再启动;留空 = 不自动应用。已有窗格不追溯 |
| `GetDefaultLaunch` | `() -> ^DefaultLaunch` | 默认启动配置指针(字段直读写) |
| `LaunchConsole` | `(cmd : string, id = {}) -> bool` | 用窗格字体启动会话(已绑会话则自动分屏继承字体) |
| `FeedConsole` | `(data : []byte, id = {}) -> bool` | 写输入到窗格 console(同时退出 review、刷新 `input_activity_ms`) |
| `ClearConsoleSession` | `(id = {}) -> bool` | 清窗格会话(保留 console 与字体) |
| `PollSessions` | `() -> bool` | 每帧检测会话结束 → 关窗格;返回是否还有窗格 |
| `ConsoleScroll` | `(delta : int, id = {}) -> bool` | 历史滚动:正 = 向下(新),负 = 向上(旧,进 review) |
| `ConsoleExitReview` | `(id = {}) -> bool` | 退出 review 回实时跟随(内部单点 `exitReview`) |
| `SetFocusWindow` | `(id : mem.Handle) -> bool` | 设焦点 |
| `FocusMove` | `(dir : FocusDirection, id = {}) -> bool` | 方向导航设焦点 |
| `GetFocusWindow` | `() -> mem.Handle` | 查询焦点 |
| `ConsoleCount` | `() -> int` | 查询当前页窗格数 |
| `GetConsoleInfo` | `(id = {}) -> (info : ConsoleInfo, ok : bool)` | 窗格信息快照(派生量按值返回;空窗格 has_console=false) |
| `PageCreate` | `() -> mem.Handle` | 建页(页槽 + 根空叶);不变为当前页 |
| `PageNew` | `() -> mem.Handle` | 建页 + 根窗(默认启动配置)+ 切换 |
| `PageDestroy` | `(page_h : mem.Handle) -> bool` | 关页(整树销毁);最后一页拒绝;当前页销毁 → 切相邻 |
| `PageSwitch` | `(page_h : mem.Handle) -> bool` | 切页(页内焦点即页字段,无同步) |
| `PageNext` / `PagePrev` | `() -> bool` | 存活序环绕切换(单页 = 自己) |
| `PageCount` / `PageCurrent` / `PageByIndex` | `() -> int` / `() -> mem.Handle` / `(n : int) -> mem.Handle` | 查询(PageByIndex 1-based 存活序) |
| `PageTitle` / `PageSetTitle` | `(page_h) -> string` / `(page_h, s) -> bool` | 页标题(截断 31 字节) |
| `SetSingleMode` | `(on : bool) -> bool` | 设置当前页显示模式(唯一写者;命令 `single on/off`) |
| `ToggleSingleMode` | `() -> bool` | 翻转当前页模式(绑定目标) |
| `SetUIFont` | `(path : string, size : f32) -> bool` | 设置 UI 字体(页签/状态栏/命令栏/FPS 共用;失败保留旧) |
| `GetUIFont` | `() -> mem.Handle` | 取 UI 字体(未设置惰性加载默认 consola 18) |
| `ResetUIFont` | `()` | 回默认(consola 18) |
| `SetThemeByName` | `(name : string) -> bool` | 激活命名主题(不存在 = false;下一帧全量生效) |
| `GetTheme` | `() -> ^Theme` | 当前主题指针(只读消费 / 字段直改;未激活 = `boot_theme`) |
| `DefineTheme` / `SetThemeField` / `GetThemeSlot` | `(name) -> ^NamedTheme` / `(name, field, index, color) -> bool` / `(name) -> ^NamedTheme` | 命名主题注册表(建槽 / 逐项设置 / 按名取槽) |
| `SetKeyBinding` | `(key : inp.Scancode, mods : KeyMods, cmd : ParsedCommand) -> bool` | 添加/覆盖一条绑定(同 key+mods 覆盖;表满 64 false) |
| `ClearKeyBindings` | `()` | 清空绑定表 |
| `UnsetKeyBinding` | `(key, mods) -> bool` | 移除一条绑定(不存在 = false) |
| `GetKeyBinding` | `(key, mods) -> ^Binding` | 查表内槽指针(nil = 无;不做值拷贝) |
| `LoadConfig` | `() -> (stats : ConfigStats)` | 执行入口配置(逐行顺序 + load 展开;见 6.3) |
| `GetVSync` / `SetVSync` | `() -> bool` / `(on : bool)` | 垂直同步状态与开关(render) |
| `GetBlockLoop` / `SetBlockLoop` | `() -> bool` / `(on : bool)` | 阻塞主循环开关(render;关 = 无条件跑满帧) |
| `IsFpsTagVisible` / `SetFpsTagVisible` | `() -> bool` / `(on : bool)` | FPS 标签显隐(默认 off;命令 `fps`) |
| `GetWindowBorderless` / `SetWindowBorderless` | `() -> bool` / `(on : bool)` | 无边框窗口(render) |
| `SetBackgroundShader` / `SetBackgroundShaderFile` / `ResetBackgroundShader` | `(src/path : string) -> bool` / `() -> bool` | 背景 shader 源码 / 文件 / 重载默认(render) |

### 5.1 模块接口(内部,操作级)

```odin
CreateWindowTreeRoot() -> mem.Handle               // 建根(幂等)
WindowTreeRoot() -> mem.Handle                     // 当前页根(分裂后根迁移)
GetWindowTreeNode(h) -> ^WindowTreeNode            // 取节点(直接读写字段)
NodeHandleById(id : u32) -> mem.Handle             // id → 带当前世代的句柄(不在当前页树 = 0)
WindowTreeSetRootSize(width, height : u32)         // resize 更新根几何(所有页)

TreeNodeSplit(h, split_type, factor) -> (parent_h, right_h, ok) // h 保留为左/上,新开右/下
TreeNodeRemove(h)                                  // 摘除子树,父变单子自动提升
TreeNodeSetSplitFactor(h, factor) -> bool          // 内部节点比例 0.05..0.95
TreeNodeSetSplitType(h, split_type) -> bool        // 内部节点方向
TreeNodeSetLeftSon / TreeNodeSetRightSon(h, son_h) -> bool  // 手动挂子(含环检测)
RecalculateTransforms(h)                           // 递归重算子树几何

// 叶子序(冷路径;没有单一的 ComputeLeafOrder 入口):
collectLeaves(root, ^[MAX_TREE_NODE_SLOTS]mem.Handle, ^int)  // 先序收集叶子
LeafSplitOwner(...)                                // split 认领匹配:每个 split 的唯一叶子 = 其左子树最右叶
SplitFrameHit(x, y) / nodeAtPoint(...)             // 分割条命中 / 窗格命中
FocusNeighbor(from, dir) -> mem.Handle             // 方向导航(上行找边界祖先,下行找最远 leaf)
```

### 5.2 Console

```odin
CreateConsole(rows, cols, conpty_handle = {}) -> (h, ok)  // conpty_handle 可 0(工具 console)
DestroyConsole(h)
GetConsole(h) -> ^Console
ConsoleUpdateLayout(h, t, cell_w, cell_h) -> bool  // 每帧:算 cols/rows + 居中取整
ConsoleUpdateTree(node_h)                          // 布局(遍历 node 树)→ 尺寸应用 → 输出(遍历 console)
UpdateConsole(h)                                   // 拉 conpty 环形缓冲喂解析器 + OSC 命令信道回收
ConsoleFeed(h, data)                               // 注入字节(工具自绘 / 测试 / 指令回显)
ConsoleSetCursor(h, row, col) -> bool
ConsoleViewportTop(h) -> (top, in_review)          // 视口顶行(渲染/应答共用入口)
ConsoleScreenLine(h, r) -> int                     // 屏幕第 r 行 → 缓冲行(-1 = 越界)
ConsoleScreenRow(h, line) -> int                   // 缓冲行 → 屏幕第 r 行(-1 = 不在屏上)
ConsoleActivateTermBuffer(h, buffer_h) / ConsoleAttachTermBuffer(h, buffer_h)
CreateTermBuffer(...) / DestroyTermBuffer(h) / GetTermBuffer(h)
```

- **历史滚动数据模型(单真值,顶行锚定)**:`TermBuffer.review_top` / `review_off`
  - `review_top = 0` = 活窗口(贴底跟随,窗口顶段由 `viewportAnchorLive` 从内容尾部回退 `rows` 段推出)
  - `review_top = n (1..)` = review,窗口**顶行** = `lines[n-1]` 的第 `review_off` 段起 —— **内容坐标**,resize/重排天然稳定
  - 为什么不用底行编码:底行每次都要拿 `rows` 反推顶行,而"一行占几段"随 `cols` 变,段模型下反推不成立
  - 平移原语:`ViewportAnchorShift(tb, cols, line, off, delta)` 按**屏幕段**前后走(`ConsoleScroll` 用它;越界停在内容首/末);滚到活窗口顶 ⇒ `review_top = 0` 回最新
  - 推导唯一入口:`viewportAnchor(console, tb)`(review 用锚点,否则活窗口);渲染/应答/resize/裁剪共用

**屏幕行表(屏幕坐标 ↔ 缓冲坐标的唯一换算入口)**:`TermBuffer.screen` —— `rows` 项的 `ScreenRow{line, offset}`,由 `screenEnsure(console, tb)` 建/重算;读侧(渲染 / 选区 / 鼠标 / CPR / IME / `ConsoleLineText`)一律走 `screenLineAt` / `screenRowFor`,跨包入口 `ConsoleScreenLine` / **`ConsoleScreenSegment`**(返回 `(line, offset)`,渲染按段画)/ `ConsoleScreenRow`,**不许再出现 `top + r` 这种散落算术**。
- **光标本身就是屏幕坐标**(`Console.cursor_row/col`,VT 状态的地址空间):行 0..rows-1、列 0..cols-1。内容行由写入路径换算(`screenBase + cursor_row`,阶段2 换成查表拿 `(line, offset)`);因此 `CUU/CUD/CUP/VPA/DECSTBM/DECOM/IND/RI/DSR` 全部退化成纯屏幕算术,不再做 `± base` 的来回换算。
- **写入路径用算术、读侧用表**:表只服务读侧 —— 否则每落一格就要重建一次 `rows` 项。
- **表归 buffer(内容层)**:表的形状由内容长度决定(阶段2 起一条逻辑行可占多个屏幕行),失效源就是 buffer 的写路径 ⇒ 就地失效;交替屏各持一张表 ⇒ **切页零失效逻辑**。建表仍要"屏幕多高",那是窗格几何 ⇒ 入口签名 `screenEnsure(console, tb)`:参数取几何,状态存 tb。
- **失效 = `screen_dirty`**:内容长度进了推导(一行占几段由内容决定),没有便宜的"输入快照比较"可用了 ⇒ 由写路径/几何/review/裁剪/清空**就地置位**,`screenEnsure` 消费并清除;另加 `len(screen) == rows` 兜住"新建但零值状态说自己是干净的"这一初始态。
- **内容之外的行 = 饱和在 `len(lines)`(不是伪造行号)**:表对内容用尽之后的屏幕行一律给 `line = len(lines)`。**读方必须在索引 `lines` 前判界** —— 这条约定踩过坑:`mouse.odin` 的悬停命中里,`LineWidth(tb.lines[line].cells[:], …)` 落在边界检查之外,而那个分支只在有选区时进入 ⇒ 一选区、鼠标移到内容下方空白区就索引越界 panic(且 `-subsystem:windows` 把 panic 文本吞了,表现为"程序直接退出、没有报错")。凡是从屏幕行表取值后索引 `lines` 的地方,一律先 `line_ok := line >= 0 && line < len(tb.lines)`。
- **阶段2(已落地,逻辑行 + 屏幕段)**:
  - 内容:`Line` = **逻辑行**(只有硬换行才开新行,长度可远超 cols);`wrapped` 标记**已删除** —— 软折行 = 同一行、硬换行 = 不同行,结构自己说明,段划分由 `SegmentLen`/`LineSegments`/`SegmentStart` 从内容**派生**(宽字对不跨段)。
  - 内容长度:`LineExtent` = 末尾空白之外的正文长度(`lineContent` 视图)。段数/锚点/推进一律按它算 —— 否则 EL/ED 补齐的空白会被当成内容(1 列下 "abc"+77 空白 = 80 段,窗口锚到行尾空白)。
  - 写入热路径:**光标段缓存** `Console.cursor_line/cursor_off/cursor_seg_ok/cursor_seg_row`。软折行用 `cursorSegmentNextSegment`(留在同一行,off += 段长,O(1);`SegmentLen == 0` 时 off 不动,否则空行上会凭空前进一格);LF 用 `cursorSegmentNextLine`(本行走完才换行,"走完"按 `LineExtent` 内容长度,不含 EL/ED 补齐的空白)。缓存的失效:写入路径靠"屏幕行号变了就重查";**切页(1049)/清空(RIS/DECCOLM)/SU 全屏上滚显式作废**;LF 在行号不符时先按当前行同步一次(CUP 不清缓存,但下一笔写入或 LF 会重查)。内容下方空白区的屏幕行映射到"末尾之后第 `r - 空白区首行` 条新行"(光标在那里写入时按屏行补齐,不是全挤在内容末尾)。
  - 硬换行:`LF` = 下移一段(内容不动)、**清 `wrap_pending`**(xterm 的 index 走 `CursorDown`);**列 0 上的 LF(= CR+LF)** 若落在逻辑行内部,按**段边界**拆行(`splitLineAt`)把硬断点记进结构 —— 段边界保证画面不动。
  - 全屏软折行:**不 append 空行** —— 同一逻辑行多长一段就把活窗口的顶段挤出(视口贴底推导),底段即光标段;只有 LF/SU 这类"下移到新行"才 append 空行。逐段底折行/空行问题的复现与修复见 `docs/DEBUG_SUMMARY.md` B8。
  - 段内操作:EL/ECH/ICH/DCH 只在 `[off, off+cols)` 内动;`sanitizeWidePairs(line, from, to)` 段口径。
  - 屏幕级操作:ED 逐屏幕行取段擦(`clearScreenRow`);IL/DL/SU/SD 先 `splitRowsInRegion` 把滚动区内每个屏幕行拆成一条行(长行可按段拆,画面不变),再做行级搬移。
  - 失效:`screen_dirty` 取代快照比较(写路径/几何/review/裁剪/清空就地置位);`screenEnsure` 另加 `len(screen) == rows` 兜住零值初始态。
  - 选区:`screenToBuffer` 返回**逻辑列**(段首 + 段内列);复制按逻辑行,每条行之间就是换行(不再靠 `wrapped` 拼接)。
  - 历史视口:锚点换成**顶行 + 段**(`review_top`/`review_off`),`ViewportAnchorShift` 按屏幕段平移,`ConsoleScroll` 按屏幕行走(不再按行跳);`applyConsoleSize` 不再重定锚点(只在 `cols` 变时把 `off` 吸附到新的段边界)。
  - 验收:`playground/reflowcheck/`(变宽并回 / 变窄零丢失 / 硬换行不合并 / CJK 不劈开)、`playground/segcheck/`(分段原语 83 项)、`playground/screenmapcheck/`(**231 项**:表 ↔ 公式等价、跨 buffer 隔离、段平移往返与越界)。

**擦除语义(ED,宿主实现 clear 走这条)**:`ED 0/1/2` 只作用于**可视窗**(行数组尾部 `rows` 行),不碰历史、不动光标;`ED 3`(`ESC[3J`)= **Erase Saved Lines**,只丢可视窗**之上**已滚出的历史(`cutHistoryHead(screenBase)`),**可视屏内容与光标屏幕行都不许变**。曾经的实现是 `ED 3 → TermBufferClear`,行数组清空而 `cursor_row` 留在原处 —— 下一次写入把数组补空行补回那一行,提示符的屏幕行就等于"清屏那一刻攒下的历史长度"(实测宿主对 `clear` 发的正是 `\e[H\e[2J\e[3J`):历史长则提示符沉到屏幕底部、历史短则停在中间或顶部,同一个 `clear` 每次落点不同。

**光标在屏上(不变式,已结构化)**:`cursor_row` **就是屏幕行**(0..rows-1),所以"光标在视口内"不再是一条需要守的不变式 —— 它由坐标语义直接保证(旧模型里 `cursor_row` 是物理行、可落到窗口之上,才需要额外守)。

**resize 时按内容重定光标屏行(尺寸无关量 = 逻辑行 + 行内绝对列)**:`applyConsoleSize` 在改尺寸**之前**取 `(cursor_line, cursor_pos) = (光标所在逻辑行, off + cursor_col)`——只存段首不够,`cols` 一变段边界跟着变,老段首在新网格里可能落在段中间,只有写入路径的绝对列 `at = off + col` 是尺寸无关的;改完尺寸用 `screenRowForPos`(段级查表,行级 `screenRowFor` 只能给一条逻辑行的第一段)把光标落回新屏行,列换成新段内的列。**不重定的后果**(用户实测):字号变大 ⇒ 列宽变小 ⇒ 长行多折出一段,内容整体往下长一格,而 `cursor_row` 还指着老行 ⇒ shell 收到 `SIGWINCH` 重画提示行的那一笔落在 `dir` 列表**中段**,列表被写花(截图里 `Dev  「…」od  Recent` 这种形态)。内容不在窗口里(在锚点之前/之后)才夹到顶/底;光标内容落到窗之上时按真实终端语义丢掉新屏装不下的**底部**行,光标成为窗顶。两个细节:① 地址落在段外(光标停在行内容末尾、新网格这一段装不下)⇒ 停在该段末列 + `wrap_pending`(与写入路径同一编码),否则那一笔覆盖行尾字符;② 光标段缓存要**直接写成**重定后的那一段,不能一律 `cursorSegmentInvalidate` —— 折行推进靠缓存里"同一逻辑行"的知识,失效态下的惰性重查会按新屏行取段(实测:缩到 1 列后写 `d` 落到新行而不是接着 `abc` 后面)。

**`applyConsoleSize` 同尺寸 = no-op(几何没变就别动 VT 状态)**:`ConsoleUpdateLayout` **每帧**都会调它(`layoutWalk`),所以开头用 `rows/cols` 相同直接返回。这不只是省开销 —— 里面的"清 `wrap_pending`"和"重置滚动区"每帧做一次会踩两个坑(实测):① 抹掉"写满最后一列、等下一字符折行"的状态 ⇒ 下一个字符**覆盖末列**(4 列写完 `abcd` 再写 `e` → `abce`,不是折到下一行);② 把应用用 `DECSTBM` 设的滚动区重置成全屏(`1..3` → `1..5`),vim 那类 TUI 当场失效。验收:`playground/resizecursor/`(20 项:光标内容位置跨 resize 不变、提示行重画落点、行尾续写追加、同尺寸 layout 不动状态)。

**选区数据模型(两条规则,故意做薄)**:`Selection` 存 buffer `(行, 列)` 区间(逻辑列,`SelectionPoint`)+ 所属 buffer/宿主 console。
- **按键输入即取消**:唯一入口在 `exitReview`(它同时是"退出 review"与"用户动作"的唯一写点;`FeedConsole` 与 `ConsoleExitReview` 都走它)⇒ 不在内容写路径里做任何选区平移/自愈。
- **review 时保持**:选区锚在内容坐标上 ⇒ 翻历史、切页、resize、重排都不影响它。
- 失效只剩两种,都**惰性**判:`SelectionValid()` 检查锚点行是否还在界内(裁剪/清屏之后);`TermBufferClear`(交替屏/整块清屏)直接清。**没有每帧自愈趟**。
- 行尾口径 = `LineWidth(cells, cols)` = `max(屏幕宽, 内容长度)`:高亮铺满整行(常规观感),长行则覆盖它全部段;文本提取只读真实存在的格(`min(e, len(cells))`)。

**宽字符列算术(不变式)**:光标移动一律**纯算术**,禁止按缓冲内容(宽字续列)修正 —— BS = 列-1,CUB n = 列-n,光标**允许**停在续列上。理由:应用(zsh/zle、vim)按自己的列模型发**相对**位移,终端若"帮忙"多挪一列,两边就此错开,后续擦除/重写落错格,劈开宽字对 —— 症状是"纯输入正常、一编辑整行就乱"。`vt.odin` 中不得出现读 `cell.cp/wide` 来调整光标的代码(唯一的宽字处理在写入路径:写窄字覆盖半个宽字对时把另一半清成空白)。

### 5.3 工具 iterm【规划,接口未实现】

> 以下接口在 `src/` 中**不存在**;这是落地时的接口形态草案。

```odin
TreeNodeAddIterm(h, tool_type) -> (index, ok)      // 挂工具(锚定参数由 ItermGet 直写)
TreeNodeRemoveIterm(h, index)
ItermGet(h, index) -> ^Iterm                       // 直写 tool_type / 锚定 / layer
ItermAbsoluteTransform(h, index) -> Transform      // 锚定公式(见 4.2)
```

### 5.4 焦点与输入路由

```odin
SetFocusWindow(node_h) / GetFocusWindow() -> mem.Handle
FocusNeighbor(from, dir) -> mem.Handle             // 方向导航(上行找边界祖先,下行找最远 leaf)

// 键盘(每帧,真实消费链):
//   1. command.ProcessKeys 先消费全局按键:命中绑定 → 载入该命令(命中即置 consumed)
//   2. canvas 取未消费剩余(input.TakeAppInput):
//        命令栏可见 → commandBarFeed(含 esc 序列状态机)
//        否则       → FeedConsole(写焦点窗格 conpty)
// 鼠标:canvas.ProcessMouse(分割条拖拽独占 → 页签区 → 窗口树命中 → 应用鼠标模式回写)
//   应用鼠标模式(1000/1002/1003)激活时,鼠标事件编码成 SGR 序列写回子进程而不是本地处理
```

### 5.5 会话 / 字体 / 渲染(现状保留)

```odin
// conpty
CreateConptyContext(size : win.COORD, cmd : string, cwd : string = "") -> (h, ok)
DestroyConpty(h)
Resize(h, cols, rows) -> bool
WriteConptyInput(h, data) -> (n, ok)
StartReadThread(h) -> bool / StopReadThread(h) / StopAllReadThreads()
GetReadWriteData(h) -> ^ReadWriteData
IsReadThreadAlive(h) -> bool                       // 管道断开信号
IsChildAlive(h) -> bool                            // 主进程退出信号(存活判定双信号之一)
RingHasData(h) / AnyRingHasData() -> bool          // 环形缓冲是否还有未读字节(只读谓词)
InitWakeEvent() / wakeMainLoop()                   // 读线程唤醒主循环(线程安全 PushEvent)

// font
LoadFont(path_or_name, size, quiet := false, with_fallback := true, em_px := 0) -> (h, ok)
RetainFont(h) / ReleaseFont(h) / GetFont(h) / GetMetrics(h)   // 引用计数持有者 = Console
GetGlyph(h, cp) / GetGlyphById(h, gid) / GlyphIndex(h, cp)
GetAtlasTexture(h) / ShapeLine(h, ^[dynamic]u16) / ShapeGlyphs(&gsub, ^[dynamic]u16)
SetHinting(Hinting) / GetHinting() / InvalidateGlyphCaches()  // 光栅化模式(命令 hinting);切完清缓存重光栅化
FtAvailable() / FtVersion()                                   // FreeType 载荷状态(freetype/x64/)

// render
Init / Quit / GetWindowSize / GetWindow
BeginFrame / EndFrame
DrawRect / DrawRune / DrawGlyphById / DrawText / DrawRectBg
DrawFrame()                                  // 无参:两趟遍历(背景趟 → 背景 pass → 字形趟)
drawTabBar()                                 // 底部页签条(几何/命中在 canvas,渲染只读)
SyncWindowTitle() / UpdateIMEArea()          // OS 标题(读 app_title)/ 输入法候选窗跟随光标
FpsTick() / NextAnimDeadlineMs() / BlinkAlpha()  // FPS 采样 / 动画期限(阻塞主循环)/ 光标闪烁
GetVSync / SetVSync / GetBlockLoop / SetBlockLoop
// 背景可编程 shader(源码外置 resource/shader/:main.vert / main.frag / background.frag)
InitBackgroundShader() -> bool               // 读 background.frag 编译(缺文件 = 背景批直接上屏兜底)
SetBackgroundShader(src) -> bool             // 运行时替换(完整 GLSL;编译失败保留旧)
ResetBackgroundShader() -> bool              // 重读默认文件(热重载)
// 背景恒定走 FBO → 用户片段 shader(无"纯色模式"开关);要纯色背景 = 直接改
// background.frag(直接输出 uBg)。语义:theme 打底 + 全部 cell 底色先渲染到 RGBA8
// 纹理(uBg),经 shader 变换输出;字形/光标/UI 不受影响。帧序:第 1 趟画背景 →
// 背景 pass(FBO+shader)→ 第 2 趟画字形(分两趟原因:主批 push 会因纹理切换提前
// flush,字形先上屏会被全屏 quad 覆盖)
```

## 6. 对外扩展接口

### 6.1 指令入口现状(已实现三条)

- **悬浮命令栏**:F2 呼出,输入指令回车执行(见 5.0)。交互入口,人用。
- **子进程 OSC 999 信道**:子进程经 `ESC]999;<cmd> ST` 向 CETerm 发指令,回执经同一 OSC 号写回子进程 stdin。识别路径 OSC 999 → 命令字符串 → `executeString`(命令层;状态机在 `src/canvas/vtparse.odin`);需先由命令栏 `osc on` 授权该窗格。**协议规范见 `OSC999.md`,号码总览见 `OSC.md`**。
- **配置文件**:`config.ceterm` 是"启动时批量执行的脚本"(见 6.3)。
- 三条共用同一套指令语义(5.0),只是载体不同;`ret` 三态(Ok / Err / None)与失败原因文本在三条上一致。

### 6.2 DLL 插件【规划,未实现】

- `ApiTable`:用户视角函数族(见 5.0b)+ `AppState`(全局状态指针,GenArray 定长存储、地址稳定)。
- 用户 DLL `ceterm_bind(^ApiTable)` 接收接口;改行为只需重编译 DLL + 热重载,不重启 CETerm。
- 跨边界约束:不传动态数组 / 字符串所有权;用户 DLL 不分配内存;全部 `proc "stdcall"`。

### 6.3 配置分层(已实现:`config.ceterm` = 命令脚本)

- **用户配置** `%LOCALAPPDATA%\CETerm\config.ceterm`:存在且可读 → 只执行它(完全替代保底配置)。
- **保底配置** `<资源根>\config.ceterm`:用户配置缺失/读失败时执行(随源码提交 = 出厂默认;资源根解析见 3.3)。
- 语法 = 一行一条指令(与命令栏共用 `ParseCommandStringEx` + `ExecuteCommand`);行首 `#` / `//` 为注释(**行内 `#` 不是注释**);
  某行失败 → stderr 报 `路径:行号 + 原因` 并继续执行后续行(不整体回退)。
- **执行模型 = 逐行顺序执行(无相位)**:顺序由配置自己负责 —— 需要窗格的命令(split/font/launch/page-*)写在 `page-new` 之后;main 只在配置未建页时保底建第一页。
- **分片 = `load "<path>"`**:就地展开另一个命令文件;相对路径按**当前文件所在目录**解析,嵌套上限 8。
  主题库 `resource/themes.ceterm`(内置 24 套配色)即由入口配置首行 `load "themes.ceterm"` 引入。
- 配置里可写多页启动布局(`page-new "dev"` / `split right` / `launch "bash"` …)。
- **行为配置**(Odin 代码 / DLL,编译):自定义初始化流程、特殊布局逻辑。
- 细节(查找顺序 / 词法 / 错误表 / 完整示例)见 `SCRIPT.md` §3 与 §6。

## 7. 工程规则(编码规范)

> **全文见 `CODING_STYLE.md`**(理念根基 / 数据建模 / 模块与依赖 / 接口风格 / 遍历与每帧路径 /
> 数据驱动命令 / 并发与事件模型 / 内存与生命周期 / 直白代码 / 注释与文档 / 验证与演化 / 反模式清单)。

与本设计直接相关的四条(展开与反例在 `CODING_STYLE.md`):

- **纯赋值/纯读取不提供接口**:经 Get 返回指针直接读写字段;只有运算抽象才暴露 Setter/Getter。
- **接口 = 不变式守卫**:数据有结构正确性约束时用成套接口(树的 `linkSon` / `unlinkSon` / `replaceChild`)保证"经接口建/改必合法",禁止裸写结构字段。
- **一次遍历只写一种数据**:收集与处理分段(如 `PollSessions` 的遍历段 + 处理段)。
- **函数间传 `mem.Handle`**(u32 id + 世代),count 从 1 起,0 = 空/无效。

## 8. 待办与开放问题

- [x] ANSI 子进程指令通道:vtparse 识别 `OSC 999 ; <cmd> ST`,转 `executeString`(见 `OSC999.md`)
- [x] 指令回复通道:回执经 `OSC 999 ; > ok|err ; <body> ST` 写回子进程 stdin(见 `OSC999.md` §3)
- [x] 阻塞主循环(4 个唤醒端点:ConPTY 环有数据 / SDL 事件 / 命令信道 / 动画期限)
- [x] 静止帧不渲染:靠**阻塞主循环入睡**实现(不是脏标记 —— `render` 里没有跳帧逻辑,每帧仍 `gl.Clear` + `SwapWindow`;见 `DIRTY_TRACKING_REVIEW.md`)
- [x] 宽字对守卫:任何部分写/擦/插/删后修边界,不成对的半个宽字清成空白(见 `buffer.odin` 的 `unpairWideAt` / `sanitizeWidePairs`)
- [x] resize 趟序:输出排空 → 改本地尺寸 → 通知 ConPTY(`ConsoleUpdateTree`;**ConPTY resize 语义/reflow 策略未定**)
- [x] 会话初始尺寸 = 真实几何(`ConsoleGridForRect`;不再用写死的 80x24 —— 那会迫使每个会话都靠一次 resize 去纠正)
- [x] resize 失败不记"已应用",下帧重试(`ResizePseudoConsole` 会失败;一次失败 = 永久卡在旧尺寸)
- [x] ConPTY 实现可切换:**外部 `conpty.dll`(Windows Terminal 的 OpenConsole 实现)注入** + 命令 `conpty on|off`(只影响新会话;见 `resource/conpty/README.md`)
- [x] XTWINOPS 查询应答补齐:11(窗口状态)/ 14(像素尺寸)/ 18(文本区)/ 19(屏幕字符)—— 新版 conpty 启动即查询
- [ ] 试新版 conpty 的 `PSEUDOCONSOLE_GLYPH_WIDTH_{GRAPHEMES|WCSWIDTH|CONSOLE}` 旗标(宿主可选的 CJK 宽度算法;或可从源头治宽字宽度分歧)
- [ ] iterm 工具运行时(InternalApp 绘制 + 输入拦截)落地后定义工具输入接口(见 4.2 / 5.3)
- [ ] rich content:扩展 ANSI 序列设计(内容上传协议;Cell 扩展为内容判别)
- [ ] 多插件注册与优先级
- [ ] 命令结果 UI 显示(查询输出当前打 stdout;命令栏内驻留显示待做)
- [ ] 配置热重载(改 `config.ceterm` 后经命令重读)
