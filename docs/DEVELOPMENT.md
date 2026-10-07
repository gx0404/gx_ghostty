# 开发流程（gx_ghostty）

本文是 fork 的开发闭环与上游同步手册。命令细节见 [MAKE_COMMANDS.md](MAKE_COMMANDS.md)，测试分层与证据规则见 [TESTING.md](TESTING.md)，发版见 [RELEASE.md](RELEASE.md)。上游自己的构建、lint 与手测说明在 [HACKING.md](../HACKING.md)，本文只写 fork 增加或改变的部分。

## 首次准备

以下前置需要人工准备。框架不代装系统级工具，hook 也会拒绝 winget、choco、scoop、msiexec。

- Git、`just`、Python ≥ 3.10（框架脚本只用标准库；3.10 需已装 `tomli`）。
- Windows：Visual Studio 2022 Build Tools（MSVC）与 Windows SDK；另需在「设置 → 系统 → 开发者选项」开启开发者模式，允许非管理员创建符号链接，否则 `just test-vt` 中 `src/lib/tinyio` 的符号链接用例会以 `PermissionDenied` 失败。
- 网络：`just setup` 要下载 Zig 与 graphify；首次 `zig build` 还会拉取 `build.zig.zon` 声明的依赖。
- 内存：`just test-vt` 并行编译两个 lib-vt 测试二进制时，每个 LLVM 编译进程约占 6 GB。

然后在仓库根依次运行：

```sh
just setup          # 钉版 Zig 0.16.0 与图谱 venv 装进仓内 .local/，幂等
just doctor         # 只读体检，必需项缺失时退出 1
just install-hooks  # core.hooksPath=.githooks，启用 commit-msg 提交规范检查
```

- `just setup`（`scripts/setup_env.py`）分两步，各自幂等。第一步把 Zig 按 sha256 钉版下载到 `.local/toolchains/zig/zig-0.16.0/`：`GX_GHOSTTY_ZIG_MIRROR` 指定的源最先尝试，然后是内置镜像，最后是官方源，源太慢或校验不符就换下一个；`GX_GHOSTTY_ZIG` 或 `ZIG` 已经指向可用的 0.16.0 时跳过下载。第二步建 `.local/tools/venv` 并装 `graphifyy==0.9.73`，有 `uv` 用 uv，否则用 venv + pip，解释器取 `find_real_python` 找到的真实路径。任一步失败退出 1。钉版目录损坏时用 `python scripts/setup_env.py --force` 覆盖重装（`just setup` 不接受参数）。
- `just doctor`（`setup_env.py --check`）：不安装，不在仓库里建任何东西（符号链接探测只用系统临时目录并随即删除）。必需项是 zig、python、git、MSVC（仅 Windows）、venv、graphify，任一为 MISSING 就退出 1；hooksPath、Windows 上的符号链接权限（`symlink`，未开开发者模式时为 OPTIONAL）与 codex、claude、kimi、zcode、actionlint、uv 只报 FOUND 或 OPTIONAL。每项都给出修复提示。
- `just install-hooks`：只改本仓 `.git/config` 的 `core.hooksPath`。不装也能开发，但 `gx-ci` 的 `framework` job 按同一规则校验首父链提交，不合规的提交 push 后一样会红。

装好后用 `just framework-check` 确认框架本身是绿的，再用 `just ci-check` 确认 Zig 链路可用。首次 `just ci-check` 要拉依赖并编译测试二进制，远比日常慢；之后热缓存下约 100 s，改过 Zig 源码再加约 2 min 编译（见 TESTING.md「并行运行器与耗时」）。

## 日常闭环（九步）

每个任务都走完九步。某步不适用时，在交付说明里写明理由，不要默默跳过。

### 1. 验收点

动手前写下「做完长什么样」：可观察的行为、要跑的命令、要过的测试，GUI 可见的改动还要写明截图要证明什么。同时判断每个验收点能在哪里证明：Windows 本机只能跑框架单测、`just fmt-check` 与 libghostty-vt 的测试和构建（`just test` 在 Windows 上退出 2，`just build` 退出 1，见下文「Windows 注意事项」），GTK、macOS、完整单测与非 vt 代码的编译要靠 `gx-ci` 或 Linux/macOS 开发机（见 TESTING.md）。给不出可验证验收点的任务，先和人对齐。

### 2. 加载规则

```sh
just rules <本轮会读、改、审的路径…>
```

resolver 先列出命中的领域文档 `docs/AGENT_RULES/<id>.md`，再列出按路径祖先目录匹配的上游嵌套 `AGENTS.md`，两类都必读，读完再动手。目录会展开为其中的 Git 可见文件，多路径取并集；scope 扩大后用完整集合重跑。按任务类型追加文档用 `--task`（`release`、`sync`、`test`、`review`），例如 `just rules --task sync`。路径未登记路由或任务未知时退出 2：先在 `routes.toml` 登记（方法见 `docs/AGENT_RULES/README.md`），不要绕过。

### 3. 实现与文档

- 先读代码再改。状态所有者、线程与锁协议见 ARCHITECTURE.md 和对应领域文档。
- 代码、标识符与代码注释用英文，fork 文档用中文。
- 改上游已有的源码文件时，加 `fork(gx): GX-NNNN` 标记并登记到 `docs/FORK_PATCHES.md`，`scripts/test_fork_patches.py` 会锁定登记闭集；fork 自己的新文件尽量放在上游没有的路径，减少同步冲突。
- 改了某份文档描述的行为，就同步那份文档：领域文档、本目录文档、根 `AGENTS.md` 的 fork 段。上游原文（根 `AGENTS.md` 标记以上、嵌套 `AGENTS.md`、`.agents/**`）不改。
- 用户可观察的 fork 变化写进根 `CHANGELOG.md` 当前的 `## X.Y.Z(TBD)` 段。

### 4. 针对性检查

先跑与改动相称的最小集合，红了先修，再扩大范围：

| 改动 | 命令 |
|---|---|
| libghostty-vt（根模块 `src/lib_vt.zig`、`src/terminal/c/**`、`include/ghostty/**`） | `just test-vt --filter <名>` |
| 其他 Zig 核心代码 | Linux/macOS 上 `just test --filter <名>`；Windows 上 `just test` 退出 2，记 PENDING 交给 `gx-ci` 的 `linux-main`；改动也编进 libghostty-vt 时（如 `src/terminal/`），本机先跑 `just test-vt` |
| 任意 `.zig` 文件 | `just fmt-check`，需要改格式时 `just fmt` |
| 框架脚本、hook、workflow | `python scripts/run_unittests.py test_<名>`（Linux 用 `python3`；看单个方法用 `python -m unittest scripts.test_<名>.<类>.<方法> -v`），再 `just framework-test` |
| 路由、领域文档、根 `AGENTS.md` | `just rules-check` |

`--filter` 按用例全名做子串匹配，在运行期筛选、不重新编译，可重复给出取并集；一条都没命中时退出 2。`-Dtest-filter` 仍会透传给 zig build，但它在编译期裁剪用例，每换一个值就重编一次测试二进制，定向时优先 `--filter`；它裁掉全部用例时运行器同样退出 2，报错会写明是哪一种。值里含空格时，经 `just` 要写内嵌引号，或改为直接调用脚本，见 MAKE_COMMANDS.md「约定」。

### 5. 适用集成与 CI

按改动面挑选；不适用的写明原因。

- 本机聚合门：`just ci-check`（framework-check → fmt-check → test-vt），提交前必跑；热缓存约 100 s。Linux/macOS 开发机另跑完整单测 `just test`；它只跑 `ghostty-test`，macOS app 的单测另用 `macos/build.nu --action test`。
- C API 或头文件：`just build-vt`；示例在各自目录里用钉版 Zig 构建，例如在 `example/c-vt-static` 下执行 `python ../../scripts/zigw.py build`（Linux/macOS 用 `python3`；`just` 的配方总在仓库根执行，进不了示例目录）；ABI 清单用 `just zig build test-lib-vt-schema`，前置见 TESTING.md。
- wasm：`just vt-wasm`，再用 `node test/wasm-alloc.mjs zig-out/bin/ghostty-vt.wasm` 做分配器冒烟。
- 其他目标：`just build-vt -Dtarget=<triple>`；源码包：`just dist-vt`。
- Linux 完整测试、交叉矩阵与 Windows job 在 push 到 `gx_ghostty` 后由 `gx-ci` 运行；GTK 截图冒烟与 macOS 上的 lib-vt 测试只在手动触发 `gx-ci` 并打开 `gtk_smoke` / `macos` 输入时运行；macOS app 只在手动运行 `gx-release` 并打开 `macos` 输入时构建。push 与手动触发由用户执行（fork 上要先启用 Actions，见 RELEASE.md「首次启用」），结果出来之前这些项记 PENDING；GTK 截图要下载 artifact 并实际读图后才能记 PASS。

### 6. 修复复测

失败时先看完整输出，判断是代码问题、环境问题还是前置缺失。`just test-vt` / `just test` 失败时，结论行之后会打印一条可直接复制执行的完整复现命令，形如 `python scripts/zig_test.py <本次的 --suite/--binary、-D、--zig-arg、--no-build、非默认的 --timeout> --seed 0x… --filter <引好的用例全名>`，先原样执行它定向重跑；用例名含空格，所以它绕过 just 直接调用脚本，不能把这些参数接在 `just test-vt` 后面。怀疑是分片或执行顺序引起的，再用上游串行路径 `just zig build test-lib-vt` 对照。修复后用同一条命令复测，必要时再扩大一层。失败输出要保留，不能用后一次成功覆盖前一次失败的记录。缺环境不等于通过：没能运行的检查补齐前置后补跑，否则记 PENDING 并写补验命令；命令已实际运行、因前置缺失而失败的（如未开开发者模式时 `just test-vt` 的 4 处符号链接用例）记 FAIL 并注明原因。

### 7. 生成物与版本

- KB：改了语料就 `just kb`，审 diff 后随改动一起提交。只改函数体不会让 KB 过期，改公开签名、文档注释或文档才会；语料范围见下文「生成物重建时机」。
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

## Windows 注意事项

- **MSVC**：Windows 目标未指定 ABI 时默认用 MSVC ABI（`src/build/Config.zig::init` 的目标解析，避免 MSVC 链接器拒收 GNU ABI 目标文件），所以本机构建需要 MSVC 与 Windows SDK，`just doctor` 会报告二者是否可用。显式 `-Dtarget=x86_64-windows-gnu` 不走这条默认，`gx-ci` 的交叉矩阵里就有这个目标。
- **没有 app，只能构建 libghostty-vt**：`src/apprt/runtime.zig::Runtime.default` 只在 Linux、FreeBSD 上选 `gtk`，其余平台都是 `none`，所以 Windows 上默认 `install` 要构建 libghostty-vt 与 libghostty-internal（`ghostty-internal.dll`、`ghostty-internal-static.lib`）。后者编译不过：`src/build/SharedDeps.zig::add` 给每个经它装配的产物（libghostty-internal、`ghostty` exe、`ghostty-test`、`-Demit-bench` 的工具）无条件加上 translate-c 导入 `posix_c`（`errno.h`、`pwd.h`、`signal.h`、`sys/types.h`、`unistd.h`），MSVC 目标找不到 `pwd.h`，两条库链都停在 `translate-c posix_c.h`。因此本机 `just build` 退出 1。Windows 上构建库用 `just build-vt`（`zig build -Demit-lib-vt`；libghostty-vt 不经 `SharedDeps.add`），测试用 `just test-vt`，`gx-ci` 的 `windows` job 跑的也是这两项。i18n 默认关闭。GUI 相关验收在本机记 PENDING：GTK 由 `gx-ci` 的 `gtk-smoke` 截图补证；macOS app 只能由 `gx-release` 构建出未正式签名的包，没有自动化 GUI 冒烟。
- **主测试是 test-vt**：上游 CI 在 Windows 只跑 `test-lib-vt`、`-Demit-lib-vt` 构建和 C 示例，2026-08-28 起不再在 Windows 跑完整 `zig build test`；完整单测 `ghostty-test` 也因同一个 `posix_c` 导入编译不过。所以 `just test` 在 Windows 上不构建，直接以退出码 2 结束并说明原因。本机全量就是 `just ci-check`（框架单测、`just fmt-check`、`just test-vt`）。非 vt 的 Zig 代码在本机没有编译检查：它由 `gx-ci` 的 `linux-main`（`-Dapp-runtime=none` 编译并运行整个 `ghostty-test`）与 Linux/macOS 开发机覆盖，本机记 PENDING；只在 Windows 目标上才编译的非 vt 分支（如 ConPTY）在这两处也不会被分析，目前没有任何编译检查。上游手测程序 `test/windows/test_dll_init.c` 要先构建 `ghostty-internal.dll`，现在无法执行，记 PENDING（受阻）。
- **编译耗时**：改过 Zig 源码后，`just test-vt` 要用 LLVM 重新编译 `ghostty-vt`、`ghostty-vt-c` 两个 Debug 测试二进制，两次编译并行，约 2 min。这段时间省不掉：Zig 自托管后端在 Windows 上编出的测试二进制无法运行。运行器给测试构建钉住版本串（`X.Y.Z-dev+0000000`），换提交不会让缓存失效；源码没变时构建步骤 1 秒内完成。
- **python 别名**：`justfile` 在 Windows 上调用 `python`，其他平台调用 `python3`。`%LOCALAPPDATA%\Microsoft\WindowsApps` 下的 `python.exe`、`python3.exe` 是应用执行别名：可能转到 Python 安装管理器（找不到匹配运行时会把 Python 装进当前目录，`.gitignore` 的 fork 段因此忽略 `/Python/`），也可能只是 Microsoft Store 占位程序。`scripts/setup_env.py::find_real_python` 建 venv 时跳过这类别名，`just doctor` 显示实际解析到的解释器；`.githooks/commit-msg` 也只用能实际运行的 `python3` 或 `python`。`zig build test-lib-vt-schema` 由 `build.zig` 直接调用 `python3`，这个名字同样必须能运行。
- **本机状态都在 `.local/`**：钉版 Zig、Zig 全局缓存（未设置 `ZIG_GLOBAL_CACHE_DIR` 时 `scripts/zigw.py` 指向 `.local/zig-cache/global`）、图谱 venv 和两个测试运行器的耗时缓存（`.local/test-timings/`，只影响调度顺序）都在仓内 `.local/`，由 `.gitignore` 的 fork 段忽略，不写用户全局目录。构建输出与依赖工作副本仍在上游默认的 `zig-out/`、`.zig-cache/`、`zig-pkg/`，已被上游 `.gitignore` 忽略。agent 的文件编辑工具被 hook 禁止写 `.local/`；删除 `.local/` 后要重新 `just setup`，Zig 依赖也会重新下载。
- **换行**：本机 `core.autocrlf=true`。上游 `.gitattributes` 已把 `.zig`、`.md`、`.py`、`.toml`、`.yml` 等固定为 LF，但 `justfile`、`.graphifyignore`、`.conf` 与无扩展名的 hook 不在其中，检出后可能是 CRLF。框架脚本一律用 `splitlines()` 解析，容忍 CRLF；`.githooks/.gitattributes` 把 hook 固定为 LF。提交前跑 `git diff --check`。
- **shell**：`just` 在 Windows 上用 `cmd.exe` 执行配方（`justfile` 的 `set windows-shell`），所以从 cmd、PowerShell、Git Bash 调用效果相同。配方都是单行 Python 调用，不依赖 POSIX shell。参数是不加引号拼进命令行的：含 `& | < > ^ %` 的自由文本（以及单条提交标题）会被 cmd 解释，这时直接调用脚本，如 `python scripts/conventional_commits.py "<标题>"`、`python scripts/agent_kb.py "<查询>"`。

## 分支模型

| 分支或远端 | 角色 |
|---|---|
| `upstream` | `ghostty-org/ghostty`，只 fetch，永不推送 |
| `origin` | `gx0404/gx_ghostty`，即本 fork |
| `main` | 上游镜像：只快进到 `upstream/main`，不放任何 fork 提交 |
| `gx_ghostty` | 开发与发布分支（本地 `origin/HEAD` 指向 `origin/gx_ghostty`）：全部 fork 改动在这里，`gx-ci` 由它触发，`gx-release` 默认从它构建 |

- fork 提交只进 `gx_ghostty`。不 rebase 到上游，不 force push，不改写已推送的历史。
- fork 的 tag 只有 `gx-vX.Y.Z` 一种，由 `gx-release` 的 publish job 创建，不手工打 tag（见 RELEASE.md）。`v` 前缀是上游版本 tag 的格式：HEAD 上的 `v` tag 必须与 `build.zig.zon` 版本一致，否则构建会 panic；非 `v` 前缀的 tag 按补丁 GX-0001 与 `tip` 一样跳过发布校验，回退到分支预发布版本。

## 上游同步

只在用户要求时执行。整个过程不 force push、不推送 `upstream`；push 由用户在全部检查通过后执行。开始前加载同步规则：`just rules --task sync`。

**0. 前置**：工作树干净（`git status --porcelain` 无输出）。记下两条分支当前的 SHA（`git rev-parse main gx_ghostty`），作为出问题时的回退点。

**1. 抓取与审阅**

```sh
git fetch upstream
git log --oneline main..upstream/main
```

逐条看本轮上游带来了什么，留意 workflow、`AGENTS.md`、`build.zig.zon` 依赖、新目录和嵌套 `AGENTS.md` 的变化。

**2. `main` 只快进**

```sh
git switch main
git merge --ff-only upstream/main
```

不能快进说明 `main` 上出现了非上游提交，先查清原因；不能用 `reset --hard` 或 force push 解决。

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
- **fork 补丁**：按 `docs/FORK_PATCHES.md` 逐条核对补丁是否仍然需要、是否仍然成立（目前是 `src/build/Config.zig::init` 的 GX-0001 与 `build.zig::build` 的 GX-0002：后者三个纯新增块注册 `test-lib-vt-bin`、`test-bin`，上游改动测试对象时按该节「同步冲突处理」放回），标记与登记由 `scripts/test_fork_patches.py` 检查。
- **其余上游文件**：取上游版本。不用整文件 ours/theirs 糊过冲突，也不用 squash、cherry-pick 或 rebase 代替合并。

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
```

framework-check 会捕获未覆盖的新路径、嵌套 AGENTS 变化、被重新启用的 workflow 与丢失的补丁标记。

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

- `type` 是小写英文，取 `feat fix perf docs ci test refactor chore build revert style release` 之一；`scope` 可省略，建议写受影响的面（如 `build`、`ai`、`github`、`kb`、`sync`、`release`）；破坏性变更在冒号前加 `!`。不加 emoji，不加 AI co-author 行。
- 校验正则是 `^type(\(scope\))?!?: \S`，由 `scripts/conventional_commits.py` 实现：冒号是半角，后面恰好一个空格；scope 里不能有空格或括号；`fixup!`、`squash!`、`amend!` 提交不能进入历史。入口 `just commit-check --message-file <文件>` 或 `just commit-check --range <base>..<head>`；校验单条标题时直接调用 `python scripts/conventional_commits.py "<标题>"`（Linux 用 `python3`），因为标题含空格，经 just 传参会被拆开（见 MAKE_COMMANDS.md「约定」）。
- 例子：`fix(build): 非 v 前缀 tag 不再触发版本号 panic`、`chore(sync): 合并上游 main（<sha>）`、`chore(release): 定版 0.1.0`。

**只查首父链**：`--range` 内部用 `git log --first-parent`；`gx-ci` 的 `framework` job 同样只沿首父链校验，push 取 `before..after`（`before` 全零时只查 head），PR 取 `base..head`。上游提交经 `chore(sync)` 合并进来，不在 `gx_ghostty` 的首父链上，不受 fork 规范约束；合并提交本身在首父链上，所以必须带合规信息。

**优先于上游 skill**：上游的 `.agents/skills/writing-commit-messages`（`<subsystem>: <summary>` 格式）保持原样，只用于准备回馈上游的提交；在 `gx_ghostty` 上与本节冲突时以本节为准。该 skill 里「直接提交」的步骤也不构成提交授权。

**hook 与暂存**：`just install-hooks` 后，`.githooks/commit-msg` 对每次提交运行同一检查，包括 `git merge` 生成的合并提交；hook 安全门禁止 `--no-verify`。暂存时精确列出路径，不用 `git add -A`，也不用 `git add -f` 强加被忽略的文件。`.githooks/commit-msg` 首次入库必须用 `git add --chmod=+x .githooks/commit-msg`（本仓 `core.filemode=false`，否则以 100644 入库，POSIX 上的 git 会忽略这个 hook；`scripts/test_conventional_commits.py` 在它入库后检查模式为 100755）。

## 生成物重建时机

| 产物 | 何时重建 | 生成 | 校验 | 入库 |
|---|---|---|---|---|
| `docs/kb/chunks.json` | KB 语料变化：根与嵌套 `AGENTS.md`、`CLAUDE.md`、`README.md`、`HACKING.md`、`CONTRIBUTING.md`、`PACKAGING.md`、`AI_POLICY.md`、`CHANGELOG.md`、`docs/*.md`、`docs/AGENT_RULES/*.md`、`src/**/*.zig` 的 `//!` 模块文档与 `pub` 签名（含其 `///` 注释）、`include/ghostty/**/*.h` 的声明 | `just kb` | `just kb-check`，属于 framework-check 与 `gx-ci` 的 `framework` job | 是 |
| `graphify-out/GRAPH_REPORT.md`、`graphify-out/source-fingerprint.json` | 被索引源码增删改：Git 可见、未被 `.graphifyignore` 排除、扩展名在 `scripts/graphify_fingerprint.py::INDEXED_EXTENSIONS` 内的文件（如 `.zig .swift .c .h .cpp .m .py .sh`），实际主要是 `src/`、`pkg/`、`include/`、`macos/` 与 `build.zig`；或者管线输入 `scripts/graphify.py`、`scripts/graphify_fingerprint.py`、`.graphifyignore` 变化 | `just graph` | `just graph-check`，只在 `gx-release` 的 prepare 阶段与上游同步后强制 | 是 |
| `graphify-out/graph.json` | 同上，约 20 MB | `just graph` | 无 | 否，仅本机 |
| `CHANGELOG.md` 版本标题 | fork 可观察变化、定版 | 手写 | `just version-check` | 是 |
| `build.zig.zon.json`、`build.zig.zon.nix`、`build.zig.zon.txt`、`flatpak/zig-packages.json` | `build.zig.zon` 依赖变化 | `nix/build-support/check-zig-cache.sh --update`（要 `nix develop` 提供的 zon2nix、alejandra、prettier） | 同一脚本不带参数 | 是，上游生成物 |
| `po/com.mitchellh.ghostty.pot` 与 `po/*.po` | 源码或 Blueprint 中的可翻译字符串变化 | `zig build update-translations`（需要启用 i18n，Windows 不可用） | `.github/scripts/check-translations.sh` | 是，上游生成物 |
| `vendor/glad/` | 更新 GLAD loader | 上游 `Makefile` 的 `glad` 目标 | 无 | 是，上游 vendored |

图谱新鲜度刻意不进 `framework-check`、`ci-check` 和 push CI：每改一次 Zig 源码就要花几分钟重建图谱，不划算。日常允许图谱落后于源码，但发版和上游同步时必须追平。检查失败时不手改产物，也不放宽排除表来「变绿」。
