// 用户接口测试:CreateWindowTreeRoot / SplitNewWindow / SetFocusWindow / FocusMove
// / SetSplitFactor / ExchangeWindow / SetWindowFont / SetAutoClose / WindowCount / DestroyWindow
package main

import ua "../../src/canvas"
import cv "../../src/canvas"
import mem "../../src/memory"
import "core:fmt"

fails := 0

check :: proc(name : string, cond : bool) {
	status := "PASS"
	if !cond {
		status = "FAIL"
		fails += 1
	}
	fmt.printf("%-46s %s\n", name, status)
}

main :: proc() {
	// 页:CreateWindowTreeRoot 作用于当前页(无当前页 = 返回 0)
	ua.PageNew()

	// 1. 建根
	root := ua.CreateWindowTreeRoot()
	check("根已创建且为焦点", root.id != 0 && ua.GetFocusWindow() == root)
	check("window 数 = 1", ua.WindowCount() == 1)

	// 2. 分裂(焦点移到新窗 = 右子)
	new_win := ua.SplitNewWindow(.LeftRight)
	check("分裂出新窗", new_win.id != 0 && new_win != root)
	check("新窗成为焦点", ua.GetFocusWindow() == new_win)
	check("window 数 = 2", ua.WindowCount() == 2)

	// 2b. 焦点移动到左子(root 保留位)
	check("FocusMove left", ua.FocusMove(.Left))
	left := ua.GetFocusWindow()
	check("焦点到左子", left.id != 0 && left != new_win)

	// 3. 焦点移动:从 left 向右 → 右子;再向左 → 回 left
	check("FocusMove right", ua.FocusMove(.Right))
	right := ua.GetFocusWindow()
	check("焦点到右子", right.id != 0 && right != left)
	check("FocusMove left 返回", ua.FocusMove(.Left))
	check("焦点回左子", ua.GetFocusWindow() == left)

	// 4. 再分裂左子(down),window 数 = 3;焦点移到新下子
	down_win := ua.SplitNewWindow(.UpDown)
	check("再分裂 down", down_win.id != 0)
	check("window 数 = 3", ua.WindowCount() == 3)

	// 5. SetSplitFactor:焦点(down 新窗)的父 = 原 left 分裂出的 UpDown 内部节点
	check("SetSplitFactor 0.3", ua.SetSplitFactor(0.3))
	cur := ua.GetFocusWindow()
	parent := cv.GetWindowTreeNode(cur).parent_id
	check("父节点 factor = 0.3", cv.GetWindowTreeNode(parent).split_factor == 0.3)

	// 6. ExchangeWindow:焦点(down 新窗)与其 Right 方向邻居(right)交换窗口内容
	// 先给两个窗挂占位 window_id,交换后验证 window_id 互换
	d_node := cv.GetWindowTreeNode(down_win)
	d_node.window_id = mem.Handle { id = 111, generation = 1 }
	r_node := cv.GetWindowTreeNode(right)
	r_node.window_id = mem.Handle { id = 222, generation = 1 }
	check("ExchangeWindow right", ua.ExchangeWindow(.Right))
	// 语义:只换 window_id,焦点跟随"原焦点窗口"(111 现挂在 right 节点)
	check("交换后焦点 = right", ua.GetFocusWindow() == right)
	check("交换后 down 窗持 222", cv.GetWindowTreeNode(down_win).window_id.id == 222)
	check("交换后 right 窗持 111", cv.GetWindowTreeNode(right).window_id.id == 111)

	// 7. SetWindowFont(需要 GL 上下文的 LoadFont 无法在无头测试验证)
	// 这里只验证失败路径(无效路径返回 false,不崩溃)
	check("SetWindowFont 无效路径失败", !ua.SetWindowFont("./nonexistent.ttf", 40))

	// 8. SetAutoClose
	check("SetAutoClose true", ua.SetAutoClose(true))
	win := cv.NodeWindow(ua.GetFocusWindow())
	check("auto_close 已设", win != nil && win.auto_close)

	// 9. LaunchConsole 前置检查:未设 cmd 之前 console_id=0 → 失败(不实际启动)
	// 这里直接验证"未设置字体时失败"已由上面覆盖;跳过真实启动(沙箱无 ConPTY)

	// 10. DestroyWindow:删除焦点窗,window 数 -1
	before := ua.WindowCount()
	check("DestroyWindow", ua.DestroyWindow())
	check("window 数 = before-1", ua.WindowCount() == before - 1)
	check("焦点仍有效", ua.GetFocusWindow().id != 0)

	// 11. 根在有其他窗口时不可删;唯一窗口时清空整树
	root_h := ua.GetFocusWindow()
	for cv.GetWindowTreeNode(root_h).parent_id.id != 0 {
		root_h = cv.GetWindowTreeNode(root_h).parent_id
	}
	check("非唯一根不可删", !ua.DestroyWindow(root_h))
	// 清空剩余窗口(含根):最后一个窗口销毁 = 整树重置为空根叶(空叶仍是一个叶节点)
	for cv.NodeWindow(ua.GetFocusWindow()) != nil {
		if !ua.DestroyWindow() {
			break
		}
	}
	check("全部销毁后无窗口对象", cv.NodeWindow(cv.WindowTreeRoot()) == nil)

	fmt.printf("\n%s (%d failures)\n", fails == 0 ? "ALL PASS" : "SOME FAILED", fails)
}
