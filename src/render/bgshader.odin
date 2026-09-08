// 背景可编程 shader:终端背景(主题打底 + 全部 cell 底色)先渲染到 RGBA8 纹理,
// 再经用户片段 shader 变换输出(字形/光标/UI 不受影响,在其上直接绘制)。
// 背景恒定走 FBO 路径(无"纯色模式"开关);要纯色背景 = 改 background.frag
// (直接输出 uBg 即可),或 SetBackgroundShader 换成自定义源码。
// 默认加载 resource/shader/background.frag(完整 GLSL,自带 main/声明);
// 源码编译失败保留旧 shader(自愈),文件缺失 = 背景批直接上屏兜底。
package render

import gl "vendor:OpenGL"
import cv "../canvas"
import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"

// 默认背景 shader 文件(相对 src.exe 工作目录)
BG_SHADER_PATH :: "resource/shader/background.frag"

bg_shader_src : string // 当前源码(文件内容/Set 传入)
bg_program : u32 // 0 = 未编译
bg_u_bg, bg_u_screen, bg_u_time : i32

bg_fbo : u32
bg_tex : u32
bg_tex_w, bg_tex_h : u32

// 读取默认背景 shader 文件并编译(render.Init 调用;失败 = 打印警告)
InitBackgroundShader :: proc() -> bool {
	data, err := os.read_entire_file_from_path(BG_SHADER_PATH, context.allocator)
	if err != nil {
		fmt.eprintln("background shader missing:", BG_SHADER_PATH)
		return false
	}
	defer delete(data)
	return SetBackgroundShader(string(data))
}

// 重载默认背景 shader(修改 background.frag 后调用;失败 = 保留旧 shader)
ResetBackgroundShader :: proc() -> bool {
	return InitBackgroundShader()
}

// 设置背景 shader 源码(完整 GLSL;编译替换;失败 = 保留旧 shader,返回 false)
SetBackgroundShader :: proc(src : string) -> bool {
	prog := compileBgShader(src)
	if prog == 0 {
		fmt.eprintln("background shader compile failed; keeping previous")
		return false
	}
	if bg_program != 0 {
		gl.DeleteProgram(bg_program)
	}
	bg_program = prog
	bg_u_bg = gl.GetUniformLocation(bg_program, "uBg")
	bg_u_screen = gl.GetUniformLocation(bg_program, "uScreenSize")
	bg_u_time = gl.GetUniformLocation(bg_program, "uTime")
	if bg_shader_src != "" {
		delete(bg_shader_src)
	}
	bg_shader_src = strings.clone(src)
	return true
}

// 清理(render.Quit 调)
BackgroundShaderQuit :: proc() {
	if bg_shader_src != "" {
		delete(bg_shader_src)
		bg_shader_src = ""
	}
	if bg_program != 0 {
		gl.DeleteProgram(bg_program)
		bg_program = 0
	}
	if bg_tex != 0 {
		gl.DeleteTextures(1, &bg_tex)
		bg_tex = 0
	}
	if bg_fbo != 0 {
		gl.DeleteFramebuffers(1, &bg_fbo)
		bg_fbo = 0
	}
	bg_tex_w, bg_tex_h = 0, 0
}

compileBgShader :: proc(src : string) -> u32 {
	if main_vs == 0 {
		return 0
	}
	cs := strings.clone_to_cstring(src)
	defer delete(cs)
	return linkProgram(main_vs, compileShader(gl.FRAGMENT_SHADER, cs))
}

// 背景 pass(每帧,主批 flush 前):背景批 → FBO → 全屏 quad(bg shader)→ 屏幕
drawBackgroundPass :: proc(time_s : f32) {
	if bg_quad_count == 0 {
		return
	}
	if bg_program == 0 {
		if !InitBackgroundShader() {
			// 缺文件/编译失败:背景批直接上屏(纯色兜底,不引入模式开关);
			// 字形趟随后在主批,顺序不变
			gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
			flushBgBatch()
			return
		}
	}
	w, h := GetWindowSize()
	ensureBgTarget(w, h)

	// ① 背景批 → FBO(清 = 主题背景,与直接路径同底色)
	gl.BindFramebuffer(gl.FRAMEBUFFER, bg_fbo)
	gl.Viewport(0, 0, c.int(w), c.int(h))
	theme := cv.GetTheme()
	gl.ClearColor(
		f32(theme.bg >> 16 & 0xFF) / 255,
		f32(theme.bg >> 8 & 0xFF) / 255,
		f32(theme.bg & 0xFF) / 255,
		1)
	gl.Clear(gl.COLOR_BUFFER_BIT)
	flushBgBatch()

	// ② 全屏 quad(uv 上下翻转适配:FBO 行 0 = 屏幕底)→ 屏幕
	gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
	gl.UseProgram(bg_program)
	gl.Uniform1i(bg_u_bg, 0)
	gl.ActiveTexture(gl.TEXTURE0)
	gl.BindTexture(gl.TEXTURE_2D, bg_tex)
	gl.Uniform2f(bg_u_screen, f32(w), f32(h))
	gl.Uniform1f(bg_u_time, time_s)
	fs_quad := [6]Vertex{
		{0, 0, 0, 1, 1, 1, 1, 1}, {f32(w), 0, 1, 1, 1, 1, 1, 1}, {f32(w), f32(h), 1, 0, 1, 1, 1, 1},
		{0, 0, 0, 1, 1, 1, 1, 1}, {f32(w), f32(h), 1, 0, 1, 1, 1, 1}, {0, f32(h), 0, 0, 1, 1, 1, 1},
	}
	gl.BindVertexArray(vao)
	gl.BindBuffer(gl.ARRAY_BUFFER, vbo)
	gl.BufferData(gl.ARRAY_BUFFER, size_of(fs_quad), &fs_quad[0], gl.DYNAMIC_DRAW)
	gl.DrawArrays(gl.TRIANGLES, 0, 6)

	// 恢复 unit 0 绑回主批纹理(主批 flush 不重绑纹理,依赖最后一次 push 的绑定)
	if current_tex != 0 {
		gl.BindTexture(gl.TEXTURE_2D, current_tex)
	}
}

// 背景渲染目标(屏幕尺寸 RGBA8;尺寸变化才重建)
ensureBgTarget :: proc(w, h : u32) {
	if bg_tex != 0 && bg_tex_w == w && bg_tex_h == h {
		return
	}
	if bg_tex != 0 {
		gl.DeleteTextures(1, &bg_tex)
	}
	if bg_fbo != 0 {
		gl.DeleteFramebuffers(1, &bg_fbo)
	}
	gl.GenFramebuffers(1, &bg_fbo)
	gl.GenTextures(1, &bg_tex)
	gl.BindTexture(gl.TEXTURE_2D, bg_tex)
	gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, c.int(w), c.int(h), 0, gl.RGBA, gl.UNSIGNED_BYTE, nil)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
	gl.BindFramebuffer(gl.FRAMEBUFFER, bg_fbo)
	gl.FramebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, bg_tex, 0)
	gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
	bg_tex_w, bg_tex_h = w, h
}
