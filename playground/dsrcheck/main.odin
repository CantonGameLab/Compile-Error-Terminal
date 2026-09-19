// DSR/CPR 回路测试:**我们写进 ConPTY 输入的应答,子进程到底收不收得到?**
//
// 为什么关键:vim/nvim 靠 `ESC[6n`(CPR)跟踪真实光标位置,再据此**跳过**不必要的定位;
// 应答不到或内容不对,它认为的光标位置就与我们不一致 —— 下一次写入会落错一格,下次重绘
// 又"回正"。这条症状与"换 conpty 实现/换 vim 版本都不变""动光标才出现"完全吻合。
//
// 子进程 = powershell:先往 stdout 发 `ESC[6n`,再轮询控制台按键 1.5 秒,把收到的字符打印出来。
// 探针 = 在输出里看到 `ESC[6n` 就写一条 `ESC[1;1R` 进输入管道(与 CETerm 的做法一致)。
//
// 判据:
//   子进程打印 GOT:[\e[1;1R]  → 回路通(应答能到子进程),问题在应答内容/时机
//   子进程打印 GOT:[]          → **回路断**(宿主把应答吞了):应用永远拿不到光标位置
//
// 用法:odin run playground/dsrcheck/
package main

import ct "../../src/conpty"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

CHILD :: `powershell.exe -NoProfile -Command "$o=[Console]::Out; $o.Write([char]27+'[6n'); $o.Flush(); Start-Sleep -Milliseconds 250; $s=''; $d=(Get-Date).AddMilliseconds(1200); while((Get-Date) -lt $d){ if([Console]::KeyAvailable){ $k=[Console]::ReadKey($true); $s+=('{0:X2}' -f [int]$k.KeyChar)+' ' }; Start-Sleep -Milliseconds 20 }; $o.Write('HEX1:['+$s+']'+[char]13+[char]10); $o.Flush(); Start-Sleep -Milliseconds 100; $s2=''; $d=(Get-Date).AddMilliseconds(1200); while((Get-Date) -lt $d){ if([Console]::KeyAvailable){ $k=[Console]::ReadKey($true); $s2+=('{0:X2}' -f [int]$k.KeyChar)+' ' }; Start-Sleep -Milliseconds 20 }; $o.Write('HEX2:['+$s2+']'+[char]13+[char]10); $o.Flush(); Start-Sleep -Milliseconds 150"`

main :: proc() {
	ct.SetConptyPreferExternal(true)
	fmt.println("启动子进程:", CHILD)
	h, ok := ct.CreateConptyContext({80, 24}, CHILD)
	if !ok {
		fmt.eprintln("CreateConptyContext failed")
		return
	}
	defer ct.DestroyConpty(h)
	if !ct.StartReadThread(h) {
		fmt.eprintln("StartReadThread failed")
		return
	}
	defer ct.StopReadThread(h)

	out := make([dynamic]u8, 0, 1 << 16)
	defer delete(out)
	buf := make([]u8, 4096)
	defer delete(buf)
	replied := false
	for i in 0 ..< 200 { // 最多 ~6 秒
		data := ct.GetReadWriteData(h)
		if data != nil {
			for {
				n := ct.RingPop(data, buf)
				if n == 0 {
					break
				}
				append(&out, ..buf[:n])
			}
		}
		if !replied && strings.contains(string(out[:]), "\x1b[6n") {
			time.sleep(500 * time.Millisecond)
			fmt.println("→ 第 1 段:写普通文本 \"ABC\"(对照)")
			m1 := "ABC"
			ct.WriteConptyInput(h, transmute([]u8)m1)
			time.sleep(1500 * time.Millisecond)
			fmt.println("→ 第 2 段:写 CSI 应答 \"ESC[1;1R\"")
			m2 := "\x1b[1;1R"
			ct.WriteConptyInput(h, transmute([]u8)m2)
			replied = true
		}
		if strings.contains(string(out[:]), "HEX2:") && len(out) > 0 {
			time.sleep(300 * time.Millisecond)
			break
		}
		time.sleep(30 * time.Millisecond)
	}

	esc := '[' + 0
	_ = esc
	txt := string(out[:])
	fmt.printf("\n子进程输出 %d 字节(可读化):\n%s\n", len(out),
		strings.replace_all(txt, "\x1b", "\\e", context.temp_allocator))
	switch {
	case strings.contains(txt, "GOT:[\x1b[1;1R]"):
		fmt.println("\n⇒ 回路**通**:应答原样到达子进程 ✓")
	case strings.contains(txt, "GOT:[]"):
		fmt.println("\n⇒ 回路**断**:宿主把应答吞了,应用永远拿不到光标位置 ✗✗")
	case strings.contains(txt, "GOT:["):
		fmt.println("\n⇒ 收到了东西但内容不同(见上面的 GOT: [...] 原文)")
	case:
		fmt.println("\n⇒ 子进程没打印 GOT(可能没起来/超时)")
	}
	_ = os.args
}
