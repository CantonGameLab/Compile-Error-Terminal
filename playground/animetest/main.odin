// 光标闪烁回归(DECSCUSR 硬相位 + 输入窗口常亮):纯函数,免 GL。
package main

import rnd "../../src/render"
import "core:fmt"
import "core:math"

check :: proc(name : string, got, want : $T) {
	if got == want {
		fmt.printf("  ok  %s\n", name)
	} else {
		fmt.printf("FAIL  %s got=%v want=%v\n", name, got, want)
	}
}

checkNear :: proc(name : string, got, want : f32) {
	if math.abs(got - want) < 1e-3 {
		fmt.printf("  ok  %s (%.4f)\n", name, got)
	} else {
		fmt.printf("FAIL  %s got=%.4f want=%.4f\n", name, got, want)
	}
}

main :: proc() {
	no_act := u64(0)

	// ---- 硬相位闪烁(DECSCUSR 语义:0/1/3/5 闪烁,固定 500ms 亮/500ms 灭;2/4/6 常亮) ----
	checkNear("blink style0 on", rnd.BlinkAlpha(0, 0, no_act), 1.0)
	checkNear("blink style0 near edge", rnd.BlinkAlpha(0, 499, no_act), 1.0)
	checkNear("blink style0 off", rnd.BlinkAlpha(0, 500, no_act), 0.0)
	checkNear("blink style0 off-mid", rnd.BlinkAlpha(0, 750, no_act), 0.0)
	checkNear("blink style1 on", rnd.BlinkAlpha(1, 250, no_act), 1.0)
	checkNear("blink style5 on", rnd.BlinkAlpha(5, 0, no_act), 1.0)
	checkNear("blink style5 off", rnd.BlinkAlpha(5, 600, no_act), 0.0)
	check("steady style2", rnd.BlinkAlpha(2, 0, no_act), 1.0) // 常亮类恒常亮
	check("steady style4", rnd.BlinkAlpha(4, 500, no_act), 1.0)

	// ---- 输入活动窗口:距上次活动 < 500ms → 常亮(即使绝对相位在灭段) ----
	act := u64(1500) // 上次活动时刻 = 相位 500ms(灭段起点)
	checkNear("activity window on", rnd.BlinkAlpha(0, 1900, act), 1.0) // 差 400ms,相位 900(灭段)仍常亮
	checkNear("activity window edge", rnd.BlinkAlpha(0, 1999, act), 1.0) // 差 499ms
	checkNear("activity window out off", rnd.BlinkAlpha(0, 2500, act), 0.0) // 差 1000ms → 相位 500 = 灭
	checkNear("activity window out on", rnd.BlinkAlpha(0, 2100, act), 1.0) // 差 600ms → 相位 100 = 亮
	checkNear("activity style1 on", rnd.BlinkAlpha(1, 1600, act), 1.0) // 差 100ms 窗口内
	checkNear("activity style1 out", rnd.BlinkAlpha(1, 2600, act), 0.0) // 差 1100ms → 相位 600 = 灭
	check("activity steady style2", rnd.BlinkAlpha(2, 2500, act), 1.0) // 常亮类不受影响
	checkNear("activity zero-last", rnd.BlinkAlpha(0, 1099, u64(0)), 1.0) // last=0 视为从未输入:相位 99 = 亮
	checkNear("activity zero-last off", rnd.BlinkAlpha(0, 1500, u64(0)), 0.0) // 相位 500 = 灭

	// ---- 颜色编码 ----
	check("color alpha .5", rnd.CursorColor(0x00FFFFFF, 0.5), u32(0x80FFFFFF))
	check("color opaque", rnd.CursorColor(0x00FFFFFF, 1.0), u32(0xFFFFFFFF))
	check("color zero", rnd.CursorColor(0x123456, 0.0), u32(0x00123456))

	fmt.println("animetest done")
}
