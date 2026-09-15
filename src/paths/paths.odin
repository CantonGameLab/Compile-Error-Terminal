// 资源根解析:发行版 = 可执行文件同目录的 resource/(双击 / 快捷方式 / PATH / Win+R 启动都对),
// 开发与回归探针 = 从仓库根运行时回落 <cwd>/resource(odin run 产出的可执行文件在临时目录,
// 不在源码目录,探针只能靠这条回落读到出厂配置)。
// 解析顺序:① 环境变量 CETERM_RESOURCE_DIR(显式覆盖)② <exe目录>/resource
//           ③ <cwd>/resource ④ 兜底 ②(不存在也用它:报错信息给出用户看得懂的路径)。
// 解析只做一次(首次访问自动解析,幂等);路径串零分配,全部借用定长缓冲。
// 依赖 core:os + core:sys/windows(不挂 SDL,任何初始化之前都能用)。
package paths

import "core:fmt"
import "core:os"
import win "core:sys/windows"

PATH_BUF_MAX :: 1024

resource_root_buf : [PATH_BUF_MAX]u8 // 解析结果(唯一真相)
resource_root_len : int
resolve_buf : [PATH_BUF_MAX]u8 // Resource 的拼接缓冲

// 显式解析(main 启动时调用:让路径问题尽早暴露;重复调用无副作用)
Init :: proc() {
	ensureResolved()
}

// 资源根目录(借用;程序运行期有效)
ResourceRoot :: proc() -> string {
	ensureResolved()
	return string(resource_root_buf[:resource_root_len])
}

// 资源根下的子路径(借用 resolve_buf,直到下一次 Resource 调用失效;
// 需同时持有两串 = fmt.aprintf("%s/%s", ResourceRoot(), sub) 自行分配)
Resource :: proc(sub : string) -> string {
	ensureResolved()
	return fmt.bprintf(resolve_buf[:], "%s/%s", string(resource_root_buf[:resource_root_len]), sub)
}

ensureResolved :: proc() {
	if resource_root_len > 0 {
		return
	}
	// exe 目录:GetModuleFileNameW 取 exe 全路径,砍掉文件名(超长路径按缓冲截断)
	wide : [PATH_BUF_MAX]u16
	n := int(win.GetModuleFileNameW(nil, &wide[0], win.DWORD(len(wide))))
	utf8_buf : [PATH_BUF_MAX]u8
	exe_path := win.utf16_to_utf8_buf(utf8_buf[:], wide[:n])
	exe_dir := exe_path
	for i := len(exe_path) - 1; i >= 0; i -= 1 {
		if exe_path[i] == '\\' || exe_path[i] == '/' {
			exe_dir = exe_path[:i]
			break
		}
	}
	// ① 环境变量覆盖(相对路径按 cwd 解释;给探针/便携布局留的显式开关)
	if env := os.get_env("CETERM_RESOURCE_DIR", context.allocator); len(env) > 0 {
		defer delete(env)
		resource_root_len = copy(resource_root_buf[:], env)
		return
	}
	probe_buf : [PATH_BUF_MAX]u8
	// ② exe 同目录(发行版布局)
	probe := fmt.bprintf(probe_buf[:], "%s/resource", exe_dir)
	if os.exists(probe) {
		resource_root_len = copy(resource_root_buf[:], probe)
		return
	}
	// ③ cwd(开发/探针:从仓库根运行)
	if cwd, err := os.get_working_directory(context.allocator); err == nil {
		defer delete(cwd)
		probe = fmt.bprintf(probe_buf[:], "%s/resource", cwd)
		if os.exists(probe) {
			resource_root_len = copy(resource_root_buf[:], probe)
			return
		}
	}
	// ④ 兜底:exe 同目录
	probe = fmt.bprintf(probe_buf[:], "%s/resource", exe_dir)
	resource_root_len = copy(resource_root_buf[:], probe)
}
