# 命令手册（just）

文件名沿用 wezterm、herdr 两个 fork 的 `docs/MAKE_COMMANDS.md`，方便三仓对照；本仓的命令入口是根目录的 `justfile`，用 `just` 调用，不是 make。上游 `Makefile` 原样保留，不承载任何 fork 命令。流程上怎么组合这些命令见 [DEVELOPMENT.md](DEVELOPMENT.md)，每条测试命令能证明什么见 [TESTING.md](TESTING.md)。

## 约定

- `just`（不带参数）执行默认配方，即 `just --list`，列出全部配方及其说明。
- `justfile` 开头设置 `set windows-shell := ["cmd.exe", "/d", "/s", "/c"]`，并按平台选择解释器变量 `python`：Windows 上是 `python`，其他系统是 `python3`。每个配方体只有一条命令，在 cmd、PowerShell、Git Bash 与 Linux 上行为一致（参数里的空格与 shell 元字符除外，见下）。
- 配方总在仓库根（`justfile` 所在目录）执行，与调用时的当前目录无关。
- 产品配方一律经 `{{python}} scripts/zigw.py …` 调用钉版 Zig，不直接调用 PATH 上的 `zig`。
- 配方名后面的参数原样拼进命令，包括 `-D…` 与 `--…` 形式，例如 `just test-vt --filter printSlice`、`just build-vt -Dtarget=wasm32-freestanding`、`just rules --task sync`。
- 参数里的空格会把一个参数拆成两个：调用时写的引号先被外层 shell 去掉，`just` 再把参数原样拼进配方命令行，由配方 shell（Windows 上是 `cmd.exe`）重新切分（本机实测：在 Git Bash 里给 `--filter` 传带引号的 `"Terminal: input"`，脚本收到的是 `--filter Terminal:` 和多出的 `input`，以 `unrecognized arguments: input` 退出 2）。`--filter` 与 `-Dtest-filter` 都是子串匹配，多数时候取一段不含空格的名字即可；值里必须带空格时二选一：把双引号嵌进参数，留给配方 shell 处理，如 bash 下 `just test-vt '--filter="Terminal: input"'`；或绕过 just 直接调用脚本，如 `python scripts/zig_test.py --suite vt --filter "Terminal: input"`（Linux/macOS 用 `python3`）。
- 参数里也不要带 shell 元字符：just 不加引号地把参数交给配方 shell 解释，Windows 上 `cmd.exe` 会处理 `& | < > ^ %`，其他系统上 `sh` 会处理 `& | < > ; $` 等。例如 `just commit-check "fix: a -> b"` 会创建或清空仓库根的文件 `b`，`just kb-query "x & echo y"` 会另外执行 `echo y`；`just --dry-run <配方> <参数…>` 只打印拼好的命令行，可先确认。含这些字符的自由文本（查询词、提交标题）一律绕过 just 直接调用脚本：`python scripts/conventional_commits.py "<标题>"`、`python scripts/agent_kb.py "<查询>"`（Linux/macOS 用 `python3`）。
- 退出码：`just` 返回失败那条命令的退出码；聚合配方按依赖顺序执行，第一个失败即停止并返回其退出码（本机 just 1.58 实测）。

## 配方总表

### 环境与工具链

| 命令 | 作用 | 前置 | 副作用 / 输出 | 退出码 |
|---|---|---|---|---|
| `just` / `just default` | 默认配方，执行 `just --list` 列出全部配方 | `just` | 只读 | 0 |
| `just setup` | `setup_env.py`：第一步安装钉版 Zig 0.16.0（sha256 校验，自定义源 → 内置镜像 → 官方源），`GX_GHOSTTY_ZIG` 或 `ZIG` 已指向可用的 0.16.0 时跳过；第二步建 `.local/tools/venv` 并装 `graphifyy==0.9.73`（有 uv 用 uv，否则 venv + pip） | 网络；Python ≥ 3.10 | 写 `.local/toolchains/zig/zig-0.16.0/` 与 `.local/tools/venv/`；两步都幂等，已装且有效则跳过 | 0 成功；任一步失败 1。不接受参数，覆盖重装损坏的钉版 Zig 用 `python scripts/setup_env.py --force` |
| `just doctor` | `setup_env.py --check`：只读体检。必需项 zig、python、git、MSVC（仅 Windows）、venv、graphify；可选项 hooksPath、symlink（仅 Windows）与 codex、claude、kimi、zcode、actionlint、uv。symlink 在系统临时目录试建一次符号链接：成功报 FOUND；失败报 OPTIONAL，说明未开启开发者模式，`just test-vt` 的 tinyio 符号链接用例会以 `PermissionDenied` 失败 | Python | 只读，不在仓库里建任何东西（symlink 探测只用仓库外的临时目录，用后即删）；输出 STATUS / ITEM / DETAIL 表，状态为 FOUND / MISSING / OPTIONAL，附修复提示 | 0；任一必需项 MISSING 时 1，可选项不影响退出码 |
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
| `just framework-check` | 聚合门：rules-check → version-check → framework-test → kb-check，不需要 Zig | Python、Git、已生成的 KB | 只读；本机约 15 s | 首个失败子项的退出码 |
| `just ci-check` | 聚合门：framework-check → fmt-check → test-vt，本机复现 CI 主干（不含完整单测 `just test`） | 以上，加钉版 Zig；Windows 需 MSVC | 构建缓存、`zig-out/` 与 `.local/test-timings/`；热缓存约 100 s，改过 Zig 源码另加约 2 min 编译（见 TESTING.md「并行运行器与耗时」） | 首个失败子项的退出码 |
| `just commit-check <参数…>` | `conventional_commits.py`：校验提交标题，用 `--message-file <文件>` 或 `--range <A>..<B>`（`git log --first-parent`；A 为全零 SHA 时只查 B）；`fixup!`、`squash!`、`amend!` 提交一律不合规。脚本也接受直接给出的标题，但标题必含空格，经 just 传入会被拆成几段而误报，`>`、`&` 等字符还会被配方 shell 解释（见「约定」），单条标题改用 `python scripts/conventional_commits.py "<标题>"` | Python；`--range` 需要 Git 历史 | 只读；不合规时列出标题与原因 | 0 全部合规；1 有违规；2 用法错误或读不到输入 |

### 生成物

| 命令 | 作用 | 前置 | 副作用 / 输出 | 退出码 |
|---|---|---|---|---|
| `just kb` | `build_agent_kb.py --confirm`：重建知识库 | Python、Git | 原子写入 `docs/kb/chunks.json`（确定性 JSON，入库，审 diff） | 0；语料读取失败 2 |
| `just kb-check` | `build_agent_kb.py`：内存重建后与产物逐字节比较，列出变化来源 | Python、Git | 只读 | 0 新鲜；缺失或过期 1；语料读取失败 2 |
| `just kb-query <词…>` | `agent_kb.py`：BM25 检索知识库，中英文都可；`--top <n>` 改返回条数（默认 8），`--json` 输出 JSON。查询词含 `&`、`>` 等 shell 元字符时直接调用 `python scripts/agent_kb.py "<查询>"`（见「约定」） | 已有 `docs/kb/chunks.json` | stdout，每条命中带 `doc` 与 `anchor` 便于回源 | 0，没有命中时输出「(无命中)」也是 0；KB 缺失或损坏、没给查询词时 2 |
| `just graph` | `graphify.py rebuild`：全量重建代码图谱，随后写入并校验指纹 | `just setup` 装好的 graphifyy 0.9.73；耗时数分钟 | 写 `graphify-out/`：入库的 `GRAPH_REPORT.md`、`source-fingerprint.json`，以及本机的 `graph.json` | 0；graphify 缺失、版本不符或抽取失败时非 0 |
| `just graph-check` | `graphify.py check`：校验源码、管线与入库产物的指纹 | Python、Git；不需要 graphify 与 `graph.json` | 只读；`graph.json` 缺失时只提示 | 0 新鲜；过期或缺产物 2 |
| `just graph-query <问题…>` | `graphify.py query`：在本机图谱上查询，多个词合并为一句；路径与解释查询没有配方，直接用 `python scripts/graphify.py path …` 或 `python scripts/graphify.py explain …` | 本机已有 `graph.json`（先 `just graph`） | stdout | 透传 graphify；缺 `graph.json` 时 1 |
| `just generated-check` | 聚合门：kb-check → graph-check | 同上两项 | 只读 | 首个失败子项的退出码 |

### 产品构建与测试

| 命令 | 作用 | 前置 | 副作用 / 输出 | 退出码 |
|---|---|---|---|---|
| `just build <参数…>` | `zig build …`。Windows 上没有 app，默认 `install` 改为构建 libghostty-internal，而它编译不过（`src/build/SharedDeps.zig::add` 的 translate-c 导入 `posix_c` 找不到 `pwd.h`），命令以退出码 1 结束；Windows 上构建库用 `just build-vt` | 钉版 Zig；Windows 需 MSVC 与 Windows SDK；首次构建要联网拉依赖 | `zig-out/`、`.zig-cache/`、`zig-pkg/`、`.local/zig-cache/global/` | 透传 zig（Windows 上不带 `-Demit-lib-vt` 时为 1）；找不到 Zig 时 2 |
| `just test-vt <参数…>` | `zig_test.py --suite vt …`：先 `zig build test-lib-vt-bin`（fork 补丁 GX-0002 的步骤，只编译并安装），再把 `zig-out/test/vt/`、`zig-out/test/vt_c/` 两个测试二进制（`ghostty-vt`、`ghostty-vt-c` 模块）的用例分片到 `--jobs` 个进程。参数：`--filter <子串>`（按用例全名在运行期过滤，可重复，不重编）、`--seed <n>`、`--json <文件>`、`--list`、`--jobs <n>`（默认逻辑核数）、`--timeout <秒>`（单条用例，默认 600）、`--no-build`（直接跑已安装的二进制）、`--dedupe`、`--serial-filter <子串>`；`-D<选项>=<值>` 透传给 zig build（`-Dtest-filter` 是编译期裁剪，换值就要重编），其他以 `-` 开头的 zig 参数写成 `--zig-arg=<参数>`。Windows 本机的主测试 | 同上；Windows 还需开启「开发者模式」（允许非管理员创建符号链接），否则 `src/lib/tinyio` 的 2 个符号链接用例（两个测试二进制各跑一次，共 4 处）以 `PermissionDenied` 失败；`just doctor` 的可选项 symlink 报告这项前置 | 同上，另写 `zig-out/test/`、耗时缓存 `.local/test-timings/vt.json` 与 `vt_c.json`、`--json` 指定的文件 | 0 全部通过（跳过不算失败）；1 有用例 fail、leak、log_err、crash、timeout 或未运行；2 用法错误、构建失败（含找不到 Zig）、缺测试二进制、读不到用例清单，或没有可运行的用例（报错写明是运行期 `--filter` 没命中、构建期 `-Dtest-filter` 裁掉了全部用例，还是二进制本身没有用例）；130 被中断：Ctrl+C，POSIX 上 SIGTERM、SIGHUP 也按 Ctrl+C 处理，杀掉测试进程后退出 |
| `just test <参数…>` | `zig_test.py --suite main …`：先构建 `test-bin`，再把以 `src/main.zig` 为根的完整单测 `ghostty-test` 分片运行，参数同 `just test-vt`；CI 的 `linux-main` 加 `-Dapp-runtime=none`。只支持 Linux、macOS：Windows 上只要没加 `--no-build`，就在构建前以退出码 2 结束并说明原因（`scripts/zig_test.py::MAIN_SUITE_ON_WINDOWS`：`ghostty-test` 在 Windows 编译不过，上游 `zig build test` 同样找不到 `pwd.h`），加了 `--no-build` 也因找不到二进制退出 2。macOS 上只跑 `ghostty-test`：上游 `zig build test` 不带 `-Dtest-filter` 时还经 `addTestStepDependencies` 挂上 macOS app 的 `xcodebuild test`（跳过 `GhosttyUITests`），`just test` 不含它，app 单测用 `macos/build.nu --action test` | 同 `just build` | 同上，产物 `zig-out/test/ghostty-test`，耗时缓存 `.local/test-timings/ghostty-test.json` | 同 `just test-vt`；Windows 上为 2 |
| `just build-vt <参数…>` | `zig build -Demit-lib-vt …`：只构建 libghostty-vt；交叉编译加 `-Dtarget=<triple>` | 同 `just build` | 同 `just build` | 同 `just build` |
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
- 上游串行路径原样保留，用于与运行器的结论对照：`just zig build test-lib-vt`（每个二进制在单个进程里逐条运行，本机全量 6–8 min）与 `just zig build test`（Linux/macOS；macOS 上不带 `-Dtest-filter` 时还多跑 app 的 `xcodebuild test`）；`-Dtest-filter` 在这两条路径上同样可用。

## 环境变量

| 变量 | 读取方 | 作用 |
|---|---|---|
| `GX_GHOSTTY_ZIG` | `scripts/zigw.py` | 指定 zig，优先级最高。含路径分隔符的值按文件解析，裸命令名按 PATH 查找；一旦设置就是权威，指向无效时直接退出 2，不回退 |
| `ZIG` | `scripts/zigw.py` | 次优先，规则同上。两者都未设置时依次用钉版目录与 PATH 上的 `zig`；无论来源，`zig version` 都必须等于 `scripts/setup_zig.py::ZIG_VERSION` |
| `GX_GHOSTTY_ZIG_HOME` | `scripts/setup_zig.py`（`zigw.py` 经它定位钉版） | 覆盖钉版 Zig 的安装根，默认 `.local/toolchains/zig`，供测试或多个 worktree 共享 |
| `GX_GHOSTTY_ZIG_MIRROR` | `scripts/setup_zig.py` | 自定义下载源，排在内置镜像与官方源之前；任何来源都要过同一 sha256 校验 |
| `GX_ZIG_TEST_TIMINGS_DIR` | `scripts/zig_test.py::timings_path` | 换掉耗时缓存目录（默认 `.local/test-timings`），相对路径按仓库根解析；只影响调度顺序。gx-ci 的三个测试 job 设为 `.zig-cache/gx-test-timings`，随 `setup-zig` 的缓存保存 |
| `ZIG_GLOBAL_CACHE_DIR` | Zig；`scripts/zigw.py` | Zig 全局缓存目录。未设置或为空时 `zigw.py` 设为 `.local/zig-cache/global`；显式设置的值原样保留 |
| `GX_GHOSTTY_GRAPHIFY_CLI` | `scripts/graphify.py` | 指定 graphify CLI；未设置时先用 `.local/tools/venv` 的 `python -m graphify`（不直接执行 venv 里生成的 `graphify.exe`：Windows 智能应用控制会以 WinError 4551 拦截这个未签名启动器），再找 PATH 里的 `graphify` |
| `GX_GHOSTTY_GRAPHIFY_ALLOW_ANY_VERSION` | `scripts/graphify.py` | 设为 `1` 时放行非钉版 graphify，只用于升级钉版前在临时副本里比对图谱 |
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
- 构建需要 MSVC 与 Windows SDK，由人类安装；`just doctor` 用 vswhere 查找带 C++ 工具组件的 Visual Studio，只报告不安装。
- `just test` 在 Windows 上直接以退出码 2 结束（`ghostty-test` 编译不过，见上表），`just build` 以退出码 1 结束（libghostty-internal 编译不过，库用 `just build-vt`）；`just test-vt` 是本机主测试，本机能跑的全量是 `just ci-check`（framework-check、fmt-check、test-vt）。完整单测与非 vt 代码的编译交给 `gx-ci` 的 `linux-main`，本机记 PENDING。GUI 相关命令在 Windows 上没有对应物。
- 判断成败只看退出码，不把命令接到 `| tail`、`| head`；各 shell 的写法见 TESTING.md「证据规则」。
