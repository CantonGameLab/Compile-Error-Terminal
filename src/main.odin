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
		fmt.eprintln("render init failed")
		return
	}
	defer render.Quit()
	if !input.Init(render.GetWindow()) {
		fmt.eprintln("input init failed")
		return
	}

	// 配置逐行执行;顺序由配置自己负责(需要窗格的命令写在 page-new 之后)。
	command.LoadConfig()
	if canvas.PageCount() == 0 {
		canvas.PageNew() // 配置未建页:保底建第一页(空窗格,无默认启动)
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
			fmt.println("Thank you for using our terminal emulator sailor!")
			break
		}
		render.Update()
	}
}
