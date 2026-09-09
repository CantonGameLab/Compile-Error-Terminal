// ParseCommandString 隔离测试:CommandBar 输入路径的解析验证。
package main

import cv "../../src/canvas"
import cmd "../../src/command"
import "core:fmt"

main :: proc() {
	tests := []string{
		`launch "bash.exe"`,
		`launch "cmd.exe"`,
		`launch bash.exe`,
		`launch "cmd.exe" @3`,
		`font "FiraCode Nerd Font Mono" 22`,
		`split right 0.5`,
		`focus left`,
		`feed "dir /b"`,
		`theme monokai`,
		`count`,
	}
	for t in tests {
		pc, ok := cmd.ParseCommandString(t)
		fmt.printf("%-40q ok=%v kind=%v target=%d sval=%q fval=%v\n", t, ok, pc.kind, pc.target.id, pc.sval, pc.fval)
	}
}
