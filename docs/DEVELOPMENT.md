# 开发流程（gx_ghostty）

本文是 fork 的开发闭环与上游同步手册。命令细节见 [MAKE_COMMANDS.md](MAKE_COMMANDS.md)，测试分层与证据规则见 [TESTING.md](TESTING.md)，发版见 [RELEASE.md](RELEASE.md)，代码结构见 [ARCHITECTURE.md](ARCHITECTURE.md)。上游自己的构建、lint 与手测说明在 [HACKING.md](../HACKING.md)，本文只写 fork 增加或改变的部分。

## 首次准备

以下前置需要人工准备。框架不代装系统级工具，hook 也会拒绝 winget、choco、scoop、msiexec。

- Git、`just`、Python ≥ 3.10（框架脚本只用标准库；3.10 需已装 `tomli`）。
- Windows：Visual Studio 2022 Build Tools（MSVC）与 Windows SDK——libghostty-vt 的本机构建与测试（`just test-vt`、`just build-vt`）用默认的 MSVC 目标；Windows app 与完整单测（`just build`、`just test`）按 `x86_64-windows-gnu` 构建，用 Zig 自带的 MinGW 头文件，不依赖 MSVC。另需在「设置 → 系统 → 开发者选项」开启开发者模式，允许非管理员创建符号链接，否则 `src/lib/tinyio` 的两个符号链接用例以 `PermissionDenied` 失败（`just test-vt` 里 4 处，`just test` 里 2 处）。
- 可选：WSL2 与 `Ubuntu-24.04` 发行版，用于 Linux GTK 的构建、测试与截图（下文「WSL：Linux GTK」）。
- 网络：`just setup` 要下载 Zig 与 graphify；首次 `zig build` 还会拉取 `build.zig.zon` 声明的依赖；`just package-windows` 首次要下载钉版的 ConPTY、Mesa 与字体。
- 内存：`just test-vt` 并行编译两个 lib-vt 测试二进制时，每个 LLVM 编译进程约占 6 GB。

然后在仓库根依次运行：

```sh
just setup               # 钉版 Zig 0.16.0 与图谱 venv 装进仓内 .local/，幂等
just setup --innosetup   # 可选，仅 Windows：另装钉版 Inno Setup 7.1.0，just package-windows 打安装包要用
just doctor              # 只读体检，必需项缺失时退出 1
just install-hooks       # core.hooksPath=.githooks，启用 commit-msg 提交规范检查
```

- `just setup`（`scripts/setup_env.py`）分两步，各自幂等。第一步把 Zig 按 sha256 钉版下载到 `.local/toolchains/zig/zig-0.16.0/`：`GX_GHOSTTY_ZIG_MIRROR` 指定的源最先尝试，然后是内置镜像，最后是官方源，源太慢或校验不符就换下一个；`GX_GHOSTTY_ZIG` 或 `ZIG` 已经指向可用的 0.16.0 时跳过下载。第二步建 `.local/tools/venv` 并装 `graphifyy==0.9.73`，有 `uv` 用 uv，否则用 venv + pip，解释器取 `find_real_python` 找到的真实路径。任一步失败退出 1。参数原样交给脚本：`--force` 覆盖重装损坏的钉版 Zig；`--innosetup` 另加第三步，把 sha256 钉版的 Inno Setup 7.1.0 安装包缓存到 `.local/cache/innosetup/`，以 `/CURRENTUSER /PORTABLE=1` 静默装进 `.local/tools/innosetup/`（不写注册表、不建卸载项与快捷方式），非 Windows 主机上这一步失败。
- `just doctor`（`setup_env.py --check`）：不安装，不在仓库里建任何东西（符号链接探测只用系统临时目录并随即删除）。必需项是 zig、python、git、MSVC（仅 Windows）、venv、graphify，任一为 MISSING 就退出 1；hooksPath、Windows 上的符号链接权限（`symlink`）与钉版 Inno Setup（`innosetup`），以及 codex、claude、kimi、zcode、actionlint、uv 只报 FOUND 或 OPTIONAL。每项都给出修复提示。
- `just install-hooks`：只改本仓 `.git/config` 的 `core.hooksPath`。不装也能开发，但 `gx-ci` 的 `framework` job 按同一规则校验首父链提交，不合规的提交 push 后一样会红。

装好后用 `just framework-check` 确认框架本身是绿的，再用 `just ci-check` 确认 Zig 链路可用。首次 `just ci-check` 要拉依赖并编译测试二进制，远比日常慢；之后热缓存下约 100 s，改过 Zig 源码再加约 2 min 编译（见 TESTING.md「并行运行器与耗时」）。

## 日常闭环（九步）

每个任务都走完九步。某步不适用时，在交付说明里写明理由，不要默默跳过。

### 1. 验收点

动手前写下「做完长什么样」：可观察的行为、要跑的命令、要过的测试，GUI 可见的改动还要写明截图要证明什么。同时判断每个验收点能在哪里证明：

- Windows 本机：框架单测、`just fmt-check`、libghostty-vt 的测试与构建、`just build` 出的 win32 app、完整单测 `just test`（按 win32 apprt 与 `x86_64-windows-gnu` 编译），以及用桌面自动化截图验证的 Windows GUI。
- WSL（`just wsl`）：GTK app 的构建、带 GTK apprt 的单测、Xvfb 截图，以及只在 Linux 上编译的代码（GTK apprt、`/proc` 分支）。
- `gx-ci` 与 `gx-release`：Linux 完整单测（`-Dapp-runtime=none`）、交叉构建、Windows app 构建、GTK 与 Windows 截图冒烟、macOS（见 TESTING.md）。

给不出可验证验收点的任务，先和人对齐。

### 2. 加载规则

```sh
just rules <本轮会读、改、审的路径…>
```

resolver 先列出命中的领域文档 `docs/AGENT_RULES/<id>.md`，再列出按路径祖先目录匹配的上游嵌套 `AGENTS.md`，两类都必读，读完再动手。目录会展开为其中的 Git 可见文件，多路径取并集；scope 扩大后用完整集合重跑。按任务类型追加文档用 `--task`（`release`、`sync`、`test`、`review`），例如 `just rules --task sync`。路径未登记路由或任务未知时退出 2：先在 `routes.toml` 登记（方法见 `docs/AGENT_RULES/README.md`），不要绕过。

### 3. 实现与文档

- 先读代码再改。状态所有者、线程与锁协议见 ARCHITECTURE.md 和对应领域文档。
- 代码、标识符与代码注释用英文，fork 文档用中文。
- fork 代码放在上游没有的路径：Windows 界面在 `src/apprt/win32/`，两个 apprt 共用的逻辑在 `src/gx/`，GTK 的 GX 部分在 `src/apprt/gtk/gx/`。必须改上游已有的源码文件时，加 `fork(gx): GX-NNNN` 标记并登记到 `docs/FORK_PATCHES.md`，`scripts/test_fork_patches.py` 会锁定登记闭集。
- GX 界面文字写英文 msgid、经 `gx.i18n` 翻译；新的中文译文写进 `src/gx/i18n/gx.zh_CN.po`，再 `just i18n` 重建 `src/gx/i18n/zh_CN.zig`。上游 GTK 字符串仍按上游的 gettext 流程。
- 改了某份文档描述的行为，就同步那份文档：领域文档、本目录文档、根 `AGENTS.md` 的 fork 段。上游原文（根 `AGENTS.md` 标记以上、嵌套 `AGENTS.md`、`.agents/**`）不改。
- 用户可观察的 fork 变化写进根 `CHANGELOG.md` 当前的 `## X.Y.Z(TBD)` 段。

### 4. 针对性检查

先跑与改动相称的最小集合，红了先修，再扩大范围：

| 改动 | 命令 |
|---|---|
| libghostty-vt（根模块 `src/lib_vt.zig`、`src/terminal/c/**`、`include/ghostty/**`） | `just test-vt --filter <名>` |
| 其他 Zig 核心代码与 `src/gx/` | `just test --filter <名>`（Windows 上运行器按 win32 apprt、`x86_64-windows-gnu` 构建）；只在 Linux 上编译的分支（`/proc`、`tcgetpgrp`）再跑 `just wsl test --filter <名>`；改动也编进 libghostty-vt 时（如 `src/terminal/`）先跑 `just test-vt` |
| win32 apprt（`src/apprt/win32/**`）与 Windows 专有代码 | `just build`、`just test --filter apprt.win32`，GUI 可见的改动按 TESTING.md「Windows GUI 验证」截图 |
| GTK apprt 与 GTK 的 GX 层 | `just wsl sync <worktree> --dirty`、`just wsl build --gtk`、`just wsl test --gtk --filter apprt.gtk`，GUI 可见的改动再 `just wsl smoke` 截图 |
| GX 译文（`src/gx/i18n/gx.zh_CN.po`、`po/zh_CN.po`） | `just i18n` 后 `just i18n-check` |
| 打包与发布脚本 | `python scripts/run_unittests.py test_gx_package test_gx_release test_gx_linux_build`，Windows 包再实跑 `just package-windows` |
| 任意 `.zig` 文件 | `just fmt-check`，需要改格式时 `just fmt` |
| 框架脚本、hook、workflow | `python scripts/run_unittests.py test_<名>`（Linux 用 `python3`；看单个方法用 `python -m unittest scripts.test_<名>.<类>.<方法> -v`），再 `just framework-test` |
| 路由、领域文档、根 `AGENTS.md` | `just rules-check` |

`--filter` 按用例全名做子串匹配，在运行期筛选、不重新编译，可重复给出取并集；一条都没命中时退出 2。`-Dtest-filter` 仍会透传给 zig build，但它在编译期裁剪用例，每换一个值就重编一次测试二进制，定向时优先 `--filter`；它裁掉全部用例时运行器同样退出 2，报错会写明是哪一种。值里含空格时，经 `just` 要写内嵌引号，或改为直接调用脚本，见 MAKE_COMMANDS.md「约定」。

### 5. 适用集成与 CI

按改动面挑选；不适用的写明原因。

- 本机聚合门：`just ci-check`（framework-check → fmt-check → test-vt），提交前必跑；热缓存约 100 s。改了 lib-vt 以外的 Zig 代码，再跑完整单测 `just test`（它只跑 `ghostty-test`，macOS app 的单测另用 `macos/build.nu --action test`）。
- Windows app：`just build` 后按 TESTING.md「Windows GUI 验证」操作并截图；打包相关改动跑 `just package-windows`（需 `just setup --innosetup`，只要 zip 时加 `--skip-installer`）。
- GTK：`just wsl build --gtk` 与 `just wsl smoke --out <目录>`，截图读图后才算数。
- C API 或头文件：`just build-vt`；示例在各自目录里用钉版 Zig 构建，例如在 `example/c-vt-static` 下执行 `python ../../scripts/zigw.py build`（Linux/macOS 用 `python3`；`just` 的配方总在仓库根执行，进不了示例目录）；ABI 清单用 `just zig build test-lib-vt-schema`，前置见 TESTING.md。
- wasm：`just vt-wasm`，再用 `node test/wasm-alloc.mjs zig-out/bin/ghostty-vt.wasm` 做分配器冒烟。
- 其他目标：`just build-vt -Dtarget=<triple>`；源码包：`just dist-vt`。
- push 到 `gx_ghostty` 后 `gx-ci` 运行 Linux 完整测试、交叉矩阵、Windows 的 lib-vt 测试与 app 构建；GTK 截图冒烟（`gtk_smoke`）、Windows 截图冒烟（`win_smoke`）与 macOS 上的 lib-vt 测试只在手动触发 `gx-ci` 并打开对应输入时运行；发布资产（含 Windows 便携包与安装包、Ubuntu 24.04 的 `linux-gtk-noble` 验证）只在手动运行 `gx-release` 时构建。push 与手动触发由用户执行（fork 上要先启用 Actions，见 RELEASE.md「首次启用」），结果出来之前这些项记 PENDING；截图类证据要下载 artifact 并实际读图后才能记 PASS。

### 6. 修复复测

失败时先看完整输出，判断是代码问题、环境问题还是前置缺失。`just test-vt` / `just test` 失败时，结论行之后会打印一条可直接复制执行的完整复现命令，形如 `python scripts/zig_test.py <本次的 --suite/--binary、-D、--zig-arg、--no-build、非默认的 --timeout> --seed 0x… --filter <引好的用例全名>`，先原样执行它定向重跑；用例名含空格，所以它绕过 just 直接调用脚本，不能把这些参数接在 `just test-vt` 后面。怀疑是分片或执行顺序引起的，再用上游串行路径 `just zig build test-lib-vt` 对照。修复后用同一条命令复测，必要时再扩大一层。失败输出要保留，不能用后一次成功覆盖前一次失败的记录。缺环境不等于通过：没能运行的检查补齐前置后补跑，否则记 PENDING 并写补验命令；命令已实际运行、因前置缺失而失败的（如未开开发者模式时的 tinyio 符号链接用例）记 FAIL 并注明原因。

### 7. 生成物与版本

- KB：改了语料就 `just kb`，审 diff 后随改动一起提交。只改函数体不会让 KB 过期，改公开签名、文档注释或文档才会；语料范围见下文「生成物重建时机」。产物是 schema 2 的紧凑 JSON：首行文件头，每个文档一行 `[path, source_sha256, [`（逐文档的来源哈希），其后每片一行 `[anchor, text]`，所以 diff 里变化的行就是变化的小节；chunk id 不入库，`kb-query --json` 的 `id` 由 `path#anchor` 推导。Markdown 正文原样收录；代码层为控制体积做了裁剪：Zig 结构省略 `pub` 前缀，模块文档丢掉分隔线与字形表、超过 3000 字符截断，`///` 与头文件注释只留首句及 120 字符内的后续整句。体积预算 2.5 MiB 由 `scripts/test_agent_kb.py` 锁定，逼近时收紧代码层裁剪、用 `just kb-query` 对照代表查询的前后结果，不放宽预算，也不删 Markdown 语料。
- GX 译表：改了两份 `.po` 就 `just i18n`，`src/gx/i18n/zh_CN.zig` 随改动提交。
- 图谱：日常不强制重建；发版前和上游同步后必须 `just graph`，再跑 `just generated-check`。
- 版本：CHANGELOG 标题格式用 `just version-check` 校验；CHANGELOG 前 6000 字符也是 KB 语料，改完同样要 `just kb`。产品版本仍以 `build.zig.zon` 为真源，不做同步。
- 上游生成物只用各自的生成器更新，不手改。

### 8. 复审

```sh
just rules-review <本轮全部路径…>
```

`rules-review` 等于在 resolver 上追加 `--task review`。按输出里的 `code-review` 规程做只读复审，结论按 严重 / 中 / 轻 / 结论 四级给出。可以交给只读评审员 `.claude/agents/code-reviewer.md` 或 `.codex/agents/gx-ghostty-reviewer.toml`；上游的 `.agents/commands/review-branch`（Nushell 脚本，需要 `nu`）也可用，结论同样按 `code-review` 的格式输出。复审发现的问题回到第 3 至 7 步处理。

### 9. 交付

先按根 `AGENTS.md`「完成门」自检，再写交付说明：

- 改动清单与各自的真源；
- 实际跑过的命令及退出码，逐项标 PASS / FAIL / PENDING / N/A（判定见 TESTING.md「证据规则」）；
- PENDING 项的原因与补验命令，例如「push 后看 `gx-ci` 的 `linux-main` job」；
- 建议的提交信息与拆分方式。

只精确暂存本轮相关文件。提交前先提出 commit message 与用户对齐；没有明确要求不 commit、不 push。

## Windows 开发

### 构建与运行

- `just build` 在 Windows 主机上给 `zig build` 补 `-Dtarget=x86_64-windows-gnu`（`scripts/zig_build.py`；显式写了 `-Dtarget` 或是 `-Demit-lib-vt` 构建时不补），Windows 目标的 apprt 默认就是 `win32`（GX-0003），产出 Debug 的 `zig-out\bin\ghostty.exe` 与 `zig-out\share\`。要看性能时加 `-Doptimize=ReleaseFast`。不经 `just` 直接 `zig build` 时目标没写 ABI，`src/build/Config.zig::init` 会强制 MSVC，这条路径未验证。
- 运行：直接启动 `zig-out\bin\ghostty.exe`。它是 GUI 子系统程序，没有控制台；`+list-fonts` 等 CLI 动作的输出只在标准输出被重定向或接管道时可见（cmd 的 `>`、`|`，Git Bash 均可；PowerShell 要 `| Out-String`）。
- 日志：每次运行写 `%LOCALAPPDATA%\ghostty\logs\ghostty.log`，上一次的改名为 `ghostty.log.1`（`src/apprt/win32/file_log.zig`）；Debug 构建写全部级别，其他构建不写 debug。常用的核对行：`runtime=.win32`、`loaded OpenGL X.Y vendor=… renderer=… software=…`、`ConPTY: bundled …` 或 `ConPTY: system (kernel32) …`。
- 隔离配置做实验：Windows 上的配置目录是 `%XDG_CONFIG_HOME%\ghostty`，未设时 `%LOCALAPPDATA%\ghostty`（`src/os/xdg.zig::config`），用户配置、`gui-settings.ghostty` 与写入的 `GX Mocha` 主题都在这里；日志目录只看 `LOCALAPPDATA`。实验与截图验证时把两个变量都指向同一个隔离目录（约定 `.local\evidence\<任务>\env\<场景>`，与 TESTING.md「Windows GUI 验证」一致），配置写在其下的 `ghostty\config.ghostty`，日志落在 `ghostty\logs\ghostty.log`，例如 PowerShell：

  ```powershell
  $dir = "$PWD\.local\evidence\demo\env\default"
  New-Item -ItemType Directory -Force -Path "$dir\ghostty" | Out-Null
  $env:LOCALAPPDATA = $dir
  $env:XDG_CONFIG_HOME = $dir
  Remove-Item Env:NO_COLOR -ErrorAction SilentlyContinue   # agent 的 shell 常带它，pwsh 会因此不输出颜色
  .\zig-out\bin\ghostty.exe
  ```

  2026-10-09 用 `ghostty.exe +show-config` 实测确认它读的是 `%XDG_CONFIG_HOME%\ghostty\config.ghostty`。隔离后，只装在真实 `%LOCALAPPDATA%\Programs\GXShell\bin` 等处、不在 `PATH` 上的 GX Zsh 与 herdr 探测不到，默认 shell 退到 PowerShell，需要时在配置里写 `command`；终端里的 shell 也会继承这两个变量。只想跳过 GX 默认值、对照上游行为时设 `GHOSTTY_GX_DEFAULTS=0`。
- 随包 ConPTY 与 Mesa 的本地副本：`just build` 不复制这些文件，开发构建因此用系统 ConPTY 与系统 OpenGL 驱动。要试随包 ConPTY，把 `conpty.dll` 与 `OpenConsole.exe` 放到 `ghostty.exe` 旁边；要试软件渲染，把 `opengl32.dll`、`libgallium_wgl.dll` 放进 `zig-out\bin\mesa\` 并设 `GHOSTTY_GX_OPENGL=software`（包里另有的 `dxil.dll` 只给 Mesa 的 D3D12 驱动用，llvmpipe 不需要）。最省事的来源是 `just package-windows` 打出的便携 zip（`zig-out\dist\`），里面这些文件都按 `scripts/gx_windows_package.py::PAYLOAD` 的 sha256 校验过。`GHOSTTY_GX_CONPTY=system` 强制回到系统 ConPTY。注意 `just package-windows` 会把 ReleaseFast 构建装进 `zig-out\`，覆盖之前的 Debug 构建。
- 打包：`just package-windows` 构建 ReleaseFast 并在 `zig-out\dist\` 产出便携 zip 与安装包（安装包要先 `just setup --innosetup`，只要 zip 用 `--skip-installer`）。版本串取自本检出（`scripts/gx_release.py::ReleaseInfo.version_string`），钉版下载缓存在 `.local\cache\gx-package\`。

### 环境与工具

- **MSVC**：Windows 目标未指定 ABI 时默认用 MSVC ABI（`src/build/Config.zig::init`，避免 MSVC 链接器拒收 GNU ABI 目标文件），所以 `just test-vt`、`just build-vt` 需要 MSVC 与 Windows SDK，`just doctor` 会报告二者是否可用；`just build`、`just test` 用 GNU ABI，不需要它们。`gx-ci` 的 `windows` job 跑 lib-vt 的 MSVC 路径，`windows-app` job 构建 GNU ABI 的 app。
- **界面语言**：Windows 构建关闭 gettext i18n（`zig build update-translations` 在 Windows 上报错），win32 界面的文字全部走 `gx.i18n`，改译文用 `just i18n`。
- **编译耗时**：改过 Zig 源码后，`just test-vt` 要用 LLVM 重新编译 `ghostty-vt`、`ghostty-vt-c` 两个 Debug 测试二进制，两次编译并行，约 2 min；`just test` 另编 `ghostty-test`（2026-10-09 本机冷构建 `test-bin` 用了 3 min 52 s）。这段时间省不掉：Zig 自托管后端在 Windows 上编出的测试二进制无法运行。运行器给测试构建钉住版本串（`X.Y.Z-dev+0000000`），换提交不会让缓存失效；源码没变时构建步骤几秒内完成。
- **python 别名**：`justfile` 在 Windows 上调用 `python`，其他平台调用 `python3`。`%LOCALAPPDATA%\Microsoft\WindowsApps` 下的 `python.exe`、`python3.exe` 是应用执行别名：可能转到 Python 安装管理器（找不到匹配运行时会把 Python 装进当前目录，`.gitignore` 的 fork 段因此忽略 `/Python/`），也可能只是 Microsoft Store 占位程序。`scripts/setup_env.py::find_real_python` 建 venv 时跳过这类别名，`just doctor` 显示实际解析到的解释器；`.githooks/commit-msg` 也只用能实际运行的 `python3` 或 `python`。`zig build test-lib-vt-schema` 由 `build.zig` 直接调用 `python3`，这个名字同样必须能运行。
- **本机状态都在 `.local/`**：钉版 Zig、Zig 全局缓存（未设置 `ZIG_GLOBAL_CACHE_DIR` 时 `scripts/zigw.py` 指向 `.local/zig-cache/global`）、图谱 venv、钉版 Inno Setup、打包下载缓存（`.local/cache/`）与两个测试运行器的耗时缓存（`.local/test-timings/`，只影响调度顺序）都在仓内 `.local/`，由 `.gitignore` 的 fork 段忽略，不写用户全局目录。构建输出与依赖工作副本仍在上游默认的 `zig-out/`、`.zig-cache/`、`zig-pkg/`，已被上游 `.gitignore` 忽略。agent 的文件编辑工具被 hook 禁止写 `.local/`；删除 `.local/` 后要重新 `just setup`，Zig 依赖与打包下载也会重新下载。
- **换行**：本机 `core.autocrlf=true`。上游 `.gitattributes` 已把 `.zig`、`.md`、`.py`、`.toml`、`.yml` 等固定为 LF，但 `justfile`、`.graphifyignore`、`.conf` 与无扩展名的 hook 不在其中，检出后可能是 CRLF。框架脚本一律用 `splitlines()` 解析，容忍 CRLF；`.githooks/.gitattributes` 把 hook 固定为 LF。打包脚本会把 fork 主题转成 LF 再放进包里。提交前跑 `git diff --check`。
- **shell**：`just` 在 Windows 上用 `cmd.exe` 执行配方（`justfile` 的 `set windows-shell`），所以从 cmd、PowerShell、Git Bash 调用效果相同。配方都是单行 Python 调用，不依赖 POSIX shell。参数是不加引号拼进命令行的：含 `& | < > ^ %` 的自由文本（以及单条提交标题）会被 cmd 解释，这时直接调用脚本，如 `python scripts/conventional_commits.py "<标题>"`、`python scripts/agent_kb.py "<查询>"`。

## WSL：Linux GTK

Windows 主机上的 Linux 构建、测试与截图都经 `just wsl`（`scripts/gx_wsl.py`）在 WSL 里的克隆中执行，默认发行版 `Ubuntu-24.04`、克隆 `~/src/gx_ghostty`（`--distro`/`--clone` 或 `GX_WSL_DISTRO`/`GX_WSL_CLONE` 可改）。参数与退出码见 MAKE_COMMANDS.md「WSL」。

```sh
just wsl setup --apt                     # 首次：先以 root 补装 apt 依赖与 zh_CN.UTF-8、en_US.UTF-8 locale，再做下一行的事
just wsl setup                           # 幂等：克隆、钉版 Zig、钉版 blueprint-compiler 0.16.0、预取 Zig 包；已就绪时约 1 s
just wsl sync <worktree 目录> --dirty     # 把某个 worktree（连未提交改动）detached 检出到克隆
just wsl build --gtk                     # GTK app（-fno-sys=gtk4-layer-shell）
just wsl test                            # 完整单测，同 gx-ci linux-main 加 -Dapp-runtime=none；--gtk 带上 GTK apprt
just wsl smoke --out <Windows 目录>       # 与 gx-ci gtk-smoke 相同的 Xvfb 参数截图，复制回 Windows
```

- 一个克隆同一时间只给一个任务用；并行任务各用 `--clone '~/src/gx_ghostty-<id>'`（Git Bash 下给以 `~` 或 `/` 开头的路径加引号），`setup` 会负责克隆。`sync` 在克隆有本地改动或会孤立本地提交时拒绝（退出 3）。
- 代理：Zig 自带的 HTTP 客户端经 HTTP 代理访问 HTTPS 会失败（`HttpConnectionClosing`），而 WSL 往往只能经代理出网，所以 `setup`、`build`、`test` 先按 `build.zig.zon.json` 与各级 `build.zig.zon` 用 curl 下载缺失的包，再 `zig fetch <文件>` 登记并核对 hash。在 WSL 里起的 podman 容器同样受影响，要先把 Zig 包放进容器的 Zig 全局缓存。
- 截图：`smoke` 跑在 Xvfb 下（1280x800、X11 后端、软件 OpenGL，没有合成器），截图要实际读图。`just wsl run` 在 WSLg 桌面上打开窗口，但本机截不到 WSLg 窗口的内容，只能确认窗口出现，不能当截图证据。
- 配置隔离：`smoke`、`run` 给 Ghostty 一个私有的 `XDG_CONFIG_HOME`（`--config` 文件或空文件），不读写 WSL 用户自己的 Ghostty 配置。
- WSL 的结果是本机 Linux 证据，不代证 `gx-ci` 的 `linux-main` 与 `gtk-smoke`，也不代证 debian:13 或真实 Wayland 桌面。

## 分支模型

| 分支或远端 | 角色 |
|---|---|
| `upstream` | `ghostty-org/ghostty`，只 fetch，永不推送 |
| `origin` | `gx0404/gx_ghostty`，即本 fork |
| `main` | 上游镜像：只快进到 `upstream/main`，不放任何 fork 提交 |
| `gx_ghostty` | 开发与发布分支（本地 `origin/HEAD` 指向 `origin/gx_ghostty`）：全部 fork 改动在这里，`gx-ci` 由它触发，`gx-release` 默认从它构建 |

- fork 提交只进 `gx_ghostty`。不 rebase 到上游，不 force push，不改写已推送的历史。
- fork 的 tag 只有 `gx-vX.Y.Z` 一种，由 `gx-release` 的 publish job 创建，不手工打 tag（见 RELEASE.md）。`v` 前缀是上游版本 tag 的格式：HEAD 上的 `v` tag 必须与 `build.zig.zon` 版本一致，否则构建会 panic；非 `v` 前缀的 tag 按补丁 GX-0001 与 `tip` 一样跳过发布校验，回退到分支预发布版本。
- `main` 带着上游原样的 `.github/workflows/`，push `main` 会在 fork 上触发上游 workflow（见 TESTING.md「CI 覆盖与本机对应」），它们的结果不是 fork 的证据。

## 上游同步

只在用户要求时执行。整个过程不 force push、不推送 `upstream`；push 由用户在全部检查通过后执行。开始前加载同步规则：`just rules --task sync`。

**0. 前置**：工作树干净（`git status --porcelain` 无输出）。记下两条分支当前的 SHA（`git rev-parse main gx_ghostty`），作为出问题时的回退点。

**1. 抓取与审阅**

```sh
git fetch upstream
git log --oneline main..upstream/main
```

逐条看本轮上游带来了什么，留意 workflow、`AGENTS.md`、`build.zig.zon` 依赖、新目录和嵌套 `AGENTS.md` 的变化，以及下文「补丁热点」里那些文件的改动。

**2. `main` 只快进**

```sh
git switch main
git merge --ff-only upstream/main
```

不能快进说明 `main` 上出现了非上游提交，先查清原因；不能用 `reset --hard` 或 force push 解决。

`main` 上是上游原样的 `.github/workflows/`，推送 `main` 会在 fork 上触发其中带 `push` 触发器的 workflow；它们依赖上游的 runner 与密钥，在 fork 上只会一直排队或跳过。上游的 `Test` 与 `Nix` 已在 fork 上禁用（`gh workflow disable Test --repo gx0404/gx_ghostty`，`Nix` 同理；`gh workflow list --all` 查看状态）。推送 `main` 后若出现新的上游 workflow 运行，取消它并同样禁用。

**3. 合入 `gx_ghostty`**

```sh
git switch gx_ghostty
git merge --no-ff main -m "chore(sync): 合并上游 main（<sha>）"
```

`<sha>` 取 `git rev-parse --short main`。合并提交必须使用这条合规信息：它在首父链上，会被提交规范检查；已装 hook 时 commit-msg 对 `git merge` 同样生效，Git 默认的 `Merge branch 'main' …` 会被拒绝。

有冲突时合并会停下。按第 4 步的规则逐块解决并 `git add` 后，用同一条信息完成合并：

```sh
git commit -m "chore(sync): 合并上游 main（<sha>）"
```

不要用 `git commit --no-edit`：带 `-m` 的合并冲突后，`.git/MERGE_MSG` 末尾的 `# Conflicts:` 注释会原样写进提交信息（本机 Git 2.56 实测）。

**4. 冲突处理规则**

- **根 `AGENTS.md`**：标记行 `<!-- gx-fork: … -->` 以上整段取上游新版本，标记及以下保留 fork 段。再核对上游新内容有没有让 fork 段里的命令或描述失效，需要时改 fork 段与对应领域文档。合并后超过 16 KiB 时压缩 fork 段，不删改上游原文。
- **`.gitignore`、`.prettierignore`**：上游行取上游版本；以 `# --- GX fork：` 开头的追加段原样保留在文件末尾。
- **workflow**：上游修改已归档的 workflow 时，Git 的重命名检测通常会把改动直接落到 `.github/workflows-archive/<name>.yml`，不产生冲突；上游删除已归档的 workflow 时出现 rename/delete 冲突，跟随上游删除归档副本（`git rm`）；上游新增的 workflow 会出现在 `.github/workflows/`，必须原样 `git mv` 进 `.github/workflows-archive/`。最终启用的只能是 `gx-ci.yml` 与 `gx-release.yml`，由 `scripts/test_gx_workflows.py` 锁定。以上 Git 行为已在临时仓库中用 Git 2.56 验证。归档文件有增删时，同步更新 `scripts/test_gx_workflows.py` 的 `ARCHIVED` 清单与 `.github/workflows-archive/README.md` 的用途表；`gx-*.yml` 的每个 action 都复用归档里已钉的 SHA 与版本注释，上游升级钉版后旧 SHA 若不再出现在归档里，同一测试会失败，这时把 `gx-*.yml` 里的 SHA 改成上游的新值。
- **fork 补丁**：按 `docs/FORK_PATCHES.md` 逐条核对补丁是否仍然需要、是否仍然成立，冲突按该补丁小节的「同步冲突处理」放回，标记与登记由 `scripts/test_fork_patches.py` 检查。热点见下表。
- **其余上游文件**：取上游版本。不用整文件 ours/theirs 糊过冲突，也不用 squash、cherry-pick 或 rebase 代替合并。

**补丁热点**：40 个上游文件带 GX 补丁，其中 `src/Surface.zig`（GX-0005、GX-0006、GX-0012、GX-0014）与 `src/apprt/gtk/class/application.zig`（GX-0011、GX-0015、GX-0016）各叠了多个补丁，最容易冲突。

| 补丁 | 上游文件 | 冲突时核对 |
|---|---|---|
| GX-0001 | `src/build/Config.zig` | `vsn.tag` 判断的形状由 `scripts/test_fork_patches.py` 锁定 |
| GX-0002 | `build.zig` | 三个纯新增块的位置与安装路径，路径与 `scripts/zig_test.py::SUITES` 对应 |
| GX-0003 | `src/apprt.zig`、`src/apprt/runtime.zig`、`src/build/SharedDeps.zig`、`src/main_ghostty.zig`、`src/config/Config.zig`，以及按 `app_runtime` 穷举的 GObject 分支（`src/apprt/{action,structs,surface}.zig`、`src/datastruct/split_tree.zig`、`src/font/face.zig`、`src/input/Binding.zig`、`src/terminal/mouse.zig`） | 上游新增按 `app_runtime` 穷举的 switch 要补 `.win32`（编译 win32 目标会报出）；上游合入 PR #14608 后 `posix_c` 守卫改取上游 |
| GX-0004 | `src/renderer/OpenGL.zig`、`src/renderer/opengl/Frame.zig` | 上游改 `init`/`threadEnter`/`present`、`Device` 接口或帧呈现协议时同步 `src/renderer/opengl/wgl.zig` |
| GX-0005 | `src/Surface.zig`、`src/termio/{Exec,Options,Termio,stream_handler}.zig` | 唤醒句柄按指针传递、Windows 读线程退出、退出管道的 Win32 句柄、命令行切分、URL 不按路径解析 |
| GX-0006 | `src/terminal/modes.zig`、`include/ghostty/vt/modes.h`、`src/terminal/snapshot/{terminal.zig,snapshot.ksy}`、`src/terminal/stream_terminal.zig`、`src/Surface.zig` | 上游在 `entries` 末尾加模式时 fork 条目顺延，快照位号、ksy 与单测一起改；`encodeKey` 开头的分流 |
| GX-0007 | `src/pty.zig` | `WindowsPty` 的创建、缩放、关闭走同一个 `gx_conpty.Instance` |
| GX-0008 | `src/termio/stream_handler.zig`、`src/os/hostname.zig` | `reportPwd` 在主机检查之后、`setPwd` 之前调 `gx_osc7.nativePath` |
| GX-0009 | `src/font/{discovery,DeferredFace,backend}.zig` | `Discover`、`DeferredFace.Windows` 的接口变化时同步 `src/font/directwrite/` |
| GX-0010 | `src/config/Config.zig` | `gx-*` 字段块留在字段区末尾；`Config.load`、`Replay`、`loadCliArgs` 改动后核对 `src/gx/config_layers.zig::loadWith` 的分层下标 |
| GX-0011、GX-0015、GX-0016 | `src/apprt/gtk/class/{application,window,tab,surface}.zig`、`src/apprt/gtk/App.zig`、`src/apprt/gtk/build/gresource.zig` | `Application.new`/`startupActionMap`/`propConfig`、`Window.getTabsVisible` 等钩子位置；上游改菜单时同步 `src/apprt/gtk/ui/1.5/gx/menus.blp` |
| GX-0012 | `src/Surface.zig`、`src/termio/Exec.zig` | `needsConfirmQuit` 的 `.true` 分支、`Subprocess.getProcessInfo` 的 Windows 分支 |
| GX-0014 | `src/input/Binding.zig`、`src/input/command.zig`、`src/Surface.zig` | `Binding.Action` 新增穷举 switch 时补 `.gx`；`src/apprt/gtk/class/command_palette.zig` 的过滤块已移除（登记为 `removed`），该文件取上游 |
| GX-0021 | `src/renderer/generic.zig` | 预编辑追赶循环的 `< len` 上界；上游自己修好后按移除条件删除 |
| GX-0022 | `src/terminal/Terminal.zig`、`src/termio/Exec.zig` | `flags.semantic_prompt_fresh_line` 紧跟 `resize_pull_scrollback` 且 `fullReset` 保留它；`semanticPromptFreshLine` 开头的早退；`Exec.initTerminal` 在 Windows 上关闭它与 `resize_pull_scrollback`；上游改 `PageList.resize` 的拉回语义时跑 `scrollback pull` 用例 |

合并后，`gx-ci` 的 `windows-app` 只构建 app、不跑单测，`linux-main` 只编译 `-Dapp-runtime=none`、不含 GTK apprt，所以 Windows 上的单测与 GTK apprt 的编译和单测要在本机补齐：Windows 上 `just build` 与 `just test`，WSL 里 `just wsl build --gtk` 与 `just wsl test --gtk`。

**5. 登记新路径、嵌套 AGENTS 与钉版 Zig**

- 上游新增或删除嵌套 `AGENTS.md` 时，`just rules-check` 会因实际集合与 `nested_agents` 不一致而失败。修法：更新 `docs/AGENT_RULES/routes.toml` 的 `nested_agents`，并在对应领域文档的「上游指令」段补链接；只链接，不复制、不改写上游正文。
- 上游新增的文件没有路由覆盖时，为合适的领域补 pattern，不用 `**` 兜底；上游删文件导致某个 pattern 零命中时，删除或修正该 pattern。
- 上游改了 `build.zig.zon` 的 `minimum_zig_version` 时，钉版 Zig 必须跟着升级（`build.zig` 经 `src/build/zig.zig::requireZig` 校验版本，钉版落后就无法构建）：
  1. 从官方 `https://ziglang.org/download/index.json` 取新版本各平台条目的 `shasum`，更新 `scripts/setup_zig.py` 的 `ZIG_VERSION` 与 `PINS`（五个平台都要更新）。
  2. `just setup` 装好新版本，再跑 `just framework-test`：`scripts/test_setup_zig.py` 锁定 `ZIG_VERSION` 等于 `minimum_zig_version`，测试里写死的旧版本号也会在这里暴露，一并改正。`gx-ci` 与 `gx-release` 的 `mlugg/setup-zig` 都按 `minimum_zig_version` 取版本（`gx-release` 的 prepare 另外校验它与 `ZIG_VERSION` 一致），workflow 不用改。
  3. 更新文档与注释里写死的 `0.16.0`：根 `AGENTS.md`「项目模型」、`justfile`、本目录与 `docs/AGENT_RULES/` 下的文档。
  4. 在 `CHANGELOG.md` 当前的 `(TBD)` 段记一条「钉版 Zig 升级到 X.Y.Z」，然后 `just kb`。

  `GX_GHOSTTY_ZIG`、`ZIG` 只用来指向已装好的同版本 Zig，不能拿来换版本、绕过钉版（zigw 也会拒绝与 `ZIG_VERSION` 不一致的 Zig）；正确做法是按上面的步骤升级钉版。

**6. 验证**

```sh
just framework-check
just ci-check
just test                 # Windows 上按 win32 apprt 编译并运行完整单测
just wsl test --gtk       # GTK apprt（需要 WSL）
```

framework-check 会捕获未覆盖的新路径、嵌套 AGENTS 变化、被重新启用的 workflow 与丢失的补丁标记；上游改了 `po/zh_CN.po` 时它里面的 `i18n-check` 失败，修法是 `just i18n`。

**7. 重建生成物**

```sh
just kb
just graph
just generated-check
```

上游改动几乎总会改变 KB 语料与被索引源码，所以同步后两类生成物都要重建，并且必须通过 `generated-check`。

**8. 收尾**

审完整 diff。合并提交只含合并本身与冲突解决；合并之后才做的适配与重建的生成物作为后续提交，例如 `ci(github): 归档上游新增 workflow`、`chore(ai): 登记上游新增路由`、`docs(kb): 同步上游后重建图谱报告与知识库`。用 `git merge-base --is-ancestor main gx_ghostty` 确认祖先关系。整串提交都通过上述检查后再交给用户 push，避免在中间状态把上游新 workflow 推上去被触发。

## 提交规范

格式 `type(scope): 中文描述`：

- `type` 是小写英文，取 `feat fix perf docs ci test refactor chore build revert style release` 之一；`scope` 可省略，建议写受影响的面（如 `build`、`win32`、`gtk`、`gx`、`ai`、`github`、`kb`、`sync`）；破坏性变更在冒号前加 `!`。不加 emoji，不加 AI co-author 行。
- 校验正则是 `^type(\(scope\))?!?: \S`，由 `scripts/conventional_commits.py` 实现：冒号是半角，后面恰好一个空格；scope 里不能有空格或括号；`fixup!`、`squash!`、`amend!` 提交不能进入历史。入口 `just commit-check --message-file <文件>` 或 `just commit-check --range <base>..<head>`；校验单条标题时直接调用 `python scripts/conventional_commits.py "<标题>"`（Linux 用 `python3`），因为标题含空格，经 just 传参会被拆开（见 MAKE_COMMANDS.md「约定」）。
- 例子：`fix(build): 非 v 前缀 tag 不再触发版本号 panic`、`chore(sync): 合并上游 main（<sha>）`、`chore(release): 定版 0.0.1`。

**只查首父链**：`--range` 内部用 `git log --first-parent`；`gx-ci` 的 `framework` job 同样只沿首父链校验，push 取 `before..after`（`before` 全零时只查 head），PR 取 `base..head`。上游提交经 `chore(sync)` 合并进来，不在 `gx_ghostty` 的首父链上，不受 fork 规范约束；合并提交本身在首父链上，所以必须带合规信息。

**优先于上游 skill**：上游的 `.agents/skills/writing-commit-messages`（`<subsystem>: <summary>` 格式）保持原样，只用于准备回馈上游的提交；在 `gx_ghostty` 上与本节冲突时以本节为准。该 skill 里「直接提交」的步骤也不构成提交授权。

**hook 与暂存**：`just install-hooks` 后，`.githooks/commit-msg` 对每次提交运行同一检查，包括 `git merge` 生成的合并提交；hook 安全门禁止 `--no-verify`。暂存时精确列出路径，不用 `git add -A`，也不用 `git add -f` 强加被忽略的文件。`.githooks/commit-msg` 首次入库必须用 `git add --chmod=+x .githooks/commit-msg`（本仓 `core.filemode=false`，否则以 100644 入库，POSIX 上的 git 会忽略这个 hook；`scripts/test_conventional_commits.py` 在它入库后检查模式为 100755）。

## 生成物重建时机

| 产物 | 何时重建 | 生成 | 校验 | 入库 |
|---|---|---|---|---|
| `docs/kb/chunks.json` | KB 语料变化：根与嵌套 `AGENTS.md`、`CLAUDE.md`、`README.md`、`HACKING.md`、`CONTRIBUTING.md`、`PACKAGING.md`、`AI_POLICY.md`、`CHANGELOG.md`、`docs/*.md`、`docs/AGENT_RULES/*.md`、`src/**/*.zig` 的 `//!` 模块文档与 `pub` 签名（含其 `///` 注释）、`include/ghostty/**/*.h` 的声明 | `just kb` | `just kb-check`，属于 framework-check 与 `gx-ci` 的 `framework` job | 是 |
| `graphify-out/GRAPH_REPORT.md`、`graphify-out/source-fingerprint.json` | 被索引源码增删改：Git 可见、未被 `.graphifyignore` 排除、扩展名在 `scripts/graphify_fingerprint.py::INDEXED_EXTENSIONS` 内的文件（如 `.zig .swift .c .h .cpp .m .py .sh`），实际主要是 `src/`、`pkg/`、`include/`、`macos/` 与 `build.zig`；或者管线输入 `scripts/graphify.py`、`scripts/graphify_fingerprint.py`、`.graphifyignore` 变化 | `just graph` | `just graph-check`，只在 `gx-release` 的 prepare 阶段与上游同步后强制 | 是 |
| `graphify-out/graph.json` | 同上，约 20 MB | `just graph` | 无 | 否，仅本机 |
| `src/gx/i18n/zh_CN.zig` | `po/zh_CN.po` 或 `src/gx/i18n/gx.zh_CN.po` 变化（上游同步改了 `po/zh_CN.po` 也算） | `just i18n` | `just i18n-check`，属于 framework-check 与 generated-check；`scripts/test_gx_i18n.py` 也校验，随框架单测进 `gx-ci` 的 `framework` job | 是 |
| `CHANGELOG.md` 版本标题 | fork 可观察变化、定版 | 手写 | `just version-check` | 是 |
| `build.zig.zon.json`、`build.zig.zon.nix`、`build.zig.zon.txt`、`flatpak/zig-packages.json` | `build.zig.zon` 依赖变化 | `nix/build-support/check-zig-cache.sh --update`（要 `nix develop` 提供的 zon2nix、alejandra、prettier） | 同一脚本不带参数 | 是，上游生成物 |
| `po/com.mitchellh.ghostty.pot` 与 `po/*.po` | 源码或 Blueprint 中的可翻译字符串变化 | `zig build update-translations`（需要启用 i18n，Windows 不可用） | `.github/scripts/check-translations.sh` | 是，上游生成物 |
| `vendor/glad/` | 更新 GLAD loader | 上游 `Makefile` 的 `glad` 目标 | 无 | 是，上游 vendored |

图谱新鲜度刻意不进 `framework-check`、`ci-check` 和 push CI：每改一次 Zig 源码就要花几分钟重建图谱，不划算。日常允许图谱落后于源码，但发版和上游同步时必须追平。检查失败时不手改产物，也不放宽排除表来「变绿」。
