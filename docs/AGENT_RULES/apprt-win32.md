# apprt-win32：Windows 原生应用运行时

## 范围

- fork 新路径 `src/apprt/win32.zig` 与 `src/apprt/win32/**`：Windows 目标默认的 apprt（补丁 GX-0003 在 `src/apprt/runtime.zig::Runtime` 加入 `win32` 并设为 Windows 默认值），移植自 MIT 许可的 shiweis/ghostty-windows@119b9270c 后按模块拆分，文件头注明出处。
- 渲染钩子 `src/renderer/opengl/wgl.zig`（补丁 GX-0004，同属 `renderer`），以及编进 exe 的资源：fork 的 `dist/windows/gx/ghostty-gx.rc`（GX-0026 让 `src/build/GhosttyExe.zig` 选用它）引用 Ghostty GX 图标 `dist/windows/gx/ghostty-gx.ico` 与上游的 `dist/windows/ghostty.manifest`；上游的 `ghostty.rc`、`ghostty.ico` 不再编进 exe（同属 `packaging-dist`）。
- 分界：apprt 接口、Surface 生命周期与 `needsConfirmQuit` 见 `app-core.md`；共享核心 `src/gx/**`（UI 语言、配置分层、启动配置、`gx:` 动作、进程判断、win32-input-mode 编码、ConPTY、OSC 7）见 `gx-core.md`；DirectWrite 字体发现见 `font.md`；ConPTY 与 termio 的 Windows 分支见 `termio-pty-os.md`；便携包与安装包见 `packaging-dist.md`。

## 符号真源

### 模块

| 模块 | 职责 |
|---|---|
| `App.zig` | 注册窗口类 `GhosttyWindow`、`GhosttyTerminal`（`CS_OWNDC`）与消息专用窗口 `GhosttyMsg`；消息循环 `run`、`wakeup`、`performAction`、`gxAction`；默认 shell（`updateDefaultCommand`）、全局热键、快捷键冲突检测（`probeShortcuts`）、托盘通知、任务栏进度、退出计时 |
| `shortcut_conflicts.zig` | 绑定到组合键（MOD_*、VK）的映射、待检测集合、`RegisterHotKey` 试注册与 TSF 保留键查询、冲突表 `Conflicts`、提示条要列出的默认绑定 |
| `Window.zig` | 顶层窗口：标签模型（每个标签一棵 split tree）、分屏布局、DPI、窗口位置（首窗约为显示器工作区的 80%）、首帧前 cloak、herdr 应用模式（`updateAppMode`）、关闭标签与窗口 |
| `Surface.zig` | 每个终端一个子 HWND：按键、IME、鼠标、拖放、剪贴板、标题与光标；持有 `palette`、`search_bar`、`link_preview`、`scrollbar` 与 `frame_event` |
| `chrome/TitleBar.zig`、`chrome/TabBar.zig`、`chrome/Backdrop.zig` | 集成标题栏（`WM_NCCALCSIZE`、`WM_NCHITTEST`、Snap Layouts、系统菜单）；Direct2D 标签栏；DWM 主题、窗口材质（`gx-window-material`）与按像素透明（`background-opacity`） |
| `ui/d2d.zig`、`ui/style.zig`、`ui/Popup.zig` | 手写的 Direct2D/DirectWrite COM 绑定与 `Canvas`（单位 DIP）；由终端配色派生的设计 token；可复用弹层（DWM 圆角、每显示器 DPI、可接输入法的 `TextInput`） |
| `ui/Palette.zig`、`ui/Keybinds.zig`、`ui/fuzzy.zig`、`ui/trigger.zig` | 命令面板、快捷键速查表（标出冲突按键）、模糊匹配与 frecency、绑定键帽与菜单提示（`Hints` 跳过冲突按键） |
| `ui/Menu.zig`、`ui/MenuPopup.zig` | 主菜单、启动配置菜单、标签与终端右键菜单；按主题自绘的模态菜单 |
| `ui/Settings.zig`、`ui/settings/*.zig` | 设置浮层（语言、外观、字体、交互、Shell、关于；关于页与关于对话框都显示 `src/gx/branding.zig` 的非官方分支声明），写 `gui-settings.ghostty` 后重载配置 |
| `ui/Dialogs.zig`、`ui/SearchBar.zig`、`ui/LinkPreview.zig`、`ui/ResizeOverlay.zig`、`ui/ShortcutNotice.zig`、`Scrollbar.zig` | 主题化对话框、查找栏、链接预览、尺寸提示、快捷键冲突提示条、细滚动条 |
| `QuickTerminal.zig`、`file_log.zig`、`win32.zig`、`ui/wstr.zig` | 快速终端；日志 `%LOCALAPPDATA%\ghostty\logs\ghostty.log`（上一次运行保留为 `.log.1`）；Win32 声明；UTF-8 转 UTF-16 |

### 线程与渲染钩子

- GUI 线程跑 `App.run` 的 `GetMessageW` 循环；HWND、GDI、Direct2D 与 COM UI 对象只在它上面创建和使用（`ui/d2d.zig` 文件头）。`App.wakeup` 可从任意线程调用，只向 `msg_hwnd` 投递 `WM_APP_WAKEUP`，`msgWndProc` 收到后执行 `core_app.tick`。
- `wgl.Device` 在进程内一次选定 OpenGL 实现：系统驱动能建 4.3 core context 就用它，否则用 exe 旁 `mesa\opengl32.dll` 的 llvmpipe；`GHOSTTY_GX_OPENGL=software` 直接用 Mesa。`Surface` 取得子窗口的私有 DC 后在主线程调一次 `Device.setPixelFormat`；`wgl.Context.init` 只记录 DC，context 在渲染线程的 `threadEnter` 创建（NVIDIA 驱动下 `wglMakeCurrent` 会瞬时失败，按次数重试）。
- `present` 把 render target blit 到默认 framebuffer 后 `SwapBuffers`，再经 `@hasDecl` 回调 `Surface.signalFrameDrawn` 置位 `frame_event`；Windows 上 `ExportedFrame` 为 `void`，不导出帧。驱动报告 GPU 重置时 `present` 重建 context，并在持有渲染器 `draw_mutex` 时调 `Surface.gpuContextReset`：它只把渲染器标为未 realize、丢掉已上传的图像，再投递 `WM_APP_GPU_RESET`，由 GUI 线程经 `GR` 计时器等资源释放后重新 realize。
- `frame_event` 是手动复位事件：live resize 时 `handleResize` 先复位它、唤醒渲染，再最多等 16 ms（`Window.layoutSplits` 对多个 pane 一次等全部，渲染并行）；新窗口在首帧前保持 cloak，`FIRST_FRAME_TIMER_ID` 每 10 ms 查一次，最长 `Window.first_frame_timeout_ms`。

### 消息与计时器 ID 登记表

ID 只在同一 HWND 内唯一。窗口私有消息与测试钩子用 `WM_USER + n`，跨模块投递的应用消息用 `WM_APP + n`；共享 HWND 上的计时器用两个 ASCII 字母编码。

| HWND | 自定义消息 | 计时器 |
|---|---|---|
| `GhosttyMsg`（`App.msg_hwnd`） | `WM_APP+1` WAKEUP、`WM_APP+3` TRAY、`WM_APP+0x62` QUIT | 1 退出延时、2 通知气泡、3 `QuickTerminal.ANIM_TIMER_ID`、4 快捷键冲突检测 |
| `GhosttyWindow` | `WM_APP+20` MAIN_MENU、`WM_APP+0x61` CLOSE_TAB、`WM_USER+0x47` SIMULATE_DPI（测试钩子） | `HD` 应用模式、`FF` 首帧、`CH` 标签栏轮询、`TT` 提示、`RG` 尺寸提示、`SN` 快捷键冲突提示条 |
| `GhosttyTerminal` | `WM_APP+0x60` CONFIRM_CLOSE、`WM_APP+30` GPU_RESET、`WM_USER+0x48` SIMULATE_GPU_RESET（测试钩子） | `CR`、`CW` 剪贴板重试，`GR` GPU 重置 |
| 滚动条弹层 | `WM_USER+1` SCROLLBAR_QUERY | 1 淡出、2 空闲 |
| 其他弹层 | 无 | 命令面板与设置浮层在自己的弹层 HWND 上用带 TIMERPROC 的小整数；`MenuPopup` 用线程计时器（`SetTimer(null, 0, …)`） |

### 输入、IME、DPI 与文字

- 按键：`App.run` 对 `GhosttyTerminal` 的按键消息跳过 `TranslateMessage`（`Surface.handleKeyEvent` 自己调 `ToUnicode`，两者共用死键状态），但 `VK_PROCESSKEY`（交给输入法）与 `VK_PACKET`（SendInput 的 Unicode 注入）必须经过它。按键、`WM_CHAR` 与输入法上屏文字都经核心 `Surface.gxWin32KeyCallback` 进入（补丁 GX-0006，接入契约在 `src/gx/win32_input.zig` 文件头）；终端开着 DECSET 9001 时按 KEY_EVENT_RECORD 发出。粘贴与拖放不走记录，拖放的路径按 shell 引用（`gx.path_quote`）。
- 弹层编辑框：`App.routeEditKey` 先把 Enter、Esc 与方向键交给标签改名、命令面板与查找栏；Ctrl 与 Ctrl+Shift 组合键冒泡给终端绑定，只有 Ctrl+A/C/V/X/Y/Z 留给编辑框。Alt+Space 由 `Window.handleSystemMenuKey` 打开窗口菜单。
- 快捷键冲突：其他程序的全局热键与输入法的 TSF 保留键到不了窗口。`App.probeShortcuts` 在首窗显示约 1 s 后与每次重载配置后（`GhosttyMsg` 计时器 4，GUI 线程，不阻塞首帧）逐个试注册带修饰键的绑定并查询 TSF，结果存于 `App.shortcut_conflicts`：速查表标记，菜单与命令面板经 `trigger.Hints` 跳过，默认的复制、粘贴、查找、分屏键受影响时每次运行显示一次 `ShortcutNotice`。自己的 `global:` 热键与 Windows 保留但仍会送达的 Alt+F4、F12、Shift+F12 不检测。TSF 只报告输入法用 `PreserveKey` 登记的键：微软拼音的 Ctrl+Shift+F 不是保留键，检测不到（下文「已知坑」照旧）。
- IME：组字串作为 preedit 交给核心内联显示，候选窗由 `Surface.positionImeWindow` 按 DPI 放到光标处；终端失焦时取消组字。
- DPI：manifest 声明 PerMonitorV2。只有顶层窗口收到 `WM_DPICHANGED`，`Window.handleDpiChange` 重排 chrome 并调用每个 Surface 的 `handleDpiChange`；弹层本身是顶层窗口，自己处理。chrome（标题栏、标签栏、它们的提示、尺寸提示与从标题栏打开的菜单）的尺寸、字体、命中区、Direct2D 画布 DPI 以及新建终端的初始缩放一律取 `Window.scale`（弹层经 `Popup.setOwnerScale`），只有 Windows 与 DWM 自己画的部分（顶部缩放带、材质下 DWM 的标题按钮）取 `GetDpiForWindow`；`WM_GHOSTTY_SIMULATE_DPI` 只改 `Window.scale`，混用两者在模拟时就会错位。
- 界面文字：一律写英文 msgid，经 `gx.i18n.tr`（编译期 msgid）或 `trRuntime` 在使用时翻译；菜单与对话框每次显示时重建，语言切换经各模块的 `onLanguageChanged` 下发。规则与生成器见 `gx-core.md`。

## 不变量

- 线程：其他线程进入 apprt 的入口（`wakeup`、`signalFrameDrawn`、`gpuContextReset`）只投递消息、置位事件或改渲染器自身的状态，不碰 HWND、Direct2D 与 apprt 的 UI 状态；GL 调用只在渲染线程（`renderer.md`）。
- 关闭：`Surface.close` 只投递 `WM_CLOSE` 或 `WM_APP_CONFIRM_CLOSE`，销毁一律在消息循环里进行，不在核心回调中关窗或释放 Surface。关闭分屏、标签、窗口与退出都先问核心 `needsConfirmQuit`（含 GX-0012 的空闲进程判断）。
- 模态循环：菜单、对话框、`MessageBoxW` 与另存为对话框都会继续派发消息，任何对象都可能在其间被释放。返回后重新解析 Window 与 Surface，不沿用调用前的裸指针；对话框打开期间窗口推迟自己的 `WM_CLOSE`，最外层对话框返回后再投递。窗口与终端销毁时清零 `GWLP_USERDATA`，窗口过程据此丢弃迟到的消息。
- 菜单只从窗口消息里打开：绑定动作经 `Window.queueMainMenu` 投递 `WM_APP_MAIN_MENU`，同一时刻只开一个菜单。
- Direct2D 可能不可用（`App.uiFactory` 返回 null）：自绘 UI 要有退路，对话框退回 `MessageBoxW`。
- 按像素合成：`Backdrop.perPixel` 为真的顶层窗口开了 DWM blur-behind（空区域），DWM 按客户区像素的 alpha 合成，GDI 画出的像素 alpha 为 0、等于全透明。在顶层窗口与终端子窗口上作画一律经预乘 32bpp DIB（`Backdrop.fillBackground`、`fillOpaque`，标题栏的 Direct2D DIB），不直接用 `FillRect` 或画笔；能否按像素合成在启动时由 `Backdrop.alphaFramesSupported` 定一次（`App.alpha_frames`）。
- 新增自定义消息或计时器先查上表，同一 HWND 不重号，`WM_TIMER` 分派保持完整，并把新 ID 写进上表。
- 配置：`App.config` 只在 GUI 线程的 `config_change` 中替换；设计 token 绘制时由当前配置派生（`ui/style.zig`），不跨线程缓存 `*const Config`。

## 禁止项

- 不用 gettext 的 `_`、`N_`（Windows 构建默认 `-Di18n=false`），不写死任一语言的界面文字。
- 不在渲染线程调用 HWND、GDI 或 Direct2D，不在 GUI 线程调用 GL 或 `wglMakeCurrent`。
- 不在核心回调里运行模态循环，不跨模态循环持有 Window 或 Surface 指针。
- Windows 专属逻辑放在 `src/apprt/win32/**` 或 `src/gx/**`；必须改上游文件时按 GX-NNNN 登记（`development.md`）。
- 验证时不读写用户真实配置与日志，不为截图改系统设置；测试配置只放在隔离目录。

## 验证

- 构建：`just build`（Windows 主机自动补 `-Dtarget=x86_64-windows-gnu`，Windows 目标默认 `-Dapp-runtime=win32`）产出 `zig-out/bin/ghostty.exe`；发布形态 `just package-windows`（见 `packaging-dist.md`）。
- 单测：`just test --filter apprt.win32`（2026-10 本机 82 条，热缓存墙钟约 3 s），共享核心 `just test --filter gx.`；只依赖 std 的文件（如 `ui/settings/fuzzy.zig`）也可 `just zig test <文件>`。
- GUI 证据，GUI 可见改动必做：
  1. 隔离：`LOCALAPPDATA` 与 `XDG_CONFIG_HOME` 都指向 `.local/evidence/<任务>/env/<场景>`，配置写在其下的 `ghostty\config.ghostty`，日志在 `ghostty\logs\ghostty.log`。隔离后，只装在真实 `%LOCALAPPDATA%\Programs` 下、不在 `PATH` 上的 GX Zsh 探测不到，默认 shell 会退到 PowerShell；需要时在配置里写 `command`。
  2. agent shell 常带 `NO_COLOR=1` 与 `TERM=dumb`：启动 `ghostty.exe` 前去掉 `NO_COLOR`，否则 pwsh 等不输出颜色与粗斜体。
  3. 用 kimi-cu 桌面自动化截取 `GhosttyWindow`（`get_app_state` 截图，`click`、`press_key` 操作），或用 PowerShell `CopyFromScreen` 截图；图片存到 `.local/evidence/<任务>/`，逐张读图核对后才记 PASS。
  4. 已知坑：微软拼音把 Ctrl+Shift+F 当作简繁切换吞掉，自动化测试查找栏前先切到英文键盘布局，或从命令面板打开查找；GUI 子系统的 exe 没有控制台，`+version`、`+list-fonts` 的输出要重定向或接管道（PowerShell 用 `| Out-String`）；复现 CI 的软件渲染设 `GHOSTTY_GX_OPENGL=software`。
- CI：`gx-ci` 的 `windows-app` job 在 push 与 PR 上构建 win32 app，手动输入 `win_smoke` 为真时用随包 Mesa llvmpipe 启动并截图（artifact `evidence-windows-smoke`）；`gx-release` 的 `windows-app` 产出 zip 与安装包。读回截图前 CI 证据记 PENDING。
- 改 Zig 跑 `just fmt-check`；改了 `pub` 签名或 `//!` 文档跑 `just kb`。
