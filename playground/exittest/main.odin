// 会话结束回归:LaunchConsole(cmd.exe)→ feed "exit\r\n" → 轮询读线程/PollSessions。
// 诊断 exit 不自动关窗:读线程是否 dead(管道 EOF)、PollSessions 是否判定结束。
// 日志:无缓冲文件(直接 write,崩溃不丢)。
package main

import ct "../../src/conpty"
import cv "../../src/canvas"
import fnt "../../src/font"
import "core:fmt"
import "core:os"
import "core:time"

log_fd : ^os.File

logf :: proc(s : string) {
	os.write(log_fd, transmute([]u8)s)
}

main :: proc() {
	file, _ := os.open("exittest.log", os.O_CREATE | os.O_WRONLY | os.O_TRUNC)
	log_fd = file
	defer os.close(log_fd)

	logf(fmt.tprintf("== step: PageNew ==\n"))
	page := cv.PageNew()
	if page.id == 0 {
		logf("FAIL: no page\n")
		return
	}
	logf("== step: SetConsoleFont ==\n")
	if !cv.SetConsoleFont("resource/font/Go-Mono/GoMonoNerdFontMono-Regular.ttf", 18) {
		logf("FAIL: font failed\n")
		return
	}
	logf("== step: LaunchConsole cmd.exe ==\n")
	if !cv.LaunchConsole("cmd.exe") {
		logf("FAIL: launch failed\n")
		return
	}
	logf("launched\n")
	console := cv.NodeConsole(cv.GetFocusWindow())
	if console == nil {
		logf("FAIL: no console\n")
		return
	}
	logf(fmt.tprintf("conpty=%d launched, waiting for prompt...\n", console.conpty_handle.id))
	time.sleep(800 * time.Millisecond)

	// 写 exit 回车(与用户在 shell 敲 exit 等价)
	s := "exit\r\n"
	cv.FeedConsole(transmute([]u8)s)
	logf("== fed 'exit' ==\n")

	// 轮询主循环判定序列(等价 PollSessions 帧调用)
	for i in 0 ..< 30 {
		time.sleep(200 * time.Millisecond)
		alive_rt := ct.IsReadThreadAlive(console.conpty_handle)
		stay := cv.PollSessions()
		windows := cv.ConsoleCount()
		logf(fmt.tprintf("t=%4dms readthread_alive=%v poll_sessions=%v windows=%d\n",
			(i + 1) * 200, alive_rt, stay, windows))
		if !stay {
			logf("== PASS: session ended -> all closed ==\n")
			return
		}
		if windows == 0 {
			logf("== FAIL: windows gone but PollSessions stayed true ==\n")
			return
		}
	}
	logf("== FAIL: still alive after 6s (read thread never died) ==\n")
}
