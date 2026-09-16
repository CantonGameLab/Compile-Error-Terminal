# CompileErrorTerminal (CETerm)
CompileErrorTerminal (CETerm for short) is an open-source terminal emulator for Windows project maintained by a sub-studio under CantonGameLab.
It uses an OpenGL graphics API rendering pipeline and supports most features of modern terminal emulators, such as split panes, tab pages, window management, and keybindings. At the same time, we use a dirty flag mechanism to avoid the common drawback of rendering-based terminals consuming excessive CPU resources. 
On top of this, we implemented a fully scriptable terminal behavior control system through a simple parser. You can configure our terminal through the terminal scripting language we developed (config.ceterm) and implement the complete terminal control logic on top of it. Based on this scripting language, we also implemented support for OSC semantic sequences. Through a layer of OSC semantic wrapping, a process under a terminal window can interact with and control CETerm itself via stdin/stdout text streams + OSC 999.

The project is developed entirely in the Odin Programming Language, including program builds, test programs, and all program code. It can be regarded as a relatively large and very practical project in the Odin programming community.

The project is licensed under GPL v3.0, so you can use the project code fairly freely.

