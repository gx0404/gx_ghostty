# testing：测试分层、覆盖面与测试纪律

## 范围

- `test/**`：`esctest/`（esctest2 一致性运行器）、`fuzz-libghostty/`（AFL++ harness 与语料）、`windows/`（Windows 手测程序）、`ucs-detect.sh`、`wasm-alloc.mjs`。
- 基准与合成数据：`src/benchmark/**`、`src/synthetic/**`、`src/main_bench.zig`、`src/main_gen.zig`、`src/build/GhosttyBench.zig`；以及 `pkg/afl++/**`、`valgrind.supp`、`nix/tests.nix`、`nix/vm/**`、`nix/test-src/**`。
- `--task test`：写、改、跑测试或报告测试结论的任务都加载本文档。各域的定向测试见对应领域文档的「验证」段；完整分层表、CI 对照、证据分级与故障注入的人读版在 `docs/TESTING.md`。

## 符号真源

- Zig 单测与实现写在同一文件（`test` 块），由两个互不包含的入口收集：`build.zig::build` 的 `test`（根 `src/main.zig`，经 `src/main_ghostty.zig` 末尾的 `test` 块引入各子系统，含 `benchmark/` 与 `synthetic/`）和 `test-lib-vt`（`src/build/GhosttyZig.zig::init` 的 `ghostty-vt`、`ghostty-vt-c` 两个模块）。`-Dtest-filter` 按测试名过滤，可重复。
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
| 框架单测 | `just framework-test` | 脚本、hook、workflow 形状、版本与补丁标记的契约 / 任何 Zig 行为 | `framework` | 可跑 |
| 格式 | `just fmt-check` | 符合 `zig fmt` / 能否编译 | `zig-fmt` | 可跑 |
| lib-vt 单测 | `just test-vt` | vt 两个模块的单测 / app、渲染、字体、apprt | `linux`、`windows`；`macos` 仅 dispatch | 可跑，主力 |
| 完整单测 | `just test` | `src/main.zig` 根的单测（Debug、baseline CPU）/ test-lib-vt；`-Dapp-runtime=none` 时不含 GTK apprt | `linux`（`-Dapp-runtime=none`） | 尽力而为 |
| ABI 清单 | `just zig build test-lib-vt-schema` | 导出清单符合 schema / 头文件声明 | `linux` | 需 `python3` 与 `jsonschema` |
| 构建与交叉 | `just build-vt`、`just vt-wasm`、`just build-vt -Dtarget=<triple>` | 能编译链接 / 目标上的运行 | `lib-vt-cross` | 可跑 |
| 示例 | `example/<dir>` 下 `zig build` | 消费方能按示例链接 / 其他示例 | `windows` 仅 `c-vt-static` | 可跑 |
| GTK 冒烟 | 手动触发 `gx-ci`，`gtk_smoke` 为真 | 能构建、在 Xvfb 下启动并截图 / Wayland、IME、真实桌面 | 仅 dispatch | 不可，记 PENDING |
| valgrind | `just zig build test-valgrind` | 运行期内存错误 / 其他平台 | 无 | 不可 |
| fuzz | `test/fuzz-libghostty` 下 `zig build run-<name>` | 给定语料与时长内无崩溃 / 不存在崩溃 | 无 | 不可（AFL++） |
| esctest | `test/esctest` 下 `zig build run` | 一致性计数 / 不是通过门 | 无 | 不可（`forkpty`） |
| 基准 | `just build -Demit-bench -Doptimize=ReleaseFast` 后用 hyperfine | 同机同输入的耗时对比 / 正确性 | 无 | 未验证 |
| NixOS VM | `nix run .#checks.<system>.<test>.driver` | GUI 与 ssh 集成 / 非 NixOS 环境 | 无 | 不可 |

## 不变量

### 选择与报告

- 先跑覆盖改动的最窄一层，再放宽；层与层互不代证：test-vt 不代完整单测，交叉编译不代运行，Windows 不代 Linux，artifact 存在不代截图验收。
- 定向运行要报告 filter 字符串与实际运行的测试数。filter 拼错时可能一个测试都没跑也照样成功，所以加 `--summary all` 核对，如 `just test-vt -Dtest-filter=<名> --summary all`。
- 以退出码判定，验收命令不接 `| tail`、`| head`；必要工具缺失时记 PENDING 并附补验命令，不能整族跳过后报绿。PASS、FAIL、PENDING、N/A 的判据见 `docs/TESTING.md`。
- Windows 完整 `just test`：上游提交 `380778e3c`（2026-08-28）删除了 `test-windows` job，此后上游只在 Windows 验证 lib-vt。本机结果如实记 PASS 或 FAIL 并注明「Windows 本机」；失败先分清是 Windows 特有问题还是回归，Linux 结论以 gx-ci `linux` job 为准。`src/lib/tinyio/test.zig` 与 `src/lib/tinyio/windows.zig` 的符号链接用例需要 Windows 开发者模式（或管理员），缺权限时报 `PermissionDenied`，属环境前置，不得为此跳过或改用例。
- GUI 可见变更：本机没有 Ghostty GUI，记 PENDING 而不是 N/A；用户 push 后手动触发 `gx-ci` 的 `gtk-smoke`，下载 `gx-gtk-smoke-evidence` artifact 并实际读图后才记 PASS。

### 新测试

- 修 bug 先写修复前会失败的用例；新行为覆盖错误路径；分配一律经 `std.testing.allocator`，让泄漏直接失败。
- 测试确定：不联网，不依赖墙钟与执行顺序，随机输入用固定种子（如 `src/synthetic/Osc.zig` 的 `test_seed`）；测试不向 stderr 输出。
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
- 手测程序 `test/windows/test_dll_init.c`（`ghostty-internal.dll` 的 CRT 初始化回归）与 `test/ucs-detect.sh`（Unicode 宽度对照）按各自说明执行，结果写进交付说明。

## 禁止项

- 不并行跑基准，不把 `ghostty-gen` 的输出直接管给 `ghostty-bench` 做对比。
- 不提交 `afl-out/`、基准数据或大语料；没有明确要求时不跑 `afl-tmin`；不为让测试通过删改既有语料或 fixture。
- 不对 `afl-showmap`、`afl-cmin`、`afl-tmin` 用 `@@`（harness 从 stdin 读）。
- 不用缩小 filter、跳过用例或放宽断言把失败变绿；Windows 上完整测试只编译成功不记 PASS。
- 测试不联网，不写真实仓库与用户目录；框架测试只用临时目录。

## 验证

- 改 `src/benchmark/**` 或 `src/synthetic/**`：`just test -Dtest-filter=<模块测试名>`，再 `just build -Demit-bench -Doptimize=ReleaseFast` 确认工具能构建。
- 改 `test/fuzz-libghostty/**` 或 `pkg/afl++/**`：在装好 AFL++ 的 Linux/macOS 上到 `test/fuzz-libghostty` 下 `zig build`（上游 CI 也只构建 harness）；本机记 PENDING。
- 改 `test/esctest/**`：Linux/macOS 上到 `test/esctest` 下 `zig build run > esctest.log`，对比 `tests passed` 计数；本机记 PENDING。
- 改 `valgrind.supp`：Linux 上 `just zig build test-valgrind`；本机记 PENDING。
- 改 `nix/tests.nix` 或 `nix/vm/**`：Nix 主机上 `nix flake check`，或按 `HACKING.md` 运行单个 `.driver`。
- 改测试本身：确认修复前失败、修复后通过，收尾 `just ci-check`。

## 上游指令

- `test/fuzz-libghostty/AGENTS.md`：AFL++ 构建、`run-<name>`、语料命名、stdin 输入与崩溃回放。
- `src/benchmark/AGENTS.md`：`ghostty-gen` 与 `ghostty-bench` 的分工、hyperfine 对比、构建参数与禁止并行。
- `example/AGENTS.md`：示例工程（分层表中的「示例」）的模板与约定。
