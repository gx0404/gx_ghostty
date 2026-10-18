# 测试与证据（gx_ghostty）

每一层都要写清楚能证明什么、不能代证什么。不同层不能互相顶替，Windows 本机的结果也不能顶替 Linux 或 macOS。命令细节见 [MAKE_COMMANDS.md](MAKE_COMMANDS.md)，九步闭环见 [DEVELOPMENT.md](DEVELOPMENT.md)，测试相关的领域规则见 `docs/AGENT_RULES/testing.md`。

## 分层

| 层 | 命令 | 前置 | 能证明 | 不能代证 |
|---|---|---|---|---|
| 框架单测 | `just framework-test`（`scripts/run_unittests.py` 并行）；只跑一部分用 `python scripts/run_unittests.py <PATTERN…>` | Python ≥ 3.10 | resolver、hook 允许与拒绝探针、版本、提交规范、zigw 与 setup、两个测试运行器、WSL 入口的命令与脚本构造、GUI 自动化与耗时脚本的纯逻辑及场景文件、打包与 GX Shell stage、发布脚本、workflow 形状与启用集合、KB 检索回归、图谱指纹、fork 补丁标记与 GX CSS 的 GTK 4.14 语法约束、三个 GX Zig 测试根的显式收集（`scripts/test_gx_test_roots.py`）、GTK GX 层对上游 blueprint 的替换契约（`scripts/test_gtk_gx_contract.py`）、GX 译表等框架契约 | 任何 Zig 产品行为；真实下载与真实安装；AI 客户端的新会话是否真的加载了配置（见 AI_TOOLS.md 验证账本） |
| 规则闭集 | `just rules-check` | Python、Git | 每个 Git 可见文件都有路由、pattern 无零命中、与 `root_only` 不重叠；嵌套 `AGENTS.md` 与登记一致；领域文档闭集与体积；根 `AGENTS.md` ≤16 KiB 且含 fork 标记 | 规则内容是否与源码一致，这要靠复审 |
| 版本格式 | `just version-check` | Python | `CHANGELOG.md` 标题都合法、至少有一个，可以取出最大 SemVer | 能否发版：`gx-release` 以 `publish=true` 运行时，prepare 另要求最大版本已带日期且版本段非空 |
| KB 新鲜度 | `just kb-check` | Python | `docs/kb/chunks.json` 与当前语料一致 | 文档内容是否正确 |
| GX 译表 | `just i18n-check` | Python | `src/gx/i18n/zh_CN.zig` 与两份 `.po` 一致，占位符匹配 | 译文质量、界面上是否真的用了这条译文 |
| 拼音首字母表 | `just pinyin-check`（`scripts/gx_pinyin.py --check`，离线；重建用联网的 `just pinyin`） | Python | `src/gx/pinyin/initials.zig` 与生成器一致 | 源数据本身是否正确、界面上的拼音匹配行为 |
| 图谱新鲜度 | `just graph-check` | Python；不需要本机 `graph.json` | 被索引源码、管线脚本与入库报告的指纹一致 | 图谱质量；它不在 framework-check、ci-check 与 push CI 里 |
| Zig 格式 | `just fmt-check` | 钉版 Zig（`just setup`） | 全仓 `.zig` 文件符合 `zig fmt`（排除 `.local`、`zig-pkg`、`zig-out`、`.zig-cache`） | 能否编译，行为是否正确 |
| libghostty-vt 单测 | `just test-vt`（`scripts/zig_test.py` 并行分片），定向加 `--filter <子串>` | Zig；Windows 需 MSVC | 以 `src/lib_vt.zig` 为根的 Zig 模块与 C API 模块的单测在本机目标上通过，判定与 `zig build` 相同 | ABI 清单、其他目标、完整单测（`zig build test` 不包含 test-lib-vt，反之亦然） |
| ABI 清单 | `just zig build test-lib-vt-schema` | Zig；PATH 上的 `python3` 是真实解释器且装有 `jsonschema`，wasm 目标还要 `wasmtime`（上游靠 `nix develop` 提供） | 本次构建出的共享库导出的类型清单符合 `src/terminal/c/types.schema.json` | 运行时行为 |
| 完整 Zig 单测 | `just test`（同一运行器，`--suite main`），定向加 `--filter <子串>` | Zig。Windows 上运行器按 `-Dapp-runtime=win32 -Dtarget=x86_64-windows-gnu` 构建，不需要 MSVC；未开开发者模式时 2 个 tinyio 符号链接用例失败 | 以 `src/main.zig` 为根的 `ghostty-test` 在该 apprt 与目标下通过。Windows 构建含 win32 apprt、`src/gx/` 与 Windows 专有分支（DirectWrite、ConPTY、OSC 7 路径、Toolhelp32 进程树）的单测；Linux/macOS 构建含 `/proc` 等 POSIX 分支 | libghostty-vt 单测；另一平台的专有分支（Windows 结果不代证 Linux，反之亦然）；`-Dapp-runtime=none` 时不含任何 GUI apprt；GUI 行为；macOS app 的 Swift 单测（上游 `zig build test` 在 macOS 上不带 `-Dtest-filter` 时会挂上 `xcodebuild test`，`just test` 不含，用 `macos/build.nu --action test`） |
| 上游串行对照 | `just zig build test-lib-vt`，可加 `-Dtest-filter=<名> --summary all`；完整单测用 `just zig build test`（Windows 上加 `-Dapp-runtime=win32 -Dtarget=x86_64-windows-gnu`；macOS 上不带 `-Dtest-filter` 时还多跑 app 的 `xcodebuild test`） | Zig；lib-vt 在 Windows 上需 MSVC | 同一批用例由 `zig build` 在单个进程里逐条运行时也通过，用来排除运行器（分片、进程复用、调度顺序）对结论的影响 | 并行运行器已证明的内容之外，只多证明「与上游运行方式一致」；lib-vt 全量要 6–8 min |
| C 与 Zig 示例 | 在 `example/<dir>` 下执行 `python ../../scripts/zigw.py build`，`python ../../scripts/zigw.py build run` 运行（Linux/macOS 用 `python3`） | 钉版 Zig；示例经 `../../` 路径依赖本仓 | 外部消费者能按示例方式链接 libghostty-vt，如静态链接的 `c-vt-static`、动态链接的 `c-vt-effects` | 其他示例与其他平台 |
| 交叉构建 | `just build-vt -Dtarget=<triple>` | Zig | 该目标能编译、链接 | 在该目标上的运行结果 |
| wasm | `just vt-wasm`，再 `node test/wasm-alloc.mjs zig-out/bin/ghostty-vt.wasm` | Zig；冒烟需要 Node | wasm32-freestanding 的 ReleaseSmall 构建；导出的分配接口可用 | 浏览器集成与性能 |
| 源码包 | `just dist-vt`；完整校验 `just zig build distcheck -Demit-lib-vt=true` | Zig、Git；distcheck 的内层命令另需 PATH 上的 `zig`（0.16.x）、`tar` 与 `cmake` | dist：用 `git archive` 打包 HEAD 生成源码 tarball；distcheck：解包后 `test-lib-vt` 通过，且 CMake 能从 tarball 构建 | 工作树里未提交的改动（不进 tarball）；二进制发布包 |
| Windows app 构建 | `just build`（可加 `-Doptimize=ReleaseFast`） | Windows、钉版 Zig；首次构建联网拉依赖 | win32 app 能以 GNU ABI 编译链接，`zig-out\bin\ghostty.exe` 与 `share\` 安装成功 | 运行行为；不经 `just` 时的 MSVC ABI 构建（未验证） |
| Windows GUI 验证 | `just win-gui run --out <目录> [W01 …]` 回放 `test/gui/win32/` 的场景，或启动 `zig-out\bin\ghostty.exe`（或解压的便携包）用其他桌面自动化操作并截图，见下文「Windows GUI 验证」 | Windows 10/11 的交互式桌面会话 | 截图里看得到的界面状态，加上日志里对应的行 | 其他 Windows 版本、显卡驱动与显示缩放；没截图覆盖的交互；Linux 与 macOS |
| Windows 打包 | `just package-windows`（`--skip-installer` 只出 zip） | Windows；安装包要 `just setup --innosetup`；首次要联网下载钉版组件 | ReleaseFast 构建；zip 与安装包的名字、目录布局、必需文件与最小体积符合 `scripts/gx_release.py::expected_assets`；每个钉版下载与包内文件的 sha256 一致 | 安装、升级、卸载在真实系统上的行为（要另外装一遍验证）；签名（资产没有 Authenticode 签名） |
| GTK 冒烟（CI） | 手动触发 `gx-ci`，打开 `gtk_smoke` 输入 | fork 已启用 Actions，提交已 push | debian:13 容器里 GTK app 能以 ReleaseFast 构建，`ghostty +version` 能运行，在 Xvfb（1280x800，X11 后端、软件渲染）下启动 20 秒后仍在运行并完成截图；artifact `gx-gtk-smoke-evidence` 必须下载并实际读图 | 渲染内容是否正确（以读图结论为准）、Wayland、IME、真实桌面交互与其他发行版 |
| Windows 冒烟（CI） | 手动触发 `gx-ci`，打开 `win_smoke` 输入 | 同上 | windows-2025 上 Debug 构建的 win32 app 用钉版 Mesa llvmpipe（`GHOSTTY_GX_OPENGL=software`）启动 20 秒后仍在运行，日志有 `loaded OpenGL 4.` 行，并截下主屏；artifact `evidence-windows-smoke` 必须下载并实际读图 | 硬件 GPU 渲染、随包 ConPTY（冒烟不放它）、ReleaseFast 包、真实交互 |
| WSL 本机 Linux | `just wsl test`（主套件，`-Dapp-runtime=none`）、`just wsl test --gtk`、`just wsl test --suite vt`、`just wsl build --gtk` 后 `just wsl smoke --out <目录>`、`just wsl scenario --out <目录>`（`test/gui/gtk/` 的 G 场景）与 `just wsl smoke --perf`（见 MAKE_COMMANDS.md「WSL」） | Windows 与 WSL2 Ubuntu 24.04，`just wsl setup` 装好钉版 Zig、blueprint-compiler 0.16.0 与 Zig 包 | 该 Ubuntu 24.04（GTK 4.14.5、libadwaita 1.5.0）上完整单测（含 GTK apprt 时也含 `src/apprt/gtk/gx/`）与 lib-vt 单测通过；GTK app 能构建，以与 `gtk-smoke` 相同的 Xvfb 参数启动并截图，`--lang` 切换 locale，xdotool 脚本可以驱动键盘输入；G 场景的日志里没有 CSS 解析错误；`--perf` 给出吞吐负载下各线程的 CPU 时间；截图须实际读图 | gx-ci 的 debian:13 容器与 ReleaseFast 构建；有合成器的真实桌面（Xvfb 里没有窗口管理器与合成器）、Wayland 与 IME；WSLg 交互（本机截不到 WSLg 窗口内容，只能确认窗口出现） |
| GX Shell deb stage（Ubuntu 24.04） | 本机：WSL 里用 podman 起全新 `ubuntu:24.04` 容器，照 `scripts/gx_package.py` 模块文档「Consumer contract」的 deb 命令运行，再在另一个全新容器 `apt-get install` `test-deb` 打出的包并截图；CI：运行 `gx-release`，看 `linux-gtk-noble` | 本机需 WSL2 与 podman（或 docker）；CI 需 fork 已启用 Actions | 文档里的命令能在只装了 `ca-certificates`、`git`、`python3` 的 Ubuntu 24.04（GTK 4.14.5、libadwaita 1.5.0）上装好依赖、以 ReleaseFast 构建并生成通过 `verify-stage` 的 stage；随包的 `libgtk4-layer-shell.so` 经 RUNPATH `$ORIGIN/../lib` 加载；测试包的 Depends 在全新系统上能解析，`ghostty-gx +version` 等于 `$VS`，Xvfb 截图须实际读图 | CI 在构建容器里安装测试包，开发包已在，所以不证明 Depends 完整（本机第二个全新容器才证明）；GX Shell 的正式 deb、Wayland 与真实桌面 |
| macOS lib-vt | 手动触发 `gx-ci`，打开 `macos` 输入 | 同上 | macos-15 上 `zig build test-lib-vt` 通过 | macOS app 构建（Xcode）、签名、公证与 app 交互 |
| macOS app 构建 | 手动运行 `gx-release`，打开 `macos` 输入（`publish=false` 只构建不发布） | 同上 | macos-26 上 `zig build -Doptimize=ReleaseFast` 产出只做 ad-hoc 签名的 `Ghostty.app`，以 artifact 形式保留 | GUI 行为、正式签名与公证；没有自动化的 macOS GUI 冒烟 |
| valgrind | `just zig build test-valgrind`、`just zig build run-valgrind` | Linux 与 valgrind，手动执行 | 单测或运行期没有 valgrind 能发现的内存错误（已知误报由 `valgrind.supp` 抑制） | 其他平台 |
| fuzz | 在 `test/fuzz-libghostty` 下 `zig build` 构建 harness（需要 `afl-cc`），再按该目录的 `AGENTS.md` 用 `zig build run-<name>` 跑 AFL++ | Linux 或 macOS 与 AFL++，手动执行 | 在给定语料和时长内没有发现崩溃 | 不存在崩溃的普遍结论 |
| esctest | 在 `test/esctest` 下 `zig build run`，比较输出里的通过计数 | Linux 或 macOS（运行器用 `forkpty` 拉起 `python3`），手动执行 | 同一环境下改动前后的一致性计数变化 | 不是通过门：上游许多用例本来就失败 |
| benchmark | `just build -Demit-bench -Doptimize=ReleaseFast`，用 hyperfine 对比（见 `src/benchmark/AGENTS.md`） | 手动执行，同一台机器、同一份输入；Linux 或 macOS（Windows 上 GNU ABI 能构建这些工具，见 `docs/AGENT_RULES/build-system.md`「平台」，但没有在 Windows 上做过基准） | 声明条件下的耗时对比 | 普遍性能结论 |
| GUI 耗时 | `just perf win32 --exe <旧> --exe <新> --out <目录>`、`just perf gtk --clone <克隆> --out <目录>`；已有样本用 `just perf summarize` / `just perf compare`（见下文「耗时度量与基线」） | ReleaseFast 构建；Windows 交互式桌面或 WSL；机器空闲 | 同一台机器、同一负载下，两个构建的启动、新标签、分屏、resize 与 GTK 吞吐负载 CPU 时间的中位数与 p90 之差 | 其他机器、驱动与显示设置；绝对性能结论；正确性 |
| NixOS VM | 按 `HACKING.md` 运行 `nix run .#checks.<system>.<test-name>.driver`，全部用 `nix flake check` | Nix，手动执行 | `nix/tests.nix` 定义的 GUI 与集成场景 | 非 NixOS 环境 |
| 上游 lint | 按 `HACKING.md`「Linting」一节运行 prettier、alejandra、shellcheck、swiftlint | 对应工具，本机均未安装 | 文档、Nix、shell、Swift 符合上游 lint 规则 | fork CI 不跑这些检查；没实际跑过就不能声称通过 |

聚合入口：`just framework-check` = rules-check → version-check → framework-test → kb-check → i18n-check → pinyin-check，不需要 Zig，本机约 15 s；`just ci-check` = framework-check → fmt-check → test-vt，提交前必跑，热缓存约 100 s，改过 Zig 源码另加约 2 min 编译（见下节）；`just generated-check` = kb-check → i18n-check → pinyin-check → graph-check，上游同步后与发版前必跑。valgrind、fuzz、esctest、benchmark、NixOS VM 与上游 lint 是上游的手动流程，fork 不提供专门的 just 配方，也不进 CI。

示例、`test/fuzz-libghostty` 与 `test/esctest` 是各带 `build.zig` 的子工程，`just` 配方总在仓库根执行、进不了这些目录；表中子工程里的 `zig build …` 都在该目录用钉版 Zig 运行，即 `python ../../scripts/zigw.py build …`（Linux/macOS 用 `python3`）。

## Windows GUI 验证

本机 Windows 能直接运行 Ghostty GX，GUI 可见的 Windows 改动在本机验收（规则正文在 `docs/AGENT_RULES/apprt-win32.md`「验证」段）；GTK 走 WSL 的 `just wsl smoke` 或 `gx-ci` 的 `gtk-smoke`，macOS 没有 GUI 冒烟。

做法：

1. 构建：`just build`；看性能或发布形态时用 `-Doptimize=ReleaseFast`，或解压 `just package-windows` 的便携 zip。
2. 隔离：把 `LOCALAPPDATA` 与 `XDG_CONFIG_HOME` 都指向 `.local/evidence/<任务>/env/<场景>`，配置写在其下的 `ghostty\config.ghostty`，日志落在 `ghostty\logs\ghostty.log`，不读写用户真实的配置与日志。隔离后，只装在真实 `%LOCALAPPDATA%\Programs` 下、不在 `PATH` 上的 GX Zsh 探测不到，默认 shell 会退到 PowerShell，需要时在配置里写 `command`。agent 的 shell 常带 `NO_COLOR=1`，启动前去掉它，否则 pwsh 等不输出颜色与粗斜体。`just win-gui` 自动做这些隔离。
3. 操作：优先用 `just win-gui`（见下文）回放场景或逐条发命令；临时探查也可用其他桌面自动化（如 kimi-cu 对 `GhosttyWindow` 的截图、点击与按键），或 PowerShell 的 `CopyFromScreen` 截图脚本。执行要验证的操作：点击、按键、输入法输入、拖动改尺寸、切换语言或主题等。
4. 截图与读图：在每个要证明的状态截图，图片存到 `.local/evidence/<任务>/`（gitignored，不入库），逐张打开读图、对照预期写结论；同时读日志里相关的行（如 `loaded OpenGL … software=`、`ConPTY: …`、确认与菜单的日志）。结论写明提交、构建类型、Windows 版本号、显示缩放、显卡或 Mesa（日志里的 `renderer=` 与 `software=`）。

可以记 PASS 的证据：在真实桌面会话里截下、已经读过、能看出预期状态的截图，加上对应的日志行。不能记 PASS 的：只确认进程在运行或窗口存在；截图全黑、全白或截到了别的窗口；截了但没读；只读日志没看界面。

已知的坑：微软拼音把 Ctrl+Shift+F 当作简繁切换吞掉，自动化测试查找栏前先切到英文键盘布局，或从命令面板打开查找；GUI 子系统的 exe 没有控制台（见下文「Windows 本机限制」）；复现 CI 的软件渲染设 `GHOSTTY_GX_OPENGL=software`，并把 Mesa 的 DLL 放进 exe 旁的 `mesa\`。

难在本机复现的路径有测试钩子：向顶层窗口 `SendMessage` `src/apprt/win32/Window.zig::WM_GHOSTTY_SIMULATE_DPI`（`wParam` 为 DPI）走一遍 `WM_DPICHANGED` 的处理，向终端子窗口发 `src/apprt/win32/Surface.zig::WM_GHOSTTY_SIMULATE_GPU_RESET` 让渲染器把下一帧当作 GPU 重置处理。钩子只证明这两条代码路径，不代证真实的多显示器与驱动重置。软件渲染路径用 `GHOSTTY_GX_OPENGL=software` 加 exe 旁的 `mesa\` 验证（`gx-ci` 的 `win_smoke` 也是这样做的）。

### 自动化：`just win-gui`

`scripts/gx_win_gui.py` 只用标准库与 ctypes，把上面的隔离、输入、截图与取证做成命令：

- **场景**：`test/gui/win32/W*.toml`，格式见 `test/gui/README.md`。`just win-gui run --out <目录> [W01 …]` 逐个场景用全新的隔离配置启动、执行步骤、截图，在 `<目录>/<id>/` 写截图、`run.json`（每步的耗时与结果，以及 `startup_ms`）、日志副本与 `notes.txt`（每张图必须显示什么）。缺前置（WSL 发行版、Windows 版本）的场景记 SKIPPED；有副作用的场景（W06 会打开默认浏览器）只在加 `--allow-side-effects` 时运行；`--retries N` 重跑失败的场景。退出码 0 只说明步骤与断言通过，图仍要逐张读。
- **单步**：`just win-gui start <ENV_DIR> [--config <文件>] [--env 名=值]` 启动一个实例（状态在 `ENV_DIR/session.json`），之后用 `key`、`type`、`click`、`wheel`、`drag`、`capture`、`pixel`、`wait-log`、`dpi`、`ime-off`、`cancel-mode`、`windows`、`activate` 操作它，`stop` 关闭。
- **隔离**：`LOCALAPPDATA` 与 `XDG_CONFIG_HOME` 指向 `env/`，去掉调用方的 `NO_COLOR`、`TERM`、`COLORTERM`、`TERM_PROGRAM*`、`GHOSTTY_*`；GX 开关用 `--env` 或场景的 `env` 显式传。只关自己启动的实例：结束进程前核对映像路径与创建时间。清空配置目录前，要求其中有本工具写的标记文件。
- **输入守门**：进程以 Per-Monitor-V2 DPI 感知、用物理像素工作。每次 `SendInput` 前，前台窗口必须属于该实例；鼠标事件前，指针下的窗口也必须属于它，否则不发送并让这一步失败。坐标写 DIP，按窗口 DPI（或 `dpi` 步骤模拟的 DPI）换算；双屏时虚拟桌面原点可能为负，绝对坐标按虚拟桌面归一化。
- **截图**：默认 `screen`，像 `CopyFromScreen` 那样截屏幕，窗口被别的进程挡住时失败；`print` 用 `PrintWindow`（`PW_RENDERFULLCONTENT`），挡住也能截。菜单、面板、设置等弹层（`GhosttyGxPopup`）是进程的独立顶层窗口，`what = "all"` 把它们逐个截下。

| 场景 | 验证内容 | 前置 / 副作用 |
|---|---|---|
| W01 | 标签标题覆盖不被终端标题冲掉，空标题清除覆盖 | — |
| W02 | 查找栏里的编辑组合键留在查找框，不进 shell | — |
| W03 | 查找高亮匹配项，Esc 清除高亮 | — |
| W04 | 嵌套分屏的分隔条跟随指针；关掉一个窗格后焦点给相邻窗格 | — |
| W05 | 打开命令面板不预览第一行主题；Esc 恢复原主题 | — |
| W06 | Ctrl+单击 4100 字符的 URL 能打开，窗口不卡死 | 副作用：默认浏览器打开 `http://127.0.0.1:9/` |
| W07 | 启动即失败的命令在窗口底部显示非模态的「Command Failed」提示（D12）：提示不抢焦点，主窗仍执行分屏绑定；在失败终端按一个键只关闭它，提示随之消失 | — |
| W08 | 连续五次粘贴都进查找框，Ctrl+Shift+V 粘贴进 shell | — |
| W09 | 焦点上报：每次切标签往返恰好一对 `^[[O` / `^[[I` | `wsl:Ubuntu-24.04` |
| W10 | 水平滚轮：向右报按钮 67，向左报 66 | `wsl:Ubuntu-24.04` |
| W11 | 侧键 X1、X2 报 SGR 按钮 128、129，各一次按下一次松开 | `wsl:Ubuntu-24.04` |
| W12 | 按住时丢失鼠标捕获只报一次松开，之后的抬起不再报 | `wsl:Ubuntu-24.04` |
| W13 | quick terminal 一开始滑入就有键盘焦点 | — |
| W14 | 切成不透明后，经过面板主题预览仍保持不透明 | `windows-build:22621` |
| W15 | `goto_tab` 从 1 数起，`last_tab` 到末尾，`move_tab` 只移一格（不是交换） | — |
| W16 | chrome 巡览：主菜单、快捷键速查表、设置 | — |
| W17 | 模拟 DPI 96 → 144 → 192，chrome 与终端一起缩放 | — |
| W18 | 3 个与 12 个标签时标签栏怎样收窄、溢出 | — |
| W19 | zh-CN 界面：窗口与主菜单 | — |
| W20 | 拖动分屏分隔条、已关闭的 HWND 与后台标签推迟的 DPI 变化 | — |

W01–W15 逐条对应 R0 的验收点，W16 起采集界面现状截图。R0 验收时踩过、已写进工具与场景的坑：

- 宿主程序（如 agent 的桌面端）偶尔抢走前台：守门拒绝发送，这一步失败，场景不会误操作别的窗口；加 `--retries 1` 重跑。
- 模态对话框会禁用主窗：`activate` 改为激活主窗的 `GW_ENABLEDPOPUP`，否则对话框拿不到键盘焦点。W07 的失败提示是非模态 Notice，不经这条路径：先用绑定动作确认主窗仍收键，再在失败终端按空格（不触发输入法组字）关闭它，并等提示消失。
- 弹层出现有延迟：按键后先等 `wait_popup`（`new = true` 只认这次输入之后出现的弹层），再截图。
- 连续粘贴之间等约 0.4 s，让剪贴板读取完成（W08）。

## GTK 截图验证

GTK 的 GUI 可见改动在本机 Windows 上没有 GTK 桌面，截图证据来自下面两处，都要实际读图：

- 本机 WSL：`just wsl build --gtk` 后 `just wsl smoke --out <Windows 目录>`（Xvfb，参数与 `gtk-smoke` 相同；`--lang`、`--xdotool`、`--config`、`--env`、`--settle` 按需），截图与日志复制回 Windows，读图后才记 PASS。它是 Ubuntu 24.04 上的证据，不代证 `gtk-smoke`。
- 场景：`just wsl scenario --out <Windows 目录> [G01 …]` 逐个跑 `test/gui/gtk/G*.toml`（格式见 `test/gui/README.md`），每个场景一份配置、一段 xdotool 脚本、一次 smoke，日志命中 `forbid`（默认 `Theme parser error`、`css parsing failed`）即失败；`<id>/notes.txt` 列出读图要点，`SUMMARY.txt` 每个场景一行。G01 英文启动、G02 中文主菜单、G03 设置对话框、G04 快捷键速查表的搜索、G05 双标签加分屏、G06 浅色主题加命令面板；G07–G13 是主菜单、启动配置菜单、标签右键菜单、快捷键速查表与设置分页，G14 Ctrl 滚轮缩放字号，G15 把现有分屏移到新标签，G16 从启动配置菜单打开启动配置管理器。Xvfb 里没有窗口管理器，脚本先在终端里单击一次取得键盘焦点；也没有合成器，弹出菜单周围透明的阴影区画成黑色，不是渲染错误。
- CI：手动触发 `gx-ci` 并打开 `gtk_smoke`，下载 artifact `gx-gtk-smoke-evidence` 读图；`gx-release` 的 `linux-gtk-noble` 另有 Ubuntu 24.04 测试包的截图（`evidence-linux-gtk-noble`）。
- 读图之前一律记 PENDING：提交没 push、CI 没跑、artifact 还没下载或下载了没读，都不能记 PASS。

## 耗时度量与基线

`scripts/gx_perf.py`（`just perf`）收集、汇总并对比 GUI 的耗时样本，只管测量与统计；结论要写明机器、构建类型与负载。

- **样本**：`src/gx/perf.zig::record` 只写微秒时间 `info(gx_perf): <指标> <值>us`；解析器兼容 ns、ms、s 的历史时间行。计数必须另用无单位的 `metric <名> <值>`，同名 time/count 冲突拒绝。另收集 `metric <名> <值> [s|ms|us]`、Debug 的 `window shown after <n>ms`、`gx_win_gui.py` 的 `startup_ms`，以及 Windows 时间戳日志里的首次 OpenGL 探测、配置、字体、子进程与渲染上下文里程碑。时间换算为毫秒，p90 取最近秩；递归路径归一去重，父子目录重叠不会增加 n，跳过隔离配置目录中的日志原件。普通 `summarize` 仍可汇总任意指标，但不是性能通过门。
- **Windows**：`just perf win32 --exe <旧> --exe <新> --out <目录> [--runs 10] [--resizes 6] [--env 名=值]`。每个构建一个隔离配置，先跑一轮丢弃的预热，此后都是热启动；两个构建按 A B、B A 交替，让机器状态的漂移同时作用于两边。每轮记录进程创建到主窗口创建、可见、取消 cloak 的时间（`startup.created`、`startup.visible`、`startup.shown`，1 ms 轮询），Ctrl+Shift+T 与 Ctrl+Shift+O 到新终端子窗口可见的时间（`new_tab.terminal_visible`、`split.terminal_visible`），`SetWindowPos` 改尺寸的同步耗时（`resize.setwindowpos`），以及窗口是否仍响应消息。每轮写 `<目录>/<标签>/run-NN.txt` 与日志副本，最后写 `SUMMARY.txt`。
- **GTK**：先 `just wsl build --gtk -Doptimize=ReleaseFast`，再 `just perf gtk --clone <克隆> [--clone <克隆>] --out <新目录> [--runs 10] [--env 名=值]`。GTK 没有自动预热；默认 AB/BA 各 10 轮，每轮都是新的私有配置和 Xvfb 会话。正常负载仍是 `seq 1 3000000`，不缩样本、不补跑失败轮。窗口出现及 done 文件都每 50 ms 轮询；elapsed 是 realtime 差，超时用 monotonic；CPU 窗口含结束后的 1 秒排空尾巴，不是与 workload_seconds 完全相同的区间。DMABUF 警告按匹配行计数，一行多个关键词只计一次。`llvmpipe-N` 合组，实际出现但未耗 CPU 的线程组仍记零；缺失不补零。
- **GTK 有效性**：实际 held exe 的 `+version` 验证 ReleaseFast，普通非 perf GUI smoke 仍可用 Debug。性能前先精确提交源树，经正常 `just wsl build --gtk -Doptimize=ReleaseFast` 生成 `.local/gx-wsl/gtk-build-receipt.json`（`gx-gtk-build-v1`）：构建 argv/退出、构建前后 commit/tree/dirty、实际 exe SHA/版本。argv 按钉版 Zig 0.16 `lib/compiler/build_runner.zig` 的选项消耗方式分类：默认目标或唯一 `install` 才能签收；允许 `--summary all`、`--color off` 等已登记带值选项及 `-j4`。该版本 `-j 4` 实测为 InvalidCharacter，不替使用者偷偷改写。`gx_wsl.py --help` 显示工具帮助，`gx_wsl.py build --help/-h` 则进入正常 Zig query，不被子命令 argparse 提前截走。help/list、test/custom step、`--`、prefix/target/emit、skip-oom 或未知 flag 都不签收性能；普通命令仍透传 Zig 输出/退出，即使查询退出 0，receipt 也只有 ineligible attempt，不探测旧映像。脏树、源树变化及不符的 version override 同样拒绝；不能手写 receipt 代 build。smoke 与 collector 交叉核对 receipt、实际映像身份、原始 version/version_exit、干净源树及 cleanup/child_exit。正常受控 pidfd SIGTERM 后 child_exit 为 -15（或正常 0）允许，崩溃 -11 等拒绝。
- **进程与线程**：启动、采样前后、xdotool、清理核对 PID/字段 22/实际 exe；持有未回收直接 Popen child 与 pidfd，信号只发受控 pidfd。pidfd 不可用启动前拒绝；打开失败只清自己的未回收 child。端点 TID/字段 22、统计完整性、负增量、main/renderer、负载/退出继续严格守门；两端相同不证明窗口内没有线程出生/退出。
- **CPU 观测与诊断**：每个端点用 `/proc/<pid>/stat` 前后夹住 task 遍历，保存原始 stat 与 monotonic ns 的读序/持续时间。`cpu.total` 取进程 post_stat 的累计 tick 增量（真实短线程试验证实包含已退出线程）；`cpu.endpoint_threads` 与各组是端点仍存活线程的量化计数，不保证相加等于进程 total。旧样本进程 1611 与端点 1571、残差 U/S=16/24、候选界 284 仅是观测，不证明 Linux adjusted CPU counters 的舍入逻辑满足 `n_before+n_after+2`。该公式及夹读增长只保留为 `diagnostic_only` 的候选界，明确 proof=unproved；不再用 `comparable=True`、超界或 50 ms 候选预算决定样本有效性，也不把残差说成精确 transient CPU/未归属区间。source identity、稳定 TID birth、完整 workload、计数非负和合法读序仍 fail-closed。比较仅在相同声明时钟/负载/环境及完整计划下统计这些观测 tick，不保证全人口、精确计量或优化收益。零组与原 comm 保存，token 碰撞拒绝。
- **证据合同**：保存 `*-meta.json`（`gx-gtk-perf-v1`）、唯一 capture_id、raw tasks/process/status/times、build receipt、退出/finished、身份检查点、实际软件相关环境与制品哈希；collector 从 raw 重算对账与 metric，不只信 valid/errors。同名前缀在排他锁内复查，复制使用独占创建，冲突非零且保留未复制 raw。GTK out 必须新/空；`gtk-runs.json` 核对唯一 `(label,run,path)`、完整 canonical AB/BA 顺序、路径不逃出 owned out、不经 symlink、每轮实际 manifest SHA 和唯一 capture。`RESULT.json` 保留原 planned_runs 与失败原因，不补跑缩 n。渲染日志保留，但 Xvfb/Mesa/env 不证明 EGL/硬件/CPU fallback，未知为 unknown。
- **对比**：`just perf compare --old <目录或文件…> --new <目录或文件…>` 要求指标/单位类别/n 对齐；GTK 两侧各有 runs 个 main/renderer/total 和窗口/负载时间。来自 declared batch 的选择还必须包含每个选中 label 的全部 planned_runs 原件；声明 10 轮却各选 run-01 不能因 n=1,1 变绿。历史无 manifest timing 可继续 unverified 统计，但旧合格身份、不完整新 receipt/CPU 对账均不能代新合同。单个 smoke 的验证只证明 harness/source 证据，不代新旧各 10 次性能门；不内置收益百分比，性能结论仍需同机同时间段 AB/BA。

2026-10-10 的基线：提交 `a3535c2ed`（工作树只改了测试块），ReleaseFast，Windows 11 构建 26300，RTX 5080（`software=false`），系统 ConPTY（exe 旁没有随包的 `conpty.dll`）；当时还没有 `src/gx/perf.zig`，所以没有 `gx_perf` 指标。证据在 `.local/evidence/R1-C/baseline/`（不入库）。

| 指标 | 机器空闲：中位数 / p90（ms） | 同时有并行构建 |
|---|---|---|
| `startup.created` | 197.4 / 206.3 | 236.6 / 254.2 |
| `startup.visible` | 233.7 / 251.5 | 284.8 / 299.1 |
| `startup.shown` | 468.4 / 496.7 | 565.8 / 625.8 |
| `new_tab.terminal_visible` | 21.2 / 23.8 | 23.8 / 26.3 |
| `split.terminal_visible` | 20.5 / 22.5 | 23.2 / 27.1 |
| `resize.setwindowpos`（n=60） | 12.3 / 14.0 | 14.5 / 16.9 |
| `log.opengl_probed` | 171.5 / 178.0 | 203.5 / 217.0 |
| `log.renderer_context` | 251.0 / 266.0 | 303.5 / 321.0 |

同日 GTK（WSL Ubuntu 24.04 的 Xvfb，ReleaseFast，10 轮，中位数 / p90）：窗口出现 497 / 552 ms；负载墙钟 3152 / 3250 ms；负载期间 CPU 时间 main 635 / 660 ms、renderer 1060 / 1080 ms、io-reader 320 / 330 ms、io-gather 1355 / 1400 ms、llvmpipe 14.1 / 14.4 s；DMABUF 警告约 620 条（当时日志报告导出失败与 CPU 呈现）。这组历史 GTK 数字没有当前进程/线程身份合同，按 unverified 保留参考，不补认成新性能门证据。

## 并行运行器与耗时

用户要求所有测试不超过 2 分钟；本机热缓存曾测得 95–110 s，但不保证每轮达标：后续包含 544 个框架测试的 `just ci-check` 实测 133.52 s（框架 12.79 s，test-vt 118.0 s，其中构建 1.5 s），退出 0、6593 条 Zig 用例通过、62 条跳过，性能要求未达成。冷编译、源码变更后的重编译与完整 CI 同样尚未达成要求。不能排除编译耗时或缩小覆盖后宣布目标完成。下列历史热缓存结果只说明其声明条件下的耗时，命令参数与退出码见 MAKE_COMMANDS.md。

**原理**：上游 `zig build test-lib-vt` 与 `zig build test` 让每个测试二进制在一个进程里逐条运行，多核基本闲置。fork 补丁 GX-0002 新增只编译、安装而不运行的步骤 `test-lib-vt-bin` 与 `test-bin`（见 FORK_PATCHES.md），`scripts/zig_test.py` 再按 Zig 测试运行器的 server 协议（`--listen=-`：先 `query_test_metadata` 取用例名，再逐条 `run_test`）把用例分到多个进程。全部用例排成一张任务表，按 `.local/test-timings/<label>.json`（`GX_ZIG_TEST_TIMINGS_DIR` 可换目录）从长到短分给 `--jobs` 个工作线程，每个线程对每个二进制复用一个测试进程；没有记录的用例按 0.1 s 估计，删掉缓存只改变调度顺序，不改变结论。每轮运行后把实测并入缓存；只有本轮由 `--suite` 构建、且 `-D` 与 `--zig-arg` 里都没有 `-Dtest-filter` 的完整二进制，才顺带删去二进制里已不存在的用例，`--no-build`、`--binary` 与带 `-Dtest-filter` 的运行只合并不删。用例崩溃或超时（单条默认 600 s）后，运行器为剩余用例重启进程。超时、崩溃与中断时，运行器在 POSIX 上杀掉测试进程所在的整个进程组，Windows 上在超时与中断时杀掉整个进程树；中断指 Ctrl+C，POSIX 上还包括 SIGTERM、SIGHUP，清理后退出 130（`scripts/run_unittests.py` 对 SIGTERM、SIGHUP 的处理相同）。

**判定**与 `zig build` 相同（`std/Build/Step/Run.zig::evalZigTest`）：先看 fail，再看内存泄漏（leak）与 error 日志（log_err）；skip 单列、不算失败；崩溃、超时与未运行都算失败。随机种子默认每轮随机，结论行总会打印 `seed 0x…`；有失败时还会打印一条可直接复制执行的复现命令：`python scripts/zig_test.py`，带上本次的 `--suite`/`--binary`、`-D`、`--zig-arg`、`--no-build` 与非默认的 `--timeout`，再加 `--seed 0x…` 与引好的 `--filter <用例全名>`。用例全名含空格，复现时原样执行这条命令，不经 just。怀疑运行器本身（分片、进程复用、执行顺序）影响结论时，用上表的上游串行路径对照。

**框架单测**：`scripts/run_unittests.py` 把每个 `TestCase` 类作为一个单元放进独立子进程，并发默认取逻辑核数与 8 的较小值——这些单元主要在起 git、bash、PowerShell 与 Python 子进程，Windows 上进程创建在少量并发时就饱和，再多只会互相拖慢。调度按 `.local/test-timings/unittest.json` 从慢到快，`RUN_LAST = True` 的类在其余单元全部启动后才启动（`scripts/test_ai_tool_hooks.py::WindowsEntryTests` 启动 Windows PowerShell 5.1，与其他单元同时跑会拖慢整机的进程创建）。子进程跑的测试数与发现阶段不符也记失败。

**实测**（本机 20 逻辑核、空闲、构建缓存命中，2026-10-07 前后）：

| 命令 | 规模与结果 | 墙钟 | 改造前 |
|---|---|---|---|
| `just test-vt` | 6655 条（vt 3096 + vt_c 3559）：6593 通过、62 跳过、0 失败 | 80.3 s，其中构建 0.6 s；2026-10-07 收尾时连续三次 84.2、95.8、89.2 s | `zig build test-lib-vt` 6–8 min |
| `just test-vt --dedupe` | vt_c 里与 vt 同名的用例不再运行 | 约 64 s | — |
| `just framework-test` | 79 个单元、约 500 个测试（两次实测 494、498 个） | 13.1 s、12.0 s | 串行 `python -m unittest discover` 约 62–87 s（当时 430 个测试） |
| `just ci-check` | framework-check 约 15 s → fmt-check 约 1 s → test-vt 约 81 s | 约 100 s；收尾时连续三次 95.4、109.7、100.8 s | — |

2026-10-09 在 32 逻辑核的本机上，Windows 主套件（`scripts/zig_test.py --suite main`，按 `-Dapp-runtime=win32 -Dtarget=x86_64-windows-gnu` 构建）热缓存跑了 4133 条用例：4071 通过、60 跳过、2 失败，失败的正是两个 tinyio 符号链接用例（未开开发者模式，`PermissionDenied`）；墙钟 45.1 s，其中构建 2.3 s，32 路并行。同日定向 `--filter gx.` 128 条（墙钟 2.8 s）、`--filter apprt.win32` 38 条（2.6 s）全部通过；冷构建 `test-bin` 用了 3 min 52 s。

- **下限**：各用例耗时合计约 1600 s（20 路并行下测得），1600 / 20 ≈ 80 s，所以 80 s 已接近 20 核的下限；最慢的单条用例 `terminal.Terminal.test.Terminal: printSlice differential fuzz vs print` 本机约 39–58 s，核数再多也快不过它。笔记本 CPU 连续满载后会降频：上表第二次紧接着第一次运行，test-vt 多花了约 10 s；本机同时有其他重负载时，全量可能超过 2 分钟。
- **`--dedupe`** 是覆盖取舍：vt_c 是同一模块以 `c_abi = true` 编译的测试二进制，同名用例在 C ABI 打开时再跑一遍，另有只在它里面的 `terminal.c.*`；去重后少了 C ABI 打开时的那一遍。默认关闭；用了就在结论里写明。
- **编译**：改过 Zig 源码后，`ghostty-vt`、`ghostty-vt-c` 两个 Debug 测试二进制都要用 LLVM 重新编译，两次编译并行，各约 2 min、约 6 GB 内存（RSS）。这段时间运行器省不掉：试过 Zig 自托管后端，它在 Windows 上编出的测试二进制无法运行。没改 Zig 源码时，`test-lib-vt-bin` 只做 1 秒内的缓存校验；运行器给测试构建钉 `-Dversion-string=<X.Y.Z>-dev+0000000`，否则版本串随提交哈希变化，每次提交都会让测试二进制整体重编。
- **CI**：`gx-ci` 的托管 runner 只有 4 个 vCPU，LLVM 编译测试二进制本身就要数分钟，用例也只能分 4 路，已测 CI 未达到 2 分钟。旧布局首次运行墙钟约 22 min（旧 `linux` job 21.5 min、`windows` 19 min）。新布局把 Linux 拆成并行的 `linux-vt` 与 `linux-main` 并改用运行器，2026-10-07 首次运行（run 37582059213，冷缓存、没有耗时记录）墙钟约 14.4 min：`linux-vt` 9.5 min（构建 91 s，6651 条用例 429 s）、`linux-main` 12.8 min（构建 419 s，3909 条用例 330 s）、`windows` 13.9 min（构建 304 s，6655 条用例 323 s），`lib-vt-cross` 各 1.3–2.7 min。之后加入的 `windows-app` 还没有在 GitHub 上跑过。

### CI 缓存诊断

`mlugg/setup-zig` 跨运行保存的 Zig 缓存目录超过 `cache-size-limit` 就被清空。旧 `linux` job 约 2.99 GB 超过默认 2048 MiB；三个测试 job 提高到 4096 MiB 后仍有失效：2026-10-07 run 37587736223 的 `linux-vt` 最终为 **5,078,327,232 字节**，超过 4096 MiB 被清空，下一轮恢复的只有 **186 字节**。不能把恢复步骤成功视为有效热缓存命中。

钉版 translate-c 源码已证实 `--zig-lib` 参数的路径直接进入 hash，旧 setup-zig 的随机解压路径因而会改变输入。后续两轮已观测到两个 VT job 的 CPU 型号变化，但其与 miss 的因果关系不能一概而论，见下方实测。当前实现与验收边界：

- `linux-vt`、`linux-main`、`windows` 的 setup-zig 均设 `use-tool-cache: true`，以固定工具链路径减少路径变体，并用 `cache-key: stable-toolchain-v1` 隔离旧变体；不删除旧 cache，4096 MiB 上限不变。`windows-app` 用同一组设置。`lib-vt-cross` 仍按 target 分 key。
- 三个测试 job 的 `GX_ZIG_TEST_TIMINGS_DIR=.zig-cache/gx-test-timings` 让调度记录随 Zig 缓存保存；只有真正恢复到有效记录，才可按上轮耗时调度。构建增加 `--summary all`（经运行器 `--zig-arg` 透传），从日志区分缓存命中和实际编译。
- `scripts/ci_cache.py snapshot` 在 restored 与 finished 两阶段按白名单记录 CPU 型号/核数、Zig 可执行文件与库路径、local/global cache 总量及顶层分区大小、timings 条数；不导出完整环境变量或文件内容。报告里的不完整扫描或错误不能当作完整统计。
- 手动输入 `cache_probe` 默认 false，只有 `workflow_dispatch` 且为 true 时才在同一 runner 重复相同套件的安装构建（main 保留 `-Dapp-runtime=none`），不重复运行用例；普通 push/PR 不增加这次编译。probe JSON 记录命令、耗时与退出码，详细构建 summary 在 job 日志。
- `gx-zig-test-<job>` 以 `always()` 上传测试 JSON、`cache-restored.json`、`cache-finished.json` 和启用探针时的 `cache-probe.json`，保留 14 天。finished 快照在 setup-zig 的 action post 之前，只反映保存前状态；还要检查 post 日志是否超限清空、下一轮 restored 是否恢复了有效数据。

#### 两轮真实 CI 验收

同一提交 `48b73e018` 的首轮 [push 37601186564](https://github.com/gx0404/gx_ghostty/actions/runs/37601186564) 与第二轮 [手动 37603432582](https://github.com/gx0404/gx_ghostty/actions/runs/37603432582)（`cache_probe=true`）均全绿。读回三个测试 job 的 JSON、构建 summary 与 action post 日志后，证据如下；下表秒数仅为构建耗时，不是测试或整个 CI 的墙钟。

| job | 首轮冷构建（s） | 第二轮恢复后首次构建（s） | 第二轮同机 probe（s） | 首次构建 / probe 的 cached 节点 |
|---|---:|---:|---:|---|
| `linux-vt` | 101.808 | 120.545 | 0.315 | 10/45 → 45/45 |
| `linux-main` | 389.189 | 187.431 | 0.416 | 49/100 → 100/100 |
| `windows` | 341.859 | 398.938 | 1.094 | 10/45 → 45/45 |

| job | 第二轮恢复目录（bytes） | 第二轮结束目录（bytes） | 恢复的 timings 条数 | 第二轮 total / passed / skipped |
|---|---:|---:|---|---|
| `linux-vt` | 1,842,888,128 | 3,459,272,197 | vt 3094 + vt_c 3557 | 6651 / 6581 / 70 |
| `linux-main` | 1,512,204,370 | 2,316,580,596 | main 3909 | 3909 / 3867 / 42 |
| `windows` | 1,350,354,731 | 2,495,151,382 | vt 3096 + vt_c 3559 | 6655 / 6593 / 62 |

- **PASS：路径固定与真实恢复。** 两轮 Linux 的 exe/lib 均为 `/opt/hostedtoolcache/zig/0.16.0/x64/{zig,lib}`，Windows 均为 `C:\hostedtoolcache\windows\zig\0.16.0\x64\{zig.exe,lib}`，逐项相同。第二轮恢复了首轮的 `stable-toolchain-v1` key，各 job 恢复目录字节数逐项等于首轮结束值，timings 完整带回；两轮 post 均为 `keeping intact`，没有清空。
- **PASS：同机复建且不重复测试。** probe JSON 的 command 数组与该 job 第一次构建完全一致，只有 `test-lib-vt-bin` / `test-bin` 安装构建步骤；各 job 日志仅一次 `[zig_test] running`，没有 filter 或 dedupe，测试无 failure。probe 的全部构建节点命中，耗时 0.315–1.094 s。
- **跨 runner 仅部分复用。** 第二轮首次构建仍有 translate-c 与测试编译节点未 cached；缓存 `o` 分区继续增长，不能把恢复成功或同机全 cached 写成跨运行全命中。本次结束大小虽均低于 4096 MiB，未来仍可能超限，不能宣称所有缓存问题已解决。
- **CPU 事实与根因分开。** `linux-vt`、`windows` 从 AMD EPYC 9V74 换成 7763，`linux-main` 两轮均为 9V74；CPU 变化对前两个 job 已是观测事实，但不足以解释所有 miss。源码支持「编译工具产物不同 → `Run.artifact` hash 改变 → 下游失效」的传播机制；初始 native 工具产物为何不同，尤其 main 同 CPU 时为何 miss，仍未确定。

固定路径、缓存恢复、timings 保留和同机快速复建已验收；跨 runner 完整复用及增长控制仍需后续运行补证。「所有测试 ≤2 min」仍未达成，不能用 probe 秒数替代全量耗时，也不得删用例、默认去重或收窄覆盖。

## CI 覆盖与本机对应

`gx-ci.yml` 的触发：push 到 `gx_ghostty`、目标为 `gx_ghostty` 的 PR，以及手动 `workflow_dispatch`（可选输入 `gtk_smoke`、`win_smoke`、`macos`、`cache_probe`，均默认 false）。全局只有 `contents: read` 权限；同一 PR 的新运行会取消旧运行，push 与手动运行互不取消（每次 push 的提交标题都要校验）。`framework` 与 `zig-fmt` 并行先跑，其余 job 都等它们通过。CI 用 `mlugg/setup-zig` 把 Zig 放到 PATH 上：直接写的 `zig build …` 用它；两个运行器经 `scripts/zigw.py` 调用 Zig，zigw 在没有钉版目录时回退到 PATH 上的同一个 Zig（版本仍须等于 `scripts/setup_zig.py::ZIG_VERSION`）。

| job | 何时运行 | 内容 | 本机对应 |
|---|---|---|---|
| `framework` | 每次 | resolver `--check`、version `--check`、`python3 scripts/run_unittests.py`、kb-check、首父链提交标题校验（push 取 `before..after`，`before` 全零时只查 head；PR 取 `base..head`；手动触发只查 head）；不跑 graph-check 与 i18n-check（GX 译表由框架单测里的 `scripts/test_gx_i18n.py` 校验） | `just framework-check`；`just commit-check --range <base>..HEAD` |
| `zig-fmt` | 每次 | `zig fmt --check .` | `just fmt-check` |
| `linux-vt` | 每次 | 装 `python3-jsonschema` 后跑 `python3 scripts/zig_test.py --suite vt` 与 `zig build test-lib-vt-schema`；`setup-zig` 设 `cache-size-limit: 4096` | `just test-vt`；ABI 清单的本机前置见下文 |
| `linux-main` | 每次，与 `linux-vt` 并行 | `python3 scripts/zig_test.py --suite main -Dapp-runtime=none`；`setup-zig` 设 `cache-size-limit: 4096` | Linux 上 `just test -Dapp-runtime=none` 或 `just wsl test`；Windows 本机的 `just test` 是 win32 构建，两者覆盖不同、互不代证 |
| `lib-vt-cross` | 每次 | 六个目标各跑一次 `zig build -Demit-lib-vt -Dtarget=<triple>`（默认 Debug）：`x86_64-linux-gnu`、`aarch64-linux-gnu`、`x86_64-linux-musl`、`x86_64-windows-gnu`、`aarch64-macos`、`wasm32-freestanding`；`setup-zig` 的 `cache-key` 按 target 区分 | `just build-vt -Dtarget=<triple>`；`just vt-wasm` 是 ReleaseSmall 变体 |
| `windows` | 每次 | windows-2025 上关闭 `core.autocrlf` 后检出，跑 `python scripts/zig_test.py --suite vt`、`zig build -Demit-lib-vt`，再构建并运行 `example/c-vt-static` 的 `c_vt_static.exe`；pwsh 中每条原生命令后检查 `$LASTEXITCODE` | `just test-vt`、`just build-vt`、示例构建 |
| `windows-app` | 每次 | windows-2025 上 `zig build -Dapp-runtime=win32 -Dtarget=x86_64-windows-gnu`（Debug）；随后在 stdout 为管道、文件与 NUL 时各跑一次 `ghostty +validate-config`，合法配置须退出 0、非法配置须退出 1（GX-0049）；再用运行器跑 fork 的 Windows 单测 `python scripts/zig_test.py --suite main -Dapp-runtime=win32 -Dtarget=x86_64-windows-gnu --filter apprt.win32 --filter gx. --filter font.directwrite --filter renderer.opengl.wgl --filter Command: --filter lib.tinyio`（前三组只编进 Windows 的测试二进制，`renderer.opengl.wgl` 是用注入函数表的 WGL 恢复与资源用例；`Command:` 含用 Windows 原生解码器核对子进程 argv 的用例（GX-0053），其余 POSIX 专用用例跳过；tinyio 的符号链接用例在本机缺权限时失败，托管 runner 有管理员令牌），报告以 `always()` 上传为 `gx-zig-test-windows-app`；`win_smoke` 为真时另下载 sha256 钉版的 Mesa 26.2.4，用 llvmpipe 启动 app 20 秒后截主屏、复制日志，检查进程仍在运行且日志有 `loaded OpenGL 4.`，证据 artifact `evidence-windows-smoke`（保留 14 天） | `just build`；`just test --filter apprt.win32 --filter gx. --filter font.directwrite --filter renderer.opengl.wgl --filter Command: --filter lib.tinyio`；Windows 主套件的其余用例只有本机 `just test` 覆盖 |
| `gtk-smoke` | 仅手动触发且 `gtk_smoke` 为真 | debian:13 容器构建 GTK app，`xvfb-run` 截图；再跑 GTK GX 层单测 `python3 scripts/zig_test.py --suite main -Dapp-runtime=gtk --filter apprt.gtk.gx`（另编一次 Debug 测试二进制），报告 `zig-test.json` 与截图一起上传为证据 artifact（保留 14 天） | `just wsl smoke`、`just wsl test --gtk --filter apprt.gtk.gx`（不同的发行版与构建类型，不代证） |
| `macos` | 仅手动触发且 `macos` 为真 | macos-15 上 `zig build test-lib-vt` | 无，本机记 PENDING |

`linux-vt`、`linux-main`、`windows`、`windows-app` 四个跑测试的 job 给运行器加 `--json "$RUNNER_TEMP/gx-zig-test/<job>.json"` 与 `--zig-arg=--summary --zig-arg=all`；成功或失败都以 `always()` 上传 artifact `gx-zig-test-<job>`（保留 14 天）。`gtk-smoke` 的测试报告在它的证据 artifact 里。测试 JSON 含失败用例全名、stderr 与本轮 seed，缓存快照及可选复建报告也在同一目录，见「CI 缓存诊断」。job 日志还有运行器打印的完整复现命令（带该 job 的 `--suite` 与 `-D`），在能编译该套件的本机上原样执行即可。

`gx-release.yml` 只能手动触发。它的 prepare 阶段强制 resolver `--check`、version `--check`、kb-check 与 graph-check，图谱或 KB 过期就拒绝发版；其中与测试证据有关的两个 job：`windows-app` 构建 ReleaseFast 的 win32 app 并打出便携 zip 与安装包（用钉版的 Inno Setup 7.1.0），`linux-gtk-noble` 在 `ubuntu:24.04` 容器按 GX Shell 的消费方命令构建 deb stage、装测试包并截图（artifact `evidence-linux-gtk-noble`）。构建矩阵与发布步骤见 RELEASE.md。上游 15 个 workflow 原样归档在 `.github/workflows-archive/`，在 `gx_ghostty` 上不会被触发，它们多数依赖上游专用的 namespace runner。

差异要点：图谱新鲜度只在发版与同步时检查，push CI 不查；Linux 完整单测（`linux-main`）、GTK 与 macOS 的 CI 证据要等用户 push 或手动触发后才有，此前一律 PENDING；Windows 主套件在 CI 上只跑 fork 的三组与 tinyio（`windows-app`），完整的 `just test` 只在本机跑。2026-10-09 时 `origin/gx_ghostty` 仍停在 `0ac89c301`（2026-10-07），之后加入的 `windows-app`、`win_smoke`、`linux-gtk-noble` 与 gx-release 的 `windows-app` 都还没在 GitHub 上跑过。

## Windows 本机限制

能跑：框架单测、`just fmt-check`、`just test-vt` 与 `just build-vt`（MSVC）、`just build` 与 `just test`（GNU ABI，win32 apprt）、Windows GUI 验证、`just package-windows`，以及经 `just wsl` 的 Linux 构建、单测与 Xvfb 截图。限制与已知的环境性失败：

- **GTK 与 macOS 的 GUI**：本机没有，GTK 用 WSL 的 `smoke` 或 `gx-ci` 的 `gtk-smoke` 补证；macOS 只能用 `gx-ci` 的 `macos`（lib-vt 测试）或 `gx-release` 的 macOS 构建补证构建层面，GUI 行为记 PENDING，不记 N/A（能力存在、只是本机缺环境）。
- **只在 Linux 上编译的代码**：`/proc`、`tcgetpgrp` 分支与 GTK apprt 不进 Windows 的 `ghostty-test`，用 `just wsl test`（`--gtk` 带上 GTK apprt）或 `gx-ci` 的 `linux-main` 补证。
- **MSVC ABI 与嵌入库**：lib-vt 走 MSVC；不经 `just` 时 Windows 目标默认也是 MSVC，app 与 `ghostty-test` 在 MSVC 下能否编译未验证。`-Dapp-runtime=none` 的 libghostty-internal 在 Windows 上链接失败（缺 `gladLoadGLContext` 等符号，见 `docs/AGENT_RULES/build-system.md`「平台」），Windows 上没有可用的嵌入库；上游手测程序 `test/windows/test_dll_init.c` 要先编出 `ghostty-internal.dll`（步骤见 `test/windows/README.md`），因此仍无法执行，记 PENDING 并注明受阻。
- **符号链接权限**：`src/lib/tinyio` 的 `deleteFile edge cases` 与 `windows: realPath resolves through symlinks` 要创建符号链接。未开启开发者模式（也不是管理员）时它们以 `PRIVILEGE_NOT_HELD` → `PermissionDenied` 失败：`just test-vt` 里每个用例在两个测试二进制各失败一次，共 4 处；`just test` 里各一次，共 2 处。这是环境前置不满足，不是代码回归；记 FAIL 并注明原因，开启开发者模式后重跑，不跳过、不改用例。gx-ci 的托管 runner 有管理员令牌：`windows` job 的 `--suite vt` 与 `windows-app` 的 `--filter lib.tinyio` 跑到这 6 处，可作 CI 补证，但不覆盖本机记录的 FAIL。
- **i18n**：Windows 上 `zig build update-translations` 直接报错（构建脚本在 gettext i18n 关闭时拒绝该步骤），上游 pot 与 `.po` 的检查交给 Linux；GX 译表 `just i18n-check` 本机照常可跑。
- **`test-lib-vt-schema`**：`build.zig` 用 `python3` 执行 `src/terminal/c/types-schema-verify.py`，缺 `jsonschema` 时脚本以「run this inside `nix develop`」退出。框架不代装这个依赖，缺失时记 PENDING，由 `gx-ci` 的 `linux-vt` job 补证。
- **GUI 子系统程序的输出**：`ghostty.exe` 没有控制台，`+version`、`+list-fonts`、`+show-config` 等只在标准输出被重定向或接管道时可见；PowerShell 里要 `| Out-String`，赋值给变量或 `>` 会遇到 `PIPE_CLOSING`。
- **崩溃退出码**：Git Bash 与 `zig build run` 会把 Windows 进程的 NTSTATUS 截成 8 位。要看原生程序的真实崩溃码，在 pwsh 里直接运行程序并读 `$LASTEXITCODE`（上游 Windows job 的做法）；`scripts/zig_test.py` 记 crash 时打印完整的 32 位退出码（如 `0xC0000005`）。
- **graphify**：Windows 智能应用控制会拦截 venv 里生成的未签名 `graphify.exe`（WinError 4551），`scripts/graphify.py` 因此一律用 `python -m graphify`。
- valgrind 与 AFL++ 只在 Linux、macOS 上可用；Nix VM 测试需要 Nix。

**WSL**：装有 WSL2 时，`just wsl` 在 WSL 克隆里补跑完整单测、GTK 构建与 Xvfb 截图（分层表「WSL 本机 Linux」）。2026-10-09 在 32 逻辑核的 WSL Ubuntu 24.04 上实测：`just wsl setup` 从零（克隆、钉版 Zig、blueprint-compiler、39 个 Zig 包）85 s，已就绪时约 1 s；GTK Debug 冷构建 69 s；主套件 3939 条（3897 通过、42 跳过）冷编译时墙钟 267 s（构建 225 s），热缓存 43 s；`just wsl test --gtk` 带上 GTK apprt 共 3971 条（3929 通过、42 跳过），冷编译时墙钟 306 s（构建 231 s）；lib-vt 6712 条（6642 通过、70 跳过）热缓存 84 s；`smoke` 约 25 s（含默认 20 s 等待）。这些数字测于 `src/gx/`、win32 apprt 与 GTK 的 GX 层合入之前，现在的用例数更多。WSL 的限制：Xvfb 里没有窗口管理器与合成器，截图只证明 X11 下的软件渲染；WSLg 窗口内容截不到；Zig 自己的下载走不了 HTTP 代理（`gx_wsl.py` 用 curl 预取绕开）。WSL 结果是本机 Linux 证据，不代证 `gx-ci` 的 `linux-main` 与 `gtk-smoke`，GUI 可见变更的 PASS 判据不变。

**GX Shell deb stage**：同日在该 WSL 里用 podman 起全新 `ubuntu:24.04` 容器（Zig 包事先放进容器的 Zig 全局缓存，因为 Zig 自己的下载走不了 HTTP 代理），照 `scripts/gx_package.py` 文档的 deb 命令实测：从检出构建（`--install-deps` 装 281 个包，下载钉版 Zig 与 blueprint-compiler，ReleaseFast 构建，生成并校验 stage）共 525 s，从 `zig build dist` 的源码包构建 517 s，两者 `verify-stage` 均通过、检出保持干净。测试包在另一个全新容器里补装 138 个依赖包后 `ghostty-gx +version` 正确，Xvfb 截图正常；只是以 `--no-install-recommends` 安装时缺 `libgtk-4-1` 推荐的 `librsvg2-common`，标题栏的 SVG 图标画成占位，所以 `linux-gtk-noble` 截图前装上它。另一个坑：同一本地缓存里换提交后再跑 `zig build dist`，`git archive HEAD` 那一步命中缓存，产出的仍是旧提交的源码包；`gx_linux_build.py` 核对源码包的提交号，会拒绝这种包。

**GitHub 上的上游 workflow**：`main` 只镜像上游，带着上游原样的 `.github/workflows/`，push `main` 会在 fork 上触发它们。例如 2026-10-09 run 37895496344（上游 `Test`，push `main`）在 namespace runner 上排队 7 小时以上，同一次 push 的 `Nix` 被跳过。这些不是 fork 的 CI，结论不采信，也不影响 `gx_ghostty`。

## 故障注入预期

关键门必须被证明「会失败」。注入只在临时副本或临时输入上做：框架单测用临时目录；需要完整仓库时在 `.local/tmp/` 下建临时 clone。不要修改跟踪中的文件再事后还原。

| 注入 | 应失败的门 | 预期 |
|---|---|---|
| 新增一个没有路由覆盖的文件 | `just rules-check` | 退出 2，列出未覆盖文件 |
| 新增一份嵌套 `AGENTS.md` | `just rules-check` | 退出 2，指出实际集合与 `nested_agents` 不一致 |
| 改动 KB 语料（文档、公开签名、文档注释）但不重建 | `just kb-check` | 退出 1，列出变化来源；只改函数体时仍为 0 |
| 改 `.po` 但不重建 GX 译表 | `just i18n-check` | 退出 1 |
| 改动被索引源码但不重建图谱 | `just graph-check` | 退出 2；改动被 `.graphifyignore` 排除的文件时仍为 0 |
| `CHANGELOG.md` 标题格式错误或版本重复 | `just version-check` | 退出 1 |
| 在 `.github/workflows/` 放回一个上游 workflow | `scripts/test_gx_workflows.py`（`just framework-test` 内） | 失败 |
| 删掉 fork 补丁标记 | `scripts/test_fork_patches.py`（`just framework-test` 内） | 失败 |
| 不合规的提交信息 | `python scripts/conventional_commits.py "<标题>"`、`just commit-check --message-file <文件>`、commit-msg hook | 退出 1，hook 拒绝提交 |
| KB 乱码查询 | `scripts/test_agent_kb.py` 的检索回归（`just framework-test` 内） | 返回空结果；正常的中英文查询命中预期文档 |
| 危险命令，如 force push | hook 探针 `scripts/test_ai_tool_hooks.py` | 真执行被拒；只是文本提及（如出现在提交信息里）则放行 |
| 找不到 Zig | 经 `scripts/zigw.py` 的配方，如 `just test-vt` | 退出 2，提示运行 `just setup` |
| `--filter` 写了不存在的子串 | `just test-vt --filter <不存在的子串>` | 退出 2，报「运行期 --filter … 没有匹配任何用例」，不会一条都没跑也报绿 |
| `-Dtest-filter` 写了不存在的子串 | `just test-vt -Dtest-filter=<不存在的子串>`（会重编两个测试二进制） | 退出 2，报「构建期 -Dtest-filter=… 裁掉了全部用例」；之后 `--no-build` 再跑这批被裁空的二进制，报「测试二进制本身没有用例」 |
| 测试二进制报告失败、泄漏、error 日志、崩溃或挂起 | `scripts/test_zig_test.py` 的伪测试二进制（`just framework-test` 内） | 分别记 fail、leak、log_err、crash、timeout，运行器退出 1 |
| 框架单测失败、超时，或子进程跑的测试数与发现阶段不符 | `scripts/test_run_unittests.py` 的临时夹具（`just framework-test` 内） | `run_unittests.py` 退出 1；PATTERN 未命中时退出 2 |
| 钉版下载或包内文件的 sha256 不符、资产缺件或多件 | `scripts/test_gx_package.py`、`scripts/test_gx_release.py` 的夹具（`just framework-test` 内）；真实运行时 `just package-windows` 与 `scripts/gx_release.py verify` | 打包退出 1 且丢弃不符的下载；verify 退出 1 并列出缺少与多余的资产 |

## 证据规则

| 结论 | 条件 |
|---|---|
| PASS | 命令在声明的环境里实际跑完、退出码为 0，并能给出命令、提交、环境与输出位置；截图类验收还必须实际读过图 |
| FAIL | 实际跑了，但退出码非 0 或断言失败。保留输出，修复后复测，不覆盖失败记录 |
| PENDING | 需要验证但当前环境跑不了，例如本机没有 GTK 或 macOS 桌面、提交还没 push、CI 尚未首跑、客户端未安装。必须写明原因与补验命令 |
| N/A | 该能力本项目不存在，例如项目没有内置 AI，RuleManifest 记 N/A。必须写明理由，不能拿来掩盖缺环境 |

- 以退出码判定，不凭输出「看起来成功」。验收命令不接会吞退出码的管道：不写 `just test-vt | tail`、`| head`。需要留存输出时重定向到文件，再检查退出码：
  - Git Bash：`just test-vt > .local/test-vt.log 2>&1; echo $?`
  - PowerShell：每条原生命令后立即检查 `$LASTEXITCODE`，别让后一条的成功覆盖前一条的失败
  - cmd：`echo %ERRORLEVEL%`
- 定向测试要报告 filter 字符串、seed 和实际运行的用例数（运行器计数表的 `total` 列）。运行器零命中时退出 2，报错写明是运行期 `--filter` 没命中还是构建期 `-Dtest-filter` 裁掉了全部用例；走上游 `zig build` 路径时，filter 拼错可能一个测试都没跑也照样退出 0，所以要加 `--summary all` 核对，例如 `just zig build test-lib-vt -Dtest-filter=<名> --summary all`。
- 运行器的结论还要写明非默认参数：`--dedupe`、`--serial-filter`、`--jobs`、`--timeout`。需要留存结果时可加 `--json <文件>`（schema 见 `scripts/zig_test.py::build_report`）。
- 截图类结论写明截图的来源（本机桌面、WSL 的 Xvfb、CI artifact 名与 run）、读图结论与对应的日志行；Windows GUI 的具体要求见上文「Windows GUI 验证」。
- 一层通过不证明另一层：test-vt 通过不等于完整单测通过；Windows 的 `just test` 通过不等于 Linux 的 `linux-main` 通过；交叉编译通过不等于该目标上能运行；WSL 截图不等于 `gtk-smoke` 截图；artifact 存在不等于截图验收通过。
- 必要工具缺失时，不得整族跳过后报绿，记 PENDING。
- CI 结论要引用具体运行：workflow、run、job 与提交 SHA。本地 `actionlint` 只证明 workflow 语法，不证明 job 能通过。
