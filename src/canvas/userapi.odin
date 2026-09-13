// 用户接口层(userapi):面向意图的函数族(窗格生命周期/会话/字体/滚动/焦点/查询),
// 命令栏、键位绑定、配置文件(command/config.odin)、main 的绑定目标;
// id 省略(0)= 当前焦点窗格;失败 = false / 空句柄(尽力而为,不抛错),无效输入 = 空操作。
//
// 分层规则(见 docs/CODING_STYLE.md 3.3):userapi 只给用户与配置段落;程序内部代码
// 一律 GetXxx() 指针直改数据,不调 Set 系列。域内 userapi 归各自数据类文件,本文件
// 只放窗格/会话/字体/焦点域(数据层:leaf 节点直接持 console,无 Window 中间层):
//   默认启动配置  SetDefaultLaunch / GetDefaultLaunch
//   窗格树        CreateWindowTreeRoot / SplitNewWindow / DestroyWindow / SetSplitFactor*
//                 ExchangeWindow / SetFocusWindow / FocusMove / GetFocusWindow
//   字体集        SetConsoleFont / SetConsoleFontSize / AdjustConsoleFontSize
//   会话          LaunchConsole / FeedConsole / ClearConsoleSession / PollSessions
//   历史滚动      ConsoleScroll / ConsoleExitReview
//   查询          ConsoleCount / GetSplitFactor / GetConsoleInfo
// 其他域:主题 theme.odin / UI 字体 ui.odin / 页 page.odin / 选区 selection.odin /
// 命令栏 commandbar.odin / 键位 command/keybindings.odin / 窗口装饰与 shader render。
// 命令字符串 → 本层的映射 = command/spec.odin(表)+ ExecuteCommand(唯一解释器)。
package canvas

import ct "../conpty"
import fnt "../font"
import inp "../input"
import mem "../memory"
import "core:fmt"
import "core:strings"

// ---------------------------------------------------------------------------
// 默认启动配置(新建窗格时自动应用;cmd 留空 = 不自动启动)
// ---------------------------------------------------------------------------
// 状态属于用户接口层配置:userapi 设置生效于之后创建的窗格
// (CreateWindowTreeRoot / SplitNewWindow),对已有窗格不追溯。
// cmd 非空但 font 为空时,LaunchConsole 因无字体失败(启动前必须可设字体);
// 正常用法是 cmd+font+size 一起设置,或全部留空 = 窗格不启动。
// 内部读写 = GetDefaultLaunch() 指针直接操作字段(字符串所有权归设置方)。
DefaultLaunch :: struct {
	cmd : string,
	font : string,
	size : f32,
}

default_launch : DefaultLaunch

// userapi:设置默认启动配置(cmd/font 传空串 = 对应项不自动应用)
SetDefaultLaunch :: proc(cmd, font : string, size : f32) {
	if default_launch.cmd != "" {
		delete(default_launch.cmd)
	}
	if default_launch.font != "" {
		delete(default_launch.font)
	}
	default_launch.cmd = strings.clone(cmd)
	default_launch.font = strings.clone(font)
	default_launch.size = size
}

// 默认启动配置指针(原结构体;字段读写直接操作)
GetDefaultLaunch :: proc() -> ^DefaultLaunch {
	return &default_launch
}

// 新建窗格的自动应用:先字体后启动(先设字体,应用才能挂上)。
// 只应用于创建瞬间,不影响窗格后续手动操作;字体/会话都触发 console 懒创建。
applyDefaultLaunch :: proc(node_h : mem.Handle) {
	if node_h.id == 0 {
		return
	}
	d := &default_launch
	if d.font != "" {
		SetConsoleFont(d.font, d.size, node_h)
	}
	if d.cmd != "" {
		if !LaunchConsole(d.cmd, node_h) {
			fmt.eprintln("Your default launch didn't. Alacritty users write this in TOML and it works first try, after the compiler spends 90 seconds thinking about it. Look at your command and feel something:", d.cmd)
		}
	}
}

// ---------------------------------------------------------------------------
// 窗口树
// ---------------------------------------------------------------------------
// 当前页建根窗(页根已由 PageCreate 分配):建根窗格内容 + 默认启动配置 + 设焦点。
// 根窗格恒有 console(窗格"存在"的判定依据 = 有 console;会话/字体可选)。
CreateWindowTreeRoot :: proc() -> mem.Handle {
	root := WindowTreeRoot()
	if root.id == 0 {
		return {}
	}
	ensureConsole(root)
	applyDefaultLaunch(root)
	CurrentPage().focused = root // 焦点 = 页字段,直接操作
	return root
}

// 对 id(或焦点)窗格按轴分裂出新窗格(空窗格,console 懒创建);新窗成为焦点。
// new_on_first = 新窗放首侧(左/上):分裂后交换左右子窗内容 ——
// split left/up 即"新窗在左/上、原窗在右/下"(默认 false = 右/下)。
// factor = 原窗(首子)占比(0.05..0.95 由 TreeNodeSetSplitFactor 校验;<= 0 = 0.5)。
// 树级 TreeNodeSplit 保持纯结构;默认启动配置在用户语义层(SplitNewWindow)应用。
SplitNewWindow :: proc(dir : SplitType, id : mem.Handle = {}, new_on_first := false, factor : f32 = 0.5) -> mem.Handle {
	if singleGuard() {
		return {} // 单窗模式:分屏禁
	}
	node_h := resolveWindow(id)
	if node_h.id == 0 {
		return {}
	}
	f := factor
	if f <= 0 {
		f = 0.5
	}
	_, new_h, ok := TreeNodeSplit(node_h, dir, f)
	if !ok {
		return {}
	}
	ensureConsole(new_h) // 新窗格建 console(内容容器;字体/会话由默认启动配置决定)
	applyDefaultLaunch(new_h)
	// 新窗在首侧:交换两子窗内容(console 随节点走),焦点 = 首侧
	if new_on_first {
		if n := GetWindowTreeNode(new_h); n != nil {
			if p := GetWindowTreeNode(n.parent_id); p != nil {
				a := GetWindowTreeNode(p.left_son_id)
				b := GetWindowTreeNode(p.right_son_id)
				if a != nil && b != nil {
					a.console_id, b.console_id = b.console_id, a.console_id
					CurrentPage().focused = p.left_son_id
					return p.left_son_id
				}
			}
		}
	}
	CurrentPage().focused = new_h
	return new_h
}

// 删除 id(或焦点)window:关闭其 console 应用 + 会话,释放窗口,并从树中摘除。
// 目标是唯一剩余窗口(根)时,清空整个树(所有窗口关闭 = 程序可退出)。
DestroyWindow :: proc(id : mem.Handle = {}) -> bool {
	node_h := resolveWindow(id)
	if node_h.id == 0 {
		return false
	}
	node := GetWindowTreeNode(node_h)
	if node == nil || !node.is_leaf {
		return false
	}
	// 单窗模式:被销毁 = 该页 Single 的显示中焦点窗 → 先自动回 Tiled,再走一般销毁
	// (展示目标失效,树不可再无遮挡恢复;隐藏窗/后台页销毁则模式保留)。
	it : mem.Iter(MAX_PAGE_SLOTS, Page) = mem.All(&pages)
	for ph in mem.next(&it) {
		if p := mem.Get(&pages, ph); p != nil && p.view_mode == .Single && p.focused == node_h {
			p.view_mode = .Tiled
		}
	}
	// console 是窗格内容的唯一拥有者(字体/会话/缓冲):销毁它即清空窗格
	DestroyConsole(node.console_id)
	// 唯一剩余窗口(根):清空整个树
	if node_h == WindowTreeRoot() {
		ResetWindowTree()
		CurrentPage().focused = {}
		PageAutoClean() // 页内无窗口:非最后一页自动清出
		return true
	}
	// 变动前:图 BFS 定位最近窗叶,记录其 console_id —— 节点句柄会被摘除/
	// 吸收(提升)改变,console 句柄稳定,变动后按 id 全树找回。
	nearest := nearestWindowLeaf(node_h)
	target_console := mem.Handle {}
	if nearest.id != 0 {
		if nn := GetWindowTreeNode(nearest); nn != nil {
			target_console = nn.console_id
		}
	}
	TreeNodeRemove(node_h)
	// 当前页焦点 = 被删节点:先按 console_id 找回最近窗(变动后树位置)。
	// 必须在 PageClearFocus 之前 —— 它会把当前页焦点改成"整树第一个有窗叶",
	// 导致本分支永远不命中(旧 bug:焦点跳"1"的根源)。
	if CurrentPage().focused == node_h {
		f := mem.Handle {}
		if target_console.id != 0 {
			stack : [MAX_TREE_NODE_SLOTS]mem.Handle
			top := 1
			stack[0] = WindowTreeRoot()
			for top > 0 && f.id == 0 {
				top -= 1
				cur := stack[top]
				n := GetWindowTreeNode(cur)
				if n == nil {
					continue
				}
				if n.is_leaf {
					if n.console_id == target_console {
						f = cur
					}
				} else {
					if n.right_son_id.id != 0 && top < MAX_TREE_NODE_SLOTS {
						stack[top] = n.right_son_id
						top += 1
					}
					if n.left_son_id.id != 0 && top < MAX_TREE_NODE_SLOTS {
						stack[top] = n.left_son_id
						top += 1
					}
				}
			}
		}
		if f.id == 0 {
			f = firstLeaf(WindowTreeRoot()) // 最近窗无 console(空窗格)时退回整树第一个叶
		}
		CurrentPage().focused = f // 0 = 树内无此窗(空页),交由 PageAutoClean 清出
	}
	// 其余页指向该节点的焦点自愈(当前页已找回,不再命中;后台页切回不悬挂)
	PageClearFocus(node_h)
	// 摘除后非根路径也可能触发页空(兄弟提升后无窗口等):统一收尾检查
	PageAutoClean()
	return true
}

// ---------------------------------------------------------------------------
// 分割配置
// ---------------------------------------------------------------------------
// 设置 id(或焦点)窗格父节点的 split_factor(0.05..0.95)
SetSplitFactor :: proc(factor : f32, id : mem.Handle = {}) -> bool {
	if singleGuard() {
		return false // 单窗模式:尺寸调整禁
	}
	node_h := resolveWindow(id)
	if node_h.id == 0 {
		return false
	}
	node := GetWindowTreeNode(node_h)
	if node == nil {
		return false
	}
	return TreeNodeSetSplitFactor(node.parent_id, factor)
}

// 与 id(或焦点)窗格的 dir 方向邻居交换内容:只交换两节点的 console_id,
// 树结构不变。focus 跟随内容:交换后焦点迁往持有"原焦点 console"的节点。
ExchangeWindow :: proc(dir : FocusDirection, id : mem.Handle = {}) -> bool {
	if singleGuard() {
		return false // 单窗模式:交换禁
	}
	node_h := resolveWindow(id)
	if node_h.id == 0 {
		return false
	}
	target := FocusNeighbor(node_h, dir)
	if target.id == 0 {
		return false
	}
	a := GetWindowTreeNode(node_h)
	b := GetWindowTreeNode(target)
	if a == nil || b == nil {
		return false
	}
	a.console_id, b.console_id = b.console_id, a.console_id
	if CurrentPage().focused == node_h {
		CurrentPage().focused = target // 原焦点窗格内容现在挂在 target
	} else if CurrentPage().focused == target {
		CurrentPage().focused = node_h
	}
	return true
}

// 设置先序叶子序号(1-based)认领的 split 节点 factor;无认领(最右叶/越界)返回 false。
// 认领覆盖全部 split(每个内部节点恰一个认领叶),叶子序号即所有 split_factor
// 的统一索引。认领表内嵌于 LeafSplitOwner(局部性,不落包状态)。
SetSplitFactorLeaf :: proc(n : int, factor : f32) -> bool {
	if singleGuard() {
		return false // 单窗模式:尺寸调整禁
	}
	if n < 1 {
		return false
	}
	owner := LeafSplitOwner(n)
	if owner.id == 0 {
		return false
	}
	return TreeNodeSetSplitFactor(owner, factor)
}

// 查询 id(或焦点)窗格父节点的 split_factor(根窗无父 = false)
GetSplitFactor :: proc(id : mem.Handle = {}) -> (f32, bool) {
	node_h := resolveWindow(id)
	if node_h.id == 0 {
		return 0, false
	}
	node := GetWindowTreeNode(node_h)
	if node == nil {
		return 0, false
	}
	parent := GetWindowTreeNode(node.parent_id)
	if parent == nil {
		return 0, false
	}
	return parent.split_factor, true
}

// ---------------------------------------------------------------------------
// 字体加载(表满 = 全部引用在用;引用归零的槽由 RefCounted 自动复用)
// ---------------------------------------------------------------------------
// 引用管理:LoadFont 调用方获得一个引用;窗口持有 font_id 期间引用有效,
// 换字体/销毁窗口时 ReleaseFont(旧引用归零即需可复用)。字体表全局共享。

// 装载变体(失败 = 空引用;成功 = +1 引用;静默:变体缺失是常态)
// 变体名 = font 包的族名/文件双形式推导(见 LoadFontVariant)
loadVariant :: proc(name : string, size : f32, sfx_family, sfx_file : string) -> mem.Handle {
	return fnt.LoadFontVariant(name, size, sfx_family, sfx_file)
}

// 设定 id(或焦点)窗格的字体样式(加载字体文件;LaunchConsole 前必须设置)。
// 空窗格自动创建 console(字体集住在 console 里)。变体:同族
// "X Bold/Italic/Bold Italic" 兄弟文件,有 = 渲染用真 face,无 = 渲染合成(双描/斜切)
// 兜底;font_input 留存原始名(字号重载/继承用,字符串所有权归 console)。
SetConsoleFont :: proc(path : string, size : f32, id : mem.Handle = {}) -> bool {
	if len(path) == 0 {
		return false // 空名称不是合法字体输入
	}
	node_h := resolveWindow(id)
	if node_h.id == 0 {
		fmt.eprintln("SCF: that handle points at nothing. You're dressing a mannequin that was never shipped.")
		return false
	}
	console := ensureConsole(node_h)
	if console == nil {
		fmt.eprintln("SCF: the node's real, but there's no console in it. You knocked on a door that was painted on.")
		return false
	}
	new_font, ok := fnt.LoadFont(path, size)
	if !ok {
		fmt.eprintln("SCF: LoadFont choked on it. kitty would have quietly picked six fallbacks and shaped around your mistake. Wrong path, wrong size, or a file that lies about being a font:", path, size)
		return false
	}
	// 入参可能是本 console 旧 font_input(字号重载 = 自引用调用):先独立持有一份,
	// 否则下方 releaseConsoleFontSet 释放旧名后再 clone 会读到悬垂内存
	name := strings.clone(path)
	// 变体装载(失败 = 空引用不阻塞主字体;静默,变体缺失是常态)
	new_bold := loadVariant(path, size, "Bold", "Bold")
	new_italic := loadVariant(path, size, "Italic", "Italic")
	new_bi := loadVariant(path, size, "Bold Italic", "BoldItalic")
	// 释放旧字体集引用 + 旧输入名;赋新(LoadFont 命中同字体时先 +1 后 -1,净零)
	releaseConsoleFontSet(console)
	console.font_id = new_font
	console.font_bold = new_bold
	console.font_italic = new_italic
	console.font_bold_italic = new_bi
	console.font_input = name
	return true
}

// 设置 id(或焦点)窗格的字体大小(重载完整字体集:同原始名新 size,
// 变体同步重载;失败保留旧字体)
SetConsoleFontSize :: proc(size : f32, id : mem.Handle = {}) -> bool {
	node_h := resolveWindow(id)
	if node_h.id == 0 {
		return false
	}
	console := NodeConsole(node_h)
	if console == nil || console.font_id.id == 0 || console.font_input == "" {
		return false // 未设字体
	}
	return SetConsoleFont(console.font_input, size, node_h)
}

// 增量改字号(绑定 FontSizeUp/Down 的目标;步长由调用方给,命令层用 ±2)
AdjustConsoleFontSize :: proc(delta : f32, id : mem.Handle = {}) -> bool {
	node_h := resolveWindow(id)
	if node_h.id == 0 {
		return false
	}
	console := NodeConsole(node_h)
	if console == nil || console.font_id.id == 0 {
		return false
	}
	return SetConsoleFontSize(fnt.GetFont(console.font_id).size + delta, node_h)
}

// 清空 id(或焦点)窗格的会话:销毁 ConPTY + 缓冲,console 与字体保留,
// 之后可再次 LaunchConsole。与 DestroyWindow 不同,不删窗格。
ClearConsoleSession :: proc(id : mem.Handle = {}) -> bool {
	node_h := resolveWindow(id)
	if node_h.id == 0 {
		fmt.eprintln("CCS: no such node. Wiping a session off a thing that never existed is a very specific kind of denial.")
		return false
	}
	console_h := NodeConsoleId(node_h)
	if console_h.id == 0 {
		fmt.eprintln("CCS: that node never had a console. You cleared nothing and you feel lighter, don't you? That's the scary part.")
		return false
	}
	return consoleClearSession(console_h)
}

// ---------------------------------------------------------------------------
// 会话(Console 应用)
// ---------------------------------------------------------------------------
// launch 语义:在 id(或焦点)窗格启动一个 console 应用。
//   - 窗格空闲(无 console 或无会话)→ 就地启动
//   - 已绑会话 → 自动 split 出兄弟窗格(继承字体)再启动,新窗成为焦点
//   - 明确失败:无可启动节点 / 无字体
LaunchConsole :: proc(cmd : string, id : mem.Handle = {}) -> bool {
	node_h := resolveWindow(id)
	if node_h.id == 0 {
		fmt.eprintln("LC: can't launch into a node that isn't there. Go be real somewhere else, then come back.")
		return false
	}
	console_h := NodeConsoleId(node_h)
	console := GetConsole(console_h)
	// 新会话初始目录(优先级递减):
	//   ① 目标窗格会话自己报告过的目录
	//   ② 焦点窗口会话的目录(新建页时焦点已在新页,查不到就往下)
	//   ③ 任意会话最近报告过的目录(旧页/其他窗口)
	//   ④ 配置默认(命令 `cwd`)
	source_cwd := ""
	if console != nil {
		source_cwd = console.cwd
	}
	if source_cwd == "" {
		source_cwd = GetSessionCwd()
	}
	// 单窗模式:已占用 = 启动会自动分屏(树变),拒绝;空闲 = 就地启动,允许
	if singleGuard() && console != nil && console.conpty_handle.id != 0 {
		return false
	}
	// 已绑会话:不覆盖,split 一个新窗承载新会话(字体继承);
	// 悬挂 console 句柄由 GenArray 判定 == nil,一律视为空闲(自愈清 0)
	if console != nil && console.conpty_handle.id != 0 {
		_, new_h, ok := TreeNodeSplit(node_h, .LeftRight, 0.5)
		if !ok {
			fmt.eprintln("LC: tried to split your pane to make room and the tree shut its legs. Even your data structure is done with you.")
			return false
		}
		new_console := ensureConsole(new_h)
		if new_console == nil {
			fmt.eprintln("LC: split worked and the new pane came out hollow. You built an extra room and forgot the floor.")
			return false
		}
		inheritConsoleFontSet(new_console, console) // 继承完整字体集;引用 ×4
		CurrentPage().focused = new_h
		node_h, console_h, console = new_h, NodeConsoleId(new_h), new_console
	}
	if console == nil || fnt.GetFont(console.font_id) == nil {
		fmt.eprintln("LC: no font -> no cell size -> no console. Alacritty would have silently used a fallback font and let you be wrong. SetConsoleFont first, genius.")
		return false // 未设置字体,先 SetConsoleFont
	}
	conpty_h, ok := ct.CreateConptyContext({80, 24}, cmd, source_cwd)
	if !ok {
		fmt.eprintln("LC: CreateConptyContext died before foreplay. Your command is wrong, cursed, or both:", cmd)
		return false
	}
	if !ct.StartReadThread(conpty_h) {
		fmt.eprintln("LC: pty is up, read thread won't start. You built a mouth and forgot the ears. Useless:", cmd)
		ct.DestroyConpty(conpty_h)
		return false
	}
	// console 已存在(字体集在内):就地绑会话;不存在则新建
	if console_h.id != 0 {
		if !consoleStartSession(console_h, conpty_h, 24, 80) {
			fmt.eprintln("LC: the pty was already in and the session still wouldn't start. Performance issues. I'm pulling out — you get nothing:", cmd)
			ct.StopReadThread(conpty_h)
			ct.DestroyConpty(conpty_h)
			return false
		}
	} else {
		new_h, cok := CreateConsole(24, 80, conpty_h)
		if !cok {
			fmt.eprintln("LC: couldn't create the console itself. kitty does consoles, images and a scripting language, and it's one guy. You have a pty, a font, and nowhere to put them:", cmd)
			ct.StopReadThread(conpty_h)
			ct.DestroyConpty(conpty_h)
			return false
		}
		TreeNodeSetConsole(node_h, new_h)
	}
	return true
}

// 焦点窗口会话报告过的工作目录(OSC 7;"" = 未报告)。`cwd` 查询命令显示它。
FocusedConsoleCwd :: proc() -> string {
	node_h := resolveWindow({})
	if node_h.id == 0 {
		return ""
	}
	console := NodeConsole(node_h)
	if console == nil {
		return ""
	}
	return console.cwd
}

// 焦点窗口所属 console 的应用标题(OSC 0/2 设置;"" = 未设置)。
// OS 窗口标题栏用它;tabbar 仍显示 Page.title —— 用户命名与应用命名互不覆盖。
FocusedAppTitle :: proc() -> string {
	node_h := resolveWindow({})
	if node_h.id == 0 {
		return ""
	}
	console := NodeConsole(node_h)
	if console == nil {
		return ""
	}
	return console.app_title
}

// 通过 conpty 向 id(或焦点)窗格的会话输入字符串。
// 用户输入统一语义:退出 review(历史查看 → 输入即回实时)+ 活动标记
// (输入期间光标暂停闪烁,render 消费)+ 写 ConPTY。
FeedConsole :: proc(data : []byte, id : mem.Handle = {}) -> bool {
	node_h := resolveWindow(id)
	if node_h.id == 0 {
		return false
	}
	console := NodeConsole(node_h)
	if console == nil {
		return false
	}
	exitReview(console) // 输入即回实时(单一写点)
	console.input_activity_ms = inp.NowTicks()
	// conpty 句柄无效(工具 console 等)由 WriteConptyInput 内部返回 false
	_, ok := ct.WriteConptyInput(console.conpty_handle, data)
	return ok
}

// 会话轮询:遍历(只读收集会话状态)→ 处理段(单节点动作)。
// 遍历规范:一次遍历不改多种数据 —— 收集在遍历内,销毁/输出消费是显式处理段。
// 会话结束 = 关闭该窗格(销毁 console + 节点,无 auto_close 开关)。
// 返回 true = 仍有窗格(主循环继续);false = 所有窗格已关闭(程序可退出)。
PollSessions :: proc() -> bool {
	// 遍历(所有页,不只当前页):窗格在 = 程序继续;会话 ended 跨页收集
	ended : [MAX_TREE_NODE_SLOTS]mem.Handle
	ended_count := 0
	alive := false

	pit : mem.Iter(MAX_PAGE_SLOTS, Page) = mem.All(&pages)
	for ph in mem.next(&pit) {
		root := PageTreeRoot(ph)
		if root.id == 0 {
			continue
		}
		leaves : [MAX_TREE_NODE_SLOTS]mem.Handle
		count := 0
		collectLeaves(root, &leaves, &count)
		for i in 0 ..< count {
			node_h := leaves[i]
			console := NodeConsole(node_h)
			if console == nil {
				continue // 空窗格(无 console):不算"窗格存在"
			}
			alive = true // 任一页有窗格内容 = 程序继续(会话可有可无)
			if console.conpty_handle.id == 0 {
				continue // 工具 console:无会话
			}
			// 会话结束 = 主进程退出(GetExitCodeProcess,最终信号)或读线程 dead
			// (管道断开),任一即结束。不能只信读线程:ConPTY 的 conhost 可能保活
			// 管道写端(cmd exit 场景 ReadFile 永不 EOF),只信 Job 又会误杀
			// 脱离 Job 的 msys2 —— 主进程退出与管道断开双信号取或。
			if !ct.IsChildAlive(console.conpty_handle) ||
			   !ct.IsReadThreadAlive(console.conpty_handle) {
				ended[ended_count] = node_h
				ended_count += 1
			}
		}
	}

	// 处理:每项动作(先消费剩余输出,再销毁窗格 = console + 节点)
	for i in 0 ..< ended_count {
		consumeConsoleOutput(ended[i])
		DestroyWindow(ended[i])
	}
	return alive // 所有页都无窗格才退出
}

// 消费单个窗格 console 的剩余输出(会话结束前的最后内容)
consumeConsoleOutput :: proc(node_h : mem.Handle) {
	console := NodeConsole(node_h)
	if console != nil {
		UpdateConsole(NodeConsoleId(node_h))
	}
}

// ---------------------------------------------------------------------------
// 历史滚动(review)
// ---------------------------------------------------------------------------
// 历史滚动,delta 单位 = 行:
//   delta > 0 → 向下翻(看更新的内容);delta < 0 → 向上翻(看旧内容,进入 review)
//   边界:向上翻到历史顶 clamp;向下滚到底(回到最新行)自动退出 review,
//   回到普通模式(实时跟随)。
// 数据模型(单真值):TermBuffer.review_line
//   0              = 普通模式(实时跟随,底行 = 最新行)
//   n (1..)        = review 模式,值 = 窗口底行物理索引 + 1;绝对锚定:
//                    新输出到达时不动(视口内容稳定),trim 裁剪时平移补偿
//   滚回最新       = review_line 置 0(与"底行索引+1 == len"等价,避免
//                    "底行 = 0"与普通模式哨兵冲突)
// 输入即退出 review 由 FeedConsole 统一承担(用户输入语义内聚)。
ConsoleScroll :: proc(delta : int, id : mem.Handle = {}) -> bool {
	node_h := resolveWindow(id)
	if node_h.id == 0 {
		return false
	}
	console := NodeConsole(node_h)
	if console == nil {
		return false
	}
	tb := GetTermBuffer(console.active_term_buffer_id)
	if tb == nil {
		return false
	}
	cur := int(tb.review_line) - 1
	if tb.review_line == 0 {
		cur = len(tb.lines) - 1 // 普通模式起点 = 最新底行
	}
	nl := clamp(cur + delta, 0, len(tb.lines) - 1)
	if nl >= len(tb.lines) - 1 {
		tb.review_line = 0 // 滚回最新 = 普通模式
	} else {
		tb.review_line = u32(nl + 1)
	}
	return true
}

// 退出 review 回普通模式(实时跟随);无会话 = false。键盘输入路径见 FeedConsole。
ConsoleExitReview :: proc(id : mem.Handle = {}) -> bool {
	node_h := resolveWindow(id)
	if node_h.id == 0 {
		return false
	}
	console := NodeConsole(node_h)
	if console == nil {
		return false
	}
	return exitReview(console)
}

// review 退出的唯一写点(输入 / 命令 / 将来入口都走这里)
exitReview :: proc(console : ^Console) -> bool {
	tb := GetTermBuffer(console.active_term_buffer_id)
	if tb == nil {
		return false
	}
	tb.review_line = 0
	return true
}

// ---------------------------------------------------------------------------
// 焦点
// ---------------------------------------------------------------------------
// 设置 id 为当前焦点
SetFocusWindow :: proc(id : mem.Handle) -> bool {
	if singleGuard() {
		return false // 单窗模式:焦点切换禁
	}
	if GetWindowTreeNode(id) == nil {
		return false
	}
	p := CurrentPage()
	if p == nil {
		return false
	}
	p.focused = id
	return true
}

// 将 id(或焦点)窗格的 dir 方向邻居设为焦点
FocusMove :: proc(dir : FocusDirection, id : mem.Handle = {}) -> bool {
	if singleGuard() {
		return false // 单窗模式:焦点切换禁
	}
	node_h := resolveWindow(id)
	if node_h.id == 0 {
		return false
	}
	target := FocusNeighbor(node_h, dir)
	if target.id == 0 {
		return false
	}
	CurrentPage().focused = target
	return true
}

// 查询当前焦点 window(节点 handle)
GetFocusWindow :: proc() -> mem.Handle {
	p := CurrentPage()
	if p == nil {
		return {}
	}
	return p.focused
}

// ---------------------------------------------------------------------------
// 查询
// ---------------------------------------------------------------------------
// 统计当前页 leaf(窗格)数量(含尚未建 console 的空窗格)
ConsoleCount :: proc() -> int {
	count := 0
	countLeaves(WindowTreeRoot(), &count)
	return count
}

// 窗格信息快照(派生量按值返回,同 fnt.GetMetrics 的做法;font_name 借用 console
// 持有的字符串,console 销毁即失效 —— 只读展示用)。空窗格 = has_console false。
ConsoleInfo :: struct {
	node : mem.Handle,
	has_console : bool,
	has_session : bool, // conpty_handle != 0
	font_name : string, // 原始字体输入名(font_input)
	font_size : f32,
	bold_face : bool, // 有真 Bold 变体(否则渲染合成)
	italic_face : bool,
	bi_face : bool,
	rows, cols : u16,
	review_line : u32, // 0 = 普通模式
	split_factor : f32, // 父节点比例(根窗 = 0)
}

GetConsoleInfo :: proc(id : mem.Handle = {}) -> (info : ConsoleInfo, ok : bool) {
	node_h := resolveWindow(id)
	if node_h.id == 0 {
		return {}, false
	}
	node := GetWindowTreeNode(node_h)
	if node == nil || !node.is_leaf {
		return {}, false
	}
	info.node = node_h
	if parent := GetWindowTreeNode(node.parent_id); parent != nil {
		info.split_factor = parent.split_factor
	}
	console := NodeConsole(node_h)
	if console == nil {
		return info, true // 空窗格
	}
	info.has_console = true
	info.has_session = console.conpty_handle.id != 0
	info.font_name = console.font_input
	info.bold_face = console.font_bold.id != 0
	info.italic_face = console.font_italic.id != 0
	info.bi_face = console.font_bold_italic.id != 0
	if f := fnt.GetFont(console.font_id); f != nil {
		info.font_size = f.size
	}
	info.rows, info.cols = console.rows, console.cols
	if tb := GetTermBuffer(console.active_term_buffer_id); tb != nil {
		info.review_line = tb.review_line
	}
	return info, true
}

// ---------------------------------------------------------------------------
// 内部辅助
// ---------------------------------------------------------------------------
// 单窗模式守卫:当前页 view_mode == .Single 时,树/焦点/尺寸类操作一律拒绝。
// 页规则集中在这一处(域边界守点):命令栏、绑定、指令通道、任何将来入口
// 都经本层 userapi 生效;命令解释层不重复判定。
singleGuard :: proc() -> bool {
	p := CurrentPage()
	return p != nil && p.view_mode == .Single
}

// id 省略(0)时解析为当前焦点
resolveWindow :: proc(id : mem.Handle) -> mem.Handle {
	if id.id != 0 {
		return id
	}
	p := CurrentPage()
	if p == nil {
		return {}
	}
	return p.focused
}

