// file.exe shim(仅 harness 沙箱用):yazi 调 `file -bL --mime-type <path>`,
// 本目录只有 png,恒回 image/png(沙箱里 msys2 的 file.exe 无法初始化)。
package main

import "core:fmt"

main :: proc() {
	fmt.println("image/png")
}
