# 测试与证据（gx_ghostty）

每一层都要写清楚能证明什么、不能代证什么。不同层不能互相顶替，Windows 本机的结果也不能顶替 Linux 或 macOS。命令细节见 [MAKE_COMMANDS.md](MAKE_COMMANDS.md)，九步闭环见 [DEVELOPMENT.md](DEVELOPMENT.md)，测试相关的领域规则见 `docs/AGENT_RULES/testing.md`。

## 分层

| 层 | 命令 | 前置 | 能证明 | 不能代证 |
|---|---|---|---|---|
| 框架单测 | `just framework-test` | Python ≥ 3.10 | resolver、hook 允许与拒绝探针、版本、提交规范、zigw 与 setup、发布脚本、workflow 形状与启用集合、KB 检索回归、图谱指纹、fork 补丁标记等框架契约 | 任何 Zig 产品行为；AI 客户端的新会话是否真的加载了配置（见 AI_TOOLS.md 验证账本） |
| 规则闭集 | `just rules-check` | Python、Git | 每个 Git 可见文件都有路由、pattern 无零命中、与 `root_only` 不重叠；嵌套 `AGENTS.md` 与登记一致；领域文档闭集与体积；根 `AGENTS.md` ≤16 KiB 且含 fork 标记 | 规则内容是否与源码一致，这要靠复审 |
| 版本格式 | `just version-check` | Python | `CHANGELOG.md` 标题都合法、至少有一个，可以取出最大 SemVer | 能否发版：`gx-release` 以 `publish=true` 运行时，prepare 另要求最大版本已带日期 |
| KB 新鲜度 | `just kb-check` | Python | `docs/kb/chunks.json` 与当前语料一致 | 文档内容是否正确 |
| 图谱新鲜度 | `just graph-check` | Python；不需要本机 `graph.json` | 被索引源码、管线脚本与入库报告的指纹一致 | 图谱质量；它不在 framework-check、ci-check 与 push CI 里 |
| Zig 格式 | `just fmt-check` | 钉版 Zig（`just setup`） | 全仓 `.zig` 文件符合 `zig fmt`（排除 `.local`、`zig-pkg`、`zig-out`、`.zig-cache`） | 能否编译，行为是否正确 |
| libghostty-vt 单测 | `just test-vt`，可加 `-Dtest-filter=<名>` | Zig；Windows 需 MSVC | 以 `src/lib_vt.zig` 为根的 Zig 模块与 C API 模块的单测在本机目标上通过 | ABI 清单、其他目标、完整单测（`zig build test` 不包含 test-lib-vt，反之亦然） |
| ABI 清单 | `just zig build test-lib-vt-schema` | Zig；PATH 上的 `python3` 是真实解释器且装有 `jsonschema`，wasm 目标还要 `wasmtime`（上游靠 `nix develop` 提供） | 本次构建出的共享库导出的类型清单符合 `src/terminal/c/types.schema.json` | 运行时行为 |
| 完整 Zig 单测 | `just test`，可加 `-Dtest-filter=<名>` | Zig；以 Linux、macOS 为准，Windows 尽力而为 | 以 `src/main.zig` 为根的 `ghostty-test` 单测 | libghostty-vt 单测、GUI 行为；Windows 上的结果不代表 Linux |
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
| benchmark | `just build -Demit-bench -Doptimize=ReleaseFast`，用 hyperfine 对比（见 `src/benchmark/AGENTS.md`） | 手动执行，同一台机器、同一份输入 | 声明条件下的耗时对比 | 普遍性能结论 |
| NixOS VM | 按 `HACKING.md` 运行 `nix run .#checks.<system>.<test-name>.driver`，全部用 `nix flake check` | Nix，手动执行 | `nix/tests.nix` 定义的 GUI 与集成场景 | 非 NixOS 环境 |
| 上游 lint | 按 `HACKING.md`「Linting」一节运行 prettier、alejandra、shellcheck、swiftlint | 对应工具，本机均未安装 | 文档、Nix、shell、Swift 符合上游 lint 规则 | fork CI 不跑这些检查；没实际跑过就不能声称通过 |

聚合入口：`just framework-check` = rules-check → version-check → framework-test → kb-check，不需要 Zig；`just ci-check` = framework-check → fmt-check → test-vt，提交前必跑；`just generated-check` = kb-check → graph-check，上游同步后与发版前必跑。valgrind、fuzz、esctest、benchmark、NixOS VM 与上游 lint 是上游的手动流程，fork 不提供专门的 just 配方，也不进 CI。

示例、`test/fuzz-libghostty` 与 `test/esctest` 是各带 `build.zig` 的子工程，`just` 配方总在仓库根执行、进不了这些目录；表中子工程里的 `zig build …` 都在该目录用钉版 Zig 运行，即 `python ../../scripts/zigw.py build …`（Linux/macOS 用 `python3`）。

## CI 覆盖与本机对应

`gx-ci.yml` 的触发：push 到 `gx_ghostty`、目标为 `gx_ghostty` 的 PR，以及手动 `workflow_dispatch`（可选输入 `gtk_smoke`、`macos`）。全局只有 `contents: read` 权限；同一 PR 的新运行会取消旧运行，push 与手动运行互不取消（每次 push 的提交标题都要校验）。`framework` 与 `zig-fmt` 并行先跑，其余 job 都等它们通过。CI 用 `mlugg/setup-zig` 提供 PATH 上的 Zig，不经 `zigw.py`。

| job | 何时运行 | 内容 | 本机对应 |
|---|---|---|---|
| `framework` | 每次 | resolver `--check`、version `--check`、框架 unittest、kb-check、首父链提交标题校验（push 取 `before..after`，`before` 全零时只查 head；PR 取 `base..head`；手动触发只查 head）；不跑 graph-check | `just framework-check`；`just commit-check --range <base>..HEAD` |
| `zig-fmt` | 每次 | `zig fmt --check .` | `just fmt-check` |
| `linux` | 每次 | 装 `python3-jsonschema` 后跑 `zig build -Dapp-runtime=none test`、`zig build test-lib-vt`、`zig build test-lib-vt-schema` | 无法等价复现；Windows 上 `just test` 只是尽力而为 |
| `lib-vt-cross` | 每次 | 六个目标各跑一次 `zig build -Demit-lib-vt -Dtarget=<triple>`（默认 Debug）：`x86_64-linux-gnu`、`aarch64-linux-gnu`、`x86_64-linux-musl`、`x86_64-windows-gnu`、`aarch64-macos`、`wasm32-freestanding` | `just build-vt -Dtarget=<triple>`；`just vt-wasm` 是 ReleaseSmall 变体 |
| `windows` | 每次 | windows-2025 上关闭 `core.autocrlf` 后检出，跑 `zig build test-lib-vt`、`zig build -Demit-lib-vt`，再构建并运行 `example/c-vt-static` 的 `c_vt_static.exe`；pwsh 中每条原生命令后检查 `$LASTEXITCODE` | `just test-vt`、`just build-vt`、示例构建 |
| `gtk-smoke` | 仅手动触发且 `gtk_smoke` 为真 | debian:13 容器构建 GTK app，`xvfb-run` 截图，上传证据 artifact（保留 14 天） | 无，本机记 PENDING |
| `macos` | 仅手动触发且 `macos` 为真 | macos-15 上 `zig build test-lib-vt` | 无，本机记 PENDING |

`gx-release.yml` 只能手动触发。它的 prepare 阶段强制 resolver `--check`、version `--check`、kb-check 与 graph-check，图谱或 KB 过期就拒绝发版；构建矩阵与发布步骤见 RELEASE.md。上游 15 个 workflow 原样归档在 `.github/workflows-archive/`，不会被触发，它们多数依赖上游专用的 namespace runner。

差异要点：图谱新鲜度只在发版与同步时检查，push CI 不查；Linux 完整测试、GTK、macOS 只有 CI 能证明；`gx-ci` 的结论要等用户 push 或手动触发后才有，此前一律 PENDING。

## Windows 本机限制

- 没有 GUI：GTK 与 macOS 相关验收在本机记 PENDING，不记 N/A，因为能力存在、只是本机缺环境。GTK 的补验是手动触发 `gx-ci` 的 `gtk-smoke` 并读回截图；macOS 只能用 `gx-ci` 的 `macos`（lib-vt 测试）或 `gx-release` 的 macOS 构建补证构建层面，GUI 行为仍是 PENDING。
- 完整 `zig build test`：上游 2026-08-28 起不在 Windows 运行（提交 `380778e3c` 移除了 `test-windows` job）。本机 `just test` 是尽力而为，结果如实记 PASS 或 FAIL，并注明「Windows 本机」。
- 符号链接权限：`src/lib/tinyio` 的 `deleteFile edge cases` 与 `windows: realPath resolves through symlinks` 要创建符号链接。未开启开发者模式（也不是管理员）时它们以 `PRIVILEGE_NOT_HELD` → `PermissionDenied` 失败，每个用例在两个测试二进制里各失败一次，共 4 处。这是环境前置不满足，不是代码回归；记 FAIL 并注明原因，开启开发者模式后重跑。
- i18n 关闭：Windows 上 `zig build update-translations` 直接报错（构建脚本在 i18n 关闭时拒绝该步骤），翻译相关检查交给 Linux。
- `test-lib-vt-schema`：`build.zig` 用 `python3` 执行 `src/terminal/c/types-schema-verify.py`，缺 `jsonschema` 时脚本以「run this inside `nix develop`」退出。框架不代装这个依赖，缺失时记 PENDING，由 `gx-ci` 的 `linux` job 补证。
- valgrind 与 AFL++ 只在 Linux、macOS 上可用；Nix VM 测试需要 Nix。
- 崩溃退出码：Git Bash 与 `zig build run` 会把 Windows 进程的 NTSTATUS 截成 8 位。要看原生程序的真实崩溃码，在 pwsh 里直接运行程序并读 `$LASTEXITCODE`（上游 Windows job 的做法）。
- 上游手测程序 `test/windows/test_dll_init.c` 用来验证 `ghostty-internal.dll` 的 CRT 初始化，步骤见 `test/windows/README.md`。

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
- 定向测试要报告 filter 字符串和实际运行的测试数。filter 拼错时可能一个测试都没跑也照样退出 0，所以加 `--summary all` 核对，例如 `just test-vt -Dtest-filter=<名> --summary all`。
- 一层通过不证明另一层：test-vt 通过不等于完整单测通过；交叉编译通过不等于该目标上能运行；Windows 通过不等于 Linux 通过；artifact 存在不等于截图验收通过。
- 必要工具缺失时，不得整族跳过后报绿，记 PENDING。
- CI 结论要引用具体运行：workflow、run、job 与提交 SHA。本地 `actionlint` 只证明 workflow 语法，不证明 job 能通过。
