# AI 工具接入与验证账本

本仓的 AI 协作面是「两份真源 + 各客户端薄适配」：

- 规则真源：根 `AGENTS.md` 加 `docs/AGENT_RULES/`，由 `scripts/resolve_agent_rules.py`（`just rules <paths...>`）按路径解析。
- 危险操作真源：`.claude/hooks/dangerous_patterns.conf`，判定逻辑 `.claude/hooks/pre_tool_use_gate.py`。

各客户端目录只做协议适配，不复制规则或模式。入库范围由根 `.gitignore` fork 段的白名单决定；认证、会话、`settings.local.json` 等个人状态留在本机，`.kimi-code/` 整目录忽略。

## 各客户端如何加载

| 客户端 | 规则入口 | 领域规则 | 项目配置 | 安全门 | 只读复审 |
|---|---|---|---|---|---|
| Claude Code | `CLAUDE.md` 首行 `@AGENTS.md` 导入根规则 | resolver；`.claude/rules/*.md` 按 `paths` 触发「先跑 resolver」提醒 | `.claude/settings.json` | PreToolUse（Bash 与写文件工具）→ `.claude/hooks/block_dangerous.sh`，Claude 协议，支持 ask | `.claude/agents/code-reviewer.md` |
| Codex | 根 `AGENTS.md`（原生读取） | resolver | `.codex/config.toml`（项目受信任后才加载） | PreToolUse（匹配 Bash 与 `apply_patch`）→ `.codex/hooks/pre_tool_use_policy.py`，Codex 协议，ask 按 deny 返回 | `.codex/agents/gx-ghostty-reviewer.toml` |
| Kimi Code | 根 `AGENTS.md`（会话启动时注入） | resolver；项目 skill 目录 `.agents/skills/` | 无（`.kimi-code/` 不入库） | 无项目级 hooks，见下文 | 无专属定义；按 `docs/AGENT_RULES/code-review.md` 自审 |
| ZCode | 根 `AGENTS.md`（不经 `CLAUDE.md`，根文件必须自足） | resolver | `.zcode/config.json`（只有 hooks） | PreToolUse → 同一个 `block_dangerous.sh`，Claude 协议 | 无 |

各工具的规则文件、reviewer 与 `CLAUDE.md` 都只提醒运行 resolver，规则正文只在 `docs/AGENT_RULES/`。

## 共享安全门（PreToolUse）

### 策略

`dangerous_patterns.conf` 每行 `SECTION<TAB>regex<TAB>理由<TAB>deny|ask`：

- SHELL 段匹配 Bash 命令全文；另把反斜杠续行（bash）与反引号续行（PowerShell）并成一行再匹配一次，任一命中即算。
- FILE 段匹配写文件工具（Edit、Write、MultiEdit、NotebookEdit）的目标路径，以及 Codex `apply_patch` 补丁头里的路径（见下文）：先相对化到仓库根（由 hook 文件位置推导，不依赖会话 cwd），再按大小写不敏感匹配。
- 同一调用同时命中 deny 与 ask 时，deny 优先。

deny：

- force push（`-f`、`--force`、`--mirror`、`+refspec`；参数带引号也算，如 `"+HEAD:gx_ghostty"`、`"--force"`）。
- 推送到名为 `upstream` 的 remote，或推送到含 `ghostty-org/ghostty` 的 URL。
- 绕过仓库 hooks：`--no-verify`（`git commit` 还包括 `-n`），以及 `git -c core.hooksPath=…`、`--config-env` 临时改 hooks 路径。
- `git add -f`；`filter-branch`、`filter-repo`、`replace`、`reflog expire`。
- `gh issue create|new`、`gh pr create|new|merge`、`gh release create|new|edit|delete|delete-asset|upload`、`gh workflow run … gx-release`。
- `gh api` 以写方法改 `releases`、`dispatches`、`git/refs`、`actions/workflows`：显式 `-X`/`--method` 为 POST、PATCH、PUT 或 DELETE，或带 `-f`、`-F`、`--field`、`--raw-field`、`--input` 而没有显式 GET（此时 gh 默认 POST）。
- 读取私钥、`.ssh/` 或 `.env`。读取类命令除 `cat`、`head`、`cp` 等外，还包括 `grep`、`rg`、`sed`、`awk`、`sort`、`diff` 等文本工具，`python`、`node`、`perl`、`ruby` 解释器，以及 PowerShell 的 `Get-Content`、`gc`、`type`、`Select-String`、`Copy-Item`（不区分大小写）。
- 系统级安装或升级：`winget`、`choco`、`scoop` 的 `install`、`add`、`upgrade`、`update`，`cinst`、`cup`，以及 `msiexec /i`。
- 改写生成物：重定向、`tee`、`sed -i`/`--in-place`、`mv`（生成物作源或目标都算），以 `cp` 覆盖生成物，以及 PowerShell 的 `Set-Content`、`Add-Content`、`Out-File`、`Move-Item`、`Copy-Item`；路径用 `/` 或 `\` 分隔都算，不区分大小写。`cp`/`Copy-Item` 只按最后一个参数（目标）判定，把生成物复制出去只是读取，照常放行。

ask：

- `--force-with-lease`；删除远端分支或 tag（`git push --delete`、`-d`、`origin :branch`）；`git reset --hard`；`git clean -f/-d`；`pkill`、`killall`、`taskkill`；`gh run rerun`（重跑 gx-release 的 publish run 会再发一次版）。
- `git config` 设置或清除 `core.hooksPath`（`--unset`、`unset`、`set` 都算），它会停用 commit-msg 校验；只读查询照常放行，启用 hooks 用 `just install-hooks`。
- 用 shell 改写、移动或删除安全门自身与客户端权限配置（路径见下方 FILE ask）：重定向、`tee`、`sed -i`/`--in-place`、`mv`、`rm`、以 `cp` 覆盖，以及 PowerShell 的 `Set-Content`、`Add-Content`、`Out-File`、`Move-Item`、`Remove-Item`、`Copy-Item`、`del`；`rm -rf .claude` 这类整目录删除同样要确认。

FILE deny：

- 生成物：`graphify-out/`、`docs/kb/chunks.json`、`build.zig.zon.{json,nix,txt}`、`flatpak/zig-packages.json`、`vendor/glad/`。
- 本机工具链：`.local/`。
- 归档的上游 workflow：`.github/workflows-archive/*.yml`。同目录的 `README.md` 是 fork 自有文件，不拦。
- 凭据：`.env` 及其变体（`.env.example` 等模板与上游的 `.envrc` 除外），私钥，`.ssh/`。

FILE ask：安全门自身与客户端权限配置，即 `.claude/hooks/`、`.claude/settings.json`、`.claude/settings.local.json`、`.codex/config.toml`、`.codex/hooks/`、`.zcode/config.json`。改它们可能削弱安全门，所以要人工确认；Codex 没有 ask，这些路径在 Codex 里直接拒绝，由人工修改。

### 命令位置锚定

所有 SHELL 规则（以 `>` 开头的两条重定向规则除外）共用同一个前缀，只在以下位置命中：

- 行首；
- `;`、`&`、`|`、`(`、`)`、`{`、反引号、`$(` 之后，其中 `)` 覆盖 `case` 分支；
- 上述位置之后的 shell 关键字 `if`、`elif`、`while`、`until`、`then`、`do`、`else` 与 `!` 之后；
- `sudo`、`env`、`xargs`、`timeout`、`bash -c`、`sh -c`、`eval`、`powershell`、`pwsh`、`wsl`，以及 PowerShell 的 `iex`、`Invoke-Expression`、`Start-Process`（不区分大小写）等包装词之后，而且包装词本身也要处在命令位置；
- 容许 `VAR=x` 前缀、`git -C <path>` 这类全局选项，以及用 `/` 或 `\` 分隔的命令路径；
- 命令名、git/gh 子命令与 push 的危险参数可以带引号（`"git" push`、`& "git" push`、`git "push"`），参数之间可以是逗号（`Start-Process git -ArgumentList "push","--force"`）。

关键字和包装词分开处理：关键字后面紧跟的就是命令，所以 `if rg -q 'git push -f' docs; then …` 仍然放行；包装词会跳过任意参数，误拦面更大，因此不把关键字并进包装词列表。

git 与 gh 的全局选项用无歧义的 `--?\w[\w-]*` 逐个跳过。旧写法 `-{1,2}[\w-]+` 对 `--x` 有两种切分，匹配失败时指数回溯：带 22 个长选项的命令实测要 7 秒，24 个要 22 秒，而 hook 超时等于放行。测试锁定 40 个长选项在 1 秒内判完。包装词之后的参数跳过仍有平方级最坏情况（单行几万字符、同一命令名重复上千次的刻意构造），由下文的判定看门狗兜底。

因此：

- 真执行会被拦：直接执行、`&&` 链式、`sudo`、`xargs`、`bash -c '…'`、`iex`/`Invoke-Expression`/`Start-Process`/`wsl` 包装、`VAR=x` 前缀、`git -C path`、`if`/`while`/`until`/`!` 与 `case` 分支里的命令、用续行拆开的命令、带引号的命令名与参数，以及 `bash <<EOF` 正文里位于行首的命令。
- 只是提到命令不会被拦：`rg` 的搜索词、python heredoc 里的字符串、`git commit -m` 的说明、`echo` 的参数。

正则看不到引号的边界，以下误拦是有意保留的保守行为：

- 引号里出现 `;`、`&&`、`(`、`)` 或反引号，后面紧跟危险命令。双引号里的反引号确实会执行。
- heredoc 正文里某一行以危险命令开头。
- 读取类命令的参数里出现 `.env`、`id_rsa`、`.ssh`、`*.pem` 等字面量，例如 `rg '\.env' docs/`。换一个不含这些字面量的检索词即可。

### Codex 的 apply_patch

Codex 改文件走 `apply_patch`，参数里没有 `file_path`。共享门从 `apply_patch` 的 `tool_input` 里任一字符串值提取补丁头 `*** Add File:`、`*** Update File:`、`*** Delete File:`、`*** Move to:` 之后的路径，再套 FILE 规则；Bash 命令调用 `apply_patch`（例如 heredoc 形式）时同样提取。Write、Edit 写入的正文不解析，文档里的补丁示例不会误拦。

这是尽力而为的覆盖：离线探针已覆盖补丁头的各种写法，但 Codex 真实会话里 hook 收到的 `tool_name` 是否就是 `apply_patch`、补丁文本放在哪个键里，都未实测（PENDING）。对不上时 FILE 规则不生效，生成物仍由 SHELL 段的重定向与写入规则兜底。

### 失败关闭与协议

- 策略任一行非法、文件缺失或不是 UTF-8 时，受控工具（Bash、写文件工具、`apply_patch`）一律 exit 2，原因写到 stderr；其他工具照常放行。
- hook 只注册在受控工具上，所以 stdin 为空、不是合法 JSON 或不是 JSON 对象时，同样按失败关闭处理（exit 2）。
- 注册命令本身也失败关闭。Claude Code 与 Codex 只把 exit 2 当拦截（ZCode 沿用 Claude 协议，未实测），127（脚本或解释器找不到）、1 等其他退出码只记 hook 失败，工具照常执行；因此注册命令都把失败统一转成 exit 2：
  - Claude Code：`bash "${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel)}/.claude/hooks/block_dangerous.sh" || exit 2`。Claude Code 给 hook 导出 `CLAUDE_PROJECT_DIR`，会话 cwd 在仓库外也照常判定。
  - ZCode：`$(git rev-parse --show-toplevel)` 形式加 `|| exit 2`。ZCode 没有文档化的项目目录变量，这里不臆造；cwd 在仓库外时所有受控调用都被拦。
  - Codex（POSIX）：`command = 'python3 "$(git rev-parse --show-toplevel)/.codex/hooks/pre_tool_use_policy.py" || exit 2'`。Codex 0.160 把 exit 2 加 stderr 原因当作拦截（可执行文件里有 `PreToolUse hook exited with code 2 but did not write a blocking reason to stderr` 的报错），`python3` 缺失时 shell 自己会往 stderr 写原因。
  - Codex（Windows）：Codex 在 Windows 上经 PowerShell 执行 `command_windows`，内容是同一条 `python3 "$(git rev-parse --show-toplevel)/…/pre_tool_use_policy.py"`，后接 `; if (-not $? -or $LASTEXITCODE -ne 0) { exit 2 }`。POSIX 写法在这里不能用：Windows PowerShell 5.1 直接拒绝 `||`（解析错误，exit 1），PowerShell 7 里 `|| exit 2` 不生效，失败一律以 exit 1 结束，两者对 Codex 都等于放行。`$?` 覆盖 `python3` 找不到的情况（此时 `$LASTEXITCODE` 不会被设置，还停留在 `git rev-parse` 的 0），`$LASTEXITCODE` 覆盖安全门或 Python 的非 0 退出。键名 `command_windows` 与 `commandWindows` 都被 Codex 0.160 接受：把任一个设成整数，`codex -c … features list` 都报 `invalid type: integer, expected a string`，未知键则被忽略。
- `block_dangerous.sh` 依次尝试 `python3`、`python`；第一个解释器无法运行时（例如 Windows 应用商店的 `python3` 占位程序）回退到下一个，两者都不可用时 exit 2。Codex 适配器加载不到共享门或共享门运行出错时同样 exit 2。
- 判定看门狗：客户端在 hook 超时（30 秒）后放行工具，而病态命令能让正则引擎在不释放 GIL 的情况下长时间运行。共享门用 `faulthandler` 的 C 级看门狗限时 10 秒（`pre_tool_use_gate.py::EVALUATION_DEADLINE_SECONDS`），超时以 exit 1 结束并把调用栈写到 stderr；注册命令把它转成 exit 2。`block_dangerous.sh` 最多试两个解释器，两次限时加启动仍在 30 秒内。
- Claude Code 与 ZCode 收到 `hookSpecificOutput.permissionDecision`，取值 deny 或 ask。
- Codex 收到同一结构，但从不出现 ask：Codex 0.160 把 ask 当作 hook 失败并继续执行工具，所以 ask 级规则按 deny 返回，理由里注明。Codex 的输出键集合按其可执行文件内嵌的 PreToolUse 输出 schema（两级都是 `additionalProperties: false`）锁进测试。wezterm 参考实现里扁平的 `{"permissionDecision", "reason"}` 不在该 schema 内，属于无效输出；按 Codex 文档，hook 只会被记为失败，工具照常执行。本仓没有照搬。

### 修改流程

只改 `dangerous_patterns.conf`，然后跑 `python -m unittest scripts.test_ai_tool_hooks`。新增模式要同时补「真执行被拦」与「文本提及放行」两组探针；探针里的危险字面量用字符串拼接构造，避免被宿主会话自身的安全门拦下。改注册命令或 matcher 时，同步改测试里锁定的命令与 matcher 常量。

## 权限

- **Claude Code**：
  - `defaultMode: acceptEdits`。
  - allow：仓内 `Read(./**)` 与 `Edit(./**)`，Glob、Grep、WebSearch、WebFetch、Agent、Skill，以及常用命令前缀：常规 git 子命令、`just`、`python`/`python3 scripts/*`、`python -m unittest`、`zig build`、`zig fmt`、`gh run list|view`、`actionlint`。
  - deny：读取 `.env`、`*.pem` 与 `.git/`。
  - 不设 ask 列表：ask 在任何模式下都会弹窗，allow 与 hook 都压不住。
  - 不写 `Write(...)` 路径规则：Claude Code 只按 `Read(...)`/`Edit(...)` 判定文件权限，`Edit` 规则同时覆盖 Write 与 NotebookEdit。
  - reviewer 的 `permissionMode` 会被主会话的 acceptEdits 覆盖，所以只读边界靠工具白名单（Read、Grep、Glob、Bash）与 `disallowedTools`。
- **Codex**：
  - `approval_policy = "never"` + `sandbox_mode = "danger-full-access"`，是用户授权的基线，与 wezterm、herdr 两个 fork 一致；破坏性操作由安全门兜底。
  - `[shell_environment_policy]` 继承全部环境变量，但排除 `*KEY*`、`*SECRET*`、`*TOKEN*`、`*PASSWORD*`。
  - reviewer 用 `config_file` 注册，`sandbox_mode = "read-only"`。
  - 项目层配置只在 Codex 信任本项目后加载；非托管 hook 首次出现或内容变更后，要在 `/hooks` 里审阅并信任，否则会被跳过。
- **ZCode**：只有 hooks；`hooks.enabled: true` 与毫秒单位的 `timeoutMs` 缺一不可。
- **Kimi Code**：项目不提供配置，审批行为由用户自己的设置决定。

## Kimi Code

- **规则**：读根 `AGENTS.md`。搭建本框架的 Kimi Code 会话启动时注入了根 `AGENTS.md`（当时只有上游原文），文件落盘变化后会提示重读。
- **skills**：按[官方文档](https://www.kimi.com/code/docs/en/kimi-code-cli/customization/skills.html)，项目级扫描 `.kimi-code/skills/` 与 `.agents/skills/`，用户级扫描 `$KIMI_CODE_HOME/skills/` 与 `~/.agents/skills/`。
  - 本仓 `.agents/skills/writing-commit-messages` 是上游 skill，格式为 `<subsystem>: <summary>`。Kimi Code 与 Codex 都会发现它，本会话的项目 skill 列表里就有它；Claude Code 不读取 `.agents/`。
  - 提交信息一律按根 `AGENTS.md`「提交规范」的 `type(scope): 中文描述`，fork 规则优先；该 skill 只用于准备回馈上游的提交。
  - `.agents/commands/review-branch` 仍可作为审核提示使用，结论按 `code-review` 的格式输出。
- **hooks**：按[官方文档](https://www.kimi.com/code/docs/en/kimi-code-cli/customization/hooks.html)，Kimi Code 的 hooks 只写在用户级 `~/.kimi-code/config.toml` 的 `[[hooks]]` 里，没有项目级 hooks，所以本仓安全门不会自动作用于 Kimi 会话；而且 Kimi 的 hook 出错或超时都按放行处理（fail-open）。
  - 需要时可以在用户配置里自行挂接，下面的写法未经验证：
    ```toml
    [[hooks]]
    event = "PreToolUse"
    matcher = "^(Bash|Write|Edit)$"
    command = 'python3 "$(git rev-parse --show-toplevel)/.codex/hooks/pre_tool_use_policy.py" || exit 2'
    timeout = 30
    ```
  - 这里选 Codex 适配器，是因为 Kimi 文档只描述了 deny（exit 2，或 `hookSpecificOutput.permissionDecision: "deny"`），没有提到 ask；末尾的 `|| exit 2` 把启动失败也转成 deny。共享门已兼容 Kimi 写文件工具的 `path` 参数。如果 Kimi 在 Windows 上经 PowerShell 执行 hook，`||` 同样失效，要换成 `.codex/config.toml` 里 `command_windows` 的写法。

## 验证账本

只把实际跑过的检查记为 PASS。离线探针都在 `scripts/test_ai_tool_hooks.py` 里，2026-10-07 在 Windows 11 上实测：

- 从 Git Bash 运行 `python -m unittest scripts.test_ai_tool_hooks`：60 项通过，exit 0。
- 从 cmd.exe 在最小 Windows PATH 下运行同一命令：此时 `bash` 先解析到 WindowsApps 的 WSL 启动器，测试改从 `git --exec-path` 推导出 Git Bash，60 项同样全部通过，exit 0。
- PowerShell 测试在本机用 Windows PowerShell 5.1.26100 与 PowerShell 7.6.6 原样执行注册的 `command_windows`；Windows 上两者都找不到时测试失败而不是跳过，只有非 Windows 主机才跳过。
- `command_windows` 的键名用 `codex -c … features list`（0.160.0）离线核对：把它设成整数时配置加载报类型错误，未知键不报错；同一 hooks 段放进临时 `CODEX_HOME` 的 `config.toml` 时加载通过。

| 项 | Claude | Codex | Kimi | ZCode |
|---|---|---|---|---|
| 配置可解析且形状锁定 | PASS（JSON；无 ask 列表；hook 注册与脚本存在） | PASS（tomllib；数组表 hooks、matcher 含 `apply_patch`、秒单位 timeout、reviewer `config_file` 存在且为 read-only） | N/A（无项目配置） | PASS（JSON；`enabled: true`、`timeoutMs: 30000`） |
| 引擎成对探针（真执行拦 / 文本提及放行 / FILE 绝对与相对路径） | PASS | PASS | N/A | PASS |
| `apply_patch` 补丁头的 FILE 判定（离线） | N/A（无此工具） | PASS | N/A | N/A（无此工具） |
| 40 个长选项的命令 1 秒内判完（防回溯超时） | PASS | PASS | N/A | PASS |
| 判定看门狗（超时以非 0 结束，注册命令转成 exit 2） | PASS | PASS | N/A | PASS |
| 按注册命令原样经 Git Bash 执行（仓库根与子目录两种 cwd） | PASS | PASS（`command`） | N/A | PASS |
| 按 `command_windows` 原样经 powershell.exe 5.1 与 pwsh 7 执行 | N/A | PASS（deny 输出 JSON 且 exit 0；空 payload、仓库外 cwd、缺 `python3` 都 exit 2） | N/A | N/A（ZCode 无此字段，见下文第 6 步） |
| 注册命令失败关闭（仓库外 cwd、stdin 非 JSON、缺解释器都 exit 2） | PASS（设了 `CLAUDE_PROJECT_DIR` 时仓库外照常判定） | PASS | N/A | PASS |
| 协议输出 | PASS（deny / ask） | PASS（只出 deny，键集合符合 0.160 schema） | N/A | PASS（Claude 协议输出；ZCode 是否按该协议执行未实测） |
| 失败关闭（策略损坏、缺 Python、缺共享门、共享门运行出错） | PASS | PASS | N/A | PASS |
| 适配器完整性（python3 调用的文件过 `ast.parse`，bash 调用的文件过 `bash -n`） | PASS | PASS | N/A | PASS |
| 规则提醒 `paths` 的每个 glob 命中 Git 可见文件 | PASS | N/A | N/A | N/A |
| 本机客户端 | PENDING（未安装 claude） | PASS（`codex --version`：codex-cli 0.160.0） | PASS（`kimi --version`：2.1.1） | PENDING（未安装 zcode） |
| 严格配置解析（真实启动） | PENDING | PENDING（见下注） | N/A | PENDING |
| 新会话加载规则入口 | PENDING | PENDING | PENDING（fork 段需新会话确认） | PENDING |
| 真实会话中 hook 拦截与信任流程 | PENDING | PENDING（含 `apply_patch` 是否触发 hook） | N/A（无项目级 hooks） | PENDING |
| MCP | N/A（本仓无项目级 MCP） | N/A | N/A | N/A |

注：`codex --strict-config --version` 在仓库根输出 `codex-cli 0.160.0`、exit 0，但附加无效的 `-c` 覆盖时同样 exit 0，说明 `--version` 不加载配置，不能代证严格解析；`codex features`、`codex mcp` 不接受 `--strict-config`。真正的严格解析只能在启动会话时验证。

PENDING 的补验方式：在对应客户端里从仓库根开新会话，然后依次确认：

1. 规则入口：Claude Code 用 `/context` 或 `/memory` 确认 `CLAUDE.md` 与导入的 `AGENTS.md` 已加载；其他客户端直接问它根 `AGENTS.md` 的 fork 段讲了什么。Codex 与 Claude Code 还要先接受项目信任，Codex 在 `/hooks` 里信任 PreToolUse hook。
2. 拦截：让 agent 执行 `gh pr create --help`，应被 deny；这条命令即使漏拦也只会打印帮助。
3. ask：执行 `git clean -n -d`，Claude Code 与 ZCode 应弹出确认，Codex 应被 deny；`-n` 让它即使漏拦也只是演练。
4. FILE：Claude Code 与 ZCode 写 `graphify-out/__probe__.txt`，Codex 用 `apply_patch` 新增同一文件，都应被 deny；该目录已被忽略，漏拦也无害。
5. 放行：执行 `git status`，应直接通过。
6. Windows 上的 hook shell：
   - Codex：确认它在 Windows 上执行的是 `command_windows`，而且是经 PowerShell 执行。可以在 `docs/` 下用 `apply_patch` 新增一个文件看能否放行，再按第 4 步看能否拦截。只要 hook 能在 Windows 上判定，就说明 `$(git rev-parse --show-toplevel)` 已展开、退出码判定生效。
   - ZCode：注册命令用的是 POSIX 的 `|| exit 2`。如果 ZCode 在 Windows 上经 PowerShell 执行 hook，会遇到与 Codex 相同的问题：Windows PowerShell 5.1 解析失败，PowerShell 7 的失败只剩 exit 1，都等于放行。ZCode 的配置没有类似 `command_windows` 的字段，这里不臆造，记 PENDING；补验时让它在仓库外的 cwd 执行 `git status`，应被拦截。
   - Claude Code：注册命令同样依赖 POSIX shell（`${…:-…}` 与 `||`），要确认 Windows 上的 hook 经 Git Bash 执行。在 Windows 上做第 2 步即可：换成其他 shell 时这两种语法会解析失败，表现为 hook 报错、工具照常执行。

补验后把对应格改成 PASS 并注明日期与客户端版本。
