// cwd 链路探针:直连 src/conpty,验证「CreateConptyContext 的 cwd 参数是否真的
// 传到了 CreateProcessW 的 lpCurrentDirectory」。子进程用 `cmd /c cd` 打印自己的
// 工作目录 —— 打印出来的是 C:\Windows 就说明后端通了,问题只可能在数据源。
// 用法:odin run playground/cwdprobe/
package main

import ct "../../src/conpty"
import cv "../../src/canvas"
import "core:fmt"
import "core:time"

runCase :: proc(name, cmd, cwd : string) {
	h, ok := ct.CreateConptyContext({80, 24}, cmd, cwd)
	if !ok {
		fmt.printf("%-28s conpty failed\n", name)
		return
	}
	_ = ct.StartReadThread(h)
	time.sleep(900 * time.Millisecond)

	data := ct.GetReadWriteData(h)
	buf : [4096]u8
	n := ct.RingPop(data, buf[:])
	out := string(buf[:n])

	// 只挑可打印部分做目视(conhost 初始化序列会混在里面)
	printable := make([dynamic]u8, 0, 256)
	defer delete(printable)
	for b in transmute([]u8)out {
		if b >= 0x20 && b < 0x7f {
			append(&printable, b)
		} else if b == '\r' || b == '\n' {
			if len(printable) > 0 && printable[len(printable) - 1] != ' ' {
				append(&printable, ' ')
			}
		}
	}
	fmt.printf("%-28s cwd=%-22s -> %s\n", name, cwd == "" ? "(nil)" : cwd, string(printable[:]))
	ct.StopReadThread(h)
}

main :: proc() {
	fmt.println("期望:下面每一行箭头右边都出现该行 cwd 指定的目录\n")
	runCase("cwd = C:\\Windows", "cmd.exe /c cd", "C:\\Windows")
	runCase("cwd = C:\\Users", "cmd.exe /c cd", "C:\\Users")
	runCase("cwd = 空(nil)", "cmd.exe /c cd", "")
	runCase("cwd 不存在(应回退)", "cmd.exe /c cd", "C:\\NoSuchDir_xyz")

	// 组合:全局会话目录(配置 `cwd` / OSC 7 写)→ 新会话初始目录
	fmt.println()
	cv.SetSessionCwd("/c/Windows")
	runCase("全局目录 SetSessionCwd", "cmd.exe /c cd", cv.GetSessionCwd())
}
