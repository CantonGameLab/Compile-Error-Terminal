# conpty(x64)—— 新版 ConPTY 实现(第三方二进制)

这两个文件是 **Microsoft 官方发布的新版 ConPTY**,由 CETerm 在运行时注入,用来顶替
Windows 装箱的 `conhost.exe` 实现。

## 为什么需要它

装箱的 ConPTY 实现在 `conhost.exe` 里,而新版实现(Windows Terminal 项目的
OpenConsole)**任何 Windows 版本都不随系统发布**
([microsoft/terminal#17452](https://github.com/microsoft/terminal/issues/17452))。
装箱 conhost 的 VtEngine(把屏幕序列化成 VT 发给终端的那一层)正是
"resize 时整屏重排重发""宽字对只发一半"这类问题的所在地;新版把这一层整个换掉了
([microsoft/terminal#17510](https://github.com/microsoft/terminal/pull/17510)
"A minor ConPTY refactoring: Goodbye VtEngine Edition")。

同样做法的先例:[Alacritty](https://github.com/alacritty/alacritty/blob/f99dc717/alacritty_terminal/src/tty/windows/conpty.rs#L110-L244)、
Cygwin/mintty([邮件列表](https://sourceware.org/pipermail/cygwin/2025-September/258777.html))。

## 文件

| 文件 | 来源(包内路径) | 大小 |
|---|---|---|
| `x64/conpty.dll` | `runtimes/win-x64/native/conpty.dll` | 109,920 |
| `x64/OpenConsole.exe` | `build/native/runtimes/x64/OpenConsole.exe` | 1,066,296 |

**两个必须放在一起** —— `conpty.dll` 在**自己所在目录**找宿主 `OpenConsole.exe`(实测)。
所以它们不能拆开、不能改名。

## 来源与许可

- 包:`Microsoft.Windows.Console.ConPTY` **1.24.260710001**
  (Windows Terminal release [v1.24.11911.0](https://github.com/microsoft/terminal/releases/tag/v1.24.11911.0) 的资产)
- 仓库:<https://github.com/microsoft/terminal>
- 许可:**MIT**(nuspec `<license type="expression">MIT</license>`)
- 官方支持面:包描述原文 ——
  *"This package allows applications to host Windows Console sessions.
  It should work on all versions of Windows 10.0.17763.0 and above."*

## 加载规则(实现见 `src/conpty/api.odin`)

1. 先按**裸名** `conpty.dll` 找:`exe 同目录` → 系统目录 → 当前目录 → `PATH`;
2. 再试**资源树全路径**:`<资源根>/conpty/x64/conpty.dll`(即本目录);
3. 都没有 → 静默回退系统 `kernel32` 的 ConPTY。

导出名两套都试:`ConptyCreatePseudoConsole`(官方头文件 `inc/conpty.h` 声明的名字)
与裸名 `CreatePseudoConsole`。**只按裸名找会在官方包上静默回退**(Alacritty 就是这么写的)。

启动时会往 stderr 打一行,标明用的是哪套:

```
[conpty] 新会话使用外部 conpty.dll(宿主 OpenConsole.exe 已就位,导出名 = ConptyCreatePseudoConsole)
[conpty] 新会话使用系统 kernel32(装箱 conhost 实现)
```

**"dll 加载成功" ≠ "新实现生效"**(Win10 上踩过,排查方向被带偏很久):`conpty.dll` 只是壳,
真正的宿主进程是它**自己所在目录**里的 `OpenConsole.exe`;找不到就依次退回
`<同目录>/<arch>/OpenConsole.exe` → `%SystemRoot%\System32\conhost.exe`
(WT 源码 `src/winconpty/winconpty.cpp:_ConsoleHostPath`),**静默**用回装箱 conhost ——
日志写着 OpenConsole、跑的却是 conhost,于是"换了 conpty.dll 问题依旧"。
所以现在启动时**先查宿主 exe**,不在位就打印

```
[conpty] ⚠ conpty.dll 同目录缺 OpenConsole.exe(它会静默退回装箱 conhost),已改用系统实现;两个文件必须放在一起
```

并且**不再使用这份 dll**(既然它给不出新实现,就不假装在用)。分发只有一条规则:
两个文件**同目录、同名、一起走**。

命令 `conpty on|off` 可运行时切换(**只影响新会话** —— 一个 HPCON 只能由创建它的
那套实现 resize/close)。

## 怎么更新

从 Windows Terminal 的 release 资产里下 `Microsoft.Windows.Console.ConPTY.<版本>.nupkg`
(nupkg 就是 zip),取出上面表里两个路径的文件覆盖本目录即可。
`playground/conptydll/` 下有提取脚本思路与已提取的副本(playground 不入库)。
