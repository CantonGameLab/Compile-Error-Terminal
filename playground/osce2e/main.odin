// OSC 端到端探针:真实链路,不伪造 parser 输入。
//   --emit [--long] 角色:子进程用 WriteFile 直发 OSC 字节(经 ConPTY 管道)
//   主角色:dterm 侧走 UpdateConsole(ring → vtparse 状态机 → oscDispatch → 落点)
// 两轮:
//   轮 1 基础:BEL 终止 / ST 终止 / UTF-8 多字节标题 / OSC 7 / OSC 52
//   轮 2 长标题:3000 字节 OSC(跨 ring 分块到达)→ 断言完整收下并按 128 截断
// 用法:odin run playground/osce2e/          基础轮
//       odin run playground/osce2e/ -- --long  长标题轮
package main

import ct "../../src/conpty"
import cv "../../src/canvas"
import inp "../../src/input"
import s3 "vendor:sdl3"
import win "core:sys/windows"
import "core:fmt"
import "core:os"
import "core:time"

fail_count : int

DIAG :: "playground/osce2e/diag.txt"

check :: proc(name : string, got, want : $T) {
	if got == want {
		fmt.printf("  ok  %s\n", name)
	} else {
		fmt.printf("FAIL  %s got=%v want=%v\n", name, got, want)
		fail_count += 1
	}
}

// 子进程:直发字节(不经 shell,排除 shell 的引号/编码干扰)
emit :: proc(mode : string) {
	h := win.GetStdHandle(win.STD_OUTPUT_HANDLE)
	written : win.DWORD
	write :: proc(h : win.HANDLE, s : string, written : ^win.DWORD) {
		_ = win.WriteFile(h, raw_data(s), u32(len(s)), written, nil)
	}
	switch mode {
	case "long":
		// 3000 字节标题:超过 OSC_BUFFER 之前,但远超 APP_TITLE_MAX(128)
		buf : [4096]u8
		n := 0
		n += copy(buf[n:], "\x1b]2;")
		for n < 3000 {
			buf[n] = 'A'
			n += 1
		}
		n += copy(buf[n:], "\x07")
		write(h, string(buf[:n]), &written)
	case "silent":
		// 什么都不发:观察 conhost 自己注入的序列
	case "console":
		// 复刻 cygwin 等 tty 层的典型行为:打开 CONOUT$ 用控制台 API 写。
		// 这条路经进 conhost,与我们直连管道的 WriteFile 路径不同。
		fname := win.utf8_to_wstring("CONOUT$")
		ch := win.CreateFileW(
			fname,
			win.GENERIC_WRITE,
			win.FILE_SHARE_READ | win.FILE_SHARE_WRITE,
			nil,
			win.OPEN_EXISTING,
			0,
			nil,
		)
		if ch == win.INVALID_HANDLE_VALUE {
			_ = os.write_entire_file(DIAG, "CONOUT$ open failed")
			return
		}
		s := "\x1b]7;file:///C:/Users/GroupTheory\x07" + "\x1b]1338;probe-payload\x07" + "\x1b]9999;also-probe\x07"
		ws := win.utf8_to_wstring(s)
		nw : win.DWORD
		okw := win.WriteConsoleW(ch, rawptr(ws), u32(len(s)), &nw, nil)
		_ = os.write_entire_file(DIAG, fmt.tprintf("WriteConsoleW ok=%v written=%d", okw, nw))
		win.CloseHandle(ch)
	case:
		write(h, "\x1b]2;DT-TITLE-BEL\x07", &written) // OSC 2 + BEL
		write(h, "\x1b]7;file:///C:/Windows\x07", &written) // OSC 7
		write(h, "\x1b]52;c;aGVsbG8=\x07", &written) // OSC 52 "hello"
		write(h, "\x1b]0;中文标题\x1b\\", &written) // OSC 0 + ST + UTF-8(最后生效)
	}
	time.sleep(1500 * time.Millisecond)
}

// 不走 canvas,直接 dump conpty ring 的原始字节(转义可视化)
dumpRaw :: proc(cmdline : string) {
	ctx, ok := ct.CreateConptyContext({80, 24}, cmdline)
	if !ok {
		fmt.eprintln("conpty failed")
		return
	}
	_ = ct.StartReadThread(ctx)
	defer ct.DestroyConpty(ctx)
	time.sleep(1600 * time.Millisecond)

	data := ct.GetReadWriteData(ctx)
	if data == nil {
		fmt.println("no ring")
		return
	}
	buf : [16384]u8
	n := ct.RingPop(data, buf[:])
	fmt.printf("原始字节 %d 个:\n", n)
	vis := make([dynamic]u8, 0, 1024)
	defer delete(vis)
	for b in buf[:n] {
		switch {
		case b == 0x1b:
			append(&vis, ..transmute([]u8)string("<ESC>"))
		case b == 0x07:
			append(&vis, ..transmute([]u8)string("<BEL>"))
		case b == 0x0d:
			append(&vis, ..transmute([]u8)string("<CR>"))
		case b == 0x0a:
			append(&vis, ..transmute([]u8)string("<LF>"))
		case b >= 0x20 && b < 0x7f:
			append(&vis, b)
		case:
			append(&vis, ..transmute([]u8)fmt.tprintf("<%02X>", b))
		}
	}
	fmt.println(string(vis[:]))
}

main :: proc() {
	mode := ""
	for a in os.args[1:] {
		if a == "--long" {
			mode = "long"
		}
		if a == "--silent" {
			mode = "silent"
		}
		if a == "--bash" {
			mode = "bash"
		}
		if a == "--bashraw" {
			mode = "bashraw"
		}
		if a == "--pwsh" {
			mode = "pwsh"
		}
		if a == "--pwshraw" {
			mode = "pwshraw"
		}
		if a == "--console" {
			mode = "console"
		}
		if a == "--diag" {
			mode = "diag"
		}
	}
	if len(os.args) > 1 && os.args[1] == "--emit" {
		emit(mode)
		return
	}

	_ = s3.Init(s3.INIT_VIDEO) // 剪贴板需要
	defer s3.Quit()

	exe := os.args[0]
	cmdline := fmt.tprintf("\"%s\" --emit", exe)
	switch mode {
	case "long":
		cmdline = fmt.tprintf("\"%s\" --emit --long", exe)
	case "silent":
		cmdline = "cmd.exe /c cd" // 之前观察到这个命令下 conhost 会注入 OSC 0 标题
	case "pwsh":
		// 经 Console API 写(可能被 conhost 接管 —— 交互式 shell 的输出路径)
		cmdline = `powershell.exe -NoProfile -Command "$e=[char]27;$b=[char]7;[Console]::Out.Write($e+']7;file:///C:/Users/GroupTheory'+$b);[Console]::Out.Flush();Start-Sleep -Milliseconds 900"`
	case "pwshraw":
		// 显式走 stdout 流(WriteFile 路径,绕过 Console API)
		cmdline = `powershell.exe -NoProfile -Command "$e=[char]27;$b=[char]7;$s=$e+']7;file:///C:/Users/GroupTheory'+$b;$o=[Console]::OpenStandardOutput();$d=[Text.Encoding]::UTF8.GetBytes($s);$o.Write($d,0,$d.Length);$o.Flush();Start-Sleep -Milliseconds 900"`
	case "console":
		// 经 CONOUT$ + WriteConsoleW 发(复刻 tty 层行为)
		cmdline = fmt.tprintf("\"%s\" --emit --console", exe)
		dumpRaw(cmdline) // 先看原始字节:分辨「conhost 没转发」还是「dterm 没解析」
	case "bash":
		// 用户的实际场景:msys2 bash 里敲 printf(经 bash 内建 → fd 1)
		cmdline = `C:\msys64\usr\bin\bash.exe -c "printf '\033]7;file:///C:/Users/GroupTheory\007'; echo BASH-MARK; sleep 1"`
	case "bashraw":
		cmdline = `C:\msys64\usr\bin\bash.exe -c "printf '\033]7;file:///C:/Users/GroupTheory\007'; echo BASH-MARK; sleep 1"`
		dumpRaw(cmdline)
		return
	}
	fmt.printf("== %s ==\n", modeName(mode))

	ctx, ok := ct.CreateConptyContext({80, 24}, cmdline)
	if !ok {
		fmt.eprintln("conpty failed")
		return
	}
	_ = ct.StartReadThread(ctx)
	defer ct.DestroyConpty(ctx)

	ch, cok := cv.CreateConsole(24, 80, ctx)
	check("console", cok, true)
	if !cok {
		return
	}
	defer cv.DestroyConsole(ch)

	want_a : [128]u8
	for i in 0 ..< len(want_a) {
		want_a[i] = 'A'
	}
	want := mode == "long" ? string(want_a[:]) : "中文标题"
	for _ in 0 ..< 400 {
		cv.ConsoleUpdateTree(cv.WindowTreeRoot()) // 真实 dterm 每帧入口(不是 UpdateConsole 直调)
		if cv.GetConsole(ch).app_title == want {
			break
		}
		time.sleep(5 * time.Millisecond)
	}

	console := cv.GetConsole(ch)
	switch mode {
	case "long":
		check("长标题被完整收下并截断到 128", len(console.app_title), 128)
		all_a := true
		for c in console.app_title {
			if c != 'A' {
				all_a = false
			}
		}
		check("内容全为 A(未被中间截断污染)", all_a, true)
	case "silent":
		// 观察项:conhost 是否注入初始 OSC 0 取决于子进程与时序,不做硬断言
		fmt.printf("静默子进程后 app_title=(%s)  session_cwd=(%s)\n", console.app_title, cv.GetSessionCwd())
		fmt.println("(若为非空 = conhost 注入了初始标题,它会覆盖 Page.title 回落值)")
	case "bash":
		// 用户报的场景:bash 里 printf '\033]7;file:///C:/Users/GroupTheory\007'
		fmt.printf("bash 发 OSC 7 后 session_cwd=(%s)\n", cv.GetSessionCwd())
		check("bash printf 的 OSC 7 生效", cv.GetSessionCwd(), "C:\\Users\\GroupTheory")
	case "pwsh":
		fmt.printf("Console API 路径后 session_cwd=(%s)\n", cv.GetSessionCwd())
		check("经 Console API 的 OSC 7 生效", cv.GetSessionCwd(), "C:\\Users\\GroupTheory")
	case "console":
		fmt.printf("CONOUT$ 路径后 session_cwd=(%s)\n", cv.GetSessionCwd())
		if d, derr := os.read_entire_file_from_path(DIAG, context.allocator); derr == nil {
			fmt.printf("writer diag: %s\n", string(d))
		}
		check("经 conhost 控制台(WriteConsoleW)的 OSC 7 生效", cv.GetSessionCwd(), "C:\\Users\\GroupTheory")
	case "pwshraw":
		fmt.printf("stdout 流路径后 session_cwd=(%s)\n", cv.GetSessionCwd())
		check("经 stdout 流的 OSC 7 生效", cv.GetSessionCwd(), "C:\\Users\\GroupTheory")
	case:
		fmt.printf("最终 app_title=(%s)  session_cwd=(%s)\n", console.app_title, cv.GetSessionCwd())
		check("OSC 0 + ST + UTF-8 标题", console.app_title, "中文标题")
		check("OSC 7 → 全局会话目录", cv.GetSessionCwd(), "C:\\Windows")
		check("OSC 52 → 剪贴板", string(inp.GetClipboardText()), "hello")
	}

	fmt.printf("\n结果:%s\n", fail_count == 0 ? "ALL PASS" : "有失败")
}

modeName :: proc(mode : string) -> string {
	switch mode {
	case "long":
		return "轮 2:3000 字节标题(跨包 + 截断)"
	case "silent":
		return "轮 3:静默子进程(看 conhost 注入)"
	case "bash":
		return "轮 4:msys2 bash 内 printf(用户报的场景)"
	case:
		return "轮 1:基础语义"
	}
}
