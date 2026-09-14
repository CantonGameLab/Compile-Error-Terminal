// 命令信道消费(帧内路由,非 userapi):遍历 canvas 的 poll 池,每个 poll 取空为止地
// PopCommand,结果(成功标志 + 查询回显/失败原因,多行追加)写回事件槽;
// 生产者帧尾自行回读(命令栏 = canvas.CommandBarReap)。
package command

import cv "../canvas"
import mem "../memory"

// out 回调的目标事件(ExecuteCommand 的 out 签名无 userdata,显式模块级传递)
current_event : ^cv.CommandEvent

// 查询输出追加到事件槽(多行;槽满丢弃后续)
outWrite :: proc(msg : string) {
	ev := current_event
	if ev == nil {
		return
	}
	space := len(ev.result) - int(ev.result_len)
	if space <= 0 {
		return
	}
	n := min(len(msg), space)
	copy(ev.result[ev.result_len:], msg[:n])
	ev.result_len += u16(n)
	if int(ev.result_len) < len(ev.result) {
		ev.result[ev.result_len] = '\n'
		ev.result_len += 1
	}
}

// Update 内调用(见 command.Update):遍历 poll 池,每个取空为止;结果写入 result 槽。
// 完成标志不落字段:PopCommand 推进 head 本身就是"这条已被消费"。
// 跨生产者顺序 = 槽位序(与创建顺序无关),不可依赖。
processCommandEvents :: proc() {
	it : mem.Iter(cv.MAX_COMMAND_POLLS, cv.CommandPoll) = mem.All(cv.GetCommandPolls())
	for poll_h in mem.next(&it) {
		for {
			ev := cv.PopCommand(poll_h)
			if ev == nil {
				break
			}
			errbuf : [256]u8
			current_event = ev
			_, ok := executeString(string(ev.text[:ev.len]), errbuf[:], outWrite)
			current_event = nil
			ev.ok = ok
		}
	}
}
