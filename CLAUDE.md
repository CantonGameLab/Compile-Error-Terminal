# CompileErrorTerminal (CETerm) 项目规范

Windows 终端模拟器(Odin + SDL3 + OpenGL 4.4 core + ConPTY)。完整规范见 `docs/CODING_STYLE.md`(本文件为其精炼版);完整工程体系(含理论根基/检查清单)见 skill `dod-engineer`(`.dsh/skills/dod-engineer/SKILL.md`)。

## 编码规则

- **接口 = 不变式守卫**:数据有结构正确性约束(树:无环/单连通/父-子镜像/叶判定)时,用成套接口(树的 `linkSon/unlinkSon/replaceChild`)保证"经接口建/改必合法",禁止裸写结构字段;**孤立属性**(无约束单字段)不设接口,**禁止值拷贝 getter**(字段复制返回 = `NodeContentTransform` 式,一律删)。
- **局部性最大化**:算法(DFS/BFS/搜索)的辅助状态(表/栈/标记)与辅助过程全部定义在入口函数内部(迭代显式栈代替递归),不污染包命名空间;包级只留数据/接口/跨调用生命周期状态。
- **纯赋值/纯读取不提供接口**:数据获取 = 原结构体指针 Get(`GetTheme() ^Theme`)或句柄解码(`GetConsole/GetFont`)后直接读写字段;只有运算抽象(校验、clamp、联动副作用如重算布局)才暴露函数。
- **userapi 分层**:`Set<域>`/`Get<域>`/`Reset<域>` 家族是给用户的接口(命令栏/绑定/**main.initWindows 配置段落**),保留;程序内部代码不绕 userapi,一律 `GetXxx()` 指针直改数据。
- **禁止绕过池抽象**:不许 `池.data[句柄.id]` 直索引、不许手拼 `Handle{id, generation}`、不许裸读 `next/pool/generations`;句柄只能 `Alloc/AllocAt/GetHandle` 产出,取值 `Get/GetIndex`,枚举 `Alive(i)`+`GetIndex/GetHandle(i)` 配对。
- **引用计数纪律**(RefCounted 公用数据):`LoadFont` = +1,持有者释放 = -1(归零句柄失效、槽保留由 Alloc 复用);最后释放方做深析构;释放必须经模块封装(`ReleaseFont`),不许直接 `mem.Free`。
- 公开函数 PascalCase;外部库绑定(api.odin)不重命名。
- 函数间传 u32 id 句柄,count 从 1 起,0 = null/空槽。
- 注释精简,只写非显然逻辑(中文)。

## DOD 工程原则(Jonathan Blow 风格)

- **数据布局先行**:先想数据怎么存、怎么被遍历,再写操作它的代码。结构设计(布局)决定性能,算法其次。
- **无继承、无虚函数、无接口**:struct + 操作函数;需要多态时用 enum 判别 + switch,不用类型体操。
- **槽位数组 + id 句柄**:对象存定长数组,函数间传 id,不用指针跨层。数据连续、无悬挂、遍历局部性好。
- **预分配、避免热路径分配**:固定容量数组优先;动态数组按需扩容,不逐帧分配。
- **直白代码**:一个函数干一件事,变量就近声明,不做"为未来"的抽象;必要抽象在第二次出现时才做。
- **数据不动就不重算**:dirty 标志、增量计算;不为永远没发生的瓶颈写缓存。
- **显式优于隐式**:循环直接写,状态显式传递;禁止隐藏的全局状态机。
- **值语义**:小结构按值传,复制成本低就不传指针。
- **一次遍历只写一种数据**:每个循环(遍历)要么纯读收集、要么只更新单一数据结构;组合动作用显式分趟(收集 → 处理)或阶段拆解,禁止在同一循环里顺手改多种数据。
- **每帧路径分层**:编排入口(Update)按"数据种类"组织成固定有序的独立趟;跨趟传递用工作表(标记/索引表),不把副作用下压进遍历体。

## 构建

用户自行运行 `odin build src/`(生成 ./src.exe)并粘贴输出;Odin 库源码从项目 `reference/` 目录读取。
发布/分发包内的可执行文件名 = `ceterm.exe`(打包时 `odin build src/ -out:build/ceterm.exe`;开发构建仍用上面的命令)。
