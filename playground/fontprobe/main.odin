// 字体名解析探针:轻量 name 表读取(family 名)+ LoadFont 名称解析。
package main

import fn "../../src/font"
import "core:fmt"

main :: proc() {
	// 1) 轻量 family 读取(项目资源文件;验证 nameTableFamily 解析正确性)
	paths := []string{
		"C:\\Users\\GroupTheory\\Source\\dterm\\resource\\font\\CascadiaCode\\CaskaydiaCoveNerdFont-Regular.ttf",
		"C:\\Users\\GroupTheory\\Source\\dterm\\resource\\font\\CascadiaCode\\CaskaydiaCoveNerdFontMono-Regular.ttf",
		"C:\\Users\\GroupTheory\\Source\\dterm\\resource\\font\\CascadiaCode\\CaskaydiaCoveNerdFont-Bold.ttf",
		"C:\\Users\\GroupTheory\\Source\\dterm\\resource\\font\\Go-Mono\\GoMonoNerdFontMono-Regular.ttf",
	}
	for path in paths {
		fmt.printf("A %s\n", path)
		fam := fn.FontFamilyFromFile(path)
		fmt.printf("B family(%s) = %q\n", path, fam)
		delete(fam)
	}

	// 2) LoadFont 名称解析(本机系统有 Cascadia Code;使用注册表/索引路径)
	fh, ok := fn.LoadFont("Cascadia Code", 26)
	if ok {
		defer fn.ReleaseFont(fh)
		fmt.println("LoadFont('Cascadia Code', 26) OK -> font", fh.id)
	} else {
		fmt.println("LoadFont('Cascadia Code', 26) FAILED")
	}

	// 3) 变体(粗体,同名解析 → 同目录 -Bold.ttf)
	fb := fn.LoadFontVariant("Cascadia Code", 26, "Bold", "Bold")
	if fb.id != 0 {
		defer fn.ReleaseFont(fb)
		fmt.println("LoadFontVariant('Cascadia Code', bold) OK -> font", fb.id)
	} else {
		fmt.println("LoadFontVariant('Cascadia Code', bold) FAILED")
	}
}
