// 窗口树数据:WindowTreeNode(节点)+ Transform(几何)+ SplitType/FocusDirection(方向枚举)。
// 树结构操作(分裂/摘除/挂载/重算/焦点/命中)+ 每帧树遍历编排(ConsoleUpdateTree)。
// 焦点是树状态;命中测试(nodeAtPoint)属树几何。
// 分页:一棵树 = 一个页(树节点表全局,页只持根引用 + 页内焦点;根槽不再固定)。
package canvas

import ct "../conpty"
import fnt "../font"
import mem "../memory"
import "core:fmt"
import "core:math"

MAX_TREE_NODE_SLOTS :: 2000

// 绝对几何:像素坐标,由布局层按 split tree 递归算出
Transform :: struct {
	position_x : f32, // 矩形的左上角
	position_y : f32,
	height : f32,
	width : f32,
}

SplitType :: enum u8 {
	UpDown,
	LeftRight,
}

// 树节点:纯结构(几何/分割/父子/挂载 console)。leaf 挂 console_id,内部节点 = 0
WindowTreeNode :: struct {
	console_id : mem.Handle, // leaf 承载的 console(窗格内容);0 = 空窗格

	using transform : Transform,

	frame_width : u32, // 分割条像素宽(颜色读主题 theme.frame)

	parent_id : mem.Handle, // 0 = 无父(仅根)

	left_son_id : mem.Handle, // left or up
	right_son_id : mem.Handle, // right or down

	split_factor : f32, // 左子树所占空间

	split_type : SplitType,

	is_leaf : bool,
}

window_tree_nodes : mem.GenArray(MAX_TREE_NODE_SLOTS, WindowTreeNode)

// 窗口区尺寸(内容高度 = 物理高 - 页签条;resize 时更新):
//   Window_Width x Window_Height = 当前页 root 的几何根
Window_Width : u32 = 1920

Window_Height : u32 = 1048 // = 1080 - TAB_BAR_HEIGHT(32)

// 分割条默认样式:1 像素宽(颜色读主题)
DEFAULT_FRAME_WIDTH :: 1

CreateWindowTreeNode :: proc() -> (h : mem.Handle) {
	return mem.Alloc(&window_tree_nodes, WindowTreeNode {
		is_leaf = true,
		frame_width = DEFAULT_FRAME_WIDTH,
	})
}

GetWindowTreeNode :: proc(h : mem.Handle) -> ^WindowTreeNode {
	return mem.Get(&window_tree_nodes, h)
}

// 按 id 构造当前世代的有效句柄(指令字符串的 @id 用);槽不存在或**不在当前页树内**返回 0
NodeHandleById :: proc(id : u32) -> mem.Handle {
	if id == 0 {
		return {}
	}
	h := mem.GetHandle(&window_tree_nodes, int(id)) // Alive + 当前世代(池内部数据不外漏)
	if h.id == 0 {
		return {}
	}
	if !inCurrentPageTree(h) {
		return {}
	}
	return h
}

// 节点是否属于当前页树(沿 parent 上行至根 == 页根)
inCurrentPageTree :: proc(h : mem.Handle) -> bool {
	root := WindowTreeRoot()
	if root.id == 0 {
		return false
	}
	cur := h
	for cur.id != 0 {
		if cur == root {
			return true
		}
		node := GetWindowTreeNode(cur)
		if node == nil {
			return false
		}
		cur = node.parent_id
	}
	return false
}

// 当前页树根(每页一棵树;根 = 页持有句柄,parent_id = 0)
WindowTreeRoot :: proc() -> mem.Handle {
	if p := mem.Get(&pages, current_page); p != nil {
		return p.tree_root
	}
	return {}
}

// 清空当前页树(唯一剩余窗口关闭时):整树销毁,页根常驻(页仍可加窗/聚焦)。
// 页根释放会让页句柄失效,故根不释放,只释放其后代并恢复空叶。
ResetWindowTree :: proc() {
	root := WindowTreeRoot()
	if root.id == 0 {
		return
	}
	if n := GetWindowTreeNode(root); n != nil && !n.is_leaf {
		left, right := n.left_son_id, n.right_son_id
		unlinkSon(root, left) // 先摘链(接口维护 is_leaf),再释放子树
		unlinkSon(root, right)
		TreeNodeRemoveAll(left)
		TreeNodeRemoveAll(right)
	}
	if n := GetWindowTreeNode(root); n != nil {
		n.console_id = {}
	}
}

// 递归释放子树(含根),不保留结构
TreeNodeRemoveAll :: proc(h : mem.Handle) {
	node := GetWindowTreeNode(h)
	if node == nil {
		return
	}
	if !node.is_leaf {
		TreeNodeRemoveAll(node.left_son_id)
		TreeNodeRemoveAll(node.right_son_id)
	}
	mem.Free(&window_tree_nodes, h)
}

// ---------------------------------------------------------------------------
// 焦点(页字段:读写直接经 CurrentPage().focused;页切换即保留)
// ---------------------------------------------------------------------------
FocusDirection :: enum u8 {
	Left,
	Right,
	Up,
	Down,
}

// 方向导航:找焦点 leaf 在 dir 方向上的相邻 leaf。
// 上行找同轴边界祖先,下行找最远侧 leaf;无邻居返回 0。
FocusNeighbor :: proc(from : mem.Handle, dir : FocusDirection) -> mem.Handle {
	cur := from
	for {
		node := GetWindowTreeNode(cur)
		if node == nil || node.parent_id.id == 0 {
			return {}
		}
		parent := GetWindowTreeNode(node.parent_id)
		if parent == nil {
			return {}
		}
		is_horiz := dir == .Left || dir == .Right
		same_axis := (is_horiz && parent.split_type == .LeftRight) || (!is_horiz && parent.split_type == .UpDown)
		if same_axis {
			// 焦点在当前侧时,另一侧即候选;否则继续上行
			if dir == .Left && cur == parent.right_son_id {
				return focusDescend(parent.left_son_id, dir)
			}
			if dir == .Right && cur == parent.left_son_id {
				return focusDescend(parent.right_son_id, dir)
			}
			if dir == .Up && cur == parent.right_son_id {
				return focusDescend(parent.left_son_id, dir)
			}
			if dir == .Down && cur == parent.left_son_id {
				return focusDescend(parent.right_son_id, dir)
			}
		}
		cur = node.parent_id
	}
}

// 从候选根下行到最远侧 leaf;跨轴时固定取左/上子
focusDescend :: proc(h : mem.Handle, dir : FocusDirection) -> mem.Handle {
	node := GetWindowTreeNode(h)
	if node == nil {
		return {}
	}
	if node.is_leaf {
		return h
	}
	is_horiz := dir == .Left || dir == .Right
	if is_horiz && node.split_type == .LeftRight {
		if dir == .Left {
			return focusDescend(node.right_son_id, dir) // 找最右
		}
		return focusDescend(node.left_son_id, dir) // 找最左
	}
	if !is_horiz && node.split_type == .UpDown {
		if dir == .Up {
			return focusDescend(node.right_son_id, dir) // 找最下
		}
		return focusDescend(node.left_son_id, dir) // 找最上
	}
	// 跨轴:固定取左/上子(简单方案)
	return focusDescend(node.left_son_id, dir)
}

// ---------------------------------------------------------------------------
// 节点内容操作(leaf 节点直接持一个 console)
// ---------------------------------------------------------------------------
// 挂载/摘除 console(0 = 摘除);仅 leaf 有效。交换窗格内容 = 交换两节点的 console_id
TreeNodeSetConsole :: proc(h : mem.Handle, console_h : mem.Handle) -> bool {
	node := GetWindowTreeNode(h)
	if node == nil || !node.is_leaf {
		return false
	}
	node.console_id = console_h
	return true
}

// 取节点挂载的 console / console 句柄见 console.odin(NodeConsole / NodeConsoleId)

// leaf 节点几何即内容矩形(窗口占满节点);transform 是节点内联字段,
// 读取直接 GetWindowTreeNode(h).transform,不再提供拷贝包装。

// 命中测试:包含点 (x, y)(窗口物理像素)的 leaf 节点;无命中返回 {}
nodeAtPoint :: proc(x, y : f32) -> mem.Handle {
	return nodeAtPointRec(WindowTreeRoot(), x, y)
}

// 分割条命中:内部节点的条带命中(条中心线公式与 drawFrame 同源,见其注释)。
// 命中 = 轴向上 |cur - 条中心| ≤ fw/2 + FRAME_HIT_PAD,且点在节点另一轴范围内;
// 多点命中(正交条交叉)取垂距最小,等距先序先见(确定性)。迭代先序,栈内嵌,零分配。
FRAME_HIT_PAD :: f32(2)

SplitFrameHit :: proc(x, y : f32) -> mem.Handle {
	root := WindowTreeRoot()
	if root.id == 0 {
		return {}
	}
	best : mem.Handle
	best_d := math.INF_F32
	stack : [MAX_TREE_NODE_SLOTS]mem.Handle
	sp := 0
	stack[sp] = root
	sp += 1
	for sp > 0 {
		sp -= 1
		cur := stack[sp]
		node := GetWindowTreeNode(cur)
		if node == nil || node.is_leaf {
			continue
		}
		if left := GetWindowTreeNode(node.left_son_id); left != nil {
			fw := f32(node.frame_width)
			switch node.split_type {
			case .LeftRight:
				if y >= node.position_y && y < node.position_y + node.height {
					center := left.position_x + left.width + fw * 0.5
					d := math.abs(x - center)
					if d <= fw * 0.5 + FRAME_HIT_PAD && d < best_d {
						best, best_d = cur, d
					}
				}
			case .UpDown:
				if x >= node.position_x && x < node.position_x + node.width {
					center := left.position_y + left.height + fw * 0.5
					d := math.abs(y - center)
					if d <= fw * 0.5 + FRAME_HIT_PAD && d < best_d {
						best, best_d = cur, d
					}
				}
			}
		}
		if node.right_son_id.id != 0 && sp < MAX_TREE_NODE_SLOTS {
			stack[sp] = node.right_son_id
			sp += 1
		}
		if node.left_son_id.id != 0 && sp < MAX_TREE_NODE_SLOTS {
			stack[sp] = node.left_son_id
			sp += 1
		}
	}
	return best
}

nodeAtPointRec :: proc(h : mem.Handle, x, y : f32) -> mem.Handle {
	node := GetWindowTreeNode(h)
	if node == nil {
		return {}
	}
	if node.is_leaf {
		if x >= node.position_x && x < node.position_x + node.width &&
			y >= node.position_y && y < node.position_y + node.height {
			return h
		}
		return {}
	}
	// 矩形互不重叠,顺序无关;先右后左保持稳定偏好
	if r := nodeAtPointRec(node.right_son_id, x, y); r.id != 0 {
		return r
	}
	return nodeAtPointRec(node.left_son_id, x, y)
}

// ---------------------------------------------------------------------------
// WindowTreeNode 数据操作
// ---------------------------------------------------------------------------
// ---- 结构连接接口(不变式守卫)----
// 任何建树/改树路径必须经此三件套:禁止直接写 parent_id / left_son_id /
// right_son_id / is_leaf(裸写 = 跳过守卫,树可能被调用方搞坏)。
// 树结构不变式(接口保证):
//   I1 无环:任意节点沿 parent 链上行必止于根(挂载时拒绝"目标子 = 父的祖先")
//   I2 镜像:parent 子指针 ⇔ 子 parent_id 同时写
//   I3 叶判定:is_leaf ⇔ 双侧子均为 0(内部恰双子由调用语境保证)
// 几何/样式(position/width/height/frame_width/split_*)是派生量,直接赋值。

// 挂载 son 为 parent 的左右子:两端同写、换父自动断旧边、环拒绝、is_leaf 自维护。
// 无效句柄/son=parent/成环 = false;son 已是本父之子 = 幂等成功。
linkSon :: proc(parent_h, son_h : mem.Handle, is_left : bool) -> bool {
	parent := GetWindowTreeNode(parent_h)
	son := GetWindowTreeNode(son_h)
	if parent == nil || son == nil || son_h == parent_h {
		return false
	}
	// I1:parent 沿祖链上行,遇 son 即成环(含 son == parent 自身)
	for p := parent_h; p.id != 0; {
		if p == son_h {
			return false
		}
		n := GetWindowTreeNode(p)
		if n == nil {
			break
		}
		p = n.parent_id
	}
	// 换父:断旧边(已是本父之子 = 幂等,不动)
	if old := son.parent_id; old.id != 0 && old != parent_h {
		unlinkSon(old, son_h)
	}
	son.parent_id = parent_h
	if is_left {
		parent.left_son_id = son_h
	} else {
		parent.right_son_id = son_h
	}
	parent.is_leaf = false // I3:挂子即非叶
	return true
}

// 断开 parent → son(两端同时清;非父子 = 空操作);双侧皆空自动回到叶。
unlinkSon :: proc(parent_h, son_h : mem.Handle) -> bool {
	parent := GetWindowTreeNode(parent_h)
	son := GetWindowTreeNode(son_h)
	if parent == nil || son == nil || son.parent_id != parent_h {
		return false // 非父子(或已断):自愈空操作
	}
	son.parent_id = {}
	if parent.left_son_id == son_h {
		parent.left_son_id = {}
	}
	if parent.right_son_id == son_h {
		parent.right_son_id = {}
	}
	// I3:双侧皆空 ⇔ 叶(调用方不再裸写 is_leaf)
	parent.is_leaf = parent.left_son_id.id == 0 && parent.right_son_id.id == 0
	return true
}

// 保持左右位把父的子 old 替换为 new(接管位置/单子提升用);old 非父之子 = 空操作。
replaceChild :: proc(parent_h, old_h, new_h : mem.Handle) -> bool {
	parent := GetWindowTreeNode(parent_h)
	if parent == nil || GetWindowTreeNode(new_h) == nil {
		return false
	}
	is_left := parent.left_son_id == old_h
	if !is_left && parent.right_son_id != old_h {
		return false
	}
	unlinkSon(parent_h, old_h)
	return linkSon(parent_h, new_h, is_left)
}

// 分裂:id 保留为左子树,新分配父节点接管其位置,右子为空叶子
TreeNodeSplit :: proc(h : mem.Handle, split_type : SplitType, factor : f32) -> (parent_h, right_h : mem.Handle, ok : bool) {
	node := GetWindowTreeNode(h)
	if node == nil {
		return {}, {}, false
	}
	parent_h = CreateWindowTreeNode()
	if parent_h.id == 0 {
		return {}, {}, false
	}
	right_h = CreateWindowTreeNode()
	if right_h.id == 0 {
		mem.Free(&window_tree_nodes, parent_h)
		return {}, {}, false
	}
	np := GetWindowTreeNode(parent_h)
	if np == nil {
		mem.Free(&window_tree_nodes, parent_h)
		mem.Free(&window_tree_nodes, right_h)
		return {}, {}, false
	}
	// 接管 node 在父中的位置(根分裂 = 新根,页字段跟随;根 id 迁移,树根不固定槽)
	if node.parent_id.id != 0 {
		replaceChild(node.parent_id, h, parent_h)
	} else if p := mem.Get(&pages, current_page); p != nil && p.tree_root == h {
		p.tree_root = parent_h
	}
	np.split_type = split_type
	np.split_factor = max(0.05, min(0.95, factor))
	np.frame_width = node.frame_width
	np.position_x = node.position_x // 几何继承 h 原区域,子区域由布局重算
	np.position_y = node.position_y
	np.width = node.width
	np.height = node.height
	linkSon(parent_h, h, true)
	linkSon(parent_h, right_h, false)
	RecalculateTransforms(parent_h)
	return parent_h, right_h, true
}

// 摘除子树并释放节点槽(含窗口字体引用);根不可删;父变单子时提升兄弟顶替,保持满二叉树
TreeNodeRemove :: proc(h : mem.Handle) {
	if h.id == 0 || h == WindowTreeRoot() {
		return
	}
	node := GetWindowTreeNode(h)
	if node == nil {
		return
	}
	pid := node.parent_id
	parent := GetWindowTreeNode(pid)
	if parent != nil {
		unlinkSon(pid, h) // I2 两端同步断;双侧皆空自动回叶
	}
	if !node.is_leaf {
		TreeNodeRemove(node.left_son_id)
		TreeNodeRemove(node.right_son_id)
	}
	mem.Free(&window_tree_nodes, h)
	if parent == nil {
		return
	}
	switch {
	case parent.left_son_id.id != 0 && parent.right_son_id.id == 0:
		treeNodePromote(pid, parent.left_son_id)
	case parent.left_son_id.id == 0 && parent.right_son_id.id != 0:
		treeNodePromote(pid, parent.right_son_id)
	case parent.left_son_id.id == 0 && parent.right_son_id.id == 0:
		// 已是叶(unlinkSon 维护),无需动作
	case:
		RecalculateTransforms(pid)
	}
}

// son 顶替 parent 的位置(几何继承,由上层重算覆盖)
treeNodePromote :: proc(parent_h, son_h : mem.Handle) {
	p := GetWindowTreeNode(parent_h)
	son := GetWindowTreeNode(son_h)
	if p == nil || son == nil {
		return
	}
	gpid := p.parent_id
	son.position_x = p.position_x
	son.position_y = p.position_y
	son.width = p.width
	son.height = p.height
	// 非根:son 顶替 parent 的位置(左右位保持)
	if gpid.id != 0 {
		replaceChild(gpid, parent_h, son_h)
		mem.Free(&window_tree_nodes, parent_h)
		RecalculateTransforms(gpid)
		return
	}
	// parent 是根(无父):根壳常驻,直接吸收 son(后续分裂/删除依赖稳定的根槽;
	// 释放根会让其 id 进空闲池,被复用成"第二个根")
	p.is_leaf = son.is_leaf
	p.console_id = son.console_id
	if sl := son.left_son_id; sl.id != 0 {
		linkSon(parent_h, sl, true) // 孙改挂根壳(linkSon 自动断 son→孙旧边)
	}
	if sr := son.right_son_id; sr.id != 0 {
		linkSon(parent_h, sr, false)
	}
	unlinkSon(parent_h, son_h) // 清 son→根壳残留边(引用已全部接管)
	mem.Free(&window_tree_nodes, son_h)
	RecalculateTransforms(parent_h)
}

TreeNodeSetSplitFactor :: proc(h : mem.Handle, factor : f32) -> bool {
	node := GetWindowTreeNode(h)
	if node == nil || node.is_leaf {
		return false
	}
	node.split_factor = max(0.05, min(0.95, factor))
	RecalculateTransforms(h)
	return true
}

TreeNodeSetSplitType :: proc(h : mem.Handle, split_type : SplitType) -> bool {
	node := GetWindowTreeNode(h)
	if node == nil || node.is_leaf {
		return false
	}
	node.split_type = split_type
	RecalculateTransforms(h)
	return true
}

// 设子节点并同步父引用(结构连接经 linkSon/unlinkSon);son 是 id 的祖先时拒绝(成环)
TreeNodeSetLeftSon :: proc(h, son_h : mem.Handle) -> bool {
	return treeNodeSetSon(h, son_h, true)
}

TreeNodeSetRightSon :: proc(h, son_h : mem.Handle) -> bool {
	return treeNodeSetSon(h, son_h, false)
}

treeNodeSetSon :: proc(h, son_h : mem.Handle, is_left : bool) -> bool {
	node := GetWindowTreeNode(h)
	if node == nil {
		return false
	}
	if son_h.id == 0 {
		// 空挂载 = 摘除该侧:仍走接口(旧子 parent_id 一并不会残留)
		cur := is_left ? node.left_son_id : node.right_son_id
		if cur.id == 0 {
			return true
		}
		return unlinkSon(h, cur)
	}
	if !linkSon(h, son_h, is_left) {
		return false
	}
	RecalculateTransforms(h)
	return true
}

// ---------------------------------------------------------------------------
// 布局
// ---------------------------------------------------------------------------
// 窗口分辨率变化(物理尺寸):所有页 root 更新(内容高 = 物理高 - 页签条)并整体重算;
// 后台页几何更新、布局延后(切回时帧内自动重算)
WindowTreeSetRootSize :: proc(width, height : u32) {
	Window_Width = width
	Window_Height = height - u32(TAB_BAR_HEIGHT)
	it : mem.Iter(MAX_PAGE_SLOTS, Page) = mem.All(&pages)
	for ph in mem.next(&it) {
		if page := mem.Get(&pages, ph); page != nil {
			root := GetWindowTreeNode(page.tree_root)
			if root == nil {
				continue
			}
			root.position_x = 0
			root.position_y = 0
			root.width = f32(Window_Width)
			root.height = f32(Window_Height)
			RecalculateTransforms(page.tree_root)
		}
	}
}

// 按 split_factor / split_type / frame_width 递归划分子节点几何
RecalculateTransforms :: proc(h : mem.Handle) {
	node := GetWindowTreeNode(h)
	if node == nil || node.is_leaf {
		return
	}
	left := GetWindowTreeNode(node.left_son_id)
	right := GetWindowTreeNode(node.right_son_id)
	if left == nil || right == nil {
		return // 正常二叉树,内部节点恒双子
	}
	fw := f32(node.frame_width)
	switch node.split_type {
	case .LeftRight:
		avail := node.width - fw
		lw := avail * node.split_factor
		left.position_x = node.position_x
		left.position_y = node.position_y
		left.width = lw
		left.height = node.height
		right.position_x = node.position_x + lw + fw
		right.position_y = node.position_y
		right.width = avail - lw
		right.height = node.height
	case .UpDown:
		avail := node.height - fw
		lh := avail * node.split_factor
		left.position_x = node.position_x
		left.position_y = node.position_y
		left.width = node.width
		left.height = lh
		right.position_x = node.position_x
		right.position_y = node.position_y + lh + fw
		right.width = node.width
		right.height = avail - lh
	}
	RecalculateTransforms(node.left_son_id)
	RecalculateTransforms(node.right_son_id)
}

// 有效矩形(显示派生,唯一公式):当前页 Single(单窗)且 h == 页焦点 → 树区根矩形
// (页根 transform = 整棵树的显示区域),其余一律节点自身矩形。
// 布局(layoutWalk)/ 渲染(打底背景 / 焦点边框)共用此单真值,不许别处再写分支。
WindowEffectiveRect :: proc(h : mem.Handle) -> Transform {
	if n := GetWindowTreeNode(h); n != nil {
		if p := CurrentPage(); p != nil && p.view_mode == .Single && p.focused == h {
			if root := GetWindowTreeNode(p.tree_root); root != nil {
				return root.transform
			}
		}
		return n.transform
	}
	return {}
}

// 收集子树内所有 leaf 节点(定长数组,不分配)
collectLeaves :: proc(h : mem.Handle, leaves : ^[MAX_TREE_NODE_SLOTS]mem.Handle, count : ^int) {
	node := GetWindowTreeNode(h)
	if node == nil {
		return
	}
	if node.is_leaf {
		if count^ < MAX_TREE_NODE_SLOTS {
			leaves[count^] = h
			count^ += 1
		}
		return
	}
	collectLeaves(node.left_son_id, leaves, count)
	collectLeaves(node.right_son_id, leaves, count)
}

countLeaves :: proc(h : mem.Handle, count : ^int) {
	node := GetWindowTreeNode(h)
	if node == nil {
		return
	}
	if node.is_leaf {
		count^ += 1
		return
	}
	countLeaves(node.left_son_id, count)
	countLeaves(node.right_son_id, count)
}

// 取子树最左 leaf(上下轴 = 最上)
firstLeaf :: proc(h : mem.Handle) -> mem.Handle {
	node := GetWindowTreeNode(h)
	if node == nil {
		return {}
	}
	if node.is_leaf {
		return h
	}
	return firstLeaf(node.left_son_id)
}

// 取子树最右 leaf(上下轴 = 最下);删除右/下子后"同轴贴边"的最近叶
lastLeaf :: proc(h : mem.Handle) -> mem.Handle {
	node := GetWindowTreeNode(h)
	if node == nil {
		return {}
	}
	if node.is_leaf {
		return h
	}
	return lastLeaf(node.right_son_id)
}

// 树上最近有窗叶(图 BFS):树视为无向图,每节点三条边 father/lson/rson,
// 遍历优先级 father → lson → rson;层序首个有窗叶 = 树边距离最近。
// start 自身不算候选(其窗口正被销毁)。全树无有窗叶 = {}。
// 冷路径(销毁窗口前调用一次);固定数组,零分配。
nearestWindowLeaf :: proc(start : mem.Handle) -> mem.Handle {
	if start.id == 0 || int(start.id) >= MAX_TREE_NODE_SLOTS {
		return {}
	}
	queue : [MAX_TREE_NODE_SLOTS]mem.Handle
	seen : [MAX_TREE_NODE_SLOTS]bool
	qh, qt := 0, 0
	queue[qt] = start
	qt += 1
	seen[int(start.id)] = true
	for qh < qt {
		cur := queue[qh]
		qh += 1
		node := GetWindowTreeNode(cur)
		if node == nil {
			continue
		}
		if cur != start && node.is_leaf && NodeConsole(cur) != nil {
			return cur // 只挑有 console 的窗格(空窗格不作为迁移目标)
		}
		// 邻居展开(优先级 father → lson → rson)
		if node.parent_id.id != 0 && !seen[int(node.parent_id.id)] {
			seen[int(node.parent_id.id)] = true
			queue[qt] = node.parent_id
			qt += 1
		}
		if node.left_son_id.id != 0 && !seen[int(node.left_son_id.id)] {
			seen[int(node.left_son_id.id)] = true
			queue[qt] = node.left_son_id
			qt += 1
		}
		if node.right_son_id.id != 0 && !seen[int(node.right_son_id.id)] {
			seen[int(node.right_son_id.id)] = true
			queue[qt] = node.right_son_id
			qt += 1
		}
	}
	return {}
}

// ---------------------------------------------------------------------------
// 先序叶子序 + split 认领匹配(冷路径;每次操作前重算,树变后一致)
// ---------------------------------------------------------------------------
// 叶子序:先序 DFS(先左后右)访问叶子,得到从左到右的叶子序列。
// 认领匹配(栈):先序遍历中,每遇非叶节点 push 其 id;每遇叶子 pop 栈顶
// 认领。满二叉树 leaf = 内部节点 + 1,故每个 split 被唯一叶子认领,恰剩
// 最右叶无认领(栈空)。等价刻画:认领叶 = 该 split 左子树的最右叶子。
// 用途:叶子序号成为 split 的统一索引(factor 按认领寻址);叶子序相邻
// 即"左/右交换"的邻居。
// 局部性最大化:Dfs 栈/叶子表全部内嵌于入口(迭代先序 + 显式认领栈),
// 不进入包命名空间;每次调用独立重算(冷路径)。

// 第 n(1-based)个叶子认领的 split 节点;越界/无认领 = 0
LeafSplitOwner :: proc(n : int) -> mem.Handle {
	if n < 1 {
		return {}
	}
	// 迭代先序:DFS 栈(压 right 再 left)+ 认领栈(内部压入,叶子弹出其一)
	order : [MAX_TREE_NODE_SLOTS]mem.Handle // 叶子序号(0-based)→ 叶子节点 id
	owner : [MAX_TREE_NODE_SLOTS]mem.Handle // 叶子序号 → 认领的 split(0 = 无)
	count := 0
	dfs : [MAX_TREE_NODE_SLOTS]mem.Handle
	claim : [MAX_TREE_NODE_SLOTS]mem.Handle
	dfstop, claimtop := 0, 0
	dfs[dfstop] = WindowTreeRoot()
	dfstop += 1
	for dfstop > 0 {
		dfstop -= 1
		cur := dfs[dfstop]
		node := GetWindowTreeNode(cur)
		if node == nil {
			continue
		}
		if node.is_leaf {
			if count < MAX_TREE_NODE_SLOTS {
				order[count] = cur
				if claimtop > 0 {
					claimtop -= 1
					owner[count] = claim[claimtop]
				} else {
					owner[count] = {} // 最右叶:无认领
				}
				count += 1
			}
			continue
		}
		if claimtop < MAX_TREE_NODE_SLOTS {
			claim[claimtop] = cur
			claimtop += 1
		}
		if node.right_son_id.id != 0 && dfstop < MAX_TREE_NODE_SLOTS {
			dfs[dfstop] = node.right_son_id
			dfstop += 1
		}
		if node.left_son_id.id != 0 && dfstop < MAX_TREE_NODE_SLOTS {
			dfs[dfstop] = node.left_son_id
			dfstop += 1
		}
	}
	if n - 1 >= count {
		return {}
	}
	return owner[n - 1]
}

// ---------------------------------------------------------------------------
// 每帧更新(遍历按需分层:趟消费什么层的数据就遍历哪层,真源就地读,无跨层工作表):
//   ① 输出 —— 只碰 console 内容 → 遍历 console(拉取 + 解析)
//   ② 布局 —— 消费 node 几何 → 遍历 node(树),写 Console 布局
//   ③ 尺寸应用 —— 只碰 console/conpty 数据 → 遍历 console
// 各趟写入数据仍保持单一;跨趟信息 = 数据自身(目标 vs 已应用,比较即知)。
// ---------------------------------------------------------------------------


// 每帧对外编排:输出 → 布局 → 尺寸应用。
// 趟序契约(为什么输出必须**先于**布局):
//   环形缓冲里的字节是子进程按**上一帧几何**排版的。若先布局,这些旧几何的字节
//   会被用新 rows/cols 解释 —— 自动折行位置、EL/ECH 的覆盖范围、CUP 列 clamp
//   全按新宽度算,整行错格(窗口 resize 时最明显)。顺序必须是:
//   排空旧输出 → 改本地尺寸 → 通知 ConPTY。
ConsoleUpdateTree :: proc(node_h : mem.Handle) {
	it : mem.Iter(MAX_CONSOLE_SLOTS, Console) = mem.All(&consoles)

	// 遍历①(console):输出 —— 应答排空 + 拉取解析(无会话 console 只做应答排空)
	for ch in mem.next(&it) {
		UpdateConsole(ch)
	}

	// 遍历②(node 树):布局 —— 每个挂 console 的 leaf:就地读几何(节点真源),写 Console 布局
	layoutWalk(node_h)

	// 遍历③(console):尺寸应用 —— 目标尺寸(rows/cols)与 ConPTY 已应用(pty_*)
	// 比较,变化才 Resize。工具 console(conpty = 0)跳过。
	//
	// **只有成功才记"已应用"**:ResizePseudoConsole 会失败(Win10 的 conhost 概率性
	// 返回失败;窗口拖拽期间连续 resize 也会撞上),而无条件记录 pty_* 会让上面的
	// 尺寸比较从此永远为假 —— 一次失败 = 永久放弃,表现为"窗口变大了,终端尺寸没
	// 跟上"(布局用新尺寸、ConPTY 与子进程留在旧尺寸)。失败就不记,下一帧自动重试。
	it = mem.All(&consoles)
	for ch in mem.next(&it) {
		console := mem.Get(&consoles, ch)
		if console == nil {
			continue
		}
		if ct.GetConptyContext(console.conpty_handle) == nil {
			continue
		}
		if console.rows == console.pty_rows && console.cols == console.pty_cols {
			continue
		}
		if ct.Resize(console.conpty_handle, console.cols, console.rows) {
			console.pty_rows, console.pty_cols = console.rows, console.cols
			console.resize_retry = 0
			continue
		}
		// 失败:保持 pty_* 落后 → 下帧重试。只报第一次(否则每帧刷屏)
		if console.resize_retry == 0 {
			fmt.eprintfln("resize 到 %dx%d 失败,将持续重试(ConPTY 仍在旧尺寸 —— " +
				"此时子进程按旧宽度排版,屏幕会错位)", console.cols, console.rows)
		}
		console.resize_retry += 1
	}

	layoutWalk :: proc(node_h : mem.Handle) {
		node := GetWindowTreeNode(node_h)
		if node == nil {
			return
		}
		if !node.is_leaf {
			layoutWalk(node.left_son_id)
			layoutWalk(node.right_son_id)
			return
		}
		console := NodeConsole(node_h)
		if console == nil {
			return
		}
		m := fnt.GetMetrics(console.font_set.main_font) // 字体 = console 配置(唯一真相)
		// 单窗模式:焦点窗布局用有效矩形(树区),隐藏窗照常用自身节点矩形(值不变)
		ConsoleUpdateLayout(node.console_id, WindowEffectiveRect(node_h), m.cell_width, m.cell_height)
	}

}

