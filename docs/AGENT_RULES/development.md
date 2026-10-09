# development：AI 协作框架自身

## 范围

- 规则与入口：根 `AGENTS.md`、全部 `**/AGENTS.md`（上游嵌套文件只登记、不改写）、`CLAUDE.md`、`docs/**`（含 `docs/AGENT_RULES/`、`docs/kb/`）。
- 工具面：`.claude/**`、`.codex/**`、`.zcode/**`、`.githooks/**`，以及上游自带的 `.agents/**`。
- 命令、脚本与生成物：`justfile`、`scripts/**`、`graphify-out/**`、`.graphifyignore`，`.gitignore` 与 `.prettierignore` 的 fork 追加段。
- 原样保留的上游政策文件：`AI_POLICY.md`、`HACKING.md`。
- `--task sync`（上游同步）同时加载本文档与 `ci-release.md`。一个文件命中多个领域时取并集，例如 `scripts/gx_release.py` 也属于 `ci-release`，`scripts/zig_test.py` 与 `scripts/gx_wsl.py` 也属于 `testing`，`scripts/gx_i18n.py` 也属于 `gx-core`，`.gitignore` 也属于 `build-system`。

## 符号真源

- `docs/AGENT_RULES/routes.toml`：路由唯一机器真源，schema v3（`version = 3`、`root_max_bytes = 16384`、`root_only`、`nested_agents`、`[[rules]]` 每条恰为 `id/doc/paths/tasks`）。人读索引与维护约定在 `docs/AGENT_RULES/README.md`。
- `scripts/resolve_agent_rules.py`：参数、输出顺序与退出码见 `docs/AGENT_RULES/README.md`；`--check` 单独使用，做全仓守门，违规退出 2。根 `AGENTS.md` 常驻加载，不在输出里。
- 根 `AGENTS.md`：上游原文在前，标记行 `<!-- gx-fork: AI 协作框架（fork 维护段，上游没有；同步时保留）-->` 之后是 fork 段；`CLAUDE.md` 是指回它的薄入口。
- `.claude/hooks/dangerous_patterns.conf`：危险操作策略唯一真源（`SECTION<TAB>regex<TAB>reason<TAB>deny|ask`），Claude、Codex、ZCode 的 PreToolUse 适配器只读取它；探针 `scripts/test_ai_tool_hooks.py`；接入与逐客户端验证账本 `docs/AI_TOOLS.md`。
- `justfile` 与命令手册 `docs/MAKE_COMMANDS.md`；Zig 封装 `scripts/zigw.py`，环境 `scripts/setup_zig.py`、`scripts/setup_env.py`。
- 测试运行器：`scripts/zig_test.py`（`just test-vt`、`just test`，用法见 `testing.md`）与 `scripts/run_unittests.py`（`just framework-test`），锁定测试 `scripts/test_zig_test.py`、`scripts/test_run_unittests.py`；耗时缓存只写 `.local/test-timings/`。
- 生成物管线：`scripts/graphify.py`、`scripts/graphify_fingerprint.py`、`.graphifyignore`；`scripts/build_agent_kb.py`（默认只检查，`--confirm` 才写入）、`scripts/agent_kb.py`。
- fork 补丁：`docs/FORK_PATCHES.md` 与 `scripts/test_fork_patches.py`。上游同步与交付闭环的步骤细则：`docs/DEVELOPMENT.md`。

## 不变量

### 规则路由

- 闭集：`git ls-files --cached --others --exclude-standard` 的每个文件至少命中一个领域，或落在 `root_only`，二者不重叠；未跟踪但未忽略的新文件也要有路由。`root_only` 只放没有领域不变量的仓库元文件，不能借它绕过闭集。
- glob 语义与排序见 `docs/AGENT_RULES/README.md`：每个 pattern 至少命中一个文件，不写 `**` 万能兜底，`rules` 按 `id` 排序，各数组内部排序。
- 文档：`docs/AGENT_RULES/` 下除 `README.md` 外每份 `*.md` 恰好登记一次，≤16 KiB（目标 4–10 KiB），用五段式（可加只放链接的「上游指令」段）；领域文档之间不得出现 ≥160 字符的相同段落或列表项，跨域内容写链接。
- 嵌套 AGENTS：`nested_agents` 必须等于实际的嵌套 `AGENTS.md` 集合；上游增删时 `--check` 失败，按 `docs/AGENT_RULES/README.md` 的步骤更新登记与「上游指令」链接，不复制、不改写上游正文。fork 规则只写进 `docs/AGENT_RULES/`，不新建嵌套 `AGENTS.md`。
- resolver 无状态：scope 扩大后用完整集合重跑；退出码 2 要求补登记，不是可绕开的障碍。

### 根 AGENTS.md 与同步冲突

- 标记之前保持上游原文一字不改，fork 内容只追加在标记之后；整份 ≤16 KiB，标记行恰好一次（`--check` 校验）。`main` 快进到上游后，`git diff main -- AGENTS.md` 只应在末尾出现新增行（分隔空行、标记与 fork 段）。
- 冲突解法：标记之前整段取 `main:AGENTS.md`，标记及之后保留 fork 版本；再核对上游新内容是否让 fork 段的命令或描述失效，按需同步修改 fork 段与相关领域文档。超限时压缩 fork 段、把细节下沉到领域文档，绝不删改上游原文。
- 上游段的命令说明与 Issue and PR Guidelines 对 fork 同样有效；提交格式以 fork 段为准，上游 `.agents/skills/writing-commit-messages` 只用于准备回馈上游的提交。

### 工具配置

- `.claude/`、`.codex/`、`.zcode/` 只把 `.gitignore` fork 段白名单列出的无凭据配置入库（settings / config、hooks、rules、reviewer、README），会话、认证与本机覆盖留在本机；`.kimi-code/` 整目录忽略；`.agents/` 是上游内容，原样保留且不忽略。
- 危险模式只改 `dangerous_patterns.conf` 一处，适配器不内嵌副本；工具规则文件、reviewer 定义与 `CLAUDE.md` 只提醒运行 resolver，不复制领域正文。hook 是安全门，不加载规则，也不静默改写源码。
- 客户端状态见 `docs/AI_TOOLS.md`：规则注入、配置加载、拦截与信任分开验收，离线 fail-closed、`hooks=true` 或 `git status` 不能代证拦截；下文「hook 拒绝」以实际加载、受信任并收到调用为前提。agent 不自动 trust、不读私有配置与会话、不用 `config/read` 全层 RPC，不改 sandbox、model 或审批权限掩盖漏拦。
- `GX_GATE_WATCHDOG_SECONDS` 只给测试缩短 hook 求值看门狗（`.claude/hooks/pre_tool_use_gate.py::evaluation_deadline` 只认 (0, 10] 秒）；不写进 hook 配置或会话环境，否则 hook 提前超时并按拒绝处理。

### 脚本约定

- Python 标准库、兼容 3.10+（`tomllib` 缺失时回退已安装的 `tomli`，检查时不现装）；第三方工具只进 `.local/tools/venv`。
- 仓库根取 `Path(__file__).resolve().parents[1]`（显式 `--root` 除外），不依赖当前目录。
- UTF-8 读写、写出 LF；文本按 `splitlines()` 解析并用 CRLF 样例测试：本机 `core.autocrlf=true`，上游 `.gitattributes` 不覆盖 `.conf`、`.graphifyignore`、`justfile` 与无扩展名钩子（钩子由 `.githooks/.gitattributes` 强制 `eol=lf`）。
- 同一脚本在 cmd、PowerShell、Git Bash 与 Linux CI 上行为一致；需要真实解释器路径时用 `scripts/setup_env.py::find_real_python`，它跳过 WindowsApps 别名。
- 违规返回非 0 且原样传递；测试为 `scripts/test_*.py`（unittest、临时目录、不联网、不改真实仓库），放在 `scripts/` 顶层。`run_unittests.py` 把每个 TestCase 类放进独立子进程并行跑：类之间不共享可变状态、不依赖执行顺序；拖慢整机进程创建的类设 `RUN_LAST = True`。

### just 入口与四个门

- `justfile` 在 Windows 经 `cmd.exe` 执行（`set windows-shell`），解释器在 Windows 取 `python`、其余取 `python3`；配方体只写单条命令（Python 脚本调用，`install-hooks` 是 `git config`），串联的门用配方依赖表达，不写 POSIX 守卫或多行 shell。`.githooks/commit-msg` 必须以可执行模式入库（`git add --chmod=+x`），由提交规范测试锁定。上游 `Makefile` 不改，也不作 fork 入口。
- `just framework-check`：rules-check → version-check → framework-test → kb-check → i18n-check；不需要 Zig，本机约 15 s，改规则、脚本、文档后必跑。
- `just generated-check`：kb-check → i18n-check → graph-check；生成物新鲜度门，上游同步后执行，`gx-release` 的 prepare 也跑 kb、graph 两项。图谱重建要几分钟，graph-check 刻意不进 framework-check、ci-check 与 push CI。
- `just ci-check`：framework-check → fmt-check → test-vt；本地复现 CI 主干（不含完整单测 `just test`），需要钉版 Zig；本机热缓存实测约 100 s，改过 Zig 源码另加约 2 min 编译。「所有测试 ≤2 min」尚未完全达成，不得自行排除冷编译或用本机结果代证 CI，详见 `docs/TESTING.md`。
- `just doctor`：`setup_env.py --check` 只读诊断（FOUND / MISSING / OPTIONAL），缺必需项（zig、python、git、venv、graphify，Windows 另需 MSVC）退出 1，hooksPath、符号链接权限、Inno Setup 与各 CLI 只作可选项；只报告并给修复命令，不隐式安装。配方参数不加引号拼进命令行，含 shell 元字符的自由文本直接调用脚本。

### 工具链本地性

- Zig 只经 `just setup` 装进 `.local/toolchains/zig/zig-0.16.0/`（sha256 钉版、镜像回退；`GX_GHOSTTY_ZIG_HOME`、`GX_GHOSTTY_ZIG_MIRROR` 覆盖位置与镜像；安装幂等，损坏需 `--force`）。graphify 只装进 `.local/tools/venv`（`graphifyy==0.9.73`）。
- `zigw.py` 解析顺序 `$GX_GHOSTTY_ZIG` > `$ZIG` > 项目内钉版 > PATH，版本须等于 `scripts/setup_zig.py::ZIG_VERSION`（测试锁定其与 `build.zig.zon` 的 `minimum_zig_version` 一致）；找不到 Zig 或版本不符时退出 2 并提示 `just setup`，其余情况原样透传 zig 的退出码。
- 未设 `ZIG_GLOBAL_CACHE_DIR` 时默认 `.local/zig-cache/global`；`.zig-cache/`、`zig-out/` 由上游 `.gitignore` 忽略，`.local/` 由 fork 段忽略。工具链、缓存与产物都不指向仓库外。
- Inno Setup 7.1.0 只经 `just setup --innosetup`（仅 Windows，sha256 钉版、便携安装）装进 `.local/tools/innosetup/`，供 `just package-windows`。WSL 克隆的工具链由 `just wsl setup` 装进 WSL 用户目录；`--apt` 以 root 装 apt 包与 locale，先征得用户同意。
- 禁止系统级或用户级安装（winget、choco、scoop、msiexec 由 hook 拒绝）；MSVC、Windows SDK 这类无法仓内化的前置由人类安装，`just doctor` 报告。

### 生成物默认只检查

- 入库的图谱产物只有 `graphify-out/GRAPH_REPORT.md` 与 `source-fingerprint.json`；`graph.json` 本机重建并被忽略，缺它 graph-check 照常运行。KB 产物是 `docs/kb/chunks.json`。编辑工具写这些路径会被 hook 拒绝，只能经 `just graph` / `just kb` 生成；有意重建后审 diff，检查失败时不得手改产物或放宽排除表来「变绿」。`GRAPH_REPORT.md` 里「Run `graphify update .`」的提示不适用：`scripts/graphify.py` 拒绝 `update`，重建一律 `just graph`。
- KB 触发：语料变化，即各级 AGENTS 与根目录说明文档（含 `CHANGELOG.md`）、`docs/` 与 `docs/AGENT_RULES/` 的 Markdown、`src/**/*.zig` 的 `//!` 模块文档与 `pub` 签名（含 `///`）、`include/ghostty/**/*.h` 的声明；清单、格式与裁剪规则以 `scripts/build_agent_kb.py` 为准，函数体改动不会让 KB 过期。kb-check 在 framework-check 里，过期即失败，修法是 `just kb`。体积预算 2.5 MiB 不放宽（`scripts/test_agent_kb.py::SIZE_BUDGET_BYTES`）。
- 图谱触发：未被 `.graphifyignore` 排除的被索引源文件增删改（扩展名见 `scripts/graphify_fingerprint.py::INDEXED_EXTENSIONS`），或管线输入 `scripts/graphify_fingerprint.py::PIPELINE_INPUTS`（两个图谱脚本与 `.graphifyignore`）变化。日常可不立即重建；发版前与同步后 `just graph`，再 `just generated-check`。已知盲区：graphify 跳过名为 `build` 的目录（`src/build/**` 不在图里），拿不到 `include/` 头文件的符号，这两处直接读源码或用 `just kb-query`。graphify 一律经 venv 的 `python -m graphify` 运行，不直接执行 `graphify.exe`（Windows 智能应用控制会拦截）。

### fork 补丁登记

- 改动过的上游文件：`AGENTS.md`（标记后追加）、`.gitignore` 与 `.prettierignore`（末尾带标记的追加段）、归档的 workflow，以及 `docs/FORK_PATCHES.md` 登记表列出的源码补丁；以登记表为准，不在别处抄清单。fork 自有代码一律放上游没有的新路径（`src/gx/`、`src/apprt/win32/`、`src/apprt/gtk/gx/`、`src/font/directwrite/` 等）。
- 改上游源码（`src/`、`include/`、`pkg/`、`macos/` 与 `build.zig`）必须紧邻改动写 `fork(gx): GX-NNNN` 标记注释，并在 `docs/FORK_PATCHES.md` 登记原因与移除条件；`scripts/test_fork_patches.py` 扫描这些路径，锁定标记与登记的闭集。追加段与新路径不是源码补丁，不登记。未登记的标记、无标记的上游语义改动都是缺陷；不为「顺手」重排或重格式化上游文件。
- 与框架相关的两项：GX-0001 让 HEAD 上不以 `v` 开头的 tag（如 `gx-v0.0.1`）不再 `@panic`（版本契约见 `ci-release.md`）；GX-0002 注册只编译、不运行的 `test-lib-vt-bin`、`test-bin`，安装路径与 `scripts/zig_test.py::SUITES` 一一对应，改一边要同步另一边。

### 上游同步摘要

1. `main` 只快进到 `upstream/main`；在 `gx_ghostty` 上 `git merge --no-ff main -m "chore(sync): 合并上游 main（<sha>）"`。
2. 冲突：根 AGENTS 按上文处理；追加段原样保留；新 workflow 移入归档（见 `ci-release.md`）；对照 `docs/FORK_PATCHES.md` 逐条确认补丁仍成立、移除条件是否已满足。
3. 上游改了 `build.zig.zon` 的 `minimum_zig_version` 时，按 `https://ziglang.org/download/index.json` 中各平台的 `shasum` 更新 `scripts/setup_zig.py` 的 `ZIG_VERSION` 与 `PINS`，`just setup` 后跑 `just framework-test`（`scripts/test_setup_zig.py` 锁定两者相等），再改文档与注释里写死的 `0.16.0` 并在 `CHANGELOG.md` 记一条；不得用 `GX_GHOSTTY_ZIG` 指向另装的 Zig 绕过钉版。
4. `just framework-check`（捕获新路径与新增嵌套 AGENTS）与 `just ci-check`；Windows 上再跑 `just build` 与 `just test`（上游新增按 `app_runtime` 穷举的 switch 时 win32 编译会报错，按 GX-0003 补 `.win32`），Linux 侧 `just wsl test`；按需 `just kb` / `just graph` 后 `just generated-check`。

### 保留的上游政策

- `AI_POLICY.md` 约束对上游的外部贡献：fork 产出回馈上游时，由人类按其要求披露 AI 使用并完全理解改动后自行提交。
- agent 不创建 issue 或 PR，对上游和本 fork 都一样（上游段 Issue and PR Guidelines；hook 拒绝 `gh issue create`、`gh pr create`），用户要求时按上游原文处理。
- `.agents/commands/review-branch` 可继续使用，结论按 `code-review.md` 的格式输出。

## 禁止项

- 不把领域规则正文复制进根 `AGENTS.md`、`CLAUDE.md`、工具目录或 reviewer 定义；不把嵌套 AGENTS 的内容抄进领域文档；不新增嵌套 `AGENTS.md`。
- 不改上游原文：根 `AGENTS.md` 标记之前、9 份嵌套 `AGENTS.md`、`.agents/**`、`AI_POLICY.md`、`HACKING.md`、`CONTRIBUTING.md`。
- 不手改 `graphify-out/**`、`docs/kb/chunks.json`；不提交 `graph.json`、`.local/`、`.graphify-memory/`、`__pycache__/`。
- 框架脚本不引入第三方依赖。
- 不吞退出码：不加 `|| true`、`--exit-zero`，不把验收命令接 `| tail` 或 `| head`。
- 不建 issue / PR，不 force push，不推 `upstream`；未经用户要求不 commit、不 push。

## 验证

- 改路由、领域文档或根 `AGENTS.md`：`just rules-check`，再 `just framework-check`；查某次改动的必读规则：`just rules <paths>`。
- 改 `scripts/**`、`.githooks/**`、hook 策略或工具配置：先 `python scripts/run_unittests.py test_<名>`，再 `just framework-test` 与 `just framework-check`。
- 改两个测试运行器：除各自单测外再真实跑一次 `just test-vt` 与 `just test`，或 `just framework-test`，核对用例总数分别与上游串行路径、`python -m unittest discover -s scripts -p "test_*.py"` 一致。
- 改 `justfile`、`scripts/zigw.py`、`scripts/setup_*.py`：`just doctor`，有钉版 Zig 时 `just ci-check`。
- 改 KB 语料：`just kb` 后 `just kb-check`；改被索引源码或图谱管线：`just graph` 后 `just graph-check`。
- 上游同步完成的标准：`just framework-check`、`just ci-check`、`just generated-check` 全部通过；未运行项记 PENDING 并附补跑命令。
