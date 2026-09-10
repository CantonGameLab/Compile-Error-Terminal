// canvas 模块:每帧主入口(DAG 中位于 input/event 之后、render 之前)。
// 自身数据(窗口树/Buffer/Console/VT/工具条)+ 固定有序子步骤:
//   1. 树遍历:布局 + 消费各会话输出(vtparse → 状态),Resize 联动 ConPTY
//   2. 会话轮询:auto_close 销毁;全部窗口关闭返回 false
//   3. 键命令已由 command 模块消费(main 帧序:command.ProcessKeys 先于本入口);
//      本模块 = 鼠标路由 + 未消费文本路由(bar 可见 → CommandBar;否则 → FeedConsole)
//   4. 命令事件读回(队列 Result 槽;失败回显)
package canvas

import mem "../memory"
import inp "../input"
import "core:fmt"

Update :: proc() -> bool {
	ConsoleUpdateTree(WindowTreeRoot()) // 更新 WindowTree 的 layout + 消费输出
	if !PollSessions() {
		fmt.println("all sessions ended. Nothing left to draw. A garbage collector would have stop-the-world'd for 200ms and then collected the wrong session anyway. Post-nut clarity, terminal edition — I'll show myself out.")
		return false
	}

	SelectionValidate() // 选区自愈(buffer 数据链验证;失效即清,渲染前定稿)

	ProcessMouse()

	if CommandBarVisible() {
		if buf := inp.TakeAppInput(); len(buf) > 0 {
			commandBarFeed(buf)
		}
	} else {
		if buf := inp.TakeAppInput(); len(buf) > 0 {
			FeedConsole(buf)
		}
	}

	CommandEventsReap() // 命令事件读回(已执行;失败回显日志)

	return true
}
