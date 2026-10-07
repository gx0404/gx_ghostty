# renderer：渲染线程、GPU 后端与着色器

## 范围

- `src/renderer.zig`、`src/renderer/**`：渲染线程、通用渲染器、Metal/OpenGL 后端、着色器、Kitty 图像、调试 overlay、DMABUF 帧导出。
- `pkg/opengl/**`（GL/EGL 绑定）、`pkg/glslang/**` 与 `pkg/spirv-cross/**`（自定义着色器编译链）、`pkg/wuffs/**`（图像解码与像素转换）、`vendor/glad/**`（生成的 loader）、根目录 `passthrough.glsl`。
- 相邻域：`pkg/**`、`vendor/**` 同归 `build-system.md`；字形与 atlas 见 `font.md`；`RenderState` 见 `terminal-core.md`；GTK 帧消费见 `apprt-gtk.md`。
- `src/renderer/size.zig` 同属 `libghostty-vt`：`src/input/mouse_encode.zig` 与 `src/terminal/c/mouse_encode.zig` 用它的 `Size` 换算鼠标坐标，经 `src/lib_vt.zig::input.MouseEncodeOptions` 进入 lib-vt 公开面。它在仓内只能依赖 `src/terminal/size.zig`（freestanding 约束见 `libghostty-vt.md`），改动后还要跑 `just test-vt` 与 `just vt-wasm`。

## 符号真源

- 后端（编译期唯一）：`src/renderer.zig::Renderer` 即 `GenericRenderer(GraphicsAPI)`，按 `build_config.renderer` 取 `Metal` 或 `OpenGL`；默认值 `src/renderer/backend.zig::Backend.default`（Darwin 为 `metal`，其余为 `opengl`），`-Drenderer` 在 `src/build/Config.zig` 覆盖。Metal 只支持 macOS/iOS 且要求 embedded apprt（`src/renderer/Metal.zig::init` 内 compileError）。
- `src/renderer.zig::Device`：app 级设备（`App.device`）；OpenGL 版持有 EGL surfaceless display 与 config，Metal 版持有共享 MTLDevice。
- `src/renderer/generic.zig::Renderer`：层次为 GraphicsAPI → Target → Frame → RenderPass/Step → Pipeline（见其文档注释）。`updateFrame` 做终端快照并 `rebuildCells`；`drawFrame` 同步帧数据、编码各 pass、最后跑自定义后处理链；`frameCompleted` 归还 swap chain 信号量，健康度变化时推 `renderer_health`。
- 后端实现：`src/renderer/OpenGL.zig` 要求 core profile，最低版本见 `MIN_VERSION_MAJOR`/`MIN_VERSION_MINOR`，离屏渲染后由 `present` 导出 `ExportedFrame`（`dmabuf` 或 `memory`）；`src/renderer/Metal.zig` 以 `IOSurfaceLayer` 输出，`loopEnter` 注册 CALayer display 回调，macOS 用 CVDisplayLink 做 vsync。两者各自声明 `swap_chain_count`（多缓冲帧数）。
- `src/renderer/Thread.zig`：`Mailbox` 是有界 `BlockingQueue`；async `wakeup`（可合并，drain mailbox 后更新并绘制）、`draw_now`（只绘制）、`stop`；定时器 `render_h`（只服务动画，按 `Renderer.animationWake`）、`cursor_h`（光标闪烁，间隔 `CURSOR_BLINK_INTERVAL`）、`Compression`（空闲后增量压缩 scrollback，只 `tryLock`，从不等锁）。
- 锁与消息：`src/renderer/State.zig`（`mutex` 与 `lockDemand`/`unlockDemand`/`yieldToDemand`）；`src/renderer/generic.zig::Renderer.draw_mutex`（保护 `drawFrame` 用到的全部状态）；`src/renderer/message.zig::Message`。
- 健康度：`src/renderer.zig::Health`（`c_int`），测试 `ghostty.h Health` 对照 `include/ghostty.h` 的 `GHOSTTY_RENDERER_HEALTH_*`；`presentation_health` 另记 apprt 能否呈现导出帧。
- 帧导出：`src/renderer/Dmabuf.zig`（plane 上限 `max_planes`，持有 fd）；`src/renderer/opengl/Target.zig::exportDmabuf` 经 EGLImage 导出，`readPixelsAlloc` 做 CPU 回读；GTK 的 `src/apprt/gtk/class/render_surface.zig::RenderSurface` 在主线程 `takeFrame`，导入失败经 `Surface.reportPresentationHealth` 回报 `unhealthy`。
- 着色器：`src/renderer/opengl/shaders.zig` 编译期 `@embedFile` 并展开 `src/renderer/shaders/glsl/` 的 `#include`；`src/renderer/metal/shaders.zig` 嵌入 `src/build/MetallibStep.zig` 用 xcrun 编出的 `ghostty_metallib`；`src/renderer/shadertoy.zig` 把 `src/renderer/shaders/shadertoy_prefix.glsl` 与用户 `mainImage` 拼接，经 glslang 编成 SPIR-V，再由 spirv-cross 转成后端要的 GLSL 或 MSL（`custom_shader_target`）。
- 图像：`src/renderer/image.zig::State`（kitty 三层放置与 overlay）；背景图由 `src/renderer/generic.zig::Renderer.prepBackgroundImage` 经 wuffs 解码；`src/renderer/Overlay.zig` 用 z2d 在 CPU 画 inspector 调试 overlay。
- GLAD：`pkg/opengl/glad.zig::context` 是 threadlocal；`src/build/SharedDeps.zig::add` 只给非 lib 产物编译 `vendor/glad/src/gl.c`，GTK 另编 `vendor/glad/src/glad_egl.c` 并链接 `egl`。

## 不变量

- **OpenGL context 单线程**：每个 surface 一个 EGL context。`OpenGL.init` 在主线程创建后立即释放 current；渲染线程在 `threadEnter` make current 并加载 threadlocal GLAD，`threadExit` 释放后主线程才在 `deinit` 销毁。GL 调用只能出现在渲染线程的 `threadEnter` 与 `threadExit` 之间，主线程没有 GLAD 上下文，调用任何 GL 函数都会崩溃（上游提交 `0fca3d34a` 因此删掉了 GTK imgui widget 的 GL 调用）。`src/Surface.zig::draw`（embedded apprt 的 `ghostty_surface_draw`）要求渲染器容许主线程同步 `drawFrame(true)`，只有 Metal 满足；GTK 不走这条路径，OpenGL 不得接到会调用它的宿主上。
- **GPU 资源归渲染线程**：`displayRealized`/`displayUnrealized` 在主线程运行，只在 `draw_mutex` 下改标志。swap chain 与 shaders 在 `drawFrame` 惰性重建；`releaseGpuResources` 在渲染线程释放 swap chain（不可见、未 realize、`threadExit` 时），shaders 只在未 realize 时释放；图像只在 `threadExit` 释放，免得遮挡后重传。
- **锁协议**：
  - `State` 成员（terminal、preedit、mouse、inspector）只在持 `State.mutex` 时读写。渲染快照用 `lockDemand`/`unlockDemand` 成对加解锁；误用 `mutex.unlock` 数据仍安全，但 `yieldToDemand` 一方会空等到超时。
  - 交接：`lockDemand` 先递增 `demand` 再加锁；`unlockDemand` 解锁后递增 `handoff_gen` 并 futex 唤醒。热循环（`src/termio/Exec.zig` 的解析线程）在两段临界区之间、未持锁时调 `yieldToDemand`：有排队者就等 `handoff_gen` 变化，最长 `handoff_timeout_ns`。这些原子量只是调度启发（monotonic），数据顺序由 mutex 保证。
  - 现有嵌套顺序是 `State.mutex` → `draw_mutex` → `SharedGrid.lock`（kitty 更新、`rebuildCells` 取字形、atlas 纹理同步），不得反向。`State` 临界区只做快照，重活放到锁外（`terminal_state.beginUpdate`/`endUpdate` 已按此拆分）。
  - `syncDisplayLink` 只在渲染线程且不持 `draw_mutex` 时调用：Metal 的 CALayer 回调会在主线程同步执行 `drawFrame(true)`，而停止 CVDisplayLink 是阻塞操作。
- **消息所有权**：
  - `font_grid`：发送方先 `SharedGridSet.ref` 新 key；渲染线程 `setFontGrid` 采纳后 `deref(old_key)`，采纳失败则保留旧 grid、改 deref `new_key`。换 grid 要清 shaper cache、把各帧 atlas 版本归零并 `markDirty`。
  - `change_config`：用 `Message.initChangeConfig` 构造；送达后 `Renderer.changeConfig` 接管 `impl` 的内容（先 deinit 旧配置），线程只 destroy 两个指针；`Message.deinit` 只用于未送达的消息。
  - `search_*` 的 arena 由渲染器接管，替换时 deinit 旧值；匹配可能指向已失效的 PageList 节点，用前要校验。
- **后端对等**：generic 层只依赖两个后端共有的类型（`Target`、`Buffer`、`Texture`、`Sampler`、`RenderPass`、`Pipeline`、`shaders`）与工厂函数，可选钩子用 `@hasDecl` 探测（`threadEnter`/`threadExit`、`loopEnter`/`loopExit`、`displayRealized`、`setViewport`）。uniform 与顶点结构成对维护：`src/renderer/opengl/shaders.zig` 对 `src/renderer/shaders/glsl/*.glsl`（std140），`src/renderer/metal/shaders.zig` 对 `src/renderer/shaders/shaders.metal`，`src/renderer/shadertoy.zig::Uniforms` 对 `shadertoy_prefix.glsl`（已有测试锁定部分偏移）。`custom_shader_y_is_down`（OpenGL 为 false、Metal 为 true）决定 GTK 是否翻转纹理。
- **Health 跨后端共享**：某后端到达不了的状态也保留；增值要同步 `include/ghostty.h`（见 `libghostty-embedding.md`）与 macOS app。
- **失败可降级**：自定义着色器加载或编译失败只记日志，退化为无后处理。只有 `presentation_health` 为 `healthy` 才尝试导出 DMABUF，失败即退回 CPU 回读；导出纹理必须是非 sRGB 的 RGBA8（Mesa 不能导出 sRGB），blit 时临时关闭 `GL_FRAMEBUFFER_SRGB`。OpenGL 的 `Frame.complete` 忽略 `sync`，帧经 `LatestFrame` 交给 apprt，只留最新一帧。
- **帧节奏**：常规渲染由 `wakeup` 驱动；`synchronized_output` 下 `updateFrame` 直接返回；不可见时动画全部暂停；动画唤醒间隔下限是 `draw_interval_ms`；`terminal_state` 按帧数定期整体重建以回收内存。
- **cell 缓冲**：`src/renderer/cell.zig::Contents.fg_rows` 不得用 `appendAssumeCapacity`（组合字符与多字形替换会超出初始容量）；`fg_rows[0]` 专用于光标，保证光标是 GPU 缓冲的首项。
- **wuffs 是共享依赖**：`src/build/GhosttyZig.zig` 在启用 kitty graphics 时把它接进 libghostty-vt（freestanding 目标不启用，见 `src/terminal/build_options.zig::Options.kittyGraphics`），因此不能依赖 libc：非 Windows 目标一律用 `pkg/wuffs/include/` 的极简头文件，未链接 libc 时导出弱符号 `calloc`/`free` 桩。
- **GLAD 生成物**：GL 部分（`vendor/glad/` 下的 `gl.{h,c}`）由根 `Makefile` 的 `glad` 目标解压 gen.glad.sh 产出的 `glad.zip`（已 gitignore）得到；EGL 部分（`glad_egl.{h,c}` 与随附的 `vendor/glad/include/EGL/eglplatform.h`）出自旧版 glad 生成器，是另行生成后加入的，`Makefile` 不管。两部分的生成器与参数都记在各自头文件注释里。`make glad` 先 `rm -rf vendor/glad`，会连带删掉 EGL 部分，并多写一个未入库的 `vendor/glad/include/glad/glad.h`。

## 禁止项

- 不在主线程、`threadEnter` 之前或 `threadExit` 之后调用 GL，不在主线程创建或销毁 GPU 资源。
- 不在持 `draw_mutex` 或 `SharedGrid.lock` 时获取 `State.mutex`；不在 `State` 临界区内做 shaping、大块分配或 I/O；不靠 sleep 或改 mutex 公平性解决饥饿。
- 不只改一个后端的 uniform、顶点结构或 pipeline 名；不调整 `Health` 既有值的顺序。
- 不手改 `vendor/glad/`（AI hook 也拦截写入）；重新生成后确认 EGL 文件仍在、新文件是否该入库，并审 diff。
- 不把 `passthrough.glsl` 当作代码依赖：没有代码引用它，它只是手工验证 `custom-shader` 时可用的直通样例。

## 验证

- 路由：`just rules src/renderer/generic.zig` 列出必读集合；改本文档后跑 `just framework-check`。
- 定向单测（以下都是纯 CPU 用例；`-Dtest-filter` 可重复，按测试名子串匹配，但仍要编出完整测试二进制，Windows 上属尽力而为）：
  - `just test -Dtest-filter=shader -Dtest-filter=spirv`：glslang/spirv-cross 链路与自定义 uniform 布局。
  - `just test -Dtest-filter=preedit -Dtest-filter=Contents -Dtest-filter=renderCellMap`：State、cell 缓冲与链接。
  - `just test -Dtest-filter=kitty`（Kitty 图像）；`just test -Dtest-filter=Health`（对照 `include/ghostty.h`）。
- 编译与格式：`just build` 在 Windows 只产出 `ghostty-internal` 库，GL/EGL 代码只编译不运行，上游 CI 不在 Windows 构建它，结果尽力而为；改 Zig 跑 `just fmt-check`。
- 改 `pkg/wuffs`：`just test-vt` 与 `just build-vt`（wasm32 不含 kitty graphics，`just vt-wasm` 覆盖不到它）；上游 CI 另在 `pkg/wuffs/` 下执行 `zig build test`，gx-ci 未覆盖，需手动补跑。
- PENDING（本机没有 GPU 呈现路径）：真实 GL 渲染、DMABUF 导入与截图交 gx-ci 手动触发的 `gtk-smoke`（输入 `gtk_smoke`），读回截图后才记 PASS；Metal 与 CVDisplayLink 交 gx-ci 的 `macos`（输入 `macos`）或 macOS 本机；完整单测以 gx-ci `linux` job 的 `zig build -Dapp-runtime=none test` 为准。
