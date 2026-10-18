# apprt-win32：Windows 原生应用运行时

## 范围

- fork 新路径 `src/apprt/win32.zig` 与 `src/apprt/win32/**`：Windows 目标默认的 apprt（GX-0003 在 `src/apprt/runtime.zig::Runtime` 加入 `win32` 并设为 Windows 默认值），移植自 MIT 许可的 shiweis/ghostty-windows@119b9270c 后按模块拆分，文件头注明出处。
- 渲染钩子 `src/renderer/opengl/wgl.zig`（GX-0004，同属 `renderer`）；编进 exe 的 `dist/windows/gx/ghostty-gx.rc`（GX-0026 让 `src/build/GhosttyExe.zig` 选用）引用 `ghostty-gx.ico` 与上游 `dist/windows/ghostty.manifest`，上游 `ghostty.rc`、`ghostty.ico` 不再编进 exe（同属 `packaging-dist`）。
- GUI 自动化 `scripts/gx_win_gui.py`、场景 `test/gui/win32/**` 与测试根守门 `scripts/test_gx_test_roots.py`（同属 `testing`）。
- 分界：apprt 接口、Surface 生命周期与 `needsConfirmQuit` 见 `app-core.md`；共享核心 `src/gx/**` 见 `gx-core.md`；DirectWrite 见 `font.md`；ConPTY 与 termio 的 Windows 分支见 `termio-pty-os.md`；便携包与安装包见 `packaging-dist.md`。

## 符号真源

### 模块

| 模块 | 职责 |
|---|---|
| `App.zig`、`shortcut_conflicts.zig` | 窗口类 `GhosttyWindow`、`GhosttyTerminal`（`CS_OWNDC`）与消息窗口 `GhosttyMsg`；消息循环 `run`、`wakeup`、`performAction`、`gxAction`；默认 shell、全局热键、托盘通知；快捷键冲突检测（`RegisterHotKey` 试注册与 TSF 保留键查询） |
| `Window.zig` | 顶层窗口：标签模型（每个标签一棵 split tree）、分屏布局、DPI、窗口位置、首帧前 cloak、herdr 应用模式、关闭标签与窗口；纯函数在 `tabs.zig`、`splits.zig` |
| `Surface.zig` | 每个终端一个子 HWND：按键、IME、鼠标、拖放、剪贴板、标题与光标；持有查找栏、链接预览、滚动条与 `frame_event`；命令面板由 Window 持有 |
| `chrome/TitleBar.zig`、`chrome/TabBar.zig`、`chrome/Backdrop.zig` | 集成标题栏（`WM_NCCALCSIZE`、`WM_NCHITTEST`、Snap Layouts）；Direct2D 标签栏；DWM 主题、窗口材质与按像素透明 |
| `ui/d2d.zig`、`ui/style.zig`、`ui/anim.zig` | D2D/DirectWrite 绑定与 `Canvas`（DIP、像素对齐、文字缓存；`Color` 即 `gx.ui_color.Color`，`colorRef` 转 GDI 色）；设计 token（尺寸为 4 DIP 的倍数，编译期校验）；帧时钟与 `Tween` |
| `ui/Popup.zig`、`ui/controls.zig`、`ui/text_edit.zig`、`ui/Notice.zig`、`ui/Toast.zig` | 弹层（首帧揭幕、输入法 `TextInput`）；共用控件；编辑模型；提示条与 Toast |
| `ui/Palette.zig`、`ui/Keybinds.zig`、`ui/trigger.zig` | 命令面板、快捷键速查表、绑定键帽与菜单提示（`Hints` 跳过冲突按键） |
| `ui/Menu.zig`、`ui/MenuPopup.zig` | 主菜单、启动配置菜单、右键菜单；自绘模态菜单 |
| `ui/Settings.zig`、`ui/settings/*.zig` | 设置浮层（六页，关于页显示 `gx.branding` 的非官方分支声明），写 `gui-settings.ghostty` 后重载配置 |
| `ui/Dialogs.zig`、`ui/SearchBar.zig`、`ui/LinkPreview.zig`、`ui/ResizeOverlay.zig`、`ui/ShortcutNotice.zig`、`Scrollbar.zig` | 主题化对话框、查找栏、链接预览、尺寸提示、快捷键冲突提示条、细滚动条 |
| `QuickTerminal.zig`、`file_log.zig`、`win32.zig`、`ui/wstr.zig` | 快速终端；日志 `%LOCALAPPDATA%\ghostty\logs\ghostty.log`；Win32 声明；UTF-8 转 UTF-16 |
| `clipboard.zig`、`open_url.zig` | 打开剪贴板的有界重试；在工作线程上用 `ShellExecuteW` 打开 URL |
| `Leaf.zig`、`Pane.zig`、`PaneSnapshot.zig` | split tree 的叶身份（本地 Surface 或远程窗格）与借用适配器 |
| `RemotePane.zig`、`RemotePaneUi.zig`、`RemoteInput.zig`、`RemoteSurfaceView.zig`、`ui/uia_remote.zig` | 目标端远程窗格：画面、原生输入与目标侧 UI |
| `RemoteSource.zig`、`RemoteHost.zig`、`RemoteCoordinator.zig`、`TabTransfer.zig` | 源端输入与绑定续延（GX-0044）；隐藏宿主保留 PTY 与渲染线程；跨进程迁移、收回与拖回 |
| `ipc/*.zig` | 本机认证命名管道：单实例选主与转交、远程通道、专用拖放 broker |
| `Session.zig`、`ShellIntegration.zig`、`shell/*.zig` | 会话恢复；Shell 身份、WinRT Toast、通知激活与 JumpList |
| `ole_drop.zig`、`drop_data.zig`、`DropBridge.zig`、`DropCompanion.zig`、`ui/DropFeedback.zig` | OLE 拖入与 protected paste；高权限端 broker 适配与 medium 接收窗口 |
| `ui/uia.zig`、`ui/uia_bridge.zig`、`ui/dcomp.zig`、`ui/fluent_icons.zig`、`key_translate.zig` | UIA 快照发布；弹层 DComp 实验；Fluent 几何缓存（随 D2D factory 释放）；物理键解码 |

### 线程与渲染钩子

- GUI 线程跑 `App.run` 的 `GetMessageW` 循环，HWND、GDI、Direct2D 与 COM UI 对象只在它上面创建和使用。`App.wakeup` 可从任意线程调用，只向 `msg_hwnd` 投递 `WM_APP_WAKEUP`，收到后执行 `core_app.tick`。
- `wgl.Device` 一次选定 OpenGL 实现：系统驱动能建 4.3 core context 就用它，否则用 exe 旁 `mesa\opengl32.dll` 的 llvmpipe（`GHOSTTY_GX_OPENGL=software` 直接用 Mesa）。pixel format 在主线程设定，context 在渲染线程的 `threadEnter` 创建（NVIDIA 下 `wglMakeCurrent` 会瞬时失败，按次数重试）。
- `present` blit 后 `SwapBuffers`，再经 `@hasDecl` 回调 `Surface.signalFrameDrawn` 置位 `frame_event`。只有远程源的隐藏宿主经 GX-0043 在渲染线程读回 BGRA 写进 `RemoteHost` 映射，GUI 不调 GL。GPU 重置时 `present` 留旧 context、持 `draw_mutex` 调 `Surface.gpuContextReset`（标未 realize、投 `WM_APP_GPU_RESET`）；帧归还后 GX-0050 在旧 context 释放资源再换新的，GUI 经 `GR` 计时器再 realize。
- `frame_event` 手动复位：live resize 时发布目标尺寸，`Window.PaneLayout` 调 `Surface.awaitResizeFrames` 以一个 16 ms deadline 等各 pane 的匹配尺寸帧；新窗口首帧前保持 cloak，`WM_APP+31` 按 core id 揭幕，`FIRST_FRAME_TIMER_ID` 以 `Window.first_frame_timeout_ms`（300 ms）兜底。

### 消息与计时器 ID 登记表

ID 只在同一 HWND 内唯一。窗口私有消息与测试钩子用 `WM_USER + n`，跨模块投递的应用消息用 `WM_APP + n`；共享 HWND 上的计时器用两个 ASCII 字母编码。

| HWND | 自定义消息 | 计时器 |
|---|---|---|
| `GhosttyMsg`（`App.msg_hwnd`） | `WM_APP+1` WAKEUP、`WM_APP+3` TRAY、`WM_APP+36` EXPORT_TERMINAL_IO、`WM_APP+0x62` QUIT、`+0x63` IPC、`+0x64` DROP、`+0x65/+0x66` DROP_REGISTER/DROP_REAP（仅唤醒外层循环）、`+0x67` UIA、`+0x68` SHELL、`+0x69` REMOTE、`+0x6B/+0x6C` DropBridge/DropCompanion 唤醒；另有 `+6` DEFERRED_GX、`+34` OPEN_LINK | 1 退出延时、2 通知气泡、3 `QuickTerminal.ANIM_TIMER_ID`、4 快捷键冲突检测、5 任务栏进度、`SS` session 保存防抖、`SH` toast 服务保活、`RM` 远程重试、`PT` 撤销面板主题预览（`ui/Palette.zig` 的 TIMERPROC） |
| `GhosttyWindow` | `WM_APP+20` MAIN_MENU、`+31` FIRST_FRAME（core id）、`+38` OWNER_ACTIVE_LOCK、`+42/+43` SYNC_ACTIVATION/NATIVE_FALLBACK、`+0x61` CLOSE_TAB、`+0x68` TAB_DETACH；`WM_USER+0x47` SIMULATE_DPI、`+0x49` SIMULATE_SYSTEM_THEME、`+0x4A/+0x4B` WINDOW_STATE/SIMULATE_OCCLUSION、`+0x4C/+0x4D` SIMULATE_D2D_FAILURE/CAPTION_QUERY；`+0x4F/+0x50` REMOTE_BEGIN/QUERY（须 `GHOSTTY_GX_REMOTE_TEST=1`） | `HQ` 应用模式（旧 `HD` 退役）、`FF` 首帧、`CH` 标签栏轮询、`TT` 提示、`RG` 尺寸提示、`SN` 快捷键冲突提示条 |
| `GhosttyTerminal` | `WM_APP+0x60` CONFIRM_CLOSE、`+30` GPU_RESET、`+32` CHILD_EXITED、`+33` CONFIRM_CLIPBOARD、`+35` RELEASE_BUTTONS、`WM_USER+0x48` SIMULATE_GPU_RESET（测试钩子） | `CR`、`CW` 剪贴板重试，`GR` GPU 重置 |
| 滚动条弹层 | `WM_USER+1` SCROLLBAR_QUERY | 1 淡出、2 空闲 |
| 其他弹层（`Popup`） | `WM_APP+39`、`+40` Notice、Toast 投递后显示；`WM_USER+0x4E` POPUP_DCOMP（实验的 reset/failure/query） | `RV` 首帧揭幕、`CB` 插入符、`RP` 按住连发；Notice `NT`、`NW`，Toast `TS`、`TW`；命令面板与设置浮层另用带 TIMERPROC 的小整数；`MenuPopup` 用线程计时器 |
| `GhosttyGxAnimClock`（`ui/anim.zig`） | `WM_APP+37` TICK | 无 |

### 输入、IME、DPI 与文字

- 按键：`App.run` 对终端子窗口的按键跳过 `TranslateMessage`（`Surface.handleKeyEvent` 自己调 `ToUnicode`，共用死键状态），`VK_PROCESSKEY` 与 `VK_PACKET` 除外。按键、`WM_CHAR` 与上屏文字都经核心 `Surface.gxWin32KeyCallback`（GX-0006，契约见 `src/gx/win32_input.zig` 文件头），DECSET 9001 开时按 KEY_EVENT_RECORD 发出；粘贴与拖放不走记录，拖放路径按 shell 引用（`gx.path_quote`）。
- 弹层编辑框：`App.routeEditKey` 与纯函数 `App.editKeyRoute` 分流：编辑键、输入法与修饰键留给编辑框；`trigger.isBound` 命中绑定的 Ctrl 组合交给终端绑定（查找栏只交出焦点、不结束搜索）；其余 Ctrl 组合吞掉，未绑定的 Ctrl+Alt 按 AltGr 输入。查找栏从外部关闭一律经核心 `end_search`；Alt+Space 由 `Window.handleSystemMenuKey` 打开窗口菜单。
- 快捷键冲突：`App.probeShortcuts` 在首窗显示约 1 s 后与每次重载后（计时器 4）试注册带修饰键的绑定并查 TSF 保留键，结果 `App.shortcut_conflicts` 供速查表标记、`trigger.Hints` 跳过；用户可见行为见 `docs/GX_FEATURES.md`「快捷键冲突」。
- IME：组字串作为 preedit 交给核心内联显示，候选窗由 `Surface.positionImeWindow` 按 DPI 放到光标处；终端失焦时取消组字。
- 剪贴板：`OpenClipboard` 都经 `clipboard.open`（有界重试，应对剪贴板管理器与远程桌面的短暂占用），终端读写另由 `CR`、`CW` 计时器再试约 0.6 s。自绘输入框粘贴只取第一行，截到 `text_edit.max_len`（4096 个 UTF-16 码元）。
- `WM_SETTINGCHANGE` 只发给顶层窗口：滚动条模式由滚动条弹层自己处理，预留宽度变了经 `Surface.refitGrid` 重排。
- DPI：PerMonitorV2。只有顶层窗口收到 `WM_DPICHANGED`：`Window.handleDpiChange` 重排 chrome 并转给每个 Surface，弹层自己处理。chrome 及其提示、菜单与新终端的初始缩放一律取 `Window.scale`（弹层经 `Popup.setOwnerScale`），只有 Windows 与 DWM 自己画的部分取 `GetDpiForWindow`；`WM_GHOSTTY_SIMULATE_DPI` 只改 `Window.scale`，混用两者在模拟时就会错位。
- 界面文字：英文 msgid 经 `gx.i18n.tr`/`trRuntime` 翻译；菜单与对话框每次显示时重建，语言切换经 `onLanguageChanged` 下发（`gx-core.md`）。

## 不变量

- 线程：其他线程进入 apprt 的入口（`wakeup`、`signalFrameDrawn`、`gpuContextReset`、`anim` 时钟线程）只投递消息、置位事件或改渲染器自身的状态，不碰 HWND、Direct2D 与 apprt 的 UI 状态；GL 调用只在渲染线程（`renderer.md`）。
- 关闭：`Surface.close` 只投递 `WM_CLOSE` 或 `WM_APP_CONFIRM_CLOSE`，销毁一律在消息循环里进行，不在核心回调中关窗或释放 Surface。关闭分屏、标签、窗口与退出都先问核心 `needsConfirmQuit`（含 GX-0012 的空闲进程判断）。
- 模态循环（菜单、对话框、`MessageBoxW`、另存为）照常派发消息，其间任何对象都可能被释放：返回后重新解析 Window 与 Surface，不沿用裸指针；对话框打开期间窗口推迟自己的 `WM_CLOSE`，最外层对话框返回后再投递。窗口与终端销毁时清零 `GWLP_USERDATA`，据此丢弃迟到的消息。自绘对话框与菜单取到 WM_QUIT 时仅当 `App.quit_requested` 才结束并重投（`Popup.modalQuitCode`）。
- 弹层关闭：`WM_CLOSE`（Alt+F4、系统关闭、外部发来）把已显示的弹层隐藏而不销毁，以 `.owner` 报 `dismissed`；会取焦点且开着 `close_owner_on_close` 的弹层再关所属窗口；未显示的弹层忽略它（`taskkill` 已发给每个窗口）。`Dialogs` 关掉 `close_owner_on_close`，外部关闭按取消结束模态循环。
- 持锁回调：核心持 `renderer_state.mutex` 时会回调 apprt（如 `open_url`、`setClipboard`、`export_terminal_io`），它们不得泵消息或跑模态循环（重入核心再取锁即自锁）：URL 交给 `open_url.zig` 的工作线程，另存为对话框经 `WM_APP_EXPORT_TERMINAL_IO` 回到消息循环。
- 菜单只从窗口消息里打开：绑定动作经 `Window.queueMainMenu` 投递 `WM_APP_MAIN_MENU`，同一时刻只开一个菜单。
- Direct2D 可能不可用（`App.uiFactory` 返回 null）：自绘 UI 要有退路，对话框退回 `MessageBoxW`。
- 按像素合成：`Backdrop.perPixel` 的顶层窗口开了 DWM blur-behind，按客户区像素 alpha 合成，GDI 画出的像素 alpha 为 0 即全透明；在顶层窗口与终端子窗口上作画一律经预乘 32bpp DIB（`Backdrop.fillBackground`、`fillOpaque`），不直接用 `FillRect` 或画笔；能否按像素合成启动时定一次（`App.alpha_frames`）。
- 颜色与动效以 `src/gx` 为真源：`style.Tokens` 逐字段镜像 `gx.ui_tokens.Tokens` 并带 `gx.chrome` 的颜色（编译期校验），`anim` 只留时钟与 `Tween`，时长与曲线取 `gx.motion`；改色值、对比度或动效先改 `src/gx`，不在 win32 另写常量。时钟线程随首个动画启动并 detach 常驻；tick 回调可先 `stop` 自己再释放所有者。
- 新增自定义消息或计时器先查上表，同一 HWND 不重号，`WM_TIMER` 分派保持完整，并把新 ID 写进上表。
- 配置：`App.config` 只在 GUI 线程的 `config_change` 中替换；token 在绘制时由当前配置派生（`style.Tokens.fromConfig`），不跨线程缓存 `*const Config`。
- 外部线程（UIA MTA、WinRT、IPC 与 broker 工作线程）只拿 owned 快照或投递消息，不借用 Surface、RemotePane 或帧映射；GUI 实际执行后才回复成功。OLE 注册 HWND 在外层循环撤销注册后才销毁；拖入与远程粘贴走 protected paste，不自动加 Enter。
- 远程：源持有终端、PTY、渲染与绑定，目标只持有画面与 UI；断连不重放已执行的输入或动作；混合标签不跨进程，Quick Terminal 与 Session 不收远程叶。单实例转交（`App.routeInitialLaunch`）先于热键与 Surface，结果不明即报错退出。
- Popup DComp 仅 `GHOSTTY_GX_POPUP_DCOMP=1` 启用、只影响弹层，失败退回 legacy 绘制。

## 禁止项

- 不用 gettext 的 `_`、`N_`（Windows 构建默认 `-Di18n=false`），不写死任一语言的界面文字。
- 不在渲染线程调用 HWND、GDI 或 Direct2D，不在 GUI 线程调用 GL 或 `wglMakeCurrent`。
- 不在核心回调里运行模态循环，不跨模态循环持有 Window 或 Surface 指针。
- Windows 专属逻辑放在 `src/apprt/win32/**` 或 `src/gx/**`；必须改上游文件时按 GX-NNNN 登记（`development.md`）。
- 验证时不读写用户真实配置与日志，不为截图改系统设置；测试配置只放在隔离目录。

## 验证

- 构建：`just build`（Windows 主机自动补 `-Dtarget=x86_64-windows-gnu`，默认 `-Dapp-runtime=win32`）产出 `zig-out/bin/ghostty.exe`；发布形态 `just package-windows`。
- 单测：`just test --filter apprt.win32`，共享核心 `just test --filter gx.`（条数以运行器输出为准，零命中不算通过）。带测试的文件须在 `src/apprt/win32.zig` 的 `test` 块显式引用，否则会悄悄漏收（`python scripts/run_unittests.py test_gx_test_roots` 守门）。
- GUI 证据，GUI 可见改动必做：`just win-gui run --out <证据目录> [W01 …]` 回放 `test/gui/win32/W*.toml`（隔离、输入守门与单步子命令见 `docs/TESTING.md`）；步骤通过只说明断言成立，逐张读图核对后才记 PASS。改用其他截图方式时同样隔离并去掉 `NO_COLOR`。
- 已知坑：隔离后探测不到只装在真实 `%LOCALAPPDATA%\Programs` 下的 GX Zsh；微软拼音吞掉 Ctrl+Shift+F（先 `just win-gui ime-off <目录>`）；GUI 子系统的 exe 没有控制台，`+version` 等输出要重定向。
- CI：`gx-ci` 的 `windows-app` job（`ci-release.md`）；`win_smoke` 的截图读回前记 PENDING。
- 改 Zig 跑 `just fmt-check`；改了 `pub` 签名或 `//!` 文档跑 `just kb`。
