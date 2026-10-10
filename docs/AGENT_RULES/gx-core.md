# gx-core：Ghostty GX 共享核心

## 范围

- fork 新路径 `src/gx/**`：win32 与 GTK 两个 apprt 共用的 GX 核心，以及它的数据文件 `defaults.ghostty`、`defaults-windows.ghostty`、`themes/GX Mocha`、`i18n/gx.zh_CN.po`，生成物 `i18n/zh_CN.zig` 与 `pinyin/initials.zig`（旁附上游许可原文）。
- 生成器：翻译表 `scripts/gx_i18n.py`（测试 `scripts/test_gx_i18n.py`，上游输入 `po/zh_CN.po` 同属 `apprt-gtk`）；拼音首字母表 `scripts/gx_pinyin.py`（测试 `scripts/test_gx_pinyin.py`）。
- 分界：消费方是 win32 apprt（`apprt-win32.md`）与 GTK 的 GX 层 `src/apprt/gtk/gx/**`（`apprt-gtk.md`）；接入上游的钩子是 fork 补丁 GX-0006、GX-0007、GX-0008、GX-0010、GX-0012、GX-0014（原因、行为与同步方法见 `docs/FORK_PATCHES.md`），对应的上游规则分别在 `input.md`、`termio-pty-os.md`、`config.md`、`app-core.md`。

## 符号真源

### 模块

标「R2/R3 接入」的接口已有单测，apprt 还没有调用方。

| 模块 | 内容 |
|---|---|
| `main.zig` | 导出全部模块；它的 `test` 块经 GX-0010 加在 `src/config/Config.zig` 的 `test` 块进入 `ghostty-test`，用例名以 `gx.` 开头 |
| `config_layers.zig`、`config_types.zig`、`gui_settings.zig`、`theme.zig` | 配置分层与快照 `Layers`、`gx-*` 键的值类型、覆盖文件 `gui-settings.ghostty`、内置主题 |
| `settings_map.zig` | 与 UI 工具包无关的设置模型：选项（含明暗成对主题 `ThemePair`）、写入的键与值、标签 msgid、按平台过滤的响铃项、`errorReason`、`fontFamilies`；`Changes` 一次提交 |
| `state_file.zig`、`window_state.zig`、`palette_history.zig` | 状态目录（Windows `%LOCALAPPDATA%\ghostty\`，Linux `$XDG_STATE_HOME/ghostty/`）的原子读写；窗口位置记忆与恢复前校验；命令面板使用记录，只存键的 FNV-1a 哈希（均 R2/R3 接入） |
| `i18n.zig`、`i18n/` | 界面语言与翻译 |
| `branding.zig` | 产品名、维护者、链接与非官方分支声明（上游要求非官方构建写明未获认可），两端关于页都显示 |
| `action.zig`、`profiles.zig` | `gx:` 绑定动作与标题 msgid（`Action.title`）；启动配置探测与解析 |
| `proc.zig`、`policy.zig`、`confirm.zig`、`app_mode.zig` | 进程表 `Table`（Windows 用 Toolhelp32，Linux 读 `/proc`；一次遍历，多根 `tree`，比较创建时间防 pid 复用）与 1 s 共享快照 `Shared`、空闲与辅助进程名单与 `displayName`、关闭确认（GX-0012）与 `Scope`、herdr 应用模式 |
| `leader.zig`、`unread.zig` | 前台程序归类（远程、超级用户、容器）；后台标签的新输出（均 R2/R3 接入） |
| `url_policy.zig` | OSC 8 链接放行、先确认或拒绝，只看文本（R2 接入） |
| `perf.zig` | `GHOSTTY_GX_PERF=1` 时每个样本记一行 `info(gx_perf): <指标> <微秒>us`，`scripts/gx_perf.py` 汇总；现只记 `config_load`、`config_build` |
| `ui_color.zig`、`ui_tokens.zig`、`chrome.zig`、`motion.zig` | 界面库，见下文「界面库」 |
| `fuzzy.zig`、`pinyin.zig` | 模糊匹配：空格切词、各词都须命中，全角折叠，前缀与完全匹配加分，至少两个 ASCII 字母的词可按拼音首字母匹配汉字；`Frecency` |
| `theme_swatch.zig`、`shortcuts.zig` | 主题文件的颜色与列表色块 `Cache`；快捷键速查的模型、键名与搜索（按标题或按键） |
| `win32_input.zig`、`conpty.zig`、`osc7.zig`、`path_quote.zig` | Windows 终端支持：KEY_EVENT_RECORD 编码（GX-0006）、随包 ConPTY（GX-0007）、OSC 7 的盘符路径（GX-0008）、拖放与粘贴路径按 shell 引用 |
| `gtk_css.zig` | GTK 外观的配色 CSS，纯文本生成；强调色仍取 palette 4，未用 `ui_tokens`（R3） |

### 配置分层

- `config_layers.zig::load` 由 GX-0010 的 `Config.load` 钩子调用。优先级从低到高：GX 默认值（内嵌 `defaults.ghostty`，Windows 另加 `defaults-windows.ghostty`）< 用户配置文件与它们引入的全部 `config-file` < `gui-settings.ghostty` < 命令行 < `-e` 及其命令。文件仍按上游顺序读取，再把 `_replay_steps` 按层重排，经 `Config.gxReplay` 重建，所以主题加载与明暗切换的重放保持层序。
- 某层设置 `font-family*` 时替换低层的字体列表而不是追加（`replaced_keys`）。`GHOSTTY_GX_DEFAULTS` 为 `0`、`false`、`off` 或 `no` 时（`enabled`）完全按上游加载，`Layers.load` 返回 `error.LayeringDisabled`。
- `Layers`：读一次各层输入，之后 `build(overrides)` 在内存里重建（与加载逐键一致，主题预览用），`provenance(key)`、`sets(layer, key)` 说明值来自哪层；`setOverlay` 与 `settings_map.Changes.applyToLayers`（须在 `commit` 前）让快照跟上刚保存的设置。`rebuild(config, alloc, args)` 按配置记录的输入在内存里重建，保留明暗状态与 `-e`，除主题外不读盘：`applyArg`（参数放到所有层之上、`-e` 之前，win32 的 `toggle_background_opacity` 用）与 GTK 语言切换后的重建（`gx/app.zig::reload`、`gx/language.zig::startup`）都经它。
- 诊断：覆盖文件读不出、`language` 不是 `zh-CN`/`en` 时记成 `.diagnostic` 重放步骤，每次重放、克隆、`rebuild` 都再报（`+validate-config` 因此退出 1）；`diagnosticsDigest` 在诊断不变时返回同一值，供 apprt 判断是否再提示。
- `loadWithOverrides`：设置界面预览用的内存覆盖，排在命令行之上、`-e` 之下；`defaultConfig`：只含 GX 默认值的配置；`overlayPath`：覆盖文件放在首选用户配置文件旁（`file_load.preferredDefaultFilePath`）。
- 默认值见 `defaults.ghostty`（主题、语言、字体与 CJK 码段映射、解绑 Alt+1..8、`gx:` 快捷键、三条命令面板条目）；Windows 另设 `quit-after-last-window-closed = true` 与 `shift+insert=paste_from_clipboard`（无选择剪贴板，单测锁定）。win32 加载前用 `setMaterialOpacity` 说明材质能否透到终端；能且各层都没设 `background-opacity` 时，默认值层末尾补 `materialOpacity` 一条（mica、tabbed 0.3，acrylic 0.75）。
- 默认值的三条命令面板条目是英文 msgid（`gx.zh_CN.po` 须有译文，单测锁定）。上游 GTK 面板原样显示配置文字，所以 GTK 构建在 `load` 时按最终的 `language` 把默认值层这些条目的重放步骤改写成译文（`translatePalette`）；win32 面板显示时才翻译，用户写的条目不改。
- `gui_settings.zig::Overlay` 逐行编辑，保留注释、空行、未知键与顺序，`save` 原子替换文件。内置主题在加载前写进用户主题目录 `<配置目录>/ghostty/themes`（`theme.zig::install`，每个进程只装一次），文件首行是 `theme.marker`；内容变化才替换，没有标记的同名用户文件不动。
- fork 配置键是 `src/config/Config.zig` 中 GX-0010 块的字段：`gx-launch-profile`（`名称=命令`，可重复）、`gx-herdr-app-mode`（默认 true）、`gx-window-material`（`solid|mica|acrylic|tabbed`，只在 Windows 生效）、`gx-idle-processes`（可重复，空时用 `policy.builtin_idle_processes`）、`gx-open-config-ui`（`settings|editor`，默认 settings）、`gx-ctrl-scroll-zoom`（默认 true，只在 Windows，R2 实现前不生效）；`language` 只认 `zh-CN` 与 `en`。字段的 doc comment 就是用户文档，写法见 `config.md`。

### i18n

- `i18n.zig`：`Language`（`zh_CN`、`en`，默认 zh-CN）、`parseLanguage`、`resolve`、`current` 与 `setCurrent`（进程级原子值）、`tr`（msgid 必须编译期已知，查表在编译期完成）、`trCtx`、`trRuntime`、`format` 与 `fill`（`{name}` 占位符）。
- `scripts/gx_i18n.py` 合并上游 `po/zh_CN.po` 与 fork 的 `src/gx/i18n/gx.zh_CN.po`（同一键以 fork 为准），跳过 fuzzy、废弃条目与空译文，带 msgctxt 的条目以 `<msgctxt>\x04<msgid>` 为键；fork 条目的 `{name}` 占位符必须与原文一致；输出按键排序、确定性。`just i18n` 写出 `src/gx/i18n/zh_CN.zig`，`just i18n-check` 只读校验，属于 `just framework-check` 与 `just generated-check`。
- `scripts/gx_pinyin.py` 从钉版 pinyin-data 0.15.0 的三个文件（sha256 钉在 `SOURCE_FILES`）生成首字母表（最常用读音加两部字典的其余读音），第二行记格式版本与摘要，输出确定。`just pinyin`（联网）重建，`just pinyin-check` 离线校验，同属上述两个聚合门。随包许可见 `packaging-dist.md`。

### gx: 动作与启动配置

- `action.zig::Action` 的语法是 `gx:<name>[:<argument>]`：`settings`、`main_menu`、`keybinds`、`new_tab_profile:<id>`、`new_window_profile:<id>`，以及 `settings_page:<页>`（`SettingsPage` 六页）、`new_tab_menu`、`context_menu`、`move_split_to_tab`、`move_split_to_window`、`tab_switcher`。GX-0014 给 `input.Binding.Action` 加 `gx` 成员；核心 `Surface.performBindingAction` 在 apprt 声明了 `gxAction` 时调用 `rt_app.gxAction(target, action)`（win32 的 `App.gxAction`，GTK 的转给 `src/apprt/gtk/gx/app.zig`），否则记 warn 并返回 false。两个 apprt 只执行前五个，其余也返回 false（R2/R3 实现），`performable:` 绑定因而把按键交还终端。
- `profiles.zig::detect` 是 `Environment` 的纯函数：GX Zsh 与 herdr 先查随包与 GX Shell 安装目录的 `bin`，再查 `PATH`；Windows 另有 PowerShell 7、Windows PowerShell、cmd、Git Bash、MSYS2 UCRT64、Nushell 与注册表里的 WSL 发行版（跳过 Docker/Rancher Desktop 的内部发行版，`isUtilityDistro`），Linux 另有登录 shell、zsh、bash、fish；最后是 `custom:<名称>`。`defaultProfile`：Windows 依次 GX Zsh、pwsh、powershell、cmd，Linux 依次 GX Zsh、登录 shell；`commandConfigured` 判断各层是否设了 `command`。
- `profiles.Cache`（app 一份）按环境变量指纹缓存 shell，重载配置时 `invalidate`；`List.resolve` 解析 `gx:new_*_profile:<参数>`：id，再自定义配置名，再英文或当前语言的显示名（忽略大小写）。二者与 `commandConfigured` 都 R2/R3 接入（win32 `App` 仍有自己的一份）。

### 界面库

- `ui_color`：WCAG 亮度与对比度，`isDark` 按 gamma 亮度。`ensureContrast` 只移动 OKLab 明度、保留色相与彩度，按 8 位量化后再校验；`ensureContrastAll` 按对比度最低的表面调整；`mixToContrast`。`pickAccent` 依次试光标色、palette 4、palette 12，取第一个彩度 ≥0.05 且达 3:1 的，否则夹紧第一个彩色候选的明度，最后退回 #0067c0。`Color` 是 D2D1_COLOR_F 布局的 extern struct（win32 的 `d2d.Color` 即它）。
- `ui_tokens`：`surface`、`surface_raised` 由背景向限彩度的前景步进；按下比悬停淡（`pressed_share` < `hover_share`）。`text_secondary`、`text_placeholder` 4.5:1、`text_tertiary` 3:1、`border` 1.4:1 在背景与两级表面上都保底；强调色、焦点环与 caution/success/critical 对 `surface_raised` 3:1。焦点环：win32 用 `focus_stroke` 加 `focus_stroke_inner`（WinUI 做法），`focus_stroke_accent` 留给 GTK。高对比度用 `SystemColors` 与 `Tokens.fromSystem`。
- `chrome`：标签条 `titleBar` 比背景深 32%（浅色 8%），至少 1.12:1；分隔线、悬停与按下覆盖层、窗口边框、标题栏关闭钮；`Chrome.fromSystem`；`Options.fromConfig` 读 `split-divider-color` 与只在 GTK 生效的 `window-titlebar-*`。
- `motion`：83/167/250 ms，`enter`、`exit`、`ease`（移动）与 `linear` 曲线，`fraction` 按时间算进度，`enabled` 综合系统动画设置、远程会话与 `GHOSTTY_GX_ANIMATIONS`。
- 消费方：win32 的 `ui/style.zig` 逐字段镜像 `ui_tokens` 与 `chrome`，`ui/anim.zig` 取 `motion`（`apprt-win32.md`）；GTK 尚未接入（R3）。

## 不变量

- 可在任何主机上测：探测与判断写成注入 `Environment`、`io` 或 `/proc` 目录的纯函数（`profiles.detect`、`proc.Table.readProc`、`app_mode.procRunsHerdr`、`leader.procKind`），两个平台的规则都能单测；Windows 专属代码按 `builtin.os.tag` 编译期门控（`conpty`、`confirm.windows`、`profiles.wslDistros`）。
- 与 UI 工具包无关：`src/gx` 不导入 GTK、Win32 UI 模块或 apprt；`settings_map`、`gtk_css` 与界面库只产出数据与文本，界面在各 apprt 里。`src/gx` 只属于 app 产物（`config_layers` 读 `src/global.zig`），libghostty-vt 可达的代码不得导入它。
- 层序是用户契约：改层或排序要同时更新 `config_layers.zig` 的文件头、`defaults.ghostty` 的注释与单测。默认值文件不写颜色（颜色来自主题）。`gui-settings.ghostty` 只由设置界面经 `Overlay` 或 `settings_map.Changes` 写入；「恢复默认」是删键（`Changes.reset`，D13），值回落到下层；任何代码都不写用户的 `config.ghostty`。
- 状态文件不是配置：窗口位置与面板记录只写状态目录（`state_file` 原子替换），不进任何配置文件；面板记录不存明文。
- fork 的界面文字是英文 msgid 加 `gx.i18n`：编译期字面量用 `tr`，运行期才知道的 msgid（如启动配置名）用 `trRuntime`。新 msgid 先查 `po/zh_CN.po` 有没有上游译文，没有才加进 `gx.zh_CN.po`，再 `just i18n`，`.po` 与生成表进同一提交。
- 进程判断保守：读不到进程（pid 未知、组长已退出、`/proc` 打不开、Linux 与 Windows 以外的系统）按「忙」处理，保持上游结论。列进程只在 GUI 线程同步进行，不持 `renderer_state.mutex`，不移到工作线程。
- 控制列进程次数：一次检查只读一张 `proc.Table`（多个终端用多根 `Table.tree`，win32 标签栏已如此）。以下 R2/R3 接入：周期检查（标签栏每 2 s、应用模式）共用 app 持有的 `proc.Shared`（1 s 内复用）；应用模式连续两次命中才进入（`app_mode.State`），间隔按 `nextDelay` 从 500 ms 退到 10 s（现仍是 `decide` 加固定间隔）；一次关闭确认在 `confirm.Scope` 内只拍一张表，模态框前 `end`（可重复调用；嵌套 scope 不能在自己的对话框前结束外层，跨对话框读到的是外层较早的表）。关闭确认的进程名不带 `.exe`（`policy.displayName`）。
- 后台标签新输出用 `unread.Tracker`：隐藏时记基线，此后脏且内容（回滚行数、光标、光标行）变了才算；周期检查只 `tryLock`。
- `gx:` 动作名、`SettingsPage` 页名与 `Profile.id`（`gx-zsh`、`pwsh`、`wsl:<发行版>`、`custom:<名称>` 等）出现在用户的 `keybind`、`command-palette-entry` 里，改名属于破坏性变更。

## 禁止项

- 不手改 `src/gx/i18n/zh_CN.zig` 与 `src/gx/pinyin/initials.zig`；不为 fork 字符串改 `po/zh_CN.po` 或上游 pot；fork 代码不用 gettext 的 `_`、`N_`、`C_`。
- 不在 `src/gx` 引入 GTK、Win32 UI 依赖或网络访问；不在默认值文件里写颜色或本机路径。
- 不绕过 `config_layers` 与 `gui_settings` 读写配置文件。
- 不把 GX 逻辑写进上游文件；确需新钩子时按 GX-NNNN 登记，钩子只调用 `src/gx` 或 apprt 的 GX 层（`development.md`）。

## 验证

- 单测：`just test --filter gx.`。Windows 本机跑 win32 构建的 `ghostty-test`（2026-10 本机 305 条，热缓存墙钟约 3 s），覆盖 Windows 分支；Linux 分支用 `just wsl test --filter gx.`（`-Dapp-runtime=none`，与 gx-ci 的 `linux-main` 相同）。改平台专属代码时两边都跑。
- 翻译：`just i18n` 后 `just i18n-check`；改生成器跑 `python scripts/run_unittests.py test_gx_i18n`。拼音：`just pinyin-check`；改生成器或升级钉版跑 `python scripts/run_unittests.py test_gx_pinyin`，再 `just pinyin` 并审 diff。
- 改配置键、默认值或分层：`just test --filter gx.config_layers --filter gx.settings_map`，再按 `config.md` 的验证生成文档（`just build -Demit-webdata`），并用隔离配置启动 app 核对效果（GUI 证据见 `apprt-win32.md`、`apprt-gtk.md`）。
- 改 Zig 跑 `just fmt-check`；改了 `pub` 签名或 `//!` 文档跑 `just kb`。
