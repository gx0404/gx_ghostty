# testing：测试分层、覆盖面与测试纪律

## 范围

- `test/**`：`esctest/`（esctest2 一致性运行器）、`fuzz-libghostty/`（AFL++ harness 与语料）、`windows/`（Windows 手测程序）、`ucs-detect.sh`、`wasm-alloc.mjs`。
- 基准与合成数据：`src/benchmark/**`、`src/synthetic/**`、`src/main_bench.zig`、`src/main_gen.zig`、`src/build/GhosttyBench.zig`；以及 `pkg/afl++/**`、`valgrind.supp`、`nix/tests.nix`、`nix/vm/**`、`nix/test-src/**`。
- 运行入口：并行测试运行器 `scripts/zig_test.py` 与 WSL 驱动 `scripts/gx_wsl.py`（`just wsl`，在 Windows 上经 WSL 跑 Linux 构建、完整单测与 Xvfb 截图），两者的测试同在本域（脚本约定见 `development.md`）。
- `--task test`：写、改、跑测试或报告测试结论的任务都加载本文档。各域的定向测试见对应领域文档的「验证」段；完整分层表、CI 对照、证据分级与故障注入的人读版在 `docs/TESTING.md`。

## 符号真源

- Zig 单测与实现写在同一文件（`test` 块），由两个互不包含的入口收集：`build.zig::build` 的 `test`（根 `src/main.zig`，经 `src/main_ghostty.zig` 末尾的 `test` 块引入各子系统，含 `benchmark/` 与 `synthetic/`）和 `test-lib-vt`（`src/build/GhosttyZig.zig::init` 的 `ghostty-vt`、`ghostty-vt-c` 两个模块，后者以 `c_abi = true` 编译）。`-Dtest-filter` 按测试名过滤，可重复。
- 运行方式：`just test-vt`、`just test` 经 `scripts/zig_test.py` 运行这两组测试；Windows 主机上 `just test` 给 `test-bin` 补 `-Dapp-runtime=win32 -Dtarget=x86_64-windows-gnu`（`scripts/zig_test.py::MAIN_SUITE_ON_WINDOWS`，同名 `-D` 选项以使用者为准）。fork 补丁 GX-0002 的 `test-lib-vt-bin`、`test-bin` 只编译并把二进制装到 `zig-out/test/`，运行器按 Zig 测试运行器协议（`--listen=-`）取用例名，把用例分片到多个进程，判定照搬 `std/Build/Step/Run.zig::evalZigTest`。`--filter` 是运行期子串过滤，不重编；`-Dtest-filter` 是编译期裁剪，换值即重编。上游 `zig build test-lib-vt`、`zig build test` 是串行对照路径。参数、耗时与退出码见 `docs/MAKE_COMMANDS.md` 与 `docs/TESTING.md`。
- `src/main.zig` 的 `test` 块把测试日志级别压到 `err`：Zig 0.16 下测试只要写了 stderr，即使全部通过也会报「failed command」。
- 失败注入用 `src/tripwire.zig`（覆盖 `errdefer` 路径），泄漏检测用 `std.testing.allocator`；ABI 清单测试见 `libghostty-vt.md`。
- fuzz：`test/fuzz-libghostty/build.zig::fuzzers`（`osc`、`parser`、`stream`），`Fuzzer.corpus` 让 `run-<name>` 以 `corpus/<name>-cmin` 为输入；harness 在 `pkg/afl++`（`afl.c` 从 stdin 读输入）；崩溃回放用 `test/fuzz-libghostty/replay-crashes.nu`。
- esctest：`test/esctest/build.zig`（esctest2 钉在同目录的 `build.zig.zon`），运行器 `test/esctest/src/main.zig` 经 `forkpty` 拉起 `python3` 版 esctest，把输出喂给 libghostty-vt 的 `Terminal`。
- 基准：`src/build/GhosttyBench.zig::init` 产出 `ghostty-gen` 与 `ghostty-bench`，根模块固定 ReleaseFast；动作表 `src/synthetic/cli.zig::Action`、`src/benchmark/cli.zig::Action`，命令行用 `+<动作>` 选择（`src/cli/action.zig::detectIter`）。
- 其他：`valgrind.supp` 供 `test-valgrind` 与 `run-valgrind` 使用；`nix/tests.nix` 定义 NixOS VM 测试（如 `basic-version-check`、`basic-window-check-gnome`、`ssh-integration-test`）；`nix/libghostty-vt.nix` 的 `passthru.tests` 用到 `nix/test-src/test_libghostty_vt.c`；框架单测是 `scripts/test_*.py`。
- 子工程 `example/<dir>`、`test/esctest`、`test/fuzz-libghostty` 各有自己的 `build.zig`，经 `../../` 路径依赖本仓；下文的 `zig build` 指在该目录用钉版 Zig 运行，即 `python ../../scripts/zigw.py build …`（Linux/macOS 用 `python3`）。

### 分层与覆盖

| 层 | 入口 | 能证明 / 不能代证 | gx-ci | 本机 Windows |
|---|---|---|---|---|
| 框架单测 | `just framework-test`（`scripts/run_unittests.py`） | 脚本、hook、workflow 形状、版本与补丁标记的契约 / 任何 Zig 行为 | `framework` | 可跑 |
| 格式 | `just fmt-check` | 符合 `zig fmt` / 能否编译 | `zig-fmt` | 可跑 |
| lib-vt 单测 | `just test-vt` | vt 两个模块的单测 / app、渲染、字体、apprt | `linux-vt`、`windows`；`macos` 仅 dispatch | 可跑，主力 |
| 完整单测 | `just test`；Linux 用 `just wsl test` | `src/main.zig` 根的单测（Debug、baseline CPU）/ test-lib-vt、macOS app 的 `xcodebuild test`；只编译所选 apprt 与目标平台的分支（`-Dapp-runtime=none` 不含 GTK，Windows 构建不含 POSIX 分支） | `linux-main`（`-Dapp-runtime=none`） | 可跑：win32 + windows-gnu，2026-10 本机 4133 条，热缓存约 45 s |
| 上游串行对照 | `just zig build test-lib-vt` | 同一批用例在单进程逐条运行也通过，排除运行器的影响 / 同 lib-vt 单测 | 无 | 可跑，6–8 min |
| ABI 清单 | `just zig build test-lib-vt-schema` | 导出清单符合 schema / 头文件声明 | `linux-vt` | 需 `python3` 与 `jsonschema` |
| 构建与交叉 | `just build-vt`、`just vt-wasm`、`just build-vt -Dtarget=<triple>` | 能编译链接 / 目标上的运行 | `lib-vt-cross` | 可跑 |
| 示例 | `example/<dir>` 下 `zig build` | 消费方能按示例链接 / 其他示例 | `windows` 仅 `c-vt-static` | 可跑 |
| GTK 冒烟 | `just wsl smoke --out <目录>`；手动触发 `gx-ci`，`gtk_smoke` 为真 | 能构建、在 Xvfb 下启动并截图 / Wayland、IME、真实桌面 | 仅 dispatch | 经 WSL 可跑 |
| Windows GUI | `just build` 后按 `apprt-win32.md` 隔离启动、自动化操作并截图；`gx-ci` 的 `win_smoke` | 真实窗口、chrome、弹层、IME 与渲染效果 / GTK 与 Linux | `windows-app` 构建；截图仅 dispatch | 可跑 |
| valgrind | `just zig build test-valgrind` | 运行期内存错误 / 其他平台 | 无 | 不可 |
| fuzz | `test/fuzz-libghostty` 下 `zig build run-<name>` | 给定语料与时长内无崩溃 / 不存在崩溃 | 无 | 不可（AFL++） |
| esctest | `test/esctest` 下 `zig build run` | 一致性计数 / 不是通过门 | 无 | 不可（`forkpty`） |
| 基准 | `just build -Demit-bench -Doptimize=ReleaseFast` 后用 hyperfine | 同机同输入的耗时对比 / 正确性 | 无 | 可构建（2026-10 本机实测） |
| NixOS VM | `nix run .#checks.<system>.<test>.driver` | GUI 与 ssh 集成 / 非 NixOS 环境 | 无 | 不可 |

## 不变量

### 选择与报告

- 先跑覆盖改动的最窄一层，再放宽；层与层互不代证：test-vt 不代完整单测，交叉编译不代运行，Windows 不代 Linux，artifact 存在不代截图验收。
- 定向运行用 `just test-vt --filter <子串>` 或 `just test --filter <子串>`，报告 filter、seed 与运行器计数表里的实际用例数；零命中时运行器退出 2，报错写明是运行期 `--filter` 没命中还是构建期 `-Dtest-filter` 裁掉了全部用例。走上游 `zig build` 路径（`-Dtest-filter`）时零命中照样退出 0，要加 `--summary all` 核对。
- 非默认参数写进结论：`--dedupe` 少跑 C ABI 打开时的那一遍，`--serial-filter`、`--jobs`、`--timeout` 改变调度或时限。失败先原样执行结论行之后打印的完整复现命令（`python scripts/zig_test.py`，带本次的 `--suite`/`--binary`、`-D`、`--zig-arg`、`--no-build` 与非默认的 `--timeout`，加 `--seed 0x…` 与引好的 `--filter <用例全名>`）定向复现；用例名含空格，这条命令不经 just，也不要把其中的参数接在 just 后面。怀疑分片、进程复用或执行顺序影响结论时用上游串行路径对照，两边不一致要写进交付说明。
- 以退出码判定，验收命令不接 `| tail`、`| head`；必要工具缺失时记 PENDING 并附补验命令，不能整族跳过后报绿。PASS、FAIL、PENDING、N/A 的判据见 `docs/TESTING.md`。
- 平台互不代证：Windows 上的 `just test` 只编译 Windows 分支与 win32 apprt，Linux 上的只编译 POSIX 分支；改平台相关代码时 Windows 跑 `just test`，Linux 跑 `just wsl test`（或以 gx-ci 的 `linux-main` 为证据）。`src/lib/tinyio/test.zig` 与 `src/lib/tinyio/windows.zig` 的符号链接用例需要 Windows 开发者模式（或管理员），缺权限时报 `PermissionDenied`（`just test-vt` 4 处、`just test` 2 处），属环境前置：记 FAIL 并写明原因，不跳过、不改用例。
- GUI 可见变更必须有读过的截图才记 PASS，不记 N/A：win32 按 `apprt-win32.md` 在本机隔离启动并截图；GTK 用 `just wsl smoke --out <目录>`，或用户 push 后手动触发 `gx-ci` 的 `gtk-smoke` 并下载 `gx-gtk-smoke-evidence`；macOS 没有本机条件，记 PENDING。

### 新测试

- 修 bug 先写修复前会失败的用例；新行为覆盖错误路径；分配一律经 `std.testing.allocator`，让泄漏直接失败。
- 测试确定：不联网，不依赖墙钟与执行顺序，随机输入用固定种子（如 `src/synthetic/Osc.zig` 的 `test_seed`）；测试不向 stderr 输出。
- 并行安全：运行器按耗时从长到短跨多个进程调度，同一进程里先后跑的是互不相关的用例。用例不得依赖同一二进制里其他用例的副作用或声明顺序；争用同一外部资源（固定路径的文件、环境变量、当前目录）的用例各自隔离（如用临时目录），不靠 `--serial-filter` 掩盖冲突。
- `error.SkipZigTest` 只用于缺运行环境（如 GTK 无法初始化），条件写死在测试里；不为让红灯变绿而跳过。
- 改 lib-vt 的 C ABI 时加跑 ABI 清单与相关示例（`libghostty-vt.md`）。

### fuzz 语料

- `corpus/<fuzzer>-initial/` 是手写种子，`corpus/<fuzzer>-cmin/` 是 `afl-cmin` 的输出，也是 `run-<name>` 的输入；用法与 stdin 约束以 `test/fuzz-libghostty/AGENTS.md` 为准。
- `afl-cmin` 之后先跑 `test/fuzz-libghostty/corpus/sanitize-filenames.sh` 把冒号换成下划线；它默认只处理 `parser-cmin` 与 `stream-cmin`，osc 语料要显式传 `osc-cmin`。
- `afl-out/` 与 `corpus/**/.traces/` 已被忽略。修崩溃时把复现输入写成对应模块的单测，不只靠语料。
- 本机 `core.autocrlf=true`：新种子提交前用 `git ls-files --eol` 确认为 `-text`；`test/fuzz-libghostty/.gitattributes` 只把 parser 与 stream 目录标成 binary。
- 上游误入库的 `test/fuzz-libghostty/.afl-tmin-temp-37266` 属上游内容，不顺手删除。

### 基准与合成数据

- 流程以 `src/benchmark/AGENTS.md` 为准：先生成数据，再对同一份文件测；同一台机器上不并行跑多个基准。
- `ghostty-gen` 的通用入口以当前时间为种子（`src/synthetic/cli.zig::mainActionImpl`），只有 `+styled` 与 `+utf8` 接受 `--seed`。可复现的数据要么用这两个生成器加固定种子，要么生成一次保存后复用。生成器无限输出，用 `head -c <字节数>` 截断，大语料放仓库外。
- 动作名带 `+` 前缀，如 `ghostty-gen +styled --seed=42`、`ghostty-bench +terminal-stream --data=<文件>`。

### esctest、valgrind 与手测

- esctest 只报告：上游 CI 中它 `continue-on-error`，许多用例本来就失败（libghostty-vt 不实现 DECSTR，终端也不随 XTWINOPS、DECCOLM 改尺寸）。只比较同一环境下改动前后的通过计数。
- `valgrind.supp` 只为已知的第三方误报加条目，并附复现说明；不能用抑制规则掩盖 Ghostty 自身的泄漏。
- 手测程序 `test/ucs-detect.sh`（Unicode 宽度对照）按其说明执行，结果写进交付说明。`test/windows/test_dll_init.c`（`ghostty-internal.dll` 的 CRT 初始化回归）要先构建这个 DLL，而它目前在 Windows 上链接失败（`build-system.md`「平台」），这条回归无法执行：记 PENDING 并注明受阻，不记 PASS 或 N/A。

## 禁止项

- 不并行跑基准，不把 `ghostty-gen` 的输出直接管给 `ghostty-bench` 做对比。
- 不提交 `afl-out/`、基准数据或大语料；没有明确要求时不跑 `afl-tmin`；不为让测试通过删改既有语料或 fixture。
- 不对 `afl-showmap`、`afl-cmin`、`afl-tmin` 用 `@@`（harness 从 stdin 读）。
- 不用缩小 filter、`--dedupe`、跳过用例或放宽断言把失败变绿；`test-lib-vt-bin`、`test-bin` 只编译不运行，它们成功不记测试 PASS。
- 测试不联网，不写真实仓库与用户目录；框架测试只用临时目录。

## 验证

- 改 `src/benchmark/**` 或 `src/synthetic/**`：`just test --filter <模块测试名>`，再 `just build -Demit-bench -Doptimize=ReleaseFast` 确认工具能构建（Windows 本机冷缓存约 4 min）。
- 改 `scripts/zig_test.py` 或 `scripts/gx_wsl.py`：`python scripts/run_unittests.py test_zig_test test_gx_wsl`，再真实跑一次 `just test-vt` 与 `just test`（WSL 驱动另跑 `just wsl test --filter <名>`），核对计数表。
- 改 `test/fuzz-libghostty/**` 或 `pkg/afl++/**`：在装好 AFL++ 的 Linux/macOS 上到 `test/fuzz-libghostty` 下 `zig build`（上游 CI 也只构建 harness）；本机记 PENDING。
- 改 `test/esctest/**`：Linux/macOS 上到 `test/esctest` 下 `zig build run > esctest.log`，对比 `tests passed` 计数；本机记 PENDING。
- 改 `valgrind.supp`：Linux 上 `just zig build test-valgrind`；本机记 PENDING。
- 改 `nix/tests.nix` 或 `nix/vm/**`：Nix 主机上 `nix flake check`，或按 `HACKING.md` 运行单个 `.driver`。
- 改测试本身：确认修复前失败、修复后通过，收尾 `just ci-check`。

## 上游指令

- `test/fuzz-libghostty/AGENTS.md`：AFL++ 构建、`run-<name>`、语料命名、stdin 输入与崩溃回放。
- `src/benchmark/AGENTS.md`：`ghostty-gen` 与 `ghostty-bench` 的分工、hyperfine 对比、构建参数与禁止并行。
- `example/AGENTS.md`：示例工程（分层表中的「示例」）的模板与约定。
