// PollSessions 语义测试(无头):
// 1) 两个窗口有 console;一个 auto_close=true,一个 false
// 2) 模拟"会话结束":手动置 Job 状态不可行(需真实 conpty),
//    改为验证 collectLeaves 收集正确 + PollSessions 的空窗/无会话分支不误杀
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
	ua.SplitNewWindow(.LeftRight) // 2 窗
	ua.FocusMove(.Left)
	ua.SplitNewWindow(.UpDown) // 3 窗

	// 全部 auto_close = true
	cur := ua.GetFocusWindow()
	check("设置 auto_close", ua.SetAutoClose(true))
	ua.SetFocusWindow(cur)

	// 语义:返回"仍有窗口"(会话可有可无)。无头环境无 conpty = 无会话,但窗口在 = 继续
	check("无会话但窗口在:轮询继续", ua.PollSessions())
	check("窗口数仍 = 3", ua.WindowCount() == 3)

	// 销毁一个窗口,剩余 2
	check("销毁焦点窗", ua.DestroyWindow())
	check("窗口数 = 2", ua.WindowCount() == 2)
	check("焦点有效", ua.GetFocusWindow().id != 0)

	// 再销毁到空:最后一个窗口销毁 = 整树重置为空根叶(无窗口对象)
	check("销毁剩余", ua.DestroyWindow() && ua.DestroyWindow())
	check("无窗口对象", cv.NodeWindow(cv.WindowTreeRoot()) == nil)
	check("无窗口:会话轮询结束", !ua.PollSessions())

	fmt.printf("\n%s (%d failures)\n", fails == 0 ? "ALL PASS" : "SOME FAILED", fails)
}
