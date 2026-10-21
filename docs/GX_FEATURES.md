# Ghostty GX 功能清单与 WezTerm GX 对照

> Ghostty GX 是 Ghostty 的非官方分支，由 gx0404 维护，与 Ghostty 团队无关，未获其认可或背书。本页的「Ghostty GX」均指这个分支，不指 Ghostty 官方发布。

Ghostty GX 是 GX Shell 新的终端组件（0.0.1 起），接替 WezTerm GX（GX Shell 0.4.0 起）。本页按功能对照 WezTerm GX 与 Ghostty GX 在 Windows、Linux GTK 上的实现，并列出借鉴自社区项目的做法。代码结构见 [ARCHITECTURE.md](ARCHITECTURE.md)，可观察变更的完整描述见根 `CHANGELOG.md`，验证情况见 [TESTING.md](TESTING.md)。

口径：

- Ghostty GX 两列以本仓 `gx_ghostty` 分支的源码为准，「有」指代码已在分支上；它不等于每项都已在 GUI 上验收，GUI 结论以读过的截图为准（TESTING.md「证据规则」）。
- WezTerm GX 一列依据 `gx0404/wezterm`（`feature/gx_wezterm` 分支）的 `CHANGELOG.md` 与 GX Shell 0.4.0 的移除说明整理，本仓没有复验，只作对照。
- macOS 一列：macOS app 是上游原样的 Swift app，经 C API（`ghostty_config_load_default_files` 等）分步加载配置，不经过 GX 配置分层（`src/gx/config_layers.zig`），也没有 GX 界面；只有核心层的改动对它生效，例如 GX-0006 让终端核心识别 DECSET 9001、GX-0021 修正渲染器的预编辑越界。

## 对照表

| 功能 | WezTerm GX | Ghostty GX：Windows | Ghostty GX：Linux GTK | macOS（上游原样） | 说明 |
|---|---|---|---|---|---|
| 界面语言切换 | 有：`language`（默认 `zh-CN`，可选 `en`）与 `WEZTERM_LANG`；GUI 文案与 CLI 帮助都汉化，切换后浮层即时重绘 | 有：`language` 默认 `zh-CN`；win32 界面文字全部经 `gx.i18n`；主菜单「语言」、设置浮层与命令面板切换，写入 `gui-settings.ghostty`，已打开的窗口、菜单与浮层当场换语言 | 有（GX-0011）：GX 文字经 `gx.i18n`，上游 GTK 文字经 gettext（需装 `zh_CN.UTF-8` 或 `en_US.UTF-8`）；运行时切换后菜单、提示、命令面板与新开的对话框换语言，部分上游控件要重开窗口（会弹 toast 说明）；终端里的 shell 保持系统语言 | 无（上游 macOS app 未本地化） | Ghostty GX 的 CLI 帮助（`+help` 等）仍是英文 |
| 设置界面 | 有：设置浮层（语言、外观、交互、字体，后加 Shell 分区与窗口材质），写 `gui-settings.json` | 有：Direct2D 模态浮层（`src/apprt/win32/ui/Settings.zig`），背后变暗；六个分区：语言、外观（主题列表带配色样例、模糊过滤、实时预览，主题明暗成对时用「浅色主题 / 深色主题」切换编辑哪一半；强调色；窗口材质）、字体（字号、DirectWrite 列出的等宽字体族）、交互（右键菜单、滚动条、关闭确认、响铃）、Shell、关于；入口 `gx:settings`、主菜单与 `open_config`（Ctrl+,） | 有（GX-0015）：`Adw.PreferencesDialog`（920×680，页面切换栏在标题栏），同样六页（窗口材质改写 `background-opacity` 与 `background-blur`）；外观页可选强调色，Shell 页列出启动配置并进入编辑子页，关于页显示 Ghostty GX 图标；运行期需要 libadwaita 1.5 | 无 | 两边都只写 `gui-settings.ghostty`，不写用户的 `config.ghostty`；300 ms 内的改动合并保存后重新加载；`gx-open-config-ui = editor` 时 `open_config` 仍打开编辑器 |
| 主题 | 有：内置 1001 个配色方案，移动即预览、Enter 应用、Esc 还原；默认 Catppuccin Mocha 系 | 有：内置 `GX Mocha`（Catppuccin Mocha 色板、`#1f1f28` 背景、`#cdd6f4` 前景）与 `GX Latte`（Catppuccin Latte 色板），加载时写进用户主题目录，默认 `theme = light:GX Latte,dark:GX Mocha` 随系统明暗切换；设置浮层与命令面板里实时预览，回车写入 `theme`（明暗成对时只替换当前编辑的一半），未应用就关闭则恢复 | 有：同一默认主题对；设置对话框分浅色、深色两行，各自预览与应用其中一半 | 上游主题机制，没有 GX 默认主题 | 主题列表是 Ghostty 自带的主题加用户主题目录；`gx-accent-color`（默认 `brand` 即 GX 紫，`theme` 跟随主题，或指定颜色）决定两端界面的强调色，链接用 GX 蓝，均按背景保证对比度 |
| 窗口材质 | 有：`window_material` 取壁纸、Mica、Acrylic 或纯色，非 Windows 降级为壁纸 | 有：`gx-window-material` 取 `solid`、`mica`、`acrylic`、`tabbed`；Windows 11 22H2 起生效（更早的系统按 `solid` 处理并记日志）。材质透到整个窗口：DWM 按像素合成（顶层窗口 `DwmEnableBlurBehindWindow` 空区域），终端背景按 `background-opacity` 透出材质，文字、光标、选区与图片不透明，分屏间隙一样；没设 `background-opacity` 时 Mica、Tabbed 取 0.3，Acrylic 取 0.75（同 WezTerm GX），设成 1 则只透在标题栏。`solid` 配 `background-opacity` 小于 1 时桌面透过终端背景、文字不透明，`background-blur` 把它模糊；`toggle_background_opacity` 所有窗口一起切换。更早的系统、Mesa 软件渲染或像素格式无 alpha 时保持 0.0.1 的做法：材质只在标题栏，`background-opacity` 整窗半透明（连文字），日志记一行原因 | 部分：没有系统材质；设置里的「纯色、半透明、毛玻璃」写 `background-opacity` 与 `background-blur`，毛玻璃是否生效取决于合成器（未验证） | 上游的 `background-opacity`、`background-blur` | — |
| 壁纸 | 有：壁纸浮层（列出、预览、添加、删除）与 16 张内置壁纸 | 未移植。上游的 `background-image`（与 `-opacity`、`-position`、`-fit`、`-repeat`）可以设背景图，Windows 上没有专门验证过 | 未移植；同样可用上游的 `background-image` | 上游的 `background-image` | GX Shell 0.4.0 随 WezTerm GX 移除了壁纸 |
| 标签栏外观 | 有：fancy 圆角标签栏、集成标题栏按钮、关闭按钮悬停 `#c42b1c`、未读计数、☰ 按钮 | 有：标签并入标题栏，Direct2D 绘制：8 DIP 圆角、活动标签与终端背景相连且顶部有 2 DIP 强调色签名条（与 GTK 同色）、`程序 ~ 标题`、未读圆点、管理员盾牌与 WSL 图标；拖动排序、双击改名、中键关闭；自绘最小化、最大化、关闭（悬停 `#c42b1c`），贴靠布局与窗口菜单；新窗口约占显示器工作区 80%，首帧前不显示 | 有（GX-0016）：libadwaita 标签栏加 GX 样式：8 px 圆角、活动标签顶部 2 px 强调色签名条、取自主题的标题栏与标签配色、悬停与按下的短过渡、1 px 分屏线、细滚动条；查找、尺寸、链接与按键表浮层用主题的表面与边框色 | 上游原样 | — |
| 主菜单 | 有：☰ 主菜单（命令面板、快捷键、设置、重载配置、隐藏窗口、退出），`ShowMainMenu` | 有：☰ 主菜单是按主题自绘的弹出菜单：新建标签页与窗口、启动配置子菜单、分屏、命令面板、设置、键盘快捷键、语言、重新加载配置、打开配置文件、关于、退出；`gx:main_menu`（默认 Ctrl+Shift+M） | 有（GX-0011）：上游 ☰ 菜单加 GX 分区（设置…、键盘快捷键、语言）；「关于 Ghostty GX」打开 GX 自己的关于对话框（写明非官方分支），代替上游的关于；`gx:main_menu` 从 ☰ 按钮弹出 | 上游菜单栏 | Windows 的标签页右键与终端右键菜单也是同一套自绘菜单；两边的「关于」与设置的关于页都写明 Ghostty GX 是非官方分支 |
| 命令面板 | 有：汉化的命令面板，中文模糊搜索，frecency 排序，鼠标悬停与点击 | 有：Direct2D 弹层，分组列出最近使用、标签页、启动配置、命令、设置、主题；同时匹配译文与英文原文，汉字可按拼音首字母或全拼匹配；frecency 排序，使用记录跨运行保存在状态目录（只存条目键的哈希）；选中主题即预览；键盘与鼠标 | 上游 GTK 命令面板，上游条目随界面语言翻译；GX 默认值的三条 `gx:` 条目也列出，可按标题或 `gx:` 动作搜索、回车执行（GX-0014），标题与描述在加载配置时按 `language` 翻译（中文为设置、键盘快捷键、主菜单），切换语言后随配置重载更新；用户自己写的条目按原文显示 | 上游 | 使用记录不写进任何配置文件 |
| 快捷键速查表 | 有：快捷键速查浮层 | 有：`gx:keybinds`（默认 Ctrl+Shift+/）：按类别列出全部绑定，前导键序列显示为 `A → B`，可按标题、动作与按键搜索；被其他程序或输入法占用的按键带警告标记并说明原因（见下文「快捷键冲突」） | 有（GX-0011）：`Adw.Dialog`，按类别分组，可搜索；另有快捷键编辑器：按类别列出全部快捷键与来源，编辑子页选动作、录键、开关标志、填参数并内联提示冲突，键表、按键序列与动作链在高级页用配置语法编辑；只写 `gui-settings.ghostty`，命令行的条目只读 | 无 | Windows 的速查表只查看与执行，不编辑绑定 |
| 快捷键冲突 | 无 | 有：启动后与每次重载配置时检测被其他程序注册为全局快捷键的组合键，以及当前输入法保留的按键；日志逐条警告，速查表标出，菜单与命令面板不再提示收不到的按键，默认的复制、粘贴、查找、分屏键受影响时每次运行提示一次替代方式；Shift+Insert 粘贴剪贴板、Ctrl+Insert 复制 | 无（上游行为；Shift+Insert 仍是上游的粘贴选择内容） | 无 | 见下文「快捷键冲突」 |
| 启动配置与默认 Shell | 有：探测 PowerShell 7、Windows PowerShell 5.1、cmd、Git Bash、MSYS2 UCRT64、Nushell、各 WSL 发行版与 GX Zsh；设置的 Shell 分区写默认 Shell；回退顺序 GX Zsh、PowerShell 7、PowerShell 5.1 | 有：`src/gx/profiles.zig` 探测 GX Zsh、herdr、PowerShell 7、Windows PowerShell、命令提示符、Git Bash、MSYS2 UCRT64、Nushell、各 WSL 发行版，加 `gx-launch-profile`；「+」旁的「▾」与右键「+」列出，另有 `gx:new_tab_profile`、`gx:new_window_profile`；未配置 `command` 时默认 GX Zsh，依次退到 PowerShell 7、Windows PowerShell、命令提示符；设置的 Shell 分区写 `command` | 有：新建标签页下拉列出 GX Zsh、herdr、登录 Shell、zsh、bash、fish 与 `gx-launch-profile`，另有「用启动配置新建窗口」；未配置 `command` 时默认 GX Zsh（`/usr/lib/ohmyzsh-gx/bin` 或 `PATH`），没有则退到上游的登录 shell；设置的 Shell 分区可写 `command`，其下的启动配置列表可新建、编辑、改名、删除自定义启动配置并设默认（只写 `gui-settings.ghostty`，菜单「编辑启动配置…」打开该页） | 上游 | 两边选 GX Zsh 时都在后台运行 `herdr --gx-set-default-shell`，退出码 3 表示用户自管 herdr 配置，只提示 |
| herdr 应用模式 | 有（配置脚本 `events/status.lua`）：唯一标签运行 herdr 时隐藏标签栏 | 有：`gx-herdr-app-mode`（默认开）：窗口唯一的标签页运行 herdr 时隐藏标签，保留标题栏与按钮；每 1.5 s 及标签页、分屏变化时重新判断 | 有（GX-0016）：隐藏标签栏；`gtk-titlebar-style = tabs` 时改为显示标题栏，窗口仍可拖动与关闭 | 无 | — |
| 关闭与退出确认 | 有：空闲 Shell 名单，全部窗格空闲时关闭与退出不确认 | 有：核心 `needsConfirmQuit` 加 GX-0012 的空闲进程判断（`gx-idle-processes` 或内置列表），检查 shell 及其全部子孙；关闭标签页、窗口与退出都先问，主题化对话框列出仍在运行的进程 | 有：同一判断，检查 pty 前台进程组组长及其子孙（`/proc`）；对话框是上游 GTK 的 | 上游行为（读不到进程时保持上游结论） | — |
| 输入法（IME） | 有：内置预编辑显示光标位置；改尺寸、切换焦点后候选框位置修正 | 有：内联预编辑；候选窗贴着光标并按 DPI 定位，改尺寸或 DPI 变化后重新定位；GX-0021 修正预编辑时渲染线程越界崩溃；win32-input-mode 下输入法上屏的文字按 VK=0 记录发送 | 上游 GTK IME；GX-0021 同样生效 | 上游；GX-0021 同样编入 | 微软拼音会吞掉 Ctrl+Shift+F（它不是 TSF 保留键，冲突检测发现不了），查找可从命令面板或右键菜单打开 |
| 通知、响铃与进度 | 有：响铃聚焦抑制、请求注意与节流；Windows 任务栏闪烁与 OSC 9;4 进度 | 限定可用：OSC 9 与 OSC 777 在安装版走系统通知，便携版或后端不可用时走托盘气泡；显示曾有未解释失败；程序运行时激活通知回到原终端已实测；程序退出后的激活会在前台提示原终端已不可用（见下节）；`bell-features` 的 `system` 发系统提示音、`attention` 在窗口不在前台时闪烁任务栏，后台标签显示未读圆点；`progress-style` 开启时 OSC 9;4 进度显示在任务栏按钮；支持 `notify-on-command-finish` | 上游 GTK 行为 | 上游 | — |
| 剪贴板图片粘贴 | 有：Ctrl+V 粘贴剪贴板图片，以 OSC 1337 内联或写临时文件（`clipboard_image_paste`） | 未移植：只粘贴文本；OLE 拖入文本、链接与文件，以及粘贴文件列表时，路径按当前 shell 引用（`gx.path_quote`：cmd、PowerShell、MSYS2/Git Bash/GX Zsh、WSL） | 未移植（上游行为） | 上游 | GX Shell 0.4.0 把它列为随 WezTerm GX 移除的功能 |
| 字体包 | 有：JetBrainsMono Nerd Font 6 个字重与 Noto Sans CJK Regular/Bold，随配置快照与安装包分发 | 有：同一组 8 个字体文件（其中 Oh My Zsh GX 也带的 4 个与它逐字节相同，GX Shell 只在字节一致时合并组件字体）；安装包按与程序相同的范围（当前用户或所有用户）安装，已有同名字体时跳过，卸载不删；便携 zip 只附带不安装。默认 `font-family = JetBrainsMono Nerd Font`，CJK 经 `font-codepoint-map` 交给 `Noto Sans CJK SC`；字体发现用 DirectWrite（GX-0009） | 部分：deb stage 带 `fonts/`，由 GX Shell 安装；Debian 13 tarball 不带字体；默认配置相同，字体缺失时退到内嵌的 JetBrains Mono 与系统回退 | 上游 | — |
| 安装包 | 有：0.3.0 起的原生安装包（Windows EXE 与 Ubuntu deb），后来改由 GX Shell 统一打包 | 有：Inno Setup 7.1 安装包与便携 zip（`just package-windows`；`gx-release` 的 `windows-app`），带随包 ConPTY、Mesa 软件渲染后备、字体与许可证；可选「在此处打开 Ghostty GX」右键菜单；exe 与安装包用 Ghostty GX 自己的图标（GX-0026），欢迎页、「应用和功能」与便携包 `README.txt` 写明非官方分支声明 | 无独立安装包：发布实验性的 Debian 13 tarball；Ubuntu 24.04 的 deb 由 GX Shell 用 stage 构建，启动器与程序内嵌的窗口图标是 Ghostty GX 图标（GX-0058）；Debian 13 tarball 与 `zig build install` 安装的系统图标保持上游 | `gx-release` 可选构建只做 ad-hoc 签名的 app zip | 全部资产都没有代码签名 |
| GX Shell 集成 | GX Shell 0.4.0 之前的终端组件 | 有：GX Shell 0.4.0 起的终端组件（0.4.0 随包 0.0.1，0.4.1 随包 0.0.2，来源锁钉各自的定版提交）；`scripts/gx_package.py windows` 产出 stage；在 `<exe>\..\bin`、`%LOCALAPPDATA%\Programs\GXShell\bin`、`%LOCALAPPDATA%\Programs\OhMyZshGX\bin` 与 PATH 中找 GX Zsh 与 herdr | 有：`scripts/gx_package.py deb` 产出 Ubuntu 24.04 的 stage，装到 `/usr/lib/ghostty-gx`，命令 `ghostty-gx`；在 `/usr/lib/ohmyzsh-gx/bin` 与 PATH 中找 GX Zsh 与 herdr | 无 | 消费方契约写在 `scripts/gx_package.py` 模块文档 |
| 随包 ConPTY | 有：随包的 `conpty.dll` 与 `OpenConsole.exe`（同一个 1.24.261001001 版本） | 有（GX-0007）：两者都在 exe 旁时优先使用，`GHOSTTY_GX_CONPTY=system` 强制用系统 ConPTY | 不适用 | 不适用 | 开发构建（`just build`）不带这两个文件，走系统 ConPTY |
| 工作目录继承（OSC 7） | 有（上游 WezTerm 支持 OSC 7） | 有（GX-0008）：解析 `file:///C:/…`、`/c/…`、`/cygdrive/c/…` 与本机主机名，新标签页、分屏与窗口从 shell 报告的目录启动 | 上游行为 | 上游行为 | — |

## 快捷键冲突

Windows 把别的程序用 `RegisterHotKey` 注册的全局快捷键直接交给那个程序，前台窗口收不到；输入法用 TSF 保留的按键、以及输入法自己处理的按键（例如微软拼音的简繁切换 Ctrl+Shift+F）也在到达窗口前被吞掉。常见的例子是 bilibili 客户端的「老板键」占用 Ctrl+Shift+C，于是默认的复制键失效。

- 检测：Windows 应用在第一个窗口显示约 1 秒后、以及每次重载配置后，对每个带修饰键的绑定（按键序列取第一个组合键）在消息窗口上试注册一次 `RegisterHotKey` 并立即注销，`ERROR_HOTKEY_ALREADY_REGISTERED` 即被占用；再向界面线程的 TSF 按键管理器查询当前输入法的保留键（`GetPreservedKey`）。不检测 Ghostty GX 自己注册的 `global:` 快捷键，也不报告 Windows 保留但仍会交给窗口的 Alt+F4、F12 与 Shift+F12。
- 局限：输入法在本线程激活后才登记保留键，启动时的检测可能还看不到；微软拼音的 Ctrl+Shift+F 由它的按键处理直接吃掉，不是保留键（2026-10 本机实测：拼音激活时 `GetPreservedKey` 对它返回 `S_FALSE`，遍历全部虚拟键与常见修饰组合只发现无修饰的 `VK_CONVERT`），所以检测不到，查找请用命令面板、右键菜单，或在拼音设置里关掉简繁切换快捷键。
- 呈现：日志 `%LOCALAPPDATA%\ghostty\logs\ghostty.log` 对每个受影响的绑定记一条警告；速查表在对应按键前加警告标记，并写明「被其他程序注册为全局快捷键」或「被输入法占用」；右键菜单、主菜单与命令面板改为提示同一动作的其他可用按键，没有就不提示；默认的复制、粘贴、查找或分屏键受影响时，每次运行在窗口底部提示一次（约 20 秒后自动消失），列出被占用的键与替代方式，并可打开速查表。
- 替代方式：Windows 默认 Ctrl+Insert 复制、Shift+Insert 粘贴（Windows 没有选择剪贴板，上游的 `shift+insert=paste_from_selection` 在这里无效，GX 的 Windows 默认值改为粘贴剪贴板）；也可用终端右键菜单与命令面板（Ctrl+Shift+P），或在 `config.ghostty` 用 `keybind` 改到未被占用的组合键。输入法的保留键随当前输入法变化，检测结果以最近一次检测时的输入法为准。

### 实机上遇到的冲突

GX Shell 的 Windows 用户最常碰到的就是这类冲突：按键被抢走时 Ghostty GX 什么也收不到，看起来像是快捷键失灵。下表是 2026-10 在一台装有常见桌面软件的 Windows 11 上实际遇到的冲突。「影响」一列对照 Ghostty GX 在 Windows 上的默认绑定；默认未绑定的组合键只有用户自己绑定时才受影响，但被全局热键占用的组合键同样到不了终端里的程序（例如 shell 与 Vim 的 Alt 组合键）。优先在占用的程序里改键或关闭热键；改不了时用上面的替代方式，或用 `keybind` 把动作换到别的组合键。

| 程序 | 占用的组合键 | 影响 | 解除办法 |
|---|---|---|---|
| bilibili 桌面客户端 | Ctrl+Shift+C（老板键） | 复制（`copy_to_clipboard`）；能检测到，窗口底部会提示 | 客户端「设置 → 快捷键 → 老板键」改成别的组合键或清空；临时可用 Ctrl+Insert 或右键菜单复制 |
| AMD Software（性能指标叠加层） | Ctrl+Shift+O、Ctrl+Shift+X、Ctrl+Alt+L | Ctrl+Shift+O 是向右分屏（`new_split:right`），能检测到，窗口底部会提示；另两个默认未绑定 | 在 AMD Software 设置的热键里改掉或清除这些热键，或关闭性能指标叠加层；分屏也可从右键菜单或命令面板执行 |
| 微软拼音输入法 | Ctrl+Shift+F（简繁切换） | 查找（`start_search`）；它不是 TSF 保留键，检测不到，速查表与提示条都不会标出 | 设置 → 时间和语言 → 语言和区域 → 微软拼音 → 按键 → 热键，关闭简繁切换；或把注册表 `HKCU\Software\Microsoft\InputMethod\Settings\CHS` 的 `EnableSimplifiedTraditionalOutputSwitch`（DWORD）设为 `0`；查找也可从命令面板或右键菜单打开 |
| Kimi Code | Ctrl+Shift+S、Ctrl+Shift+Space | 默认未绑定 | 在 Kimi Code 的设置里修改它的全局快捷键 |
| 微信 | Ctrl+Alt+W、Alt+A | 默认未绑定；Alt+A 到不了终端里的程序 | 微信「设置 → 快捷键」修改或清除 |
| NVIDIA App | Ctrl+Alt+M、Alt+Shift+R | 默认未绑定 | 在 NVIDIA App 叠加层的快捷键设置里修改或停用 |

## 借鉴的社区做法

| 来源 | 做法 | 在 Ghostty GX 中的位置 | 依据 |
|---|---|---|---|
| [shiweis/ghostty-windows](https://github.com/shiweis/ghostty-windows)（MIT，提交 `119b9270c`） | 在 Ghostty 核心上做 Win32 apprt：窗口与消息循环、键鼠与 IME、ConPTY 接线、DirectWrite 字体发现、快速终端 | `src/apprt/win32/**` 的移植文件与 `src/font/directwrite/` | 文件头的出处注释；之后的模块拆分与 Direct2D 界面是 fork 自己写的 |
| Windows Terminal | 标签页放进标题栏，标题栏按钮顶到窗口上沿；粘贴与拖放仍发原始文本 | `src/apprt/win32/chrome/TitleBar.zig`、`src/apprt/win32/Surface.zig` | 代码注释写明对齐 Windows Terminal |
| Windows Terminal 与 microsoft/terminal | win32-input-mode：ConPTY 开启 DECSET 9001 后按键以 KEY_EVENT_RECORD 记录发送，格式与 `TerminalInput::_makeWin32Output` 相同，kitty 键盘协议开启时让位 | `src/gx/win32_input.zig`（GX-0006） | 模块文档引用 microsoft/terminal 的 spec #4999 |
| microsoft/terminal 的 ConPTY 包 | 随包 `conpty.dll` 与 `OpenConsole.exe`，不开 `PSEUDOCONSOLE_INHERIT_CURSOR`（Windows Terminal 默认也不开） | `src/gx/conpty.zig`（GX-0007） | [FORK_PATCHES.md](FORK_PATCHES.md) GX-0007 |
| Windows 11 的界面规范 | 关闭按钮悬停色 `#c42b1c`、Snap Layouts（`HTMAXBUTTON`）、DWM 圆角与阴影、Mica/Acrylic 系统材质、圆角弹出菜单 | `src/apprt/win32/chrome/`、`src/apprt/win32/ui/` | 代码与 CHANGELOG |
| [Noctty](https://github.com/amanthanvi/noctty)（原名 winghostty） | 同样是基于 Ghostty 核心的原生 Win32 终端；公开 README 里有 shell 选择器（PowerShell、cmd、Git Bash、WSL）、命令面板、Ctrl+, 打开设置、带「在此处打开」资源管理器右键菜单的安装包加便携 ZIP、发布 SHA256SUMS | 启动配置（`src/gx/profiles.zig`）、命令面板、设置浮层、`dist/windows/gx/ghostty-gx.iss`、`gx-release` | 仓库与提交历史没有记录参考了 Noctty 的哪些部分；本行只按 Noctty 的公开 README（2026-10-09 读取）对照同类做法 |

与 Noctty 公开 README 的差异：Noctty 有自动更新检查、自签名证书签名与 ARM64 包，没有软件渲染器（OpenGL 回落到软件时不启动）；Ghostty GX 的候选实现支持下述会话恢复，尚无自动更新，资产未签名、只有 x64，但在系统驱动建不出 OpenGL 4.3 时用随包的 Mesa llvmpipe 运行。

## 会话、实例与远程窗格（0.0.3 候选）

本节按 `gx_ghostty` 工作区源码描述 0.0.3 的候选行为，代码已接线不等于完整平台验收已经完成；已知限制见下文，验证与补验方式见 [TESTING.md](TESTING.md)。

### 会话恢复

- 默认关闭。Windows 与 GTK 都用 `gx-session-restore = true` 开启，改动后需完全重启。开启后，普通启动恢复上次的普通窗口、标签、分屏结构与比例、放大的分屏、字号、手动设置的窗口与标签标题和工作目录；快速终端与远程窗格不进入会话。
- 会话文件是有版本、有大小上限的结构（最多 16 个窗口、每窗 64 个标签），放在状态目录，不是配置。它只记启动配置的稳定 ID（如 `pwsh`、`wsl:<发行版>`、`custom:<名称>`），恢复时按当前配置解析：`custom:` 自定义启动配置每次恢复前确认，已不存在的跳过并提示；临时命令（`-e`、`initial-command`）与来源不明的终端不恢复。
- 不保存命令、参数、环境变量、终端输入、动态标题或滚屏内容。工作目录只接受本机绝对路径；WSL 启动配置记录发行版内的目录，恢复时以 `--cd` 交给同一启动配置。
- 命令行指定了 `-e`、`command`、`initial-command` 或 `working-directory` 时本次不恢复，也不覆盖已保存的会话；命令行的字号与标题优先于会话。从「退出」结束时保留退出时的布局，逐个关掉最后一个普通窗口后下次不再恢复这些窗口。

### Windows 单实例与 `-e`

- `gx-single-instance` 默认开：普通启动在同一用户、登录会话、权限、配置目录、程序构建、安装位置与 `class` 都相同的已运行实例里新开窗口（可带启动配置），自己随即退出。实例之间用本机认证的命名管道，主实例在界面实际完成后才回复成功。
- 拖放 broker 的管道同时要求匹配用户和登录 SID；不同账户即使经 runas 共享交互登录，也不能仅凭登录 SID 打开入口。同用户的普通/提权路径保留关联令牌校验；最终 Win10/Win11 跨账户与四方向补验仍单独记录。
- 从旧版升级后，安装版正常启动会给指向当前安装、没有 AUMID 的固定快捷方式补齐应用标识，保留原参数、工作目录、图标等属性；已有标识或指向别处的快捷方式不改，便携版不迁移。实际任务栏是否合为同一个按钮、旧固定项是否保留 JumpList，仍待最终安装包在 VM 中验收。
- `-e`、无法转交的命令行参数或 `--gx-single-instance=false` 启动独立进程；以管理员身份运行与普通权限运行属于不同的隔离域，互不复用。转交结果不明时报错退出，不另开一份终端。
- `+toggle-quick-terminal`（可加 `--class`）在 Windows 上经同一通道切换已运行实例的快速终端，目标未运行时返回错误；GTK 仍走 GApplication 的 D-Bus。

### Windows 远程窗格

- 把标签拖出窗口、放到同一隔离域内另一个 Ghostty GX 进程的窗口上，标签里的终端以远程窗格显示在目标窗口。原进程在后台宿主里继续持有终端、PTY、渲染与子进程，目标只承载画面（BGRA 帧）并转发键盘、鼠标、输入法、焦点与粘贴；关闭原普通窗口不会重启或结束命令。
- 可以在远程窗格旁新建目标进程的本地终端，形成混合分屏；作用于全部窗格的动作只影响目标窗口里可见的窗格。只含远程窗格的标签可以拖回原进程（拖到别的进程会提示「请移回原进程」），混合标签不能跨进程移动，快速终端不接收远程窗格，会话只保留混合标签里的本地部分。
- 目标退出或断开后，原进程收回仍存活的终端；原进程故障时远程窗格显示「不可用」并提供关闭，不重放任何命令或输入。远程粘贴单次最多 16 MiB，分块传输，不自动追加回车；搜索、确认与剪贴板由目标窗口显示，结果回到原终端后才算完成。

### 拖放、受保护粘贴与提权窗口

- 终端用 OLE 接收拖入的文本、文件与链接，路径按当前 shell 引用；拖入内容和粘贴一样按终端的粘贴确认规则处理，确认后也不自动发送回车。
- 以管理员身份运行的窗口收不到普通权限程序的拖放（UIPI）。为此有一个普通权限的接收窗口「拖入提权终端」，只服务一个经过核验（进程号与创建时间、同一程序映像）的提权进程：内容在提权窗口里预览，点「允许粘贴」才粘贴；接收窗口显示已粘贴、已取消、被拒绝、目标已关闭、已过期或结果未知。它不读剪贴板、不改 UIPI 过滤、不提权。提权窗口的主菜单提供「拖入管理员终端…」：接收窗口以同一用户、同一会话的关联普通权限令牌启动，Win11 安装版已实测启动与配对，并实测普通权限程序把文本拖入提权窗口：预览后取消、允许后粘贴且不追加回车、多行内容经保护提示后取消，接收窗口都显示对应结果。同一用户下其余三个方向（普通→普通、管理员→普通、管理员→管理员）的直接文本拖放也已实测，均不追加回车；文件、链接与多 DPI 场景尚未逐项验证。

### 系统通知、跳转列表、无障碍与 DComp

- 系统通知限定可用：显示与两种激活已在 Win11 安装版实测，但此前三次未显示的原因未明，不算完整验收；诊断版及原版重启对照均成功显示；Win11 安装版已实测程序运行时在通知中心激活通知会回到原终端且不另起进程，程序退出后激活通知时，系统启动的 Ghostty GX 在前台提示「这条通知对应的终端已不可用。」，用户关闭提示后正常退出，不另开 shell，Win11 安装版已实测。预期通过安装程序登记的 Shell 身份（AUMID 与通知激活器）发送通知，点击回到原终端；程序已退出时点击，由通知启动的进程只提示原终端已不可用随即退出，不另开 shell。任务栏 JumpList 的列表和选择启动配置已经实测；条目使用稳定 ID，已删除的配置不会启动默认 shell。便携版不做任何注册；系统通知后端不可用时退回托盘气泡，被勿扰或用户关闭的通知不改用气泡。
- 窗口、标签、终端窗格与自绘弹层向 UI Automation 公开名称、角色和调用、选择、切换、展开等操作；外部读屏工具只拿到界面线程生成的快照。
- 弹层的 DirectComposition 呈现是实验：环境变量 `GHOSTTY_GX_POPUP_DCOMP=1` 才启用（其他值与未设置都走原路径），只影响弹层，不改终端的 WGL 渲染；初始化、设备重置或提交失败时退回原绘制方式。

### 已知限制与验收状态

原完整验收仍为 `not_complete`。最后登记的 142 叶检查点为 139 PENDING、2 PASS_SCOPED、1 DEFERRED，没有完整 PASS；未覆盖的平台、硬件与组合继续保留 PENDING，GTK Dock 进度仍延期。

- Windows UIA：旧节点保留的 `ValuePattern.SetValue` 实测返回 `0x80131509`，未满足预期的 `UIA_E_ELEMENTNOTAVAILABLE`（`0x80040201`）。撤销候选未采纳，完整失效语义与产品归因仍未确定，不能认定所有旧节点均无副作用。
- GTK 4.14.5：反复打开设置时可触发 `gtk_at_context_set_accessible_role` CRITICAL，属于已知的无障碍上下文重新挂树兼容性限制；尚无确定的本仓源码修复。
- GTK 字体：D-30 间歇性崩溃已有缓解改动 `6720c0e90`，完整因果与最终 ReleaseFast 验收仍为 PENDING，不能认定彻底修复。
- 性能：P4 弹层热路径未全部达到 160 Hz 下的 6.25 ms 门槛，P7 resize 等帧 timeout 未满足严格下降要求，两项保留 FAIL；其余缺少有效最终比较的指标仍为 PENDING。简化交付不等于原完整验收通过。

## 没有实现的

- WezTerm GX 的壁纸浮层与内置壁纸、剪贴板图片粘贴、CLI 帮助汉化，以及配置脚本里的插件与键位集合，Ghostty GX 都没有移植；GX Shell 0.4.0 不迁移 WezTerm 的配置。
- Linux GTK 上没有系统窗口材质。
- macOS app 没有任何 GX 界面与配置分层。

## Windows 查找栏的按键与位置

查找栏有焦点时，F3/Shift+F3、Enter、上下箭头和 Esc 优先用于查找。其他已绑定且不带 Ctrl 的 F1–F24（含 Shift、Alt、Win 组合）按终端绑定执行，焦点交回终端，查找栏保持打开；未绑定功能键留在查找栏，普通字符照常输入。F10 与 Alt 功能键的系统消息同样参与路由。命令面板和标签重命名不使用这项放行。

默认配置下可见的变化是 Alt+F4：它执行 `close_window`，请求关闭窗口前不再先结束搜索；在关闭确认中取消后，查找栏、needle 和匹配保留，焦点在终端。改绑 Alt+F4 时执行新动作；解绑后仍走弹层关闭路径，先结束搜索再请求关窗，因此取消关闭也不会恢复查找栏。

横向位置以窗口客户区为界，保留 8 DIP 边距。窗格太窄时，查找栏保持 240 DIP 最小宽度并向左移动；窗口本身不足以容纳时才进一步压缩。普通窗格的最大宽度为 380 DIP。位置真源是 `src/apprt/win32/ui/SearchBar.zig::screenRect` / `barSpan`，输入路由真源是 `src/apprt/win32/App.zig::routeEditKey`。

当前限制：

- 只夹横向；底部窗格或窗口极矮时，44 DIP 高的栏仍可能越过底边。纵向避让须同时保留终端区上界，不能直接夹到客户区而盖住标签栏；可用高度不足时还需要明确收缩或隐藏策略。
- 窄窗格贴右缘且滚动条始终显示时，查找栏可能盖住其左侧约 6 DIP。窗口边界与窗格预留宽度是不同坐标约束，后续应结合多个窗格统一避让，而非对所有窗格一律缩减窗口右界。
- 相邻窗格各开查找栏时，左移的栏可能遮住邻栏按钮；仍可用键盘导航和 Esc 关闭。保持最小宽度、完整按钮与多个栏互不重叠无法在任意窄窗格同时满足，需窗口层协调布局。
- 绑定判断沿用 Ctrl 路径的根键表查询，不查询活动键表，不从查找栏开始前导键序列；这是既有限制。
