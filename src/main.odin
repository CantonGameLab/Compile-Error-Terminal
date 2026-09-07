// 窗口主循环(纯编排壳):初始化 → 按 DAG 顺序调用各模块入口 → 清理。
// 数据流:event/input → command(键优先消费)→ canvas → render,单向;main 不持业务状态。
// 布局:单窗口 0(root),默认 = msys2 bash。
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

	if !initWindows() {
		fmt.eprintln("init windows failed")
		return
	}

	//MAIN LOOP标准循环

	for {
		input.BeginFrame() // 清上一帧边沿(事件泵先于本模块调用)
		event.Update() // 事件泵 → 分发(源模块:尺寸→canvas,键鼠→input)
		if event.QuitRequested() {
			break
		}
		command.Update() // ① 命令消费(canvas 之前):键绑定(命中 → consumed)+ 命令栏队列(上帧提交)
		if !canvas.Update() { // ② 剩余:鼠标路由/文本(未消费)/树/轮询/事件读回
			fmt.println("all windows closed")
			fmt.println("Thank you for using our terminal emulator sailor!")
			break
		}
		render.Update()
	}
}

// 初始化窗口布局(配置函数:userapi 是给用户/配置段落的接口,此处直接使用;
// 运行期内部代码不绕用户接口,一律经 Get* 指针直接操作数据)。
initWindows :: proc() -> bool {
	// 键位绑定表(显式填充一次;查询纯读)
	command.ClearKeyBindings()

	// 焦点
	command.SetKeyBinding(.H, {.Alt}, command.ParsedCommand { kind = .FocusDir, fdir = .Left })
	command.SetKeyBinding(.L, {.Alt}, command.ParsedCommand { kind = .FocusDir, fdir = .Right })
	command.SetKeyBinding(.K, {.Alt}, command.ParsedCommand { kind = .FocusDir, fdir = .Up })
	command.SetKeyBinding(.J, {.Alt}, command.ParsedCommand { kind = .FocusDir, fdir = .Down })

	// 分屏(四方向,与焦点键位同构):新窗在左/下/上/右
	command.SetKeyBinding(.H, {.Alt, .Shift}, command.ParsedCommand { kind = .Split, dir = .LeftRight, split_first = true })
	command.SetKeyBinding(.J, {.Alt, .Shift}, command.ParsedCommand { kind = .Split, dir = .UpDown })
	command.SetKeyBinding(.K, {.Alt, .Shift}, command.ParsedCommand { kind = .Split, dir = .UpDown, split_first = true })
	command.SetKeyBinding(.L, {.Alt, .Shift}, command.ParsedCommand { kind = .Split, dir = .LeftRight })

	// 交换(几何方向邻居)
	command.SetKeyBinding(.H, {.Ctrl, .Shift}, command.ParsedCommand { kind = .Exchange, fdir = .Left })
	command.SetKeyBinding(.L, {.Ctrl, .Shift}, command.ParsedCommand { kind = .Exchange, fdir = .Right })
	command.SetKeyBinding(.K, {.Ctrl, .Shift}, command.ParsedCommand { kind = .Exchange, fdir = .Up })
	command.SetKeyBinding(.J, {.Ctrl, .Shift}, command.ParsedCommand { kind = .Exchange, fdir = .Down })

	// 销毁焦点窗口
	command.SetKeyBinding(.W, {.Ctrl, .Shift}, command.ParsedCommand { kind = .Destroy })

	// 新建页签(WT 惯例;关页 = 关光当前页窗口自动清出)
	command.SetKeyBinding(.T, {.Ctrl, .Shift}, command.ParsedCommand { kind = .PageNew })

	// 历史翻页
	command.SetKeyBinding(.PAGEUP, {.Shift}, command.ParsedCommand { kind = .ReviewUp })
	command.SetKeyBinding(.PAGEDOWN, {.Shift}, command.ParsedCommand { kind = .ReviewDown })

	// 命令栏
	command.SetKeyBinding(.F2, {}, command.ParsedCommand { kind = .ToggleCommandBar })

	// 文本选区:复制/粘贴/全选(默认键位;改键改这一处)
	command.SetKeyBinding(.C, {.Ctrl, .Shift}, command.ParsedCommand { kind = .CopySelection })
	command.SetKeyBinding(.V, {.Ctrl, .Shift}, command.ParsedCommand { kind = .PasteClipboard })
	command.SetKeyBinding(.A, {.Ctrl, .Shift}, command.ParsedCommand { kind = .SelectAll })

	// 字号
	command.SetKeyBinding(.EQUALS, {.Ctrl, .Shift}, command.ParsedCommand { kind = .FontSizeUp })
	command.SetKeyBinding(.MINUS, {.Ctrl, .Shift}, command.ParsedCommand { kind = .FontSizeDown })

	// 页签切换
	command.SetKeyBinding(.TAB, {.Ctrl}, command.ParsedCommand { kind = .PageNext })
	command.SetKeyBinding(.TAB, {.Ctrl, .Shift}, command.ParsedCommand { kind = .PagePrev })

	// Alt+数字键 → 切到对应页(页存活序 1-based,与页签次序一致)
	command.SetKeyBinding(._1, {.Alt}, command.ParsedCommand { kind = .PageSwitch, ival = 1 })
	command.SetKeyBinding(._2, {.Alt}, command.ParsedCommand { kind = .PageSwitch, ival = 2 })
	command.SetKeyBinding(._3, {.Alt}, command.ParsedCommand { kind = .PageSwitch, ival = 3 })
	command.SetKeyBinding(._4, {.Alt}, command.ParsedCommand { kind = .PageSwitch, ival = 4 })
	command.SetKeyBinding(._5, {.Alt}, command.ParsedCommand { kind = .PageSwitch, ival = 5 })
	command.SetKeyBinding(._6, {.Alt}, command.ParsedCommand { kind = .PageSwitch, ival = 6 })
	command.SetKeyBinding(._7, {.Alt}, command.ParsedCommand { kind = .PageSwitch, ival = 7 })
	command.SetKeyBinding(._8, {.Alt}, command.ParsedCommand { kind = .PageSwitch, ival = 8 })
	command.SetKeyBinding(._9, {.Alt}, command.ParsedCommand { kind = .PageSwitch, ival = 9 })

	// Alt+F → 切换无边框窗口(标题栏/边框显隐)
	command.SetKeyBinding(.F, {.Alt}, command.ParsedCommand { kind = .ToggleBorderless })

	canvas.SetDefaultLaunch(
		"bash",
		"FiraCode Nerd Font Mono", 26)

	// 第一页:页根 + 根窗(自动启动默认),成为当前页
	page := canvas.PageNew()
	if page.id == 0 {
		return false
	}

	canvas.SetTheme(canvas.MONOKAI_THEME)

	render.SetBackgroundShaderEnabled(true)
	render.ResetBackgroundShader()
	render.SetVSync(true)

	// 无边框窗口(去除系统标题栏/边框,render 内容不变);
	// 无边框后窗口无法用标题栏拖动/边缘缩放(后续按需加自绘拖拽或 F11 全屏)
	render.SetWindowBorderless(false)

	return true
}
