// 命令信道消费(帧内路由,非 userapi):遍历 canvas 的 poll 池,每个 poll 取空为止地
// PopCommand,把 executeString 的返回值(ret 文本 + 成败)写回事件槽;
// 生产者帧尾自行回读(命令栏 = canvas.CommandBarReap;OSC 信道 = canvas 侧的回写)。
//
// 命令串前缀标记(通用,不分来源):缺省 = on-ret(产出 ret);
// NO_RET_MARK 前缀 = no-ret(ret_status = None,不产出任何输出)。
package command

import cv "../canvas"
import mem "../memory"

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
			ret, ok := executeString(s, errbuf[:])
			if no_ret {
				// 不产出 ret:输出一并丢弃 —— 维持不变式 None ⟹ ret_len == 0
				ev.ret_status = .None
				ev.ret_len = 0
				continue
			}
			n := min(len(ret), len(ev.ret))
			copy(ev.ret[:n], ret)
			ev.ret_len = u16(n)
			ev.ret_status = ok ? .Ok : .Err
		}
	}
}
