package conpty

import "core:fmt"
import win "core:sys/windows"
import mem "../memory"

// Job Object 用途:把整个 ConPTY 进程树(含孙进程,如 opencode 拉起的 node)放进 Job,
// 会话结束判定 = Job 内活动进程数为 0,而不是只查直接子进程——
// 直接子进程可能是 cmd 包装(msys2_shell.cmd)提前退出,而真实 shell 还活着;
// 反过来 opencode 退出后残留 node 子进程,conhost 认为还有连接,读管道不关。
// 绑定在 api.odin(静态链接 kernel32)。

ConptyContext :: struct {
	hpc          : HPCON,
	read_conpty  : win.HANDLE, // 读子进程输出(VT 序列)
	write_conpty : win.HANDLE, // 写键盘输入
	proc_info    : win.PROCESS_INFORMATION,
	child_procid : win.DWORD,
	job          : win.HANDLE, // Job Object:跟踪整个进程树,会话结束判定
}

MAX_CONPTY_SLOTS :: 32

conpty_contexts : mem.GenArray(MAX_CONPTY_SLOTS, ConptyContext)

CreateConptyContext :: proc(size : win.COORD, cmd : string) -> (h : mem.Handle, ok : bool) {
	ctx, created := createConptyContextValue(size, cmd)
	if !created {
		return {}, false
	}
	h = mem.Alloc(&conpty_contexts, ctx)
	if h.id == 0 {
		destroyConptyContext(&ctx)
		return {}, false
	}
	return h, true
}

GetConptyContext :: proc(h : mem.Handle) -> ^ConptyContext {
	return mem.Get(&conpty_contexts, h)
}

createConptyContextValue :: proc(size: win.COORD, cmd: string) -> (ctx: ConptyContext, ok: bool = false) {
	conpty_side_read : win.HANDLE // ConPTY 端读(子进程键盘事件)
	main_side_write  : win.HANDLE // 我们写键盘输入
	main_side_read   : win.HANDLE // 我们读输出
	conpty_side_write: win.HANDLE // ConPTY 端写(发给子进程)

	// 本地管道句柄:CreatePseudoConsole 后 conhost 已复制副本,CreateProcessW
	// 也会把 std 句柄复制给子进程,本地副本必须关闭——否则输出管道写端
	// 永远有句柄,子进程退出后读端不产生 EOF,读线程永久阻塞(exit 卡死根因)
	defer win.CloseHandle(conpty_side_read)
	defer win.CloseHandle(conpty_side_write)

	if !win.CreatePipe(&conpty_side_read, &main_side_write, nil, 0) {
		return
	}
	if !win.CreatePipe(&main_side_read, &conpty_side_write, nil, 0) {
		win.CloseHandle(main_side_write) // conpty_side 两个由 defer 统一关
		return
	}

	hpc, hr := createPseudoConsole(size, conpty_side_read, conpty_side_write, 0)
	if hr != win.HRESULT(0) {
		fmt.eprintfln("CreatePseudoConsole returned 0x%X. Windows Terminal calls this same function all day and never whines — it saves the whining for the 1757 open issues on its tracker. This one is yours.", transmute(u32) hr)
		win.CloseHandle(main_side_write)
		win.CloseHandle(main_side_read)
		return
	}

	ctx.hpc          = hpc
	ctx.read_conpty  = main_side_read
	ctx.write_conpty = main_side_write

	start_info: STARTUPINFOEXW
	start_info.StartupInfo.cb = size_of(start_info)

	attr_size: win.SIZE_T
	InitializeProcThreadAttributeList(nil, 1, 0, &attr_size)

	heap := win.GetProcessHeap()
	start_info.lpAttributeList = cast(LPPROC_THREAD_ATTRIBUTE_LIST) win.HeapAlloc(heap, 0, attr_size)
	if start_info.lpAttributeList == nil {
		destroyConptyContext(&ctx)
		return
	}
	if !InitializeProcThreadAttributeList(start_info.lpAttributeList, 1, 0, &attr_size) {
		destroyConptyContext(&ctx)
		win.HeapFree(heap, 0, start_info.lpAttributeList)
		return
	}
	if !UpdateProcThreadAttribute(
		start_info.lpAttributeList,
		0,
		PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
		cast(rawptr) hpc,
		size_of(HPCON),
		nil,
		nil,
	) {
		destroyConptyContext(&ctx)
		DeleteProcThreadAttributeList(start_info.lpAttributeList)
		win.HeapFree(heap, 0, start_info.lpAttributeList)
		return
	}

	// 子进程 std 句柄直连管道:pseudoconsole 只接管控制台(conhost),std 句柄
	// 否则会继承父进程(stdout 泄漏到父控制台),这里显式重定向到 ConPTY 管道两端
	start_info.StartupInfo.dwFlags = win.STARTF_USESTDHANDLES
	start_info.StartupInfo.hStdInput = conpty_side_read
	start_info.StartupInfo.hStdOutput = conpty_side_write
	start_info.StartupInfo.hStdError = conpty_side_write

	cmd_wide := win.utf8_to_wstring(cmd)

	// Job Object:容纳整个进程树(含孙进程),KILL_ON_JOB_CLOSE 保证
	// 我们关闭 Job 句柄时树内所有进程被终止(避免 opencode 退出后残留 node 子进程
	// 让 conhost 认为还有连接,读管道永不关闭 → 界面冻结)
	ctx.job = jobCreate()
	if ctx.job != nil {
		jobSetKillOnClose(ctx.job)
	}

	// 终端支持真彩色:注入 COLORTERM=truecolor,否则 yazi 等应用
	// 检测不到颜色能力,降级为无颜色输出(reverse 高亮)
	old_colorterm : [64]u16
	had_colorterm := win.GetEnvironmentVariableW(win.LPCWSTR("COLORTERM"), &old_colorterm[0], len(old_colorterm)) > 0
	win.SetEnvironmentVariableW(win.LPCWSTR("COLORTERM"), win.LPCWSTR("truecolor"))

	ok_create := win.CreateProcessW(
		nil,
		cmd_wide,
		nil,
		nil,
		false,
		win.EXTENDED_STARTUPINFO_PRESENT,
		nil,
		nil,
		&start_info.StartupInfo,
		&ctx.proc_info,
	)

	// 恢复父进程环境
	if had_colorterm {
		win.SetEnvironmentVariableW(win.LPCWSTR("COLORTERM"), cstring16(&old_colorterm[0]))
	} else {
		win.SetEnvironmentVariableW(win.LPCWSTR("COLORTERM"), nil)
	}

	if !ok_create {
		err := win.GetLastError()
		fmt.eprintfln("CreateProcessW failed: %v. I tried to make a shell and shot blanks. Check your command before you question my fertility.", err)
		destroyConptyContext(&ctx)
		DeleteProcThreadAttributeList(start_info.lpAttributeList)
		win.HeapFree(heap, 0, start_info.lpAttributeList)
		return
	}
	ctx.child_procid = ctx.proc_info.dwProcessId

	// 创建进程成功后把它放进 Job
	if ctx.job != nil {
		jobAssign(ctx.job, ctx.proc_info.hProcess)
		when ODIN_DEBUG {
			fmt.eprintfln("AssignProcessToJobObject err=%v", win.GetLastError())
		}
	}

	// hThread 不再需要;hProcess 保留用于等待/终止
	win.CloseHandle(ctx.proc_info.hThread)
	ctx.proc_info.hThread = win.INVALID_HANDLE_VALUE

	DeleteProcThreadAttributeList(start_info.lpAttributeList)
	win.HeapFree(heap, 0, start_info.lpAttributeList)
	return ctx, true
}

readConptyOutput :: proc(conpty_context: ^ConptyContext, buf: []byte) -> (n: u32, ok: bool) {
	if conpty_context.read_conpty == win.INVALID_HANDLE_VALUE {
		return 0, false
	}
	bytes_we_read: win.DWORD
	if !win.ReadFile(conpty_context.read_conpty, raw_data(buf), u32(len(buf)), &bytes_we_read, nil) {
		return 0, false
	}
	if bytes_we_read == 0 {
		return 0, false // EOF:写端全部关闭(子进程树退出)
	}
	return bytes_we_read, true
}

// 回显由终端负责;直接传 UTF-8 字节
WriteConptyInput :: proc(h : mem.Handle, data: []byte) -> (n: u32, ok: bool) {
	conpty_context := GetConptyContext(h)
	if conpty_context == nil {
		return 0, false
	}
	if conpty_context.write_conpty == win.INVALID_HANDLE_VALUE {
		return 0, false
	}
	bytes_written: win.DWORD
	if !win.WriteFile(conpty_context.write_conpty, raw_data(data), u32(len(data)), &bytes_written, nil) {
		return 0, false
	}
	return bytes_written, true
}

// 窗口缩放时:cols = 像素宽/单元宽,rows = 像素高/单元高
Resize :: proc(h : mem.Handle, cols, rows: u16) -> bool {
	conpty_context := GetConptyContext(h)
	if conpty_context == nil {
		return false
	}
	hr := resizePseudoConsole(conpty_context.hpc, win.COORD{win.SHORT(cols), win.SHORT(rows)})
	return hr == win.HRESULT(0)
}

// Job Object 辅助:创建 / 设置 KILL_ON_JOB_CLOSE / AssignProcessToJobObject
@(private = "file")
jobCreate :: proc() -> win.HANDLE {
	return CreateJobObjectW(nil, nil)
}

@(private = "file")
jobSetKillOnClose :: proc(job : win.HANDLE) {
	info : JobObjectExtendedLimitInfo
	info.basic_limit.limit_flags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
	SetInformationJobObject(job, JOBOBJECTINFOCLASS_EXTENDED_LIMIT, &info, size_of(JobObjectExtendedLimitInfo))
}

@(private = "file")
jobAssign :: proc(job, process : win.HANDLE) {
	AssignProcessToJobObject(job, process)
}

// 子进程(主进程)是否还活着;false = 会话结束。
// 判定 = GetExitCodeProcess(最终信号)。Job 只用于 KILL_ON_CLOSE 兜底,
// 不参与存活判定:msys2 等进程会脱离我们创建的 Job(JobActiveProcesses 恒 0,
// 用它判定会误杀活会话)。
IsChildAlive :: proc(h : mem.Handle) -> bool {
	ctx := GetConptyContext(h)
	if ctx == nil {
		return false
	}
	if ctx.proc_info.hProcess == win.INVALID_HANDLE_VALUE {
		return false
	}
	code: win.DWORD
	if !win.GetExitCodeProcess(ctx.proc_info.hProcess, &code) {
		return false
	}
	return code == STILL_ACTIVE
}

DestroyConpty :: proc(h : mem.Handle) {
	ctx := GetConptyContext(h)
	if ctx == nil {
		return
	}
	destroyConptyContext(ctx)
	mem.Free(&conpty_contexts, h)
}

// 供创建失败回滚使用(槽位尚未登记完成)
destroyConptyContext :: proc(conpty_context: ^ConptyContext) {
	if conpty_context == nil {
		return
	}
	if conpty_context.hpc != nil {
		closePseudoConsole(conpty_context.hpc)
		conpty_context.hpc = nil
	}
	if conpty_context.read_conpty != win.INVALID_HANDLE_VALUE {
		win.CloseHandle(conpty_context.read_conpty) // 阻塞中的 read 立即返回 false
		conpty_context.read_conpty = win.INVALID_HANDLE_VALUE
	}
	if conpty_context.write_conpty != win.INVALID_HANDLE_VALUE {
		win.CloseHandle(conpty_context.write_conpty)
		conpty_context.write_conpty = win.INVALID_HANDLE_VALUE
	}
	if conpty_context.proc_info.hProcess != win.INVALID_HANDLE_VALUE {
		if win.WaitForSingleObject(conpty_context.proc_info.hProcess, 3000) != win.WAIT_OBJECT_0 {
			win.TerminateProcess(conpty_context.proc_info.hProcess, 1)
			win.WaitForSingleObject(conpty_context.proc_info.hProcess, win.INFINITE)
		}
		win.CloseHandle(conpty_context.proc_info.hProcess)
		conpty_context.proc_info.hProcess = win.INVALID_HANDLE_VALUE
	}
	// Job 句柄最后关:关闭触发 KILL_ON_JOB_CLOSE,树内残留进程(如 opencode 的
	// node 子进程)被终止,conhost 检测到全部断开后读管道关闭,读线程退出
	if conpty_context.job != nil {
		win.CloseHandle(conpty_context.job)
		conpty_context.job = nil
	}
}
