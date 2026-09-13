// cwd 命令探针:验证配置 / 命令栏路径 —— `cwd "<path>"` 写全局会话目录并经形态归一,
// 无参数时走查询(输出回调)。
// 用法:odin run playground/cwdcmd/
package main

import cmd "../../src/command"
import cv "../../src/canvas"
import "core:fmt"

main :: proc() {
	fmt.println("-- 设置 --")
	fmt.printf("cwd \"C:/Windows/System32\" -> ok=%v  ->  %s\n",
		cmd.ExecuteCommandString(`cwd "C:/Windows/System32"`), cv.GetSessionCwd())
	fmt.printf("cwd \"/c/Users\"            -> ok=%v  ->  %s\n",
		cmd.ExecuteCommandString(`cwd "/c/Users"`), cv.GetSessionCwd())
	fmt.printf("cwd \"\\\\\\\\server\\\\share\"    -> ok=%v  ->  %s\n",
		cmd.ExecuteCommandString(`cwd "\\server\share"`), cv.GetSessionCwd())

	fmt.println("-- 查询(无参数)--")
	_ = cmd.ExecuteCommandString("cwd", proc(msg : string) { fmt.printf("   %s\n", msg) })

	fmt.println("-- 语法错误 --")
	fmt.printf("cwd 两个参数               -> ok=%v\n",
		cmd.ExecuteCommandString(`cwd "a" "b"`))
}
