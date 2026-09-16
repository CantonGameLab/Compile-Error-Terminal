// 页数据:每页一棵独立窗口树(页持有根句柄 + 页内焦点 + 显示模式)。
// 一棵树 = 一个"标签页":树节点表/console/font/window 均全局,页只是组织层
// (根引用 + 焦点记忆 + 显示模式);句柄体系不变(id+世代全局唯一,页切换无迁移)。
// 根槽不再固定:根 = 普通 Alloc(parent_id = 0),页槽持有;根壳常驻/吸收逻辑不变。
package canvas

import mem "../memory"
import fnt "../font"
import "core:fmt"

MAX_PAGE_SLOTS :: 16

// 底部页签条(状态栏雏形)高度;树区高度 = 窗口物理高 - BAR。
// 页签矩形 = 满条高:激活页签背景直通条上下边,与内容区背景连续(WT 式背景延伸)。
TAB_BAR_HEIGHT :: f32(32)

// 页签条内页签尺寸(渲染与命中共用)
TAB_PAD_X :: f32(12)
TAB_MIN_W :: f32(80)
TAB_MAX_W :: f32(240)
TAB_GAP :: f32(3)
NEW_TAB_W :: f32(26) // "+" 新建按钮宽

// 条内右侧工具区(固定宽,从右往左):FPS 标签 + 命令栏输入框
CMD_VIEW_W :: f32(320) // 命令栏输入框宽
FPS_TAG_W :: f32(64) // FPS 标签宽
TOOL_GAP :: f32(6) // 工具区与页签区最小间距

// 页显示模式:焦点窗如何占用树区(状态类参量一律枚举)
PageMode :: enum u8 {
	Tiled,   // 平铺:按树几何显示全部窗口(默认;零值 = 安全空态)
	Single,  // 单窗:焦点窗独占树区显示,树结构不动
}

Page :: struct {
	title : [32]u8, // 页标题(定长,截断;默认 = 页序号)
	title_len : u8,
	tree_root : mem.Handle, // 本页树根(空叶;页销毁时整树释放)
	focused : mem.Handle, // 页内焦点(每页记忆,切换即复用,无同步)
	view_mode : PageMode, // 显示模式;写者 = SetSingleMode + DestroyWindow(销毁显示窗自愈回 Tiled)
}

pages : mem.GenArray(MAX_PAGE_SLOTS, Page)
current_page : mem.Handle // 当前页;0 = 无页(程序空态)

// ---------------------------------------------------------------------------
// 生命周期
// ---------------------------------------------------------------------------
// 建页:分配页槽 + 根节点(空叶,几何 = 当前窗口区尺寸;无窗)
PageCreate :: proc() -> mem.Handle {
	root := CreateWindowTreeNode()
	if root.id == 0 {
		return {}
	}
	if n := GetWindowTreeNode(root); n != nil {
		n.position_x = 0
		n.position_y = 0
		n.width = f32(Window_Width)
		n.height = f32(Window_Height)
	}
	page_h := mem.Alloc(&pages, Page {
		tree_root = root,
	})
	if page_h.id == 0 {
		mem.Free(&window_tree_nodes, root)
		return {}
	}
	pageSetTitleNum(page_h, page_h.id)
	return page_h
}

// 新建页并切换:页 + 根窗(默认启动配置自动应用)+ 成为当前页
PageNew :: proc() -> mem.Handle {
	page_h := PageCreate()
	if page_h.id == 0 {
		return {}
	}
	PageSwitch(page_h)
	if PageTreeRoot(page_h).id != 0 {
		CreateWindowTreeRoot() // 当前页建根窗(applyDefaultLaunch)
	}
	return page_h
}

// 关页:先销毁整树(会话 → 窗口槽 → 节点),再释放页槽。
// 最后一页拒绝(页空但存在;全部页无存活会话时主循环退出)。
PageDestroy :: proc(page_h : mem.Handle) -> bool {
	if mem.Get(&pages, page_h) == nil {
		return false
	}
	if PageCount() <= 1 {
		return false
	}
	destroyPageTree(PageTreeRoot(page_h))
	mem.Free(&pages, page_h)
	if current_page == page_h {
		current_page = {}            // 临时空;切到相邻页(存活序环绕)
		if !PageNext() {
			PagePrev()
		}
	}
	return true
}

// 自动清出:页内所有窗格已销毁(用户关光/会话结束)→ 自动关页;
// 最后一页保留(空态等主循环判定退出)。当前页销毁后重新遍历,直至稳定。
PageAutoClean :: proc() {
	for {
		if PageCount() <= 1 {
			return // 最后一页保留
		}
		cleaned := false
		it : mem.Iter(MAX_PAGE_SLOTS, Page) = mem.All(&pages)
		for ph in mem.next(&it) {
			if p := mem.Get(&pages, ph); p != nil {
				if firstLeafWithConsole(p.tree_root).id == 0 {
					PageDestroy(ph)
					cleaned = true
					break // 页销毁后句柄/焦点迁移,重新遍历
				}
			}
		}
		if !cleaned {
			return
		}
	}
}

// 整树销毁:leaf 的 console(会话/字体/缓冲)先销毁,再递归释放节点(含根)
destroyPageTree :: proc(root : mem.Handle) {
	if root.id == 0 {
		return
	}
	leaves : [MAX_TREE_NODE_SLOTS]mem.Handle
	count := 0
	collectLeaves(root, &leaves, &count)
	for i in 0 ..< count {
		node := GetWindowTreeNode(leaves[i])
		if node != nil {
			DestroyConsole(node.console_id)
		}
	}
	TreeNodeRemoveAll(root)
}

// ---------------------------------------------------------------------------
// 切换
// ---------------------------------------------------------------------------
// 切页:页焦点即页字段,无需同步;当前页帧内自动布局(几何已按最新尺寸)
PageSwitch :: proc(page_h : mem.Handle) -> bool {
	if mem.Get(&pages, page_h) == nil {
		return false
	}
	current_page = page_h
	return true
}

// ---------------------------------------------------------------------------
// 显示模式(页属性):Tiled 平铺 / Single 单窗(焦点窗独占树区,树不动)
// ---------------------------------------------------------------------------
// userapi:设置当前页显示模式(on = Single);返回是否生效。
// 语义:树结构零改动;布局/渲染/鼠标按 有效矩形(WindowEffectiveRect)覆盖解释。
// 写者 = SetSingleMode(唯一)+ DestroyWindow(销毁显示中的焦点窗先自动回 Tiled)。
SetSingleMode :: proc(on : bool) -> bool {
	p := CurrentPage()
	if p == nil {
		return false
	}
	p.view_mode = on ? .Single : .Tiled
	return true
}

// userapi:翻转当前页模式;返回翻转后是否 Single(绑定目标)
ToggleSingleMode :: proc() -> bool {
	p := CurrentPage()
	if p == nil {
		return false
	}
	SetSingleMode(p.view_mode != .Single)
	return p.view_mode == .Single
}

PageNext :: proc() -> bool {
	return pageShift(1)
}

PagePrev :: proc() -> bool {
	return pageShift(-1)
}

pageShift :: proc(d : int) -> bool {
	if PageCount() < 1 {
		return false
	}
	cur := pageIndexInAlive(current_page)
	if cur < 0 {
		// 空位兜底(如刚销毁当前页):直接取第一存活页
		h := PageByIndex(1)
		if h.id == 0 {
			return false
		}
		return PageSwitch(h)
	}
	n := (cur + d + PageCount()) % PageCount()
	h := PageByIndex(n + 1) // 1-based
	if h.id == 0 {
		return false
	}
	return PageSwitch(h)
}

// 当前页在存活序中的位置(0-based);-1 = 无
pageIndexInAlive :: proc(page_h : mem.Handle) -> int {
	it : mem.Iter(MAX_PAGE_SLOTS, Page) = mem.All(&pages)
	idx := 0
	for h in mem.next(&it) {
		if h == page_h {
			return idx
		}
		idx += 1
	}
	return -1
}

// ---------------------------------------------------------------------------
// 查询
// ---------------------------------------------------------------------------
PageCount :: proc() -> int {
	it : mem.Iter(MAX_PAGE_SLOTS, Page) = mem.All(&pages)
	count := 0
	for _ in mem.next(&it) {
		count += 1
	}
	return count
}

PageCurrent :: proc() -> mem.Handle {
	return current_page
}

// 当前页数据指针(原结构体):页字段(焦点/标题/根)读写直接经它操作,
// 不再提供 Set/Get 包装;无页 = nil(主循环下页恒存在)。
CurrentPage :: proc() -> ^Page {
	return mem.Get(&pages, current_page)
}

// 存活序第 n 个页(1-based)
PageByIndex :: proc(n : int) -> mem.Handle {
	it : mem.Iter(MAX_PAGE_SLOTS, Page) = mem.All(&pages)
	idx := 0
	for h in mem.next(&it) {
		idx += 1
		if idx == n {
			return h
		}
	}
	return {}
}

// 页树根(页不存在 = 0)
PageTreeRoot :: proc(page_h : mem.Handle) -> mem.Handle {
	if p := mem.Get(&pages, page_h); p != nil {
		return p.tree_root
	}
	return {}
}

// 页标题(渲染/页签借用,只读;截断 31 字节)
PageTitle :: proc(page_h : mem.Handle) -> string {
	if p := mem.Get(&pages, page_h); p != nil {
		return string(p.title[:p.title_len])
	}
	return ""
}

PageSetTitle :: proc(page_h : mem.Handle, s : string) -> bool {
	p := mem.Get(&pages, page_h)
	if p == nil {
		return false
	}
	n := min(len(s), 31)
	copy(p.title[:n], s)
	p.title_len = u8(n)
	return true
}

pageSetTitleNum :: proc(page_h : mem.Handle, n : u32) {
	p := mem.Get(&pages, page_h)
	if p == nil {
		return
	}
	s := fmt.aprintf("%d", n)
	defer delete(s) // aprintf 用 context.allocator,与 delete 匹配
	nn := min(len(s), 31)
	copy(p.title[:nn], s)
	p.title_len = u8(nn)
}

// ---------------------------------------------------------------------------
// 页签几何(渲染与命中共用同一公式;按存活序从左到右)
// ---------------------------------------------------------------------------
// 页签 index(0-based 存活序)矩形(绝对屏幕坐标,含条内定位)
PageTabRect :: proc(index : int) -> (rect : Transform, ok : bool) {
	page_h := PageByIndex(index + 1)
	if page_h.id == 0 {
		return {}, false
	}
	w := tabWidth(page_h)
	x := tabAreaX(index)
	bar_top := f32(Window_Height) // 内容区底 = 条顶;页签满条高(背景延伸)
	return Transform {
		position_x = x,
		position_y = bar_top,
		width = w,
		height = TAB_BAR_HEIGHT,
	}, true
}

// "+" 新建按钮矩形
NewTabRect :: proc() -> Transform {
	bar_top := f32(Window_Height)
	return Transform {
		position_x = tabAreaX(pageCountAlive()) + TAB_GAP,
		position_y = bar_top,
		width = NEW_TAB_W,
		height = TAB_BAR_HEIGHT,
	}
}

// 页签序 x 起点(左侧留 6px 边)
tabAreaX :: proc(index : int) -> f32 {
	x := f32(6) + NEW_TAB_W + TAB_GAP * 2
	for i in 0 ..< index {
		page_h := PageByIndex(i + 1)
		if page_h.id == 0 {
			break
		}
		x += tabWidth(page_h) + TAB_GAP
	}
	return x
}

// 页签宽(标题度量 + padding,clamp 最小/最大)
tabWidth :: proc(page_h : mem.Handle) -> f32 {
	m := fnt.GetMetrics(GetUIFont())
	text_w := f32(len(PageTitle(page_h))) * m.cell_width
	w := text_w + TAB_PAD_X * 2
	if w < TAB_MIN_W {
		w = TAB_MIN_W
	}
	if w > TAB_MAX_W {
		w = TAB_MAX_W
	}
	return w
}

pageCountAlive :: proc() -> int {
	return PageCount()
}

// 命令栏输入框矩形(条内右侧;可见时绘制/命中保护用)
CommandBarRect :: proc() -> Transform {
	bar_top := f32(Window_Height)
	return Transform {
		position_x = f32(Window_Width) - FPS_TAG_W - TOOL_GAP - CMD_VIEW_W,
		position_y = bar_top,
		width = CMD_VIEW_W,
		height = TAB_BAR_HEIGHT,
	}
}

// FPS 标签矩形(条内最右角)
FpsTagRect :: proc() -> Transform {
	bar_top := f32(Window_Height)
	return Transform {
		position_x = f32(Window_Width) - FPS_TAG_W,
		position_y = bar_top,
		width = FPS_TAG_W,
		height = TAB_BAR_HEIGHT,
	}
}

// 页签条命中:返回命中元素(index 0-based 页签 / -1 = "+" 按钮)
TabBarHit :: proc(x, y : f32) -> (kind : TabHitKind, index : int) {
	if y < f32(Window_Height) {
		return .None, -1
	}
	// 右侧工具区(命令栏/FPS)优先排除:与页签区互不侵入
	if cr := CommandBarRect(); x >= cr.position_x {
		return .None, -1
	}
	n := pageCountAlive()
	for i in 0 ..< n {
		rect, ok := PageTabRect(i)
		if ok && x >= rect.position_x && x < rect.position_x + rect.width &&
			y >= rect.position_y && y < rect.position_y + rect.height {
			return .Tab, i
		}
	}
	nr := NewTabRect()
	if x >= nr.position_x && x < nr.position_x + nr.width &&
		y >= nr.position_y && y < nr.position_y + nr.height {
		return .NewPage, -1
	}
	return .None, -1
}

TabHitKind :: enum u8 {
	None,
	Tab,
	NewPage,
}

// ---------------------------------------------------------------------------
// 焦点自愈
// ---------------------------------------------------------------------------
// 节点被销毁时清理所有页中指向它的焦点(后台页切回时焦点不悬挂)
PageClearFocus :: proc(node_h : mem.Handle) {
	it : mem.Iter(MAX_PAGE_SLOTS, Page) = mem.All(&pages)
	for ph in mem.next(&it) {
		if p := mem.Get(&pages, ph); p != nil && p.focused == node_h {
			p.focused = firstLeafWithConsole(p.tree_root) // 0 = 无窗格
		}
	}
}

// 子树中最左的有 console 的 leaf;无 = 0
firstLeafWithConsole :: proc(root : mem.Handle) -> mem.Handle {
	leaves : [MAX_TREE_NODE_SLOTS]mem.Handle
	count := 0
	collectLeaves(root, &leaves, &count)
	for i in 0 ..< count {
		if NodeConsole(leaves[i]) != nil {
			return leaves[i]
		}
	}
	return {}
}
