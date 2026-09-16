package conpty

import win "core:sys/windows"
import "core:thread"
import "core:sync"
import "core:time"
import s3 "vendor:sdl3"
import mem "../memory"

MAX_READ_BUFFER :: (2<<16) // 128KB,2 的幂(环绕用 & 掩码)

// SPSC 无锁环形缓冲:生产者=读线程(只写 tail),消费者=主循环(只写 head)。
// 跨线程字段用 sync 原子:写 .Release,读 .Acquire。
// 与 conpty_contexts 同下标并行,无独立世代;handle 存关联 conpty 句柄供读线程取上下文。
ReadWriteData :: struct {
	handle      : mem.Handle,
	thread      : ^thread.Thread,
	read_buffer : [MAX_READ_BUFFER]byte,
	head        : u32, // 仅主循环写
	tail        : u32, // 仅读线程写
	dead        : b32, // 读线程退出(管道断开)标记:主循环检测,避免界面永久冻结
}

read_write_datas : [MAX_CONPTY_SLOTS]ReadWriteData

// ---------------------------------------------------------------------------
// 唤醒主循环(阻塞式主循环的前提)
// ---------------------------------------------------------------------------
// 主循环会阻塞在 WaitEventTimeout 上睡觉。子进程输出由本模块的读线程推进 ring,
// 若不通知,主循环就不知道有新输出 —— 终端会停止刷新。
// 做法:读线程往 SDL 事件队列推一个自定义事件,把主循环唤醒。
// event.Update 的 #partial switch 不匹配这个类型,天然忽略(只起"醒一下"的作用)。
wake_event_type : u32 = 0 // s3.RegisterEvents(1) 结果;0 = 未注册

initWakeEvent :: proc() {
	if wake_event_type == 0 {
		wake_event_type = s3.RegisterEvents(1)
	}
}

// 启动读线程前调用:确保唤醒事件类型已注册(否则读线程的 wakeMainLoop 静默跳过,
// 退化成"主循环靠超时轮询" —— 能跑,但阻塞期间子进程输出会延迟到下次超时)。
InitWakeEvent :: proc() {
	initWakeEvent()
}

// 读线程调用(线程安全);未注册时静默跳过(退化为轮询,不会出错)
wakeMainLoop :: proc() {
	if wake_event_type == 0 {
		return
	}
	ev : s3.Event
	ev.type = s3.EventType(wake_event_type)
	_ = s3.PushEvent(&ev)
}

// 读线程阻塞读管道 → 写环形缓冲;ReadFile 被 CloseHandle 打断(失败)时退出
readThreadProc :: proc(t: ^thread.Thread) {
	h := (cast(^mem.Handle)t.data)^
	conpty_context := GetConptyContext(h)
	if conpty_context == nil {
		return
	}
	read_write_data := &read_write_datas[h.id]
	buf := make([]byte, 8 * 1024)
	defer delete(buf)
	defer sync.atomic_store_explicit(&read_write_data.dead, true, .Release)
	defer wakeMainLoop() // 线程退出(管道断开)= 状态变化,也叫醒一次
	for {
		n, ok := readConptyOutput(conpty_context, buf)
		if !ok {
			break
		}
		ringPush(read_write_data, buf[:n])
		wakeMainLoop() // 有新输出:叫醒可能正在睡的主循环
	}
}

// 读线程是否还活着(管道是否断开);主循环每帧检查
IsReadThreadAlive :: proc(h : mem.Handle) -> bool {
	read_write_data := GetReadWriteData(h)
	if read_write_data == nil {
		return false
	}
	return !sync.atomic_load_explicit(&read_write_data.dead, .Acquire)
}

GetReadWriteData :: proc(h : mem.Handle) -> ^ReadWriteData {
	if GetConptyContext(h) == nil {
		return nil
	}
	return &read_write_datas[h.id]
}

ringPush :: proc(read_write_data: ^ReadWriteData, data: []byte) {
	written := 0
	for written < len(data) {
		avail := MAX_READ_BUFFER - 1 - ringLen(read_write_data) // 留一字节区分空/满
		if avail == 0 {
			time.sleep(1 * time.Millisecond)
			continue
		}
		n := min(avail, u32(len(data) - written))
		base := int(read_write_data.tail) & (MAX_READ_BUFFER - 1)
		for i in 0 ..< int(n) {
			read_write_data.read_buffer[(base + i) & (MAX_READ_BUFFER - 1)] = data[written + i]
		}
		sync.atomic_store_explicit(&read_write_data.tail, read_write_data.tail + n, .Release)
		written += int(n)
	}
}

ringLen :: proc(read_write_data: ^ReadWriteData) -> u32 {
	return read_write_data.tail - sync.atomic_load_explicit(&read_write_data.head, .Acquire)
}

// ---------------------------------------------------------------------------
// 未读检查(阻塞式主循环的判据①)
// ---------------------------------------------------------------------------
// 只读,不消耗。主循环靠它决定"子进程还有输出没消化"要不要再跑一帧。
// 与 RingPop 的分工:RingPop 是消费者(推进 head),这里是观察者。
RingHasData :: proc(h : mem.Handle) -> (pending : bool, bytes : u32) {
	rwd := GetReadWriteData(h)
	if rwd == nil {
		return false, 0
	}
	n := ringLen(rwd)
	return n > 0, n
}

// 全部会话里是否有任意一个还有未读输出(主循环每帧问一次)。
// 走池枚举,不裸读数组。
AnyRingHasData :: proc() -> bool {
	it : mem.Iter(MAX_CONPTY_SLOTS, ConptyContext) = mem.All(&conpty_contexts)
	for h in mem.next(&it) {
		if pending, _ := RingHasData(h); pending {
			return true
		}
	}
	return false
}

RingPop :: proc(read_write_data: ^ReadWriteData, out: []byte) -> int {
	n := 0
	for n < len(out) {
		if ringLen(read_write_data) == 0 {
			break
		}
		idx := int(read_write_data.head) & (MAX_READ_BUFFER - 1)
		out[n] = read_write_data.read_buffer[idx]
		sync.atomic_store_explicit(&read_write_data.head, read_write_data.head + 1, .Release)
		n += 1
	}
	return n
}

StartReadThread :: proc(h : mem.Handle) -> bool {
	if GetConptyContext(h) == nil {
		return false
	}
	initWakeEvent() // 唤醒机制就绪(首个会话建立时注册也来得及)
	read_write_data := &read_write_datas[h.id]
	if read_write_data.thread != nil {
		return false
	}
	read_write_data.handle = h
	read_write_data.head, read_write_data.tail = 0, 0
	read_write_data.dead = false
	read_write_data.thread = thread.create(readThreadProc)
	if read_write_data.thread == nil {
		return false
	}
	read_write_data.thread.data = &read_write_data.handle // 必须在 start 前设置
	thread.start(read_write_data.thread)
	return true
}

// 先关句柄破阻塞 → join → 再释放槽(读线程仍持 ^ConptyContext,槽须在 join 后释放)
StopReadThread :: proc(h : mem.Handle) {
	ctx := GetConptyContext(h)
	if ctx == nil {
		return
	}
	read_write_data := &read_write_datas[h.id]
	if read_write_data.thread == nil {
		return
	}
	destroyConptyContext(ctx)
	thread.join(read_write_data.thread)
	thread.destroy(read_write_data.thread)
	read_write_data.thread = nil
	mem.Free(&conpty_contexts, h)
}

StopAllReadThreads :: proc() {
	it : mem.Iter(MAX_CONPTY_SLOTS, ConptyContext) = mem.All(&conpty_contexts)
	for h in mem.next(&it) {
		StopReadThread(h)
	}
}
