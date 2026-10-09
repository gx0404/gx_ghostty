# gx-core：Ghostty GX 共享核心

## 范围

- fork 新路径 `src/gx/**`：win32 与 GTK 两个 apprt 共用的 GX 核心，以及它的数据文件 `defaults.ghostty`、`defaults-windows.ghostty`、`themes/GX Mocha`、`i18n/gx.zh_CN.po` 与生成的 `i18n/zh_CN.zig`。
- 翻译表生成器 `scripts/gx_i18n.py`（测试 `scripts/test_gx_i18n.py`）及其上游输入 `po/zh_CN.po`（同属 `apprt-gtk`）。
- 分界：消费方是 win32 apprt（`apprt-win32.md`）与 GTK 的 GX 层 `src/apprt/gtk/gx/**`（`apprt-gtk.md`）；接入上游的钩子是 fork 补丁 GX-0006、GX-0007、GX-0008、GX-0010、GX-0012、GX-0014（原因、行为与同步方法见 `docs/FORK_PATCHES.md`），对应的上游规则分别在 `input.md`、`termio-pty-os.md`、`config.md`、`app-core.md`。

## 符号真源

### 模块

| 模块 | 内容 |
|---|---|
| `main.zig` | 导出全部模块；它的 `test` 块经 GX-0010 加在 `src/config/Config.zig` 的 `test` 块进入 `ghostty-test`，用例名以 `gx.` 开头 |
| `config_layers.zig`、`config_types.zig`、`gui_settings.zig`、`theme.zig` | 配置分层、`gx-*` 键的值类型、覆盖文件 `gui-settings.ghostty`、内置主题 |
| `settings_map.zig` | 与 UI 工具包无关的设置模型：选项、写入的键与值、标签 msgid，`Changes` 一次提交到覆盖文件 |
| `i18n.zig`、`i18n/` | 界面语言与翻译 |
| `branding.zig` | 产品名、维护者、链接与非官方分支声明（Ghostty 维护者要求非官方构建写明未获认可）；两个 apprt 的关于对话框与设置的关于页都显示它 |
| `action.zig`、`profiles.zig` | `gx:` 绑定动作；启动配置探测 |
| `proc.zig`、`policy.zig`、`confirm.zig`、`app_mode.zig` | 进程快照（Windows 用 Toolhelp32，Linux 读 `/proc`，比较创建时间防 pid 复用）、空闲与 herdr 策略、关闭确认（GX-0012）、herdr 应用模式 |
| `win32_input.zig`、`conpty.zig`、`osc7.zig`、`path_quote.zig` | Windows 终端支持：KEY_EVENT_RECORD 编码（GX-0006）、随包 ConPTY（GX-0007）、OSC 7 的盘符路径（GX-0008）、拖放与粘贴路径按 shell 引用 |
| `gtk_css.zig` | GTK 外观的配色 CSS，纯文本生成、不依赖 GTK |

### 配置分层

- `config_layers.zig::load` 由 GX-0010 的 `Config.load` 钩子调用。优先级从低到高：GX 默认值（内嵌 `defaults.ghostty`，Windows 另加 `defaults-windows.ghostty`）< 用户配置文件与它们引入的全部 `config-file` < `gui-settings.ghostty` < 命令行 < `-e` 及其命令。文件仍按上游顺序读取，再把 `_replay_steps` 按层重排，经 `Config.gxReplay` 重建，所以主题加载与明暗切换的重放保持层序。
- 某层设置 `font-family*` 时替换低层的字体列表而不是追加（`replaced_keys`）。`GHOSTTY_GX_DEFAULTS` 为 `0`、`false`、`off` 或 `no` 时（`enabled`）完全按上游加载。
- `loadWithOverrides`：设置界面预览用的内存覆盖，排在命令行之上、`-e` 之下；`defaultConfig`：只含 GX 默认值的配置，供界面「恢复默认」；`overlayPath`：覆盖文件放在首选用户配置文件旁（`file_load.preferredDefaultFilePath`，Windows 为 `%XDG_CONFIG_HOME%\ghostty` 或 `%LOCALAPPDATA%\ghostty`，Linux 为 `$XDG_CONFIG_HOME/ghostty` 或 `~/.config/ghostty`）。
- 默认值：主题 `GX Mocha`、`language = zh-CN`、`JetBrainsMono Nerd Font` 加把 CJK 码段映射到 `Noto Sans CJK SC` 的 `font-codepoint-map`、字号 12、内边距、闪烁块光标、解绑 Alt+1..8、`gx:` 快捷键与三条命令面板条目；Windows 另设 `quit-after-last-window-closed = true`。
- 默认值里三条命令面板条目的标题与描述是英文 msgid，`gx.zh_CN.po` 必须有它们的译文（单测锁定）。上游 GTK 面板原样显示配置文字，所以 GTK 构建在 `load` 时按各层最终的 `language` 把默认值层这些条目的重放步骤改写成译文（`translatePalette`），主题与条件重放、克隆都保留；win32 面板显示时才翻译，用户自己写的条目不改。
- `gui_settings.zig::Overlay` 逐行编辑，保留注释、空行、未知键与顺序，`save` 原子替换文件。`theme.zig::install` 在加载前把内置主题写进用户主题目录 `<配置目录>/ghostty/themes`，文件首行是 `theme.marker`；内容变化才替换，没有标记的同名用户文件不动。
- fork 配置键是 `src/config/Config.zig` 中 GX-0010 块的字段：`gx-launch-profile`（`名称=命令`，可重复）、`gx-herdr-app-mode`（默认 true）、`gx-window-material`（`solid|mica|acrylic|tabbed`，只在 Windows 生效）、`gx-idle-processes`（可重复，空时用 `policy.builtin_idle_processes`）、`gx-open-config-ui`（`settings|editor`，默认 settings）；`language` 只认 `zh-CN` 与 `en`。字段的 doc comment 就是用户文档，写法见 `config.md`。

### i18n

- `i18n.zig`：`Language`（`zh_CN`、`en`，默认 zh-CN）、`parseLanguage`、`resolve`、`current` 与 `setCurrent`（进程级原子值）、`tr`（msgid 必须编译期已知，查表在编译期完成）、`trCtx`、`trRuntime`、`format` 与 `fill`（`{name}` 占位符）。
- `scripts/gx_i18n.py` 合并上游 `po/zh_CN.po` 与 fork 的 `src/gx/i18n/gx.zh_CN.po`（同一键以 fork 为准），跳过 fuzzy、废弃条目与空译文，带 msgctxt 的条目以 `<msgctxt>\x04<msgid>` 为键；fork 条目的 `{name}` 占位符必须与原文一致；输出按键排序、确定性。`just i18n` 写出 `src/gx/i18n/zh_CN.zig`，`just i18n-check` 只读校验，属于 `just framework-check` 与 `just generated-check`。

### gx: 动作与启动配置

- `action.zig::Action` 的语法是 `gx:<name>[:<argument>]`：`settings`、`main_menu`、`keybinds`、`new_tab_profile:<id>`、`new_window_profile:<id>`。GX-0014 给 `input.Binding.Action` 加 `gx` 成员；核心 `Surface.performBindingAction` 在 apprt 声明了 `gxAction` 时调用 `rt_app.gxAction(target, action)`（win32 的 `App.gxAction`，GTK 的 `App.gxAction` 转给 `src/apprt/gtk/gx/app.zig`），否则记 warn 并返回 false，`performable:` 绑定因而把按键交还终端。
- `profiles.zig::detect` 是 `Environment` 的纯函数。Windows：GX Zsh 与 herdr（依次查 `<exe>\..\bin`、`%LOCALAPPDATA%\Programs\GXShell\bin`、`%LOCALAPPDATA%\Programs\OhMyZshGX\bin`，再查 `PATH`）、PowerShell 7、Windows PowerShell、cmd、Git Bash、MSYS2 UCRT64、Nushell、注册表里的每个 WSL 发行版；Linux：GX Zsh 与 herdr（`/usr/lib/ohmyzsh-gx/bin`，再 `PATH`）、登录 shell、zsh、bash、fish；最后是 `gx-launch-profile` 的 `custom:<名称>`。`defaultProfile`：Windows 依次 GX Zsh、pwsh、powershell、cmd，Linux 依次 GX Zsh、登录 shell。

## 不变量

- 可在任何主机上测：探测与判断写成注入 `Environment`、`io` 或 `/proc` 目录的纯函数（`profiles.detect`、`proc.procSnapshot`、`app_mode.procRunsHerdr`），两个平台的规则都能单测；Windows 专属代码按 `builtin.os.tag` 编译期门控（`conpty`、`confirm.windows`、`profiles.wslDistros`）。
- 与 UI 工具包无关：`src/gx` 不导入 GTK、Win32 UI 模块或 apprt；`settings_map`、`gtk_css` 只产出数据与文本，界面在各 apprt 里。`src/gx` 只属于 app 产物（`config_layers` 读 `src/global.zig`），libghostty-vt 可达的代码不得导入它。
- 层序是用户契约：改层或排序要同时更新 `config_layers.zig` 的文件头、`defaults.ghostty` 的注释与单测。默认值文件不写颜色（颜色来自主题）。`gui-settings.ghostty` 只由设置界面经 `Overlay` 或 `settings_map.Changes` 写入；任何代码都不写用户的 `config.ghostty`。
- fork 的界面文字是英文 msgid 加 `gx.i18n`：编译期字面量用 `tr`，运行期才知道的 msgid（如启动配置名）用 `trRuntime`。新 msgid 先查 `po/zh_CN.po` 有没有上游译文，没有才加进 `gx.zh_CN.po`，再 `just i18n`，`.po` 与生成表进同一提交。
- 进程判断保守：读不到进程（pid 未知、组长已退出、`/proc` 打不开、Linux 与 Windows 以外的系统）按「忙」处理，保持上游结论。只在关闭与退出确认、应用模式轮询时列进程，在 GUI 线程同步进行，不持 `renderer_state.mutex`。
- `gx:` 动作名与 `Profile.id`（`gx-zsh`、`pwsh`、`wsl:<发行版>`、`custom:<名称>` 等）出现在用户的 `keybind`、`command-palette-entry` 里，改名属于破坏性变更。

## 禁止项

- 不手改 `src/gx/i18n/zh_CN.zig`；不为 fork 字符串改 `po/zh_CN.po` 或上游 pot；fork 代码不用 gettext 的 `_`、`N_`、`C_`。
- 不在 `src/gx` 引入 GTK、Win32 UI 依赖或网络访问；不在默认值文件里写颜色或本机路径。
- 不绕过 `config_layers` 与 `gui_settings` 读写配置文件。
- 不把 GX 逻辑写进上游文件；确需新钩子时按 GX-NNNN 登记，钩子只调用 `src/gx` 或 apprt 的 GX 层（`development.md`）。

## 验证

- 单测：`just test --filter gx.`。Windows 本机跑 win32 构建的 `ghostty-test`（2026-10 本机 128 条，热缓存墙钟约 3 s），覆盖 Windows 分支；Linux 分支用 `just wsl test --filter gx.`（`-Dapp-runtime=none`，与 gx-ci 的 `linux-main` 相同）。改平台专属代码时两边都跑。
- 翻译：`just i18n` 后 `just i18n-check`；改生成器跑 `python scripts/run_unittests.py test_gx_i18n`。
- 改配置键、默认值或分层：`just test --filter gx.config_layers --filter gx.settings_map`，再按 `config.md` 的验证生成文档（`just build -Demit-webdata`），并用隔离配置启动 app 核对效果（GUI 证据见 `apprt-win32.md`、`apprt-gtk.md`）。
- 改 Zig 跑 `just fmt-check`；改了 `pub` 签名或 `//!` 文档跑 `just kb`。
