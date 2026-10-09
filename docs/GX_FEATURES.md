# Ghostty GX 功能清单与 WezTerm GX 对照

Ghostty GX 0.0.1 是 GX Shell 新的终端组件，接替 WezTerm GX（GX Shell 0.4.0 起）。本页按功能对照 WezTerm GX 与 Ghostty GX 在 Windows、Linux GTK 上的实现，并列出借鉴自社区项目的做法。代码结构见 [ARCHITECTURE.md](ARCHITECTURE.md)，可观察变更的完整描述见根 `CHANGELOG.md`，验证情况见 [TESTING.md](TESTING.md)。

口径：

- Ghostty GX 两列以本仓 `gx_ghostty` 分支的源码为准，「有」指代码已在分支上；它不等于每项都已在 GUI 上验收，GUI 结论以读过的截图为准（TESTING.md「证据规则」）。
- WezTerm GX 一列依据 `gx0404/wezterm`（`feature/gx_wezterm` 分支）的 `CHANGELOG.md` 与 GX Shell 0.4.0 的移除说明整理，本仓没有复验，只作对照。
- macOS 一列：macOS app 是上游原样的 Swift app，经 C API（`ghostty_config_load_default_files` 等）分步加载配置，不经过 GX 配置分层（`src/gx/config_layers.zig`），也没有 GX 界面；只有核心层的改动对它生效，例如 GX-0006 让终端核心识别 DECSET 9001、GX-0021 修正渲染器的预编辑越界。

## 对照表

| 功能 | WezTerm GX | Ghostty GX：Windows | Ghostty GX：Linux GTK | macOS（上游原样） | 说明 |
|---|---|---|---|---|---|
| 界面语言切换 | 有：`language`（默认 `zh-CN`，可选 `en`）与 `WEZTERM_LANG`；GUI 文案与 CLI 帮助都汉化，切换后浮层即时重绘 | 有：`language` 默认 `zh-CN`；win32 界面文字全部经 `gx.i18n`；主菜单「语言」、设置浮层与命令面板切换，写入 `gui-settings.ghostty`，已打开的窗口、菜单与浮层当场换语言 | 有（GX-0011）：GX 文字经 `gx.i18n`，上游 GTK 文字经 gettext（需装 `zh_CN.UTF-8` 或 `en_US.UTF-8`）；运行时切换后菜单、提示、命令面板与新开的对话框换语言，部分上游控件要重开窗口（会弹 toast 说明）；终端里的 shell 保持系统语言 | 无（上游 macOS app 未本地化） | Ghostty GX 的 CLI 帮助（`+help` 等）仍是英文 |
| 设置界面 | 有：设置浮层（语言、外观、交互、字体，后加 Shell 分区与窗口材质），写 `gui-settings.json` | 有：Direct2D 模态浮层（`src/apprt/win32/ui/Settings.zig`），背后变暗；六个分区：语言、外观（窗口材质与主题列表，带配色样例、模糊过滤、实时预览）、字体（字号、DirectWrite 列出的等宽字体族）、交互（右键菜单、滚动条、关闭确认、响铃）、Shell、关于；入口 `gx:settings`、主菜单与 `open_config`（Ctrl+,） | 有（GX-0015）：`Adw.PreferencesDialog`，同样六页（窗口材质改写 `background-opacity` 与 `background-blur`）；运行期需要 libadwaita 1.5 | 无 | 两边都只写 `gui-settings.ghostty`，不写用户的 `config.ghostty`；300 ms 内的改动合并保存后重新加载；`gx-open-config-ui = editor` 时 `open_config` 仍打开编辑器 |
| 主题 | 有：内置 1001 个配色方案，移动即预览、Enter 应用、Esc 还原；默认 Catppuccin Mocha 系 | 有：GX 默认主题 `GX Mocha`（Catppuccin Mocha 色板、`#1f1f28` 背景，加载时写进用户主题目录）；设置浮层与命令面板里实时预览，回车写入 `theme`，未应用就关闭则恢复 | 有：同一默认主题；设置对话框里预览与应用 | 上游主题机制，没有 GX 默认主题 | 主题列表是 Ghostty 自带的主题加用户主题目录 |
| 窗口材质 | 有：`window_material` 取壁纸、Mica、Acrylic 或纯色，非 Windows 降级为壁纸 | 有：`gx-window-material` 取 `solid`、`mica`、`acrylic`、`tabbed`；Windows 11 22H2 起生效（更早的系统按 `solid` 处理并记日志），只透在标题栏一行，终端区保持不透明（WGL 子窗口）；`background-opacity` 小于 1 时整窗半透明，`background-blur` 只用于纯色材质 | 部分：没有系统材质；设置里的「纯色、半透明、毛玻璃」写 `background-opacity` 与 `background-blur`，毛玻璃是否生效取决于合成器（未验证） | 上游的 `background-opacity`、`background-blur` | — |
| 壁纸 | 有：壁纸浮层（列出、预览、添加、删除）与 16 张内置壁纸 | 未移植。上游的 `background-image`（与 `-opacity`、`-position`、`-fit`、`-repeat`）可以设背景图，Windows 上没有专门验证过 | 未移植；同样可用上游的 `background-image` | 上游的 `background-image` | GX Shell 0.4.0 随 WezTerm GX 移除了壁纸 |
| 标签栏外观 | 有：fancy 圆角标签栏、集成标题栏按钮、关闭按钮悬停 `#c42b1c`、未读计数、☰ 按钮 | 有：标签并入标题栏，Direct2D 绘制：8 DIP 圆角、活动标签与终端背景相连、`程序 ~ 标题`、未读圆点、管理员盾牌与 WSL 图标；拖动排序、双击改名、中键关闭；自绘最小化、最大化、关闭（悬停 `#c42b1c`），贴靠布局与窗口菜单；新窗口约占显示器工作区 80%，首帧前不显示 | 有（GX-0016）：libadwaita 标签栏加 GX 样式：8 px 圆角、取自主题的标题栏与标签配色、1 px 分屏线、细滚动条 | 上游原样 | — |
| 主菜单 | 有：☰ 主菜单（命令面板、快捷键、设置、重载配置、隐藏窗口、退出），`ShowMainMenu` | 有：☰ 主菜单是按主题自绘的弹出菜单：新建标签页与窗口、启动配置子菜单、分屏、命令面板、设置、键盘快捷键、语言、重新加载配置、打开配置文件、关于、退出；`gx:main_menu`（默认 Ctrl+Shift+M） | 有（GX-0011）：上游 ☰ 菜单加 GX 分区（设置…、键盘快捷键、语言）；`gx:main_menu` 从 ☰ 按钮弹出 | 上游菜单栏 | Windows 的标签页右键与终端右键菜单也是同一套自绘菜单 |
| 命令面板 | 有：汉化的命令面板，中文模糊搜索，frecency 排序，鼠标悬停与点击 | 有：Direct2D 弹层，分组列出最近使用、标签页、启动配置、命令、设置、主题；同时匹配译文与英文原文；本次运行内的 frecency；选中主题即预览；键盘与鼠标 | 上游 GTK 命令面板，上游条目随界面语言翻译；GX 默认值的三条 `gx:` 条目也列出，可按标题或 `gx:` 动作搜索、回车执行（GX-0014），标题与描述在加载配置时按 `language` 翻译（中文为设置、键盘快捷键、主菜单），切换语言后随配置重载更新；用户自己写的条目按原文显示 | 上游 | Windows 的使用记录只保存在进程内，重启后清空 |
| 快捷键速查表 | 有：快捷键速查浮层 | 有：`gx:keybinds`（默认 Ctrl+Shift+/）：按类别列出全部绑定，前导键序列显示为 `A → B`，可按标题、动作与按键搜索 | 有（GX-0011）：`Adw.Dialog`，按类别分组，可搜索 | 无 | — |
| 启动配置与默认 Shell | 有：探测 PowerShell 7、Windows PowerShell 5.1、cmd、Git Bash、MSYS2 UCRT64、Nushell、各 WSL 发行版与 GX Zsh；设置的 Shell 分区写默认 Shell；回退顺序 GX Zsh、PowerShell 7、PowerShell 5.1 | 有：`src/gx/profiles.zig` 探测 GX Zsh、herdr、PowerShell 7、Windows PowerShell、命令提示符、Git Bash、MSYS2 UCRT64、Nushell、各 WSL 发行版，加 `gx-launch-profile`；「+」旁的「▾」与右键「+」列出，另有 `gx:new_tab_profile`、`gx:new_window_profile`；未配置 `command` 时默认 GX Zsh，依次退到 PowerShell 7、Windows PowerShell、命令提示符；设置的 Shell 分区写 `command` | 有：新建标签页下拉列出 GX Zsh、herdr、登录 Shell、zsh、bash、fish 与 `gx-launch-profile`，另有「用启动配置新建窗口」；默认仍是上游的登录 shell，设置的 Shell 分区可写 `command` | 上游 | 两边选 GX Zsh 时都在后台运行 `herdr --gx-set-default-shell`，退出码 3 表示用户自管 herdr 配置，只提示 |
| herdr 应用模式 | 有（配置脚本 `events/status.lua`）：唯一标签运行 herdr 时隐藏标签栏 | 有：`gx-herdr-app-mode`（默认开）：窗口唯一的标签页运行 herdr 时隐藏标签，保留标题栏与按钮；每 1.5 s 及标签页、分屏变化时重新判断 | 有（GX-0016）：隐藏标签栏；`gtk-titlebar-style = tabs` 时改为显示标题栏，窗口仍可拖动与关闭 | 无 | — |
| 关闭与退出确认 | 有：空闲 Shell 名单，全部窗格空闲时关闭与退出不确认 | 有：核心 `needsConfirmQuit` 加 GX-0012 的空闲进程判断（`gx-idle-processes` 或内置列表），检查 shell 及其全部子孙；关闭标签页、窗口与退出都先问，主题化对话框列出仍在运行的进程 | 有：同一判断，检查 pty 前台进程组组长及其子孙（`/proc`）；对话框是上游 GTK 的 | 上游行为（读不到进程时保持上游结论） | — |
| 输入法（IME） | 有：内置预编辑显示光标位置；改尺寸、切换焦点后候选框位置修正 | 有：内联预编辑；候选窗贴着光标并按 DPI 定位，改尺寸或 DPI 变化后重新定位；GX-0021 修正预编辑时渲染线程越界崩溃；win32-input-mode 下输入法上屏的文字按 VK=0 记录发送 | 上游 GTK IME；GX-0021 同样生效 | 上游；GX-0021 同样编入 | 微软拼音会吞掉 Ctrl+Shift+F，查找可从命令面板打开 |
| 通知、响铃与进度 | 有：响铃聚焦抑制、请求注意与节流；Windows 任务栏闪烁与 OSC 9;4 进度 | 有：OSC 9 与 OSC 777 的桌面通知显示为托盘气泡，点击回到对应终端；`bell-features` 的 `system` 发系统提示音、`attention` 在窗口不在前台时闪烁任务栏，后台标签显示未读圆点；`progress-style` 开启时 OSC 9;4 进度显示在任务栏按钮；支持 `notify-on-command-finish` | 上游 GTK 行为 | 上游 | — |
| 剪贴板图片粘贴 | 有：Ctrl+V 粘贴剪贴板图片，以 OSC 1337 内联或写临时文件（`clipboard_image_paste`） | 未移植：只粘贴文本；拖放文件与粘贴文件列表时插入按当前 shell 引用的路径（`gx.path_quote`：cmd、PowerShell、MSYS2/Git Bash/GX Zsh、WSL） | 未移植（上游行为） | 上游 | GX Shell 0.4.0 把它列为随 WezTerm GX 移除的功能 |
| 字体包 | 有：JetBrainsMono Nerd Font 6 个字重与 Noto Sans CJK Regular/Bold，随配置快照与安装包分发 | 有：同一组 8 个字体文件（其中 Oh My Zsh GX 也带的 4 个与它逐字节相同，GX Shell 只在字节一致时合并组件字体）；安装包按与程序相同的范围（当前用户或所有用户）安装，已有同名字体时跳过，卸载不删；便携 zip 只附带不安装。默认 `font-family = JetBrainsMono Nerd Font`，CJK 经 `font-codepoint-map` 交给 `Noto Sans CJK SC`；字体发现用 DirectWrite（GX-0009） | 部分：deb stage 带 `fonts/`，由 GX Shell 安装；Debian 13 tarball 不带字体；默认配置相同，字体缺失时退到内嵌的 JetBrains Mono 与系统回退 | 上游 | — |
| 安装包 | 有：0.3.0 起的原生安装包（Windows EXE 与 Ubuntu deb），后来改由 GX Shell 统一打包 | 有：Inno Setup 7.1 安装包与便携 zip（`just package-windows`；`gx-release` 的 `windows-app`），带随包 ConPTY、Mesa 软件渲染后备、字体与许可证；可选「在此处打开 Ghostty GX」右键菜单 | 无独立安装包：发布实验性的 Debian 13 tarball；Ubuntu 24.04 的 deb 由 GX Shell 用 stage 构建 | `gx-release` 可选构建只做 ad-hoc 签名的 app zip | 全部资产都没有代码签名 |
| GX Shell 集成 | GX Shell 0.4.0 之前的终端组件 | 有：GX Shell 0.4.0 的终端组件（来源锁等 `gx-v0.0.1` 发布后才写正式修订）；`scripts/gx_package.py windows` 产出 stage；在 `<exe>\..\bin`、`%LOCALAPPDATA%\Programs\GXShell\bin`、`%LOCALAPPDATA%\Programs\OhMyZshGX\bin` 与 PATH 中找 GX Zsh 与 herdr | 有：`scripts/gx_package.py deb` 产出 Ubuntu 24.04 的 stage，装到 `/usr/lib/ghostty-gx`，命令 `ghostty-gx`；在 `/usr/lib/ohmyzsh-gx/bin` 与 PATH 中找 GX Zsh 与 herdr | 无 | 消费方契约写在 `scripts/gx_package.py` 模块文档 |
| 随包 ConPTY | 有：随包的 `conpty.dll` 与 `OpenConsole.exe`（同一个 1.24.261001001 版本） | 有（GX-0007）：两者都在 exe 旁时优先使用，`GHOSTTY_GX_CONPTY=system` 强制用系统 ConPTY | 不适用 | 不适用 | 开发构建（`just build`）不带这两个文件，走系统 ConPTY |
| 工作目录继承（OSC 7） | 有（上游 WezTerm 支持 OSC 7） | 有（GX-0008）：解析 `file:///C:/…`、`/c/…`、`/cygdrive/c/…` 与本机主机名，新标签页、分屏与窗口从 shell 报告的目录启动 | 上游行为 | 上游行为 | — |

## 借鉴的社区做法

| 来源 | 做法 | 在 Ghostty GX 中的位置 | 依据 |
|---|---|---|---|
| [shiweis/ghostty-windows](https://github.com/shiweis/ghostty-windows)（MIT，提交 `119b9270c`） | 在 Ghostty 核心上做 Win32 apprt：窗口与消息循环、键鼠与 IME、ConPTY 接线、DirectWrite 字体发现、快速终端 | `src/apprt/win32/**` 的移植文件与 `src/font/directwrite/` | 文件头的出处注释；之后的模块拆分与 Direct2D 界面是 fork 自己写的 |
| Windows Terminal | 标签页放进标题栏，标题栏按钮顶到窗口上沿；粘贴与拖放仍发原始文本 | `src/apprt/win32/chrome/TitleBar.zig`、`src/apprt/win32/Surface.zig` | 代码注释写明对齐 Windows Terminal |
| Windows Terminal 与 microsoft/terminal | win32-input-mode：ConPTY 开启 DECSET 9001 后按键以 KEY_EVENT_RECORD 记录发送，格式与 `TerminalInput::_makeWin32Output` 相同，kitty 键盘协议开启时让位 | `src/gx/win32_input.zig`（GX-0006） | 模块文档引用 microsoft/terminal 的 spec #4999 |
| microsoft/terminal 的 ConPTY 包 | 随包 `conpty.dll` 与 `OpenConsole.exe`，不开 `PSEUDOCONSOLE_INHERIT_CURSOR`（Windows Terminal 默认也不开） | `src/gx/conpty.zig`（GX-0007） | [FORK_PATCHES.md](FORK_PATCHES.md) GX-0007 |
| Windows 11 的界面规范 | 关闭按钮悬停色 `#c42b1c`、Snap Layouts（`HTMAXBUTTON`）、DWM 圆角与阴影、Mica/Acrylic 系统材质、圆角弹出菜单 | `src/apprt/win32/chrome/`、`src/apprt/win32/ui/` | 代码与 CHANGELOG |
| [Noctty](https://github.com/amanthanvi/noctty)（原名 winghostty） | 同样是基于 Ghostty 核心的原生 Win32 终端；公开 README 里有 shell 选择器（PowerShell、cmd、Git Bash、WSL）、命令面板、Ctrl+, 打开设置、带「在此处打开」资源管理器右键菜单的安装包加便携 ZIP、发布 SHA256SUMS | 启动配置（`src/gx/profiles.zig`）、命令面板、设置浮层、`dist/windows/gx/ghostty-gx.iss`、`gx-release` | 仓库与提交历史没有记录参考了 Noctty 的哪些部分；本行只按 Noctty 的公开 README（2026-10-09 读取）对照同类做法 |

与 Noctty 公开 README 的差异：Noctty 有会话恢复、自动更新检查、自签名证书签名与 ARM64 包，没有软件渲染器（OpenGL 回落到软件时不启动）；Ghostty GX 没有会话恢复与自动更新，资产未签名、只有 x64，但在系统驱动建不出 OpenGL 4.3 时用随包的 Mesa llvmpipe 运行。

## 没有实现的

- WezTerm GX 的壁纸浮层与内置壁纸、剪贴板图片粘贴、CLI 帮助汉化，以及配置脚本里的插件与键位集合，Ghostty GX 都没有移植；GX Shell 0.4.0 不迁移 WezTerm 的配置。
- 会话恢复（窗口、标签与工作目录在重启后恢复）两边都没有。
- Linux GTK 上：默认 shell 仍是登录 shell（不默认进 GX Zsh），没有系统窗口材质。
- macOS app 没有任何 GX 界面与配置分层。
