// 树栈复现:initWindows 三窗布局 → 按用户操作 destroy×2 → ToggleCommandBar,
// 打印每步的树根/焦点/CommandBar 状态,定位 F2 失效环节。
// 每步后跑树结构不变式校验(I1 无环 / I2 镜像 / I3 叶判定 / 单连通)。
package main

import cv "../../src/canvas"
import mem "../../src/memory"
import "core:fmt"

v_bad : int
v_visited : [512]bool
v_leaf : int

// 简化:节点 id 打印(树结构/焦点)
dump :: proc(tag : string) {
	fmt.printf("%-24s root=%d focus=%d barVisible=%v\n", tag,
		cv.WindowTreeRoot().id, cv.GetFocusWindow().id, cv.CommandBarVisible())
}

// 结构校验:从根 DFS —— ① 每节点恰访问一次(重复 = 环/多连通)
// ② 镜像:子.parent_id == 当前 ③ I3:is_leaf ⇔ 无子 / 内部 ⇔ 恰双子
// ④ 叶数 == 存活窗数(单连通,窗都在根下)
walk :: proc(h : mem.Handle) {
	if h.id == 0 {
		return
	}
	if int(h.id) >= len(v_visited) {
		v_bad += 1
		fmt.println("  !! node id out of range:", h.id)
		return
	}
	if v_visited[int(h.id)] {
		v_bad += 1
		fmt.println("  !! visited twice (cycle/multi-component):", h.id)
		return
	}
	v_visited[int(h.id)] = true
	n := cv.GetWindowTreeNode(h)
	if n == nil {
		v_bad += 1
		fmt.println("  !! nil node:", h.id)
		return
	}
	// 镜像(I2)
	sides := [2]mem.Handle{n.left_son_id, n.right_son_id}
	for &c in sides {
		if c.id != 0 {
			cn := cv.GetWindowTreeNode(c)
			if cn == nil || cn.parent_id != h {
				v_bad += 1
				fmt.println("  !! mirror broken at", h.id, "->", c.id)
			}
		}
	}
	// 叶判定(I3)
	if n.is_leaf && (n.left_son_id.id != 0 || n.right_son_id.id != 0) {
		v_bad += 1
		fmt.println("  !! leaf with children at", h.id)
	}
	if !n.is_leaf && (n.left_son_id.id == 0 || n.right_son_id.id == 0) {
		v_bad += 1
		fmt.println("  !! inner without 2 children at", h.id)
	}
	if n.is_leaf {
		v_leaf += 1
	}
	walk(n.left_son_id)
	walk(n.right_son_id)
}

validateTree :: proc(tag : string) {
	v_bad = 0
	v_leaf = 0
	for &b in v_visited {
		b = false
	}
	root := cv.WindowTreeRoot()
	if rn := cv.GetWindowTreeNode(root); rn != nil && rn.parent_id.id != 0 {
		v_bad += 1
		fmt.println("  !! root has parent")
	}
	walk(root)
	if v_leaf != cv.ConsoleCount() {
		v_bad += 1
		fmt.printf("  !! leaf count %d != window count %d (disconnected)\n", v_leaf, cv.ConsoleCount())
	}
	if v_bad == 0 {
		fmt.printf("%-24s TREE VALID\n", tag)
	} else {
		fmt.printf("%-24s TREE INVALID (%d)\n", tag, v_bad)
	}
}

main :: proc() {
	cv.PageNew() // 分页:第一页(页根 + 根窗)
	cv.SplitNewWindow(.LeftRight)
	win2 := cv.GetFocusWindow()
	cv.FocusMove(.Left)
	win1 := cv.GetFocusWindow()
	cv.SplitNewWindow(.UpDown)
	win4 := cv.GetFocusWindow()
	cv.FocusMove(.Up)
	win3 := cv.GetFocusWindow()
	cv.SetFocusWindow(win3)

	// 模拟窗格内容建立(SetConsoleFont 建 console):给三个窗格都挂 console
	wns := [3]mem.Handle{win2, win3, win4}
	for n in wns {
		nnode := cv.GetWindowTreeNode(n)
		if nnode != nil && nnode.console_id.id == 0 {
			ch, cok := cv.CreateConsole(24, 80, {})
			if cok {
				cv.TreeNodeSetConsole(n, ch)
			}
		}
	}
	fmt.printf("init: root=%d win1=%d win2=%d win3=%d win4=%d\n",
		cv.WindowTreeRoot().id, win1.id, win2.id, win3.id, win4.id)
	dump("init done")
	validateTree("after init")

	// 用户:焦点窗 3 上 F2 开条 + destroy
	cv.ToggleCommandBar() // F2
	fmt.printf("toggle@3: barVisible=%v\n", cv.CommandBarVisible())
	cv.DestroyWindow() // destroy(焦点窗)
	dump("after destroy#1")
	validateTree("after destroy#1")

	// 用户:新焦点(第二个窗)destroy
	cv.DestroyWindow()
	dump("after destroy#2")
	validateTree("after destroy#2")

	// 用户:剩余窗按 F2
	f := cv.GetFocusWindow()
	cv.ToggleCommandBar()
	fmt.printf("post-toggle focus=%d barVisible=%v\n", f.id, cv.CommandBarVisible())
	dump("final")
	validateTree("final")

	// 再按一次 F2:关闭
	cv.ToggleCommandBar()
	fmt.printf("toggle-off: barVisible=%v\n", cv.CommandBarVisible())

	// 用户场景:split right 新窗格后 F2(空窗格,console 懒创建)
	split_h := cv.SplitNewWindow(.LeftRight)
	fmt.printf("post-split: focus=%d console=%v\n", split_h.id, cv.NodeConsole(split_h) != nil)
	ok := cv.ToggleCommandBar()
	fmt.printf("toggle@split-new: ok=%v barVisible=%v\n", ok, cv.CommandBarVisible())
	dump("final2")
	validateTree("final2")
}
