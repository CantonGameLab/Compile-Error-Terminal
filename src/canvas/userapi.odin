// 用户接口层:面向意图的函数族(窗口生命周期/会话/字体/滚动),
// CommandBar 与子进程指令通道(parser)的绑定目标;id 省略 = 当前焦点。
package canvas

import ct "../conpty"
import fnt "../font"
import inp "../input"
import mem "../memory"
import "core:fmt"
import "core:strings"

// ---------------------------------------------------------------------------
// 默认启动配置(新建窗口时自动应用;cmd 留空 = 不自动启动)
// ---------------------------------------------------------------------------
// 状态属于用户接口层配置:userapi 设置生效于之后创建的窗口
// (CreateWindowTreeRoot / SplitNewWindow),对已有窗口不追溯。
// cmd 非空但 font 为空时,LaunchConsole 因无字体失败(启动前必须可设字体);
// 正常用法是 cmd+font+size 一起设置,或全部留空 = 窗口不启动。
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

// 新建窗口的自动应用:先字体后启动(先设字体,应用才能挂上)。
// 只应用于创建瞬间,不影响窗口后续手动操作。
applyDefaultLaunch :: proc(node_h : mem.Handle) {
	if node_h.id == 0 {
		return
	}
	d := &default_launch
	if d.font != "" {
		SetWindowFont(d.font, d.size, node_h)
	}
	if d.cmd != "" {
		if !LaunchConsole(d.cmd, node_h) {
			fmt.eprintln("default launch failed:", d.cmd)
		}
	}
}

// ---------------------------------------------------------------------------
// 窗口树
// ---------------------------------------------------------------------------
// 当前页建根窗(页根已由 PageCreate 分配):挂新窗(幂等)+ 默认启动配置应用 + 设焦点。
CreateWindowTreeRoot :: proc() -> mem.Handle {
	root := WindowTreeRoot()
	if root.id == 0 {
		return {}
	}
	if NodeWindow(root) == nil {
		win_h := CreateWindow()
		if win_h.id != 0 {
			TreeNodeSetWindow(root, win_h)
		}
	}
	applyDefaultLaunch(root)
	CurrentPage().focused = root // 焦点 = 页字段,直接操作
	return root
}

// 对 id(或焦点)window 按轴分裂出新 window:自动分配窗口对象(空白窗格,
// 后续 SetWindowFont/launch/工具直接可用);新窗成为焦点。
// new_on_first = 新窗放首侧(左/上):分裂后交换左右子窗内容 ——
// split left/up 即"新窗在左/上、原窗在右/下"(默认 false = 右/下)。
// 树级 TreeNodeSplit 保持纯结构;窗口分配在用户语义层(SplitNewWindow)完成。
// 新窗按默认启动配置应用(cmd 留空 = 空白窗格不启动)。
SplitNewWindow :: proc(dir : SplitType, id : mem.Handle = {}, new_on_first := false) -> mem.Handle {
	if singleGuard() {
		return {} // 单窗模式:分屏禁
	}
	node_h := resolveWindow(id)
	if node_h.id == 0 {
		return {}
	}
	_, new_h, ok := TreeNodeSplit(node_h, dir, 0.5)
	if !ok {
		return {}
	}
	ensureWindow(new_h) // 分配窗口对象(建窗失败不阻塞 split;按需补建,幂等)
	applyDefaultLaunch(new_h)
	// 新窗在首侧:交换两子窗内容(携带会话的窗口对象随节点走),焦点 = 首侧
	if new_on_first {
		if n := GetWindowTreeNode(new_h); n != nil {
			if p := GetWindowTreeNode(n.parent_id); p != nil {
				a := GetWindowTreeNode(p.left_son_id)
				b := GetWindowTreeNode(p.right_son_id)
				if a != nil && b != nil {
					a.window_id, b.window_id = b.window_id, a.window_id
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
	win_h := node.window_id
	if win := GetWindow(node.window_id); win != nil {
		// 关闭会话:先断引用再销毁(GenArray 句柄各自判定,DestroyConsole 只销毁本体)
		clearConsoleRefs(win.console_id)
		DestroyConsole(win.console_id)
		// 窗口槽释放内含字体引用释放(ReleaseFont)
		DestroyWindowSlot(win_h)
	}
	// 唯一剩余窗口(根):清空整个树
	if node_h == WindowTreeRoot() {
		ResetWindowTree()
		CurrentPage().focused = {}
		PageAutoClean() // 页内无窗口:非最后一页自动清出
		return true
	}
	// 变动前:图 BFS 定位最近有窗叶,记录其 window_id —— 节点句柄会被摘除/
	// 吸收(提升)改变,窗口对象 id 稳定,变动后按 id 全树找回。
	nearest := nearestWindowLeaf(node_h)
	target_win := mem.Handle {}
	if nearest.id != 0 {
		if nn := GetWindowTreeNode(nearest); nn != nil {
			target_win = nn.window_id
		}
	}
	TreeNodeRemove(node_h)
	// 当前页焦点 = 被删节点:先按 window_id 找回最近窗(变动后树位置)。
	// 必须在 PageClearFocus 之前 —— 它会把当前页焦点改成"整树第一个有窗叶",
	// 导致本分支永远不命中(旧 bug:焦点跳"1"的根源)。
	if CurrentPage().focused == node_h {
		f := mem.Handle {}
		if target_win.id != 0 {
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
					if n.window_id == target_win {
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
// 设置 id(或焦点)window 的父节点 split_factor(0.05..0.95)
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

// 与 id(或焦点)window 的 dir 方向邻居交换窗口内容:只交换两节点的 window_id,
// 树结构不变。focus 跟随 window:交换后焦点迁往持有"原焦点窗口"的节点。
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
	a.window_id, b.window_id = b.window_id, a.window_id
	if CurrentPage().focused == node_h {
		CurrentPage().focused = target // 原焦点窗口现在挂在 target
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

// 设定 id(或焦点)window 的字体样式(加载字体文件;LaunchConsole 前必须设置)。
// 节点无窗口时自动创建窗口。变体:同族 "X Bold/Italic/Bold Italic" 兄弟文件,
// 有 = 渲染用真 face,无 = 渲染合成(双描/斜切)兜底;font_input 留存原始名
// (字号重载/继承用,字符串所有权归窗口)。
SetWindowFont :: proc(path : string, size : f32, id : mem.Handle = {}) -> bool {
	if len(path) == 0 {
		return false // 空名称不是合法字体输入
	}
	node_h := resolveWindow(id)
	if node_h.id == 0 {
		fmt.eprintln("SWF: no window")
		return false
	}
	win := ensureWindow(node_h)
	if win == nil {
		fmt.eprintln("SWF: no win obj")
		return false
	}
	new_font, ok := fnt.LoadFont(path, size)
	if !ok {
		fmt.eprintln("SWF: LoadFont failed:", path, size)
		return false
	}
	// 入参可能是本窗口旧 font_input(字号重载 = 自引用调用):先独立持有一份,
	// 否则下方 releaseFontSet 释放旧名后再 clone 会读到悬垂内存
	name := strings.clone(path)
	// 变体装载(失败 = 空引用不阻塞主字体;静默,不刷错误日志)
	new_bold := mem.Handle {}
	new_italic := mem.Handle {}
	new_bi := mem.Handle {}
	if len(path) > 0 {
		new_bold = loadVariant(path, size, "Bold", "Bold")
		new_italic = loadVariant(path, size, "Italic", "Italic")
		new_bi = loadVariant(path, size, "Bold Italic", "BoldItalic")
	}
	// 释放旧字体集引用 + 旧输入名;赋新(LoadFont 命中同字体时先 +1 后 -1,净零)
	releaseFontSet(win)
	win.font_id = new_font
	win.font_bold = new_bold
	win.font_italic = new_italic
	win.font_bold_italic = new_bi
	win.font_input = name
	return true
}

// 设置 id(或焦点)window 的字体大小(重载完整字体集:同原始名新 size,
// 变体同步重载;失败保留旧字体)
SetWindowFontSize :: proc(size : f32, id : mem.Handle = {}) -> bool {
	node_h := resolveWindow(id)
	if node_h.id == 0 {
		return false
	}
	win := NodeWindow(node_h)
	if win == nil || win.font_id.id == 0 || win.font_input == "" {
		return false // 未设字体
	}
	return SetWindowFont(win.font_input, size, node_h)
}

// 增量改字号(快捷键 FontSizeUp/Down 的绑定目标;步长 1)
AdjustFontSize :: proc(delta : f32, id : mem.Handle = {}) -> bool {
	node_h := resolveWindow(id)
	if node_h.id == 0 {
		return false
	}
	win := NodeWindow(node_h)
	if win == nil || win.font_id.id == 0 {
		return false
	}
	return SetWindowFontSize(fnt.GetFont(win.font_id).size + delta, node_h)
}

// 清空 id(或焦点)window 的会话:销毁其 console + ConPTY,窗口与字体保留,
// 之后可再次 LaunchConsole。与 DestroyWindow 不同,不删窗口。
ClearWindowConsole :: proc(id : mem.Handle = {}) -> bool {
	node_h := resolveWindow(id)
	if node_h.id == 0 {
		fmt.eprintln("CWC: no node")
		return false
	}
	win := NodeWindow(node_h)
	if win == nil || GetConsole(win.console_id) == nil { // 句柄有效性由 GenArray 判定
		fmt.eprintln("CWC: no console")
		return false
	}
	clearConsoleRefs(win.console_id)
	DestroyConsole(win.console_id)
	return true
}

// 断掉所有指向 console_h 的引用(窗口 console_id)。
// 窗口层销毁会话前的第一步:避免悬挂句柄让"空闲窗口"被误判占用。
clearConsoleRefs :: proc(h : mem.Handle) {
	it : mem.Iter(MAX_WINDOW_SLOTS, Window) = mem.All(&windows)
	for wh in mem.next(&it) {
		if w := mem.Get(&windows, wh); w != nil {
			if w.console_id == h {
				w.console_id = {}
			}
		}
	}
}

// ---------------------------------------------------------------------------
// 会话(Console 应用)
// ---------------------------------------------------------------------------
// launch 语义:在 id(或焦点)window 启动一个 console 应用。
//   - 窗口空闲(无 console)→ 直接启动
//   - 已被占用 → 自动 split 出兄弟窗(继承字体)再启动,新窗成为焦点
//   - 明确失败:无可启动节点 / 无字体
LaunchConsole :: proc(cmd : string, id : mem.Handle = {}) -> bool {
	node_h := resolveWindow(id)
	if node_h.id == 0 {
		fmt.eprintln("LC: no node")
		return false
	}
	win := NodeWindow(node_h)
	if win == nil {
		win = ensureWindow(node_h)
		if win == nil {
			fmt.eprintln("LC: no win obj")
			return false
		}
	}
	// 单窗模式:已占用 = 启动会自动分屏(树变),拒绝;空闲 = 就地启动,允许
	if singleGuard() && GetConsole(win.console_id) != nil {
		return false
	}
	// 已有有效 console:不覆盖,split 一个新窗承载新会话;
	// 空/悬挂引用由 GenArray 判定 == nil,一律视为空闲(自愈清 0)
	if GetConsole(win.console_id) != nil {
		_, new_h, ok := TreeNodeSplit(node_h, .LeftRight, 0.5)
		if !ok {
			fmt.eprintln("LC: split failed")
			return false
		}
		win2 := ensureWindow(new_h)
		if win2 == nil {
			fmt.eprintln("LC: no win obj (new)")
			return false
		}
		inheritFontSet(win2, win) // 继承完整字体集(已有 console 说明已设字体);引用 ×4
		CurrentPage().focused = new_h
		node_h, win = new_h, win2
	} else {
		win.console_id = {}
	}
	if fnt.GetFont(win.font_id) == nil {
		fmt.eprintln("LC: no font")
		return false // 未设置字体,先 SetWindowFont
	}
	conpty_h, ok := ct.CreateConptyContext({80, 24}, cmd)
	if !ok {
		fmt.eprintln("LC: CreateConptyContext failed:", cmd)
		return false
	}
	if !ct.StartReadThread(conpty_h) {
		fmt.eprintln("LC: StartReadThread failed:", cmd)
		ct.DestroyConpty(conpty_h)
		return false
	}
	console_h, cok := CreateConsole(24, 80, conpty_h)
	if !cok {
		fmt.eprintln("LC: CreateConsole failed:", cmd)
		ct.StopReadThread(conpty_h)
		ct.DestroyConpty(conpty_h)
		return false
	}
	win.console_id = console_h
	win.auto_close = true // 默认:应用退出即自动关窗;SetAutoClose(false) 可关闭
	return true
}

// 通过 conpty 向 id(或焦点)window 的 console 应用输入字符串。
// 用户输入统一语义:退出 review(历史查看 → 输入即回实时)+ 活动标记
// (输入期间光标暂停闪烁,render 消费)+ 写 ConPTY。
FeedConsole :: proc(data : []byte, id : mem.Handle = {}) -> bool {
	node_h := resolveWindow(id)
	if node_h.id == 0 {
		return false
	}
	win := NodeWindow(node_h)
	if win == nil {
		return false
	}
	console := GetConsole(win.console_id)
	if console == nil {
		return false
	}
	if tb := GetTermBuffer(console.active_term_buffer_id); tb != nil {
		tb.review_line = 0 // 输入即回普通模式(实时跟随)
	}
	console.input_activity_ms = inp.NowTicks()
	// conpty 句柄无效(工具 console 等)由 WriteConptyInput 内部返回 false
	_, ok := ct.WriteConptyInput(console.conpty_handle, data)
	return ok
}

// 设置 id(或焦点)window 在 console 应用退出后是否自动销毁
SetAutoClose :: proc(auto_close : bool, id : mem.Handle = {}) -> bool {
	node_h := resolveWindow(id)
	if node_h.id == 0 {
		return false
	}
	win := ensureWindow(node_h)
	if win == nil {
		return false
	}
	win.auto_close = auto_close
	return true
}

// 会话轮询:遍历(只读收集会话状态)→ 处理段(单窗口动作)。
// 遍历规范:一次遍历不改多种数据 —— 收集在遍历内,销毁/输出消费是显式处理段。
// 返回 true = 仍有窗口(主循环继续);false = 所有窗口已关闭(程序可退出)。
PollSessions :: proc() -> bool {
	// 遍历(所有页,不只当前页):窗口在 = 程序继续;会话 ended 跨页收集
	SessionEnded :: struct {
		node_h : mem.Handle,
		auto_close : bool,
	}
	ended : [MAX_TREE_NODE_SLOTS]SessionEnded
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
			win := NodeWindow(node_h)
			if win == nil {
				continue // 无窗口
			}
			alive = true // 任一页有窗口 = 程序继续(会话可有可无)
			console := GetConsole(win.console_id)
			if console == nil {
				continue // 空窗口/悬挂引用,无会话
			}
			// 会话结束 = 主进程退出(GetExitCodeProcess,最终信号)或读线程 dead
			// (管道断开),任一即结束。不能只信读线程:ConPTY 的 conhost 可能保活
			// 管道写端(cmd exit 场景 ReadFile 永不 EOF),只信 Job 又会误杀
			// 脱离 Job 的 msys2 —— 主进程退出与管道断开双信号取或。
			if !ct.IsChildAlive(console.conpty_handle) ||
			   !ct.IsReadThreadAlive(console.conpty_handle) {
				ended[ended_count] = SessionEnded { node_h = node_h, auto_close = win.auto_close }
				ended_count += 1
			}
		}
	}

	// 处理:每项动作(先消费剩余输出,再按 auto_close 销毁窗口)
	for i in 0 ..< ended_count {
		updateWindow(ended[i].node_h)
		if ended[i].auto_close {
			DestroyWindow(ended[i].node_h)
		}
	}
	return alive // 所有页都无窗口才退出
}

// 消费单个窗口 console 的剩余输出(会话结束前的最后内容)
updateWindow :: proc(node_h : mem.Handle) {
	win := NodeWindow(node_h)
	if win != nil {
		UpdateConsole(win.console_id) // 内部判 console 有效
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
	win := NodeWindow(node_h)
	if win == nil {
		return false
	}
	console := GetConsole(win.console_id)
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

// 将 id(或焦点)window 的 dir 方向指向的 window 设为焦点
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
// 枚举
// ---------------------------------------------------------------------------
// 统计当前 leaf(window)数量
WindowCount :: proc() -> int {
	count := 0
	countLeaves(WindowTreeRoot(), &count)
	return count
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

