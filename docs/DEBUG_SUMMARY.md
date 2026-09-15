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

**修复**:`VtState.wrap_pending` 字段;`ConsoleWriteRune` 写满置 pending,下一字符折行(抽出 `vtWrapOnce`);只有光标移动类操作(CUP/CUU/CUD/CUF/CUB/CHA/VPA/HPA/VPR/HPR/DECRC/BS/TAB/CR)清 pending;SGR/擦除/模式/应答不清;LF 不清(写满后 LF 下移、下一字符仍折行)。

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
3. **SGR 不取消 pending**:改色后再写字符仍折行(nvim eob 依赖);只有光标移动类操作清 pending
4. **宽字符占 2 列**:EAW=W/F 字符(`runeWidth`),续列 cell 继承样式;最后列放不下先折行;BS/CUB/CUF 跳过续列
5. **空白格 = 默认样式**:任何方式创建的空 cell 必须 `fg/bg = DEFAULT_COLOR`,零值 `bg=0` 会被渲染成黑色块

### 擦除
6. **擦除带背景**:EL/ED/ECH 擦除区域用当前 SGR 背景色填充(补全窗口矩形依赖)
7. **行定宽**:EL/ED/ECH 把行扩展到 `cols` 再擦除

### 模式
8. **DECCOLM(`?3h`)**:清屏、光标 home、滚动区重置、132 列布局固定
9. **DECOM(`?6h`)**:定位相对滚动区顶、限制在区内;DECSTBM 联动 home
10. **交替屏(1049)**:进出保存/恢复光标 + 滚动区,进入时滚动区重置全屏

### 应答
11. **DSR 报屏幕坐标**(物理行 - 可视区顶部),不报物理行
12. `ESC[?u`/`ESC[?6n` 应答 `ESC[?r;cR`;`ESC[18t` 应答 `ESC[8;rows;colst`;`ESC[?u` 不能被当成 restore-cursor

---

## 5. 测试体系

| 层 | 工具 | 覆盖 |
|---|---|---|
| 解析层 | `playground/vtparsetest` | 状态机切分、UTF-8、残留参数契约 |
| 语义层 | `playground/nvimtest`(89 断言) | 全部规则 B1-B7、132 列、origin、pum、宽字符 |
| 真实字节 | `vtcapture` + `vtreplay`/`vttestreplay` | nvim(空文件/源码文件)、yazi、vttest 1/2 |
| 验收 | vttest(经 ConPTY) | 80 列核心语义:光标/擦除/SGR/滚动/TAB/wrap/保存恢复 |

**vttest cmdfile 驱动要点**(`playground/vtcapture/vttest_cmds*.txt`):
- 文件必须 **LF 行尾**(CRLF 会让 `\r` 残留进选择,菜单报 Bad choice)
- `Wait:`/`Done:` 对覆盖 Setup 阶段的回放暂停(DA1 查询等,conhost 应答)
- `Read:` 行提供菜单选择与 holdit 回车;数量要匹配(测试 1 = 7 个等待点,测试 2 = 9+)

---

## 6. 遗留问题

1. **下划线渲染**:SGR 4(underline)已存储到 CellStyle 但渲染层未画(yazi 对部分文件用下划线标记)
2. **粗体/斜体渲染**:同样只存储不渲染
3. **132 列/origin 的 vttest 实测**:ConPTY 拦截导致无法端到端验证,保留合成测试
4. **vttest 全量**:仅跑了测试 1(光标)和 2(屏幕特性),字符集/双宽字/键盘/报告等未跑
5. **DECALN(`ESC#8`)**:conhost 拦截,未实现(直接字节流场景缺失)
6. **鼠标事件**:模式已跟踪(mouse_mode/sgr_mouse)但未实现上报
