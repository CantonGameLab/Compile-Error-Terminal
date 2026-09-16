// 编制期可消除的分趟计时(默认关闭:PROFILE = false 时所有 ben/end 都是空过程,
// 编译器把它们连同 time 读数一起消掉,发布构建零开销、零代码)。
//
// 用法(在探针里驱动真实引擎):
//   profile.Reset()                  // 每帧开头,或整轮开头
//   ... 跑帧 ...
//   stats := profile.Stats(buf)      // 取出本轮到现在的聚合
//
// 打开方式:odin run playground/<probe>/ -define:profile=true
//
// 数据布局:名字与耗时**分成两列**(名字列只在新标记时写一次,统计趟只碰耗时列)。
// 标记按帧内发生顺序追加,不做排序、不做哈希 —— 探针自己按名字聚合。
package profile

import "core:fmt"
import s3 "vendor:sdl3"

PROFILE :: #config(profile, false)

// 单次采集上限(整轮所有帧累计)。
// 一帧约 22 个标记 ⇒ 500 帧 ≈ 11000;给到 64K 是为了留足余量(2MB 静态,不值得省)。
// 满了就丢弃并计数 —— 探针必须检查 StatsDroppedForDebug,否则"每帧"口径会静默偏小。
MAX_MARKS :: 65536

// 计时器:SDL 高精度计数器(纳秒量级;频率由 GetPerformanceFrequency 给)
freq : u64 = 0

names : [MAX_MARKS]string // 名字列(mark 下标 → 名字)
ticks : [MAX_MARKS]u64    // 耗时列(mark 下标 → 本次耗时 tick)
frames : [MAX_MARKS]u32   // 帧号列(同一下标的耗时属于第几帧;SetFrame 设定)
count : int               // 本轮的标记数
dropped : int             // 超上限被丢弃的标记数
cur_frame : u32           // 当前帧号

// 设当前帧号(探针每帧调一次)。用来区分"每帧恒定开销"与"偶发尖峰":
// 只有帧号才能把同一阶段的耗时按帧分组算 min/max。
SetFrame :: proc(f : u32) {
	when PROFILE {
		cur_frame = f
	}
}

// 作用域栈(嵌套 begin/end 用;扁平标记不需要它)
STACK_MAX :: 512
stack_ticks : [STACK_MAX]u64
stack_names : [STACK_MAX]string
stack_top : int

@(private = "file")
now :: proc() -> u64 {
	when PROFILE {
		return s3.GetPerformanceCounter()
	}
	return 0
}

@(private = "file")
elapsed_ns :: proc(t : u64) -> u64 {
	when PROFILE {
		if freq == 0 {
			freq = s3.GetPerformanceFrequency()
			if freq == 0 {
				freq = 1
			}
		}
		return (t * 1_000_000_000) / freq
	}
	return 0
}

// 一轮开始:清空。每帧或整轮开头调。
Reset :: proc() {
	when PROFILE {
		count = 0
		dropped = 0
		stack_top = 0
	}
}

// 扁平标记:一次调用记一个耗时(最常用 —— 标记之间不嵌套时用它)
Mark :: proc(name : string, t0, t1 : u64) {
	when PROFILE {
		if count >= MAX_MARKS {
			dropped += 1
			return
		}
		names[count] = name
		ticks[count] = elapsed_ns(t1 - t0)
		frames[count] = cur_frame
		count += 1
	}
}

// 嵌套作用域:begin/end 配对(递归函数、有多个 return 的段落用它)。
// 必须在同一函数内配对;跨函数不保证(那是 Mark 的活)。
Begin :: proc(name : string) {
	when PROFILE {
		if stack_top >= STACK_MAX {
			return
		}
		stack_names[stack_top] = name
		stack_ticks[stack_top] = now()
		stack_top += 1
	}
}

End :: proc() {
	when PROFILE {
		if stack_top <= 0 {
			return
		}
		stack_top -= 1
		Mark(stack_names[stack_top], stack_ticks[stack_top], now())
	}
}

Now :: proc() -> u64 {
	when PROFILE {
		return now()
	}
	return 0
}

// 本轮已记录的标记数(探针自检用:关闭时应恒为 0)
StatsCountForDebug :: proc() -> int {
	when PROFILE {
		return count
	}
	return 0
}

// 本轮被丢弃的标记数(超 MAX_MARKS)
StatsDroppedForDebug :: proc() -> int {
	when PROFILE {
		return dropped
	}
	return 0
}

// 单条标记的原始读数(探针做账目核对用;越界返回 0)
MarkAt :: proc(i : int) -> (name : string, ns : u64) {
	when PROFILE {
		if i < 0 || i >= count {
			return "", 0
		}
		return names[i], ticks[i]
	}
	return "", 0
}

// 计时器频率(tick/秒;探针把裸 tick 差换算成墙钟时间用)
Frequency :: proc() -> u64 {
	when PROFILE {
		if freq == 0 {
			freq = s3.GetPerformanceFrequency()
			if freq == 0 {
				freq = 1
			}
		}
		return freq
	}
	return 1
}

// ---------------------------------------------------------------------------
// 聚合(探针每轮调一次)
// ---------------------------------------------------------------------------
Stat :: struct {
	name : string,
	total_ns : u64,
	count : u64,
	min_ns : u64,
	max_ns : u64,
	// 按帧分组的**每帧合计**最小值。与 min_ns 的区别:min_ns 是"单次调用最小值"
	// (一帧内调多次时会很小);frame_min_ns 是"某一帧里该阶段合计的最小值" ——
	// 判断"这笔开销是每帧都有,还是只在尖峰帧出现"用它。
	frame_min_ns : u64,
	has_frame_min : bool,
}

// 按名字聚合到一个调用方给的缓冲(返回实际写入条数;超出容量只统计不新增)。
// 朴素 O(n×m) 匹配:标记数在千级、种类在百级,够用且无分配。
Aggregate :: proc(out : []Stat) -> (used : int, dropped : int) {
	when PROFILE {
		for i in 0 ..< count {
			name := names[i]
			t := ticks[i]
			found := false
			for j in 0 ..< used {
				if out[j].name == name {
					out[j].total_ns += t
					out[j].count += 1
					if t < out[j].min_ns { out[j].min_ns = t }
					if t > out[j].max_ns { out[j].max_ns = t }
					found = true
					break
				}
			}
			if found {
				continue
			}
			if used >= len(out) {
				continue
			}
			out[used] = Stat { name = name, total_ns = t, count = 1, min_ns = t, max_ns = t }
			used += 1
		}

		// 第二趟:按 (名字, 帧号) 分组求每帧合计的最小值(标记按帧序追加,同帧连续)
		for j in 0 ..< used {
			nm := out[j].name
			frame_sum : u64
			frame_id : u32
			have := false
			for i in 0 ..< count {
				if names[i] != nm {
					continue
				}
				if !have || frames[i] != frame_id {
					if have && (!out[j].has_frame_min || frame_sum < out[j].frame_min_ns) {
						out[j].frame_min_ns = frame_sum
						out[j].has_frame_min = true
					}
					frame_id = frames[i]
					frame_sum = 0
					have = true
				}
				frame_sum += ticks[i]
			}
			if have && (!out[j].has_frame_min || frame_sum < out[j].frame_min_ns) {
				out[j].frame_min_ns = frame_sum
				out[j].has_frame_min = true
			}
		}
		return used, dropped
	}
	return 0, 0
}

// 打印一张按总耗时降序的表(探针用;frame_count 用于算每帧均值)
PRINT_MAX :: 256

Print :: proc(stats : []Stat, frames : int) {
	when PROFILE {
		frame_count := frames
		if frame_count <= 0 {
			frame_count = 1
		}
		// 选择排序(表小,免分配);按 total_ns 降序
		order : [PRINT_MAX]int
		n := min(len(stats), PRINT_MAX)
		for i in 0 ..< n {
			order[i] = i
		}
		for i in 0 ..< n {
			best := i
			for j in i + 1 ..< n {
				if stats[order[j]].total_ns > stats[order[best]].total_ns {
					best = j
				}
			}
			order[i], order[best] = order[best], order[i]
		}

		grand : u64
		for i in 0 ..< n {
			grand += stats[i].total_ns
		}

		fmt.printf("%-30s %11s %9s %7s %9s %9s %8s\n",
			"阶段", "每帧(µs)", "总计(ms)", "次数/帧", "单次均(ns)", "帧最小(µs)", "占比")
		fmt.println("--------------------------------------------------------------------------------")
		for i in 0 ..< n {
			s := stats[order[i]]
			if s.count == 0 {
				continue
			}
			per_frame_us := f64(s.total_ns) / f64(frame_count) / 1000.0
			per_call_ns := f64(s.total_ns) / f64(s.count)
			pct := grand > 0 ? f64(s.total_ns) / f64(grand) * 100.0 : 0
			fmin := s.has_frame_min ? f64(s.frame_min_ns) / 1000.0 : 0
			fmt.printf("%-30s %11.2f %9.3f %7.2f %9.0f %9.2f %7.2f%%\n",
				s.name,
				per_frame_us,
				f64(s.total_ns) / 1e6,
				f64(s.count) / f64(frame_count),
				per_call_ns,
				fmin,
				pct)
		}
		fmt.println("--------------------------------------------------------------------------------")
		fmt.printf("%-30s %11.2f %9.3f   (含嵌套重叠,非墙钟;不要相加)\n", "合计", f64(grand) / f64(frame_count) / 1000.0, f64(grand) / 1e6)
	}
}
