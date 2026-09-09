// 命令事件消费(帧内路由,非 userapi):执行 canvas 命令栏事件队列中上一帧提交的
// 未完成事件,结果(成功标志 + 查询回显/失败原因,多行追加)写回事件槽;
// canvas 帧尾 CommandEventsReap 读回(打印 stdout / 失败原因)。
package command

import cv "../canvas"

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

// Update 内调用(见 command.Update):执行所有未完成事件;结果写入 result 槽
processCommandEvents :: proc() {
	n := cv.CommandEventsCount()
	for i in 0 ..< n {
		ev := cv.CommandEventAt(i)
		if ev == nil || ev.done {
			continue
		}
		errbuf : [256]u8
		current_event = ev
		_, ok := executeString(string(ev.text[:ev.len]), errbuf[:], outWrite)
		current_event = nil
		ev.ok = ok
		ev.done = true
	}
}
