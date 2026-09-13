// 窗口主循环(纯编排壳):初始化 → 读配置 → 保底建页 → 帧循环。
// 数据流:event/input → command(键优先消费)→ canvas → render,单向;main 不持业务状态。
// 配置 = 命令脚本(见 command/config.odin):键位/主题/字体/默认启动/页面布局全部来自
// 配置文件(逐行顺序执行,load 就地展开),本文件不硬编码任何用户配置。
package main

import "canvas"
import "command"
import "event"
import "input"
import "render"
import "core:fmt"

main :: proc() {
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

	//MAIN LOOP标准循环

	for {
		input.BeginFrame() // 清上一帧边沿(事件泵先于本模块调用)
		event.Update() // 事件泵 → 分发(源模块:尺寸→canvas,键鼠→input)
		if event.QuitRequested() {
			break
		}
		command.Update() // ① 命令消费(canvas 之前):键绑定(命中 → consumed)+ 命令栏队列(上帧提交)
		ret := canvas.Update() // ② 剩余:鼠标路由/文本(未消费)/树/轮询/事件读回
		if !ret { 
			fmt.println("all windows closed")
			fmt.println("Thank you for using our Compile Error terminal emulator. SAILOR!")
			break
		}
		// OS 窗口标题:焦点 console 的应用标题(OSC 0/2);空 = 回落页标题
		render.SyncWindowTitle(canvas.FocusedAppTitle(), canvas.CurrentPageTitle())
		render.Update()
	}
}
