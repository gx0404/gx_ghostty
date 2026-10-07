# 架构（gx_ghostty）

结构性事实地图：东西在哪、谁拥有状态、线程如何交互、哪些文件是生成的。规则在 `docs/AGENT_RULES/<id>.md`（`just rules <路径…>` 解析），开发闭环见 [DEVELOPMENT.md](DEVELOPMENT.md)，发版见 [RELEASE.md](RELEASE.md)。事实以源码为准，引用写 `path::symbol`；计数是基线快照（上游提交 `c3203ea4b` 的 `git ls-files`，共 5914 个文件），同步后会漂移。

## 1. 定位与产物

fork 自 `ghostty-org/ghostty`：业务代码跟随上游，只叠加 AI 协作框架与两个构建补丁：GX-0001（版本推导，第 9 节）与 GX-0002（只安装测试二进制的构建步骤，第 3 节）。Zig 版本 0.16.0（`build.zig.zon` 的 `minimum_zig_version`；`src/build/zig.zig::requireZig` 编译期要求 0.16.x，fork 经 `scripts/zigw.py` 钉死 0.16.0）。

| 产物 | 说明 | 根文件 / 构建逻辑 |
|---|---|---|
| `ghostty` | Linux、FreeBSD 的 GTK 终端 | `src/main_ghostty.zig::main`；`src/build/GhosttyExe.zig` |
| `Ghostty.app` | macOS Swift 应用，静态链接 `macos/GhosttyKit.xcframework` | `macos/`；`src/build/GhosttyXCFramework.zig`、`src/build/GhosttyXcodebuild.zig`；日常用 `macos/build.nu` |
| libghostty-internal | 完整核心的嵌入式 C API `include/ghostty.h`（历史名 libghostty），只服务 macOS app | `src/main_c.zig`；`src/build/GhosttyLib.zig` |
| libghostty-vt | 可独立嵌入的终端仿真库：C 头 `include/ghostty/`、Zig 模块 `ghostty-vt`/`ghostty-vt-c`、`ghostty-vt.wasm`；API 未稳定但按 ABI 友好设计 | `src/lib_vt.zig`；`src/build/GhosttyZig.zig`、`src/build/GhosttyLibVt.zig` |

| 目标 | 默认 apprt / 渲染 / 字体 | 默认 `zig build` 的主要产物 | 上游 CI（已归档） |
|---|---|---|---|
| Linux、FreeBSD | `gtk` / OpenGL / `fontconfig_freetype` | `bin/ghostty`、`share/` 资源、libghostty-vt | Linux 全量；FreeBSD job 已注释 |
| macOS | `none`（internal 库用 `embedded`）/ Metal / `coretext` | `GhosttyKit.xcframework`、`Ghostty.app`（`-Demit-macos-app=false` 可跳过）、libghostty-vt | app 与 lib-vt |
| Windows | `none` / OpenGL / `freetype_windows`；默认 MSVC ABI，i18n 关 | 只有库，而且只有 libghostty-vt：`ghostty-vt.dll`、`ghostty-vt-static.lib`。默认 `install` 还要构建 `ghostty-internal.dll`、`ghostty-internal-static.lib`，它们编译不过（第 3 节末），`zig build` 因此失败，库用 `-Demit-lib-vt` 构建 | 只测 lib-vt；完整 test 于 2026-08-28 移除（`380778e3c`） |
| iOS、Android | — | 只有 libghostty-vt（全量构建遇 iOS 报 `UnsupportedTarget`） | lib-vt 交叉构建 |
| wasm32-freestanding | — | 只有 libghostty-vt：`bin/ghostty-vt.wasm` 与静态归档 | wasm、ABI 清单、`test/wasm-alloc.mjs` |
| 其他 freestanding | — | 只有静态 libghostty-vt 与头文件 | riscv32、thumb |

默认值来自 `src/apprt/runtime.zig::Runtime.default`、`src/renderer/backend.zig::Backend.default`、`src/font/backend.zig::Backend.default` 与 `src/build/Config.zig::init`。本机 Windows 只能验证 libghostty-vt；非 vt 代码的编译与测试、GUI 证据都交 `gx-ci`（[TESTING.md](TESTING.md)）。

## 2. 仓库布局

| 路径 | 文件数 | 角色 |
|---|---:|---|
| `src/` | 1014 | 共享 Zig 核心，见下 |
| `test/` | 4024 | 树外测试：`fuzz-libghostty/`（AFL++，语料 4002 个）、`esctest/`、`windows/`、`wasm-alloc.mjs` |
| `macos/` | 271 | Swift app（`Sources/` 177 个）、Xcode 工程、`build.nu` |
| `pkg/` | 234 | 23 个树内 Zig 包，封装 C/C++ 依赖与平台 SDK |
| `example/` | 133 | 35 个 libghostty-vt 示例，CI 按 `example/*/build.zig.zon` 发现 |
| `include/` | 37 | `ghostty.h`、`module.modulemap`；`ghostty/vt.h` 与 `ghostty/vt/` 下 34 个头 |
| `po/` | 37 | `com.mitchellh.ghostty.pot` 与 34 个 `.po` |
| `images/`、`nix/`、`.github/`、`dist/` | 34、33、24、21 | 图标；nix 环境与 VM 测试；上游 CI（已归档）与脚本；分发模板 |
| `vendor/`、`flatpak/`、`snap/`、`.agents/` | 9、5、2、2 | GLAD 与 nerd-fonts patcher；打包清单；上游 agent 命令与 skill |
| 根文件 | 34 | `build.zig`、`build.zig.zon` 及派生文件、`CMakeLists.txt`、`Doxyfile`、`Makefile`、nix 入口、lint 配置、上游文档 |

fork 新增（不计入）：`docs/`、`scripts/`、`justfile`、`CLAUDE.md`、`CHANGELOG.md`、`.claude/`、`.codex/`、`.zcode/`、`.githooks/`、`.graphifyignore`、`graphify-out/`、`.github/workflows/gx-*.yml`、`.github/workflows-archive/`；本机状态在 gitignored 的 `.local/`。

`src/` 内：顶层 31 个（入口、`App.zig`、`Surface.zig`、`global.zig`、各包入口）；`build/` 281（含 236 个 `+boo` 动画帧）；`terminal/` 202（含 C API `c/`）；`font/` 116；`apprt/` 92；`renderer/` 52；`os/` 34；`cli/` 30；`config/` 24；`lib/` 22；其余 13 个子目录各 3–20 个。路径归属以 `docs/AGENT_RULES/routes.toml` 为准。

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

启动：`src/main_ghostty.zig::main` 先 `global.init` 建立进程级状态（分配器、`std.Io`、日志、sentry、locale、资源目录、i18n 等）；有 `+action` 时执行后退出；`app_runtime == .none` 时打印 CLI 用法退出；否则 `App.create` → `apprt.App.init` → `run`。嵌入方依次调 `ghostty_init`、`ghostty_cli_try_action`、`ghostty_app_new`。

`build.zig` 的步骤：默认 `install`；`run`、`run-valgrind`；`test`、`test-valgrind`（完整单测，`-Demit-lib-vt` 时为空步骤；macOS 上不带 `-Dtest-filter` 的 `test` 还挂上 macOS app 的 `xcodebuild test`）；`test-lib-vt`、`test-lib-vt-build`；`test-lib-vt-schema`（调 `python3` 校验 ABI 清单）；`update-translations`；`dist`、`distcheck`；以及 fork 补丁 GX-0002 新增的 `test-lib-vt-bin`、`test-bin`：只编译并把 `test-lib-vt`、`test` 用的同一批测试二进制装到 `zig-out/test/`（`vt/`、`vt_c/` 与 `ghostty-test`），不运行，由 `scripts/zig_test.py` 按 Zig 测试运行器协议分片到多个进程（`just test-vt`、`just test`；`ghostty-test` 在 Windows 上编译不过）。默认 `install`：`app_runtime != none` 时装 `ghostty` 与资源；为 `none` 时非 Darwin 装 libghostty-internal 与 `ghostty.h`（Windows 上这一步编译不过，见本节末），macOS 主机出 xcframework 并经 xcodebuild 出 `Ghostty.app`；非 freestanding 目标总会装 libghostty-vt 共享库与静态库（Windows 静态库改名 `ghostty-vt-static.lib`，避开 DLL 导入库）。`-Demit-lib-vt` 是库专用模式，关闭 exe、文档、macOS app 与 internal 库，本仓被当作依赖时默认开启。

选项全集在 `src/build/Config.zig::init`，经 `Config.addOptions` 写入 `build_options`、运行期由 `src/build_config.zig` 读取；libghostty-vt 另有 `src/terminal/build_options.zig::Options`（含 `-Dvt-features`）。`src/build/SharedDeps.zig::add` 把 C 依赖与构建期生成模块挂到 libghostty-internal、`ghostty` exe、`ghostty-test` 与 bench 工具的编译步骤（libghostty-vt 只用 `SharedDeps.addSimd`）。其中 translate-c 导入 `posix_c`（`errno.h`、`pwd.h`、`signal.h`、`sys/types.h`、`unistd.h`）不分目标一律添加，MSVC 目标找不到 `pwd.h`，所以这些产物在 Windows 上都编译不过。

## 4. 核心对象与所有者

核心 `App` 由 `src/main_ghostty.zig::main` 创建（嵌入时由 `ghostty_app_new` 创建），由 apprt 的 App 驱动；核心 `Surface` 的内存归 apprt 的 Surface（GTK 部件或嵌入方视图）。

```text
App（src/App.zig）
├─ surfaces          []*apprt.Surface，只存指针
├─ mailbox           BlockingQueue(App.Message, 64)，主线程 tick 时 drain
├─ font_grid_set     font.SharedGridSet，同字体配置的 surface 共享网格（引用计数）
└─ device            renderer.Device，各 surface 的渲染器借用，最后释放
Surface（src/Surface.zig）
├─ io                termio.Termio：拥有 terminal（终端模型）、terminal_stream、Exec 后端、termio mailbox
├─ io_thread         termio 写线程
├─ renderer          GenericRenderer(Metal | OpenGL)，内含 draw_mutex
├─ renderer_state    renderer.State：mutex + 指向 io.terminal 的指针 + inspector、preedit、mouse
├─ renderer_thread   渲染线程与其 mailbox
├─ search、inspector 按需创建
└─ config            DerivedConfig，从 Config 复制的私有副本
```

- **apprt**：`src/apprt.zig::runtime` 编译期选定唯一实现（exe 为 `none` 或 `gtk`，lib 为 `embedded`，`wasm_module` 为 `browser` 桩）；核心经 `performAction` 把 `src/apprt/action.zig::Action` 交给它执行。
- **termio / terminal**：termio 的 Backend 只有 `Exec`（子进程与 pty，Windows 为 ConPTY）；`src/terminal/main.zig` 与渲染、pty 无关，libghostty-vt 直接复用，C API 只在 `options.c_abi` 时编入。
- **renderer / font / input**：`src/renderer.zig::Renderer` 按 `build_config.renderer` 选 Metal 或 OpenGL；字体后端由 `src/font/backend.zig::Backend` 选定；`src/input.zig` 的 `key_encode`、`mouse_encode`、`paste` 与 libghostty-vt 共用（`src/lib_vt.zig::input`）。
- **config**：`src/config/Config.zig::Config` 的字段名即配置键，由 apprt 加载；`App.updateConfig` 只在主线程调用，经 `Surface.updateConfig` 重建派生配置、下发新字体网格，再向渲染线程与 termio 各发 `change_config`。
- **全局状态**：`src/global.zig` 保存分配器、`std.Io`、环境、资源目录与 CLI action，每个进程只 `global.init` 一次。

## 5. 线程模型与数据流

| 线程（名称） | 创建者 | 职责 |
|---|---|---|
| 主线程 | GTK 由 `src/apprt/gtk/class/application.zig::Application.run` 每轮 `App.tick`；macOS 在主队列调 `ghostty_app_tick` | 事件、`App.drainMailbox`、`Surface.handleMessage`、surface 创建销毁 |
| `io` 写线程 | `Surface.init` → `src/termio/Thread.zig::threadMain` | xev 循环：写 pty、resize（合并 25 ms）、各类报告、同步输出 1 s 超时复位、termios 轮询 |
| `io-reader` | `src/termio/Exec.zig::threadEnter` 在 io 线程上启动 `ReadThread` | `Termio.processOutput` 持锁解析 |
| `io-gather` | `ReadThread` 的 POSIX 路径 | 把 pty 读进 4 个 64 KiB 轮转缓冲；Windows 上读与解析是同一线程 |
| `renderer` | `Surface.init` → `src/renderer/Thread.zig::threadMain` | xev 循环：drain mailbox → `updateFrame` → `drawFrame`；光标闪烁、动画、空闲压缩 |
| `search` | 首次 `.search` 绑定动作（`Surface.performBindingAction`） | `src/terminal/search/Thread.zig::threadMain`，结果经 `Surface.searchCallback` 回送 |

另有预热等辅助线程。队列都是 `src/datastruct/blocking_queue.zig::BlockingQueue`：容量 64、内部 mutex、无阻塞 pop，靠事件循环唤醒。

| 队列 | 方向 | 典型消息 |
|---|---|---|
| `src/App.zig::Mailbox` | 任意线程 → 主线程，`rt_app.wakeup()` 唤醒 | `new_window`、`close`、`quit`、`surface_message` |
| `src/apprt/surface.zig::Mailbox` | 各线程 → 主线程 `Surface.handleMessage`（包成 `surface_message` 走 App 队列） | `set_title`、剪贴板、`child_exited` |
| `src/termio/mailbox.zig::Mailbox` | 主线程（`Surface.queueIo`）与 `io-reader` → `io` | `write_*`、`resize`、`change_config`、`focused` |
| `src/renderer/Thread.zig::Mailbox` | 主线程、`io-reader`、搜索回调 → `renderer` | `resize`、`change_config`、`font_grid`、`visible` |
| `src/terminal/search/Thread.zig::Mailbox` | 主线程 → `search` | `change_needle`、`select` |

**输出路径**：pty →（POSIX 经 `io-gather`）`io-reader` → `src/termio/Termio.zig::processOutput` 加锁，`queueRender` 唤醒渲染线程，把字节喂给 `terminal_stream` → `terminal.Stream(StreamHandler)` 更新 `Terminal`/`Screen`/`PageList`，回写 pty 的响应进 termio 队列，标题、剪贴板等进 surface 消息 → 解锁，批次间 `yieldToDemand` → `src/renderer/generic.zig::Renderer.updateFrame` 在 `lockDemand` 内只做快照（`RenderState.beginUpdate` 等；同步输出模式跳过本帧），锁外 `endUpdate`、重建 cell，再 `drawFrame`。

**输入路径**：apprt 事件 → `App.keyEvent`（全局与 app 级绑定）→ `Surface.keyCallback`（绑定未命中则 `input.key_encode` 编码）→ `Surface.queueIo` → `io` 线程写 pty。鼠标经 `mouseButtonCallback`、`cursorPosCallback`、`scrollCallback` 编码上报或持锁改选区。

**锁协议**（`src/renderer/State.zig`）：

- `mutex` 保护成员指向的数据（terminal、inspector、preedit、mouse），State 本身不是线程安全的；`io-reader`、`io`、主线程、`renderer`、`search` 都会持锁。
- 防饿死：mutex 不公平，热循环解锁后立刻重锁会一直赢过沉睡的等待者。渲染线程用 `lockDemand`/`unlockDemand`（demand 计数 + futex 交接），热循环在批次间 `yieldToDemand`，最多让 1 ms。
- 持锁投递：持锁向满队列阻塞 push 会与等这把锁的消费者互等，所以 `src/termio/mailbox.zig::Mailbox.send` 的 `mutex` 参数与 `src/termio/stream_handler.zig::StreamHandler` 的三个 `*Writer` 都先立即 push，失败才临时解锁再阻塞 push（termio、渲染两路还会先唤醒消费者）。
- scrollback 压缩（`src/renderer/Thread.zig::Compression`）只在空闲 250 ms 后 `tryLock` 做一步，从不等锁。
- OpenGL：EGL context 按 surface 创建，`src/renderer/OpenGL.zig::init` 在主线程绑定后即释放，渲染线程 `threadEnter` 重新绑定，GL 函数也只在渲染线程加载。主线程调 `drawFrame`（`Surface.draw`，由 `draw_mutex` 保护）只发生在 embedded apprt（macOS/Metal 的 resize）；GTK 不调用它。
- 关闭：`Surface.deinit` 依次停止并 join 搜索、渲染、io 线程（`Exec.threadExit` 经 quit pipe 结束读线程），最后释放共享状态。

## 6. 跨语言契约

**Swift ↔ `include/ghostty.h`**：头文件用 `GHOSTTY_API` 控制导出，对象都是不透明指针（`ghostty_app_t`、`ghostty_surface_t` 等）；`include/module.modulemap` 包成 Clang module `GhosttyKit`，Swift 只经它访问核心（`macos/Sources/App/ghostty-bridging-header.h` 只暴露 ObjC 辅助类）。实现分在 `src/main_c.zig`、`src/config/CApi.zig`（`ghostty_config_*`）、`src/apprt/embedded.zig::CAPI`（`ghostty_app_*`、`ghostty_surface_*`、`ghostty_inspector_*`）与 `src/benchmark/CApi.zig`。宿主经 `ghostty_runtime_config_s`（`src/apprt/embedded.zig::App.Options`）提供 wakeup、action、剪贴板回调；wakeup 可来自任意线程，`macos/Sources/Ghostty/Ghostty.App.swift::Ghostty.App.wakeup` 把 tick 投递到主队列。`build.zig::addGhosttyH` 把头文件经 translate-c 导入单测，由 `src/lib/enum.zig::checkGhosttyHEnum` 比对 Zig 枚举与头文件常量。

**C、C++、Zig ↔ libghostty-vt**：

- 导出链：`src/terminal/c/<module>.zig` → `src/terminal/c/main.zig` → `src/lib_vt.zig` 的 `@export`（`ghostty_` 前缀）→ `include/ghostty/vt/`。细则见 `src/terminal/c/AGENTS.md`，示例与 `@snippet` 规则见 `example/AGENTS.md`，API 文档由 `Doxyfile` 生成。
- ABI 形状：不透明指针、sized struct（`GHOSTTY_INIT_SIZED`）或 `_padding`、C 枚举以 `_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE` 收尾。库导出 `ghostty_type_json`（指针宽度、对齐、字节序、结构布局），`test-lib-vt-schema` 按 `src/terminal/c/types.schema.json` 校验（需要 Python 的 `jsonschema`，wasm 另需 `wasmtime`）。
- 分发：共享库与静态库附 pkg-config；Apple 上可出 `ghostty-vt.xcframework`（module `GhosttyVt`）；CMake 经根 `CMakeLists.txt`（内部调 `zig build -Demit-lib-vt`）与 `dist/cmake/`；Zig 用户导入 `ghostty-vt` 模块。`-Dvt-features` 可整组裁掉 C API；`src/lib_vt.zig::sys` 让嵌入方注入 PNG 解码、日志回调等实现，`src/lib_vt.zig::TinyIo` 是体积优化的 `std.Io`。

**JS ↔ wasm**：`src/build/GhosttyLibVt.zig::initWasm` 把库构建成无入口的 wasm exe，导出全部 `ghostty_*` 与间接函数表，栈 128 KiB，由 `src/build/wasm_patch_growable_table.zig` 改写表段，让 JS 能扩表登记回调；另导出 `ghostty_wasm_alloc` 等分配辅助（`src/lib/allocator/wasm.zig`、`include/ghostty/vt/wasm.h`）。默认开 `simd128`，release 日志为空操作，Kitty 图形关闭。

## 7. 关键不变量

规则全文与验证在括号里的领域文档。

1. 终端状态只在持 `renderer_state.mutex` 时读写，持锁投递只走会临时解锁的路径（[renderer](AGENT_RULES/renderer.md)、[termio-pty-os](AGENT_RULES/termio-pty-os.md)）。
2. 线程间只经 mailbox 通信；`Surface.init`、`App.updateConfig` 在主线程；销毁时先停线程再释放共享状态（[app-core](AGENT_RULES/app-core.md)）。
3. `StreamHandler` 与终端同生命周期，不能中途换新（[termio-pty-os](AGENT_RULES/termio-pty-os.md)）。
4. OpenGL context 同一时间只在一个线程 current；`src/Surface.zig::draw` 的注释要求渲染器容许主线程调用 `drawFrame`，目前只有 embedded apprt（Metal）这样调用（[renderer](AGENT_RULES/renderer.md)）。
5. `global.init` 只有三个调用点：`src/main_ghostty.zig::main`、`src/main_c.zig::ghostty_init`、`src/benchmark/cli.zig`；libghostty-vt 引用 `src/global.zig` 会编译失败。注释称全局状态只为 C API 存在，实际已有近百个文件经 `global.io()`、`global.alloc()` 取用（[app-core](AGENT_RULES/app-core.md)）。
6. libghostty-vt 必须能构建到 freestanding（该路径不依赖 libc 与 `src/simd`），且不启用 oniguruma（[libghostty-vt](AGENT_RULES/libghostty-vt.md)、[terminal-core](AGENT_RULES/terminal-core.md)）。
7. C ABI 四步导出、`_MAX_VALUE` 哨兵、sized struct；ABI 清单受 `test-lib-vt-schema` 守护（[libghostty-vt](AGENT_RULES/libghostty-vt.md)）。
8. `ghostty.h` 只给 macOS app，外部嵌入用 libghostty-vt（[libghostty-embedding](AGENT_RULES/libghostty-embedding.md)、[macos-app](AGENT_RULES/macos-app.md)）。
9. `Config` 字段的 doc comment 就是用户文档，按 Pandoc Markdown 写（[config](AGENT_RULES/config.md)）。
10. 字符串用 `_`、`N_`、`C_` 标记，`po/` 只经 `update-translations` 更新，`src/os/i18n_locales.zig` 与 `po/` 保持一致；macOS 尚未本地化（[apprt-gtk](AGENT_RULES/apprt-gtk.md)）。
11. 入库生成物只经生成器重建（[build-system](AGENT_RULES/build-system.md)、[development](AGENT_RULES/development.md)）。
12. HEAD 上的 `v` 前缀 tag 必须等于 `build.zig.zon` 的版本；fork 的 tag 用 `gx-v` 前缀（[build-system](AGENT_RULES/build-system.md)、[ci-release](AGENT_RULES/ci-release.md)）。

## 8. 生成物与派生文件

入库的生成物（何时重建见 [DEVELOPMENT.md](DEVELOPMENT.md)「生成物重建时机」）：

| 产物 | 输入 → 生成器 | 检查 |
|---|---|---|
| `build.zig.zon.{json,nix,txt}`、`flatpak/zig-packages.json` | `build.zig.zon` → `nix/build-support/check-zig-cache.sh --update`（需要 Nix） | 同一脚本不带参数 |
| `po/com.mitchellh.ghostty.pot`、`po/*.po` | `src/apprt/gtk/` 的 `.zig` 与 `.blp`、`src/input/command.zig`、`dist/linux/ghostty_nautilus.py` → `zig build update-translations` | `.github/scripts/check-translations.sh` |
| `vendor/glad/` | `glad.zip` → `Makefile` 的 `glad` 目标 | 无 |
| `build.zig.zon` 的 `iterm2_themes` 条目 | 上游每周的 `update-colorschemes.yml`（已归档，随同步获得） | 同第一行 |
| `CODEOWNERS`、`.github/VOUCHED.td` | 上游 vouch 机器人（已归档） | 只随同步更新 |
| `graphify-out/` 的两份入库产物 | 被索引源码 → `just graph` | `just graph-check` |
| `docs/kb/chunks.json` | KB 语料 → `just kb` | `just kb-check` |
| `nix/zigCacheHash.nix` | 无：注释与 `HACKING.md` 称由脚本生成，但现行脚本不写它，也无引用 | 上游遗留，勿手改 |

构建期派生、不入库：`help_strings`（`src/helpgen.zig`，供 `+help`、man 页与网站数据）、Unicode 表（`src/build/UnicodeTables.zig`）、`+boo` 帧数据（`src/build/GhosttyFrameData.zig`）、GTK 资源（`src/build/SharedDeps.zig::gtkNgDistResources`，`.blp` 检查用 `nix/build-support/check-blueprints.sh`）、安装资源（`src/build/GhosttyResources.zig`：terminfo 源 `src/terminfo/ghostty.zig`、`src/extra/` 的补全与语法、主题、Linux 桌面文件）、`-Demit-docs` 与 `-Demit-webdata` 的文档、Doxygen API 文档。

源码包：`zig build dist`（`src/build/GhosttyDist.zig::init`）对 `HEAD` 做 `git archive`，附上 `VERSION` 并预置 GTK 资源与帧数据（`src/apprt/gtk/ghostty_resources.c`/`.h`、`src/build/framegen/framedata.compressed`），lib-vt 模式按 `lib_vt_excludes` 剔除无关目录；`zig build distcheck` 解压后在包内跑测试，lib-vt 模式另跑 CMake 构建。

## 9. 版本与发布

**产品版本**：`build.zig` 优先读源码包里的 `VERSION`，否则取 `build.zig.zon` 的 `.version`（当前 `1.3.2-dev`），`src/build/Config.zig::init` 只取其中 `X.Y.Z` 再定版：`-Dversion-string` 原样使用；作为依赖构建时为 `X.Y.Z`；否则由 `src/build/GitVersion.zig::detect` 探测——无 git 时为 `X.Y.Z-dev+0000000`，`tip` tag 视为预发布，`v` 前缀 tag 必须恰好是 `vX.Y.Z`（否则 `@panic`），其余为 `X.Y.Z-<分支>+<短 hash>`（分支名的非 `[0-9A-Za-z-]` 字符换成 `-`，本分支得 `1.3.2-gx-ghostty+<hash>`）。带预发布段的版本发布通道为 `tip`（`Config.addOptions`，`+version` 会显示）。libghostty-vt 版本是 `build.zig` 常量 `lib_version`（`0.1.0-dev`），可用 `-Dlib-version-string` 覆盖。

因此源码包没有 `.git` 时退化为 `X.Y.Z-dev+0000000`，解压在别的 Git 工作树之内（如 `distcheck` 解压在 `.zig-cache` 下）时会探测到外层仓库；release 构建一律显式传 `-Dversion-string`。测试构建也显式传：`scripts/zig_test.py::pinned_version_string` 给测试步骤固定 `-Dversion-string=X.Y.Z-dev+0000000`（与无 git 时的回退同形），否则版本串随提交哈希变化，每次提交都会让测试二进制整体重编。

**GX-0001**：上游遇到非 `v` 前缀 tag（如 `gx-v0.1.0`）也会 panic，打了 fork tag 的提交不传 `-Dversion-string` 就无法构建。补丁在 `src/build/Config.zig::init` 的 tag 判断处加 `fork(gx): GX-0001` 标记，让这类 tag 与 `tip` 一样跳过发布校验、回退到分支预发布版本；登记与移除条件见 [FORK_PATCHES.md](FORK_PATCHES.md)，由 `scripts/test_fork_patches.py` 锁定。

**fork 版本与发布**：fork 版本是根 `CHANGELOG.md` 中 `## X.Y.Z(TBD|YYYY-MM-DD)` 标题里最大的 SemVer（`just version`、`just version-check`），与产品版本互不同步。tag 为 `gx-vX.Y.Z`，release 名 `Ghostty GX X.Y.Z`，构建版本串 `<zon 的 X.Y.Z>-gx.<fork X.Y.Z>`（如 `1.3.2-gx.0.1.0`，发布通道显示 `tip`）。启用中的 workflow 只有 `gx-ci.yml` 与 `gx-release.yml`；发布只经手动触发的 `gx-release`，prepare 先过 resolver、版本、`kb-check`、`graph-check`，由唯一有写权限的 publish job 发布（见 [RELEASE.md](RELEASE.md)）。

## 10. 图谱与知识库

- **图谱**：`just graph`（`scripts/graphify.py`，钉版 graphifyy 0.9.73，装在 `.local/tools/venv`）以仓库根为索引根、`.graphifyignore` 为排除表；入库 `graphify-out/GRAPH_REPORT.md` 与 `graphify-out/source-fingerprint.json`，约 20 MB 的 `graph.json` 只留本机；`just graph-query <问题>` 查询。指纹覆盖 graphify 会索引的全部代码扩展名（`scripts/graphify_fingerprint.py::INDEXED_EXTENSIONS`，至少含 `.zig .swift .c .h .cpp .cc .hpp .m .mm .metal .py .sh .bash`）中未被排除的文件、管线脚本与入库报告，没有 `graph.json` 也能 `just graph-check`。graphify 固定跳过名为 `build`、`dist`、`target` 的目录，所以 `src/build/**` 不在图里，查构建逻辑要直接读源码；新鲜度只在 `gx-release` 的 prepare 与上游同步后（`just generated-check`）强制。
- **知识库**：`docs/kb/chunks.json`，`just kb` 构建、`just kb-check` 校验、`just kb-query <词>` 检索（BM25）。语料是根与嵌套 `AGENTS.md`、上游与 fork 的说明文档、`docs/AGENT_RULES/*.md`、`src/**/*.zig` 的 `//!` 与 `pub` 签名、`include/ghostty/**/*.h` 的声明摘要；`kb-check` 属于 `framework-check`。

## 11. 上游同步面

| 类别 | 文件 | 同步时 |
|---|---|---|
| fork 独占 | 第 2 节列出的 fork 新增路径 | 不冲突；上游新路径要在 `routes.toml` 登记 |
| 上游文件 + 追加段 | 根 `AGENTS.md`（`<!-- gx-fork: … -->` 以下）、`.gitignore`、`.prettierignore`（`# --- GX fork：` 段） | 标记以上取上游，标记段原样保留 |
| 上游文件 + 补丁 | `src/build/Config.zig`（GX-0001）、`build.zig`（GX-0002） | 按 [FORK_PATCHES.md](FORK_PATCHES.md) 复核 |
| 上游文件移位 | 15 个上游 workflow 原样移到 `.github/workflows-archive/` | 上游新增的 workflow 也 `git mv` 进归档，不启用 |
| 上游独占 | 其余全部，含 `.agents/`、9 份嵌套 `AGENTS.md`、`CODEOWNERS`、lint 配置、`dependabot.yml` | 取上游 |

流程：`main` 只快进到 `upstream/main`；在 `gx_ghostty` 上 `git merge --no-ff main`，信息用 `chore(sync): 合并上游 main（<sha>）`；再跑 `just framework-check`、`just ci-check`，重建 KB 与图谱后跑 `just generated-check`。永不 force push、不推送 `upstream`。步骤见 [DEVELOPMENT.md](DEVELOPMENT.md)「上游同步」。
