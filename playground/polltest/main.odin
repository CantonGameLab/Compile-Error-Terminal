// PollSessions 语义测试(无头):
// 1) 三窗格(空窗格,无 console = 无会话)
// 2) 验证 PollSessions 的"无会话/空窗格"分支不误杀 + 窗口销毁/轮询结束语义
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
	ua.PageNew() // CreateWindowTreeRoot 作用于当前页
	root := ua.CreateWindowTreeRoot()
	ua.SplitNewWindow(.LeftRight) // 2 窗格
	ua.FocusMove(.Left)
	ua.SplitNewWindow(.UpDown) // 3 窗格

	// 语义:返回"仍有窗格"(会话可有可无)。空窗格无 console = 无会话,窗格在 = 继续
	check("无会话但窗格在:轮询继续", ua.PollSessions())
	check("窗格数仍 = 3", ua.ConsoleCount() == 3)

	// 销毁一个窗格,剩余 2
	check("销毁焦点窗格", ua.DestroyWindow())
	check("窗格数 = 2", ua.ConsoleCount() == 2)
	check("焦点有效", ua.GetFocusWindow().id != 0)

	// 再销毁到空:最后一个窗格销毁 = 整树重置为空根叶(无 console)
	check("销毁剩余", ua.DestroyWindow() && ua.DestroyWindow())
	check("无 console", cv.NodeConsole(cv.WindowTreeRoot()) == nil)
	check("无窗格:会话轮询结束", !ua.PollSessions())

	fmt.printf("\n%s (%d failures)\n", fails == 0 ? "ALL PASS" : "SOME FAILED", fails)
}
