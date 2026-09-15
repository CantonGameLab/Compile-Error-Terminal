// 命令信道消费(帧内路由,非 userapi):遍历 canvas 的 poll 池,每个 poll 取空为止地
// PopCommand,产出 ret_status + ret 写回事件槽;生产者帧尾自行回读
// (命令栏 = canvas.CommandBarReap;OSC 信道 = canvas 侧的回写)。
//
// 命令串前缀标记(通用,不分来源):缺省 = on-ret(产出 ret);
// NO_RET_MARK 前缀 = no-ret(ret_status = None,不产出任何输出)。
package command

import cv "../canvas"
import mem "../memory"

// out 回调的目标事件(ExecuteCommand 的 out 签名无 userdata,显式模块级传递)
current_event : ^cv.CommandEvent

// 查询输出追加到事件槽(多行自然文本;槽满丢弃后续)
outWrite :: proc(msg : string) {
	ev := current_event
	if ev == nil {
		return
	}
	space := len(ev.ret) - int(ev.ret_len)
	if space <= 0 {
		return
	}
	n := min(len(msg), space)
	copy(ev.ret[ev.ret_len:], msg[:n])
	ev.ret_len += u16(n)
	if int(ev.ret_len) < len(ev.ret) {
		ev.ret[ev.ret_len] = '\n'
		ev.ret_len += 1
	}
}

// Update 内调用(见 command.Update):遍历 poll 池,每个取空为止。
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
			// 剥 no-ret 前缀标记(标记属于命令串语法,只有本层认识它)
			s := string(ev.text[:ev.len])
			no_ret := len(s) > 0 && s[0] == NO_RET_MARK
			if no_ret {
				s = s[1:]
			}
			errbuf : [256]u8
			current_event = ev
			_, ok := executeString(s, errbuf[:], outWrite)
			if !ok && ev.ret_len == 0 {
				outWrite("执行失败") // 保证 Err 必有原因(ret 非空)
			}
			current_event = nil
			switch {
			case no_ret:
				// 不产出 ret:连已经写进去的输出一起丢弃 ——
				// 维持不变式 None ⟹ ret_len == 0(消费者据此只看状态就够)
				ev.ret_status = .None
				ev.ret_len = 0
			case ok:
				ev.ret_status = .Ok
			case:
				ev.ret_status = .Err
			}
		}
	}
}
