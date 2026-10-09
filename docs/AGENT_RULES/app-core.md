# app-core：App、Surface、apprt 接口与进程入口

## 范围

- 核心对象：`src/App.zig`、`src/Surface.zig`、`src/surface_mouse.zig`（后者也属 `input`）。
- apprt 接口层：`src/apprt.zig` 与 `src/apprt/*.zig` 中的 `action`、`surface`、`ipc`、`structs`、`runtime`、`none`、`browser`。同一 glob 还命中 `src/apprt/gtk.zig`（另属 `apprt-gtk`）与 `src/apprt/embedded.zig`（另属 `libghostty-embedding`、`macos-app`），它们的实现规则以那几份文档为准。
- 入口与进程状态：`src/main.zig`、`src/main_ghostty.zig`、`src/main_wasm.zig`、`src/global.zig`；libghostty C API 入口 `src/main_c.zig` 归 `libghostty-embedding`。
- 崩溃上报：`src/crash/**`、`pkg/sentry/**`、`pkg/breakpad/**`（两个 `pkg/` 同属 `build-system`）。
- 本文给出线程模型总览；termio 的线程与锁细节见 `termio-pty-os.md`，渲染线程与 `renderer/State.zig` 见 `renderer.md`。

## 符号真源

- 入口分派：`src/main.zig::entrypoint` 按 `build_config.exe_entrypoint`（`src/build/Config.zig::ExeEntrypoint`：ghostty、helpgen、mdgen_*、webgen_*）选根文件，再转出 `main` 与 `std_options`。
- `src/main_ghostty.zig::main`：`global.init(.{ .main = … })` → 有 `+action` 就执行并退出 → 否则 `App.create` → `apprt.App.init` → `run`。它的 `std_options`（日志级别、`logFn`）也被 `src/main_c.zig` 复用。
- `src/apprt.zig::runtime` 编译期选定唯一 apprt：exe 取 `app_runtime`（`none`/`gtk`），lib 取 `embedded`，`wasm_module` 取 `browser`。默认值来自 `src/apprt/runtime.zig::Runtime.default`：Linux/FreeBSD 为 gtk，其余为 none（不产出 exe，默认 install 改为构建 libghostty-internal；Windows 上它编译不过，见「验证」）。每个 apprt 必须提供 `App`、`Surface`、`resourcesDir`。
- `src/App.zig::App` 拥有：`surfaces`（`*apprt.Surface` 列表）、`mailbox`（`Mailbox.Queue = BlockingQueue(Message, 64)`）、`font_grid_set`（同字体配置的 surface 共享）、`device`（app 级 `renderer.Device`，各 surface 的 renderer 借用）、`config_conditional_state`。`tick` 只做 `drainMailbox`。
- `src/Surface.zig::Surface` 拥有：`renderer`、`renderer_state`（mutex 堆分配）、`renderer_thread`/`renderer_thr`、`io`（`termio.Termio`）、`io_thread`/`io_thr`、`inspector`、`search`、`config`（`DerivedConfig`）、`keyboard`/`mouse` 状态。`rt_app`/`rt_surface` 指回 apprt 对象，apprt 侧用 `core()` 取回 `*Surface`。
- 跨线程消息：`src/apprt/surface.zig::Message` 与 `Mailbox`（把消息包成 `App.Message.surface_message` 投到 app 线程）；`src/App.zig::Mailbox.push` 入队后调用 `rt_app.wakeup()`；app 线程经 `App.surfaceMessage` → `Surface.handleMessage` 处理。
- apprt 动作：`src/apprt/action.zig::Action`、`Target`、`Action.Key`（对应 `include/ghostty.h` 的 `ghostty_action_tag_e`）；IPC 为 `src/apprt/ipc.zig::Action`、`Target`；跨 apprt 的值类型在 `src/apprt/structs.zig`。
- 全局状态：`src/global.zig` 的私有 `state`、`init`/`deinit`、`InitOpts`（`.main`/`.tool`/`.c`）、`GlobalState`，以及访问器 `io`、`alloc`、`environ`、`environMap`、`args`、`resourcesDir`、`rlimits`、`tmpDirPath`、`logging`、`action`、`syncEnviron`。
- 崩溃：`src/crash/sentry.zig::init`/`deinit`/`thread_state`/`ThreadState`/`Transport`，`src/crash/dir.zig::defaultDir`，`src/crash/sentry_envelope.zig::Envelope`。构建开关 `-Dsentry` 在 `src/build/Config.zig`（默认只在 macOS/iOS 打开）；`src/build/SharedDeps.zig` 以 `backend = .breakpad` 链接 `pkg/sentry` 并追加 `pkg/breakpad` 静态库。查看报告的 `+crash-report` 在 `src/cli/crash_report.zig`（`cli-inspector` 域）。

## 不变量

### 线程模型

- 主线程跑 apprt 事件循环：GTK 的 `Application` 主循环调用 `App.tick`，macOS 宿主经 C API `ghostty_app_tick`。apprt 回调、`Surface.handleMessage`、`App.updateConfig`、`Surface.init` 都只在主线程执行（后两者的注释明确要求）。
- 每个 surface 的线程：`renderer`（`src/renderer/Thread.zig::threadMain`）、`io` 写线程（`src/termio/Thread.zig::threadMain`）、pty 读线程 `io-reader`，POSIX 上再加采集线程 `io-gather`；执行 `search` 绑定动作时按需创建 `search` 线程（`terminal.search.Thread`，与 surface 共用 `renderer_state.mutex`）。
- 进程级线程：`App.create` 分离启动字体发现与渲染设备的 `warmup`（后端提供时）；开启 Sentry 时有 `sentry-init`；macOS CoreText shaper 自带 CF 释放线程（`font` 域）。
- 非主线程不直接调用 App/Surface 方法，一律投递消息。消息必须自带内存：内联定长数据、`MessageData` 的 small/stable/alloc 变体，或 arena 持有的指针（如 `apprt.ClipboardRequest.KittyRead`），由接收方释放。
- `Surface.searchCallback` 在搜索线程执行，源码注释要求它只读 surface 上永不改变的值；结果经 renderer mailbox 与 surface mailbox 转交。

### 生命周期与所有权

- `Surface.init` 需要稳定指针（回调会保存它）。顺序：应用条件配置并派生 `DerivedConfig` → 从 `App.font_grid_set` 引用字体网格 → `Renderer.init`（借 `App.device`）→ 渲染线程状态与 `termio.Thread` → `termio.Exec`、SPSC mailbox、`Termio.init` → 启动 renderer 与 io 线程。`App.first` 决定是否使用 `initial-command`。
- `Surface.deinit` 先停 search 线程，再依次通知并 join 渲染线程与 io 线程，之后才释放共享状态（renderer、termio、inspector、键盘队列、`font_grid_set.deref`、mutex、`DerivedConfig`）。新增跨线程状态同样「先 join 后释放」。
- `App.deinit` 先销毁全部 surface，断言 `font_grid_set.count() == 0`，最后 `device.deinit()`。
- app 线程处理 surface 消息前用 `hasSurface` 确认目标仍在；`deleteSurface` 主动清空 `focused_surface`，因为分配器会复用地址，单靠 `hasSurface` 会误判（源码注释记录过这个缺陷）。`focusedSurface` 只在主线程、`tick` 之前有效。
- `DerivedConfig` 把所需配置复制进自己的 arena，surface 不持有 `Config` 指针。`Surface.updateConfig` 重新派生，向 renderer 发 `renderer.Message.initChangeConfig` 的结果、向 termio 发堆上的 `Termio.DerivedConfig`，并结束按键序列、停用全部 key table（它们持有旧配置里的指针）。`apprt.surface.Message.change_config` 的指针收到后即失效，必须当场派生。
- 写往 pty 的数据统一经 `Surface.queueIo`：只读模式（`readonly`）在这里丢弃并释放 `write_*` 消息。
- 关闭确认统一经 `Surface.needsConfirmQuit`（各 apprt 都调用它）：只读模式恒确认、子进程已退出不确认，其余按 `confirm-close-surface`。fork 补丁 GX-0012 在 `true` 且光标不在提示符时，经 `src/gx/confirm.zig` 列出终端里的进程（Linux 为前台进程组组长及其子孙，Windows 为 shell 及其子孙），全部空闲就不确认；列进程在主线程进行，不持有 `renderer_state.mutex`。
- `activateInspector`/`deactivateInspector` 在 `renderer_state.mutex` 下挂上或摘下 `renderer_state.inspector`，再通知 renderer 与 termio；inspector 包本身见 `cli-inspector.md`。
- `App.drainMailbox` 收到 `.quit` 立刻执行并返回，剩余消息留到下一次 tick。

### apprt 动作与 C ABI

- 新增 apprt 动作遵循 `src/apprt/action.zig::Action` 开头的「A GUIDE TO ADDING NEW ACTIONS」：`Key` 只在末尾追加（顺序直接映射 libghostty C 枚举），union 加值，非 void 值必须是 extern 或提供 `C` 与 `cval`，并同步 `include/ghostty.h`。`Action.CValue` 的大小由 comptime 断言锁在 24 字节；`src/apprt/ipc.zig::Action` 适用同一套规则（其 `CValue` 也有尺寸断言）。
- 动作对 apprt 是可选的，`performAction` 返回是否已处理；必需能力直接定义在 runtime 结构上，缺失就编译失败。
- `src/apprt/structs.zig` 里注明要同步 `ghostty.h` 的类型（`Clipboard`、`ClipboardReadResult` 等），以及按 `app_runtime` 穷举 `gtk`/`none` 的 `getGObjectType`，要一起维护；新增 `apprt.Runtime` 成员会波及所有这类 switch。

### 全局状态

- `src/main_ghostty.zig::main` 的注释说明：全局状态存在是因为 C API 需要访问它，其他 Zig 代码都不应访问。它只由 exe 的 `main`（`.main`）、工具二进制（`.tool`，跳过 app CLI 动作检测）或 libghostty 的 `ghostty_init`（`.c`，Windows 返回 `error.UnsupportedOSForCApi`）初始化。
- `src/global.zig` 在 `terminal_options.artifact == .lib` 时 `@compileError`，libghostty-vt 可达代码只要 import 它就编译失败。
- 现状：Zig 0.16 迁移后很多模块经 `global.io()`、`global.alloc()` 取 I/O 与分配器。测试构建中 `io`、`alloc`、`environ`、`environMap` 回退到 `std.testing` 的对应物，`args`、`resourcesDir`、`rlimits` 返回空值；`tmpDirPath`、`logging`、`action` 没有测试回退，`syncEnviron` 断言非测试。上游正把依赖改成显式传参，例如 `src/crash/sentry.zig::init` 接收 `environ_map`，`src/os/xdg.zig` 接收 `io`、`alloc`、`environ_map`。
- 进程环境只在启动阶段修改：`global.init`（`ensureLocale` 之后 `syncEnviron`）与 GTK `Application` 初始化（设 `LANG`、`LANGUAGE`、`GDK_DEBUG`、`GDK_DISABLE` 后同样 `global.syncEnviron`）。`syncEnviron` 没有并发控制，启动之后改用 `std.process.Environ.Map`。唯一的例外是 GX 界面语言的运行时切换（补丁 GX-0011）：gettext 每次查词都读 `LANGUAGE`，所以它在主线程 `setenv` 后 `syncEnviron`。`GHOSTTY_LOG` 控制日志去向；`Surface.init` 启动子进程前移除它，并注入 `GHOSTTY_SURFACE_ID`。

### 崩溃上报

- 默认不联网：`Transport` 只把含 event 的信封写成 `<uuid>.ghosttycrash`，放到 `crash.defaultDir`（XDG state 下的 `ghostty/crash`），由用户自行处理（见 `init` 的 PRIVACY NOTE）。
- `init` 在独立线程完成目录解析与 Sentry 初始化，环境快照归该线程所有；Windows 直接返回（不支持）。`deinit` 必须在调用 `init` 的同一线程执行，它会 join 初始化线程。
- 线程入口和 Surface 的每个 apprt 回调都设置 `crash.sentry.thread_state` 并 `defer` 复位，`beforeSend` 靠它填 surface 尺寸。新增线程入口或回调要照做。
- `crash` 绑定动作（`main`、`io`、`render`）用于人工触发对应线程的崩溃。

### 入口的已知状态

- `src/main_wasm.zig` 没有被任何构建步骤引用（wasm 产物走 `src/lib_vt.zig`）；`apprt.browser` 只有空的 `App` 与 `Window`，不满足 apprt 接口。不要把它当作可用入口。
- `src/main_ghostty.zig::main` 的 `app_runtime == .none` 分支调用了 Zig 0.16 std 已不存在的 `std.io.getStdOut()`。none 不产出 exe，目前没有任何产物会分析这段代码，改它得不到编译验证。

## 禁止项

- 不在非主线程调用 App/Surface 的公共方法；跨线程只发自带内存的消息。
- 不绕过 `Surface.queueIo` 直接调用 `io.queueMessage`，否则只读模式失效。
- 不在 `apprt.Action.Key`、`ipc.Action` 中间插入或重排成员；不改 C 可见类型而不同步 `include/ghostty.h`。
- 不新增全局可变状态；libghostty-vt 可达代码不 import `src/global.zig`；除上文 GX 界面语言切换外，不在启动阶段之外修改进程环境（`setenv`、`syncEnviron`）。
- 不让崩溃上报默认上传数据；不假设 Windows 上有 Sentry。
- 不先释放再 join；不跨 tick 保存未经 `hasSurface` 校验的 surface 指针。

## 验证

- 定向测试（`just test` 只在 Linux/macOS 可跑）：`just test --filter ghostty.h`（Zig 枚举与 `include/ghostty.h` 对账，含 `apprt.Action.Key`、`ipc.Action.Key`、`ipc.Target.Key`）、`just test --filter Envelope`（崩溃信封）、`just test --filter queueIo`、`just test --filter copyUtf8Z`、`just test --filter keyToMouseShape`。
- 编译覆盖：本机 Windows 没有本域代码的编译检查。`just build` 要构建的 libghostty-internal 与 `just test` 要构建的 `ghostty-test` 都经 `src/build/SharedDeps.zig::add`，卡在 translate-c 导入 `posix_c` 缺 `pwd.h`（`build-system.md`「平台」）：`just build` 退出 1，`just test` 直接退出 2，本机记 PENDING。POSIX 分支由 `gx-ci` 的 `linux-main` job（`-Dapp-runtime=none` 编译并运行整个 `ghostty-test`，不编 GTK apprt）与 Linux/macOS 开发机覆盖，GTK 在 gx-ci 里只由手动触发的 `gtk-smoke` 构建；只在 Windows 目标上才编译的分支目前没有任何编译检查。
- 改 apprt 动作、Surface 生命周期或主循环交互：本机没有 GUI，记 PENDING，GTK 交 `gx-ci` 手动触发的 `gtk-smoke` 截图；macOS 侧只能在 Mac 上验证（gx-ci 的 `macos` job 只跑 `zig build test-lib-vt`）。
- 崩溃链路（Sentry 默认只在 macOS 构建）：用 `crash` 绑定动作人工验证，本机记 PENDING。
- 改 Zig 后跑 `just fmt-check`。

## 上游指令

- `src/inspector/AGENTS.md`：Surface 负责 inspector 的启停；改 inspector 包本身时必读。
