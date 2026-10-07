# 测试与证据（gx_ghostty）

每一层都要写清楚能证明什么、不能代证什么。不同层不能互相顶替，Windows 本机的结果也不能顶替 Linux 或 macOS。命令细节见 [MAKE_COMMANDS.md](MAKE_COMMANDS.md)，九步闭环见 [DEVELOPMENT.md](DEVELOPMENT.md)，测试相关的领域规则见 `docs/AGENT_RULES/testing.md`。

## 分层

| 层 | 命令 | 前置 | 能证明 | 不能代证 |
|---|---|---|---|---|
| 框架单测 | `just framework-test`（`scripts/run_unittests.py` 并行）；只跑一部分用 `python scripts/run_unittests.py <PATTERN…>` | Python ≥ 3.10 | resolver、hook 允许与拒绝探针、版本、提交规范、zigw 与 setup、两个测试运行器、发布脚本、workflow 形状与启用集合、KB 检索回归、图谱指纹、fork 补丁标记等框架契约 | 任何 Zig 产品行为；AI 客户端的新会话是否真的加载了配置（见 AI_TOOLS.md 验证账本） |
| 规则闭集 | `just rules-check` | Python、Git | 每个 Git 可见文件都有路由、pattern 无零命中、与 `root_only` 不重叠；嵌套 `AGENTS.md` 与登记一致；领域文档闭集与体积；根 `AGENTS.md` ≤16 KiB 且含 fork 标记 | 规则内容是否与源码一致，这要靠复审 |
| 版本格式 | `just version-check` | Python | `CHANGELOG.md` 标题都合法、至少有一个，可以取出最大 SemVer | 能否发版：`gx-release` 以 `publish=true` 运行时，prepare 另要求最大版本已带日期 |
| KB 新鲜度 | `just kb-check` | Python | `docs/kb/chunks.json` 与当前语料一致 | 文档内容是否正确 |
| 图谱新鲜度 | `just graph-check` | Python；不需要本机 `graph.json` | 被索引源码、管线脚本与入库报告的指纹一致 | 图谱质量；它不在 framework-check、ci-check 与 push CI 里 |
| Zig 格式 | `just fmt-check` | 钉版 Zig（`just setup`） | 全仓 `.zig` 文件符合 `zig fmt`（排除 `.local`、`zig-pkg`、`zig-out`、`.zig-cache`） | 能否编译，行为是否正确 |
| libghostty-vt 单测 | `just test-vt`（`scripts/zig_test.py` 并行分片），定向加 `--filter <子串>` | Zig；Windows 需 MSVC | 以 `src/lib_vt.zig` 为根的 Zig 模块与 C API 模块的单测在本机目标上通过，判定与 `zig build` 相同 | ABI 清单、其他目标、完整单测（`zig build test` 不包含 test-lib-vt，反之亦然） |
| ABI 清单 | `just zig build test-lib-vt-schema` | Zig；PATH 上的 `python3` 是真实解释器且装有 `jsonschema`，wasm 目标还要 `wasmtime`（上游靠 `nix develop` 提供） | 本次构建出的共享库导出的类型清单符合 `src/terminal/c/types.schema.json` | 运行时行为 |
| 完整 Zig 单测 | `just test`（同一运行器，`--suite main`），定向加 `--filter <子串>` | Zig；只在 Linux、macOS 上可用，Windows 上退出 2（见「Windows 本机限制」） | 以 `src/main.zig` 为根的 `ghostty-test` 单测 | libghostty-vt 单测、GUI 行为、macOS app 的 Swift 单测（上游 `zig build test` 在 macOS 上不带 `-Dtest-filter` 时会挂上 `xcodebuild test`，`just test` 不含，用 `macos/build.nu --action test`）；`-Dapp-runtime=none` 时不含 GTK apprt |
| 上游串行对照 | `just zig build test-lib-vt`，可加 `-Dtest-filter=<名> --summary all`；Linux/macOS 另有 `just zig build test`（macOS 上不带 `-Dtest-filter` 时还多跑 app 的 `xcodebuild test`） | Zig；Windows 需 MSVC；`zig build test` 只在 Linux、macOS 上能编译 | 同一批用例由 `zig build` 在单个进程里逐条运行时也通过，用来排除运行器（分片、进程复用、调度顺序）对结论的影响 | 并行运行器已证明的内容之外，只多证明「与上游运行方式一致」；lib-vt 全量要 6–8 min |
| C 与 Zig 示例 | 在 `example/<dir>` 下执行 `python ../../scripts/zigw.py build`，`python ../../scripts/zigw.py build run` 运行（Linux/macOS 用 `python3`） | 钉版 Zig；示例经 `../../` 路径依赖本仓 | 外部消费者能按示例方式链接 libghostty-vt，如静态链接的 `c-vt-static`、动态链接的 `c-vt-effects` | 其他示例与其他平台 |
| 交叉构建 | `just build-vt -Dtarget=<triple>` | Zig | 该目标能编译、链接 | 在该目标上的运行结果 |
| wasm | `just vt-wasm`，再 `node test/wasm-alloc.mjs zig-out/bin/ghostty-vt.wasm` | Zig；冒烟需要 Node | wasm32-freestanding 的 ReleaseSmall 构建；导出的分配接口可用 | 浏览器集成与性能 |
| 源码包 | `just dist-vt`；完整校验 `just zig build distcheck -Demit-lib-vt=true` | Zig、Git；distcheck 的内层命令另需 PATH 上的 `zig`（0.16.x）、`tar` 与 `cmake` | dist：用 `git archive` 打包 HEAD 生成源码 tarball；distcheck：解包后 `test-lib-vt` 通过，且 CMake 能从 tarball 构建 | 工作树里未提交的改动（不进 tarball）；二进制发布包 |
| GTK 冒烟 | 手动触发 `gx-ci`，打开 `gtk_smoke` 输入 | fork 已启用 Actions，提交已 push | debian:13 容器里 GTK app 能以 ReleaseFast 构建，`ghostty +version` 能运行，在 Xvfb（1280x800，X11 后端、软件渲染）下启动 20 秒后仍在运行并完成截图；artifact `gx-gtk-smoke-evidence` 必须下载并实际读图 | 渲染内容是否正确（以读图结论为准）、Wayland、IME、真实桌面交互与其他发行版 |
| macOS lib-vt | 手动触发 `gx-ci`，打开 `macos` 输入 | 同上 | macos-15 上 `zig build test-lib-vt` 通过 | macOS app 构建（Xcode）、签名、公证与 app 交互 |
| macOS app 构建 | 手动运行 `gx-release`，打开 `macos` 输入（`publish=false` 只构建不发布） | 同上 | macos-15 上 `zig build -Doptimize=ReleaseFast` 产出只做 ad-hoc 签名的 `Ghostty.app`，以 artifact 形式保留 | GUI 行为、正式签名与公证；没有自动化的 macOS GUI 冒烟 |
| valgrind | `just zig build test-valgrind`、`just zig build run-valgrind` | Linux 与 valgrind，手动执行 | 单测或运行期没有 valgrind 能发现的内存错误（已知误报由 `valgrind.supp` 抑制） | 其他平台 |
| fuzz | 在 `test/fuzz-libghostty` 下 `zig build` 构建 harness（需要 `afl-cc`），再按该目录的 `AGENTS.md` 用 `zig build run-<name>` 跑 AFL++ | Linux 或 macOS 与 AFL++，手动执行 | 在给定语料和时长内没有发现崩溃 | 不存在崩溃的普遍结论 |
| esctest | 在 `test/esctest` 下 `zig build run`，比较输出里的通过计数 | Linux 或 macOS（运行器用 `forkpty` 拉起 `python3`），手动执行 | 同一环境下改动前后的一致性计数变化 | 不是通过门：上游许多用例本来就失败 |
| benchmark | `just build -Demit-bench -Doptimize=ReleaseFast`，用 hyperfine 对比（见 `src/benchmark/AGENTS.md`） | 手动执行，同一台机器、同一份输入；Linux 或 macOS（Windows 上编不出这些工具，见「Windows 本机限制」） | 声明条件下的耗时对比 | 普遍性能结论 |
| NixOS VM | 按 `HACKING.md` 运行 `nix run .#checks.<system>.<test-name>.driver`，全部用 `nix flake check` | Nix，手动执行 | `nix/tests.nix` 定义的 GUI 与集成场景 | 非 NixOS 环境 |
| 上游 lint | 按 `HACKING.md`「Linting」一节运行 prettier、alejandra、shellcheck、swiftlint | 对应工具，本机均未安装 | 文档、Nix、shell、Swift 符合上游 lint 规则 | fork CI 不跑这些检查；没实际跑过就不能声称通过 |

聚合入口：`just framework-check` = rules-check → version-check → framework-test → kb-check，不需要 Zig，本机约 15 s；`just ci-check` = framework-check → fmt-check → test-vt，提交前必跑，热缓存约 100 s，改过 Zig 源码另加约 2 min 编译（见下节）；`just generated-check` = kb-check → graph-check，上游同步后与发版前必跑。valgrind、fuzz、esctest、benchmark、NixOS VM 与上游 lint 是上游的手动流程，fork 不提供专门的 just 配方，也不进 CI。

示例、`test/fuzz-libghostty` 与 `test/esctest` 是各带 `build.zig` 的子工程，`just` 配方总在仓库根执行、进不了这些目录；表中子工程里的 `zig build …` 都在该目录用钉版 Zig 运行，即 `python ../../scripts/zigw.py build …`（Linux/macOS 用 `python3`）。

## 并行运行器与耗时

目标：热缓存下本机全量测试（Windows 上即 `just ci-check`）不超过 2 分钟；改过 Zig 源码时多出的约 2 分钟编译不在此列，原因见下。命令参数与退出码见 MAKE_COMMANDS.md。

**原理**：上游 `zig build test-lib-vt` 与 `zig build test` 让每个测试二进制在一个进程里逐条运行，多核基本闲置。fork 补丁 GX-0002 新增只编译、安装而不运行的步骤 `test-lib-vt-bin` 与 `test-bin`（见 FORK_PATCHES.md），`scripts/zig_test.py` 再按 Zig 测试运行器的 server 协议（`--listen=-`：先 `query_test_metadata` 取用例名，再逐条 `run_test`）把用例分到多个进程。全部用例排成一张任务表，按 `.local/test-timings/<label>.json`（`GX_ZIG_TEST_TIMINGS_DIR` 可换目录）从长到短分给 `--jobs` 个工作线程，每个线程对每个二进制复用一个测试进程；没有记录的用例按 0.1 s 估计，删掉缓存只改变调度顺序，不改变结论。每轮运行后把实测并入缓存；只有本轮由 `--suite` 构建、且 `-D` 与 `--zig-arg` 里都没有 `-Dtest-filter` 的完整二进制，才顺带删去二进制里已不存在的用例，`--no-build`、`--binary` 与带 `-Dtest-filter` 的运行只合并不删。用例崩溃或超时（单条默认 600 s）后，运行器为剩余用例重启进程。超时、崩溃与中断时，运行器在 POSIX 上杀掉测试进程所在的整个进程组，Windows 上在超时与中断时杀掉整个进程树；中断指 Ctrl+C，POSIX 上还包括 SIGTERM、SIGHUP，清理后退出 130（`scripts/run_unittests.py` 对 SIGTERM、SIGHUP 的处理相同）。

**判定**与 `zig build` 相同（`std/Build/Step/Run.zig::evalZigTest`）：先看 fail，再看内存泄漏（leak）与 error 日志（log_err）；skip 单列、不算失败；崩溃、超时与未运行都算失败。随机种子默认每轮随机，结论行总会打印 `seed 0x…`；有失败时还会打印一条可直接复制执行的复现命令：`python scripts/zig_test.py`，带上本次的 `--suite`/`--binary`、`-D`、`--zig-arg`、`--no-build` 与非默认的 `--timeout`，再加 `--seed 0x…` 与引好的 `--filter <用例全名>`。用例全名含空格，复现时原样执行这条命令，不经 just。怀疑运行器本身（分片、进程复用、执行顺序）影响结论时，用上表的上游串行路径对照。

**框架单测**：`scripts/run_unittests.py` 把每个 `TestCase` 类作为一个单元放进独立子进程，并发默认取逻辑核数与 8 的较小值——这些单元主要在起 git、bash、PowerShell 与 Python 子进程，Windows 上进程创建在少量并发时就饱和，再多只会互相拖慢。调度按 `.local/test-timings/unittest.json` 从慢到快，`RUN_LAST = True` 的类在其余单元全部启动后才启动（`scripts/test_ai_tool_hooks.py::WindowsEntryTests` 启动 Windows PowerShell 5.1，与其他单元同时跑会拖慢整机的进程创建）。子进程跑的测试数与发现阶段不符也记失败。

**实测**（本机 20 逻辑核、空闲、构建缓存命中）：

| 命令 | 规模与结果 | 墙钟 | 改造前 |
|---|---|---|---|
| `just test-vt` | 6655 条（vt 3096 + vt_c 3559）：6593 通过、62 跳过、0 失败 | 80.3 s，其中构建 0.6 s | `zig build test-lib-vt` 6–8 min |
| `just test-vt --dedupe` | vt_c 里与 vt 同名的用例不再运行 | 约 64 s | — |
| `just framework-test` | 79 个单元、约 500 个测试（两次实测 494、498 个） | 13.1 s、12.0 s | 串行 `python -m unittest discover` 约 62–87 s（当时 430 个测试） |
| `just ci-check` | framework-check 约 15 s → fmt-check 约 1 s → test-vt 约 81 s | 约 100 s | — |

- **下限**：各用例耗时合计约 1600 s（20 路并行下测得），1600 / 20 ≈ 80 s，所以 80 s 已接近 20 核的下限；最慢的单条用例 `terminal.Terminal.test.Terminal: printSlice differential fuzz vs print` 本机约 45–58 s，核数再多也快不过它。
- **`--dedupe`** 是覆盖取舍：vt_c 是同一模块以 `c_abi = true` 编译的测试二进制，同名用例在 C ABI 打开时再跑一遍，另有只在它里面的 `terminal.c.*`；去重后少了 C ABI 打开时的那一遍。默认关闭；用了就在结论里写明。
- **编译**：改过 Zig 源码后，`ghostty-vt`、`ghostty-vt-c` 两个 Debug 测试二进制都要用 LLVM 重新编译，两次编译并行，各约 2 min、约 6 GB 内存（RSS）。这段时间运行器省不掉：试过 Zig 自托管后端，它在 Windows 上编出的测试二进制无法运行。没改 Zig 源码时，`test-lib-vt-bin` 只做 1 秒内的缓存校验；运行器给测试构建钉 `-Dversion-string=<X.Y.Z>-dev+0000000`，否则版本串随提交哈希变化，每次提交都会让测试二进制整体重编。
- **CI**：`gx-ci` 的托管 runner 只有 4 个 vCPU，LLVM 编译测试二进制本身就要数分钟，用例也只能分 4 路，CI 达不到本机约 2 分钟的水平。旧布局首次运行墙钟约 22 min（旧 `linux` job 21.5 min、`windows` 19 min）；新布局把 Linux 拆成并行的 `linux-vt` 与 `linux-main` 并改用运行器，实际耗时以用户 push 后的首次运行为准，此前记 PENDING。缓存：`mlugg/setup-zig` 跨运行保存 Zig 缓存目录，目录超过 `cache-size-limit`（默认 2048 MiB）时会被清空。旧 `linux` job 的缓存目录约 2.99 GB，每次都被清空，Linux 从未命中热缓存；新布局给 `linux-main` 设 `cache-size-limit: 4096`（MiB），`lib-vt-cross` 矩阵按 target 各用自己的 `cache-key`，免得六个目标共用一份缓存；`linux-vt`、`linux-main`、`windows` 设 `GX_ZIG_TEST_TIMINGS_DIR=.zig-cache/gx-test-timings`，让运行器的耗时缓存随 Zig 缓存一起保存（否则 CI 每次都没有耗时记录，最慢的用例可能排到最后才开始）。热缓存能否命中要看第二次运行，同样记 PENDING。

## CI 覆盖与本机对应

`gx-ci.yml` 的触发：push 到 `gx_ghostty`、目标为 `gx_ghostty` 的 PR，以及手动 `workflow_dispatch`（可选输入 `gtk_smoke`、`macos`）。全局只有 `contents: read` 权限；同一 PR 的新运行会取消旧运行，push 与手动运行互不取消（每次 push 的提交标题都要校验）。`framework` 与 `zig-fmt` 并行先跑，其余 job 都等它们通过。CI 用 `mlugg/setup-zig` 把 Zig 放到 PATH 上：直接写的 `zig build …` 用它；两个运行器经 `scripts/zigw.py` 调用 Zig，zigw 在没有钉版目录时回退到 PATH 上的同一个 Zig（版本仍须等于 `scripts/setup_zig.py::ZIG_VERSION`）。

| job | 何时运行 | 内容 | 本机对应 |
|---|---|---|---|
| `framework` | 每次 | resolver `--check`、version `--check`、`python3 scripts/run_unittests.py`、kb-check、首父链提交标题校验（push 取 `before..after`，`before` 全零时只查 head；PR 取 `base..head`；手动触发只查 head）；不跑 graph-check | `just framework-check`；`just commit-check --range <base>..HEAD` |
| `zig-fmt` | 每次 | `zig fmt --check .` | `just fmt-check` |
| `linux-vt` | 每次 | 装 `python3-jsonschema` 后跑 `python3 scripts/zig_test.py --suite vt` 与 `zig build test-lib-vt-schema` | `just test-vt`；ABI 清单的本机前置见下文 |
| `linux-main` | 每次，与 `linux-vt` 并行 | `python3 scripts/zig_test.py --suite main -Dapp-runtime=none`；`setup-zig` 设 `cache-size-limit: 4096` | Linux/macOS 开发机上 `just test -Dapp-runtime=none`；Windows 上没有对应（`just test` 退出 2） |
| `lib-vt-cross` | 每次 | 六个目标各跑一次 `zig build -Demit-lib-vt -Dtarget=<triple>`（默认 Debug）：`x86_64-linux-gnu`、`aarch64-linux-gnu`、`x86_64-linux-musl`、`x86_64-windows-gnu`、`aarch64-macos`、`wasm32-freestanding`；`setup-zig` 的 `cache-key` 按 target 区分 | `just build-vt -Dtarget=<triple>`；`just vt-wasm` 是 ReleaseSmall 变体 |
| `windows` | 每次 | windows-2025 上关闭 `core.autocrlf` 后检出，跑 `python scripts/zig_test.py --suite vt`、`zig build -Demit-lib-vt`，再构建并运行 `example/c-vt-static` 的 `c_vt_static.exe`；pwsh 中每条原生命令后检查 `$LASTEXITCODE` | `just test-vt`、`just build-vt`、示例构建 |
| `gtk-smoke` | 仅手动触发且 `gtk_smoke` 为真 | debian:13 容器构建 GTK app，`xvfb-run` 截图，上传证据 artifact（保留 14 天） | 无，本机记 PENDING |
| `macos` | 仅手动触发且 `macos` 为真 | macos-15 上 `zig build test-lib-vt` | 无，本机记 PENDING |

`linux-vt`、`linux-main`、`windows` 三个测试 job 给运行器加 `--json "$RUNNER_TEMP/gx-zig-test/<job>.json"`；job 失败时把它上传为 artifact `gx-zig-test-<job>`（保留 14 天），里面有失败用例的全名、stderr 与本轮 seed；job 日志里还有运行器打印的完整复现命令（带着该 job 的 `--suite` 与 `-D`），在能编译该套件的本机上原样执行即可。

`gx-release.yml` 只能手动触发。它的 prepare 阶段强制 resolver `--check`、version `--check`、kb-check 与 graph-check，图谱或 KB 过期就拒绝发版；构建矩阵与发布步骤见 RELEASE.md。上游 15 个 workflow 原样归档在 `.github/workflows-archive/`，不会被触发，它们多数依赖上游专用的 namespace runner。

差异要点：图谱新鲜度只在发版与同步时检查，push CI 不查；完整单测（`linux-main`）、GTK、macOS 只有 CI 能证明；`gx-ci` 的结论要等用户 push 或手动触发后才有，此前一律 PENDING。

## Windows 本机限制

- 没有 GUI：GTK 与 macOS 相关验收在本机记 PENDING，不记 N/A，因为能力存在、只是本机缺环境。GTK 的补验是手动触发 `gx-ci` 的 `gtk-smoke` 并读回截图；macOS 只能用 `gx-ci` 的 `macos`（lib-vt 测试）或 `gx-release` 的 macOS 构建补证构建层面，GUI 行为仍是 PENDING。
- 非 vt 的 Zig 代码不能在 Windows 上编译：`src/build/SharedDeps.zig::add` 给每个经它装配的产物（libghostty-internal、`ghostty` exe、`ghostty-test`、`-Demit-bench` 的工具）无条件加上 translate-c 导入 `posix_c`（`errno.h`、`pwd.h`、`signal.h`、`sys/types.h`、`unistd.h`），MSVC 目标找不到 `pwd.h`。libghostty-vt 不经这条路径，不受影响。后果：
  - `just build`（含 `-Demit-bench` 等变体）退出 1：默认 `install` 要构建的 `ghostty-internal.dll` 与 `ghostty-internal-static.lib` 都停在 `translate-c posix_c.h`。Windows 上的库构建用 `just build-vt`。
  - `just test` 只要没加 `--no-build`，就在构建前以退出码 2 结束并说明原因（`scripts/zig_test.py::MAIN_SUITE_ON_WINDOWS`）。上游 `zig build test` 同样失败，上游 2026-08-28 起也不在 Windows 跑它（提交 `380778e3c` 移除了 `test-windows` job）。
  - 本机没有针对非 vt 代码的编译检查。这部分由 `gx-ci` 的 `linux-main`（`-Dapp-runtime=none` 编译并运行整个 `ghostty-test`）与 Linux/macOS 开发机覆盖，本机记 PENDING；只在 Windows 目标上才编译的非 vt 分支（如 ConPTY）在这两处都不会被分析，目前没有任何编译检查。
  - 本机能跑的全量是框架单测、`just fmt-check` 与 `just test-vt`（`just ci-check` 一次跑完）。
- 符号链接权限：`src/lib/tinyio` 的 `deleteFile edge cases` 与 `windows: realPath resolves through symlinks` 要创建符号链接。未开启开发者模式（也不是管理员）时它们以 `PRIVILEGE_NOT_HELD` → `PermissionDenied` 失败，每个用例在两个测试二进制里各失败一次，共 4 处。这是环境前置不满足，不是代码回归；记 FAIL 并注明原因，开启开发者模式后重跑。
- i18n 关闭：Windows 上 `zig build update-translations` 直接报错（构建脚本在 i18n 关闭时拒绝该步骤），翻译相关检查交给 Linux。
- `test-lib-vt-schema`：`build.zig` 用 `python3` 执行 `src/terminal/c/types-schema-verify.py`，缺 `jsonschema` 时脚本以「run this inside `nix develop`」退出。框架不代装这个依赖，缺失时记 PENDING，由 `gx-ci` 的 `linux-vt` job 补证。
- valgrind 与 AFL++ 只在 Linux、macOS 上可用；Nix VM 测试需要 Nix。
- 崩溃退出码：Git Bash 与 `zig build run` 会把 Windows 进程的 NTSTATUS 截成 8 位。要看原生程序的真实崩溃码，在 pwsh 里直接运行程序并读 `$LASTEXITCODE`（上游 Windows job 的做法）；`scripts/zig_test.py` 记 crash 时打印完整的 32 位退出码（如 `0xC0000005`）。
- 上游手测程序 `test/windows/test_dll_init.c` 用来验证 `ghostty-internal.dll` 的 CRT 初始化（步骤见 `test/windows/README.md`）。它要先构建这个 DLL，而 DLL 目前在 Windows 上编不出来（见上文），所以这条回归现在无法执行，记 PENDING 并注明受阻，不记 PASS 或 N/A。

## 故障注入预期

关键门必须被证明「会失败」。注入只在临时副本或临时输入上做：框架单测用临时目录；需要完整仓库时在 `.local/tmp/` 下建临时 clone。不要修改跟踪中的文件再事后还原。

| 注入 | 应失败的门 | 预期 |
|---|---|---|
| 新增一个没有路由覆盖的文件 | `just rules-check` | 退出 2，列出未覆盖文件 |
| 新增一份嵌套 `AGENTS.md` | `just rules-check` | 退出 2，指出实际集合与 `nested_agents` 不一致 |
| 改动 KB 语料（文档、公开签名、文档注释）但不重建 | `just kb-check` | 退出 1，列出变化来源；只改函数体时仍为 0 |
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
| 在 Windows 上跑完整单测 | `just test` | 构建之前退出 2，并说明 `ghostty-test` 不能为 Windows 编译 |
| 测试二进制报告失败、泄漏、error 日志、崩溃或挂起 | `scripts/test_zig_test.py` 的伪测试二进制（`just framework-test` 内） | 分别记 fail、leak、log_err、crash、timeout，运行器退出 1 |
| 框架单测失败、超时，或子进程跑的测试数与发现阶段不符 | `scripts/test_run_unittests.py` 的临时夹具（`just framework-test` 内） | `run_unittests.py` 退出 1；PATTERN 未命中时退出 2 |

## 证据规则

| 结论 | 条件 |
|---|---|
| PASS | 命令在声明的环境里实际跑完、退出码为 0，并能给出命令、提交、环境与输出位置；截图类验收还必须实际读过图 |
| FAIL | 实际跑了，但退出码非 0 或断言失败。保留输出，修复后复测，不覆盖失败记录 |
| PENDING | 需要验证但当前环境跑不了，例如本机没有 GUI、提交还没 push、CI 尚未首跑、客户端未安装。必须写明原因与补验命令 |
| N/A | 该能力本项目不存在，例如项目没有内置 AI，RuleManifest 记 N/A。必须写明理由，不能拿来掩盖缺环境 |

- 以退出码判定，不凭输出「看起来成功」。验收命令不接会吞退出码的管道：不写 `just test-vt | tail`、`| head`。需要留存输出时重定向到文件，再检查退出码：
  - Git Bash：`just test-vt > .local/test-vt.log 2>&1; echo $?`
  - PowerShell：每条原生命令后立即检查 `$LASTEXITCODE`，别让后一条的成功覆盖前一条的失败
  - cmd：`echo %ERRORLEVEL%`
- 定向测试要报告 filter 字符串、seed 和实际运行的用例数（运行器计数表的 `total` 列）。运行器零命中时退出 2，报错写明是运行期 `--filter` 没命中还是构建期 `-Dtest-filter` 裁掉了全部用例；走上游 `zig build` 路径时，filter 拼错可能一个测试都没跑也照样退出 0，所以要加 `--summary all` 核对，例如 `just zig build test-lib-vt -Dtest-filter=<名> --summary all`。
- 运行器的结论还要写明非默认参数：`--dedupe`、`--serial-filter`、`--jobs`、`--timeout`。需要留存结果时可加 `--json <文件>`（schema 见 `scripts/zig_test.py::build_report`）。
- 一层通过不证明另一层：test-vt 通过不等于完整单测通过；交叉编译通过不等于该目标上能运行；Windows 通过不等于 Linux 通过；artifact 存在不等于截图验收通过。
- 必要工具缺失时，不得整族跳过后报绿，记 PENDING。
- CI 结论要引用具体运行：workflow、run、job 与提交 SHA。本地 `actionlint` 只证明 workflow 语法，不证明 job 能通过。
