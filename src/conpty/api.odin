package conpty

import "core:fmt"
import paths "../paths"
import win "core:sys/windows"

foreign import kernel32 "system:kernel32.lib"

HPCON :: rawptr
PROC_THREAD_ATTRIBUTE_LIST :: rawptr
LPPROC_THREAD_ATTRIBUTE_LIST :: ^PROC_THREAD_ATTRIBUTE_LIST

PSEUDOCONSOLE_INHERIT_CURSOR :: 1
PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE :: 0x00020016 //虚拟终端属性记号
STILL_ACTIVE :: 0x00000103 // GetExitCodeProcess 中进程仍存活

// Job Object(进程树管理):core:sys/windows 未绑定,此处静态绑定 kernel32
JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE :: 0x2000
JOBOBJECTINFOCLASS_BASIC_ACCOUNTING :: 1
JOBOBJECTINFOCLASS_EXTENDED_LIMIT :: 9

// 查询信息类 JobObjectBasicAccountingInformation 的返回结构
JobObjectBasicAccountingInfo :: struct {
	total_user_time, total_kernel_time : i64,
	this_period_total_user_time, this_period_total_kernel_time : i64,
	total_page_fault_count, total_processes : u32,
	active_processes, total_terminated_processes : u32,
}

// SetInformationJobObject 类 JobObjectExtendedLimitInformation 的输入结构
// (仅 LimitFlags 字段有意义,其余保持 0)
JobObjectBasicLimitInformation :: struct {
	per_process_user_time_limit, per_process_kernel_time_limit : i64,
	limit_flags : u32,
	minimum_working_set_size, maximum_working_set_size : win.SIZE_T,
	active_process_limit : u32,
	affinity : win.SIZE_T,
	priority_class : u32,
	scheduling_class : u32,
}

JobObjectExtendedLimitInfo :: struct {
	basic_limit : JobObjectBasicLimitInformation,
	io_info     : [7]u64, // IO_COUNTERS
	process_mem : [3]win.SIZE_T,
	job_mem     : [4]win.SIZE_T,
	peer_handle : win.HANDLE,
}

STARTUPINFOEXW :: struct {
	StartupInfo: win.STARTUPINFOW,
	lpAttributeList: LPPROC_THREAD_ATTRIBUTE_LIST,
}

foreign kernel32 {
	@(link_name="CreatePseudoConsole")
	_CreatePseudoConsole :: proc(
		size:    win.COORD,
		hInput:  win.HANDLE,
		hOutput: win.HANDLE,
		dwFlags: win.DWORD,
		phPC:    ^HPCON,
	) -> win.HRESULT ---

	@(link_name="ResizePseudoConsole")
	_ResizePseudoConsole :: proc(
		hPC:  HPCON,
		size: win.COORD,
	) -> win.HRESULT ---

	@(link_name="ClosePseudoConsole")
	_ClosePseudoConsole :: proc(hPC: HPCON) ---
	@(link_name="InitializeProcThreadAttributeList")
	InitializeProcThreadAttributeList :: proc(
		lpAttributeList: LPPROC_THREAD_ATTRIBUTE_LIST,
		dwAttributeCount: win.DWORD,
		dwFlags: win.DWORD,
		lpSize: ^win.SIZE_T,
	) -> win.BOOL ---

	@(link_name="UpdateProcThreadAttribute")
	UpdateProcThreadAttribute :: proc(
		lpAttributeList: LPPROC_THREAD_ATTRIBUTE_LIST,
		dwFlags: win.DWORD,
		Attribute: win.DWORD_PTR,
		lpValue: rawptr,
		cbSize: win.SIZE_T,
		lpPreviousValue: rawptr,
		lpReturnSize: ^win.SIZE_T,
	) -> win.BOOL ---

	@(link_name="DeleteProcThreadAttributeList")
	DeleteProcThreadAttributeList :: proc(
		lpAttributeList: LPPROC_THREAD_ATTRIBUTE_LIST,
	) ---

	@(link_name="CreateJobObjectW")
	CreateJobObjectW :: proc(lpJobAttributes: ^win.SECURITY_ATTRIBUTES, lpName: win.LPCWSTR) -> win.HANDLE ---
	@(link_name="SetInformationJobObject")
	SetInformationJobObject :: proc(hJob: win.HANDLE, JobObjectInformationClass: i32, lpJobObjectInformation: rawptr, cbJOB_OBJECT_INFOLength: win.DWORD) -> i32 ---
	@(link_name="AssignProcessToJobObject")
	AssignProcessToJobObject :: proc(hJob, hProcess: win.HANDLE) -> i32 ---
	@(link_name="QueryInformationJobObject")
	QueryInformationJobObject :: proc(hJob: win.HANDLE, JobObjectInformationClass: i32, lpJobObjectInformation: rawptr, cbJOB_OBJECT_INFOLength: win.DWORD, lpReturnLength: ^win.DWORD) -> i32 ---
}

// ---------------------------------------------------------------------------
// ConPTY 实现来源:系统 kernel32 / 外部 conpty.dll(两套并存,按会话选择)
// ---------------------------------------------------------------------------
// 装箱的 ConPTY 实现在 conhost.exe 里,而**新版实现(Windows Terminal 项目的
// OpenConsole)任何 Windows 版本都不随系统发布**(microsoft/terminal#17452),
// 所以想在 Win10/11 上拿到新行为只有一条路:自己带一份 `conpty.dll` +
// `OpenConsole.exe`,运行时注入以顶替系统 conhost。
// 做法与 Alacritty、Cygwin-mintty 相同:LoadLibrary + GetProcAddress;
// 三个函数**签名与系统版完全一致**,所以是纯替换,加载不到就无声退回。
// 文件搜索顺序由 LoadLibrary 决定:exe 同目录 → 系统目录 → 当前目录 → PATH;
// `conpty.dll` 与 `OpenConsole.exe` **必须放在一起**(dll 要能找到宿主 exe)。
//
// 为什么值得:装箱 conhost 的 VtEngine(把屏幕序列化成 VT 发给终端的那一层)
// 正是"resize 时整屏重排重发""宽字对只发一半"这类问题的所在地;新版把这一层
// 整个换掉了(microsoft/terminal#17510 "Goodbye VtEngine Edition")。
//
// 两套实现**同时驻留**:一个 HPCON 只能由创建它的那套实现 resize / close,
// 所以上下文各自记住自己是谁建的(见 ConptyContext.impl),切换开关只影响新会话。

CreatePseudoConsoleFn :: #type proc "cdecl" (
	size: win.COORD,
	h_input: win.HANDLE,
	h_output: win.HANDLE,
	dw_flags: win.DWORD,
	ph_pc: ^HPCON,
) -> win.HRESULT

ResizePseudoConsoleFn :: #type proc "cdecl" (hpc: HPCON, size: win.COORD) -> win.HRESULT

ClosePseudoConsoleFn :: #type proc "cdecl" (hpc: HPCON)

ConptyApi :: struct {
	create : CreatePseudoConsoleFn,
	resize : ResizePseudoConsoleFn,
	close  : ClosePseudoConsoleFn,
}

// 实现判别(零值 = 系统);同时是 conpty_apis 的下标
ConptyImpl :: enum u8 {
	System,   // 装箱 conhost(kernel32 导出)
	External, // 外部 conpty.dll(Windows Terminal 的 OpenConsole)
}

// 两套导出名:`Conpty*` 前缀 = 官方 NuGet 包 inc/conpty.h 声明的名字;
// 裸名 = WT 自带那份 conpty.dll / Alacritty 按裸名取的兼容面。都要试 ——
// 只按裸名找会在官方包上静默回退到系统实现。
// 资源树里的相对路径(resource/ 下;见 loadConptyDll)
CONPTY_DLL_REL :: "conpty/x64/conpty.dll"

CONPTY_EXPORT_SETS :: [2][3]cstring{
	{"ConptyCreatePseudoConsole", "ConptyResizePseudoConsole", "ConptyClosePseudoConsole"},
	{"CreatePseudoConsole", "ResizePseudoConsole", "ClosePseudoConsole"},
}

conpty_apis : [2]ConptyApi
conpty_ext_available : bool
conpty_prefer_ext : bool
conpty_dll : win.HMODULE // 非 0 = 外部 conpty.dll 已加载常驻
conpty_export_set : cstring // 命中的导出名(诊断)
conpty_ready : bool

// 找 conpty.dll:① 裸名(exe 同目录 → 系统 → 当前目录 → PATH)
//               ② <资源根>/conpty/x64/ 的全路径
// ② 是为发布包准备的:第三方载荷集中在 resource/(与字体/主题同级),exe 旁边不留散文件。
// conpty.dll 在**自己所在目录**找宿主 OpenConsole.exe,所以两个文件必须放一起。
loadConptyDll :: proc() -> win.HMODULE {
	if h := win.LoadLibraryW(win.LPCWSTR("conpty.dll")); h != nil {
		return h
	}
	full := paths.Resource(CONPTY_DLL_REL)
	if len(full) == 0 {
		return nil
	}
	wide : [512]u16
	w := win.utf8_to_utf16_buf(wide[:], full)
	if len(w) == 0 || len(w) + 1 > len(wide) {
		return nil
	}
	wide[len(w)] = 0 // LoadLibraryW 要 NUL 结尾(utf8_to_utf16_buf 不写终止符)
	return win.LoadLibraryW(win.LPCWSTR(&wide[0]))
}

// 首次使用自动解析(幂等,只跑一次)。结果写一行 stderr —— 这是 Win10 兼容性
// 排查的关键事实(用没用到外部实现,一眼可见)。
initConptyApi :: proc() {
	if conpty_ready {
		return
	}
	conpty_ready = true

	conpty_apis[ConptyImpl.System] = ConptyApi {
		create = _CreatePseudoConsole,
		resize = _ResizePseudoConsole,
		close  = _ClosePseudoConsole,
	}

	if h := loadConptyDll(); h != nil {
		for set in CONPTY_EXPORT_SETS {
			c := win.GetProcAddress(h, set[0])
			r := win.GetProcAddress(h, set[1])
			cl := win.GetProcAddress(h, set[2])
			if c != nil && r != nil && cl != nil {
				conpty_apis[ConptyImpl.External] = ConptyApi {
					create = transmute(CreatePseudoConsoleFn) c,
					resize = transmute(ResizePseudoConsoleFn) r,
					close  = transmute(ClosePseudoConsoleFn) cl,
				}
				conpty_dll = h // 常驻:已有会话可能仍在用它
				conpty_ext_available = true
				conpty_prefer_ext = true // 部署了就用(与 Alacritty 一致);命令可改
				conpty_export_set = set[0]
				break
			}
		}
		if !conpty_ext_available {
			// 半残的 dll:两套导出都没齐,不要留
			win.FreeLibrary(h)
			fmt.eprintln("[conpty] conpty.dll 存在但导出不全,已忽略")
		}
	}

	if GetConptyPreferExternal() {
		fmt.eprintfln("[conpty] 新会话使用外部 conpty.dll(OpenConsole 实现,导出名 = %s)", conpty_export_set)
	} else {
		fmt.eprintln("[conpty] 新会话使用系统 kernel32(装箱 conhost 实现;conpty.dll 未找到)")
	}
}

createPseudoConsole :: proc(
	size : win.COORD,
	hinput : win.HANDLE,
	houtput : win.HANDLE,
	flags : win.DWORD = 0
) -> (hpc : HPCON, impl : ConptyImpl, hr : win.HRESULT) {
	initConptyApi()
	impl = GetConptyPreferExternal() ? .External : .System
	hr = conpty_apis[impl].create(size, hinput, houtput, flags, &hpc)
	return
}

resizePseudoConsole :: proc(
	impl : ConptyImpl,
	hpc: HPCON,
	size: win.COORD
) -> win.HRESULT {
	initConptyApi()
	return conpty_apis[impl].resize(hpc, size)
}

closePseudoConsole :: proc(
	impl : ConptyImpl,
	hpc : HPCON
) {
	initConptyApi()
	conpty_apis[impl].close(hpc)
}

// ---------------------------------------------------------------------------
// 实现选择(userapi:命令 `conpty on|off`)
// ---------------------------------------------------------------------------
// 只影响**新建会话**;正在跑的会话保持它出生时那套实现(HPCON 与实现绑定)。
// 外部实现不可用(没找到 dll / 导出不全)时 `on` 返回 false,调用方报错。

SetConptyPreferExternal :: proc(on : bool) -> bool {
	initConptyApi()
	if on && !conpty_ext_available {
		return false
	}
	conpty_prefer_ext = on
	return true
}

GetConptyPreferExternal :: proc() -> bool {
	return conpty_ext_available && conpty_prefer_ext
}

ConptyExternalAvailable :: proc() -> bool {
	initConptyApi()
	return conpty_ext_available
}

// 当前实现来源("conpty.dll" / "kernel32"),命令与探针用
GetConptyApiSource :: proc() -> string {
	initConptyApi()
	return GetConptyPreferExternal() ? "conpty.dll" : "kernel32"
}

// 命中的导出名(诊断用;"" = 没有外部实现)
GetConptyExportSet :: proc() -> cstring {
	initConptyApi()
	return conpty_export_set
}
