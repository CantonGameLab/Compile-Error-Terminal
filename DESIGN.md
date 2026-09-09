# dterm 设计文档

> 版本:v1(草案,待完善)
> 定位:dterm 是一个**拓展性的终端应用管理器(exterminal)**

---

## 1. 定位与愿景

- dterm 不是"终端模拟器",而是**终端应用管理器**:每个窗口承载一个终端应用,并为其提供管理工具与应用间协作能力。
- 终端应用 = **ConPTY 子进程**(shell / neovim / agent 工具等),通过 ConPTY 管道与 dterm 交流——不引入其他通信抽象。
- 超文本内容(数学公式 / GIF / 视频 / UI 控件)是未来能力,通过**扩展 ANSI 转义序列**实现;当前只做文本渲染。

## 2. 概念模型

```
Window(leaf 节点)= 一个 App = 一个 ConPTY 子进程
  ├─ console:渲染子进程输出(conpty pipeline 是唯一交流通道)
  └─ iterm[]:dterm 内置管理工具(浮层 UI,不是 app,不走 conpty)
       └─ 工具通过 dterm 指令通道控制 app
```

- **window ↔ app 一一对应**:一个 window 一个 conpty 一个 console。
- **iterm = 管理工具**:控制台、侧边文件树、预览面板、状态栏——dterm 自己渲染,复用 Console/TermBuffer(conpty_handle = 0 的内部 console)。
- **应用间交互 = 指令通道**:文件树 app 通过扩展 ANSI 序列向 dterm 发送 canvas 接口调用指令(如 focus、send-input),dterm 解析执行——指令接口面向**需要控制 dterm 的使用方**(子进程 / 外部工具)。

## 3. 分层架构

```
┌─ 使用方层:悬浮控制台指令(F2 呼出,已实现)/ ConPTY 子进程 ANSI 指令(规划)/ DLL 插件(规划)
├─ 用户接口层:指令语义(5.0)+ 用户函数族(5.0b)
├─ 适配器层:command parser(指令字符串 → 用户函数;id 世代解析)
├─ 模块接口层:canvas / conpty / font / render 公开函数(操作级,见 5.1)
├─ 数据层:窗口树 / Console / TermBuffer / 会话 / 字体
└─ 渲染层:DrawFrame(终端内容)+ nanovg UI 层(悬浮控制台)
```

- 指令入口与 DLL 插件**并存**:DLL 给编译代码的用户,指令给交互/子进程;两者都落在用户接口(5.0)上,经适配器翻译到模块接口。
- **模块间通过数据交互,避免回调交叉**;回调只允许出现在"框架 → 使用方"边界(插件契约)。

### 3.1 canvas 模块文件划分(一类数据 + 其操作 = 一个文件)

| 文件 | 数据类型 | 职责 |
|---|---|---|
| `tree.odin` | `WindowTreeNode`/`Transform`/`SplitType`/`FocusDirection`/焦点状态 | 树结构操作(分裂/摘除/挂载/重算/焦点/命中)+ `ConsoleUpdateTree` 编排 |
| `win.odin` | `Window` | 窗口表生命周期(Create/Get/DestroySlot/ensureWindow) |
| `iterm.odin` | `Iterm`/`ToolType` | 工具浮层增删/锚定变换 |
| `commandbar.odin` | `CommandBar` | 悬浮控制台:iterm 工具(`ToolType.CommandBar`)的编辑状态,**fat struct 内联**在窗口 iterms 条目(`using commandbar : CommandBar`),显隐 = 条目 `visible`,渲染按 iterm 锚定几何 |
| `buffer.odin` | `Cell`/`CellStyle`/`Line`/`TermBuffer` | 内容层生命周期 + **全部写路径**(落格/折行/滚动/擦除/裁剪)+ `review_line` 真值 |
| `console.odin` | `Console` | 视口生命周期 + 布局(居中/`viewportTop`/review 锚定) |
| `vt.odin` | `VtState` | VT 语法语义分派(ESC/CSI/SGR/DEC 模式)+ 应答 |
| `userapi.odin` | —(用户接口状态) | 窗口/会话/字体/焦点域用户接口函数族(id 省略 = 焦点)+ 默认启动配置(`DefaultLaunch`)+ 查询(`WindowCount`/`GetSplitFactor`/`GetWindowInfo`) |
| `theme.odin` | `Theme`/`ThemeSpec` | 主题数据(fg/bg/cursor + 16 ANSI + UI 色:frame/focus_border/fps/**页签条 tab_\***);颜色引用编码归属(DEFAULT_COLOR/colorRgb/colorIndex/ResolveColor/ansi256ToRgb 固定公式);`THEME_SPECS` 名字表 + SetTheme/SetThemeByName/GetThemes/GetTheme |
| `page.odin` | `Page`/`PageMode` | 页数据:每页一棵窗口树(页持根句柄 + 页内焦点 + 显示模式);页签几何/命中(PageTabRect/TabBarHit);PageCreate/New/Destroy/Switch/Next/Prev + SetSingleMode/ToggleSingleMode |
| `ui.odin` | —(UI 定制状态) | UI 字体定制(页签/状态栏/FPS 共用):SetUIFont/GetUIFont/ResetUIFont;默认 consola 18 |

### 3.2 command 模块文件划分(动作层)

| 文件 | 数据类型 | 职责 |
|---|---|---|
| `command/spec.odin` | `CommandSpec`/`ArgKind`/`CmdScope` | 命令规格表(`COMMAND_SPECS`):名字/别名/参数形态/相位/用法/帮助 —— 解析、校验、错误文本、格式化、help 全部表驱动 |
| `command/command.odin` | `ParsedCommand`/`CommandStringKind`/`ToggleMode` | 解析(`ParseCommandStringEx`,带失败原因)+ 逆变换(`FormatCommand`)+ 唯一解释器(`ExecuteCommand`)+ 子命令槽表 |
| `command/config.odin` | `ConfigStats` | 配置文件 = 命令脚本:两级路径(用户配置 → 保底配置)+ 两趟相位加载(`LoadConfig(.Global/.Window)`) |
| `command/keybindings.odin` | `Binding`/`KeyMods`/`KeyBindings` | 快捷键绑定表(mods+key → 数据化命令)+ 每帧键消费(`ProcessKeys`)+ 表操作 userapi |
| `command/execute.odin` | `CommandEvent`(canvas) | 命令栏事件队列消费(帧内路由):执行 → 结果/失败原因写回事件槽 |

## 4. 程序状态(数据结构设计)

### 4.0 主题(配色)数据

参考落地:alacritty(269 索引表 + normal/bright/dim 结构字段)、WT(扁平 20 字段 JSON 配色方案)、kitty(color0-255 展开 + 边框色独立)。dterm 取三方共识与最小集:

```odin
// src/canvas/theme.odin — 主题数据(唯一写者 = canvas;render 只读)
// 决策:① CellStyle.fg/bg 用引用编码(主题热切换零缓冲污染)
//      ② 256 色固定算法(主题只管 0-15 + 默认;覆盖表第二次出现再做)
//      ③ frame_color 从树节点删除,分割条读主题(节点回到纯结构)
//      ④ 主题归 canvas:SetTheme/ThemeGet userapi,切换即下一帧生效
Theme :: struct {
    fg, bg       : u32,      // 默认前景/背景(SGR 39/49/0 解析目标)
    cursor       : u32,      // 光标
    ansi         : [16]u32,  // SGR 索引 0..15:0-7 普通,8-15 亮(顺序 = WT/alacritty/kitty)
    frame        : u32,      // 分割条
    focus_border : u32,      // 焦点窗口边框(kitty active_border 对应物)
    fps_bg, fps_fg : u32,    // 右上角 FPS tag(渲染层观测数据)
}

// CellStyle.fg/bg 颜色引用编码(u32,一键 switch 解码,渲染期 resolve):
//   0x00RRGGBB           直接 RGB(SGR 38;2;r;g;b)
//   0x01xxxxxx(低24 = n) 索引色 n:0-15 → theme.ansi[n];16-255 → 固定 cube/灰度算法
//   0xFFFFFFFF           默认 → theme.fg / theme.bg
// 解析器(SGR)只做语法 → 编码,零主题依赖;ansi256ToRgb 固定公式随编码一起驻 theme.odin。
```

### 4.1 窗口树节点

```odin
// leaf 节点 = 一个 app:绑定 console;内部节点 = 纯分割容器
WindowTreeNode :: struct {
    console_id : mem.Handle,   // 仅 leaf:主应用 console;0 = 空窗
    iterms : [dynamic]Iterm,   // 管理工具浮层(锚定于本节点几何)
    using transform : Transform, // position_x/y, width/height(像素)
    frame_width : u32,          // 分割条像素宽(颜色读主题 frame)
    parent_id : mem.Handle,     // 0 = 无父(仅根)
    left_son_id : mem.Handle,   // left or up
    right_son_id : mem.Handle,  // right or down
    split_factor : f32,         // 左子树所占空间
    split_type : SplitType,     // UpDown / LeftRight
    is_leaf : bool,
}
```

### 4.2 工具 iterm(锚定定位)

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

### 4.3 Console(内容与渲染目标)

```odin
Console :: struct {
    rows, cols : u16,            // 目标网格尺寸(布局趟真源)
    pty_rows, pty_cols : u16,    // ConPTY 已应用尺寸(尺寸应用趟比较)
    origin_x, origin_y : f32,
    cursor_row, cursor_col : u16,
    vt : VtState,
    term_buffer_ids : [MAX_BUFFERS_PER_CONSOLE]mem.Handle,
    active_term_buffer_id : mem.Handle,
    conpty_handle : mem.Handle,  // 0 = 无后端(工具 console,dterm 自己写内容)
    font_size : f32,
}
```

字体唯一真相 = **Window.font_id**(渲染/布局/鼠标换算都经窗口取;Console 无字体副本)。

Cell 当前为文本单元(`cp: rune + style + wide`);rich content 未来经扩展 ANSI 序列进入,Cell 届时扩展为内容判别。

### 4.4 焦点状态

```odin
focused_node : mem.Handle  // 聚焦的 window(leaf);0 = 无
focused_iterm : i32        // -1 = 焦点在主应用;>=0 = iterms 下标
```

### 4.5 会话与字体(现状保留)

- `ConptyContext`:hpc / 管道 / 进程信息 / Job Object(进程树跟踪 + KILL_ON_JOB_CLOSE 清理)。
- `Font`:faces / GSUB / 图集 / shape 缓存。
- `Theme`:canvas 数据(唯一写者;见 4.0),渲染层每帧 `ThemeGet` 只读消费。

### 4.6 页(Page,每页一棵窗口树)

```odin
// src/canvas/page.odin — 页数据(分页后根槽不再固定:根 = 普通 Alloc,页持有句柄)
// 一棵树 = 一个标签页;树节点/console/font/window 表全局,页只是组织层
// (根引用 + 页内焦点);句柄体系不变(id+世代),页切换无迁移。
MAX_PAGE_SLOTS :: 16
TAB_BAR_HEIGHT :: 28          // 底部页签条(状态栏雏形);树区高 = 物理高 - BAR

Page :: struct {
    title : [32]u8,           // 页标题(定长,默认 = 页序号)
    title_len : u8,
    tree_root : mem.Handle,   // 本页树根(页创建分配;根分裂时页字段跟随新父)
    focused : mem.Handle,     // 页内焦点(每页记忆,切换即恢复)
}
pages : mem.GenArray(MAX_PAGE_SLOTS, Page)
current_page : mem.Handle     // 当前页;0 = 无页(程序空态)
```

- **根语义变化**:`ROOT_WINDOW_TREE_NODE_ID=1 / AllocAt(1)` 废除;`WindowTreeRoot()` = 当前页根(页字段);`TreeNodeSplit` 根分支同步页根(根 id 迁移到新父);根壳常驻/吸收逻辑不变(用 parent_id==0 判根)
- **页签几何/命中**:PageTabRect/NewTabRect(渲染与命中共用公式,标题宽经 UI 字体度量)、TabBarHit(点击页签切页 / "+" 建页);`ProcessMouse` 页签区优先于窗口树命中
- **后台页休眠**:布局只算当前页;`WindowTreeSetRootSize` 更新所有页根几何 + 重排(尺寸变化),后台页布局延后到切回帧
- **会话全量**:输出趟(updateConsoleOutput)与 PollSessions 不依赖页——后台页持续消费输出;会话结束判定**只信读线程 alive**(msys2 进程会脱离 Job,JobActiveProcesses 恒 0 不可靠)

### 4.7 状态栏(页签条,一期)

- 底部 28px 条:`[页签...][+] │ 状态区(预留)`;激活页签背景 = 主题 bg,与内容区**无缝延伸**(WT 式)
- 主题字段:tab_bar_bg / tab_fg / tab_active_bg(= bg,默认延伸)/ tab_active_fg / tab_hover_bg
- 一期交互:点击页签切页、点 + 建页、Ctrl+Tab/Ctrl+Shift+Tab 环绕切换;× 关闭右侧期

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

**入口**:① 悬浮控制台(F2 呼出)输入指令回车执行;② 配置文件 `config.dterm`(逐行 = 一条指令,见 6.3)。
两处共用同一套语法、解析器与解释器;**指令无 `:` 前缀**,命令名与键名大小写不敏感。

**语法**:`命令名 参数... [@id]`
- 参数空格分隔,`"..."` 包裹字符串(字符串内不能含引号)
- `@id` 放末尾指定目标窗口(缺省 = 当前焦点),仅窗口类命令接受;id 不在当前页树内 = 目标空(执行失败)
- 方向:水平 `right|leftright|h`,垂直 `down|updown|v`;`left/up` = 新窗在首侧
- 三态参数 `on|off`(缺省 = 翻转);布尔参数 `true|false|on|off|1|0`
- 相位(`Global`/`Window`)是命令固有属性:配置文件据此分两趟执行

| 指令 | 参数 | 相位 | 说明 |
|---|---|---|---|
| `split` | `<right\|left\|up\|down> [factor] [@id]` | W | 分裂窗口(新窗成为焦点);factor = 原窗占比(默认 0.5) |
| `focus` | `<id\|left\|right\|up\|down>` | W | 聚焦指定窗口(id 或方向导航) |
| `destroy` / `close` | `[@id]` | W | 关闭窗口及其会话;唯一剩余窗口 = 清空整树 |
| `factor` | `<ratio> [@id]` | W | 设置窗口**父节点** split_factor(0.05..0.95) |
| `factorleaf` | `<n> <ratio>` | W | 设置先序叶子序号 n(1-based)认领的 split factor |
| `exchange` | `<left\|right\|up\|down> [@id]` | W | 与方向邻居交换窗口内容(只换 window_id) |
| `single` / `single-mode` | `[on\|off]` | W | 单窗显示模式(焦点窗独占树区;缺省 = 翻转) |
| `count` / `windows` | - | W | 查询窗口数量 |
| `info` | `[@id]` | W | 查询窗口信息(字体/会话/比例/自动关闭) |
| `focus-get` / `getfocus` | - | W | 查询当前焦点窗口 id |
| `font` | `"<path\|name>" <size> [@id]` | W | 设置窗口字体;单个数字参数 = 只改字号(等价 `fontsize`) |
| `fontsize` | `<size> [@id]` | W | 改字号(保留字体) |
| `fontsizeup` / `fontsizedown` | `[@id]` | W | 字号 ±2 |
| `launch` | `"<cmd>" [@id]` | W | 用窗口已配置的字体启动 console 应用 |
| `feed` | `"<text>" [@id]` | W | 向窗口会话写入输入 |
| `autoclose` | `<true\|false> [@id]` | W | 应用退出后是否自动关窗(默认 true) |
| `clearconsole` / `clearc` | `[@id]` | W | 清空窗口会话(保留窗口与字体) |
| `scroll` | `<lines> [@id]` | W | 历史滚动:正 = 向下(新),负 = 向上(旧,进 review) |
| `reviewup` / `reviewdown` | `[@id]` | W | 上/下翻一屏历史 |
| `review-exit` / `exitreview` | `[@id]` | W | 退出 review 回实时跟随 |
| `page-new` | `["<title>"]` | W | 新建页并切换(可选标题;根窗 + 默认启动) |
| `page` | `<n>` | W | 切换页(n = 页存活序,1-based) |
| `page-next` / `page-prev` | - | W | 相邻页环绕 |
| `page-close` | `[n]` | W | 关页(缺省 = 当前页;最后一页拒绝) |
| `page-title` / `title` | `"<title>" [n]` | W | 设置页标题(缺省 = 当前页) |
| `pages` | - | W | 列出所有页(序号/标题/当前标记) |
| `copy` / `paste` | - | W | 复制选区到剪贴板 / 粘贴到焦点窗口 |
| `clearselection` / `deselect` | - | W | 清除文本选区 |
| `selectall` | - | W | 全选焦点窗口缓冲 |
| `theme` | `[name]` | G | 切换主题(缺省 = 列出全部主题) |
| `uifont` | `"<path\|name>" <size>` | G | 设置 UI 字体(页签/状态栏/FPS 共用) |
| `uifont-reset` / `uireset` | - | G | UI 字体回默认(consola 18) |
| `borderless` / `toggle-borderless` | `[on\|off]` | G | 无边框窗口(缺省 = 翻转) |
| `vsync` | `[on\|off]` | G | 垂直同步(缺省 = 翻转) |
| `bgshader` / `bg` | `["<path>"]` | G | 背景 shader:缺省 = 重载默认文件,带路径 = 编译该文件 |
| `toggle-commandbar` / `togglebar` | - | G | 悬浮控制台开关 |
| `default-launch` / `startup` | `"<cmd>" ["<font>" <size>]` | G | 新建窗口的默认启动配置(cmd 空 = 不自动启动) |
| `bind` | `<mods+key> "<命令>"` | G | 绑定键位(mods 前缀 alt/ctrl/shift/win 以 `+` 连键名) |
| `unbind` | `<mods+key>` | G | 移除绑定(不存在 = 失败) |
| `bindings` | - | G | 枚举全部绑定(**输出可再 bind**,走 `FormatCommand`) |
| `help` / `?` | `[命令]` | G | 列出全部命令(带参数 = 单条用法) |

**示例**:
```
split right            # 焦点窗向右分裂
split down 0.4         # 向下分裂,上(原窗)占 40%
focus 3                # 聚焦 id=3 的窗口
focus left             # 焦点向左导航
factor 0.6             # 焦点窗父节点比例 0.6
factorleaf 2 0.7       # 第 2 个叶子认领的 split → 0.7
exchange right         # 与右侧邻居交换内容
font "./f.ttf" 18      # 焦点窗字体 Cascadia 18
fontsize 20            # 改字号
fontsizeup             # 绑定动作的字符串形式
scroll -10             # 历史向上翻 10 行(review)
reviewup               # 上翻一屏
launch "cmd.exe"       # 启动 cmd(需先设字体)
destroy @3             # 关闭窗口 3
autoclose false        # 应用退出后保留窗口
theme monokai          # 切主题(theme 无参 = 列出)
page-new "logs"        # 新建页并命名
page-close 2           # 关第 2 页
help split             # 单条命令用法
bind alt+shift+l "split right"   # 绑定:Alt+Shift+L → 右分屏
unbind f2              # 移除 F2 绑定
bindings               # 枚举全部绑定(输出可再 bind)
count                  # 窗口数量
```

**实现:** `src/command/` —— `spec.odin`(`COMMAND_SPECS` 表:名字/别名/参数形态/相位/用法/帮助)、
`command.odin`(`ParseCommandStringEx` 解析 + `FormatCommand` 逆变换 + `ExecuteCommand` 唯一解释器)、
`config.odin`(配置文件两趟加载)、`keybindings.odin`(绑定表)、`execute.odin`(命令栏事件消费)。
新命令 = 规格表加一行 + 解释器加一个分支(解析/校验/错误文本/格式化/help 自动跟随)。

### 5.0b 用户接口(函数族,window.odin)

控制台指令最终映射到这些函数(用户代码/未来 DLL 也可直接调用):

| 函数 | 签名 | 说明 |
|---|---|---|
| `CreateWindowTreeRoot` | `() -> mem.Handle` | 建根节点 + 根窗口,幂等 |
| `SplitNewWindow` | `(dir : SplitType, id = {}, new_on_first := false, factor : f32 = 0.5) -> mem.Handle` | 分裂新窗,焦点移到新窗;factor = 原窗占比(<= 0 = 0.5) |
| `DestroyWindow` | `(id = {}) -> bool` | 关应用+会话+树摘除;唯一剩余窗口清空整树 |
| `SetSplitFactor` | `(factor : f32, id = {}) -> bool` | 设父节点比例 |
| `SetSplitFactorLeaf` | `(n : int, factor : f32) -> bool` | 设先序叶子序号 n(1-based)认领的 split 比例 |
| `GetSplitFactor` | `(id = {}) -> (f32, bool)` | 查询父节点比例(根窗 = false) |
| `ExchangeWindow` | `(dir : FocusDirection, id = {}) -> bool` | 与方向邻居交换 window_id |
| `SetWindowFont` | `(path : string, size : f32, id = {}) -> bool` | 设窗口字体(无窗则自动创建) |
| `SetWindowFontSize` | `(size : f32, id = {}) -> bool` | 改字号(保留字体文件;失败保留旧字体) |
| `AdjustFontSize` | `(delta : f32, id = {}) -> bool` | 字号增量(绑定目标;命令层用 ±2) |
| `SetDefaultLaunch` | `(cmd, font : string, size : f32)` | 默认启动配置:之后新建窗口自动先设字体再启动;留空 = 不自动应用。已有窗口不追溯 |
| `GetDefaultLaunch` | `() -> ^DefaultLaunch` | 默认启动配置指针(字段直读写) |
| `LaunchConsole` | `(cmd : string, id = {}) -> bool` | 用窗口字体启动会话;默认 auto_close=true |
| `FeedConsole` | `(data : []byte, id = {}) -> bool` | 写输入到窗口 console(同时退出 review) |
| `ClearWindowConsole` | `(id = {}) -> bool` | 清窗口会话(保留窗口/字体) |
| `SetAutoClose` | `(b : bool, id = {}) -> bool` | 设置自动关闭 |
| `PollSessions` | `() -> bool` | 每帧检测会话结束,按 auto_close 处理;返回是否有存活窗口 |
| `ConsoleScroll` | `(delta : int, id = {}) -> bool` | 历史滚动:正=向下(新),负=向上(旧,进 review) |
| `ConsoleExitReview` | `(id = {}) -> bool` | 退出 review 回实时跟随(内部单点 `exitReview`) |
| `SetFocusWindow` | `(id : mem.Handle) -> bool` | 设焦点 |
| `FocusMove` | `(dir : FocusDirection, id = {}) -> bool` | 方向导航设焦点 |
| `GetFocusWindow` | `() -> mem.Handle` | 查询焦点 |
| `WindowCount` | `() -> int` | 查询窗口数 |
| `GetWindowInfo` | `(id = {}) -> (WindowInfo, bool)` | 窗口信息快照(派生量按值返回;font_name 借用) |
| `PageCreate` | `() -> mem.Handle` | 建页(页槽 + 根空叶);不变为当前页 |
| `PageNew` | `() -> mem.Handle` | 建页 + 根窗(默认启动配置)+ 切换 |
| `PageDestroy` | `(h) -> bool` | 关页(整树销毁);最后一页拒绝;当前页销毁 → 切相邻 |
| `PageSwitch` | `(h) -> bool` | 切页(页内焦点即页字段,无同步) |
| `PageNext` / `PagePrev` | `() -> bool` | 存活序环绕切换(单页 = 自己) |
| `PageCount` / `PageCurrent` / `PageByIndex(n)` | `() -> (int / Handle)` | 查询(PageByIndex 1-based 存活序) |
| `PageTitle` / `PageSetTitle` | `(h [, s]) -> (string / bool)` | 页标题(截断 31 字节) |
| `SetSingleMode` | `(on : bool) -> bool` | 设置当前页显示模式(唯一写者;命令 `single on/off`) |
| `ToggleSingleMode` | `() -> bool` | 翻转当前页模式(绑定目标) |
| `SetUIFont` | `(path : string, size : f32) -> bool` | 设置 UI 字体(页签/状态栏/FPS 共用;失败保留旧) |
| `GetUIFont` | `() -> mem.Handle` | 取 UI 字体(未设置惰性加载默认 consola 18) |
| `ResetUIFont` | `()` | 回默认(consola 18) |
| `SetTheme` / `SetThemeByName` | `(t : Theme / name : string) -> bool` | 切换主题(按名字大小写不敏感;下一帧全量生效) |
| `GetTheme` | `() -> ^Theme` | 当前主题指针(只读消费/字段直改) |
| `GetThemes` | `() -> []ThemeSpec` | 内置主题表(名字 + Theme;`theme` 无参列出) |
| `SetKeyBinding` | `(key : inp.Scancode, mods : KeyMods, cmd : ParsedCommand) -> bool` | 添加/覆盖一条绑定(同 key+mods 覆盖;表满 64 false) |
| `ClearKeyBindings` | `()` | 清空绑定表 |
| `UnsetKeyBinding` | `(key, mods) -> bool` | 移除一条绑定(不存在 = false) |
| `GetKeyBinding` | `(key, mods) -> ^Binding` | 查表内槽指针(nil = 无;不做值拷贝) |
| `LoadConfig` | `(phase : CmdScope) -> ConfigStats` | 配置文件按相位执行(见 6.3) |
| `GetVSync` / `SetVSync` | `() -> bool` / `(on : bool)` | 垂直同步状态与开关(render) |
| `GetWindowBorderless` / `SetWindowBorderless` | `() -> bool` / `(on : bool)` | 无边框窗口(render) |
| `SetBackgroundShader` / `SetBackgroundShaderFile` / `ResetBackgroundShader` | `(...) -> bool` | 背景 shader 源码/文件/重载默认(render) |

### 5.1 模块接口(内部,操作级)

```odin
InitWindowTree()                                   // 建根(幂等)
WindowTreeRoot() -> mem.Handle                     // 当前根(分裂后根迁移)
GetWindowTreeNode(h) -> ^WindowTreeNode            // 取节点(直接读写字段)
NodeHandleById(id : u32) -> mem.Handle             // id → 带当前世代的句柄
WindowTreeSetRootSize(w, h)                        // 窗口 resize 更新根几何

TreeNodeSplit(h, split_type, factor) -> (parent, new_h, ok)  // h 保留为左/上,新开右/下
TreeNodeRemove(h)                                  // 摘除子树,父变单子自动提升
TreeNodeSetSplitFactor(h, factor) -> bool          // 内部节点比例 0.05..0.95
TreeNodeSetSplitType(h, split_type) -> bool        // 内部节点方向
TreeNodeSetLeftSon / TreeNodeSetRightSon(h, son) -> bool  // 手动挂子(含环检测)
RecalculateTransforms(h)                           // 递归重算子树几何
ComputeLeafOrder()                                 // 先序叶子序 + split 认领匹配(冷路径,结果表
                                                   // leaf_order/leaf_split_owner;满二叉树 leaf = split+1,
                                                   // 每个 split 被唯一叶子认领 = 其左子树最右叶,最右叶无认领)
```

### 5.2 Console

```odin
CreateConsole(rows, cols, conpty_handle) -> (h, ok)  // conpty_handle 可 0(工具 console)
DestroyConsole(h)
GetConsole(h) -> ^Console
ConsoleUpdateLayout(h, t, cell_w, cell_h) -> bool  // 每帧:算 cols/rows + 居中取整
ConsoleUpdateTree(root_h)                          // 布局(遍历 node 树)→ 尺寸应用 → 输出(遍历 console)
UpdateConsole(h)                                   // 拉 conpty 环形缓冲喂解析器
ConsoleFeed(h, data)                               // 注入字节(工具自绘 / 测试 / 指令回显)
ConsoleSetCursor(h, row, col) -> bool
ConsoleViewportTop(h) -> (top, in_review)          // 视口顶行(渲染/应答共用入口)
ConsoleActiveTermBuffer(h) -> mem.Handle
```

**历史滚动数据模型(单真值,绝对锚定)**:`TermBuffer.review_line`
- `0` = 普通模式(实时跟随,底行 = 最新行,新输出自动贴底)
- `n (1..)` = review 模式,值 = 屏幕底行物理索引 + 1;**新输出到达时不动**(视口内容稳定),trim 裁剪头行时平移补偿,resize 按"顶行不变"重排
- 滚回最新(n 到达 len)→ 置 0(普通);与"底行 = 0"的哨兵冲突用 +1 编码避开
- 视口顶行 = `viewportTop(console, tb)`(唯一公式,渲染/光标应答共用)

### 5.3 工具 iterm

```odin
TreeNodeAddIterm(h, tool_type) -> (index, ok)      // 挂工具(锚定参数由 ItermGet 直写)
TreeNodeRemoveIterm(h, index)
ItermGet(h, index) -> ^Iterm                       // 直写 tool_type / 锚定 / layer
ItermAbsoluteTransform(h, index) -> Transform      // 锚定公式(见 4.2)
```

### 5.4 焦点与输入路由

```odin
SetFocus(node_h) / GetFocus() -> mem.Handle
FocusNeighbor(from, dir) -> mem.Handle             // 方向导航(上行找边界祖先,下行找最远 leaf)
SetFocusIterm(index : i32) / GetFocusIterm() -> i32

// 输入路由(每帧):全局按键 → 焦点目标
//   焦点在主应用(focused_iterm == -1):写 conpty
//   焦点在工具:交给工具处理(dterm 内部,后续工具落地时定义)
```

### 5.5 会话 / 字体 / 渲染(现状保留)

```odin
// conpty
CreateConptyContext(size, cmd) -> (h, ok)
DestroyConpty(h)
Resize(h, cols, rows) -> bool
WriteConptyInput(h, data) -> (n, ok)
StartReadThread(h) / StopReadThread(h)
GetReadWriteData(h) -> ^ReadWriteData
IsReadThreadAlive(h) -> bool
JobActiveProcesses(h) -> int

// font
LoadFont(path, size, antialias=1) -> (h, ok)
DestroyFont(h) / GetFont(h) / GetMetrics(h)
GetGlyph(h, cp) / GetGlyphById(h, gid) / GlyphIndex(h, cp)
GetAtlasTexture(h) / ShapeLine(h, ^[dynamic]u16)

// render
Init / Quit / GetWindowSize / GetWindow
BeginFrame / EndFrame
DrawRect / DrawRune / DrawGlyphById / DrawText / DrawRectBg
DrawFrame()                                  // 无参:两趟遍历(背景趟 → 背景 pass → 字形趟)
drawTabBar()                                 // 底部页签条(几何/命中在 canvas,渲染只读)
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

### 6.1 指令入口现状(V1 已实现)

- **悬浮控制台指令**(已实现):F2 呼出悬浮输入框,输入指令回车执行(见 5.0)。这是当前唯一的指令入口,供用户交互。
- **ANSI 子进程指令通道**(规划,未实现):子进程经扩展 ANSI 序列(`ESC]999;<cmd> ESC\`)向 dterm 发指令。需在 OSC 999 识别 → 提取命令字符串 → `ExecuteCommandString`(vtparse 状态机已并入 canvas,`src/canvas/vtparse.odin`)。
- 两者共用同一套指令语义(5.0),只是载体不同。

### 6.2 DLL 插件(规划,未实现)

- `ApiTable`:用户视角函数族(见 5.0b)+ `AppState`(全局状态指针,GenArray 定长存储、地址稳定)。
- 用户 DLL `dterm_bind(^ApiTable)` 接收接口;改行为只需重编译 DLL + 热重载,不重启 dterm。
- 跨边界约束:不传动态数组/字符串所有权;用户 DLL 不分配内存;全部 `proc "stdcall"`。

### 6.3 配置分层(已实现:`config.dterm` = 命令脚本)

- **用户配置** `%APPDATA%\dterm\config.dterm`:存在且可读 → 只执行它(完全替代保底配置)。
- **保底配置** `<工作目录>\resource\config.dterm`:用户配置缺失/读失败时执行(随源码提交 = 出厂默认)。
- 语法 = 一行一条指令(与命令栏共用 `ParseCommandStringEx` + `ExecuteCommand`);行首 `#` / `//` 为注释;
  某行失败 → stderr 报 `路径:行号 + 原因` 并继续执行后续行(不整体回退)。
- 加载两趟:`LoadConfig(.Global)` → 建第一页 → `LoadConfig(.Window)`。相位来自命令规格表的 `CmdScope`:
  全局命令(主题/UI 字体/键位/装饰/默认启动/背景 shader)必须在建根窗前生效,窗口与页命令在其后按序执行。
- 配置里可写多页启动布局(`page-new "dev"` / `split right` / `launch "bash"` …)。
- **行为配置**(Odin 代码 / DLL,编译):自定义初始化流程、特殊布局逻辑。

## 7. 工程规则(编码规范)

- 纯赋值/纯读取不提供接口:经 Get 返回指针直接读写字段;只有设计运算抽象才暴露 Setter/Getter。
- 公开函数 PascalCase;外部库绑定(api.odin)不重命名。
- 函数间传 `mem.Handle`(u32 id + 世代),count 从 1 起,0 = 空。
- 注释精简,只写非显然逻辑(中文)。
- DOD 原则:数据布局先行、槽位数组 + id、预分配、直白代码、显式优于隐式、值语义。

## 8. 待办与开放问题

- [ ] ANSI 子进程指令通道:vtparse 识别 `OSC 999 ; <cmd> ST`,转 `ExecuteCommandString`
- [ ] iterm 工具运行时(InternalApp 绘制 + 输入拦截)落地后定义工具输入接口
- [ ] rich content:扩展 ANSI 序列设计(OSC 998 回执 / 内容上传协议)
- [ ] 多插件注册与优先级
- [ ] 指令回复通道(子进程需要知道指令成败?)
- [ ] 命令结果 UI 显示(查询输出当前打 stdout;命令栏内驻留显示待做)
- [ ] 配置热重载(改 `config.dterm` 后经命令重读)
- [ ] 多插件注册与优先级
