// 动画引擎(render 域帧间状态):光标闪烁(硬相位 + 输入窗口常亮)。
// 真源不动(canvas 零改动);显式时间输入(now)便于测试。无位置动画。
package render

import s3 "vendor:sdl3"
import "core:math"

now_ms :: proc() -> f64 {
	return f64(s3.GetTicks())
}

// 闪烁相位(DECSCUSR 语义,固定 500ms 亮 / 500ms 灭):闪烁样式 0/1/3/5 按相位
// 亮灭(硬切);常亮样式 2/4/6 恒亮。相位用绝对时间戳(零状态)。
// 输入活动窗口(距 last_activity_ms < INPUT_ACTIVE_MS)= 常亮(WT 行为:用户
// 输入期间光标不闪烁;活动时刻 = console.input_activity_ms,显式注入)。
INPUT_ACTIVE_MS :: 500

BlinkAlpha :: proc(style : u8, now : f64, last_activity_ms : u64) -> f32 {
	switch style {
	case 0, 1, 3, 5:
		if last_activity_ms != 0 && now - f64(last_activity_ms) < INPUT_ACTIVE_MS {
			return 1.0 // 输入窗口:常亮
		}
		if math.mod(now, 1000.0) < 500.0 {
			return 1.0
		}
		return 0.0
	}
	return 1.0
}

// 光标颜色:主题色 + alpha(0xAARRGGBB;0xRRGGBB 高字节 0 = 不透明)
CursorColor :: proc(base : u32, alpha : f32) -> u32 {
	a := u32(clamp(alpha, 0, 1) * 255 + 0.5)
	return (a << 24) | (base & 0x00FFFFFF)
}
