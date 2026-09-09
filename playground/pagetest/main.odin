// 分页回归:建页/切页/页计数/焦点独立/关页(含最后一页拒绝)。
package main

import cv "../../src/canvas"
import "core:fmt"

check :: proc(name : string, got, want : $T) {
	if got == want {
		fmt.printf("  ok  %s\n", name)
	} else {
		fmt.printf("FAIL  %s got=%v want=%v\n", name, got, want)
	}
}

main :: proc() {
	check("count=0 init", cv.PageCount(), 0)

	p1 := cv.PageNew()
	check("page1 created", p1.id != 0, true)
	check("count=1", cv.PageCount(), 1)
	check("current=1", cv.PageCurrent(), p1)
	n1 := cv.GetWindowTreeNode(cv.PageTreeRoot(p1))
	check("page1 root size", n1 != nil && n1.width > 0 && n1.height > 0, true)

	// 焦点独立:p1 焦点 = 根窗;分裂出第二窗再换页回来应恢复
	cv.SplitNewWindow(.LeftRight)
	split_focus := cv.GetFocusWindow()
	check("focus on split", split_focus.id != 0, true)

	p2 := cv.PageNew()
	check("page2 created", p2.id != 0, true)
	check("count=2", cv.PageCount(), 2)
	check("current=2", cv.PageCurrent(), p2)
	n2 := cv.GetWindowTreeNode(cv.PageTreeRoot(p2))
	check("page2 root size", n2 != nil && n2.width > 0 && n2.height > 0, true)
	check("page2 focus = root", cv.GetFocusWindow() != cv.PageTreeRoot(p2), false) // 建根窗后焦点 = 根

	// 切回 p1:焦点恢复(分裂窗)
	cv.PageSwitch(p1)
	check("switch back p1", cv.PageCurrent(), p1)
	check("p1 focus restored", cv.GetFocusWindow(), split_focus)

	// 环绕
	cv.PageNext()
	check("next = p2", cv.PageCurrent(), p2)
	cv.PagePrev()
	check("prev = p1", cv.PageCurrent(), p1)

	// 关页:当前 p1 → 自动切相邻 p2
	ok := cv.PageDestroy(p1)
	check("destroy p1", ok, true)
	check("count=1", cv.PageCount(), 1)
	check("auto switched to p2", cv.PageCurrent(), p2)

	// 最后一页拒绝
	ok = cv.PageDestroy(p2)
	check("last page refused", ok, false)
	check("count stays 1", cv.PageCount(), 1)

	// 跨页存活 + 空页自动清出:当前页窗口关完 ≠ 程序退出(其他页还有窗口),
	// 但空页自动关(非最后一页)
	pa := cv.PageNew() // count=2;pa 为当前(新页自动切换)
	pb := cv.PageNew() // count=3;pb 为当前;此时活页 = {p2, pa, pb}
	check("three pages", cv.PageCount(), 3)
	cv.PageSwitch(pa)
	cv.DestroyWindow() // 关 pa 唯一窗口(当前页树清空,根常驻)
	check("pa auto-cleaned", cv.PageCount(), 2)
	check("pa cleared, still alive", cv.PollSessions(), true)
	cv.PageSwitch(pb)
	cv.DestroyWindow()
	check("pb auto-cleaned", cv.PageCount(), 1)
	check("pb cleared, still alive", cv.PollSessions(), true) // p2 还有窗
	cv.PageSwitch(p2)
	cv.DestroyWindow() // 最后一页的窗口也没了
	check("last page stays", cv.PageCount(), 1) // 最后一页保留(空态)
	check("all pages empty -> exit", cv.PollSessions(), false)

	// split left/up 方向词:新窗在首侧(左/上),焦点 = 新窗
	p3 := cv.PageNew()
	if p3.id != 0 {
		wl := cv.SplitNewWindow(.LeftRight, {}, true)
		nl := cv.GetWindowTreeNode(wl)
		check("split left: new window on left", nl != nil && nl.parent_id.id != 0 &&
			cv.GetWindowTreeNode(nl.parent_id).left_son_id == wl, true)
		wu := cv.SplitNewWindow(.UpDown, {}, true)
		nu := cv.GetWindowTreeNode(wu)
		check("split up: new window on top", nu != nil && nu.parent_id.id != 0 &&
			cv.GetWindowTreeNode(nu.parent_id).left_son_id == wu, true)
		// 焦点最近(图 BFS):树 = [上 wu | 下 wl] | 右旧窗;删右窗 → BFS
		// (father→lson→rson)同层首候选 = lson 侧 = wu(上叶)
		cv.FocusMove(.Right)
		check("focus moved to old right window", cv.GetFocusWindow().id != wl.id && cv.GetFocusWindow().id != wu.id, true)
		cv.DestroyWindow()
		check("destroy right -> focus nearest via BFS", cv.GetFocusWindow(), wu)
	}

	// 区分场景(旧 bug 复现检查):树 = [W0 | updown(Wr | updown(W1 | W2))],
	// 删中间层上叶 W1 → 最近 = 兄弟 W2(距 2);旧"第一有窗叶"会跳 W0。
	p5 := cv.PageNew()
	if p5.id != 0 {
		w0 := cv.GetFocusWindow()
		wr := cv.SplitNewWindow(.LeftRight)
		w1 := cv.SplitNewWindow(.UpDown)
		w2 := cv.SplitNewWindow(.UpDown)
		_ = wr
		cv.FocusMove(.Up) // W2 → W1
		cv.DestroyWindow() // 删 W1
		check("destroy mid-level -> focus sibling (not first leaf)", cv.GetFocusWindow(), w2)
		check("w0 not stolen", cv.GetFocusWindow() != w0, true)
	}

	// exchange:focus 跟随 window(不是 node)
	p6 := cv.PageNew()
	if p6.id != 0 {
		e1 := cv.SplitNewWindow(.LeftRight) // 焦点 = 右节点(e1)
		win_id := cv.GetWindowTreeNode(e1).console_id
		left_leaf := cv.GetWindowTreeNode(cv.GetWindowTreeNode(e1).parent_id).left_son_id
		cv.ExchangeWindow(.Left) // 与左邻居交换
		f := cv.GetFocusWindow()
		check("exchange: focus moved to left leaf", f == left_leaf, true)
		check("exchange: same window object", cv.GetWindowTreeNode(f).console_id == win_id, true)
	}
}
