# 命令手册（just）

本仓的命令入口是根目录的 `justfile`，用 `just` 调用，不是 make；文件名与其他 GX 仓库的命令手册一致。上游 `Makefile` 原样保留，不承载任何 fork 命令。流程上怎么组合这些命令见 [DEVELOPMENT.md](DEVELOPMENT.md)，每条测试命令能证明什么见 [TESTING.md](TESTING.md)。

## 约定

- `just`（不带参数）执行默认配方，即 `just --list`，列出全部配方及其说明。
- `justfile` 开头设置 `set windows-shell := ["cmd.exe", "/d", "/s", "/c"]`，并按平台选择解释器变量 `python`：Windows 上是 `python`，其他系统是 `python3`。每个配方体只有一条命令，在 cmd、PowerShell、Git Bash 与 Linux 上行为一致（参数里的空格与 shell 元字符除外，见下）。
- 配方总在仓库根（`justfile` 所在目录）执行，与调用时的当前目录无关。
- 产品配方一律经 `{{python}} scripts/zigw.py …` 调用钉版 Zig（`just build` 经 `scripts/zig_build.py`、两个测试配方经 `scripts/zig_test.py` 转调它），不直接调用 PATH 上的 `zig`。
- 配方名后面的参数原样拼进命令，包括 `-D…` 与 `--…` 形式，例如 `just test-vt --filter printSlice`、`just build-vt -Dtarget=wasm32-freestanding`、`just rules --task sync`、`just setup --innosetup`。
- 参数里的空格会把一个参数拆成两个：调用时写的引号先被外层 shell 去掉，`just` 再把参数原样拼进配方命令行，由配方 shell（Windows 上是 `cmd.exe`）重新切分（本机实测：在 Git Bash 里给 `--filter` 传带引号的 `"Terminal: input"`，脚本收到的是 `--filter Terminal:` 和多出的 `input`，以 `unrecognized arguments: input` 退出 2）。`--filter` 与 `-Dtest-filter` 都是子串匹配，多数时候取一段不含空格的名字即可；值里必须带空格时二选一：把双引号嵌进参数，留给配方 shell 处理，如 bash 下 `just test-vt '--filter="Terminal: input"'`；或绕过 just 直接调用脚本，如 `python scripts/zig_test.py --suite vt --filter "Terminal: input"`（Linux/macOS 用 `python3`）。
- 参数里也不要带 shell 元字符：just 不加引号地把参数交给配方 shell 解释，Windows 上 `cmd.exe` 会处理 `& | < > ^ %`，其他系统上 `sh` 会处理 `& | < > ; $` 等。例如 `just commit-check "fix: a -> b"` 会创建或清空仓库根的文件 `b`，`just kb-query "x & echo y"` 会另外执行 `echo y`；`just --dry-run <配方> <参数…>` 只打印拼好的命令行，可先确认。含这些字符的自由文本（查询词、提交标题）一律绕过 just 直接调用脚本：`python scripts/conventional_commits.py "<标题>"`、`python scripts/agent_kb.py "<查询>"`（Linux/macOS 用 `python3`）。
- 退出码：`just` 返回失败那条命令的退出码；聚合配方按依赖顺序执行，第一个失败即停止并返回其退出码（本机 just 1.58 实测）。

## 配方总表

### 环境与工具链

| 命令 | 作用 | 前置 | 副作用 / 输出 | 退出码 |
|---|---|---|---|---|
| `just` / `just default` | 默认配方，执行 `just --list` 列出全部配方 | `just` | 只读 | 0 |
| `just setup <参数…>` | `setup_env.py`：第一步安装钉版 Zig 0.16.0（sha256 校验，自定义源 → 内置镜像 → 官方源），`GX_GHOSTTY_ZIG` 或 `ZIG` 已指向可用的 0.16.0 时跳过；第二步建 `.local/tools/venv` 并装 `graphifyy==0.9.73`（有 uv 用 uv，否则 venv + pip）。参数原样交给脚本：`--innosetup` 另加第三步，安装 sha256 钉版的 Inno Setup 7.1.0（仅 Windows，`just package-windows` 打安装包要用）；`--force` 覆盖重装损坏的钉版 Zig | 网络；Python ≥ 3.10 | 写 `.local/toolchains/zig/zig-0.16.0/` 与 `.local/tools/venv/`；`--innosetup` 另写 `.local/cache/innosetup/`（安装包）与 `.local/tools/innosetup/`（以 `/CURRENTUSER /PORTABLE=1` 安装，不写注册表、不建卸载项）。各步幂等，已装且有效则跳过 | 0 成功；任一步失败（含非 Windows 主机上的 `--innosetup`）1；用法错误（如 `--check` 与 `--innosetup` 同用）2 |
| `just doctor` | `setup_env.py --check`：只读体检。必需项 zig、python、git、MSVC（仅 Windows）、venv、graphify；可选项 hooksPath、symlink 与 innosetup（仅 Windows），以及 codex、claude、kimi、zcode、actionlint、uv。symlink 在系统临时目录试建一次符号链接：成功报 FOUND；失败报 OPTIONAL，说明未开启开发者模式，tinyio 符号链接用例会以 `PermissionDenied` 失败。innosetup 在 `.local/tools/innosetup/` 有完整的钉版 Inno Setup 时报 FOUND，否则 OPTIONAL 并提示 `just setup --innosetup` | Python | 只读，不在仓库里建任何东西（symlink 探测只用仓库外的临时目录，用后即删）；输出 STATUS / ITEM / DETAIL 表，状态为 FOUND / MISSING / OPTIONAL，附修复提示 | 0；任一必需项 MISSING 时 1，可选项不影响退出码 |
| `just install-hooks` | `git config core.hooksPath .githooks`，启用 `.githooks/commit-msg`。钩子必须以可执行模式 `100755` 入库，否则 Linux/macOS 上的 git 会忽略它；Windows 克隆的 `core.filemode=false` 让普通 `git add` 记成 `100644`，所以首次提交用 `git add --chmod=+x .githooks/commit-msg`，入库后由 `scripts/test_conventional_commits.py` 校验模式 | Git | 修改本仓 `.git/config` | 透传 git 的退出码 |
| `just zig <参数…>` | 直通 `zigw.py`，用钉版 Zig 执行任意子命令，如 `just zig version`、`just zig build --help`、`just zig build test-lib-vt-schema` | 钉版 Zig，或 `GX_GHOSTTY_ZIG`、`ZIG` 指向的 0.16.0 | 取决于子命令；未设置 `ZIG_GLOBAL_CACHE_DIR` 时全局缓存写 `.local/zig-cache/global/` | 透传 zig 的退出码；找不到 Zig、版本不是 0.16.0 或覆盖变量指向无效文件时 2 |

### 规则、版本与框架门

| 命令 | 作用 | 前置 | 副作用 / 输出 | 退出码 |
|---|---|---|---|---|
| `just rules <路径…>` | resolver：列出本轮必读的领域文档，随后列出适用的上游嵌套 `AGENTS.md`；可加 `--task <类型>`（`release`、`sync`、`test`、`review`）与 `--json` | Python、Git | stdout；`--json` 时含 `upstream_agents` 字段 | 0；路径未登记、任务未知或参数错误时 2 |
| `just rules-review <路径…>` | 同上，追加 `--task review`，带出 `code-review` 规程 | 同上 | 同上 | 0 / 2 |
| `just rules-check` | resolver `--check`：根 `AGENTS.md` 体积与 fork 标记、schema 与排序、领域文档闭集、`nested_agents` 与实际一致、零命中 pattern、未覆盖文件、`root_only` 重叠、领域文档间重复段落 | Python、Git | 只读 | 0 通过；任何违规 2 |
| `just version` | `version.py`：打印 fork 版本，即 `CHANGELOG.md` 中数值最大的 SemVer | Python | stdout 一行 `X.Y.Z` | 0；标题非法或读不到 CHANGELOG 时 1 |
| `just version-check` | `version.py --check`：所有二级标题都是合法版本标题、版本不重复、至少一个 | Python | 只读 | 0 / 1 |
| `just framework-test` | `run_unittests.py`：并行运行 `scripts/test_*.py` 全部框架单测。每个 `TestCase` 类是一个单元、各起一个 `python -m unittest` 子进程（定义了 `load_tests` 的模块整体算一个单元）；并发默认取逻辑核数与 8 的较小值，按耗时缓存从慢到快调度，类属性 `RUN_LAST = True` 的单元最后启动。配方不接参数；只跑一部分或改并发时直接调用 `python scripts/run_unittests.py [-j N] [--list] [--timeout 秒] [PATTERN…]`，PATTERN 取 `test_x`、`scripts/test_x.py`、`test_x.Class` 或通配符，单元时限默认 600 s；单个测试方法用 `python -m unittest scripts.test_x.Class.test_y` | Python | 测试只用临时目录，不改仓库；写耗时缓存 `.local/test-timings/unittest.json`；本机约 500 个测试、约 13 s | 0 全部通过（跳过不算失败）；1 有失败、错误、崩溃或超时；2 用法或发现错误（模块导入失败、PATTERN 未命中）；130 被中断：Ctrl+C，POSIX 上 SIGTERM、SIGHUP 也按 Ctrl+C 处理，清理子进程后退出 |
| `just framework-check` | 聚合门：rules-check → version-check → framework-test → kb-check → i18n-check，不需要 Zig | Python、Git、已生成的 KB | 只读；本机约 15 s | 首个失败子项的退出码 |
| `just ci-check` | 聚合门：framework-check → fmt-check → test-vt，本机复现 CI 主干（不含完整单测 `just test`） | 以上，加钉版 Zig；Windows 需 MSVC | 构建缓存、`zig-out/` 与 `.local/test-timings/`；热缓存约 100 s，改过 Zig 源码另加约 2 min 编译（见 TESTING.md「并行运行器与耗时」） | 首个失败子项的退出码 |
| `just commit-check <参数…>` | `conventional_commits.py`：校验提交标题，用 `--message-file <文件>` 或 `--range <A>..<B>`（`git log --first-parent`；A 为全零 SHA 时只查 B）；`fixup!`、`squash!`、`amend!` 提交一律不合规。脚本也接受直接给出的标题，但标题必含空格，经 just 传入会被拆成几段而误报，`>`、`&` 等字符还会被配方 shell 解释（见「约定」），单条标题改用 `python scripts/conventional_commits.py "<标题>"` | Python；`--range` 需要 Git 历史 | 只读；不合规时列出标题与原因 | 0 全部合规；1 有违规；2 用法错误或读不到输入 |

### 生成物

| 命令 | 作用 | 前置 | 副作用 / 输出 | 退出码 |
|---|---|---|---|---|
| `just kb` | `build_agent_kb.py --confirm`：重建知识库 | Python、Git | 原子写入 `docs/kb/chunks.json`（确定性的 schema 2 JSON：每个文档一行头、每片一行；入库，审 diff），打印文档数、片数与体积 | 0；语料读取失败 2 |
| `just kb-check` | `build_agent_kb.py`：内存重建后与产物逐字节比较，列出变化来源；旧 schema 的产物报「格式或 schema 变化」 | Python、Git | 只读 | 0 新鲜；缺失或过期 1；语料读取失败 2 |
| `just kb-query <词…>` | `agent_kb.py`：BM25 检索知识库，中英文都可；`--top <n>` 改返回条数（默认 8），`--json` 输出 JSON（`id` 为 `path#anchor`）。查询词含 `&`、`>` 等 shell 元字符时直接调用 `python scripts/agent_kb.py "<查询>"`（见「约定」） | 已有 `docs/kb/chunks.json` | stdout，每条命中带 `doc` 与 `anchor` 便于回源 | 0，没有命中时输出「(无命中)」也是 0；KB 缺失、损坏或 schema 不符，以及没给查询词时 2 |
| `just graph` | `graphify.py rebuild`：全量重建代码图谱，随后写入并校验指纹 | `just setup` 装好的 graphifyy 0.9.73；耗时数分钟 | 写 `graphify-out/`：入库的 `GRAPH_REPORT.md`、`source-fingerprint.json`，以及本机的 `graph.json` | 0；graphify 缺失、版本不符或抽取失败时非 0 |
| `just graph-check` | `graphify.py check`：校验源码、管线与入库产物的指纹 | Python、Git；不需要 graphify 与 `graph.json` | 只读；`graph.json` 缺失时只提示 | 0 新鲜；过期或缺产物 2 |
| `just graph-query <问题…>` | `graphify.py query`：在本机图谱上查询，多个词合并为一句；路径与解释查询没有配方，直接用 `python scripts/graphify.py path …` 或 `python scripts/graphify.py explain …` | 本机已有 `graph.json`（先 `just graph`） | stdout | 透传 graphify；缺 `graph.json` 时 1 |
| `just i18n` | `gx_i18n.py`：由上游 `po/zh_CN.po` 与 fork 的 `src/gx/i18n/gx.zh_CN.po`（同一 msgid 以 fork 为准）重新生成 GX 界面的 zh-CN 翻译表；跳过 fuzzy、废弃与空译文，带 msgctxt 的条目以 `<msgctxt>\x04<msgid>` 为键，fork 条目的 `{name}` 占位符必须与原文一致 | Python | 写 `src/gx/i18n/zh_CN.zig`（按键的 UTF-8 字节序排序、LF、无时间戳，入库，审 diff）；内容不变时不写 | 0；源文件缺失、语法错误、键重复或占位符不一致 2 |
| `just i18n-check` | `gx_i18n.py --check`：内存重新生成后与已提交的翻译表比较（CRLF 检出视同 LF） | Python | 只读 | 0 新鲜；缺失或过期 1；源文件问题 2 |
| `just generated-check` | 聚合门：kb-check → i18n-check → graph-check | 同上三项 | 只读 | 首个失败子项的退出码 |

### 产品构建与测试

| 命令 | 作用 | 前置 | 副作用 / 输出 | 退出码 |
|---|---|---|---|---|
| `just build <参数…>` | `zig_build.py`：`zig build …`。Windows 主机上参数里没有 `-Dtarget=…`、也不是 `-Demit-lib-vt` 构建时，在前面补 `-Dtarget=x86_64-windows-gnu`；Windows 目标的 apprt 默认 `win32`（GX-0003），所以产出 win32 app `zig-out/bin/ghostty.exe`（另装 `share/` 与 libghostty-vt）。其他主机原样透传（Linux 默认 GTK app） | 钉版 Zig；首次构建要联网拉依赖；Windows 上的 GNU ABI 构建不需要 MSVC | `zig-out/`、`.zig-cache/`、`zig-pkg/`、`.local/zig-cache/global/` | 透传 zig；找不到 Zig 时 2 |
| `just test-vt <参数…>` | `zig_test.py --suite vt …`：先 `zig build test-lib-vt-bin`（fork 补丁 GX-0002 的步骤，只编译并安装），再把 `zig-out/test/vt/`、`zig-out/test/vt_c/` 两个测试二进制（`ghostty-vt`、`ghostty-vt-c` 模块）的用例分片到 `--jobs` 个进程。参数：`--filter <子串>`（按用例全名在运行期过滤，可重复，不重编）、`--seed <n>`、`--json <文件>`、`--list`、`--jobs <n>`（默认逻辑核数）、`--timeout <秒>`（单条用例，默认 600）、`--no-build`（直接跑已安装的二进制）、`--dedupe`、`--serial-filter <子串>`；`-D<选项>=<值>` 透传给 zig build（`-Dtest-filter` 是编译期裁剪，换值就要重编），其他以 `-` 开头的 zig 参数写成 `--zig-arg=<参数>` | 钉版 Zig；Windows 需 MSVC 与 Windows SDK（本机目标默认 MSVC），还需开启「开发者模式」（允许非管理员创建符号链接），否则 `src/lib/tinyio` 的 2 个符号链接用例（两个测试二进制各跑一次，共 4 处）以 `PermissionDenied` 失败；`just doctor` 的可选项 symlink 报告这项前置 | 同 `just build`，另写 `zig-out/test/`、耗时缓存 `.local/test-timings/vt.json` 与 `vt_c.json`、`--json` 指定的文件 | 0 全部通过（跳过不算失败）；1 有用例 fail、leak、log_err、crash、timeout 或未运行；2 用法错误、构建失败（含找不到 Zig）、缺测试二进制、读不到用例清单，或没有可运行的用例（报错写明是运行期 `--filter` 没命中、构建期 `-Dtest-filter` 裁掉了全部用例，还是二进制本身没有用例）；130 被中断：Ctrl+C，POSIX 上 SIGTERM、SIGHUP 也按 Ctrl+C 处理，杀掉测试进程后退出 |
| `just test <参数…>` | `zig_test.py --suite main …`：先构建 `test-bin`，再把以 `src/main.zig` 为根的完整单测 `ghostty-test` 分片运行，参数同 `just test-vt`。Windows 主机上给构建补 `-Dapp-runtime=win32 -Dtarget=x86_64-windows-gnu`（`-D` 或 `--zig-arg` 里已写的同名选项以使用者为准），与 `just build` 同一组合；Linux/macOS 原样，CI 的 `linux-main` 加 `-Dapp-runtime=none`。macOS 上只跑 `ghostty-test`：上游 `zig build test` 不带 `-Dtest-filter` 时还经 `addTestStepDependencies` 挂上 macOS app 的 `xcodebuild test`（跳过 `GhosttyUITests`），`just test` 不含它，app 单测用 `macos/build.nu --action test` | 同 `just build`；Windows 未开开发者模式时 tinyio 的 2 个符号链接用例以 `PermissionDenied` 失败 | 同上，产物 `zig-out/test/ghostty-test(.exe)`，耗时缓存 `.local/test-timings/ghostty-test.json` | 同 `just test-vt` |
| `just build-vt <参数…>` | `zig build -Demit-lib-vt …`：只构建 libghostty-vt；交叉编译加 `-Dtarget=<triple>` | 钉版 Zig；Windows 本机目标需 MSVC 与 Windows SDK | 同 `just build` | 透传 zig；找不到 Zig 时 2 |
| `just vt-wasm` | `zig build -Demit-lib-vt -Dtarget=wasm32-freestanding -Doptimize=ReleaseSmall` | 钉版 Zig | `zig-out/bin/ghostty-vt.wasm` | 同上 |
| `just dist-vt` | `zig build dist -Demit-lib-vt=true`：libghostty-vt 源码包 | 钉版 Zig、Git | 用 `git archive` 打包 HEAD（未提交的改动不在内），输出 `zig-out/dist/libghostty-vt-<版本>.tar.gz` | 同上 |
| `just fmt` | `zig fmt --exclude .local --exclude zig-pkg --exclude zig-out --exclude .zig-cache .`：格式化全仓 Zig 文件；`zig-pkg/` 是 Zig 0.16 构建时拉进仓库根的第三方依赖，必须排除 | 钉版 Zig | **改写文件** | 同上 |
| `just fmt-check` | 同上加 `--check`：只检查 | 钉版 Zig | 只读，列出未格式化的文件 | 0 / 非 0 |

`just test-vt` 与 `just test` 的补充说明（耗时与原理见 TESTING.md「并行运行器与耗时」）：

- 测试构建钉 `-Dversion-string=<build.zig.zon 的 X.Y.Z>-dev+0000000`（`scripts/zig_test.py::pinned_version_string`），换提交不改版本串，测试构建缓存照常命中；显式给 `-Dversion-string=` 时以显式值为准。
- 输出：每 2 秒一行进度；未通过的用例当场报一行，结束时附其 stderr；随后是各二进制的计数表、最慢 10 条用例和结论行 `PASS|FAIL … · wall …（build …, tests …）· jobs … · seed 0x…`；有失败时另打印一条可直接复制执行的复现命令 `python scripts/zig_test.py <本次的 --suite/--binary、-D、--zig-arg、--no-build、非默认的 --timeout> --seed 0x… --filter <引好的用例全名>`。用例名含空格，这条命令本身就绕过 just，不要把其中的参数接在 `just test-vt` 后面。
- 进程清理：单条用例超时、测试进程崩溃或整轮运行被中断时，运行器在 POSIX 上杀掉测试进程所在的整个进程组；Windows 上在超时与中断时杀掉整个进程树。中断指 Ctrl+C，POSIX 上还包括 SIGTERM、SIGHUP，清理后退出 130。
- 二进制选择：同一安装位置同时有无后缀与 `.exe` 两个文件时，非 Windows 主机优先取无后缀的，Windows 优先取 `.exe`。
- `--no-build` 跑的是 `zig-out/test/` 里上次安装的二进制；用过 `-Dtest-filter` 之后，那里可能只剩裁剪后的用例，裁空时报「测试二进制本身没有用例」。这类运行只把实测并入耗时缓存，不删记录（见 TESTING.md「并行运行器与耗时」）。
- 上游串行路径原样保留，用于与运行器的结论对照：`just zig build test-lib-vt`（每个二进制在单个进程里逐条运行，本机全量 6–8 min）与 `just zig build test`（Windows 上要自己写 `-Dapp-runtime=win32 -Dtarget=x86_64-windows-gnu`；macOS 上不带 `-Dtest-filter` 时还多跑 app 的 `xcodebuild test`）；`-Dtest-filter` 在这两条路径上同样可用。

### 打包

| 命令 | 作用 | 前置 | 副作用 / 输出 | 退出码 |
|---|---|---|---|---|
| `just package-windows <参数…>` | `gx_windows_package.py --build …`：先以 ReleaseFast 把 win32 app 构建进 `--prefix`（默认 `zig-out`），再下载并校验钉版组件（ConPTY 1.24.261001001、Mesa 26.2.4 llvmpipe、JetBrainsMono Nerd Font 与 Noto Sans CJK、许可证），产出便携 zip `ghostty-gx-<VS>-x86_64-windows.zip` 与 Inno Setup 安装包 `ghostty-gx-<VS>-x86_64-windows-setup.exe`，最后按 `scripts/gx_release.py::expected_assets` 检查。参数：`--skip-installer`（只出 zip）、`--offline`（只用缓存，不下载）、`--cache-dir <目录>`、`--iscc <ISCC.exe>`、`--prefix <目录>`、`--output-dir <目录>`（默认 `zig-out/dist`）、`--version-string <VS>`（默认且必须等于本检出推导的版本串） | Windows（其他主机未验证）；钉版 Zig；安装包要 ISCC（`--iscc` > `ISCC` 环境变量 > `just setup --innosetup` 装的 `.local/tools/innosetup/ISCC.exe` > PATH 上的 `iscc`）；首次联网下载（api.nuget.org、github.com、raw.githubusercontent.com）；系统自带的 `System32\tar.exe` 解 Mesa 的 `.7z` | **构建装进 `--prefix`，默认覆盖 `zig-out/` 里原有的构建**；`--output-dir` 里的同名产物被替换；下载缓存写 `GX_GHOSTTY_PACKAGE_CACHE` 或 `.local/cache/gx-package/`；sha256 不符的下载丢弃不留 | 0 成功（逐个打印产物大小与 sha256）；1 构建、下载、校验或 ISCC 失败；2 用法错误 |
| `just stage <平台> <新目录> <参数…>` | `gx_package.py <平台> --stage-dir <新目录> …`，`<平台>` 取 `windows` 或 `deb`：生成 GX Shell 组件 stage（schema 3，`stage-manifest.json` 加 `app/`、`fonts/`、`build-inputs/` 或 `root/`、`fonts/`），先过 `verify-stage` 才算成功。`--build` 先构建：windows 为 win32 ReleaseFast；deb 走 Ubuntu 24.04 配方 `scripts/gx_linux_build.py`，可加 `--install-deps`、`--source-tarball <ghostty-$VS.tar.gz>`。复核已有 stage 与打一次性测试包没有配方，直接调用 `python scripts/gx_package.py verify-stage <目录>`、`python3 scripts/gx_package.py test-deb <目录> --output <文件>` | windows：Windows 与钉版 Zig；deb：Ubuntu 24.04（`--install-deps` 以 root 或 sudo 装 apt 依赖，patchelf 0.18.0）；消费方契约、工具与网络需求只写在 `scripts/gx_package.py` 模块文档 | `<新目录>` 必须不存在，在旁边的临时目录组装、校验通过后才改名，失败不留下；`--build` 用临时前缀，结束后删除；下载缓存同上 | 0 成功；1 拒绝或失败；2 用法错误 |

### WSL（Windows 主机上的 Linux 构建、测试与截图）

| 命令 | 作用 | 前置 | 副作用 / 输出 | 退出码 |
|---|---|---|---|---|
| `just wsl <子命令> <参数…>` | `scripts/gx_wsl.py`：经 `wsl.exe -d <发行版> -e bash -c <脚本> gx-wsl <参数…>` 在 WSL 克隆（默认 `Ubuntu-24.04` 的 `~/src/gx_ghostty`）里执行，补上 Windows 本机编不出的 GTK app 与 Linux 上的单测。全局参数放在子命令前后都可以：`--distro`、`--clone`（Linux 路径；Git Bash 会改写以 `/` 开头的参数，写成 `'~/src/x'`）、`--dry-run`（只打印 wsl.exe 命令行与脚本） | Windows 与 WSL2；发行版里装好 apt 依赖（`setup --apt` 可补装）；首次 `setup` 要联网 | 只写 WSL 内：克隆、克隆内的 `.local/`（钉版 Zig、Zig 缓存）与 `zig-pkg/`、`~/.local/opt/blueprint-compiler-0.16.0` 与 `~/.local/bin/blueprint-compiler`；`smoke` 另写 `--out` 给的 Windows 目录 | 透传 WSL 内命令的退出码；用法错误、找不到 wsl.exe、缺克隆或缺构建产物、wsl.exe 自身失败为 2；`sync` 拒绝改动克隆为 3 |

| 子命令 | 作用 |
|---|---|
| `setup [--check] [--apt]` | 幂等：克隆不存在时从本仓 `git clone`；克隆内 `python3 scripts/setup_zig.py --install`；下载钉版 blueprint-compiler 0.16.0（GNOME GitLab 的 `v0.16.0` tag 归档，按 sha256 校验），用 meson 装到 `~/.local/opt/blueprint-compiler-0.16.0` 并写 `~/.local/bin/blueprint-compiler` shim（不覆盖别人写的同名文件）；最后预取 Zig 包。`--check` 只读报告；`--apt` 先以 root 安装缺失的 apt 包与 locale，只装缺的、不升级已装的 |
| `sync [<ref> \| <worktree 目录>] [--dirty]` | 把本仓的一个提交取进克隆并 detached 检出：目录参数按 worktree 处理（取其 HEAD），其余按本仓 ref 解析，省略时取脚本所在的 worktree。`--dirty` 用临时 index 把该 worktree 的未提交与未跟踪（未被忽略）文件快照成一个提交对象再同步，不动它的 index、ref 与文件，快照对象留在对象库里直到 gc。克隆有本地改动、或检出会孤立克隆里的本地提交时拒绝；同步结果记在克隆的 `refs/gx-wsl/synced` |
| `build [--gtk] <zig build 参数…>` | 克隆内 `python3 scripts/zigw.py build …`；`--gtk` 追加 `-Dapp-runtime=gtk -fno-sys=gtk4-layer-shell`：Ubuntu 24.04 没有 gtk4-layer-shell 开发包，改由 `pkg/gtk4-layer-shell` 构建动态库并装到 `zig-out/lib/` |
| `test [--suite main\|vt] [--gtk] [--filter <子串>]… <zig_test 参数…>` | 克隆内 `python3 scripts/zig_test.py`；`main`（默认）与 gx-ci `linux-main` 一样加 `-Dapp-runtime=none`，`--gtk` 改为 GTK 运行时（含 `src/apprt/gtk/gx/` 的单测） |
| `smoke --out <Windows 目录> [--lang zh_CN\|en] [--xdotool <文件>] [--config <文件>] [--wait <秒>] [--name <前缀>] [-- <ghostty 参数…>]` | 与 gx-ci `gtk-smoke` 相同的 `xvfb-run`（`1280x800x24`）、`GDK_BACKEND=x11 LIBGL_ALWAYS_SOFTWARE=1 NO_AT_BRIDGE=1` 与 `--gtk-single-instance=false`，等 `--wait` 秒（默认 20）后 scrot 截图；给了 xdotool 脚本就执行它（`$1` 是 Ghostty 的 PID）再截一张。`<前缀>.png`、`<前缀>-after.png`、`<前缀>.log`、`<前缀>-version.txt`、`<前缀>-meta.txt` 复制到 `--out`，前缀默认 `ghostty-xvfb[-<lang>]`；Ghostty 提前退出或截图为空时退出 1 |
| `run [--lang zh_CN\|en] [--config <文件>] [--x11] [-- <ghostty 参数…>]` | 在 WSLg 桌面后台启动 `zig-out/bin/ghostty`（默认 Wayland，`--x11` 走 XWayland），打印 PID 与停止命令；每次的私有配置与日志在 `~/.cache/gx-wsl/run/<时间>-<pid>/`，只保留最近 10 次。本机截不到 WSLg 窗口的内容，截图证据用 `smoke` |
| `shell` | 打印进入克隆、手工构建与运行的命令 |

- 网络：WSL 里 Zig 自带的 HTTP 客户端经 HTTP 代理访问 HTTPS 会失败（`HttpConnectionClosing`：CONNECT 隧道建好后没有做 TLS），所以 `setup`、`build`、`test` 先按 `build.zig.zon.json` 与各级 `build.zig.zon`（忽略 `//` 注释）用 curl 下载缺失的包，再在克隆里 `zig fetch <文件>` 登记，打印出的包 hash 必须等于声明值；`git+https` 依赖改取 GitHub / Codeberg 上该提交的归档，同样由 hash 保证内容一致。
- 运行期库：Zig 写进 `ghostty` 的 RUNPATH 是相对路径 `.zig-cache/o/<hash>`，只有在克隆根目录下运行才找得到 `libgtk4-layer-shell.so`，所以 `smoke`、`run` 设 `LD_LIBRARY_PATH=<克隆>/zig-out/lib`。另一条路是 `src/build/Config.zig` 的 `-Dpatch-rpath='$ORIGIN/../lib'`（PATH 上要有 `patchelf`）：实测得到 RUNPATH `$ORIGIN/../lib`，任意目录都能运行；但它就地改写 Zig 缓存里的产物，gx_wsl 不默认使用（Ubuntu 24.04 配方 `scripts/gx_linux_build.py` 为此用单独的本地缓存）。
- 配置隔离：`smoke`、`run` 给 Ghostty 一个私有的 `XDG_CONFIG_HOME`，其中 `ghostty/config.ghostty` 是 `--config` 文件（CRLF 转为 LF）或空文件，并用 `env = XDG_CONFIG_HOME=…` 把原值交还给终端里的 shell；不读写 WSL 用户自己的 Ghostty 配置，也不在 `~/.config/ghostty` 生成模板。
- WSL 内的环境：去掉 PATH 中的 `/mnt/*` 项、把 `~/.local/bin` 放在最前，并 unset `ZIG` 与 `GX_GHOSTTY_ZIG`，一律使用克隆内的钉版 Zig。
- 一个克隆同一时间只给一个任务用；其他任务用 `--clone '~/src/gx_ghostty-<id>'`（或 `GX_WSL_CLONE`）各自建克隆，`setup` 会负责克隆。

## 环境变量

| 变量 | 读取方 | 作用 |
|---|---|---|
| `GX_GHOSTTY_ZIG` | `scripts/zigw.py` | 指定 zig，优先级最高。含路径分隔符的值按文件解析，裸命令名按 PATH 查找；一旦设置就是权威，指向无效时直接退出 2，不回退 |
| `ZIG` | `scripts/zigw.py` | 次优先，规则同上。两者都未设置时依次用钉版目录与 PATH 上的 `zig`；无论来源，`zig version` 都必须等于 `scripts/setup_zig.py::ZIG_VERSION` |
| `GX_GHOSTTY_ZIG_HOME` | `scripts/setup_zig.py`（`zigw.py` 经它定位钉版） | 覆盖钉版 Zig 的安装根，默认 `.local/toolchains/zig`，供测试或多个 worktree 共享 |
| `GX_GHOSTTY_ZIG_MIRROR` | `scripts/setup_zig.py` | 自定义下载源，排在内置镜像与官方源之前；任何来源都要过同一 sha256 校验 |
| `GX_ZIG_TEST_TIMINGS_DIR` | `scripts/zig_test.py::timings_path` | 换掉耗时缓存目录（默认 `.local/test-timings`），相对路径按仓库根解析；只影响调度顺序。gx-ci 的三个测试 job 设为 `.zig-cache/gx-test-timings`，随 `setup-zig` 的缓存保存 |
| `ZIG_GLOBAL_CACHE_DIR` | Zig；`scripts/zigw.py` | Zig 全局缓存（下载的包等）。未设置或为空时 `zigw.py` 设为 `.local/zig-cache/global`；显式设置的值原样保留。`gx-release` 的构建 job 设在 `$RUNNER_TEMP`，让 `distcheck` 的内层构建看不到检出的 Git 元数据 |
| `ZIG_LOCAL_CACHE_DIR` | Zig；`scripts/gx_linux_build.py` | Zig 本地缓存，默认构建根的 `.zig-cache`。Ubuntu 配方未设时用 `.local/zig-cache/gx-linux-build`（`-Dpatch-rpath` 会就地改写缓存里的产物，所以单独一份）；`gx-release` 设在 `$RUNNER_TEMP` |
| `GX_GHOSTTY_PACKAGE_CACHE` | `scripts/gx_windows_package.py::cache_dir`、`scripts/gx_package.py`、`scripts/gx_linux_build.py` | 钉版下载（ConPTY、Mesa、字体、blueprint-compiler 归档）的缓存目录，默认 `.local/cache/gx-package`；`--cache-dir` 优先。缓存里 sha256 不符的文件会被重新下载 |
| `ISCC` | `scripts/gx_windows_package.py::find_iscc` | Inno Setup 编译器 `ISCC.exe` 的路径，排在 `--iscc` 之后、`.local/tools/innosetup/ISCC.exe` 与 PATH 之前；指向不存在的文件时打包失败。`gx-release` 的 `windows-app` job 用它传入钉版安装的 ISCC |
| `GX_GHOSTTY_GRAPHIFY_CLI` | `scripts/graphify.py` | 指定 graphify CLI；未设置时先用 `.local/tools/venv` 的 `python -m graphify`（不直接执行 venv 里生成的 `graphify.exe`：Windows 智能应用控制会以 WinError 4551 拦截这个未签名启动器），再找 PATH 里的 `graphify` |
| `GX_GHOSTTY_GRAPHIFY_ALLOW_ANY_VERSION` | `scripts/graphify.py` | 设为 `1` 时放行非钉版 graphify，只用于升级钉版前在临时副本里比对图谱 |
| `GHOSTTY_GX_DEFAULTS` | `src/gx/config_layers.zig::enabled`（`Config.load`） | 设为 `0`、`false`、`off` 或 `no` 时，ghostty 像上游一样加载配置：没有 Ghostty GX 默认值、不读 `gui-settings.ghostty`、按上游顺序；用于对照上游行为与测试 |
| `GHOSTTY_GX_OPENGL` | `src/renderer/opengl/wgl.zig`（`Device.init`） | 仅 Windows：设为 `software`（不区分大小写）时跳过系统 OpenGL 驱动，直接用 exe 旁 `mesa\opengl32.dll`（Mesa llvmpipe）；未设时只在系统驱动建不出 OpenGL 4.3 core 上下文时才用 Mesa。日志行 `loaded OpenGL … software=` 显示实际结果 |
| `GHOSTTY_GX_CONPTY` | `src/gx/conpty.zig` | 仅 Windows：`system`（不区分大小写）强制用系统 ConPTY（kernel32）；未设、空或 `bundled` 时 exe 旁同时有 `conpty.dll` 与 `OpenConsole.exe` 就用随包 ConPTY；其他值记 warning 后按默认处理。日志行 `ConPTY: …` 显示实际结果 |
| `XDG_CONFIG_HOME`、`LOCALAPPDATA` | Ghostty（`src/os/xdg.zig::config`、`src/apprt/win32/file_log.zig`） | 配置目录是 `$XDG_CONFIG_HOME/ghostty`；Windows 上未设 `XDG_CONFIG_HOME` 时退回 `%LOCALAPPDATA%\ghostty`，日志总在 `%LOCALAPPDATA%\ghostty\logs\`。做实验与截图验证时把两者指向隔离目录（TESTING.md「Windows GUI 验证」） |
| `GX_WSL_DISTRO` | `scripts/gx_wsl.py` | `just wsl` 的默认 WSL 发行版（缺省 `Ubuntu-24.04`），`--distro` 优先 |
| `GX_WSL_CLONE` | `scripts/gx_wsl.py` | `just wsl` 的默认克隆路径，必须是 Linux 路径（缺省 `~/src/gx_ghostty`），`--clone` 优先 |
| `GX_GATE_WATCHDOG_SECONDS` | `.claude/hooks/pre_tool_use_gate.py::evaluation_deadline` | 只供测试：缩短 hook 求值看门狗（默认 `EVALUATION_DEADLINE_SECONDS`，10 秒），只认 (0, 10] 内的数，其余值一律按默认处理，所以只能缩短、不能延长。日常会话不要设置：它只会让 hook 更早超时，从而拒绝本可放行的调用 |

## 上游 Makefile 目标（原样保留）

| 目标 | 作用 |
|---|---|
| `make init` | 只打印提示，建议改用 `zig build` |
| `make glad` | 用放在仓库根的 `glad.zip`（https://gen.glad.sh/ 生成）重建 `vendor/glad/`；先删除 `vendor/glad` 再运行 |
| `make clean` | 删除 `zig-out`、`.zig-cache`、`macos/build`、`macos/GhosttyKit.xcframework` |

这三个目标属于上游，fork 不修改、不扩展；本机没有安装 make，日常也用不到它们。`vendor/glad/` 是上游 vendored 的生成物，agent 的编辑工具不能直接改。

## Windows 说明

- 配方在 `cmd.exe` 里执行，不依赖 Git Bash 或 WSL；从 cmd、PowerShell、Git Bash 调用 `just` 结果相同。
- `justfile` 在 Windows 上调用 `python`。如果它解析到 `WindowsApps` 下不可用的别名，所有配方（包括 `just doctor`）都会失败；用 `where python` 与 `python --version` 确认解析结果，必要时调整 PATH 让真实解释器排在前面。
- 两种 ABI：`just build`、`just test`、`just package-windows` 按 `x86_64-windows-gnu` 构建 win32 app 与 `ghostty-test`，用 Zig 自带的 MinGW 头文件；`just test-vt`、`just build-vt` 与不经 `just` 的 `zig build` 用本机默认的 MSVC 目标，需要 MSVC 与 Windows SDK，由人类安装，`just doctor` 用 vswhere 查找带 C++ 工具组件的 Visual Studio，只报告不安装。
- 本机能跑的全量：`just ci-check`（framework-check、fmt-check、test-vt）加 `just test`。只在 Linux 上编译的代码与 GTK 用 `just wsl` 或 `gx-ci` 的 `linux-main` 补证，Windows 上的单测不进 CI（`gx-ci` 的 `windows-app` 只构建）。
- `just package-windows` 默认把 ReleaseFast 构建装进 `zig-out/`，之后要回到 Debug 构建就再跑一次 `just build`。
- 装了 WSL2 时，`just wsl test`、`just wsl build --gtk` 与 `just wsl smoke --out <目录>` 在 WSL 克隆里补跑 Linux 完整单测、GTK 构建与 Xvfb 截图（见上文「WSL」）；这是本机 Linux 证据，与 `gx-ci` 的 job 互不代证。
- 判断成败只看退出码，不把命令接到 `| tail`、`| head`；各 shell 的写法见 TESTING.md「证据规则」。
