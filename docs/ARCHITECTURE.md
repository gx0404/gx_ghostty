# 架构（gx_ghostty）

结构性事实地图：东西在哪、谁拥有状态、线程如何交互、哪些文件是生成的。规则在 `docs/AGENT_RULES/<id>.md`（`just rules <路径…>` 解析），开发闭环见 [DEVELOPMENT.md](DEVELOPMENT.md)，发版见 [RELEASE.md](RELEASE.md)，fork 功能清单与 WezTerm GX 的对照见 [GX_FEATURES.md](GX_FEATURES.md)。事实以源码为准，引用写 `path::symbol`；计数是快照（上游镜像 `main` 在 `b115e4567` 时 `git ls-files` 共 5915 个文件），同步后会漂移。

## 1. 定位与产物

fork 自 `ghostty-org/ghostty`，产品名 Ghostty GX。终端核心、渲染器、字体栈、GTK app 与 macOS app 跟随上游，fork 在其上增加四块：

- **Windows 原生应用**：win32 apprt（`src/apprt/win32.zig` 与 `src/apprt/win32/**`），移植自 MIT 许可的 shiweis/ghostty-windows@119b9270c（移植的文件头注明出处），之后按模块拆分并改写，界面改为 Direct2D 自绘（第 6 节）。配套的上游补丁：apprt 接线 GX-0003、WGL 渲染 GX-0004、termio 修正 GX-0005、win32-input-mode GX-0006、随包 ConPTY GX-0007、OSC 7 GX-0008、DirectWrite 字体发现 GX-0009。
- **GX 共享核心** `src/gx/`：配置分层与 GX 默认值、界面语言与翻译、启动配置、进程检查、关闭确认、herdr 应用模式、`gx:` 绑定动作，win32 与 GTK 两个 apprt 共用（第 7 节）。
- **GTK 的 GX 层** `src/apprt/gtk/gx/`：运行时切换界面语言、GX 菜单与启动配置、设置对话框、快捷键速查、herdr 应用模式与 GX 样式（第 8 节）。
- **打包、发布与开发框架**：Windows 便携 zip 与 Inno Setup 安装包、GX Shell 组件 stage、`gx-release` 发布链（第 13 节），以及 `docs/`、`scripts/`、`justfile` 组成的 AI 协作框架。

改动过的上游源码都登记为 fork 补丁，见 [FORK_PATCHES.md](FORK_PATCHES.md)（GX-0001～GX-0012、GX-0014～GX-0016、GX-0021、GX-0022，共 40 个上游文件；GX-0013 与 GX-0017～GX-0020 未使用）。Zig 版本 0.16.0（`build.zig.zon` 的 `minimum_zig_version`；`src/build/zig.zig::requireZig` 编译期要求 0.16.x，fork 经 `scripts/zigw.py` 钉死 0.16.0）。

| 产物 | 说明 | 根文件 / 构建逻辑 |
|---|---|---|
| `ghostty`（Linux、FreeBSD） | GTK 终端，含 GX 层 | `src/main_ghostty.zig::main`；`src/build/GhosttyExe.zig` |
| `ghostty.exe`（Windows） | win32 终端，GUI 子系统，经 `dist/windows/ghostty.rc` 嵌入图标与 manifest（per-monitor v2 DPI） | 同上；`src/build/GhosttyExe.zig::init` 的 Windows 分支 |
| `Ghostty.app` | macOS Swift 应用（上游原样），静态链接 `macos/GhosttyKit.xcframework` | `macos/`；`src/build/GhosttyXCFramework.zig`、`src/build/GhosttyXcodebuild.zig`；日常用 `macos/build.nu` |
| libghostty-internal | 完整核心的嵌入式 C API `include/ghostty.h`（历史名 libghostty），只服务 macOS app | `src/main_c.zig`；`src/build/GhosttyLib.zig` |
| libghostty-vt | 可独立嵌入的终端仿真库：C 头 `include/ghostty/`、Zig 模块 `ghostty-vt`/`ghostty-vt-c`、`ghostty-vt.wasm`；API 未稳定但按 ABI 友好设计 | `src/lib_vt.zig`；`src/build/GhosttyZig.zig`、`src/build/GhosttyLibVt.zig` |

| 目标 | 默认 apprt / 渲染 / 字体 | 主要产物 | fork 的构建与验证 |
|---|---|---|---|
| Linux、FreeBSD | `gtk` / OpenGL（EGL）/ `fontconfig_freetype` | `bin/ghostty`、`share/` 资源、libghostty-vt | gx-ci `linux-main`（`-Dapp-runtime=none`）与手动 `gtk-smoke`；本机经 `just wsl`；FreeBSD 没有 CI |
| Windows | `win32`（GX-0003）/ OpenGL（WGL，GX-0004）/ `freetype_windows`（DirectWrite 发现，GX-0009）；gettext i18n 关闭 | app 按 `x86_64-windows-gnu` 构建（`just build` 自动补目标）：`bin/ghostty.exe`、`share/`，同时装 libghostty-vt；`-Demit-lib-vt` 只出库 | gx-ci `windows`（lib-vt）与 `windows-app`（构建，手动 `win_smoke` 截图）；本机 `just build`、`just test`、桌面截图 |
| macOS | `none`（internal 库用 `embedded`）/ Metal / `coretext` | `GhosttyKit.xcframework`、`Ghostty.app`（`-Demit-macos-app=false` 可跳过）、libghostty-vt | 手动 gx-ci `macos`（lib-vt 单测）；`gx-release` 的 `macos=true` 构建未签名 app |
| iOS、Android | — | 只有 libghostty-vt（全量构建遇 iOS 报 `UnsupportedTarget`） | 无 |
| wasm32-freestanding | — | 只有 libghostty-vt：`bin/ghostty-vt.wasm` 与静态归档 | gx-ci `lib-vt-cross` |
| 其他 freestanding | — | 只有静态 libghostty-vt 与头文件 | 无（上游 CI 已归档） |

默认值来自 `src/apprt/runtime.zig::Runtime.default`、`src/renderer/backend.zig::Backend.default`、`src/font/backend.zig::Backend.default` 与 `src/build/Config.zig::init`。Windows 目标没写 ABI 时 `Config.init` 强制 MSVC（要求 Visual Studio 与 Windows SDK）；app 只验证过 GNU ABI（`-Dtarget=x86_64-windows-gnu`，用 Zig 自带的 MinGW 头文件与导入库），MSVC ABI 的 app 构建未验证。各层证据见 [TESTING.md](TESTING.md)。

## 2. 仓库布局

| 路径 | 文件数（上游） | 角色 |
|---|---:|---|
| `src/` | 1015 | 共享 Zig 核心，见下 |
| `test/` | 4024 | 树外测试：`fuzz-libghostty/`（AFL++，语料 4002 个）、`esctest/`、`windows/`、`wasm-alloc.mjs` |
| `macos/` | 271 | Swift app（`Sources/` 177 个）、Xcode 工程、`build.nu` |
| `pkg/` | 234 | 23 个树内 Zig 包，封装 C/C++ 依赖与平台 SDK |
| `example/` | 133 | 35 个 libghostty-vt 示例，CI 按 `example/*/build.zig.zon` 发现 |
| `include/` | 37 | `ghostty.h`、`module.modulemap`；`ghostty/vt.h` 与 `ghostty/vt/` 下 34 个头 |
| `po/` | 37 | `com.mitchellh.ghostty.pot` 与 34 个 `.po` |
| `images/`、`nix/`、`.github/`、`dist/` | 34、33、24、21 | 图标；nix 环境与 VM 测试；上游 CI（已归档）与脚本；分发模板 |
| `vendor/`、`flatpak/`、`snap/`、`.agents/` | 9、5、2、2 | GLAD 与 nerd-fonts patcher；打包清单；上游 agent 命令与 skill |
| 根文件 | 34 | `build.zig`、`build.zig.zon` 及派生文件、`CMakeLists.txt`、`Doxyfile`、`Makefile`、nix 入口、lint 配置、上游文档 |

`src/` 内（上游）：顶层 31 个（入口、`App.zig`、`Surface.zig`、`global.zig`、各包入口）；`build/` 281（含 236 个 `+boo` 动画帧）；`terminal/` 203（含 C API `c/`）；`font/` 116；`apprt/` 92；`renderer/` 52；`os/` 34；`cli/` 30；`config/` 24；`lib/` 22；其余 13 个子目录各 3–20 个。路径归属以 `docs/AGENT_RULES/routes.toml` 为准。

fork 新增的路径（上游没有，同步时不冲突）：

- 源码：`src/apprt/win32.zig` 与 `src/apprt/win32/**`（win32 apprt，含 `chrome/`、`ui/`、`ui/settings/`）；`src/gx/**`（共享核心，含 `i18n/`、`themes/`、两份 `defaults*.ghostty`）；`src/apprt/gtk/gx/**` 与 `src/apprt/gtk/ui/1.5/gx-settings-dialog.blp`、`src/apprt/gtk/ui/1.5/gx/menus.blp`（GTK 的 GX 层）；`src/font/directwrite/**`（DirectWrite 发现，`com.zig` 与 `discovery.zig` 移植自 shiweis/ghostty-windows）；`src/renderer/opengl/wgl.zig`。这些是新文件，不是补丁，只经登记过的补丁接进上游代码。
- 分发：`dist/windows/gx/`（Inno Setup 脚本 `ghostty-gx.iss` 与随包第三方组件的许可证）。
- 框架：`docs/`、`scripts/`、`justfile`、`CLAUDE.md`、`CHANGELOG.md`、`.claude/`、`.codex/`、`.zcode/`、`.githooks/`、`.graphifyignore`、`graphify-out/`、`.github/workflows/gx-*.yml`、`.github/workflows-archive/`（上游 15 个 workflow 原样归档）；本机状态在 gitignored 的 `.local/`。

## 3. 入口与构建产物

Zig 不允许 `main` 所在文件位于模块根目录的子目录，所以所有 exe 共用 `src/main.zig`，由编译期选项 `exe_entrypoint`（`src/build/Config.zig::ExeEntrypoint`）挑出真正入口；`src/build_config.zig::Artifact.detect` 区分 `exe`、`lib`、`wasm_module`。

| 根文件 | 产出 |
|---|---|
| `src/main.zig::entrypoint` | `ghostty` → `src/main_ghostty.zig`；`helpgen` → `src/helpgen.zig`；`mdgen_*` → `src/build/mdgen/`；`webgen_*` → `src/build/webgen/`；也是完整单测 `ghostty-test` 的根 |
| `src/main_c.zig` | libghostty-internal；编译期断言 apprt 为 `embedded`，并引用各 `CApi` 使其导出 |
| `src/lib_vt.zig` | libghostty-vt；只在作为根模块时 `@export` C 符号，按 `terminal_options` 特性门裁剪 |
| `src/main_build_data.zig::Action` | 宿主工具 `ghostty-build-data`：shell 补全、编辑器语法、terminfo |
| `src/main_bench.zig`、`src/main_gen.zig` | `ghostty-bench`、`ghostty-gen`（`-Demit-bench`） |
| `src/main_wasm.zig` | 整应用 wasm 入口（配 `src/apprt/browser.zig` 桩），当前无构建脚本引用 |

启动：`src/main_ghostty.zig::main` 先 `global.init` 建立进程级状态（分配器、`std.Io`、日志、sentry、locale、资源目录、i18n 等）；有 `+action` 时执行后退出；`app_runtime == .none` 时打印 CLI 用法退出；否则 `App.create` → `apprt.App.init` → `run`。win32 构建的 `logFn` 另把每条日志追加到 `%LOCALAPPDATA%\ghostty\logs\ghostty.log`（GX-0003，`src/apprt/win32/file_log.zig`）。嵌入方依次调 `ghostty_init`、`ghostty_cli_try_action`、`ghostty_app_new`。

`build.zig` 的步骤：默认 `install`；`run`、`run-valgrind`；`test`、`test-valgrind`（完整单测，`-Demit-lib-vt` 时为空步骤；macOS 上不带 `-Dtest-filter` 的 `test` 还挂上 macOS app 的 `xcodebuild test`）；`test-lib-vt`、`test-lib-vt-build`；`test-lib-vt-schema`（调 `python3` 校验 ABI 清单）；`update-translations`；`dist`、`distcheck`；以及 GX-0002 新增的 `test-lib-vt-bin`、`test-bin`：只编译并把 `test-lib-vt`、`test` 用的同一批测试二进制装到 `zig-out/test/`（`vt/`、`vt_c/` 与 `ghostty-test`），不运行，由 `scripts/zig_test.py` 按 Zig 测试运行器协议分片到多个进程（`just test-vt`、`just test`）。默认 `install`：`app_runtime != none` 时装 app 与资源（Windows 为 `ghostty.exe`）；为 `none` 时非 Darwin 装 libghostty-internal 与 `ghostty.h`，macOS 主机出 xcframework 并经 xcodebuild 出 `Ghostty.app`；非 freestanding 目标总会装 libghostty-vt 共享库与静态库（Windows 静态库改名 `ghostty-vt-static.lib`，避开 DLL 导入库）。`-Demit-lib-vt` 是库专用模式，关闭 exe、文档、macOS app 与 internal 库，本仓被当作依赖时默认开启。

选项全集在 `src/build/Config.zig::init`，经 `Config.addOptions` 写入 `build_options`、运行期由 `src/build_config.zig` 读取；libghostty-vt 另有 `src/terminal/build_options.zig::Options`（含 `-Dvt-features`）。`src/build/SharedDeps.zig::add` 把 C 依赖与构建期生成模块挂到 libghostty-internal、`ghostty` exe、`ghostty-test` 与 bench 工具的编译步骤（libghostty-vt 只用 `SharedDeps.addSimd`）。上游在这里对所有目标 translate-c 导入 `posix_c`（含 `pwd.h`），Windows 上因此编不出任何非 vt 产物；GX-0003 让 Windows 目标跳过这个导入（与上游 PR #14608 的守卫相同），并给 win32 apprt 链接 Win32 系统库（含 Direct2D 的 `d2d1` 与 `dwrite`）。此后按 GNU ABI 能构建 win32 app、`ghostty-test` 与 `-Demit-bench` 的工具；`-Dapp-runtime=none` 的 libghostty-internal 在 Windows 上仍链接失败（缺 glad 的 `gladLoadGLContext` 等符号，见 `docs/AGENT_RULES/build-system.md`「平台」），Windows 上没有可用的嵌入库。

## 4. 核心对象与所有者

核心 `App` 由 `src/main_ghostty.zig::main` 创建（嵌入时由 `ghostty_app_new` 创建），由 apprt 的 App 驱动；核心 `Surface` 的内存归 apprt 的 Surface（GTK 部件、win32 终端子窗口的包装 `src/apprt/win32/Surface.zig`，或嵌入方视图）。

```text
App（src/App.zig）
├─ surfaces          []*apprt.Surface，只存指针
├─ mailbox           BlockingQueue(App.Message, 64)，主线程 tick 时 drain
├─ font_grid_set     font.SharedGridSet，同字体配置的 surface 共享网格（引用计数）
└─ device            renderer.Device，各 surface 的渲染器借用，最后释放（Windows 上是 wgl.Device）
Surface（src/Surface.zig）
├─ io                termio.Termio：拥有 terminal（终端模型）、terminal_stream、Exec 后端、termio mailbox
├─ io_thread         termio 写线程
├─ renderer          GenericRenderer(Metal | OpenGL)，内含 draw_mutex
├─ renderer_state    renderer.State：mutex + 指向 io.terminal 的指针 + inspector、preedit、mouse
├─ renderer_thread   渲染线程与其 mailbox
├─ search、inspector 按需创建
├─ gx_win32_key      本次按键的 Win32 消息（GX-0006，只有 win32 apprt 填写）
└─ config            DerivedConfig，从 Config 复制的私有副本（含 GX-0012 的 gx_idle_processes）
```

- **apprt**：`src/apprt.zig::runtime` 编译期选定唯一实现（exe 为 `none`、`gtk` 或 `win32`，lib 为 `embedded`，`wasm_module` 为 `browser` 桩）；核心经 `performAction` 把 `src/apprt/action.zig::Action` 交给它执行。GX 绑定动作不进这张表：`Surface.performBindingAction` 遇到 `.gx` 直接调 apprt 的 `gxAction`（GX-0014，win32 与 GTK 实现）。
- **termio / terminal**：termio 的 Backend 只有 `Exec`（子进程与 pty；Windows 为 ConPTY，exe 旁有随包 `conpty.dll` 与 `OpenConsole.exe` 时优先用它，GX-0007）；`src/terminal/main.zig` 与渲染、pty 无关，libghostty-vt 直接复用，C API 只在 `options.c_abi` 时编入。
- **renderer / font / input**：`src/renderer.zig::Renderer` 按 `build_config.renderer` 选 Metal 或 OpenGL；字体后端由 `src/font/backend.zig::Backend` 选定（Windows 的 `freetype_windows` 发现改走 `src/font/directwrite/`，GX-0009）；`src/input.zig` 的 `key_encode`、`mouse_encode`、`paste` 与 libghostty-vt 共用（`src/lib_vt.zig::input`）。
- **config**：`src/config/Config.zig::Config` 的字段名即配置键。`Config.load` 默认转交 `src/gx/config_layers.zig::load` 做 GX 分层（GX-0010，第 7 节），GTK、win32 与 CLI 动作都经它加载；macOS app 经 C API（`ghostty_config_load_default_files` 等）分步加载，不经过 GX 分层。`App.updateConfig` 只在主线程调用，经 `Surface.updateConfig` 重建派生配置、下发新字体网格，再向渲染线程与 termio 各发 `change_config`。
- **全局状态**：`src/global.zig` 保存分配器、`std.Io`、环境、资源目录与 CLI action，每个进程只 `global.init` 一次。

## 5. 线程模型与数据流

| 线程（名称） | 创建者 | 职责 |
|---|---|---|
| 主线程（GUI 线程） | GTK：`src/apprt/gtk/class/application.zig::Application.run` 每轮 `App.tick`。win32：`src/apprt/win32/App.zig::run` 的 `GetMessageW` 循环，其他线程经 `App.wakeup` 向消息专用窗口投递 `WM_APP_WAKEUP`，处理时调 `App.tick`。macOS：主队列调 `ghostty_app_tick` | 事件、`App.drainMailbox`、`Surface.handleMessage`、surface 创建销毁；win32 的全部窗口、自绘界面、计时器与模态循环 |
| `io` 写线程 | `Surface.init` → `src/termio/Thread.zig::threadMain` | xev 循环（Windows 上 libxev 用 IOCP）：写 pty、resize（合并 25 ms）、各类报告、同步输出 1 s 超时复位、termios 轮询 |
| `io-reader` | `src/termio/Exec.zig::threadEnter` 在 io 线程上启动 `ReadThread` | `Termio.processOutput` 持锁解析；Windows 上读 ConPTY 输出管道，管道断开或 EOF 时记日志后退出（GX-0005） |
| `io-gather` | `ReadThread` 的 POSIX 路径 | 把 pty 读进 4 个 64 KiB 轮转缓冲；Windows 上读与解析是同一线程 |
| `renderer` | `Surface.init` → `src/renderer/Thread.zig::threadMain` | xev 循环：drain mailbox → `updateFrame` → `drawFrame`；光标闪烁、动画、空闲压缩；Windows 上 WGL 上下文在这个线程创建、使用与销毁 |
| `search` | 首次 `.search` 绑定动作（`Surface.performBindingAction`） | `src/terminal/search/Thread.zig::threadMain`，结果经 `Surface.searchCallback` 回送 |

另有预热等辅助线程。win32 apprt 自己不建线程：标签标题轮询、herdr 应用模式检查、剪贴板重试、通知图标都用 GUI 线程的 `WM_TIMER`；菜单与对话框跑模态消息循环，循环中照常分发其他消息，所以调用方返回后要重新解析可能已被释放的指针（`src/apprt/win32/ui/Dialogs.zig`、`src/apprt/win32/ui/MenuPopup.zig` 的模块文档）。ConPTY 的控制台宿主（`OpenConsole.exe` 或系统 conhost）是独立进程。

队列都是 `src/datastruct/blocking_queue.zig::BlockingQueue`：容量 64、内部 mutex、无阻塞 pop，靠事件循环唤醒。

| 队列 | 方向 | 典型消息 |
|---|---|---|
| `src/App.zig::Mailbox` | 任意线程 → 主线程，`rt_app.wakeup()` 唤醒 | `new_window`、`close`、`quit`、`surface_message` |
| `src/apprt/surface.zig::Mailbox` | 各线程 → 主线程 `Surface.handleMessage`（包成 `surface_message` 走 App 队列） | `set_title`、剪贴板、`child_exited` |
| `src/termio/mailbox.zig::Mailbox` | 主线程（`Surface.queueIo`）与 `io-reader` → `io` | `write_*`、`resize`、`change_config`、`focused` |
| `src/renderer/Thread.zig::Mailbox` | 主线程、`io-reader`、搜索回调 → `renderer` | `resize`、`change_config`、`font_grid`、`visible` |
| `src/terminal/search/Thread.zig::Mailbox` | 主线程 → `search` | `change_needle`、`select` |

**输出路径**：pty →（POSIX 经 `io-gather`）`io-reader` → `src/termio/Termio.zig::processOutput` 加锁，`queueRender` 唤醒渲染线程（唤醒句柄按指针传递，GX-0005；按值复制时 IOCP 的 `Async` 唤不醒），把字节喂给 `terminal_stream` → `terminal.Stream(StreamHandler)` 更新 `Terminal`/`Screen`/`PageList`，回写 pty 的响应进 termio 队列，标题、剪贴板等进 surface 消息 → 解锁，批次间 `yieldToDemand` → `src/renderer/generic.zig::Renderer.updateFrame` 在 `lockDemand` 内只做快照（`RenderState.beginUpdate` 等；同步输出模式跳过本帧），锁外 `endUpdate`、重建 cell，再 `drawFrame`。

**帧的呈现**：`drawFrame` 画进离屏 render target，`src/renderer/opengl/Frame.zig::complete` 调 `src/renderer/OpenGL.zig::present`，此后两个平台分开：

- Linux GTK（EGL，上游）：OpenGL 上下文来自 surfaceless EGL display，`present` 把 target 导出为 DMABUF（导出失败或 apprt 报告呈现不健康时退回 CPU 像素 `ExportedFrame.memory`），帧进队列并向 surface 推 `.redraw`；GTK 主线程在 `src/apprt/gtk/class/render_surface.zig` 的快照回调里取帧交给 GTK 合成，渲染线程从不碰 GTK。
- Windows（WGL，GX-0004）：每个终端是一个 `CS_OWNDC` 子窗口，apprt 建窗时调一次 `wgl.Device.setPixelFormat`；`OpenGL.init` 在主线程只记录 HDC，渲染线程的 `threadEnter` 建 OpenGL 4.3 core 上下文并 current（NVIDIA 线程化驱动的 `wglMakeCurrent` 瞬时失败时最多重试 20 次）。`present` 转 `src/renderer/opengl/wgl.zig::Context.present`：把 target blit 到窗口默认 framebuffer 后 `SwapBuffers`，`ExportedFrame` 为 `void`、不推 `.redraw`；随后 `Surface.signalFrameDrawn` 置事件，拖动改尺寸时 GUI 线程最多等 16 ms 新尺寸的帧（`src/apprt/win32/Surface.zig::resize_frame_timeout_ms`），新窗口在第一帧呈现前保持 DWM cloak（最长 `src/apprt/win32/Window.zig::first_frame_timeout_ms`，300 ms），所以不会闪白。驱动由 `wgl.Device.init` 进程级选一次：系统驱动建不出 4.3 core 上下文时改用 exe 旁 `mesa\opengl32.dll`（Mesa llvmpipe），`GHOSTTY_GX_OPENGL=software` 直接用 Mesa，都不可用时弹窗说明，`App` 初始化以 `DeviceFailed` 失败。驱动支持 `WGL_ARB_create_context_robustness` 时，GPU 重置后 `present` 重建上下文并调 `Surface.gpuContextReset` 让渲染器重建 GPU 资源。像素格式带 8 位 alpha，帧里保留渲染器写的预乘 alpha（终端背景为 `background-opacity`，字形、光标、选区与图片为 1）；`wgl.Device.alphaFrames` 报告系统驱动与 alpha 格式时，Windows 11 22H2 起有材质或 `background-opacity` 小于 1 的顶层窗口调 `DwmEnableBlurBehindWindow`（空区域），DWM 就按这个 alpha 合成整个客户区（WGL 子窗口一起），材质或桌面从终端背景透出（`src/apprt/win32/chrome/Backdrop.zig`）。
- macOS（Metal，上游）：`Surface.draw` 允许嵌入方在主线程调 `drawFrame`（resize 时），由 `draw_mutex` 保护。

**输入路径**：apprt 事件 → `App.keyEvent`（全局与 app 级绑定）→ `Surface.keyCallback`（绑定未命中则 `input.key_encode` 编码）→ `Surface.queueIo` → `io` 线程写 pty。win32 apprt 改调 `Surface.gxWin32KeyCallback`：它记下这次的 Win32 消息再进 `keyCallback`，终端开着 win32-input-mode（DECSET 9001，ConPTY 启动时开启）且没有 kitty 键盘标志时，`encodeKey` 改写 `CSI Vk;Sc;Uc;Kd;Cs;Rc _` 记录（GX-0006，`src/gx/win32_input.zig`）。输入法：预编辑经 `preeditCallback` 画在光标处，候选窗按 `Surface.imePoint` 定位。鼠标经 `mouseButtonCallback`、`cursorPosCallback`、`scrollCallback` 编码上报或持锁改选区。

**锁协议**（`src/renderer/State.zig`）：

- `mutex` 保护成员指向的数据（terminal、inspector、preedit、mouse），State 本身不是线程安全的；`io-reader`、`io`、主线程、`renderer`、`search` 都会持锁。
- 防饿死：mutex 不公平，热循环解锁后立刻重锁会一直赢过沉睡的等待者。渲染线程用 `lockDemand`/`unlockDemand`（demand 计数 + futex 交接），热循环在批次间 `yieldToDemand`，最多让 1 ms。
- 持锁投递：持锁向满队列阻塞 push 会与等这把锁的消费者互等，所以 `src/termio/mailbox.zig::Mailbox.send` 的 `mutex` 参数与 `src/termio/stream_handler.zig::StreamHandler` 的三个 `*Writer` 都先立即 push，失败才临时解锁再阻塞 push（termio、渲染两路还会先唤醒消费者）。
- scrollback 压缩（`src/renderer/Thread.zig::Compression`）只在空闲 250 ms 后 `tryLock` 做一步，从不等锁。
- OpenGL：上下文同一时间只在一个线程 current。EGL 上下文在主线程创建后即释放，渲染线程重新绑定；WGL 上下文只在渲染线程创建与使用，主线程从不调 GL。主线程调 `drawFrame` 只发生在 embedded apprt（macOS/Metal 的 resize）；GTK 与 win32 都不调用它。
- 关闭：`Surface.deinit` 依次停止并 join 搜索、渲染、io 线程（`Exec.threadExit` 经退出管道结束读线程，Windows 上用 `WriteFile`/`CloseHandle` 操作这个 Win32 句柄，GX-0005），最后释放共享状态。

## 6. Windows 应用（win32 apprt）

| 模块（`src/apprt/win32/` 下） | 职责 |
|---|---|
| `../win32.zig` | apprt 入口，导出 `App`、`Surface` 等 |
| `App.zig` | 三个窗口类（容器 `GhosttyWindow`、终端 `GhosttyTerminal`（`CS_OWNDC`）、消息专用 `GhosttyMsg`）、消息循环 `run`、`performAction`、`gxAction`/`performGx`、未配置 `command` 时的默认启动配置（`updateDefaultCommand`）、配置重载、托盘通知、全局热键、退出计时 |
| `Window.zig` | 顶层容器：标签模型（每个标签一棵 split 树）、分屏布局 `layoutSplits`、DPI、窗口位置（约占所在显示器工作区 80%，多窗口依次错开）与首帧 cloak、herdr 应用模式 `updateAppMode`、关闭确认 |
| `Surface.zig` | 终端子窗口：键鼠、IME、拖放（路径经 `gx.path_quote` 按 shell 引用）、剪贴板（被占用时计时器重试）、弹层宿主（命令面板、查找栏、链接预览）、`signalFrameDrawn`/`gpuContextReset` |
| `QuickTerminal.zig`、`Scrollbar.zig` | 从屏幕边缘滑出的快速终端；主题化细滚动条 |
| `file_log.zig`、`win32.zig` | 日志文件；手写 Win32 类型与 extern 声明 |
| `chrome/TitleBar.zig` | 非客户区与集成标题栏：`WM_NCCALCSIZE` 把客户区延伸到标题栏，`WM_NCHITTEST` 报 `HTCAPTION`、`HTTOP` 与 `HTMINBUTTON`/`HTMAXBUTTON`（Windows 11 贴靠布局）/`HTCLOSE`；`window-decoration` 各模式、全屏；整行用 Direct2D 画进带逐像素 alpha 的 32bpp DIB 再贴到窗口 |
| `chrome/TabBar.zig` | 标题栏行里的标签页：绘制、命中测试、拖动排序、右键菜单、双击改名、未读圆点、`程序 ~ 标题` 标签 |
| `chrome/Backdrop.zig` | DWM 深浅色与边框色、`gx-window-material`（`mica`/`acrylic`/`tabbed`，Windows 11 22H2 起，标题栏一行延伸 DWM 边框，此时标题栏按钮交给 DWM 绘制）、按像素合成（`perPixel`：材质与 `background-opacity` 从终端背景透出；GDI 不写 alpha，窗口自己画的部分经 `fillBackground`、`fillOpaque` 贴预乘 DIB）、退路（更早的系统、Mesa、无 alpha 格式：`background-opacity` 整窗 `WS_EX_LAYERED`）、`background-blur`（只用于纯色材质） |
| `ui/d2d.zig`、`ui/style.zig` | 手写的 Direct2D 1.1/DirectWrite COM 绑定与 `Canvas`（`Factory` 由 `App.uiFactory` 持有，只在 GUI 线程使用）；从终端主题推导的设计令牌 |
| `ui/Popup.zig` | 可复用的自绘弹出窗口：属主窗口、DWM 圆角与系统阴影、按显示器 DPI、键鼠、带 IME 的单行输入 |
| `ui/MenuPopup.zig`、`ui/Menu.zig` | Windows 11 风格的主题化弹出菜单（子菜单、键盘导航、靠屏幕边缘翻转）；主菜单、启动配置菜单、标签页与终端右键菜单 |
| `ui/Palette.zig`、`ui/fuzzy.zig`、`ui/trigger.zig`、`ui/Keybinds.zig` | 命令面板（分组、中英文模糊匹配、本次运行内的 frecency、主题预览）；按键显示与反查；快捷键速查表 |
| `ui/Settings.zig`、`ui/settings/*.zig` | 设置浮层：模态、背后变暗，六个分区，改动写入 `gui-settings.ghostty` 后重载 |
| `ui/Dialogs.zig` | 主题化模态对话框：关闭与退出确认（列出仍在运行的进程）、剪贴板授权与不安全粘贴（带预览）、子进程退出、关于；任务模态，嵌套上限 4 层，对话框期间推迟 `WM_CLOSE`；另存为用系统对话框 |
| `ui/SearchBar.zig`、`ui/LinkPreview.zig`、`ui/ResizeOverlay.zig`、`ui/wstr.zig` | 查找栏（`当前/总数` 计数）、链接预览气泡、改尺寸时的列×行提示；UTF-8 → UTF-16 |

- 启动：`App.init` 用 `Config.load` 加载配置（GX 分层）、修复资源管理器传来的盘符根目录工作目录、按 `language` 设定界面语言、注册窗口类与消息专用窗口；`App.run` 建第一个窗口与标签后进入消息循环。终端子窗口的按键消息跳过 `TranslateMessage`（由 `handleKeyEvent` 自己调 `ToUnicode`，避免死键状态被改两次），只有 `VK_PROCESSKEY`（交给输入法）与 `VK_PACKET`（`SendInput` 注入的 Unicode）照常翻译。
- 界面文字全部经 `gx.i18n`（Windows 构建没有 gettext），语言切换时窗口、菜单、命令面板与设置浮层当场重建文字。
- 测试钩子：向窗口 `SendMessage` `src/apprt/win32/Window.zig::WM_GHOSTTY_SIMULATE_DPI` 走一遍 DPI 变化路径，向终端子窗口发 `src/apprt/win32/Surface.zig::WM_GHOSTTY_SIMULATE_GPU_RESET` 让渲染器把下一帧当作 GPU 重置处理；用法见 [TESTING.md](TESTING.md)。

## 7. GX 共享核心与配置分层

`src/gx/main.zig` 汇总共享模块，单测经 GX-0010 在 `src/config/Config.zig` 里的 `test` 块进入 `ghostty-test`：

| 模块 | 作用 |
|---|---|
| `config_layers.zig`、`config_types.zig`、`defaults.ghostty`、`defaults-windows.ghostty`、`theme.zig`、`themes/` | 配置分层（下文）、`gx-*` 键的值类型、内嵌的 GX 默认值、内置主题 `GX Mocha` |
| `gui_settings.zig`、`settings_map.zig` | 设置界面的覆盖文件 `gui-settings.ghostty`（逐行编辑、原子替换）；与界面无关的设置模型（选项、写入的键、待保存的改动） |
| `i18n.zig`、`i18n/gx.zh_CN.po`、`i18n/zh_CN.zig` | 界面语言（`zh-CN`/`en`，进程级，可运行时切换）与 zh-CN 译表；译表由 `just i18n` 从 `po/zh_CN.po` 与 `gx.zh_CN.po` 生成 |
| `profiles.zig` | 启动配置探测（Windows：GX Zsh、herdr、PowerShell 7、Windows PowerShell、命令提示符、Git Bash、MSYS2 UCRT64、Nushell、各 WSL 发行版；Linux：GX Zsh、herdr、登录 shell、zsh、bash、fish）加 `gx-launch-profile`，以及默认启动配置的顺序 |
| `proc.zig`、`policy.zig`、`confirm.zig`、`app_mode.zig` | 列进程（Linux `/proc`，Windows Toolhelp32）、空闲进程策略、关闭确认（GX-0012）、herdr 应用模式判定 |
| `action.zig` | `gx:<name>[:<argument>]` 动作的类型、解析与格式化（GX-0014） |
| `win32_input.zig`、`conpty.zig`、`osc7.zig`、`path_quote.zig` | Windows 终端支持：KEY_EVENT_RECORD 编码（GX-0006）、随包 ConPTY（GX-0007）、OSC 7 路径转换（GX-0008）、拖放路径的 shell 引用 |
| `gtk_css.zig` | 由终端主题生成 GTK 的 GX 配色 CSS（GX-0016） |

**配置分层**（`src/gx/config_layers.zig`，GX-0010）：从低到高依次是内嵌的 GX 默认值（`defaults.ghostty`，Windows 另加 `defaults-windows.ghostty`）、用户配置文件及其 `config-file` 引入的文件、设置界面写的 `gui-settings.ghostty`（与用户配置在同一目录）、命令行（`-e` 及其命令最后）。各文件仍按上游顺序读取，重放步骤再按层排序重建，所以主题加载与明暗切换的重放保持层序；某层设置 `font-family*` 时替换而不是追加低层的列表。环境变量 `GHOSTTY_GX_DEFAULTS=0`（或 `false`、`off`、`no`）时按上游方式加载。配置目录：Linux 为 `$XDG_CONFIG_HOME/ghostty`（缺省 `~/.config/ghostty`）；Windows 为 `%XDG_CONFIG_HOME%\ghostty`，未设时 `%LOCALAPPDATA%\ghostty`（`src/os/xdg.zig::config`）。`GX Mocha` 在加载前写进 `<配置目录>/themes`，文件首行带 GX 标记，同名但没有标记的用户文件不动。

GX 默认值：主题 `GX Mocha`、`language = zh-CN`、`font-family = JetBrainsMono Nerd Font` 并把 CJK 区段经 `font-codepoint-map` 交给 `Noto Sans CJK SC`、12 号字、内边距 10/8、闪烁块光标、右键菜单、`confirm-close-surface = true`、`gx-herdr-app-mode = true`、解绑 Alt+1～8、`gx:` 快捷键与三个命令面板条目；Windows 另设 `quit-after-last-window-closed = true`。win32 apprt 能让窗口材质透到终端时（加载前调 `src/gx/config_layers.zig::setMaterialOpacity`），各层都没设 `background-opacity` 的材质在默认值层补一条：`mica`、`tabbed` 为 0.3，`acrylic` 为 0.75（`materialOpacity`）。fork 配置键：`gx-launch-profile`、`gx-herdr-app-mode`、`gx-window-material`、`gx-idle-processes`、`gx-open-config-ui`；`language` 只认 `zh-CN` 与 `en`，默认 `zh-CN`。

**GX 绑定动作**：`gx:settings`、`gx:main_menu`（默认 Ctrl+Shift+M）、`gx:keybinds`（默认 Ctrl+Shift+/）、`gx:new_tab_profile:<id>`、`gx:new_window_profile:<id>`。核心 `Surface.performBindingAction` 把它交给 apprt 的 `gxAction`（`src/apprt/win32/App.zig::gxAction`、`src/apprt/gtk/App.zig::gxAction`）；没有实现的 apprt 记日志并返回未执行，带 `performable:` 的绑定把按键交给终端。

## 8. GTK 的 GX 层

`src/apprt/gtk/gx/main.zig` 汇总，上游 GTK 文件只在带 GX-0011、GX-0015、GX-0016 标记的钩子里调用它：

| 模块 | 作用 |
|---|---|
| `language.zig`、`app.zig` | 启动与运行时应用 `language`：改写 `LANGUAGE` 与 `LC_MESSAGES`、让 gettext 缓存失效、切换 `gx.i18n`，子进程拿回原来的 `LANG`/`LANGUAGE`；app action `app.gx-language`、`app.gx-keybinds`；`performGxAction` 执行五个 `gx:` 动作 |
| `window.zig`、`menus.zig`、`ui/1.5/gx/menus.blp`、`launch.zig` | 菜单与按钮提示随语言重建（复刻上游菜单并加 GX 分区：设置…、键盘快捷键、语言）；新建标签页下拉的启动配置与「用启动配置新建窗口」 |
| `shortcuts.zig`、`shortcuts_dialog.zig` | 快捷键速查表（`Adw.Dialog`，可搜索） |
| `settings_dialog.zig`、`ui/1.5/gx-settings-dialog.blp` | 设置对话框（`Adw.PreferencesDialog`，app action `app.gx-settings`，运行期 libadwaita 低于 1.5 时只记日志；GX-0015） |
| `app_mode.zig`、`style.zig`、`style.css` | herdr 应用模式隐藏标签栏、GX 样式的 CSS provider 与 `window-theme` 随配置重设（GX-0016） |

命令面板用上游原样的 `class/command_palette.zig`：它列出 `command-palette-entry` 里的 `gx:` 条目，选中后与绑定一样经 `Surface.performBindingAction`（GX-0014）交给 `App.gxAction`。面板原样显示配置里的标题与描述，GX 默认值写的是英文 msgid，所以 GTK 构建在加载配置时（`src/gx/config_layers.zig::translatePalette`）把默认值层的这些条目按 `language` 换成译文，重载配置即随语言更新；win32 面板则在显示时经 `gx.i18n` 翻译。

GTK 的上游文字仍走 gettext（`_`/`N_`/`C_` 与 `po/`），只有装了对应 UTF-8 locale 才跟随 `language`；GX 自有文字一律用英文 msgid 经 `gx.i18n` 翻译，不进上游 pot。

## 9. 跨语言契约

**Swift ↔ `include/ghostty.h`**：头文件用 `GHOSTTY_API` 控制导出，对象都是不透明指针（`ghostty_app_t`、`ghostty_surface_t` 等）；`include/module.modulemap` 包成 Clang module `GhosttyKit`，Swift 只经它访问核心（`macos/Sources/App/ghostty-bridging-header.h` 只暴露 ObjC 辅助类）。实现分在 `src/main_c.zig`、`src/config/CApi.zig`（`ghostty_config_*`）、`src/apprt/embedded.zig::CAPI`（`ghostty_app_*`、`ghostty_surface_*`、`ghostty_inspector_*`）与 `src/benchmark/CApi.zig`。宿主经 `ghostty_runtime_config_s`（`src/apprt/embedded.zig::App.Options`）提供 wakeup、action、剪贴板回调；wakeup 可来自任意线程，`macos/Sources/Ghostty/Ghostty.App.swift::Ghostty.App.wakeup` 把 tick 投递到主队列。`build.zig::addGhosttyH` 把头文件经 translate-c 导入单测，由 `src/lib/enum.zig::checkGhosttyHEnum` 比对 Zig 枚举与头文件常量。

**C、C++、Zig ↔ libghostty-vt**：

- 导出链：`src/terminal/c/<module>.zig` → `src/terminal/c/main.zig` → `src/lib_vt.zig` 的 `@export`（`ghostty_` 前缀）→ `include/ghostty/vt/`。细则见 `src/terminal/c/AGENTS.md`，示例与 `@snippet` 规则见 `example/AGENTS.md`，API 文档由 `Doxyfile` 生成。fork 只加了一个模式常量 `GHOSTTY_MODE_WIN32_INPUT`（GX-0006）。
- ABI 形状：不透明指针、sized struct（`GHOSTTY_INIT_SIZED`）或 `_padding`、C 枚举以 `_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE` 收尾。库导出 `ghostty_type_json`（指针宽度、对齐、字节序、结构布局），`test-lib-vt-schema` 按 `src/terminal/c/types.schema.json` 校验（需要 Python 的 `jsonschema`，wasm 另需 `wasmtime`）。
- 分发：共享库与静态库附 pkg-config；Apple 上可出 `ghostty-vt.xcframework`（module `GhosttyVt`）；CMake 经根 `CMakeLists.txt`（内部调 `zig build -Demit-lib-vt`）与 `dist/cmake/`；Zig 用户导入 `ghostty-vt` 模块。`-Dvt-features` 可整组裁掉 C API；`src/lib_vt.zig::sys` 让嵌入方注入 PNG 解码、日志回调等实现，`src/lib_vt.zig::TinyIo` 是体积优化的 `std.Io`。

**JS ↔ wasm**：`src/build/GhosttyLibVt.zig::initWasm` 把库构建成无入口的 wasm exe，导出全部 `ghostty_*` 与间接函数表，栈 128 KiB，由 `src/build/wasm_patch_growable_table.zig` 改写表段，让 JS 能扩表登记回调；另导出 `ghostty_wasm_alloc` 等分配辅助（`src/lib/allocator/wasm.zig`、`include/ghostty/vt/wasm.h`）。默认开 `simd128`，release 日志为空操作，Kitty 图形关闭。

## 10. 关键不变量

规则全文与验证在括号里的领域文档。

1. 终端状态只在持 `renderer_state.mutex` 时读写，持锁投递只走会临时解锁的路径（[renderer](AGENT_RULES/renderer.md)、[termio-pty-os](AGENT_RULES/termio-pty-os.md)）。
2. 线程间只经 mailbox 通信；`Surface.init`、`App.updateConfig` 在主线程；销毁时先停线程再释放共享状态（[app-core](AGENT_RULES/app-core.md)）。
3. `StreamHandler` 与终端同生命周期，不能中途换新（[termio-pty-os](AGENT_RULES/termio-pty-os.md)）。
4. OpenGL 上下文同一时间只在一个线程 current；WGL 上下文只在渲染线程创建与使用；`src/Surface.zig::draw` 的注释要求渲染器容许主线程调用 `drawFrame`，目前只有 embedded apprt（Metal）这样调用（[renderer](AGENT_RULES/renderer.md)）。
5. `global.init` 只有三个调用点：`src/main_ghostty.zig::main`、`src/main_c.zig::ghostty_init`、`src/benchmark/cli.zig`；libghostty-vt 引用 `src/global.zig` 会编译失败。注释称全局状态只为 C API 存在，实际已有近百个文件经 `global.io()`、`global.alloc()` 取用（[app-core](AGENT_RULES/app-core.md)）。
6. libghostty-vt 必须能构建到 freestanding（该路径不依赖 libc 与 `src/simd`），且不启用 oniguruma（[libghostty-vt](AGENT_RULES/libghostty-vt.md)、[terminal-core](AGENT_RULES/terminal-core.md)）。
7. C ABI 四步导出、`_MAX_VALUE` 哨兵、sized struct；ABI 清单受 `test-lib-vt-schema` 守护（[libghostty-vt](AGENT_RULES/libghostty-vt.md)）。
8. `ghostty.h` 只给 macOS app，外部嵌入用 libghostty-vt（[libghostty-embedding](AGENT_RULES/libghostty-embedding.md)、[macos-app](AGENT_RULES/macos-app.md)）。
9. `Config` 字段的 doc comment 就是用户文档，按 Pandoc Markdown 写，`gx-*` 键同样如此（[config](AGENT_RULES/config.md)）。
10. 上游 GTK 字符串用 `_`、`N_`、`C_` 标记，`po/` 只经 `update-translations` 更新；GX 自有界面文字用英文 msgid 经 `gx.i18n`，译文只在 `src/gx/i18n/gx.zh_CN.po` 维护；macOS 尚未本地化（[apprt-gtk](AGENT_RULES/apprt-gtk.md)）。
11. 改上游源码必须带 `fork(gx): GX-NNNN` 标记并登记，fork 代码放在上游没有的新路径（[development](AGENT_RULES/development.md)）。
12. 入库生成物只经生成器重建（[build-system](AGENT_RULES/build-system.md)、[development](AGENT_RULES/development.md)）。
13. HEAD 上的 `v` 前缀 tag 必须等于 `build.zig.zon` 的版本；fork 的 tag 用 `gx-v` 前缀（[build-system](AGENT_RULES/build-system.md)、[ci-release](AGENT_RULES/ci-release.md)）。

## 11. 生成物与派生文件

入库的生成物（何时重建见 [DEVELOPMENT.md](DEVELOPMENT.md)「生成物重建时机」）：

| 产物 | 输入 → 生成器 | 检查 |
|---|---|---|
| `build.zig.zon.{json,nix,txt}`、`flatpak/zig-packages.json` | `build.zig.zon` → `nix/build-support/check-zig-cache.sh --update`（需要 Nix） | 同一脚本不带参数 |
| `po/com.mitchellh.ghostty.pot`、`po/*.po` | `src/apprt/gtk/` 的 `.zig` 与 `.blp`、`src/input/command.zig`、`dist/linux/ghostty_nautilus.py` → `zig build update-translations` | `.github/scripts/check-translations.sh` |
| `src/gx/i18n/zh_CN.zig` | `po/zh_CN.po` 与 `src/gx/i18n/gx.zh_CN.po` → `just i18n` | `just i18n-check` |
| `vendor/glad/` | `glad.zip` → `Makefile` 的 `glad` 目标 | 无 |
| `build.zig.zon` 的 `iterm2_themes` 条目 | 上游每周的 `update-colorschemes.yml`（已归档，随同步获得） | 同第一行 |
| `CODEOWNERS`、`.github/VOUCHED.td` | 上游 vouch 机器人（已归档） | 只随同步更新 |
| `graphify-out/` 的两份入库产物 | 被索引源码 → `just graph` | `just graph-check` |
| `docs/kb/chunks.json` | KB 语料 → `just kb` | `just kb-check` |
| `nix/zigCacheHash.nix` | 无：注释与 `HACKING.md` 称由脚本生成，但现行脚本不写它，也无引用 | 上游遗留，勿手改 |

构建期派生、不入库：`help_strings`（`src/helpgen.zig`，供 `+help`、man 页与网站数据）、Unicode 表（`src/build/UnicodeTables.zig`）、`+boo` 帧数据（`src/build/GhosttyFrameData.zig`）、GTK 资源（`src/build/SharedDeps.zig::gtkNgDistResources`，`.blp` 检查用 `nix/build-support/check-blueprints.sh`）、安装资源（`src/build/GhosttyResources.zig`：terminfo 源 `src/terminfo/ghostty.zig`、`src/extra/` 的补全与语法、主题、Linux 桌面文件）、`-Demit-docs` 与 `-Demit-webdata` 的文档、Doxygen API 文档。

源码包：`zig build dist`（`src/build/GhosttyDist.zig::init`）对 `HEAD` 做 `git archive`，附上 `VERSION` 并预置 GTK 资源与帧数据（`src/apprt/gtk/ghostty_resources.c`/`.h`、`src/build/framegen/framedata.compressed`），lib-vt 模式按 `lib_vt_excludes` 剔除无关目录；`zig build distcheck` 解压后在包内跑测试，lib-vt 模式另跑 CMake 构建。

## 12. 版本与发布

**产品版本**：`build.zig` 优先读源码包里的 `VERSION`，否则取 `build.zig.zon` 的 `.version`（当前 `1.3.2-dev`），`src/build/Config.zig::init` 只取其中 `X.Y.Z` 再定版：`-Dversion-string` 原样使用；作为依赖构建时为 `X.Y.Z`；否则由 `src/build/GitVersion.zig::detect` 探测——无 git 时为 `X.Y.Z-dev+0000000`，`tip` tag 视为预发布，`v` 前缀 tag 必须恰好是 `vX.Y.Z`（否则 `@panic`），其余为 `X.Y.Z-<分支>+<短 hash>`（分支名的非 `[0-9A-Za-z-]` 字符换成 `-`，本分支得 `1.3.2-gx-ghostty+<hash>`）。带预发布段的版本发布通道为 `tip`（`Config.addOptions`，`+version` 会显示）。libghostty-vt 版本是 `build.zig` 常量 `lib_version`（`0.1.0-dev`），可用 `-Dlib-version-string` 覆盖。

因此源码包没有 `.git` 时退化为 `X.Y.Z-dev+0000000`，解压在别的 Git 工作树之内（如 `distcheck` 解压在 `.zig-cache` 下）时会探测到外层仓库；release 构建一律显式传 `-Dversion-string`。测试构建也显式传：`scripts/zig_test.py::pinned_version_string` 给测试步骤固定 `-Dversion-string=X.Y.Z-dev+0000000`（与无 git 时的回退同形），否则版本串随提交哈希变化，每次提交都会让测试二进制整体重编。

**GX-0001**：上游遇到非 `v` 前缀 tag（如 `gx-v0.0.1`）也会 panic，打了 fork tag 的提交不传 `-Dversion-string` 就无法构建。补丁在 `src/build/Config.zig::init` 的 tag 判断处加 `fork(gx): GX-0001` 标记，让这类 tag 与 `tip` 一样跳过发布校验、回退到分支预发布版本；登记与移除条件见 [FORK_PATCHES.md](FORK_PATCHES.md)，由 `scripts/test_fork_patches.py` 锁定。

**fork 版本与发布**：fork 版本是根 `CHANGELOG.md` 中 `## X.Y.Z(TBD|YYYY-MM-DD)` 标题里最大的 SemVer（`just version`、`just version-check`），与产品版本互不同步；首个发布版本为 0.0.1。tag 为 `gx-vX.Y.Z`，release 名 `Ghostty GX X.Y.Z`，构建版本串 `<zon 的 X.Y.Z>-gx.<fork X.Y.Z>`（如 `1.3.2-gx.0.0.1`，发布通道显示 `tip`）。启用中的 workflow 只有 `gx-ci.yml` 与 `gx-release.yml`；发布只经手动触发的 `gx-release`：prepare 先过 resolver、版本、`kb-check`、`graph-check`，verify 核对资产集合并写 `manifest.json`（schema 2）与 `SHA256SUMS`，唯一有写权限的 publish job 以 CHANGELOG 版本段为开头的说明发布正式 Release（不是 prerelease），见 [RELEASE.md](RELEASE.md)。

## 13. 打包与发布产物

| 产物 | 生成方 | 内容 |
|---|---|---|
| `ghostty-gx-$VS-x86_64-windows.zip` | `scripts/gx_windows_package.py`（`just package-windows`；gx-release `windows-app`） | 顶层目录 `ghostty-gx-$VS-x86_64-windows/`：`ghostty.exe`、随包 ConPTY（`conpty.dll`、`OpenConsole.exe`，1.24.261001001）、`mesa/`（Mesa 26.2.4 llvmpipe：`opengl32.dll`、`libgallium_wgl.dll`、`dxil.dll`）、`share/`（含 fork 主题）、`fonts/`（JetBrainsMono Nerd Font 6 个、Noto Sans CJK 2 个）、`licenses/`、中英文 `README.txt` |
| `ghostty-gx-$VS-x86_64-windows-setup.exe` | 同上，Inno Setup 7.1（`dist/windows/gx/ghostty-gx.iss`） | 同一棵树去掉 `fonts/` 装进 `{app}`，字体装进 `{autofonts}`（与程序同一范围：当前用户或所有用户） |
| `ghostty-gx-$VS-x86_64-linux-debian13.tar.gz` | gx-release `linux-gtk`（debian:13 容器，从完整源码包构建） | 实验性 GTK app，`usr/` 前缀 |
| GX Shell 组件 stage（schema 3） | `scripts/gx_package.py` 的 `windows` 与 `deb`（`just stage`），deb 经 Ubuntu 24.04 配方 `scripts/gx_linux_build.py` | `stage-manifest.json` 加 Windows 的 `app/`、`fonts/`、`build-inputs/`，或 deb 的 `root/`、`fonts/`；不是发布资产，由 GX Shell 组装成自己的安装包；gx-release `linux-gtk-noble` 按消费方命令验证 deb 路径 |
| libghostty-vt 预编译库与源码包、完整源码包 | gx-release `libvt`、`libvt-macos`、`source`、`linux-gtk` | 见 [RELEASE.md](RELEASE.md)「资产」 |

Windows 包的第三方下载都在 `scripts/gx_windows_package.py::DOWNLOADS`/`PAYLOAD` 里按 sha256 钉死，校验不符即失败（Ubuntu 配方的 blueprint-compiler 钉在 `scripts/gx_linux_build.py`）；下载缓存在 `.local/cache/gx-package/`（`GX_GHOSTTY_PACKAGE_CACHE` 或 `--cache-dir` 可改）。打出的文件名与内容由 `scripts/gx_release.py::expected_assets` 统一定义，打包脚本与 `verify` 用同一份。

## 14. 图谱与知识库

- **图谱**：`just graph`（`scripts/graphify.py`，钉版 graphifyy 0.9.73，装在 `.local/tools/venv`）以仓库根为索引根、`.graphifyignore` 为排除表；入库 `graphify-out/GRAPH_REPORT.md` 与 `graphify-out/source-fingerprint.json`，约 20 MB 的 `graph.json` 只留本机；`just graph-query <问题>` 查询。指纹覆盖 graphify 会索引的全部代码扩展名（`scripts/graphify_fingerprint.py::INDEXED_EXTENSIONS`，至少含 `.zig .swift .c .h .cpp .cc .hpp .m .mm .metal .py .sh .bash`）中未被排除的文件、管线脚本与入库报告，没有 `graph.json` 也能 `just graph-check`。graphify 固定跳过名为 `build`、`dist`、`target` 的目录，所以 `src/build/**` 不在图里，查构建逻辑要直接读源码；新鲜度只在 `gx-release` 的 prepare 与上游同步后（`just generated-check`）强制。
- **知识库**：`docs/kb/chunks.json`，`just kb` 构建、`just kb-check` 校验、`just kb-query <词>` 检索（BM25）。语料是根与嵌套 `AGENTS.md`、上游与 fork 的说明文档、`docs/AGENT_RULES/*.md`、`src/**/*.zig` 的 `//!` 与 `pub` 签名、`include/ghostty/**/*.h` 的声明摘要；`kb-check` 属于 `framework-check`。

## 15. 上游同步面

| 类别 | 文件 | 同步时 |
|---|---|---|
| fork 独占 | 第 2 节列出的 fork 新增路径 | 不冲突；上游新路径要在 `routes.toml` 登记 |
| 上游文件 + 追加段 | 根 `AGENTS.md`（`<!-- gx-fork: … -->` 以下）、`.gitignore`、`.prettierignore`（`# --- GX fork：` 段） | 标记以上取上游，标记段原样保留 |
| 上游文件 + 补丁 | [FORK_PATCHES.md](FORK_PATCHES.md) 登记表里状态为 `active` 的 39 个文件，集中在 `src/Surface.zig`、`src/config/Config.zig`、`src/termio/`、`src/apprt/gtk/class/`、`src/renderer/`、`src/font/` 与 `build.zig` | 按补丁小节的「同步冲突处理」复核，热点见 [DEVELOPMENT.md](DEVELOPMENT.md)「上游同步」 |
| 上游文件移位 | 15 个上游 workflow 原样移到 `.github/workflows-archive/` | 上游新增的 workflow 也 `git mv` 进归档，不启用 |
| 上游独占 | 其余全部，含 `.agents/`、9 份嵌套 `AGENTS.md`、`CODEOWNERS`、lint 配置、`dependabot.yml` | 取上游 |

流程：`main` 只快进到 `upstream/main`；在 `gx_ghostty` 上 `git merge --no-ff main`，信息用 `chore(sync): 合并上游 main（<sha>）`；再跑 `just framework-check`、`just ci-check`，重建 KB 与图谱后跑 `just generated-check`。永不 force push、不推送 `upstream`。步骤见 [DEVELOPMENT.md](DEVELOPMENT.md)「上游同步」。
