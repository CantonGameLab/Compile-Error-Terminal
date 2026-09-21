# CETerm 终端语义层调试全记录

本文档记录从 vtparse 移植集成到 vttest 验收、yazi 高亮修复的完整调试过程。
按"现象 → 根因 → 修复 → 验证"记录每个 bug,末尾固化终端语义规则与调试方法论。

## 目录

1. [调试方法论(工具链)](#1-调试方法论)
2. [Bug 清单](#2-bug-清单)
3. [架构发现:ConPTY 的 conhost 拦截](#3-架构发现conpty-的-conhost-拦截)
4. [终端语义规则(固化)](#4-终端语义规则固化)
5. [测试体系](#5-测试体系)
6. [遗留问题](#6-遗留问题)

---

## 1. 调试方法论

终端模拟器 bug 的调试核心:**拿到真实字节流,离线回放,逐格检查**。不靠肉眼猜。

### 工具链

| 工具 | 作用 |
|---|---|
| `playground/vtcapture` | 用 ConPTY 启动真实程序(nvim/yazi/vttest),抓取全部输出字节到 capture.bin |
| `playground/vtreplay` | 把字节流喂进 Console(真实解析链),dump 最终屏幕 + 样式摘要 |
| `playground/vttestreplay` | 按 "Push <RETURN>" 标记分段回放 vttest 输出,逐步 dump(含 visible_top 换算) |
| `playground/cellcheck` | 逐格打印 cell(cp/wide/reverse/fg/bg),检查数据层精确状态 |
| `playground/nvimtest` | 89 项断言:合成序列覆盖全部已知语义规则,防回归 |
| `odin build src/ -define:vt_debug=true` | 光标级追踪(每个 CUP/LF/WRITE/ECH 打印位置) |

### 工作流

1. 用户环境抓取:改 vtcapture 的 `#config` 分支 → 用户跑 `odin run playground/vtcapture/ -define:vt_capture_xxx=true`
2. 离线回放:vtreplay/vttestreplay 复现问题(数据层)
3. 定位:VT_DEBUG 追踪 / cellcheck 逐格 / 对照字节流
4. 修复 + 固化断言到 nvimtest
5. 全量回归 + 冒烟

### 关键教训

- **字符索引 ≠ 字节索引**:PowerShell/字符串分析时 UTF-8 汉字 3 字节 vs 1 字符,先确认坐标系
- **dump 必须按 visible_top 换算**:全屏滚动后内容在历史区,直接 dump lines[0..rows] 会误判"空屏"
- **样式摘要只标首个非默认格**:vtreplay 的 `[fg=...]` 标记不代表整行,读数据用 cellcheck
- **沙箱限制**:msys 程序(CreateFileMapping error 5)和部分原生程序(903 spawn 失败)在沙箱内无法运行,需用户在真实环境抓取

---

## 2. Bug 清单

### B1. vtparse 残留参数(消费端契约)

**现象**:bash/zsh/nvim 全乱。`ESC[2J` 后跟 `ESC[H`,光标跑到第 2 行;`ESC[?1049h` 后跟 `ESC[H` 光标跳到底行,整屏错位。

**根因**:vtparse 的 `Clear` 动作只重置 `num_params` **不清零参数数组**(C 库通用设计,复用缓冲区)。`vtCsiDispatch` 无条件读 `p.params[0]`,无参序列继承了上一条的残留参数。

**修复**:p0/p1 按 `num_params` 守卫读取;`vtSetMode` 同样守卫。顺带修复 `ESC[m`(无参 SGR)= `ESC[0m` 重置语义(原实现 no-op 导致颜色泄漏)。

**验证**:`playground/vtcapture` 抓真实 bash 启动(241B)回放:修复前文本从第 1 行开始,修复后从第 0 行。nvimtest 固化断言(CUP after 1049)。

### B2. wrap-pending 时机错误(两行状态栏)

**现象**:nvim 两行状态栏、`-- INSERT --` 两行、`~` 出现在第一行。

**根因**:两处错误叠加:
1. **写满最后一列立即折行**——xterm 语义是写满后停在最后列,下一字符才折行(自动换行等待)
2. **任何 CSI(含 SGR)都取消 pending**——nvim 的 eob 绘制依赖"写满 + 改色(SGR) + `~` 折行",SGR 不能取消等待

**修复**:`VtState.wrap_pending` 字段;`ConsoleWriteRune` 写满置 pending,下一字符折行(抽出 `vtWrapOnce`);光标移动类操作(CUP/CUU/CUD/CUF/CUB/CHA/VPA/HPA/VPR/HPR/DECRC/BS/TAB/CR)清 pending;SGR/模式/应答不清。
(后修正:LF/IND/RI 与 EL/ED/ECH/DCH/ICH/IL/DL 也清 pending —— xterm 源码里 index 走 `CursorDown`、RI 走 `CursorUp`,这些函数与擦除/插删类一样都调 `ResetWrap`;见 B8。)原实现"LF 不清"会让"写满末列 + LF + 写字"多下移一行、白出一空行。

**验证**:nvimtest 断言:80 空格 + SGR + `~` → `~` 在下一行行首;CR 取消 pending。

### B3. 宽字符(汉字)按单宽处理

**现象**:nvim 打开含中文的文件(如 src/main.odin)全部错位——注释行 51 列宽按 30 列算,填充空格数对不上,折行时机全错,光标位置累积漂移。

**根因**:`ConsoleWriteRune` 每个字符占 1 列。nvim 用 wcwidth 计算行宽(汉字双宽),填充空格到 80 列;我们的终端按单宽执行,行宽差 20+ 列。

**修复**:
- `Cell` 加 `wide` 字段:宽字符占 2 格(本格 `{cp, wide=true}` + 续列 `{cp=0, wide=true}`)
- `runeWidth`:EAW=W/F 判定(Hangul/CJK/全角/emoji 等,与 wcwidth 一致)
- 写满前放不下(只剩 1 列)先折行;BS/CUB/CUF 跳过续列;渲染续列只画背景

**验证**:nvimtest 断言(占列/续列/末列折行/CUB 跳续列);真实抓取 main.odin 回放正确。

### B4. 擦除语义错误(补全窗口矩形不完整)

**现象**:nvim 补全窗口(pum)只有有字的 cell 有背景色,矩形不完整。

**根因**:两处:
1. EL/ED/ECH 擦除的 cell 清成 `{}`(透明),xterm 语义是**用当前 SGR 背景色填充**擦除区域
2. 行是稀疏的,EL 只清已存在的 cell,行尾从未写入的区域没有 cell

**修复**:
- `eraseCell`:擦除用 cell 携带当前背景色
- `lineEnsureCol` + 行定宽:EL/ED/ECH 把行扩展到 `cols` 再擦除(行模型定宽,与 xterm 一致)
- DCH/ICH 补的空白同样带当前背景
- 渲染:空白 cell 带非默认背景时画背景

**验证**:nvimtest 断言(补全窗口场景:文本格 fg/bg、擦除区保留背景、行定宽 80)。

### B5. 132 列模式 + Origin mode 实现(ConPTY 下无法由 vttest 触发)

**需求**:vttest 的 132 列测试(4 个)和 origin mode 测试依赖这两个特性。

**实现**:
- DECCOLM(`?3h`):切换清屏、光标回 home、滚动区重置、布局固定 132 列(左对齐)、ConPTY resize 联动
- DECOM(`?6h`):CUP/CUU/CUD/VPA/VPR 相对滚动区定位(`vtTargetRow`),DECSTBM 联动 home,DECRQM 查询

**验证**:nvimtest 合成断言(21 项)。**注意**:vttest 在 ConPTY 下测不到这两个特性——见 §3。

### B6. 空白格零值(黑色背景块)

**现象**:yazi 每行左边缘出现黑色竖条,高亮/背景显示错乱。

**根因**:行扩展时 `append(&line.cells, Cell{})` 补出的空白格是零值(`fg=0, bg=0`)。渲染层判定"带背景的空白格"时 `bg=0 ≠ theme.bg` → 画黑色背景块。yazi 布局中 col 0 恰好是未写入区,整列黑块覆盖在边框/高亮旁。宽字符续列同理(零值续列也画黑块)。

**修复**:所有空白格创建(行定宽、字符写入扩展、ICH 扩展)改用默认样式 `{fg=DEFAULT_COLOR, bg=DEFAULT_COLOR}`;宽字符续列继承字符样式。

**验证**:yazi 抓取(3835B)回放:黑块全部消失,布局完全正确。

### B7. COLORTERM 缺失

**现象**:yazi 无颜色输出(只有 reverse 高亮,无主题色)。

**根因**:yazi(anstream)检测 `COLORTERM`;ConPTY 子进程环境无此变量时降级无颜色模式(NO_COLOR 也会强制降级)。

**修复**:`conpty.odin` 创建子进程时注入 `COLORTERM=truecolor`(创建后恢复父进程环境变量)。

**验证**:yazi 抓取出现 156 个颜色 SGR(38;5;4 蓝、38;2;3;169;244 青、48;5;4 蓝底等),回放正确。

### B8. 底部软折行/回车产生多余空行(折行逻辑与光标段缓存)

> 注:B9 起内容层改为**逐行网格**(纯物理行),本条修补的"逻辑行 + 段派生"前提已废弃;
> 留下作为历史记录与"为什么改模型"的对照。

**现象**(用户报告"莫名其妙出现很多多余的空行"):屏幕底行的内容一折行,正文就整体上浮、下面多出等量空行;回车后提示符落在一串空行之上;某些序列(EL 补齐后回车、进交替屏、SU、RIS/DECCOLM)之后内容整块错位。用 `playground/wrapcheck/` 逐条复现(5×10 面板):

| 场景 | 旧行为 | 新行为 |
|---|---|---|
| 底行输入 25 字符 | 内容行 5 条 → 7 条(2 空行),正文占屏 0..2、光标在空行 4 | 5 条,正文占 2..4,光标紧跟行尾 |
| `eeeab` + `ESC[K` + 回车 | 拆出一条纯补齐空白的行,PROMPT 与内容之间多一行 | 回车直接进下一行,无空白行 |
| 区域滚动内折行 | 新行以空格开头(off 凭空 +1) | 从段首写起 |
| 滚屏后回顶写 + 进交替屏 | 空页被补出 5 条空行,X 落在第 6 行 | 空页 1 行,X 在第一行 |
| 滚屏后回顶写 + `ESC[S` | 后续写入落在已滚出视口的行上(屏上无变化) | 写进光标所在屏行 |
| 内容未满屏 + CUP 到第 5 行写 | 字写在第 3 行、光标框留在第 5 行 | 字与光标都在第 5 行 |
| 写满末列 + 裸 LF + 写字 | LF 下移后 pending 又折一次,多一空行/前导空白 | LF 清 pending,字符写在新行的原列(xterm) |
| 写满末列 + `ESC[K` + 写字 | 折到下一行 | 原列覆盖(xterm) |

**根因**:
1. **全屏软折行借道 `vtScrollUp`**:全屏上滚的实现是"行数组尾部 append 一条空行";软折行其实只是同一逻辑行多长一段,而活窗口贴底(`viewportAnchorLive` 取内容尾部),追加的空行必然被显示在底行 ⇒ 每折一次多一空行。软折行路径改为不 append —— 紧随的写入让逻辑行多长一段,活窗口自然把顶段挤出,与"`cursor_row` 不变"自洽;区域滚动仍走 `vtScrollUp`(区内按行搬移)。
2. **"本行走完"按 `len(cells)` 判定**:EL/ED 会把行补齐到 `cols`,补齐空白不是内容;回车被当成"行内硬断点",在内容末尾 `splitLineAt` 拆出一条全空白的行。改用 `LineExtent`(内容长度)。
3. **`cursorSegmentNextSegment` 用 `max(1, SegmentLen)`**:空行返回 0 也前进一格,区域滚动后落在新插入空行上的第一笔带前导空格;改成 `n > 0` 才前进。**`cursorSegmentRefresh` 对内容之后的屏幕行饱和成 `len(lines)`**:写入全挤到内容末尾(光标在第 5 行、字出现在第 3 行)。空白区映射改为"末尾之后第 `r - 空白区首行` 条新行"。
4. **光标段缓存失效面不全**:命中写入路径的 `cursorSegment` 有"屏幕行变了就重查"的守卫,但 LF/折行推进与切页不经过它 —— `ConsoleAttach/ActivateTermBuffer`(1049)、`TermBufferClear`(RIS/DECCOLM)、`SU` 全屏上滚都要显式作废;`CUP` 之后未写入就 LF 时,缓存还属于旧行 ⇒ `vtLf` 先按当前行同步一次(有 review 视口时不查表,避免写进回看内容)。
5. **`wrap_pending` 与 xterm 不符**:见 B2 后修正。LF/IND/RI 清 pending;EL/ED(0/1/2)/ECH/DCH/ICH/IL/DL 清 pending;SGR/模式/应答不清(nvim eob 依赖后者)。

**验证**:`playground/wrapcheck/`(本地探针,18 组场景回归;`playground/` 已在 .gitignore)。

### B9. vim visual 模式按 `l` 后内容错乱/自动加行(折行模型重构为逐行)

**现象**(用户截图):vim 打开 `resource/config.ceterm`,`G` 到底部、`v` 进 visual 再按几次 `l`,屏幕出现阶梯状散落字符、`-- VISUAL --` 双影、行数莫名增加,终端与 vim 的屏幕模型彻底错位。

**复现**(`playground/vimrepro/`):ConPTY 里跑真实 vim,喂给 canvas 的真实语义层(含 CPR/DA 应答),按键脚本 `G → gg → v → l×6 → resize 90 → resize 120`,每步 dump `lines`/屏幕行↔行号映射。用旧模型复现:启动时 `default-launch "...FiraCode Nerd Font"` 这类长行写满后靠**自动折行**落到下一物理行;vim 认为那是独立屏幕行,随后用 `CUP` 定位到该行重绘 —— 旧模型把它换算回**同一逻辑行的续段**或**下一条逻辑行**,写入落错,增量重绘级联把整屏写花(截图里的阶梯字符)。

**根因**:**逻辑行 + 屏幕段派生**与 VT 绝对寻址不兼容。自动折行是 VT 明文行为(下一物理行),应用(CUP 绝对定位)与终端对"第 r 行是什么"的理解必须一致;段派生让屏幕行 → 内容行的映射依赖内容长度,任何"折行 + 绝对定位"混用都会错行。

**修复**:内容层重构为**逐行网格**(对照 alacritty `grid/row.rs` 的 `WRAPLINE`、Windows Terminal `textBuffer.cpp` 的 `WasWrapForced`):
- `Line = {cells, wrapped}`;屏幕第 r 行 ↔ `lines[base + r]`(线性下标,无表/无段/无光标段缓存);屏幕始终物化 `rows` 行。
- 软折行 = 新开物理行 + `wrapped = true`(`vtWrapOnce`);硬换行(LF/IND/NEL 列 0)清落点行标记;显式行首覆盖写与整行擦除也清;reflow 只在 `wrapped` 串内合并。
- `cols` 变化 ⇒ reflow(按 `wrapped` 串合并/重切;内容长度用 `LineExtent`;宽字对不跨行);光标/选区/review 锚点按"流内偏移"随动;**所有登记页都重排**(含交替屏期间的主屏)。
- `rows` 变化 ⇒ 只重算 base 与光标屏行;同尺寸 no-op 保留。
- 擦除/插删全部退化为物理行的 `[0, cols)` 算术;IL/DL/SU/SD 不再需要 `splitRowsInRegion`。

**验证**:`playground/vimrepro/` 复现转绿(行数恒 30、无 `wrapped` 残留、`l` 逐列移动、resize 后并回);`playground/wrapcheck/`(底部折行/EL 回车/CUP 覆盖续行/硬行 reflow/CJK 不劈开/选区跨软折行/resize 选区随动/交替屏/裸 LF+EL 清 pending)。

---

## 3. 架构发现:ConPTY 的 conhost 拦截

通过 vttest 字节流分析发现的 ConPTY 关键行为:

**conhost 拦截"影响自身屏幕模型"的序列,自己执行后以 80 列坐标的"重绘输出"推给客户端;其余序列原样转发。**

| 序列 | 行为 |
|---|---|
| `ESC[?3h/l`(DECCOLM)、`ESC#8`(DECALN) | **拦截**,conhost 自己切换/填屏 |
| `ESC[?6h/l`(DECOM)、`ESC[?7h/l`(DECAWM) | **拦截** |
| `ESC[c`(DA1)、`ESC[6n`(DSR) | **拦截应答**(conhost 返回自己的属性) |
| `ESC[?25h/l`、SGR、CUP、ED/EL、文本 | 原样转发 |
| `ESC[>0c`(DA2)、`ESC[?u` | 转发(我们应答 ✓) |

**推论**:
1. vttest 在 ConPTY 下验证的是"conhost 执行 VT + 重绘 + 我们解析重绘",80 列核心语义全部通过
2. 132 列/origin mode 实现在 ConPTY 下**无法被 vttest 触发**(序列到不了我们),只能靠合成测试验证
3. 子进程 `GetConsoleMode(stdout)` 返回 `0x7`(含 ENABLE_VIRTUAL_TERMINAL_PROCESSING),终端能力正常

---

## 4. 终端语义规则(固化)

以下规则是本次调试确认的 xterm 兼容语义,新增特性不得违反:

### 解析层
1. **vtparse 契约**:`Clear` 只重置 `num_params`/`num_intermediate_chars`,不清数组;消费端必须按 `num_params` 读参数,按 `num_intermediate_chars` 读中间字节

### 写入/折行
2. **wrap-pending**:写满最后一列,光标停最后一列置 pending;**下一个可打印字符**才折行
3. **谁清 pending(xterm `ResetWrap` 口径)**:光标移动类(CUP/CUU/CUD/CUF/CUB/CHA/VPA/HPA/VPR/HPR/DECRC/BS/TAB/CR)、LF/IND/RI、EL/ED 0-2/ECH/DCH/ICH/IL/DL 都清;**SGR/模式/应答不清**(nvim eob 依赖"写满 + 改色 + 字符折行")
4. **折行 = 新物理行(逐行网格,B9)**:软折行落到下一行并置 `wrapped`(底行先滚屏,顶行进历史);硬换行(LF/NEL/IND 列 0)也开新行但清 `wrapped`。屏幕第 r 行 ↔ `lines[base + r]`,绝对定位与自动折行不会错行
5. **宽字符占 2 列**:EAW=W/F 字符(`runeWidth`),续列 cell 继承样式;最后列放不下先折行;BS/CUB/CUF 跳过续列
6. **空白格 = 默认样式**:任何方式创建的空 cell 必须 `fg/bg = DEFAULT_COLOR`,零值 `bg=0` 会被渲染成黑色块

### 擦除
7. **擦除带背景**:EL/ED/ECH 擦除区域用当前 SGR 背景色填充(补全窗口矩形依赖)
8. **行定宽**:EL/ED/ECH 把行扩展到 `cols` 再擦除

### 模式
9. **DECCOLM(`?3h`)**:清屏、光标 home、滚动区重置、132 列布局固定
10. **DECOM(`?6h`)**:定位相对滚动区顶、限制在区内;DECSTBM 联动 home
11. **交替屏(1049)**:进出保存/恢复光标 + 滚动区,进入时滚动区重置全屏

### 应答
12. **DSR 报屏幕坐标**(物理行 - 可视区顶部),不报物理行
13. `ESC[?u`/`ESC[?6n` 应答 `ESC[?r;cR`;`ESC[18t` 应答 `ESC[8;rows;colst`;`ESC[?u` 不能被当成 restore-cursor

---

## 5. 测试体系

| 层 | 工具 | 覆盖 |
|---|---|---|
| 解析层 | `playground/vtparsetest` | 状态机切分、UTF-8、残留参数契约 |
| 语义层 | `playground/nvimtest`(89 断言) | 全部规则 B1-B7、132 列、origin、pum、宽字符 |
| 真实字节 | `vtcapture` + `vtreplay`/`vttestreplay` | nvim(空文件/源码文件)、yazi、vttest 1/2 |
| 验收 | vttest(经 ConPTY) | 80 列核心语义:光标/擦除/SGR/滚动/TAB/wrap/保存恢复 |
| **性能** | `playground/profilerun` + `playground/profiletest` | 逐模块/子模块分趟计时(见 §5.1) |

**vttest cmdfile 驱动要点**(`playground/vtcapture/vttest_cmds*.txt`):
- 文件必须 **LF 行尾**(CRLF 会让 `\r` 残留进选择,菜单报 Bad choice)
- `Wait:`/`Done:` 对覆盖 Setup 阶段的回放暂停(DA1 查询等,conhost 应答)
- `Read:` 行提供菜单选择与 holdit 回车;数量要匹配(测试 1 = 7 个等待点,测试 2 = 9+)

### 5.1 分趟计时(性能定位)

**机制**:`src/profile/profile.odin`,编译期开关 `profile`(默认 **false**)。

```
odin run playground/profilerun/ -define:profile=true     # 出分趟表
odin run playground/profiletest/  -define:profile=false  # 验证零开销
```

- 关闭时 `Mark/Begin/End/Now` 全被编译掉 —— 已实测**精确零开销**(4.001 ms vs 4.001 ms)。
- 开启时单次标记 ~117 ns(两次 `GetPerformanceCounter` + 一次记录)。
- 打点覆盖:main 帧序 6 处、`canvas.Update` 6 个子趟、`ConsoleUpdateTree` 4 处、
  `render.Update` 3 处 + `DrawFrame` 6 个渲染趟(约 22 标记/帧)。

**必须先看账目自检**:探针会打印"FRAME 标记之和 vs 该段实测墙钟"的偏差。
偏差 > 5% 或"标记数 ≠ 帧数"时表不可信 —— 开发过程中正是这道检查抓到了
`MAX_MARKS` 打满(标记被静默丢弃,每帧口径整体偏小)。

**读表口径**:
- `每帧(µs)` = 总计 / 帧数(按记录到的帧数,不是名义帧数)
- `帧最小(µs)` = "某一帧里该阶段合计"的最小值。**用它区分"每帧恒定开销"与"偶发尖峰"**
  —— `单次均(ns)` 在"一帧内调多次"的阶段会小到没有意义。

**负载要分开测**:静置与满载混在一起会被平均掉,看什么都是平的。探针跑两相(A 静置 / B 子进程持续刷屏)。

---

## 5.2 首次分趟实测结论(160×43 面板,vsync off)

| 相 | 帧墙钟 | swap | 应用逻辑合计 | 其中最大项 |
|---|---|---|---|---|
| A 静置 | 222 µs | 172 µs(77%) | ~6 µs | `scene:fg 趟` 30 µs(总工作,已含 DrawFrame) |
| B 满载 | 232 µs | 150 µs(65%) | ~5 µs | `scene:fg 趟` 56 µs + `bg 趟` 9.6 µs |

**两条结论**:
1. **`GL_SwapWindow` 是当前最大单项**(150–172 µs/帧)。但它不是 CPU 工作 ——
   探针里窗口不被合成器刷,所以这是"呈现路径"的成本,不是可优化的算法成本。
   要判断真实瓶颈必须**带 vsync 或在真实窗口状态下测**。
2. **应用侧最重的是 `scene:fg 趟`(字形绘制)**,静置 30 µs / 满载 56 µs。
   相对地,**VT 解析只要 0.19 µs/帧**(`UpdateConsole`),`canvas.Update` 3.5 µs —— 
   `Cell`/`GlyphSlot` 内存布局优化(此前测过 SoA 收益 ~0.01% 帧预算)确实不可能是瓶颈。

**下一步该查的**(按实测大小):`scene:fg 趟` 内部(TabBar/CommandBar/FPS 那一趟 8.2 µs
比整棵 console 树的更新 0.59 µs 还贵,值得先看)。

---

## 6. 遗留问题

1. **下划线渲染**:SGR 4(underline)已存储到 CellStyle 但渲染层未画(yazi 对部分文件用下划线标记)
2. **粗体/斜体渲染**:同样只存储不渲染
3. **132 列/origin 的 vttest 实测**:ConPTY 拦截导致无法端到端验证,保留合成测试
4. **vttest 全量**:仅跑了测试 1(光标)和 2(屏幕特性),字符集/双宽字/键盘/报告等未跑
5. **DECALN(`ESC#8`)**:conhost 拦截,未实现(直接字节流场景缺失)
6. **鼠标事件**:模式已跟踪(mouse_mode/sgr_mouse)但未实现上报
