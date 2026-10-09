# Changelog（gx0404/gx_ghostty fork）

本文件只记录 fork 层面的可观察变更：Ghostty GX 的产品功能、构建补丁、发布链与开发框架。上游 Ghostty 不维护 CHANGELOG；Ghostty 产品版本以 `build.zig.zon` 的 `.version` 为真源，本文件不复述上游产品变更，也不与产品版本同步。

版本规则：

- fork 版本取本文件 `## X.Y.Z(YYYY-MM-DD|TBD)` 标题中数值最大的 SemVer；`just version` 查询，`just version-check` 校验标题格式。
- 未发布的版本写 `(TBD)`，发版时改为发布当天的日期。发布 tag 为 `gx-vX.Y.Z`，构建版本串为 `<build.zig.zon 的 X.Y.Z>-gx.<X.Y.Z>`（0.0.1 即 tag `gx-v0.0.1`、版本串 `<build.zig.zon 的 X.Y.Z>-gx.0.0.1`），流程见 `docs/RELEASE.md`。
- 每个版本按 `### Added` / `### Changed` / `### Fixed` 分节（没有条目的节省略），只写使用者能观察到的效果。
- 本文件开头 6000 字符是知识库语料：每次修改后运行 `just kb`，把 `docs/kb/chunks.json` 与本文件放进同一个提交，否则 `gx-ci` 的 `framework` job 失败。

## 0.0.2(TBD)

### Added

- Windows 应用检测被占用的快捷键。GX Shell 的 Windows 用户常遇到快捷键按了没反应：组合键被其他程序注册成全局热键（如 bilibili 客户端「老板键」的 Ctrl+Shift+C、AMD Software 性能指标叠加层的 Ctrl+Shift+O）或被输入法先吃掉，Ghostty GX 收不到按键，以前也不会提示。现在第一个窗口显示约 1 秒后与每次重载配置后，检查每个带修饰键的绑定是否被其他程序注册为全局快捷键，以及是否是当前输入法经 TSF 保留的按键（微软拼音简繁切换的 Ctrl+Shift+F 不是保留键，检测不到）。每个受影响的绑定在日志里记一条警告；快捷键速查表（Ctrl+Shift+/）在这些按键前加警告标记并说明原因；右键菜单、主菜单与命令面板改为提示同一动作的其他可用按键，没有就不提示；默认的复制、粘贴、查找或分屏键受影响时，每次运行在窗口底部提示一次（约 20 秒后消失），列出被占用的键与替代方式（Ctrl+Insert / Shift+Insert、右键菜单、命令面板），并可直接打开速查表。实机上遇到的冲突程序（bilibili、AMD Software、微软拼音、Kimi Code、微信、NVIDIA App）与各自的解除办法见 `docs/GX_FEATURES.md`「快捷键冲突」。
- 写明 Ghostty GX 是非官方分支：Windows 的「关于」对话框与设置的「关于」页、Linux GTK 设置对话框的「关于」页、安装包的欢迎页与「应用和功能」里的说明、便携包的 `README.txt`、GitHub 发布说明的结尾与仓库首页 README 的开头，都写明「Ghostty GX 是 Ghostty 的非官方分支，由 gx0404 维护，与 Ghostty 团队无关，未获其认可或背书」（英文界面显示英文）。
- Linux GTK 主菜单的「关于 Ghostty GX」打开 Ghostty GX 自己的关于对话框：名称、版本、项目主页与问题反馈都指向 gx0404/gx_ghostty，首页写明「gx0404 维护的 Ghostty 非官方分支」，不再显示把本构建说成 Ghostty 开发者出品的上游关于对话框。

### Changed

- Windows 窗口材质透到整个终端区：`gx-window-material = mica|acrylic|tabbed` 不再只透在标题栏，终端背景按 `background-opacity` 透出材质，文字、光标、选区与图片保持不透明，分屏间隙一样透出。没设 `background-opacity` 时材质自带默认值（同 WezTerm GX）：Mica、Tabbed 为 0.3，Acrylic 为 0.75；显式设置（包括 `background-opacity = 1`，只在标题栏透出材质）优先。`solid` 配 `background-opacity` 小于 1 时改为只有终端背景透明、桌面透过来，文字不再随整窗变淡，`background-blur` 照常模糊透出的桌面；`toggle_background_opacity` 改为所有窗口一起在配置的不透明度与不透明之间切换（同 macOS）。需要 Windows 11 22H2（build 22621）及以上与硬件 OpenGL 驱动；更早的系统、Mesa 软件渲染（`GHOSTTY_GX_OPENGL=software`）或像素格式没有 alpha 时保持 0.0.1 的行为，日志记一行原因。`background-opacity` 的配置文档（`+explain-config background-opacity`）写明了 Windows 上的这些行为（GX-0024）。
- Ghostty GX 的 Windows 应用与安装包改用自己的图标（GX Mocha 配色的深色圆角方块加蓝色 `>_` 提示符，48 像素起加 `GX` 字样），不再使用 Ghostty 的幽灵图标；标题栏、任务栏、资源管理器、通知区域、安装程序与 GX Shell 的 Windows 安装包都显示它（GX-0026）。`ghostty.exe` 的文件属性显示产品名 Ghostty GX、发行者 gx0404 与非官方分支声明。Linux GTK 应用仍用上游图标。
- Windows「关于」对话框的第二个链接改为「上游 Ghostty」，指向 ghostty.org。
- 知识库产物 `docs/kb/chunks.json` 改为 schema 2，体积从约 2.3 MiB 降到约 1.8 MiB（预算仍是 2.5 MiB）：每个文档一行头（路径与逐文档的 `source_sha256`），其后每片一行，diff 按行对应小节；Markdown 正文不变，Zig 结构省略 `pub` 前缀、超长模块文档截断，Zig 与 C 头文件的文档注释只留摘要句。`just kb-query --json` 的 `id` 改为 `path#anchor`；旧格式的产物由 `just kb-check` 报「格式或 schema 变化」，运行 `just kb` 重建即可。

### Fixed

- Windows 上 Shift+Insert 粘贴剪贴板。Windows 没有选择剪贴板，上游默认的 `shift+insert=paste_from_selection` 按下后什么也不做；GX 的 Windows 默认值改为 `paste_from_clipboard`，与 Ctrl+Insert 复制配对，Ctrl+Shift+C / Ctrl+Shift+V 被其他程序占用时仍可复制粘贴。
- GTK 应用（GX-0023）：GTK 4.20 以前（如 Ubuntu 24.04 的 GTK 4.14）启动时不再记录 `Theme parser error: style.css:…`。拖动分屏时，目标终端靠近指针的那一半重新显示蓝色高亮；只读提示的文字恢复浅橙色；`window-theme = ghostty` 时 GTK 4.14 不再报 `css parsing failed`，失焦窗口的标题栏略微变暗；GTK 4.16–4.18 上拖放高亮的运行时 CSS 也不再报错。

## 0.0.1(2026-10-10)

Ghostty GX 的首个版本：新增 Windows 原生应用，改进 Linux GTK 应用，两端共用 GX 核心与默认配置，并有 fork 自己的发布链与开发框架。括号里的 GX-NNNN 是 `docs/FORK_PATCHES.md` 登记的上游源码补丁。

### Added

**Windows 原生应用**（新运行时 `src/apprt/win32`，移植自 MIT 许可的 shiweis/ghostty-windows 后重构）

- 运行：Windows 上 `just build` 产出 `zig-out/bin/ghostty.exe`。OpenGL 4.3 经 WGL 在渲染线程绘制，系统驱动不可用时改用 exe 旁 `mesa\` 里的 Mesa llvmpipe（发布包自带；`GHOSTTY_GX_OPENGL=software` 强制），GPU 重置、休眠恢复与显示器变化后自动恢复绘制。exe 旁有 `conpty.dll` 与 `OpenConsole.exe`（发布包自带 ConPTY 1.24）时优先使用（GX-0007，`GHOSTTY_GX_CONPTY=system` 改用系统自带）；`TERM=xterm-256color`、`COLORTERM=truecolor`；shell 经 OSC 7 报告的工作目录由新标签页、分屏与窗口继承（GX-0008）。日志在 `%LOCALAPPDATA%\ghostty\logs\ghostty.log`（上次运行的为 `.log.1`）。
- 窗口：标签页并入自绘标题栏（Windows Terminal 式），同一行有「+」新建标签页、「▾」启动配置与 ☰ 主菜单按钮，支持 Snap 布局与窗口菜单（Alt+Space）。标签页显示「程序 ~ 标题」、后台输出或响铃的圆点、管理员盾牌与 WSL 图标，可拖动排序、双击重命名、中键关闭。`gx-window-material = mica|acrylic|tabbed` 在 Windows 11 22H2 及以上让标题栏透出系统材质。新窗口占所在显示器工作区约 80% 并居中、依次错开，画出第一帧前不显示，不闪白。
- 菜单、命令面板与对话框：界面文字随 `language` 显示中文或英文，重载配置即切换。主菜单、启动配置菜单、标签页与终端右键菜单都是跟随主题的 Windows 11 风格弹出菜单，含分屏、界面语言、复制标签页、移到新窗口、在资源管理器中打开当前目录等。命令面板按最近使用、标签页、启动配置、命令、设置、主题分组，中英文模糊匹配，停在主题上即预览；`gx:keybinds`（Ctrl+Shift+/）打开可搜索的快捷键速查表。关闭确认（列出仍在运行的进程）、剪贴板授权（带预览）、不安全粘贴、子进程退出与关于都是主题化对话框；查找栏显示「当前/总数」，滚动条为细胶囊。
- 设置：`gx:settings`、主菜单「设置…」与 `open_config`（Ctrl+,）打开 Direct2D 模态设置浮层：语言、外观（窗口材质，带配色样例、移动即预览的主题列表）、字体、交互（右键菜单、滚动条、关闭确认、响铃）、Shell（默认启动配置；选 GX Zsh 时同时设为 herdr 的默认 shell）、关于。改动在 300 ms 内合并写入 `gui-settings.ghostty` 后重新加载配置，从不改写 `config.ghostty`。
- 输入与 shell 集成：ConPTY 开启 win32-input-mode 后按键以 KEY_EVENT_RECORD 发送（GX-0006），PowerShell、herdr 等能区分 Shift+Enter、Ctrl+Shift+字母与 Alt+方向键；输入法组字内联显示、候选窗跟随光标；拖放文件的路径按目标 shell 加引号。未配置 `command` 时依次尝试 GX Zsh、PowerShell 7、Windows PowerShell、命令提示符，启动配置另外探测 herdr、Git Bash、MSYS2 UCRT64、Nushell 与各 WSL 发行版；herdr 应用模式下隐藏标签、保留标题栏按钮。关闭与退出按核心的 `needsConfirmQuit` 确认；OSC 9/777 通知显示为托盘气泡，点击回到对应终端；响铃遵循 `bell-features`；资源管理器「在此处打开」在盘符根目录也可用。

**Linux GTK 应用**

- 界面语言（GX-0011）：`LANG=C.UTF-8`（WSL 默认）下也能显示中文；改 `language`（配置文件、`gui-settings.ghostty` 或 ☰ 菜单「语言」）后菜单、按钮提示、命令面板与之后打开的对话框立即换语言，终端里的 shell 仍用启动时的语言环境。上游 GTK 文字要系统装有 `zh_CN.UTF-8` 或 `en_US.UTF-8` 之一才跟随切换。
- ☰ 菜单新增「设置…」「键盘快捷键」「语言」；新建标签页按钮的下拉列出启动配置（GX Zsh、herdr、登录 Shell、zsh、bash、fish 与 `gx-launch-profile`），可在新标签页或新窗口启动；可搜索的快捷键速查对话框；执行 `gx:` 动作；窗口与标签页的默认标题为 `Ghostty GX`。
- 设置对话框（GX-0015）：`ctrl+,` 与「打开配置」打开它，页面与 Windows 相同（外观页的材质为纯色 / 半透明 / 毛玻璃），主题列表移动即预览、应用才写入，改动只写 `gui-settings.ghostty`。
- herdr 应用模式与 GX 外观（GX-0016）：唯一的标签页运行 herdr 时隐藏标签栏；圆角标签、1 px 分屏线、更细的滚动条，`window-theme` 为 `auto` 或 `ghostty` 时标题栏与标签配色取自终端主题，重载配置即更新。

**GX 共享核心与配置**（`src/gx`，Windows 与 GTK 应用共用）

- 配置分层（GX-0010）：GX 默认值 < 用户配置（含 `config-file` 引入的文件）< 设置界面写的 `gui-settings.ghostty`（与 `config.ghostty` 同目录）< 命令行；用户的 `theme` 与显式颜色照常覆盖默认值，`GHOSTTY_GX_DEFAULTS=0` 恢复上游加载方式。
- 新配置键 `gx-launch-profile`（`名称=命令` 的自定义启动配置）、`gx-herdr-app-mode`、`gx-window-material`（仅 Windows）、`gx-idle-processes`、`gx-open-config-ui`（默认 `settings` 打开设置界面，`editor` 照上游打开配置文件）；`language` 只认 `zh-CN` 与 `en`，可在运行时切换。
- `gx:` 绑定动作（GX-0014）：`keybind` 与 `command-palette-entry` 可用 `gx:settings`、`gx:main_menu`（默认 Ctrl+Shift+M）、`gx:keybinds`（默认 Ctrl+Shift+/）、`gx:new_tab_profile:<id>`、`gx:new_window_profile:<id>`（`<id>` 如 `pwsh`、`wsl:Ubuntu`、`custom:<名称>`）；默认命令面板追加「设置」「键盘快捷键」「主菜单」，Windows 与 GTK 的命令面板都列出并执行 `gx:` 条目，这三条的标题与描述随界面语言显示，切换语言后即更新。
- 关闭确认识别空闲进程（GX-0012）：`confirm-close-surface = true` 时，终端里只有 shell、shell 启动器与控制台辅助进程（`gx-idle-processes` 或内置列表）就直接关闭，运行 `vim`、`herdr` 或后台任务时照常确认；Linux 与 Windows 之外保持上游行为。
- 内置主题 `GX Mocha`（Catppuccin Mocha 调色板，`#1f1f28` 背景），加载时写入用户主题目录。

**打包与发布**

- Windows：`just package-windows` 产出便携包 `ghostty-gx-<VS>-x86_64-windows.zip` 与安装包 `ghostty-gx-<VS>-x86_64-windows-setup.exe`，都带 ConPTY、Mesa 与第三方许可证。安装包要求 Windows 10 1809 及以上，默认按用户安装到 `%LOCALAPPDATA%\Programs\Ghostty GX`（可选为所有用户），提供开始菜单、可选的桌面图标、App Paths 与资源管理器「在此处打开 Ghostty GX」，并安装随附的 JetBrainsMono Nerd Font 与 Noto Sans CJK 字体（范围与程序相同；已有则跳过，卸载时保留），卸载不动用户配置。
- `gx-release` 资产：libghostty-vt 预编译库（Linux x86_64/aarch64 glibc、x86_64 musl、wasm32、Windows MSVC）与源码包、完整源码包、实验性的 Linux GTK 包（Debian 13）、Windows 便携包与安装包，`macos` 输入为真时另有 libghostty-vt XCFramework 与未签名的 macOS app；附 `SHA256SUMS` 与 `manifest.json`。
- GX Shell 组件 stage：`scripts/gx_package.py windows|deb` 生成并复核 schema 3 的 stage；deb 用 Ubuntu 24.04 构建配方 `scripts/gx_linux_build.py`（随包带 `libgtk4-layer-shell.so`），`gx-release` 的 `linux-gtk-noble` job 在全新 `ubuntu:24.04` 容器里构建、安装并截图验证。

**开发框架与工具**

- AI 协作框架：根 `AGENTS.md` 的 fork 段、`docs/AGENT_RULES/` 的 22 份领域规则与 `just rules`；Claude Code、Codex、ZCode 的 PreToolUse hook 共用一份危险操作策略，真实接入状态见 `docs/AI_TOOLS.md`。
- `just` 命令入口（Windows 与 Linux/macOS 用法相同）：`just setup` 把钉版 Zig 0.16.0 与 graphify 装进仓库内的 `.local/`（`--innosetup` 另装 Inno Setup 7.1），不做系统级安装；并行测试运行器 `scripts/zig_test.py`（`just test-vt`、`just test`，运行期 `--filter` 不重新编译，失败时打印复现命令）与 `scripts/run_unittests.py`（`just framework-test`），测试二进制由 `test-lib-vt-bin`、`test-bin` 步骤构建（GX-0002）；另有代码图谱与知识库（`just graph*`、`just kb*`）、GX 翻译表（`just i18n`）、WSL 入口 `just wsl` 与提交规范 `type(scope): 中文描述`。

### Changed

- 默认配置（GX 默认值，用于 Windows 与 GTK 应用及 `ghostty +show-config` 等命令行动作）：主题 `GX Mocha`、界面语言 `zh-CN`、字体 JetBrainsMono Nerd Font（中日韩字符经 `font-codepoint-map` 用 Noto Sans CJK SC，缺失时走系统回退）、12 号字、内边距 10/8 并居中、闪烁的块光标、`gx-herdr-app-mode = true`，Alt+1..Alt+8 留给 shell；Windows 上关闭最后一个窗口即退出。
- Windows 上的构建与测试：Windows 目标的 `-Dapp-runtime` 默认为 `win32`（GX-0003）；`just build` 在未给 `-Dtarget` 时补 `-Dtarget=x86_64-windows-gnu`，用 Zig 自带的 MinGW 构建 win32 应用，不需要 Visual Studio；`just test` 以同一组合构建并运行完整单测 `ghostty-test`。libghostty-vt 仍用 `just build-vt` 与 `just test-vt`。
- CI：上游 15 个 GitHub Actions workflow 原样归档到 `.github/workflows-archive/`，只启用 `gx-ci.yml` 与 `gx-release.yml`。`gx-ci` 在 push 与 PR 到 `gx_ghostty` 时运行 `framework`（规则路由、CHANGELOG 版本标题、框架单测、知识库新鲜度、首父链提交标题）、`zig-fmt`、`linux-vt`、`linux-main`（无 app runtime 的完整单测）、`lib-vt-cross`（6 个目标）、`windows`（libghostty-vt 测试、构建与静态链接示例）与 `windows-app`（构建 win32 应用）；GTK 截图（`gtk_smoke`）、Windows 截图（`win_smoke`，Mesa 软件渲染）、macOS 测试与缓存探针需手动触发。测试 job 与本机用同一套并行运行器，结果与缓存诊断作为 artifact 上传。
- 发布：`gx-release` 只能手动触发，默认只构建与校验；`publish=true` 时以 tag `gx-vX.Y.Z` 发布正式 release `Ghostty GX X.Y.Z`（不是 prerelease），说明以本文件对应版本节开头、后附资产表。资产都未签名，完整性靠 `SHA256SUMS`、`manifest.json` 与 GitHub 资产摘要。

### Fixed

- 版本推导（GX-0001）：HEAD 打了非 `v` 前缀 tag（如 `gx-v0.0.1`）时，未传 `-Dversion-string` 的 `zig build`（包括 `zig build --help`）不再 panic，版本回退为分支预发布版本 `X.Y.Z-<branch>+<hash>`；`tip` 与 `vX.Y.Z` tag 的行为与上游一致。
- 配置诊断（GX-0010）：设置了 `theme` 时，明暗切换与 `ghostty +validate-config` 再次重放配置不再丢掉 `config-file` 打不开、循环引用等诊断，`+validate-config` 不再漏报缺失的 include；`GHOSTTY_GX_DEFAULTS=0` 时同样生效。
- Windows 字体发现改用 DirectWrite（GX-0009）：粗体、斜体、粗斜体使用字体族里真实的字面（此前粗体常显示为常规体）；`微软雅黑` 等本地化族名、注册表登记在其他目录的字体与 `AddFontResourceEx` 加载的字体都能找到；按码位回退改用系统字体回退并按区域设置选字（`中` 在 zh-CN 下用 Microsoft YaHei UI），首个 CJK 字符不再逐个打开字体文件；`ghostty +list-fonts` 列出各字面的样式名。
- 输入法预编辑（GX-0021，各平台共用的渲染器）：在 herdr 这类铺满背景色的 TUI 里开始组字时，渲染线程不再因字形游标越界而崩溃。
- Windows 上终端与 ConPTY 的屏幕同步（GX-0022）：输出滚进回滚区后再放大窗口，不再把历史行拉回屏幕，而是在提示符下方补空行；之后的命令与输出紧接在提示符后面，不再写到旧行上、与旧行交错或留下多余的提示符，使用系统自带 ConPTY 时也不再丢掉被拉回的那段历史，滚轮能翻回全部输出。shell 在提示符前发 OSC 133（如 GX Zsh 的 powerlevel10k）时，使用系统自带 ConPTY（开发构建、`GHOSTTY_GX_CONPTY=system` 或随包 ConPTY 不可用时）不再每执行一条命令就把上一条折叠后的命令行滚出屏幕、在顶部留下空行；Windows 上 OSC 133 不再做 fresh-line，与 ConPTY 和 Windows Terminal 一致。
- Windows 上的上游 termio 缺陷（GX-0005）：终端输出能及时重绘，子进程退出时进程不再崩溃，带引号且含空格的 `command` 路径可以启动，`https://…` 这类链接不再被当作路径解析而触发断言。
