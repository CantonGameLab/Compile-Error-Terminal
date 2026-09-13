// LaunchConsole 继承 cwd 的端到端验证:走完整 canvas 路径(页 → 树 → 字体 → launch),
// 而不是只测 conpty 层。子进程用 `cmd /c cd` 自报工作目录,再从 TermBuffer 里读出来。
// 用法:odin run playground/cwdlaunch/
package main

import cv "../../src/canvas"
import mem "../../src/memory"
import "core:fmt"
import "core:time"
import "core:unicode/utf8"

dumpBuffer :: proc(root : mem.Handle) {
	console := cv.NodeConsole(root)
	if console == nil {
		fmt.println("  (no console)")
		return
	}
	tb := cv.GetTermBuffer(console.active_term_buffer_id)
	if tb == nil {
		fmt.println("  (no buffer)")
		return
	}
	for line, i in tb.lines {
		s := make([dynamic]u8, 0, 128)
		for c in line.cells {
			if c.cp != 0 {
				b, n := utf8.encode_rune(c.cp)
				append(&s, ..b[:n])
			}
		}
		if len(s) > 0 {
			fmt.printf("  L%d: %s\n", i, string(s[:]))
		}
		delete(s)
	}
}

main :: proc() {
	cv.PageNew()
	root := cv.WindowTreeRoot()
	fmt.printf("root id=%d\n", root.id)

	font_ok := cv.SetConsoleFont("Consolas", 16, root)
	if !font_ok {
		font_ok = cv.SetConsoleFont("Cascadia Code", 16, root)
	}
	fmt.printf("字体加载=%v\n", font_ok)
	if !font_ok {
		return
	}

	cv.SetSessionCwd("C:/Windows")
	fmt.printf("session_cwd=(%s)\n", cv.GetSessionCwd())

	launched := cv.LaunchConsole("cmd.exe /c cd", root)
	fmt.printf("launch=%v\n", launched)
	if !launched {
		return
	}

	for _ in 0 ..< 300 {
		cv.ConsoleUpdateTree(cv.WindowTreeRoot())
		time.sleep(5 * time.Millisecond)
	}

	fmt.println("--- 场景 A:配置默认 cwd → 新会话(期望 C:\\Windows)---")
	dumpBuffer(root)

	// 场景 B:已有会话记忆了目录(OSC 7 上报)→ 从它 split 出的新会话继承该目录
	console_h := cv.NodeConsoleId(root)
	if console_h.id != 0 {
		cv.SetConsoleCwd(console_h, "C:/Users") // 模拟 shell 的 OSC 7 上报
		fmt.printf("\n会话 1 记忆目录=(%s)\n", cv.NodeConsole(root).cwd)

		ok2 := cv.LaunchConsole("cmd.exe /c cd", root) // 已有会话 → 自动 split
		fmt.printf("第二次 launch=%v\n", ok2)
		for _ in 0 ..< 300 {
			cv.ConsoleUpdateTree(cv.WindowTreeRoot())
			time.sleep(5 * time.Millisecond)
		}
		fmt.println("--- 场景 B:新会话 buffer(期望 C:\\Users)---")
		dumpBuffer(cv.GetFocusWindow())
	}
}
