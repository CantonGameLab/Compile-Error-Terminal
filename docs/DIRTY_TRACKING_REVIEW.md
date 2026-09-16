# 脏标记(Dirty Tracking)前置复盘

> 目的:在动手实现"画面没变就不重绘"之前,先查清**什么状态变了要重画什么**,
> 以及现有代码里是否存在"多写者"导致脏标记会漏刷的结构问题。
>
> 方法:**先量,再读**。所有数字来自 `playground/profilerun`(分趟计时 + 产出计量),
> 不是推算。写作时点的实测口径见文末"复现方式"。

---

## 0. 起因:实测发现的浪费

分趟计时(`playground/profilerun -define:profile=true`)在静止画面下的结果:

```
帧墙钟        222 µs
  render.Update      216 µs
    EndFrame(swap)   172 µs   ← 76% 的帧时间
    DrawFrame         42 µs
  canvas.Update        4 µs   ← 全部 canvas 逻辑
  command/event/...   ~2 µs
```

`swap` 占 76%,但受控实验(`playground/swapprobe`、`swapprobe2`)证明它**不是可优化的算法成本**:

| 实验 | 结果 | 排除 |
|---|---|---|
| 面积 320×240 → 2560×1440(×480) | 耗时 207 → 174 µs | **不是像素拷贝** |
| MSAA 关 vs 4x | 170.8 vs 177.8 µs | 不是 4x resolve |
| 额外 200 万顶点 | 233.8 → 204.0 µs | **不等 GPU** |
| 窗口隐藏 | 198 → 959 µs | 是"可见时的呈现成本" |
| vsync off / on | 5,419 fps / 276 fps | 275 Hz 显示器 |

**根因是帧循环本身**:vsync off + 无脏标记 ⇒ 引擎以 **5,419 fps** 渲染并呈现同一幅画面
(显示器只有 275 Hz)。开了 vsync 降到 276 fps —— 省 CPU,但**仍然每帧都画、都提交**
(实测 `vsync on` 时静止画面 552 帧/2s ≠ 0)。

所以真正要做的是:**没变就不进入渲染与呈现**。

---

## 1. 每帧恒定开销清单

**实测**(静止画面、无可观察变化、2000 帧统计;`playground/profilerun` 的"产出计量"表):

```
render:本帧四边形 合计   116.6 /帧      提交批次数  6.0 /帧      100% 的帧都非零
```

分趟与溯源(标签统计):

| 项 | quad/帧 | 性质 | 能否归零 |
|---|---|---|---|
| `fg-内容`(字形 `pushGlyph` + 装饰线) | **103** | 屏幕上的**真实内容** | 只有"整帧不画"才能 |
| `页签条`(条底 2 段 + 非激活页签矩形 + "+") | **7** | **纯常量**,与状态无关 | ✅ |
| `bg-焦点描边`(上下左右 4 条) | **4** | **纯常量**(焦点不变则不变) | ✅ |
| `bg-内容底` / `bg-激活页签底` | **2** | **纯常量** | ✅ |
| 光标 | 0–2 | 样式 + 闪烁相位 | 否(闪烁即动画) |
| `FPS` | 0–8,仅 **0.5%** 的帧 | 已由 `fps_value` 更新(0.5s)自动门控 | 已自门控 |
| `命令栏` | 0 | 不可见时 0 | 已是 |
| `bgshader` | **0** | 只是 shader 求值,不产 quad | 已是最小 |

**对账**(同一次运行内):

| | 可见面板非空格子 | `fg-内容` quad | `pushGlyph` |
|---|---|---|---|
| 静置 | 103 | 103.17 | 107.04 |
| 满载 | 228 | 228.12 | 237.16 |

⇒ `fg-内容` 的 quad 数 = 屏幕上的非空格子数,**不是无脑重画**。

### 判定:"完全静止"在现有代码里**不成立**

两个强制重绘源,周期都是 **0.5 秒**:

1. **光标闪烁** —— `BlinkAlpha(style, now_ms(), input_activity_ms)`,硬相位 500 ms(刻意设计)
2. **FPS 标签** —— `fps_value` 每 0.5 s 更新一次显示值

所以脏标记的判据不是"有没有变",而是:

```
需要重绘  ⟺  状态变过  或  距上次绘制 ≥ 500 ms
```

### 关键约束:每帧从 `gl.Clear` 开始,无帧缓冲累积

`BeginFrame` 每帧清屏 → 全部内容重推。那 103 个 quad **必须**重推,没有上一帧像素可复用。
因此两条路:

| 方案 | 做法 | 省什么 | 改动 |
|---|---|---|---|
| **A. 跳过整帧** ✅ | 无变化 → 不 `DrawFrame`、不 `swap` | 全部 117 quad + 180 µs swap | 小 |
| B. 局部重绘 | 只重推变化区域(`glScissor` / FBO 累积) | 只省变化的反面 | 大 |

**选 A**:终端画面静止时 GPU 上那幅图本来就是对的,重复呈现纯属浪费。
A 只需要一个判据:**"这一帧有没有任何东西变过"**。

---

## 2. 五项可见输出的字段级状态清单 + 唯一写者

| # | 输出 | 数据字段 | 唯一写者入口 | 收敛状态 |
|---|---|---|---|---|
| 1 | **终端格子** | `TermBuffer.lines[].cells[]`、`cells[].cp/style`、`Line.wrapped` | **`Parse(console_h, data)`**(`vtparse.odin:90`)| ✅ **完全收敛** |
| 2 | **光标** | `Console.cursor_row/cursor_col`、`Console.vt.cursor_visible/cursor_style` | 见 §3.1 | ❌ **三个模块** |
| 3 | **选区** | `Selection.pivot/cur/buffer_h/host/active` | 见 §3.2 | ❌ **六处 + 被 buffer 操作平移** |
| 4 | **UI 条** | `Page.title`、`CommandBar.input/len/cursor`、`command_bar_visible`、FPS 显示值 | 见 §3.3 | ⚠️ 部分收敛 |
| 5 | **窗格几何** | `WindowTreeNode.transform`、`split_factor/split_type`、`Page.focused/view_mode` | `RecalculateTransforms` / `WindowTreeSetRootSize` | ⚠️ 几何收敛,`focused` 不收敛 |

### 1. 终端格子 —— ✅ 唯一写者,无需改动

全链路只有一个入口:

```
Parse(console_h, data)                      ← 唯一入口(vtparse.odin:90)
 └ vtDispatch                              (vt.odin:83,唯一调用点)
    ├ .Print        → vtPrint → ConsoleWriteRune / vtWrapOnce
    ├ .Execute      → vtHandleC0
    ├ .EscDispatch  → vtEscDispatch
    ├ .CsiDispatch  → vtCsiDispatch → vtEraseIn*/vtEraseChars/vtDeleteChars/
    │                                 vtInsertChars/vtInsertLines/vtDeleteLines/
    │                                 vtScrollUp/vtScrollDown/TermBufferClear
    └ .OscEnd       → oscDispatch
```

`Parse` 的调用者只有 `vtFeed`;`vtFeed` 的调用者:`UpdateConsole`(每帧拉 ConPTY)
与 `Feed` 命令(键盘注入)。**没有任何旁路写者**。

⇒ **给 `Parse` 加一处"内容变了"标记即可覆盖整个屏幕状态。**

### 2–5. 见 §3 的问题清单

---

## 3. 写者收敛检查(发现的问题)

### 3.1 ❌ 光标有三个写者,其中一个是**非 VT 路径**

| 写者 | 位置 | 触发场景 |
|---|---|---|
| VT 输出 | `vt.odin` 约 30 处(CUP/CUD/CUF/LF/CR/BS/CNL/CHA/VPA/HPA/…)+ `vtEscDispatch`(DECSC/DECRC) | 程序输出 |
| **`ConsoleUpdateLayout`** | `console.odin:428`(`cursor_col = min(cursor_col, cols-1)`) | **窗口 resize** |
| **`ConsoleResize`** | `console.odin:486-487`(`cursor_row/col = min(…, rows-1/cols-1)`) | **窗口 resize** |
| 生命周期 | `console.odin:223/249`、`vt.odin:664-673`(RIS)、`vt.odin:899/964`(交替屏) | 会话重建 / RIS / 主屏⇄交替屏 |

**问题**:光标可以由"非 VT 路径"(窗口 resize)改变。
如果脏标记只挂在 `Parse` 上,**改窗口尺寸后画面不会刷新**。

### 3.2 ❌ 选区有六类写者,并且会被**终端的行操作平移**

| 写者 | 位置 | 说明 |
|---|---|---|
| 鼠标建立/拖拽 | `mouse.odin`、`keybindings.odin:28-32,84-86` | 正常路径 |
| 命令 | `command.odin:330-334`(`clearselection` / `selectall`) | 正常路径 |
| **选区自愈** | `selection.odin:84`(`SelectionClear`,校验失败即清) | 每帧 `SelectionValidate` |
| **行插入/删除平移** | `selection.odin:333-397`——`selectionLineInsert/Delete`、`selectionLineShiftCols/UnshiftCols` | **由 `vtInsertLines`/`vtDeleteLines`/`vtEraseChars`/`vtInsertChars`/`vtDeleteChars` 调用** |
| **滚动区平移** | `selectionLineScroll`(同上族) | 由 `vtScrollUp/Down` 调用 |
| **裁剪** | `trimScrollback` → `selectionLineDelete(0, cut)`(`buffer.odin:303`) | 超 10000 行时 |

**问题**:选区坐标是**绝对行号**,而终端的行插入/删除/滚动会移动行号,
所以每个行操作都必须手动平移选区。这是"状态在字段里"的典型症状 ——
`selection.odin:333-397` 那 5 个平移函数全是为了维护这个镜像而存在。

### 3.3 ⚠️ `Page.focused` 是裸写重灾区

| 写者 | 位置 |
|---|---|
| `page.odin:422`(`PageClearFocus`) | 销毁窗格后重选 |
| `userapi.odin:90/125/131/159/208/274-277/493/712/729` | 分割/销毁/交换/显式设置 |
| `keybindings.odin:80/107`、`mouse.odin`(拖动) | **行为层直接改页面字段** |

`keybindings.odin:80` 是 `CurrentPage().focused = node_h` ——
**行为层绕过 userapi 直接写页面字段**,违反项目规范("程序内部一律 `GetXxx()` 指针直改"
是指改数据,但跨模块改**别人拥有的状态**应当有守卫)。
这不只是脏标记的问题:焦点可被十余处修改,漏掉任何一处都会表现为"偶发不刷新"。

### 3.4 ⚠️ 单个操作跨多个状态类:窗口 resize 与 `trimScrollback`

`ConsoleUpdateLayout` 同时改**几何**(字号→行列数)与**光标**;
`trimScrollback` 一个函数里改了 **cells + 选区 + 光标 + review 锚点** 四项独立状态:

```odin
// buffer.odin:300-312
remove_range(&tb.lines, 0, cut)
selectionLineDelete(0, cut)     // ← 选区
console.cursor_row -= u16(cut)  // ← 光标
tb.review_line = ...            // ← 视口锚点
```

⇒ 脏标记必须挂在**这些具体操作**上,或把这些状态改成**派生值**。

---

## 4. 结论与设计建议

### 4.1 脏标记的最小可行形态(方案 A)

一个**帧级布尔** + 分散的"置脏"点,判据:

```
if !dirty && (now - last_present) < 500ms {
    跳过 DrawFrame 与 swap,直接进下一帧
}
```

### 4.2 置脏点清单(按 §2/§3 的写者清单)

| 置脏来源 | 挂在哪 | 覆盖 |
|---|---|---|
| **VT 输出** | `Parse` 入口(唯一) | 屏幕全部内容 + 大部分光标变化 |
| **窗口 resize 路径** | `ConsoleUpdateLayout` / `ConsoleResize` | 几何 + 光标钳位 |
| **鼠标/选区** | `mouse.odin`、`SelectionClear/SelectAll`、`SelectionExtend` | 选区 |
| **命令执行** | `ExecuteCommand`(唯一解释器) | 用户可见的一切配置/树/页变化 |
| **会话生命周期** | `consoleInitSession` / `consoleClearSession` / RIS / 交替屏切换 | 换程序、清屏 |
| **定时** | 光标闪烁(500ms)、FPS 标签(500ms) | 动画 |

**注意**:`ExecuteCommand` 已经在"命令 → userapi"这一层收口,
所以"命令改了状态"只需要一个置脏点 —— 这是现有架构给的红利。

### 4.3 建议先做的收敛(否则会偶发漏刷)

| 优先级 | 收敛项 | 理由 |
|---|---|---|
| **高** | `Page.focused` 收进 `SetFocusWindow` 单一入口(含行为层的 `keybindings`/`mouse`) | 十余处裸写;漏一处 = 偶发不刷新 |
| **高** | 光标钳位(resize)走一个 `clampCursor(console)` 函数 | 让 resize 路径只有一个置脏点 |
| 中 | 选区坐标改为**相对行锚定**(或给 `TermBuffer` 加 `line_generation` 计数,平移改为惰性重算) | 消掉 `selection.odin:333-397` 那 5 个镜像维护函数 |
| 低 | `Page.title` 已是 `PageSetTitle` 唯一写者 ✅;`CommandBar` 输入已收在 `commandBarFeed`/`CommandBarSubmit` ✅ | 无需改动 |

### 4.4 不做什么

- **不做局部重绘(方案 B)**:需要帧缓冲累积,改动远大于收益 —— 静止帧本来就该 0 产出。
- **不动内存布局**:已实测,`Cell`/`GlyphSlot` 的 SoA 收益 ≈ 0.01% 帧预算
  (见 `playground/soabench`、`glyphcachetest`),在 76% 的 swap 面前没有意义。
- **不为了脏标记重构成"事件系统"**:一个布尔 + 几个置脏点就够,不要为不存在的复杂度付利息。

---

## 5. 复现方式

```
# 分趟计时 + 产出计量(两相:A 静置 / B 满载)
odin run playground/profilerun/ -define:profile=true

# 验证计时设施本身:关闭时零开销、开启时测得准
odin run playground/profiletest/
odin run playground/profiletest/ -define:profile=true

# swap 成本受控实验
odin run playground/swapprobe/     # 面积扫描 / MSAA / vsync
odin run playground/swapprobe2/    # 显示模式 / GPU 负载 / 窗口隐藏 / 稳态批次

# vsync 出帧率对照
odin run playground/vsyncprobe/

# 屏幕内容 dump(离线看清某时刻面板上有什么)
odin run playground/screendump/
```

**读表注意**:分趟表必须先看探针打印的**账目自检**("FRAME 标记之和 vs 该段实测墙钟",
偏差须 < 5%)。开发本复盘时正是这道检查抓到了 `MAX_MARKS` 打满导致的整表偏小。
