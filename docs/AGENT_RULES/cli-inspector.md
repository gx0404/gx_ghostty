# cli-inspector：CLI 动作、参数解析、终端 inspector 与生成的补全/语法文件

## 范围

- `src/cli.zig` 与 `src/cli/**`：动作检测 `action.zig`、动作登记与分派 `ghostty.zig`、通用参数解析 `args.zig`（含 `CommaSplitter.zig`）、诊断 `diagnostics.zig`、分页 `Pager.zig`、`tui.zig`；每个 `+action` 一个文件（`version`、`help`、`list-fonts`、`list-keybinds`、`list-themes`、`list-colors`、`list-actions`、`ssh`、`ssh-cache`、`edit-config`、`show-config`、`explain-config`、`validate-config`、`show-face`、`crash-report`、`boo`、`new-window`、`new-tab`、`toggle-quick-terminal`），`ssh-cache/` 磁盘缓存，`+list-themes` 的预览文本 `lorem_ipsum.txt`，开发说明 `README.md`。
- `src/inspector/**`（inspector 核心与 `widgets/`）与 `pkg/dcimgui/**`（Dear ImGui 的 C 绑定包）。
- `src/extra/**`：bash/fish/zsh 补全、vim 与 sublime 语法文件的编译期生成器。
- 并集分工：`src/extra/{bash,fish,zsh}.zig` 同属 `shell-integration.md`，`+ssh` 与 shell 脚本的契约也在那里；配置语义见 `config.md`；inspector 的宿主见 `apprt-gtk.md`（`src/apprt/gtk/class/inspector_widget.zig`、`imgui_widget.zig`）与 `libghostty-embedding.md`（`ghostty_inspector_*`）；`ghostty-build-data` 入口 `src/main_build_data.zig` 与资源安装归 `build-system.md`、`packaging-dist.md`。

## 符号真源

### 动作

- `src/cli/action.zig::detectIter`：扫描全部参数，把 `+<name>` 映射为枚举值；出现第二个动作报 `MultipleActions`，未知名字报 `InvalidAction`；枚举可声明 `detectSpecialCase` 返回 `SpecialCase`。同一个检测器被 `src/global.zig::init`（ghostty 与 libghostty）、`src/main_build_data.zig`、`src/benchmark/cli.zig`、`src/synthetic/cli.zig` 共用。
- `src/cli/ghostty.zig::Action` 是动作的唯一登记处：
  - `detectSpecialCase`：`--version` 立即选中 `version`；`--help`、`-h` 只在没有别的动作时回落为 `help`；尚未见到动作就遇到 `-e` 时停止检测，所以 `ghostty -e ghostty +foo` 不会执行动作。
  - `run` 把 `Action.help_error` 转成打印 `help_strings.Action.<name>` 并返回 0；`file` 把 tag 中的 `-` 换成 `_`，得到 `cli/<name>.zig`；`options` 返回该动作的 `Options` 类型，供补全生成。
- 执行：`src/global.zig::init` 检测到动作后默认关闭 stderr 日志（`GHOSTTY_LOG` 可重新打开）；检测出错（多个动作、未知动作）时 `src/main_ghostty.zig::main` 打印说明并退出 1，否则以 `run` 的返回值作为进程退出码，动作返回错误时退出 1。macOS 的 app 可执行文件经 `src/main_c.zig::ghostty_cli_try_action` 走同一条路径。
- 动作文件的形状：`pub const Options` 的字段就是旗标（`_` 前缀为内部状态）；需要 `-h`、`--help` 的动作实现 `help` 并返回 `Action.help_error`（`help.zig` 自行处理）；带 `///` 注释的 `pub fn run(alloc) !u8`，这段注释就是 `+<name> --help`、`ghostty(1)` 与网站 `commands.mdx` 的正文（`src/cli/README.md`）。
- IPC 动作 `+new-window`、`+new-tab`、`+toggle-quick-terminal` 经 `apprt.App.performIpc`，只有 GTK 实现（`src/apprt/gtk/App.zig::performIpc`），none 与 embedded 一律返回 false。

### 参数解析与诊断

- `src/cli/args.zig::parse`：只接受 `--key=value` 与 `--key` 两种写法；`parseManuallyHook`、`help`、`compatibility`、`_arena`、`_diagnostics` 都是按 `@hasDecl`、`@hasField` 启用的可选协议。`parseIntoField` 按字段类型分派：bool 缺值视为 true，空值复位默认值，有 `parseCLI` 时优先调用；packed struct 支持 `no-` 前缀与整体 `true`/`false`；tagged union 写成 `tag:value`；普通 struct 写成 `k:v,…`，由 `CommaSplitter` 处理引号与转义。
- `args.argsIterator` 跳过 argv0，`ArgsIterator` 跳过所有以 `+` 开头的参数；`args.LineIterator` 把配置文件的每一行转成 `--key=value`（语法细节见 `config.md`）。
- `src/cli/diagnostics.zig`：`Diagnostic.format` 输出 `<路径>:<行>:<键>: <消息>`，来源是命令行时为 `cli:<序号>:`；`DiagnosticList` 在 libghostty 构建中额外维护 `precompute` 消息表。
- `src/cli/Pager.zig`：stdout 是 TTY 时按 `$GHOSTTY_PAGER` > `$PAGER` > `less` 启动分页器，变量设为空串即关闭；`+show-config` 与 `+explain-config` 使用。

### inspector 与 dcimgui

- `src/inspector/Inspector.zig`：`setup`（要求宿主已设置当前 ImGui 上下文；开启 docking 与 sRGB，`IniFilename`、`LogFilename` 置空，使用内嵌字体）、`init`/`deinit`、`recordKeyEvent`（最多保留 50 条）、`recordPtyRead`、`render`。整体布局在 `src/inspector/widgets/surface.zig::Inspector.draw`，各面板在 `widgets/*.zig`。
- 生命周期由 Surface 管理：`src/Surface.zig::Surface.activateInspector`、`deactivateInspector`（加锁与通知顺序见 `app-core.md`）。
- 宿主：GTK 用 OpenGL3 后端（`imgui_widget.zig`，关停时调用 `ImGui_ImplOpenGL3_ShutdownWithLoaderCleanup`）；macOS 经 `src/apprt/embedded.zig` 的 `ghostty_inspector_*` 使用 Metal 后端。
- `pkg/dcimgui`：`build.zig.zon` 钉 Dear ImGui 1.92.5 docking 分支与配套的 dear_bindings v0.17（注释要求两者严格对应）；`build.zig` 的 `freetype`、`backend-opengl3`、`backend-metal`、`backend-osx` 由 `src/build/SharedDeps.zig` 按目标设置（非 Apple 用 OpenGL3，Apple 用 Metal，macOS 另加 OSX）。`main.zig` 暴露 translate-c 生成的 `c`，并手写后端函数、DockBuilder 内部 API（其头文件的位域 translate-c 处理不了）与 `ext`；`ext.cpp` 补上 dear_bindings 缺的构造函数和 OpenGL3 加载器清理。

### 生成器（`src/extra/`）

- `bash.zig`、`fish.zig`、`zsh.zig` 的 `completions`，`vim.zig` 的 `syntax`、`ftdetect`、`ftplugin`、`compiler`，`sublime.zig` 的 `syntax`：都在编译期遍历 `Config` 字段与 `Action.options()` 生成；fish 另取 `help_strings.Config` 的首句作为描述。
- 构建时由 `ghostty-build-data`（`src/main_build_data.zig::Action`）输出到 stdout，再由 `src/build/GhosttyResources.zig::init` 安装到 `share/bash-completion/completions/`、`share/fish/vendor_completions.d/`、`share/zsh/site-functions/_ghostty`、`share/vim/vimfiles/`、`share/nvim/site/` 与 `share/bat/syntaxes/`。
- vim 插件反过来调用 CLI：`keywordprg=ghostty +explain-config`；编译器 `makeprg=ghostty +validate-config --config-file=%:S`，`errorformat=%f:%l:%m,%m`。

## 不变量

- 新增动作要四处一起改：`Action` 的 tag、`src/cli/<name>.zig` 文件、`Action.runMain` 与 `Action.options` 两个 switch。`+help` 的列表、补全、`ghostty(1)`、`commands.mdx` 都从 `Action` 派生，不另立清单。
- helpgen（`src/helpgen.zig::genActions`）在每个动作文件里找第一个 `fn run`，要求它以 `pub fn run` 声明且紧挨 `///` 注释，否则构建期打印错误并退出 1。helpgen 随每次 exe、lib、`ghostty-test` 构建运行，所以一个动作缺注释会让这些构建全部失败；动作文件里也不要在它之前出现其他名为 `run` 的函数。
- 退出码与输出是脚本契约：`+validate-config` 有诊断时返回 1；`Diagnostic.format` 的 `<路径>:<行>:` 前缀被 vim 的 `errorformat` 解析。`+version` 的输出被上游 CI（fork 中已归档的 `test.yml` 用 `grep` 检查构建模式）与 fork 的 `gx-release`（核对 `$VS`）读取，改格式前先同步 `ci-release.md`。
- `src/cli/args.zig` 同时定义 CLI 旗标、配置文件、`GHOSTTY_LOG`、GTK 的 IPC 覆盖项（`src/apprt/gtk/class/Overrides.zig`）与 bench、gen 工具的参数语法，任何语义变化都是用户可见的语法变化。
- `Options` 的字段名和类型就是补全内容，改名、改类型会同时改变 shell 补全。手工解析参数的动作要让 `Options` 与实际接受的旗标保持一致：`explain_config.zig` 手工处理 `--no-pager`，而 `Options` 没有这个字段，补全因此缺它。
- `+ssh` 的 `--forward-env`、`--terminfo` 与 `--` 分隔被五种 shell 集成脚本直接调用，不能单方面改（见 `shell-integration.md`）。`src/cli/ssh.zig::Options` 带 `_diagnostics`，未知旗标只记诊断而不致命；`parseManuallyHook` 把第一个不以 `--` 开头的参数及其后全部参数原样交给 `ssh`。
- 诊断只经 `DiagnosticList.append` 追加，`precompute` 消息表与 `list` 必须一一对应（有断言保护）。
- inspector：
  - 只在宿主已设置当前 ImGui 上下文时调用 `setup` 与绘制。绘制由 apprt 宿主驱动，与 termio、渲染线程并发，读取终端状态的面板只在 `renderer_state.mutex` 内访问（加锁集中在 `Inspector.draw`），不得在锁外保留 `Terminal`、page 或 pin。
  - 启用期间 `src/termio/Termio.zig::processOutputLocked` 改为逐字节交替喂给 inspector 与终端流；未启用时必须保持整块 `nextSlice` 的快路径，记录逻辑不得进入未启用分支。
  - `Inspector.render` 每帧唤醒渲染线程，这是有意的调试开销；`deactivateInspector` 必须完整撤销，关闭后不留常驻开销。ImGui 的 ini 与 log 文件保持关闭，不往用户目录写布局。
- dcimgui：升级时 imgui 与 dear_bindings 的 URL、hash 一起换；translate-c 处理不了的 API 在 `pkg/dcimgui/main.zig` 手写 extern，缺的 C++ 便利函数加进 `ext.cpp` 并在 `main.zig` 的 `ext` 中声明。
- 生成器在编译期遍历 `Config` 与 `Action`，新键、新动作会自动进入补全与语法文件。特殊补全（`font-family*` 补字体、`theme` 补主题、`working-directory` 补目录、`RepeatablePath` 补文件、packed struct 列出 `no-` 变体）按字段名或类型写死在各生成器里，新增同类字段时检查是否需要对应分支。

## 禁止项

- 不在 `src/cli/ghostty.zig` 之外维护动作清单；不把帮助文本另写成字符串常量；不省略 `run` 的 `///`。
- 不在 CLI 动作里初始化 GUI apprt；IPC 只经 `apprt.App.performIpc`。
- 不在 `renderer_state.mutex` 之外读写终端状态；不往 inspector 核心引入某个 apprt 专有的依赖，宿主差异留在 apprt 层。
- 不提交、不手改生成物：缓存里的 `dcimgui.h`，安装出来的补全与语法文件。
- 不改 dcimgui 的上游源码（以 lazy 依赖拉取），只改 `pkg/dcimgui` 的包装层。
- `src/cli/**`、`src/inspector/**`、`src/extra/**`、`pkg/dcimgui/**` 是上游源码：fork 内改动须带 `fork(gx)` 标记并登记 GX 补丁（`development.md`）。

## 验证

- 定向单测（`just test`，只在 Linux/macOS 可跑；Windows 上直接退出 2，交 gx-ci `linux-main`）：
  - 动作检测：`just test --filter detect`。
  - 参数与配置行：`just test --filter parseIntoField`、`just test --filter LineIterator`、`just test --filter splitter`。
  - `+ssh`：`just test --filter parseDestination`、`just test --filter parseManuallyHook`；分页器：`just test --filter pager`；fish 描述：`just test --filter getDescription`。
- 动作冒烟需要可运行的 `ghostty`（Linux 的 GTK 构建或 macOS app；Windows 构建不出可执行文件，本机记 PENDING）：`ghostty +help`、`ghostty +<动作> --help`（核对 help 文本）、`ghostty +version`。
- 生成器：Linux 上 `just build` 会运行 `ghostty-build-data` 并安装产物，检查 `zig-out/share/` 下对应文件；Windows 默认 `app-runtime=none`，不安装这些资源。
- inspector 没有单测（见上游指令）：编译与交互验证只能在 Linux GTK（`just build` 后在 Ghostty 里打开 inspector）或 macOS 上进行，本机 Windows 记 PENDING。
- 收尾：`just fmt-check`；改了 `pub` 签名或文档后跑 `just kb`。

## 上游指令

- `src/inspector/AGENTS.md`：查 dcimgui C API 与 ImGui 示例的方法、macOS 上的构建参数、本包没有单测。改 `src/inspector/**` 时 resolver 会一并列出，必读，这里不复制。补充 fork 事实：经 `scripts/zigw.py` 运行时，Zig 全局缓存默认在仓库内的 `.local/zig-cache/global`，从仓库根执行的查找同样覆盖它。
