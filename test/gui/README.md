# GUI 场景（test/gui）

每个场景是一份 TOML 文件，写明隔离配置、操作步骤，以及截图里必须看到什么。运行器负责启动、输入和截图，但**截图逐张读过之后结论才算数**，PASS 的判据见 `docs/TESTING.md`「证据规则」。

| 目录 | 平台 | 运行器 | 每个场景的证据 |
|---|---|---|---|
| `win32/W*.toml` | Windows，本机交互式桌面 | `scripts/gx_win_gui.py`（`just win-gui`） | `<out>/<id>/`：截图、`run.json`（每步的耗时与结果）、`ghostty.log`、`notes.txt`、隔离配置目录 `env/` |
| `gtk/G*.toml` | Linux GTK，WSL 里的 Xvfb | `scripts/gx_wsl.py scenario`（`just wsl scenario`） | `<out>/<id>/`：`<id>.png`、`<id>-after.png`、日志、版本、`notes.txt`；`<out>/SUMMARY.txt` |

## 运行

Windows：先 `just build`。看性能或发布形态时，改用 ReleaseFast 构建，再用 `--exe` 指过去。

```sh
just win-gui list                                   # id、标题、前置条件与副作用
just win-gui run --out .local/evidence/<任务>/shots W01 W03
just win-gui run --exe <ghostty.exe> --retries 1 --out <目录>
```

GTK：先把工作树同步进 WSL 克隆并构建：`just wsl sync --dirty`，然后 `just wsl build --gtk`。

```sh
just wsl scenario --out .local/evidence/<任务>/gtk          # 全部 G 场景
just wsl scenario --out <目录> G02 G05
```

运行器的退出码是 0 表示所有场景都 OK。这只说明步骤执行完了、断言通过了，读图仍然要逐张做。打开 `notes.txt` 对照其中的 `expect` 一条条看。

## 编号与覆盖

- `W01`–`W15` 逐条对应 R0 的验收点，删改前要先确认验收点已有别的覆盖。`W16` 起的场景用来采集界面现状截图：chrome 巡览、模拟 DPI、多标签、中文界面。
- 编号连续、不重复，文件名以编号开头（`W16-chrome-tour.toml`）。`scripts/test_gx_win_gui.py` 与 `scripts/test_gx_wsl.py` 会检查编号，并检查每个场景都有 `expect`、在 `config` 里显式写了 `language`。
- 新场景接着最大编号往下编。

## Windows 场景格式

顶层键：

- `id`、`title`、`config`：config 是 `config.ghostty` 的内容。
- `harness`：默认 true，会在配置末尾追加 `confirm-close-surface = false`，关窗时就不会弹确认。
- `env`：环境变量表。运行器启动 Ghostty 时会去掉调用方的 `NO_COLOR`、`TERM*`、`GHOSTTY_*`，需要的变量（如 `GHOSTTY_GX_OPENGL = "software"`）在这里写。
- `args`：额外的命令行参数。
- `requires`：前置条件，取值为 `wsl:<发行版>`、`file:<路径>` 或 `windows-build:<号>`。不满足的场景记 SKIPPED。
- `side_effects`：写明场景会影响桌面之外的东西（如打开默认浏览器）。这类场景只有加 `--allow-side-effects` 才会运行。
- `expect`：截图必须显示的内容，写成「截图名: 内容」。
- `[[step]]`：按顺序执行的步骤。

步骤由 `action` 选定，参数表以 `scripts/gx_win_gui.py::ACTIONS` 为准：

- 等待与断言：`wait_window`、`wait_terminals`、`wait_popup`、`wait_title`、`assert_title`、`wait_log`、`assert_log`、`wait_file`、`assert_responsive`、`pixel`。`wait_popup` 的 `cls` 按类名前缀匹配；`new = true` 时，只认最近一次输入之后才出现的弹层。`wait_file` 等一个文件的全文匹配正则，例如终端里的程序写出的结果，WSL 里的文件可以用 `\\wsl.localhost\<发行版>\…` 路径读。注意 shell 默认是规范模式：不按回车，`cat` 收不到输入，屏幕上看到的 `^[[O` 之类只是行规程的回显；要让程序直接拿到输入，先执行 `stty -icanon -echo`。
- 输入：`type`（KEYEVENTF_UNICODE 逐字输入，`\n` 是回车）、`key`（带扫描码的真实虚拟键，如 `ctrl+shift+t`）、`click`、`mouse_down`、`mouse_up`、`move`、`drag`、`drag_divider`、`wheel`、`clipboard`。
- 钩子：`dpi`（`WM_GHOSTTY_SIMULATE_DPI`）、`gpu_reset`、`cancel_mode`、`ime_off`、`resize`、`activate`、`close`、`file`（写一个文件）、`sleep`。
- 截图：`capture`。`what` 可取 `window`（默认）、`quick`、`popups`、`all`（主窗加每个弹层）。`method` 可取 `screen`（默认，窗口被别的程序挡住时失败）或 `print`（PrintWindow）。

坐标都是 DIP，相对于锚点：`in = "client"`（默认）、`"window"` 或 `"terminal:N"`（第 N 个可见终端，按先上后下、先左后右排序）。运行器按窗口 DPI（或 `dpi` 步骤模拟的 DPI）换算成物理像素。负数从右下角往回算，也可以写百分比（如 `"25%"`）。

每次发输入之前，运行器都会确认前台窗口属于这个实例；发鼠标事件之前，还要确认指针下的窗口也属于它。条件不满足就不发送，并让这一步失败。运行器从不把输入打到别的程序。宿主程序偶尔会抢走前台，这时加 `--retries 1` 让失败的场景重跑一次。

## GTK 场景格式

顶层键：`id`、`title`、`config`、`lang`（`en` 或 `zh_CN`，设置 locale）、`xdotool`（第一张截图之后运行的 xdotool 脚本，`$1` 是 Ghostty 的 PID）、`wait`（等窗口出现的上限，默认 20 s）、`settle`（窗口出现后到截图的间隔，默认 3 s）、`env`、`args`、`expect`、`forbid`。

`forbid` 是日志里不允许出现的行的正则，默认是 `Theme parser error` 和 `css parsing failed`，命中就判失败。

Xvfb 里没有窗口管理器，脚本要先 `mousemove 400 300` 再 `click 1` 把键盘焦点给终端。Xvfb 里也没有合成器，所以弹出菜单周围透明的阴影区会画成黑色，这不是渲染错误。

## 写场景的经验

- 界面语言在 `config` 里显式写：GX 默认是 `language = zh-CN`，与 locale 无关。
- shell 用固定提示符，截图与像素断言才稳定：Windows 写 `command = cmd.exe /d /k prompt $G$S`，GTK 写 `command = /bin/bash --noprofile --norc`。
- 弹层（菜单、面板、设置、对话框）是独立的顶层窗口。按键之后先 `wait_popup`（`new = true`）等它出现，再截图，并在截图里用 `what = "all"` 把弹层一起截下来。
- 模态对话框会让主窗失去输入能力。运行器激活主窗时，实际激活的是它的 `GW_ENABLEDPOPUP`，所以测试顺序不会让对话框丢掉键盘焦点。
- 微软拼音会把 Ctrl+Shift+F 当作简繁切换吞掉，打开查找栏之前先 `ime_off`。
- 连续粘贴时，每次粘贴后等约 0.4 s，让剪贴板读取完成。
