// 窗口主循环(纯编排壳):初始化 → 读配置 → 保底建页 → 帧循环。
// 数据流:event/input → command(键优先消费)→ canvas → render,单向;main 不持业务状态。
// 配置 = 命令脚本(见 command/config.odin):键位/主题/字体/默认启动/页面布局全部来自
// 配置文件(逐行顺序执行,load 就地展开),本文件不硬编码任何用户配置。
package main

import "canvas"
import "command"
import "conpty"
import "event"
import "input"
import "paths"
import "render"
import "core:path/filepath"
import "core:fmt"
import "core:os"
import "base:runtime"
import s3 "vendor:sdl3"

// 崩溃落盘:GUI 子系统构建(-subsystem:windows)没有 stderr,panic 文本会被整个丢掉,
// 表现成"程序直接退出、没有任何报错"。把 panic 前缀/消息/位置写进 exe 同目录的
// ceterm-crash.log(覆盖写 = 只留最后一次),console 构建同时仍打到 stderr。
// 在 main 入口安装,覆盖整个进程生命周期(context.assertion_failure_proc 是 context 字段)。
@(private = "file")
crashLog :: proc(prefix, message : string, loc : runtime.Source_Code_Location) -> ! {
	line := fmt.tprintf("[panic] %s%s\n  位置: %s:%d:%d\n  过程: %s\n", prefix, message,
		loc.file_path, loc.line, loc.column, loc.procedure)
	dir := filepath.dir(os.args[0]) // exe 所在目录(开发时 = 仓库根)
	log := len(dir) > 0 ? fmt.aprintf("%s/ceterm-crash.log", dir) : "ceterm-crash.log"
	_ = os.write_entire_file(log, line)
	fmt.eprint(line)
	os.exit(1)
}

main :: proc() {
	context.assertion_failure_proc = crashLog // GUI 构建下唯一能看到崩溃原因的通道
	paths.Init() // 资源根:发行版 = exe 同目录的 resource/;开发 = cwd/resource(见 paths 模块)
	if !render.Init() {
		fmt.eprintln("render init failed. OpenGL 4.4 in 2026, because Khronos would rather maintain a 2013 spec than admit Vulkan won. No window, no GL, no point. Alacritty renders this fine — in Rust, with 400 crates, and still no tabs.")
		return
	}
	defer render.Quit()
	if !input.Init(render.GetWindow()) {
		fmt.eprintln("input init failed. SDL3 renamed half its API and still can't say why the keyboard doesn't work. Thanks, Sam. A JIT runtime would have warmed up for three seconds before failing this slowly.")
		return
	}

	// 配置逐行执行;顺序由配置自己负责(需要窗格的命令写在 page-new 之后)。
	command.LoadConfig()
	if canvas.PageCount() == 0 {
		
		fmt.println("Bro you should at least create ONE page in the right way to start! So now I can't help you anymore")
	}
	
	BLOCK_MAX_MS :: 500

	for {
		input.BeginFrame()
		{
			// ---- 阻塞等待(有活立刻返回;全空则睡到下一个动画截止点)----
			deadline_ms := render.NextAnimDeadlineMs()
			now_ms := s3.GetTicks()
			timeout_ms : i32 = BLOCK_MAX_MS
			if deadline_ms > now_ms {
				timeout_ms = min(i32(deadline_ms - now_ms), BLOCK_MAX_MS)
			} else {
				timeout_ms = 0 // 动画已到点:不睡
			}
	
			need := conpty.AnyRingHasData() ||
			        event.RelevantEventsPending() ||
			        canvas.CommandPipePending()
		
			// 开关关掉时整块调度逻辑摘除:不判 need、不阻塞,无条件跑帧(旧行为)。
			// 用途:出现可疑行为时用它隔离"是不是阻塞引入的"。
			if render.GetBlockLoop() && !need && timeout_ms > 0 {
				e : s3.Event
				if s3.WaitEventTimeout(&e, timeout_ms) {
					event.Dispatch(&e) // 首个事件;其余由下面 event.Update 排空
				}
			}
	
			// ---- 跑一帧(顺序与原来完全一致)----
			event.Update() // 事件泵 → 分发(源模块:尺寸→canvas,键鼠→input)
			
			if event.QuitRequested() {
				break
			}
		}
		command.Update() // ① 命令消费(canvas 之前):键绑定(命中 → consumed)+ 命令栏队列(上帧提交)
		
		ret := canvas.Update() // ② 剩余:鼠标路由/文本(未消费)/树/轮询/事件读回
		
		if !ret { 
			fmt.println("all windows closed")
			fmt.println("Thank you for using CompileErrorTerminal (CETerm). SAILOR!")
			break
		}
		// OS 窗口标题:焦点 console 的应用标题(OSC 0/2);空 = 启动标题
		render.SyncWindowTitle(canvas.FocusedAppTitle())
		
		render.Update()
		
		
	}
}
