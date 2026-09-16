// SDL 事件层(源模块,DAG 起点):事件泵 → 分发到各模块。
//   窗口尺寸 → canvas(树根几何);键/鼠/文本 → input 设备通道。
// 与 render 互不依赖;main 每帧按序调用 Update。
package event

import s3 "vendor:sdl3"
import cv "../canvas"
import inp "../input"

quit_requested : bool

// 派发**单个**事件(阻塞式主循环用:WaitEventTimeout 拿到的首个事件交给这里)。
// Update 与主循环共用本函数 —— 事件类型的判定只此一处,不重复。
Dispatch :: proc(e : ^s3.Event) {
	#partial switch e.type {
	case .QUIT, .WINDOW_CLOSE_REQUESTED:
		quit_requested = true
	case .WINDOW_PIXEL_SIZE_CHANGED: // 物理像素尺寸(渲染/布局用);WINDOW_RESIZED 是逻辑点尺寸
		cv.WindowTreeSetRootSize(u32(e.window.data1), u32(e.window.data2))
	case .KEY_DOWN, .KEY_UP, .TEXT_INPUT:
		inp.Handle(e)
	case .MOUSE_MOTION, .MOUSE_BUTTON_DOWN, .MOUSE_BUTTON_UP, .MOUSE_WHEEL:
		inp.Handle(e) // 鼠标原始状态进 input 通道,绑定/编码由 canvas 层决策
	}
}

// 每帧唯一入口:poll 剩余 SDL 事件并分发;退出请求经 QuitRequested 暴露。
// 注:首个事件通常已由主循环的 WaitEventTimeout 取走并 Dispatch 过,这里负责排空剩余。
Update :: proc() {
	for e : s3.Event; s3.PollEvent(&e); {
		Dispatch(&e)
	}
}

// 轮询并应用全部事件;返回 true = 请求退出(兼容旧名)
Poll :: proc() -> (quit : bool) {
	Update()
	return quit_requested
}

// 退出请求(窗口关闭/QUIT)
QuitRequested :: proc() -> bool {
	return quit_requested
}

// ---------------------------------------------------------------------------
// 待处理检查(阻塞式主循环的判据②)
// ---------------------------------------------------------------------------
// 只读,不消耗。**必须按类型过滤**:SDL 会自发产生设备通知
// (KEYBOARD_ADDED 0x305 / MOUSE_ADDED 0x404 等),我们并不处理它们,
// 但它们会让 HasEvents(ALL) 为真 —— 拿全量当判据会让主循环空转
// (实测:建窗口后 ~100ms 内会爆发若干个;键鼠热插拔时也会冒)。
// 判据 = Update 的 #partial switch 里真正会派发的那几类。
RelevantEventsPending :: proc() -> bool {
	return s3.HasEvents(.QUIT, .WINDOW_CLOSE_REQUESTED) ||
	       s3.HasEvents(.WINDOW_PIXEL_SIZE_CHANGED, .WINDOW_PIXEL_SIZE_CHANGED) ||
	       s3.HasEvents(.KEY_DOWN, .KEY_UP) ||
	       s3.HasEvents(.TEXT_INPUT, .TEXT_INPUT) ||
	       s3.HasEvents(.MOUSE_MOTION, .MOUSE_WHEEL)
}
