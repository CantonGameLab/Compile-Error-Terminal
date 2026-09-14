// 命令信道(CommandPipe):canvas 各组件 → command 模块的唯一通路。
// 存储 = 全局 poll 池(command_polls);持有者只拿一个 mem.Handle(poll_h),
// 不嵌 poll、不持有跨层指针 —— command 遍历池即可服务所有生产者。
//
// 每个 CommandPoll 两索引 + 数组长度,共三个位置:
//   read_head ──► head ──► len(command_events)
//   [read_head, head) : command 已执行完、等本组件回读结果(result/ok 有效)
//   [head, len)       : 已提交、等 command 消费(未执行)
//   read_head == head == len = 空 → 下次 Push 时清零复用(唯一的内存回收点:
//   数组只从尾 append,不做 front-pop,不回收就会无限长)
//
// 状态在索引里,不在数据里:事件没有 done 字段 —— "执行完没有"由 head 的位置回答。
// 纪律:command 执行期间不得 Push(会写进正在被消费的窗口)。
package canvas

import mem "../memory"

MAX_POLL_TEXT :: 512 // 单条命令字符串上限(与命令栏输入缓冲同宽)
MAX_COMMAND_POLLS :: 32 // poll 池容量(槽 0 保留,有效 MAX_COMMAND_POLLS-1)

CommandEvent :: struct {
	text : [MAX_POLL_TEXT]u8, // 待执行命令字符串
	len : u16,
	result : [4096]u8, // 执行结果槽(查询回显多行 / 失败原因;command 写入)
	result_len : u16,
	ok : bool, // 执行成功(command 写)
}

CommandPoll :: struct {
	command_events : [dynamic]CommandEvent,
	read_head : int, // 本组件已回读到这
	head : int, // command 已消费到这
}

command_polls : mem.GenArray(MAX_COMMAND_POLLS, CommandPoll)

// 池本体(command 侧遍历用;持有者不碰,只拿句柄)
GetCommandPolls :: proc() -> ^mem.GenArray(MAX_COMMAND_POLLS, CommandPoll) {
	return &command_polls
}

// 建一个 poll(持有者在自己的创建点调用;池满 = 空句柄)
CreateCommandPoll :: proc() -> mem.Handle {
	return mem.Alloc(&command_polls, CommandPoll {})
}

// 销一个 poll(持有者在自己的销毁点调用)。
// 深析构:command_events 是自有堆资源,mem.Free 只复位槽值不释放它
// (见 generational.odin 顶部:"T 须为值语义")。
ReleaseCommandPoll :: proc(poll_h : mem.Handle) {
	poll := mem.Get(&command_polls, poll_h)
	if poll == nil {
		return
	}
	delete(poll.command_events)
	mem.Free(&command_polls, poll_h)
}

// 提交(生产侧)。false = 拒收(句柄空/过期、超长)。
// 不截断:截断 = 执行另一条命令,宁可拒收。
PushCommand :: proc(poll_h : mem.Handle, s : string) -> bool {
	poll := mem.Get(&command_polls, poll_h)
	if poll == nil || len(s) > MAX_POLL_TEXT {
		return false
	}
	// 窗口已全回读 → 从 0 重用(dynamic 容量保留,首帧后不再分配)
	if poll.read_head == len(poll.command_events) {
		clear(&poll.command_events)
		poll.read_head = 0
		poll.head = 0
	}
	// append 零值 = 顺带清 result_len/ok(槽可能是复用来的)
	append(&poll.command_events, CommandEvent {})
	ev := &poll.command_events[len(poll.command_events) - 1]
	copy(ev.text[:], s)
	ev.len = u16(len(s))
	return true
}

// 取一条待处理事件(command 侧);推进 head。nil = 本 poll 已取空(或句柄失效)。
// 返回槽指针:调用方执行完直接写 result/ok(单写者 = command)。
PopCommand :: proc(poll_h : mem.Handle) -> ^CommandEvent {
	poll := mem.Get(&command_polls, poll_h)
	if poll == nil || poll.head >= len(poll.command_events) {
		return nil
	}
	ev := &poll.command_events[poll.head]
	poll.head += 1
	return ev
}

// 回读一条已执行结果(生产侧帧尾);推进 read_head。ok = false = 本帧无结果。
// 槽地址来自池(稳定),但事件数组会被下一次 Push / Release 改写 —— 即时读用,不留存。
ReapCommand :: proc(poll_h : mem.Handle) -> (ev : ^CommandEvent, ok : bool) {
	poll := mem.Get(&command_polls, poll_h)
	if poll == nil || poll.read_head >= poll.head {
		return nil, false
	}
	e := &poll.command_events[poll.read_head]
	poll.read_head += 1
	return e, true
}
