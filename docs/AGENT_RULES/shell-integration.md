# shell-integration：shell 集成脚本、自动注入与 terminfo

## 范围

- `src/shell-integration/**`：`bash/ghostty.bash`；vendored 的 `bash/bash-preexec.sh`（rcaloras/bash-preexec 0.7.0，只在 Bash 4.4 以下作为回退加载）；`zsh/.zshenv` 与 `zsh/ghostty-integration`；`fish/vendor_conf.d/ghostty-shell-integration.fish`；`elvish/lib/ghostty-integration.elv`；`nushell/vendor/autoload/ghostty.nu`；开发说明 `README.md`（含各 shell 的手动加载方法）。
- 自动注入 `src/termio/shell_integration.zig` 与命令拼接、转义 `src/os/shell.zig`（两者同属 `termio-pty-os.md`）。
- terminfo：`src/terminfo/**`。`ghostty.zig` 是 Ghostty terminfo 条目的 Zig 真源，`Source.zig` 是编码器，`main.zig` 是包入口。
- `src/extra/{bash,fish,zsh}.zig` 是补全生成器，机制见 `cli-inspector.md`。补全装在 `share/bash-completion`、`share/fish/vendor_completions.d`、`share/zsh/site-functions`，由各 shell 自己的补全系统加载，与 `share/ghostty/shell-integration` 下的集成脚本无关，两者不要混改。
- 相邻：调用点 `src/termio/Exec.zig`、资源目录 `src/os/resourcesdir.zig`（`termio-pty-os.md`）；`+ssh`、`+ssh-cache`（`cli-inspector.md`）；OSC 解析（`terminal-core.md`）；脚本与 terminfo 的安装 `src/build/GhosttyResources.zig`（`packaging-dist.md`）。

## 符号真源

### 自动注入（`src/termio/shell_integration.zig`）

- `setup(alloc_arena, resource_dir, command, env, force_shell)` 返回 `ShellIntegration`（`shell` 与改写后的 `command`），返回 null 表示不注入。`force_shell` 来自配置 `shell-integration`，取 `detect` 时为 null，交给 `detectShell`。
- `detectShell` 只看 argv0 的 basename：`bash`、`elvish`、`fish`、`nu`、`zsh`；Darwin 上的 `/bin/bash`（系统自带的 Bash 3.2 关闭了基于 `ENV` 的 POSIX 启动路径）返回 null。
- bash（`setupBash`）：命令改写成 `<bash> --posix …`；`ENV` 指向 `<resources>/shell-integration/bash/ghostty.bash`，原值存入 `GHOSTTY_BASH_ENV`；`GHOSTTY_BASH_INJECT` 为 `1` 再加上截获的 `--norc`、`--noprofile`；`--rcfile`、`--init-file` 的值存入 `GHOSTTY_BASH_RCFILE`；`HISTFILE` 未设时设为 `~/.bash_history` 并置 `GHOSTTY_BASH_UNEXPORT_HISTFILE`。遇到 `--posix` 或含 `c` 的短选项组时放弃注入。脚本据此退出 posix 模式，并按 bash(1) INVOCATION 的规则自行 source 启动文件。
- zsh（`setupZsh`）：`ZDOTDIR` 指向 `<resources>/shell-integration/zsh`，原值存入 `GHOSTTY_ZSH_ZDOTDIR`；`zsh/.zshenv` 先恢复 `ZDOTDIR` 并 source 用户的 `.zshenv`，交互 shell 再 autoload `ghostty-integration`（要求 zsh 5.1 及以上）。
- fish、elvish（`setupXdgDataDirs`）：把 `<resources>/shell-integration` 前置到 `XDG_DATA_DIRS`（原来为空时补上 `/usr/local/share:/usr/share`），并存入 `GHOSTTY_SHELL_INTEGRATION_XDG_DIR`，脚本加载后自行从 `XDG_DATA_DIRS` 中移除它。elvish 只拿到模块路径，仍需用户 `use ghostty-integration`。
- nushell（`setupNushell`）：同样设置 XDG，再追加 `--execute 'use ghostty *'`；遇到 `--command`、`--lsp` 或含 `c` 的短选项时放弃改写命令，但保留 XDG 改动。
- `setupFeatures(env, features, cursor_blink)`：把 `src/config/Config.zig::ShellIntegrationFeatures`（`cursor`、`sudo`、`title`、`ssh-env`、`ssh-terminfo`、`path`）中开启的项按名称排序、用逗号连接后写入 `GHOSTTY_SHELL_FEATURES`；`cursor` 后附 `:blink` 或 `:steady`（取 `cursor-style-blink`，未设时按闪烁）；全部关闭时不设置该变量。
- 调用点 `src/termio/Exec.zig::Subprocess.init`（完整的子进程环境契约见 `termio-pty-os.md`）：总是先调用 `setupFeatures`，手动加载的集成也依赖它；`shell-integration = none` 或没有资源目录时不调用 `setup`。脚本依赖其中三项：`GHOSTTY_RESOURCES_DIR`；`TERMINFO=<resources>/../terminfo`（只在找到资源目录、`TERM` 取配置 `term` 时设置，否则 `TERM=xterm-256color`）；`GHOSTTY_BIN_DIR`（Flatpak 内不设置）。
- `src/os/shell.zig::ShellCommandBuilder` 只用单个空格拼接参数、跳过空串、不加引号；`ShellEscapeWriter` 给 shell 特殊字符加反斜杠（换行除外），供 `src/os/edit.zig` 与 GTK 拖放路径使用。

### 脚本协议

- 行为只由 `GHOSTTY_SHELL_FEATURES` 决定：`path` 把 `GHOSTTY_BIN_DIR` 追加到 `PATH` 末尾（已存在则跳过）；`sudo` 包装成 `sudo --preserve-env=TERMINFO`（带 `-e`、`--edit` 时不加；除 nushell 外还要求 `TERMINFO` 非空）；开启任一 `ssh-*` 时 `ssh` 改走 `"$GHOSTTY_BIN_DIR/ghostty" +ssh [--forward-env=false] [--terminfo=false] -- <参数>`。nushell 只实现 `ssh` 与 `sudo`，`title`、`cursor` 等由 nushell 自身提供（README）。
- 发给终端的序列：OSC 133 语义提示（`A` 提示开始、`B` 输入开始、`C` 输出开始、`D;<状态>` 命令结束、`P;k=i|s` 主/次提示；bash 附带 `aid`、`redraw=last`、`cl=line`，fish 4.1 起附带 `click_events=1`）；OSC 7 报告工作目录（bash、zsh、elvish 用原始路径的 `kitty-shell-cwd://`，fish 用 URL 编码的 `file://`）；OSC 2 标题；`CSI 5 q`、`CSI 6 q` 在提示处设为闪烁或常亮竖条光标，执行命令前用 `CSI 0 q` 复位。
- 接收端：`src/terminal/osc/parsers/semantic_prompt.zig::parse`、`src/terminal/osc/parsers/report_pwd.zig::parse`，以及 `src/termio/stream_handler.zig::StreamHandler.reportPwd`（只接受 `file` 与 `kitty-shell-cwd` 两种 scheme）。

### terminfo

- `src/terminfo/ghostty.zig::ghostty`：名称 `xterm-ghostty|ghostty|Ghostty` 与全部能力。`version` 是编码结果的 Wyhash，`+ssh` 的安装缓存（`src/cli/ssh-cache/DiskCache.zig`）用它判断远端条目是否过期；`+ssh` 经 `ssh … tic -x -` 在远端安装同一份编码结果（`src/cli/ssh.zig`）。
- `src/terminfo/Source.zig`：`encode` 输出 terminfo 源文本；`xtgettcapMap` 在编译期生成 XTGETTCAP 应答表（另外提供 `TN`、`Co=256`、`RGB=8`），被 `src/termio/stream_handler.zig` 与 libghostty-vt 的 `src/terminal/stream_terminal.zig` 使用。
- 构建：`ghostty-build-data +terminfo` 输出源文本。`-Demit-terminfo` 决定是否安装源文件 `ghostty.terminfo`（默认 Windows 开，其他平台 Debug 开、Release 关），`-Demit-termcap` 决定是否安装 `infotocap` 转出的 `ghostty.termcap`（Debug 默认开）；非 Windows 还总会用 `tic -x` 编出数据库，并以 `cp -R` 复制以保留符号链接。何时安装、装到哪里见 `packaging-dist.md`；Windows 默认 `app-runtime=none`，这些步骤都不执行。

## 不变量

- terminfo 只在 `src/terminfo/ghostty.zig` 里改；源文件、数据库、termcap、XTGETTCAP 应答、远端安装都由它派生。首名必须保持 `xterm-ghostty`，并与配置 `term` 的默认值一致（文件中的 HACK 注释：vim 依赖 `xterm` 前缀启用按键协议，tcell 要求首名等于 `TERM`）。
- `xtgettcapMap` 在编译期展开：不支持 canceled 能力，`^X` 控制字符只能位于字符串开头，违反即编译失败。terminfo 进入了 libghostty-vt 的编译闭包，改动要同时满足 lib-vt 的构建约束。
- 资源目录靠已安装的 terminfo 定位：`src/os/resourcesdir.zig::resourcesDir` 在 Release 构建中先看环境变量 `GHOSTTY_RESOURCES_DIR`（Debug 构建则把它放到最后），再从可执行文件向上查找 `share/terminfo/x/xterm-ghostty` 一类的哨兵路径（Windows 为 `terminfo/ghostty.terminfo`，macOS 为 `terminfo/78/xterm-ghostty`）。改 terminfo 的安装路径或名字，会连带让 shell 集成、主题与传给子进程的 `GHOSTTY_RESOURCES_DIR` 一起失效。
- 注入失败必须静默降级：资源缺失、shell 未识别、遇到不支持的参数时 `setup` 返回 null，按原命令启动且不改环境（nushell 遇到不支持参数时保留 XDG 改动是有意的例外，有测试锁定）；不得因此让终端启动失败。现状有一处偏差：`setupZsh` 先写 `GHOSTTY_ZSH_ZDOTDIR` 再检查目录，用户原本设了 `ZDOTDIR` 而资源缺失时它会残留（上游既有行为，测试未覆盖）。
- 被改动的环境变量都要能还原：Zig 侧把原值存入 `GHOSTTY_BASH_ENV`、`GHOSTTY_ZSH_ZDOTDIR`、`GHOSTTY_SHELL_INTEGRATION_XDG_DIR`，脚本读取后清除。变量名两侧必须同步修改，子进程不得继承注入用的 `ENV`、`ZDOTDIR` 与 XDG 前缀。
- 脚本原样安装：`GhosttyResources` 把 `src/shell-integration` 整目录装到 `share/ghostty/shell-integration`，只排除 `.md`。脚本只能按自身位置或 `GHOSTTY_RESOURCES_DIR`、`GHOSTTY_BIN_DIR` 定位文件，不写死安装前缀；同时必须支持 README 里的手动 source（bash 用 `GHOSTTY_BASH_INJECT` 区分自动注入），并在非交互 shell 中立即返回。
- 新增集成特性要一次改齐：`ShellIntegrationFeatures` 的字段、配置键 `shell-integration-features` 的 doc comment、`setup features` 测试里的期望串，以及需要它的各个脚本。bash、zsh、elvish 用子串匹配（如 `*"title"*`、`*ssh-*`），新名字不得包含已有名字，也不得被已有名字包含。
- `ssh` 包装依赖 `src/cli/ssh.zig::Options` 的旗标名与 `--` 分隔，并直接调用 `$GHOSTTY_BIN_DIR/ghostty`；改任何一侧都要同步另一侧。
- 脚本发出的序列必须是终端侧能解析的：新的 OSC 133 选项先在 `semantic_prompt.zig` 支持；OSC 7 只用 `file` 或 `kitty-shell-cwd`。
- `setupBash`、`setupNushell` 用 `ShellCommandBuilder` 把参数重新拼成 `.shell` 字符串且不加引号；改动这里的参数处理时，要补上含空格或引号参数的测试。

## 禁止项

- 不改 vendored 的 `bash/bash-preexec.sh`（只随上游同步；`.editorconfig` 也为它单列缩进规则）。
- 不手写 terminfo 或 termcap 文本，不提交构建产出的 `ghostty.terminfo`、`ghostty.termcap` 与 terminfo 数据库。
- 不在脚本里写死安装路径或依赖仓库布局；不在脚本中输出 Ghostty 终端不解析的私有序列。
- 不让注入失败中断子进程启动；不在 `setup` 放弃注入后留下半套环境变量（nushell 的 XDG 例外除外）。
- 不把补全生成器（`src/extra/`）的改动当成集成脚本的改动来验证，反之亦然。
- `src/shell-integration/**`、`src/terminfo/**`、`src/termio/shell_integration.zig`、`src/os/shell.zig` 是上游源码：fork 内改动须带 `fork(gx)` 标记并登记 GX 补丁（`development.md`）。

## 验证

- 注入与特性（`just test`，Windows 上只是尽力而为；其中两个 `xdg:` 测试在 Windows 上主动跳过）：`just test -Dtest-filter=bash -Dtest-filter=zsh -Dtest-filter=nushell -Dtest-filter=xdg`、`just test -Dtest-filter=detectShell`、`just test -Dtest-filter=features`。
- 命令拼接与转义：`just test -Dtest-filter=ShellCommandBuilder`、`just test -Dtest-filter=escape`。
- terminfo：`just test -Dtest-filter=xtgettcap`（`Source.zig` 的应答表；过滤区分大小写）与 `just test-vt -Dtest-filter=XTGETTCAP`（libghostty-vt 侧的应答）。安装产物只能在 Linux 或 macOS 上检查：`just build -Demit-terminfo -Demit-termcap` 后查看 `zig-out/share/terminfo/`；本机 Windows 记 PENDING。
- 脚本：仓库内没有脚本单测。`*.sh`、`*.bash` 用 `HACKING.md` 的 ShellCheck 一节给出的上游命令检查（本机未装 shellcheck，未运行就记 PENDING，fork CI 也不跑）；其余 shell 只能在 Linux GTK 构建里实机打开对应 shell，核对 `GHOSTTY_SHELL_FEATURES`、提示跳转与工作目录继承。`ssh-terminfo` 的端到端用例是 `nix/tests.nix` 中的 `ssh-integration-test`，按 `HACKING.md` 的 Nix VM 一节运行，需要 Nix，本机记 PENDING。
- 收尾：`just fmt-check`；改了 `pub` 签名或文档后跑 `just kb`。
