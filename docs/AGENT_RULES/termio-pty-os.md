# termio-pty-os：终端 IO、子进程、pty 与 OS 辅助

## 范围

- termio：`src/termio.zig` 与 `src/termio/**`（`Termio`、`Thread`、`Exec`、`backend`、`mailbox`、`message`、`stream_handler`、`Options`）。`src/termio/shell_integration.zig` 同属 `shell-integration`，注入细节以那份文档为准。
- 子进程与 pty：`src/Command.zig`、`src/pty.zig`、`src/pty.c`（Linux、FreeBSD、macOS 的 openpty 等 C 头，经 translate-c 以 `pty-c` 模块引入，见 `src/build/SharedDeps.zig`）。
- fork 的 Windows 支持 `src/gx/conpty.zig`（随包 ConPTY，补丁 GX-0007）与 `src/gx/osc7.zig`（OSC 7 路径，补丁 GX-0008），模块约定同属 `gx-core.md`。
- OS 辅助 `src/os/**`。以下文件另属其他域，改动时两边规则都要满足：`cgroup.zig`、`flatpak.zig`、`i18n.zig`、`i18n_locales.zig` 属 `apprt-gtk`；`macos.zig`、`cf_release_thread.zig` 属 `macos-app`；`shell.zig` 属 `shell-integration`；`wasm/**`、`mach.zig`、`stderr.zig`、`string_encoding.zig`、`windows.zig` 属 `libghostty-vt`。
- 这几个 lib-vt 文件经以下引用进入 libghostty-vt 的导入闭包，因此同时受 `libghostty-vt.md` 的 freestanding 约束：`stderr.zig`（被 `src/lib_vt.zig`、`src/terminal/c/sys.zig` 引用）、`windows.zig`（被 `src/terminal/page.zig`、`src/terminal/mem.zig`、`src/lib/tinyio/` 引用）、`mach.zig`（被 `src/terminal/PageList.zig` 引用）、`string_encoding.zig`（被 OSC 133 解析器 `src/terminal/osc/parsers/semantic_prompt.zig` 引用）。

## 符号真源

- `src/termio/Termio.zig::Termio`：持有 `terminal`、`terminal_stream`（`StreamHandler.Stream`）、`backend`、`mailbox` 与 `renderer_state` 指针；入口 `processOutput`、`processOutputLocked`、`queueMessage(msg, MutexState)`、`queueWrite`、`changeConfig`、`resize`、`threadEnter`；`ThreadData` 只给写线程用。
- `src/termio/Thread.zig::Thread`：写线程（xev loop）。`threadMain` 调 `threadMain_`，`drainMailbox` 逐条处理消息；resize 按 `Coalesce.min_ms`（25ms）合并，同步输出超时 `sync_reset_ms`（1000ms），选区自动滚动间隔 `selection_scroll_ms`（15ms）。
- `src/termio/mailbox.zig::Mailbox`：目前只有 `spsc`，即 `BlockingQueue(termio.Message, 64)` 加 `xev.Async` 唤醒；接口 `send(msg, mutex)` 与 `notify`。
- `src/termio/message.zig::Message`：写线程消息。`WriteReq = MessageData(u8, 38)`，文件内无名测试把 `@sizeOf(Message)` 锁在 40 字节。
- `src/termio/stream_handler.zig::StreamHandler`：`terminal.Stream` 的应用侧 handler，`vt`/`vtFallible` 执行 VT 动作，并产生 pty 回复、surface 消息与 renderer 消息。libghostty-vt 用的是 `src/terminal/stream_terminal.zig::Handler`（`terminal-core` 域）。
- `src/termio/Exec.zig`：`Subprocess`（环境、argv、cwd，`start`/`stop`/`resize`/`killCommand`）、`threadEnter`（启动子进程、退出 watcher、termios 轮询与读线程）、`threadExit`、`ReadThread`（`threadMainPosix` 与 `gatherMainPosix`、`threadMainWindows`）、`execCommand`、`queueWrite`。`src/termio/backend.zig::Backend` 目前只有 `exec` 一种。
- `src/pty.zig::Pty`：编译期选 `PosixPty`、`WindowsPty`（ConPTY）或 `NullPty`（iOS 占位）；另有 `Mode`、`ProcessInfo`、`winsize`。
- `src/Command.zig::Command`：POSIX 走 fork/exec，Windows 走 `CreateProcessW` 加伪控制台。`os_pre_exec`、`rt_pre_exec` 在子进程 exec 前运行，`rt_post_fork` 在父进程运行；另有 `wait` 与 `error.ExecFailedInChild`。
- `src/os/main.zig` 是 OS 辅助的导出面：`xdg`、`homedir`、`passwd`、`path`、`pipe`、`locale`、`resourcesDir`、rlimit 与临时目录（`file.zig`）、`TempDir`、`open`、`uri` 与 `hostname`（OSC 7 校验）、`windows`、`FlatpakHostCommand` 等。

## 不变量

### 数据流与锁

- 输出路径：读线程（POSIX 是 `io-gather` 采集加 `io-reader` 解析的两级流水线，Windows 是单循环）→ `Termio.processOutput` 获取 `renderer_state.mutex` → `processOutputLocked`：先唤醒渲染，按 500ms 节流重置光标闪烁；有 inspector 时逐字节记录（慢路径），否则 `terminal_stream.nextSlice`；handler 期间若给写线程发过消息，末尾统一 `mailbox.notify`。
- 每处理完一个批次，读线程调用 `renderer_state.yieldToDemand`，把锁让给用 `lockDemand` 排队的渲染快照，避免渲染被饿死；新增的读侧热循环必须保留这个让步点。
- 终端状态（`Terminal`、`Screen`、`PageList`）的任何读写都要持有 `renderer_state.mutex`；`Termio.ThreadData` 只由写线程访问，无需加锁。
- `Mailbox.send` 的锁约定：调用方已持有 `renderer_state.mutex` 时必须把它传进来，即 `queueMessage(msg, .locked)`。队列满时 `send` 会唤醒写线程、解锁、阻塞入队、再重新加锁（唤醒失败则丢弃消息并记日志）；写线程处理 resize、focus 等消息时自己也要拿这把锁，持锁阻塞就会死锁。未持锁则传 `.unlocked`。
- `StreamHandler` 给 surface 与 renderer 发消息时（`surfaceMessageWriter`、`rendererMessageWriter`）用同一模式：先 `instant` 推送，失败再解锁（renderer 一侧先唤醒渲染线程）、阻塞推送、重新加锁。
- `Termio.queueWrite` 只能在写线程调用；其他线程发 `write_*` 消息，surface 侧统一经 `Surface.queueIo`。
- 写线程出错（如 `OpenptyFailed`，或配置的 `input` 读不到）时，`Thread.threadMain` 在锁内把错误说明印到终端上；若 loop 尚未停止，则置 `flags.drain` 再跑 loop，此后的消息只释放、不处理。

### StreamHandler

- 它有状态，寿命与终端相同。源码注释写明：停掉一个再新建一个继续用是无效的，除非复制全部成员。配置变化走 `StreamHandler.changeConfig`（由持锁的 `Termio.changeConfig` 调用），不替换 handler。
- `vtFallible` 对 `Stream.Action.Tag` 穷举，未实现的动作显式列出（`title_push`、`title_pop`、`kitty_dnd`、`osc_unknown`）。`src/terminal/stream.zig` 新增动作时，这里和 `src/terminal/stream_terminal.zig::Handler` 都要处理。

### 子进程与 pty

- `Command.start` 在 fork 之前用 arena 完成全部分配（源码注释：fork 与 exec 之间 malloc 属未定义行为）。子进程里只做 fd 重定向、`chdir`（失败忽略、不记日志，因为 stderr 已指向 pty）、恢复 rlimit、pre-exec 回调与 `execve`。pre-exec 回调（如 GTK 的 `src/apprt/gtk/pre_exec.zig::preExec`）同样不做堆分配，返回非 null 时子进程以该值退出。exec 失败时向 stderr 说明原因并返回 `error.ExecFailedInChild`，`Exec.threadEnter` 收到后直接 `std.process.exit(1)`，绝不回到父进程逻辑。
- POSIX pty：master 设 `FD_CLOEXEC` 并打开 `IUTF8`；子进程 `childPreExec` 复位信号、`setsid`、`TIOCSCTTY`，然后关闭 master 与 slave；父进程启动成功后关闭 slave。进程级忽略 `SIGPIPE`（`src/global.zig::GlobalState`）。
- 停止子进程：`killPid` 对进程组循环发 `SIGHUP`，直到 `waitpid(WNOHANG)` 回收（Darwin 的 `EPERM` 忽略）；Flatpak 经 `FlatpakHostCommand` 走 D-Bus。`threadExit` 先停子进程，再写退出管道（Windows 另调 `CancelIoEx`），最后 join 读线程。
- 子进程环境由 `Exec.Subprocess.init` 组装：`GHOSTTY_RESOURCES_DIR`；`TERM` 与 `COLORTERM=truecolor`（找到资源目录时 `TERM` 取配置的 `term` 并设 `TERMINFO`，否则 `TERM=xterm-256color`；Windows 上恒为 `xterm-256color`、不设 `TERMINFO`，补丁 GX-0005）；`GHOSTTY_BIN_DIR` 并把它追加到 `PATH`；`TERM_PROGRAM`、`TERM_PROGRAM_VERSION`；删除 `VTE_VERSION`；shell 集成与 `GHOSTTY_SHELL_FEATURES`；最后叠加用户 `env`，有 cwd 时设 `PWD`。`GHOSTTY_SURFACE_ID` 的注入与 `GHOSTTY_LOG` 的移除在 `Surface.init`。这些都是对 shell 与外部程序的契约。
- argv 由 `execCommand` 生成：macOS 一律经 `/usr/bin/login -flp <user>`（自查 `.hushlogin` 决定是否加 `-q`），shell 形式的命令再包一层 `bash --noprofile --norc -c "exec -l …"`；其他 POSIX 把 shell 形式包进 `/bin/sh -c`（Flatpak 内加 `-l`）；Windows 直接执行 shell 值，裸 `cmd.exe` 解析为 `%COMSPEC%`，带参数时按 C 运行库的命令行规则切分（支持双引号，GX-0005）。direct 形式的 argv 原样传递。
- termios 轮询（200ms，用来识别密码输入）只在 POSIX 运行，Windows 上一旦启动就 `@panic`；失焦时停止。

### 平台与库约束

- Windows 分支由 win32 app 实际运行（`apprt-win32.md`）。渲染唤醒句柄按指针传递（`termio.Options.renderer_wakeup` 是 `*xev.Async`，GX-0005）：libxev 的 IOCP `Async` 把等待者存在结构体里，复制出的副本唤不醒渲染线程。读线程遇到管道断开、EOF 或零字节读即正常退出，退出管道用 `WriteFile`/`CloseHandle` 操作 Win32 句柄（GX-0005）。
- ConPTY：`WindowsPty.open` 经 `src/gx/conpty.zig::Instance.create` 优先载入 exe 旁成对的 `conpty.dll` 与 `OpenConsole.exe`（flags 0x6），缺任一或失败时退回 kernel32；`GHOSTTY_GX_CONPTY=system` 强制系统 ConPTY；缩放与关闭必须用创建它的同一实现（GX-0007）。`WindowsPty` 的输入端必须是带 `FILE_FLAG_OVERLAPPED` 的命名管道（libxev 的 IOCP 后端只用 overlapped 操作）。
- `WindowsPty.getProcessInfo` 返回 null；GX-0012 让 `Exec.Subprocess.getProcessInfo(.foreground_pid)` 在 Windows 上改报子进程（shell）的 pid，供关闭确认与 herdr 应用模式列进程（`src/gx/confirm.zig`、`src/gx/app_mode.zig`）。OSC 7 在 Windows 上经 `src/gx/osc7.zig::nativePath` 转成盘符路径后存为 pwd，新标签与分屏据此继承工作目录（GX-0008）。
- lib-vt 闭包里的 `os` 文件（见「范围」）不得引入 libc、`global.zig`、termio 或 apprt 依赖，必须能编到 `wasm32-freestanding`。
- `src/os/` 新代码优先显式接收 `io`、`alloc`、`environ_map`（参照 `src/os/xdg.zig`、`src/os/homedir.zig`），不读全局环境。`src/os/locale.zig::ensureLocale` 会改进程环境，只在 `global.init` 里调用，并断言非测试。
- 读管线常量（`ReadThread.buffer_count`、`buffer_capacity`、`bridge_*`、`gather_budget_ns`）的取值依据（实测数据或延迟预算）写在各自注释里，改动要给出同等证据；`src/benchmark/TerminalStream.zig` 的读缓冲刻意与 `buffer_capacity` 一致，改一处要同步另一处。

## 禁止项

- 持有 `renderer_state.mutex` 时用 `.unlocked`（或空 mutex）发 termio 消息；未持锁却传 `.locked`。
- 在写线程以外调用 `queueWrite`，或在 handler、读线程里直接写 pty。
- 运行期替换 `StreamHandler` 或重建 `terminal_stream`。
- 在 fork 与 exec 之间做堆分配、在正常路径写日志，或让子进程回到父进程流程；让 master fd 被子进程继承。
- 在 Windows 上启动 termios 轮询。
- 无意中让 `termio.Message` 变大，或为了通过而改 40 字节尺寸测试。
- 让 lib-vt 闭包里的 `src/os/` 文件依赖 libc、全局状态或 termio。

## 验证

- 定向测试：`just test --filter Command:`（fork/exec、环境变量、工作目录）、`just test --filter execCommand`（各平台 argv）、`just test --filter printf_q`（`string_encoding`）、`just test --filter expand:`（`src/os/path.zig` 的 PATH 查找）。
- 无名测试（`src/pty.zig` 的 open 与 resize、`src/termio/message.zig` 的尺寸锁）随完整 `just test` 运行；Windows 上 `pty.test` 经同一入口走系统 ConPTY。
- 平台分支各自验证：Windows 分支（ConPTY、`threadMainWindows`、`Command` 的 Windows 路径、`execCommand windows:` 用例）用本机 `just build` 与 `just test --filter execCommand --filter pty.test --filter gx.conpty --filter gx.osc7`；POSIX 分支用 `just wsl test --filter <名>` 或 gx-ci 的 `linux-main`。运行行为（输出刷新、`exit` 后关窗、ConPTY 日志行）按 `apprt-win32.md` 启动 app 检查。
- 改 lib-vt 闭包里的 `os` 文件：`just test-vt`、`just build-vt`、`just vt-wasm`。
- 改读管线或 StreamHandler 热路径：按 `src/benchmark/AGENTS.md` 的流程对比前后吞吐，用 `just build -Demit-bench -Doptimize=ReleaseFast` 构建 `ghostty-bench`，`+terminal-stream` 近似 IO 线程的解析负载；真实 pty 下的读线程收益没有基准覆盖，记 PENDING。
- 改 Zig 后跑 `just fmt-check`。

## 上游指令

- `src/benchmark/AGENTS.md`：改读管线或解析热路径、需要做性能对比时必读。
